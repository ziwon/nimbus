const std = @import("std");
const accelerator = @import("accelerator.zig");
const accelerator_agent = @import("accelerator_agent.zig");
const allocation = @import("allocation.zig");
const client = @import("client.zig");
const orchestration = @import("orchestration.zig");
const reservation = @import("reservation.zig");
const runtime = @import("runtime.zig");
const shutdown = @import("shutdown.zig");

const LocalState = struct {
    schema_version: u8 = 2,
    applied: []const runtime.AppliedRecord = &.{},
    accelerator_reservations: reservation.Ledger = .{},
};

pub const Options = struct {
    server: []const u8,
    node_id: []const u8,
    token: ?[]const u8,
    runtime_options: runtime.Options,
    accelerator_inventory: *const accelerator.Inventory,
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
    var desired_reservations = try reservation.fromAssignments(
        init.gpa,
        desired.value.accelerator_assignments,
    );
    defer desired_reservations.deinit();
    if (!validDesiredReservations(desired.value, options.accelerator_inventory.report()) or
        !validDesiredAllocations(desired.value, options.accelerator_inventory.report()))
        return error.InvalidDesiredState;

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
    if (previous.schema_version != 1 and previous.schema_version != 2)
        return error.UnsupportedLocalState;
    try reservation.validate(previous.accelerator_reservations);

    for (desired.value.accelerator_allocations) |command| {
        if (command.action != .run) continue;
        if (findApplied(previous.applied, command.deployment) != null)
            return error.LegacyRuntimeConflict;
    }
    try accelerator_agent.reconcileDesired(init, .{
        .server = options.server,
        .node_id = options.node_id,
        .token = options.token,
        .runtime_options = options.runtime_options,
        .inventory = options.accelerator_inventory,
    }, desired.value);

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
            if (old != null)
                runtime.releaseArtifactPin(
                    init,
                    options.runtime_options,
                    deployment.name,
                ) catch |err| {
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

        if (deployment.resources != null) {
            if (findRunAllocation(
                desired.value.accelerator_allocations,
                deployment.name,
            ) != null) continue;
            if (old) |record| try next.append(init.gpa, record);
            const block_reason = if (findAssignment(
                desired.value.accelerator_assignments,
                deployment.name,
            ) == null)
                "accelerator_assignment_unavailable"
            else
                "runtime_device_injection_unavailable";
            report(
                init,
                options,
                deployment,
                .blocked,
                block_reason,
            ) catch {
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

        const preflight_path = runtime.preflightArtifact(
            init,
            deployment,
            options.runtime_options,
        ) catch |err| {
            if (old) |record| try next.append(init.gpa, record);
            report(init, options, deployment, .failed, @errorName(err)) catch {
                status_delivery_failed = true;
            };
            continue;
        };
        defer if (preflight_path) |path| init.gpa.free(path);

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
        if (old != null)
            runtime.releaseArtifactPin(
                init,
                options.runtime_options,
                deployment.name,
            ) catch |err| {
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
            continue;
        };
        runtime.releaseArtifactPin(init, options.runtime_options, record.name) catch {};
    }

    try saveState(init, state_path, .{
        .applied = next.items,
        .accelerator_reservations = desired_reservations.view(),
    });
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

fn validDesiredReservations(
    desired: orchestration.DesiredState,
    inventory: accelerator.InventoryReport,
) bool {
    for (desired.deployments) |deployment| {
        const assignment = findAssignment(
            desired.accelerator_assignments,
            deployment.name,
        );
        const resources = deployment.resources orelse {
            if (assignment != null) return false;
            continue;
        };
        if (deployment.desired == .stopped) {
            if (assignment != null) return false;
            continue;
        }
        const selected = assignment orelse continue;
        if (!orchestration.validateAcceleratorAssignment(selected) or
            selected.revision != deployment.revision or
            selected.device_ids.len != resources.accelerators.count or
            inventory.status == .unavailable)
            return false;
        for (selected.device_ids) |device_id| {
            var matched = false;
            for (inventory.accelerators) |device| {
                if (!std.mem.eql(u8, device.id, device_id)) continue;
                matched = accelerator.matchesRequirement(device, resources.accelerators);
                break;
            }
            if (!matched) return false;
        }
    }
    for (desired.accelerator_assignments) |assignment| {
        var found = false;
        for (desired.deployments) |deployment| {
            if (!std.mem.eql(u8, deployment.name, assignment.deployment)) continue;
            found = true;
            break;
        }
        if (!found) return false;
    }
    return true;
}

fn validDesiredAllocations(
    desired: orchestration.DesiredState,
    inventory: accelerator.InventoryReport,
) bool {
    if (desired.accelerator_allocations.len > 0 and
        desired.accelerator_assignments.len > 0)
        return false;

    for (desired.accelerator_allocations, 0..) |command, index| {
        allocation.validateDesired(command) catch return false;
        for (desired.accelerator_allocations[0..index]) |previous| {
            if (std.mem.eql(u8, previous.allocation_id, command.allocation_id) or
                std.mem.eql(u8, previous.deployment, command.deployment))
                return false;
            const previous_ids = if (previous.action == .run)
                previous.target_device_ids
            else
                previous.retiring_device_ids;
            const current_ids = if (command.action == .run)
                command.target_device_ids
            else
                command.retiring_device_ids;
            for (previous_ids) |previous_id| {
                for (current_ids) |current_id| {
                    if (std.mem.eql(u8, previous_id, current_id)) return false;
                }
            }
        }

        if (command.action == .release) continue;
        const deployment = findDeployment(
            desired.deployments,
            command.deployment,
        ) orelse return false;
        const resources = deployment.resources orelse return false;
        if (deployment.desired != .running or
            deployment.revision != command.revision or
            resources.accelerators.count != command.target_device_ids.len)
            return false;

        for (command.target_device_ids) |device_id| {
            var found = false;
            for (inventory.accelerators) |device| {
                if (!std.mem.eql(u8, device.id, device_id)) continue;
                if (!accelerator.matchesRequirement(device, resources.accelerators))
                    return false;
                found = true;
                break;
            }
            if (!found and inventory.status == .complete) return false;
        }
    }
    return true;
}

fn findDeployment(
    deployments: []const orchestration.Deployment,
    name: []const u8,
) ?orchestration.Deployment {
    for (deployments) |deployment| {
        if (std.mem.eql(u8, deployment.name, name)) return deployment;
    }
    return null;
}

fn findAssignment(
    assignments: []const orchestration.AcceleratorAssignment,
    deployment_name: []const u8,
) ?orchestration.AcceleratorAssignment {
    for (assignments) |assignment| {
        if (std.mem.eql(u8, assignment.deployment, deployment_name)) return assignment;
    }
    return null;
}

fn findRunAllocation(
    allocations: []const allocation.DesiredAllocation,
    deployment_name: []const u8,
) ?allocation.DesiredAllocation {
    for (allocations) |command| {
        if (command.action == .run and
            std.mem.eql(u8, command.deployment, deployment_name)) return command;
    }
    return null;
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

test "desired accelerator assignments are verified against the heartbeat snapshot" {
    const devices = [_]accelerator.Device{.{
        .id = "gpu:nvidia:a",
        .kind = .gpu,
        .vendor = "NVIDIA",
        .model = "L4",
        .source = "fixture",
        .memory_total_bytes = 24 * 1024 * 1024 * 1024,
        .capabilities = &.{"fp16"},
    }};
    const inventory: accelerator.InventoryReport = .{
        .status = .complete,
        .accelerators = &devices,
        .probes = &.{},
    };
    const deployments = [_]orchestration.Deployment{.{
        .name = "vision",
        .revision = 2,
        .runtime = .{ .kind = .process, .command = &.{"/bin/true"} },
        .resources = .{ .accelerators = .{
            .kind = .gpu,
            .vendor = "nvidia",
            .capabilities = &.{"fp16"},
        } },
        .targets = .{ .all = true },
    }};
    const assignments = [_]orchestration.AcceleratorAssignment{.{
        .deployment = "vision",
        .revision = 2,
        .device_ids = &.{"gpu:nvidia:a"},
    }};
    const desired: orchestration.DesiredState = .{
        .node_id = "edge-01",
        .generation = 1,
        .deployments = &deployments,
        .accelerator_assignments = &assignments,
    };
    try std.testing.expect(validDesiredReservations(desired, inventory));

    var without_assignment = desired;
    without_assignment.accelerator_assignments = &.{};
    try std.testing.expect(validDesiredReservations(without_assignment, inventory));

    var wrong_revision = assignments;
    wrong_revision[0].revision = 1;
    var invalid = desired;
    invalid.accelerator_assignments = &wrong_revision;
    try std.testing.expect(!validDesiredReservations(invalid, inventory));

    var missing_device = assignments;
    missing_device[0].device_ids = &.{"gpu:nvidia:missing"};
    invalid.accelerator_assignments = &missing_device;
    try std.testing.expect(!validDesiredReservations(invalid, inventory));
}

test "fenced allocation validation separates run and release trust boundaries" {
    const devices = [_]accelerator.Device{.{
        .id = "gpu:nvidia:a",
        .kind = .gpu,
        .vendor = "NVIDIA",
        .model = "L4",
        .source = "fixture",
        .capabilities = &.{"fp16"},
    }};
    const inventory: accelerator.InventoryReport = .{
        .status = .complete,
        .accelerators = &devices,
        .probes = &.{},
    };
    const deployments = [_]orchestration.Deployment{.{
        .name = "vision",
        .revision = 3,
        .runtime = .{ .kind = .docker, .reference = "example/vision@sha256:" ++ ("ab" ** 32) },
        .resources = .{ .accelerators = .{
            .kind = .gpu,
            .vendor = "nvidia",
            .capabilities = &.{"fp16"},
        } },
        .targets = .{ .all = true },
    }};
    const run = [_]allocation.DesiredAllocation{.{
        .allocation_id = "alloc-vision",
        .generation = 1,
        .deployment = "vision",
        .revision = 3,
        .action = .run,
        .target_device_ids = &.{"gpu:nvidia:a"},
    }};
    const desired: orchestration.DesiredState = .{
        .node_id = "edge-01",
        .generation = 1,
        .deployments = &deployments,
        .accelerator_allocations = &run,
    };
    try std.testing.expect(validDesiredAllocations(desired, inventory));

    var stale = run;
    stale[0].revision = 2;
    var invalid = desired;
    invalid.accelerator_allocations = &stale;
    try std.testing.expect(!validDesiredAllocations(invalid, inventory));

    const release = [_]allocation.DesiredAllocation{.{
        .allocation_id = "alloc-vision",
        .generation = 2,
        .deployment = "vision",
        .revision = 3,
        .action = .release,
        .retiring_device_ids = &.{"gpu:nvidia:a"},
    }};
    const deleted: orchestration.DesiredState = .{
        .node_id = "edge-01",
        .generation = 2,
        .deployments = &.{},
        .accelerator_allocations = &release,
    };
    const unavailable: accelerator.InventoryReport = .{
        .status = .unavailable,
        .accelerators = &.{},
        .probes = &.{},
    };
    try std.testing.expect(validDesiredAllocations(deleted, unavailable));
}
