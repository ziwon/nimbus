const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const max_devices = 32;
pub const max_bindings = max_devices;
pub const max_device_id_bytes = 256;
pub const max_cdi_devices_per_binding = 16;
pub const max_cdi_name_bytes = 256;
pub const max_device_nodes_per_binding = 32;
pub const max_device_path_bytes = 512;
pub const max_environment_per_binding = 16;
pub const max_environment_value_bytes = 1024;

const max_plan_cdi_devices = max_devices * max_cdi_devices_per_binding;
const max_plan_device_nodes = max_devices * max_device_nodes_per_binding;
const max_plan_environment = max_devices * max_environment_per_binding;

pub const Permissions = enum {
    read,
    read_write,
};

pub const DeviceNode = struct {
    path: []const u8,
    permissions: Permissions,
};

pub const EnvironmentVariable = struct {
    name: []const u8,
    value: []const u8,
};

pub const HostAccessCompleteness = enum {
    /// The vendor integration has provided a complete access description.
    vendor_verified,
    /// Useful for diagnostics, but never sufficient to launch a workload.
    advisory,
};

pub const HostAccess = struct {
    completeness: HostAccessCompleteness,
    device_nodes: []const DeviceNode = &.{},
    environment: []const EnvironmentVariable = &.{},
};

/// A local, node-specific binding for one public accelerator device ID.
/// Catalog values are borrowed unless held by OwnedCatalog.
pub const LocalBinding = struct {
    device_id: []const u8,
    cdi_devices: []const []const u8 = &.{},
    host_access: ?HostAccess = null,
};

pub const Catalog = struct {
    bindings: []const LocalBinding = &.{},
};

pub const Policy = enum {
    cdi_only,
    cdi_or_host,
};

pub const Access = union(enum) {
    cdi: []const []const u8,
    host: HostAccess,
};

pub const Plan = struct {
    device_ids: []const []const u8,
    access: Access,
    fingerprint: [Sha256.digest_length]u8,
};

/// Canonical launch access plan. Every nested slice is allocator-owned.
pub const OwnedPlan = struct {
    allocator: std.mem.Allocator,
    device_ids: []const []const u8,
    access: Access,
    fingerprint: [Sha256.digest_length]u8,

    pub fn deinit(self: *OwnedPlan) void {
        freeStrings(self.allocator, self.device_ids);
        switch (self.access) {
            .cdi => |devices| freeStrings(self.allocator, devices),
            .host => |host_access| deinitHostAccess(self.allocator, host_access),
        }
        self.* = undefined;
    }

    pub fn view(self: *const OwnedPlan) Plan {
        return .{
            .device_ids = self.device_ids,
            .access = self.access,
            .fingerprint = self.fingerprint,
        };
    }
};

/// Deep-copied probe catalog suitable for storage beyond the probe call.
pub const OwnedCatalog = struct {
    allocator: std.mem.Allocator,
    bindings: []LocalBinding,

    pub fn initClone(
        allocator: std.mem.Allocator,
        bindings: []const LocalBinding,
    ) (std.mem.Allocator.Error || ValidationError)!OwnedCatalog {
        try validateCatalogShape(.{ .bindings = bindings });

        const owned_bindings = try allocator.alloc(LocalBinding, bindings.len);
        var initialized: usize = 0;
        errdefer {
            for (owned_bindings[0..initialized]) |binding|
                deinitBinding(allocator, binding);
            allocator.free(owned_bindings);
        }

        for (bindings) |binding| {
            owned_bindings[initialized] = try cloneBinding(allocator, binding);
            initialized += 1;
        }
        return .{ .allocator = allocator, .bindings = owned_bindings };
    }

    pub fn deinit(self: *OwnedCatalog) void {
        for (self.bindings) |binding| deinitBinding(self.allocator, binding);
        self.allocator.free(self.bindings);
        self.* = undefined;
    }

    pub fn view(self: *const OwnedCatalog) Catalog {
        return .{ .bindings = self.bindings };
    }
};

pub const ValidationError = error{
    TooManyInventoryDevices,
    InvalidInventoryDeviceId,
    DuplicateInventoryDevice,
    TooManyBindings,
    InvalidDeviceId,
    DuplicateBinding,
    UnknownBinding,
    TooManyCdiDevices,
    InvalidCdiDevice,
    DuplicateCdiDevice,
    TooManyDeviceNodes,
    MissingVerifiedDeviceNodes,
    InvalidDevicePath,
    TooManyEnvironmentVariables,
    InvalidEnvironmentName,
    InvalidEnvironmentValue,
};

pub const ResolveError = std.mem.Allocator.Error || ValidationError || error{
    NoAssignedDevices,
    TooManyAssignedDevices,
    InvalidAssignedDeviceId,
    DuplicateAssignedDevice,
    AssignmentUnknownDevice,
    MissingBinding,
    HostAccessForbidden,
    MissingHostAccess,
    UnverifiedHostAccess,
    EnvironmentConflict,
};

