const std = @import("std");
const accelerator = @import("accelerator.zig");
const allocation = @import("allocation.zig");
const placement = @import("placement.zig");

pub const schema_version: u8 = 1;

pub const RuntimeKind = enum {
    process,
    systemd,
    docker,
    containerd,
};

pub const DesiredStatus = enum {
    running,
    stopped,
};

pub const RestartPolicy = enum {
    never,
    on_failure,
    always,
};

pub const HealthKind = enum {
    runtime,
    http,
    tcp,
    command,
};

pub const ObservedState = enum {
    pending,
    applying,
    healthy,
    degraded,
    failed,
    stopped,
    blocked,
};

pub const RuntimeSpec = struct {
    kind: RuntimeKind,
    /// A systemd unit or an immutable container image reference.
    reference: ?[]const u8 = null,
    /// Executed directly without a shell. `{artifact}` is replaced with the
    /// verified local artifact path when an artifact is present.
    command: []const []const u8 = &.{},
    working_directory: ?[]const u8 = null,
};

pub const Artifact = struct {
    /// `file://` and `http://` are supported by the bootstrap transport.
    source: []const u8,
    sha256: []const u8,
    /// Hex-encoded Ed25519 signature. A single artifact signs its lowercase
    /// digest; a named variant signs the domain-separated variant descriptor.
    signature_ed25519: ?[]const u8 = null,
};

pub const ArtifactSelector = struct {
    os: ?[]const u8 = null,
    arch: ?[]const u8 = null,
    abi: ?[]const u8 = null,
    accelerator_kind: ?accelerator.Kind = null,
    accelerator_vendor: ?[]const u8 = null,
    accelerator_model: ?[]const u8 = null,
    accelerator_capabilities: []const []const u8 = &.{},
};

pub const ArtifactVariant = struct {
    name: []const u8,
    artifact: Artifact,
    selector: ArtifactSelector = .{},
    /// A fallback participates only when no compatible primary variant exists.
    /// Integrity or signature failure never triggers a downgrade.
    fallback: bool = false,
};

pub const HealthCheck = struct {
    kind: HealthKind = .runtime,
    /// HTTP URL or numeric `host:port` TCP endpoint.
    target: ?[]const u8 = null,
    /// Direct argv for command health checks; no shell expansion is applied.
    command: []const []const u8 = &.{},
    timeout_seconds: u32 = 5,
    failure_threshold: u8 = 3,
};

pub const Targets = struct {
    all: bool = false,
    node_ids: []const []const u8 = &.{},
    roles: []const []const u8 = &.{},
    labels: []const LabelSelector = &.{},
};

pub const LabelSelector = struct {
    key: []const u8,
    value: []const u8,
};

pub const Rollout = struct {
    batch_size: u32 = 1,
    max_unavailable: u32 = 1,
    pause_seconds: u32 = 0,
    auto_rollback: bool = true,
};

pub const Resources = struct {
    accelerators: accelerator.Requirement,
};

pub const Deployment = struct {
    schema_version: u8 = schema_version,
    name: []const u8,
    revision: u64,
    desired: DesiredStatus = .running,
    runtime: RuntimeSpec,
    artifact: ?Artifact = null,
    /// Omitted on the wire unless a deployment opts into artifact variants.
    /// This preserves strict-parser compatibility with pre-A4 agents.
    artifact_variants: ?[]const ArtifactVariant = null,
    health_check: HealthCheck = .{},
    restart_policy: RestartPolicy = .always,
    resources: ?Resources = null,
    placement: ?placement.Policy = null,
    targets: Targets,
    rollout: Rollout = .{},
};

pub const AcceleratorAssignment = struct {
    deployment: []const u8,
    revision: u64,
    /// The outer slice and strings are borrowed from the desired-state document.
    device_ids: []const []const u8,
};

pub const DesiredState = struct {
    schema_version: u8 = schema_version,
    node_id: []const u8,
    generation: i64,
    deployments: []const Deployment,
    accelerator_assignments: []const AcceleratorAssignment = &.{},
    accelerator_allocations: []const allocation.DesiredAllocation = &.{},
};

pub const StatusReport = struct {
    schema_version: u8 = schema_version,
    node_id: []const u8,
    deployment: []const u8,
    revision: u64,
    state: ObservedState,
    message: []const u8 = "",
    observed_unix_ms: i64,
};

