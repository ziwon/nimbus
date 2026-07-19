const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const digest_hex_len = Sha256.digest_length * 2;
const maximum_pin_bytes = digest_hex_len + 1;

const CacheEntry = struct {
    name: []u8,
    size: u64,
    pinned: bool,
};

/// Returns the allocator-owned path for a canonical lowercase SHA-256 digest.
pub fn contentPathAlloc(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    digest: []const u8,
) ![]u8 {
    if (!isCanonicalDigest(digest)) return error.InvalidDigest;
    return std.fs.path.join(allocator, &.{ state_dir, "artifacts", "sha256", digest });
}

/// Admits a verified temporary file into the content-addressed cache.
///
/// Unpinned entries are evicted in filename lexical order. Capacity is proven
/// before the first eviction, so an unsatisfiable admission leaves the cache
/// untouched. A successful call consumes `temporary_path` through rename and
/// returns an allocator-owned cache path.
pub fn admit(
    init: std.process.Init,
    state_dir: []const u8,
    digest: []const u8,
    temporary_path: []const u8,
    size: u64,
    max_cache_bytes: u64,
) ![]u8 {
    return admitWith(
        init.gpa,
        init.io,
        state_dir,
        digest,
        temporary_path,
        size,
        max_cache_bytes,
    );
}

/// Atomically pins a digest to one deployment safe-token.
pub fn pin(
    init: std.process.Init,
    state_dir: []const u8,
    deployment: []const u8,
    digest: []const u8,
) !void {
    return pinWith(init.gpa, init.io, state_dir, deployment, digest);
}

/// Removes exactly one deployment pin. Missing pins are already unpinned.
pub fn unpin(
    init: std.process.Init,
    state_dir: []const u8,
    deployment: []const u8,
) !void {
    return unpinWith(init.gpa, init.io, state_dir, deployment);
}

fn admitWith(
    allocator: std.mem.Allocator,
    io: std.Io,
    state_dir: []const u8,
    digest: []const u8,
    temporary_path: []const u8,
    size: u64,
    max_cache_bytes: u64,
) ![]u8 {
    if (!isCanonicalDigest(digest)) return error.InvalidDigest;
    if (size > max_cache_bytes) return error.ArtifactExceedsCacheCapacity;
    try verifyTemporary(io, temporary_path, digest, size);

    const content_root = try std.fs.path.join(
        allocator,
        &.{ state_dir, "artifacts", "sha256" },
    );
    defer allocator.free(content_root);
    const pin_root = try std.fs.path.join(
        allocator,
        &.{ state_dir, "artifacts", "pins" },
    );
    defer allocator.free(pin_root);
    const destination = try contentPathAlloc(allocator, state_dir, digest);
    errdefer allocator.free(destination);

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, content_root);
    try cwd.createDirPath(io, pin_root);

    var pins = try readPins(allocator, io, pin_root);
    defer {
        for (pins.items) |value| allocator.free(value);
        pins.deinit(allocator);
    }

    var entries: std.ArrayList(CacheEntry) = .empty;
    defer {
        for (entries.items) |entry| allocator.free(entry.name);
        entries.deinit(allocator);
    }
    var total_bytes: u64 = 0;
    var replaced_bytes: u64 = 0;
    try scanContent(
        allocator,
        io,
        content_root,
        pins.items,
        digest,
        &entries,
        &total_bytes,
        &replaced_bytes,
    );

    const retained_bytes = std.math.sub(u64, total_bytes, replaced_bytes) catch
        return error.CorruptArtifactCache;
    var required_bytes = std.math.add(u64, retained_bytes, size) catch
        return error.ArtifactExceedsCacheCapacity;

    std.mem.sort(CacheEntry, entries.items, {}, lessCacheEntry);
    var eviction_count: usize = 0;
    while (required_bytes > max_cache_bytes) {
        while (eviction_count < entries.items.len and
            (entries.items[eviction_count].pinned or
                std.mem.eql(u8, entries.items[eviction_count].name, digest)))
        {
            eviction_count += 1;
        }
        if (eviction_count == entries.items.len)
            return error.InsufficientUnpinnedCacheCapacity;
        required_bytes = std.math.sub(
            u64,
            required_bytes,
            entries.items[eviction_count].size,
        ) catch return error.CorruptArtifactCache;
        eviction_count += 1;
    }

    // The sorted prefix may contain protected entries skipped while selecting
    // victims. Delete only the unpinned, non-destination entries in it.
    var content_dir = try cwd.openDir(io, content_root, .{});
    defer content_dir.close(io);
    for (entries.items[0..eviction_count]) |entry| {
        if (entry.pinned or std.mem.eql(u8, entry.name, digest)) continue;
        try content_dir.deleteFile(io, entry.name);
    }

    // rename is the publication boundary. It also atomically replaces a prior
    // object with the same digest, preventing a corrupt stale object from being
    // reused merely because its filename looked valid.
    try cwd.rename(temporary_path, cwd, destination, io);
    return destination;
}

