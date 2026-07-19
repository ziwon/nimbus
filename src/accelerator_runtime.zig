const std = @import("std");
const builtin = @import("builtin");
const agent_journal = @import("agent_journal.zig");
const allocation = @import("allocation.zig");
const device_access = @import("device_access.zig");
const host_runtime = @import("host_runtime.zig");
const orchestration = @import("orchestration.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

const container_inspect_format =
    "{{.Id}}|{{.State.Running}}|" ++
    "{{index .Config.Labels \"io.nimbus.managed\"}}|" ++
    "{{index .Config.Labels \"io.nimbus.allocation-id\"}}|" ++
    "{{index .Config.Labels \"io.nimbus.generation\"}}|" ++
    "{{index .Config.Labels \"io.nimbus.deployment\"}}|" ++
    "{{index .Config.Labels \"io.nimbus.revision\"}}|" ++
    "{{index .Config.Labels \"io.nimbus.operation-id\"}}|" ++
    "{{index .Config.Labels \"io.nimbus.access-fingerprint\"}}";

const systemd_runtime_root = "/run/systemd/system";
const max_runtime_output_bytes = 64 * 1024;
const max_drop_in_bytes = 256 * 1024;

pub const RuntimeHandle = agent_journal.RuntimeHandle;
pub const ContainerEngine = agent_journal.ContainerEngine;

/// Generation-fenced identity which is written into the runtime boundary.
/// Every string is borrowed. The allocation and operation IDs are safe tokens;
/// the access fingerprint is the lowercase SHA-256 of the private access plan.
pub const ExpectedIdentity = struct {
    allocation_id: []const u8,
    generation: u64,
    deployment: []const u8,
    revision: u64,
    operation_id: []const u8,
    access_fingerprint_hex: []const u8,

    pub fn validate(self: ExpectedIdentity) !void {
        if (!allocation.isSafeToken(self.allocation_id))
            return error.InvalidAllocationId;
        if (self.generation == 0 or self.generation > std.math.maxInt(i64))
            return error.InvalidGeneration;
        if (!allocation.isSafeToken(self.deployment))
            return error.InvalidDeployment;
        if (self.revision == 0 or self.revision > std.math.maxInt(i64))
            return error.InvalidRevision;
        if (!allocation.isSafeToken(self.operation_id))
            return error.InvalidOperationId;
        if (!isLowerHex(self.access_fingerprint_hex, 64))
            return error.InvalidAccessFingerprint;
    }
};

/// `identity_mismatch` is deliberately a state, not absence. Callers must
/// retain the reservation and never stop or replace the observed runtime.
pub const InspectState = enum {
    absent,
    matching_running,
    matching_stopped,
    identity_mismatch,
};

/// The optional handle and its nested strings are owned by the allocator used
/// by `inspect` (currently `init.gpa`). Call `deinit` unless `takeHandle` is
/// used to transfer ownership to the journal.
pub const InspectResult = struct {
    state: InspectState,
    handle: ?RuntimeHandle = null,

    pub fn deinit(self: *InspectResult, allocator_: std.mem.Allocator) void {
        if (self.handle) |*handle| deinitHandle(allocator_, handle);
        self.* = undefined;
    }

    pub fn takeHandle(self: *InspectResult) ?RuntimeHandle {
        const result = self.handle;
        self.handle = null;
        return result;
    }
};

pub const OwnedArgv = struct {
    allocator: std.mem.Allocator,
    argv: []const []const u8,

    pub fn deinit(self: *OwnedArgv) void {
        freeStrings(self.allocator, self.argv);
        self.* = undefined;
    }
};

pub const OwnedProcessCommand = struct {
    allocator: std.mem.Allocator,
    unit_name: []const u8,
    argv: []const []const u8,

    pub fn deinit(self: *OwnedProcessCommand) void {
        self.allocator.free(self.unit_name);
        freeStrings(self.allocator, self.argv);
        self.* = undefined;
    }
};

const OwnedManagedDropIn = struct {
    allocator: std.mem.Allocator,
    unit_name: []const u8,
    relative_path: []const u8,
    content: []const u8,
    fingerprint: [Sha256.digest_length]u8,

    fn deinit(self: *OwnedManagedDropIn) void {
        self.allocator.free(self.unit_name);
        self.allocator.free(self.relative_path);
        self.allocator.free(self.content);
        self.* = undefined;
    }
};

/// Start a generation-fenced accelerator runtime, or adopt an already-running
/// exact identity after a crash. The returned handle owns its string fields;
/// transfer it into agent_journal or release it with `deinitHandle`.
pub fn start(
    init: std.process.Init,
    deployment: orchestration.Deployment,
    access_plan: device_access.Plan,
    expected: ExpectedIdentity,
    artifact_path: ?[]const u8,
) !RuntimeHandle {
    if (builtin.os.tag != .linux) return error.RuntimeUnsupported;
    try validateStart(deployment, access_plan, expected);

    return switch (deployment.runtime.kind) {
        .docker => startContainer(init, .docker, deployment, access_plan, expected),
        .containerd => startContainer(init, .nerdctl, deployment, access_plan, expected),
        .process => startProcess(init, deployment, access_plan, expected, artifact_path),
        .systemd => startSystemd(init, deployment, access_plan, expected),
    };
}

/// Inspect by deterministic name/unit plus the complete expected identity.
/// Deployment is required because an existing systemd unit name is arbitrary
/// and cannot be reconstructed from RuntimeKind alone.
pub fn inspect(
    init: std.process.Init,
    deployment: orchestration.Deployment,
    expected: ExpectedIdentity,
) !InspectResult {
    if (builtin.os.tag != .linux) return error.RuntimeUnsupported;
    try expected.validate();
    if (!orchestration.validateDeployment(deployment)) return error.InvalidDeploymentSpec;
    if (!std.mem.eql(u8, deployment.name, expected.deployment) or
        deployment.revision != expected.revision)
        return error.DeploymentIdentityMismatch;

    return switch (deployment.runtime.kind) {
        .docker => inspectContainerByName(init, .docker, expected),
        .containerd => inspectContainerByName(init, .nerdctl, expected),
        .process => inspectTransientProcess(init, expected),
        .systemd => inspectExistingSystemd(
            init,
            deployment.runtime.reference orelse return error.MissingSystemdUnit,
            expected,
        ),
    };
}

/// Stop only the immutable persisted handle. A name is never substituted for
/// a full container ID, and an InvocationID/configuration mismatch is fenced.
pub fn stop(
    init: std.process.Init,
    expected: ExpectedIdentity,
    handle: RuntimeHandle,
) !void {
    if (builtin.os.tag != .linux) return error.RuntimeUnsupported;
    try expected.validate();
    try handle.validate();
    switch (handle) {
        .container => |container| try stopContainer(init, expected, container),
        .systemd => |systemd| if (systemd.configuration_fingerprint == null)
            try stopTransientProcess(init, expected, systemd)
        else
            try stopExistingSystemd(init, expected, systemd),
        .direct_process => return error.DirectProcessHandleUnsupported,
    }
}

/// Runtime health is true only when the persisted immutable handle is still
/// active and every generation/operation/configuration fence matches.
pub fn healthy(
    init: std.process.Init,
    expected: ExpectedIdentity,
    handle: RuntimeHandle,
) !bool {
    if (builtin.os.tag != .linux) return error.RuntimeUnsupported;
    try expected.validate();
    try handle.validate();
    return switch (handle) {
        .container => |container| containerHealthy(init, expected, container),
        .systemd => |systemd| if (systemd.configuration_fingerprint == null)
            transientProcessHealthy(init, expected, systemd)
        else
            existingSystemdHealthy(init, expected, systemd),
        .direct_process => error.DirectProcessHandleUnsupported,
    };
}

pub fn deinitHandle(allocator_: std.mem.Allocator, handle: *RuntimeHandle) void {
    switch (handle.*) {
        .container => |container| allocator_.free(container.full_id),
        .systemd => |systemd| {
            allocator_.free(systemd.unit_name);
            allocator_.free(systemd.invocation_id);
            if (systemd.configuration_fingerprint) |fingerprint|
                allocator_.free(fingerprint);
        },
        .direct_process => {},
    }
    handle.* = undefined;
}

/// Pure exact Docker/nerdctl argv builder used by production and tests.
pub fn buildContainerRunCommandAlloc(
    allocator_: std.mem.Allocator,
    engine: ContainerEngine,
    deployment: orchestration.Deployment,
    access_plan: device_access.Plan,
    expected: ExpectedIdentity,
) !OwnedArgv {
    try validateStart(deployment, access_plan, expected);
    switch (deployment.runtime.kind) {
        .docker => if (engine != .docker) return error.ContainerEngineMismatch,
        .containerd => if (engine != .nerdctl) return error.ContainerEngineMismatch,
        else => return error.ContainerRuntimeRequired,
    }
    const cdi_devices = switch (access_plan.access) {
        .cdi => |devices| devices,
        .host => return error.ContainerRequiresCdi,
    };
    if (cdi_devices.len == 0) return error.MissingCdiDevices;

    var argv: std.ArrayList([]const u8) = .empty;
    errdefer deinitStringList(allocator_, &argv);
    try appendContainerPrefix(allocator_, &argv, engine);
    try appendOwned(allocator_, &argv, "run");
    try appendOwned(allocator_, &argv, "-d");
    try appendOwned(allocator_, &argv, "--name");
    const name = try containerNameAlloc(allocator_, expected.allocation_id);
    defer allocator_.free(name);
    try appendOwned(allocator_, &argv, name);

    try appendLabel(allocator_, &argv, "io.nimbus.managed", "true");
    try appendLabel(allocator_, &argv, "io.nimbus.allocation-id", expected.allocation_id);
    try appendUnsignedLabel(allocator_, &argv, "io.nimbus.generation", expected.generation);
    try appendLabel(allocator_, &argv, "io.nimbus.deployment", expected.deployment);
    try appendUnsignedLabel(allocator_, &argv, "io.nimbus.revision", expected.revision);
    try appendLabel(allocator_, &argv, "io.nimbus.operation-id", expected.operation_id);
    try appendLabel(
        allocator_,
        &argv,
        "io.nimbus.access-fingerprint",
        expected.access_fingerprint_hex,
    );

    var previous: ?[]const u8 = null;
    for (cdi_devices) |device| {
        if (!device_access.isValidCdiDevice(device)) return error.InvalidCdiDevice;
        if (previous) |value| {
            const order = std.mem.order(u8, value, device);
            if (order == .eq) return error.DuplicateCdiDevice;
            if (order == .gt) return error.NonCanonicalCdiDevices;
        }
        previous = device;
        try appendOwned(allocator_, &argv, "--device");
        try appendOwned(allocator_, &argv, device);
    }

    if (deployment.restart_policy != .never) {
        try appendOwned(allocator_, &argv, "--restart");
        try appendOwned(allocator_, &argv, restartName(deployment.restart_policy));
    }
    try appendOwned(allocator_, &argv, deployment.runtime.reference.?);
    for (deployment.runtime.command) |argument|
        try appendOwned(allocator_, &argv, argument);

    return .{
        .allocator = allocator_,
        .argv = try argv.toOwnedSlice(allocator_),
    };
}

/// Pure systemd-run builder. The host_runtime module supplies exact device
/// policy; this layer adds the generation-fenced runtime identity.
pub fn buildProcessRunCommandAlloc(
    allocator_: std.mem.Allocator,
    deployment: orchestration.Deployment,
    access_plan: device_access.Plan,
    expected: ExpectedIdentity,
    artifact_path: ?[]const u8,
) !OwnedProcessCommand {
    try validateStart(deployment, access_plan, expected);
    if (deployment.runtime.kind != .process) return error.ProcessRuntimeRequired;

    var base = try host_runtime.planProcessAlloc(allocator_, access_plan, .{
        .workload_id = expected.allocation_id,
        .revision = expected.revision,
        .command = deployment.runtime.command,
        .artifact_path = artifact_path,
        .working_directory = deployment.runtime.working_directory,
    });
    defer base.deinit();

    var argv: std.ArrayList([]const u8) = .empty;
    errdefer deinitStringList(allocator_, &argv);
    const description = try systemdDescriptionAlloc(allocator_, expected);
    defer allocator_.free(description);
    const description_option = try std.fmt.allocPrint(
        allocator_,
        "--property=Description={s}",
        .{description},
    );
    defer allocator_.free(description_option);

    var inserted_identity = false;
    for (base.argv) |argument| {
        if (!inserted_identity and std.mem.eql(u8, argument, "--")) {
            try appendOwned(allocator_, &argv, description_option);
            inserted_identity = true;
        }
        try appendOwned(allocator_, &argv, argument);
    }
    if (!inserted_identity) return error.InvalidProcessPlan;

    const owned_unit_name = try allocator_.dupe(u8, base.unit_name);
    errdefer allocator_.free(owned_unit_name);
    const owned_argv = try argv.toOwnedSlice(allocator_);

    return .{
        .allocator = allocator_,
        .unit_name = owned_unit_name,
        .argv = owned_argv,
    };
}

fn validateStart(
    deployment: orchestration.Deployment,
    access_plan: device_access.Plan,
    expected: ExpectedIdentity,
) !void {
    try expected.validate();
    if (!orchestration.validateDeployment(deployment)) return error.InvalidDeploymentSpec;
    if (deployment.desired != .running) return error.DeploymentNotRunning;
    if (!std.mem.eql(u8, deployment.name, expected.deployment) or
        deployment.revision != expected.revision)
        return error.DeploymentIdentityMismatch;
    if (access_plan.device_ids.len == 0) return error.NoAssignedDevices;
    const actual_fingerprint = std.fmt.bytesToHex(access_plan.fingerprint, .lower);
    if (!std.mem.eql(u8, &actual_fingerprint, expected.access_fingerprint_hex))
        return error.AccessFingerprintMismatch;
}

fn startContainer(
    init: std.process.Init,
    engine: ContainerEngine,
    deployment: orchestration.Deployment,
    access_plan: device_access.Plan,
    expected: ExpectedIdentity,
) !RuntimeHandle {
    var observed = try inspectContainerByName(init, engine, expected);
    defer observed.deinit(init.gpa);
    switch (observed.state) {
        .matching_running, .matching_stopped => return observed.takeHandle() orelse
            error.RuntimeHandleUnavailable,
        .identity_mismatch => return error.RuntimeIdentityMismatch,
        .absent => {},
    }

    var command = try buildContainerRunCommandAlloc(
        init.gpa,
        engine,
        deployment,
        access_plan,
        expected,
    );
    defer command.deinit();
    var output = try runCommand(init, command.argv, 300);
    defer output.deinit();
    if (!output.succeeded) return error.RuntimeStartFailed;
    const full_id = try parseContainerRunId(output.stdout);

    var created = try inspectContainerById(init, engine, full_id, expected);
    defer created.deinit(init.gpa);
    if (created.state == .identity_mismatch) return error.RuntimeIdentityMismatch;
    if (created.state == .absent) return error.RuntimeStartUnobservable;
    const handle = created.handle orelse return error.RuntimeHandleUnavailable;
    if (!std.mem.eql(u8, handle.container.full_id, full_id))
        return error.RuntimeHandleMismatch;
    return created.takeHandle().?;
}

fn inspectContainerByName(
    init: std.process.Init,
    engine: ContainerEngine,
    expected: ExpectedIdentity,
) !InspectResult {
    const name = try containerNameAlloc(init.gpa, expected.allocation_id);
    defer init.gpa.free(name);
    if (!try containerExists(init, engine, .name, name)) return .{ .state = .absent };
    return inspectContainerTarget(init, engine, name, expected);
}

fn inspectContainerById(
    init: std.process.Init,
    engine: ContainerEngine,
    full_id: []const u8,
    expected: ExpectedIdentity,
) !InspectResult {
    if (!isLowerHex(full_id, 64)) return error.InvalidContainerId;
    if (!try containerExists(init, engine, .id, full_id)) return .{ .state = .absent };
    return inspectContainerTarget(init, engine, full_id, expected);
}

const ContainerLookup = enum { name, id };

fn containerExists(
    init: std.process.Init,
    engine: ContainerEngine,
    lookup: ContainerLookup,
    value: []const u8,
) !bool {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(init.gpa);
    try appendContainerPrefixBorrowed(&argv, init.gpa, engine);
    try argv.appendSlice(init.gpa, &.{ "ps", "-a", "--no-trunc", "--filter" });
    const filter = try std.fmt.allocPrint(
        init.gpa,
        "{s}={s}",
        .{ if (lookup == .name) "name" else "id", value },
    );
    defer init.gpa.free(filter);
    try argv.append(init.gpa, filter);
    try argv.appendSlice(init.gpa, &.{
        "--format",
        if (lookup == .name) "{{.Names}}" else "{{.ID}}",
    });
    var output = try runCommand(init, argv.items, 15);
    defer output.deinit();
    if (!output.succeeded) return error.RuntimeInspectFailed;
    var lines = std.mem.splitScalar(u8, output.stdout, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.eql(u8, line, value)) return true;
    }
    return false;
}

