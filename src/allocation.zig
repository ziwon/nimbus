const std = @import("std");
const accelerator = @import("accelerator.zig");

pub const max_token_bytes = 128;
pub const max_message_bytes = 1024;

pub const DesiredAction = enum {
    run,
    release,
};

/// Generation-fenced allocation command sent by the control plane. Slices are
/// borrowed from the containing desired-state document.
pub const DesiredAllocation = struct {
    allocation_id: []const u8,
    generation: u64,
    deployment: []const u8,
    revision: u64,
    action: DesiredAction,
    target_device_ids: []const []const u8 = &.{},
    retiring_device_ids: []const []const u8 = &.{},
};

pub const ObservedPhase = enum {
    pending,
    prepared,
    stopping_old,
    old_stopped,
    starting_target,
    target_started,
    verifying,
    active,
    stopping_target,
    target_stopped,
    restoring_old,
    release_requested,
    stopping,
    released_ack_pending,
    released,
    ambiguous,
    failed,
};

/// Agent observation for one allocation generation. A status is accepted only
/// after validateStatusForDesired confirms that its fence matches the command.
pub const Status = struct {
    allocation_id: []const u8,
    generation: u64,
    node_id: []const u8,
    deployment: []const u8,
    revision: u64,
    phase: ObservedPhase,
    message: []const u8 = "",
    observed_unix_ms: i64,
};

pub const ClaimRole = enum {
    active,
    candidate,
    retiring,
    ambiguous,
};

/// Durable agent-side operation journal. Device lists must already be in
/// strict lexical order; recovery never silently repairs persisted ownership.
pub const JournalEntry = struct {
    allocation_id: []const u8,
    generation: u64,
    deployment: []const u8,
    action: DesiredAction = .run,
    phase: ObservedPhase,
    active_revision: ?u64 = null,
    target_revision: ?u64 = null,
    operation_id: []const u8 = "",
    active_device_ids: []const []const u8 = &.{},
    target_device_ids: []const []const u8 = &.{},
    retiring_device_ids: []const []const u8 = &.{},
};

pub const ValidationError = error{
    InvalidAllocationId,
    InvalidGeneration,
    InvalidNodeId,
    InvalidDeployment,
    InvalidRevision,
    InvalidMessage,
    InvalidTimestamp,
    InvalidOperationId,
    MissingOperationId,
    TooManyDevices,
    InvalidDeviceId,
    DuplicateDeviceId,
    NonCanonicalDeviceIds,
    OverlappingDevices,
    InvalidActionDevices,
    UnexpectedPhase,
    StaleStatus,
};

pub fn validateDesired(value: DesiredAllocation) ValidationError!void {
    if (!isSafeToken(value.allocation_id)) return error.InvalidAllocationId;
    if (!isPositiveFence(value.generation)) return error.InvalidGeneration;
    if (!isSafeToken(value.deployment)) return error.InvalidDeployment;
    if (!isPositiveFence(value.revision)) return error.InvalidRevision;

    try validateDeviceIds(value.target_device_ids);
    try validateDeviceIds(value.retiring_device_ids);
    if (overlaps(value.target_device_ids, value.retiring_device_ids))
        return error.OverlappingDevices;

    switch (value.action) {
        .run => if (value.target_device_ids.len == 0)
            return error.InvalidActionDevices,
        .release => if (value.target_device_ids.len != 0 or
            value.retiring_device_ids.len == 0)
            return error.InvalidActionDevices,
    }
}

pub fn validateStatus(value: Status) ValidationError!void {
    if (!isSafeToken(value.allocation_id)) return error.InvalidAllocationId;
    if (!isPositiveFence(value.generation)) return error.InvalidGeneration;
    if (!isSafeToken(value.node_id)) return error.InvalidNodeId;
    if (!isSafeToken(value.deployment)) return error.InvalidDeployment;
    if (!isPositiveFence(value.revision)) return error.InvalidRevision;
    if (value.message.len > max_message_bytes) return error.InvalidMessage;
    if (value.observed_unix_ms <= 0) return error.InvalidTimestamp;
}

