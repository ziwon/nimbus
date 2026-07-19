const std = @import("std");
const accelerator = @import("accelerator.zig");
const allocation = @import("allocation.zig");
const heartbeat = @import("heartbeat.zig");
const orchestration = @import("orchestration.zig");
const edge_placement = @import("placement.zig");
const c = @cImport({
    @cInclude("sqlite3.h");
});

const heartbeat_sample_ms: i64 = 5 * 60 * 1000;
const heartbeat_retention_ms: i64 = 7 * 24 * 60 * 60 * 1000;
const audit_retention_ms: i64 = 30 * 24 * 60 * 60 * 1000;
const workload_status_retention_ms: i64 = 30 * 24 * 60 * 60 * 1000;

pub const Registry = struct {
    db: *c.sqlite3,
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Registry {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        var db_optional: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        if (c.sqlite3_open_v2(path_z.ptr, &db_optional, flags, null) != c.SQLITE_OK) {
            if (db_optional) |db| {
                logSqliteError(db, "open");
                _ = c.sqlite3_close(db);
            }
            return error.SqliteOpenFailed;
        }

        var registry: Registry = .{ .db = db_optional.?, .allocator = allocator, .io = io };
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

    pub fn ready(self: *Registry) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var statement = try self.prepare("SELECT 1;");
        defer statement.finalize();
        return try statement.row() and statement.columnInt64(0) == 1;
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
            \\  host_arch TEXT,
            \\  cpu_count INTEGER NOT NULL,
            \\  agent_version TEXT NOT NULL,
            \\  report_json TEXT NOT NULL,
            \\  first_seen_unix_ms INTEGER NOT NULL,
            \\  last_seen_unix_ms INTEGER NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS node_labels (
            \\  node_id TEXT NOT NULL REFERENCES nodes(node_id) ON DELETE CASCADE,
            \\  label_key TEXT NOT NULL,
            \\  label_value TEXT NOT NULL,
            \\  PRIMARY KEY (node_id, label_key)
            \\);
            \\CREATE INDEX IF NOT EXISTS node_labels_lookup
            \\  ON node_labels(label_key, label_value, node_id);
            \\CREATE TABLE IF NOT EXISTS node_features (
            \\  node_id TEXT NOT NULL REFERENCES nodes(node_id) ON DELETE CASCADE,
            \\  feature TEXT NOT NULL,
            \\  PRIMARY KEY (node_id, feature)
            \\);
            \\CREATE TABLE IF NOT EXISTS node_accelerator_inventory (
            \\  node_id TEXT PRIMARY KEY REFERENCES nodes(node_id) ON DELETE CASCADE,
            \\  heartbeat_schema_version INTEGER NOT NULL,
            \\  inventory_schema_version INTEGER NOT NULL,
            \\  status TEXT NOT NULL,
            \\  updated_unix_ms INTEGER NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS node_accelerators (
            \\  node_id TEXT NOT NULL REFERENCES nodes(node_id) ON DELETE CASCADE,
            \\  accelerator_id TEXT NOT NULL,
            \\  kind TEXT NOT NULL,
            \\  vendor TEXT NOT NULL,
            \\  model TEXT NOT NULL,
            \\  source TEXT NOT NULL,
            \\  availability TEXT NOT NULL,
            \\  memory_total_bytes INTEGER,
            \\  PRIMARY KEY (node_id, accelerator_id)
            \\);
            \\CREATE TABLE IF NOT EXISTS node_accelerator_capabilities (
            \\  node_id TEXT NOT NULL,
            \\  accelerator_id TEXT NOT NULL,
            \\  capability TEXT NOT NULL,
            \\  PRIMARY KEY (node_id, accelerator_id, capability),
            \\  FOREIGN KEY (node_id, accelerator_id)
            \\    REFERENCES node_accelerators(node_id, accelerator_id) ON DELETE CASCADE
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
            \\CREATE TABLE IF NOT EXISTS schema_migrations (
            \\  version INTEGER PRIMARY KEY,
            \\  applied_unix_ms INTEGER NOT NULL
            \\);
            \\INSERT OR IGNORE INTO schema_migrations (version, applied_unix_ms)
            \\  VALUES (1, 0), (2, 0), (3, 0), (4, 0);
            \\CREATE TABLE IF NOT EXISTS deployments (
            \\  name TEXT PRIMARY KEY,
            \\  revision INTEGER NOT NULL,
            \\  spec_json TEXT NOT NULL,
            \\  previous_revision INTEGER,
            \\  previous_spec_json TEXT,
            \\  batch_size INTEGER NOT NULL,
            \\  max_unavailable INTEGER NOT NULL,
            \\  pause_seconds INTEGER NOT NULL,
            \\  auto_rollback INTEGER NOT NULL,
            \\  current_wave INTEGER NOT NULL DEFAULT 0,
            \\  wave_started_unix_ms INTEGER NOT NULL,
            \\  status TEXT NOT NULL,
            \\  created_unix_ms INTEGER NOT NULL,
            \\  updated_unix_ms INTEGER NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS deployment_targets (
            \\  deployment_name TEXT NOT NULL REFERENCES deployments(name) ON DELETE CASCADE,
            \\  target_kind TEXT NOT NULL,
            \\  target_value TEXT NOT NULL,
            \\  PRIMARY KEY (deployment_name, target_kind, target_value)
            \\);
            \\CREATE INDEX IF NOT EXISTS deployment_targets_lookup
            \\  ON deployment_targets(target_kind, target_value, deployment_name);
            \\CREATE TABLE IF NOT EXISTS deployment_label_targets (
            \\  deployment_name TEXT NOT NULL REFERENCES deployments(name) ON DELETE CASCADE,
            \\  label_key TEXT NOT NULL,
            \\  label_value TEXT NOT NULL,
            \\  PRIMARY KEY (deployment_name, label_key)
            \\);
            \\CREATE TABLE IF NOT EXISTS workload_assignments (
            \\  deployment_name TEXT NOT NULL REFERENCES deployments(name) ON DELETE CASCADE,
            \\  node_id TEXT NOT NULL REFERENCES nodes(node_id) ON DELETE CASCADE,
            \\  wave INTEGER NOT NULL,
            \\  state TEXT NOT NULL,
            \\  observed_revision INTEGER NOT NULL DEFAULT 0,
            \\  message TEXT NOT NULL DEFAULT '',
            \\  updated_unix_ms INTEGER NOT NULL,
            \\  PRIMARY KEY (deployment_name, node_id)
            \\);
            \\CREATE INDEX IF NOT EXISTS workload_assignments_wave
            \\  ON workload_assignments(deployment_name, wave, state);
            \\CREATE TABLE IF NOT EXISTS accelerator_reservations (
            \\  node_id TEXT NOT NULL REFERENCES nodes(node_id) ON DELETE CASCADE,
            \\  accelerator_id TEXT NOT NULL,
            \\  deployment_name TEXT NOT NULL REFERENCES deployments(name) ON DELETE CASCADE,
            \\  revision INTEGER NOT NULL,
            \\  reserved_unix_ms INTEGER NOT NULL,
            \\  PRIMARY KEY (node_id, accelerator_id)
            \\);
            \\CREATE INDEX IF NOT EXISTS accelerator_reservations_owner
            \\  ON accelerator_reservations(deployment_name, node_id, revision);
            \\CREATE TABLE IF NOT EXISTS accelerator_allocation_commands (
            \\  node_id TEXT NOT NULL REFERENCES nodes(node_id) ON DELETE RESTRICT,
            \\  deployment_name TEXT NOT NULL,
            \\  allocation_id TEXT NOT NULL UNIQUE,
            \\  generation INTEGER NOT NULL,
            \\  revision INTEGER NOT NULL,
            \\  action TEXT NOT NULL,
            \\  phase TEXT NOT NULL,
            \\  created_unix_ms INTEGER NOT NULL,
            \\  updated_unix_ms INTEGER NOT NULL,
            \\  PRIMARY KEY (node_id, deployment_name),
            \\  UNIQUE (allocation_id, generation),
            \\  CHECK (generation > 0),
            \\  CHECK (revision > 0),
            \\  CHECK (action IN ('run', 'release')),
            \\  CHECK (phase IN (
            \\    'pending', 'prepared', 'stopping_old', 'old_stopped',
            \\    'starting_target', 'target_started', 'verifying', 'active',
            \\    'stopping_target', 'target_stopped', 'restoring_old',
            \\    'release_requested', 'stopping', 'released_ack_pending',
            \\    'released', 'ambiguous', 'failed'
            \\  ))
            \\);
            \\CREATE TABLE IF NOT EXISTS accelerator_allocation_claims (
            \\  node_id TEXT NOT NULL,
            \\  accelerator_id TEXT NOT NULL,
            \\  allocation_id TEXT NOT NULL,
            \\  deployment_name TEXT NOT NULL,
            \\  generation INTEGER NOT NULL,
            \\  revision INTEGER NOT NULL,
            \\  role TEXT NOT NULL,
            \\  updated_unix_ms INTEGER NOT NULL,
            \\  PRIMARY KEY (node_id, accelerator_id),
            \\  CHECK (generation > 0),
            \\  CHECK (revision > 0),
            \\  CHECK (role IN ('active', 'candidate', 'retiring', 'ambiguous')),
            \\  FOREIGN KEY (allocation_id, generation)
            \\    REFERENCES accelerator_allocation_commands(allocation_id, generation)
            \\    ON UPDATE CASCADE ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED
            \\);
            \\CREATE INDEX IF NOT EXISTS accelerator_allocation_claims_owner
            \\  ON accelerator_allocation_claims(allocation_id, role, accelerator_id);
            \\CREATE TABLE IF NOT EXISTS accelerator_allocation_status_history (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  allocation_id TEXT NOT NULL,
            \\  generation INTEGER NOT NULL,
            \\  node_id TEXT NOT NULL,
            \\  deployment_name TEXT NOT NULL,
            \\  revision INTEGER NOT NULL,
            \\  phase TEXT NOT NULL,
            \\  message TEXT NOT NULL,
            \\  observed_unix_ms INTEGER NOT NULL,
            \\  received_unix_ms INTEGER NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS accelerator_allocation_status_lookup
            \\  ON accelerator_allocation_status_history(
            \\    allocation_id, generation, received_unix_ms DESC
            \\  );
            \\CREATE TABLE IF NOT EXISTS placement_decisions (
            \\  deployment_name TEXT NOT NULL REFERENCES deployments(name) ON DELETE CASCADE,
            \\  node_id TEXT NOT NULL REFERENCES nodes(node_id) ON DELETE CASCADE,
            \\  revision INTEGER NOT NULL,
            \\  status TEXT NOT NULL,
            \\  reason_code TEXT NOT NULL,
            \\  reason_detail TEXT NOT NULL,
            \\  updated_unix_ms INTEGER NOT NULL,
            \\  PRIMARY KEY (deployment_name, node_id)
            \\);
            \\CREATE TABLE IF NOT EXISTS workload_status_history (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  deployment_name TEXT NOT NULL,
            \\  node_id TEXT NOT NULL,
            \\  revision INTEGER NOT NULL,
            \\  state TEXT NOT NULL,
            \\  message TEXT NOT NULL,
            \\  observed_unix_ms INTEGER NOT NULL,
            \\  received_unix_ms INTEGER NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS workload_status_history_lookup
            \\  ON workload_status_history(deployment_name, node_id, received_unix_ms DESC);
        );
        const has_host_arch = blk: {
            var column = try self.prepare(
                "SELECT 1 FROM pragma_table_info('nodes') WHERE name='host_arch';",
            );
            defer column.finalize();
            break :blk try column.row();
        };
        if (!has_host_arch) try self.exec("ALTER TABLE nodes ADD COLUMN host_arch TEXT;");
        try self.exec(
            "INSERT OR IGNORE INTO schema_migrations (version, applied_unix_ms) VALUES (5, 0);",
        );
    }

    pub fn recordHeartbeat(
        self: *Registry,
        report: heartbeat.Heartbeat,
        report_json: []const u8,
        received_unix_ms: i64,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var enrolled = true;
        var latest_history: ?i64 = null;
        {
            var current = try self.prepare("SELECT 1 FROM nodes WHERE node_id=?;");
            defer current.finalize();
            try current.bindText(1, report.node_id);
            enrolled = !try current.row();
        }
        {
            var latest = try self.prepare(
                "SELECT MAX(received_unix_ms) FROM heartbeat_history WHERE node_id=?;",
            );
            defer latest.finalize();
            try latest.bindText(1, report.node_id);
            if (try latest.row() and !latest.columnIsNull(0)) latest_history = latest.columnInt64(0);
        }
        const sample_history = latest_history == null or
            received_unix_ms -| latest_history.? >= heartbeat_sample_ms;

        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};

        var upsert = try self.prepare(
            \\INSERT INTO nodes (
            \\  node_id, hostname, role, os, arch, abi, host_arch, cpu_count,
            \\  agent_version, report_json, first_seen_unix_ms, last_seen_unix_ms
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            \\ON CONFLICT(node_id) DO UPDATE SET
            \\  hostname=excluded.hostname,
            \\  role=excluded.role,
            \\  os=excluded.os,
            \\  arch=excluded.arch,
            \\  abi=excluded.abi,
            \\  host_arch=excluded.host_arch,
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
        if (report.platform.host_arch) |host_arch|
            try upsert.bindText(7, host_arch)
        else
            try upsert.bindNull(7);
        try upsert.bindInt64(8, @intCast(report.resources.cpu_count));
        try upsert.bindText(9, report.agent_version);
        try upsert.bindText(10, report_json);
        try upsert.bindInt64(11, received_unix_ms);
        try upsert.bindInt64(12, received_unix_ms);
        try upsert.done();

        var clear_labels = try self.prepare("DELETE FROM node_labels WHERE node_id=?;");
        defer clear_labels.finalize();
        try clear_labels.bindText(1, report.node_id);
        try clear_labels.done();
        for (report.labels) |label| {
            var insert_label = try self.prepare(
                "INSERT INTO node_labels (node_id, label_key, label_value) VALUES (?, ?, ?);",
            );
            defer insert_label.finalize();
            try insert_label.bindText(1, report.node_id);
            try insert_label.bindText(2, label.key);
            try insert_label.bindText(3, label.value);
            try insert_label.done();
        }

        try self.replaceNodeAcceleratorInventory(report, received_unix_ms);
        try self.reschedulePlacementDeployments(received_unix_ms);

        if (sample_history) {
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

            var prune_history = try self.prepare(
                "DELETE FROM heartbeat_history WHERE received_unix_ms < ?;",
            );
            defer prune_history.finalize();
            try prune_history.bindInt64(1, received_unix_ms -| heartbeat_retention_ms);
            try prune_history.done();
        }
        if (enrolled) try self.audit(received_unix_ms, report.node_id, "node.enrolled", report.agent_version);
        try self.exec("COMMIT;");
    }

    fn replaceNodeAcceleratorInventory(
        self: *Registry,
        report: heartbeat.Heartbeat,
        received_unix_ms: i64,
    ) !void {
        var clear_features = try self.prepare("DELETE FROM node_features WHERE node_id=?;");
        defer clear_features.finalize();
        try clear_features.bindText(1, report.node_id);
        try clear_features.done();
        for (report.features) |feature| {
            var insert_feature = try self.prepare(
                "INSERT INTO node_features (node_id, feature) VALUES (?, ?);",
            );
            defer insert_feature.finalize();
            try insert_feature.bindText(1, report.node_id);
            try insert_feature.bindText(2, feature);
            try insert_feature.done();
        }

        const inventory_status = if (report.accelerator_inventory) |inventory|
            @tagName(inventory.status)
        else
            "unreported";
        const inventory_schema: i64 = if (report.accelerator_inventory) |inventory|
            inventory.schema_version
        else
            0;
        var upsert_inventory = try self.prepare(
            \\INSERT INTO node_accelerator_inventory (
            \\  node_id, heartbeat_schema_version, inventory_schema_version, status, updated_unix_ms
            \\) VALUES (?, ?, ?, ?, ?)
            \\ON CONFLICT(node_id) DO UPDATE SET
            \\  heartbeat_schema_version=excluded.heartbeat_schema_version,
            \\  inventory_schema_version=excluded.inventory_schema_version,
            \\  status=excluded.status,
            \\  updated_unix_ms=excluded.updated_unix_ms;
        );
        defer upsert_inventory.finalize();
        try upsert_inventory.bindText(1, report.node_id);
        try upsert_inventory.bindInt64(2, report.schema_version);
        try upsert_inventory.bindInt64(3, inventory_schema);
        try upsert_inventory.bindText(4, inventory_status);
        try upsert_inventory.bindInt64(5, received_unix_ms);
        try upsert_inventory.done();

        var clear_accelerators = try self.prepare("DELETE FROM node_accelerators WHERE node_id=?;");
        defer clear_accelerators.finalize();
        try clear_accelerators.bindText(1, report.node_id);
        try clear_accelerators.done();

        const inventory = report.accelerator_inventory orelse return;
        for (inventory.accelerators) |device| {
            var insert_device = try self.prepare(
                \\INSERT INTO node_accelerators (
                \\  node_id, accelerator_id, kind, vendor, model, source,
                \\  availability, memory_total_bytes
                \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            );
            defer insert_device.finalize();
            try insert_device.bindText(1, report.node_id);
            try insert_device.bindText(2, device.id);
            try insert_device.bindText(3, @tagName(device.kind));
            try insert_device.bindText(4, device.vendor);
            try insert_device.bindText(5, device.model);
            try insert_device.bindText(6, device.source);
            try insert_device.bindText(7, @tagName(device.availability));
            if (device.memory_total_bytes) |memory|
                try insert_device.bindInt64(8, @intCast(memory))
            else
                try insert_device.bindNull(8);
            try insert_device.done();

            for (device.capabilities) |capability| {
                var insert_capability = try self.prepare(
                    \\INSERT INTO node_accelerator_capabilities (
                    \\  node_id, accelerator_id, capability
                    \\) VALUES (?, ?, ?);
                );
                defer insert_capability.finalize();
                try insert_capability.bindText(1, report.node_id);
                try insert_capability.bindText(2, device.id);
                try insert_capability.bindText(3, capability);
                try insert_capability.done();
            }
        }
    }

    pub fn listNodes(
        self: *Registry,
        now_unix_ms: i64,
        stale_after_ms: i64,
        limit: u16,
        after: ?[]const u8,
    ) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var statement = try self.prepare(
            \\SELECT node_id, hostname, role, os, arch, abi, host_arch, cpu_count,
            \\       agent_version, last_seen_unix_ms
            \\FROM nodes WHERE node_id > ? ORDER BY node_id LIMIT ?;
        );
        defer statement.finalize();
        try statement.bindText(1, after orelse "");
        try statement.bindInt64(2, @as(i64, limit) + 1);

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        try output.appendSlice(self.allocator, "{\"items\":[");
        var first = true;
        var count: usize = 0;
        var has_more = false;
        var next_after: ?[]u8 = null;
        defer if (next_after) |value| self.allocator.free(value);
        while (try statement.row()) {
            if (count == limit) {
                has_more = true;
                break;
            }
            const summary: NodeSummary = .{
                .node_id = statement.columnText(0),
                .hostname = statement.columnText(1),
                .role = statement.columnText(2),
                .platform = .{
                    .os = statement.columnText(3),
                    .arch = statement.columnText(4),
                    .abi = statement.columnText(5),
                    .host_arch = if (statement.columnIsNull(6)) null else statement.columnText(6),
                },
                .cpu_count = @intCast(statement.columnInt64(7)),
                .agent_version = statement.columnText(8),
                .last_seen_unix_ms = statement.columnInt64(9),
                .status = status(now_unix_ms, statement.columnInt64(9), stale_after_ms),
            };
            const item = try std.json.Stringify.valueAlloc(self.allocator, summary, .{});
            defer self.allocator.free(item);
            if (!first) try output.append(self.allocator, ',');
            first = false;
            try output.appendSlice(self.allocator, item);
            if (next_after) |value| self.allocator.free(value);
            next_after = try self.allocator.dupe(u8, summary.node_id);
            count += 1;
        }
        try output.appendSlice(self.allocator, "],\"next_after\":");
        if (has_more) {
            const cursor = try std.json.Stringify.valueAlloc(self.allocator, next_after.?, .{});
            defer self.allocator.free(cursor);
            try output.appendSlice(self.allocator, cursor);
        } else {
            try output.appendSlice(self.allocator, "null");
        }
        try output.appendSlice(self.allocator, "}\n");
        return try output.toOwnedSlice(self.allocator);
    }

    pub fn inspectNode(
        self: *Registry,
        node_id: []const u8,
        now_unix_ms: i64,
        stale_after_ms: i64,
    ) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
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

    pub fn applyDeployment(
        self: *Registry,
        deployment: orchestration.Deployment,
        spec_json: []const u8,
        now_unix_ms: i64,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var previous_revision: ?i64 = null;
        var previous_spec: ?[]u8 = null;
        defer if (previous_spec) |value| self.allocator.free(value);

        {
            var current = try self.prepare("SELECT revision, spec_json FROM deployments WHERE name=?;");
            defer current.finalize();
            try current.bindText(1, deployment.name);
            if (try current.row()) {
                const revision = current.columnInt64(0);
                if (deployment.revision <= @as(u64, @intCast(revision)))
                    return error.RevisionMustIncrease;
                previous_revision = revision;
                previous_spec = try self.allocator.dupe(u8, current.columnText(1));
            }
        }

        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};

        if (previous_spec) |old_spec| {
            var update = try self.prepare(
                \\UPDATE deployments SET
                \\  revision=?, spec_json=?, previous_revision=?, previous_spec_json=?,
                \\  batch_size=?, max_unavailable=?, pause_seconds=?, auto_rollback=?,
                \\  current_wave=0, wave_started_unix_ms=?, status='deploying', updated_unix_ms=?
                \\WHERE name=?;
            );
            defer update.finalize();
            try update.bindInt64(1, @intCast(deployment.revision));
            try update.bindText(2, spec_json);
            try update.bindInt64(3, previous_revision.?);
            try update.bindText(4, old_spec);
            try update.bindInt64(5, deployment.rollout.batch_size);
            try update.bindInt64(6, deployment.rollout.max_unavailable);
            try update.bindInt64(7, deployment.rollout.pause_seconds);
            try update.bindInt64(8, @intFromBool(deployment.rollout.auto_rollback));
            try update.bindInt64(9, now_unix_ms);
            try update.bindInt64(10, now_unix_ms);
            try update.bindText(11, deployment.name);
            try update.done();
        } else {
            var insert = try self.prepare(
                \\INSERT INTO deployments (
                \\  name, revision, spec_json, previous_revision, previous_spec_json,
                \\  batch_size, max_unavailable, pause_seconds, auto_rollback,
                \\  current_wave, wave_started_unix_ms, status, created_unix_ms, updated_unix_ms
                \\) VALUES (?, ?, ?, NULL, NULL, ?, ?, ?, ?, 0, ?, 'deploying', ?, ?);
            );
            defer insert.finalize();
            try insert.bindText(1, deployment.name);
            try insert.bindInt64(2, @intCast(deployment.revision));
            try insert.bindText(3, spec_json);
            try insert.bindInt64(4, deployment.rollout.batch_size);
            try insert.bindInt64(5, deployment.rollout.max_unavailable);
            try insert.bindInt64(6, deployment.rollout.pause_seconds);
            try insert.bindInt64(7, @intFromBool(deployment.rollout.auto_rollback));
            try insert.bindInt64(8, now_unix_ms);
            try insert.bindInt64(9, now_unix_ms);
            try insert.bindInt64(10, now_unix_ms);
            try insert.done();
        }

        var clear_targets = try self.prepare("DELETE FROM deployment_targets WHERE deployment_name=?;");
        defer clear_targets.finalize();
        try clear_targets.bindText(1, deployment.name);
        try clear_targets.done();

        if (deployment.placement != null) {
            var preserve_active = try self.prepare(
                \\INSERT INTO placement_decisions (
                \\  deployment_name, node_id, revision, status, reason_code,
                \\  reason_detail, updated_unix_ms
                \\)
                \\SELECT deployment_name, node_id, ?, 'ready', 'placement_sticky',
                \\       '{"selected":true,"sticky":true}', ?
                \\FROM workload_assignments
                \\WHERE deployment_name=? AND state NOT IN ('pending', 'blocked', 'stopped')
                \\ON CONFLICT(deployment_name, node_id) DO UPDATE SET
                \\  revision=excluded.revision, status='ready',
                \\  reason_code='placement_sticky', reason_detail=excluded.reason_detail,
                \\  updated_unix_ms=excluded.updated_unix_ms;
            );
            defer preserve_active.finalize();
            try preserve_active.bindInt64(1, @intCast(deployment.revision));
            try preserve_active.bindInt64(2, now_unix_ms);
            try preserve_active.bindText(3, deployment.name);
            try preserve_active.done();
        }

        var clear_assignments = try self.prepare("DELETE FROM workload_assignments WHERE deployment_name=?;");
        defer clear_assignments.finalize();
        try clear_assignments.bindText(1, deployment.name);
        try clear_assignments.done();

        var clear_label_targets = try self.prepare(
            "DELETE FROM deployment_label_targets WHERE deployment_name=?;",
        );
        defer clear_label_targets.finalize();
        try clear_label_targets.bindText(1, deployment.name);
        try clear_label_targets.done();

        if (deployment.targets.all) try self.insertTarget(deployment.name, "all", "*");
        for (deployment.targets.node_ids) |node_id|
            try self.insertTarget(deployment.name, "node", node_id);
        for (deployment.targets.roles) |role|
            try self.insertTarget(deployment.name, "role", role);
        for (deployment.targets.labels) |label|
            try self.insertLabelTarget(deployment.name, label.key, label.value);

        // Freeze a deterministic wave plan for every node already known to the
        // control plane. Nodes that join later are assigned lazily.
        try self.populateAssignments(
            deployment.name,
            deployment.rollout.batch_size,
            now_unix_ms,
        );
        var release_untargeted = try self.prepare(
            \\DELETE FROM accelerator_reservations
            \\WHERE deployment_name=? AND NOT EXISTS (
            \\  SELECT 1 FROM workload_assignments a
            \\  WHERE a.deployment_name=accelerator_reservations.deployment_name
            \\    AND a.node_id=accelerator_reservations.node_id
            \\);
        );
        defer release_untargeted.finalize();
        try release_untargeted.bindText(1, deployment.name);
        try release_untargeted.done();
        var clear_untargeted_decisions = try self.prepare(
            \\DELETE FROM placement_decisions
            \\WHERE deployment_name=? AND NOT EXISTS (
            \\  SELECT 1 FROM workload_assignments a
            \\  WHERE a.deployment_name=placement_decisions.deployment_name
            \\    AND a.node_id=placement_decisions.node_id
            \\);
        );
        defer clear_untargeted_decisions.finalize();
        try clear_untargeted_decisions.bindText(1, deployment.name);
        try clear_untargeted_decisions.done();

        if (deployment.placement != null)
            try self.schedulePlacement(deployment, now_unix_ms);

        try self.audit(now_unix_ms, "", "deployment.applied", deployment.name);
        try self.exec("COMMIT;");
    }

    pub fn listDeployments(self: *Registry) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var statement = try self.prepare(
            \\SELECT name, revision, status, current_wave, batch_size, updated_unix_ms
            \\FROM deployments ORDER BY name;
        );
        defer statement.finalize();

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        try output.append(self.allocator, '[');
        var first = true;
        while (try statement.row()) {
            const summary: DeploymentSummary = .{
                .name = statement.columnText(0),
                .revision = @intCast(statement.columnInt64(1)),
                .status = statement.columnText(2),
                .current_wave = @intCast(statement.columnInt64(3)),
                .batch_size = @intCast(statement.columnInt64(4)),
                .updated_unix_ms = statement.columnInt64(5),
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

    pub fn inspectDeployment(self: *Registry, name: []const u8) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var deployment = try self.prepare(
            \\SELECT revision, status, current_wave, batch_size, max_unavailable,
            \\       pause_seconds, auto_rollback, spec_json, updated_unix_ms
            \\FROM deployments WHERE name=?;
        );
        defer deployment.finalize();
        try deployment.bindText(1, name);
        if (!try deployment.row()) return null;

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        const prefix = try std.fmt.allocPrint(
            self.allocator,
            "{{\"name\":\"{s}\",\"revision\":{d},\"status\":\"{s}\",\"current_wave\":{d}," ++
                "\"batch_size\":{d},\"max_unavailable\":{d},\"pause_seconds\":{d}," ++
                "\"auto_rollback\":{s},\"updated_unix_ms\":{d},\"spec\":{s},\"assignments\":[",
            .{
                name,
                deployment.columnInt64(0),
                deployment.columnText(1),
                deployment.columnInt64(2),
                deployment.columnInt64(3),
                deployment.columnInt64(4),
                deployment.columnInt64(5),
                if (deployment.columnInt64(6) == 1) "true" else "false",
                deployment.columnInt64(8),
                deployment.columnText(7),
            },
        );
        defer self.allocator.free(prefix);
        try output.appendSlice(self.allocator, prefix);

        var assignments = try self.prepare(
            \\SELECT node_id, wave, state, observed_revision, message, updated_unix_ms
            \\FROM workload_assignments WHERE deployment_name=? ORDER BY wave, node_id;
        );
        defer assignments.finalize();
        try assignments.bindText(1, name);
        var first = true;
        while (try assignments.row()) {
            const summary: AssignmentSummary = .{
                .node_id = assignments.columnText(0),
                .wave = @intCast(assignments.columnInt64(1)),
                .state = assignments.columnText(2),
                .observed_revision = @intCast(assignments.columnInt64(3)),
                .message = assignments.columnText(4),
                .updated_unix_ms = assignments.columnInt64(5),
            };
            const item = try std.json.Stringify.valueAlloc(self.allocator, summary, .{});
            defer self.allocator.free(item);
            if (!first) try output.append(self.allocator, ',');
            first = false;
            try output.appendSlice(self.allocator, item);
        }
        try output.appendSlice(self.allocator, "],\"placements\":[");
        var placements = try self.prepare(
            \\SELECT node_id, revision, status, reason_code, reason_detail, updated_unix_ms
            \\FROM placement_decisions WHERE deployment_name=? ORDER BY node_id;
        );
        defer placements.finalize();
        try placements.bindText(1, name);
        first = true;
        while (try placements.row()) {
            const summary: PlacementSummary = .{
                .node_id = placements.columnText(0),
                .revision = @intCast(placements.columnInt64(1)),
                .status = placements.columnText(2),
                .reason_code = placements.columnText(3),
                .reason_detail = placements.columnText(4),
                .updated_unix_ms = placements.columnInt64(5),
            };
            const item = try std.json.Stringify.valueAlloc(self.allocator, summary, .{});
            defer self.allocator.free(item);
            if (!first) try output.append(self.allocator, ',');
            first = false;
            try output.appendSlice(self.allocator, item);
        }

        try output.appendSlice(self.allocator, "],\"accelerator_reservations\":[");
        var reservations = try self.prepare(
            \\SELECT node_id, accelerator_id, revision FROM accelerator_reservations
            \\WHERE deployment_name=? ORDER BY node_id, accelerator_id;
        );
        defer reservations.finalize();
        try reservations.bindText(1, name);
        first = true;
        while (try reservations.row()) {
            const summary: ReservationSummary = .{
                .node_id = reservations.columnText(0),
                .accelerator_id = reservations.columnText(1),
                .revision = @intCast(reservations.columnInt64(2)),
            };
            const item = try std.json.Stringify.valueAlloc(self.allocator, summary, .{});
            defer self.allocator.free(item);
            if (!first) try output.append(self.allocator, ',');
            first = false;
            try output.appendSlice(self.allocator, item);
        }
        try output.appendSlice(self.allocator, "]}\n");
        return try output.toOwnedSlice(self.allocator);
    }

    pub fn deleteDeployment(self: *Registry, name: []const u8, now_unix_ms: i64) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};
        try self.markDeploymentLifecycleRelease(name, now_unix_ms);
        var statement = try self.prepare("DELETE FROM deployments WHERE name=?;");
        defer statement.finalize();
        try statement.bindText(1, name);
        try statement.done();
        const deleted = c.sqlite3_changes(self.db) > 0;
        if (deleted) try self.audit(now_unix_ms, "", "deployment.deleted", name);
        try self.exec("COMMIT;");
        return deleted;
    }

    fn markDeploymentLifecycleRelease(
        self: *Registry,
        deployment_name: []const u8,
        now_unix_ms: i64,
    ) !void {
        var exhausted = try self.prepare(
            \\SELECT 1 FROM accelerator_allocation_commands
            \\WHERE deployment_name=? AND action='run' AND phase<>'released'
            \\  AND generation>=? LIMIT 1;
        );
        defer exhausted.finalize();
        try exhausted.bindText(1, deployment_name);
        try exhausted.bindInt64(2, std.math.maxInt(i64));
        if (try exhausted.row()) return error.AllocationGenerationExhausted;

        var update = try self.prepare(
            \\UPDATE accelerator_allocation_commands
            \\SET generation=generation+1, action='release',
            \\    phase='release_requested', updated_unix_ms=?
            \\WHERE deployment_name=? AND action='run' AND phase<>'released';
        );
        defer update.finalize();
        try update.bindInt64(1, now_unix_ms);
        try update.bindText(2, deployment_name);
        try update.done();

        var claims = try self.prepare(
            \\UPDATE accelerator_allocation_claims
            \\SET role='retiring', updated_unix_ms=?
            \\WHERE deployment_name=? AND allocation_id IN (
            \\  SELECT allocation_id FROM accelerator_allocation_commands
            \\  WHERE deployment_name=? AND action='release' AND phase<>'released'
            \\);
        );
        defer claims.finalize();
        try claims.bindInt64(1, now_unix_ms);
        try claims.bindText(2, deployment_name);
        try claims.bindText(3, deployment_name);
        try claims.done();
    }

    pub fn rollbackDeployment(self: *Registry, name: []const u8, now_unix_ms: i64) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};
        const rolled_back = try self.rollbackDeploymentInTransaction(name, now_unix_ms);
        if (rolled_back) try self.audit(now_unix_ms, "", "deployment.rolled_back", name);
        try self.exec("COMMIT;");
        return rolled_back;
    }

    pub fn desiredStateForNode(self: *Registry, node_id: []const u8, now_unix_ms: i64) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var role_value: ?[]u8 = null;
        defer if (role_value) |value| self.allocator.free(value);
        var report_json: ?[]u8 = null;
        defer if (report_json) |value| self.allocator.free(value);
        {
            var node = try self.prepare("SELECT role, report_json FROM nodes WHERE node_id=?;");
            defer node.finalize();
            try node.bindText(1, node_id);
            if (!try node.row()) return null;
            role_value = try self.allocator.dupe(u8, node.columnText(0));
            report_json = try self.allocator.dupe(u8, node.columnText(1));
        }
        var node_report = try std.json.parseFromSlice(
            heartbeat.Heartbeat,
            self.allocator,
            report_json.?,
            .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
        );
        defer node_report.deinit();
        const supports_accelerator_requirements = hasFeature(
            node_report.value.features,
            heartbeat.feature_accelerator_requirements_v1,
        );
        const supports_accelerator_lifecycle = hasFeature(
            node_report.value.features,
            heartbeat.feature_accelerator_lifecycle_v1,
        );
        const supports_artifact_variants = hasFeature(
            node_report.value.features,
            heartbeat.feature_artifact_variants_v1,
        );
        const supports_edge_placement = hasFeature(
            node_report.value.features,
            heartbeat.feature_edge_placement_v1,
        );

        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};

        var deployments = try self.prepare(
            \\SELECT DISTINCT d.name, d.revision, d.spec_json, d.previous_spec_json,
            \\       d.batch_size, d.current_wave, d.status
            \\FROM deployments d
            \\LEFT JOIN deployment_targets t ON t.deployment_name=d.name
            \\WHERE (t.target_kind='all')
            \\   OR (t.target_kind='node' AND t.target_value=?)
            \\   OR (t.target_kind='role' AND t.target_value=?)
            \\   OR EXISTS (
            \\     SELECT 1 FROM workload_assignments assigned
            \\     WHERE assigned.deployment_name=d.name AND assigned.node_id=?
            \\   )
            \\   OR (
            \\     EXISTS (SELECT 1 FROM deployment_label_targets lt
            \\             WHERE lt.deployment_name=d.name)
            \\     AND NOT EXISTS (
            \\       SELECT 1 FROM deployment_label_targets lt
            \\       WHERE lt.deployment_name=d.name
            \\         AND NOT EXISTS (
            \\           SELECT 1 FROM node_labels nl
            \\           WHERE nl.node_id=? AND nl.label_key=lt.label_key
            \\             AND nl.label_value=lt.label_value
            \\         )
            \\     )
            \\   )
            \\ORDER BY d.name;
        );
        defer deployments.finalize();
        try deployments.bindText(1, node_id);
        try deployments.bindText(2, role_value.?);
        try deployments.bindText(3, node_id);
        try deployments.bindText(4, node_id);

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        const prefix = try std.fmt.allocPrint(
            self.allocator,
            "{{\"schema_version\":1,\"node_id\":\"{s}\",\"generation\":{d},\"deployments\":[",
            .{ node_id, now_unix_ms },
        );
        defer self.allocator.free(prefix);
        try output.appendSlice(self.allocator, prefix);

        var assignment_output: std.ArrayList(u8) = .empty;
        defer assignment_output.deinit(self.allocator);
        try assignment_output.append(self.allocator, '[');

        var first = true;
        var first_assignment = true;
        while (try deployments.row()) {
            const name = try self.allocator.dupe(u8, deployments.columnText(0));
            defer self.allocator.free(name);
            const current_spec = try self.allocator.dupe(u8, deployments.columnText(2));
            defer self.allocator.free(current_spec);
            const previous_spec = if (deployments.columnIsNull(3))
                null
            else
                try self.allocator.dupe(u8, deployments.columnText(3));
            defer if (previous_spec) |value| self.allocator.free(value);
            const batch_size: i64 = deployments.columnInt64(4);
            const current_wave: i64 = deployments.columnInt64(5);
            const rollout_status = try self.allocator.dupe(u8, deployments.columnText(6));
            defer self.allocator.free(rollout_status);

            var current_has_placement = false;
            {
                var current = try std.json.parseFromSlice(
                    orchestration.Deployment,
                    self.allocator,
                    current_spec,
                    .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
                );
                defer current.deinit();
                current_has_placement = current.value.placement != null;
            }
            var wave = try self.getOrCreateAssignmentWave(
                name,
                node_id,
                batch_size,
                current_wave,
                rollout_status,
                now_unix_ms,
            );
            if (current_has_placement) {
                if (!supports_edge_placement or !try self.placementSelected(name, node_id)) {
                    if (supports_accelerator_lifecycle)
                        try self.ensureLifecycleRelease(name, node_id, now_unix_ms);
                    try self.releaseAcceleratorReservation(name, node_id);
                    try self.markPlacementAssignmentUnselected(name, node_id, now_unix_ms);
                    continue;
                }
                try self.rebuildPlacementWaves(name, @intCast(batch_size));
                wave = try self.assignmentWave(name, node_id);
            }
            const selected_spec = if (wave <= current_wave) current_spec else previous_spec orelse continue;
            var emitted_spec = selected_spec;
            var parsed_spec = try std.json.parseFromSlice(
                orchestration.Deployment,
                self.allocator,
                selected_spec,
                .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
            );
            defer parsed_spec.deinit();
            var parsed_fallback: ?std.json.Parsed(orchestration.Deployment) = null;
            defer if (parsed_fallback) |*parsed| parsed.deinit();
            var effective_spec = parsed_spec.value;
            var owned_agent_spec: ?[]u8 = null;
            defer if (owned_agent_spec) |value| self.allocator.free(value);

            if (parsed_spec.value.artifact_variants != null and
                !supports_artifact_variants)
            {
                try self.recordPlacementDecision(
                    parsed_spec.value,
                    node_id,
                    false,
                    "artifact_variant_feature_unsupported",
                    now_unix_ms,
                );
                const fallback = previous_spec orelse continue;
                parsed_fallback = try std.json.parseFromSlice(
                    orchestration.Deployment,
                    self.allocator,
                    fallback,
                    .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
                );
                if (parsed_fallback.?.value.artifact_variants != null) continue;
                emitted_spec = fallback;
                effective_spec = parsed_fallback.?.value;
            }

            if (effective_spec.placement != null) {
                if (!supports_edge_placement or
                    !try self.placementSelected(effective_spec.name, node_id))
                {
                    if (supports_accelerator_lifecycle)
                        try self.ensureLifecycleRelease(
                            effective_spec.name,
                            node_id,
                            now_unix_ms,
                        );
                    try self.releaseAcceleratorReservation(effective_spec.name, node_id);
                    try self.markPlacementAssignmentUnselected(
                        effective_spec.name,
                        node_id,
                        now_unix_ms,
                    );
                    continue;
                }
                var agent_spec = effective_spec;
                agent_spec.placement = null;
                owned_agent_spec = try std.json.Stringify.valueAlloc(
                    self.allocator,
                    agent_spec,
                    .{ .emit_null_optional_fields = false },
                );
                emitted_spec = owned_agent_spec.?;
            }

            if (effective_spec.resources) |resources| {
                if (effective_spec.desired == .stopped) {
                    if (supports_accelerator_lifecycle)
                        try self.ensureLifecycleRelease(
                            effective_spec.name,
                            node_id,
                            now_unix_ms,
                        );
                    try self.releasePlacement(effective_spec.name, node_id);
                } else {
                    if (!supports_accelerator_requirements) {
                        try self.recordPlacementDecision(
                            effective_spec,
                            node_id,
                            false,
                            "agent_feature_unsupported",
                            now_unix_ms,
                        );
                        const fallback = previous_spec orelse continue;
                        if (!try isCpuDeploymentSpec(self.allocator, fallback)) continue;
                        emitted_spec = fallback;
                    } else if (supports_accelerator_lifecycle) {
                        var placement = try self.syncLifecycleAllocation(
                            node_report.value,
                            effective_spec,
                            resources.accelerators,
                            now_unix_ms,
                        );
                        defer placement.deinit();
                        try self.recordPlacementDecision(
                            effective_spec,
                            node_id,
                            placement.ready,
                            placement.reason_code,
                            now_unix_ms,
                        );
                    } else {
                        var placement = try self.placeAccelerators(
                            node_report.value,
                            effective_spec,
                            resources.accelerators,
                            now_unix_ms,
                        );
                        defer placement.deinit();
                        try self.recordPlacementDecision(
                            effective_spec,
                            node_id,
                            placement.ready,
                            placement.reason_code,
                            now_unix_ms,
                        );
                        if (placement.ready) {
                            const assignment: orchestration.AcceleratorAssignment = .{
                                .deployment = effective_spec.name,
                                .revision = effective_spec.revision,
                                .device_ids = placement.ids.items,
                            };
                            const assignment_json = try std.json.Stringify.valueAlloc(
                                self.allocator,
                                assignment,
                                .{},
                            );
                            defer self.allocator.free(assignment_json);
                            if (!first_assignment) try assignment_output.append(self.allocator, ',');
                            first_assignment = false;
                            try assignment_output.appendSlice(self.allocator, assignment_json);
                        }
                    }
                }
            } else {
                if (supports_accelerator_lifecycle)
                    try self.ensureLifecycleRelease(
                        effective_spec.name,
                        node_id,
                        now_unix_ms,
                    );
                if (effective_spec.placement != null)
                    try self.releaseAcceleratorReservation(effective_spec.name, node_id)
                else
                    try self.releasePlacement(effective_spec.name, node_id);
            }
            if (!first) try output.append(self.allocator, ',');
            first = false;
            try output.appendSlice(self.allocator, emitted_spec);
        }
        try output.append(self.allocator, ']');
        if (supports_accelerator_requirements) {
            try assignment_output.append(self.allocator, ']');
            try output.appendSlice(self.allocator, ",\"accelerator_assignments\":");
            try output.appendSlice(self.allocator, assignment_output.items);
        }
        if (supports_accelerator_lifecycle) {
            try self.releaseOrphanedLifecycleAllocations(node_id, now_unix_ms);
            try output.appendSlice(self.allocator, ",\"accelerator_allocations\":");
            try self.appendLifecycleAllocations(&output, node_id);
        }
        try output.appendSlice(self.allocator, "}\n");
        try self.exec("COMMIT;");
        return try output.toOwnedSlice(self.allocator);
    }

    fn syncLifecycleAllocation(
        self: *Registry,
        report: heartbeat.Heartbeat,
        deployment: orchestration.Deployment,
        requirement: accelerator.Requirement,
        now_unix_ms: i64,
    ) !PlacementResult {
        var existing = try self.loadLifecycleCommand(report.node_id, deployment.name);
        defer if (existing) |*command| command.deinit();
        const inventory = report.accelerator_inventory orelse
            return self.blockedPlacement(if (existing == null)
                "inventory_missing"
            else
                "assigned_device_unconfirmed");

        if (existing) |*command| {
            if (command.phase == .ambiguous)
                return self.blockedPlacement("allocation_recovery_required");
            if (command.phase == .failed) {
                if (command.action != .run or command.revision == deployment.revision)
                    return self.blockedPlacement("allocation_recovery_required");
                if (inventory.status != .complete)
                    return self.blockedPlacement("assigned_device_unconfirmed");
                if (reservationMatches(inventory, requirement, command.ids.items)) {
                    try self.writeLifecycleRun(
                        report.node_id,
                        deployment.name,
                        command.allocation_id,
                        try nextAllocationGeneration(command.generation),
                        deployment.revision,
                        command.ids.items,
                        now_unix_ms,
                    );
                    return .{
                        .ids = try cloneIds(self.allocator, command.ids.items),
                        .ready = true,
                        .reason_code = "",
                    };
                }
                try self.markLifecycleRelease(command.*, now_unix_ms);
                return self.blockedPlacement("accelerator_release_in_progress");
            }
            if (command.action == .release and command.phase != .released)
                return self.blockedPlacement("accelerator_release_in_progress");
            if (command.action == .run and command.phase != .released) {
                if (command.revision == deployment.revision) {
                    if (inventory.status == .complete and
                        !reservationMatches(inventory, requirement, command.ids.items))
                    {
                        const reason = if (reservationIdsPresent(inventory, command.ids.items))
                            "assigned_device_incompatible"
                        else
                            "assigned_device_missing";
                        return self.blockedPlacement(reason);
                    }
                    return .{
                        .ids = try cloneIds(self.allocator, command.ids.items),
                        .ready = true,
                        .reason_code = "",
                    };
                }

                if (command.phase != .active)
                    return self.blockedPlacement("allocation_operation_in_progress");

                if (inventory.status != .complete)
                    return self.blockedPlacement("assigned_device_unconfirmed");
                if (reservationMatches(inventory, requirement, command.ids.items)) {
                    try self.writeLifecycleRun(
                        report.node_id,
                        deployment.name,
                        command.allocation_id,
                        try nextAllocationGeneration(command.generation),
                        deployment.revision,
                        command.ids.items,
                        now_unix_ms,
                    );
                    return .{
                        .ids = try cloneIds(self.allocator, command.ids.items),
                        .ready = true,
                        .reason_code = "",
                    };
                }
                try self.markLifecycleRelease(command.*, now_unix_ms);
                return self.blockedPlacement("accelerator_release_in_progress");
            }
        }

        if (inventory.status != .complete)
            return self.blockedPlacement("inventory_unconfirmed");
        if (inventory.accelerators.len == 0)
            return self.blockedPlacement("no_accelerator");

        // An A2 reservation is logical-only and never launched. Adopt a still
        // compatible one when the agent upgrades to the fenced lifecycle.
        var legacy = try self.loadExistingReservation(report.node_id, deployment.name);
        defer legacy.ids.deinit();
        if (legacy.ids.items.len > 0 and
            reservationMatches(inventory, requirement, legacy.ids.items))
        {
            const allocation_id = if (existing) |command|
                try self.allocator.dupe(u8, command.allocation_id)
            else
                try lifecycleAllocationIdAlloc(self.allocator, report.node_id, deployment.name);
            defer self.allocator.free(allocation_id);
            try self.writeLifecycleRun(
                report.node_id,
                deployment.name,
                allocation_id,
                if (existing) |command|
                    try nextAllocationGeneration(command.generation)
                else
                    1,
                deployment.revision,
                legacy.ids.items,
                now_unix_ms,
            );
            try self.deleteLegacyReservation(report.node_id, deployment.name);
            return .{
                .ids = try cloneIds(self.allocator, legacy.ids.items),
                .ready = true,
                .reason_code = "",
            };
        }
        if (legacy.ids.items.len > 0)
            try self.deleteLegacyReservation(report.node_id, deployment.name);

        var reserved = try self.loadLifecycleReservedIds(report.node_id, deployment.name);
        defer reserved.deinit();
        const selected = selectAcceleratorsAlloc(
            self.allocator,
            inventory,
            requirement,
            reserved.items,
            deployment.placement,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.blockedPlacement(selectionReason(err)),
        };
        defer self.allocator.free(selected);
        const allocation_id = if (existing) |command|
            try self.allocator.dupe(u8, command.allocation_id)
        else
            try lifecycleAllocationIdAlloc(self.allocator, report.node_id, deployment.name);
        defer self.allocator.free(allocation_id);
        try self.writeLifecycleRun(
            report.node_id,
            deployment.name,
            allocation_id,
            if (existing) |command|
                try nextAllocationGeneration(command.generation)
            else
                1,
            deployment.revision,
            selected,
            now_unix_ms,
        );
        return .{
            .ids = try cloneIds(self.allocator, selected),
            .ready = true,
            .reason_code = "",
        };
    }

    fn writeLifecycleRun(
        self: *Registry,
        node_id: []const u8,
        deployment_name: []const u8,
        allocation_id: []const u8,
        generation: u64,
        revision: u64,
        device_ids: []const []const u8,
        now_unix_ms: i64,
    ) !void {
        const desired: allocation.DesiredAllocation = .{
            .allocation_id = allocation_id,
            .generation = generation,
            .deployment = deployment_name,
            .revision = revision,
            .action = .run,
            .target_device_ids = device_ids,
        };
        try allocation.validateDesired(desired);
        var command = try self.prepare(
            \\INSERT INTO accelerator_allocation_commands (
            \\  node_id, deployment_name, allocation_id, generation, revision,
            \\  action, phase, created_unix_ms, updated_unix_ms
            \\) VALUES (?, ?, ?, ?, ?, 'run', 'pending', ?, ?)
            \\ON CONFLICT(node_id, deployment_name) DO UPDATE SET
            \\  allocation_id=excluded.allocation_id,
            \\  generation=excluded.generation,
            \\  revision=excluded.revision,
            \\  action='run', phase='pending', updated_unix_ms=excluded.updated_unix_ms;
        );
        defer command.finalize();
        try command.bindText(1, node_id);
        try command.bindText(2, deployment_name);
        try command.bindText(3, allocation_id);
        try command.bindInt64(4, @intCast(generation));
        try command.bindInt64(5, @intCast(revision));
        try command.bindInt64(6, now_unix_ms);
        try command.bindInt64(7, now_unix_ms);
        try command.done();

        var clear = try self.prepare(
            "DELETE FROM accelerator_allocation_claims WHERE allocation_id=?;",
        );
        defer clear.finalize();
        try clear.bindText(1, allocation_id);
        try clear.done();
        for (device_ids) |device_id| {
            var claim = try self.prepare(
                \\INSERT INTO accelerator_allocation_claims (
                \\  node_id, accelerator_id, allocation_id, deployment_name,
                \\  generation, revision, role, updated_unix_ms
                \\) VALUES (?, ?, ?, ?, ?, ?, 'candidate', ?);
            );
            defer claim.finalize();
            try claim.bindText(1, node_id);
            try claim.bindText(2, device_id);
            try claim.bindText(3, allocation_id);
            try claim.bindText(4, deployment_name);
            try claim.bindInt64(5, @intCast(generation));
            try claim.bindInt64(6, @intCast(revision));
            try claim.bindInt64(7, now_unix_ms);
            try claim.done();
        }
    }

    fn ensureLifecycleRelease(
        self: *Registry,
        deployment_name: []const u8,
        node_id: []const u8,
        now_unix_ms: i64,
    ) !void {
        var existing = try self.loadLifecycleCommand(node_id, deployment_name);
        defer if (existing) |*command| command.deinit();
        const command = existing orelse return;
        if (command.phase == .released or command.action == .release) return;
        try self.markLifecycleRelease(command, now_unix_ms);
    }

    fn markLifecycleRelease(
        self: *Registry,
        command: LifecycleCommand,
        now_unix_ms: i64,
    ) !void {
        if (command.ids.items.len == 0) return error.InconsistentAllocationClaims;
        const next_generation = try nextAllocationGeneration(command.generation);
        const desired: allocation.DesiredAllocation = .{
            .allocation_id = command.allocation_id,
            .generation = next_generation,
            .deployment = command.deployment_name,
            .revision = command.revision,
            .action = .release,
            .retiring_device_ids = command.ids.items,
        };
        try allocation.validateDesired(desired);
        var update = try self.prepare(
            \\UPDATE accelerator_allocation_commands
            \\SET generation=?, action='release',
            \\    phase='release_requested', updated_unix_ms=?
            \\WHERE node_id=? AND deployment_name=?;
        );
        defer update.finalize();
        try update.bindInt64(1, @intCast(next_generation));
        try update.bindInt64(2, now_unix_ms);
        try update.bindText(3, command.node_id);
        try update.bindText(4, command.deployment_name);
        try update.done();
        var claims = try self.prepare(
            \\UPDATE accelerator_allocation_claims
            \\SET role='retiring', updated_unix_ms=?
            \\WHERE allocation_id=?;
        );
        defer claims.finalize();
        try claims.bindInt64(1, now_unix_ms);
        try claims.bindText(2, command.allocation_id);
        try claims.done();
    }

    fn releaseOrphanedLifecycleAllocations(
        self: *Registry,
        node_id: []const u8,
        now_unix_ms: i64,
    ) !void {
        var query = try self.prepare(
            \\SELECT deployment_name FROM accelerator_allocation_commands command
            \\WHERE node_id=? AND action='run' AND phase<>'released'
            \\  AND NOT EXISTS (
            \\    SELECT 1 FROM workload_assignments assignment
            \\    WHERE assignment.deployment_name=command.deployment_name
            \\      AND assignment.node_id=command.node_id
            \\  ) ORDER BY deployment_name;
        );
        defer query.finalize();
        try query.bindText(1, node_id);
        var names: std.ArrayList([]const u8) = .empty;
        defer {
            for (names.items) |name| self.allocator.free(name);
            names.deinit(self.allocator);
        }
        while (try query.row())
            try names.append(self.allocator, try self.allocator.dupe(u8, query.columnText(0)));
        for (names.items) |name|
            try self.ensureLifecycleRelease(name, node_id, now_unix_ms);
    }

    fn appendLifecycleAllocations(
        self: *Registry,
        output: *std.ArrayList(u8),
        node_id: []const u8,
    ) !void {
        try output.append(self.allocator, '[');
        var commands = try self.prepare(
            \\SELECT deployment_name, allocation_id, generation, revision, action
            \\FROM accelerator_allocation_commands
            \\WHERE node_id=? AND phase<>'released' ORDER BY deployment_name;
        );
        defer commands.finalize();
        try commands.bindText(1, node_id);
        var first = true;
        while (try commands.row()) {
            const deployment_name = try self.allocator.dupe(u8, commands.columnText(0));
            defer self.allocator.free(deployment_name);
            const allocation_id = try self.allocator.dupe(u8, commands.columnText(1));
            defer self.allocator.free(allocation_id);
            const action = std.meta.stringToEnum(
                allocation.DesiredAction,
                commands.columnText(4),
            ) orelse return error.InvalidAllocationAction;
            var ids = try self.loadLifecycleClaimIds(allocation_id);
            defer ids.deinit();
            const desired: allocation.DesiredAllocation = .{
                .allocation_id = allocation_id,
                .generation = @intCast(commands.columnInt64(2)),
                .deployment = deployment_name,
                .revision = @intCast(commands.columnInt64(3)),
                .action = action,
                .target_device_ids = if (action == .run) ids.items else &.{},
                .retiring_device_ids = if (action == .release) ids.items else &.{},
            };
            try allocation.validateDesired(desired);
            const encoded = try std.json.Stringify.valueAlloc(self.allocator, desired, .{});
            defer self.allocator.free(encoded);
            if (!first) try output.append(self.allocator, ',');
            first = false;
            try output.appendSlice(self.allocator, encoded);
        }
        try output.append(self.allocator, ']');
    }

    fn loadLifecycleCommand(
        self: *Registry,
        node_id: []const u8,
        deployment_name: []const u8,
    ) !?LifecycleCommand {
        var query = try self.prepare(
            \\SELECT allocation_id, generation, revision, action, phase
            \\FROM accelerator_allocation_commands
            \\WHERE node_id=? AND deployment_name=?;
        );
        defer query.finalize();
        try query.bindText(1, node_id);
        try query.bindText(2, deployment_name);
        if (!try query.row()) return null;
        const action = std.meta.stringToEnum(
            allocation.DesiredAction,
            query.columnText(3),
        ) orelse return error.InvalidAllocationAction;
        const phase = std.meta.stringToEnum(
            allocation.ObservedPhase,
            query.columnText(4),
        ) orelse return error.InvalidAllocationPhase;
        const allocation_id = try self.allocator.dupe(u8, query.columnText(0));
        errdefer self.allocator.free(allocation_id);
        const owned_node_id = try self.allocator.dupe(u8, node_id);
        errdefer self.allocator.free(owned_node_id);
        const owned_deployment = try self.allocator.dupe(u8, deployment_name);
        errdefer self.allocator.free(owned_deployment);
        var ids = try self.loadLifecycleClaimIds(allocation_id);
        errdefer ids.deinit();
        return .{
            .allocator = self.allocator,
            .node_id = owned_node_id,
            .deployment_name = owned_deployment,
            .allocation_id = allocation_id,
            .generation = @intCast(query.columnInt64(1)),
            .revision = @intCast(query.columnInt64(2)),
            .action = action,
            .phase = phase,
            .ids = ids,
        };
    }

    fn loadLifecycleClaimIds(
        self: *Registry,
        allocation_id: []const u8,
    ) !OwnedIds {
        var query = try self.prepare(
            \\SELECT accelerator_id FROM accelerator_allocation_claims
            \\WHERE allocation_id=? ORDER BY accelerator_id;
        );
        defer query.finalize();
        try query.bindText(1, allocation_id);
        var ids: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (ids.items) |id| self.allocator.free(id);
            ids.deinit(self.allocator);
        }
        while (try query.row())
            try ids.append(self.allocator, try self.allocator.dupe(u8, query.columnText(0)));
        return .{ .allocator = self.allocator, .items = try ids.toOwnedSlice(self.allocator) };
    }

    fn loadLifecycleReservedIds(
        self: *Registry,
        node_id: []const u8,
        deployment_name: []const u8,
    ) !OwnedIds {
        var query = try self.prepare(
            \\SELECT accelerator_id FROM accelerator_allocation_claims
            \\WHERE node_id=? AND deployment_name<>?
            \\UNION
            \\SELECT accelerator_id FROM accelerator_reservations
            \\WHERE node_id=? AND deployment_name<>?
            \\ORDER BY accelerator_id;
        );
        defer query.finalize();
        try query.bindText(1, node_id);
        try query.bindText(2, deployment_name);
        try query.bindText(3, node_id);
        try query.bindText(4, deployment_name);
        var ids: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (ids.items) |id| self.allocator.free(id);
            ids.deinit(self.allocator);
        }
        while (try query.row())
            try ids.append(self.allocator, try self.allocator.dupe(u8, query.columnText(0)));
        return .{ .allocator = self.allocator, .items = try ids.toOwnedSlice(self.allocator) };
    }

    fn deleteLegacyReservation(
        self: *Registry,
        node_id: []const u8,
        deployment_name: []const u8,
    ) !void {
        var statement = try self.prepare(
            "DELETE FROM accelerator_reservations WHERE node_id=? AND deployment_name=?;",
        );
        defer statement.finalize();
        try statement.bindText(1, node_id);
        try statement.bindText(2, deployment_name);
        try statement.done();
    }

    fn placeAccelerators(
        self: *Registry,
        report: heartbeat.Heartbeat,
        deployment: orchestration.Deployment,
        requirement: accelerator.Requirement,
        now_unix_ms: i64,
    ) !PlacementResult {
        if (try self.hasActiveLifecycleCommand(report.node_id, deployment.name))
            return self.blockedPlacement("agent_feature_regressed");
        var existing = try self.loadExistingReservation(report.node_id, deployment.name);
        defer existing.ids.deinit();
        const inventory = report.accelerator_inventory orelse
            return self.blockedPlacement(if (existing.ids.items.len == 0)
                "inventory_missing"
            else
                "assigned_device_unconfirmed");

        if (existing.ids.items.len > 0) {
            var other_claims = try self.loadOtherReservationIds(report.node_id, deployment.name);
            defer other_claims.deinit();
            for (existing.ids.items) |existing_id| {
                for (other_claims.items) |claimed_id| {
                    if (std.mem.eql(u8, existing_id, claimed_id))
                        return self.blockedPlacement("accelerator_capacity_exhausted");
                }
            }
            if (inventory.status != .unavailable and
                reservationMatches(inventory, requirement, existing.ids.items))
            {
                var update = try self.prepare(
                    \\UPDATE accelerator_reservations SET revision=?, reserved_unix_ms=?
                    \\WHERE node_id=? AND deployment_name=?;
                );
                defer update.finalize();
                try update.bindInt64(1, @intCast(deployment.revision));
                try update.bindInt64(2, now_unix_ms);
                try update.bindText(3, report.node_id);
                try update.bindText(4, deployment.name);
                try update.done();
                return .{
                    .ids = try cloneIds(self.allocator, existing.ids.items),
                    .ready = true,
                    .reason_code = "",
                };
            }
            if (inventory.status != .complete)
                return self.blockedPlacement("assigned_device_unconfirmed");
            if (existing.revision == deployment.revision) {
                const reason = if (reservationIdsPresent(inventory, existing.ids.items))
                    "assigned_device_incompatible"
                else
                    "assigned_device_missing";
                return self.blockedPlacement(reason);
            }
            var release_old = try self.prepare(
                "DELETE FROM accelerator_reservations WHERE node_id=? AND deployment_name=?;",
            );
            defer release_old.finalize();
            try release_old.bindText(1, report.node_id);
            try release_old.bindText(2, deployment.name);
            try release_old.done();
        }

        if (inventory.status == .complete and inventory.accelerators.len == 0)
            return self.blockedPlacement("no_accelerator");

        var reserved = try self.loadOtherReservationIds(report.node_id, deployment.name);
        defer reserved.deinit();
        const selected = selectAcceleratorsAlloc(
            self.allocator,
            inventory,
            requirement,
            reserved.items,
            deployment.placement,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.blockedPlacement(selectionReason(err)),
        };
        defer self.allocator.free(selected);

        for (selected) |device_id| {
            var insert = try self.prepare(
                \\INSERT INTO accelerator_reservations (
                \\  node_id, accelerator_id, deployment_name, revision, reserved_unix_ms
                \\) VALUES (?, ?, ?, ?, ?);
            );
            defer insert.finalize();
            try insert.bindText(1, report.node_id);
            try insert.bindText(2, device_id);
            try insert.bindText(3, deployment.name);
            try insert.bindInt64(4, @intCast(deployment.revision));
            try insert.bindInt64(5, now_unix_ms);
            try insert.done();
        }
        return .{
            .ids = try cloneIds(self.allocator, selected),
            .ready = true,
            .reason_code = "",
        };
    }

    fn blockedPlacement(self: *Registry, reason_code: []const u8) !PlacementResult {
        return .{
            .ids = .{
                .allocator = self.allocator,
                .items = try self.allocator.alloc([]const u8, 0),
            },
            .ready = false,
            .reason_code = reason_code,
        };
    }

    fn loadExistingReservation(
        self: *Registry,
        node_id: []const u8,
        deployment_name: []const u8,
    ) !ExistingReservation {
        var statement = try self.prepare(
            \\SELECT accelerator_id, revision FROM accelerator_reservations
            \\WHERE node_id=? AND deployment_name=? ORDER BY accelerator_id;
        );
        defer statement.finalize();
        try statement.bindText(1, node_id);
        try statement.bindText(2, deployment_name);
        var ids: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (ids.items) |id| self.allocator.free(id);
            ids.deinit(self.allocator);
        }
        var revision: ?u64 = null;
        while (try statement.row()) {
            try ids.append(self.allocator, try self.allocator.dupe(u8, statement.columnText(0)));
            const row_revision: u64 = @intCast(statement.columnInt64(1));
            if (revision) |value| {
                if (value != row_revision) return error.InconsistentReservation;
            } else revision = row_revision;
        }
        return .{
            .ids = .{ .allocator = self.allocator, .items = try ids.toOwnedSlice(self.allocator) },
            .revision = revision,
        };
    }

    fn loadOtherReservationIds(
        self: *Registry,
        node_id: []const u8,
        deployment_name: []const u8,
    ) !OwnedIds {
        var statement = try self.prepare(
            \\SELECT accelerator_id FROM accelerator_reservations
            \\WHERE node_id=? AND deployment_name<>?
            \\UNION
            \\SELECT accelerator_id FROM accelerator_allocation_claims
            \\WHERE node_id=? AND deployment_name<>?
            \\ORDER BY accelerator_id;
        );
        defer statement.finalize();
        try statement.bindText(1, node_id);
        try statement.bindText(2, deployment_name);
        try statement.bindText(3, node_id);
        try statement.bindText(4, deployment_name);
        var ids: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (ids.items) |id| self.allocator.free(id);
            ids.deinit(self.allocator);
        }
        while (try statement.row())
            try ids.append(self.allocator, try self.allocator.dupe(u8, statement.columnText(0)));
        return .{ .allocator = self.allocator, .items = try ids.toOwnedSlice(self.allocator) };
    }

    fn hasActiveLifecycleCommand(
        self: *Registry,
        node_id: []const u8,
        deployment_name: []const u8,
    ) !bool {
        var query = try self.prepare(
            \\SELECT 1 FROM accelerator_allocation_commands
            \\WHERE node_id=? AND deployment_name=? AND phase<>'released' LIMIT 1;
        );
        defer query.finalize();
        try query.bindText(1, node_id);
        try query.bindText(2, deployment_name);
        return try query.row();
    }

    fn reschedulePlacementDeployments(self: *Registry, now_unix_ms: i64) !void {
        var deployments = try self.prepare(
            "SELECT spec_json FROM deployments ORDER BY name;",
        );
        defer deployments.finalize();
        while (try deployments.row()) {
            var parsed = try std.json.parseFromSlice(
                orchestration.Deployment,
                self.allocator,
                deployments.columnText(0),
                .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
            );
            defer parsed.deinit();
            if (parsed.value.placement != null)
                try self.schedulePlacement(parsed.value, now_unix_ms);
        }
    }

    /// Persist one deterministic admission plan. Existing selections are
    /// sticky: an offline node is never duplicated elsewhere without a signed
    /// cross-node lease proving that its workload stopped.
    fn schedulePlacement(
        self: *Registry,
        deployment: orchestration.Deployment,
        now_unix_ms: i64,
    ) !void {
        const policy = deployment.placement orelse return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var candidates: std.ArrayList(edge_placement.Candidate) = .empty;

        var nodes = try self.prepare(
            \\SELECT n.node_id, n.last_seen_unix_ms, n.report_json FROM nodes n
            \\WHERE EXISTS (
            \\        SELECT 1 FROM deployment_targets t
            \\        WHERE t.deployment_name=? AND t.target_kind='all'
            \\      )
            \\   OR EXISTS (
            \\        SELECT 1 FROM deployment_targets t
            \\        WHERE t.deployment_name=? AND t.target_kind='node'
            \\          AND t.target_value=n.node_id
            \\      )
            \\   OR EXISTS (
            \\        SELECT 1 FROM deployment_targets t
            \\        WHERE t.deployment_name=? AND t.target_kind='role'
            \\          AND t.target_value=n.role
            \\      )
            \\   OR (
            \\        EXISTS (SELECT 1 FROM deployment_label_targets lt
            \\                WHERE lt.deployment_name=?)
            \\        AND NOT EXISTS (
            \\          SELECT 1 FROM deployment_label_targets lt
            \\          WHERE lt.deployment_name=?
            \\            AND NOT EXISTS (
            \\              SELECT 1 FROM node_labels nl
            \\              WHERE nl.node_id=n.node_id AND nl.label_key=lt.label_key
            \\                AND nl.label_value=lt.label_value
            \\            )
            \\        )
            \\      )
            \\ORDER BY n.node_id;
        );
        defer nodes.finalize();
        for (1..6) |index| try nodes.bindText(@intCast(index), deployment.name);
        while (try nodes.row()) {
            const node_id = try allocator.dupe(u8, nodes.columnText(0));
            const report_json = try allocator.dupe(u8, nodes.columnText(2));
            const report = std.json.parseFromSliceLeaky(
                heartbeat.Heartbeat,
                allocator,
                report_json,
                .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
            ) catch continue;
            var supports_placement = false;
            for (report.features) |feature| {
                if (std.mem.eql(u8, feature, heartbeat.feature_edge_placement_v1)) {
                    supports_placement = true;
                    break;
                }
            }
            var other_reservations = try self.loadOtherReservationIds(
                node_id,
                deployment.name,
            );
            defer other_reservations.deinit();
            var device_metrics: std.ArrayList(edge_placement.DeviceTelemetry) = .empty;
            if (deployment.resources) |resources| {
                if (report.accelerator_inventory) |inventory| {
                    for (inventory.accelerators) |device| {
                        if (!accelerator.matchesRequirement(device, resources.accelerators)) continue;
                        var reserved = false;
                        for (other_reservations.items) |reserved_id| {
                            if (std.mem.eql(u8, reserved_id, device.id)) {
                                reserved = true;
                                break;
                            }
                        }
                        if (reserved) continue;
                        try device_metrics.append(allocator, .{
                            .id = device.id,
                            .memory_free_bytes = device.memory_free_bytes,
                            .temperature_millicelsius = device.temperature_millicelsius,
                            .power_draw_milliwatts = device.power_draw_milliwatts,
                        });
                    }
                }
            }
            try candidates.append(allocator, .{
                .node_id = node_id,
                .last_seen_unix_ms = nodes.columnInt64(1),
                .supports_placement = supports_placement,
                .accelerator_inventory_complete = if (report.accelerator_inventory) |inventory|
                    inventory.status == .complete
                else
                    false,
                .telemetry = report.placement_telemetry,
                .devices = device_metrics.items,
                .required_device_count = if (deployment.resources) |resources|
                    resources.accelerators.count
                else
                    0,
            });
        }

        var artifact_digests: [33][]const u8 = undefined;
        var digest_count: usize = 0;
        if (deployment.artifact) |artifact| {
            artifact_digests[digest_count] = artifact.sha256;
            digest_count += 1;
        }
        if (deployment.artifact_variants) |variants| for (variants) |variant| {
            artifact_digests[digest_count] = variant.artifact.sha256;
            digest_count += 1;
        };
        const ranked = try edge_placement.rankAlloc(
            allocator,
            candidates.items,
            policy,
            artifact_digests[0..digest_count],
            now_unix_ms,
        );

        var selected_query = try self.prepare(
            "SELECT COUNT(*) FROM placement_decisions WHERE deployment_name=? AND status='ready';",
        );
        defer selected_query.finalize();
        try selected_query.bindText(1, deployment.name);
        _ = try selected_query.row();
        var selected_count: usize = @intCast(selected_query.columnInt64(0));
        for (ranked) |entry| {
            const sticky = try self.wasPlacementSelected(
                deployment.name,
                entry.candidate.node_id,
            );
            const has_capacity = if (policy.replicas) |replicas|
                selected_count < replicas
            else
                true;
            const is_selected = sticky or (entry.evaluation.eligible and has_capacity);
            if (!sticky and is_selected) selected_count += 1;
            const reason = if (sticky)
                "placement_sticky"
            else if (is_selected)
                "placement_selected"
            else if (entry.evaluation.eligible)
                "not_selected_lower_rank"
            else
                entry.evaluation.reason_code;
            const detail = try edge_placement.detailAlloc(allocator, entry, is_selected);
            try self.recordPlacementDecisionDetail(
                deployment,
                entry.candidate.node_id,
                is_selected,
                reason,
                detail,
                now_unix_ms,
                if (is_selected) null else -1,
            );
        }
        try self.rebuildPlacementWaves(deployment.name, deployment.rollout.batch_size);
    }

    fn rebuildPlacementWaves(
        self: *Registry,
        deployment_name: []const u8,
        batch_size: u32,
    ) !void {
        var selected_nodes: std.ArrayList([]const u8) = .empty;
        defer {
            for (selected_nodes.items) |node_id| self.allocator.free(node_id);
            selected_nodes.deinit(self.allocator);
        }
        {
            var selected = try self.prepare(
                \\SELECT node_id FROM placement_decisions
                \\WHERE deployment_name=? AND status='ready' ORDER BY node_id;
            );
            defer selected.finalize();
            try selected.bindText(1, deployment_name);
            while (try selected.row())
                try selected_nodes.append(
                    self.allocator,
                    try self.allocator.dupe(u8, selected.columnText(0)),
                );
        }
        for (selected_nodes.items, 0..) |node_id, index| {
            var update = try self.prepare(
                "UPDATE workload_assignments SET wave=? WHERE deployment_name=? AND node_id=?;",
            );
            defer update.finalize();
            try update.bindInt64(1, @intCast(index / batch_size));
            try update.bindText(2, deployment_name);
            try update.bindText(3, node_id);
            try update.done();
        }
    }

    fn assignmentWave(
        self: *Registry,
        deployment_name: []const u8,
        node_id: []const u8,
    ) !i64 {
        var query = try self.prepare(
            "SELECT wave FROM workload_assignments WHERE deployment_name=? AND node_id=?;",
        );
        defer query.finalize();
        try query.bindText(1, deployment_name);
        try query.bindText(2, node_id);
        if (!try query.row()) return error.InconsistentPlacementAssignment;
        return query.columnInt64(0);
    }

    fn wasPlacementSelected(
        self: *Registry,
        deployment_name: []const u8,
        node_id: []const u8,
    ) !bool {
        var selected = try self.prepare(
            \\SELECT 1 FROM placement_decisions
            \\WHERE deployment_name=? AND node_id=? AND status='ready';
        );
        defer selected.finalize();
        try selected.bindText(1, deployment_name);
        try selected.bindText(2, node_id);
        return try selected.row();
    }

    fn placementSelected(
        self: *Registry,
        deployment_name: []const u8,
        node_id: []const u8,
    ) !bool {
        return self.wasPlacementSelected(deployment_name, node_id);
    }

    fn recordPlacementDecision(
        self: *Registry,
        deployment: orchestration.Deployment,
        node_id: []const u8,
        is_ready: bool,
        reason_code: []const u8,
        now_unix_ms: i64,
    ) !void {
        if (deployment.placement != null and is_ready and reason_code.len == 0) return;
        return self.recordPlacementDecisionDetail(
            deployment,
            node_id,
            is_ready,
            reason_code,
            "",
            now_unix_ms,
            null,
        );
    }

    fn recordPlacementDecisionDetail(
        self: *Registry,
        deployment: orchestration.Deployment,
        node_id: []const u8,
        is_ready: bool,
        reason_code: []const u8,
        reason_detail: []const u8,
        now_unix_ms: i64,
        assignment_wave: ?i64,
    ) !void {
        var upsert = try self.prepare(
            \\INSERT INTO placement_decisions (
            \\  deployment_name, node_id, revision, status, reason_code,
            \\  reason_detail, updated_unix_ms
            \\) VALUES (?, ?, ?, ?, ?, ?, ?)
            \\ON CONFLICT(deployment_name, node_id) DO UPDATE SET
            \\  revision=excluded.revision, status=excluded.status,
            \\  reason_code=excluded.reason_code, reason_detail=excluded.reason_detail,
            \\  updated_unix_ms=excluded.updated_unix_ms;
        );
        defer upsert.finalize();
        try upsert.bindText(1, deployment.name);
        try upsert.bindText(2, node_id);
        try upsert.bindInt64(3, @intCast(deployment.revision));
        try upsert.bindText(4, if (is_ready) "ready" else "unschedulable");
        try upsert.bindText(5, reason_code);
        try upsert.bindText(6, reason_detail);
        try upsert.bindInt64(7, now_unix_ms);
        try upsert.done();

        const assignment_state = if (is_ready) "pending" else "blocked";
        const assignment_message = if (is_ready) "" else reason_code;
        var update_assignment = try self.prepare(
            \\UPDATE workload_assignments SET wave=COALESCE(?, wave), state=?, message=?, updated_unix_ms=?
            \\WHERE deployment_name=? AND node_id=?
            \\  AND state IN ('pending', 'blocked');
        );
        defer update_assignment.finalize();
        if (assignment_wave) |wave|
            try update_assignment.bindInt64(1, wave)
        else
            try update_assignment.bindNull(1);
        try update_assignment.bindText(2, assignment_state);
        try update_assignment.bindText(3, assignment_message);
        try update_assignment.bindInt64(4, now_unix_ms);
        try update_assignment.bindText(5, deployment.name);
        try update_assignment.bindText(6, node_id);
        try update_assignment.done();
    }

    fn releasePlacement(self: *Registry, deployment_name: []const u8, node_id: []const u8) !void {
        try self.releaseAcceleratorReservation(deployment_name, node_id);
        var clear_decision = try self.prepare(
            "DELETE FROM placement_decisions WHERE deployment_name=? AND node_id=?;",
        );
        defer clear_decision.finalize();
        try clear_decision.bindText(1, deployment_name);
        try clear_decision.bindText(2, node_id);
        try clear_decision.done();
    }

    fn releaseAcceleratorReservation(
        self: *Registry,
        deployment_name: []const u8,
        node_id: []const u8,
    ) !void {
        var release = try self.prepare(
            "DELETE FROM accelerator_reservations WHERE deployment_name=? AND node_id=?;",
        );
        defer release.finalize();
        try release.bindText(1, deployment_name);
        try release.bindText(2, node_id);
        try release.done();
    }

    fn markPlacementAssignmentUnselected(
        self: *Registry,
        deployment_name: []const u8,
        node_id: []const u8,
        now_unix_ms: i64,
    ) !void {
        var update = try self.prepare(
            \\UPDATE workload_assignments
            \\SET wave=-1, state='blocked', message='placement_not_selected', updated_unix_ms=?
            \\WHERE deployment_name=? AND node_id=? AND state IN ('pending', 'blocked');
        );
        defer update.finalize();
        try update.bindInt64(1, now_unix_ms);
        try update.bindText(2, deployment_name);
        try update.bindText(3, node_id);
        try update.done();
    }

    pub fn recordWorkloadStatus(
        self: *Registry,
        report: orchestration.StatusReport,
        received_unix_ms: i64,
    ) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};

        var update = try self.prepare(
            \\UPDATE workload_assignments
            \\SET state=?, observed_revision=?, message=?, updated_unix_ms=?
            \\WHERE deployment_name=? AND node_id=?;
        );
        defer update.finalize();
        try update.bindText(1, @tagName(report.state));
        try update.bindInt64(2, @intCast(report.revision));
        try update.bindText(3, report.message);
        try update.bindInt64(4, received_unix_ms);
        try update.bindText(5, report.deployment);
        try update.bindText(6, report.node_id);
        try update.done();
        if (c.sqlite3_changes(self.db) == 0) {
            try self.exec("ROLLBACK;");
            return false;
        }

        var history = try self.prepare(
            \\INSERT INTO workload_status_history (
            \\  deployment_name, node_id, revision, state, message,
            \\  observed_unix_ms, received_unix_ms
            \\) VALUES (?, ?, ?, ?, ?, ?, ?);
        );
        defer history.finalize();
        try history.bindText(1, report.deployment);
        try history.bindText(2, report.node_id);
        try history.bindInt64(3, @intCast(report.revision));
        try history.bindText(4, @tagName(report.state));
        try history.bindText(5, report.message);
        try history.bindInt64(6, report.observed_unix_ms);
        try history.bindInt64(7, received_unix_ms);
        try history.done();

        var prune_history = try self.prepare(
            "DELETE FROM workload_status_history WHERE received_unix_ms < ?;",
        );
        defer prune_history.finalize();
        try prune_history.bindInt64(1, received_unix_ms -| workload_status_retention_ms);
        try prune_history.done();

        if (report.state == .failed or report.state == .degraded) {
            try self.handleUnavailable(report.deployment, received_unix_ms);
        } else if (report.state == .healthy or report.state == .stopped) {
            try self.maybeAdvanceRollout(report.deployment, received_unix_ms);
        }

        try self.exec("COMMIT;");
        return true;
    }

    /// Persist a generation-fenced allocation observation. The agent can only
    /// report `released_ack_pending`; claim deletion and the final `released`
    /// phase are owned by this transaction.
    pub fn recordAllocationStatus(
        self: *Registry,
        report: allocation.Status,
        received_unix_ms: i64,
    ) !bool {
        allocation.validateStatus(report) catch return error.InvalidAllocationStatus;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};

        var current = try self.loadLifecycleCommand(report.node_id, report.deployment);
        defer if (current) |*command| command.deinit();
        const command = current orelse {
            try self.exec("ROLLBACK;");
            return false;
        };

        // An acknowledgement response may be lost. Keep the released command
        // as an idempotency tombstone and accept the exact retry.
        if (command.action == .release and command.phase == .released and
            report.phase == .released_ack_pending and
            std.mem.eql(u8, report.allocation_id, command.allocation_id) and
            report.generation == command.generation and
            report.revision == command.revision)
        {
            try self.exec("COMMIT;");
            return true;
        }

        const desired: allocation.DesiredAllocation = .{
            .allocation_id = command.allocation_id,
            .generation = command.generation,
            .deployment = command.deployment_name,
            .revision = command.revision,
            .action = command.action,
            .target_device_ids = if (command.action == .run) command.ids.items else &.{},
            .retiring_device_ids = if (command.action == .release) command.ids.items else &.{},
        };
        allocation.validateStatusTransition(
            report,
            desired,
            command.node_id,
            command.phase,
        ) catch return error.InvalidAllocationStatus;

        const stored_phase: allocation.ObservedPhase = if (report.phase == .released_ack_pending)
            .released
        else
            report.phase;
        var update = try self.prepare(
            \\UPDATE accelerator_allocation_commands
            \\SET phase=?, updated_unix_ms=?
            \\WHERE allocation_id=? AND generation=?;
        );
        defer update.finalize();
        try update.bindText(1, @tagName(stored_phase));
        try update.bindInt64(2, received_unix_ms);
        try update.bindText(3, report.allocation_id);
        try update.bindInt64(4, @intCast(report.generation));
        try update.done();
        if (c.sqlite3_changes(self.db) == 0)
            return error.StaleAllocationStatus;

        if (report.phase == .active) {
            var activate = try self.prepare(
                \\UPDATE accelerator_allocation_claims
                \\SET role='active', updated_unix_ms=?
                \\WHERE allocation_id=? AND generation=?;
            );
            defer activate.finalize();
            try activate.bindInt64(1, received_unix_ms);
            try activate.bindText(2, report.allocation_id);
            try activate.bindInt64(3, @intCast(report.generation));
            try activate.done();
        } else if (report.phase == .released_ack_pending) {
            var release = try self.prepare(
                \\DELETE FROM accelerator_allocation_claims
                \\WHERE allocation_id=? AND generation=?;
            );
            defer release.finalize();
            try release.bindText(1, report.allocation_id);
            try release.bindInt64(2, @intCast(report.generation));
            try release.done();
        }

        var history = try self.prepare(
            \\INSERT INTO accelerator_allocation_status_history (
            \\  allocation_id, generation, node_id, deployment_name, revision,
            \\  phase, message, observed_unix_ms, received_unix_ms
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        );
        defer history.finalize();
        try history.bindText(1, report.allocation_id);
        try history.bindInt64(2, @intCast(report.generation));
        try history.bindText(3, report.node_id);
        try history.bindText(4, report.deployment);
        try history.bindInt64(5, @intCast(report.revision));
        try history.bindText(6, @tagName(report.phase));
        try history.bindText(7, report.message);
        try history.bindInt64(8, report.observed_unix_ms);
        try history.bindInt64(9, received_unix_ms);
        try history.done();

        var prune = try self.prepare(
            "DELETE FROM accelerator_allocation_status_history WHERE received_unix_ms < ?;",
        );
        defer prune.finalize();
        try prune.bindInt64(1, received_unix_ms -| workload_status_retention_ms);
        try prune.done();
        if (command.action == .run) {
            const workload_state: orchestration.ObservedState = switch (report.phase) {
                .pending => .pending,
                .active => .healthy,
                .failed, .ambiguous => .failed,
                else => .applying,
            };
            try self.recordAllocationWorkloadStatus(
                report,
                workload_state,
                received_unix_ms,
            );
            if (workload_state == .failed) {
                try self.handleUnavailable(report.deployment, received_unix_ms);
            } else if (workload_state == .healthy) {
                try self.maybeAdvanceRollout(report.deployment, received_unix_ms);
            }
        }
        if (report.phase == .released_ack_pending)
            try self.audit(received_unix_ms, report.node_id, "accelerator.released", report.deployment);

        try self.exec("COMMIT;");
        return true;
    }

    fn recordAllocationWorkloadStatus(
        self: *Registry,
        report: allocation.Status,
        state: orchestration.ObservedState,
        received_unix_ms: i64,
    ) !void {
        const message = if (report.message.len > 0) report.message else @tagName(report.phase);
        var update = try self.prepare(
            \\UPDATE workload_assignments
            \\SET state=?, observed_revision=?, message=?, updated_unix_ms=?
            \\WHERE deployment_name=? AND node_id=?;
        );
        defer update.finalize();
        try update.bindText(1, @tagName(state));
        try update.bindInt64(2, @intCast(report.revision));
        try update.bindText(3, message);
        try update.bindInt64(4, received_unix_ms);
        try update.bindText(5, report.deployment);
        try update.bindText(6, report.node_id);
        try update.done();
        if (c.sqlite3_changes(self.db) == 0)
            return error.InconsistentLifecycleAssignment;

        var history = try self.prepare(
            \\INSERT INTO workload_status_history (
            \\  deployment_name, node_id, revision, state, message,
            \\  observed_unix_ms, received_unix_ms
            \\) VALUES (?, ?, ?, ?, ?, ?, ?);
        );
        defer history.finalize();
        try history.bindText(1, report.deployment);
        try history.bindText(2, report.node_id);
        try history.bindInt64(3, @intCast(report.revision));
        try history.bindText(4, @tagName(state));
        try history.bindText(5, message);
        try history.bindInt64(6, report.observed_unix_ms);
        try history.bindInt64(7, received_unix_ms);
        try history.done();

        var prune = try self.prepare(
            "DELETE FROM workload_status_history WHERE received_unix_ms < ?;",
        );
        defer prune.finalize();
        try prune.bindInt64(1, received_unix_ms -| workload_status_retention_ms);
        try prune.done();
    }

    fn insertTarget(self: *Registry, name: []const u8, kind: []const u8, value: []const u8) !void {
        var statement = try self.prepare(
            "INSERT OR IGNORE INTO deployment_targets (deployment_name, target_kind, target_value) VALUES (?, ?, ?);",
        );
        defer statement.finalize();
        try statement.bindText(1, name);
        try statement.bindText(2, kind);
        try statement.bindText(3, value);
        try statement.done();
    }

    fn insertLabelTarget(
        self: *Registry,
        name: []const u8,
        key: []const u8,
        value: []const u8,
    ) !void {
        var statement = try self.prepare(
            \\INSERT INTO deployment_label_targets (deployment_name, label_key, label_value)
            \\VALUES (?, ?, ?);
        );
        defer statement.finalize();
        try statement.bindText(1, name);
        try statement.bindText(2, key);
        try statement.bindText(3, value);
        try statement.done();
    }

    fn populateAssignments(
        self: *Registry,
        deployment_name: []const u8,
        batch_size: u32,
        now_unix_ms: i64,
    ) !void {
        var nodes = try self.prepare(
            \\SELECT n.node_id FROM nodes n
            \\WHERE EXISTS (
            \\        SELECT 1 FROM deployment_targets t
            \\        WHERE t.deployment_name=? AND t.target_kind='all'
            \\      )
            \\   OR EXISTS (
            \\        SELECT 1 FROM deployment_targets t
            \\        WHERE t.deployment_name=? AND t.target_kind='node'
            \\          AND t.target_value=n.node_id
            \\      )
            \\   OR EXISTS (
            \\        SELECT 1 FROM deployment_targets t
            \\        WHERE t.deployment_name=? AND t.target_kind='role'
            \\          AND t.target_value=n.role
            \\      )
            \\   OR (
            \\        EXISTS (SELECT 1 FROM deployment_label_targets lt
            \\                WHERE lt.deployment_name=?)
            \\        AND NOT EXISTS (
            \\          SELECT 1 FROM deployment_label_targets lt
            \\          WHERE lt.deployment_name=?
            \\            AND NOT EXISTS (
            \\              SELECT 1 FROM node_labels nl
            \\              WHERE nl.node_id=n.node_id AND nl.label_key=lt.label_key
            \\                AND nl.label_value=lt.label_value
            \\            )
            \\        )
            \\      )
            \\ORDER BY n.node_id;
        );
        defer nodes.finalize();
        for (1..6) |index| try nodes.bindText(@intCast(index), deployment_name);

        var index: i64 = 0;
        while (try nodes.row()) : (index += 1) {
            var insert = try self.prepare(
                \\INSERT INTO workload_assignments (
                \\  deployment_name, node_id, wave, state, observed_revision,
                \\  message, updated_unix_ms
                \\) VALUES (?, ?, ?, 'pending', 0, '', ?);
            );
            defer insert.finalize();
            try insert.bindText(1, deployment_name);
            try insert.bindText(2, nodes.columnText(0));
            try insert.bindInt64(3, @divFloor(index, @as(i64, batch_size)));
            try insert.bindInt64(4, now_unix_ms);
            try insert.done();
        }
    }

    fn getOrCreateAssignmentWave(
        self: *Registry,
        deployment_name: []const u8,
        node_id: []const u8,
        batch_size: i64,
        current_wave: i64,
        rollout_status: []const u8,
        now_unix_ms: i64,
    ) !i64 {
        var existing = try self.prepare(
            "SELECT wave FROM workload_assignments WHERE deployment_name=? AND node_id=?;",
        );
        defer existing.finalize();
        try existing.bindText(1, deployment_name);
        try existing.bindText(2, node_id);
        if (try existing.row()) return existing.columnInt64(0);

        const wave = if (std.mem.eql(u8, rollout_status, "completed") or
            std.mem.eql(u8, rollout_status, "rolled_back"))
            current_wave
        else blk: {
            var count = try self.prepare(
                "SELECT COUNT(*) FROM workload_assignments WHERE deployment_name=?;",
            );
            defer count.finalize();
            try count.bindText(1, deployment_name);
            _ = try count.row();
            break :blk @divFloor(count.columnInt64(0), batch_size);
        };

        var insert = try self.prepare(
            \\INSERT INTO workload_assignments (
            \\  deployment_name, node_id, wave, state, observed_revision, message, updated_unix_ms
            \\) VALUES (?, ?, ?, 'pending', 0, '', ?);
        );
        defer insert.finalize();
        try insert.bindText(1, deployment_name);
        try insert.bindText(2, node_id);
        try insert.bindInt64(3, wave);
        try insert.bindInt64(4, now_unix_ms);
        try insert.done();
        return wave;
    }

    fn handleUnavailable(self: *Registry, name: []const u8, now_unix_ms: i64) !void {
        var counts = try self.prepare(
            \\SELECT d.max_unavailable, d.auto_rollback, d.previous_spec_json,
            \\  (SELECT COUNT(*) FROM workload_assignments a
            \\   WHERE a.deployment_name=d.name AND a.wave=d.current_wave
            \\     AND a.observed_revision=d.revision
            \\     AND a.state IN ('failed', 'degraded'))
            \\FROM deployments d WHERE d.name=?;
        );
        defer counts.finalize();
        try counts.bindText(1, name);
        if (!try counts.row()) return;
        if (counts.columnInt64(3) < counts.columnInt64(0)) return;

        if (counts.columnInt64(1) == 1 and !counts.columnIsNull(2)) {
            if (try self.rollbackDeploymentInTransaction(name, now_unix_ms))
                try self.audit(now_unix_ms, "", "deployment.auto_rolled_back", name);
        } else {
            var failed = try self.prepare(
                "UPDATE deployments SET status='failed', updated_unix_ms=? WHERE name=?;",
            );
            defer failed.finalize();
            try failed.bindInt64(1, now_unix_ms);
            try failed.bindText(2, name);
            try failed.done();
        }
    }

    fn maybeAdvanceRollout(self: *Registry, name: []const u8, now_unix_ms: i64) !void {
        var progress = try self.prepare(
            \\SELECT d.current_wave, d.pause_seconds, d.wave_started_unix_ms,
            \\  (SELECT COUNT(*) FROM workload_assignments a
            \\   WHERE a.deployment_name=d.name AND a.wave=d.current_wave),
            \\  (SELECT COUNT(*) FROM workload_assignments a
            \\   WHERE a.deployment_name=d.name AND a.wave=d.current_wave
            \\     AND a.observed_revision=d.revision AND a.state IN ('healthy', 'stopped')),
            \\  COALESCE((SELECT MAX(a.wave) FROM workload_assignments a
            \\            WHERE a.deployment_name=d.name), 0),
            \\  d.status
            \\FROM deployments d WHERE d.name=?;
        );
        defer progress.finalize();
        try progress.bindText(1, name);
        if (!try progress.row()) return;
        const current_wave = progress.columnInt64(0);
        const pause_ms = progress.columnInt64(1) * 1000;
        const started = progress.columnInt64(2);
        const total = progress.columnInt64(3);
        const healthy = progress.columnInt64(4);
        const maximum_wave = progress.columnInt64(5);
        const rollout_status = progress.columnText(6);
        if (total == 0 or healthy != total) return;

        if (current_wave >= maximum_wave) {
            var complete = try self.prepare(
                \\UPDATE deployments SET status='completed', updated_unix_ms=?
                \\WHERE name=?;
            );
            defer complete.finalize();
            try complete.bindInt64(1, now_unix_ms);
            try complete.bindText(2, name);
            try complete.done();
            return;
        }

        if (pause_ms > 0 and !std.mem.eql(u8, rollout_status, "paused")) {
            var pause = try self.prepare(
                \\UPDATE deployments SET status='paused', wave_started_unix_ms=?,
                \\  updated_unix_ms=? WHERE name=?;
            );
            defer pause.finalize();
            try pause.bindInt64(1, now_unix_ms);
            try pause.bindInt64(2, now_unix_ms);
            try pause.bindText(3, name);
            try pause.done();
            return;
        }
        if (pause_ms > 0 and now_unix_ms - started < pause_ms) return;

        var update = try self.prepare(
            \\UPDATE deployments SET current_wave=current_wave+1,
            \\  wave_started_unix_ms=?, status='deploying', updated_unix_ms=? WHERE name=?;
        );
        defer update.finalize();
        try update.bindInt64(1, now_unix_ms);
        try update.bindInt64(2, now_unix_ms);
        try update.bindText(3, name);
        try update.done();
    }

    fn rollbackDeploymentInTransaction(self: *Registry, name: []const u8, now_unix_ms: i64) !bool {
        var update = try self.prepare(
            \\UPDATE deployments SET
            \\  revision=previous_revision,
            \\  spec_json=previous_spec_json,
            \\  previous_revision=NULL,
            \\  previous_spec_json=NULL,
            \\  current_wave=COALESCE((SELECT MAX(wave) FROM workload_assignments
            \\                         WHERE deployment_name=deployments.name), 0),
            \\  wave_started_unix_ms=?, status='rolled_back', updated_unix_ms=?
            \\WHERE name=? AND previous_spec_json IS NOT NULL;
        );
        defer update.finalize();
        try update.bindInt64(1, now_unix_ms);
        try update.bindInt64(2, now_unix_ms);
        try update.bindText(3, name);
        try update.done();
        const rolled_back = c.sqlite3_changes(self.db) > 0;
        if (!rolled_back) return false;

        var reset = try self.prepare(
            \\UPDATE workload_assignments
            \\SET state='pending', observed_revision=0, message='rollback requested', updated_unix_ms=?
            \\WHERE deployment_name=?;
        );
        defer reset.finalize();
        try reset.bindInt64(1, now_unix_ms);
        try reset.bindText(2, name);
        try reset.done();
        return true;
    }

    fn audit(
        self: *Registry,
        timestamp: i64,
        node_id: []const u8,
        action: []const u8,
        detail: []const u8,
    ) !void {
        var prune = try self.prepare("DELETE FROM audit_events WHERE created_unix_ms < ?;");
        defer prune.finalize();
        try prune.bindInt64(1, timestamp -| audit_retention_ms);
        try prune.done();

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
        if (c.sqlite3_exec(self.db, sql, null, null, null) != c.SQLITE_OK) {
            logSqliteError(self.db, "exec");
            return error.SqliteExecFailed;
        }
    }

    fn prepare(self: *Registry, sql: []const u8) !Statement {
        var optional: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &optional, null) != c.SQLITE_OK) {
            logSqliteError(self.db, "prepare");
            return error.SqlitePrepareFailed;
        }
        return .{ .handle = optional.?, .db = self.db };
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