fn inspectContainerTarget(
    init: std.process.Init,
    engine: ContainerEngine,
    target: []const u8,
    expected: ExpectedIdentity,
) !InspectResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(init.gpa);
    try appendContainerPrefixBorrowed(&argv, init.gpa, engine);
    try argv.appendSlice(init.gpa, &.{
        "inspect",
        "--format",
        container_inspect_format,
        target,
    });
    var output = try runCommand(init, argv.items, 15);
    defer output.deinit();
    if (!output.succeeded) return error.RuntimeInspectFailed;
    return parseContainerInspectAlloc(init.gpa, engine, output.stdout, expected);
}

fn stopContainer(
    init: std.process.Init,
    expected: ExpectedIdentity,
    handle: agent_journal.ContainerHandle,
) !void {
    var observed = try inspectContainerById(init, handle.engine, handle.full_id, expected);
    defer observed.deinit(init.gpa);
    if (observed.state == .absent) return;
    if (observed.state == .identity_mismatch) return error.RuntimeIdentityMismatch;
    const current = observed.handle orelse return error.RuntimeHandleUnavailable;
    if (!std.mem.eql(u8, current.container.full_id, handle.full_id))
        return error.RuntimeHandleMismatch;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(init.gpa);
    try appendContainerPrefixBorrowed(&argv, init.gpa, handle.engine);
    try argv.appendSlice(init.gpa, &.{ "rm", "-f", handle.full_id });
    var output = try runCommand(init, argv.items, 60);
    defer output.deinit();
    if (!output.succeeded) return error.RuntimeStopFailed;
    if (try containerExists(init, handle.engine, .id, handle.full_id))
        return error.RuntimeStopUnconfirmed;
}

