const std = @import("std");
const builtin = @import("builtin");
const accelerator = @import("accelerator.zig");
const artifact_cache = @import("artifact_cache.zig");
const artifact_selector = @import("artifact_selector.zig");
const client = @import("client.zig");
const device_access = @import("device_access.zig");
const orchestration = @import("orchestration.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Enabled = struct {
    process: bool = false,
    systemd: bool = false,
    docker: bool = false,
    containerd: bool = false,

    pub fn allows(self: Enabled, kind: orchestration.RuntimeKind) bool {
        return switch (kind) {
            .process => self.process,
            .systemd => self.systemd,
            .docker => self.docker,
            .containerd => self.containerd,
        };
    }

    pub fn any(self: Enabled) bool {
        return self.process or self.systemd or self.docker or self.containerd;
    }
};

pub const AppliedRecord = struct {
    name: []const u8,
    revision: u64,
    runtime: orchestration.RuntimeKind,
    reference: ?[]const u8 = null,
    pid: ?u64 = null,
    /// Linux `/proc/<pid>/stat` start-time ticks prevent killing a reused PID.
    process_start_ticks: ?u64 = null,
    spec_json: []const u8,
};

pub const ApplyResult = struct {
    pid: ?u64 = null,
    process_start_ticks: ?u64 = null,
};

pub const OwnedCommand = struct {
    allocator: std.mem.Allocator,
    argv: []const []const u8,

    pub fn deinit(self: *OwnedCommand) void {
        for (self.argv) |argument| self.allocator.free(argument);
        self.allocator.free(self.argv);
        self.* = undefined;
    }
};

pub const Options = struct {
    enabled: Enabled,
    state_dir: []const u8,
    artifact_public_key_hex: ?[]const u8,
    require_artifact_signatures: bool,
    max_artifact_bytes: u64,
    max_artifact_cache_bytes: u64 = 16 * 1024 * 1024 * 1024,
};

pub fn parseEnabled(value: []const u8) !Enabled {
    var result: Enabled = .{};
    var iterator = std.mem.splitScalar(u8, value, ',');
    while (iterator.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t");
        if (item.len == 0) continue;
        if (std.mem.eql(u8, item, "process")) {
            result.process = true;
        } else if (std.mem.eql(u8, item, "systemd")) {
            result.systemd = true;
        } else if (std.mem.eql(u8, item, "docker")) {
            result.docker = true;
        } else if (std.mem.eql(u8, item, "containerd")) {
            result.containerd = true;
        } else {
            return error.UnknownRuntime;
        }
    }
    return result;
}

pub fn apply(
    init: std.process.Init,
    deployment: orchestration.Deployment,
    artifact_path: ?[]const u8,
) !ApplyResult {
    return applyWithAccess(init, deployment, artifact_path, null);
}

pub fn applyWithAccess(
    init: std.process.Init,
    deployment: orchestration.Deployment,
    artifact_path: ?[]const u8,
    access_plan: ?device_access.Plan,
) !ApplyResult {
    if (access_plan != null and builtin.os.tag != .linux)
        return error.RuntimeUnsupported;
    return switch (deployment.runtime.kind) {
        .process => if (access_plan == null)
            try startProcess(init, deployment, artifact_path)
        else
            error.HostDeviceIsolationUnavailable,
        .systemd => {
            if (access_plan != null) return error.HostDeviceIsolationUnavailable;
            const unit = deployment.runtime.reference.?;
            if (!try commandSucceeded(init, &.{ "systemctl", "restart", "--", unit }, 60))
                return error.RuntimeApplyFailed;
            return .{};
        },
        .docker => {
            try replaceContainer(init, "docker", deployment, access_plan);
            return .{};
        },
        .containerd => {
            try replaceContainer(init, "nerdctl", deployment, access_plan);
            return .{};
        },
    };
}

pub fn stop(init: std.process.Init, record: AppliedRecord) !void {
    switch (record.runtime) {
        .process => try stopProcess(init, record),
        .systemd => {
            const unit = record.reference orelse return;
            if (!try commandSucceeded(init, &.{ "systemctl", "stop", "--", unit }, 60))
                return error.RuntimeStopFailed;
        },
        .docker => try removeContainer(init, "docker", record.name),
        .containerd => try removeContainer(init, "nerdctl", record.name),
    }
}

pub fn runtimeHealthy(init: std.process.Init, record: AppliedRecord) !bool {
    return switch (record.runtime) {
        .process => processAlive(init, record),
        .systemd => if (record.reference) |unit|
            commandSucceeded(init, &.{ "systemctl", "is-active", "--quiet", "--", unit }, 10)
        else
            false,
        .docker => containerHealthy(init, "docker", record.name),
        .containerd => containerHealthy(init, "nerdctl", record.name),
    };
}

pub fn healthCheck(
    init: std.process.Init,
    deployment: orchestration.Deployment,
    record: AppliedRecord,
) !bool {
    if (deployment.health_check.kind == .runtime)
        return runtimeHealthy(init, record);
    return applicationHealthCheck(init, deployment);
}

/// Run the deployment's application-level probe after a caller has already
/// verified its own immutable runtime handle. A runtime-only check succeeds at
/// this layer because exact process/container ownership is adapter-specific.
pub fn applicationHealthCheck(
    init: std.process.Init,
    deployment: orchestration.Deployment,
) !bool {
    const health = deployment.health_check;
    return switch (health.kind) {
        .runtime => true,
        .http => blk: {
            var buffer: [4096]u8 = undefined;
            const result = client.getJson(init, health.target.?, null, &buffer) catch break :blk false;
            const code = @intFromEnum(result.status);
            break :blk code >= 200 and code < 400;
        },
        .tcp => tcpHealthy(init, health.target.?, health.timeout_seconds),
        .command => commandSucceeded(init, health.command, health.timeout_seconds),
    };
}

pub fn prepareArtifact(
    init: std.process.Init,
    deployment: orchestration.Deployment,
    options: Options,
) !?[]u8 {
    return prepareArtifactFor(init, deployment, options, &.{});
}