const DeploymentSummary = struct {
    name: []const u8,
    revision: u64,
    status: []const u8,
    current_wave: u64,
    batch_size: u64,
    updated_unix_ms: i64,
};

const AssignmentSummary = struct {
    node_id: []const u8,
    /// Edge-placement candidates outside the selected replica set use -1 and
    /// do not participate in rollout health gates.
    wave: i64,
    state: []const u8,
    observed_revision: u64,
    message: []const u8,
    updated_unix_ms: i64,
};

const PlacementSummary = struct {
    node_id: []const u8,
    revision: u64,
    status: []const u8,
    reason_code: []const u8,
    reason_detail: []const u8,
    updated_unix_ms: i64,
};

const ReservationSummary = struct {
    node_id: []const u8,
    accelerator_id: []const u8,
    revision: u64,
};

const OwnedIds = struct {
    allocator: std.mem.Allocator,
    items: []const []const u8,

    fn deinit(self: *OwnedIds) void {
        for (self.items) |item| self.allocator.free(item);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

const ExistingReservation = struct {
    ids: OwnedIds,
    revision: ?u64,
};

const LifecycleCommand = struct {
    allocator: std.mem.Allocator,
    node_id: []const u8,
    deployment_name: []const u8,
    allocation_id: []const u8,
    generation: u64,
    revision: u64,
    action: allocation.DesiredAction,
    phase: allocation.ObservedPhase,
    ids: OwnedIds,

    fn deinit(self: *LifecycleCommand) void {
        self.allocator.free(self.node_id);
        self.allocator.free(self.deployment_name);
        self.allocator.free(self.allocation_id);
        self.ids.deinit();
        self.* = undefined;
    }
};

const PlacementResult = struct {
    ids: OwnedIds,
    ready: bool,
    reason_code: []const u8,

    fn deinit(self: *PlacementResult) void {
        self.ids.deinit();
        self.* = undefined;
    }
};

const Statement = struct {
    handle: *c.sqlite3_stmt,
    db: *c.sqlite3,

    fn finalize(self: *Statement) void {
        _ = c.sqlite3_finalize(self.handle);
        self.* = undefined;
    }

    fn bindText(self: *Statement, index: c_int, value: []const u8) !void {
        if (c.sqlite3_bind_text(self.handle, index, value.ptr, @intCast(value.len), null) != c.SQLITE_OK) {
            logSqliteError(self.db, "bind text");
            return error.SqliteBindFailed;
        }
    }

    fn bindInt64(self: *Statement, index: c_int, value: i64) !void {
        if (c.sqlite3_bind_int64(self.handle, index, value) != c.SQLITE_OK) {
            logSqliteError(self.db, "bind integer");
            return error.SqliteBindFailed;
        }
    }

    fn bindNull(self: *Statement, index: c_int) !void {
        if (c.sqlite3_bind_null(self.handle, index) != c.SQLITE_OK) {
            logSqliteError(self.db, "bind null");
            return error.SqliteBindFailed;
        }
    }

    fn done(self: *Statement) !void {
        if (c.sqlite3_step(self.handle) != c.SQLITE_DONE) {
            logSqliteError(self.db, "step");
            return error.SqliteStepFailed;
        }
    }

    fn row(self: *Statement) !bool {
        return switch (c.sqlite3_step(self.handle)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => {
                logSqliteError(self.db, "row step");
                return error.SqliteStepFailed;
            },
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

    fn columnIsNull(self: *Statement, index: c_int) bool {
        return c.sqlite3_column_type(self.handle, index) == c.SQLITE_NULL;
    }
};

fn hasFeature(features: []const []const u8, expected: []const u8) bool {
    for (features) |feature| {
        if (std.mem.eql(u8, feature, expected)) return true;
    }
    return false;
}

fn isCpuDeploymentSpec(allocator: std.mem.Allocator, spec_json: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(
        orchestration.Deployment,
        allocator,
        spec_json,
        .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
    );
    defer parsed.deinit();
    return parsed.value.resources == null;
}

fn cloneIds(allocator: std.mem.Allocator, input: []const []const u8) !OwnedIds {
    const items = try allocator.alloc([]const u8, input.len);
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |item| allocator.free(item);
        allocator.free(items);
    }
    for (input) |item| {
        items[initialized] = try allocator.dupe(u8, item);
        initialized += 1;
    }
    return .{ .allocator = allocator, .items = items };
}

fn lifecycleAllocationIdAlloc(
    allocator: std.mem.Allocator,
    node_id: []const u8,
    deployment_name: []const u8,
) ![]u8 {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var hash = Sha256.init(.{});
    hash.update("nimbus.accelerator.allocation.v1\x00");
    hash.update(node_id);
    hash.update("\x00");
    hash.update(deployment_name);
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "alloc-{s}", .{encoded});
}

fn nextAllocationGeneration(current: u64) !u64 {
    if (current == 0 or current >= std.math.maxInt(i64))
        return error.AllocationGenerationExhausted;
    return current + 1;
}

fn reservationMatches(
    inventory: accelerator.InventoryReport,
    requirement: accelerator.Requirement,
    device_ids: []const []const u8,
) bool {
    if (device_ids.len != requirement.count) return false;
    for (device_ids) |device_id| {
        var matched = false;
        for (inventory.accelerators) |device| {
            if (!std.mem.eql(u8, device.id, device_id)) continue;
            matched = accelerator.matchesRequirement(device, requirement);
            break;
        }
        if (!matched) return false;
    }
    return true;
}

fn reservationIdsPresent(
    inventory: accelerator.InventoryReport,
    device_ids: []const []const u8,
) bool {
    for (device_ids) |device_id| {
        var found = false;
        for (inventory.accelerators) |device| {
            if (!std.mem.eql(u8, device.id, device_id)) continue;
            found = true;
            break;
        }
        if (!found) return false;
    }
    return true;
}

fn selectionReason(err: accelerator.SelectionError) []const u8 {
    return switch (err) {
        error.InvalidInventory => "invalid_inventory",
        error.InvalidRequirement => "invalid_requirement",
        error.InventoryPartial => "inventory_partial",
        error.InventoryUnavailable => "inventory_unavailable",
        error.KindMismatch => "accelerator_kind_unavailable",
        error.DeviceUnavailable => "accelerator_unavailable",
        error.VendorMismatch => "accelerator_vendor_unavailable",
        error.MemoryMismatch => "accelerator_memory_insufficient",
        error.CapabilityMismatch => "accelerator_capability_missing",
        error.InsufficientDevices => "accelerator_count_insufficient",
        error.DeviceReserved => "accelerator_capacity_exhausted",
        error.DynamicPolicyMismatch => "accelerator_dynamic_policy_mismatch",
        error.OutOfMemory => "out_of_memory",
    };
}

fn selectAcceleratorsAlloc(
    allocator: std.mem.Allocator,
    inventory: accelerator.InventoryReport,
    requirement: accelerator.Requirement,
    reserved_ids: []const []const u8,
    policy: ?edge_placement.Policy,
) accelerator.SelectionError![]const []const u8 {
    return if (policy) |edge_policy|
        accelerator.selectForPlacementAlloc(
            allocator,
            inventory,
            requirement,
            reserved_ids,
            edge_policy,
        )
    else
        accelerator.selectAlloc(allocator, inventory, requirement, reserved_ids);
}

fn logSqliteError(db: *c.sqlite3, operation: []const u8) void {
    const message = std.mem.span(c.sqlite3_errmsg(db));
    std.log.err("SQLite {s} failed: {s}", .{ operation, message });
}

fn status(now_unix_ms: i64, last_seen_unix_ms: i64, stale_after_ms: i64) []const u8 {
    return if (now_unix_ms - last_seen_unix_ms > stale_after_ms) "stale" else "online";
}

const lifecycle_test_devices = [_]accelerator.Device{.{
    .id = "gpu:nvidia:a",
    .kind = .gpu,
    .vendor = "NVIDIA",
    .model = "L4",
    .source = "fixture",
    .memory_total_bytes = 24 * 1024 * 1024 * 1024,
    .capabilities = &.{"fp16"},
}};

const lifecycle_test_probes = [_]accelerator.ProbeOutcome{.{
    .name = "fixture",
    .status = .ok,
    .devices_found = 1,
}};

fn lifecycleTestHeartbeat(features: []const []const u8) heartbeat.Heartbeat {
    return .{
        .node_id = "gpu-edge",
        .hostname = "gpu-edge",
        .role = "edge",
        .features = features,
        .platform = .{
            .os = "linux",
            .arch = "x86_64",
            .abi = "gnu",
            .host_arch = "aarch64",
        },
        .resources = .{ .cpu_count = 8 },
        .accelerator_inventory = .{
            .status = .complete,
            .accelerators = &lifecycle_test_devices,
            .probes = &lifecycle_test_probes,
        },
        .timestamp_unix_ms = 1000,
    };
}

fn lifecycleTestDeployment(name: []const u8) orchestration.Deployment {
    return .{
        .name = name,
        .revision = 1,
        .runtime = .{
            .kind = .docker,
            .reference = "registry.example/vision@sha256:" ++ ("ab" ** 32),
        },
        .resources = .{ .accelerators = .{
            .kind = .gpu,
            .vendor = "nvidia",
            .capabilities = &.{"fp16"},
        } },
        .targets = .{ .all = true },
    };
}

fn recordLifecycleTestHeartbeat(
    registry: *Registry,
    report: heartbeat.Heartbeat,
    now_unix_ms: i64,
) !void {
    const json = try heartbeat.serializeAlloc(std.testing.allocator, report);
    defer std.testing.allocator.free(json);
    try registry.recordHeartbeat(report, json, now_unix_ms);
}

fn applyLifecycleTestDeployment(
    registry: *Registry,
    deployment: orchestration.Deployment,
    now_unix_ms: i64,
) !void {
    const json = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        deployment,
        .{ .emit_null_optional_fields = false },
    );
    defer std.testing.allocator.free(json);
    try registry.applyDeployment(deployment, json, now_unix_ms);
}

test "migration five adds runtime host architecture to existing databases" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &root_buffer);
    const database_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root_buffer[0..root_len], "legacy.db" },
    );
    defer std.testing.allocator.free(database_path);
    const database_path_z = try std.testing.allocator.dupeZ(u8, database_path);
    defer std.testing.allocator.free(database_path_z);

    var old_database: ?*c.sqlite3 = null;
    try std.testing.expect(c.sqlite3_open_v2(
        database_path_z.ptr,
        &old_database,
        c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE,
        null,
    ) == c.SQLITE_OK);
    errdefer {
        if (old_database) |database| _ = c.sqlite3_close(database);
    }
    const old_schema =
        \\CREATE TABLE nodes (
        \\  node_id TEXT PRIMARY KEY, hostname TEXT NOT NULL, role TEXT NOT NULL,
        \\  os TEXT NOT NULL, arch TEXT NOT NULL, abi TEXT NOT NULL,
        \\  cpu_count INTEGER NOT NULL, agent_version TEXT NOT NULL,
        \\  report_json TEXT NOT NULL, first_seen_unix_ms INTEGER NOT NULL,
        \\  last_seen_unix_ms INTEGER NOT NULL
        \\);
        \\CREATE TABLE schema_migrations (
        \\  version INTEGER PRIMARY KEY, applied_unix_ms INTEGER NOT NULL
        \\);
    ;
    try std.testing.expect(c.sqlite3_exec(old_database.?, old_schema, null, null, null) == c.SQLITE_OK);
    try std.testing.expect(c.sqlite3_close(old_database.?) == c.SQLITE_OK);
    old_database = null;

    var registry = try Registry.open(std.testing.allocator, std.testing.io, database_path);
    defer registry.close();
    var column = try registry.prepare(
        "SELECT 1 FROM pragma_table_info('nodes') WHERE name='host_arch';",
    );
    defer column.finalize();
    try std.testing.expect(try column.row());
    var migration = try registry.prepare(
        "SELECT 1 FROM schema_migrations WHERE version=5;",
    );
    defer migration.finalize();
    try std.testing.expect(try migration.row());
}