fn containerHealthy(
    init: std.process.Init,
    expected: ExpectedIdentity,
    handle: agent_journal.ContainerHandle,
) !bool {
    var observed = try inspectContainerById(init, handle.engine, handle.full_id, expected);
    defer observed.deinit(init.gpa);
    return switch (observed.state) {
        .absent, .matching_stopped => false,
        .identity_mismatch => error.RuntimeIdentityMismatch,
        .matching_running => blk: {
            const current = observed.handle orelse return error.RuntimeHandleUnavailable;
            if (!std.mem.eql(u8, current.container.full_id, handle.full_id))
                return error.RuntimeHandleMismatch;
            break :blk true;
        },
    };
}

fn parseContainerInspectAlloc(
    allocator_: std.mem.Allocator,
    engine: ContainerEngine,
    output: []const u8,
    expected: ExpectedIdentity,
) !InspectResult {
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    var fields: [9][]const u8 = undefined;
    var count: usize = 0;
    var iterator = std.mem.splitScalar(u8, trimmed, '|');
    while (iterator.next()) |field| {
        if (count == fields.len) return error.InvalidRuntimeOutput;
        fields[count] = field;
        count += 1;
    }
    if (count != fields.len or !isLowerHex(fields[0], 64))
        return error.InvalidRuntimeOutput;
    const running = if (std.mem.eql(u8, fields[1], "true"))
        true
    else if (std.mem.eql(u8, fields[1], "false"))
        false
    else
        return error.InvalidRuntimeOutput;

    if (!std.mem.eql(u8, fields[2], "true") or
        !std.mem.eql(u8, fields[3], expected.allocation_id) or
        !decimalMatches(fields[4], expected.generation) or
        !std.mem.eql(u8, fields[5], expected.deployment) or
        !decimalMatches(fields[6], expected.revision) or
        !std.mem.eql(u8, fields[7], expected.operation_id) or
        !std.mem.eql(u8, fields[8], expected.access_fingerprint_hex))
        return .{ .state = .identity_mismatch };

    return .{
        .state = if (running) .matching_running else .matching_stopped,
        .handle = .{ .container = .{
            .engine = engine,
            .full_id = try allocator_.dupe(u8, fields[0]),
        } },
    };
}

fn parseContainerRunId(stdout: []const u8) ![]const u8 {
    const value = std.mem.trim(u8, stdout, " \t\r\n");
    if (!isLowerHex(value, 64)) return error.InvalidContainerId;
    return value;
}

fn startProcess(
    init: std.process.Init,
    deployment: orchestration.Deployment,
    access_plan: device_access.Plan,
    expected: ExpectedIdentity,
    artifact_path: ?[]const u8,
) !RuntimeHandle {
    var command = try buildProcessRunCommandAlloc(
        init.gpa,
        deployment,
        access_plan,
        expected,
        artifact_path,
    );
    defer command.deinit();

    var observed = try inspectTransientProcessAtUnit(init, command.unit_name, expected);
    defer observed.deinit(init.gpa);
    switch (observed.state) {
        .matching_running, .matching_stopped => return observed.takeHandle() orelse
            error.RuntimeHandleUnavailable,
        .identity_mismatch => return error.RuntimeIdentityMismatch,
        .absent => {},
    }

    var output = try runCommand(init, command.argv, 60);
    defer output.deinit();
    if (!output.succeeded) return error.RuntimeStartFailed;
    var created = try inspectTransientProcessAtUnit(init, command.unit_name, expected);
    defer created.deinit(init.gpa);
    if (created.state == .identity_mismatch) return error.RuntimeIdentityMismatch;
    if (created.state == .absent) return error.RuntimeStartUnobservable;
    return created.takeHandle() orelse error.RuntimeHandleUnavailable;
}

fn inspectTransientProcess(
    init: std.process.Init,
    expected: ExpectedIdentity,
) !InspectResult {
    const unit_name = try transientUnitNameAlloc(init.gpa, expected);
    defer init.gpa.free(unit_name);
    return inspectTransientProcessAtUnit(init, unit_name, expected);
}