pub fn prepareArtifactFor(
    init: std.process.Init,
    deployment: orchestration.Deployment,
    options: Options,
    selected_accelerators: []const accelerator.Device,
) !?[]u8 {
    return prepareArtifactVariantFor(init, deployment, options, selected_accelerators, null);
}

pub fn prepareArtifactVariantFor(
    init: std.process.Init,
    deployment: orchestration.Deployment,
    options: Options,
    selected_accelerators: []const accelerator.Device,
    variant_name: ?[]const u8,
) !?[]u8 {
    return prepareArtifactForMode(
        init,
        deployment,
        options,
        selected_accelerators,
        variant_name,
        true,
    );
}

pub fn preflightArtifact(
    init: std.process.Init,
    deployment: orchestration.Deployment,
    options: Options,
) !?[]u8 {
    return preflightArtifactFor(init, deployment, options, &.{});
}

pub fn preflightArtifactFor(
    init: std.process.Init,
    deployment: orchestration.Deployment,
    options: Options,
    selected_accelerators: []const accelerator.Device,
) !?[]u8 {
    return preflightArtifactVariantFor(init, deployment, options, selected_accelerators, null);
}

pub fn preflightArtifactVariantFor(
    init: std.process.Init,
    deployment: orchestration.Deployment,
    options: Options,
    selected_accelerators: []const accelerator.Device,
    variant_name: ?[]const u8,
) !?[]u8 {
    return prepareArtifactForMode(
        init,
        deployment,
        options,
        selected_accelerators,
        variant_name,
        false,
    );
}

pub fn releaseArtifactPin(
    init: std.process.Init,
    options: Options,
    deployment: []const u8,
) !void {
    try artifact_cache.unpin(init, options.state_dir, deployment);
}

fn prepareArtifactForMode(
    init: std.process.Init,
    deployment: orchestration.Deployment,
    options: Options,
    selected_accelerators: []const accelerator.Device,
    variant_name: ?[]const u8,
    pin_active: bool,
) !?[]u8 {
    const selector_context: artifact_selector.Context = .{
        .os = @tagName(builtin.target.os.tag),
        .arch = @tagName(builtin.target.cpu.arch),
        .abi = @tagName(builtin.target.abi),
        .accelerators = selected_accelerators,
    };
    const selection = if (variant_name) |name|
        try artifact_selector.selectNamed(deployment, selector_context, name)
    else
        (try artifact_selector.select(deployment, selector_context)) orelse return null;
    const artifact = selection.artifact;
    try verifySignaturePolicy(
        init.gpa,
        selection,
        options.artifact_public_key_hex,
        options.require_artifact_signatures,
    );

    var digest_lower: [Sha256.digest_length * 2]u8 = undefined;
    _ = std.ascii.lowerString(&digest_lower, artifact.sha256);
    const final_path = try artifact_cache.contentPathAlloc(
        init.gpa,
        options.state_dir,
        &digest_lower,
    );
    errdefer init.gpa.free(final_path);
    const cache_hit = fileDigestMatches(init, final_path, &digest_lower) catch |err| switch (err) {
        error.FileNotFound => false,
        else => return err,
    };
    if (cache_hit) {
        if (pin_active)
            try artifact_cache.pin(init, options.state_dir, deployment.name, &digest_lower);
        return final_path;
    }

    const parts_dir = try std.fs.path.join(
        init.gpa,
        &.{ options.state_dir, "artifacts", "parts" },
    );
    defer init.gpa.free(parts_dir);
    try std.Io.Dir.cwd().createDirPath(init.io, parts_dir);
    const temporary_path = try std.fmt.allocPrint(
        init.gpa,
        "{s}/{s}-{d}.part",
        .{ parts_dir, deployment.name, deployment.revision },
    );
    defer init.gpa.free(temporary_path);
    std.Io.Dir.cwd().deleteFile(init.io, temporary_path) catch {};
    errdefer std.Io.Dir.cwd().deleteFile(init.io, temporary_path) catch {};

    if (std.mem.startsWith(u8, artifact.source, "file://")) {
        const source_path = artifact.source["file://".len..];
        if (!std.fs.path.isAbsolute(source_path)) return error.ArtifactPathMustBeAbsolute;
        try copyFile(init, source_path, temporary_path, options.max_artifact_bytes);
    } else if (std.mem.startsWith(u8, artifact.source, "http://")) {
        try downloadFile(init, artifact.source, temporary_path, options.max_artifact_bytes);
    } else {
        return error.UnsupportedArtifactSource;
    }

    {
        var downloaded = try std.Io.Dir.cwd().openFile(init.io, temporary_path, .{});
        defer downloaded.close(init.io);
        if (try downloaded.length(init.io) > options.max_artifact_bytes)
            return error.ArtifactTooLarge;
        try downloaded.setPermissions(init.io, .executable_file);
    }
    if (!try fileDigestMatches(init, temporary_path, artifact.sha256))
        return error.ArtifactDigestMismatch;
    const stat = try std.Io.Dir.cwd().statFile(init.io, temporary_path, .{
        .follow_symlinks = false,
    });
    const admitted_path = try artifact_cache.admit(
        init,
        options.state_dir,
        &digest_lower,
        temporary_path,
        stat.size,
        options.max_artifact_cache_bytes,
    );
    errdefer init.gpa.free(admitted_path);
    init.gpa.free(final_path);
    if (pin_active)
        try artifact_cache.pin(init, options.state_dir, deployment.name, &digest_lower);
    return admitted_path;
}

