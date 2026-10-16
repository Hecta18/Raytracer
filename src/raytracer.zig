//! Root of the raytracer library module. Nothing here touches raylib, so the
//! renderer can be built and unit tested without a graphics context.
pub const geometry = @import("geometry.zig");
pub const light = @import("light.zig");
pub const material = @import("material.zig");
pub const math = @import("math.zig");
pub const renderer = @import("renderer.zig");
pub const scene = @import("scene.zig");