const std = @import("std");
const allocation = @import("allocation.zig");

pub const schema_version: u16 = 1;
pub const max_journal_bytes: usize = 4 * 1024 * 1024;
pub const max_operations: usize = 4096;
pub const fingerprint_hex_bytes: usize = 64;
pub const max_spec_json_bytes: usize = 1024 * 1024;

pub const ContainerEngine = enum {
    docker,
    nerdctl,
};

pub const ContainerHandle = struct {
    engine: ContainerEngine,
    /// Full immutable OCI container ID. Names are deliberately not accepted.
    full_id: []const u8,
};

pub const SystemdHandle = struct {
    unit_name: []const u8,
    /// systemd InvocationID encoded as 32 lowercase hexadecimal characters.
    invocation_id: []const u8,
    /// Hash of the Nimbus-owned unit/drop-in configuration, when applicable.
    configuration_fingerprint: ?[]const u8 = null,
};

pub const DirectProcessHandle = struct {
    pid: u32,
    /// Kernel process start ticks fence PID reuse across agent restarts.
    start_ticks: u64,
};

/// Immutable identity returned by a runtime after a successful start/adoption.
/// JSON uses a one-key tagged object such as
/// `{ "container": { "full_id": "..." } }`.
pub const RuntimeHandle = union(enum) {
    container: ContainerHandle,
    systemd: SystemdHandle,
    direct_process: DirectProcessHandle,

    pub fn validate(self: RuntimeHandle) ValidationError!void {
        switch (self) {
            .container => |handle| {
                if (!isLowerHex(handle.full_id, 64)) return error.InvalidContainerId;
            },
            .systemd => |handle| {
                if (!isUnitName(handle.unit_name)) return error.InvalidSystemdUnit;
                if (!isLowerHex(handle.invocation_id, 32))
                    return error.InvalidSystemdInvocationId;
                if (handle.configuration_fingerprint) |fingerprint| {
                    if (!isFingerprint(fingerprint))
                        return error.InvalidConfigurationFingerprint;
                }
            },
            .direct_process => |handle| {
                if (handle.pid == 0 or handle.pid > std.math.maxInt(i32))
                    return error.InvalidProcessId;
                if (handle.start_ticks == 0) return error.InvalidProcessStartTicks;
            },
        }
    }

    pub fn eql(left: RuntimeHandle, right: RuntimeHandle) bool {
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
        return switch (left) {
            .container => |value| value.engine == right.container.engine and
                std.mem.eql(u8, value.full_id, right.container.full_id),
            .systemd => |value| std.mem.eql(u8, value.unit_name, right.systemd.unit_name) and
                std.mem.eql(u8, value.invocation_id, right.systemd.invocation_id) and
                optionalStringEql(
                    value.configuration_fingerprint,
                    right.systemd.configuration_fingerprint,
                ),
            .direct_process => |value| value.pid == right.direct_process.pid and
                value.start_ticks == right.direct_process.start_ticks,
        };
    }

    /// Deep copy into a caller-owned allocator (normally an arena).
    pub fn clone(self: RuntimeHandle, allocator_: std.mem.Allocator) !RuntimeHandle {
        return cloneHandle(allocator_, self);
    }
};

/// The control plane has not acknowledged a stopped release until the entry
/// advances from `released_ack_pending` to `released_tombstone`.
pub const Disposition = enum {
    operation,
    released_ack_pending,
    released_tombstone,
};

/// One deep-owned, generation-fenced operation. A run replacement may need
/// both the retiring active handle and the newly created target handle.
pub const Operation = struct {
    entry: allocation.JournalEntry,
    desired_fingerprint: []const u8,
    access_fingerprint: []const u8,
    active_handle: ?RuntimeHandle = null,
    target_handle: ?RuntimeHandle = null,
    /// Exact specs retained for adoption and rollback; never inferred from a
    /// newly fetched deployment after a crash.
    active_spec_json: ?[]const u8 = null,
    target_spec_json: ?[]const u8 = null,
    disposition: Disposition = .operation,
    recorded_unix_ms: i64,
    control_plane_ack_unix_ms: ?i64 = null,

    pub fn validate(self: Operation) ValidationError!void {
        try validateOperation(self);
    }

    /// Deep copy into a caller-owned allocator (normally an arena).
    pub fn clone(self: Operation, allocator_: std.mem.Allocator) !Operation {
        return cloneOperation(allocator_, self);
    }
};

