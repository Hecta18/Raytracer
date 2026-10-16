//! The diorama: seven cubes in a centre-plus-six-neighbours arrangement, and
//! the queries the renderer needs against them.
const math = @import("math.zig");
const geometry = @import("geometry.zig");
const material = @import("material.zig");
const light = @import("light.zig");

const Vec3 = math.Vec3;

/// Material slots, used by the cube layout below.
pub const emerald: u32 = 0;
pub const amber: u32 = 1;
pub const sapphire: u32 = 2;
pub const rose_gold: u32 = 3;
pub const obsidian: u32 = 4;

pub const cube_size: f32 = 1.0;
pub const cube_count: usize = 7;

pub const Camera = struct {
    yaw: f32 = -0.65,
    pitch: f32 = 0.32,
    distance: f32 = 5.9,
    fov_degrees: f32 = 42.0,
    target: Vec3 = .{ 0.0, 0.1, 0.0 },
    aspect: f32 = 16.0 / 9.0,

    pub fn position(self: Camera) Vec3 {
        const cos_pitch = @cos(self.pitch);
        return self.target + @as(Vec3, .{
            self.distance * @cos(self.yaw) * cos_pitch,
            self.distance * @sin(self.pitch),
            self.distance * @sin(self.yaw) * cos_pitch,
        });
    }

    /// ndc.x and ndc.y run from -1 to 1 with +y up.
    pub fn ray(self: Camera, ndc: math.Vec2) math.Ray {
        const eye = self.position();
        const forward = math.normalize(self.target - eye);
        const right = math.normalize(math.cross(forward, .{ 0.0, 1.0, 0.0 }));
        const up = math.cross(right, forward);
        const half_fov = @tan(self.fov_degrees * 0.5 * math.pi / 180.0);

        return .{
            .origin = eye,
            .dir = math.normalize(forward + math.scale(right, ndc[0] * half_fov * self.aspect) + math.scale(up, ndc[1] * half_fov)),
        };
    }

    /// Accumulated samples belong to one exact pose, so anything that changes a
    /// ray has to reset the progressive renderer.
    pub fn eql(a: Camera, b: Camera) bool {
        return a.yaw == b.yaw and a.pitch == b.pitch and a.distance == b.distance and
            a.fov_degrees == b.fov_degrees and a.target[0] == b.target[0] and
            a.target[1] == b.target[1] and a.target[2] == b.target[2] and
            a.aspect == b.aspect;
    }
};

pub const Scene = struct {
    cubes: [cube_count]geometry.Cube,
    light: light.SpotLight,

    pub const materials = material.palette;

    /// Centre cube plus one cube per face, each touching its neighbour exactly,
    /// like a Minecraft block cross.
    pub fn init() Scene {
        return .{
            .cubes = .{
                geometry.Cube.centered(.{ 0.0, 0.0, 0.0 }, cube_size, emerald),
                geometry.Cube.centered(.{ cube_size, 0.0, 0.0 }, cube_size, amber),
                geometry.Cube.centered(.{ -cube_size, 0.0, 0.0 }, cube_size, sapphire),
                geometry.Cube.centered(.{ 0.0, cube_size, 0.0 }, cube_size, rose_gold),
                geometry.Cube.centered(.{ 0.0, -cube_size, 0.0 }, cube_size, obsidian),
                geometry.Cube.centered(.{ 0.0, 0.0, cube_size }, cube_size, emerald),
                geometry.Cube.centered(.{ 0.0, 0.0, -cube_size }, cube_size, sapphire),
            },
            .light = light.SpotLight.init(
                .{ 3.2, 4.4, -2.4 },
                .{ 0.0, 0.0, 0.0 },
                0.95,
                18.0,
                45.0,
                250.0,
            ),
        };
    }

    pub fn intersect(self: *const Scene, ray: math.Ray, t_limit: f32) ?geometry.Hit {
        var closest: ?geometry.Hit = null;
        var limit = t_limit;
        for (self.cubes) |cube| {
            if (geometry.intersect(cube, ray, limit)) |hit| {
                closest = hit;
                limit = hit.t;
            }
        }
        return closest;
    }

    /// What a ray sees when it leaves the cluster without hitting anything.
    pub fn background(self: *const Scene, ray: math.Ray) Vec3 {
        return self.light.emission(ray);
    }

    /// How much of the light survives travelling from `ray.origin` to
    /// `t_limit`. Opaque cubes block completely; transmissive cubes tint the
    /// shadow instead, which is what puts coloured light on the far faces.
    pub fn shadowTransmittance(self: *const Scene, ray: math.Ray, t_limit: f32) Vec3 {
        var transmittance: Vec3 = @splat(1.0);
        var current = ray;
        var remaining = t_limit;
        var segments: u32 = 0;

        while (segments < 8) : (segments += 1) {
            const hit = self.intersect(current, remaining) orelse return transmittance;
            const m = &Scene.materials[hit.mat_id];
            if (m.transmission <= 0.0) return @splat(0.0);

            const cos_theta = @max(math.dot(current.dir, hit.normal), 0.0);
            const fresnel = material.fresnelSchlick(cos_theta, m.f0());
            transmittance *= (@as(Vec3, @splat(1.0)) - fresnel) * m.absorb(hit.t);

            remaining -= hit.t;
            current = .{
                .origin = hit.point + math.scale(current.dir, 1e-3),
                .dir = current.dir,
            };
        }
        return transmittance;
    }
};
const testing = std.testing;
const std = @import("std");