/// Verify that a catalog is safe and only describes devices in the inventory.
/// Inventory IDs are separate from accelerator.zig to keep the ownership layer
/// free of a circular dependency.
pub fn validateCatalog(
    inventory_device_ids: []const []const u8,
    catalog: Catalog,
) ValidationError!void {
    if (inventory_device_ids.len > max_devices) return error.TooManyInventoryDevices;
    for (inventory_device_ids, 0..) |device_id, index| {
        if (!isValidDeviceId(device_id)) return error.InvalidInventoryDeviceId;
        if (containsString(inventory_device_ids[0..index], device_id))
            return error.DuplicateInventoryDevice;
    }

    try validateCatalogShape(catalog);
    for (catalog.bindings) |binding| {
        if (!containsString(inventory_device_ids, binding.device_id))
            return error.UnknownBinding;
    }
}

/// Resolve assigned public IDs to one homogeneous runtime access mechanism.
/// CDI is always preferred when every selected binding supports it. Host access
/// is used only when explicitly allowed and every selected binding is complete.
pub fn resolveAlloc(
    allocator: std.mem.Allocator,
    inventory_device_ids: []const []const u8,
    catalog: Catalog,
    assignment_device_ids: []const []const u8,
    policy: Policy,
) ResolveError!OwnedPlan {
    try validateCatalog(inventory_device_ids, catalog);
    if (assignment_device_ids.len == 0) return error.NoAssignedDevices;
    if (assignment_device_ids.len > max_devices) return error.TooManyAssignedDevices;

    var selected: [max_devices]LocalBinding = undefined;
    for (assignment_device_ids, 0..) |device_id, index| {
        if (!isValidDeviceId(device_id)) return error.InvalidAssignedDeviceId;
        if (containsString(assignment_device_ids[0..index], device_id))
            return error.DuplicateAssignedDevice;
        if (!containsString(inventory_device_ids, device_id))
            return error.AssignmentUnknownDevice;
        selected[index] = findBinding(catalog.bindings, device_id) orelse
            return error.MissingBinding;
    }

    const owned_device_ids = try cloneSortedStrings(allocator, assignment_device_ids);
    errdefer freeStrings(allocator, owned_device_ids);

    var all_cdi = true;
    for (selected[0..assignment_device_ids.len]) |binding| {
        if (binding.cdi_devices.len == 0) {
            all_cdi = false;
            break;
        }
    }

    const access: Access = if (all_cdi) blk: {
        break :blk .{ .cdi = try buildCdiPlan(
            allocator,
            selected[0..assignment_device_ids.len],
        ) };
    } else blk: {
        if (policy == .cdi_only) return error.HostAccessForbidden;
        break :blk .{ .host = try buildHostPlan(
            allocator,
            selected[0..assignment_device_ids.len],
        ) };
    };
    errdefer switch (access) {
        .cdi => |devices| freeStrings(allocator, devices),
        .host => |host_access| deinitHostAccess(allocator, host_access),
    };

    return .{
        .allocator = allocator,
        .device_ids = owned_device_ids,
        .access = access,
        .fingerprint = fingerprintPlan(owned_device_ids, access),
    };
}

/// Resolve an assignment to an explicitly verified host allowlist even when
/// CDI is also available. Process and systemd adapters cannot consume CDI, so
/// silently preferring it would either broaden access or make their behavior
/// depend on probe order.
pub fn resolveHostAlloc(
    allocator: std.mem.Allocator,
    inventory_device_ids: []const []const u8,
    catalog: Catalog,
    assignment_device_ids: []const []const u8,
) ResolveError!OwnedPlan {
    try validateCatalog(inventory_device_ids, catalog);
    if (assignment_device_ids.len == 0) return error.NoAssignedDevices;
    if (assignment_device_ids.len > max_devices) return error.TooManyAssignedDevices;

    var selected: [max_devices]LocalBinding = undefined;
    for (assignment_device_ids, 0..) |device_id, index| {
        if (!isValidDeviceId(device_id)) return error.InvalidAssignedDeviceId;
        if (containsString(assignment_device_ids[0..index], device_id))
            return error.DuplicateAssignedDevice;
        if (!containsString(inventory_device_ids, device_id))
            return error.AssignmentUnknownDevice;
        selected[index] = findBinding(catalog.bindings, device_id) orelse
            return error.MissingBinding;
    }

    const owned_device_ids = try cloneSortedStrings(allocator, assignment_device_ids);
    errdefer freeStrings(allocator, owned_device_ids);
    const host_access = try buildHostPlan(
        allocator,
        selected[0..assignment_device_ids.len],
    );
    errdefer deinitHostAccess(allocator, host_access);
    const access: Access = .{ .host = host_access };
    return .{
        .allocator = allocator,
        .device_ids = owned_device_ids,
        .access = access,
        .fingerprint = fingerprintPlan(owned_device_ids, access),
    };
}

pub fn isValidDeviceId(value: []const u8) bool {
    if (value.len == 0 or value.len > max_device_id_bytes or value[0] == '-') return false;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '.', '_', ':', '-' => {},
            else => return false,
        }
    }
    return true;
}

