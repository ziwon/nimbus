const std = @import("std");
const device_access = @import("device_access.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const max_command_arguments = 256;
pub const max_argument_bytes = 4096;
pub const max_workload_id_bytes = 256;
pub const drop_in_file_name = "50-nimbus-device-access.conf";

pub const ProcessRequest = struct {
    /// Stable control-plane identity. It is hashed rather than embedded in the
    /// transient unit name.
    workload_id: []const u8,
    revision: u64,
    command: []const []const u8,
    artifact_path: ?[]const u8 = null,
    working_directory: ?[]const u8 = null,
};

/// A direct argv plan for systemd-run. Every string and slice is owned.
pub const OwnedProcessPlan = struct {
    allocator: std.mem.Allocator,
    unit_name: []const u8,
    argv: []const []const u8,
    fingerprint: [Sha256.digest_length]u8,

    pub fn deinit(self: *OwnedProcessPlan) void {
        self.allocator.free(self.unit_name);
        freeStrings(self.allocator, self.argv);
        self.* = undefined;
    }
};

/// A pure existing-unit configuration plan. The caller decides whether and
/// how to write and activate it.
pub const OwnedDropIn = struct {
    allocator: std.mem.Allocator,
    unit_name: []const u8,
    relative_path: []const u8,
    content: []const u8,
    /// SHA-256 of content, suitable for no-op/update checks.
    fingerprint: [Sha256.digest_length]u8,

    pub fn deinit(self: *OwnedDropIn) void {
        self.allocator.free(self.unit_name);
        self.allocator.free(self.relative_path);
        self.allocator.free(self.content);
        self.* = undefined;
    }
};

pub const PlanError = std.mem.Allocator.Error || error{
    CdiAccessUnsupported,
    NoAssignedDevices,
    TooManyAssignedDevices,
    InvalidAssignedDevice,
    DuplicateAssignedDevice,
    UnverifiedHostAccess,
    MissingDeviceNodes,
    TooManyDeviceNodes,
    InvalidDevicePath,
    DuplicateDeviceNode,
    TooManyEnvironmentVariables,
    InvalidEnvironmentName,
    InvalidEnvironmentValue,
    DuplicateEnvironmentVariable,
    InvalidWorkloadId,
    InvalidRevision,
    MissingCommand,
    TooManyCommandArguments,
    InvalidCommandArgument,
    ExecutableMustBeAbsolute,
    ArtifactRequired,
    InvalidArtifactPath,
    InvalidWorkingDirectory,
    InvalidUnitName,
};

/// Build a fail-closed accelerator process launch. The workload is run in a
/// transient service rather than as an unrestricted child of the agent.
pub fn planProcessAlloc(
    allocator: std.mem.Allocator,
    access_plan: device_access.Plan,
    request: ProcessRequest,
) PlanError!OwnedProcessPlan {
    var host = try canonicalHostAlloc(allocator, access_plan);
    defer host.deinit();
    try validateProcessRequest(request);

    const unit_name = try transientUnitNameAlloc(
        allocator,
        request.workload_id,
        request.revision,
        access_plan.fingerprint,
    );
    errdefer allocator.free(unit_name);

    var argv: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (argv.items) |argument| allocator.free(argument);
        argv.deinit(allocator);
    }

    try appendOwned(allocator, &argv, "systemd-run");
    {
        const unit_option = try std.fmt.allocPrint(allocator, "--unit={s}", .{unit_name});
        errdefer allocator.free(unit_option);
        try argv.append(allocator, unit_option);
    }
    try appendOwned(allocator, &argv, "--collect");
    try appendOwned(allocator, &argv, "--quiet");
    try appendOwned(allocator, &argv, "--property=Type=exec");
    try appendOwned(allocator, &argv, "--property=DevicePolicy=closed");

    for (host.nodes) |node| {
        const option = try std.fmt.allocPrint(
            allocator,
            "--property=DeviceAllow={s} {s}",
            .{ node.path, permissionName(node.permissions) },
        );
        errdefer allocator.free(option);
        try argv.append(allocator, option);
    }
    for (host.environment) |variable| {
        const option = try std.fmt.allocPrint(
            allocator,
            "--setenv={s}={s}",
            .{ variable.name, variable.value },
        );
        errdefer allocator.free(option);
        try argv.append(allocator, option);
    }
    if (request.working_directory) |path| {
        const option = try std.fmt.allocPrint(
            allocator,
            "--working-directory={s}",
            .{path},
        );
        errdefer allocator.free(option);
        try argv.append(allocator, option);
    }
    try appendOwned(allocator, &argv, "--");
    for (request.command) |argument| {
        const resolved = if (std.mem.eql(u8, argument, "{artifact}"))
            request.artifact_path orelse return error.ArtifactRequired
        else
            argument;
        try appendOwned(allocator, &argv, resolved);
    }

    const owned_argv = try argv.toOwnedSlice(allocator);
    return .{
        .allocator = allocator,
        .unit_name = unit_name,
        .argv = owned_argv,
        .fingerprint = fingerprintArguments(owned_argv),
    };
}

