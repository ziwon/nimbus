const std = @import("std");
const orchestration = @import("orchestration.zig");

pub const schema_version: u8 = 1;
const max_reservations = 32;
const max_device_ids = 32;

/// Serialization-friendly local ownership record. All slices are borrowed.
/// An OwnedLedger owns the same shape when it is built from assignments.
pub const LocalReservation = struct {
    deployment: []const u8,
    revision: u64,
    device_ids: []const []const u8,
};

/// Persistent accelerator reservation ledger stored with the agent state.
/// Records and device IDs must be in strict lexical order.
pub const Ledger = struct {
    schema_version: u8 = schema_version,
    reservations: []const LocalReservation = &.{},
};

pub const ValidationError = error{
    UnsupportedSchema,
    TooManyReservations,
    InvalidReservation,
    DuplicateOwner,
    UnsortedOwners,
    TooManyDevices,
    UnsortedDeviceIds,
    DuplicateDevice,
};

/// Canonical ledger with allocator-owned deployment names, device IDs, inner
/// slices, and outer reservation slice.
pub const OwnedLedger = struct {
    allocator: std.mem.Allocator,
    reservations: []LocalReservation,

    pub fn deinit(self: *OwnedLedger) void {
        for (self.reservations) |reservation| deinitReservation(self.allocator, reservation);
        self.allocator.free(self.reservations);
        self.* = undefined;
    }

    pub fn view(self: *const OwnedLedger) Ledger {
        return .{ .reservations = self.reservations };
    }
};

/// Validate persisted state before it participates in allocation. Validation
/// is intentionally fail-closed: non-canonical ordering and any duplicate are
/// rejected instead of being silently repaired after restart.
pub fn validate(ledger: Ledger) ValidationError!void {
    if (ledger.schema_version != schema_version) return error.UnsupportedSchema;
    if (ledger.reservations.len > max_reservations) return error.TooManyReservations;

    var total_devices: usize = 0;
    for (ledger.reservations, 0..) |reservation, reservation_index| {
        const assignment: orchestration.AcceleratorAssignment = .{
            .deployment = reservation.deployment,
            .revision = reservation.revision,
            .device_ids = reservation.device_ids,
        };
        if (!orchestration.validateAcceleratorAssignment(assignment))
            return error.InvalidReservation;

        if (reservation_index > 0) {
            const previous = ledger.reservations[reservation_index - 1];
            if (std.mem.eql(u8, previous.deployment, reservation.deployment))
                return error.DuplicateOwner;
            if (!lessString({}, previous.deployment, reservation.deployment))
                return error.UnsortedOwners;
        }

        total_devices += reservation.device_ids.len;
        if (total_devices > max_device_ids) return error.TooManyDevices;
        for (reservation.device_ids[1..], 1..) |device_id, device_index| {
            if (!lessString({}, reservation.device_ids[device_index - 1], device_id))
                return error.UnsortedDeviceIds;
        }
    }

    for (ledger.reservations, 0..) |reservation, reservation_index| {
        for (reservation.device_ids) |device_id| {
            for (ledger.reservations[0..reservation_index]) |previous| {
                for (previous.device_ids) |previous_id| {
                    if (std.mem.eql(u8, previous_id, device_id))
                        return error.DuplicateDevice;
                }
            }
        }
    }
}

pub fn isValid(ledger: Ledger) bool {
    validate(ledger) catch return false;
    return true;
}

/// Copy wire assignments into a canonical, persistent ledger. The caller owns
/// the returned ledger and must call deinit. Input ordering never affects the
/// serialized order.
pub fn fromAssignments(
    allocator: std.mem.Allocator,
    assignments: []const orchestration.AcceleratorAssignment,
) !OwnedLedger {
    if (assignments.len > max_reservations) return error.TooManyReservations;
    for (assignments) |assignment| {
        if (!orchestration.validateAcceleratorAssignment(assignment))
            return error.InvalidReservation;
    }

    const reservations = try allocator.alloc(LocalReservation, assignments.len);
    var initialized: usize = 0;
    errdefer {
        for (reservations[0..initialized]) |reservation|
            deinitReservation(allocator, reservation);
        allocator.free(reservations);
    }

    for (assignments) |assignment| {
        reservations[initialized] = try cloneAssignment(allocator, assignment);
        initialized += 1;
    }

    std.mem.sort(LocalReservation, reservations, {}, lessReservation);
    var owned: OwnedLedger = .{ .allocator = allocator, .reservations = reservations };
    try validate(owned.view());
    return owned;
}

/// Compare a recovered ledger with current assignments without relying on
/// either assignment or device input order. This also detects count and
/// revision mismatches that are not encoded separately in LocalReservation.
pub fn matchesAssignments(
    ledger: Ledger,
    assignments: []const orchestration.AcceleratorAssignment,
) bool {
    validate(ledger) catch return false;
    if (ledger.reservations.len != assignments.len) return false;

    for (assignments, 0..) |assignment, assignment_index| {
        if (!orchestration.validateAcceleratorAssignment(assignment)) return false;
        for (assignments[0..assignment_index]) |previous| {
            if (std.mem.eql(u8, previous.deployment, assignment.deployment)) return false;
        }

        const reservation = findOwner(ledger.reservations, assignment.deployment) orelse
            return false;
        if (reservation.revision != assignment.revision or
            reservation.device_ids.len != assignment.device_ids.len)
            return false;
        for (reservation.device_ids) |device_id| {
            if (!containsId(assignment.device_ids, device_id)) return false;
        }
    }
    return true;
}

