const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const Heartbeat = struct {
    schema_version: u8 = 1,
    node_id: []const u8,
    hostname: []const u8,
    role: []const u8,
    labels: []const Label = &.{},
    platform: Platform,
    resources: Resources,
    timestamp_unix_ms: i64,
    agent_version: []const u8 = build_options.version,
};

pub const Label = struct {
    key: []const u8,
    value: []const u8,
};

pub const Platform = struct {
    os: []const u8,
    arch: []const u8,
    abi: []const u8,
};

pub const Resources = struct {
    cpu_count: usize,
};

pub fn collect(
    init: std.process.Init,
    node_id: []const u8,
    role: []const u8,
    labels: []const Label,
) Heartbeat {
    const hostname = detectHostname(init);

    return .{
        .node_id = node_id,
        .hostname = hostname,
        .role = role,
        .labels = labels,
        .platform = .{
            .os = @tagName(builtin.target.os.tag),
            .arch = @tagName(builtin.target.cpu.arch),
            .abi = @tagName(builtin.target.abi),
        },
        .resources = .{
            .cpu_count = std.Thread.getCpuCount() catch 0,
        },
        .timestamp_unix_ms = std.Io.Clock.real.now(init.io).toMilliseconds(),
    };
}

fn detectHostname(init: std.process.Init) []const u8 {
    if (init.environ_map.get("HOSTNAME") orelse init.environ_map.get("COMPUTERNAME")) |value|
        return value;
    switch (builtin.target.os.tag) {
        .linux, .macos => {
            var buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
            const value = std.posix.gethostname(&buffer) catch return "unknown";
            return init.arena.allocator().dupe(u8, value) catch "unknown";
        },
        else => return "unknown",
    }
}

pub fn serializeAlloc(allocator: std.mem.Allocator, value: Heartbeat) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

test "heartbeat JSON contains portable target metadata" {
    const value: Heartbeat = .{
        .node_id = "edge-01",
        .hostname = "raspberrypi",
        .role = "edge",
        .platform = .{ .os = "linux", .arch = "aarch64", .abi = "musl" },
        .resources = .{ .cpu_count = 4 },
        .timestamp_unix_ms = 1_700_000_000_000,
    };

    const json = try serializeAlloc(std.testing.allocator, value);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"node_id\":\"edge-01\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"arch\":\"aarch64\"") != null);
}