test "SQLite registry persists and marks nodes stale" {
    var registry = try Registry.open(std.testing.allocator, std.testing.io, ":memory:");
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

    const nodes = try registry.listNodes(4001, 3000, 100, null);
    defer std.testing.allocator.free(nodes);
    try std.testing.expect(std.mem.indexOf(u8, nodes, "\"node_id\":\"edge-01\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, nodes, "\"status\":\"stale\"") != null);
}

test "artifact variants are delivered only to agents that advertise support" {
    var registry = try Registry.open(std.testing.allocator, std.testing.io, ":memory:");
    defer registry.close();
    const legacy_features = [_][]const u8{
        heartbeat.feature_accelerator_requirements_v1,
        heartbeat.feature_accelerator_lifecycle_v1,
    };
    try recordLifecycleTestHeartbeat(&registry, lifecycleTestHeartbeat(&legacy_features), 1000);
    const variants = [_]orchestration.ArtifactVariant{.{
        .name = "linux-x86",
        .artifact = .{
            .source = "file:///tmp/model",
            .sha256 = "ab" ** 32,
        },
        .selector = .{ .os = "linux", .arch = "x86_64" },
    }};
    const deployment: orchestration.Deployment = .{
        .name = "variant-model",
        .revision = 1,
        .runtime = .{ .kind = .process, .command = &.{"{artifact}"} },
        .artifact_variants = &variants,
        .targets = .{ .all = true },
    };
    try applyLifecycleTestDeployment(&registry, deployment, 1100);

    const unsupported = (try registry.desiredStateForNode("gpu-edge", 1200)).?;
    defer std.testing.allocator.free(unsupported);
    var parsed_unsupported = try std.json.parseFromSlice(
        orchestration.DesiredState,
        std.testing.allocator,
        unsupported,
        .{ .ignore_unknown_fields = false },
    );
    defer parsed_unsupported.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed_unsupported.value.deployments.len);

    const supported_features = [_][]const u8{
        heartbeat.feature_accelerator_requirements_v1,
        heartbeat.feature_accelerator_lifecycle_v1,
        heartbeat.feature_artifact_variants_v1,
    };
    try recordLifecycleTestHeartbeat(&registry, lifecycleTestHeartbeat(&supported_features), 1300);
    const supported = (try registry.desiredStateForNode("gpu-edge", 1400)).?;
    defer std.testing.allocator.free(supported);
    var parsed_supported = try std.json.parseFromSlice(
        orchestration.DesiredState,
        std.testing.allocator,
        supported,
        .{ .ignore_unknown_fields = false },
    );
    defer parsed_supported.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_supported.value.deployments.len);
    try std.testing.expect(parsed_supported.value.deployments[0].artifact_variants != null);
}

