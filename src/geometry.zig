//! Ray/primitive intersection. Only the primitive the diorama needs is here.
const math = @import("math.zig");

const Aabb = math.Aabb;
const Ray = math.Ray;
const Vec3 = math.Vec3;

pub const Hit = struct {
    /// Distance along the ray.
    t: f32,
    point: Vec3,
    /// Always oriented against the incoming ray, so dot(dir, normal) < 0.
    normal: Vec3,
    /// True when the ray entered the primitive rather than leaving it.
    front_face: bool,
    mat_id: u32,
    /// Face local coordinates in [0, 1]; each material samples its own texture
    /// with these.
    uv: math.Vec2,
};

pub const Cube = struct {
    bounds: Aabb,
    mat_id: u32,

    pub fn centered(center: Vec3, size: f32, mat_id: u32) Cube {
        return .{ .bounds = Aabb.centered(center, size * 0.5), .mat_id = mat_id };
    }
};

pub fn intersect(cube: Cube, ray: Ray, t_limit: f32) ?Hit {
    const t = cube.bounds.intersect(ray, t_limit) orelse return null;
    const point = ray.origin + math.scale(ray.dir, t);

    // The face is whichever of the six is closest to the hit point, so exactly
    // one axis gets a normal. Works for rays that start inside the box too.
    var face_axis: usize = 0;
    var face_sign: f32 = 1.0;
    var closest: f32 = math.inf;
    inline for (0..3) |axis| {
        const from_min = @abs(point[axis] - cube.bounds.min[axis]);
        if (from_min < closest) {
            closest = from_min;
            face_axis = axis;
            face_sign = -1.0;
        }
        const from_max = @abs(point[axis] - cube.bounds.max[axis]);
        if (from_max < closest) {
            closest = from_max;
            face_axis = axis;
            face_sign = 1.0;
        }
    }
    const normal: Vec3 = switch (face_axis) {
        0 => .{ face_sign, 0.0, 0.0 },
        1 => .{ 0.0, face_sign, 0.0 },
        else => .{ 0.0, 0.0, face_sign },
    };

    const uv: math.Vec2 = switch (face_axis) {
        0 => faceUv(point, cube.bounds, 1, 2),
        1 => faceUv(point, cube.bounds, 0, 2),
        else => faceUv(point, cube.bounds, 0, 1),
    };

    const front_face = math.dot(ray.dir, normal) < 0;
    return .{
        .t = t,
        .point = point,
        .normal = if (front_face) normal else -normal,
        .front_face = front_face,
        .mat_id = cube.mat_id,
        .uv = uv,
    };
}
/// Face local coordinates of a point on an axis aligned box, for the two axes
/// that are not the face normal.
fn faceUv(point: Vec3, bounds: Aabb, comptime u_axis: usize, comptime v_axis: usize) math.Vec2 {
    const size_u = bounds.max[u_axis] - bounds.min[u_axis];
    const size_v = bounds.max[v_axis] - bounds.min[v_axis];
    return .{
        (point[u_axis] - bounds.min[u_axis]) / size_u,
        (point[v_axis] - bounds.min[v_axis]) / size_v,
    };
}
