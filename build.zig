const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Raytracing in ReleaseFast by default; Debug is available via -Doptimize=Debug.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
        // Audio is unused and would pull in an ALSA link dependency.
        .raudio = false,
    });
    const raylib = raylib_dep.module("raylib");

    const exe = b.addExecutable(.{
        .name = "diorama",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "raylib", .module = raylib }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the diorama");
    run_step.dependOn(&run_cmd.step);
}