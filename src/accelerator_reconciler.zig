const std = @import("std");
const accelerator = @import("accelerator.zig");
const agent_journal = @import("agent_journal.zig");
const allocation = @import("allocation.zig");
const device_access = @import("device_access.zig");
const orchestration = @import("orchestration.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const RuntimeIdentity = struct {
    allocation_id: []const u8,
    generation: u64,
    deployment: []const u8,
    revision: u64,
    operation_id: []const u8,
    access_fingerprint: []const u8,
};

pub const InspectResult = union(enum) {
    absent,
    owned: agent_journal.RuntimeHandle,
    conflict,
};

pub const ReportResult = struct {
    released: bool = false,
};

/// Injectable effect boundary. Tests use a deterministic fake; production
/// wrappers delegate to the exact runtime adapters and HTTP client.
pub const Hooks = struct {
    context: ?*anyopaque,
    now_fn: *const fn (?*anyopaque) anyerror!i64,
    persist_fn: *const fn (?*anyopaque, *const agent_journal.Journal) anyerror!void,
    report_fn: *const fn (?*anyopaque, allocation.Status) anyerror!ReportResult,
    inspect_fn: *const fn (
        ?*anyopaque,
        orchestration.Deployment,
        RuntimeIdentity,
    ) anyerror!InspectResult,
    start_fn: *const fn (
        ?*anyopaque,
        orchestration.Deployment,
        device_access.Plan,
        RuntimeIdentity,
    ) anyerror!agent_journal.RuntimeHandle,
    stop_fn: *const fn (
        ?*anyopaque,
        RuntimeIdentity,
        agent_journal.RuntimeHandle,
    ) anyerror!void,
    healthy_fn: *const fn (
        ?*anyopaque,
        orchestration.Deployment,
        RuntimeIdentity,
        agent_journal.RuntimeHandle,
    ) anyerror!bool,
    deinit_handle_fn: *const fn (?*anyopaque, *agent_journal.RuntimeHandle) void,
};

pub const ReconcileError = error{
    MissingRunDeployment,
    MissingRunAccessPlan,
    MissingReleaseJournal,
    StaleAllocationCommand,
    AllocationGenerationGap,
    RuntimeOwnershipAmbiguous,
    MissingActiveRuntime,
    MissingActiveSpec,
    MissingActiveAccessFingerprint,
    InvalidPersistedSpec,
    ReleaseNotAcknowledged,
    ReconcileStepLimitExceeded,
};

