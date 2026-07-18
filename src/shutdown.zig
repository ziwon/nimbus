const std = @import("std");
const builtin = @import("builtin");

var requested = std.atomic.Value(bool).init(false);

pub fn install() void {
    requested.store(false, .release);
    if (comptime builtin.os.tag != .windows) {
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = handleSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.INT, &action, null);
        std.posix.sigaction(.TERM, &action, null);
    }
}

pub fn isRequested() bool {
    return requested.load(.acquire);
}

pub fn request() void {
    requested.store(true, .release);
}

fn handleSignal(_: std.posix.SIG) callconv(.c) void {
    request();
}

pub fn sleepInterruptible(io: std.Io, total_ms: u64) !void {
    var remaining = total_ms;
    while (remaining > 0 and !isRequested()) {
        const chunk = @min(remaining, 250);
        const duration: std.Io.Clock.Duration = .{
            .clock = .boot,
            .raw = .fromMilliseconds(@intCast(chunk)),
        };
        duration.sleep(io) catch |err| switch (err) {
            error.Canceled => if (!isRequested()) return err,
        };
        remaining -= chunk;
    }
}
