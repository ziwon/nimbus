const std = @import("std");
const heartbeat = @import("heartbeat.zig");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Registry = struct {
    db: *c.sqlite3,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Registry {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        var db_optional: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        if (c.sqlite3_open_v2(path_z.ptr, &db_optional, flags, null) != c.SQLITE_OK) {
            if (db_optional) |db| _ = c.sqlite3_close(db);
            return error.SqliteOpenFailed;
        }

        var registry: Registry = .{ .db = db_optional.?, .allocator = allocator };
        errdefer registry.close();
        try registry.exec("PRAGMA journal_mode=WAL;");
        try registry.exec("PRAGMA foreign_keys=ON;");
        try registry.exec("PRAGMA busy_timeout=5000;");
        try registry.migrate();
        return registry;
    }

    pub fn close(self: *Registry) void {
        _ = c.sqlite3_close(self.db);
        self.* = undefined;
    }

    fn migrate(self: *Registry) !void {
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS nodes (
            \\  node_id TEXT PRIMARY KEY,
            \\  hostname TEXT NOT NULL,
            \\  role TEXT NOT NULL,
            \\  os TEXT NOT NULL,
            \\  arch TEXT NOT NULL,
            \\  abi TEXT NOT NULL,
            \\  cpu_count INTEGER NOT NULL,
            \\  agent_version TEXT NOT NULL,
            \\  report_json TEXT NOT NULL,
            \\  first_seen_unix_ms INTEGER NOT NULL,
            \\  last_seen_unix_ms INTEGER NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS heartbeat_history (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  node_id TEXT NOT NULL REFERENCES nodes(node_id) ON DELETE CASCADE,
            \\  received_unix_ms INTEGER NOT NULL,
            \\  reported_unix_ms INTEGER NOT NULL,
            \\  report_json TEXT NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS heartbeat_history_node_time
            \\  ON heartbeat_history(node_id, received_unix_ms DESC);
            \\CREATE TABLE IF NOT EXISTS audit_events (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  created_unix_ms INTEGER NOT NULL,
            \\  node_id TEXT,
            \\  action TEXT NOT NULL,
            \\  detail TEXT NOT NULL
            \\);
        );
    }

    pub fn recordHeartbeat(
        self: *Registry,
        report: heartbeat.Heartbeat,
        report_json: []const u8,
        received_unix_ms: i64,
    ) !void {
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};

        var upsert = try self.prepare(
            \\INSERT INTO nodes (
            \\  node_id, hostname, role, os, arch, abi, cpu_count, agent_version,
            \\  report_json, first_seen_unix_ms, last_seen_unix_ms
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            \\ON CONFLICT(node_id) DO UPDATE SET
            \\  hostname=excluded.hostname,
            \\  role=excluded.role,
            \\  os=excluded.os,
            \\  arch=excluded.arch,
            \\  abi=excluded.abi,
            \\  cpu_count=excluded.cpu_count,
            \\  agent_version=excluded.agent_version,
            \\  report_json=excluded.report_json,
            \\  last_seen_unix_ms=excluded.last_seen_unix_ms;
        );
        defer upsert.finalize();
        try upsert.bindText(1, report.node_id);
        try upsert.bindText(2, report.hostname);
        try upsert.bindText(3, report.role);
        try upsert.bindText(4, report.platform.os);
        try upsert.bindText(5, report.platform.arch);
        try upsert.bindText(6, report.platform.abi);
        try upsert.bindInt64(7, @intCast(report.resources.cpu_count));
        try upsert.bindText(8, report.agent_version);
        try upsert.bindText(9, report_json);
        try upsert.bindInt64(10, received_unix_ms);
        try upsert.bindInt64(11, received_unix_ms);
        try upsert.done();

        var history = try self.prepare(
            "INSERT INTO heartbeat_history " ++
                "(node_id, received_unix_ms, reported_unix_ms, report_json) VALUES (?, ?, ?, ?);",
        );
        defer history.finalize();
        try history.bindText(1, report.node_id);
        try history.bindInt64(2, received_unix_ms);
        try history.bindInt64(3, report.timestamp_unix_ms);
        try history.bindText(4, report_json);
        try history.done();

        try self.audit(received_unix_ms, report.node_id, "heartbeat.accepted", report.agent_version);
        try self.exec("COMMIT;");
    }

    pub fn listNodes(self: *Registry, now_unix_ms: i64, stale_after_ms: i64) ![]u8 {
        var statement = try self.prepare(
            \\SELECT node_id, hostname, role, os, arch, abi, cpu_count,
            \\       agent_version, last_seen_unix_ms
            \\FROM nodes ORDER BY node_id;
        );
        defer statement.finalize();

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        try output.append(self.allocator, '[');
        var first = true;
        while (try statement.row()) {
            const summary: NodeSummary = .{
                .node_id = statement.columnText(0),
                .hostname = statement.columnText(1),
                .role = statement.columnText(2),
                .platform = .{
                    .os = statement.columnText(3),
                    .arch = statement.columnText(4),
                    .abi = statement.columnText(5),
                },
                .cpu_count = @intCast(statement.columnInt64(6)),
                .agent_version = statement.columnText(7),
                .last_seen_unix_ms = statement.columnInt64(8),
                .status = status(now_unix_ms, statement.columnInt64(8), stale_after_ms),
            };
            const item = try std.json.Stringify.valueAlloc(self.allocator, summary, .{});
            defer self.allocator.free(item);
            if (!first) try output.append(self.allocator, ',');
            first = false;
            try output.appendSlice(self.allocator, item);
        }
        try output.appendSlice(self.allocator, "]\n");
        return output.toOwnedSlice(self.allocator);
    }

    pub fn inspectNode(
        self: *Registry,
        node_id: []const u8,
        now_unix_ms: i64,
        stale_after_ms: i64,
    ) !?[]u8 {
        var statement = try self.prepare(
            "SELECT report_json, last_seen_unix_ms FROM nodes WHERE node_id=?;",
        );
        defer statement.finalize();
        try statement.bindText(1, node_id);
        if (!try statement.row()) return null;

        const last_seen = statement.columnInt64(1);
        return try std.fmt.allocPrint(
            self.allocator,
            "{{\"status\":\"{s}\",\"last_seen_unix_ms\":{d},\"report\":{s}}}\n",
            .{ status(now_unix_ms, last_seen, stale_after_ms), last_seen, statement.columnText(0) },
        );
    }

    fn audit(
        self: *Registry,
        timestamp: i64,
        node_id: []const u8,
        action: []const u8,
        detail: []const u8,
    ) !void {
        var statement = try self.prepare(
            "INSERT INTO audit_events (created_unix_ms, node_id, action, detail) VALUES (?, ?, ?, ?);",
        );
        defer statement.finalize();
        try statement.bindInt64(1, timestamp);
        try statement.bindText(2, node_id);
        try statement.bindText(3, action);
        try statement.bindText(4, detail);
        try statement.done();
    }

    fn exec(self: *Registry, sql: [*:0]const u8) !void {
        if (c.sqlite3_exec(self.db, sql, null, null, null) != c.SQLITE_OK) return error.SqliteExecFailed;
    }

    fn prepare(self: *Registry, sql: []const u8) !Statement {
        var optional: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &optional, null) != c.SQLITE_OK)
            return error.SqlitePrepareFailed;
        return .{ .handle = optional.? };
    }
};

