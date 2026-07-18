const std = @import("std");

pub const max_identity_bytes = 128;

pub fn loadOrCreate(init: std.process.Init, path: []const u8) ![]const u8 {
    if (load(init, path)) |value| return value else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var random_bytes: [16]u8 = undefined;
    init.io.random(&random_bytes);
    const hex = std.fmt.bytesToHex(random_bytes, .lower);
    const generated = try std.fmt.allocPrint(init.arena.allocator(), "node-{s}", .{hex});

    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) try std.Io.Dir.cwd().createDirPath(init.io, parent);
    }

    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(init.io, path, .{
        .make_path = true,
        .replace = false,
    });
    defer atomic_file.deinit(init.io);
    try atomic_file.file.writeStreamingAll(init.io, generated);
    try atomic_file.file.writeStreamingAll(init.io, "\n");
    try atomic_file.file.sync(init.io);
    atomic_file.link(init.io) catch |err| switch (err) {
        error.PathAlreadyExists => return load(init, path),
        else => return err,
    };
    return generated;
}

fn load(init: std.process.Init, path: []const u8) ![]const u8 {
    var file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);

    var read_buffer: [max_identity_bytes + 2]u8 = undefined;
    var file_reader = file.reader(init.io, &read_buffer);
    const bytes = try file_reader.interface.allocRemaining(init.gpa, .limited(max_identity_bytes + 1));
    defer init.gpa.free(bytes);
    const value = std.mem.trim(u8, bytes, " \t\r\n");
    if (!isValid(value)) return error.InvalidNodeIdentity;
    return init.arena.allocator().dupe(u8, value);
}

pub fn isValid(value: []const u8) bool {
    if (value.len == 0 or value.len > max_identity_bytes) return false;
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.')) return false;
    }
    return true;
}

test "node identity validation" {
    try std.testing.expect(isValid("edge-01.lab"));
    try std.testing.expect(!isValid(""));
    try std.testing.expect(!isValid("bad/id"));
}
