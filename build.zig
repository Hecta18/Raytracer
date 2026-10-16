const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Raytracing in ReleaseFast by default; Debug is available via -Doptimize=Debug.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        // raylib is not the hot path here. It is built as a shared library
        // because the static archive bundles the system .so files, which LLD
        // rejects when linking a ReleaseFast executable.
        .optimize = .ReleaseSafe,
        .linkage = .dynamic,
        // Audio is unused and would pull in an ALSA link dependency.
        .raudio = false,
    });
    const raylib = raylib_dep.module("raylib");

    // The raytracer itself never touches raylib, which keeps it buildable and
    // testable without a graphics context.
    const raytracer = b.addModule("raytracer", .{
        .root_source_file = b.path("src/raytracer.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "diorama",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "raylib", .module = raylib },
                .{ .name = "raytracer", .module = raytracer },
            },
        }),
    });
    b.installArtifact(exe);
    // Ship the shared raylib next to the binary so zig-out/bin/diorama runs on
    // its own.
    b.installArtifact(raylib_dep.artifact("raylib"));

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the diorama");
    run_step.dependOn(&run_cmd.step);

    // The raytracer module never imports raylib, so its tests link no graphics
    // stack and run without a display.
    const module_tests = b.addTest(.{ .root_module = raytracer });
    // The renderer reads a monotonic clock and sleeps through libc.
    module_tests.root_module.link_libc = true;
    const test_step = b.step("test", "Run the raytracer unit tests");
    test_step.dependOn(&b.addRunArtifact(module_tests).step);
}