const std = @import("std");

pub const max_cached_artifacts: usize = 128;
pub const max_power_sources: usize = 3;

pub const PowerSource = enum {
    unknown,
    mains,
    battery,
};

pub fn parsePowerSource(value: []const u8) !PowerSource {
    return std.meta.stringToEnum(PowerSource, value) orelse error.InvalidPowerSource;
}

pub const DeviceTelemetry = struct {
    id: []const u8,
    memory_free_bytes: ?u64 = null,
    temperature_millicelsius: ?i32 = null,
    power_draw_milliwatts: ?u64 = null,
};

pub const Telemetry = struct {
    schema_version: u8 = 1,
    connectivity_quality_percent: u8 = 100,
    power_source: PowerSource = .unknown,
    power_budget_milliwatts: ?u64 = null,
    cost_microunits_per_hour: ?u64 = null,
    cached_artifact_sha256: []const []const u8 = &.{},
};

pub const Policy = struct {
    /// Null keeps every eligible target. A value selects the best N targets.
    replicas: ?u16 = null,
    max_offline_seconds: u32 = 90,
    min_connectivity_quality_percent: ?u8 = null,
    allowed_power_sources: []const PowerSource = &.{},
    min_power_budget_milliwatts: ?u64 = null,
    max_cost_microunits_per_hour: ?u64 = null,
    min_accelerator_free_memory_bytes: ?u64 = null,
    max_accelerator_temperature_millicelsius: ?i32 = null,
    max_accelerator_power_milliwatts: ?u64 = null,
    prefer_cached_artifact: bool = true,
};

pub const Candidate = struct {
    node_id: []const u8,
    last_seen_unix_ms: i64,
    supports_placement: bool = true,
    accelerator_inventory_complete: bool = true,
    telemetry: ?Telemetry,
    devices: []const DeviceTelemetry = &.{},
    required_device_count: u8 = 0,
};

pub const Evaluation = struct {
    eligible: bool,
    reason_code: []const u8,
    cache_hit: bool = false,
    connectivity_quality_percent: u8 = 0,
    free_memory_bytes: u64 = 0,
    maximum_temperature_millicelsius: i32 = std.math.maxInt(i32),
    cost_microunits_per_hour: u64 = std.math.maxInt(u64),
};

pub const RankedCandidate = struct {
    candidate: Candidate,
    evaluation: Evaluation,
};

pub fn validateTelemetry(value: Telemetry) bool {
    if (value.schema_version != 1 or value.connectivity_quality_percent > 100 or
        value.cached_artifact_sha256.len > max_cached_artifacts)
        return false;
    if (value.power_budget_milliwatts) |budget| if (budget == 0) return false;
    for (value.cached_artifact_sha256, 0..) |digest, index| {
        if (!isDigest(digest)) return false;
        if (index > 0 and std.mem.order(
            u8,
            value.cached_artifact_sha256[index - 1],
            digest,
        ) != .lt) return false;
    }
    return true;
}

pub fn validatePolicy(value: Policy) bool {
    if (value.replicas) |replicas| if (replicas == 0 or replicas > 10_000) return false;
    if (value.max_offline_seconds == 0 or value.max_offline_seconds > 86_400)
        return false;
    if (value.min_connectivity_quality_percent) |quality| if (quality > 100) return false;
    if (value.allowed_power_sources.len > max_power_sources) return false;
    for (value.allowed_power_sources, 0..) |source, index| {
        for (value.allowed_power_sources[0..index]) |previous|
            if (previous == source) return false;
    }
    if (value.min_power_budget_milliwatts) |budget| if (budget == 0) return false;
    if (value.min_accelerator_free_memory_bytes) |memory| if (memory == 0) return false;
    if (value.max_accelerator_temperature_millicelsius) |temperature| {
        if (temperature < -100_000 or temperature > 250_000) return false;
    }
    if (value.max_accelerator_power_milliwatts) |power| if (power == 0) return false;
    return true;
}