/// Validate a status and reject reports from a different allocation or stale
/// generation before they can change claims held by the desired command.
pub fn validateStatusForDesired(
    value: Status,
    desired: DesiredAllocation,
    expected_node_id: []const u8,
) ValidationError!void {
    try validateDesired(desired);
    try validateStatus(value);
    if (!isSafeToken(expected_node_id)) return error.InvalidNodeId;
    if (!std.mem.eql(u8, value.allocation_id, desired.allocation_id) or
        value.generation != desired.generation or
        !std.mem.eql(u8, value.node_id, expected_node_id) or
        !std.mem.eql(u8, value.deployment, desired.deployment) or
        value.revision != desired.revision)
        return error.StaleStatus;
    if (!statusPhaseMatchesAction(value.phase, desired.action))
        return error.UnexpectedPhase;
}

/// Validate both fences and the persisted phase edge. A missing prior phase
/// accepts only the canonical first observation; repeated reports are
/// idempotent. Agents stop at released_ack_pending—the control plane owns the
/// final released acknowledgement and claim deletion.
pub fn validateStatusTransition(
    value: Status,
    desired: DesiredAllocation,
    expected_node_id: []const u8,
    previous_phase: ?ObservedPhase,
) ValidationError!void {
    try validateStatusForDesired(value, desired, expected_node_id);
    if (previous_phase) |previous| {
        if (previous != value.phase and !canTransition(previous, value.phase))
            return error.UnexpectedPhase;
        return;
    }
    const initial: ObservedPhase = switch (desired.action) {
        .run => .pending,
        .release => .release_requested,
    };
    if (value.phase != initial) return error.UnexpectedPhase;
}

pub fn validateJournal(value: JournalEntry) ValidationError!void {
    if (!isSafeToken(value.allocation_id)) return error.InvalidAllocationId;
    if (!isPositiveFence(value.generation)) return error.InvalidGeneration;
    if (!isSafeToken(value.deployment)) return error.InvalidDeployment;
    if (value.active_revision) |revision| {
        if (!isPositiveFence(revision)) return error.InvalidRevision;
    }
    if (value.target_revision) |revision| {
        if (!isPositiveFence(revision)) return error.InvalidRevision;
    }

    if (value.operation_id.len > 0 and !isSafeToken(value.operation_id))
        return error.InvalidOperationId;
    if (isMutating(value.phase) and value.operation_id.len == 0)
        return error.MissingOperationId;

    try validateDeviceIds(value.active_device_ids);
    try validateDeviceIds(value.target_device_ids);
    try validateDeviceIds(value.retiring_device_ids);
    if (overlaps(value.target_device_ids, value.retiring_device_ids))
        return error.OverlappingDevices;
    if (!phaseMatchesAction(value.phase, value.action))
        return error.UnexpectedPhase;
    if (value.active_revision == null and value.active_device_ids.len != 0)
        return error.InvalidActionDevices;

    switch (value.action) {
        .run => {
            if (value.target_revision == null or value.target_device_ids.len == 0)
                return error.InvalidActionDevices;
            if (value.phase == .active) {
                if (value.active_revision == null or
                    value.active_revision.? != value.target_revision.? or
                    !equalIds(value.active_device_ids, value.target_device_ids) or
                    value.retiring_device_ids.len != 0)
                    return error.InvalidActionDevices;
            }
        },
        .release => {
            if (value.target_revision != null or value.target_device_ids.len != 0)
                return error.InvalidActionDevices;
            if (value.phase == .released) {
                if (value.active_revision != null or value.active_device_ids.len != 0 or
                    value.retiring_device_ids.len != 0)
                    return error.InvalidActionDevices;
            } else if (value.retiring_device_ids.len == 0) {
                return error.InvalidActionDevices;
            }
            switch (value.phase) {
                .release_requested, .stopping => {
                    if (value.active_revision == null or
                        !equalIds(value.active_device_ids, value.retiring_device_ids))
                        return error.InvalidActionDevices;
                },
                .released_ack_pending => {
                    if (value.active_revision != null or value.active_device_ids.len != 0)
                        return error.InvalidActionDevices;
                },
                else => {},
            }
        },
    }
}

/// A phase is terminal when automatic progress for its generation must stop.
/// Failed generations deliberately retain their claims until a separately
/// fenced release is acknowledged.
pub fn isTerminal(phase: ObservedPhase) bool {
    return phase == .failed or phase == .released;
}