fn pinWith(
    allocator: std.mem.Allocator,
    io: std.Io,
    state_dir: []const u8,
    deployment: []const u8,
    digest: []const u8,
) !void {
    if (!isSafeToken(deployment)) return error.InvalidDeployment;
    if (!isCanonicalDigest(digest)) return error.InvalidDigest;
    const pin_root = try std.fs.path.join(
        allocator,
        &.{ state_dir, "artifacts", "pins" },
    );
    defer allocator.free(pin_root);

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, pin_root);
    var dir = try cwd.openDir(io, pin_root, .{});
    defer dir.close(io);
    var atomic = try dir.createFileAtomic(io, deployment, .{
        .make_path = false,
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, digest);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

fn unpinWith(
    allocator: std.mem.Allocator,
    io: std.Io,
    state_dir: []const u8,
    deployment: []const u8,
) !void {
    if (!isSafeToken(deployment)) return error.InvalidDeployment;
    const pin_root = try std.fs.path.join(
        allocator,
        &.{ state_dir, "artifacts", "pins" },
    );
    defer allocator.free(pin_root);
    var dir = std.Io.Dir.cwd().openDir(io, pin_root, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    dir.deleteFile(io, deployment) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn verifyTemporary(
    io: std.Io,
    path: []const u8,
    expected_digest: []const u8,
    expected_size: u64,
) !void {
    const cwd = std.Io.Dir.cwd();
    const stat = try cwd.statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .file) return error.InvalidTemporaryArtifact;
    if (stat.size != expected_size) return error.ArtifactSizeMismatch;

    var file = try cwd.openFile(io, path, .{});
    defer file.close(io);
    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    var hash = Sha256.init(.{});
    while (true) {
        var block: [64 * 1024]u8 = undefined;
        const count = try reader.interface.readSliceShort(&block);
        if (count == 0) break;
        hash.update(block[0..count]);
    }
    var actual: [Sha256.digest_length]u8 = undefined;
    hash.final(&actual);
    const actual_hex = std.fmt.bytesToHex(actual, .lower);
    if (!std.mem.eql(u8, &actual_hex, expected_digest))
        return error.ArtifactDigestMismatch;
}

fn readPins(
    allocator: std.mem.Allocator,
    io: std.Io,
    pin_root: []const u8,
) !std.ArrayList([]u8) {
    var result: std.ArrayList([]u8) = .empty;
    errdefer {
        for (result.items) |value| allocator.free(value);
        result.deinit(allocator);
    }
    var dir = try std.Io.Dir.cwd().openDir(io, pin_root, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterateAssumeFirstIteration();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !isSafeToken(entry.name))
            return error.CorruptArtifactPins;
        var file = try dir.openFile(io, entry.name, .{});
        defer file.close(io);
        var read_buffer: [maximum_pin_bytes]u8 = undefined;
        var reader = file.reader(io, &read_buffer);
        const value = reader.interface.allocRemaining(
            allocator,
            .limited(maximum_pin_bytes),
        ) catch |err| switch (err) {
            error.StreamTooLong => return error.CorruptArtifactPins,
            else => return err,
        };
        errdefer allocator.free(value);
        if (!isCanonicalDigest(value)) return error.CorruptArtifactPins;
        try result.append(allocator, value);
    }
    return result;
}

fn scanContent(
    allocator: std.mem.Allocator,
    io: std.Io,
    content_root: []const u8,
    pins: []const []u8,
    destination_digest: []const u8,
    entries: *std.ArrayList(CacheEntry),
    total_bytes: *u64,
    replaced_bytes: *u64,
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, content_root, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterateAssumeFirstIteration();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !isCanonicalDigest(entry.name))
            return error.CorruptArtifactCache;
        const stat = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
        if (stat.kind != .file) return error.CorruptArtifactCache;
        total_bytes.* = std.math.add(u64, total_bytes.*, stat.size) catch
            return error.CorruptArtifactCache;
        if (std.mem.eql(u8, entry.name, destination_digest)) {
            replaced_bytes.* = stat.size;
        }
        const owned_name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(owned_name);
        try entries.append(allocator, .{
            .name = owned_name,
            .size = stat.size,
            .pinned = containsDigest(pins, entry.name),
        });
    }
}