test "edge placement is deterministic sticky explainable and bounded" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &root_buffer);
    const database_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root_buffer[0..root_len], "placement.db" },
    );
    defer std.testing.allocator.free(database_path);
    var registry = try Registry.open(std.testing.allocator, std.testing.io, database_path);
    defer registry.close();
    const features = [_][]const u8{
        heartbeat.feature_accelerator_requirements_v1,
        heartbeat.feature_accelerator_lifecycle_v1,
        heartbeat.feature_artifact_variants_v1,
        heartbeat.feature_edge_placement_v1,
    };
    const digest = "ab" ** 32;
    var report: heartbeat.Heartbeat = .{
        .node_id = "edge-c",
        .hostname = "edge-c",
        .role = "edge",
        .features = &features,
        .platform = .{ .os = "linux", .arch = "x86_64", .abi = "gnu" },
        .resources = .{ .cpu_count = 8 },
        .accelerator_inventory = .{
            .status = .complete,
            .accelerators = &.{},
            .probes = &.{.{
                .name = "fixture",
                .status = .not_present,
                .devices_found = 0,
            }},
        },
        .placement_telemetry = .{ .cost_microunits_per_hour = 10 },
        .timestamp_unix_ms = 1000,
    };
    try recordLifecycleTestHeartbeat(&registry, report, 1000);
    report.node_id = "edge-a";
    report.hostname = "edge-a";
    report.placement_telemetry = .{
        .connectivity_quality_percent = 80,
        .cost_microunits_per_hour = 20,
        .cached_artifact_sha256 = &.{digest},
    };
    try recordLifecycleTestHeartbeat(&registry, report, 19_000);
    report.node_id = "edge-b";
    report.hostname = "edge-b";
    report.placement_telemetry = .{
        .connectivity_quality_percent = 100,
        .cost_microunits_per_hour = 10,
    };
    try recordLifecycleTestHeartbeat(&registry, report, 19_100);
    report.schema_version = 3;
    report.node_id = "edge-legacy";
    report.hostname = "edge-legacy";
    report.features = &.{
        heartbeat.feature_accelerator_requirements_v1,
        heartbeat.feature_accelerator_lifecycle_v1,
    };
    report.placement_telemetry = null;
    try recordLifecycleTestHeartbeat(&registry, report, 19_200);
    report.schema_version = heartbeat.current_schema_version;
    report.node_id = "edge-b";
    report.hostname = "edge-b";
    report.features = &features;

    const deployment: orchestration.Deployment = .{
        .name = "edge-ranked",
        .revision = 1,
        .runtime = .{ .kind = .process, .command = &.{"{artifact}"} },
        .artifact = .{ .source = "file:///tmp/model", .sha256 = digest },
        .placement = .{
            .replicas = 1,
            .max_offline_seconds = 5,
            .max_cost_microunits_per_hour = 100,
        },
        .targets = .{ .all = true },
    };
    try applyLifecycleTestDeployment(&registry, deployment, 20_000);

    const selected = (try registry.desiredStateForNode("edge-a", 20_100)).?;
    defer std.testing.allocator.free(selected);
    try std.testing.expect(std.mem.indexOf(u8, selected, "\"name\":\"edge-ranked\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, selected, "\"placement\"") == null);
    const lower_rank = (try registry.desiredStateForNode("edge-b", 20_100)).?;
    defer std.testing.allocator.free(lower_rank);
    try std.testing.expect(std.mem.indexOf(u8, lower_rank, "\"name\":\"edge-ranked\"") == null);
    const offline = (try registry.desiredStateForNode("edge-c", 20_100)).?;
    defer std.testing.allocator.free(offline);
    try std.testing.expect(std.mem.indexOf(u8, offline, "\"name\":\"edge-ranked\"") == null);

    const inspected = (try registry.inspectDeployment("edge-ranked")).?;
    defer std.testing.allocator.free(inspected);
    try std.testing.expect(std.mem.indexOf(u8, inspected, "placement_selected") != null);
    try std.testing.expect(std.mem.indexOf(u8, inspected, "not_selected_lower_rank") != null);
    try std.testing.expect(std.mem.indexOf(u8, inspected, "node_offline") != null);
    try std.testing.expect(std.mem.indexOf(u8, inspected, "agent_feature_unsupported") != null);
    try std.testing.expect(std.mem.indexOf(u8, inspected, "\\\"cache_hit\\\":true") != null);

    var waves = try registry.prepare(
        \\SELECT node_id, wave FROM workload_assignments
        \\WHERE deployment_name='edge-ranked' ORDER BY node_id;
    );
    defer waves.finalize();
    while (try waves.row()) {
        const expected_wave: i64 = if (std.mem.eql(u8, waves.columnText(0), "edge-a")) 0 else -1;
        try std.testing.expectEqual(expected_wave, waves.columnInt64(1));
    }
    report.node_id = "edge-d";
    report.hostname = "edge-d";
    report.placement_telemetry = .{ .cost_microunits_per_hour = 30 };
    try recordLifecycleTestHeartbeat(&registry, report, 20_120);
    const late_unselected = (try registry.desiredStateForNode("edge-d", 20_130)).?;
    defer std.testing.allocator.free(late_unselected);
    try std.testing.expect(std.mem.indexOf(u8, late_unselected, "\"name\":\"edge-ranked\"") == null);
    var late_wave = try registry.prepare(
        "SELECT wave FROM workload_assignments WHERE deployment_name='edge-ranked' AND node_id='edge-d';",
    );
    defer late_wave.finalize();
    try std.testing.expect(try late_wave.row());
    try std.testing.expectEqual(@as(i64, -1), late_wave.columnInt64(0));
    try std.testing.expect(try registry.recordWorkloadStatus(.{
        .node_id = "edge-a",
        .deployment = "edge-ranked",
        .revision = 1,
        .state = .healthy,
        .observed_unix_ms = 20_150,
    }, 20_150));
    const completed = (try registry.inspectDeployment("edge-ranked")).?;
    defer std.testing.allocator.free(completed);
    try std.testing.expect(std.mem.indexOf(u8, completed, "\"status\":\"completed\"") != null);

    // The persisted plan, not desired-state read order, survives a server restart.
    registry.close();
    registry = try Registry.open(std.testing.allocator, std.testing.io, database_path);
    const after_restart = (try registry.desiredStateForNode("edge-a", 20_100)).?;
    defer std.testing.allocator.free(after_restart);
    try std.testing.expect(std.mem.indexOf(u8, after_restart, "\"name\":\"edge-ranked\"") != null);

    // A newly better report cannot duplicate an already admitted singleton.
    report.node_id = "edge-b";
    report.hostname = "edge-b";
    report.placement_telemetry = .{
        .connectivity_quality_percent = 100,
        .cost_microunits_per_hour = 1,
        .cached_artifact_sha256 = &.{digest},
    };
    for (0..1000) |_| try recordLifecycleTestHeartbeat(&registry, report, 21_000);
    const still_selected = (try registry.desiredStateForNode("edge-a", 21_100)).?;
    defer std.testing.allocator.free(still_selected);
    try std.testing.expect(std.mem.indexOf(u8, still_selected, "\"name\":\"edge-ranked\"") != null);
    const still_lower = (try registry.desiredStateForNode("edge-b", 21_100)).?;
    defer std.testing.allocator.free(still_lower);
    try std.testing.expect(std.mem.indexOf(u8, still_lower, "\"name\":\"edge-ranked\"") == null);

    var decisions = try registry.prepare(
        "SELECT COUNT(*) FROM placement_decisions WHERE deployment_name='edge-ranked';",
    );
    defer decisions.finalize();
    try std.testing.expect(try decisions.row());
    try std.testing.expectEqual(@as(i64, 5), decisions.columnInt64(0));
    var history = try registry.prepare("SELECT COUNT(*) FROM heartbeat_history;");
    defer history.finalize();
    try std.testing.expect(try history.row());
    try std.testing.expect(history.columnInt64(0) <= 5);
}

