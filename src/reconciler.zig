const std = @import("std");
const client = @import("client.zig");
const orchestration = @import("orchestration.zig");
const runtime = @import("runtime.zig");
const shutdown = @import("shutdown.zig");

const LocalState = struct {
    schema_version: u8 = 1,
    applied: []const runtime.AppliedRecord = &.{},
};

pub const Options = struct {
    server: []const u8,
    node_id: []const u8,
    token: ?[]const u8,
    runtime_options: runtime.Options,
};

pub fn reconcileOnce(init: std.process.Init, options: Options) !void {
    var status_delivery_failed = false;
    const desired_url = try endpointAlloc(init.gpa, options.server, options.node_id, "desired-state");
    defer init.gpa.free(desired_url);
    const response_buffer = try init.gpa.alloc(u8, 4 * 1024 * 1024);
    defer init.gpa.free(response_buffer);
    const result = try client.getJson(init, desired_url, options.token, response_buffer);
    if (result.status != .ok) return error.DesiredStateRejected;

    var desired = try std.json.parseFromSlice(orchestration.DesiredState, init.gpa, result.response_body, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    });
    defer desired.deinit();
    if (desired.value.schema_version != orchestration.schema_version or
        !std.mem.eql(u8, desired.value.node_id, options.node_id))
        return error.InvalidDesiredState;
    for (desired.value.deployments) |deployment| {
        if (!orchestration.validateDeployment(deployment)) return error.InvalidDesiredState;
    }

    const state_path = try std.fmt.allocPrint(
        init.gpa,
        "{s}/applied.json",
        .{options.runtime_options.state_dir},
    );
    defer init.gpa.free(state_path);
    const state_bytes: ?[]u8 = readStateAlloc(init, state_path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (state_bytes) |bytes| init.gpa.free(bytes);
    var parsed_state: ?std.json.Parsed(LocalState) = if (state_bytes) |bytes|
        try std.json.parseFromSlice(LocalState, init.gpa, bytes, .{
            .ignore_unknown_fields = false,
            .allocate = .alloc_always,
        })
    else
        null;
    defer if (parsed_state) |*parsed| parsed.deinit();
    const previous: LocalState = if (parsed_state) |parsed| parsed.value else .{};
    if (previous.schema_version != 1) return error.UnsupportedLocalState;

    var next: std.ArrayList(runtime.AppliedRecord) = .empty;
    defer next.deinit(init.gpa);
    var owned_specs: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_specs.items) |spec| init.gpa.free(spec);
        owned_specs.deinit(init.gpa);
    }

    for (desired.value.deployments) |deployment| {
        const old = findApplied(previous.applied, deployment.name);
        if (deployment.desired == .stopped) {
            if (old) |record| runtime.stop(init, record) catch |err| {
                try next.append(init.gpa, record);
                report(init, options, deployment, .failed, @errorName(err)) catch {
                    status_delivery_failed = true;
                };
                continue;
            };
            report(init, options, deployment, .stopped, "desired state is stopped") catch {
                status_delivery_failed = true;
            };
            continue;
        }

        if (!options.runtime_options.enabled.allows(deployment.runtime.kind)) {
            if (old) |record| try next.append(init.gpa, record);
            report(init, options, deployment, .blocked, "runtime is not enabled by the agent") catch {
                status_delivery_failed = true;
            };
            continue;
        }

        if (old) |record| {
            if (record.revision == deployment.revision and record.runtime == deployment.runtime.kind) {
                const healthy = runtime.healthCheck(init, deployment, record) catch false;
                if (healthy) {
                    try next.append(init.gpa, record);
                    report(init, options, deployment, .healthy, "desired revision is healthy") catch {
                        status_delivery_failed = true;
                    };
                    continue;
                }
                if (deployment.restart_policy == .never) {
                    try next.append(init.gpa, record);
                    report(init, options, deployment, .failed, "health check failed and restart is disabled") catch {
                        status_delivery_failed = true;
                    };
                    continue;
                }
            }
        }

        report(init, options, deployment, .applying, "applying desired revision") catch {
            status_delivery_failed = true;
        };
        if (old) |record| runtime.stop(init, record) catch |err| {
            try next.append(init.gpa, record);
            report(init, options, deployment, .failed, @errorName(err)) catch {
                status_delivery_failed = true;
            };
            continue;
        };

        const applied = applyAndVerify(init, deployment, options.runtime_options, &owned_specs) catch |err| {
            if (old) |record| {
                if (try restorePrevious(init, record, options.runtime_options)) |restored|
                    try next.append(init.gpa, restored);
            }
            report(init, options, deployment, .failed, @errorName(err)) catch {
                status_delivery_failed = true;
            };
            continue;
        };
        try next.append(init.gpa, applied);
        report(init, options, deployment, .healthy, "desired revision is healthy") catch {
            status_delivery_failed = true;
        };
    }

    for (previous.applied) |record| {
        if (desiredContains(desired.value.deployments, record.name)) continue;
        runtime.stop(init, record) catch {
            try next.append(init.gpa, record);
        };
    }

    try saveState(init, state_path, .{ .applied = next.items });
    if (status_delivery_failed) return error.StatusDeliveryFailed;
}