fn inspectTransientProcessAtUnit(
    init: std.process.Init,
    unit_name: []const u8,
    expected: ExpectedIdentity,
) !InspectResult {
    var status = try querySystemdUnit(init, unit_name);
    defer status.deinit();
    if (std.mem.eql(u8, status.load_state, "not-found")) return .{ .state = .absent };
    const description = try systemdDescriptionAlloc(init.gpa, expected);
    defer init.gpa.free(description);
    if (!std.mem.eql(u8, status.description, description))
        return .{ .state = .identity_mismatch };
    const running = std.mem.eql(u8, status.active_state, "active");
    if (!isLowerHex(status.invocation_id, 32)) {
        if (running) return error.InvalidSystemdInvocationId;
        return .{ .state = .matching_stopped };
    }
    return .{
        .state = if (running) .matching_running else .matching_stopped,
        .handle = try makeSystemdHandle(
            init.gpa,
            unit_name,
            status.invocation_id,
            null,
        ),
    };
}

fn stopTransientProcess(
    init: std.process.Init,
    expected: ExpectedIdentity,
    handle: agent_journal.SystemdHandle,
) !void {
    const unit_name = try transientUnitNameAlloc(init.gpa, expected);
    defer init.gpa.free(unit_name);
    if (!std.mem.eql(u8, unit_name, handle.unit_name))
        return error.RuntimeHandleMismatch;
    var observed = try inspectTransientProcessAtUnit(init, unit_name, expected);
    defer observed.deinit(init.gpa);
    if (observed.state == .absent) return;
    if (observed.state == .identity_mismatch) return error.RuntimeIdentityMismatch;
    try requireInvocation(observed.handle, handle.invocation_id);
    try systemctlUnit(init, "stop", unit_name, 60);
    // `systemd-run --collect` unloads the transient unit asynchronously. A
    // restart rotates the fenced description, so do not return until the old
    // unit name is actually reusable.
    for (0..20) |attempt| {
        var after = try querySystemdUnit(init, unit_name);
        defer after.deinit();
        if (std.mem.eql(u8, after.load_state, "not-found")) return;
        if (std.mem.eql(u8, after.active_state, "active"))
            return error.RuntimeStopUnconfirmed;
        if (attempt + 1 < 20) {
            const duration: std.Io.Clock.Duration = .{
                .clock = .boot,
                .raw = .fromMilliseconds(25),
            };
            try duration.sleep(init.io);
        }
    }
    return error.RuntimeStopUnconfirmed;
}

fn transientProcessHealthy(
    init: std.process.Init,
    expected: ExpectedIdentity,
    handle: agent_journal.SystemdHandle,
) !bool {
    const unit_name = try transientUnitNameAlloc(init.gpa, expected);
    defer init.gpa.free(unit_name);
    if (!std.mem.eql(u8, unit_name, handle.unit_name))
        return error.RuntimeHandleMismatch;
    var observed = try inspectTransientProcessAtUnit(init, unit_name, expected);
    defer observed.deinit(init.gpa);
    return switch (observed.state) {
        .absent, .matching_stopped => false,
        .identity_mismatch => error.RuntimeIdentityMismatch,
        .matching_running => blk: {
            try requireInvocation(observed.handle, handle.invocation_id);
            break :blk true;
        },
    };
}

fn startSystemd(
    init: std.process.Init,
    deployment: orchestration.Deployment,
    access_plan: device_access.Plan,
    expected: ExpectedIdentity,
) !RuntimeHandle {
    const unit_name = deployment.runtime.reference orelse return error.MissingSystemdUnit;
    var desired = try buildManagedDropInAlloc(init.gpa, unit_name, access_plan, expected);
    defer desired.deinit();
    const desired_fingerprint_hex = std.fmt.bytesToHex(desired.fingerprint, .lower);

    var observed = try inspectExistingSystemd(init, unit_name, expected);
    defer observed.deinit(init.gpa);
    if (observed.state == .matching_running or observed.state == .matching_stopped) {
        const actual_content = (try readDropInAlloc(init, desired.relative_path)) orelse
            return error.RuntimeIdentityMismatch;
        defer init.gpa.free(actual_content);
        if (!std.mem.eql(u8, actual_content, desired.content))
            return error.RuntimeConfigurationMismatch;
    }
    switch (observed.state) {
        .identity_mismatch => return error.RuntimeIdentityMismatch,
        .matching_running => {
            const handle = observed.handle orelse return error.RuntimeHandleUnavailable;
            if (!std.mem.eql(
                u8,
                handle.systemd.configuration_fingerprint.?,
                &desired_fingerprint_hex,
            )) return error.RuntimeConfigurationMismatch;
            return observed.takeHandle().?;
        },
        .matching_stopped => if (observed.handle) |handle| {
            if (!std.mem.eql(
                u8,
                handle.systemd.configuration_fingerprint.?,
                &desired_fingerprint_hex,
            )) return error.RuntimeConfigurationMismatch;
        },
        .absent => {
            // A pre-existing host service may currently be active without a
            // Nimbus drop-in. Stop it before introducing accelerator access.
            try systemctlUnit(init, "stop", unit_name, 60);
            try writeDropInAtomic(init, desired.relative_path, desired.content);
        },
    }

    try systemctlDaemonReload(init);
    try systemctlUnit(init, "restart", unit_name, 60);
    var created = try inspectExistingSystemd(init, unit_name, expected);
    defer created.deinit(init.gpa);
    if (created.state == .identity_mismatch) return error.RuntimeIdentityMismatch;
    if (created.state != .matching_running) return error.RuntimeStartUnobservable;
    const handle = created.handle orelse return error.RuntimeHandleUnavailable;
    if (!std.mem.eql(
        u8,
        handle.systemd.configuration_fingerprint.?,
        &desired_fingerprint_hex,
    )) return error.RuntimeConfigurationMismatch;
    return created.takeHandle().?;
}

fn inspectExistingSystemd(
    init: std.process.Init,
    unit_name: []const u8,
    expected: ExpectedIdentity,
) !InspectResult {
    if (!host_runtime.isSafeServiceUnitName(unit_name)) return error.InvalidSystemdUnit;
    const relative_path = try dropInRelativePathAlloc(init.gpa, unit_name);
    defer init.gpa.free(relative_path);
    const content = (try readDropInAlloc(init, relative_path)) orelse
        return .{ .state = .absent };
    defer init.gpa.free(content);
    if (!dropInIdentityMatches(content, expected))
        return .{ .state = .identity_mismatch };

    var fingerprint: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(content, &fingerprint, .{});
    const fingerprint_hex = std.fmt.bytesToHex(fingerprint, .lower);
    var status = try querySystemdUnit(init, unit_name);
    defer status.deinit();
    const running = std.mem.eql(u8, status.active_state, "active");
    if (!isLowerHex(status.invocation_id, 32)) {
        if (running) return error.InvalidSystemdInvocationId;
        return .{ .state = .matching_stopped };
    }
    return .{
        .state = if (running) .matching_running else .matching_stopped,
        .handle = try makeSystemdHandle(
            init.gpa,
            unit_name,
            status.invocation_id,
            &fingerprint_hex,
        ),
    };
}