test "version one and accelerator inventory heartbeats coexist" {
    var registry = try Registry.open(std.testing.allocator, std.testing.io, ":memory:");
    defer registry.close();

    const version_one: heartbeat.Heartbeat = .{
        .schema_version = 1,
        .node_id = "legacy-edge",
        .hostname = "legacy-edge",
        .role = "edge",
        .platform = .{ .os = "linux", .arch = "aarch64", .abi = "musl" },
        .resources = .{ .cpu_count = 4 },
        .timestamp_unix_ms = 1000,
    };
    const version_one_json = try heartbeat.serializeAlloc(std.testing.allocator, version_one);
    defer std.testing.allocator.free(version_one_json);
    try registry.recordHeartbeat(version_one, version_one_json, 1000);

    const devices = [_]accelerator.Device{.{
        .id = "gpu:nvidia:7f3c",
        .kind = .gpu,
        .vendor = "NVIDIA",
        .model = "Jetson-Orin",
        .source = "fixture",
        .memory_total_bytes = 8 * 1024 * 1024 * 1024,
        .capabilities = &.{ "fp16", "int8" },
    }};
    const probes = [_]accelerator.ProbeOutcome{.{
        .name = "fixture",
        .status = .ok,
        .devices_found = 1,
    }};
    const version_two: heartbeat.Heartbeat = .{
        .schema_version = 2,
        .node_id = "accelerated-edge",
        .hostname = "accelerated-edge",
        .role = "edge",
        .platform = .{ .os = "linux", .arch = "aarch64", .abi = "musl" },
        .resources = .{ .cpu_count = 8 },
        .accelerator_inventory = .{
            .status = .complete,
            .accelerators = &devices,
            .probes = &probes,
        },
        .timestamp_unix_ms = 2000,
    };
    const version_two_json = try heartbeat.serializeAlloc(std.testing.allocator, version_two);
    defer std.testing.allocator.free(version_two_json);
    try registry.recordHeartbeat(version_two, version_two_json, 2000);

    const legacy = (try registry.inspectNode("legacy-edge", 2000, 3000)).?;
    defer std.testing.allocator.free(legacy);
    try std.testing.expect(std.mem.indexOf(u8, legacy, "\"schema_version\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, legacy, "gpu:nvidia") == null);

    const accelerated = (try registry.inspectNode("accelerated-edge", 2000, 3000)).?;
    defer std.testing.allocator.free(accelerated);
    try std.testing.expect(std.mem.indexOf(u8, accelerated, "\"schema_version\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, accelerated, "\"gpu:nvidia:7f3c\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, accelerated, "\"status\":\"complete\"") != null);
}

test "accelerator placement is deterministic and exclusive" {
    var registry = try Registry.open(std.testing.allocator, std.testing.io, ":memory:");
    defer registry.close();
    const devices = [_]accelerator.Device{.{
        .id = "gpu:nvidia:a",
        .kind = .gpu,
        .vendor = "NVIDIA",
        .model = "L4",
        .source = "fixture",
        .memory_total_bytes = 24 * 1024 * 1024 * 1024,
        .capabilities = &.{"fp16"},
    }};
    const probes = [_]accelerator.ProbeOutcome{.{
        .name = "fixture",
        .status = .ok,
        .devices_found = 1,
    }};
    const report: heartbeat.Heartbeat = .{
        .node_id = "gpu-edge",
        .hostname = "gpu-edge",
        .role = "edge",
        .features = &.{heartbeat.feature_accelerator_requirements_v1},
        .platform = .{ .os = "linux", .arch = "x86_64", .abi = "gnu" },
        .resources = .{ .cpu_count = 8 },
        .accelerator_inventory = .{
            .status = .complete,
            .accelerators = &devices,
            .probes = &probes,
        },
        .timestamp_unix_ms = 1000,
    };
    const heartbeat_json = try heartbeat.serializeAlloc(std.testing.allocator, report);
    defer std.testing.allocator.free(heartbeat_json);
    try registry.recordHeartbeat(report, heartbeat_json, 1000);

    const first: orchestration.Deployment = .{
        .name = "accelerated-a",
        .revision = 1,
        .runtime = .{ .kind = .process, .command = &.{"/bin/true"} },
        .resources = .{ .accelerators = .{
            .kind = .gpu,
            .vendor = "nvidia",
            .memory_min_bytes = 8 * 1024 * 1024 * 1024,
            .capabilities = &.{"fp16"},
        } },
        .targets = .{ .all = true },
    };
    const first_json = try std.json.Stringify.valueAlloc(std.testing.allocator, first, .{
        .emit_null_optional_fields = false,
    });
    defer std.testing.allocator.free(first_json);
    try registry.applyDeployment(first, first_json, 1100);

    var second = first;
    second.name = "accelerated-b";
    const second_json = try std.json.Stringify.valueAlloc(std.testing.allocator, second, .{
        .emit_null_optional_fields = false,
    });
    defer std.testing.allocator.free(second_json);
    try registry.applyDeployment(second, second_json, 1200);

    const desired_json = (try registry.desiredStateForNode("gpu-edge", 1300)).?;
    defer std.testing.allocator.free(desired_json);
    var desired = try std.json.parseFromSlice(
        orchestration.DesiredState,
        std.testing.allocator,
        desired_json,
        .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
    );
    defer desired.deinit();
    try std.testing.expectEqual(@as(usize, 2), desired.value.deployments.len);
    try std.testing.expectEqualStrings("accelerated-a", desired.value.deployments[0].name);
    try std.testing.expectEqualStrings("accelerated-b", desired.value.deployments[1].name);
    try std.testing.expectEqual(@as(usize, 1), desired.value.accelerator_assignments.len);
    try std.testing.expectEqualStrings(
        "gpu:nvidia:a",
        desired.value.accelerator_assignments[0].device_ids[0],
    );

    const first_inspect = (try registry.inspectDeployment("accelerated-a")).?;
    defer std.testing.allocator.free(first_inspect);
    try std.testing.expect(std.mem.indexOf(u8, first_inspect, "\"accelerator_id\":\"gpu:nvidia:a\"") != null);
    const second_inspect = (try registry.inspectDeployment("accelerated-b")).?;
    defer std.testing.allocator.free(second_inspect);
    try std.testing.expect(std.mem.indexOf(u8, second_inspect, "\"reason_code\":\"accelerator_capacity_exhausted\"") != null);

    var normalized = try registry.prepare("SELECT COUNT(*) FROM node_accelerators;");
    defer normalized.finalize();
    try std.testing.expect(try normalized.row());
    try std.testing.expectEqual(@as(i64, 1), normalized.columnInt64(0));

    const failed_probes = [_]accelerator.ProbeOutcome{.{
        .name = "fixture",
        .status = .failed,
        .devices_found = 0,
        .error_name = "ProviderCommandFailed",
    }};
    var unavailable_report = report;
    unavailable_report.accelerator_inventory = .{
        .status = .unavailable,
        .accelerators = &.{},
        .probes = &failed_probes,
    };
    const unavailable_json = try heartbeat.serializeAlloc(std.testing.allocator, unavailable_report);
    defer std.testing.allocator.free(unavailable_json);
    try registry.recordHeartbeat(unavailable_report, unavailable_json, 1400);
    const unavailable_desired = (try registry.desiredStateForNode("gpu-edge", 1500)).?;
    defer std.testing.allocator.free(unavailable_desired);
    const unconfirmed = (try registry.inspectDeployment("accelerated-a")).?;
    defer std.testing.allocator.free(unconfirmed);
    try std.testing.expect(std.mem.indexOf(u8, unconfirmed, "\"reason_code\":\"assigned_device_unconfirmed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, unconfirmed, "\"accelerator_id\":\"gpu:nvidia:a\"") != null);

    const empty_probes = [_]accelerator.ProbeOutcome{.{
        .name = "fixture",
        .status = .ok,
        .devices_found = 0,
    }};
    var empty_report = report;
    empty_report.accelerator_inventory = .{
        .status = .complete,
        .accelerators = &.{},
        .probes = &empty_probes,
    };
    const empty_json = try heartbeat.serializeAlloc(std.testing.allocator, empty_report);
    defer std.testing.allocator.free(empty_json);
    try registry.recordHeartbeat(empty_report, empty_json, 1600);
    const empty_desired = (try registry.desiredStateForNode("gpu-edge", 1700)).?;
    defer std.testing.allocator.free(empty_desired);
    const missing = (try registry.inspectDeployment("accelerated-a")).?;
    defer std.testing.allocator.free(missing);
    try std.testing.expect(std.mem.indexOf(u8, missing, "\"reason_code\":\"assigned_device_missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "\"accelerator_id\":\"gpu:nvidia:a\"") != null);

    const cpu_v1: orchestration.Deployment = .{
        .name = "compat-workload",
        .revision = 1,
        .runtime = .{ .kind = .process, .command = &.{"/bin/true"} },
        .targets = .{ .node_ids = &.{"gpu-edge"} },
    };
    const cpu_v1_json = try std.json.Stringify.valueAlloc(std.testing.allocator, cpu_v1, .{
        .emit_null_optional_fields = false,
    });
    defer std.testing.allocator.free(cpu_v1_json);
    try registry.applyDeployment(cpu_v1, cpu_v1_json, 1800);

    var legacy_report = report;
    legacy_report.schema_version = 2;
    legacy_report.features = &.{};
    const legacy_json = try heartbeat.serializeAlloc(std.testing.allocator, legacy_report);
    defer std.testing.allocator.free(legacy_json);
    try registry.recordHeartbeat(legacy_report, legacy_json, 1900);

    var accelerated_v2 = cpu_v1;
    accelerated_v2.revision = 2;
    accelerated_v2.resources = first.resources;
    const accelerated_v2_json = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        accelerated_v2,
        .{ .emit_null_optional_fields = false },
    );
    defer std.testing.allocator.free(accelerated_v2_json);
    try registry.applyDeployment(accelerated_v2, accelerated_v2_json, 2000);

    const legacy_desired_json = (try registry.desiredStateForNode("gpu-edge", 2100)).?;
    defer std.testing.allocator.free(legacy_desired_json);
    var legacy_desired = try std.json.parseFromSlice(
        orchestration.DesiredState,
        std.testing.allocator,
        legacy_desired_json,
        .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
    );
    defer legacy_desired.deinit();
    try std.testing.expectEqual(@as(usize, 1), legacy_desired.value.deployments.len);
    try std.testing.expectEqualStrings(
        "compat-workload",
        legacy_desired.value.deployments[0].name,
    );
    try std.testing.expectEqual(@as(u64, 1), legacy_desired.value.deployments[0].revision);
    try std.testing.expect(legacy_desired.value.deployments[0].resources == null);
}

test "fenced accelerator claims survive deletion until central release acknowledgement" {
    var registry = try Registry.open(std.testing.allocator, std.testing.io, ":memory:");
    defer registry.close();
    const devices = [_]accelerator.Device{.{
        .id = "gpu:nvidia:a",
        .kind = .gpu,
        .vendor = "NVIDIA",
        .model = "L4",
        .source = "fixture",
        .memory_total_bytes = 24 * 1024 * 1024 * 1024,
        .capabilities = &.{"fp16"},
    }};
    const probes = [_]accelerator.ProbeOutcome{.{
        .name = "fixture",
        .status = .ok,
        .devices_found = 1,
    }};
    const report: heartbeat.Heartbeat = .{
        .node_id = "gpu-edge",
        .hostname = "gpu-edge",
        .role = "edge",
        .features = &.{
            heartbeat.feature_accelerator_requirements_v1,
            heartbeat.feature_accelerator_lifecycle_v1,
        },
        .platform = .{ .os = "linux", .arch = "x86_64", .abi = "gnu" },
        .resources = .{ .cpu_count = 8 },
        .accelerator_inventory = .{
            .status = .complete,
            .accelerators = &devices,
            .probes = &probes,
        },
        .timestamp_unix_ms = 1000,
    };
    const heartbeat_json = try heartbeat.serializeAlloc(std.testing.allocator, report);
    defer std.testing.allocator.free(heartbeat_json);
    try registry.recordHeartbeat(report, heartbeat_json, 1000);

    const deployment: orchestration.Deployment = .{
        .name = "vision",
        .revision = 1,
        .runtime = .{
            .kind = .docker,
            .reference = "registry.example/vision@sha256:" ++ ("ab" ** 32),
        },
        .resources = .{ .accelerators = .{
            .kind = .gpu,
            .vendor = "nvidia",
            .capabilities = &.{"fp16"},
        } },
        .targets = .{ .all = true },
    };
    const deployment_json = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        deployment,
        .{ .emit_null_optional_fields = false },
    );
    defer std.testing.allocator.free(deployment_json);
    try registry.applyDeployment(deployment, deployment_json, 1100);

    const desired_json = (try registry.desiredStateForNode("gpu-edge", 1200)).?;
    defer std.testing.allocator.free(desired_json);
    var desired = try std.json.parseFromSlice(
        orchestration.DesiredState,
        std.testing.allocator,
        desired_json,
        .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
    );
    defer desired.deinit();
    try std.testing.expectEqual(@as(usize, 0), desired.value.accelerator_assignments.len);
    try std.testing.expectEqual(@as(usize, 1), desired.value.accelerator_allocations.len);
    const run_command = desired.value.accelerator_allocations[0];
    try std.testing.expectEqual(allocation.DesiredAction.run, run_command.action);
    try std.testing.expectEqual(@as(u64, 1), run_command.generation);
    try std.testing.expectEqualStrings("gpu:nvidia:a", run_command.target_device_ids[0]);

    var run_status: allocation.Status = .{
        .allocation_id = run_command.allocation_id,
        .generation = run_command.generation,
        .node_id = "gpu-edge",
        .deployment = "vision",
        .revision = 1,
        .phase = .active,
        .observed_unix_ms = 1201,
    };
    try std.testing.expectError(
        error.InvalidAllocationStatus,
        registry.recordAllocationStatus(run_status, 1201),
    );
    const run_phases = [_]allocation.ObservedPhase{
        .pending,
        .prepared,
        .starting_target,
        .target_started,
        .verifying,
        .active,
    };
    for (run_phases, 0..) |phase, index| {
        run_status.phase = phase;
        run_status.observed_unix_ms = 1210 + @as(i64, @intCast(index));
        try std.testing.expect(try registry.recordAllocationStatus(
            run_status,
            run_status.observed_unix_ms,
        ));
    }

    var rollout = try registry.prepare(
        \\SELECT a.state, a.observed_revision, d.status
        \\FROM workload_assignments a
        \\JOIN deployments d ON d.name=a.deployment_name
        \\WHERE a.deployment_name='vision' AND a.node_id='gpu-edge';
    );
    defer rollout.finalize();
    try std.testing.expect(try rollout.row());
    try std.testing.expectEqualStrings("healthy", rollout.columnText(0));
    try std.testing.expectEqual(@as(i64, 1), rollout.columnInt64(1));
    try std.testing.expectEqualStrings("completed", rollout.columnText(2));

    var active_claim = try registry.prepare(
        \\SELECT role, generation FROM accelerator_allocation_claims
        \\WHERE node_id='gpu-edge' AND accelerator_id='gpu:nvidia:a';
    );
    defer active_claim.finalize();
    try std.testing.expect(try active_claim.row());
    try std.testing.expectEqualStrings("active", active_claim.columnText(0));
    try std.testing.expectEqual(@as(i64, 1), active_claim.columnInt64(1));

    try std.testing.expect(try registry.deleteDeployment("vision", 1300));
    const release_json = (try registry.desiredStateForNode("gpu-edge", 1400)).?;
    defer std.testing.allocator.free(release_json);
    var release_desired = try std.json.parseFromSlice(
        orchestration.DesiredState,
        std.testing.allocator,
        release_json,
        .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
    );
    defer release_desired.deinit();
    try std.testing.expectEqual(@as(usize, 0), release_desired.value.deployments.len);
    try std.testing.expectEqual(@as(usize, 1), release_desired.value.accelerator_allocations.len);
    const release_command = release_desired.value.accelerator_allocations[0];
    try std.testing.expectEqual(allocation.DesiredAction.release, release_command.action);
    try std.testing.expectEqual(@as(u64, 2), release_command.generation);
    try std.testing.expectEqualStrings("gpu:nvidia:a", release_command.retiring_device_ids[0]);

    var stale = run_status;
    stale.phase = .failed;
    stale.observed_unix_ms = 1401;
    try std.testing.expectError(
        error.InvalidAllocationStatus,
        registry.recordAllocationStatus(stale, 1401),
    );

    var release_status: allocation.Status = .{
        .allocation_id = release_command.allocation_id,
        .generation = release_command.generation,
        .node_id = "gpu-edge",
        .deployment = "vision",
        .revision = 1,
        .phase = .release_requested,
        .observed_unix_ms = 1410,
    };
    const release_phases = [_]allocation.ObservedPhase{
        .release_requested,
        .stopping,
        .released_ack_pending,
    };
    for (release_phases, 0..) |phase, index| {
        release_status.phase = phase;
        release_status.observed_unix_ms = 1410 + @as(i64, @intCast(index));
        try std.testing.expect(try registry.recordAllocationStatus(
            release_status,
            release_status.observed_unix_ms,
        ));
    }
    // Lost HTTP responses are safe: the exact final report is idempotent.
    try std.testing.expect(try registry.recordAllocationStatus(release_status, 1420));

    var claim_count = try registry.prepare(
        "SELECT COUNT(*) FROM accelerator_allocation_claims WHERE node_id='gpu-edge';",
    );
    defer claim_count.finalize();
    try std.testing.expect(try claim_count.row());
    try std.testing.expectEqual(@as(i64, 0), claim_count.columnInt64(0));
    const released_json = (try registry.desiredStateForNode("gpu-edge", 1500)).?;
    defer std.testing.allocator.free(released_json);
    var released_desired = try std.json.parseFromSlice(
        orchestration.DesiredState,
        std.testing.allocator,
        released_json,
        .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
    );
    defer released_desired.deinit();
    try std.testing.expectEqual(@as(usize, 0), released_desired.value.accelerator_allocations.len);
}