pub const ValidationError = allocation.ValidationError || error{
    TooManyOperations,
    DuplicateAllocation,
    InvalidDesiredFingerprint,
    InvalidAccessFingerprint,
    InvalidContainerId,
    InvalidSystemdUnit,
    InvalidSystemdInvocationId,
    InvalidConfigurationFingerprint,
    InvalidProcessId,
    InvalidProcessStartTicks,
    InvalidSpec,
    InvalidRecordedTimestamp,
    InvalidAcknowledgementTimestamp,
    InvalidDisposition,
    MissingRuntimeHandle,
};

pub const PutError = ValidationError || std.mem.Allocator.Error || error{
    StaleGeneration,
    GenerationGap,
    DeploymentChanged,
    CommandChanged,
    DesiredFingerprintChanged,
    AccessFingerprintChanged,
    RuntimeHandleChanged,
    SpecChanged,
    OperationIdChanged,
    AcknowledgementChanged,
    InvalidPhaseTransition,
    TimestampRegressed,
    OperationInProgress,
};

const WireDocument = struct {
    schema_version: u16,
    operations: []const Operation,
};

/// Arena-owned local journal. Every string, device list and runtime handle is
/// copied on `put` or `load`; callers may release input buffers immediately.
pub const Journal = struct {
    arena: std.heap.ArenaAllocator,
    operations: std.ArrayList(Operation) = .empty,

    pub fn init(allocator_: std.mem.Allocator) Journal {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator_) };
    }

    pub fn deinit(self: *Journal) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn items(self: *const Journal) []const Operation {
        return self.operations.items;
    }

    pub fn find(self: *const Journal, allocation_id: []const u8) ?*const Operation {
        for (self.operations.items) |*operation| {
            if (std.mem.eql(u8, operation.entry.allocation_id, allocation_id))
                return operation;
        }
        return null;
    }

    /// Replace the current generation only after validating fences and the
    /// immutability of runtime identities. The caller must persist this state
    /// with `save` before performing the side effect described by a mutating
    /// phase (`starting_target`, `stopping`, and so on).
    pub fn put(self: *Journal, operation: Operation) PutError!void {
        try validateOperation(operation);
        if (self.operations.items.len >= max_operations and
            self.findIndex(operation.entry.allocation_id) == null)
            return error.TooManyOperations;

        if (self.findIndex(operation.entry.allocation_id)) |index| {
            try validateReplacement(self.operations.items[index], operation);
            self.operations.items[index] = try cloneOperation(
                self.arena.allocator(),
                operation,
            );
        } else {
            try self.operations.append(
                self.arena.allocator(),
                try cloneOperation(self.arena.allocator(), operation),
            );
        }
    }

    pub fn validate(self: *const Journal) ValidationError!void {
        try validateOperations(self.operations.items);
    }

    /// Atomically writes and fsyncs a replacement journal. Returning success
    /// is the write-ahead durability boundary for subsequent runtime effects.
    pub fn save(self: *const Journal, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
        try self.saveWithOptions(io, dir, path, .{});
    }

    fn saveWithOptions(
        self: *const Journal,
        io: std.Io,
        dir: std.Io.Dir,
        path: []const u8,
        options: SaveOptions,
    ) !void {
        try self.validate();
        const payload = try std.json.Stringify.valueAlloc(
            self.arena.child_allocator,
            WireDocument{
                .schema_version = schema_version,
                .operations = self.operations.items,
            },
            .{},
        );
        defer self.arena.child_allocator.free(payload);

        var atomic = try dir.createFileAtomic(io, path, .{
            .make_path = true,
            .replace = true,
        });
        defer atomic.deinit(io);
        var write_buffer: [4096]u8 = undefined;
        var writer = atomic.file.writer(io, &write_buffer);
        try writer.interface.writeAll(payload);
        try writer.interface.flush();
        try atomic.file.sync(io);
        if (options.fail_before_replace) return error.InjectedWriteFailure;
        try atomic.replace(io);
    }

    pub fn load(
        allocator_: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        path: []const u8,
    ) !Journal {
        var file = try dir.openFile(io, path, .{});
        defer file.close(io);

        var read_buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &read_buffer);
        const payload = reader.interface.allocRemaining(
            allocator_,
            .limited(max_journal_bytes),
        ) catch |err| switch (err) {
            error.StreamTooLong => return error.JournalTooLarge,
            else => return err,
        };
        defer allocator_.free(payload);

        var journal = Journal.init(allocator_);
        errdefer journal.deinit();
        const document = std.json.parseFromSliceLeaky(
            WireDocument,
            journal.arena.allocator(),
            payload,
            .{
                .ignore_unknown_fields = false,
                .allocate = .alloc_always,
                .max_value_len = max_spec_json_bytes,
            },
        ) catch return error.CorruptJournal;
        if (document.schema_version != schema_version)
            return error.UnsupportedJournalSchema;
        validateOperations(document.operations) catch return error.CorruptJournal;
        try journal.operations.appendSlice(journal.arena.allocator(), document.operations);
        return journal;
    }

    fn findIndex(self: *const Journal, allocation_id: []const u8) ?usize {
        for (self.operations.items, 0..) |operation, index| {
            if (std.mem.eql(u8, operation.entry.allocation_id, allocation_id)) return index;
        }
        return null;
    }
};

