const std = @import("std");
const builtin = @import("builtin");
const device_access = @import("device_access.zig");
const placement = @import("placement.zig");

pub const max_command_output_bytes = 64 * 1024;
pub const max_device_count = 32;
pub const max_probe_count = 16;

pub const Kind = enum {
    gpu,
    npu,
    dla,
    tpu,
    dsp,
    other,
};

pub const Requirement = struct {
    count: u8 = 1,
    kind: Kind,
    vendor: ?[]const u8 = null,
    memory_min_bytes: ?u64 = null,
    capabilities: []const []const u8 = &.{},
};

pub const SelectionError = error{
    OutOfMemory,
    InvalidInventory,
    InvalidRequirement,
    InventoryPartial,
    InventoryUnavailable,
    KindMismatch,
    DeviceUnavailable,
    VendorMismatch,
    MemoryMismatch,
    CapabilityMismatch,
    InsufficientDevices,
    DeviceReserved,
    DynamicPolicyMismatch,
};

pub const Availability = enum {
    available,
    degraded,
    unavailable,
};

pub const RuntimeVersion = struct {
    name: []const u8,
    version: []const u8,
};

/// All slices are owned by the containing Inventory.
pub const Device = struct {
    id: []const u8,
    kind: Kind,
    vendor: []const u8,
    model: []const u8,
    source: []const u8,
    availability: Availability = .available,
    memory_total_bytes: ?u64 = null,
    memory_free_bytes: ?u64 = null,
    temperature_millicelsius: ?i32 = null,
    power_draw_milliwatts: ?u64 = null,
    driver_version: ?[]const u8 = null,
    runtimes: []const RuntimeVersion = &.{},
    capabilities: []const []const u8 = &.{},

    fn deinit(self: *Device, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.vendor);
        allocator.free(self.model);
        allocator.free(self.source);
        if (self.driver_version) |version| allocator.free(version);
        for (self.runtimes) |runtime| {
            allocator.free(runtime.name);
            allocator.free(runtime.version);
        }
        allocator.free(self.runtimes);
        for (self.capabilities) |capability| allocator.free(capability);
        allocator.free(self.capabilities);
    }
};

pub const DeviceInput = struct {
    id: []const u8,
    kind: Kind,
    vendor: []const u8,
    model: []const u8,
    source: []const u8,
    availability: Availability = .available,
    memory_total_bytes: ?u64 = null,
    memory_free_bytes: ?u64 = null,
    temperature_millicelsius: ?i32 = null,
    power_draw_milliwatts: ?u64 = null,
    driver_version: ?[]const u8 = null,
    runtimes: []const RuntimeVersion = &.{},
    capabilities: []const []const u8 = &.{},
    /// Node-local runtime access data. This is never included in report().
    local_binding: ?device_access.LocalBinding = null,
};

pub const InventoryStatus = enum {
    /// Every configured probe completed or reported that its provider is absent.
    complete,
    /// Some devices were found, but at least one probe failed or was truncated.
    partial,
    /// No trustworthy inventory could be produced.
    unavailable,
};

pub const ProbeStatus = enum {
    ok,
    not_present,
    failed,
    truncated,
};

pub const ProbeOutcome = struct {
    name: []const u8,
    status: ProbeStatus,
    devices_found: usize,
    error_name: ?[]const u8 = null,

    fn deinit(self: *ProbeOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.error_name) |name| allocator.free(name);
    }
};

pub const Inventory = struct {
    allocator: std.mem.Allocator,
    status: InventoryStatus,
    devices: []Device,
    probe_outcomes: []ProbeOutcome,
    access_catalog: device_access.OwnedCatalog,

    pub fn deinit(self: *Inventory) void {
        for (self.devices) |*device| device.deinit(self.allocator);
        self.allocator.free(self.devices);
        for (self.probe_outcomes) |*outcome| outcome.deinit(self.allocator);
        self.allocator.free(self.probe_outcomes);
        self.access_catalog.deinit();
        self.* = undefined;
    }

    pub fn isCpuOnly(self: Inventory) bool {
        return self.status == .complete and self.devices.len == 0;
    }

    /// Borrowed, serialization-friendly view. It is valid until deinit is called.
    pub fn report(self: *const Inventory) InventoryReport {
        return .{
            .status = self.status,
            .accelerators = self.devices,
            .probes = self.probe_outcomes,
        };
    }

    /// Borrowed node-private catalog. It must never cross the heartbeat/API
    /// trust boundary.
    pub fn accessCatalog(self: *const Inventory) device_access.Catalog {
        return self.access_catalog.view();
    }
};

pub const InventoryReport = struct {
    schema_version: u8 = 1,
    status: InventoryStatus,
    accelerators: []const Device,
    probes: []const ProbeOutcome,
};

pub fn validateRequirement(requirement: Requirement) bool {
    if (requirement.count == 0 or requirement.count > max_device_count or
        requirement.capabilities.len > 32)
        return false;
    if (requirement.vendor) |vendor| {
        if (!validOpaqueName(vendor, 64)) return false;
    }
    if (requirement.memory_min_bytes) |memory| {
        if (memory == 0 or memory > std.math.maxInt(i64)) return false;
    }
    for (requirement.capabilities, 0..) |capability, index| {
        if (!validOpaqueName(capability, 256)) return false;
        for (requirement.capabilities[0..index]) |previous| {
            if (std.mem.eql(u8, previous, capability)) return false;
        }
    }
    return true;
}

pub fn isValidDeviceId(value: []const u8) bool {
    return validOpaqueName(value, 256);
}

/// Returns a caller-owned outer slice whose device ID strings borrow from the
/// inventory. Selection is all-or-none and stable across inventory order.
pub fn selectAlloc(
    allocator: std.mem.Allocator,
    inventory: InventoryReport,
    requirement: Requirement,
    reserved_ids: []const []const u8,
) SelectionError![]const []const u8 {
    return selectInternalAlloc(allocator, inventory, requirement, reserved_ids, null);
}

pub fn selectForPlacementAlloc(
    allocator: std.mem.Allocator,
    inventory: InventoryReport,
    requirement: Requirement,
    reserved_ids: []const []const u8,
    policy: placement.Policy,
) SelectionError![]const []const u8 {
    return selectInternalAlloc(allocator, inventory, requirement, reserved_ids, policy);
}

fn selectInternalAlloc(
    allocator: std.mem.Allocator,
    inventory: InventoryReport,
    requirement: Requirement,
    reserved_ids: []const []const u8,
    policy: ?placement.Policy,
) SelectionError![]const []const u8 {
    if (!validateRequirement(requirement)) return error.InvalidRequirement;
    if (inventory.accelerators.len > max_device_count) return error.InvalidInventory;
    switch (inventory.status) {
        .partial => return error.InventoryPartial,
        .unavailable => return error.InventoryUnavailable,
        .complete => {},
    }

    var kind_count: usize = 0;
    var vendor_count: usize = 0;
    var memory_count: usize = 0;
    var compatible_count: usize = 0;
    var available_count: usize = 0;
    var dynamic_count: usize = 0;
    var candidates: [max_device_count][]const u8 = undefined;
    var candidate_count: usize = 0;

    for (inventory.accelerators) |device| {
        if (device.kind != requirement.kind) continue;
        kind_count += 1;
        if (!vendorMatches(device, requirement)) continue;
        vendor_count += 1;
        if (!memoryMatches(device, requirement)) continue;
        memory_count += 1;
        if (!capabilitiesMatch(device, requirement)) continue;
        compatible_count += 1;
        if (device.availability != .available) continue;
        available_count += 1;
        if (policy) |placement_policy| {
            if (!placement.deviceEligible(.{
                .id = device.id,
                .memory_free_bytes = device.memory_free_bytes,
                .temperature_millicelsius = device.temperature_millicelsius,
                .power_draw_milliwatts = device.power_draw_milliwatts,
            }, placement_policy)) continue;
        }
        dynamic_count += 1;
        if (containsId(reserved_ids, device.id)) continue;
        candidates[candidate_count] = device.id;
        candidate_count += 1;
    }

    if (kind_count == 0) return error.KindMismatch;
    if (vendor_count == 0) return error.VendorMismatch;
    if (memory_count == 0) return error.MemoryMismatch;
    if (compatible_count == 0) return error.CapabilityMismatch;
    if (compatible_count < requirement.count) return error.InsufficientDevices;
    if (available_count < requirement.count) return error.DeviceUnavailable;
    if (dynamic_count < requirement.count) return error.DynamicPolicyMismatch;
    if (candidate_count < requirement.count) return error.DeviceReserved;

    sortIds(candidates[0..candidate_count]);
    return allocator.dupe([]const u8, candidates[0..requirement.count]);
}