pub fn isValidCdiDevice(value: []const u8) bool {
    if (value.len == 0 or value.len > max_cdi_name_bytes) return false;
    for (value) |byte| {
        if (byte <= 0x20 or byte >= 0x7f) return false;
    }

    const equals = std.mem.indexOfScalar(u8, value, '=') orelse return false;
    if (equals == 0 or equals + 1 == value.len) return false;
    if (std.mem.indexOfScalarPos(u8, value, equals + 1, '=') != null) return false;

    const kind = value[0..equals];
    const device = value[equals + 1 ..];
    const slash = std.mem.indexOfScalar(u8, kind, '/') orelse return false;
    if (slash == 0 or slash + 1 == kind.len) return false;
    if (std.mem.indexOfScalarPos(u8, kind, slash + 1, '/') != null) return false;

    const vendor = kind[0..slash];
    const class = kind[slash + 1 ..];
    if (!isValidVendorDomain(vendor) or !isValidCdiComponent(class)) return false;
    if (!isValidCdiComponent(device)) return false;
    if (std.ascii.eqlIgnoreCase(device, "all")) return false;
    return true;
}

pub fn isValidDevicePath(path: []const u8) bool {
    if (path.len <= "/dev/".len or path.len > max_device_path_bytes) return false;
    if (!std.mem.startsWith(u8, path, "/dev/")) return false;
    var components = std.mem.splitScalar(u8, path[1..], '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, "..")) return false;
        for (component) |byte| {
            if (byte <= 0x20 or byte >= 0x7f) return false;
            switch (byte) {
                '*', '?', '[', ']', '{', '}' => return false,
                else => {},
            }
        }
    }
    return true;
}

fn validateCatalogShape(catalog: Catalog) ValidationError!void {
    if (catalog.bindings.len > max_bindings) return error.TooManyBindings;

    var seen_cdi: [max_plan_cdi_devices][]const u8 = undefined;
    var seen_cdi_count: usize = 0;
    for (catalog.bindings, 0..) |binding, binding_index| {
        if (!isValidDeviceId(binding.device_id)) return error.InvalidDeviceId;
        for (catalog.bindings[0..binding_index]) |previous| {
            if (std.mem.eql(u8, previous.device_id, binding.device_id))
                return error.DuplicateBinding;
        }

        if (binding.cdi_devices.len > max_cdi_devices_per_binding)
            return error.TooManyCdiDevices;
        for (binding.cdi_devices) |cdi_device| {
            if (!isValidCdiDevice(cdi_device)) return error.InvalidCdiDevice;
            if (containsString(seen_cdi[0..seen_cdi_count], cdi_device))
                return error.DuplicateCdiDevice;
            seen_cdi[seen_cdi_count] = cdi_device;
            seen_cdi_count += 1;
        }

        if (binding.host_access) |host_access| {
            if (host_access.device_nodes.len > max_device_nodes_per_binding)
                return error.TooManyDeviceNodes;
            if (host_access.completeness == .vendor_verified and
                host_access.device_nodes.len == 0)
                return error.MissingVerifiedDeviceNodes;
            for (host_access.device_nodes) |node| {
                if (!isValidDevicePath(node.path)) return error.InvalidDevicePath;
            }

            if (host_access.environment.len > max_environment_per_binding)
                return error.TooManyEnvironmentVariables;
            for (host_access.environment) |variable| {
                if (!isAllowedEnvironmentName(variable.name))
                    return error.InvalidEnvironmentName;
                if (!isValidEnvironmentValue(variable.value))
                    return error.InvalidEnvironmentValue;
            }
        }
    }
}

fn isValidVendorDomain(value: []const u8) bool {
    if (value.len == 0 or value.len > 253 or std.mem.indexOfScalar(u8, value, '.') == null)
        return false;
    var labels = std.mem.splitScalar(u8, value, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or label[0] == '-' or
            label[label.len - 1] == '-') return false;
        for (label) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '-') return false;
        }
    }
    return true;
}

fn isValidCdiComponent(value: []const u8) bool {
    if (value.len == 0 or value[0] == '-') return false;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '.', '_', ':', '-' => {},
            else => return false,
        }
    }
    return true;
}

fn isAllowedEnvironmentName(name: []const u8) bool {
    const allowed = [_][]const u8{
        "CUDA_VISIBLE_DEVICES",
        "ROCR_VISIBLE_DEVICES",
        "HIP_VISIBLE_DEVICES",
        "ZE_AFFINITY_MASK",
        "NIMBUS_ACCELERATOR_IDS",
    };
    return containsString(&allowed, name);
}