/// Build a deterministic drop-in for an existing service. Environment values
/// are quoted according to systemd.syntax and percent signs are doubled so
/// unit specifiers cannot alter the value.
pub fn planSystemdDropInAlloc(
    allocator: std.mem.Allocator,
    access_plan: device_access.Plan,
    unit_name: []const u8,
) PlanError!OwnedDropIn {
    if (!isSafeServiceUnitName(unit_name)) return error.InvalidUnitName;
    var host = try canonicalHostAlloc(allocator, access_plan);
    defer host.deinit();

    const owned_unit_name = try allocator.dupe(u8, unit_name);
    errdefer allocator.free(owned_unit_name);
    const relative_path = try std.fmt.allocPrint(
        allocator,
        "{s}.d/{s}",
        .{ unit_name, drop_in_file_name },
    );
    errdefer allocator.free(relative_path);

    var content: std.ArrayList(u8) = .empty;
    errdefer content.deinit(allocator);
    try content.appendSlice(
        allocator,
        "[Service]\nDevicePolicy=closed\nDeviceAllow=\n",
    );
    for (host.nodes) |node| {
        try content.appendSlice(allocator, "DeviceAllow=");
        try content.appendSlice(allocator, node.path);
        try content.append(allocator, ' ');
        try content.appendSlice(allocator, permissionName(node.permissions));
        try content.append(allocator, '\n');
    }
    for (host.environment) |variable| {
        try content.appendSlice(allocator, "Environment=\"");
        try content.appendSlice(allocator, variable.name);
        try content.append(allocator, '=');
        try appendSystemdQuoted(allocator, &content, variable.value);
        try content.appendSlice(allocator, "\"\n");
    }

    const owned_content = try content.toOwnedSlice(allocator);
    var fingerprint: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(owned_content, &fingerprint, .{});
    return .{
        .allocator = allocator,
        .unit_name = owned_unit_name,
        .relative_path = relative_path,
        .content = owned_content,
        .fingerprint = fingerprint,
    };
}

pub fn isSafeServiceUnitName(value: []const u8) bool {
    if (value.len <= ".service".len or value.len > 255) return false;
    if (!std.mem.endsWith(u8, value, ".service")) return false;
    if (!std.ascii.isAlphanumeric(value[0])) return false;
    if (std.mem.indexOf(u8, value, "..") != null) return false;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '-', '_', '.', '@', ':' => {},
            else => return false,
        }
    }
    return true;
}

const CanonicalHost = struct {
    allocator: std.mem.Allocator,
    nodes: []device_access.DeviceNode,
    environment: []device_access.EnvironmentVariable,

    fn deinit(self: *CanonicalHost) void {
        self.allocator.free(self.nodes);
        self.allocator.free(self.environment);
        self.* = undefined;
    }
};