pub fn matchesRequirement(device: Device, requirement: Requirement) bool {
    return validateRequirement(requirement) and
        device.kind == requirement.kind and
        device.availability == .available and
        vendorMatches(device, requirement) and
        memoryMatches(device, requirement) and
        capabilitiesMatch(device, requirement);
}

fn vendorMatches(device: Device, requirement: Requirement) bool {
    const vendor = requirement.vendor orelse return true;
    return std.ascii.eqlIgnoreCase(device.vendor, vendor);
}

fn memoryMatches(device: Device, requirement: Requirement) bool {
    const minimum = requirement.memory_min_bytes orelse return true;
    const total = device.memory_total_bytes orelse return false;
    return total >= minimum;
}

fn capabilitiesMatch(device: Device, requirement: Requirement) bool {
    for (requirement.capabilities) |required| {
        var found = false;
        for (device.capabilities) |available| {
            if (!std.mem.eql(u8, required, available)) continue;
            found = true;
            break;
        }
        if (!found) return false;
    }
    return true;
}

fn containsId(ids: []const []const u8, target: []const u8) bool {
    for (ids) |id| if (std.mem.eql(u8, id, target)) return true;
    return false;
}

fn sortIds(ids: [][]const u8) void {
    for (ids[1..], 1..) |id, index| {
        var destination = index;
        while (destination > 0 and std.mem.order(u8, id, ids[destination - 1]) == .lt) : (destination -= 1) {
            ids[destination] = ids[destination - 1];
        }
        ids[destination] = id;
    }
}

pub const ProbeDisposition = enum {
    supported,
    not_present,
};

pub const ProbeFn = *const fn (
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    collector: *Collector,
) anyerror!ProbeDisposition;

pub const Probe = struct {
    name: []const u8,
    context: ?*anyopaque = null,
    run_fn: ProbeFn,

    fn run(
        self: Probe,
        allocator: std.mem.Allocator,
        io: std.Io,
        collector: *Collector,
    ) !ProbeDisposition {
        return self.run_fn(self.context, allocator, io, collector);
    }
};

pub const Collector = struct {
    allocator: std.mem.Allocator,
    limit: usize,
    devices: std.ArrayList(Device) = .empty,
    access_bindings: std.ArrayList(device_access.LocalBinding) = .empty,

    pub fn init(allocator: std.mem.Allocator, limit: usize) Collector {
        return .{ .allocator = allocator, .limit = limit };
    }

    pub fn deinit(self: *Collector) void {
        for (self.devices.items) |*device| device.deinit(self.allocator);
        self.devices.deinit(self.allocator);
        for (self.access_bindings.items) |binding|
            deinitAccessBinding(self.allocator, binding);
        self.access_bindings.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *Collector, input: DeviceInput) !void {
        if (self.devices.items.len >= self.limit) return error.DeviceLimitExceeded;
        try validateInput(input);

        var device: Device = .{
            .id = try self.allocator.dupe(u8, input.id),
            .kind = input.kind,
            .vendor = undefined,
            .model = undefined,
            .source = undefined,
            .availability = input.availability,
            .memory_total_bytes = input.memory_total_bytes,
            .memory_free_bytes = input.memory_free_bytes,
            .temperature_millicelsius = input.temperature_millicelsius,
            .power_draw_milliwatts = input.power_draw_milliwatts,
            .driver_version = null,
        };
        errdefer self.allocator.free(device.id);
        device.vendor = try self.allocator.dupe(u8, input.vendor);
        errdefer self.allocator.free(device.vendor);
        device.model = try self.allocator.dupe(u8, input.model);
        errdefer self.allocator.free(device.model);
        device.source = try self.allocator.dupe(u8, input.source);
        errdefer self.allocator.free(device.source);
        if (input.driver_version) |version| {
            device.driver_version = try self.allocator.dupe(u8, version);
        }
        errdefer if (device.driver_version) |version| self.allocator.free(version);

        var runtimes: std.ArrayList(RuntimeVersion) = .empty;
        errdefer {
            for (runtimes.items) |runtime| {
                self.allocator.free(runtime.name);
                self.allocator.free(runtime.version);
            }
            runtimes.deinit(self.allocator);
        }
        for (input.runtimes) |runtime| {
            const name = try self.allocator.dupe(u8, runtime.name);
            errdefer self.allocator.free(name);
            const version = try self.allocator.dupe(u8, runtime.version);
            errdefer self.allocator.free(version);
            try runtimes.append(self.allocator, .{ .name = name, .version = version });
        }
        device.runtimes = try runtimes.toOwnedSlice(self.allocator);
        errdefer {
            for (device.runtimes) |runtime| {
                self.allocator.free(runtime.name);
                self.allocator.free(runtime.version);
            }
            self.allocator.free(device.runtimes);
        }

        var capabilities: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (capabilities.items) |capability| self.allocator.free(capability);
            capabilities.deinit(self.allocator);
        }
        for (input.capabilities) |capability| {
            const owned_capability = try self.allocator.dupe(u8, capability);
            errdefer self.allocator.free(owned_capability);
            try capabilities.append(self.allocator, owned_capability);
        }
        device.capabilities = try capabilities.toOwnedSlice(self.allocator);
        errdefer {
            for (device.capabilities) |capability| self.allocator.free(capability);
            self.allocator.free(device.capabilities);
        }

        const owned_binding = if (input.local_binding) |binding| blk: {
            if (!std.mem.eql(u8, binding.device_id, input.id))
                return error.InvalidDeviceBinding;
            try device_access.validateCatalog(&.{input.id}, .{ .bindings = &.{binding} });
            break :blk try cloneAccessBinding(self.allocator, binding);
        } else null;
        errdefer if (owned_binding) |binding|
            deinitAccessBinding(self.allocator, binding);

        try self.devices.ensureUnusedCapacity(self.allocator, 1);
        if (owned_binding != null)
            try self.access_bindings.ensureUnusedCapacity(self.allocator, 1);
        self.devices.appendAssumeCapacity(device);
        if (owned_binding) |binding| self.access_bindings.appendAssumeCapacity(binding);
    }
};

