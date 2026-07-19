const std = @import("std");
const builtin = @import("builtin");
const accelerator = @import("accelerator.zig");
const accelerator_reconciler = @import("accelerator_reconciler.zig");
const accelerator_runtime = @import("accelerator_runtime.zig");
const agent_journal = @import("agent_journal.zig");
const allocation = @import("allocation.zig");
const artifact_selector = @import("artifact_selector.zig");
const client = @import("client.zig");
const device_access = @import("device_access.zig");
const orchestration = @import("orchestration.zig");
const runtime = @import("runtime.zig");
const shutdown = @import("shutdown.zig");

pub const journal_file_name = "accelerator-journal.json";

pub const Options = struct {
    server: []const u8,
    node_id: []const u8,
    token: ?[]const u8,
    runtime_options: runtime.Options,
    inventory: *const accelerator.Inventory,
};

const StatusResponse = struct {
    accepted: bool,
    released: bool = false,
};

const Context = struct {
    init: std.process.Init,
    token: ?[]const u8,
    status_url: []const u8,
    journal_path: []const u8,
    runtime_options: runtime.Options,
    inventory: *const accelerator.Inventory,
};

/// Apply all fenced accelerator commands in a desired-state snapshot. Releases
/// run first so a failed stop can never be followed by a conflicting start.
pub fn reconcileDesired(
    init: std.process.Init,
    options: Options,
    desired: orchestration.DesiredState,
) !void {
    if (desired.accelerator_allocations.len == 0) return;

    const journal_path = try std.fmt.allocPrint(
        init.gpa,
        "{s}/{s}",
        .{ options.runtime_options.state_dir, journal_file_name },
    );
    defer init.gpa.free(journal_path);
    var journal = agent_journal.Journal.load(
        init.gpa,
        init.io,
        std.Io.Dir.cwd(),
        journal_path,
    ) catch |err| switch (err) {
        error.FileNotFound => agent_journal.Journal.init(init.gpa),
        else => return err,
    };
    defer journal.deinit();

    const status_url = try endpointAlloc(
        init.gpa,
        options.server,
        options.node_id,
    );
    defer init.gpa.free(status_url);
    var context: Context = .{
        .init = init,
        .token = options.token,
        .status_url = status_url,
        .journal_path = journal_path,
        .runtime_options = options.runtime_options,
        .inventory = options.inventory,
    };
    const hooks = productionHooks(&context);

    for (desired.accelerator_allocations) |command| {
        if (command.action != .release) continue;
        try accelerator_reconciler.reconcileCommand(
            init.gpa,
            &journal,
            options.node_id,
            command,
            null,
            null,
            hooks,
        );
    }

    const inventory_report = options.inventory.report();
    const inventory_ids = try init.gpa.alloc([]const u8, inventory_report.accelerators.len);
    defer init.gpa.free(inventory_ids);
    for (inventory_report.accelerators, 0..) |device, index|
        inventory_ids[index] = device.id;

    for (desired.accelerator_allocations) |command| {
        if (command.action != .run) continue;
        const deployment = findDeployment(desired.deployments, command.deployment) orelse
            return error.MissingRunDeployment;
        if (!options.runtime_options.enabled.allows(deployment.runtime.kind))
            return error.RuntimeNotEnabled;

        var plan = switch (deployment.runtime.kind) {
            .docker, .containerd => try device_access.resolveAlloc(
                init.gpa,
                inventory_ids,
                options.inventory.accessCatalog(),
                command.target_device_ids,
                .cdi_only,
            ),
            .process, .systemd => try device_access.resolveHostAlloc(
                init.gpa,
                inventory_ids,
                options.inventory.accessCatalog(),
                command.target_device_ids,
            ),
        };
        defer plan.deinit();
        try accelerator_reconciler.reconcileCommand(
            init.gpa,
            &journal,
            options.node_id,
            command,
            deployment,
            plan.view(),
            hooks,
        );
    }
}

pub fn endpointAlloc(
    allocator: std.mem.Allocator,
    server: []const u8,
    node_id: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/v1/nodes/{s}/allocation-status",
        .{ std.mem.trimEnd(u8, server, "/"), node_id },
    );
}