const SaveOptions = struct {
    fail_before_replace: bool = false,
};

pub fn validateOperation(operation: Operation) ValidationError!void {
    try allocation.validateJournal(operation.entry);
    if (!isFingerprint(operation.desired_fingerprint))
        return error.InvalidDesiredFingerprint;
    if (!isFingerprint(operation.access_fingerprint))
        return error.InvalidAccessFingerprint;
    if (operation.active_handle) |handle| try handle.validate();
    if (operation.target_handle) |handle| try handle.validate();
    try validateOptionalSpec(operation.active_spec_json);
    try validateOptionalSpec(operation.target_spec_json);
    if (operation.recorded_unix_ms <= 0) return error.InvalidRecordedTimestamp;

    switch (operation.disposition) {
        .operation => {
            if (operation.entry.phase == .released_ack_pending or
                operation.entry.phase == .released or
                operation.control_plane_ack_unix_ms != null)
                return error.InvalidDisposition;
        },
        .released_ack_pending => {
            if (operation.entry.action != .release or
                operation.entry.phase != .released_ack_pending or
                operation.control_plane_ack_unix_ms != null)
                return error.InvalidDisposition;
            if (operation.active_handle == null) return error.MissingRuntimeHandle;
        },
        .released_tombstone => {
            if (operation.entry.action != .release or
                operation.entry.phase != .released)
                return error.InvalidDisposition;
            if (operation.active_handle == null) return error.MissingRuntimeHandle;
            const acknowledged = operation.control_plane_ack_unix_ms orelse
                return error.InvalidAcknowledgementTimestamp;
            if (acknowledged <= 0 or acknowledged > operation.recorded_unix_ms)
                return error.InvalidAcknowledgementTimestamp;
        },
    }

    if (operation.entry.action == .release and operation.target_handle != null)
        return error.InvalidDisposition;
    if (operation.entry.action == .run and operation.entry.phase == .active and
        operation.target_handle == null)
        return error.MissingRuntimeHandle;
}

fn validateOperations(operations: []const Operation) ValidationError!void {
    if (operations.len > max_operations) return error.TooManyOperations;
    for (operations, 0..) |operation, index| {
        try validateOperation(operation);
        for (operations[0..index]) |previous| {
            if (std.mem.eql(
                u8,
                previous.entry.allocation_id,
                operation.entry.allocation_id,
            )) return error.DuplicateAllocation;
        }
    }
}