pub fn validateDeployment(value: Deployment) bool {
    if (value.schema_version != schema_version or !isName(value.name) or
        value.revision == 0 or value.revision > std.math.maxInt(i64))
        return false;
    if (!validTargets(value.targets) or !validRollout(value.rollout)) return false;
    const variants = value.artifact_variants orelse &.{};
    if (value.artifact != null and variants.len != 0) return false;
    if (variants.len > 32) return false;
    const has_artifact = value.artifact != null or variants.len != 0;
    if (!validRuntime(value.runtime, has_artifact)) return false;
    if (!validHealth(value.health_check)) return false;
    if (value.resources) |resources| {
        if (!accelerator.validateRequirement(resources.accelerators)) return false;
    }
    if (value.placement) |policy| {
        if (!placement.validatePolicy(policy)) return false;
        if ((policy.min_accelerator_free_memory_bytes != null or
            policy.max_accelerator_temperature_millicelsius != null or
            policy.max_accelerator_power_milliwatts != null) and
            value.resources == null) return false;
    }
    if (value.artifact) |artifact| {
        if (!validArtifact(artifact)) return false;
    }
    for (variants, 0..) |variant, index| {
        if (!isName(variant.name) or !validArtifact(variant.artifact) or
            !validArtifactSelector(variant.selector)) return false;
        for (variants[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, variant.name)) return false;
        }
    }
    return true;
}

pub fn validateAcceleratorAssignment(value: AcceleratorAssignment) bool {
    if (!isName(value.deployment) or value.revision == 0 or
        value.revision > std.math.maxInt(i64) or value.device_ids.len == 0 or
        value.device_ids.len > accelerator.max_device_count)
        return false;
    for (value.device_ids, 0..) |device_id, index| {
        if (!accelerator.isValidDeviceId(device_id)) return false;
        for (value.device_ids[0..index]) |previous| {
            if (std.mem.eql(u8, previous, device_id)) return false;
        }
    }
    return true;
}

pub fn validateStatus(value: StatusReport) bool {
    return value.schema_version == schema_version and
        isName(value.node_id) and
        isName(value.deployment) and
        value.revision > 0 and value.revision <= std.math.maxInt(i64) and
        value.message.len <= 1024 and
        value.observed_unix_ms > 0;
}

pub fn isName(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.'))
            return false;
    }
    return true;
}

pub fn validDigest(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn validTargets(targets: Targets) bool {
    if (!targets.all and targets.node_ids.len == 0 and targets.roles.len == 0 and
        targets.labels.len == 0) return false;
    if (targets.node_ids.len > 10_000 or targets.roles.len > 256 or targets.labels.len > 64)
        return false;
    for (targets.node_ids) |node_id| if (!isName(node_id)) return false;
    for (targets.roles) |role| if (!isName(role) or role.len > 64) return false;
    for (targets.labels, 0..) |label, index| {
        if (!isLabelKey(label.key) or !isLabelValue(label.value)) return false;
        for (targets.labels[0..index]) |previous| {
            if (std.mem.eql(u8, previous.key, label.key)) return false;
        }
    }
    return true;
}

pub fn isLabelKey(value: []const u8) bool {
    if (value.len == 0 or value.len > 63 or
        !std.ascii.isAlphanumeric(value[0]) or
        !std.ascii.isAlphanumeric(value[value.len - 1])) return false;
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.'))
            return false;
    }
    return true;
}

pub fn isLabelValue(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |byte| {
        if (byte < 0x21 or byte > 0x7e or byte == '"' or byte == '\\') return false;
    }
    return true;
}

fn validRollout(rollout: Rollout) bool {
    return rollout.batch_size > 0 and rollout.batch_size <= 10_000 and
        rollout.max_unavailable > 0 and rollout.max_unavailable <= rollout.batch_size and
        rollout.pause_seconds <= 86_400;
}

