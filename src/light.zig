//! A spot light with a penumbra. Two effects make it read as a real fixture
//! rather than a point light: the smooth cone falloff across the inner and
//! outer angles, and a finite emitter radius that softens shadow edges.
const std = @import("std");
const math = @import("math.zig");

const Vec3 = math.Vec3;

pub const SpotLight = struct {
    position: Vec3,
    target: Vec3,
    /// Radius of the emitter disk. Shadow edges sharpen as this goes to zero.
    radius: f32,
    /// cos of the inner/outer cone angles; outer <= inner.
    inner_cos: f32,
    outer_cos: f32,
    intensity: f32,

    pub fn init(position: Vec3, target: Vec3, radius: f32, inner_degrees: f32, outer_degrees: f32, intensity: f32) SpotLight {
        return .{
            .position = position,
            .target = target,
            .radius = radius,
            .inner_cos = @cos(inner_degrees * std.math.pi / 180.0),
            .outer_cos = @cos(outer_degrees * std.math.pi / 180.0),
            .intensity = intensity,
        };
    }

    pub fn axis(self: SpotLight) Vec3 {
        return math.normalize(self.target - self.position);
    }

    /// Uniform point on the emitter disk, facing along the cone axis.
    pub fn sample(self: SpotLight, rng: *math.Rng) Vec3 {
        const cone_axis = self.axis();
        const helper: Vec3 = if (@abs(cone_axis[2]) < 0.999) .{ 0.0, 0.0, 1.0 } else .{ 1.0, 0.0, 0.0 };
        const tangent = math.normalize(math.cross(helper, cone_axis));
        const bitangent = math.cross(cone_axis, tangent);

        const radius = self.radius * @sqrt(rng.float());
        const phi = 2.0 * math.pi * rng.float();
        return self.position + math.scale(tangent, radius * @cos(phi)) + math.scale(bitangent, radius * @sin(phi));
    }

    /// Smooth cone falloff times inverse square distance. The smoothstep is the
    /// penumbra: light fades across the outer angle instead of stopping dead.
    pub fn attenuation(self: SpotLight, to_point: Vec3) f32 {
        const offset = to_point - self.position;
        const distance_squared = @max(math.lengthSquared(offset), 1e-4);
        const cos_angle = math.dot(math.divide(offset, @sqrt(distance_squared)), self.axis());
        const cone = math.smoothstep(self.outer_cos, self.inner_cos, cos_angle);
        if (cone <= 0.0) return 0.0;
        return self.intensity * cone / distance_squared;
    }

    /// Radiance of the emitter itself, per unit area. Kept consistent with
    /// `attenuation`: intensity / (pi * r^2) turns the direct term back into
    /// L * area * cos / d^2.
    pub fn radiance(self: SpotLight) f32 {
        return self.intensity / (math.pi * self.radius * self.radius);
    }

    /// Light carried by a ray that reached the fixture without hitting the
    /// scene. Intersecting the emitter disk analytically means the light stays
    /// out of the scene graph while glass and mirrors can still pick it up,
    /// which is what makes the refracted core of a gem glow.
    pub fn emission(self: SpotLight, ray: math.Ray) Vec3 {
        const cone_axis = self.axis();
        const denominator = math.dot(ray.dir, cone_axis);
        if (@abs(denominator) < 1e-6) return @splat(0.0);

        const distance = math.dot(self.position - ray.origin, cone_axis) / denominator;
        if (distance <= 0.0) return @splat(0.0);

        // Only the lit face emits, so a ray that reaches the disk from behind
        // the fixture gets nothing.
        if (-denominator <= 0.0) return @splat(0.0);

        // Soft radial profile instead of a hard disk edge: a bigger apparent
        // source means far less variance in the refracted highlights.
        const on_disk = ray.origin + math.scale(ray.dir, distance);
        const radial = math.length(on_disk - self.position) / self.radius;
        if (radial >= 1.0) return @splat(0.0);
        const profile = 1.0 - radial * radial;
        return @as(Vec3, @splat(self.radiance() * profile * profile));
    }
};
const testing = std.testing;

test "cone falloff is smooth and bounded by the cone angles" {
    const lamp = SpotLight.init(.{ 0, 4, 0 }, .{ 0, 0, 0 }, 0.5, 10.0, 40.0, 100.0);

    const on_axis = lamp.attenuation(.{ 0, 0, 0 });
    const inside_inner = lamp.attenuation(.{ 0.3, 0, 0 });
    const outside_cone = lamp.attenuation(.{ 4, 0, 0 });

    try testing.expect(on_axis > 0.0);
    // Inside the inner angle the falloff is flat: that is what keeps the hot
    // centre of a real spot clean.
    try testing.expectApproxEqAbs(on_axis, inside_inner, on_axis * 0.02);
    try testing.expect(outside_cone == 0.0);

    // Penumbra: inside the cone but past the inner angle the light fades
    // instead of cutting off.
    const edge = math.normalize(.{ 1, -4, 0 });
    const penumbra = lamp.attenuation(math.scale(edge, 4.0));
    try testing.expect(penumbra > 0.0 and penumbra < on_axis);
}

test "inverse square falloff" {
    const lamp = SpotLight.init(.{ 0, 10, 0 }, .{ 0, 0, 0 }, 0.5, 10.0, 80.0, 100.0);
    const near = lamp.attenuation(.{ 0, 5, 0 });
    const far = lamp.attenuation(.{ 0, 0, 0 });
    try testing.expectApproxEqAbs(near / 4.0, far, far * 0.02);
}

test "emitter samples stay on the disk and rays can hit it" {
    const lamp = SpotLight.init(.{ 0, 5, 0 }, .{ 0, 0, 0 }, 0.5, 10.0, 80.0, 100.0);
    var rng = math.Rng.init(3);

    var hits: u32 = 0;
    for (0..2000) |_| {
        const point = lamp.sample(&rng);
        const on_disk = math.length(point - lamp.position);
        try testing.expect(on_disk <= lamp.radius + 1e-4);

        // Aim a ray from the origin back at that point: it must hit the disk.
        const ray: math.Ray = .{ .origin = .{ 0, 0, 0 }, .dir = math.normalize(point - @as(Vec3, @splat(0.0))) };
        if (math.maxComponent(lamp.emission(ray)) > 0.0) hits += 1;
    }
    try testing.expect(hits > 1500);

    // A ray pointing away from the light carries nothing.
    try testing.expect(math.maxComponent(lamp.emission(.{ .origin = .{ 0, 0, 0 }, .dir = .{ 0, 0, -1 } })) == 0.0);
}

test "radiance and the direct term agree on the emitter strength" {
    const lamp = SpotLight.init(.{ 0, 5, 0 }, .{ 0, 0, 0 }, 0.75, 20.0, 60.0, 90.0);
    // intensity / (pi * r^2) is the emitted radiance, and multiplying it back
    // by the disk area has to return the original intensity.
    try testing.expectApproxEqAbs(
        lamp.intensity,
        lamp.radiance() * math.pi * lamp.radius * lamp.radius,
        1e-3,
    );
}