fn canonicalHostAlloc(
    allocator: std.mem.Allocator,
    plan: device_access.Plan,
) PlanError!CanonicalHost {
    if (plan.device_ids.len == 0) return error.NoAssignedDevices;
    if (plan.device_ids.len > device_access.max_devices)
        return error.TooManyAssignedDevices;
    for (plan.device_ids, 0..) |device_id, index| {
        if (!device_access.isValidDeviceId(device_id))
            return error.InvalidAssignedDevice;
        for (plan.device_ids[0..index]) |previous| {
            if (std.mem.eql(u8, previous, device_id))
                return error.DuplicateAssignedDevice;
        }
    }

    const access = switch (plan.access) {
        .cdi => return error.CdiAccessUnsupported,
        .host => |host_access| host_access,
    };
    if (access.completeness != .vendor_verified)
        return error.UnverifiedHostAccess;
    if (access.device_nodes.len == 0) return error.MissingDeviceNodes;
    if (access.device_nodes.len >
        device_access.max_devices * device_access.max_device_nodes_per_binding)
        return error.TooManyDeviceNodes;
    if (access.environment.len >
        device_access.max_devices * device_access.max_environment_per_binding)
        return error.TooManyEnvironmentVariables;

    const nodes = try allocator.dupe(device_access.DeviceNode, access.device_nodes);
    errdefer allocator.free(nodes);
    std.mem.sort(device_access.DeviceNode, nodes, {}, lessDeviceNode);
    for (nodes, 0..) |node, index| {
        if (!isSafeSystemdDevicePath(node.path)) return error.InvalidDevicePath;
        if (index > 0 and std.mem.eql(u8, nodes[index - 1].path, node.path))
            return error.DuplicateDeviceNode;
    }

    const environment = try allocator.dupe(
        device_access.EnvironmentVariable,
        access.environment,
    );
    errdefer allocator.free(environment);
    std.mem.sort(device_access.EnvironmentVariable, environment, {}, lessEnvironment);
    for (environment, 0..) |variable, index| {
        if (!isAllowedEnvironmentName(variable.name))
            return error.InvalidEnvironmentName;
        if (!isValidEnvironmentValue(variable.value))
            return error.InvalidEnvironmentValue;
        if (index > 0 and std.mem.eql(
            u8,
            environment[index - 1].name,
            variable.name,
        )) return error.DuplicateEnvironmentVariable;
    }

    return .{
        .allocator = allocator,
        .nodes = nodes,
        .environment = environment,
    };
}

fn validateProcessRequest(request: ProcessRequest) PlanError!void {
    if (request.workload_id.len == 0 or
        request.workload_id.len > max_workload_id_bytes)
        return error.InvalidWorkloadId;
    for (request.workload_id) |byte| {
        if (byte < 0x21 or byte > 0x7e) return error.InvalidWorkloadId;
    }
    if (request.revision == 0) return error.InvalidRevision;
    if (request.command.len == 0) return error.MissingCommand;
    if (request.command.len > max_command_arguments)
        return error.TooManyCommandArguments;
    for (request.command) |argument| {
        if (argument.len == 0 or argument.len > max_argument_bytes or
            std.mem.indexOfScalar(u8, argument, 0) != null)
            return error.InvalidCommandArgument;
    }
    if (request.artifact_path) |path| {
        if (!isSafeAbsolutePath(path)) return error.InvalidArtifactPath;
    }
    if (request.working_directory) |path| {
        if (!isSafeAbsolutePath(path)) return error.InvalidWorkingDirectory;
    }

    const executable = if (std.mem.eql(u8, request.command[0], "{artifact}"))
        request.artifact_path orelse return error.ArtifactRequired
    else
        request.command[0];
    if (!isSafeAbsolutePath(executable)) return error.ExecutableMustBeAbsolute;
}

fn transientUnitNameAlloc(
    allocator: std.mem.Allocator,
    workload_id: []const u8,
    revision: u64,
    access_fingerprint: [Sha256.digest_length]u8,
) std.mem.Allocator.Error![]const u8 {
    var hash = Sha256.init(.{});
    hash.update("nimbus.host-runtime.transient-unit.v1\x00");
    hashString(&hash, workload_id);
    var encoded_revision: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded_revision, revision, .big);
    hash.update(&encoded_revision);
    hash.update(&access_fingerprint);
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "nimbus-accel-{s}.service", .{hex});
}

