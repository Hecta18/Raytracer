//! Materials. Every material owns its albedo, specular response, transparency
//! and reflectivity, plus its own procedural texture function.
const std = @import("std");
const math = @import("math.zig");
const geometry = @import("geometry.zig");

const Vec3 = math.Vec3;
const pi = math.pi;

pub const Material = struct {
    name: []const u8,
    /// Base colour for the diffuse lobe and the reflection tint of metals.
    albedo: Vec3,
    /// Scale of the specular lobe for dielectrics.
    specular: f32,
    /// GGX roughness, 0 = mirror.
    roughness: f32,
    /// 1 for metals: no diffuse lobe, albedo becomes the F0 colour.
    metallic: f32,
    /// 0 = opaque, 1 = fully refractive.
    transmission: f32,
    ior: f32,
    /// Normal incidence reflectance of the dielectric lobe.
    reflectivity: f32,
    /// Beer-Lambert absorption per unit distance, per channel. This is what
    /// tints thick glass emerald green instead of merely darkening it.
    absorption: Vec3,
    texture: TextureFn,

    /// Normal incidence reflectance: metals tint it, dielectrics use the stored
    /// reflectivity so obsidian can mirror while plain glass barely does.
    pub fn f0(self: Material) Vec3 {
        if (self.metallic > 0.5) return self.albedo;
        return @as(Vec3, @splat(math.clamp(self.reflectivity * self.specular, 0.0, 1.0)));
    }

    /// Beer-Lambert: light travelling `distance` inside the medium keeps
    /// exp(-sigma * distance) of each channel, so thin glass stays bright and
    /// thick glass saturates towards the tint.
    pub fn absorb(self: Material, distance: f32) Vec3 {
        return @exp(math.scale(self.absorption, -distance));
    }
};

pub const TextureFn = *const fn (hit: geometry.Hit) Vec3;

pub const material_count = 5;

pub inline fn fresnelSchlick(cos_theta: f32, f0_value: Vec3) Vec3 {
    const one: Vec3 = @splat(1.0);
    return f0_value + (one - f0_value) * @as(Vec3, @splat(std.math.pow(f32, 1.0 - math.clamp(cos_theta, 0.0, 1.0), 5.0)));
}

pub inline fn ggxDistribution(n_dot_h: f32, alpha: f32) f32 {
    const a2 = alpha * alpha;
    const d = n_dot_h * n_dot_h * (a2 - 1.0) + 1.0;
    return a2 / (pi * d * d);
}

/// Height correlated Smith masking, Schlick-GGX approximation.
pub inline fn smithG(n_dot_v: f32, n_dot_l: f32, alpha: f32) f32 {
    const k = alpha * 0.5;
    const gv = n_dot_v / (n_dot_v * (1.0 - k) + k);
    const gl = n_dot_l / (n_dot_l * (1.0 - k) + k);
    return gv * gl;
}

pub fn specularBRDF(self: Material, n: Vec3, view: Vec3, light_dir: Vec3) f32 {
    const h = math.normalize(view + light_dir);
    const alpha = @max(self.roughness * self.roughness, 1e-3);
    const d = ggxDistribution(@max(math.dot(n, h), 0.0), alpha);
    const g = smithG(@max(math.dot(n, view), 1e-4), @max(math.dot(n, light_dir), 1e-4), alpha);
    const f = math.maxComponent(fresnelSchlick(@max(math.dot(view, h), 0.0), self.f0()));
    return d * g * f / (4.0 * @max(math.dot(n, view), 1e-4) * @max(math.dot(n, light_dir), 1e-4));
}

/// Snell's law. Returns null on total internal reflection.
pub fn refract(direction: Vec3, normal: Vec3, eta: f32) ?Vec3 {
    const cos_theta = -math.dot(direction, normal);
    const sin2_theta = 1.0 - cos_theta * cos_theta;
    if (sin2_theta > eta * eta) return null;
    const cos_refracted = @sqrt(@max(0.0, 1.0 - sin2_theta / (eta * eta)));
    return math.scale(direction, eta) + math.scale(normal, eta * cos_theta - cos_refracted);
}