fn isValidEnvironmentValue(value: []const u8) bool {
    if (value.len > max_environment_value_bytes) return false;
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

fn buildCdiPlan(
    allocator: std.mem.Allocator,
    bindings: []const LocalBinding,
) std.mem.Allocator.Error![]const []const u8 {
    var borrowed: [max_plan_cdi_devices][]const u8 = undefined;
    var count: usize = 0;
    for (bindings) |binding| {
        for (binding.cdi_devices) |device| {
            borrowed[count] = device;
            count += 1;
        }
    }
    std.mem.sort([]const u8, borrowed[0..count], {}, lessString);
    return cloneStrings(allocator, borrowed[0..count]);
}

fn buildHostPlan(
    allocator: std.mem.Allocator,
    bindings: []const LocalBinding,
) (std.mem.Allocator.Error || ResolveError)!HostAccess {
    var node_candidates: [max_plan_device_nodes]DeviceNode = undefined;
    var node_count: usize = 0;
    var environment_candidates: [max_plan_environment]EnvironmentVariable = undefined;
    var environment_count: usize = 0;

    for (bindings) |binding| {
        const host_access = binding.host_access orelse return error.MissingHostAccess;
        if (host_access.completeness != .vendor_verified)
            return error.UnverifiedHostAccess;
        for (host_access.device_nodes) |node| {
            node_candidates[node_count] = node;
            node_count += 1;
        }
        for (host_access.environment) |variable| {
            environment_candidates[environment_count] = variable;
            environment_count += 1;
        }
    }

    std.mem.sort(DeviceNode, node_candidates[0..node_count], {}, lessDeviceNode);
    var unique_node_count: usize = 0;
    var node_index: usize = 0;
    while (node_index < node_count) : (unique_node_count += 1) {
        const path = node_candidates[node_index].path;
        node_index += 1;
        while (node_index < node_count and
            std.mem.eql(u8, node_candidates[node_index].path, path))
        {
            node_index += 1;
        }
    }

    const owned_nodes = try allocator.alloc(DeviceNode, unique_node_count);
    var initialized_nodes: usize = 0;
    errdefer {
        for (owned_nodes[0..initialized_nodes]) |node| allocator.free(node.path);
        allocator.free(owned_nodes);
    }
    node_index = 0;
    while (node_index < node_count) {
        const path = node_candidates[node_index].path;
        var permissions = node_candidates[node_index].permissions;
        node_index += 1;
        while (node_index < node_count and
            std.mem.eql(u8, node_candidates[node_index].path, path))
        {
            if (node_candidates[node_index].permissions == .read_write)
                permissions = .read_write;
            node_index += 1;
        }
        owned_nodes[initialized_nodes] = .{
            .path = try allocator.dupe(u8, path),
            .permissions = permissions,
        };
        initialized_nodes += 1;
    }

    std.mem.sort(
        EnvironmentVariable,
        environment_candidates[0..environment_count],
        {},
        lessEnvironment,
    );
    var unique_environment_count: usize = 0;
    var environment_index: usize = 0;
    while (environment_index < environment_count) : (unique_environment_count += 1) {
        const variable = environment_candidates[environment_index];
        environment_index += 1;
        while (environment_index < environment_count and std.mem.eql(
            u8,
            environment_candidates[environment_index].name,
            variable.name,
        )) {
            if (!std.mem.eql(
                u8,
                environment_candidates[environment_index].value,
                variable.value,
            )) return error.EnvironmentConflict;
            environment_index += 1;
        }
    }

    const owned_environment = try allocator.alloc(
        EnvironmentVariable,
        unique_environment_count,
    );
    var initialized_environment: usize = 0;
    errdefer {
        for (owned_environment[0..initialized_environment]) |variable| {
            allocator.free(variable.name);
            allocator.free(variable.value);
        }
        allocator.free(owned_environment);
    }
    environment_index = 0;
    while (environment_index < environment_count) {
        const variable = environment_candidates[environment_index];
        environment_index += 1;
        while (environment_index < environment_count and std.mem.eql(
            u8,
            environment_candidates[environment_index].name,
            variable.name,
        )) : (environment_index += 1) {}

        const name = try allocator.dupe(u8, variable.name);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, variable.value);
        owned_environment[initialized_environment] = .{ .name = name, .value = value };
        initialized_environment += 1;
    }

    return .{
        .completeness = .vendor_verified,
        .device_nodes = owned_nodes,
        .environment = owned_environment,
    };
}

fn fingerprintPlan(
    device_ids: []const []const u8,
    access: Access,
) [Sha256.digest_length]u8 {
    var hash = Sha256.init(.{});
    hash.update("nimbus.device-access.plan.v1\x00");
    hashSequence(&hash, 0x10, device_ids);
    switch (access) {
        .cdi => |devices| {
            hash.update(&.{0x20});
            hashSequence(&hash, 0x21, devices);
        },
        .host => |host_access| {
            hash.update(&.{ 0x30, @intFromEnum(host_access.completeness) });
            hashLength(&hash, host_access.device_nodes.len);
            for (host_access.device_nodes) |node| {
                hashString(&hash, 0x31, node.path);
                hash.update(&.{ 0x32, @intFromEnum(node.permissions) });
            }
            hashLength(&hash, host_access.environment.len);
            for (host_access.environment) |variable| {
                hashString(&hash, 0x33, variable.name);
                hashString(&hash, 0x34, variable.value);
            }
        },
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn hashSequence(hash: *Sha256, tag: u8, values: []const []const u8) void {
    hash.update(&.{tag});
    hashLength(hash, values.len);
    for (values) |value| hashString(hash, tag +% 1, value);
}

fn hashString(hash: *Sha256, tag: u8, value: []const u8) void {
    hash.update(&.{tag});
    hashLength(hash, value.len);
    hash.update(value);
}

fn hashLength(hash: *Sha256, length: usize) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, @intCast(length), .big);
    hash.update(&encoded);
}