fn stopExistingSystemd(
    init: std.process.Init,
    expected: ExpectedIdentity,
    handle: agent_journal.SystemdHandle,
) !void {
    const expected_configuration = handle.configuration_fingerprint orelse
        return error.MissingConfigurationFingerprint;
    const relative_path = try dropInRelativePathAlloc(init.gpa, handle.unit_name);
    defer init.gpa.free(relative_path);
    const content = (try readDropInAlloc(init, relative_path)) orelse
        return error.RuntimeIdentityMismatch;
    defer init.gpa.free(content);
    if (!dropInIdentityMatches(content, expected))
        return error.RuntimeIdentityMismatch;
    var fingerprint: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(content, &fingerprint, .{});
    const fingerprint_hex = std.fmt.bytesToHex(fingerprint, .lower);
    if (!std.mem.eql(u8, &fingerprint_hex, expected_configuration))
        return error.RuntimeConfigurationMismatch;

    var status = try querySystemdUnit(init, handle.unit_name);
    defer status.deinit();
    if (!std.mem.eql(u8, status.load_state, "not-found")) {
        if (!std.mem.eql(u8, status.invocation_id, handle.invocation_id))
            return error.RuntimeInvocationMismatch;
        try systemctlUnit(init, "stop", handle.unit_name, 60);
    }
    try deleteDropIn(init, relative_path);
    try systemctlDaemonReload(init);
    var after = try querySystemdUnit(init, handle.unit_name);
    defer after.deinit();
    if (std.mem.eql(u8, after.active_state, "active"))
        return error.RuntimeStopUnconfirmed;
}

fn existingSystemdHealthy(
    init: std.process.Init,
    expected: ExpectedIdentity,
    handle: agent_journal.SystemdHandle,
) !bool {
    const expected_configuration = handle.configuration_fingerprint orelse
        return error.MissingConfigurationFingerprint;
    var observed = try inspectExistingSystemd(init, handle.unit_name, expected);
    defer observed.deinit(init.gpa);
    return switch (observed.state) {
        .absent, .matching_stopped => false,
        .identity_mismatch => error.RuntimeIdentityMismatch,
        .matching_running => blk: {
            const current = observed.handle orelse return error.RuntimeHandleUnavailable;
            if (!std.mem.eql(u8, current.systemd.invocation_id, handle.invocation_id))
                return error.RuntimeInvocationMismatch;
            if (!std.mem.eql(
                u8,
                current.systemd.configuration_fingerprint.?,
                expected_configuration,
            )) return error.RuntimeConfigurationMismatch;
            break :blk true;
        },
    };
}

fn buildManagedDropInAlloc(
    allocator_: std.mem.Allocator,
    unit_name: []const u8,
    access_plan: device_access.Plan,
    expected: ExpectedIdentity,
) !OwnedManagedDropIn {
    var base = try host_runtime.planSystemdDropInAlloc(
        allocator_,
        access_plan,
        unit_name,
    );
    defer base.deinit();
    const content = try std.fmt.allocPrint(
        allocator_,
        "# Nimbus accelerator runtime v1\n" ++
            "# allocation_id={s}\n" ++
            "# generation={d}\n" ++
            "# deployment={s}\n" ++
            "# revision={d}\n" ++
            "# operation_id={s}\n" ++
            "# access_fingerprint={s}\n" ++
            "{s}",
        .{
            expected.allocation_id,
            expected.generation,
            expected.deployment,
            expected.revision,
            expected.operation_id,
            expected.access_fingerprint_hex,
            base.content,
        },
    );
    errdefer allocator_.free(content);
    var fingerprint: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(content, &fingerprint, .{});
    const owned_unit_name = try allocator_.dupe(u8, base.unit_name);
    errdefer allocator_.free(owned_unit_name);
    const owned_relative_path = try allocator_.dupe(u8, base.relative_path);
    errdefer allocator_.free(owned_relative_path);
    return .{
        .allocator = allocator_,
        .unit_name = owned_unit_name,
        .relative_path = owned_relative_path,
        .content = content,
        .fingerprint = fingerprint,
    };
}

fn dropInIdentityMatches(content: []const u8, expected: ExpectedIdentity) bool {
    var lines = std.mem.splitScalar(u8, content, '\n');
    if (!stringEquals(lines.next(), "# Nimbus accelerator runtime v1")) return false;
    if (!prefixedEquals(lines.next(), "# allocation_id=", expected.allocation_id)) return false;
    if (!prefixedDecimalEquals(lines.next(), "# generation=", expected.generation)) return false;
    if (!prefixedEquals(lines.next(), "# deployment=", expected.deployment)) return false;
    if (!prefixedDecimalEquals(lines.next(), "# revision=", expected.revision)) return false;
    if (!prefixedEquals(lines.next(), "# operation_id=", expected.operation_id)) return false;
    if (!prefixedEquals(
        lines.next(),
        "# access_fingerprint=",
        expected.access_fingerprint_hex,
    )) return false;
    return true;
}

const UnitStatus = struct {
    load_state: []const u8 = "",
    active_state: []const u8 = "",
    invocation_id: []const u8 = "",
    description: []const u8 = "",
};

const OwnedUnitStatus = struct {
    allocator: std.mem.Allocator,
    load_state: []const u8,
    active_state: []const u8,
    invocation_id: []const u8,
    description: []const u8,

    fn deinit(self: *OwnedUnitStatus) void {
        self.allocator.free(self.load_state);
        self.allocator.free(self.active_state);
        self.allocator.free(self.invocation_id);
        self.allocator.free(self.description);
        self.* = undefined;
    }
};

fn querySystemdUnit(init: std.process.Init, unit_name: []const u8) !OwnedUnitStatus {
    if (!host_runtime.isSafeServiceUnitName(unit_name)) return error.InvalidSystemdUnit;
    const argv = &.{
        "systemctl",
        "show",
        "--no-pager",
        "--property=LoadState",
        "--property=ActiveState",
        "--property=InvocationID",
        "--property=Description",
        "--",
        unit_name,
    };
    var output = try runCommand(init, argv, 15);
    defer output.deinit();
    // `systemctl show` can exit non-zero for a missing unit while still
    // returning LoadState=not-found. Parse first, then reject unexplained
    // failures.
    const status = parseSystemdShow(output.stdout) catch |err| {
        if (!output.succeeded) return error.RuntimeInspectFailed;
        return err;
    };
    if (!output.succeeded and !std.mem.eql(u8, status.load_state, "not-found"))
        return error.RuntimeInspectFailed;
    const load_state = try init.gpa.dupe(u8, status.load_state);
    errdefer init.gpa.free(load_state);
    const active_state = try init.gpa.dupe(u8, status.active_state);
    errdefer init.gpa.free(active_state);
    const invocation_id = try init.gpa.dupe(u8, status.invocation_id);
    errdefer init.gpa.free(invocation_id);
    const description = try init.gpa.dupe(u8, status.description);
    return .{
        .allocator = init.gpa,
        .load_state = load_state,
        .active_state = active_state,
        .invocation_id = invocation_id,
        .description = description,
    };
}

fn parseSystemdShow(output: []const u8) !UnitStatus {
    var result: UnitStatus = .{};
    var seen_load = false;
    var seen_active = false;
    var seen_invocation = false;
    var seen_description = false;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse
            return error.InvalidRuntimeOutput;
        const key = line[0..equals];
        const value = line[equals + 1 ..];
        if (std.mem.eql(u8, key, "LoadState")) {
            if (seen_load) return error.InvalidRuntimeOutput;
            seen_load = true;
            result.load_state = value;
        } else if (std.mem.eql(u8, key, "ActiveState")) {
            if (seen_active) return error.InvalidRuntimeOutput;
            seen_active = true;
            result.active_state = value;
        } else if (std.mem.eql(u8, key, "InvocationID")) {
            if (seen_invocation) return error.InvalidRuntimeOutput;
            seen_invocation = true;
            result.invocation_id = value;
        } else if (std.mem.eql(u8, key, "Description")) {
            if (seen_description) return error.InvalidRuntimeOutput;
            seen_description = true;
            result.description = value;
        } else {
            return error.InvalidRuntimeOutput;
        }
    }
    if (!seen_load or !seen_active or !seen_invocation or !seen_description)
        return error.InvalidRuntimeOutput;
    return result;
}