/// GGX visible normal sampling (Heitz 2018). Returns a half vector biased
/// towards the view direction, which keeps rough reflections energy conserving.
pub fn sampleGGXHalfVector(view: Vec3, normal: Vec3, roughness: f32, rng: *math.Rng) Vec3 {
    const alpha = @max(roughness * roughness, 1e-3);
    const helper: Vec3 = if (@abs(normal[2]) < 0.999) .{ 0.0, 0.0, 1.0 } else .{ 1.0, 0.0, 0.0 };
    const tangent = math.normalize(math.cross(helper, normal));
    const bitangent = math.cross(normal, tangent);

    var vh: Vec3 = .{ math.dot(view, tangent), math.dot(view, bitangent), math.dot(view, normal) };
    if (vh[2] < 0.0) vh = -vh;

    const length_sq = vh[0] * vh[0] + vh[1] * vh[1];
    var t1: Vec3 = undefined;
    if (length_sq > 0.0) {
        const scale = @sqrt(length_sq) / length_sq;
        t1 = .{ -vh[1] * scale, vh[0] * scale, 0.0 };
    } else {
        t1 = .{ 1.0, 0.0, 0.0 };
    }
    t1 = .{ alpha * t1[0], alpha * t1[1], 0.0 };
    const t2 = math.normalize(Vec3{ vh[2] * t1[0], vh[2] * t1[1], length_sq * alpha });

    const r = @sqrt(rng.float());
    const phi = 2.0 * pi * rng.float();
    const p1 = r * @cos(phi);
    const p2_circle = r * @sin(phi);
    // Blend towards the mirror lobe as the view direction becomes grazing.
    const s = 0.5 * (1.0 + vh[2]);
    const p2 = (1.0 - s) * @sqrt(@max(0.0, 1.0 - p1 * p1)) + s * p2_circle;

    // t1 and t2 lie in the tangent plane, so only the z term carries the
    // normal component.
    const n_z = @sqrt(@max(0.0, 1.0 - p1 * p1 - p2 * p2));
    const tangent_plane = math.scale(t1, p1) + math.scale(t2, p2);
    const half_vector: Vec3 = .{
        tangent[0] * tangent_plane[0] + normal[0] * n_z,
        tangent[1] * tangent_plane[0] + normal[1] * n_z,
        tangent[2] * tangent_plane[0] + normal[2] * n_z,
    };
    return math.normalize(half_vector);
}

fn hash3(x: i32, y: i32, z: i32) f32 {
    var h: u32 = @as(u32, @bitCast(x)) *% 0x8da6b343 +% @as(u32, @bitCast(y)) *% 0xd8163841 +% @as(u32, @bitCast(z)) *% 0xcb1ab31f;
    h = (h ^ (h >> 16)) *% 0x7feb352d;
    h = (h ^ (h >> 15)) *% 0x846ca68b;
    h = h ^ (h >> 16);
    return @as(f32, @floatFromInt(h >> 8)) * (1.0 / 16777216.0);
}

/// Trilinear value noise; the building block for the stone and metal textures.
fn valueNoise(p: math.Vec3) f32 {
    const base: math.Vec3 = @floor(p);
    const f = p - base;
    const smooth = f * f * (@as(Vec3, @splat(3.0)) - math.scale(f, 2.0));
    const x: i32 = @intFromFloat(base[0]);
    const y: i32 = @intFromFloat(base[1]);
    const z: i32 = @intFromFloat(base[2]);

    var result: f32 = 0;
    inline for (0..2) |dz| {
        inline for (0..2) |dy| {
            inline for (0..2) |dx| {
                const weight = (if (dx == 0) 1.0 - smooth[0] else smooth[0]) *
                    (if (dy == 0) 1.0 - smooth[1] else smooth[1]) *
                    (if (dz == 0) 1.0 - smooth[2] else smooth[2]);
                result += weight * hash3(x + @as(i32, @intCast(dx)), y + @as(i32, @intCast(dy)), z + @as(i32, @intCast(dz)));
            }
        }
    }
    return result;
}