test "the cluster is a centre cube plus one per face, touching" {
    const s = Scene.init();
    try testing.expectEqual(@as(usize, cube_count), s.cubes.len);

    for (s.cubes) |cube| {
        // Every cube is a unit cube.
        try testing.expectApproxEqAbs(1.0, cube.bounds.max[0] - cube.bounds.min[0], 1e-6);
        try testing.expectApproxEqAbs(1.0, cube.bounds.max[1] - cube.bounds.min[1], 1e-6);
        try testing.expectApproxEqAbs(1.0, cube.bounds.max[2] - cube.bounds.min[2], 1e-6);
    }

    // Each neighbour shares a face with the centre cube, so their separation
    // along that axis is exactly zero.
    const centre = s.cubes[0].bounds;
    for (s.cubes[1..]) |cube| {
        const separation: Vec3 = @max(
            @as(Vec3, @splat(0.0)),
            @max(centre.min - cube.bounds.max, cube.bounds.min - centre.max),
        );
        try testing.expectApproxEqAbs(0.0, math.length(separation), 1e-6);

        // And it sits exactly one unit away along a single axis.
        const offset = math.scale(cube.bounds.min + cube.bounds.max, 0.5);
        var along_one_axis = false;
        inline for (0..3) |axis| {
            if (@abs(offset[axis]) > 0.5) {
                try testing.expectApproxEqAbs(1.0, @abs(offset[axis]), 1e-6);
                along_one_axis = true;
            }
        }
        try testing.expect(along_one_axis);
    }

    // Two neighbours per axis: one on each side.
    var per_axis = [_]u32{0} ** 3;
    for (s.cubes[1..]) |cube| {
        const offset = math.scale(cube.bounds.min + cube.bounds.max, 0.5);
        var on_axis = false;
        inline for (0..3) |axis| {
            if (@abs(offset[axis]) > 0.5) {
                try testing.expectApproxEqAbs(1.0, @abs(offset[axis]), 1e-6);
                per_axis[axis] += 1;
                on_axis = true;
            }
        }
        try testing.expect(on_axis);
    }
    for (per_axis) |count| try testing.expectEqual(@as(u32, 2), count);
}

test "the palette maps onto the cluster with five materials" {
    const s = Scene.init();
    try testing.expectEqual(material.material_count, Scene.materials.len);

    var used = [_]bool{false} ** material.material_count;
    for (s.cubes) |cube| try testing.expect(cube.mat_id < used.len);
    for (s.cubes) |cube| used[cube.mat_id] = true;

    var distinct: usize = 0;
    for (used) |is_used| distinct += @intFromBool(is_used);
    try testing.expectEqual(@as(usize, 5), distinct);
}

test "opaque cubes block shadow rays, glass tints them" {
    const s = Scene.init();

    // Straight down onto the top face of the rose gold cube (metallic, opaque).
    const metal_top = geometry.intersect(s.cubes[rose_gold], .{
        .origin = .{ 0, 5, 0 },
        .dir = .{ 0, -1, 0 },
    }, math.inf).?;

    // Shooting at the metal cube itself blocks completely.
    const blocked = s.shadowTransmittance(.{
        .origin = metal_top.point + @as(Vec3, @splat(0.01)),
        .dir = .{ 0, -1, 0 },
    }, 1.0);
    try testing.expect(math.maxComponent(blocked) == 0.0);

    // A ray that leaves the cluster without crossing anything is fully lit.
    const open = s.shadowTransmittance(.{
        .origin = .{ 0, 4, 0 },
        .dir = .{ 0, 1, 0 },
    }, 5.0);
    try testing.expectApproxEqAbs(1.0, math.maxComponent(open), 1e-5);
}

test "background is black away from the emitter" {
    const s = Scene.init();
    const sky = s.background(.{ .origin = .{ 0, 0, 6 }, .dir = .{ 0, 0, 1 } });
    try testing.expect(math.maxComponent(sky) == 0.0);
}

test "camera rays point at the target and eql detects movement" {
    const camera = Camera{};
    const ray = camera.ray(.{ 0, 0 });
    const to_target = math.normalize(camera.target - camera.position());
    try testing.expectApproxEqAbs(1.0, math.dot(ray.dir, to_target), 1e-5);

    var moved = camera;
    moved.yaw += 0.1;
    try testing.expect(!Camera.eql(camera, moved));
    try testing.expect(Camera.eql(camera, camera));
}
