const std = @import("std");
const builtin = @import("builtin");
const accelerator = @import("accelerator.zig");
const artifact_cache = @import("artifact_cache.zig");
const heartbeat = @import("heartbeat.zig");
const placement = @import("placement.zig");
const client = @import("client.zig");
const reconciler = @import("reconciler.zig");
const runtime = @import("runtime.zig");
const shutdown = @import("shutdown.zig");

pub const Options = struct {
    server: []const u8,
    node_id: []const u8,
    role: []const u8,
    labels: []const heartbeat.Label,
    interval_seconds: u64,
    jitter_seconds: u64,
    retry_initial_seconds: u64,
    retry_max_seconds: u64,
    orchestration_enabled: bool,
    runtime_options: runtime.Options,
    token: ?[]const u8,
    placement_telemetry: placement.Telemetry = .{},
    once: bool = false,
};

pub fn run(init: std.process.Init, options: Options) !void {
    if (options.interval_seconds == 0) return error.InvalidInterval;
    if (options.interval_seconds > 24 * 60 * 60 or options.jitter_seconds > 60 * 60 or
        options.jitter_seconds > options.interval_seconds) return error.InvalidInterval;
    if (options.retry_initial_seconds == 0 or options.retry_max_seconds == 0) return error.InvalidRetry;
    if (options.retry_initial_seconds > 10 * 60 or options.retry_max_seconds > 60 * 60 or
        options.retry_initial_seconds > options.retry_max_seconds) return error.InvalidRetry;

    const endpoint = try endpointAlloc(init.gpa, options.server);
    defer init.gpa.free(endpoint);

    shutdown.install();
    var backoff = options.retry_initial_seconds;
    while (!shutdown.isRequested()) {
        var inventory = accelerator.collectSystem(init.gpa, init.io) catch |err| {
            try log(init, "accelerator inventory failed: {t}; retrying in {d}s\n", .{ err, backoff });
            if (options.once) return err;
            try shutdown.sleepInterruptible(init.io, backoff *| 1000);
            backoff = nextBackoff(backoff, options.retry_max_seconds);
            continue;
        };
        defer inventory.deinit();
        const inventory_report = inventory.report();
        var cached = artifact_cache.listDigests(
            init,
            options.runtime_options.state_dir,
        ) catch null;
        defer if (cached) |*owned| owned.deinit();
        var placement_telemetry = options.placement_telemetry;
        placement_telemetry.cached_artifact_sha256 = if (cached) |owned|
            owned.items
        else
            &.{};
        const sent = sendOnce(
            init,
            endpoint,
            options,
            inventory_report,
            if (options.orchestration_enabled and options.runtime_options.enabled.any())
                placement_telemetry
            else
                null,
        ) catch |err| blk: {
            try log(init, "heartbeat failed: {t}; retrying in {d}s\n", .{ err, backoff });
            break :blk false;
        };

        if (sent) {
            backoff = options.retry_initial_seconds;
            if (options.orchestration_enabled) {
                reconciler.reconcileOnce(init, .{
                    .server = options.server,
                    .node_id = options.node_id,
                    .token = options.token,
                    .runtime_options = options.runtime_options,
                    .accelerator_inventory = &inventory,
                }) catch |err| try log(init, "reconciliation failed: {t}\n", .{err});
            }
            if (options.once) return;
            const delay = options.interval_seconds +| randomJitter(init.io, options.jitter_seconds);
            try shutdown.sleepInterruptible(init.io, delay *| 1000);
        } else {
            if (options.once) return error.HeartbeatRejected;
            try shutdown.sleepInterruptible(init.io, backoff *| 1000);
            backoff = nextBackoff(backoff, options.retry_max_seconds);
        }
    }
    try log(init, "shutdown requested; agent stopped\n", .{});
}