pub const Registry = struct {
    probes: []const Probe,
    device_limit: usize = max_device_count,

    pub fn collect(self: Registry, allocator: std.mem.Allocator, io: std.Io) !Inventory {
        if (self.probes.len == 0) return emptyUnavailableInventory(allocator);
        if (self.probes.len > max_probe_count) return error.TooManyProbes;
        if (self.device_limit == 0 or self.device_limit > max_device_count)
            return error.InvalidDeviceLimit;

        var devices: std.ArrayList(Device) = .empty;
        errdefer deinitDeviceList(allocator, &devices);
        var access_bindings: std.ArrayList(device_access.LocalBinding) = .empty;
        errdefer deinitAccessBindingList(allocator, &access_bindings);
        var outcomes: std.ArrayList(ProbeOutcome) = .empty;
        errdefer deinitOutcomeList(allocator, &outcomes);
        var incomplete = false;

        for (self.probes) |probe| {
            if (!validOpaqueName(probe.name, 64)) return error.InvalidProbeName;
            const remaining = self.device_limit - devices.items.len;
            if (remaining == 0) {
                incomplete = true;
                try appendOutcome(allocator, &outcomes, probe.name, .truncated, 0, "DeviceLimitExceeded");
                continue;
            }

            var collector = Collector.init(allocator, remaining);
            defer collector.deinit();
            const disposition = probe.run(allocator, io, &collector) catch |err| {
                incomplete = true;
                const status: ProbeStatus = if (err == error.DeviceLimitExceeded) .truncated else .failed;
                try appendOutcome(allocator, &outcomes, probe.name, status, 0, @errorName(err));
                continue;
            };

            if (disposition == .not_present) {
                try appendOutcome(allocator, &outcomes, probe.name, .not_present, 0, null);
                continue;
            }

            const found = collector.devices.items.len;
            if (hasDuplicateDeviceId(devices.items, collector.devices.items)) {
                incomplete = true;
                try appendOutcome(allocator, &outcomes, probe.name, .failed, 0, "DuplicateDeviceId");
                continue;
            }
            try devices.ensureUnusedCapacity(allocator, found);
            try access_bindings.ensureUnusedCapacity(
                allocator,
                collector.access_bindings.items.len,
            );
            for (collector.devices.items) |device| devices.appendAssumeCapacity(device);
            for (collector.access_bindings.items) |binding|
                access_bindings.appendAssumeCapacity(binding);
            collector.devices.items.len = 0;
            collector.access_bindings.items.len = 0;
            try appendOutcome(
                allocator,
                &outcomes,
                probe.name,
                .ok,
                found,
                null,
            );
        }

        const status: InventoryStatus = if (incomplete)
            if (devices.items.len == 0) .unavailable else .partial
        else
            .complete;
        const owned_devices = try devices.toOwnedSlice(allocator);
        errdefer {
            for (owned_devices) |*device| device.deinit(allocator);
            allocator.free(owned_devices);
        }
        const owned_outcomes = try outcomes.toOwnedSlice(allocator);
        errdefer {
            for (owned_outcomes) |*outcome| outcome.deinit(allocator);
            allocator.free(owned_outcomes);
        }
        var inventory_ids: [max_device_count][]const u8 = undefined;
        for (owned_devices, 0..) |device, index| inventory_ids[index] = device.id;
        try device_access.validateCatalog(
            inventory_ids[0..owned_devices.len],
            .{ .bindings = access_bindings.items },
        );
        const owned_access_bindings = try access_bindings.toOwnedSlice(allocator);
        return .{
            .allocator = allocator,
            .status = status,
            .devices = owned_devices,
            .probe_outcomes = owned_outcomes,
            .access_catalog = .{
                .allocator = allocator,
                .bindings = owned_access_bindings,
            },
        };
    }
};

pub fn collectSystem(allocator: std.mem.Allocator, io: std.Io) !Inventory {
    // Prefer Jetson's functional GPU/DLA slots. Some Jetson releases also ship
    // nvidia-smi, and running both providers would claim the integrated GPU
    // twice under different identities.
    const jetson_probes = [_]Probe{jetsonSystemProbe()};
    var jetson = try (Registry{ .probes = &jetson_probes }).collect(allocator, io);
    if (jetson.status != .complete or jetson.devices.len > 0) return jetson;
    jetson.deinit();

    const discrete_probes = [_]Probe{nvidiaSmiProbe()};
    return (Registry{ .probes = &discrete_probes }).collect(allocator, io);
}

pub fn nvidiaSmiProbe() Probe {
    return .{ .name = "nvidia-smi", .run_fn = runNvidiaSmi };
}

pub fn jetsonSystemProbe() Probe {
    return .{ .name = "jetson-system-files", .run_fn = runJetsonSystemFiles };
}

fn validateInput(input: DeviceInput) !void {
    if (input.id.len == 0 or input.id.len > 256 or
        input.vendor.len == 0 or input.vendor.len > 64 or
        input.model.len == 0 or input.model.len > 512 or
        input.source.len == 0 or input.source.len > 64)
        return error.InvalidDevice;
    if (input.runtimes.len > 16 or input.capabilities.len > 32)
        return error.InvalidDevice;
    if (input.memory_total_bytes) |memory| {
        if (memory == 0 or memory > std.math.maxInt(i64)) return error.InvalidDevice;
    }
    if (input.memory_free_bytes) |memory| {
        if (memory > std.math.maxInt(i64) or
            (input.memory_total_bytes != null and memory > input.memory_total_bytes.?))
            return error.InvalidDevice;
    }
    if (input.temperature_millicelsius) |temperature| {
        if (temperature < -100_000 or temperature > 250_000) return error.InvalidDevice;
    }
    if (input.power_draw_milliwatts) |power| {
        if (power == 0 or power > std.math.maxInt(i64)) return error.InvalidDevice;
    }
    if (input.driver_version) |version| if (version.len > 128) return error.InvalidDevice;
    for (input.runtimes, 0..) |runtime, runtime_index| {
        if (runtime.name.len == 0 or runtime.name.len > 64 or
            runtime.version.len == 0 or runtime.version.len > 128)
            return error.InvalidDevice;
        for (input.runtimes[0..runtime_index]) |previous| {
            if (std.mem.eql(u8, previous.name, runtime.name)) return error.InvalidDevice;
        }
    }
    for (input.capabilities, 0..) |capability, capability_index| {
        if (capability.len == 0 or capability.len > 256) return error.InvalidDevice;
        for (input.capabilities[0..capability_index]) |previous| {
            if (std.mem.eql(u8, previous, capability)) return error.InvalidDevice;
        }
    }
}

fn hasDuplicateDeviceId(existing: []const Device, added: []const Device) bool {
    for (added, 0..) |device, index| {
        for (existing) |previous| {
            if (std.mem.eql(u8, previous.id, device.id)) return true;
        }
        for (added[0..index]) |previous| {
            if (std.mem.eql(u8, previous.id, device.id)) return true;
        }
    }
    return false;
}

