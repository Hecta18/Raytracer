//! Root of the raytracer library module. Nothing here touches raylib, so the
//! renderer can be built and unit tested without a graphics context.
const std = @import("std");

pub const geometry = @import("geometry.zig");
pub const light = @import("light.zig");
pub const material = @import("material.zig");
pub const math = @import("math.zig");
pub const renderer = @import("renderer.zig");
pub const scene = @import("scene.zig");

test {
    // The root only re-exports, so reference the modules from a test: this is
    // what makes the runner compile the tests that live in the submodules.
    _ = geometry;
    _ = light;
    _ = material;
    _ = math;
    _ = renderer;
    _ = scene;
    std.testing.refAllDecls(@This());
}