fn sendOnce(
    init: std.process.Init,
    endpoint: []const u8,
    options: Options,
    inventory: accelerator.InventoryReport,
    placement_telemetry: ?placement.Telemetry,
) !bool {
    const features = advertisedFeatures(
        options.orchestration_enabled,
        options.runtime_options.enabled,
    );
    const value = heartbeat.collectWithPlacement(
        init,
        options.node_id,
        options.role,
        options.labels,
        features,
        inventory,
        placement_telemetry,
    );
    const payload = try heartbeat.serializeAlloc(init.gpa, value);
    defer init.gpa.free(payload);

    var response_buffer: [4096]u8 = undefined;
    const result = try client.sendHeartbeat(init, endpoint, payload, options.token, &response_buffer);
    if (result.status != .accepted) {
        try log(init, "heartbeat rejected: HTTP {d} {s}", .{
            @intFromEnum(result.status),
            result.response_body,
        });
        return false;
    }
    try log(init, "heartbeat accepted for {s}\n", .{options.node_id});
    return true;
}

fn advertisedFeatures(
    orchestration_enabled: bool,
    enabled_runtimes: runtime.Enabled,
) []const []const u8 {
    return if (builtin.os.tag == .linux and orchestration_enabled and
        enabled_runtimes.process)
        &.{
            heartbeat.feature_accelerator_requirements_v1,
            heartbeat.feature_accelerator_lifecycle_v1,
            heartbeat.feature_artifact_variants_v1,
            heartbeat.feature_edge_placement_v1,
        }
    else if (builtin.os.tag == .linux and
        orchestration_enabled and enabled_runtimes.any())
        &.{
            heartbeat.feature_accelerator_requirements_v1,
            heartbeat.feature_accelerator_lifecycle_v1,
            heartbeat.feature_edge_placement_v1,
        }
    else
        &.{heartbeat.feature_accelerator_requirements_v1};
}

pub fn endpointAlloc(allocator: std.mem.Allocator, server: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, server, "/");
    if (std.mem.endsWith(u8, trimmed, "/v1/heartbeat")) return allocator.dupe(u8, trimmed);
    return std.fmt.allocPrint(allocator, "{s}/v1/heartbeat", .{trimmed});
}

pub fn nextBackoff(current: u64, maximum: u64) u64 {
    if (current >= maximum) return maximum;
    return @min(current *| 2, maximum);
}

fn randomJitter(io: std.Io, maximum_seconds: u64) u64 {
    if (maximum_seconds == 0) return 0;
    var value: u64 = undefined;
    io.random(std.mem.asBytes(&value));
    return value % (maximum_seconds + 1);
}

fn log(init: std.process.Init, comptime format: []const u8, args: anytype) !void {
    const message = try std.fmt.allocPrint(init.gpa, format, args);
    defer init.gpa.free(message);
    try std.Io.File.stderr().writeStreamingAll(init.io, message);
}

test "heartbeat endpoint is derived from server URL" {
    const value = try endpointAlloc(std.testing.allocator, "http://127.0.0.1:8080/");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/v1/heartbeat", value);
}

test "retry backoff is capped" {
    try std.testing.expectEqual(@as(u64, 4), nextBackoff(2, 30));
    try std.testing.expectEqual(@as(u64, 30), nextBackoff(20, 30));
}

test "accelerator lifecycle capability is advertised only when executable" {
    try std.testing.expectEqual(
        @as(usize, 1),
        advertisedFeatures(false, .{ .process = true }).len,
    );
    const enabled = advertisedFeatures(true, .{ .process = true });
    try std.testing.expectEqual(
        @as(usize, if (builtin.os.tag == .linux) 4 else 1),
        enabled.len,
    );
    if (builtin.os.tag == .linux)
        try std.testing.expectEqualStrings(
            heartbeat.feature_artifact_variants_v1,
            enabled[2],
        );
    if (builtin.os.tag == .linux)
        try std.testing.expectEqualStrings(
            heartbeat.feature_edge_placement_v1,
            enabled[3],
        );
    try std.testing.expectEqual(
        @as(usize, 1),
        advertisedFeatures(true, .{}).len,
    );
}