/// Claims are fail-closed. Even failed and ambiguous observations retain them;
/// only the explicit released acknowledgement permits central reuse.
pub fn holdsClaims(phase: ObservedPhase) bool {
    return phase != .released;
}

/// Explicit allocation-operation transition graph. Repeated phase reports do
/// not constitute transitions; callers may persist them as observations
/// without invoking this helper.
pub fn canTransition(from: ObservedPhase, to: ObservedPhase) bool {
    if (from == to or isTerminal(from)) return false;

    // Any in-flight operation can fail closed. Ambiguity cannot be cleared by
    // guessing; it may only be sealed as failed for this generation.
    if (to == .failed) return true;
    if (to == .ambiguous) return from != .ambiguous;

    return switch (from) {
        .pending => to == .prepared or to == .release_requested,
        .prepared => to == .stopping_old or to == .starting_target,
        .stopping_old => to == .old_stopped,
        .old_stopped => to == .starting_target or to == .restoring_old,
        .starting_target => to == .target_started or to == .stopping_target,
        .target_started => to == .verifying or to == .stopping_target,
        .verifying => to == .active or to == .stopping_target,
        .active => to == .release_requested,
        .stopping_target => to == .target_stopped,
        .target_stopped => to == .restoring_old,
        .restoring_old => false,
        .release_requested => to == .stopping,
        .stopping => to == .released_ack_pending,
        .released_ack_pending => to == .released,
        .ambiguous, .failed, .released => false,
    };
}

pub fn isSafeToken(value: []const u8) bool {
    if (value.len == 0 or value.len > max_token_bytes or
        !std.ascii.isAlphanumeric(value[0]) or
        !std.ascii.isAlphanumeric(value[value.len - 1]))
        return false;
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.'))
            return false;
    }
    return true;
}

fn isPositiveFence(value: u64) bool {
    return value > 0 and value <= std.math.maxInt(i64);
}

fn validateDeviceIds(device_ids: []const []const u8) ValidationError!void {
    if (device_ids.len > accelerator.max_device_count) return error.TooManyDevices;
    for (device_ids, 0..) |device_id, index| {
        if (!accelerator.isValidDeviceId(device_id)) return error.InvalidDeviceId;
        if (index > 0) switch (std.mem.order(u8, device_ids[index - 1], device_id)) {
            .eq => return error.DuplicateDeviceId,
            .gt => return error.NonCanonicalDeviceIds,
            .lt => {},
        };
    }
}

fn overlaps(left: []const []const u8, right: []const []const u8) bool {
    var left_index: usize = 0;
    var right_index: usize = 0;
    while (left_index < left.len and right_index < right.len) {
        switch (std.mem.order(u8, left[left_index], right[right_index])) {
            .lt => left_index += 1,
            .gt => right_index += 1,
            .eq => return true,
        }
    }
    return false;
}

fn equalIds(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_id, right_id| {
        if (!std.mem.eql(u8, left_id, right_id)) return false;
    }
    return true;
}

fn isMutating(phase: ObservedPhase) bool {
    return switch (phase) {
        .stopping_old, .starting_target, .stopping_target, .restoring_old, .stopping => true,
        else => false,
    };
}

fn phaseMatchesAction(phase: ObservedPhase, action: DesiredAction) bool {
    return switch (action) {
        .run => switch (phase) {
            .pending,
            .prepared,
            .stopping_old,
            .old_stopped,
            .starting_target,
            .target_started,
            .verifying,
            .active,
            .stopping_target,
            .target_stopped,
            .restoring_old,
            .ambiguous,
            .failed,
            => true,
            .release_requested, .stopping, .released_ack_pending, .released => false,
        },
        .release => switch (phase) {
            .release_requested,
            .stopping,
            .released_ack_pending,
            .released,
            .ambiguous,
            .failed,
            => true,
            else => false,
        },
    };
}

fn statusPhaseMatchesAction(phase: ObservedPhase, action: DesiredAction) bool {
    if (phase == .released) return false;
    return phaseMatchesAction(phase, action);
}

fn runDesired() DesiredAllocation {
    return .{
        .allocation_id = "alloc-vision-7",
        .generation = 3,
        .deployment = "vision",
        .revision = 7,
        .action = .run,
        .target_device_ids = &.{ "gpu:nvidia:01", "gpu:nvidia:02" },
        .retiring_device_ids = &.{"gpu:nvidia:00"},
    };
}