fn systemctlUnit(
    init: std.process.Init,
    operation: []const u8,
    unit_name: []const u8,
    timeout_seconds: u32,
) !void {
    if (!std.mem.eql(u8, operation, "stop") and
        !std.mem.eql(u8, operation, "restart"))
        return error.InvalidSystemctlOperation;
    if (!host_runtime.isSafeServiceUnitName(unit_name)) return error.InvalidSystemdUnit;
    var output = try runCommand(
        init,
        &.{ "systemctl", operation, "--", unit_name },
        timeout_seconds,
    );
    defer output.deinit();
    if (!output.succeeded) return if (std.mem.eql(u8, operation, "stop"))
        error.RuntimeStopFailed
    else
        error.RuntimeStartFailed;
}

fn systemctlDaemonReload(init: std.process.Init) !void {
    var output = try runCommand(init, &.{ "systemctl", "daemon-reload" }, 60);
    defer output.deinit();
    if (!output.succeeded) return error.SystemdDaemonReloadFailed;
}

fn readDropInAlloc(init: std.process.Init, relative_path: []const u8) !?[]u8 {
    var root = try std.Io.Dir.openDirAbsolute(init.io, systemd_runtime_root, .{});
    defer root.close(init.io);
    var file = root.openFile(init.io, relative_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(init.io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(init.io, &read_buffer);
    return reader.interface.allocRemaining(init.gpa, .limited(max_drop_in_bytes)) catch |err| switch (err) {
        error.StreamTooLong => return error.DropInTooLarge,
        else => return err,
    };
}

fn writeDropInAtomic(
    init: std.process.Init,
    relative_path: []const u8,
    content: []const u8,
) !void {
    if (content.len == 0 or content.len > max_drop_in_bytes) return error.InvalidDropIn;
    var root = try std.Io.Dir.openDirAbsolute(init.io, systemd_runtime_root, .{});
    defer root.close(init.io);
    const parent = std.fs.path.dirname(relative_path) orelse return error.InvalidDropInPath;
    try root.createDirPath(init.io, parent);
    var atomic = try root.createFileAtomic(init.io, relative_path, .{
        .make_path = false,
        .replace = true,
    });
    defer atomic.deinit(init.io);
    var write_buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(init.io, &write_buffer);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
    try atomic.file.sync(init.io);
    try atomic.replace(init.io);
}

fn deleteDropIn(init: std.process.Init, relative_path: []const u8) !void {
    var root = try std.Io.Dir.openDirAbsolute(init.io, systemd_runtime_root, .{});
    defer root.close(init.io);
    root.deleteFile(init.io, relative_path) catch |err| switch (err) {
        error.FileNotFound => return error.RuntimeIdentityMismatch,
        else => return err,
    };
}

fn dropInRelativePathAlloc(
    allocator_: std.mem.Allocator,
    unit_name: []const u8,
) ![]const u8 {
    if (!host_runtime.isSafeServiceUnitName(unit_name)) return error.InvalidSystemdUnit;
    return std.fmt.allocPrint(
        allocator_,
        "{s}.d/{s}",
        .{ unit_name, host_runtime.drop_in_file_name },
    );
}

const CommandOutput = struct {
    allocator: std.mem.Allocator,
    stdout: []u8,
    stderr: []u8,
    succeeded: bool,

    fn deinit(self: *CommandOutput) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
        self.* = undefined;
    }
};

fn runCommand(
    init: std.process.Init,
    argv: []const []const u8,
    timeout_seconds: u32,
) !CommandOutput {
    const result = try std.process.run(init.gpa, init.io, .{
        .argv = argv,
        .stdout_limit = .limited(max_runtime_output_bytes),
        .stderr_limit = .limited(max_runtime_output_bytes),
        .timeout = .{ .duration = .{
            .clock = .boot,
            .raw = .fromSeconds(timeout_seconds),
        } },
    });
    return .{
        .allocator = init.gpa,
        .stdout = result.stdout,
        .stderr = result.stderr,
        .succeeded = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        },
    };
}

fn appendContainerPrefix(
    allocator_: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    engine: ContainerEngine,
) !void {
    switch (engine) {
        .docker => try appendOwned(allocator_, argv, "docker"),
        .nerdctl => {
            try appendOwned(allocator_, argv, "nerdctl");
            try appendOwned(allocator_, argv, "--namespace");
            try appendOwned(allocator_, argv, "nimbus");
        },
    }
}

fn appendContainerPrefixBorrowed(
    argv: *std.ArrayList([]const u8),
    allocator_: std.mem.Allocator,
    engine: ContainerEngine,
) !void {
    switch (engine) {
        .docker => try argv.append(allocator_, "docker"),
        .nerdctl => try argv.appendSlice(allocator_, &.{
            "nerdctl",
            "--namespace",
            "nimbus",
        }),
    }
}

fn appendLabel(
    allocator_: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    key: []const u8,
    value: []const u8,
) !void {
    try appendOwned(allocator_, argv, "--label");
    const label = try std.fmt.allocPrint(allocator_, "{s}={s}", .{ key, value });
    errdefer allocator_.free(label);
    try argv.append(allocator_, label);
}

fn appendUnsignedLabel(
    allocator_: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    key: []const u8,
    value: u64,
) !void {
    const encoded = try std.fmt.allocPrint(allocator_, "{d}", .{value});
    defer allocator_.free(encoded);
    try appendLabel(allocator_, argv, key, encoded);
}

fn appendOwned(
    allocator_: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    value: []const u8,
) !void {
    const owned = try allocator_.dupe(u8, value);
    errdefer allocator_.free(owned);
    try argv.append(allocator_, owned);
}

fn deinitStringList(allocator_: std.mem.Allocator, values: *std.ArrayList([]const u8)) void {
    for (values.items) |value| allocator_.free(value);
    values.deinit(allocator_);
}

fn freeStrings(allocator_: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator_.free(value);
    allocator_.free(values);
}

fn containerNameAlloc(
    allocator_: std.mem.Allocator,
    allocation_id: []const u8,
) ![]const u8 {
    var hash = Sha256.init(.{});
    hash.update("nimbus.accelerator-runtime.container-name.v1\x00");
    hashString(&hash, allocation_id);
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator_, "nimbus-accel-{s}", .{hex});
}

fn transientUnitNameAlloc(
    allocator_: std.mem.Allocator,
    expected: ExpectedIdentity,
) ![]const u8 {
    var fingerprint: [Sha256.digest_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&fingerprint, expected.access_fingerprint_hex) catch
        return error.InvalidAccessFingerprint;
    // Keep this contract identical to host_runtime.transientUnitNameAlloc.
    var hash = Sha256.init(.{});
    hash.update("nimbus.host-runtime.transient-unit.v1\x00");
    hashString(&hash, expected.allocation_id);
    var revision: [8]u8 = undefined;
    std.mem.writeInt(u64, &revision, expected.revision, .big);
    hash.update(&revision);
    hash.update(&fingerprint);
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator_, "nimbus-accel-{s}.service", .{hex});
}

fn systemdDescriptionAlloc(
    allocator_: std.mem.Allocator,
    expected: ExpectedIdentity,
) ![]const u8 {
    const fingerprint = identityFingerprint(expected);
    const hex = std.fmt.bytesToHex(fingerprint, .lower);
    return std.fmt.allocPrint(allocator_, "nimbus-accelerator-v1:{s}", .{hex});
}

