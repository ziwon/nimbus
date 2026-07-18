const std = @import("std");
const heartbeat = @import("heartbeat.zig");
const orchestration = @import("orchestration.zig");
const c = @cImport({
    @cInclude("sqlite3.h");
});

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
            if (db_optional) |db| _ = c.sqlite3_close(db);
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
            \\CREATE TABLE IF NOT EXISTS node_labels (
            \\  node_id TEXT NOT NULL REFERENCES nodes(node_id) ON DELETE CASCADE,
            \\  label_key TEXT NOT NULL,
            \\  label_value TEXT NOT NULL,
            \\  PRIMARY KEY (node_id, label_key)
            \\);
            \\CREATE INDEX IF NOT EXISTS node_labels_lookup
            \\  ON node_labels(label_key, label_value, node_id);
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
            \\  VALUES (1, 0), (2, 0);
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
    }

    pub fn recordHeartbeat(
        self: *Registry,
        report: heartbeat.Heartbeat,
        report_json: []const u8,
        received_unix_ms: i64,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
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
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
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
        try output.appendSlice(self.allocator, "]}\n");
        return try output.toOwnedSlice(self.allocator);
    }

    pub fn deleteDeployment(self: *Registry, name: []const u8, now_unix_ms: i64) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};
        var statement = try self.prepare("DELETE FROM deployments WHERE name=?;");
        defer statement.finalize();
        try statement.bindText(1, name);
        try statement.done();
        const deleted = c.sqlite3_changes(self.db) > 0;
        if (deleted) try self.audit(now_unix_ms, "", "deployment.deleted", name);
        try self.exec("COMMIT;");
        return deleted;
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
        {
            var node = try self.prepare("SELECT role FROM nodes WHERE node_id=?;");
            defer node.finalize();
            try node.bindText(1, node_id);
            if (!try node.row()) return null;
            role_value = try self.allocator.dupe(u8, node.columnText(0));
        }

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

        var first = true;
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

            const wave = try self.getOrCreateAssignmentWave(
                name,
                node_id,
                batch_size,
                current_wave,
                rollout_status,
                now_unix_ms,
            );
            const selected = if (wave <= current_wave) current_spec else previous_spec orelse continue;
            if (!first) try output.append(self.allocator, ',');
            first = false;
            try output.appendSlice(self.allocator, selected);
        }
        try output.appendSlice(self.allocator, "]}\n");
        try self.exec("COMMIT;");
        return try output.toOwnedSlice(self.allocator);
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

        if (report.state == .failed or report.state == .degraded) {
            try self.handleUnavailable(report.deployment, received_unix_ms);
        } else if (report.state == .healthy or report.state == .stopped) {
            try self.maybeAdvanceRollout(report.deployment, received_unix_ms);
        }

        try self.audit(received_unix_ms, report.node_id, "workload.status", @tagName(report.state));
        try self.exec("COMMIT;");
        return true;
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
    wave: u64,
    state: []const u8,
    observed_revision: u64,
    message: []const u8,
    updated_unix_ms: i64,
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

    fn columnIsNull(self: *Statement, index: c_int) bool {
        return c.sqlite3_column_type(self.handle, index) == c.SQLITE_NULL;
    }
};

fn status(now_unix_ms: i64, last_seen_unix_ms: i64, stale_after_ms: i64) []const u8 {
    return if (now_unix_ms - last_seen_unix_ms > stale_after_ms) "stale" else "online";
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

    const nodes = try registry.listNodes(4001, 3000);
    defer std.testing.allocator.free(nodes);
    try std.testing.expect(std.mem.indexOf(u8, nodes, "\"node_id\":\"edge-01\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, nodes, "\"status\":\"stale\"") != null);
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