fn applyAndVerify(
    init: std.process.Init,
    deployment: orchestration.Deployment,
    options: runtime.Options,
    owned_specs: *std.ArrayList([]u8),
) !runtime.AppliedRecord {
    const artifact_path = try runtime.prepareArtifact(init, deployment, options);
    defer if (artifact_path) |path| init.gpa.free(path);
    const runtime_result = try runtime.apply(init, deployment, artifact_path);
    const spec_json = try std.json.Stringify.valueAlloc(init.gpa, deployment, .{});
    errdefer init.gpa.free(spec_json);
    const record: runtime.AppliedRecord = .{
        .name = deployment.name,
        .revision = deployment.revision,
        .runtime = deployment.runtime.kind,
        .reference = deployment.runtime.reference,
        .pid = runtime_result.pid,
        .process_start_ticks = runtime_result.process_start_ticks,
        .spec_json = spec_json,
    };
    if (!try healthyWithRetries(init, deployment, record)) {
        try runtime.stop(init, record);
        return error.HealthCheckFailed;
    }
    try owned_specs.append(init.gpa, spec_json);
    return record;
}

fn healthyWithRetries(
    init: std.process.Init,
    deployment: orchestration.Deployment,
    record: runtime.AppliedRecord,
) !bool {
    var attempt: u8 = 0;
    while (attempt < deployment.health_check.failure_threshold) : (attempt += 1) {
        if (try runtime.healthCheck(init, deployment, record)) return true;
        if (attempt + 1 < deployment.health_check.failure_threshold)
            try shutdown.sleepInterruptible(init.io, 1000);
    }
    return false;
}

fn restorePrevious(
    init: std.process.Init,
    old: runtime.AppliedRecord,
    options: runtime.Options,
) !?runtime.AppliedRecord {
    var parsed = std.json.parseFromSlice(orchestration.Deployment, init.gpa, old.spec_json, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    }) catch return null;
    defer parsed.deinit();
    if (!orchestration.validateDeployment(parsed.value) or
        !options.enabled.allows(parsed.value.runtime.kind)) return null;
    const artifact_path = runtime.prepareArtifact(init, parsed.value, options) catch return null;
    defer if (artifact_path) |path| init.gpa.free(path);
    const runtime_result = runtime.apply(init, parsed.value, artifact_path) catch return null;
    var restored = old;
    restored.pid = runtime_result.pid;
    restored.process_start_ticks = runtime_result.process_start_ticks;
    return restored;
}

fn report(
    init: std.process.Init,
    options: Options,
    deployment: orchestration.Deployment,
    state: orchestration.ObservedState,
    message: []const u8,
) !void {
    const status_url = try endpointAlloc(init.gpa, options.server, options.node_id, "workload-status");
    defer init.gpa.free(status_url);
    const bounded_message = message[0..@min(message.len, 1024)];
    const value: orchestration.StatusReport = .{
        .node_id = options.node_id,
        .deployment = deployment.name,
        .revision = deployment.revision,
        .state = state,
        .message = bounded_message,
        .observed_unix_ms = std.Io.Clock.real.now(init.io).toMilliseconds(),
    };
    const payload = try std.json.Stringify.valueAlloc(init.gpa, value, .{});
    defer init.gpa.free(payload);
    var response_buffer: [4096]u8 = undefined;
    const result = try client.postJson(init, status_url, payload, options.token, &response_buffer);
    if (result.status != .accepted) return error.StatusReportRejected;
}

pub fn endpointAlloc(
    allocator: std.mem.Allocator,
    server: []const u8,
    node_id: []const u8,
    subresource: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/v1/nodes/{s}/{s}",
        .{ std.mem.trimEnd(u8, server, "/"), node_id, subresource },
    );
}

fn findApplied(records: []const runtime.AppliedRecord, name: []const u8) ?runtime.AppliedRecord {
    for (records) |record| {
        if (std.mem.eql(u8, record.name, name)) return record;
    }
    return null;
}

fn desiredContains(deployments: []const orchestration.Deployment, name: []const u8) bool {
    for (deployments) |deployment| {
        if (std.mem.eql(u8, deployment.name, name)) return true;
    }
    return false;
}

fn readStateAlloc(init: std.process.Init, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(init.io, &read_buffer);
    return reader.interface.allocRemaining(init.gpa, .limited(16 * 1024 * 1024));
}

fn saveState(init: std.process.Init, path: []const u8, state: LocalState) !void {
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(init.io, parent);
    const payload = try std.json.Stringify.valueAlloc(init.gpa, state, .{});
    defer init.gpa.free(payload);
    var atomic = try std.Io.Dir.cwd().createFileAtomic(init.io, path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(init.io);
    var write_buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(init.io, &write_buffer);
    try writer.interface.writeAll(payload);
    try writer.interface.flush();
    try atomic.file.sync(init.io);
    try atomic.replace(init.io);
}

test "orchestration endpoints are derived from the server URL" {
    const value = try endpointAlloc(
        std.testing.allocator,
        "http://127.0.0.1:8080/",
        "edge-01",
        "desired-state",
    );
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:8080/v1/nodes/edge-01/desired-state",
        value,
    );
}