/// Advance exactly one fenced command. Every mutating runtime phase is saved
/// and reported before its side effect. Re-entry therefore either adopts the
/// exact expected runtime or repeats an idempotent exact stop.
pub fn reconcileCommand(
    allocator: std.mem.Allocator,
    journal: *agent_journal.Journal,
    node_id: []const u8,
    command: allocation.DesiredAllocation,
    deployment: ?orchestration.Deployment,
    access_plan: ?device_access.Plan,
    hooks: Hooks,
) !void {
    try allocation.validateDesired(command);
    try ensureOperation(
        allocator,
        journal,
        command,
        deployment,
        access_plan,
        hooks,
    );

    for (0..32) |_| {
        const current = journal.find(command.allocation_id) orelse
            return error.MissingReleaseJournal;
        if (current.entry.generation != command.generation)
            return error.StaleAllocationCommand;
        if (current.entry.phase == .released) return;

        const report_result = try reportCurrent(node_id, current.*, hooks);
        switch (current.entry.phase) {
            .pending => try transition(journal, current.*, .prepared, hooks),
            .prepared => try transition(
                journal,
                current.*,
                if (current.active_handle != null) .stopping_old else .starting_target,
                hooks,
            ),
            .stopping_old => {
                const handle = current.active_handle orelse return error.MissingActiveRuntime;
                const identity = try activeIdentityAlloc(allocator, current.*);
                defer allocator.free(identity.operation_id);
                try stopExactOrAmbiguous(
                    journal,
                    node_id,
                    current.*,
                    identity,
                    handle,
                    hooks,
                );
                try transition(journal, current.*, .old_stopped, hooks);
            },
            .old_stopped => try transition(journal, current.*, .starting_target, hooks),
            .starting_target => {
                const spec = current.target_spec_json orelse return error.InvalidPersistedSpec;
                var parsed = try parseDeployment(allocator, spec);
                defer parsed.deinit();
                const plan = access_plan orelse return error.MissingRunAccessPlan;
                const identity = targetIdentity(current.*);
                var handle = switch (try hooks.inspect_fn(
                    hooks.context,
                    parsed.value,
                    identity,
                )) {
                    .absent => try hooks.start_fn(
                        hooks.context,
                        parsed.value,
                        plan,
                        identity,
                    ),
                    .owned => |owned| owned,
                    .conflict => return markAmbiguous(
                        journal,
                        node_id,
                        current.*,
                        hooks,
                    ),
                };
                defer hooks.deinit_handle_fn(hooks.context, &handle);
                try handle.validate();
                var next = current.*;
                next.target_handle = handle;
                next.entry.phase = .target_started;
                next.recorded_unix_ms = try hooks.now_fn(hooks.context);
                try putAndPersist(journal, next, hooks);
            },
            .target_started => try transition(journal, current.*, .verifying, hooks),
            .verifying => {
                const spec = current.target_spec_json orelse return error.InvalidPersistedSpec;
                var parsed = try parseDeployment(allocator, spec);
                defer parsed.deinit();
                const handle = current.target_handle orelse return error.MissingActiveRuntime;
                const is_healthy = hooks.healthy_fn(
                    hooks.context,
                    parsed.value,
                    targetIdentity(current.*),
                    handle,
                ) catch |err| {
                    if (isOwnershipError(err))
                        return markAmbiguous(journal, node_id, current.*, hooks);
                    return err;
                };
                if (is_healthy) {
                    var next = current.*;
                    next.entry.phase = .active;
                    next.entry.active_revision = next.entry.target_revision;
                    next.entry.active_device_ids = next.entry.target_device_ids;
                    next.entry.retiring_device_ids = &.{};
                    next.recorded_unix_ms = try hooks.now_fn(hooks.context);
                    try putAndPersist(journal, next, hooks);
                } else {
                    try transition(journal, current.*, .stopping_target, hooks);
                }
            },
            .active => {
                const spec = current.target_spec_json orelse return error.InvalidPersistedSpec;
                var parsed = try parseDeployment(allocator, spec);
                defer parsed.deinit();
                const plan = access_plan orelse return error.MissingRunAccessPlan;
                if (current.restart_pending) {
                    try restartActive(
                        allocator,
                        journal,
                        node_id,
                        current.*,
                        parsed.value,
                        plan,
                        hooks,
                    );
                    continue;
                }
                const handle = actualActiveHandle(current.*) orelse
                    return error.MissingActiveRuntime;
                const identity = try currentRuntimeIdentityAlloc(allocator, current.*);
                defer allocator.free(identity.operation_id);
                const is_healthy = hooks.healthy_fn(
                    hooks.context,
                    parsed.value,
                    identity,
                    handle,
                ) catch |err| {
                    if (isOwnershipError(err))
                        return markAmbiguous(journal, node_id, current.*, hooks);
                    return err;
                };
                if (is_healthy) return;
                if (parsed.value.restart_policy == .never) {
                    try transition(journal, current.*, .failed, hooks);
                    continue;
                }
                var next = current.*;
                next.restart_attempt = std.math.add(
                    u32,
                    current.restart_attempt,
                    1,
                ) catch return error.RestartAttemptOverflow;
                next.restart_pending = true;
                next.recorded_unix_ms = try hooks.now_fn(hooks.context);
                try putAndPersist(journal, next, hooks);
            },
            .failed, .ambiguous => return,
            .stopping_target => {
                const handle = current.target_handle orelse return error.MissingActiveRuntime;
                try stopExactOrAmbiguous(
                    journal,
                    node_id,
                    current.*,
                    targetIdentity(current.*),
                    handle,
                    hooks,
                );
                try transition(journal, current.*, .target_stopped, hooks);
            },
            .target_stopped => try transition(journal, current.*, .restoring_old, hooks),
            .restoring_old => {
                var next = current.*;
                if (current.active_handle != null) {
                    const spec = current.active_spec_json orelse return error.MissingActiveSpec;
                    var parsed = try parseDeployment(allocator, spec);
                    defer parsed.deinit();
                    const plan = access_plan orelse return error.MissingRunAccessPlan;
                    const identity = restoredIdentity(current.*);
                    var restored = switch (try hooks.inspect_fn(
                        hooks.context,
                        parsed.value,
                        identity,
                    )) {
                        .absent => try hooks.start_fn(
                            hooks.context,
                            parsed.value,
                            plan,
                            identity,
                        ),
                        .owned => |owned| owned,
                        .conflict => return markAmbiguous(
                            journal,
                            node_id,
                            current.*,
                            hooks,
                        ),
                    };
                    defer hooks.deinit_handle_fn(hooks.context, &restored);
                    try restored.validate();
                    next.restored_handle = restored;
                }
                next.entry.phase = .failed;
                next.recorded_unix_ms = try hooks.now_fn(hooks.context);
                try putAndPersist(journal, next, hooks);
            },
            .release_requested => try transition(journal, current.*, .stopping, hooks),
            .stopping => {
                const handle = current.active_handle orelse return error.MissingActiveRuntime;
                const identity = try activeIdentityAlloc(allocator, current.*);
                defer allocator.free(identity.operation_id);
                try stopExactOrAmbiguous(
                    journal,
                    node_id,
                    current.*,
                    identity,
                    handle,
                    hooks,
                );
                var next = current.*;
                next.entry.phase = .released_ack_pending;
                next.entry.active_revision = null;
                next.entry.active_device_ids = &.{};
                next.disposition = .released_ack_pending;
                next.recorded_unix_ms = try hooks.now_fn(hooks.context);
                try putAndPersist(journal, next, hooks);
            },
            .released_ack_pending => {
                if (!report_result.released) return error.ReleaseNotAcknowledged;
                var next = current.*;
                next.entry.phase = .released;
                next.entry.retiring_device_ids = &.{};
                next.disposition = .released_tombstone;
                next.control_plane_ack_unix_ms = try hooks.now_fn(hooks.context);
                next.recorded_unix_ms = next.control_plane_ack_unix_ms.?;
                try putAndPersist(journal, next, hooks);
            },
            .released => return,
        }
    }
    return error.ReconcileStepLimitExceeded;
}

