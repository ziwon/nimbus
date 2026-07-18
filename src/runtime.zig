const std = @import("std");
const builtin = @import("builtin");
const client = @import("client.zig");
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

pub const Options = struct {
    enabled: Enabled,
    state_dir: []const u8,
    artifact_public_key_hex: ?[]const u8,
    require_artifact_signatures: bool,
    max_artifact_bytes: u64,
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
    return switch (deployment.runtime.kind) {
        .process => try startProcess(init, deployment, artifact_path),
        .systemd => {
            const unit = deployment.runtime.reference.?;
            if (!try commandSucceeded(init, &.{ "systemctl", "restart", "--", unit }, 60))
                return error.RuntimeApplyFailed;
            return .{};
        },
        .docker => {
            try replaceContainer(init, "docker", deployment);
            return .{};
        },
        .containerd => {
            try replaceContainer(init, "nerdctl", deployment);
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
    const health = deployment.health_check;
    return switch (health.kind) {
        .runtime => runtimeHealthy(init, record),
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
    const artifact = deployment.artifact orelse return null;
    try verifySignaturePolicy(artifact, options.artifact_public_key_hex, options.require_artifact_signatures);

    const artifact_dir = try std.fmt.allocPrint(
        init.gpa,
        "{s}/artifacts/{s}",
        .{ options.state_dir, deployment.name },
    );
    defer init.gpa.free(artifact_dir);
    try std.Io.Dir.cwd().createDirPath(init.io, artifact_dir);
    const final_path = try std.fmt.allocPrint(
        init.gpa,
        "{s}/{d}",
        .{ artifact_dir, deployment.revision },
    );
    errdefer init.gpa.free(final_path);

    if (fileDigestMatches(init, final_path, artifact.sha256) catch false) return final_path;

    const temporary_path = try std.fmt.allocPrint(init.gpa, "{s}.part", .{final_path});
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
    std.Io.Dir.cwd().deleteFile(init.io, final_path) catch {};
    try std.Io.Dir.renameAbsolute(temporary_path, final_path, init.io);
    return final_path;
}

fn verifySignaturePolicy(
    artifact: orchestration.Artifact,
    public_key_hex: ?[]const u8,
    required: bool,
) !void {
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
    var digest_lower: [64]u8 = undefined;
    _ = std.ascii.lowerString(&digest_lower, artifact.sha256);
    signature.verify(&digest_lower, public_key) catch return error.ArtifactSignatureInvalid;
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

fn replaceContainer(
    init: std.process.Init,
    executable: []const u8,
    deployment: orchestration.Deployment,
) !void {
    const container_name = try std.fmt.allocPrint(init.gpa, "nimbus-{s}", .{deployment.name});
    defer init.gpa.free(container_name);
    removeContainer(init, executable, deployment.name) catch {};

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(init.gpa);
    try argv.append(init.gpa, executable);
    if (std.mem.eql(u8, executable, "nerdctl")) {
        try argv.appendSlice(init.gpa, &.{ "--namespace", "nimbus" });
    }
    try argv.appendSlice(init.gpa, &.{ "run", "-d", "--name", container_name });
    if (deployment.restart_policy != .never)
        try argv.appendSlice(init.gpa, &.{ "--restart", restartName(deployment.restart_policy) });
    try argv.append(init.gpa, deployment.runtime.reference.?);
    try argv.appendSlice(init.gpa, deployment.runtime.command);
    if (!try commandSucceeded(init, argv.items, 300)) return error.RuntimeApplyFailed;
}

fn removeContainer(init: std.process.Init, executable: []const u8, name: []const u8) !void {
    const container_name = try std.fmt.allocPrint(init.gpa, "nimbus-{s}", .{name});
    defer init.gpa.free(container_name);
    if (std.mem.eql(u8, executable, "nerdctl")) {
        if (!try commandSucceeded(
            init,
            &.{ executable, "--namespace", "nimbus", "rm", "-f", container_name },
            60,
        )) return error.RuntimeStopFailed;
    } else {
        if (!try commandSucceeded(init, &.{ executable, "rm", "-f", container_name }, 60))
            return error.RuntimeStopFailed;
    }
}

fn containerHealthy(init: std.process.Init, executable: []const u8, name: []const u8) !bool {
    const container_name = try std.fmt.allocPrint(init.gpa, "nimbus-{s}", .{name});
    defer init.gpa.free(container_name);
    const argv: []const []const u8 = if (std.mem.eql(u8, executable, "nerdctl"))
        &.{ executable, "--namespace", "nimbus", "inspect", "-f", "{{.State.Running}}", container_name }
    else
        &.{ executable, "inspect", "-f", "{{.State.Running}}", container_name };
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
        verifySignaturePolicy(artifact, null, true),
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
    try verifySignaturePolicy(artifact, &key_hex, true);
}

test "artifact download writer enforces its limit while streaming" {
    var output_buffer: [8]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var limited: LimitedWriter = .init(&output, 5);
    try limited.writer.writeAll("12345");
    try std.testing.expectError(error.WriteFailed, limited.writer.writeAll("6"));
    try std.testing.expect(limited.exceeded);
}

test "Linux process identity parser handles spaces in command names" {
    try std.testing.expectEqual(
        4242,
        try parseProcessStartTicks(
            "123 (vision worker) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 4242 0",
        ),
    );
}