fn containsDigest(pins: []const []u8, digest: []const u8) bool {
    for (pins) |value| {
        if (std.mem.eql(u8, value, digest)) return true;
    }
    return false;
}

fn lessCacheEntry(_: void, lhs: CacheEntry, rhs: CacheEntry) bool {
    return std.mem.order(u8, lhs.name, rhs.name) == .lt;
}

fn isCanonicalDigest(value: []const u8) bool {
    if (value.len != digest_hex_len) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn isSafeToken(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    if (std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.'))
            return false;
    }
    return true;
}

fn testingInit() std.process.Init {
    return .{
        .minimal = undefined,
        .arena = undefined,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ_map = undefined,
        .preopens = undefined,
    };
}

fn temporaryRoot(temporary: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const length = try temporary.dir.realPath(std.testing.io, buffer);
    return buffer[0..length];
}

fn digestFor(bytes: []const u8) [digest_hex_len]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn writePath(io: std.Io, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
}

fn cacheEntryPath(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    digest: []const u8,
) ![]u8 {
    return contentPathAlloc(allocator, state_dir, digest);
}

test "admission is independent of directory iteration order and evicts lexically" {
    var left = std.testing.tmpDir(.{});
    defer left.cleanup();
    var right = std.testing.tmpDir(.{});
    defer right.cleanup();
    var left_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var right_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const roots = [_][]const u8{
        try temporaryRoot(&left, &left_buffer),
        try temporaryRoot(&right, &right_buffer),
    };
    const names = [_][]const u8{ "01" ** 32, "02" ** 32, "03" ** 32 };
    const insertion_orders = [_][3]usize{ .{ 2, 0, 1 }, .{ 1, 2, 0 } };
    const incoming = "incoming";
    const incoming_digest = digestFor(incoming);

    for (roots, insertion_orders) |root, order| {
        for (order) |index| {
            const path = try cacheEntryPath(std.testing.allocator, root, names[index]);
            defer std.testing.allocator.free(path);
            try writePath(std.testing.io, path, "xx");
        }
        const part = try std.fs.path.join(std.testing.allocator, &.{ root, "incoming.part" });
        defer std.testing.allocator.free(part);
        try writePath(std.testing.io, part, incoming);
        const admitted = try admit(
            testingInit(),
            root,
            &incoming_digest,
            part,
            incoming.len,
            10,
        );
        defer std.testing.allocator.free(admitted);

        try expectCacheEntry(root, names[0], false);
        try expectCacheEntry(root, names[1], false);
        try expectCacheEntry(root, names[2], true);
        try expectCacheEntry(root, &incoming_digest, true);
    }
}

test "active pin is never selected for eviction" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&temporary, &root_buffer);
    const pinned_digest = "01" ** 32;
    const evictable_digest = "02" ** 32;
    const pinned_path = try cacheEntryPath(std.testing.allocator, root, pinned_digest);
    defer std.testing.allocator.free(pinned_path);
    try writePath(std.testing.io, pinned_path, "keep");
    const evictable_path = try cacheEntryPath(std.testing.allocator, root, evictable_digest);
    defer std.testing.allocator.free(evictable_path);
    try writePath(std.testing.io, evictable_path, "drop");
    try pin(testingInit(), root, "vision", pinned_digest);

    const incoming = "next";
    const incoming_digest = digestFor(incoming);
    const part = try std.fs.path.join(std.testing.allocator, &.{ root, "next.part" });
    defer std.testing.allocator.free(part);
    try writePath(std.testing.io, part, incoming);
    const admitted = try admit(testingInit(), root, &incoming_digest, part, incoming.len, 8);
    defer std.testing.allocator.free(admitted);
    try expectCacheEntry(root, pinned_digest, true);
    try expectCacheEntry(root, evictable_digest, false);
}