/// Validate an inventory received across the heartbeat trust boundary.
pub fn validateReport(report: InventoryReport) bool {
    if (report.schema_version != 1 or report.accelerators.len > max_device_count or
        report.probes.len == 0 or report.probes.len > max_probe_count)
        return false;

    var has_incomplete_probe = false;
    for (report.probes, 0..) |probe, probe_index| {
        if (!validOpaqueName(probe.name, 64) or probe.devices_found > max_device_count)
            return false;
        for (report.probes[0..probe_index]) |previous| {
            if (std.mem.eql(u8, previous.name, probe.name)) return false;
        }
        switch (probe.status) {
            .ok, .not_present => if (probe.error_name != null) return false,
            .failed, .truncated => {
                has_incomplete_probe = true;
                const reason = probe.error_name orelse return false;
                if (!validOpaqueName(reason, 256)) return false;
            },
        }
        if (probe.status == .not_present and probe.devices_found != 0) return false;
    }

    for (report.accelerators, 0..) |device, device_index| {
        if (!validDevice(device)) return false;
        for (report.accelerators[0..device_index]) |previous| {
            if (std.mem.eql(u8, previous.id, device.id)) return false;
        }
        var source_found = false;
        for (report.probes) |probe| {
            if (!std.mem.eql(u8, probe.name, device.source)) continue;
            if (probe.status != .ok) return false;
            source_found = true;
            break;
        }
        if (!source_found) return false;
    }
    for (report.probes) |probe| {
        if (probe.status != .ok) continue;
        var source_count: usize = 0;
        for (report.accelerators) |device| {
            if (std.mem.eql(u8, device.source, probe.name)) source_count += 1;
        }
        if (source_count != probe.devices_found) return false;
    }

    return switch (report.status) {
        .complete => !has_incomplete_probe,
        .partial => has_incomplete_probe and report.accelerators.len > 0,
        .unavailable => has_incomplete_probe and report.accelerators.len == 0,
    };
}

fn validDevice(device: Device) bool {
    if (!validOpaqueName(device.id, 256) or device.vendor.len == 0 or device.vendor.len > 64 or
        device.model.len == 0 or device.model.len > 512 or !validOpaqueName(device.source, 64) or
        device.runtimes.len > 16 or device.capabilities.len > 32)
        return false;
    if (device.memory_total_bytes) |memory| {
        if (memory == 0 or memory > std.math.maxInt(i64)) return false;
    }
    if (device.memory_free_bytes) |memory| {
        if (memory > std.math.maxInt(i64) or
            (device.memory_total_bytes != null and memory > device.memory_total_bytes.?))
            return false;
    }
    if (device.temperature_millicelsius) |temperature| {
        if (temperature < -100_000 or temperature > 250_000) return false;
    }
    if (device.power_draw_milliwatts) |power| {
        if (power == 0 or power > std.math.maxInt(i64)) return false;
    }
    if (device.driver_version) |version| {
        if (version.len == 0 or version.len > 128) return false;
    }
    for (device.runtimes, 0..) |runtime, runtime_index| {
        if (!validOpaqueName(runtime.name, 64) or runtime.version.len == 0 or runtime.version.len > 128)
            return false;
        for (device.runtimes[0..runtime_index]) |previous| {
            if (std.mem.eql(u8, previous.name, runtime.name)) return false;
        }
    }
    for (device.capabilities, 0..) |capability, capability_index| {
        if (!validOpaqueName(capability, 256)) return false;
        for (device.capabilities[0..capability_index]) |previous| {
            if (std.mem.eql(u8, previous, capability)) return false;
        }
    }
    return true;
}

fn validOpaqueName(value: []const u8, maximum: usize) bool {
    if (value.len == 0 or value.len > maximum) return false;
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == ':' or byte == '-' or byte == '_' or
            byte == '.' or byte == '=')) return false;
    }
    return true;
}

fn emptyUnavailableInventory(allocator: std.mem.Allocator) !Inventory {
    var devices: std.ArrayList(Device) = .empty;
    var outcomes: std.ArrayList(ProbeOutcome) = .empty;
    const owned_devices = try devices.toOwnedSlice(allocator);
    errdefer allocator.free(owned_devices);
    const owned_outcomes = try outcomes.toOwnedSlice(allocator);
    errdefer allocator.free(owned_outcomes);
    var access_bindings: std.ArrayList(device_access.LocalBinding) = .empty;
    const owned_access_bindings = try access_bindings.toOwnedSlice(allocator);
    return .{
        .allocator = allocator,
        .status = .unavailable,
        .devices = owned_devices,
        .probe_outcomes = owned_outcomes,
        .access_catalog = .{
            .allocator = allocator,
            .bindings = owned_access_bindings,
        },
    };
}

fn appendOutcome(
    allocator: std.mem.Allocator,
    outcomes: *std.ArrayList(ProbeOutcome),
    name: []const u8,
    status: ProbeStatus,
    devices_found: usize,
    error_name: ?[]const u8,
) !void {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_error = if (error_name) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_error) |value| allocator.free(value);
    try outcomes.append(allocator, .{
        .name = owned_name,
        .status = status,
        .devices_found = devices_found,
        .error_name = owned_error,
    });
}

fn deinitDeviceList(allocator: std.mem.Allocator, devices: *std.ArrayList(Device)) void {
    for (devices.items) |*device| device.deinit(allocator);
    devices.deinit(allocator);
}

fn deinitOutcomeList(allocator: std.mem.Allocator, outcomes: *std.ArrayList(ProbeOutcome)) void {
    for (outcomes.items) |*outcome| outcome.deinit(allocator);
    outcomes.deinit(allocator);
}

fn cloneAccessBinding(
    allocator: std.mem.Allocator,
    binding: device_access.LocalBinding,
) !device_access.LocalBinding {
    const one = try device_access.OwnedCatalog.initClone(allocator, &.{binding});
    const owned = one.bindings[0];
    allocator.free(one.bindings);
    return owned;
}

fn deinitAccessBinding(
    allocator: std.mem.Allocator,
    binding: device_access.LocalBinding,
) void {
    allocator.free(binding.device_id);
    for (binding.cdi_devices) |name| allocator.free(name);
    allocator.free(binding.cdi_devices);
    if (binding.host_access) |host| {
        for (host.device_nodes) |node| allocator.free(node.path);
        allocator.free(host.device_nodes);
        for (host.environment) |variable| {
            allocator.free(variable.name);
            allocator.free(variable.value);
        }
        allocator.free(host.environment);
    }
}

fn deinitAccessBindingList(
    allocator: std.mem.Allocator,
    bindings: *std.ArrayList(device_access.LocalBinding),
) void {
    for (bindings.items) |binding| deinitAccessBinding(allocator, binding);
    bindings.deinit(allocator);
}

fn runNvidiaSmi(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    collector: *Collector,
) !ProbeDisposition {
    var sanitized_environment = std.process.Environ.Map.init(allocator);
    defer sanitized_environment.deinit();
    const argv = &.{
        "nvidia-smi",
        "--query-gpu=index,uuid,name,memory.total,driver_version,compute_cap,memory.free,temperature.gpu,power.draw",
        "--format=csv,noheader,nounits",
    };
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_command_output_bytes),
        .stderr_limit = .limited(max_command_output_bytes),
        .environ_map = &sanitized_environment,
        .timeout = .{ .duration = .{ .clock = .boot, .raw = .fromSeconds(3) } },
    }) catch |err| switch (err) {
        error.FileNotFound => {
            if (absolutePathEvidence(io, "/dev/nvidiactl"))
                return error.ProviderMissingWithDeviceEvidence;
            return .not_present;
        },
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!succeeded) return error.ProviderCommandFailed;
    const output = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (std.mem.eql(u8, output, "No devices were found")) return .supported;
    const cdi_output = try queryNvidiaCdiDevices(allocator, io);
    defer if (cdi_output) |value| allocator.free(value);
    try parseNvidiaSmiCsvWithCdi(allocator, output, cdi_output, collector);
    return .supported;
}

/// CDI discovery is intentionally optional for inventory. A missing or broken
/// local CDI provider leaves the device visible but not executable; it never
/// causes Nimbus to guess a broad runtime binding.
fn queryNvidiaCdiDevices(
    allocator: std.mem.Allocator,
    io: std.Io,
) !?[]u8 {
    var sanitized_environment = std.process.Environ.Map.init(allocator);
    defer sanitized_environment.deinit();
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "nvidia-ctk", "cdi", "list" },
        .stdout_limit = .limited(max_command_output_bytes),
        .stderr_limit = .limited(max_command_output_bytes),
        .environ_map = &sanitized_environment,
        .timeout = .{ .duration = .{ .clock = .boot, .raw = .fromSeconds(3) } },
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer allocator.free(result.stderr);
    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!succeeded) {
        allocator.free(result.stdout);
        return null;
    }
    return result.stdout;
}