fn cloneBinding(allocator: std.mem.Allocator, binding: LocalBinding) !LocalBinding {
    const device_id = try allocator.dupe(u8, binding.device_id);
    errdefer allocator.free(device_id);
    const cdi_devices = try cloneStrings(allocator, binding.cdi_devices);
    errdefer freeStrings(allocator, cdi_devices);
    const host_access = if (binding.host_access) |access|
        try cloneHostAccess(allocator, access)
    else
        null;
    return .{
        .device_id = device_id,
        .cdi_devices = cdi_devices,
        .host_access = host_access,
    };
}

fn cloneHostAccess(allocator: std.mem.Allocator, access: HostAccess) !HostAccess {
    const nodes = try allocator.alloc(DeviceNode, access.device_nodes.len);
    var initialized_nodes: usize = 0;
    errdefer {
        for (nodes[0..initialized_nodes]) |node| allocator.free(node.path);
        allocator.free(nodes);
    }
    for (access.device_nodes) |node| {
        nodes[initialized_nodes] = .{
            .path = try allocator.dupe(u8, node.path),
            .permissions = node.permissions,
        };
        initialized_nodes += 1;
    }

    const environment = try allocator.alloc(EnvironmentVariable, access.environment.len);
    var initialized_environment: usize = 0;
    errdefer {
        for (environment[0..initialized_environment]) |variable| {
            allocator.free(variable.name);
            allocator.free(variable.value);
        }
        allocator.free(environment);
    }
    for (access.environment) |variable| {
        const name = try allocator.dupe(u8, variable.name);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, variable.value);
        environment[initialized_environment] = .{ .name = name, .value = value };
        initialized_environment += 1;
    }

    return .{
        .completeness = access.completeness,
        .device_nodes = nodes,
        .environment = environment,
    };
}

fn deinitBinding(allocator: std.mem.Allocator, binding: LocalBinding) void {
    allocator.free(binding.device_id);
    freeStrings(allocator, binding.cdi_devices);
    if (binding.host_access) |access| deinitHostAccess(allocator, access);
}

fn deinitHostAccess(allocator: std.mem.Allocator, access: HostAccess) void {
    for (access.device_nodes) |node| allocator.free(node.path);
    allocator.free(access.device_nodes);
    for (access.environment) |variable| {
        allocator.free(variable.name);
        allocator.free(variable.value);
    }
    allocator.free(access.environment);
}

fn cloneSortedStrings(
    allocator: std.mem.Allocator,
    values: []const []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    var borrowed: [max_devices][]const u8 = undefined;
    @memcpy(borrowed[0..values.len], values);
    std.mem.sort([]const u8, borrowed[0..values.len], {}, lessString);
    return cloneStrings(allocator, borrowed[0..values.len]);
}

fn cloneStrings(
    allocator: std.mem.Allocator,
    values: []const []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    const result = try allocator.alloc([]const u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |value| allocator.free(value);
        allocator.free(result);
    }
    for (values) |value| {
        result[initialized] = try allocator.dupe(u8, value);
        initialized += 1;
    }
    return result;
}

fn freeStrings(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn findBinding(bindings: []const LocalBinding, device_id: []const u8) ?LocalBinding {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.device_id, device_id)) return binding;
    }
    return null;
}

fn containsString(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, expected)) return true;
    }
    return false;
}

fn lessString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn lessDeviceNode(_: void, left: DeviceNode, right: DeviceNode) bool {
    const order = std.mem.order(u8, left.path, right.path);
    if (order != .eq) return order == .lt;
    return @intFromEnum(left.permissions) < @intFromEnum(right.permissions);
}

fn lessEnvironment(_: void, left: EnvironmentVariable, right: EnvironmentVariable) bool {
    const name_order = std.mem.order(u8, left.name, right.name);
    if (name_order != .eq) return name_order == .lt;
    return std.mem.order(u8, left.value, right.value) == .lt;
}