pub fn evaluate(
    candidate: Candidate,
    policy: Policy,
    artifact_digests: []const []const u8,
    now_unix_ms: i64,
) Evaluation {
    if (!validatePolicy(policy) or now_unix_ms <= 0 or candidate.last_seen_unix_ms <= 0)
        return blocked("invalid_placement_input");
    if (!candidate.supports_placement) return blocked("agent_feature_unsupported");
    const offline_ms = @as(i64, policy.max_offline_seconds) * 1000;
    if (now_unix_ms -| candidate.last_seen_unix_ms > offline_ms)
        return blocked("node_offline");
    if (candidate.required_device_count > 0 and !candidate.accelerator_inventory_complete)
        return blocked("accelerator_inventory_incomplete");

    const telemetry = candidate.telemetry orelse {
        if (requiresNodeTelemetry(policy) or
            (policy.prefer_cached_artifact and artifact_digests.len > 0))
            return blocked("placement_telemetry_missing");
        return deviceEvaluation(candidate, policy, false, 100, std.math.maxInt(u64));
    };
    if (!validateTelemetry(telemetry)) return blocked("placement_telemetry_invalid");
    if (policy.min_connectivity_quality_percent) |minimum| {
        if (telemetry.connectivity_quality_percent < minimum)
            return blocked("connectivity_quality_insufficient");
    }
    if (policy.allowed_power_sources.len > 0 and
        !containsPowerSource(policy.allowed_power_sources, telemetry.power_source))
        return blocked("power_source_disallowed");
    if (policy.min_power_budget_milliwatts) |minimum| {
        const available = telemetry.power_budget_milliwatts orelse
            return blocked("power_budget_unknown");
        if (available < minimum) return blocked("power_budget_insufficient");
    }
    if (policy.max_cost_microunits_per_hour) |maximum| {
        const cost = telemetry.cost_microunits_per_hour orelse
            return blocked("placement_cost_unknown");
        if (cost > maximum) return blocked("placement_cost_exceeded");
    }
    const cache_hit = policy.prefer_cached_artifact and
        hasAnyDigest(telemetry.cached_artifact_sha256, artifact_digests);
    return deviceEvaluation(
        candidate,
        policy,
        cache_hit,
        telemetry.connectivity_quality_percent,
        telemetry.cost_microunits_per_hour orelse std.math.maxInt(u64),
    );
}

pub fn rankAlloc(
    allocator: std.mem.Allocator,
    candidates: []const Candidate,
    policy: Policy,
    artifact_digests: []const []const u8,
    now_unix_ms: i64,
) ![]RankedCandidate {
    const result = try allocator.alloc(RankedCandidate, candidates.len);
    for (candidates, 0..) |candidate, index| result[index] = .{
        .candidate = candidate,
        .evaluation = evaluate(candidate, policy, artifact_digests, now_unix_ms),
    };
    std.mem.sort(RankedCandidate, result, {}, betterRank);
    return result;
}

pub fn selected(
    ranked: []const RankedCandidate,
    policy: Policy,
    node_id: []const u8,
) bool {
    var eligible_index: usize = 0;
    for (ranked) |entry| {
        if (!entry.evaluation.eligible) continue;
        const within_limit = if (policy.replicas) |replicas|
            eligible_index < replicas
        else
            true;
        if (std.mem.eql(u8, entry.candidate.node_id, node_id)) return within_limit;
        eligible_index += 1;
    }
    return false;
}

pub fn detailAlloc(
    allocator: std.mem.Allocator,
    entry: RankedCandidate,
    is_selected: bool,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .selected = is_selected,
        .cache_hit = entry.evaluation.cache_hit,
        .connectivity_quality_percent = entry.evaluation.connectivity_quality_percent,
        .free_memory_bytes = entry.evaluation.free_memory_bytes,
        .maximum_temperature_millicelsius = entry.evaluation.maximum_temperature_millicelsius,
        .cost_microunits_per_hour = entry.evaluation.cost_microunits_per_hour,
    }, .{});
}

