const std = @import("std");
const accelerator = @import("accelerator.zig");
const heartbeat = @import("heartbeat.zig");
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
        const sent = sendOnce(init, endpoint, options, inventory_report) catch |err| blk: {
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
                    .accelerator_inventory = inventory_report,
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
) !bool {
    const value = heartbeat.collect(
        init,
        options.node_id,
        options.role,
        options.labels,
        &.{heartbeat.feature_accelerator_requirements_v1},
        inventory,
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
