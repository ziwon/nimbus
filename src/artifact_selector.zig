const std = @import("std");
const accelerator = @import("accelerator.zig");
const orchestration = @import("orchestration.zig");

pub const Context = struct {
    os: []const u8,
    arch: []const u8,
    abi: []const u8,
    accelerators: []const accelerator.Device = &.{},
};

pub const Selection = struct {
    artifact: orchestration.Artifact,
    variant: ?orchestration.ArtifactVariant = null,
    variant_name: ?[]const u8 = null,
    fallback: bool = false,
};

/// Select the most specific compatible primary variant. Declared fallbacks
/// are considered only when no primary matches. Equal-specificity candidates
/// use lexical variant name order, making input order irrelevant.
pub fn select(
    deployment: orchestration.Deployment,
    context: Context,
) !?Selection {
    if (deployment.artifact) |artifact| return .{ .artifact = artifact };
    const variants = deployment.artifact_variants orelse return null;
    if (variants.len == 0) return null;

    if (bestVariant(variants, context, false)) |variant|
        return .{
            .artifact = variant.artifact,
            .variant = variant,
            .variant_name = variant.name,
        };
    if (bestVariant(variants, context, true)) |variant|
        return .{
            .artifact = variant.artifact,
            .variant = variant,
            .variant_name = variant.name,
            .fallback = true,
        };
    return error.NoCompatibleArtifactVariant;
}

/// Resolve a previously journaled variant without running tie-breaking again.
/// Compatibility is still checked so a corrupt or stale journal cannot bypass
/// the declared selector.
pub fn selectNamed(
    deployment: orchestration.Deployment,
    context: Context,
    name: []const u8,
) !Selection {
    const variants = deployment.artifact_variants orelse
        return error.ArtifactVariantNotDeclared;
    for (variants) |variant| {
        if (!std.mem.eql(u8, variant.name, name)) continue;
        if (!matches(variant.selector, context))
            return error.ArtifactVariantNoLongerCompatible;
        return .{
            .artifact = variant.artifact,
            .variant = variant,
            .variant_name = variant.name,
            .fallback = variant.fallback,
        };
    }
    return error.ArtifactVariantNotDeclared;
}

fn bestVariant(
    variants: []const orchestration.ArtifactVariant,
    context: Context,
    fallback: bool,
) ?orchestration.ArtifactVariant {
    var best: ?orchestration.ArtifactVariant = null;
    var best_score: u16 = 0;
    for (variants) |variant| {
        if (variant.fallback != fallback or !matches(variant.selector, context))
            continue;
        const score = specificity(variant.selector);
        if (best == null or score > best_score or
            (score == best_score and std.mem.order(u8, variant.name, best.?.name) == .lt))
        {
            best = variant;
            best_score = score;
        }
    }
    return best;
}

fn matches(selector: orchestration.ArtifactSelector, context: Context) bool {
    if (selector.os) |value| {
        if (!std.ascii.eqlIgnoreCase(value, context.os)) return false;
    }
    if (selector.arch) |value| {
        if (!std.ascii.eqlIgnoreCase(value, context.arch)) return false;
    }
    if (selector.abi) |value| {
        if (!std.ascii.eqlIgnoreCase(value, context.abi)) return false;
    }

    const accelerator_specific = selector.accelerator_kind != null;
    if (!accelerator_specific) return true;
    if (context.accelerators.len == 0) return false;
    for (context.accelerators) |device| {
        if (device.kind != selector.accelerator_kind.?) return false;
        if (selector.accelerator_vendor) |vendor| {
            if (!std.ascii.eqlIgnoreCase(vendor, device.vendor)) return false;
        }
        if (selector.accelerator_model) |model| {
            if (!std.ascii.eqlIgnoreCase(model, device.model)) return false;
        }
        for (selector.accelerator_capabilities) |required| {
            var found = false;
            for (device.capabilities) |available| {
                if (!std.mem.eql(u8, required, available)) continue;
                found = true;
                break;
            }
            if (!found) return false;
        }
    }
    return true;
}

fn specificity(selector: orchestration.ArtifactSelector) u16 {
    var result: u16 = 0;
    if (selector.os != null) result += 1;
    if (selector.arch != null) result += 1;
    if (selector.abi != null) result += 1;
    if (selector.accelerator_kind != null) result += 4;
    if (selector.accelerator_vendor != null) result += 2;
    if (selector.accelerator_model != null) result += 2;
    result += @intCast(selector.accelerator_capabilities.len);
    return result;
}