/// Parse the legacy six-column fixture or the current bounded nine-column
/// nvidia-smi provider output.
pub fn parseNvidiaSmiCsv(
    allocator: std.mem.Allocator,
    output: []const u8,
    collector: *Collector,
) !void {
    return parseNvidiaSmiCsvWithCdi(allocator, output, null, collector);
}

fn parseNvidiaSmiCsvWithCdi(
    allocator: std.mem.Allocator,
    output: []const u8,
    cdi_output: ?[]const u8,
    collector: *Collector,
) !void {
    if (output.len > max_command_output_bytes) return error.ProviderOutputTooLarge;
    const baseline = collector.devices.items.len;
    const access_baseline = collector.access_bindings.items.len;
    errdefer {
        for (collector.devices.items[baseline..]) |*device| device.deinit(collector.allocator);
        collector.devices.items.len = baseline;
        for (collector.access_bindings.items[access_baseline..]) |binding|
            deinitAccessBinding(collector.allocator, binding);
        collector.access_bindings.items.len = access_baseline;
    }
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const fields = try parseCsvLine(allocator, line);
        defer {
            for (fields) |field| allocator.free(field);
            allocator.free(fields);
        }

        if (fields.len != 6 and fields.len != 9) return error.MalformedProviderOutput;

        if (fields[1].len == 0 or fields[2].len == 0 or
            optionalProviderValue(fields[1]) == null) return error.MalformedProviderOutput;
        _ = std.fmt.parseInt(usize, fields[0], 10) catch return error.MalformedProviderOutput;
        const memory_total = try parseOptionalMib(fields[3]);
        const memory_free = if (fields.len == 9) try parseOptionalMib(fields[6]) else null;
        const temperature = if (fields.len == 9)
            try parseOptionalMillicelsius(fields[7])
        else
            null;
        const power_draw = if (fields.len == 9)
            try parseOptionalMilliwatts(fields[8])
        else
            null;
        const driver = optionalProviderValue(fields[4]);
        const compute = optionalProviderValue(fields[5]);
        var capabilities_buffer: [1][]const u8 = undefined;
        var capability_count: usize = 0;
        var compute_capability: ?[]u8 = null;
        defer if (compute_capability) |value| allocator.free(value);
        if (compute) |version| {
            compute_capability = try std.fmt.allocPrint(allocator, "compute_capability={s}", .{version});
            capabilities_buffer[0] = compute_capability.?;
            capability_count = 1;
        }
        const opaque_id = try opaqueNvidiaId(allocator, fields[1]);
        defer allocator.free(opaque_id);
        const cdi_name = try std.fmt.allocPrint(
            allocator,
            "nvidia.com/gpu={s}",
            .{fields[1]},
        );
        defer allocator.free(cdi_name);
        var cdi_names: [1][]const u8 = undefined;
        const has_exact_cdi = device_access.isValidCdiDevice(cdi_name) and
            if (cdi_output) |catalog| containsExactLine(catalog, cdi_name) else false;
        if (has_exact_cdi) cdi_names[0] = cdi_name;
        try collector.add(.{
            .id = opaque_id,
            .kind = .gpu,
            .vendor = "NVIDIA",
            .model = fields[2],
            .source = "nvidia-smi",
            .memory_total_bytes = memory_total,
            .memory_free_bytes = memory_free,
            .temperature_millicelsius = temperature,
            .power_draw_milliwatts = power_draw,
            .driver_version = driver,
            .capabilities = capabilities_buffer[0..capability_count],
            .local_binding = if (has_exact_cdi) .{
                .device_id = opaque_id,
                .cdi_devices = cdi_names[0..1],
            } else null,
        });
    }
}

fn containsExactLine(output: []const u8, expected: []const u8) bool {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), expected))
            return true;
    }
    return false;
}

fn parseCsvLine(allocator: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |field| allocator.free(field);
        result.deinit(allocator);
    }
    var index: usize = 0;

    while (true) {
        if (result.items.len >= 9) return error.MalformedProviderOutput;
        while (index < line.len and (line[index] == ' ' or line[index] == '\t')) index += 1;
        if (index < line.len and line[index] == '"') {
            index += 1;
            var field: std.ArrayList(u8) = .empty;
            defer field.deinit(allocator);
            var closed = false;
            while (index < line.len) {
                if (line[index] == '"') {
                    if (index + 1 < line.len and line[index + 1] == '"') {
                        try field.append(allocator, '"');
                        index += 2;
                        continue;
                    }
                    index += 1;
                    closed = true;
                    break;
                }
                try field.append(allocator, line[index]);
                index += 1;
            }
            if (!closed) return error.MalformedProviderOutput;
            while (index < line.len and (line[index] == ' ' or line[index] == '\t')) index += 1;
            try result.append(allocator, try field.toOwnedSlice(allocator));
        } else {
            const start = index;
            while (index < line.len and line[index] != ',') : (index += 1) {
                if (line[index] == '"') return error.MalformedProviderOutput;
            }
            const value = std.mem.trim(u8, line[start..index], " \t");
            try result.append(allocator, try allocator.dupe(u8, value));
        }
        if (index == line.len) break;
        if (line[index] != ',') return error.MalformedProviderOutput;
        index += 1;
    }
    return result.toOwnedSlice(allocator);
}

fn optionalProviderValue(value: []const u8) ?[]const u8 {
    if (value.len == 0 or std.ascii.eqlIgnoreCase(value, "N/A") or
        std.ascii.eqlIgnoreCase(value, "[Not Supported]")) return null;
    return value;
}

fn parseOptionalMib(value: []const u8) !?u64 {
    if (optionalProviderValue(value) == null) return null;
    const mib = std.fmt.parseInt(u64, value, 10) catch return error.MalformedProviderOutput;
    return std.math.mul(u64, mib, 1024 * 1024) catch return error.MalformedProviderOutput;
}

fn parseOptionalMillicelsius(value: []const u8) !?i32 {
    if (optionalProviderValue(value) == null) return null;
    const celsius = std.fmt.parseInt(i32, value, 10) catch
        return error.MalformedProviderOutput;
    return std.math.mul(i32, celsius, 1000) catch error.MalformedProviderOutput;
}

fn parseOptionalMilliwatts(value: []const u8) !?u64 {
    if (optionalProviderValue(value) == null) return null;
    const watts = std.fmt.parseFloat(f64, value) catch return error.MalformedProviderOutput;
    if (!std.math.isFinite(watts) or watts <= 0 or watts > 1_000_000)
        return error.MalformedProviderOutput;
    return @intFromFloat(watts * 1000.0);
}

fn opaqueNvidiaId(allocator: std.mem.Allocator, uuid: []const u8) ![]u8 {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var hash = Sha256.init(.{});
    hash.update("nimbus.accelerator.nvidia.uuid.v1\x00");
    hash.update(uuid);
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "gpu:nvidia:{s}", .{encoded});
}