fn verifySignaturePolicy(
    allocator: std.mem.Allocator,
    selection: artifact_selector.Selection,
    public_key_hex: ?[]const u8,
    required: bool,
) !void {
    const artifact = selection.artifact;
    const signature_hex = artifact.signature_ed25519 orelse {
        if (required) return error.ArtifactSignatureRequired;
        return;
    };
    const key_hex = public_key_hex orelse return error.ArtifactPublicKeyRequired;
    if (key_hex.len != Ed25519.PublicKey.encoded_length * 2)
        return error.InvalidArtifactPublicKey;

    var key_bytes: [Ed25519.PublicKey.encoded_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&key_bytes, key_hex) catch return error.InvalidArtifactPublicKey;
    var signature_bytes: [Ed25519.Signature.encoded_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&signature_bytes, signature_hex) catch
        return error.InvalidArtifactSignature;
    const public_key = Ed25519.PublicKey.fromBytes(key_bytes) catch
        return error.InvalidArtifactPublicKey;
    const signature = Ed25519.Signature.fromBytes(signature_bytes);
    const message = try signatureMessageAlloc(allocator, selection);
    defer allocator.free(message);
    signature.verify(message, public_key) catch return error.ArtifactSignatureInvalid;
}

fn signatureMessageAlloc(
    allocator: std.mem.Allocator,
    selection: artifact_selector.Selection,
) ![]u8 {
    var digest_lower: [64]u8 = undefined;
    _ = std.ascii.lowerString(&digest_lower, selection.artifact.sha256);
    const variant = selection.variant orelse return allocator.dupe(u8, &digest_lower);
    var message: std.ArrayList(u8) = .empty;
    errdefer message.deinit(allocator);
    try message.appendSlice(allocator, "nimbus.artifact-variant.v1\x00");
    try appendSignatureField(allocator, &message, variant.name);
    try appendSignatureField(allocator, &message, selection.artifact.source);
    try appendSignatureField(allocator, &message, &digest_lower);
    try appendOptionalSignatureField(allocator, &message, variant.selector.os);
    try appendOptionalSignatureField(allocator, &message, variant.selector.arch);
    try appendOptionalSignatureField(allocator, &message, variant.selector.abi);
    if (variant.selector.accelerator_kind) |kind| {
        try message.append(allocator, 1);
        try appendSignatureField(allocator, &message, @tagName(kind));
    } else {
        try message.append(allocator, 0);
    }
    try appendOptionalSignatureField(
        allocator,
        &message,
        variant.selector.accelerator_vendor,
    );
    try appendOptionalSignatureField(
        allocator,
        &message,
        variant.selector.accelerator_model,
    );
    try appendSignatureLength(
        allocator,
        &message,
        variant.selector.accelerator_capabilities.len,
    );
    for (variant.selector.accelerator_capabilities) |capability|
        try appendSignatureField(allocator, &message, capability);
    try message.append(allocator, @intFromBool(variant.fallback));
    return message.toOwnedSlice(allocator);
}

fn appendOptionalSignatureField(
    allocator: std.mem.Allocator,
    message: *std.ArrayList(u8),
    value: ?[]const u8,
) !void {
    if (value) |present| {
        try message.append(allocator, 1);
        try appendSignatureField(allocator, message, present);
    } else {
        try message.append(allocator, 0);
    }
}

fn appendSignatureField(
    allocator: std.mem.Allocator,
    message: *std.ArrayList(u8),
    value: []const u8,
) !void {
    try appendSignatureLength(allocator, message, value.len);
    try message.appendSlice(allocator, value);
}

fn appendSignatureLength(
    allocator: std.mem.Allocator,
    message: *std.ArrayList(u8),
    length: usize,
) !void {
    if (length > std.math.maxInt(u32)) return error.SignatureDescriptorTooLarge;
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, @intCast(length), .big);
    try message.appendSlice(allocator, &encoded);
}

