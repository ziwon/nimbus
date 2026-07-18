const std = @import("std");

pub const FileConfig = struct {
    server: ?[]const u8 = null,
    role: ?[]const u8 = null,
    labels: ?[]const []const u8 = null,
    node_id_file: ?[]const u8 = null,
    interval_seconds: ?u64 = null,
    jitter_seconds: ?u64 = null,
    retry_initial_seconds: ?u64 = null,
    retry_max_seconds: ?u64 = null,
    orchestration: ?bool = null,
    state_dir: ?[]const u8 = null,
    runtimes: ?[]const u8 = null,
    artifact_public_key: ?[]const u8 = null,
    require_artifact_signatures: ?bool = null,
    max_artifact_bytes: ?u64 = null,
    token: ?[]const u8 = null,
    token_file: ?[]const u8 = null,
    admin_token: ?[]const u8 = null,
    admin_token_file: ?[]const u8 = null,
    bind: ?[]const u8 = null,
    port: ?u16 = null,
    database: ?[]const u8 = null,
    stale_after_seconds: ?u64 = null,
    allow_insecure_no_auth: ?bool = null,
};

pub fn load(init: std.process.Init, path: []const u8) !FileConfig {
    var file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);

    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(init.io, &read_buffer);
    const bytes = try file_reader.interface.allocRemaining(init.gpa, .limited(256 * 1024));
    defer init.gpa.free(bytes);

    return std.json.parseFromSliceLeaky(FileConfig, init.arena.allocator(), bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    });
}

pub fn envUnsigned(init: std.process.Init, name: []const u8, fallback: u64) !u64 {
    const value = init.environ_map.get(name) orelse return fallback;
    return std.fmt.parseInt(u64, value, 10);
}

pub fn envPort(init: std.process.Init, name: []const u8, fallback: u16) !u16 {
    const value = init.environ_map.get(name) orelse return fallback;
    return std.fmt.parseInt(u16, value, 10);
}

pub fn envBool(init: std.process.Init, name: []const u8, fallback: bool) !bool {
    const value = init.environ_map.get(name) orelse return fallback;
    return parseBool(value);
}

fn parseBool(value: []const u8) !bool {
    if (std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false") or std.mem.eql(u8, value, "0")) return false;
    return error.InvalidBoolean;
}

test "configuration rejects unknown keys" {
    try std.testing.expectError(
        error.UnknownField,
        std.json.parseFromSliceLeaky(FileConfig, std.testing.allocator, "{\"unknown\":true}", .{}),
    );
}

test "boolean environment values are strict" {
    try std.testing.expect(try parseBool("true"));
    try std.testing.expect(!try parseBool("0"));
    try std.testing.expectError(error.InvalidBoolean, parseBool("yes"));
}
