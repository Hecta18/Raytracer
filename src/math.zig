//! Math helpers for the raytracer. Vectors are SIMD vectors so the inner loop
//! vectorizes; every function here is small enough to inline.
const std = @import("std");

pub const Vec2 = @Vector(2, f32);
pub const Vec3 = @Vector(3, f32);
pub const Vec4 = @Vector(4, f32);

pub const inf = std.math.inf(f32);
pub const pi = std.math.pi;

pub const Ray = struct {
    origin: Vec3,
    dir: Vec3,
};

/// Zig 0.16 no longer broadcasts a scalar into a vector implicitly, and the old
/// `v.*scalar` syntax is gone too, so component-wise scaling gets a name.
pub inline fn scale(vector: Vec3, scalar: f32) Vec3 {
    return vector * @as(Vec3, @splat(scalar));
}

pub inline fn divide(vector: Vec3, scalar: f32) Vec3 {
    return vector / @as(Vec3, @splat(scalar));
}

pub inline fn dot(a: Vec3, b: Vec3) f32 {
    return @reduce(.Add, a * b);
}

pub inline fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

pub inline fn lengthSquared(v: Vec3) f32 {
    return dot(v, v);
}

pub inline fn length(v: Vec3) f32 {
    return @sqrt(dot(v, v));
}

pub inline fn normalize(v: Vec3) Vec3 {
    return divide(v, @sqrt(dot(v, v)));
}

pub inline fn maxComponent(v: Vec3) f32 {
    return @reduce(.Max, v);
}

pub inline fn minComponent(v: Vec3) f32 {
    return @reduce(.Min, v);
}

/// Mirror direction: d - 2(d.n)n
pub inline fn reflect(d: Vec3, n: Vec3) Vec3 {
    return d - scale(n, 2.0 * dot(d, n));
}

pub inline fn clamp(value: f32, low: f32, high: f32) f32 {
    return @max(low, @min(value, high));
}

pub inline fn saturate(value: f32) f32 {
    return clamp(value, 0.0, 1.0);
}

pub inline fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = saturate((x - edge0) / (edge1 - edge0));
    return t * t * (3.0 - 2.0 * t);
}

pub const Aabb = struct {
    min: Vec3,
    max: Vec3,

    pub fn centered(center: Vec3, half_extent: f32) Aabb {
        const half: Vec3 = @splat(half_extent);
        return .{ .min = center - half, .max = center + half };
    }

    /// Slab test: clip the ray against the three pairs of parallel planes that
    /// make up the box. t_min tracks the entry parameter and t_max the exit
    /// parameter; a swap per axis lets the same code handle rays that start
    /// inside the box, which matters for rays travelling through glass.
    pub fn intersect(self: Aabb, ray: Ray, t_limit: f32) ?f32 {
        var t_min: f32 = 0.0;
        var t_max: f32 = t_limit;

        inline for (0..3) |axis| {
            const inv = 1.0 / ray.dir[axis];
            var t0 = (self.min[axis] - ray.origin[axis]) * inv;
            var t1 = (self.max[axis] - ray.origin[axis]) * inv;
            if (t0 > t1) std.mem.swap(f32, &t0, &t1);
            t_min = @max(t_min, t0);
            t_max = @min(t_max, t1);
            if (t_max < t_min) return null;
        }
        return t_min;
    }
};

/// PCG32. Cheap, decent distribution, and every worker gets its own stream.
pub const Rng = struct {
    state: u64,
    inc: u64,

    pub fn init(seed: u64) Rng {
        var rng = Rng{ .state = 0, .inc = (seed << 1) | 1 };
        _ = rng.nextU32();
        rng.state +%= seed;
        _ = rng.nextU32();
        return rng;
    }

    pub fn nextU32(self: *Rng) u32 {
        const old = self.state;
        self.state = old *% 6364136223846793005 +% self.inc;
        const xorshifted: u32 = @truncate((old >> 18) ^ old);
        const rot: u32 = @intCast(old >> 59);
        return std.math.rotl(u32, xorshifted, rot);
    }

    /// Uniform in [0, 1).
    pub fn float(self: *Rng) f32 {
        return @as(f32, @floatFromInt(self.nextU32() >> 8)) * (1.0 / 16777216.0);
    }

    /// Uniform point on the unit sphere.
    pub fn unitVector(self: *Rng) Vec3 {
        const z = 2.0 * self.float() - 1.0;
        const r = @sqrt(@max(0.0, 1.0 - z * z));
        const phi = 2.0 * pi * self.float();
        return .{ r * @cos(phi), r * @sin(phi), z };
    }
};

/// Radical inverse in the given base: a low discrepancy sequence used to jitter
/// the pixel sample position, which antialiases far better than random jitter.
pub fn halton(index: u32, base: u32) f32 {
    var result: f32 = 0.0;
    var fraction: f32 = 1.0;
    var i = index;
    while (i > 0) {
        fraction /= @floatFromInt(base);
        result += fraction * @as(f32, @floatFromInt(i % base));
        i /= base;
    }
    return result;
}

/// std.time.Timer is gone in Zig 0.16, so read the monotonic clock through libc.
pub fn nowNanos() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + @as(i64, ts.nsec);
}

/// std.Thread.sleep moved behind std.Io in 0.16; libc nanosleep keeps the
/// renderer free of Io plumbing.
pub fn sleepMicros(microseconds: u32) void {
    const request: std.c.timespec = .{
        .sec = @intCast(microseconds / std.time.us_per_s),
        .nsec = @intCast((microseconds % std.time.us_per_s) * std.time.ns_per_us),
    };
    _ = std.c.nanosleep(&request, null);
}