test "lifecycle claims fence legacy placement and feature regression" {
    var registry = try Registry.open(std.testing.allocator, std.testing.io, ":memory:");
    defer registry.close();
    const lifecycle_features = [_][]const u8{
        heartbeat.feature_accelerator_requirements_v1,
        heartbeat.feature_accelerator_lifecycle_v1,
    };
    const lifecycle_report = lifecycleTestHeartbeat(&lifecycle_features);
    try recordLifecycleTestHeartbeat(&registry, lifecycle_report, 1000);
    try applyLifecycleTestDeployment(&registry, lifecycleTestDeployment("lifecycle"), 1100);

    const first_desired = (try registry.desiredStateForNode("gpu-edge", 1200)).?;
    defer std.testing.allocator.free(first_desired);
    var first = try std.json.parseFromSlice(
        orchestration.DesiredState,
        std.testing.allocator,
        first_desired,
        .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
    );
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 1), first.value.accelerator_allocations.len);
    const allocation_id = try std.testing.allocator.dupe(
        u8,
        first.value.accelerator_allocations[0].allocation_id,
    );
    defer std.testing.allocator.free(allocation_id);

    const repeated_desired = (try registry.desiredStateForNode("gpu-edge", 1210)).?;
    defer std.testing.allocator.free(repeated_desired);
    var repeated = try std.json.parseFromSlice(
        orchestration.DesiredState,
        std.testing.allocator,
        repeated_desired,
        .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
    );
    defer repeated.deinit();
    try std.testing.expectEqual(@as(usize, 1), repeated.value.accelerator_allocations.len);
    try std.testing.expectEqualStrings(
        allocation_id,
        repeated.value.accelerator_allocations[0].allocation_id,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        repeated.value.accelerator_allocations[0].generation,
    );

    const legacy_features = [_][]const u8{heartbeat.feature_accelerator_requirements_v1};
    const legacy_report = lifecycleTestHeartbeat(&legacy_features);
    try recordLifecycleTestHeartbeat(&registry, legacy_report, 1300);
    try applyLifecycleTestDeployment(&registry, lifecycleTestDeployment("legacy"), 1310);
    const downgraded_desired = (try registry.desiredStateForNode("gpu-edge", 1400)).?;
    defer std.testing.allocator.free(downgraded_desired);

    const lifecycle_inspect = (try registry.inspectDeployment("lifecycle")).?;
    defer std.testing.allocator.free(lifecycle_inspect);
    try std.testing.expect(std.mem.indexOf(
        u8,
        lifecycle_inspect,
        "\"reason_code\":\"agent_feature_regressed\"",
    ) != null);
    const legacy_inspect = (try registry.inspectDeployment("legacy")).?;
    defer std.testing.allocator.free(legacy_inspect);
    try std.testing.expect(std.mem.indexOf(
        u8,
        legacy_inspect,
        "\"reason_code\":\"accelerator_capacity_exhausted\"",
    ) != null);

    var legacy_reservations = try registry.prepare(
        "SELECT COUNT(*) FROM accelerator_reservations WHERE node_id='gpu-edge';",
    );
    defer legacy_reservations.finalize();
    try std.testing.expect(try legacy_reservations.row());
    try std.testing.expectEqual(@as(i64, 0), legacy_reservations.columnInt64(0));
}