const NodeSummary = struct {
    node_id: []const u8,
    hostname: []const u8,
    role: []const u8,
    platform: heartbeat.Platform,
    cpu_count: usize,
    agent_version: []const u8,
    last_seen_unix_ms: i64,
    status: []const u8,
};

const Statement = struct {
    handle: *c.sqlite3_stmt,

    fn finalize(self: *Statement) void {
        _ = c.sqlite3_finalize(self.handle);
        self.* = undefined;
    }

    fn bindText(self: *Statement, index: c_int, value: []const u8) !void {
        if (c.sqlite3_bind_text(self.handle, index, value.ptr, @intCast(value.len), null) != c.SQLITE_OK)
            return error.SqliteBindFailed;
    }

    fn bindInt64(self: *Statement, index: c_int, value: i64) !void {
        if (c.sqlite3_bind_int64(self.handle, index, value) != c.SQLITE_OK)
            return error.SqliteBindFailed;
    }

    fn done(self: *Statement) !void {
        if (c.sqlite3_step(self.handle) != c.SQLITE_DONE) return error.SqliteStepFailed;
    }

    fn row(self: *Statement) !bool {
        return switch (c.sqlite3_step(self.handle)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => error.SqliteStepFailed,
        };
    }

    fn columnText(self: *Statement, index: c_int) []const u8 {
        const pointer = c.sqlite3_column_text(self.handle, index);
        if (pointer == null) return "";
        const length: usize = @intCast(c.sqlite3_column_bytes(self.handle, index));
        return @as([*]const u8, @ptrCast(pointer))[0..length];
    }

    fn columnInt64(self: *Statement, index: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, index);
    }
};

fn status(now_unix_ms: i64, last_seen_unix_ms: i64, stale_after_ms: i64) []const u8 {
    return if (now_unix_ms - last_seen_unix_ms > stale_after_ms) "stale" else "online";
}

test "SQLite registry persists and marks nodes stale" {
    var registry = try Registry.open(std.testing.allocator, ":memory:");
    defer registry.close();
    const report: heartbeat.Heartbeat = .{
        .node_id = "edge-01",
        .hostname = "edge-01",
        .role = "edge",
        .platform = .{ .os = "linux", .arch = "aarch64", .abi = "musl" },
        .resources = .{ .cpu_count = 4 },
        .timestamp_unix_ms = 1000,
    };
    const json = try heartbeat.serializeAlloc(std.testing.allocator, report);
    defer std.testing.allocator.free(json);
    try registry.recordHeartbeat(report, json, 1000);

    const nodes = try registry.listNodes(4001, 3000);
    defer std.testing.allocator.free(nodes);
    try std.testing.expect(std.mem.indexOf(u8, nodes, "\"node_id\":\"edge-01\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, nodes, "\"status\":\"stale\"") != null);
}