fn runJetsonSystemFiles(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    collector: *Collector,
) !ProbeDisposition {
    if (builtin.os.tag != .linux) return .not_present;
    const model_bytes = readAbsoluteBounded(
        allocator,
        io,
        "/sys/firmware/devicetree/base/model",
        4096,
    ) catch |err| switch (err) {
        error.FileNotFound => return .not_present,
        else => return err,
    };
    defer allocator.free(model_bytes);
    const model = trimSystemValue(model_bytes);
    if (!containsIgnoreCase(model, "nvidia jetson")) return .not_present;

    const release_bytes: ?[]u8 = readAbsoluteBounded(
        allocator,
        io,
        "/etc/nv_tegra_release",
        4096,
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (release_bytes) |bytes| allocator.free(bytes);
    const driver_version = if (release_bytes) |bytes| firstLine(trimSystemValue(bytes)) else null;
    var dla_indices: [4]usize = undefined;
    var dla_count: usize = 0;
    for (0..dla_indices.len) |index| {
        var path_buffer: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "/dev/nvhost-nvdla{d}", .{index});
        if (!absolutePathEvidence(io, path)) continue;
        dla_indices[dla_count] = index;
        dla_count += 1;
    }
    try addJetsonInventory(
        allocator,
        collector,
        model,
        driver_version,
        dla_indices[0..dla_count],
    );
    return .supported;
}

fn addJetsonInventory(
    allocator: std.mem.Allocator,
    collector: *Collector,
    model: []const u8,
    driver_version: ?[]const u8,
    dla_indices: []const usize,
) !void {
    const gpu_capabilities = [_][]const u8{ "integrated", "jetson" };
    try collector.add(.{
        // This identifies the integrated GPU slot, not a device serial.
        .id = "gpu:integrated:0",
        .kind = .gpu,
        .vendor = "NVIDIA",
        .model = model,
        .source = "jetson-system-files",
        .driver_version = driver_version,
        .capabilities = &gpu_capabilities,
    });
    for (dla_indices) |index| {
        var id_buffer: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "dla:{d}", .{index});
        const dla_model = try std.fmt.allocPrint(allocator, "{s} DLA", .{model});
        defer allocator.free(dla_model);
        const dla_capabilities = [_][]const u8{ "dla", "jetson" };
        try collector.add(.{
            .id = id,
            .kind = .dla,
            .vendor = "NVIDIA",
            .model = dla_model,
            .source = "jetson-system-files",
            .driver_version = driver_version,
            .capabilities = &dla_capabilities,
        });
    }
}

fn absolutePathEvidence(io: std.Io, path: []const u8) bool {
    if (builtin.os.tag != .linux) return false;
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| {
        return err != error.FileNotFound;
    };
    file.close(io);
    return true;
}

fn readAbsoluteBounded(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    maximum: usize,
) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(maximum));
}

fn trimSystemValue(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n\x00");
}

fn firstLine(value: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, value, "\r\n") orelse value.len;
    return value[0..end];
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
    }
    return false;
}

const FakeProbeContext = struct {
    input: ?DeviceInput = null,
    disposition: ProbeDisposition = .supported,
    failure: bool = false,
    timeout: bool = false,
};

fn runFakeProbe(
    opaque_context: ?*anyopaque,
    _: std.mem.Allocator,
    _: std.Io,
    collector: *Collector,
) !ProbeDisposition {
    const context: *FakeProbeContext = @ptrCast(@alignCast(opaque_context.?));
    if (context.input) |input| try collector.add(input);
    if (context.timeout) return error.Timeout;
    if (context.failure) return error.FakeProbeFailed;
    return context.disposition;
}

test "registry isolates failed probes and reports a partial inventory" {
    var first_context: FakeProbeContext = .{ .input = .{
        .id = "gpu-0",
        .kind = .gpu,
        .vendor = "Acme",
        .model = "Deterministic 1",
        .source = "fake",
    } };
    var failed_context: FakeProbeContext = .{
        .input = .{
            .id = "discarded",
            .kind = .npu,
            .vendor = "Acme",
            .model = "Partial output",
            .source = "fake",
        },
        .failure = true,
    };
    const probes = [_]Probe{
        .{ .name = "good", .context = &first_context, .run_fn = runFakeProbe },
        .{ .name = "bad", .context = &failed_context, .run_fn = runFakeProbe },
    };
    var inventory = try (Registry{ .probes = &probes }).collect(std.testing.allocator, std.testing.io);
    defer inventory.deinit();

    try std.testing.expectEqual(InventoryStatus.partial, inventory.status);
    try std.testing.expectEqual(@as(usize, 1), inventory.devices.len);
    try std.testing.expectEqualStrings("gpu-0", inventory.devices[0].id);
    try std.testing.expectEqual(ProbeStatus.failed, inventory.probe_outcomes[1].status);
    try std.testing.expectEqualStrings("FakeProbeFailed", inventory.probe_outcomes[1].error_name.?);
}

test "absent optional probes produce a trustworthy CPU-only inventory" {
    var context: FakeProbeContext = .{ .disposition = .not_present };
    const probes = [_]Probe{
        .{ .name = "optional-provider", .context = &context, .run_fn = runFakeProbe },
    };
    var inventory = try (Registry{ .probes = &probes }).collect(std.testing.allocator, std.testing.io);
    defer inventory.deinit();

    try std.testing.expectEqual(InventoryStatus.complete, inventory.status);
    try std.testing.expect(inventory.isCpuOnly());
    try std.testing.expectEqual(ProbeStatus.not_present, inventory.probe_outcomes[0].status);
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, inventory.report(), .{});
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"allocator\"") == null);
}

test "failed probes without devices produce an unavailable inventory" {
    var context: FakeProbeContext = .{ .failure = true };
    const probes = [_]Probe{
        .{ .name = "broken", .context = &context, .run_fn = runFakeProbe },
    };
    var inventory = try (Registry{ .probes = &probes }).collect(std.testing.allocator, std.testing.io);
    defer inventory.deinit();

    try std.testing.expectEqual(InventoryStatus.unavailable, inventory.status);
    try std.testing.expect(!inventory.isCpuOnly());
}

test "probe timeout becomes an unavailable outcome without aborting collection" {
    var context: FakeProbeContext = .{ .timeout = true };
    const probes = [_]Probe{
        .{ .name = "bounded-provider", .context = &context, .run_fn = runFakeProbe },
    };
    var inventory = try (Registry{ .probes = &probes }).collect(std.testing.allocator, std.testing.io);
    defer inventory.deinit();

    try std.testing.expectEqual(InventoryStatus.unavailable, inventory.status);
    try std.testing.expectEqual(ProbeStatus.failed, inventory.probe_outcomes[0].status);
    try std.testing.expectEqualStrings("Timeout", inventory.probe_outcomes[0].error_name.?);
}

test "registry enforces its global device bound" {
    var first_context: FakeProbeContext = .{ .input = .{
        .id = "gpu-0",
        .kind = .gpu,
        .vendor = "Acme",
        .model = "First",
        .source = "fake",
    } };
    var second_context: FakeProbeContext = .{ .input = .{
        .id = "gpu-1",
        .kind = .gpu,
        .vendor = "Acme",
        .model = "Second",
        .source = "fake",
    } };
    const probes = [_]Probe{
        .{ .name = "first", .context = &first_context, .run_fn = runFakeProbe },
        .{ .name = "second", .context = &second_context, .run_fn = runFakeProbe },
    };
    var inventory = try (Registry{ .probes = &probes, .device_limit = 1 }).collect(
        std.testing.allocator,
        std.testing.io,
    );
    defer inventory.deinit();

    try std.testing.expectEqual(InventoryStatus.partial, inventory.status);
    try std.testing.expectEqual(@as(usize, 1), inventory.devices.len);
    try std.testing.expectEqual(ProbeStatus.truncated, inventory.probe_outcomes[1].status);
}