test "CDI resolution is canonical and independent of input order" {
    const inventory = [_][]const u8{ "gpu:b", "gpu:a" };
    const bindings = [_]LocalBinding{
        .{ .device_id = "gpu:b", .cdi_devices = &.{ "nvidia.com/gpu=2", "nvidia.com/gpu=1" } },
        .{ .device_id = "gpu:a", .cdi_devices = &.{"nvidia.com/gpu=0"} },
    };
    var first = try resolveAlloc(
        std.testing.allocator,
        &inventory,
        .{ .bindings = &bindings },
        &.{ "gpu:b", "gpu:a" },
        .cdi_or_host,
    );
    defer first.deinit();

    const reversed_inventory = [_][]const u8{ "gpu:a", "gpu:b" };
    const reversed_bindings = [_]LocalBinding{ bindings[1], bindings[0] };
    var second = try resolveAlloc(
        std.testing.allocator,
        &reversed_inventory,
        .{ .bindings = &reversed_bindings },
        &.{ "gpu:a", "gpu:b" },
        .cdi_only,
    );
    defer second.deinit();

    try std.testing.expectEqualStrings("gpu:a", first.device_ids[0]);
    try std.testing.expectEqualStrings("gpu:b", first.device_ids[1]);
    const first_cdi = switch (first.access) {
        .cdi => |devices| devices,
        .host => return error.TestExpectedEqual,
    };
    try std.testing.expectEqual(@as(usize, 3), first_cdi.len);
    try std.testing.expectEqualStrings("nvidia.com/gpu=0", first_cdi[0]);
    try std.testing.expectEqualStrings("nvidia.com/gpu=1", first_cdi[1]);
    try std.testing.expectEqualStrings("nvidia.com/gpu=2", first_cdi[2]);
    try std.testing.expectEqualSlices(u8, &first.fingerprint, &second.fingerprint);
}

test "broad malformed and oversized CDI names are rejected" {
    const inventory = [_][]const u8{"gpu:a"};
    const oversized = "nvidia.com/gpu=" ++ ("x" ** max_cdi_name_bytes);
    const invalid = [_][]const u8{
        "nvidia.com/gpu=all",
        "-nvidia.com/gpu=0",
        "nvidia.com/-gpu=0",
        "nvidia.com/gpu=-0",
        "nvidia.com/gpu =0",
        "nvidia.com/gpu=0\n",
        "nvidia/gpu=0",
        "nvidia.com/gpu",
        oversized,
    };
    for (invalid) |name| {
        const bindings = [_]LocalBinding{
            .{ .device_id = "gpu:a", .cdi_devices = &.{name} },
        };
        try std.testing.expectError(
            error.InvalidCdiDevice,
            validateCatalog(&inventory, .{ .bindings = &bindings }),
        );
    }
}

test "catalog and assignment binding invariants fail closed" {
    const inventory = [_][]const u8{ "gpu:a", "gpu:b" };
    const duplicate = [_]LocalBinding{
        .{ .device_id = "gpu:a", .cdi_devices = &.{"nvidia.com/gpu=0"} },
        .{ .device_id = "gpu:a", .cdi_devices = &.{"nvidia.com/gpu=1"} },
    };
    try std.testing.expectError(
        error.DuplicateBinding,
        validateCatalog(&inventory, .{ .bindings = &duplicate }),
    );

    const unknown = [_]LocalBinding{
        .{ .device_id = "gpu:z", .cdi_devices = &.{"nvidia.com/gpu=0"} },
    };
    try std.testing.expectError(
        error.UnknownBinding,
        validateCatalog(&inventory, .{ .bindings = &unknown }),
    );

    const one = [_]LocalBinding{
        .{ .device_id = "gpu:a", .cdi_devices = &.{"nvidia.com/gpu=0"} },
    };
    try std.testing.expectError(
        error.MissingBinding,
        resolveAlloc(
            std.testing.allocator,
            &inventory,
            .{ .bindings = &one },
            &.{"gpu:b"},
            .cdi_only,
        ),
    );
    try std.testing.expectError(
        error.DuplicateAssignedDevice,
        resolveAlloc(
            std.testing.allocator,
            &inventory,
            .{ .bindings = &one },
            &.{ "gpu:a", "gpu:a" },
            .cdi_only,
        ),
    );
}

test "duplicate CDI device names are rejected across bindings" {
    const inventory = [_][]const u8{ "gpu:a", "gpu:b" };
    const bindings = [_]LocalBinding{
        .{ .device_id = "gpu:a", .cdi_devices = &.{"nvidia.com/gpu=0"} },
        .{ .device_id = "gpu:b", .cdi_devices = &.{"nvidia.com/gpu=0"} },
    };
    try std.testing.expectError(
        error.DuplicateCdiDevice,
        validateCatalog(&inventory, .{ .bindings = &bindings }),
    );
}

test "CDI-only policy rejects a host-only binding" {
    const inventory = [_][]const u8{"gpu:a"};
    const bindings = [_]LocalBinding{.{
        .device_id = "gpu:a",
        .host_access = .{
            .completeness = .vendor_verified,
            .device_nodes = &.{.{ .path = "/dev/nvidia0", .permissions = .read_write }},
        },
    }};
    try std.testing.expectError(
        error.HostAccessForbidden,
        resolveAlloc(
            std.testing.allocator,
            &inventory,
            .{ .bindings = &bindings },
            &inventory,
            .cdi_only,
        ),
    );
}

test "advisory host access is never executable" {
    const inventory = [_][]const u8{"gpu:a"};
    const bindings = [_]LocalBinding{.{
        .device_id = "gpu:a",
        .host_access = .{
            .completeness = .advisory,
            .device_nodes = &.{.{ .path = "/dev/nvidia0", .permissions = .read_write }},
        },
    }};
    try std.testing.expectError(
        error.UnverifiedHostAccess,
        resolveAlloc(
            std.testing.allocator,
            &inventory,
            .{ .bindings = &bindings },
            &inventory,
            .cdi_or_host,
        ),
    );
}