fn validateReplacement(previous: Operation, next: Operation) PutError!void {
    if (next.entry.generation < previous.entry.generation)
        return error.StaleGeneration;
    if (!std.mem.eql(u8, previous.entry.deployment, next.entry.deployment))
        return error.DeploymentChanged;

    if (next.entry.generation > previous.entry.generation) {
        if (previous.entry.generation == std.math.maxInt(u64) or
            next.entry.generation != previous.entry.generation + 1)
            return error.GenerationGap;
        if (!allocation.isTerminal(previous.entry.phase) and
            previous.entry.phase != .active and previous.entry.phase != .ambiguous)
            return error.OperationInProgress;
        return;
    }

    if (!std.mem.eql(
        u8,
        previous.desired_fingerprint,
        next.desired_fingerprint,
    )) return error.DesiredFingerprintChanged;
    if (!std.mem.eql(
        u8,
        previous.access_fingerprint,
        next.access_fingerprint,
    )) return error.AccessFingerprintChanged;
    if (previous.entry.action != next.entry.action or
        previous.entry.target_revision != next.entry.target_revision or
        !stringListsEql(previous.entry.target_device_ids, next.entry.target_device_ids))
        return error.CommandChanged;
    try immutableOptionalHandle(previous.active_handle, next.active_handle);
    try immutableOptionalHandle(previous.target_handle, next.target_handle);
    try immutableOptionalString(previous.active_spec_json, next.active_spec_json);
    try immutableOptionalString(previous.target_spec_json, next.target_spec_json);
    if (previous.entry.operation_id.len > 0 and
        !std.mem.eql(u8, previous.entry.operation_id, next.entry.operation_id))
        return error.OperationIdChanged;
    if (next.recorded_unix_ms < previous.recorded_unix_ms)
        return error.TimestampRegressed;
    if (previous.control_plane_ack_unix_ms) |acknowledged| {
        if (next.control_plane_ack_unix_ms != acknowledged)
            return error.AcknowledgementChanged;
    }
    if (previous.entry.phase != next.entry.phase and
        !allocation.canTransition(previous.entry.phase, next.entry.phase))
        return error.InvalidPhaseTransition;
}

fn immutableOptionalHandle(previous: ?RuntimeHandle, next: ?RuntimeHandle) PutError!void {
    if (previous) |old| {
        const current = next orelse return error.RuntimeHandleChanged;
        if (!RuntimeHandle.eql(old, current)) return error.RuntimeHandleChanged;
    }
}

fn immutableOptionalString(previous: ?[]const u8, next: ?[]const u8) PutError!void {
    if (previous) |old| {
        const current = next orelse return error.SpecChanged;
        if (!std.mem.eql(u8, old, current)) return error.SpecChanged;
    }
}

fn cloneOperation(allocator_: std.mem.Allocator, source: Operation) !Operation {
    return .{
        .entry = try cloneEntry(allocator_, source.entry),
        .desired_fingerprint = try allocator_.dupe(u8, source.desired_fingerprint),
        .access_fingerprint = try allocator_.dupe(u8, source.access_fingerprint),
        .active_handle = if (source.active_handle) |handle|
            try cloneHandle(allocator_, handle)
        else
            null,
        .target_handle = if (source.target_handle) |handle|
            try cloneHandle(allocator_, handle)
        else
            null,
        .active_spec_json = try cloneOptionalString(allocator_, source.active_spec_json),
        .target_spec_json = try cloneOptionalString(allocator_, source.target_spec_json),
        .disposition = source.disposition,
        .recorded_unix_ms = source.recorded_unix_ms,
        .control_plane_ack_unix_ms = source.control_plane_ack_unix_ms,
    };
}