fn ensureOperation(
    allocator: std.mem.Allocator,
    journal: *agent_journal.Journal,
    command: allocation.DesiredAllocation,
    deployment: ?orchestration.Deployment,
    access_plan: ?device_access.Plan,
    hooks: Hooks,
) !void {
    const desired_fingerprint = try desiredFingerprintAlloc(allocator, command);
    defer allocator.free(desired_fingerprint);
    const existing = journal.find(command.allocation_id);
    if (existing) |operation| {
        if (operation.entry.generation > command.generation)
            return error.StaleAllocationCommand;
        if (operation.entry.generation == command.generation) {
            if (!std.mem.eql(u8, operation.desired_fingerprint, desired_fingerprint))
                return error.StaleAllocationCommand;
            if (access_plan) |plan| {
                const access_hex = std.fmt.bytesToHex(plan.fingerprint, .lower);
                if (!std.mem.eql(u8, operation.access_fingerprint, &access_hex))
                    return error.StaleAllocationCommand;
            }
            return;
        }
        if (command.generation != operation.entry.generation + 1)
            return error.AllocationGenerationGap;
    }

    const operation_id = try operationIdAlloc(
        allocator,
        command.allocation_id,
        command.generation,
    );
    defer allocator.free(operation_id);
    const now = try hooks.now_fn(hooks.context);

    if (command.action == .run) {
        const target = deployment orelse return error.MissingRunDeployment;
        const plan = access_plan orelse return error.MissingRunAccessPlan;
        const target_spec = try std.json.Stringify.valueAlloc(allocator, target, .{});
        defer allocator.free(target_spec);
        const access_hex = std.fmt.bytesToHex(plan.fingerprint, .lower);

        var active_revision: ?u64 = null;
        var active_ids: []const []const u8 = &.{};
        var active_handle: ?agent_journal.RuntimeHandle = null;
        var active_spec: ?[]const u8 = null;
        var active_access: ?[]const u8 = null;
        var active_operation_id: ?[]u8 = null;
        defer if (active_operation_id) |value| allocator.free(value);
        if (existing) |previous| {
            active_revision = actualActiveRevision(previous.*);
            active_ids = actualActiveDeviceIds(previous.*);
            active_handle = actualActiveHandle(previous.*);
            active_spec = actualActiveSpec(previous.*);
            active_access = actualActiveAccess(previous.*);
            active_operation_id = try actualActiveOperationIdAlloc(allocator, previous.*);
        }

        const operation: agent_journal.Operation = .{
            .entry = .{
                .allocation_id = command.allocation_id,
                .generation = command.generation,
                .deployment = command.deployment,
                .action = .run,
                .phase = .pending,
                .active_revision = active_revision,
                .target_revision = command.revision,
                .operation_id = operation_id,
                .active_device_ids = active_ids,
                .target_device_ids = command.target_device_ids,
            },
            .command_revision = command.revision,
            .desired_fingerprint = desired_fingerprint,
            .active_access_fingerprint = active_access,
            .active_operation_id = active_operation_id,
            .access_fingerprint = &access_hex,
            .active_handle = active_handle,
            .active_spec_json = active_spec,
            .target_spec_json = target_spec,
            .recorded_unix_ms = now,
        };
        try putAndPersist(journal, operation, hooks);
        return;
    } else {
        const previous = existing orelse return error.MissingReleaseJournal;
        const active_handle = actualActiveHandle(previous.*) orelse
            return error.MissingActiveRuntime;
        const active_access = actualActiveAccess(previous.*) orelse
            return error.MissingActiveAccessFingerprint;
        const active_spec = actualActiveSpec(previous.*) orelse
            return error.MissingActiveSpec;
        const active_operation_id = (try actualActiveOperationIdAlloc(
            allocator,
            previous.*,
        )) orelse return error.MissingActiveRuntime;
        defer allocator.free(active_operation_id);
        const operation: agent_journal.Operation = .{
            .entry = .{
                .allocation_id = command.allocation_id,
                .generation = command.generation,
                .deployment = command.deployment,
                .action = .release,
                .phase = .release_requested,
                .active_revision = command.revision,
                .operation_id = operation_id,
                .active_device_ids = command.retiring_device_ids,
                .retiring_device_ids = command.retiring_device_ids,
            },
            .command_revision = command.revision,
            .desired_fingerprint = desired_fingerprint,
            .active_access_fingerprint = active_access,
            .active_operation_id = active_operation_id,
            .access_fingerprint = active_access,
            .active_handle = active_handle,
            .active_spec_json = active_spec,
            .recorded_unix_ms = now,
        };
        try putAndPersist(journal, operation, hooks);
        return;
    }
}