test "successful empty probe confirms device disappearance" {
    var context: FakeProbeContext = .{ .input = .{
        .id = "gpu-0",
        .kind = .gpu,
        .vendor = "Acme",
        .model = "Temporary",
        .source = "fixture",
    } };
    const probes = [_]Probe{.{ .name = "fixture", .context = &context, .run_fn = runFakeProbe }};
    var present = try (Registry{ .probes = &probes }).collect(std.testing.allocator, std.testing.io);
    defer present.deinit();
    try std.testing.expectEqual(@as(usize, 1), present.devices.len);

    context.input = null;
    var disappeared = try (Registry{ .probes = &probes }).collect(std.testing.allocator, std.testing.io);
    defer disappeared.deinit();
    try std.testing.expectEqual(InventoryStatus.complete, disappeared.status);
    try std.testing.expectEqual(@as(usize, 0), disappeared.devices.len);
    try std.testing.expectEqual(ProbeStatus.ok, disappeared.probe_outcomes[0].status);
}

test "Jetson inventory uses stable GPU and DLA slot identities" {
    var collector = Collector.init(std.testing.allocator, 4);
    defer collector.deinit();
    try addJetsonInventory(
        std.testing.allocator,
        &collector,
        "NVIDIA Jetson AGX Orin",
        "R36.4",
        &.{ 0, 1 },
    );
    try std.testing.expectEqual(@as(usize, 3), collector.devices.items.len);
    try std.testing.expectEqualStrings("gpu:integrated:0", collector.devices.items[0].id);
    try std.testing.expectEqualStrings("dla:0", collector.devices.items[1].id);
    try std.testing.expectEqual(Kind.dla, collector.devices.items[1].kind);
    try std.testing.expectEqualStrings("dla:1", collector.devices.items[2].id);
}

test "nvidia CSV parser handles quoted fields and optional values" {
    var collector = Collector.init(std.testing.allocator, 4);
    defer collector.deinit();
    const output =
        "0, GPU-aaaa, \"NVIDIA A100, PCIe\", 40960, 550.54.15, 8.0, 32768, 62, 71.5\n" ++
        "1, GPU-bbbb, Jetson GPU, N/A, [Not Supported], N/A\n";
    try parseNvidiaSmiCsv(std.testing.allocator, output, &collector);

    try std.testing.expectEqual(@as(usize, 2), collector.devices.items.len);
    try std.testing.expect(std.mem.startsWith(u8, collector.devices.items[0].id, "gpu:nvidia:"));
    try std.testing.expect(std.mem.indexOf(u8, collector.devices.items[0].id, "GPU-aaaa") == null);
    try std.testing.expectEqualStrings("NVIDIA A100, PCIe", collector.devices.items[0].model);
    try std.testing.expectEqual(@as(?u64, 40 * 1024 * 1024 * 1024), collector.devices.items[0].memory_total_bytes);
    try std.testing.expectEqualStrings("550.54.15", collector.devices.items[0].driver_version.?);
    try std.testing.expectEqualStrings("compute_capability=8.0", collector.devices.items[0].capabilities[0]);
    try std.testing.expectEqual(@as(?u64, 32 * 1024 * 1024 * 1024), collector.devices.items[0].memory_free_bytes);
    try std.testing.expectEqual(@as(?i32, 62_000), collector.devices.items[0].temperature_millicelsius);
    try std.testing.expectEqual(@as(?u64, 71_500), collector.devices.items[0].power_draw_milliwatts);
    try std.testing.expectEqual(@as(?u64, null), collector.devices.items[1].memory_total_bytes);
}

test "nvidia parser keeps exact CDI binding private" {
    var collector = Collector.init(std.testing.allocator, 4);
    defer collector.deinit();
    const output = "0, GPU-private-uuid, NVIDIA RTX, 16384, 580.65, 12.0\n";
    const cdi_output =
        "nvidia.com/gpu=0\n" ++
        "nvidia.com/gpu=GPU-private-uuid\n" ++
        "nvidia.com/gpu=all\n";
    try parseNvidiaSmiCsvWithCdi(
        std.testing.allocator,
        output,
        cdi_output,
        &collector,
    );

    try std.testing.expectEqual(@as(usize, 1), collector.devices.items.len);
    try std.testing.expectEqual(@as(usize, 1), collector.access_bindings.items.len);
    try std.testing.expectEqualStrings(
        collector.devices.items[0].id,
        collector.access_bindings.items[0].device_id,
    );
    try std.testing.expectEqualStrings(
        "nvidia.com/gpu=GPU-private-uuid",
        collector.access_bindings.items[0].cdi_devices[0],
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        collector.devices.items[0].id,
        "GPU-private-uuid",
    ) == null);
}

test "inventory report never serializes node-private access binding" {
    var context: FakeProbeContext = .{ .input = .{
        .id = "gpu:nvidia:opaque",
        .kind = .gpu,
        .vendor = "NVIDIA",
        .model = "Fixture",
        .source = "fixture",
        .local_binding = .{
            .device_id = "gpu:nvidia:opaque",
            .cdi_devices = &.{"nvidia.com/gpu=GPU-private-uuid"},
        },
    } };
    const probes = [_]Probe{.{
        .name = "fixture",
        .context = &context,
        .run_fn = runFakeProbe,
    }};
    var inventory = try (Registry{ .probes = &probes }).collect(
        std.testing.allocator,
        std.testing.io,
    );
    defer inventory.deinit();

    try std.testing.expectEqual(@as(usize, 1), inventory.accessCatalog().bindings.len);
    const json = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        inventory.report(),
        .{},
    );
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "GPU-private-uuid") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "access_catalog") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "local_binding") == null);
}

test "nvidia CSV parser rejects malformed output without keeping partial device" {
    const malformed = [_][]const u8{
        "0, GPU-a, only-five, 1024, 550.1",
        "0, GPU-a, \"unterminated, 1024, 550.1, 8.0",
        "0, GPU-a, model, not-a-number, 550.1, 8.0",
        "0, GPU-a, model, 1024, 550.1, 8.0, extra",
        "0, GPU-a, model, 1024, 550.1, 8.0\nnot-index, GPU-b, model, 1024, 550.1, 8.0",
    };
    for (malformed) |output| {
        var collector = Collector.init(std.testing.allocator, 4);
        defer collector.deinit();
        try std.testing.expectError(
            error.MalformedProviderOutput,
            parseNvidiaSmiCsv(std.testing.allocator, output, &collector),
        );
        try std.testing.expectEqual(@as(usize, 0), collector.devices.items.len);
    }
}

test "nvidia parser rolls back private bindings after a later malformed row" {
    var collector = Collector.init(std.testing.allocator, 4);
    defer collector.deinit();
    const output =
        "0, GPU-valid, NVIDIA RTX, 16384, 580.65, 12.0\n" ++
        "not-index, GPU-invalid, NVIDIA RTX, 16384, 580.65, 12.0\n";
    try std.testing.expectError(
        error.MalformedProviderOutput,
        parseNvidiaSmiCsvWithCdi(
            std.testing.allocator,
            output,
            "nvidia.com/gpu=GPU-valid\n",
            &collector,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), collector.devices.items.len);
    try std.testing.expectEqual(@as(usize, 0), collector.access_bindings.items.len);
}

