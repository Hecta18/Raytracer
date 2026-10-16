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
}