fn cloneEntry(allocator_: std.mem.Allocator, source: allocation.JournalEntry) !allocation.JournalEntry {
    return .{
        .allocation_id = try allocator_.dupe(u8, source.allocation_id),
        .generation = source.generation,
        .deployment = try allocator_.dupe(u8, source.deployment),
        .action = source.action,
        .phase = source.phase,
        .active_revision = source.active_revision,
        .target_revision = source.target_revision,
        .operation_id = try allocator_.dupe(u8, source.operation_id),
        .active_device_ids = try cloneStrings(allocator_, source.active_device_ids),
        .target_device_ids = try cloneStrings(allocator_, source.target_device_ids),
        .retiring_device_ids = try cloneStrings(allocator_, source.retiring_device_ids),
    };
}

fn cloneStrings(allocator_: std.mem.Allocator, source: []const []const u8) ![]const []const u8 {
    const result = try allocator_.alloc([]const u8, source.len);
    for (source, 0..) |value, index| result[index] = try allocator_.dupe(u8, value);
    return result;
}

fn cloneHandle(allocator_: std.mem.Allocator, source: RuntimeHandle) !RuntimeHandle {
    return switch (source) {
        .container => |handle| .{ .container = .{
            .engine = handle.engine,
            .full_id = try allocator_.dupe(u8, handle.full_id),
        } },
        .systemd => |handle| .{ .systemd = .{
            .unit_name = try allocator_.dupe(u8, handle.unit_name),
            .invocation_id = try allocator_.dupe(u8, handle.invocation_id),
            .configuration_fingerprint = if (handle.configuration_fingerprint) |value|
                try allocator_.dupe(u8, value)
            else
                null,
        } },
        .direct_process => |handle| .{ .direct_process = handle },
    };
}

fn cloneOptionalString(allocator_: std.mem.Allocator, source: ?[]const u8) !?[]const u8 {
    return if (source) |value| try allocator_.dupe(u8, value) else null;
}

fn validateOptionalSpec(value: ?[]const u8) ValidationError!void {
    if (value) |spec| {
        if (spec.len == 0 or spec.len > max_spec_json_bytes) return error.InvalidSpec;
    }
}

fn isFingerprint(value: []const u8) bool {
    return isLowerHex(value, fingerprint_hex_bytes);
}

fn isLowerHex(value: []const u8, expected_length: usize) bool {
    if (value.len != expected_length) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn isUnitName(value: []const u8) bool {
    if (value.len == 0 or value.len > 255 or
        !(std.mem.endsWith(u8, value, ".service") or
            std.mem.endsWith(u8, value, ".scope")))
        return false;
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or
            byte == '.' or byte == '@' or byte == ':'))
            return false;
    }
    return true;
}

fn optionalStringEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |left_value| {
        const right_value = right orelse return false;
        return std.mem.eql(u8, left_value, right_value);
    }
    return right == null;
}

fn stringListsEql(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_value, right_value| {
        if (!std.mem.eql(u8, left_value, right_value)) return false;
    }
    return true;
}

fn activeContainerOperation() Operation {
    return .{
        .entry = .{
            .allocation_id = "alloc-vision-7",
            .generation = 3,
            .deployment = "vision",
            .phase = .active,
            .active_revision = 7,
            .target_revision = 7,
            .active_device_ids = &.{"gpu:nvidia:01"},
            .target_device_ids = &.{"gpu:nvidia:01"},
        },
        .desired_fingerprint = "ab" ** 32,
        .access_fingerprint = "bc" ** 32,
        .target_handle = .{ .container = .{
            .engine = .docker,
            .full_id = "cd" ** 32,
        } },
        .recorded_unix_ms = 1_700_000_000_000,
    };
}