fn cloneAssignment(
    allocator: std.mem.Allocator,
    assignment: orchestration.AcceleratorAssignment,
) !LocalReservation {
    const deployment = try allocator.dupe(u8, assignment.deployment);
    errdefer allocator.free(deployment);
    const device_ids = try allocator.alloc([]const u8, assignment.device_ids.len);
    errdefer allocator.free(device_ids);
    var initialized: usize = 0;
    errdefer for (device_ids[0..initialized]) |device_id| allocator.free(device_id);

    for (assignment.device_ids) |device_id| {
        device_ids[initialized] = try allocator.dupe(u8, device_id);
        initialized += 1;
    }
    std.mem.sort([]const u8, device_ids, {}, lessString);
    return .{
        .deployment = deployment,
        .revision = assignment.revision,
        .device_ids = device_ids,
    };
}

fn deinitReservation(allocator: std.mem.Allocator, reservation: LocalReservation) void {
    allocator.free(reservation.deployment);
    for (reservation.device_ids) |device_id| allocator.free(device_id);
    allocator.free(reservation.device_ids);
}

fn findOwner(
    reservations: []const LocalReservation,
    deployment: []const u8,
) ?LocalReservation {
    for (reservations) |reservation| {
        if (std.mem.eql(u8, reservation.deployment, deployment)) return reservation;
    }
    return null;
}

fn containsId(device_ids: []const []const u8, expected: []const u8) bool {
    for (device_ids) |device_id| {
        if (std.mem.eql(u8, device_id, expected)) return true;
    }
    return false;
}

fn lessString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn lessReservation(_: void, left: LocalReservation, right: LocalReservation) bool {
    return lessString({}, left.deployment, right.deployment);
}

test "assignments produce a canonical owned ledger" {
    const assignments = [_]orchestration.AcceleratorAssignment{
        .{
            .deployment = "vision-z",
            .revision = 7,
            .device_ids = &.{ "gpu:nvidia:ff", "gpu:nvidia:aa" },
        },
        .{
            .deployment = "audio-a",
            .revision = 2,
            .device_ids = &.{"dla:integrated:0"},
        },
    };
    var owned = try fromAssignments(std.testing.allocator, &assignments);
    defer owned.deinit();

    const ledger = owned.view();
    try validate(ledger);
    try std.testing.expectEqualStrings("audio-a", ledger.reservations[0].deployment);
    try std.testing.expectEqualStrings("vision-z", ledger.reservations[1].deployment);
    try std.testing.expectEqualStrings("gpu:nvidia:aa", ledger.reservations[1].device_ids[0]);
    try std.testing.expectEqualStrings("gpu:nvidia:ff", ledger.reservations[1].device_ids[1]);
    try std.testing.expect(matchesAssignments(ledger, &assignments));
}

test "persisted ledger rejects duplicate owners and devices" {
    const duplicate_owner = Ledger{ .reservations = &.{
        .{ .deployment = "vision", .revision = 1, .device_ids = &.{"gpu:a"} },
        .{ .deployment = "vision", .revision = 2, .device_ids = &.{"gpu:b"} },
    } };
    try std.testing.expectError(error.DuplicateOwner, validate(duplicate_owner));

    const duplicate_device = Ledger{ .reservations = &.{
        .{ .deployment = "audio", .revision = 1, .device_ids = &.{"gpu:a"} },
        .{ .deployment = "vision", .revision = 1, .device_ids = &.{"gpu:a"} },
    } };
    try std.testing.expectError(error.DuplicateDevice, validate(duplicate_device));
}

test "persisted ledger requires canonical ordering" {
    const owners = Ledger{ .reservations = &.{
        .{ .deployment = "vision", .revision = 1, .device_ids = &.{"gpu:a"} },
        .{ .deployment = "audio", .revision = 1, .device_ids = &.{"gpu:b"} },
    } };
    try std.testing.expectError(error.UnsortedOwners, validate(owners));

    const devices = Ledger{ .reservations = &.{
        .{ .deployment = "vision", .revision = 1, .device_ids = &.{ "gpu:b", "gpu:a" } },
    } };
    try std.testing.expectError(error.UnsortedDeviceIds, validate(devices));
}

test "recovered ledger detects assignment count and revision changes" {
    const ledger = Ledger{ .reservations = &.{
        .{ .deployment = "vision", .revision = 3, .device_ids = &.{ "gpu:a", "gpu:b" } },
    } };
    const fewer = [_]orchestration.AcceleratorAssignment{.{
        .deployment = "vision",
        .revision = 3,
        .device_ids = &.{"gpu:a"},
    }};
    try std.testing.expect(!matchesAssignments(ledger, &fewer));

    const newer = [_]orchestration.AcceleratorAssignment{.{
        .deployment = "vision",
        .revision = 4,
        .device_ids = &.{ "gpu:b", "gpu:a" },
    }};
    try std.testing.expect(!matchesAssignments(ledger, &newer));
}

test "ledger survives a JSON restart round trip" {
    const assignments = [_]orchestration.AcceleratorAssignment{
        .{ .deployment = "vision", .revision = 9, .device_ids = &.{ "gpu:c", "gpu:a" } },
    };
    var owned = try fromAssignments(std.testing.allocator, &assignments);
    defer owned.deinit();

    const payload = try std.json.Stringify.valueAlloc(std.testing.allocator, owned.view(), .{});
    defer std.testing.allocator.free(payload);
    var parsed = try std.json.parseFromSlice(Ledger, std.testing.allocator, payload, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try validate(parsed.value);
    try std.testing.expect(matchesAssignments(parsed.value, &assignments));
}