fn productionHooks(context: *Context) accelerator_reconciler.Hooks {
    return .{
        .context = context,
        .now_fn = now,
        .persist_fn = persist,
        .report_fn = report,
        .select_artifact_fn = selectArtifact,
        .preflight_fn = preflight,
        .inspect_fn = inspect,
        .start_fn = start,
        .stop_fn = stop,
        .healthy_fn = healthy,
        .deinit_handle_fn = deinitHandle,
    };
}

fn selectArtifact(
    raw_context: ?*anyopaque,
    allocator: std.mem.Allocator,
    deployment: orchestration.Deployment,
    plan: device_access.Plan,
) !?[]u8 {
    const context = contextFromOpaque(raw_context);
    var selected: [accelerator.max_device_count]accelerator.Device = undefined;
    try selectedDevices(context, plan, &selected);
    const selection = (try artifact_selector.select(deployment, .{
        .os = @tagName(builtin.target.os.tag),
        .arch = @tagName(builtin.target.cpu.arch),
        .abi = @tagName(builtin.target.abi),
        .accelerators = selected[0..plan.device_ids.len],
    })) orelse return null;
    const name = selection.variant_name orelse return null;
    return @as(?[]u8, try allocator.dupe(u8, name));
}

fn preflight(
    raw_context: ?*anyopaque,
    deployment: orchestration.Deployment,
    plan: device_access.Plan,
    variant_name: ?[]const u8,
) !void {
    const context = contextFromOpaque(raw_context);
    var selected: [accelerator.max_device_count]accelerator.Device = undefined;
    try selectedDevices(context, plan, &selected);
    const artifact_path = try runtime.preflightArtifactVariantFor(
        context.init,
        deployment,
        context.runtime_options,
        selected[0..plan.device_ids.len],
        variant_name,
    );
    if (artifact_path) |path| context.init.gpa.free(path);
}

fn contextFromOpaque(raw_context: ?*anyopaque) *Context {
    return @ptrCast(@alignCast(raw_context orelse unreachable));
}

fn now(raw_context: ?*anyopaque) !i64 {
    const context = contextFromOpaque(raw_context);
    return std.Io.Clock.real.now(context.init.io).toMilliseconds();
}

fn persist(raw_context: ?*anyopaque, journal: *const agent_journal.Journal) !void {
    const context = contextFromOpaque(raw_context);
    try journal.save(
        context.init.io,
        std.Io.Dir.cwd(),
        context.journal_path,
    );
}

fn report(
    raw_context: ?*anyopaque,
    status: allocation.Status,
) !accelerator_reconciler.ReportResult {
    const context = contextFromOpaque(raw_context);
    const payload = try std.json.Stringify.valueAlloc(context.init.gpa, status, .{});
    defer context.init.gpa.free(payload);
    var response_buffer: [4096]u8 = undefined;
    const response = try client.postJson(
        context.init,
        context.status_url,
        payload,
        context.token,
        &response_buffer,
    );
    if (response.status != .accepted) return error.AllocationStatusRejected;
    return parseStatusResponse(context.init.gpa, response.response_body);
}

fn parseStatusResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
) !accelerator_reconciler.ReportResult {
    var parsed = std.json.parseFromSlice(StatusResponse, allocator, body, .{
        .ignore_unknown_fields = false,
    }) catch return error.InvalidAllocationStatusResponse;
    defer parsed.deinit();
    if (!parsed.value.accepted) return error.AllocationStatusRejected;
    return .{ .released = parsed.value.released };
}

fn inspect(
    raw_context: ?*anyopaque,
    deployment: orchestration.Deployment,
    identity: accelerator_reconciler.RuntimeIdentity,
) !accelerator_reconciler.InspectResult {
    const context = contextFromOpaque(raw_context);
    var result = try accelerator_runtime.inspect(
        context.init,
        deployment,
        runtimeIdentity(identity),
    );
    defer result.deinit(context.init.gpa);
    return switch (result.state) {
        .absent => .absent,
        .identity_mismatch => .conflict,
        .matching_running, .matching_stopped => .{
            .owned = result.takeHandle() orelse return error.RuntimeHandleUnavailable,
        },
    };
}

