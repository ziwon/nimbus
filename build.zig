const std = @import("std");

const app_name = "nimbus";
const app_version = "0.2.0";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = addNimbus(b, target, optimize);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run nimbus");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addBuildOptions(b, unit_tests);
    addSqlite(b, unit_tests);

    const test_step = b.step("test", "Run unit tests");
    const run_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_tests.step);

    addReleaseStep(b);
}

fn addNimbus(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = app_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addBuildOptions(b, exe);
    addSqlite(b, exe);
    return exe;
}

fn addSqlite(b: *std.Build, compile: *std.Build.Step.Compile) void {
    compile.root_module.link_libc = true;
    compile.root_module.addIncludePath(b.path("third_party/sqlite"));
    compile.root_module.addCSourceFile(.{
        .file = b.path("third_party/sqlite/sqlite3.c"),
        .flags = &.{
            "-std=c99",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
        },
    });
}

fn addBuildOptions(b: *std.Build, compile: *std.Build.Step.Compile) void {
    const options = b.addOptions();
    options.addOption([]const u8, "version", app_version);
    compile.root_module.addOptions("build_options", options);
}

fn addReleaseStep(b: *std.Build) void {
    const release_step = b.step("release", "Cross-compile release binaries");

    const ReleaseTarget = struct {
        name: []const u8,
        query: std.Target.Query,
    };

    const targets = [_]ReleaseTarget{
        .{
            .name = "linux-x86_64",
            .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        },
        .{
            .name = "linux-aarch64",
            .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
        },
        .{
            .name = "windows-x86_64",
            .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
        },
        .{
            .name = "macos-x86_64",
            .query = .{ .cpu_arch = .x86_64, .os_tag = .macos },
        },
        .{
            .name = "macos-aarch64",
            .query = .{ .cpu_arch = .aarch64, .os_tag = .macos },
        },
    };

    for (targets) |item| {
        const exe = addNimbus(
            b,
            b.resolveTargetQuery(item.query),
            .ReleaseSmall,
        );
        const install = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("releases/{s}", .{item.name}) } },
        });
        release_step.dependOn(&install.step);
    }
}