fn startProcess(
    init: std.process.Init,
    deployment: orchestration.Deployment,
    artifact_path: ?[]const u8,
) !ApplyResult {
    if (builtin.os.tag != .linux)
        return error.RuntimeUnsupported;

    const command = deployment.runtime.command;
    const argv = try init.gpa.alloc([]const u8, command.len);
    defer init.gpa.free(argv);
    for (command, 0..) |argument, index| {
        argv[index] = if (std.mem.eql(u8, argument, "{artifact}"))
            artifact_path orelse return error.ArtifactRequired
        else
            argument;
    }
    var child = try std.process.spawn(init.io, .{
        .argv = argv,
        .cwd = if (deployment.runtime.working_directory) |path| .{ .path = path } else .inherit,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const pid: u64 = @intCast(child.id.?);
    const start_ticks = processStartTicks(init, pid) catch |err| {
        child.kill(init.io);
        return err;
    } orelse {
        child.kill(init.io);
        return error.RuntimeApplyFailed;
    };
    return .{ .pid = pid, .process_start_ticks = start_ticks };
}

fn stopProcess(init: std.process.Init, record: AppliedRecord) !void {
    if (builtin.os.tag != .linux) return error.RuntimeUnsupported;
    const pid_value = record.pid orelse return;
    const expected_start = record.process_start_ticks orelse {
        if (try processStartTicks(init, pid_value) == null) return;
        return error.ProcessIdentityMissing;
    };
    if (reapIfExited(pid_value)) return;
    const current_start = try processStartTicks(init, pid_value) orelse return;
    if (current_start != expected_start) return error.ProcessIdentityMismatch;

    const pid: std.posix.pid_t = @intCast(pid_value);
    std.posix.kill(pid, .TERM) catch |err| switch (err) {
        error.ProcessNotFound => return,
        else => return err,
    };
    for (0..100) |_| {
        if (reapIfExited(pid_value)) return;
        const observed = try processStartTicks(init, pid_value) orelse return;
        if (observed != expected_start) return error.ProcessIdentityMismatch;
        const duration: std.Io.Clock.Duration = .{
            .clock = .boot,
            .raw = .fromMilliseconds(50),
        };
        try duration.sleep(init.io);
    }
    std.posix.kill(pid, .KILL) catch |err| switch (err) {
        error.ProcessNotFound => return,
        else => return err,
    };
    for (0..20) |_| {
        if (reapIfExited(pid_value)) return;
        if (try processStartTicks(init, pid_value) == null) return;
        const duration: std.Io.Clock.Duration = .{
            .clock = .boot,
            .raw = .fromMilliseconds(50),
        };
        try duration.sleep(init.io);
    }
    return error.RuntimeStopTimedOut;
}

fn processAlive(init: std.process.Init, record: AppliedRecord) bool {
    if (builtin.os.tag != .linux) return false;
    const pid_value = record.pid orelse return false;
    const expected_start = record.process_start_ticks orelse return false;
    if (reapIfExited(pid_value)) return false;
    const current_start = processStartTicks(init, pid_value) catch return false;
    return current_start != null and current_start.? == expected_start;
}

fn reapIfExited(pid_value: u64) bool {
    if (builtin.os.tag != .linux) return false;
    const pid: std.posix.pid_t = @intCast(pid_value);
    var status: c_int = 0;
    return std.c.waitpid(pid, &status, @intCast(std.c.W.NOHANG)) == pid;
}

fn processStartTicks(init: std.process.Init, pid_value: u64) !?u64 {
    if (builtin.os.tag != .linux) return error.RuntimeUnsupported;
    const path = try std.fmt.allocPrint(init.gpa, "/proc/{d}/stat", .{pid_value});
    defer init.gpa.free(path);
    var file = std.Io.Dir.openFileAbsolute(init.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(init.io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(init.io, &read_buffer);
    var stat_buffer: [4096]u8 = undefined;
    const count = try reader.interface.readSliceShort(&stat_buffer);
    return try parseProcessStartTicks(stat_buffer[0..count]);
}

fn parseProcessStartTicks(stat: []const u8) !u64 {
    const comm_end = std.mem.lastIndexOf(u8, stat, ") ") orelse
        return error.InvalidProcessStat;
    var fields = std.mem.tokenizeScalar(u8, stat[comm_end + 2 ..], ' ');
    var field_index: usize = 0;
    while (fields.next()) |field| : (field_index += 1) {
        if (field_index == 19) return std.fmt.parseInt(u64, field, 10) catch
            return error.InvalidProcessStat;
    }
    return error.InvalidProcessStat;
}

pub fn buildContainerRunCommand(
    allocator: std.mem.Allocator,
    executable: []const u8,
    deployment: orchestration.Deployment,
    access_plan: ?device_access.Plan,
) !OwnedCommand {
    const is_nerdctl = std.mem.eql(u8, executable, "nerdctl");
    if (!is_nerdctl and !std.mem.eql(u8, executable, "docker"))
        return error.UnsupportedContainerRuntime;

    var argv: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (argv.items) |argument| allocator.free(argument);
        argv.deinit(allocator);
    }
    try appendOwnedArgument(allocator, &argv, executable);
    if (is_nerdctl) {
        try appendOwnedArgument(allocator, &argv, "--namespace");
        try appendOwnedArgument(allocator, &argv, "nimbus");
    }
    const run_arguments = [_][]const u8{ "run", "-d", "--name" };
    for (&run_arguments) |argument|
        try appendOwnedArgument(allocator, &argv, argument);
    const container_name = try std.fmt.allocPrint(allocator, "nimbus-{s}", .{deployment.name});
    defer allocator.free(container_name);
    try appendOwnedArgument(allocator, &argv, container_name);

    try appendOwnedArgument(allocator, &argv, "--label");
    try appendOwnedArgument(allocator, &argv, "io.nimbus.managed=true");
    try appendOwnedArgument(allocator, &argv, "--label");
    const deployment_label = try std.fmt.allocPrint(
        allocator,
        "io.nimbus.deployment={s}",
        .{deployment.name},
    );
    defer allocator.free(deployment_label);
    try appendOwnedArgument(allocator, &argv, deployment_label);
    try appendOwnedArgument(allocator, &argv, "--label");
    const revision_label = try std.fmt.allocPrint(
        allocator,
        "io.nimbus.revision={d}",
        .{deployment.revision},
    );
    defer allocator.free(revision_label);
    try appendOwnedArgument(allocator, &argv, revision_label);

    if (access_plan) |plan| {
        if (plan.device_ids.len == 0) return error.NoAssignedDevices;
        switch (plan.access) {
            .host => return error.ContainerHostAccessUnsupported,
            .cdi => |cdi_devices| {
                if (cdi_devices.len == 0) return error.MissingCdiDevices;
                const fingerprint_hex = std.fmt.bytesToHex(plan.fingerprint, .lower);
                try appendOwnedArgument(allocator, &argv, "--label");
                const access_label = try std.fmt.allocPrint(
                    allocator,
                    "io.nimbus.accelerator-assignment={s}",
                    .{fingerprint_hex},
                );
                defer allocator.free(access_label);
                try appendOwnedArgument(allocator, &argv, access_label);
                for (cdi_devices, 0..) |cdi_device, index| {
                    if (!device_access.isValidCdiDevice(cdi_device))
                        return error.InvalidCdiDevice;
                    for (cdi_devices[0..index]) |previous| {
                        if (std.mem.eql(u8, previous, cdi_device))
                            return error.DuplicateCdiDevice;
                    }
                    try appendOwnedArgument(allocator, &argv, "--device");
                    try appendOwnedArgument(allocator, &argv, cdi_device);
                }
            },
        }
    }

    if (deployment.restart_policy != .never) {
        try appendOwnedArgument(allocator, &argv, "--restart");
        try appendOwnedArgument(allocator, &argv, restartName(deployment.restart_policy));
    }
    try appendOwnedArgument(
        allocator,
        &argv,
        deployment.runtime.reference orelse return error.ContainerImageRequired,
    );
    for (deployment.runtime.command) |argument|
        try appendOwnedArgument(allocator, &argv, argument);

    return .{
        .allocator = allocator,
        .argv = try argv.toOwnedSlice(allocator),
    };
}

fn appendOwnedArgument(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    value: []const u8,
) !void {
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try argv.append(allocator, owned);
}

const ContainerOwnershipState = enum { absent, owned, foreign };

const ContainerOwnership = struct {
    state: ContainerOwnershipState,
    container_id: ?[]u8 = null,

    fn deinit(self: *ContainerOwnership, allocator: std.mem.Allocator) void {
        if (self.container_id) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn inspectContainerOwnership(
    init: std.process.Init,
    executable: []const u8,
    container_name: []const u8,
    deployment_name: []const u8,
) !ContainerOwnership {
    const listed_id = try findContainerId(init, executable, container_name) orelse
        return .{ .state = .absent };
    defer init.gpa.free(listed_id);
    const format = "{{.Id}}\n{{index .Config.Labels \"io.nimbus.managed\"}}\n" ++
        "{{index .Config.Labels \"io.nimbus.deployment\"}}";
    const argv: []const []const u8 = if (std.mem.eql(u8, executable, "nerdctl"))
        &.{ executable, "--namespace", "nimbus", "inspect", "-f", format, listed_id }
    else if (std.mem.eql(u8, executable, "docker"))
        &.{ executable, "inspect", "-f", format, listed_id }
    else
        return error.UnsupportedContainerRuntime;
    const result = try std.process.run(init.gpa, init.io, .{
        .argv = argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .clock = .boot, .raw = .fromSeconds(10) } },
    });
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!succeeded) return error.RuntimeInspectFailed;

    var ownership = try parseContainerOwnership(init.gpa, result.stdout, deployment_name);
    errdefer ownership.deinit(init.gpa);
    if (ownership.container_id) |full_id| {
        if (!std.mem.startsWith(u8, full_id, listed_id))
            return error.RuntimeInspectIdentityMismatch;
    }
    return ownership;
}

fn findContainerId(
    init: std.process.Init,
    executable: []const u8,
    container_name: []const u8,
) !?[]u8 {
    const format = "{{.ID}}\t{{.Names}}";
    const argv: []const []const u8 = if (std.mem.eql(u8, executable, "nerdctl"))
        &.{ executable, "--namespace", "nimbus", "ps", "-a", "--format", format }
    else if (std.mem.eql(u8, executable, "docker"))
        &.{ executable, "ps", "-a", "--format", format }
    else
        return error.UnsupportedContainerRuntime;
    const result = try std.process.run(init.gpa, init.io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .clock = .boot, .raw = .fromSeconds(10) } },
    });
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!succeeded) return error.RuntimeInspectFailed;
    return parseContainerList(init.gpa, result.stdout, container_name);
}