fn identityFingerprint(expected: ExpectedIdentity) [Sha256.digest_length]u8 {
    var hash = Sha256.init(.{});
    hash.update("nimbus.accelerator-runtime.identity.v1\x00");
    hashString(&hash, expected.allocation_id);
    hashUnsigned(&hash, expected.generation);
    hashString(&hash, expected.deployment);
    hashUnsigned(&hash, expected.revision);
    hashString(&hash, expected.operation_id);
    hashString(&hash, expected.access_fingerprint_hex);
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn hashString(hash: *Sha256, value: []const u8) void {
    hashUnsigned(hash, value.len);
    hash.update(value);
}

fn hashUnsigned(hash: *Sha256, value: anytype) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, @intCast(value), .big);
    hash.update(&encoded);
}

fn makeSystemdHandle(
    allocator_: std.mem.Allocator,
    unit_name: []const u8,
    invocation_id: []const u8,
    configuration_fingerprint: ?[]const u8,
) !RuntimeHandle {
    const owned_unit = try allocator_.dupe(u8, unit_name);
    errdefer allocator_.free(owned_unit);
    const owned_invocation = try allocator_.dupe(u8, invocation_id);
    errdefer allocator_.free(owned_invocation);
    const owned_configuration = if (configuration_fingerprint) |value|
        try allocator_.dupe(u8, value)
    else
        null;
    return .{ .systemd = .{
        .unit_name = owned_unit,
        .invocation_id = owned_invocation,
        .configuration_fingerprint = owned_configuration,
    } };
}

fn requireInvocation(observed: ?RuntimeHandle, expected_invocation: []const u8) !void {
    const current = observed orelse return error.RuntimeHandleUnavailable;
    if (current != .systemd or
        !std.mem.eql(u8, current.systemd.invocation_id, expected_invocation))
        return error.RuntimeInvocationMismatch;
}

fn restartName(policy: orchestration.RestartPolicy) []const u8 {
    return switch (policy) {
        .never => "no",
        .on_failure => "on-failure",
        .always => "always",
    };
}

fn decimalMatches(value: []const u8, expected: u64) bool {
    var buffer: [32]u8 = undefined;
    const canonical = std.fmt.bufPrint(&buffer, "{d}", .{expected}) catch return false;
    return std.mem.eql(u8, value, canonical);
}

fn stringEquals(optional: ?[]const u8, expected: []const u8) bool {
    const value = optional orelse return false;
    return std.mem.eql(u8, value, expected);
}

fn prefixedEquals(optional: ?[]const u8, prefix: []const u8, expected: []const u8) bool {
    const value = optional orelse return false;
    return std.mem.startsWith(u8, value, prefix) and
        std.mem.eql(u8, value[prefix.len..], expected);
}

fn prefixedDecimalEquals(optional: ?[]const u8, prefix: []const u8, expected: u64) bool {
    const value = optional orelse return false;
    return std.mem.startsWith(u8, value, prefix) and
        decimalMatches(value[prefix.len..], expected);
}