fn validRuntime(runtime: RuntimeSpec, has_artifact: bool) bool {
    if (runtime.command.len > 256) return false;
    for (runtime.command) |argument| {
        if (argument.len == 0 or argument.len > 4096 or std.mem.indexOfScalar(u8, argument, 0) != null)
            return false;
    }
    if (runtime.working_directory) |path| {
        if (path.len == 0 or path.len > 4096 or !std.fs.path.isAbsolute(path)) return false;
    }

    switch (runtime.kind) {
        .process => {
            if (runtime.reference != null or runtime.command.len == 0) return false;
            const executable = runtime.command[0];
            if (!std.fs.path.isAbsolute(executable) and
                !(has_artifact and std.mem.eql(u8, executable, "{artifact}"))) return false;
        },
        .systemd => {
            const unit = runtime.reference orelse return false;
            if (!isUnitName(unit) or runtime.command.len != 0 or has_artifact) return false;
        },
        .docker, .containerd => {
            const image = runtime.reference orelse return false;
            if (!validImageReference(image) or has_artifact) return false;
        },
    }
    return true;
}

fn validArtifact(artifact: Artifact) bool {
    if (artifact.source.len == 0 or artifact.source.len > 4096 or
        std.mem.indexOfScalar(u8, artifact.source, 0) != null) return false;
    if (!(std.mem.startsWith(u8, artifact.source, "file://") or
        std.mem.startsWith(u8, artifact.source, "http://"))) return false;
    if (!validDigest(artifact.sha256)) return false;
    if (artifact.signature_ed25519) |signature| {
        if (signature.len != 128) return false;
        for (signature) |byte| if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn validArtifactSelector(selector: ArtifactSelector) bool {
    if (selector.os) |value| if (!isSelectorValue(value)) return false;
    if (selector.arch) |value| if (!isSelectorValue(value)) return false;
    if (selector.abi) |value| if (!isSelectorValue(value)) return false;
    if (selector.accelerator_vendor) |value| if (!isSelectorValue(value)) return false;
    if (selector.accelerator_model) |value| if (!isSelectorValue(value)) return false;
    if (selector.accelerator_capabilities.len > 32) return false;
    for (selector.accelerator_capabilities, 0..) |capability, index| {
        if (!isSelectorValue(capability)) return false;
        for (selector.accelerator_capabilities[0..index]) |previous| {
            if (std.mem.eql(u8, previous, capability)) return false;
        }
        if (index > 0 and
            std.mem.order(u8, selector.accelerator_capabilities[index - 1], capability) != .lt)
            return false;
    }
    if ((selector.accelerator_vendor != null or
        selector.accelerator_model != null or
        selector.accelerator_capabilities.len != 0) and
        selector.accelerator_kind == null) return false;
    return true;
}

fn isSelectorValue(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |byte| {
        if (byte < 0x21 or byte > 0x7e or byte == '"' or byte == '\\' or byte == 0)
            return false;
    }
    return true;
}

fn validHealth(health: HealthCheck) bool {
    if (health.timeout_seconds == 0 or health.timeout_seconds > 300 or
        health.failure_threshold == 0 or health.failure_threshold > 20) return false;
    return switch (health.kind) {
        .runtime => health.target == null and health.command.len == 0,
        .http => if (health.target) |target|
            (target.len <= 4096 and std.mem.startsWith(u8, target, "http://") and
                health.command.len == 0)
        else
            false,
        .tcp => if (health.target) |target|
            (target.len > 2 and target.len <= 512 and health.command.len == 0)
        else
            false,
        .command => health.target == null and validCommand(health.command),
    };
}

fn validCommand(command: []const []const u8) bool {
    if (command.len == 0 or command.len > 256 or !std.fs.path.isAbsolute(command[0])) return false;
    for (command) |argument| {
        if (argument.len == 0 or argument.len > 4096 or std.mem.indexOfScalar(u8, argument, 0) != null)
            return false;
    }
    return true;
}

fn isUnitName(value: []const u8) bool {
    if (value.len == 0 or value.len > 255 or !std.ascii.isAlphanumeric(value[0])) return false;
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '@'))
            return false;
    }
    return true;
}

fn validImageReference(value: []const u8) bool {
    if (value.len == 0 or value.len > 1024 or !std.ascii.isAlphanumeric(value[0])) return false;
    for (value) |byte| if (byte < 0x21 or byte > 0x7e) return false;
    const marker = "@sha256:";
    const index = std.mem.lastIndexOf(u8, value, marker) orelse return false;
    if (index == 0 or index + marker.len + 64 != value.len) return false;
    return validDigest(value[index + marker.len ..]);
}