fn parseContainerList(
    allocator: std.mem.Allocator,
    output: []const u8,
    container_name: []const u8,
) !?[]u8 {
    var found: ?[]u8 = null;
    errdefer if (found) |value| allocator.free(value);
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const separator = std.mem.indexOfScalar(u8, line, '\t') orelse
            return error.InvalidRuntimeInspect;
        const container_id = line[0..separator];
        const name = line[separator + 1 ..];
        if (!device_access.isValidDeviceId(container_id) or name.len == 0)
            return error.InvalidRuntimeInspect;
        if (!std.mem.eql(u8, name, container_name)) continue;
        if (found != null) return error.AmbiguousRuntimeHandle;
        found = try allocator.dupe(u8, container_id);
    }
    return found;
}

fn parseContainerOwnership(
    allocator: std.mem.Allocator,
    output: []const u8,
    deployment_name: []const u8,
) !ContainerOwnership {
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, output, " \t\r\n"), '\n');
    const container_id = std.mem.trim(u8, lines.next() orelse return error.InvalidRuntimeInspect, " \t\r");
    const managed = std.mem.trim(u8, lines.next() orelse return error.InvalidRuntimeInspect, " \t\r");
    const deployment = std.mem.trim(u8, lines.next() orelse return error.InvalidRuntimeInspect, " \t\r");
    if (lines.next() != null or !device_access.isValidDeviceId(container_id))
        return error.InvalidRuntimeInspect;
    if (!std.mem.eql(u8, managed, "true") or
        !std.mem.eql(u8, deployment, deployment_name))
        return .{ .state = .foreign };
    return .{
        .state = .owned,
        .container_id = try allocator.dupe(u8, container_id),
    };
}

fn replaceContainer(
    init: std.process.Init,
    executable: []const u8,
    deployment: orchestration.Deployment,
    access_plan: ?device_access.Plan,
) !void {
    var command = try buildContainerRunCommand(
        init.gpa,
        executable,
        deployment,
        access_plan,
    );
    defer command.deinit();
    // Fully validate and own the replacement command before stopping the
    // currently healthy container.
    try removeContainer(init, executable, deployment.name);
    if (!try commandSucceeded(init, command.argv, 300)) return error.RuntimeApplyFailed;
}

fn removeContainer(init: std.process.Init, executable: []const u8, name: []const u8) !void {
    const container_name = try std.fmt.allocPrint(init.gpa, "nimbus-{s}", .{name});
    defer init.gpa.free(container_name);
    var ownership = try inspectContainerOwnership(init, executable, container_name, name);
    defer ownership.deinit(init.gpa);
    switch (ownership.state) {
        .absent => return,
        .foreign => return error.RuntimeHandleConflict,
        .owned => {},
    }
    const container_id = ownership.container_id.?;
    if (std.mem.eql(u8, executable, "nerdctl")) {
        if (!try commandSucceeded(
            init,
            &.{ executable, "--namespace", "nimbus", "rm", "-f", container_id },
            60,
        )) return error.RuntimeStopFailed;
    } else {
        if (!try commandSucceeded(init, &.{ executable, "rm", "-f", container_id }, 60))
            return error.RuntimeStopFailed;
    }
}