test "wire validation rejects duplicate accelerator identities" {
    const devices = [_]Device{
        .{
            .id = "gpu:nvidia:duplicate",
            .kind = .gpu,
            .vendor = "NVIDIA",
            .model = "A100",
            .source = "fixture",
        },
        .{
            .id = "gpu:nvidia:duplicate",
            .kind = .gpu,
            .vendor = "NVIDIA",
            .model = "A100",
            .source = "fixture",
        },
    };
    const probes = [_]ProbeOutcome{.{
        .name = "fixture",
        .status = .ok,
        .devices_found = 2,
    }};
    try std.testing.expect(!validateReport(.{
        .status = .complete,
        .accelerators = &devices,
        .probes = &probes,
    }));
}

test "wire validation accepts a bounded NVIDIA inventory" {
    const devices = [_]Device{.{
        .id = "gpu:nvidia:7f3c",
        .kind = .gpu,
        .vendor = "NVIDIA",
        .model = "A100",
        .source = "nvidia-smi",
        .memory_total_bytes = 40 * 1024 * 1024 * 1024,
        .driver_version = "550.54.15",
        .capabilities = &.{"compute_capability=8.0"},
    }};
    const probes = [_]ProbeOutcome{.{
        .name = "nvidia-smi",
        .status = .ok,
        .devices_found = 1,
    }};
    try std.testing.expect(validateReport(.{
        .status = .complete,
        .accelerators = &devices,
        .probes = &probes,
    }));
}

test "placement-aware selection filters dynamic device pressure" {
    const devices = [_]Device{
        .{
            .id = "gpu:nvidia:a-hot",
            .kind = .gpu,
            .vendor = "NVIDIA",
            .model = "L4",
            .source = "fixture",
            .memory_total_bytes = 24 * 1024 * 1024 * 1024,
            .memory_free_bytes = 2 * 1024 * 1024 * 1024,
            .temperature_millicelsius = 90_000,
        },
        .{
            .id = "gpu:nvidia:b-cool",
            .kind = .gpu,
            .vendor = "NVIDIA",
            .model = "L4",
            .source = "fixture",
            .memory_total_bytes = 24 * 1024 * 1024 * 1024,
            .memory_free_bytes = 16 * 1024 * 1024 * 1024,
            .temperature_millicelsius = 60_000,
        },
    };
    const probes = [_]ProbeOutcome{.{
        .name = "fixture",
        .status = .ok,
        .devices_found = 2,
    }};
    const selected = try selectForPlacementAlloc(
        std.testing.allocator,
        .{ .status = .complete, .accelerators = &devices, .probes = &probes },
        .{ .kind = .gpu, .vendor = "nvidia" },
        &.{},
        .{
            .min_accelerator_free_memory_bytes = 8 * 1024 * 1024 * 1024,
            .max_accelerator_temperature_millicelsius = 80_000,
        },
    );
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqual(@as(usize, 1), selected.len);
    try std.testing.expectEqualStrings("gpu:nvidia:b-cool", selected[0]);
}

test "device selection is deterministic and all or none" {
    const devices = [_]Device{
        .{
            .id = "gpu:nvidia:z",
            .kind = .gpu,
            .vendor = "NVIDIA",
            .model = "L4",
            .source = "fixture",
            .memory_total_bytes = 24 * 1024 * 1024 * 1024,
            .capabilities = &.{ "fp16", "int8" },
        },
        .{
            .id = "npu:acme:0",
            .kind = .npu,
            .vendor = "Acme",
            .model = "NPU",
            .source = "fixture",
            .memory_total_bytes = 8 * 1024 * 1024 * 1024,
            .capabilities = &.{"int8"},
        },
        .{
            .id = "gpu:nvidia:a",
            .kind = .gpu,
            .vendor = "Nvidia",
            .model = "A10",
            .source = "fixture",
            .memory_total_bytes = 16 * 1024 * 1024 * 1024,
            .capabilities = &.{ "int8", "fp16" },
        },
    };
    const requirement: Requirement = .{
        .count = 2,
        .kind = .gpu,
        .vendor = "nvidia",
        .memory_min_bytes = 8 * 1024 * 1024 * 1024,
        .capabilities = &.{ "fp16", "int8" },
    };
    const selected = try selectAlloc(
        std.testing.allocator,
        .{ .status = .complete, .accelerators = &devices, .probes = &.{} },
        requirement,
        &.{},
    );
    defer std.testing.allocator.free(selected);

    try std.testing.expectEqual(@as(usize, 2), selected.len);
    try std.testing.expectEqualStrings("gpu:nvidia:a", selected[0]);
    try std.testing.expectEqualStrings("gpu:nvidia:z", selected[1]);
    try std.testing.expect(matchesRequirement(devices[0], requirement));
    try std.testing.expect(!matchesRequirement(devices[1], requirement));
}

test "device selection reports each requirement mismatch" {
    const devices = [_]Device{
        .{
            .id = "gpu:nvidia:0",
            .kind = .gpu,
            .vendor = "NVIDIA",
            .model = "L4",
            .source = "fixture",
            .memory_total_bytes = 24 * 1024 * 1024 * 1024,
            .capabilities = &.{ "fp16", "int8" },
        },
        .{
            .id = "gpu:amd:0",
            .kind = .gpu,
            .vendor = "AMD",
            .model = "Fixture",
            .source = "fixture",
        },
    };
    const inventory: InventoryReport = .{
        .status = .complete,
        .accelerators = &devices,
        .probes = &.{},
    };

    try std.testing.expectError(error.KindMismatch, selectAlloc(
        std.testing.allocator,
        inventory,
        .{ .kind = .npu },
        &.{},
    ));
    try std.testing.expectError(error.VendorMismatch, selectAlloc(
        std.testing.allocator,
        inventory,
        .{ .kind = .gpu, .vendor = "Intel" },
        &.{},
    ));
    try std.testing.expectError(error.MemoryMismatch, selectAlloc(
        std.testing.allocator,
        inventory,
        .{ .kind = .gpu, .memory_min_bytes = 32 * 1024 * 1024 * 1024 },
        &.{},
    ));
    try std.testing.expectError(error.CapabilityMismatch, selectAlloc(
        std.testing.allocator,
        inventory,
        .{ .kind = .gpu, .capabilities = &.{"bf16"} },
        &.{},
    ));
    try std.testing.expectError(error.InsufficientDevices, selectAlloc(
        std.testing.allocator,
        inventory,
        .{ .count = 3, .kind = .gpu },
        &.{},
    ));

    var unavailable_devices = devices;
    unavailable_devices[0].availability = .degraded;
    try std.testing.expectError(error.DeviceUnavailable, selectAlloc(
        std.testing.allocator,
        .{ .status = .complete, .accelerators = &unavailable_devices, .probes = &.{} },
        .{ .kind = .gpu, .vendor = "nvidia" },
        &.{},
    ));
}

test "device selection fails closed for reservations and incomplete inventory" {
    const devices = [_]Device{.{
        .id = "gpu:nvidia:0",
        .kind = .gpu,
        .vendor = "NVIDIA",
        .model = "L4",
        .source = "fixture",
    }};
    const complete: InventoryReport = .{
        .status = .complete,
        .accelerators = &devices,
        .probes = &.{},
    };
    const requirement: Requirement = .{ .kind = .gpu };

    try std.testing.expectError(error.DeviceReserved, selectAlloc(
        std.testing.allocator,
        complete,
        requirement,
        &.{"gpu:nvidia:0"},
    ));
    var partial = complete;
    partial.status = .partial;
    try std.testing.expectError(error.InventoryPartial, selectAlloc(
        std.testing.allocator,
        partial,
        requirement,
        &.{},
    ));
    var unavailable = complete;
    unavailable.status = .unavailable;
    try std.testing.expectError(error.InventoryUnavailable, selectAlloc(
        std.testing.allocator,
        unavailable,
        requirement,
        &.{},
    ));
}