fn transition(
    journal: *agent_journal.Journal,
    current: agent_journal.Operation,
    phase: allocation.ObservedPhase,
    hooks: Hooks,
) !void {
    var next = current;
    next.entry.phase = phase;
    next.recorded_unix_ms = try hooks.now_fn(hooks.context);
    try putAndPersist(journal, next, hooks);
}

fn putAndPersist(
    journal: *agent_journal.Journal,
    operation: agent_journal.Operation,
    hooks: Hooks,
) !void {
    try journal.put(operation);
    try hooks.persist_fn(hooks.context, journal);
}

fn reportCurrent(
    node_id: []const u8,
    operation: agent_journal.Operation,
    hooks: Hooks,
) !ReportResult {
    return hooks.report_fn(hooks.context, .{
        .allocation_id = operation.entry.allocation_id,
        .generation = operation.entry.generation,
        .node_id = node_id,
        .deployment = operation.entry.deployment,
        .revision = operation.command_revision,
        .phase = operation.entry.phase,
        .observed_unix_ms = try hooks.now_fn(hooks.context),
    });
}

fn markAmbiguous(
    journal: *agent_journal.Journal,
    node_id: []const u8,
    current: agent_journal.Operation,
    hooks: Hooks,
) !void {
    var next = current;
    next.entry.phase = .ambiguous;
    next.recorded_unix_ms = try hooks.now_fn(hooks.context);
    try putAndPersist(journal, next, hooks);
    _ = try reportCurrent(node_id, journal.find(next.entry.allocation_id).?.*, hooks);
    return error.RuntimeOwnershipAmbiguous;
}

fn targetIdentity(operation: agent_journal.Operation) RuntimeIdentity {
    return .{
        .allocation_id = operation.entry.allocation_id,
        .generation = operation.entry.generation,
        .deployment = operation.entry.deployment,
        .revision = operation.command_revision,
        .operation_id = operation.entry.operation_id,
        .access_fingerprint = operation.access_fingerprint,
    };
}

fn restartActive(
    allocator: std.mem.Allocator,
    journal: *agent_journal.Journal,
    node_id: []const u8,
    current: agent_journal.Operation,
    deployment: orchestration.Deployment,
    access_plan: device_access.Plan,
    hooks: Hooks,
) !void {
    const previous_handle = actualActiveHandle(current) orelse
        return error.MissingActiveRuntime;
    const previous_identity = try runtimeIdentityForAttemptAlloc(
        allocator,
        current,
        current.restart_attempt - 1,
    );
    defer allocator.free(previous_identity.operation_id);
    try stopExactOrAmbiguous(
        journal,
        node_id,
        current,
        previous_identity,
        previous_handle,
        hooks,
    );

    const next_identity = try runtimeIdentityForAttemptAlloc(
        allocator,
        current,
        current.restart_attempt,
    );
    defer allocator.free(next_identity.operation_id);
    var handle = switch (try hooks.inspect_fn(
        hooks.context,
        deployment,
        next_identity,
    )) {
        .absent => try hooks.start_fn(
            hooks.context,
            deployment,
            access_plan,
            next_identity,
        ),
        .owned => |owned| owned,
        .conflict => return markAmbiguous(journal, node_id, current, hooks),
    };
    defer hooks.deinit_handle_fn(hooks.context, &handle);
    try handle.validate();
    var next = current;
    next.restart_pending = false;
    next.restart_handle = handle;
    next.recorded_unix_ms = try hooks.now_fn(hooks.context);
    try putAndPersist(journal, next, hooks);
}