test "failed accelerator generation can reconcile a newer rollback revision" {
    var registry = try Registry.open(std.testing.allocator, std.testing.io, ":memory:");
    defer registry.close();
    const features = [_][]const u8{
        heartbeat.feature_accelerator_requirements_v1,
        heartbeat.feature_accelerator_lifecycle_v1,
    };
    try recordLifecycleTestHeartbeat(&registry, lifecycleTestHeartbeat(&features), 1000);
    var deployment = lifecycleTestDeployment("vision-recovery");
    try applyLifecycleTestDeployment(&registry, deployment, 1100);

    const first_json = (try registry.desiredStateForNode("gpu-edge", 1200)).?;
    defer std.testing.allocator.free(first_json);
    var first = try std.json.parseFromSlice(
        orchestration.DesiredState,
        std.testing.allocator,
        first_json,
        .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
    );
    defer first.deinit();
    const first_command = first.value.accelerator_allocations[0];
    const allocation_id = try std.testing.allocator.dupe(u8, first_command.allocation_id);
    defer std.testing.allocator.free(allocation_id);
    var allocation_status: allocation.Status = .{
        .allocation_id = allocation_id,
        .generation = 1,
        .node_id = "gpu-edge",
        .deployment = "vision-recovery",
        .revision = 1,
        .phase = .pending,
        .observed_unix_ms = 1210,
    };
    const failure_phases = [_]allocation.ObservedPhase{
        allocation.ObservedPhase.pending,
        allocation.ObservedPhase.prepared,
        allocation.ObservedPhase.failed,
    };
    for (&failure_phases, 0..) |phase, index| {
        allocation_status.phase = phase;
        allocation_status.observed_unix_ms = 1210 + @as(i64, @intCast(index));
        try std.testing.expect(try registry.recordAllocationStatus(
            allocation_status,
            allocation_status.observed_unix_ms,
        ));
    }

    deployment.revision = 2;
    try applyLifecycleTestDeployment(&registry, deployment, 1300);
    const recovery_json = (try registry.desiredStateForNode("gpu-edge", 1400)).?;
    defer std.testing.allocator.free(recovery_json);
    var recovery = try std.json.parseFromSlice(
        orchestration.DesiredState,
        std.testing.allocator,
        recovery_json,
        .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
    );
    defer recovery.deinit();
    try std.testing.expectEqual(@as(usize, 1), recovery.value.accelerator_allocations.len);
    const command = recovery.value.accelerator_allocations[0];
    try std.testing.expectEqual(allocation.DesiredAction.run, command.action);
    try std.testing.expectEqual(@as(u64, 2), command.generation);
    try std.testing.expectEqual(@as(u64, 2), command.revision);
    try std.testing.expectEqualStrings(allocation_id, command.allocation_id);
}

