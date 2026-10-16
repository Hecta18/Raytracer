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
    /// make up the box. A ray that starts inside has no entry point, so the exit
    /// is returned instead; that case matters because rays travel through glass.
    pub fn intersect(self: Aabb, ray: Ray, t_limit: f32) ?f32 {
        var t_enter: f32 = -inf;
        var t_exit: f32 = t_limit;

        inline for (0..3) |axis| {
            const inv = 1.0 / ray.dir[axis];
            var t0 = (self.min[axis] - ray.origin[axis]) * inv;
            var t1 = (self.max[axis] - ray.origin[axis]) * inv;
            if (t0 > t1) std.mem.swap(f32, &t0, &t1);
            t_enter = @max(t_enter, t0);
            t_exit = @min(t_exit, t1);
            if (t_exit < t_enter) return null;
        }
        // A ray that starts inside has no entry point and leaves at t_exit;
        // either way the hit has to be in front of the origin.
        const t = if (t_enter > 0.0) t_enter else t_exit;
        if (t < 0.0) return null;
        return t;
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
const testing = std.testing;

fn expectApprox(expected: f32, actual: f32, tolerance: f32) !void {
    try testing.expectApproxEqAbs(expected, actual, tolerance);
}

test "AABB hits from outside, inside and from behind" {
    const box = Aabb.centered(.{ 0, 0, 0 }, 1.0);

    const hit = box.intersect(.{ .origin = .{ -4, 0, 0 }, .dir = .{ 1, 0, 0 } }, inf).?;
    try expectApprox(3.0, hit, 1e-4);

    // Starting inside must report the exit, not the origin.
    const inside = box.intersect(.{ .origin = .{ 0, 0, 0 }, .dir = .{ 1, 0, 0 } }, inf).?;
    try expectApprox(1.0, inside, 1e-4);

    try testing.expect(box.intersect(.{ .origin = .{ -4, 3, 0 }, .dir = .{ 1, 0, 0 } }, inf) == null);
}

test "reflect and normalize" {
    const n: Vec3 = .{ 0, 1, 0 };
    // Mirroring about y flips the vertical component and keeps the tangent one.
    const bounced = reflect(.{ 1, -1, 0 }, n);
    try expectApprox(1.0, bounced[0], 1e-5);
    try expectApprox(1.0, bounced[1], 1e-5);
    try expectApprox(1.0, length(normalize(.{ 3, 4, 0 })), 1e-6);
    try expectApprox(25.0, dot(.{ 3, 4, 0 }, .{ 3, 4, 0 }), 1e-5);
}

test "clamp and smoothstep" {
    try expectApprox(1.0, saturate(2.0), 1e-6);
    try expectApprox(0.0, saturate(-2.0), 1e-6);
    try expectApprox(0.5, smoothstep(0.0, 1.0, 0.5), 1e-6);
    try expectApprox(0.0, smoothstep(0.0, 1.0, -1.0), 1e-6);
    try expectApprox(1.0, smoothstep(0.0, 1.0, 2.0), 1e-6);
}

test "Rng stays in range and varies" {
    var rng = Rng.init(42);
    var sum: f64 = 0;
    var buckets = [_]u32{0} ** 4;
    for (0..20_000) |_| {
        const value = rng.float();
        try testing.expect(value >= 0.0 and value < 1.0);
        sum += value;
        buckets[@intFromFloat(value * 4)] += 1;
    }
    // A uniform stream averages 0.5 and fills every quarter of the range.
    try testing.expectApproxEqAbs(0.5, sum / 20_000, 0.01);
    for (buckets) |count| try testing.expect(count > 20_000 / 4 * 0.9);
}

test "halton covers the unit interval" {
    for (1..500) |index| {
        const value = halton(@intCast(index), 2);
        try testing.expect(value >= 0.0 and value < 1.0);
    }
    // Radical inverses: 2 is '10' in base two (0.01) and '2' in base three.
    try expectApprox(0.25, halton(2, 2), 1e-6);
    try expectApprox(0.75, halton(3, 2), 1e-6);
    try expectApprox(2.0 / 3.0, halton(2, 3), 1e-6);
}

test "nowNanos is monotonic" {
    const first = nowNanos();
    const second = nowNanos();
    try testing.expect(second >= first);
}