fn containerHealthy(init: std.process.Init, executable: []const u8, name: []const u8) !bool {
    const container_name = try std.fmt.allocPrint(init.gpa, "nimbus-{s}", .{name});
    defer init.gpa.free(container_name);
    var ownership = try inspectContainerOwnership(init, executable, container_name, name);
    defer ownership.deinit(init.gpa);
    if (ownership.state != .owned) return false;
    const container_id = ownership.container_id.?;
    const argv: []const []const u8 = if (std.mem.eql(u8, executable, "nerdctl"))
        &.{ executable, "--namespace", "nimbus", "inspect", "-f", "{{.State.Running}}", container_id }
    else
        &.{ executable, "inspect", "-f", "{{.State.Running}}", container_id };
    const result = try std.process.run(init.gpa, init.io, .{
        .argv = argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .clock = .boot, .raw = .fromSeconds(10) } },
    });
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    return succeeded and std.mem.eql(u8, std.mem.trim(u8, result.stdout, " \t\r\n"), "true");
}

fn restartName(policy: orchestration.RestartPolicy) []const u8 {
    return switch (policy) {
        .never => "no",
        .on_failure => "on-failure",
        .always => "always",
    };
}

fn commandSucceeded(
    init: std.process.Init,
    argv: []const []const u8,
    timeout_seconds: u32,
) !bool {
    const result = try std.process.run(init.gpa, init.io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{
            .clock = .boot,
            .raw = .fromSeconds(timeout_seconds),
        } },
    });
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn tcpHealthy(init: std.process.Init, target: []const u8, timeout_seconds: u32) bool {
    const separator = std.mem.lastIndexOfScalar(u8, target, ':') orelse return false;
    if (separator == 0 or separator + 1 >= target.len) return false;
    const port = std.fmt.parseInt(u16, target[separator + 1 ..], 10) catch return false;
    const address = std.Io.net.IpAddress.parse(target[0..separator], port) catch return false;
    const stream = address.connect(init.io, .{
        .mode = .stream,
        .timeout = .{ .duration = .{
            .clock = .boot,
            .raw = .fromSeconds(timeout_seconds),
        } },
    }) catch return false;
    stream.close(init.io);
    return true;
}

fn copyFile(
    init: std.process.Init,
    source_path: []const u8,
    destination_path: []const u8,
    maximum_bytes: u64,
) !void {
    var source = try std.Io.Dir.openFileAbsolute(init.io, source_path, .{});
    defer source.close(init.io);
    var destination = try std.Io.Dir.createFileAbsolute(init.io, destination_path, .{});
    defer destination.close(init.io);

    var read_buffer: [64 * 1024]u8 = undefined;
    var write_buffer: [64 * 1024]u8 = undefined;
    var reader = source.reader(init.io, &read_buffer);
    var writer = destination.writer(init.io, &write_buffer);
    var copied: u64 = 0;
    while (true) {
        var block: [64 * 1024]u8 = undefined;
        const count = try reader.interface.readSliceShort(&block);
        if (count == 0) break;
        if (count > maximum_bytes -| copied) return error.ArtifactTooLarge;
        try writer.interface.writeAll(block[0..count]);
        copied += count;
    }
    try writer.interface.flush();
    try destination.sync(init.io);
}

fn downloadFile(
    init: std.process.Init,
    url: []const u8,
    destination_path: []const u8,
    maximum_bytes: u64,
) !void {
    var destination = try std.Io.Dir.createFileAbsolute(init.io, destination_path, .{});
    defer destination.close(init.io);
    var write_buffer: [64 * 1024]u8 = undefined;
    var writer = destination.writer(init.io, &write_buffer);
    var limited: LimitedWriter = .init(&writer.interface, maximum_bytes);
    var http_client: std.http.Client = .{ .allocator = init.gpa, .io = init.io };
    defer http_client.deinit();
    const result = http_client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &limited.writer,
        .keep_alive = false,
    }) catch |err| {
        if (limited.exceeded) return error.ArtifactTooLarge;
        return err;
    };
    const code = @intFromEnum(result.status);
    if (code < 200 or code >= 300) return error.ArtifactDownloadRejected;
    try writer.interface.flush();
    try destination.sync(init.io);
}

const LimitedWriter = struct {
    output: *std.Io.Writer,
    maximum: u64,
    written: u64 = 0,
    exceeded: bool = false,
    writer: std.Io.Writer,

    fn init(output: *std.Io.Writer, maximum: u64) LimitedWriter {
        return .{
            .output = output,
            .maximum = maximum,
            .writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },
        };
    }

    fn drain(
        interface: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *LimitedWriter = @alignCast(@fieldParentPtr("writer", interface));
        const slices = data[0 .. data.len - 1];
        const pattern = data[data.len - 1];
        var incoming: u64 = 0;
        for (slices) |bytes| incoming = std.math.add(u64, incoming, bytes.len) catch {
            self.exceeded = true;
            return error.WriteFailed;
        };
        const repeated = std.math.mul(u64, pattern.len, splat) catch {
            self.exceeded = true;
            return error.WriteFailed;
        };
        incoming = std.math.add(u64, incoming, repeated) catch {
            self.exceeded = true;
            return error.WriteFailed;
        };
        if (incoming > self.maximum -| self.written) {
            self.exceeded = true;
            return error.WriteFailed;
        }
        for (slices) |bytes| try self.output.writeAll(bytes);
        for (0..splat) |_| try self.output.writeAll(pattern);
        self.written += incoming;
        return @intCast(incoming);
    }
};

fn fileDigestMatches(init: std.process.Init, path: []const u8, expected: []const u8) !bool {
    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(init.io, path, .{})
    else
        try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);
    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(init.io, &read_buffer);
    var digest: [Sha256.digest_length]u8 = undefined;
    var hash = Sha256.init(.{});
    while (true) {
        var block: [64 * 1024]u8 = undefined;
        const count = try reader.interface.readSliceShort(&block);
        if (count == 0) break;
        hash.update(block[0..count]);
    }
    hash.final(&digest);
    const actual = std.fmt.bytesToHex(digest, .lower);
    return std.ascii.eqlIgnoreCase(&actual, expected);
}

test "runtime allowlist parsing is explicit" {
    const enabled = try parseEnabled("process,docker");
    try std.testing.expect(enabled.process);
    try std.testing.expect(enabled.docker);
    try std.testing.expect(!enabled.systemd);
    try std.testing.expectError(error.UnknownRuntime, parseEnabled("shell"));
}