fn stopExactOrAmbiguous(
    journal: *agent_journal.Journal,
    node_id: []const u8,
    current: agent_journal.Operation,
    identity: RuntimeIdentity,
    handle: agent_journal.RuntimeHandle,
    hooks: Hooks,
) !void {
    hooks.stop_fn(hooks.context, identity, handle) catch |err| {
        if (isOwnershipError(err))
            return markAmbiguous(journal, node_id, current, hooks);
        return err;
    };
}

fn isOwnershipError(err: anyerror) bool {
    return switch (err) {
        error.RuntimeIdentityMismatch,
        error.RuntimeHandleMismatch,
        error.RuntimeInvocationMismatch,
        error.RuntimeConfigurationMismatch,
        => true,
        else => false,
    };
}

fn currentRuntimeIdentityAlloc(
    allocator: std.mem.Allocator,
    operation: agent_journal.Operation,
) !RuntimeIdentity {
    return runtimeIdentityForAttemptAlloc(allocator, operation, operation.restart_attempt);
}

fn runtimeIdentityForAttemptAlloc(
    allocator: std.mem.Allocator,
    operation: agent_journal.Operation,
    attempt: u32,
) !RuntimeIdentity {
    const operation_id = if (attempt == 0)
        try allocator.dupe(u8, operation.entry.operation_id)
    else
        try std.fmt.allocPrint(
            allocator,
            "{s}-restart-{d}",
            .{ operation.entry.operation_id, attempt },
        );
    return .{
        .allocation_id = operation.entry.allocation_id,
        .generation = operation.entry.generation,
        .deployment = operation.entry.deployment,
        .revision = operation.command_revision,
        .operation_id = operation_id,
        .access_fingerprint = operation.access_fingerprint,
    };
}

fn activeIdentityAlloc(
    allocator: std.mem.Allocator,
    operation: agent_journal.Operation,
) !RuntimeIdentity {
    const generation = operation.entry.generation - 1;
    return .{
        .allocation_id = operation.entry.allocation_id,
        .generation = generation,
        .deployment = operation.entry.deployment,
        .revision = operation.entry.active_revision orelse return error.MissingActiveRuntime,
        .operation_id = try allocator.dupe(
            u8,
            operation.active_operation_id orelse return error.MissingActiveRuntime,
        ),
        .access_fingerprint = operation.active_access_fingerprint orelse
            return error.MissingActiveAccessFingerprint,
    };
}

fn actualActiveOperationIdAlloc(
    allocator: std.mem.Allocator,
    operation: agent_journal.Operation,
) !?[]u8 {
    if (actualActiveHandle(operation) == null) return null;
    if (operation.restart_handle != null) {
        return @as(?[]u8, try std.fmt.allocPrint(
            allocator,
            "{s}-restart-{d}",
            .{ operation.entry.operation_id, operation.restart_attempt },
        ));
    }
    if (operation.restored_handle != null or operation.target_handle != null)
        return @as(?[]u8, try allocator.dupe(u8, operation.entry.operation_id));
    return @as(?[]u8, try allocator.dupe(
        u8,
        operation.active_operation_id orelse return error.MissingActiveRuntime,
    ));
}

fn restoredIdentity(operation: agent_journal.Operation) RuntimeIdentity {
    return .{
        .allocation_id = operation.entry.allocation_id,
        .generation = operation.entry.generation,
        .deployment = operation.entry.deployment,
        .revision = operation.entry.active_revision.?,
        .operation_id = operation.entry.operation_id,
        .access_fingerprint = operation.access_fingerprint,
    };
}

fn actualActiveHandle(operation: agent_journal.Operation) ?agent_journal.RuntimeHandle {
    if (operation.entry.phase == .released or operation.entry.phase == .ambiguous)
        return null;
    return operation.restart_handle orelse operation.restored_handle orelse
        operation.target_handle orelse operation.active_handle;
}

fn actualActiveSpec(operation: agent_journal.Operation) ?[]const u8 {
    return if (operation.restored_handle != null)
        operation.active_spec_json
    else
        operation.target_spec_json orelse operation.active_spec_json;
}

fn actualActiveAccess(operation: agent_journal.Operation) ?[]const u8 {
    if (actualActiveHandle(operation) == null) return null;
    return if (operation.restored_handle != null or operation.target_handle != null)
        operation.access_fingerprint
    else
        operation.active_access_fingerprint;
}