fn isSafeAbsolutePath(value: []const u8) bool {
    if (value.len == 0 or value.len > max_argument_bytes or value[0] != '/')
        return false;
    for (value) |byte| {
        if (byte == 0 or byte < 0x20 or byte == 0x7f) return false;
    }
    var components = std.mem.splitScalar(u8, value[1..], '/');
    while (components.next()) |component| {
        if (component.len == 0) continue;
        if (std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn isSafeSystemdDevicePath(path: []const u8) bool {
    if (!device_access.isValidDevicePath(path)) return false;
    for (path) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '/', '.', '_', ':', '+', '-', '=' => {},
            else => return false,
        }
    }
    return true;
}

fn isAllowedEnvironmentName(name: []const u8) bool {
    const allowed = [_][]const u8{
        "CUDA_VISIBLE_DEVICES",
        "ROCR_VISIBLE_DEVICES",
        "HIP_VISIBLE_DEVICES",
        "ZE_AFFINITY_MASK",
        "NIMBUS_ACCELERATOR_IDS",
    };
    for (&allowed) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn isValidEnvironmentValue(value: []const u8) bool {
    if (value.len > device_access.max_environment_value_bytes) return false;
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

fn permissionName(value: device_access.Permissions) []const u8 {
    return switch (value) {
        .read => "r",
        .read_write => "rw",
    };
}

fn appendSystemdQuoted(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    value: []const u8,
) std.mem.Allocator.Error!void {
    for (value) |byte| switch (byte) {
        '"' => try output.appendSlice(allocator, "\\\""),
        '\\' => try output.appendSlice(allocator, "\\\\"),
        '%' => try output.appendSlice(allocator, "%%"),
        else => try output.append(allocator, byte),
    };
}

fn appendOwned(
    allocator: std.mem.Allocator,
    values: *std.ArrayList([]const u8),
    value: []const u8,
) std.mem.Allocator.Error!void {
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try values.append(allocator, owned);
}

fn freeStrings(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn lessDeviceNode(_: void, left: device_access.DeviceNode, right: device_access.DeviceNode) bool {
    return std.mem.lessThan(u8, left.path, right.path);
}

fn lessEnvironment(
    _: void,
    left: device_access.EnvironmentVariable,
    right: device_access.EnvironmentVariable,
) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

fn fingerprintArguments(arguments: []const []const u8) [Sha256.digest_length]u8 {
    var hash = Sha256.init(.{});
    hash.update("nimbus.host-runtime.process-plan.v1\x00");
    var encoded_count: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded_count, @intCast(arguments.len), .big);
    hash.update(&encoded_count);
    for (arguments) |argument| hashString(&hash, argument);
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn hashString(hash: *Sha256, value: []const u8) void {
    var encoded_length: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded_length, @intCast(value.len), .big);
    hash.update(&encoded_length);
    hash.update(value);
}

fn samplePlan(access: device_access.Access) device_access.Plan {
    return .{
        .device_ids = &.{"gpu:a"},
        .access = access,
        .fingerprint = [_]u8{0x5a} ** Sha256.digest_length,
    };
}

test "accelerator process plan is deterministic and fail closed" {
    const access: device_access.HostAccess = .{
        .completeness = .vendor_verified,
        .device_nodes = &.{
            .{ .path = "/dev/nvidiactl", .permissions = .read },
            .{ .path = "/dev/nvidia0", .permissions = .read_write },
        },
        .environment = &.{
            .{ .name = "NIMBUS_ACCELERATOR_IDS", .value = "gpu:a" },
            .{ .name = "CUDA_VISIBLE_DEVICES", .value = "0" },
        },
    };
    const request: ProcessRequest = .{
        .workload_id = "vision/revision",
        .revision = 7,
        .command = &.{ "{artifact}", "--model", "edge" },
        .artifact_path = "/opt/nimbus/artifacts/vision",
        .working_directory = "/var/lib/nimbus/vision",
    };
    var first = try planProcessAlloc(std.testing.allocator, samplePlan(.{ .host = access }), request);
    defer first.deinit();
    var second = try planProcessAlloc(std.testing.allocator, samplePlan(.{ .host = access }), request);
    defer second.deinit();

    try std.testing.expect(isSafeServiceUnitName(first.unit_name));
    try std.testing.expectEqualStrings(first.unit_name, second.unit_name);
    try std.testing.expectEqualSlices(u8, &first.fingerprint, &second.fingerprint);
    try std.testing.expectEqualStrings("systemd-run", first.argv[0]);
    try std.testing.expectEqualStrings("--collect", first.argv[2]);
    try std.testing.expectEqualStrings("--quiet", first.argv[3]);
    try std.testing.expectEqualStrings("--property=Type=exec", first.argv[4]);
    try std.testing.expectEqualStrings("--property=DevicePolicy=closed", first.argv[5]);
    try std.testing.expectEqualStrings(
        "--property=DeviceAllow=/dev/nvidia0 rw",
        first.argv[6],
    );
    try std.testing.expectEqualStrings(
        "--property=DeviceAllow=/dev/nvidiactl r",
        first.argv[7],
    );
    try std.testing.expectEqualStrings("--setenv=CUDA_VISIBLE_DEVICES=0", first.argv[8]);
    try std.testing.expectEqualStrings(
        "--setenv=NIMBUS_ACCELERATOR_IDS=gpu:a",
        first.argv[9],
    );
    try std.testing.expectEqualStrings(
        "--working-directory=/var/lib/nimbus/vision",
        first.argv[10],
    );
    try std.testing.expectEqualStrings("--", first.argv[11]);
    try std.testing.expectEqualStrings("/opt/nimbus/artifacts/vision", first.argv[12]);
    try std.testing.expectEqualStrings("--model", first.argv[13]);
    try std.testing.expectEqualStrings("edge", first.argv[14]);
}

test "process planner rejects CDI advisory and unsafe process inputs" {
    const cdi = samplePlan(.{ .cdi = &.{"nvidia.com/gpu=0"} });
    const request: ProcessRequest = .{
        .workload_id = "vision",
        .revision = 1,
        .command = &.{"/opt/vision"},
    };
    try std.testing.expectError(
        error.CdiAccessUnsupported,
        planProcessAlloc(std.testing.allocator, cdi, request),
    );

    const advisory = samplePlan(.{ .host = .{
        .completeness = .advisory,
        .device_nodes = &.{.{ .path = "/dev/nvidia0", .permissions = .read_write }},
    } });
    try std.testing.expectError(
        error.UnverifiedHostAccess,
        planProcessAlloc(std.testing.allocator, advisory, request),
    );

    const host = samplePlan(.{ .host = .{
        .completeness = .vendor_verified,
        .device_nodes = &.{.{ .path = "/dev/nvidia0", .permissions = .read_write }},
    } });
    var bad = request;
    bad.command = &.{"vision"};
    try std.testing.expectError(
        error.ExecutableMustBeAbsolute,
        planProcessAlloc(std.testing.allocator, host, bad),
    );
    bad.command = &.{"{artifact}"};
    try std.testing.expectError(
        error.ArtifactRequired,
        planProcessAlloc(std.testing.allocator, host, bad),
    );
    bad.command = &.{"/opt/vision"};
    bad.working_directory = "/var/lib/../escape";
    try std.testing.expectError(
        error.InvalidWorkingDirectory,
        planProcessAlloc(std.testing.allocator, host, bad),
    );
}

test "existing unit drop-in resets and applies exact access" {
    const host = samplePlan(.{ .host = .{
        .completeness = .vendor_verified,
        .device_nodes = &.{
            .{ .path = "/dev/dri/renderD128", .permissions = .read_write },
            .{ .path = "/dev/dri/card0", .permissions = .read },
        },
        .environment = &.{.{
            .name = "ZE_AFFINITY_MASK",
            .value = "gpu 0;%n\\\"quoted\"",
        }},
    } });
    var drop_in = try planSystemdDropInAlloc(
        std.testing.allocator,
        host,
        "vision@edge.service",
    );
    defer drop_in.deinit();

    try std.testing.expectEqualStrings("vision@edge.service", drop_in.unit_name);
    try std.testing.expectEqualStrings(
        "vision@edge.service.d/50-nimbus-device-access.conf",
        drop_in.relative_path,
    );
    try std.testing.expectEqualStrings(
        "[Service]\n" ++
            "DevicePolicy=closed\n" ++
            "DeviceAllow=\n" ++
            "DeviceAllow=/dev/dri/card0 r\n" ++
            "DeviceAllow=/dev/dri/renderD128 rw\n" ++
            "Environment=\"ZE_AFFINITY_MASK=gpu 0;%%n\\\\\\\"quoted\\\"\"\n",
        drop_in.content,
    );
    var expected: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(drop_in.content, &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &drop_in.fingerprint);
}

test "drop-in rejects unsafe units paths duplicates and environment" {
    const valid_host: device_access.Access = .{ .host = .{
        .completeness = .vendor_verified,
        .device_nodes = &.{.{ .path = "/dev/nvidia0", .permissions = .read_write }},
    } };
    try std.testing.expectError(
        error.InvalidUnitName,
        planSystemdDropInAlloc(std.testing.allocator, samplePlan(valid_host), "../vision.service"),
    );

    const duplicate = samplePlan(.{ .host = .{
        .completeness = .vendor_verified,
        .device_nodes = &.{
            .{ .path = "/dev/nvidia0", .permissions = .read },
            .{ .path = "/dev/nvidia0", .permissions = .read_write },
        },
    } });
    try std.testing.expectError(
        error.DuplicateDeviceNode,
        planSystemdDropInAlloc(std.testing.allocator, duplicate, "vision.service"),
    );

    const unsafe_path = samplePlan(.{ .host = .{
        .completeness = .vendor_verified,
        .device_nodes = &.{.{ .path = "/dev/gpu\"bad", .permissions = .read_write }},
    } });
    try std.testing.expectError(
        error.InvalidDevicePath,
        planSystemdDropInAlloc(std.testing.allocator, unsafe_path, "vision.service"),
    );

    const unsafe_environment = samplePlan(.{ .host = .{
        .completeness = .vendor_verified,
        .device_nodes = &.{.{ .path = "/dev/nvidia0", .permissions = .read_write }},
        .environment = &.{.{ .name = "LD_PRELOAD", .value = "/tmp/inject.so" }},
    } });
    try std.testing.expectError(
        error.InvalidEnvironmentName,
        planSystemdDropInAlloc(
            std.testing.allocator,
            unsafe_environment,
            "vision.service",
        ),
    );
}

fn processPlanWithAllocator(allocator: std.mem.Allocator) !void {
    const host = samplePlan(.{ .host = .{
        .completeness = .vendor_verified,
        .device_nodes = &.{
            .{ .path = "/dev/nvidia0", .permissions = .read_write },
            .{ .path = "/dev/nvidiactl", .permissions = .read_write },
        },
        .environment = &.{.{ .name = "CUDA_VISIBLE_DEVICES", .value = "0" }},
    } });
    var plan = try planProcessAlloc(allocator, host, .{
        .workload_id = "vision",
        .revision = 3,
        .command = &.{ "/opt/vision/bin/server", "--device", "gpu" },
        .working_directory = "/var/lib/nimbus/vision",
    });
    defer plan.deinit();
}

test "process plan cleans up every partial allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        processPlanWithAllocator,
        .{},
    );
}

fn dropInWithAllocator(allocator: std.mem.Allocator) !void {
    const host = samplePlan(.{ .host = .{
        .completeness = .vendor_verified,
        .device_nodes = &.{
            .{ .path = "/dev/dri/card0", .permissions = .read },
            .{ .path = "/dev/dri/renderD128", .permissions = .read_write },
        },
        .environment = &.{.{ .name = "ZE_AFFINITY_MASK", .value = "0.0" }},
    } });
    var plan = try planSystemdDropInAlloc(allocator, host, "vision.service");
    defer plan.deinit();
}

test "drop-in cleans up every partial allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        dropInWithAllocator,
        .{},
    );
}
