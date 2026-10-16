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

        // Soft radial profile instead of a hard disk edge: a bigger apparent
        // source means far less variance in the refracted highlights.
        const on_disk = ray.origin + math.scale(ray.dir, distance);
        const radial = math.length(on_disk - self.position) / self.radius;
        if (radial >= 1.0) return @splat(0.0);
        const profile = 1.0 - radial * radial;
        return @as(Vec3, @splat(self.radiance() * profile * profile));
    }
};