fn deviceEvaluation(
    candidate: Candidate,
    policy: Policy,
    cache_hit: bool,
    connectivity: u8,
    cost: u64,
) Evaluation {
    if (candidate.required_device_count > 0) {
        if (policy.min_accelerator_free_memory_bytes) |minimum| {
            var count: usize = 0;
            for (candidate.devices) |device| {
                if (device.memory_free_bytes != null and device.memory_free_bytes.? >= minimum)
                    count += 1;
            }
            if (count < candidate.required_device_count)
                return blocked("accelerator_free_memory_insufficient");
        }
        if (policy.max_accelerator_temperature_millicelsius) |maximum| {
            var count: usize = 0;
            for (candidate.devices) |device| {
                if (!passesMemory(device, policy)) continue;
                if (device.temperature_millicelsius != null and
                    device.temperature_millicelsius.? <= maximum) count += 1;
            }
            if (count < candidate.required_device_count)
                return blocked("accelerator_temperature_exceeded");
        }
        if (policy.max_accelerator_power_milliwatts) |maximum| {
            var count: usize = 0;
            for (candidate.devices) |device| {
                if (!passesMemory(device, policy) or !passesTemperature(device, policy)) continue;
                if (device.power_draw_milliwatts != null and
                    device.power_draw_milliwatts.? <= maximum) count += 1;
            }
            if (count < candidate.required_device_count)
                return blocked("accelerator_power_exceeded");
        }
    }
    var compatible_count: usize = 0;
    var free_memory: u64 = 0;
    var maximum_temperature: i32 = std.math.minInt(i32);
    for (candidate.devices) |device| {
        if (!deviceEligible(device, policy)) continue;
        compatible_count += 1;
        free_memory +|= device.memory_free_bytes orelse 0;
        maximum_temperature = @max(
            maximum_temperature,
            device.temperature_millicelsius orelse std.math.maxInt(i32),
        );
    }
    if (candidate.required_device_count > 0 and compatible_count < candidate.required_device_count) {
        return blocked("accelerator_dynamic_capacity_insufficient");
    }
    return .{
        .eligible = true,
        .reason_code = "placement_selected",
        .cache_hit = cache_hit,
        .connectivity_quality_percent = connectivity,
        .free_memory_bytes = free_memory,
        .maximum_temperature_millicelsius = if (maximum_temperature == std.math.minInt(i32))
            std.math.maxInt(i32)
        else
            maximum_temperature,
        .cost_microunits_per_hour = cost,
    };
}

pub fn deviceEligible(device: DeviceTelemetry, policy: Policy) bool {
    if (!passesMemory(device, policy) or !passesTemperature(device, policy)) return false;
    if (policy.max_accelerator_power_milliwatts) |maximum| {
        if ((device.power_draw_milliwatts orelse return false) > maximum) return false;
    }
    return true;
}

fn passesMemory(device: DeviceTelemetry, policy: Policy) bool {
    const minimum = policy.min_accelerator_free_memory_bytes orelse return true;
    return (device.memory_free_bytes orelse return false) >= minimum;
}

fn passesTemperature(device: DeviceTelemetry, policy: Policy) bool {
    const maximum = policy.max_accelerator_temperature_millicelsius orelse return true;
    return (device.temperature_millicelsius orelse return false) <= maximum;
}

fn betterRank(_: void, lhs: RankedCandidate, rhs: RankedCandidate) bool {
    if (lhs.evaluation.eligible != rhs.evaluation.eligible) return lhs.evaluation.eligible;
    if (lhs.evaluation.cache_hit != rhs.evaluation.cache_hit) return lhs.evaluation.cache_hit;
    if (lhs.evaluation.connectivity_quality_percent != rhs.evaluation.connectivity_quality_percent)
        return lhs.evaluation.connectivity_quality_percent > rhs.evaluation.connectivity_quality_percent;
    if (lhs.evaluation.free_memory_bytes != rhs.evaluation.free_memory_bytes)
        return lhs.evaluation.free_memory_bytes > rhs.evaluation.free_memory_bytes;
    if (lhs.evaluation.maximum_temperature_millicelsius != rhs.evaluation.maximum_temperature_millicelsius)
        return lhs.evaluation.maximum_temperature_millicelsius < rhs.evaluation.maximum_temperature_millicelsius;
    if (lhs.evaluation.cost_microunits_per_hour != rhs.evaluation.cost_microunits_per_hour)
        return lhs.evaluation.cost_microunits_per_hour < rhs.evaluation.cost_microunits_per_hour;
    return std.mem.order(u8, lhs.candidate.node_id, rhs.candidate.node_id) == .lt;
}