test "pinned capacity failure makes no cache mutation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&temporary, &root_buffer);
    const pinned_digest = "01" ** 32;
    const pinned_path = try cacheEntryPath(std.testing.allocator, root, pinned_digest);
    defer std.testing.allocator.free(pinned_path);
    try writePath(std.testing.io, pinned_path, "keep");
    try pin(testingInit(), root, "vision", pinned_digest);

    const incoming = "next";
    const incoming_digest = digestFor(incoming);
    const part = try std.fs.path.join(std.testing.allocator, &.{ root, "next.part" });
    defer std.testing.allocator.free(part);
    try writePath(std.testing.io, part, incoming);
    try std.testing.expectError(
        error.InsufficientUnpinnedCacheCapacity,
        admit(testingInit(), root, &incoming_digest, part, incoming.len, 7),
    );
    try expectCacheEntry(root, pinned_digest, true);
    _ = try std.Io.Dir.cwd().statFile(std.testing.io, part, .{});
}

test "single artifact larger than cache capacity is rejected before mutation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&temporary, &root_buffer);
    const incoming = "too-large";
    const incoming_digest = digestFor(incoming);
    const part = try std.fs.path.join(std.testing.allocator, &.{ root, "large.part" });
    defer std.testing.allocator.free(part);
    try writePath(std.testing.io, part, incoming);
    try std.testing.expectError(
        error.ArtifactExceedsCacheCapacity,
        admit(testingInit(), root, &incoming_digest, part, incoming.len, incoming.len - 1),
    );
    _ = try std.Io.Dir.cwd().statFile(std.testing.io, part, .{});
}

test "pin replacement is atomic roundtrip and unpin is exact" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&temporary, &root_buffer);
    try pin(testingInit(), root, "vision.v2", "01" ** 32);
    try pin(testingInit(), root, "vision.v2", "02" ** 32);

    const pin_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "artifacts", "pins", "vision.v2" },
    );
    defer std.testing.allocator.free(pin_path);
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, pin_path, .{});
    defer file.close(std.testing.io);
    var read_buffer: [maximum_pin_bytes]u8 = undefined;
    var reader = file.reader(std.testing.io, &read_buffer);
    const value = try reader.interface.allocRemaining(
        std.testing.allocator,
        .limited(maximum_pin_bytes),
    );
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("02" ** 32, value);

    try unpin(testingInit(), root, "vision.v2");
    try unpin(testingInit(), root, "vision.v2");
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(std.testing.io, pin_path, .{}),
    );
}

test "malformed cache entries fail closed without cleanup" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&temporary, &root_buffer);
    const malformed = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "artifacts", "sha256", "unknown" },
    );
    defer std.testing.allocator.free(malformed);
    try writePath(std.testing.io, malformed, "do-not-delete");
    const incoming = "incoming";
    const incoming_digest = digestFor(incoming);
    const part = try std.fs.path.join(std.testing.allocator, &.{ root, "incoming.part" });
    defer std.testing.allocator.free(part);
    try writePath(std.testing.io, part, incoming);
    try std.testing.expectError(
        error.CorruptArtifactCache,
        admit(testingInit(), root, &incoming_digest, part, incoming.len, 1024),
    );
    _ = try std.Io.Dir.cwd().statFile(std.testing.io, malformed, .{});
    _ = try std.Io.Dir.cwd().statFile(std.testing.io, part, .{});
}

fn cacheEntryPathForTest(state_dir: []const u8, digest: []const u8) ![]u8 {
    return contentPathAlloc(std.testing.allocator, state_dir, digest);
}

fn expectCacheEntry(state_dir: []const u8, digest: []const u8, exists: bool) !void {
    const path = try cacheEntryPathForTest(state_dir, digest);
    defer std.testing.allocator.free(path);
    if (exists) {
        _ = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{});
    } else {
        try std.testing.expectError(
            error.FileNotFound,
            std.Io.Dir.cwd().statFile(std.testing.io, path, .{}),
        );
    }
}