test "deployment validation requires immutable and typed runtimes" {
    const process: Deployment = .{
        .name = "vision-agent",
        .revision = 1,
        .runtime = .{ .kind = .process, .command = &.{ "/opt/vision/bin/serve", "--port", "9000" } },
        .targets = .{ .roles = &.{"smart-class"} },
    };
    try std.testing.expect(validateDeployment(process));

    var mutable_image = process;
    mutable_image.runtime = .{ .kind = .docker, .reference = "registry.example/vision:latest" };
    try std.testing.expect(!validateDeployment(mutable_image));
    mutable_image.runtime = .{ .kind = .docker, .reference = "registry.example/vision@sha256:nope" };
    try std.testing.expect(!validateDeployment(mutable_image));
}

test "artifact digest and status validation are strict" {
    const deployment: Deployment = .{
        .name = "edge-model",
        .revision = 7,
        .runtime = .{ .kind = .process, .command = &.{"{artifact}"} },
        .artifact = .{
            .source = "http://artifacts.example/edge-model",
            .sha256 = "ab" ** 32,
        },
        .targets = .{ .node_ids = &.{"glasses-01"} },
    };
    try std.testing.expect(validateDeployment(deployment));
    try std.testing.expect(!validDigest("not-a-digest"));
}

test "deployment target label keys must be unique" {
    const deployment: Deployment = .{
        .name = "duplicate-labels",
        .revision = 1,
        .runtime = .{ .kind = .process, .command = &.{"/bin/true"} },
        .targets = .{ .labels = &.{
            .{ .key = "site", .value = "school-a" },
            .{ .key = "site", .value = "school-b" },
        } },
    };
    try std.testing.expect(!validateDeployment(deployment));
}

test "deployment accelerator requirements are bounded" {
    var deployment: Deployment = .{
        .name = "accelerated-model",
        .revision = 1,
        .runtime = .{ .kind = .process, .command = &.{"/bin/true"} },
        .resources = .{ .accelerators = .{
            .count = 2,
            .kind = .gpu,
            .vendor = "nvidia",
            .memory_min_bytes = 4 * 1024 * 1024 * 1024,
            .capabilities = &.{ "fp16", "int8" },
        } },
        .targets = .{ .all = true },
    };
    try std.testing.expect(validateDeployment(deployment));

    deployment.resources.?.accelerators.count = 0;
    try std.testing.expect(!validateDeployment(deployment));
    deployment.resources.?.accelerators.count = accelerator.max_device_count + 1;
    try std.testing.expect(!validateDeployment(deployment));
    deployment.resources.?.accelerators.count = 1;

    deployment.resources.?.accelerators.memory_min_bytes = 0;
    try std.testing.expect(!validateDeployment(deployment));
    deployment.resources.?.accelerators.memory_min_bytes = @as(u64, std.math.maxInt(i64)) + 1;
    try std.testing.expect(!validateDeployment(deployment));
    deployment.resources.?.accelerators.memory_min_bytes = null;
    deployment.resources.?.accelerators.vendor = "not a vendor";
    try std.testing.expect(!validateDeployment(deployment));
    deployment.resources.?.accelerators.vendor = "nvidia";
    deployment.resources.?.accelerators.capabilities = &.{ "fp16", "fp16" };
    try std.testing.expect(!validateDeployment(deployment));
}

test "accelerator assignment validation requires unique opaque device IDs" {
    const valid: AcceleratorAssignment = .{
        .deployment = "accelerated-model",
        .revision = 7,
        .device_ids = &.{ "gpu:nvidia:001", "gpu:nvidia:002" },
    };
    try std.testing.expect(validateAcceleratorAssignment(valid));

    var invalid = valid;
    invalid.device_ids = &.{ "gpu:nvidia:001", "gpu:nvidia:001" };
    try std.testing.expect(!validateAcceleratorAssignment(invalid));
    invalid.device_ids = &.{"raw device path /dev/nvidia0"};
    try std.testing.expect(!validateAcceleratorAssignment(invalid));
    invalid.device_ids = &.{};
    try std.testing.expect(!validateAcceleratorAssignment(invalid));
}