fn fixtureArtifact(comptime byte: []const u8) orchestration.Artifact {
    return .{
        .source = "file:///tmp/" ++ byte,
        .sha256 = byte ** 32,
    };
}

const nvidia: accelerator.Device = .{
    .id = "gpu:nvidia:a",
    .kind = .gpu,
    .vendor = "NVIDIA",
    .model = "L4",
    .source = "fixture",
    .capabilities = &.{ "fp16", "int8" },
};

test "selection is deterministic across CPU Jetson and server GPU contexts" {
    const variants = [_]orchestration.ArtifactVariant{
        .{
            .name = "portable",
            .artifact = fixtureArtifact("aa"),
            .selector = .{ .os = "linux" },
        },
        .{
            .name = "nvidia-l4",
            .artifact = fixtureArtifact("bb"),
            .selector = .{
                .os = "linux",
                .arch = "x86_64",
                .accelerator_kind = .gpu,
                .accelerator_vendor = "nvidia",
                .accelerator_model = "L4",
                .accelerator_capabilities = &.{"fp16"},
            },
        },
        .{
            .name = "jetson",
            .artifact = fixtureArtifact("cc"),
            .selector = .{
                .os = "linux",
                .arch = "aarch64",
                .accelerator_kind = .gpu,
                .accelerator_vendor = "nvidia",
            },
        },
    };
    const deployment: orchestration.Deployment = .{
        .name = "vision",
        .revision = 1,
        .runtime = .{ .kind = .process, .command = &.{"{artifact}"} },
        .artifact_variants = &variants,
        .targets = .{ .all = true },
    };
    try std.testing.expectEqualStrings(
        "portable",
        (try select(deployment, .{ .os = "linux", .arch = "x86_64", .abi = "gnu" })).?.variant_name.?,
    );
    try std.testing.expectEqualStrings(
        "nvidia-l4",
        (try select(deployment, .{
            .os = "linux",
            .arch = "x86_64",
            .abi = "gnu",
            .accelerators = &.{nvidia},
        })).?.variant_name.?,
    );
    var jetson = nvidia;
    jetson.model = "Jetson Orin";
    try std.testing.expectEqualStrings(
        "jetson",
        (try select(deployment, .{
            .os = "linux",
            .arch = "aarch64",
            .abi = "gnu",
            .accelerators = &.{jetson},
        })).?.variant_name.?,
    );
}

test "equal specificity is lexical and independent of declaration order" {
    const variants = [_]orchestration.ArtifactVariant{
        .{ .name = "zeta", .artifact = fixtureArtifact("dd"), .selector = .{ .os = "linux" } },
        .{ .name = "alpha", .artifact = fixtureArtifact("ee"), .selector = .{ .os = "linux" } },
    };
    const deployment: orchestration.Deployment = .{
        .name = "model",
        .revision = 1,
        .runtime = .{ .kind = .process, .command = &.{"{artifact}"} },
        .artifact_variants = &variants,
        .targets = .{ .all = true },
    };
    const selected = (try select(deployment, .{
        .os = "linux",
        .arch = "x86_64",
        .abi = "musl",
    })).?;
    try std.testing.expectEqualStrings("alpha", selected.variant_name.?);
}

test "fallback is explicit and integrity failure is outside selection" {
    const variants = [_]orchestration.ArtifactVariant{
        .{
            .name = "cuda-only",
            .artifact = fixtureArtifact("ff"),
            .selector = .{
                .accelerator_kind = .gpu,
                .accelerator_vendor = "nvidia",
            },
        },
        .{
            .name = "cpu-fallback",
            .artifact = fixtureArtifact("11"),
            .fallback = true,
        },
    };
    const deployment: orchestration.Deployment = .{
        .name = "model",
        .revision = 1,
        .runtime = .{ .kind = .process, .command = &.{"{artifact}"} },
        .artifact_variants = &variants,
        .targets = .{ .all = true },
    };
    const selected = (try select(deployment, .{
        .os = "linux",
        .arch = "x86_64",
        .abi = "gnu",
    })).?;
    try std.testing.expect(selected.fallback);
    try std.testing.expectEqualStrings("cpu-fallback", selected.variant_name.?);
}