test "artifact signature policy rejects unsigned required artifacts" {
    const artifact: orchestration.Artifact = .{
        .source = "file:///tmp/model",
        .sha256 = "ab" ** 32,
    };
    try std.testing.expectError(
        error.ArtifactSignatureRequired,
        verifySignaturePolicy(
            std.testing.allocator,
            .{ .artifact = artifact },
            null,
            true,
        ),
    );
}

test "artifact signature policy verifies Ed25519 digest signatures" {
    const digest = "ab" ** 32;
    const key_pair = try Ed25519.KeyPair.generateDeterministic(.{7} ** Ed25519.KeyPair.seed_length);
    const signature = try key_pair.sign(digest, null);
    const key_hex = std.fmt.bytesToHex(key_pair.public_key.toBytes(), .lower);
    const signature_hex = std.fmt.bytesToHex(signature.toBytes(), .lower);
    const artifact: orchestration.Artifact = .{
        .source = "file:///tmp/model",
        .sha256 = digest,
        .signature_ed25519 = &signature_hex,
    };
    try verifySignaturePolicy(
        std.testing.allocator,
        .{ .artifact = artifact },
        &key_hex,
        true,
    );
}

test "variant signature binds compatibility metadata" {
    var variant: orchestration.ArtifactVariant = .{
        .name = "cuda-engine",
        .artifact = .{
            .source = "file:///tmp/model",
            .sha256 = "cd" ** 32,
        },
        .selector = .{
            .os = "linux",
            .arch = "x86_64",
            .accelerator_kind = .gpu,
            .accelerator_vendor = "nvidia",
            .accelerator_capabilities = &.{"fp16"},
        },
    };
    const unsigned: artifact_selector.Selection = .{
        .artifact = variant.artifact,
        .variant = variant,
        .variant_name = variant.name,
    };
    const message = try signatureMessageAlloc(std.testing.allocator, unsigned);
    defer std.testing.allocator.free(message);
    const key_pair = try Ed25519.KeyPair.generateDeterministic(.{9} ** Ed25519.KeyPair.seed_length);
    const signature = try key_pair.sign(message, null);
    const signature_hex = std.fmt.bytesToHex(signature.toBytes(), .lower);
    const key_hex = std.fmt.bytesToHex(key_pair.public_key.toBytes(), .lower);
    variant.artifact.signature_ed25519 = &signature_hex;
    const signed: artifact_selector.Selection = .{
        .artifact = variant.artifact,
        .variant = variant,
        .variant_name = variant.name,
    };
    try verifySignaturePolicy(std.testing.allocator, signed, &key_hex, true);

    var changed = variant;
    changed.selector.arch = "aarch64";
    try std.testing.expectError(
        error.ArtifactSignatureInvalid,
        verifySignaturePolicy(std.testing.allocator, .{
            .artifact = changed.artifact,
            .variant = changed,
            .variant_name = changed.name,
        }, &key_hex, true),
    );
}

test "artifact download writer enforces its limit while streaming" {
    var output_buffer: [8]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var limited: LimitedWriter = .init(&output, 5);
    try limited.writer.writeAll("12345");
    try std.testing.expectError(error.WriteFailed, limited.writer.writeAll("6"));
    try std.testing.expect(limited.exceeded);
}

test "artifact preparation publishes content-addressed cache and active pin" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const source_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "model.bin" },
    );
    defer std.testing.allocator.free(source_path);
    var source = try std.Io.Dir.createFileAbsolute(std.testing.io, source_path, .{});
    defer source.close(std.testing.io);
    try source.writeStreamingAll(std.testing.io, "verified-model");
    try source.sync(std.testing.io);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash("verified-model", &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    const source_url = try std.fmt.allocPrint(
        std.testing.allocator,
        "file://{s}",
        .{source_path},
    );
    defer std.testing.allocator.free(source_url);
    const deployment: orchestration.Deployment = .{
        .name = "cache-model",
        .revision = 1,
        .runtime = .{ .kind = .process, .command = &.{"{artifact}"} },
        .artifact = .{ .source = source_url, .sha256 = &digest_hex },
        .targets = .{ .all = true },
    };
    const init: std.process.Init = .{
        .minimal = undefined,
        .arena = undefined,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ_map = undefined,
        .preopens = undefined,
    };
    const options: Options = .{
        .enabled = .{ .process = true },
        .state_dir = root,
        .artifact_public_key_hex = null,
        .require_artifact_signatures = false,
        .max_artifact_bytes = 1024,
        .max_artifact_cache_bytes = 2048,
    };
    const cached = (try prepareArtifact(init, deployment, options)).?;
    defer std.testing.allocator.free(cached);
    try std.testing.expect(std.mem.endsWith(u8, cached, &digest_hex));
    try std.testing.expect(try fileDigestMatches(init, cached, &digest_hex));
    const pin_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "artifacts", "pins", deployment.name },
    );
    defer std.testing.allocator.free(pin_path);
    _ = try std.Io.Dir.cwd().statFile(std.testing.io, pin_path, .{});
    try releaseArtifactPin(init, options, deployment.name);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(std.testing.io, pin_path, .{}),
    );
}

test "Linux process identity parser handles spaces in command names" {
    try std.testing.expectEqual(
        4242,
        try parseProcessStartTicks(
            "123 (vision worker) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 4242 0",
        ),
    );
}