test "verified host access requires an exact device allowlist" {
    const inventory = [_][]const u8{"gpu:a"};
    const bindings = [_]LocalBinding{.{
        .device_id = "gpu:a",
        .host_access = .{
            .completeness = .vendor_verified,
            .environment = &.{.{ .name = "CUDA_VISIBLE_DEVICES", .value = "0" }},
        },
    }};
    try std.testing.expectError(
        error.MissingVerifiedDeviceNodes,
        validateCatalog(&inventory, .{ .bindings = &bindings }),
    );
}

test "verified host access merges canonical paths and equal environment" {
    const inventory = [_][]const u8{ "gpu:b", "gpu:a" };
    const bindings = [_]LocalBinding{
        .{
            .device_id = "gpu:b",
            .host_access = .{
                .completeness = .vendor_verified,
                .device_nodes = &.{
                    .{ .path = "/dev/nvidiactl", .permissions = .read_write },
                    .{ .path = "/dev/nvidia1", .permissions = .read_write },
                },
                .environment = &.{.{
                    .name = "CUDA_VISIBLE_DEVICES",
                    .value = "0,1",
                }},
            },
        },
        .{
            .device_id = "gpu:a",
            .host_access = .{
                .completeness = .vendor_verified,
                .device_nodes = &.{
                    .{ .path = "/dev/nvidia0", .permissions = .read_write },
                    .{ .path = "/dev/nvidiactl", .permissions = .read },
                },
                .environment = &.{.{
                    .name = "CUDA_VISIBLE_DEVICES",
                    .value = "0,1",
                }},
            },
        },
    };
    var plan = try resolveAlloc(
        std.testing.allocator,
        &inventory,
        .{ .bindings = &bindings },
        &inventory,
        .cdi_or_host,
    );
    defer plan.deinit();

    const host = switch (plan.access) {
        .host => |access| access,
        .cdi => return error.TestExpectedEqual,
    };
    try std.testing.expectEqual(@as(usize, 3), host.device_nodes.len);
    try std.testing.expectEqualStrings("/dev/nvidia0", host.device_nodes[0].path);
    try std.testing.expectEqualStrings("/dev/nvidia1", host.device_nodes[1].path);
    try std.testing.expectEqualStrings("/dev/nvidiactl", host.device_nodes[2].path);
    try std.testing.expectEqual(Permissions.read_write, host.device_nodes[2].permissions);
    try std.testing.expectEqual(@as(usize, 1), host.environment.len);
    try std.testing.expectEqualStrings("CUDA_VISIBLE_DEVICES", host.environment[0].name);
}

test "host resolver does not silently select CDI for host runtimes" {
    const inventory = [_][]const u8{"gpu:a"};
    const bindings = [_]LocalBinding{.{
        .device_id = "gpu:a",
        .cdi_devices = &.{"nvidia.com/gpu=GPU-a"},
        .host_access = .{
            .completeness = .vendor_verified,
            .device_nodes = &.{.{ .path = "/dev/nvidia0", .permissions = .read_write }},
            .environment = &.{.{ .name = "CUDA_VISIBLE_DEVICES", .value = "GPU-a" }},
        },
    }};
    var plan = try resolveHostAlloc(
        std.testing.allocator,
        &inventory,
        .{ .bindings = &bindings },
        &inventory,
    );
    defer plan.deinit();
    const host = switch (plan.access) {
        .host => |access| access,
        .cdi => return error.TestExpectedEqual,
    };
    try std.testing.expectEqual(@as(usize, 1), host.device_nodes.len);
    try std.testing.expectEqualStrings("/dev/nvidia0", host.device_nodes[0].path);
}

test "conflicting environment values reject host merge" {
    const inventory = [_][]const u8{ "gpu:a", "gpu:b" };
    const bindings = [_]LocalBinding{
        .{
            .device_id = "gpu:a",
            .host_access = .{
                .completeness = .vendor_verified,
                .device_nodes = &.{.{ .path = "/dev/nvidia0", .permissions = .read_write }},
                .environment = &.{.{ .name = "CUDA_VISIBLE_DEVICES", .value = "0" }},
            },
        },
        .{
            .device_id = "gpu:b",
            .host_access = .{
                .completeness = .vendor_verified,
                .device_nodes = &.{.{ .path = "/dev/nvidia1", .permissions = .read_write }},
                .environment = &.{.{ .name = "CUDA_VISIBLE_DEVICES", .value = "1" }},
            },
        },
    };
    try std.testing.expectError(
        error.EnvironmentConflict,
        resolveAlloc(
            std.testing.allocator,
            &inventory,
            .{ .bindings = &bindings },
            &inventory,
            .cdi_or_host,
        ),
    );
}