fn actualActiveRevision(operation: agent_journal.Operation) ?u64 {
    if (actualActiveHandle(operation) == null) return null;
    if (operation.restored_handle != null) return operation.entry.active_revision;
    return operation.entry.target_revision orelse operation.entry.active_revision;
}

fn actualActiveDeviceIds(operation: agent_journal.Operation) []const []const u8 {
    if (actualActiveHandle(operation) == null) return &.{};
    if (operation.restored_handle != null) return operation.entry.active_device_ids;
    return if (operation.target_handle != null)
        operation.entry.target_device_ids
    else
        operation.entry.active_device_ids;
}

fn desiredFingerprintAlloc(
    allocator: std.mem.Allocator,
    command: allocation.DesiredAllocation,
) ![]u8 {
    const encoded = try std.json.Stringify.valueAlloc(allocator, command, .{});
    defer allocator.free(encoded);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(encoded, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

fn operationIdAlloc(
    allocator: std.mem.Allocator,
    allocation_id: []const u8,
    generation: u64,
) ![]u8 {
    var hash = Sha256.init(.{});
    hash.update("nimbus.accelerator.operation.v1\x00");
    hash.update(allocation_id);
    var generation_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &generation_bytes, generation, .big);
    hash.update(&generation_bytes);
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "op-{s}", .{hex});
}

fn parseDeployment(
    allocator: std.mem.Allocator,
    spec_json: []const u8,
) !std.json.Parsed(orchestration.Deployment) {
    const parsed = try std.json.parseFromSlice(
        orchestration.Deployment,
        allocator,
        spec_json,
        .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
    );
    if (!orchestration.validateDeployment(parsed.value)) {
        var invalid = parsed;
        invalid.deinit();
        return error.InvalidPersistedSpec;
    }
    return parsed;
}

const FakeContext = struct {
    now: i64 = 1_700_000_000_000,
    persist_count: usize = 0,
    start_count: usize = 0,
    stop_count: usize = 0,
    inspect_count: usize = 0,
    healthy: bool = true,
    recover_on_restart: bool = false,
    fail_persist: bool = false,
    fail_report_phase: ?allocation.ObservedPhase = null,
    conflict: bool = false,
    running: ?agent_journal.RuntimeHandle = null,
    last_stop_operation: [allocation.max_token_bytes]u8 = undefined,
    last_stop_operation_len: usize = 0,
    report_phases: [64]allocation.ObservedPhase = undefined,
    report_count: usize = 0,
};

fn fakeHooks(context: *FakeContext) Hooks {
    return .{
        .context = context,
        .now_fn = fakeNow,
        .persist_fn = fakePersist,
        .report_fn = fakeReport,
        .inspect_fn = fakeInspect,
        .start_fn = fakeStart,
        .stop_fn = fakeStop,
        .healthy_fn = fakeHealthy,
        .deinit_handle_fn = fakeDeinitHandle,
    };
}

fn fakeContext(pointer: ?*anyopaque) *FakeContext {
    return @ptrCast(@alignCast(pointer.?));
}

fn fakeNow(pointer: ?*anyopaque) !i64 {
    const context = fakeContext(pointer);
    context.now += 1;
    return context.now;
}

fn fakePersist(pointer: ?*anyopaque, _: *const agent_journal.Journal) !void {
    const context = fakeContext(pointer);
    if (context.fail_persist) return error.InjectedPersistFailure;
    context.persist_count += 1;
}

fn fakeReport(pointer: ?*anyopaque, status: allocation.Status) !ReportResult {
    const context = fakeContext(pointer);
    if (context.fail_report_phase == status.phase) return error.InjectedReportFailure;
    context.report_phases[context.report_count] = status.phase;
    context.report_count += 1;
    return .{ .released = status.phase == .released_ack_pending };
}

fn fakeInspect(
    pointer: ?*anyopaque,
    _: orchestration.Deployment,
    _: RuntimeIdentity,
) !InspectResult {
    const context = fakeContext(pointer);
    context.inspect_count += 1;
    if (context.conflict) return .conflict;
    return if (context.running) |handle| .{ .owned = handle } else .absent;
}

fn fakeStart(
    pointer: ?*anyopaque,
    _: orchestration.Deployment,
    _: device_access.Plan,
    _: RuntimeIdentity,
) !agent_journal.RuntimeHandle {
    const context = fakeContext(pointer);
    context.start_count += 1;
    const full_id = switch (context.start_count) {
        1 => "ab" ** 32,
        2 => "bc" ** 32,
        else => "cd" ** 32,
    };
    const handle: agent_journal.RuntimeHandle = .{ .container = .{
        .engine = .docker,
        .full_id = full_id,
    } };
    context.running = handle;
    if (context.recover_on_restart and context.start_count > 1)
        context.healthy = true;
    return handle;
}