test "valid run and release allocations" {
    try validateDesired(runDesired());
    try validateDesired(.{
        .allocation_id = "alloc-vision-7",
        .generation = 4,
        .deployment = "vision",
        .revision = 7,
        .action = .release,
        .retiring_device_ids = &.{ "gpu:nvidia:01", "gpu:nvidia:02" },
    });

    var invalid_run = runDesired();
    invalid_run.target_device_ids = &.{};
    try std.testing.expectError(error.InvalidActionDevices, validateDesired(invalid_run));

    var invalid_release = runDesired();
    invalid_release.action = .release;
    try std.testing.expectError(error.InvalidActionDevices, validateDesired(invalid_release));
}

test "allocation device sets reject noncanonical duplicates and overlap" {
    var desired = runDesired();
    desired.target_device_ids = &.{ "gpu:nvidia:02", "gpu:nvidia:01" };
    try std.testing.expectError(error.NonCanonicalDeviceIds, validateDesired(desired));

    desired.target_device_ids = &.{ "gpu:nvidia:01", "gpu:nvidia:01" };
    try std.testing.expectError(error.DuplicateDeviceId, validateDesired(desired));

    desired.target_device_ids = &.{"gpu:nvidia:01"};
    desired.retiring_device_ids = &.{"gpu:nvidia:01"};
    try std.testing.expectError(error.OverlappingDevices, validateDesired(desired));
}

test "status validation rejects stale and invalid observations" {
    const desired = runDesired();
    const valid: Status = .{
        .allocation_id = desired.allocation_id,
        .generation = desired.generation,
        .node_id = "edge-01",
        .deployment = desired.deployment,
        .revision = desired.revision,
        .phase = .prepared,
        .observed_unix_ms = 1_700_000_000_000,
    };
    try validateStatusForDesired(valid, desired, "edge-01");

    var stale = valid;
    stale.generation -= 1;
    try std.testing.expectError(
        error.StaleStatus,
        validateStatusForDesired(stale, desired, "edge-01"),
    );

    try std.testing.expectError(
        error.StaleStatus,
        validateStatusForDesired(valid, desired, "edge-02"),
    );

    var invalid = valid;
    invalid.observed_unix_ms = 0;
    try std.testing.expectError(error.InvalidTimestamp, validateStatus(invalid));

    invalid = valid;
    invalid.allocation_id = "../../unsafe";
    try std.testing.expectError(error.InvalidAllocationId, validateStatus(invalid));
}

test "run allocation rejects forged release acknowledgement" {
    const desired = runDesired();
    const forged: Status = .{
        .allocation_id = desired.allocation_id,
        .generation = desired.generation,
        .node_id = "edge-01",
        .deployment = desired.deployment,
        .revision = desired.revision,
        .phase = .released,
        .observed_unix_ms = 1_700_000_000_000,
    };
    try std.testing.expectError(
        error.UnexpectedPhase,
        validateStatusForDesired(forged, desired, "edge-01"),
    );
}

test "release status cannot skip stop or self-acknowledge claim deletion" {
    const desired: DesiredAllocation = .{
        .allocation_id = "alloc-vision-7",
        .generation = 4,
        .deployment = "vision",
        .revision = 7,
        .action = .release,
        .retiring_device_ids = &.{"gpu:nvidia:01"},
    };
    const direct: Status = .{
        .allocation_id = desired.allocation_id,
        .generation = desired.generation,
        .node_id = "edge-01",
        .deployment = desired.deployment,
        .revision = desired.revision,
        .phase = .released_ack_pending,
        .observed_unix_ms = 1_700_000_000_000,
    };
    try std.testing.expectError(
        error.UnexpectedPhase,
        validateStatusTransition(direct, desired, "edge-01", null),
    );

    var agent_released = direct;
    agent_released.phase = .released;
    try std.testing.expectError(
        error.UnexpectedPhase,
        validateStatusForDesired(agent_released, desired, "edge-01"),
    );
}