test "runtime handles reject mutable aliases and invalid process fences" {
    try (RuntimeHandle{ .container = .{
        .engine = .docker,
        .full_id = "ab" ** 32,
    } }).validate();
    try (RuntimeHandle{ .systemd = .{
        .unit_name = "nimbus-accel-vision.service",
        .invocation_id = "cd" ** 16,
        .configuration_fingerprint = "ef" ** 32,
    } }).validate();
    try (RuntimeHandle{ .direct_process = .{
        .pid = 42,
        .start_ticks = 1234,
    } }).validate();

    try std.testing.expectError(
        error.InvalidContainerId,
        (RuntimeHandle{ .container = .{
            .engine = .nerdctl,
            .full_id = "vision",
        } }).validate(),
    );
    try std.testing.expectError(
        error.InvalidProcessStartTicks,
        (RuntimeHandle{ .direct_process = .{ .pid = 42, .start_ticks = 0 } }).validate(),
    );
}

test "put deep owns entries and freezes handles within a generation" {
    var journal = Journal.init(std.testing.allocator);
    defer journal.deinit();

    var allocation_id = [_]u8{ 'a', 'l', 'l', 'o', 'c', '-', '0', '1' };
    var operation = activeContainerOperation();
    operation.entry.allocation_id = &allocation_id;
    try journal.put(operation);
    allocation_id[0] = 'X';
    try std.testing.expectEqualStrings("alloc-01", journal.items()[0].entry.allocation_id);

    var changed = journal.items()[0];
    changed.target_handle = .{ .container = .{
        .engine = .docker,
        .full_id = "de" ** 32,
    } };
    try std.testing.expectError(error.RuntimeHandleChanged, journal.put(changed));
}

test "atomic journal roundtrip retains release acknowledgement tombstone" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    var journal = Journal.init(std.testing.allocator);
    defer journal.deinit();
    var operation = activeContainerOperation();
    operation.entry = .{
        .allocation_id = "alloc-vision-7",
        .generation = 4,
        .deployment = "vision",
        .action = .release,
        .phase = .released,
    };
    operation.active_handle = operation.target_handle;
    operation.target_handle = null;
    operation.disposition = .released_tombstone;
    operation.control_plane_ack_unix_ms = operation.recorded_unix_ms;
    try journal.put(operation);
    try journal.save(std.testing.io, temporary.dir, "agent-journal.json");

    var loaded = try Journal.load(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "agent-journal.json",
    );
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.items().len);
    try std.testing.expectEqual(Disposition.released_tombstone, loaded.items()[0].disposition);
    try std.testing.expect(RuntimeHandle.eql(
        operation.active_handle.?,
        loaded.items()[0].active_handle.?,
    ));
}

test "interrupted atomic save preserves the prior valid journal" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    var journal = Journal.init(std.testing.allocator);
    defer journal.deinit();
    try journal.put(activeContainerOperation());
    try journal.save(std.testing.io, temporary.dir, "agent-journal.json");

    var next = journal.items()[0];
    next.recorded_unix_ms += 1;
    try journal.put(next);
    try std.testing.expectError(
        error.InjectedWriteFailure,
        journal.saveWithOptions(
            std.testing.io,
            temporary.dir,
            "agent-journal.json",
            .{ .fail_before_replace = true },
        ),
    );

    var loaded = try Journal.load(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "agent-journal.json",
    );
    defer loaded.deinit();
    try std.testing.expectEqual(
        @as(i64, 1_700_000_000_000),
        loaded.items()[0].recorded_unix_ms,
    );
}

test "load rejects malformed and semantically corrupt journals" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    var file = try temporary.dir.createFile(std.testing.io, "agent-journal.json", .{});
    try file.writeStreamingAll(std.testing.io, "{not-json");
    file.close(std.testing.io);
    try std.testing.expectError(
        error.CorruptJournal,
        Journal.load(
            std.testing.allocator,
            std.testing.io,
            temporary.dir,
            "agent-journal.json",
        ),
    );

    file = try temporary.dir.createFile(std.testing.io, "agent-journal.json", .{ .truncate = true });
    try file.writeStreamingAll(
        std.testing.io,
        "{\"schema_version\":99,\"operations\":[]}",
    );
    file.close(std.testing.io);
    try std.testing.expectError(
        error.UnsupportedJournalSchema,
        Journal.load(
            std.testing.allocator,
            std.testing.io,
            temporary.dir,
            "agent-journal.json",
        ),
    );
}