fn fakeStop(
    pointer: ?*anyopaque,
    identity: RuntimeIdentity,
    expected: agent_journal.RuntimeHandle,
) !void {
    const context = fakeContext(pointer);
    if (context.running) |actual| {
        if (!agent_journal.RuntimeHandle.eql(actual, expected))
            return error.RuntimeIdentityMismatch;
    }
    @memcpy(
        context.last_stop_operation[0..identity.operation_id.len],
        identity.operation_id,
    );
    context.last_stop_operation_len = identity.operation_id.len;
    context.stop_count += 1;
    context.running = null;
}

fn fakeHealthy(
    pointer: ?*anyopaque,
    _: orchestration.Deployment,
    _: RuntimeIdentity,
    expected: agent_journal.RuntimeHandle,
) !bool {
    const context = fakeContext(pointer);
    const actual = context.running orelse return false;
    return context.healthy and agent_journal.RuntimeHandle.eql(actual, expected);
}

fn fakeDeinitHandle(_: ?*anyopaque, _: *agent_journal.RuntimeHandle) void {}

const test_deployment: orchestration.Deployment = .{
    .name = "vision",
    .revision = 1,
    .runtime = .{
        .kind = .docker,
        .reference = "registry.example/vision@sha256:" ++ ("ab" ** 32),
    },
    .resources = .{ .accelerators = .{
        .kind = .gpu,
        .vendor = "nvidia",
    } },
    .targets = .{ .all = true },
};

const test_run: allocation.DesiredAllocation = .{
    .allocation_id = "alloc-vision",
    .generation = 1,
    .deployment = "vision",
    .revision = 1,
    .action = .run,
    .target_device_ids = &.{"gpu:nvidia:a"},
};

const test_plan: device_access.Plan = .{
    .device_ids = &.{"gpu:nvidia:a"},
    .access = .{ .cdi = &.{"nvidia.com/gpu=GPU-a"} },
    .fingerprint = [_]u8{0x11} ** 32,
};

test "write-ahead run adopts after a crash and never duplicates start" {
    var journal = agent_journal.Journal.init(std.testing.allocator);
    defer journal.deinit();
    var context: FakeContext = .{ .fail_report_phase = .starting_target };

    try std.testing.expectError(
        error.InjectedReportFailure,
        reconcileCommand(
            std.testing.allocator,
            &journal,
            "gpu-edge",
            test_run,
            test_deployment,
            test_plan,
            fakeHooks(&context),
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), context.start_count);
    try std.testing.expectEqual(
        allocation.ObservedPhase.starting_target,
        journal.find("alloc-vision").?.entry.phase,
    );

    // Simulate a crash after the runtime accepted start but before its handle
    // could be journaled. Exact inspect adopts it on the next pass.
    context.running = .{ .container = .{
        .engine = .docker,
        .full_id = "ab" ** 32,
    } };
    context.fail_report_phase = null;
    try reconcileCommand(
        std.testing.allocator,
        &journal,
        "gpu-edge",
        test_run,
        test_deployment,
        test_plan,
        fakeHooks(&context),
    );
    try std.testing.expectEqual(@as(usize, 0), context.start_count);
    try std.testing.expectEqual(
        allocation.ObservedPhase.active,
        journal.find("alloc-vision").?.entry.phase,
    );
}

test "release without a deployment spec stops exact handle before acknowledgement" {
    var journal = agent_journal.Journal.init(std.testing.allocator);
    defer journal.deinit();
    var context: FakeContext = .{};
    try reconcileCommand(
        std.testing.allocator,
        &journal,
        "gpu-edge",
        test_run,
        test_deployment,
        test_plan,
        fakeHooks(&context),
    );
    try std.testing.expectEqual(@as(usize, 1), context.start_count);

    const release: allocation.DesiredAllocation = .{
        .allocation_id = "alloc-vision",
        .generation = 2,
        .deployment = "vision",
        .revision = 1,
        .action = .release,
        .retiring_device_ids = &.{"gpu:nvidia:a"},
    };
    try reconcileCommand(
        std.testing.allocator,
        &journal,
        "gpu-edge",
        release,
        null,
        null,
        fakeHooks(&context),
    );
    const operation = journal.find("alloc-vision").?;
    try std.testing.expectEqual(allocation.ObservedPhase.released, operation.entry.phase);
    try std.testing.expectEqual(agent_journal.Disposition.released_tombstone, operation.disposition);
    try std.testing.expectEqual(@as(usize, 1), context.stop_count);
    try std.testing.expect(context.running == null);
}