test "Docker command injects only exact reserved CDI devices" {
    const inventory = [_][]const u8{"gpu:nvidia:opaque"};
    const bindings = [_]device_access.LocalBinding{.{
        .device_id = inventory[0],
        .cdi_devices = &.{"nvidia.com/gpu=GPU-exact"},
    }};
    var access = try device_access.resolveAlloc(
        std.testing.allocator,
        &inventory,
        .{ .bindings = &bindings },
        &inventory,
        .cdi_only,
    );
    defer access.deinit();
    const deployment: orchestration.Deployment = .{
        .name = "vision",
        .revision = 7,
        .runtime = .{
            .kind = .docker,
            .reference = "registry.example/vision@sha256:" ++ ("ab" ** 32),
            .command = &.{ "serve", "--port=9000" },
        },
        .restart_policy = .on_failure,
        .targets = .{ .all = true },
    };
    var command = try buildContainerRunCommand(
        std.testing.allocator,
        "docker",
        deployment,
        access.view(),
    );
    defer command.deinit();

    try std.testing.expectEqualStrings("docker", command.argv[0]);
    try std.testing.expect(commandHasPair(command.argv, "--name", "nimbus-vision"));
    try std.testing.expect(commandHasPair(
        command.argv,
        "--label",
        "io.nimbus.managed=true",
    ));
    try std.testing.expect(commandHasPair(
        command.argv,
        "--label",
        "io.nimbus.deployment=vision",
    ));
    try std.testing.expect(commandHasPair(
        command.argv,
        "--device",
        "nvidia.com/gpu=GPU-exact",
    ));
    try std.testing.expect(!commandContains(command.argv, "--gpus"));
    try std.testing.expect(!commandContains(command.argv, "--privileged"));
    try std.testing.expect(!commandContains(command.argv, "nvidia.com/gpu=all"));
    const device_index = commandIndex(command.argv, "nvidia.com/gpu=GPU-exact").?;
    const image_index = commandIndex(
        command.argv,
        "registry.example/vision@sha256:" ++ ("ab" ** 32),
    ).?;
    try std.testing.expect(device_index < image_index);
}

test "nerdctl command uses the private Nimbus namespace" {
    const deployment: orchestration.Deployment = .{
        .name = "worker",
        .revision = 1,
        .runtime = .{
            .kind = .containerd,
            .reference = "registry.example/worker@sha256:" ++ ("cd" ** 32),
        },
        .targets = .{ .all = true },
    };
    var command = try buildContainerRunCommand(
        std.testing.allocator,
        "nerdctl",
        deployment,
        null,
    );
    defer command.deinit();
    try std.testing.expectEqualStrings("nerdctl", command.argv[0]);
    try std.testing.expectEqualStrings("--namespace", command.argv[1]);
    try std.testing.expectEqualStrings("nimbus", command.argv[2]);
}

test "container command rejects raw host access" {
    const inventory = [_][]const u8{"gpu:nvidia:opaque"};
    const bindings = [_]device_access.LocalBinding{.{
        .device_id = inventory[0],
        .host_access = .{
            .completeness = .vendor_verified,
            .device_nodes = &.{.{
                .path = "/dev/nvidia0",
                .permissions = .read_write,
            }},
        },
    }};
    var access = try device_access.resolveAlloc(
        std.testing.allocator,
        &inventory,
        .{ .bindings = &bindings },
        &inventory,
        .cdi_or_host,
    );
    defer access.deinit();
    const deployment: orchestration.Deployment = .{
        .name = "vision",
        .revision = 1,
        .runtime = .{
            .kind = .docker,
            .reference = "registry.example/vision@sha256:" ++ ("ef" ** 32),
        },
        .targets = .{ .all = true },
    };
    try std.testing.expectError(
        error.ContainerHostAccessUnsupported,
        buildContainerRunCommand(
            std.testing.allocator,
            "docker",
            deployment,
            access.view(),
        ),
    );
}

test "container ownership requires exact Nimbus labels" {
    var owned = try parseContainerOwnership(
        std.testing.allocator,
        "abcdef012345\ntrue\nvision\n",
        "vision",
    );
    defer owned.deinit(std.testing.allocator);
    try std.testing.expectEqual(ContainerOwnershipState.owned, owned.state);
    try std.testing.expectEqualStrings("abcdef012345", owned.container_id.?);

    var foreign = try parseContainerOwnership(
        std.testing.allocator,
        "abcdef012345\nfalse\nvision\n",
        "vision",
    );
    defer foreign.deinit(std.testing.allocator);
    try std.testing.expectEqual(ContainerOwnershipState.foreign, foreign.state);
    try std.testing.expectEqual(@as(?[]u8, null), foreign.container_id);

    try std.testing.expectError(
        error.InvalidRuntimeInspect,
        parseContainerOwnership(
            std.testing.allocator,
            "abcdef012345\ntrue\nvision\nextra\n",
            "vision",
        ),
    );
}

test "container list confirms absence and rejects ambiguous ownership" {
    const found = (try parseContainerList(
        std.testing.allocator,
        "aaa111\tnimbus-a\nbbb222\tnimbus-vision\n",
        "nimbus-vision",
    )).?;
    defer std.testing.allocator.free(found);
    try std.testing.expectEqualStrings("bbb222", found);

    try std.testing.expect((try parseContainerList(
        std.testing.allocator,
        "aaa111\tnimbus-a\n",
        "nimbus-missing",
    )) == null);
    try std.testing.expectError(
        error.AmbiguousRuntimeHandle,
        parseContainerList(
            std.testing.allocator,
            "aaa111\tnimbus-vision\nbbb222\tnimbus-vision\n",
            "nimbus-vision",
        ),
    );
    try std.testing.expectError(
        error.InvalidRuntimeInspect,
        parseContainerList(
            std.testing.allocator,
            "malformed-without-tab\n",
            "nimbus-vision",
        ),
    );
}

fn commandHasPair(argv: []const []const u8, key: []const u8, value: []const u8) bool {
    if (argv.len < 2) return false;
    for (argv[0 .. argv.len - 1], argv[1..]) |candidate_key, candidate_value| {
        if (std.mem.eql(u8, candidate_key, key) and
            std.mem.eql(u8, candidate_value, value)) return true;
    }
    return false;
}

fn commandContains(argv: []const []const u8, expected: []const u8) bool {
    return commandIndex(argv, expected) != null;
}

fn commandIndex(argv: []const []const u8, expected: []const u8) ?usize {
    for (argv, 0..) |argument, index| {
        if (std.mem.eql(u8, argument, expected)) return index;
    }
    return null;
}