test "journal requires canonical devices and operation ids for mutations" {
    const base: JournalEntry = .{
        .allocation_id = "alloc-vision-7",
        .generation = 3,
        .deployment = "vision",
        .phase = .starting_target,
        .operation_id = "op-start-3",
        .active_revision = 6,
        .target_revision = 7,
        .active_device_ids = &.{"gpu:nvidia:00"},
        .target_device_ids = &.{"gpu:nvidia:01"},
        .retiring_device_ids = &.{"gpu:nvidia:00"},
    };
    try validateJournal(base);

    var missing_operation = base;
    missing_operation.operation_id = "";
    try std.testing.expectError(error.MissingOperationId, validateJournal(missing_operation));

    var invalid_operation = base;
    invalid_operation.operation_id = "op/start";
    try std.testing.expectError(error.InvalidOperationId, validateJournal(invalid_operation));
}

test "journal rejects phase-inconsistent ownership" {
    const empty_active: JournalEntry = .{
        .allocation_id = "alloc-vision-7",
        .generation = 3,
        .deployment = "vision",
        .phase = .active,
        .target_revision = 7,
        .target_device_ids = &.{"gpu:nvidia:01"},
    };
    try std.testing.expectError(
        error.InvalidActionDevices,
        validateJournal(empty_active),
    );

    const live_released: JournalEntry = .{
        .allocation_id = "alloc-vision-7",
        .generation = 4,
        .deployment = "vision",
        .action = .release,
        .phase = .released,
        .active_revision = 7,
        .active_device_ids = &.{"gpu:nvidia:01"},
        .retiring_device_ids = &.{"gpu:nvidia:01"},
    };
    try std.testing.expectError(
        error.InvalidActionDevices,
        validateJournal(live_released),
    );

    const released: JournalEntry = .{
        .allocation_id = "alloc-vision-7",
        .generation = 4,
        .deployment = "vision",
        .action = .release,
        .phase = .released,
    };
    try validateJournal(released);

    const unidentified_stop: JournalEntry = .{
        .allocation_id = "alloc-vision-7",
        .generation = 4,
        .deployment = "vision",
        .action = .release,
        .phase = .stopping,
        .operation_id = "op-release-4",
        .retiring_device_ids = &.{"gpu:nvidia:01"},
    };
    try std.testing.expectError(
        error.InvalidActionDevices,
        validateJournal(unidentified_stop),
    );
}

test "normal apply transitions are explicit" {
    const chain = [_]ObservedPhase{
        .pending,
        .prepared,
        .stopping_old,
        .old_stopped,
        .starting_target,
        .target_started,
        .verifying,
        .active,
    };
    for (chain[0 .. chain.len - 1], chain[1..]) |from, to|
        try std.testing.expect(canTransition(from, to));
}

test "rollback transitions restore the old allocation" {
    const chain = [_]ObservedPhase{
        .verifying,
        .stopping_target,
        .target_stopped,
        .restoring_old,
        .failed,
    };
    for (chain[0 .. chain.len - 1], chain[1..]) |from, to|
        try std.testing.expect(canTransition(from, to));
}

test "release transitions require an acknowledgement" {
    const chain = [_]ObservedPhase{
        .active,
        .release_requested,
        .stopping,
        .released_ack_pending,
        .released,
    };
    for (chain[0 .. chain.len - 1], chain[1..]) |from, to|
        try std.testing.expect(canTransition(from, to));
}

test "transition graph rejects skips and backwards movement" {
    try std.testing.expect(!canTransition(.pending, .active));
    try std.testing.expect(!canTransition(.target_started, .prepared));
    try std.testing.expect(!canTransition(.active, .verifying));
    try std.testing.expect(!canTransition(.failed, .pending));
    try std.testing.expect(!canTransition(.released, .active));
    try std.testing.expect(!canTransition(.prepared, .prepared));
    try std.testing.expect(!canTransition(.restoring_old, .active));

    try std.testing.expect(canTransition(.prepared, .ambiguous));
    try std.testing.expect(canTransition(.ambiguous, .failed));
    try std.testing.expect(canTransition(.stopping, .failed));
}

test "ambiguous and failed phases retain claims until released" {
    try std.testing.expect(holdsClaims(.ambiguous));
    try std.testing.expect(holdsClaims(.failed));
    try std.testing.expect(!holdsClaims(.released));
    try std.testing.expect(!isTerminal(.ambiguous));
    try std.testing.expect(isTerminal(.failed));
    try std.testing.expect(isTerminal(.released));
}
