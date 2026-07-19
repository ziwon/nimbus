const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const accelerator = @import("accelerator.zig");

pub const current_schema_version: u8 = 3;
pub const max_feature_count: usize = 16;
pub const max_feature_name_length: usize = 64;
pub const feature_accelerator_requirements_v1 = "accelerator-requirements-v1";
pub const feature_accelerator_lifecycle_v1 = "accelerator-lifecycle-v1";
pub const feature_artifact_variants_v1 = "artifact-variants-v1";

pub const Heartbeat = struct {
    schema_version: u8 = current_schema_version,
    node_id: []const u8,
    hostname: []const u8,
    role: []const u8,
    labels: []const Label = &.{},
    features: []const []const u8 = &.{},
    platform: Platform,
    resources: Resources,
    accelerator_inventory: ?accelerator.InventoryReport = null,
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
    features: []const []const u8,
    accelerator_inventory: accelerator.InventoryReport,
) Heartbeat {
    const hostname = detectHostname(init);

    return .{
        .node_id = node_id,
        .hostname = hostname,
        .role = role,
        .labels = labels,
        .features = features,
        .platform = .{
            .os = @tagName(builtin.target.os.tag),
            .arch = @tagName(builtin.target.cpu.arch),
            .abi = @tagName(builtin.target.abi),
        },
        .resources = .{
            .cpu_count = std.Thread.getCpuCount() catch 0,
        },
        .accelerator_inventory = accelerator_inventory,
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
        .features = &.{feature_accelerator_requirements_v1},
        .accelerator_inventory = .{
            .status = .complete,
            .accelerators = &.{},
            .probes = &.{.{
                .name = "nvidia-smi",
                .status = .not_present,
                .devices_found = 0,
            }},
        },
        .timestamp_unix_ms = 1_700_000_000_000,
    };

    const json = try serializeAlloc(std.testing.allocator, value);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"node_id\":\"edge-01\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"arch\":\"aarch64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, feature_accelerator_requirements_v1) != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"accelerator_inventory\"") != null);
}