fn start(
    raw_context: ?*anyopaque,
    deployment: orchestration.Deployment,
    plan: device_access.Plan,
    identity: accelerator_reconciler.RuntimeIdentity,
    variant_name: ?[]const u8,
) !agent_journal.RuntimeHandle {
    const context = contextFromOpaque(raw_context);
    var selected: [accelerator.max_device_count]accelerator.Device = undefined;
    try selectedDevices(context, plan, &selected);
    const artifact_path = try runtime.prepareArtifactVariantFor(
        context.init,
        deployment,
        context.runtime_options,
        selected[0..plan.device_ids.len],
        variant_name,
    );
    defer if (artifact_path) |path| context.init.gpa.free(path);
    return accelerator_runtime.start(
        context.init,
        deployment,
        plan,
        runtimeIdentity(identity),
        artifact_path,
    );
}

fn selectedDevices(
    context: *Context,
    plan: device_access.Plan,
    output: *[accelerator.max_device_count]accelerator.Device,
) !void {
    for (plan.device_ids, 0..) |device_id, index| {
        output[index] = findDevice(context.inventory.report(), device_id) orelse
            return error.AssignedAcceleratorMissing;
    }
}

fn findDevice(
    inventory: accelerator.InventoryReport,
    device_id: []const u8,
) ?accelerator.Device {
    for (inventory.accelerators) |device| {
        if (std.mem.eql(u8, device.id, device_id)) return device;
    }
    return null;
}

fn stop(
    raw_context: ?*anyopaque,
    identity: accelerator_reconciler.RuntimeIdentity,
    handle: agent_journal.RuntimeHandle,
) !void {
    const context = contextFromOpaque(raw_context);
    try accelerator_runtime.stop(context.init, runtimeIdentity(identity), handle);
    try runtime.releaseArtifactPin(
        context.init,
        context.runtime_options,
        identity.deployment,
    );
}

fn healthy(
    raw_context: ?*anyopaque,
    deployment: orchestration.Deployment,
    identity: accelerator_reconciler.RuntimeIdentity,
    handle: agent_journal.RuntimeHandle,
) !bool {
    const context = contextFromOpaque(raw_context);
    var attempt: u8 = 0;
    while (attempt < deployment.health_check.failure_threshold) : (attempt += 1) {
        const runtime_healthy = try accelerator_runtime.healthy(
            context.init,
            runtimeIdentity(identity),
            handle,
        );
        if (runtime_healthy and
            try runtime.applicationHealthCheck(context.init, deployment)) return true;
        if (attempt + 1 < deployment.health_check.failure_threshold)
            try shutdown.sleepInterruptible(context.init.io, 1000);
    }
    return false;
}

fn deinitHandle(raw_context: ?*anyopaque, handle: *agent_journal.RuntimeHandle) void {
    accelerator_runtime.deinitHandle(contextFromOpaque(raw_context).init.gpa, handle);
}

fn runtimeIdentity(
    identity: accelerator_reconciler.RuntimeIdentity,
) accelerator_runtime.ExpectedIdentity {
    return .{
        .allocation_id = identity.allocation_id,
        .generation = identity.generation,
        .deployment = identity.deployment,
        .revision = identity.revision,
        .operation_id = identity.operation_id,
        .access_fingerprint_hex = identity.access_fingerprint,
    };
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

test "allocation status endpoint is node scoped" {
    const value = try endpointAlloc(
        std.testing.allocator,
        "http://127.0.0.1:8080/",
        "edge-01",
    );
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:8080/v1/nodes/edge-01/allocation-status",
        value,
    );
}

test "allocation acknowledgement parsing is strict" {
    const accepted = try parseStatusResponse(
        std.testing.allocator,
        "{\"accepted\":true}\n",
    );
    try std.testing.expect(!accepted.released);
    const released = try parseStatusResponse(
        std.testing.allocator,
        "{\"accepted\":true,\"released\":true}\n",
    );
    try std.testing.expect(released.released);
    try std.testing.expectError(
        error.AllocationStatusRejected,
        parseStatusResponse(std.testing.allocator, "{\"accepted\":false}"),
    );
    try std.testing.expectError(
        error.InvalidAllocationStatusResponse,
        parseStatusResponse(std.testing.allocator, "{\"accepted\":true,\"extra\":1}"),
    );
}