fn octaves(p: math.Vec3) f32 {
    return 0.6 * valueNoise(p) +
        0.3 * valueNoise(math.scale(p, 2.1) + @as(Vec3, @splat(7.3))) +
        0.1 * valueNoise(math.scale(p, 4.3) + @as(Vec3, @splat(19.1)));
}

const shade = Vec3{ 0.85, 0.85, 0.85 };
const brighten = Vec3{ 0.25, 0.25, 0.25 };

/// Cloudy inclusions suspended in the stone.
fn textureEmerald(hit: geometry.Hit) Vec3 {
    return shade + brighten * @as(Vec3, @splat(octaves(math.scale(hit.point, 7.0))));
}

/// Growth rings frozen into the resin.
fn textureAmber(hit: geometry.Hit) Vec3 {
    const radius = @sqrt(hit.uv[0] * hit.uv[0] + hit.uv[1] * hit.uv[1]);
    return shade + brighten * @as(Vec3, @splat(0.5 + 0.5 * @sin(radius * 26.0)));
}

/// Fine internal speckle.
fn textureSapphire(hit: geometry.Hit) Vec3 {
    return shade + brighten * @as(Vec3, @splat(octaves(math.scale(hit.point, 22.0))));
}

/// Brushed anisotropic streaks along u.
fn textureRoseGold(hit: geometry.Hit) Vec3 {
    const streak = 0.5 + 0.5 * @sin(hit.uv[0] * 140.0);
    return shade + @as(Vec3, @splat(0.25 * streak));
}

/// Volcanic swirl.
fn textureObsidian(hit: geometry.Hit) Vec3 {
    const swirl = @sin(hit.point[0] * 5.0 + hit.point[1] * 3.0) * @sin(hit.point[2] * 6.0 - hit.point[1] * 2.0);
    return shade + @as(Vec3, @splat(0.2 * swirl));
}

/// Five materials, shared by the seven cubes. Glass family: three coloured
/// transmissive stones, one coloured metal, one dark glossy volcanic glass.
pub const palette = [_]Material{
    .{
        .name = "emerald",
        .albedo = .{ 0.05, 0.35, 0.18 },
        .specular = 1.0,
        .roughness = 0.15,
        .metallic = 0.0,
        .transmission = 0.8,
        .ior = 1.577,
        .reflectivity = 0.06,
        .absorption = .{ 4.2, 0.5, 3.4 },
        .texture = textureEmerald,
    },
    .{
        .name = "amber",
        .albedo = .{ 0.55, 0.25, 0.03 },
        .specular = 1.0,
        .roughness = 0.18,
        .metallic = 0.0,
        .transmission = 0.78,
        .ior = 1.55,
        .reflectivity = 0.05,
        .absorption = .{ 0.5, 3.2, 9.0 },
        .texture = textureAmber,
    },
    .{
        .name = "sapphire",
        .albedo = .{ 0.04, 0.12, 0.45 },
        .specular = 1.0,
        .roughness = 0.13,
        .metallic = 0.0,
        .transmission = 0.82,
        .ior = 1.77,
        .reflectivity = 0.08,
        .absorption = .{ 9.5, 5.0, 0.7 },
        .texture = textureSapphire,
    },
    .{
        .name = "rose_gold",
        .albedo = .{ 0.94, 0.55, 0.45 },
        .specular = 1.0,
        .roughness = 0.15,
        .metallic = 1.0,
        .transmission = 0.0,
        .ior = 2.2,
        .reflectivity = 0.9,
        .absorption = @as(Vec3, @splat(0.0)),
        .texture = textureRoseGold,
    },
    .{
        .name = "obsidian",
        .albedo = .{ 0.02, 0.02, 0.025 },
        .specular = 1.0,
        .roughness = 0.1,
        .metallic = 0.0,
        .transmission = 0.12,
        .ior = 1.49,
        .reflectivity = 0.55,
        .absorption = .{ 9.0, 9.0, 9.0 },
        .texture = textureObsidian,
    },
};