test "host paths and environment names are constrained" {
    const inventory = [_][]const u8{"gpu:a"};
    const invalid_paths = [_][]const u8{
        "dev/nvidia0",
        "/tmp/nvidia0",
        "/dev/../etc/passwd",
        "/dev/nvidia*",
        "/dev/nvidia0\n",
    };
    for (invalid_paths) |path| {
        const bindings = [_]LocalBinding{.{
            .device_id = "gpu:a",
            .host_access = .{
                .completeness = .vendor_verified,
                .device_nodes = &.{.{ .path = path, .permissions = .read_write }},
            },
        }};
        try std.testing.expectError(
            error.InvalidDevicePath,
            validateCatalog(&inventory, .{ .bindings = &bindings }),
        );
    }

    const unsafe_environment = [_]LocalBinding{.{
        .device_id = "gpu:a",
        .host_access = .{
            .completeness = .vendor_verified,
            .device_nodes = &.{.{ .path = "/dev/nvidia0", .permissions = .read_write }},
            .environment = &.{.{ .name = "LD_PRELOAD", .value = "/tmp/inject.so" }},
        },
    }};
    try std.testing.expectError(
        error.InvalidEnvironmentName,
        validateCatalog(&inventory, .{ .bindings = &unsafe_environment }),
    );
}

test "fingerprint is repeatable and changes with canonical plan fields" {
    const inventory = [_][]const u8{"gpu:a"};
    const first_bindings = [_]LocalBinding{
        .{ .device_id = "gpu:a", .cdi_devices = &.{"nvidia.com/gpu=0"} },
    };
    var first = try resolveAlloc(
        std.testing.allocator,
        &inventory,
        .{ .bindings = &first_bindings },
        &inventory,
        .cdi_only,
    );
    defer first.deinit();
    var repeated = try resolveAlloc(
        std.testing.allocator,
        &inventory,
        .{ .bindings = &first_bindings },
        &inventory,
        .cdi_only,
    );
    defer repeated.deinit();
    try std.testing.expectEqualSlices(u8, &first.fingerprint, &repeated.fingerprint);

    const changed_bindings = [_]LocalBinding{
        .{ .device_id = "gpu:a", .cdi_devices = &.{"nvidia.com/gpu=1"} },
    };
    var changed = try resolveAlloc(
        std.testing.allocator,
        &inventory,
        .{ .bindings = &changed_bindings },
        &inventory,
        .cdi_only,
    );
    defer changed.deinit();
    try std.testing.expect(!std.mem.eql(u8, &first.fingerprint, &changed.fingerprint));
}

test "OwnedCatalog deep copies every nested slice" {
    var device_id = [_]u8{ 'g', 'p', 'u', ':', 'a' };
    var cdi = [_]u8{ 'n', 'v', 'i', 'd', 'i', 'a', '.', 'c', 'o', 'm', '/', 'g', 'p', 'u', '=', '0' };
    var path = [_]u8{ '/', 'd', 'e', 'v', '/', 'n', 'v', 'i', 'd', 'i', 'a', '0' };
    var name = [_]u8{ 'C', 'U', 'D', 'A', '_', 'V', 'I', 'S', 'I', 'B', 'L', 'E', '_', 'D', 'E', 'V', 'I', 'C', 'E', 'S' };
    var value = [_]u8{'0'};
    const bindings = [_]LocalBinding{.{
        .device_id = &device_id,
        .cdi_devices = &.{&cdi},
        .host_access = .{
            .completeness = .vendor_verified,
            .device_nodes = &.{.{ .path = &path, .permissions = .read_write }},
            .environment = &.{.{ .name = &name, .value = &value }},
        },
    }};
    var owned = try OwnedCatalog.initClone(std.testing.allocator, &bindings);
    defer owned.deinit();

    @memset(&device_id, 'x');
    @memset(&cdi, 'x');
    @memset(&path, 'x');
    @memset(&name, 'x');
    @memset(&value, 'x');

    const cloned = owned.view().bindings[0];
    try std.testing.expectEqualStrings("gpu:a", cloned.device_id);
    try std.testing.expectEqualStrings("nvidia.com/gpu=0", cloned.cdi_devices[0]);
    try std.testing.expectEqualStrings("/dev/nvidia0", cloned.host_access.?.device_nodes[0].path);
    try std.testing.expectEqualStrings(
        "CUDA_VISIBLE_DEVICES",
        cloned.host_access.?.environment[0].name,
    );
    try std.testing.expectEqualStrings("0", cloned.host_access.?.environment[0].value);
}

fn cloneCatalogWithAllocator(allocator: std.mem.Allocator) !void {
    const bindings = [_]LocalBinding{.{
        .device_id = "gpu:a",
        .cdi_devices = &.{ "nvidia.com/gpu=0", "nvidia.com/gpu=1" },
        .host_access = .{
            .completeness = .vendor_verified,
            .device_nodes = &.{
                .{ .path = "/dev/nvidia0", .permissions = .read_write },
                .{ .path = "/dev/nvidiactl", .permissions = .read_write },
            },
            .environment = &.{.{ .name = "CUDA_VISIBLE_DEVICES", .value = "0" }},
        },
    }};
    var owned = try OwnedCatalog.initClone(allocator, &bindings);
    defer owned.deinit();
}

test "OwnedCatalog cleans up every partial allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        cloneCatalogWithAllocator,
        .{},
    );
}