test "active runtime restarts with a rotated local operation fence" {
    var journal = agent_journal.Journal.init(std.testing.allocator);
    defer journal.deinit();
    var context: FakeContext = .{};
    try reconcileCommand(
        std.testing.allocator,
        &journal,
        "gpu-edge",
        test_run,
        test_deployment,
        test_plan,
        fakeHooks(&context),
    );

    context.healthy = false;
    context.recover_on_restart = true;
    try reconcileCommand(
        std.testing.allocator,
        &journal,
        "gpu-edge",
        test_run,
        test_deployment,
        test_plan,
        fakeHooks(&context),
    );
    const operation = journal.find("alloc-vision").?;
    try std.testing.expectEqual(allocation.ObservedPhase.active, operation.entry.phase);
    try std.testing.expectEqual(@as(u32, 1), operation.restart_attempt);
    try std.testing.expect(!operation.restart_pending);
    try std.testing.expect(operation.restart_handle != null);
    try std.testing.expectEqual(@as(usize, 2), context.start_count);
    try std.testing.expectEqual(@as(usize, 1), context.stop_count);
    try std.testing.expect(agent_journal.RuntimeHandle.eql(
        context.running.?,
        operation.restart_handle.?,
    ));
    const expected_operation = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}-restart-1",
        .{operation.entry.operation_id},
    );
    defer std.testing.allocator.free(expected_operation);

    const release: allocation.DesiredAllocation = .{
        .allocation_id = "alloc-vision",
        .generation = 2,
        .deployment = "vision",
        .revision = 1,
        .action = .release,
        .retiring_device_ids = &.{"gpu:nvidia:a"},
    };
    try reconcileCommand(
        std.testing.allocator,
        &journal,
        "gpu-edge",
        release,
        null,
        null,
        fakeHooks(&context),
    );
    try std.testing.expectEqualStrings(
        expected_operation,
        context.last_stop_operation[0..context.last_stop_operation_len],
    );
}

test "persist failure occurs before any runtime effect" {
    var journal = agent_journal.Journal.init(std.testing.allocator);
    defer journal.deinit();
    var context: FakeContext = .{ .fail_persist = true };
    try std.testing.expectError(
        error.InjectedPersistFailure,
        reconcileCommand(
            std.testing.allocator,
            &journal,
            "gpu-edge",
            test_run,
            test_deployment,
            test_plan,
            fakeHooks(&context),
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), context.inspect_count);
    try std.testing.expectEqual(@as(usize, 0), context.start_count);
    try std.testing.expectEqual(@as(usize, 0), context.stop_count);
}

test "foreign deterministic runtime becomes ambiguous without mutation" {
    var journal = agent_journal.Journal.init(std.testing.allocator);
    defer journal.deinit();
    var context: FakeContext = .{ .conflict = true };
    try std.testing.expectError(
        error.RuntimeOwnershipAmbiguous,
        reconcileCommand(
            std.testing.allocator,
            &journal,
            "gpu-edge",
            test_run,
            test_deployment,
            test_plan,
            fakeHooks(&context),
        ),
    );
    try std.testing.expectEqual(
        allocation.ObservedPhase.ambiguous,
        journal.find("alloc-vision").?.entry.phase,
    );
    try std.testing.expectEqual(@as(usize, 0), context.start_count);
    try std.testing.expectEqual(@as(usize, 0), context.stop_count);
}

test "failed upgrade stops target and journals the restored immutable handle" {
    var journal = agent_journal.Journal.init(std.testing.allocator);
    defer journal.deinit();
    var context: FakeContext = .{};
    try reconcileCommand(
        std.testing.allocator,
        &journal,
        "gpu-edge",
        test_run,
        test_deployment,
        test_plan,
        fakeHooks(&context),
    );

    var deployment_v2 = test_deployment;
    deployment_v2.revision = 2;
    var run_v2 = test_run;
    run_v2.generation = 2;
    run_v2.revision = 2;
    context.healthy = false;
    try reconcileCommand(
        std.testing.allocator,
        &journal,
        "gpu-edge",
        run_v2,
        deployment_v2,
        test_plan,
        fakeHooks(&context),
    );
    const operation = journal.find("alloc-vision").?;
    try std.testing.expectEqual(allocation.ObservedPhase.failed, operation.entry.phase);
    try std.testing.expect(operation.restored_handle != null);
    try std.testing.expectEqual(@as(usize, 3), context.start_count);
    try std.testing.expectEqual(@as(usize, 2), context.stop_count);
    try std.testing.expect(agent_journal.RuntimeHandle.eql(
        context.running.?,
        operation.restored_handle.?,
    ));
}