fn requiresNodeTelemetry(policy: Policy) bool {
    return policy.min_connectivity_quality_percent != null or
        policy.allowed_power_sources.len > 0 or
        policy.min_power_budget_milliwatts != null or
        policy.max_cost_microunits_per_hour != null;
}

fn containsPowerSource(values: []const PowerSource, expected: PowerSource) bool {
    for (values) |value| if (value == expected) return true;
    return false;
}

fn hasAnyDigest(available: []const []const u8, expected: []const []const u8) bool {
    for (available) |cached| for (expected) |digest|
        if (std.ascii.eqlIgnoreCase(cached, digest)) return true;
    return false;
}

fn isDigest(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn blocked(reason: []const u8) Evaluation {
    return .{ .eligible = false, .reason_code = reason };
}

test "ranking is deterministic for equal inputs and independent of input order" {
    const policy: Policy = .{ .replicas = 1, .prefer_cached_artifact = false };
    const candidates_a = [_]Candidate{
        .{ .node_id = "node-b", .last_seen_unix_ms = 1000, .telemetry = .{} },
        .{ .node_id = "node-a", .last_seen_unix_ms = 1000, .telemetry = .{} },
    };
    const candidates_b = [_]Candidate{ candidates_a[1], candidates_a[0] };
    const ranked_a = try rankAlloc(std.testing.allocator, &candidates_a, policy, &.{}, 2000);
    defer std.testing.allocator.free(ranked_a);
    const ranked_b = try rankAlloc(std.testing.allocator, &candidates_b, policy, &.{}, 2000);
    defer std.testing.allocator.free(ranked_b);
    try std.testing.expectEqualStrings("node-a", ranked_a[0].candidate.node_id);
    try std.testing.expectEqualStrings(ranked_a[0].candidate.node_id, ranked_b[0].candidate.node_id);
}

test "offline thermal capacity cost and cache policies are simulated" {
    const digest = "ab" ** 32;
    const policy: Policy = .{
        .replicas = 1,
        .max_offline_seconds = 10,
        .min_connectivity_quality_percent = 50,
        .max_cost_microunits_per_hour = 100,
        .min_accelerator_free_memory_bytes = 1024,
        .max_accelerator_temperature_millicelsius = 80_000,
    };
    const cool = [_]DeviceTelemetry{.{
        .id = "gpu:a",
        .memory_free_bytes = 4096,
        .temperature_millicelsius = 60_000,
    }};
    const hot = [_]DeviceTelemetry{.{
        .id = "gpu:b",
        .memory_free_bytes = 4096,
        .temperature_millicelsius = 90_000,
    }};
    const candidates = [_]Candidate{
        .{
            .node_id = "offline",
            .last_seen_unix_ms = 1,
            .telemetry = .{},
            .devices = &cool,
            .required_device_count = 1,
        },
        .{
            .node_id = "hot",
            .last_seen_unix_ms = 19_000,
            .telemetry = .{ .cost_microunits_per_hour = 10 },
            .devices = &hot,
            .required_device_count = 1,
        },
        .{
            .node_id = "expensive",
            .last_seen_unix_ms = 19_000,
            .telemetry = .{ .cost_microunits_per_hour = 101 },
            .devices = &cool,
            .required_device_count = 1,
        },
        .{
            .node_id = "cached",
            .last_seen_unix_ms = 19_000,
            .telemetry = .{
                .cost_microunits_per_hour = 20,
                .cached_artifact_sha256 = &.{digest},
            },
            .devices = &cool,
            .required_device_count = 1,
        },
    };
    const ranked = try rankAlloc(std.testing.allocator, &candidates, policy, &.{digest}, 20_000);
    defer std.testing.allocator.free(ranked);
    try std.testing.expectEqualStrings("cached", ranked[0].candidate.node_id);
    try std.testing.expectEqualStrings("node_offline", evaluate(candidates[0], policy, &.{digest}, 20_000).reason_code);
    try std.testing.expectEqualStrings("accelerator_temperature_exceeded", evaluate(candidates[1], policy, &.{digest}, 20_000).reason_code);
    try std.testing.expectEqualStrings("placement_cost_exceeded", evaluate(candidates[2], policy, &.{digest}, 20_000).reason_code);
}