test "delete and recreate cannot cancel a fenced release" {
    var registry = try Registry.open(std.testing.allocator, std.testing.io, ":memory:");
    defer registry.close();
    const features = [_][]const u8{
        heartbeat.feature_accelerator_requirements_v1,
        heartbeat.feature_accelerator_lifecycle_v1,
    };
    try recordLifecycleTestHeartbeat(&registry, lifecycleTestHeartbeat(&features), 1000);
    const deployment = lifecycleTestDeployment("vision");
    try applyLifecycleTestDeployment(&registry, deployment, 1100);

    const run_json = (try registry.desiredStateForNode("gpu-edge", 1200)).?;
    defer std.testing.allocator.free(run_json);
    var run_desired = try std.json.parseFromSlice(
        orchestration.DesiredState,
        std.testing.allocator,
        run_json,
        .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
    );
    defer run_desired.deinit();
    const allocation_id = try std.testing.allocator.dupe(
        u8,
        run_desired.value.accelerator_allocations[0].allocation_id,
    );
    defer std.testing.allocator.free(allocation_id);

    try std.testing.expect(try registry.deleteDeployment("vision", 1300));
    try applyLifecycleTestDeployment(&registry, deployment, 1310);
    const release_json = (try registry.desiredStateForNode("gpu-edge", 1400)).?;
    defer std.testing.allocator.free(release_json);
    var release_desired = try std.json.parseFromSlice(
        orchestration.DesiredState,
        std.testing.allocator,
        release_json,
        .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
    );
    defer release_desired.deinit();
    try std.testing.expectEqual(@as(usize, 1), release_desired.value.deployments.len);
    try std.testing.expectEqual(@as(usize, 1), release_desired.value.accelerator_allocations.len);
    const release = release_desired.value.accelerator_allocations[0];
    try std.testing.expectEqual(allocation.DesiredAction.release, release.action);
    try std.testing.expectEqual(@as(u64, 2), release.generation);
    try std.testing.expectEqualStrings(allocation_id, release.allocation_id);

    var release_status: allocation.Status = .{
        .allocation_id = allocation_id,
        .generation = 2,
        .node_id = "gpu-edge",
        .deployment = "vision",
        .revision = 1,
        .phase = .release_requested,
        .observed_unix_ms = 1410,
    };
    const release_phases = [_]allocation.ObservedPhase{
        .release_requested,
        .stopping,
        .released_ack_pending,
    };
    for (release_phases, 0..) |phase, index| {
        release_status.phase = phase;
        release_status.observed_unix_ms = 1410 + @as(i64, @intCast(index));
        try std.testing.expect(try registry.recordAllocationStatus(
            release_status,
            release_status.observed_unix_ms,
        ));
    }

    const replacement_json = (try registry.desiredStateForNode("gpu-edge", 1500)).?;
    defer std.testing.allocator.free(replacement_json);
    var replacement = try std.json.parseFromSlice(
        orchestration.DesiredState,
        std.testing.allocator,
        replacement_json,
        .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
    );
    defer replacement.deinit();
    try std.testing.expectEqual(@as(usize, 1), replacement.value.accelerator_allocations.len);
    try std.testing.expectEqual(
        allocation.DesiredAction.run,
        replacement.value.accelerator_allocations[0].action,
    );
    try std.testing.expectEqual(@as(u64, 3), replacement.value.accelerator_allocations[0].generation);
    try std.testing.expectEqualStrings(
        allocation_id,
        replacement.value.accelerator_allocations[0].allocation_id,
    );
}

test "allocation generation rejects invalid and exhausted counters" {
    try std.testing.expectEqual(@as(u64, 2), try nextAllocationGeneration(1));
    try std.testing.expectError(error.AllocationGenerationExhausted, nextAllocationGeneration(0));
    try std.testing.expectError(
        error.AllocationGenerationExhausted,
        nextAllocationGeneration(std.math.maxInt(i64)),
    );
}

test "heartbeat history is sampled and enrollment audit is not duplicated" {
    var registry = try Registry.open(std.testing.allocator, std.testing.io, ":memory:");
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
    try registry.recordHeartbeat(report, json, 2000);
    try registry.recordHeartbeat(report, json, heartbeat_sample_ms + 1000);

    var history = try registry.prepare("SELECT COUNT(*) FROM heartbeat_history;");
    defer history.finalize();
    try std.testing.expect(try history.row());
    try std.testing.expectEqual(@as(i64, 2), history.columnInt64(0));

    var audit = try registry.prepare("SELECT COUNT(*) FROM audit_events;");
    defer audit.finalize();
    try std.testing.expect(try audit.row());
    try std.testing.expectEqual(@as(i64, 1), audit.columnInt64(0));
}

test "node listing uses stable cursor pagination" {
    var registry = try Registry.open(std.testing.allocator, std.testing.io, ":memory:");
    defer registry.close();
    var report: heartbeat.Heartbeat = .{
        .node_id = "edge-01",
        .hostname = "edge-01",
        .role = "edge",
        .platform = .{
            .os = "linux",
            .arch = "x86_64",
            .abi = "gnu",
            .host_arch = "aarch64",
        },
        .resources = .{ .cpu_count = 4 },
        .timestamp_unix_ms = 1000,
    };
    inline for (.{ "edge-01", "edge-02", "edge-03" }) |node_id| {
        report.node_id = node_id;
        report.hostname = node_id;
        const json = try heartbeat.serializeAlloc(std.testing.allocator, report);
        defer std.testing.allocator.free(json);
        try registry.recordHeartbeat(report, json, 1000);
    }

    const first = try registry.listNodes(1000, 3000, 2, null);
    defer std.testing.allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"node_id\":\"edge-01\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"node_id\":\"edge-02\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"node_id\":\"edge-03\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"next_after\":\"edge-02\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"host_arch\":\"aarch64\"") != null);

    const second = try registry.listNodes(1000, 3000, 2, "edge-02");
    defer std.testing.allocator.free(second);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"node_id\":\"edge-03\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"next_after\":null") != null);
}

test "workload status history is retained for thirty days" {
    var registry = try Registry.open(std.testing.allocator, std.testing.io, ":memory:");
    defer registry.close();
    const report: heartbeat.Heartbeat = .{
        .node_id = "edge-01",
        .hostname = "edge-01",
        .role = "edge",
        .platform = .{ .os = "linux", .arch = "x86_64", .abi = "gnu" },
        .resources = .{ .cpu_count = 4 },
        .timestamp_unix_ms = 1000,
    };
    const heartbeat_json = try heartbeat.serializeAlloc(std.testing.allocator, report);
    defer std.testing.allocator.free(heartbeat_json);
    try registry.recordHeartbeat(report, heartbeat_json, 1000);

    const deployment: orchestration.Deployment = .{
        .name = "retention-test",
        .revision = 1,
        .runtime = .{ .kind = .process, .command = &.{"/bin/true"} },
        .targets = .{ .all = true },
    };
    const deployment_json = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        deployment,
        .{},
    );
    defer std.testing.allocator.free(deployment_json);
    try registry.applyDeployment(deployment, deployment_json, 1100);
    const desired = (try registry.desiredStateForNode("edge-01", 1200)).?;
    defer std.testing.allocator.free(desired);

    try std.testing.expect(try registry.recordWorkloadStatus(.{
        .node_id = "edge-01",
        .deployment = "retention-test",
        .revision = 1,
        .state = .healthy,
        .observed_unix_ms = 1300,
    }, 1300));
    const recent = workload_status_retention_ms + 2300;
    try std.testing.expect(try registry.recordWorkloadStatus(.{
        .node_id = "edge-01",
        .deployment = "retention-test",
        .revision = 1,
        .state = .healthy,
        .observed_unix_ms = recent,
    }, recent));

    var history = try registry.prepare("SELECT COUNT(*) FROM workload_status_history;");
    defer history.finalize();
    try std.testing.expect(try history.row());
    try std.testing.expectEqual(@as(i64, 1), history.columnInt64(0));
}

test "desired state rolls out in waves and automatically rolls back" {
    var registry = try Registry.open(std.testing.allocator, std.testing.io, ":memory:");
    defer registry.close();

    const first_node: heartbeat.Heartbeat = .{
        .node_id = "edge-01",
        .hostname = "edge-01",
        .role = "smart-class",
        .labels = &.{
            .{ .key = "site", .value = "school-a" },
            .{ .key = "device", .value = "desktop" },
        },
        .platform = .{ .os = "linux", .arch = "x86_64", .abi = "gnu" },
        .resources = .{ .cpu_count = 4 },
        .timestamp_unix_ms = 1000,
    };
    var second_node = first_node;
    second_node.node_id = "edge-02";
    second_node.hostname = "edge-02";
    const first_json = try heartbeat.serializeAlloc(std.testing.allocator, first_node);
    defer std.testing.allocator.free(first_json);
    const second_json = try heartbeat.serializeAlloc(std.testing.allocator, second_node);
    defer std.testing.allocator.free(second_json);
    try registry.recordHeartbeat(first_node, first_json, 1000);
    try registry.recordHeartbeat(second_node, second_json, 1001);

    const revision_one: orchestration.Deployment = .{
        .name = "vision",
        .revision = 1,
        .runtime = .{ .kind = .process, .command = &.{ "/bin/echo", "vision" } },
        .targets = .{ .labels = &.{
            .{ .key = "site", .value = "school-a" },
            .{ .key = "device", .value = "desktop" },
        } },
        .rollout = .{ .batch_size = 1, .max_unavailable = 1, .pause_seconds = 1 },
    };
    const revision_one_json = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        revision_one,
        .{},
    );
    defer std.testing.allocator.free(revision_one_json);
    try registry.applyDeployment(revision_one, revision_one_json, 2000);

    const first_desired = (try registry.desiredStateForNode("edge-01", 2100)).?;
    defer std.testing.allocator.free(first_desired);
    try std.testing.expect(std.mem.indexOf(u8, first_desired, "\"name\":\"vision\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_desired, "\"revision\":1") != null);

    var relabeled_second = second_node;
    relabeled_second.labels = &.{
        .{ .key = "site", .value = "school-b" },
        .{ .key = "device", .value = "desktop" },
    };
    const relabeled_json = try heartbeat.serializeAlloc(std.testing.allocator, relabeled_second);
    defer std.testing.allocator.free(relabeled_json);
    try registry.recordHeartbeat(relabeled_second, relabeled_json, 2101);

    const second_pending = (try registry.desiredStateForNode("edge-02", 2102)).?;
    defer std.testing.allocator.free(second_pending);
    try std.testing.expect(std.mem.indexOf(u8, second_pending, "\"name\":\"vision\"") == null);

    try std.testing.expect(try registry.recordWorkloadStatus(.{
        .node_id = "edge-01",
        .deployment = "vision",
        .revision = 1,
        .state = .healthy,
        .observed_unix_ms = 2200,
    }, 2200));
    const paused = (try registry.inspectDeployment("vision")).?;
    defer std.testing.allocator.free(paused);
    try std.testing.expect(std.mem.indexOf(u8, paused, "\"status\":\"paused\"") != null);

    const second_waits = (try registry.desiredStateForNode("edge-02", 2201)).?;
    defer std.testing.allocator.free(second_waits);
    try std.testing.expect(std.mem.indexOf(u8, second_waits, "\"name\":\"vision\"") == null);
    try std.testing.expect(try registry.recordWorkloadStatus(.{
        .node_id = "edge-01",
        .deployment = "vision",
        .revision = 1,
        .state = .healthy,
        .observed_unix_ms = 3200,
    }, 3200));
    const second_desired = (try registry.desiredStateForNode("edge-02", 3201)).?;
    defer std.testing.allocator.free(second_desired);
    try std.testing.expect(std.mem.indexOf(u8, second_desired, "\"revision\":1") != null);

    try registry.recordHeartbeat(second_node, second_json, 3900);

    var revision_two = revision_one;
    revision_two.revision = 2;
    revision_two.runtime.command = &.{ "/bin/echo", "vision-v2" };
    const revision_two_json = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        revision_two,
        .{},
    );
    defer std.testing.allocator.free(revision_two_json);
    try registry.applyDeployment(revision_two, revision_two_json, 4000);

    const first_upgrade = (try registry.desiredStateForNode("edge-01", 4100)).?;
    defer std.testing.allocator.free(first_upgrade);
    try std.testing.expect(std.mem.indexOf(u8, first_upgrade, "\"revision\":2") != null);
    const second_holds = (try registry.desiredStateForNode("edge-02", 4101)).?;
    defer std.testing.allocator.free(second_holds);
    try std.testing.expect(std.mem.indexOf(u8, second_holds, "\"revision\":1") != null);

    try std.testing.expect(try registry.recordWorkloadStatus(.{
        .node_id = "edge-01",
        .deployment = "vision",
        .revision = 2,
        .state = .failed,
        .message = "health check failed",
        .observed_unix_ms = 4200,
    }, 4200));
    const rolled_back = (try registry.desiredStateForNode("edge-01", 4201)).?;
    defer std.testing.allocator.free(rolled_back);
    try std.testing.expect(std.mem.indexOf(u8, rolled_back, "\"revision\":1") != null);

    const inspected = (try registry.inspectDeployment("vision")).?;
    defer std.testing.allocator.free(inspected);
    try std.testing.expect(std.mem.indexOf(u8, inspected, "\"status\":\"rolled_back\"") != null);
}