fn isLowerHex(value: []const u8, expected_length: usize) bool {
    if (value.len != expected_length) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn expectedIdentity() ExpectedIdentity {
    return .{
        .allocation_id = "alloc-vision-7",
        .generation = 4,
        .deployment = "vision",
        .revision = 7,
        .operation_id = "op-vision-7",
        .access_fingerprint_hex = "5a" ** 32,
    };
}

fn containerDeployment(kind: orchestration.RuntimeKind) orchestration.Deployment {
    return .{
        .name = "vision",
        .revision = 7,
        .runtime = .{
            .kind = kind,
            .reference = "registry.example/vision@sha256:" ++ "ab" ** 32,
            .command = &.{ "serve", "--port=9000" },
        },
        .resources = .{ .accelerators = .{ .kind = .gpu } },
        .targets = .{ .all = true },
    };
}

fn cdiPlan() device_access.Plan {
    return .{
        .device_ids = &.{ "gpu:a", "gpu:b" },
        .access = .{ .cdi = &.{
            "nvidia.com/gpu=GPU-a",
            "nvidia.com/gpu=GPU-b",
        } },
        .fingerprint = [_]u8{0x5a} ** Sha256.digest_length,
    };
}

fn hostPlan() device_access.Plan {
    return .{
        .device_ids = &.{"gpu:a"},
        .access = .{ .host = .{
            .completeness = .vendor_verified,
            .device_nodes = &.{
                .{ .path = "/dev/nvidia0", .permissions = .read_write },
                .{ .path = "/dev/nvidiactl", .permissions = .read },
            },
            .environment = &.{.{
                .name = "CUDA_VISIBLE_DEVICES",
                .value = "GPU-a",
            }},
        } },
        .fingerprint = [_]u8{0x5a} ** Sha256.digest_length,
    };
}

test "container argv carries full identity and exact sorted CDI devices" {
    const expected = expectedIdentity();
    var command = try buildContainerRunCommandAlloc(
        std.testing.allocator,
        .docker,
        containerDeployment(.docker),
        cdiPlan(),
        expected,
    );
    defer command.deinit();

    try std.testing.expectEqualStrings("docker", command.argv[0]);
    try std.testing.expectEqualStrings("run", command.argv[1]);
    try std.testing.expectEqualStrings("-d", command.argv[2]);
    try expectArgumentPair(command.argv, "--label", "io.nimbus.managed=true");
    try expectArgumentPair(
        command.argv,
        "--label",
        "io.nimbus.allocation-id=alloc-vision-7",
    );
    try expectArgumentPair(command.argv, "--label", "io.nimbus.generation=4");
    try expectArgumentPair(command.argv, "--label", "io.nimbus.deployment=vision");
    try expectArgumentPair(command.argv, "--label", "io.nimbus.revision=7");
    try expectArgumentPair(command.argv, "--label", "io.nimbus.operation-id=op-vision-7");
    try expectArgumentPair(
        command.argv,
        "--label",
        "io.nimbus.access-fingerprint=" ++ "5a" ** 32,
    );
    try expectArgumentPair(command.argv, "--device", "nvidia.com/gpu=GPU-a");
    try expectArgumentPair(command.argv, "--device", "nvidia.com/gpu=GPU-b");
    try std.testing.expect(!containsArgument(command.argv, "--privileged"));
    try std.testing.expect(!containsArgument(command.argv, "--gpus"));
}

test "nerdctl argv uses the isolated Nimbus namespace" {
    var command = try buildContainerRunCommandAlloc(
        std.testing.allocator,
        .nerdctl,
        containerDeployment(.containerd),
        cdiPlan(),
        expectedIdentity(),
    );
    defer command.deinit();
    try std.testing.expectEqualStrings("nerdctl", command.argv[0]);
    try std.testing.expectEqualStrings("--namespace", command.argv[1]);
    try std.testing.expectEqualStrings("nimbus", command.argv[2]);
    try std.testing.expectEqualStrings("run", command.argv[3]);
}

test "container builder rejects host access and noncanonical CDI" {
    try std.testing.expectError(
        error.ContainerRequiresCdi,
        buildContainerRunCommandAlloc(
            std.testing.allocator,
            .docker,
            containerDeployment(.docker),
            hostPlan(),
            expectedIdentity(),
        ),
    );
    var noncanonical = cdiPlan();
    noncanonical.access = .{ .cdi = &.{
        "nvidia.com/gpu=GPU-b",
        "nvidia.com/gpu=GPU-a",
    } };
    try std.testing.expectError(
        error.NonCanonicalCdiDevices,
        buildContainerRunCommandAlloc(
            std.testing.allocator,
            .docker,
            containerDeployment(.docker),
            noncanonical,
            expectedIdentity(),
        ),
    );
}

test "container inspect parser fences every identity label" {
    const id = "ab" ** 32;
    const matching = id ++ "|true|true|alloc-vision-7|4|vision|7|op-vision-7|" ++ "5a" ** 32 ++ "\n";
    var parsed = try parseContainerInspectAlloc(
        std.testing.allocator,
        .docker,
        matching,
        expectedIdentity(),
    );
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(InspectState.matching_running, parsed.state);
    try std.testing.expectEqualStrings(id, parsed.handle.?.container.full_id);

    const stale = id ++ "|false|true|alloc-vision-7|3|vision|7|op-vision-7|" ++ "5a" ** 32;
    var stale_parsed = try parseContainerInspectAlloc(
        std.testing.allocator,
        .docker,
        stale,
        expectedIdentity(),
    );
    defer stale_parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(InspectState.identity_mismatch, stale_parsed.state);
    try std.testing.expect(stale_parsed.handle == null);
}

test "container stdout must be one full lowercase immutable ID" {
    try std.testing.expectEqualStrings("ab" ** 32, try parseContainerRunId("ab" ** 32 ++ "\n"));
    try std.testing.expectError(error.InvalidContainerId, parseContainerRunId("abcd\n"));
    try std.testing.expectError(error.InvalidContainerId, parseContainerRunId("AB" ** 32));
    try std.testing.expectError(
        error.InvalidContainerId,
        parseContainerRunId("ab" ** 32 ++ "\nextra"),
    );
}

test "accelerator process uses a fenced transient systemd service" {
    const deployment: orchestration.Deployment = .{
        .name = "vision",
        .revision = 7,
        .runtime = .{
            .kind = .process,
            .command = &.{ "/opt/vision/serve", "--port=9000" },
            .working_directory = "/opt/vision",
        },
        .resources = .{ .accelerators = .{ .kind = .gpu } },
        .targets = .{ .all = true },
    };
    var command = try buildProcessRunCommandAlloc(
        std.testing.allocator,
        deployment,
        hostPlan(),
        expectedIdentity(),
        null,
    );
    defer command.deinit();
    try std.testing.expect(std.mem.startsWith(u8, command.unit_name, "nimbus-accel-"));
    try std.testing.expectEqualStrings("systemd-run", command.argv[0]);
    try std.testing.expect(containsArgument(command.argv, "--property=DevicePolicy=closed"));
    try std.testing.expect(containsArgument(
        command.argv,
        "--property=DeviceAllow=/dev/nvidia0 rw",
    ));
    var found_description = false;
    for (command.argv) |argument| {
        if (std.mem.startsWith(u8, argument, "--property=Description=nimbus-accelerator-v1:"))
            found_description = true;
    }
    try std.testing.expect(found_description);
    const separator = findArgument(command.argv, "--") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("/opt/vision/serve", command.argv[separator + 1]);
}

test "accelerator process preserves verified artifact substitution" {
    const deployment: orchestration.Deployment = .{
        .name = "vision",
        .revision = 7,
        .runtime = .{
            .kind = .process,
            .command = &.{ "{artifact}", "--serve" },
        },
        .artifact = .{
            .source = "file:///opt/artifacts/vision",
            .sha256 = "ab" ** 32,
        },
        .resources = .{ .accelerators = .{ .kind = .gpu } },
        .targets = .{ .all = true },
    };
    var command = try buildProcessRunCommandAlloc(
        std.testing.allocator,
        deployment,
        hostPlan(),
        expectedIdentity(),
        "/var/lib/nimbus/artifacts/vision/7",
    );
    defer command.deinit();
    const separator = findArgument(command.argv, "--") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(
        "/var/lib/nimbus/artifacts/vision/7",
        command.argv[separator + 1],
    );
    try std.testing.expectError(
        error.ArtifactRequired,
        buildProcessRunCommandAlloc(
            std.testing.allocator,
            deployment,
            hostPlan(),
            expectedIdentity(),
            null,
        ),
    );
}

test "managed systemd drop-in binds full identity and detects changes" {
    const expected = expectedIdentity();
    var drop_in = try buildManagedDropInAlloc(
        std.testing.allocator,
        "vision.service",
        hostPlan(),
        expected,
    );
    defer drop_in.deinit();
    try std.testing.expect(dropInIdentityMatches(drop_in.content, expected));
    try std.testing.expect(std.mem.indexOf(
        u8,
        drop_in.content,
        "DevicePolicy=closed\nDeviceAllow=\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        drop_in.content,
        "DeviceAllow=/dev/nvidia0 rw\n",
    ) != null);
    var stale = expected;
    stale.operation_id = "op-vision-8";
    try std.testing.expect(!dropInIdentityMatches(drop_in.content, stale));

    var changed = try std.testing.allocator.dupe(u8, drop_in.content);
    defer std.testing.allocator.free(changed);
    changed[changed.len - 1] = if (changed[changed.len - 1] == '\n') ' ' else '\n';
    var changed_hash: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(changed, &changed_hash, .{});
    try std.testing.expect(!std.mem.eql(u8, &changed_hash, &drop_in.fingerprint));
}

test "systemd show parser is order independent and strict" {
    const output =
        "InvocationID=0123456789abcdef0123456789abcdef\n" ++
        "Description=nimbus-accelerator-v1:abcd\n" ++
        "ActiveState=active\n" ++
        "LoadState=loaded\n";
    const parsed = try parseSystemdShow(output);
    try std.testing.expectEqualStrings("loaded", parsed.load_state);
    try std.testing.expectEqualStrings("active", parsed.active_state);
    try std.testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef",
        parsed.invocation_id,
    );
    try std.testing.expectError(
        error.InvalidRuntimeOutput,
        parseSystemdShow("LoadState=loaded\nActiveState=active\n"),
    );
}

test "expected identity requires canonical operation and fingerprint fences" {
    try expectedIdentity().validate();
    var invalid = expectedIdentity();
    invalid.access_fingerprint_hex = "5A" ** 32;
    try std.testing.expectError(error.InvalidAccessFingerprint, invalid.validate());
    invalid = expectedIdentity();
    invalid.operation_id = "bad operation";
    try std.testing.expectError(error.InvalidOperationId, invalid.validate());
}

test "runtime names are deterministic without embedding control-plane IDs" {
    const first = try containerNameAlloc(std.testing.allocator, "alloc-vision-7");
    defer std.testing.allocator.free(first);
    const second = try containerNameAlloc(std.testing.allocator, "alloc-vision-7");
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.startsWith(u8, first, "nimbus-accel-"));
    try std.testing.expect(std.mem.indexOf(u8, first, "alloc-vision") == null);

    const unit = try transientUnitNameAlloc(std.testing.allocator, expectedIdentity());
    defer std.testing.allocator.free(unit);
    try std.testing.expect(host_runtime.isSafeServiceUnitName(unit));
}

fn expectArgumentPair(
    arguments: []const []const u8,
    option: []const u8,
    value: []const u8,
) !void {
    for (arguments[0..arguments.len -| 1], 0..) |argument, index| {
        if (!std.mem.eql(u8, argument, option)) continue;
        if (std.mem.eql(u8, arguments[index + 1], value)) return;
    }
    return error.TestExpectedEqual;
}

fn containsArgument(arguments: []const []const u8, expected: []const u8) bool {
    return findArgument(arguments, expected) != null;
}

fn findArgument(arguments: []const []const u8, expected: []const u8) ?usize {
    for (arguments, 0..) |argument, index| {
        if (std.mem.eql(u8, argument, expected)) return index;
    }
    return null;
}
