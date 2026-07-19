const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const accelerator = @import("accelerator.zig");
const placement = @import("placement.zig");

pub const current_schema_version: u8 = 5;
pub const max_feature_count: usize = 16;
pub const max_feature_name_length: usize = 64;
pub const feature_accelerator_requirements_v1 = "accelerator-requirements-v1";
pub const feature_accelerator_lifecycle_v1 = "accelerator-lifecycle-v1";
pub const feature_artifact_variants_v1 = "artifact-variants-v1";
pub const feature_edge_placement_v1 = "edge-placement-v1";

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
    placement_telemetry: ?placement.Telemetry = null,
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
    /// Runtime host architecture. `arch` remains the binary target so an
    /// emulated or translated process is distinguishable from its host.
    host_arch: ?[]const u8 = null,
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
    return collectWithPlacement(
        init,
        node_id,
        role,
        labels,
        features,
        accelerator_inventory,
        null,
    );
}

pub fn collectWithPlacement(
    init: std.process.Init,
    node_id: []const u8,
    role: []const u8,
    labels: []const Label,
    features: []const []const u8,
    accelerator_inventory: accelerator.InventoryReport,
    placement_telemetry: ?placement.Telemetry,
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
            .host_arch = detectHostArchitecture(init),
        },
        .resources = .{
            .cpu_count = std.Thread.getCpuCount() catch 0,
        },
        .accelerator_inventory = accelerator_inventory,
        .placement_telemetry = placement_telemetry,
        .timestamp_unix_ms = std.Io.Clock.real.now(init.io).toMilliseconds(),
    };
}

fn detectHostname(init: std.process.Init) []const u8 {
    if (builtin.target.os.tag == .windows) return detectWindowsHostname(init);
    if (init.environ_map.get("HOSTNAME")) |value| return value;
    switch (builtin.target.os.tag) {
        .linux, .macos => {
            var buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
            const value = std.posix.gethostname(&buffer) catch return "unknown";
            return init.arena.allocator().dupe(u8, value) catch "unknown";
        },
        else => return "unknown",
    }
}

fn detectHostArchitecture(init: std.process.Init) []const u8 {
    switch (builtin.target.os.tag) {
        .linux, .macos => {
            const uts = std.posix.uname();
            return normalizeHostArchitecture(init, std.mem.sliceTo(&uts.machine, 0));
        },
        .windows => {
            var info: WindowsSystemInfo = undefined;
            GetNativeSystemInfo(&info);
            return switch (info.processor_architecture) {
                0 => "x86",
                5 => "arm",
                6 => "ia64",
                9 => "x86_64",
                12 => "aarch64",
                else => "unknown",
            };
        },
        else => return @tagName(builtin.target.cpu.arch),
    }
}

fn normalizeHostArchitecture(init: std.process.Init, machine: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(machine, "amd64") or
        std.ascii.eqlIgnoreCase(machine, "x86_64")) return "x86_64";
    if (std.ascii.eqlIgnoreCase(machine, "arm64") or
        std.ascii.eqlIgnoreCase(machine, "aarch64")) return "aarch64";
    if (std.ascii.eqlIgnoreCase(machine, "i386") or
        std.ascii.eqlIgnoreCase(machine, "i686")) return "x86";
    if (std.ascii.startsWithIgnoreCase(machine, "armv")) return "arm";
    return init.arena.allocator().dupe(u8, machine) catch "unknown";
}

fn detectWindowsHostname(init: std.process.Init) []const u8 {
    var buffer: [256]u16 = undefined;
    var length: u32 = buffer.len;
    if (GetComputerNameW(&buffer, &length).toBool()) {
        return std.unicode.utf16LeToUtf8Alloc(
            init.arena.allocator(),
            buffer[0..length],
        ) catch "unknown";
    }
    return init.environ_map.get("COMPUTERNAME") orelse "unknown";
}

const WindowsSystemInfo = extern struct {
    processor_architecture: u16,
    reserved: u16,
    page_size: u32,
    minimum_application_address: ?*anyopaque,
    maximum_application_address: ?*anyopaque,
    active_processor_mask: usize,
    number_of_processors: u32,
    processor_type: u32,
    allocation_granularity: u32,
    processor_level: u16,
    processor_revision: u16,
};

extern "kernel32" fn GetComputerNameW(
    buffer: [*]u16,
    size: *u32,
) callconv(.winapi) std.os.windows.BOOL;

extern "kernel32" fn GetNativeSystemInfo(
    info: *WindowsSystemInfo,
) callconv(.winapi) void;

pub fn serializeAlloc(allocator: std.mem.Allocator, value: Heartbeat) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

test "heartbeat JSON contains portable target metadata" {
    const value: Heartbeat = .{
        .node_id = "edge-01",
        .hostname = "raspberrypi",
        .role = "edge",
        .platform = .{
            .os = "linux",
            .arch = "aarch64",
            .abi = "musl",
            .host_arch = "aarch64",
        },
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
    try std.testing.expect(std.mem.indexOf(u8, json, "\"host_arch\":\"aarch64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, feature_accelerator_requirements_v1) != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"accelerator_inventory\"") != null);
}
