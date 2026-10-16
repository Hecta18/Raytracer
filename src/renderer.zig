//! Tile based, multi threaded path tracer.
//!
//! A frame is split into tiles that any thread can claim. Workers keep pulling
//! tiles until the frame finishes or the per frame time budget runs out, so the
//! window stays responsive on a slow CPU. Finished frames are published as
//! they complete and every camera change starts a fresh progressive
//! accumulation, which is what turns a noisy 1 spp image into a clean one while
//! the scene sits still.
const std = @import("std");
const math = @import("math.zig");
const geometry = @import("geometry.zig");
const material = @import("material.zig");
const scene = @import("scene.zig");

const Scene = scene.Scene;
const Camera = scene.Camera;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;

pub const Config = struct {
    width: usize = 480,
    height: usize = 270,
    /// Worker threads. 0 means one less than the hardware thread count.
    worker_count: usize = 0,
    tile_size: usize = 32,
    max_depth: u32 = 8,
    /// Stop refining the image after this many accumulated samples.
    max_samples: u32 = 96,
    /// Workers stop claiming new tiles once this budget is spent.
    frame_budget_ms: u32 = 12,
    ray_epsilon: f32 = 1e-3,
    shadow_epsilon: f32 = 3e-3,
    /// Single sample clamp. The emitter is tiny in solid angle, so an unlucky
    /// refracted ray can land on it and blow out the whole average otherwise.
    firefly_clamp: f32 = 5.0,
};

/// How strongly transmission lighting bleeds through a translucent material.
const translucency_gain: f32 = 0.75;

const Claim = struct {
    tile: u32,
    buffer: usize,
    camera: Camera,
};

/// std.Io.Mutex needs an Io instance; every critical section here is a handful
/// of instructions, so a test-and-set lock with backoff is enough and keeps the
/// renderer independent of the Io plumbing. Backing off matters: with one
/// thread per core, a plain spin loop lets one thread win the lock forever and
/// starve the worker whose `finish` call everyone else is waiting on.
const SpinLock = struct {
    state: std.atomic.Value(u32) = .init(0),

    pub fn lock(self: *SpinLock) void {
        var spins: u32 = 0;
        while (self.state.swap(1, .acquire) != 0) {
            if (spins < 64) {
                spins += 1;
                std.atomic.spinLoopHint();
            } else {
                math.sleepMicros(20);
            }
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.state.store(0, .release);
    }
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    cfg: Config,
    scene: *const Scene,

    /// Two accumulation buffers: xyz holds the radiance sum, w the number of
    /// samples that went into it. Having the count per pixel makes the resolve
    /// correct even while the next frame is already being traced.
    accum: [2][]Vec4,
    out: []u8,
    tiles_x: u32,
    tiles_y: u32,

    // Everything below is guarded by `lock`.
    lock: SpinLock = .{},
    camera: Camera,
    active: usize = 0,
    next_tile: u32 = 0,
    done_tiles: u32 = 0,
    completed: u32 = 0,
    invalidated: bool = false,
    /// Read without the lock by the drain in `beginInvalidation`, so it never
    /// competes with the workers that have to finish a tile to release it.
    inflight: std.atomic.Value(u32) = .init(0),

    // Read outside the lock by the main thread.
    published: std.atomic.Value(u32) = .init(0),
    deadline: std.atomic.Value(i64) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),

    workers: []std.Thread,

    pub fn init(allocator: std.mem.Allocator, config: Config, scene_ptr: *const Scene) !*Renderer {
        var cfg = config;
        if (cfg.worker_count == 0) {
            const cpus = std.Thread.getCpuCount() catch 4;
            cfg.worker_count = @max(cpus - 1, 1);
        }

        const self = try allocator.create(Renderer);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .cfg = cfg,
            .scene = scene_ptr,
            .accum = .{ &.{}, &.{} },
            .out = &.{},
            .tiles_x = 0,
            .tiles_y = 0,
            .camera = .{},
            .workers = &.{},
        };
        self.updateTileGrid();
        try self.allocateBuffers();
        errdefer self.freeBuffers();

        self.workers = try allocator.alloc(std.Thread, cfg.worker_count);
        errdefer allocator.free(self.workers);
        for (self.workers, 0..) |*thread, id| {
            thread.* = try std.Thread.spawn(.{}, workerMain, .{ self, id });
        }
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        self.stop.store(true, .release);
        for (self.workers) |thread| thread.join();
        self.allocator.free(self.workers);
        self.freeBuffers();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// Swaps in buffers of a new size. The replacements are allocated before
/// anything is torn down, so a failure here leaves the renderer usable.
pub fn resize(self: *Renderer, new_width: usize, new_height: usize) !void {
        if (new_width == self.cfg.width and new_height == self.cfg.height) return;

        const pixel_count = new_width * new_height;
        const accum0 = try self.allocator.alloc(Vec4, pixel_count);
        errdefer self.allocator.free(accum0);
        const accum1 = try self.allocator.alloc(Vec4, pixel_count);
        errdefer self.allocator.free(accum1);
        const out = try self.allocator.alloc(u8, pixel_count * 4);
        errdefer self.allocator.free(out);

        const zero: Vec4 = .{ 0.0, 0.0, 0.0, 0.0 };
        @memset(accum0, zero);
        @memset(accum1, zero);
        @memset(out, 0);

        self.beginInvalidation();
        defer self.endInvalidation();

        self.freeBuffers();
        self.accum = .{ accum0, accum1 };
        self.out = out;
        self.cfg.width = new_width;
        self.cfg.height = new_height;
        self.updateTileGrid();
    }

    pub fn width(self: *const Renderer) usize {
        return self.cfg.width;
    }

    pub fn height(self: *const Renderer) usize {
        return self.cfg.height;
    }

    pub fn maxSamples(self: *const Renderer) u32 {
        return self.cfg.max_samples;
    }

    pub fn workerCount(self: *const Renderer) usize {
        return self.workers.len;
    }

    /// Samples accumulated into the current image.
    pub fn samples(self: *const Renderer) u32 {
        return self.published.load(.acquire);
    }

    pub fn converged(self: *const Renderer) bool {
        return self.samples() >= self.cfg.max_samples;
    }

    pub fn setFrameBudget(self: *Renderer, budget_ms: u32) void {
        self.deadline.store(math.nowNanos() + @as(i64, budget_ms) * std.time.ns_per_ms, .release);
    }

    /// Returns true when the camera moved and the accumulation was restarted.
    pub fn setCamera(self: *Renderer, camera: Camera) bool {
        self.lock.lock();
        const unchanged = Camera.eql(camera, self.camera);
        self.lock.unlock();
        if (unchanged) return false;

        self.beginInvalidation();
        self.lock.lock();
        self.camera = camera;
        self.lock.unlock();
        self.endInvalidation();
        return true;
    }

    /// Renders one tile on the calling thread. Returns false when there is
    /// nothing left to do this frame, so the main thread can join in.
    pub fn work(self: *Renderer, rng: *math.Rng) bool {
        const task = self.claim() orelse return false;
        defer self.finish();
        self.renderTile(task, rng);
        return true;
    }

    /// Tonemaps the accumulation buffer into RGBA8. Safe to call while workers
    /// are already tracing the next frame, but not from another thread that is
    /// resizing: like every other entry point it belongs to the driving thread.
    pub fn resolve(self: *Renderer) []const u8 {
        self.lock.lock();
        const buffer = self.accum[self.active];
        self.lock.unlock();

        const pixel_count = self.pixelCount();
        for (0..pixel_count) |i| {
            const sample = buffer[i];
            const count = if (sample[3] > 0.0) sample[3] else 1.0;
            const radiance = Vec3{ sample[0] / count, sample[1] / count, sample[2] / count };
            const mapped = acesFilmic(radiance);
            const offset = i * 4;
            self.out[offset + 0] = toByte(mapped[0]);
            self.out[offset + 1] = toByte(mapped[1]);
            self.out[offset + 2] = toByte(mapped[2]);
            self.out[offset + 3] = 255;
        }
        return self.out;
    }

    fn workerMain(self: *Renderer, id: usize) void {
        var rng = math.Rng.init(0x2545F4914F6CDD1D ^ (@as(u64, id + 1) *% 0x9E3779B97F4A7C15));
        var idle_spins: u32 = 0;
        while (!self.stop.load(.acquire)) {
            if (self.work(&rng)) {
                idle_spins = 0;
                continue;
            }
            // Nothing claimable: the budget is spent, the image is converged, or
            // a camera change is draining the workers.
            idle_spins += 1;
            if (idle_spins > 128) {
                math.sleepMicros(200);
                idle_spins = 0;
            } else {
                std.Thread.yield() catch {};
            }
        }
    }

    fn claim(self: *Renderer) ?Claim {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.invalidated) return null;
        if (self.completed >= self.cfg.max_samples) return null;
        if (math.nowNanos() > self.deadline.load(.monotonic)) return null;

        const tile_count = self.tileCount();
        if (self.next_tile >= tile_count) return null;

        const task = Claim{
            .tile = self.next_tile,
            .buffer = self.active,
            .camera = self.camera,
        };
        self.next_tile += 1;
        _ = self.inflight.fetchAdd(1, .acq_rel);
        return task;
    }

    fn finish(self: *Renderer) void {
        self.lock.lock();
        defer self.lock.unlock();

        _ = self.inflight.fetchSub(1, .acq_rel);
        self.done_tiles += 1;
        if (self.done_tiles == self.tileCount()) {
            self.next_tile = 0;
            self.done_tiles = 0;
            self.completed += 1;
            self.published.store(self.completed, .release);
        }
    }

    fn renderTile(self: *Renderer, task: Claim, rng: *math.Rng) void {
        const pixel_width = self.cfg.width;
        const pixel_height = self.cfg.height;
        const tile_size = self.cfg.tile_size;
        const x0 = (task.tile % self.tiles_x) * tile_size;
        const y0 = (task.tile / self.tiles_x) * tile_size;
        const x1 = @min(x0 + tile_size, pixel_width);
        const y1 = @min(y0 + tile_size, pixel_height);

        const accum = self.accum[task.buffer];
        const inv_width = 1.0 / @as(f32, @floatFromInt(pixel_width));
        const inv_height = 1.0 / @as(f32, @floatFromInt(pixel_height));

        for (y0..y1) |y| {
            for (x0..x1) |x| {
                const index = y * pixel_width + x;
                const previous = accum[index];
                const sample_index: u32 = @intFromFloat(previous[3]);

                // Halton jitter spreads the samples over the pixel footprint, so
                // progressive accumulation antialiases as it converges.
                const jitter_x = math.halton(sample_index + 1, 2);
                const jitter_y = math.halton(sample_index + 1, 3);
                const ndc_x = (@as(f32, @floatFromInt(x)) + jitter_x) * inv_width * 2.0 - 1.0;
                const ndc_y = 1.0 - (@as(f32, @floatFromInt(y)) + jitter_y) * inv_height * 2.0;

                const color = self.pathTrace(task.camera.ray(.{ ndc_x, ndc_y }), rng);
                accum[index] = .{
                    previous[0] + color[0],
                    previous[1] + color[1],
                    previous[2] + color[2],
                    previous[3] + 1.0,
                };
            }
        }
    }

    fn pathTrace(self: *Renderer, ray_in: math.Ray, rng: *math.Rng) Vec3 {
        var radiance: Vec3 = @splat(0.0);
        var throughput: Vec3 = @splat(1.0);
        var ray = ray_in;
        var depth: u32 = 0;

        while (depth < self.cfg.max_depth) : (depth += 1) {
            const hit = self.scene.intersect(ray, math.inf) orelse {
                // Nothing in the way: the ray can still carry the light itself,
                // which is what the glass transmits and the mirrors reflect.
                radiance += throughput * self.scene.background(ray);
                break;
            };
            const m = &Scene.materials[hit.mat_id];
            const base = m.albedo * m.texture(hit);

            radiance += throughput * self.directLight(hit, m, base, rng, hit.normal);

            if (m.transmission > 0.0) {
                // Transmission lighting: the same direct term evaluated from
                // inside the stone. Its shadow ray starts inside the body, so
                // it crosses the far face and picks up the Beer-Lambert tint,
                // which is what makes a backlit emerald glow green from the
                // front instead of reading as a painted block.
                const through = self.directLight(hit, m, base, rng, -hit.normal);
                radiance += throughput * math.scale(through, m.transmission * translucency_gain);
            }

            const cos_theta = @max(math.dot(ray.dir, hit.normal), 0.0);
            const fresnel = material.fresnelSchlick(cos_theta, m.*.f0());

            // Balance heuristic: take a lobe with probability p, pay 1/p. Glass
            // spends most of its time refracting, mirrors almost all of it
            // reflecting.
            const reflect_probability = math.clamp(math.maxComponent(fresnel), 0.04, 0.97);

            if (rng.float() < reflect_probability) {
                const half_vector = material.sampleGGXHalfVector(-ray.dir, hit.normal, m.roughness, rng);
                const dir = math.reflect(ray.dir, half_vector);
                throughput = math.scale(throughput * fresnel, 1.0 / reflect_probability);
                ray = .{ .origin = hit.point + math.scale(dir, self.cfg.ray_epsilon), .dir = dir };
            } else if (m.transmission > 0.0) {
                const eta = if (hit.front_face) 1.0 / m.ior else m.ior;
                const dir = material.refract(ray.dir, hit.normal, eta) orelse math.reflect(ray.dir, hit.normal);
                // Beer-Lambert over the distance travelled inside the glass is
                // what makes a thick emerald dark green and its thin edges pale.
                throughput *= math.scale(@as(Vec3, @splat(1.0)) - fresnel, 1.0 / (1.0 - reflect_probability)) * m.absorb(hit.t);
                ray = .{ .origin = hit.point + math.scale(dir, self.cfg.ray_epsilon), .dir = dir };
            } else break;

            if (depth >= 3) {
                const survival = @min(math.maxComponent(throughput), 0.95);
                if (rng.float() > survival) break;
                throughput = math.scale(throughput, 1.0 / survival);
            }
        }

        const limit: Vec3 = @splat(self.cfg.firefly_clamp);
        return @min(radiance, limit);
    }

    fn directLight(self: *Renderer, hit: geometry.Hit, m: *const material.Material, base: Vec3, rng: *math.Rng, shading_normal: Vec3) Vec3 {
        const light_point = self.scene.light.sample(rng);
        const offset = light_point - hit.point;
        const distance = @sqrt(@max(math.lengthSquared(offset), 1e-4));
        const to_light = math.divide(offset, distance);

        const cos_surface = math.dot(shading_normal, to_light);
        if (cos_surface <= 0.0) return @splat(0.0);

        const falloff = self.scene.light.attenuation(hit.point);
        if (falloff <= 0.0) return @splat(0.0);

        const shadow_ray = math.Ray{
            .origin = hit.point + math.scale(shading_normal, self.cfg.shadow_epsilon),
            .dir = to_light,
        };
        const visible = self.scene.shadowTransmittance(shadow_ray, distance - self.cfg.shadow_epsilon);
        if (math.maxComponent(visible) <= 0.0) return @splat(0.0);

        const brdf = math.scale(base, (1.0 - m.metallic) * (1.0 - m.transmission) / math.pi) +
            @as(Vec3, @splat(material.specularBRDF(m.*, hit.normal, -to_light, to_light)));
        return math.scale(brdf * visible, cos_surface * falloff);
    }

    /// Blocks new tiles and waits until every claimed tile is done, so buffer
    /// state can be replaced without a worker touching it.
    fn beginInvalidation(self: *Renderer) void {
        self.lock.lock();
        self.invalidated = true;
        self.lock.unlock();

        while (self.inflight.load(.acquire) != 0) {
            // Tiles take milliseconds, so backing off beats spinning: the
            // workers being waited on need CPU to finish their tile.
            math.sleepMicros(50);
        }
    }

    fn endInvalidation(self: *Renderer) void {
        self.lock.lock();
        self.active = 1 - self.active;
        self.next_tile = 0;
        self.done_tiles = 0;
        self.completed = 0;
        self.published.store(0, .release);
        self.invalidated = false;
        self.lock.unlock();
    }

    fn pixelCount(self: *const Renderer) usize {
        return self.cfg.width * self.cfg.height;
    }

    fn tileCount(self: *const Renderer) u32 {
        return self.tiles_x * self.tiles_y;
    }

    fn updateTileGrid(self: *Renderer) void {
        self.tiles_x = @intCast(@max(1, (self.cfg.width + self.cfg.tile_size - 1) / self.cfg.tile_size));
        self.tiles_y = @intCast(@max(1, (self.cfg.height + self.cfg.tile_size - 1) / self.cfg.tile_size));
    }

    fn allocateBuffers(self: *Renderer) !void {
        const pixel_count = self.pixelCount();
        for (&self.accum) |*buffer| {
            buffer.* = try self.allocator.alloc(Vec4, pixel_count);
            @memset(buffer.*, Vec4{ 0.0, 0.0, 0.0, 0.0 });
        }
        self.out = try self.allocator.alloc(u8, pixel_count * 4);
        @memset(self.out, 0);
    }

    fn freeBuffers(self: *Renderer) void {
        for (self.accum) |buffer| self.allocator.free(buffer);
        self.allocator.free(self.out);
    }
};

/// Narkowicz ACES fit, then sRGB gamma. Both are needed or the glass reads as
/// flat grey plastic.
fn acesFilmic(color: Vec3) Vec3 {
    const a: Vec3 = @splat(2.51);
    const b: Vec3 = @splat(0.03);
    const c: Vec3 = @splat(2.43);
    const d: Vec3 = @splat(0.59);
    const e: Vec3 = @splat(0.14);
    return @min(@max((color * (a * color + b)) / (color * (c * color + d) + e), @as(Vec3, @splat(0.0))), @as(Vec3, @splat(1.0)));
}

fn toByte(channel: f32) u8 {
    const gamma = std.math.pow(f32, math.saturate(channel), 1.0 / 2.2);
    return @intFromFloat(@min(gamma * 255.0 + 0.5, 255.0));
}
const testing = std.testing;

const test_scene = struct {
    scene: *Scene = undefined,
    renderer: *Renderer = undefined,

    fn start(config: Config) !@This() {
        var self = @This(){};
        self.scene = try testing.allocator.create(Scene);
        self.scene.* = Scene.init();
        self.renderer = try Renderer.init(testing.allocator, config, self.scene);
        return self;
    }

    fn stop(self: *@This()) void {
        self.renderer.deinit();
        testing.allocator.destroy(self.scene);
    }
};

fn imageStats(image: []const u8) struct { mean: f64, max: u8, coloured: usize } {
    var sum: f64 = 0;
    var brightest: u8 = 0;
    var coloured: usize = 0;
    const pixels = image.len / 4;
    for (0..pixels) |pixel| {
        sum += image[pixel * 4];
        brightest = @max(brightest, image[pixel * 4]);
        const r: i32 = image[pixel * 4];
        const g: i32 = image[pixel * 4 + 1];
        const b: i32 = image[pixel * 4 + 2];
        const hi = @max(r, @max(g, b));
        const lo = @min(r, @min(g, b));
        if (hi > 12 and hi - lo > 12) coloured += 1;
    }
    return .{ .mean = sum / @as(f64, @floatFromInt(pixels)), .max = brightest, .coloured = coloured };
}

test "renders a lit, coloured image" {
    var harness = try test_scene.start(.{
        .width = 96,
        .height = 64,
        .tile_size = 32,
        .worker_count = 2,
        .max_samples = 4,
        .frame_budget_ms = 5_000,
    });
    defer harness.stop();

    const aspect = @as(f32, @floatFromInt(harness.renderer.width())) / @as(f32, @floatFromInt(harness.renderer.height()));
    try testing.expect(harness.renderer.setCamera(scene.Camera{ .aspect = aspect }));

    var rng = math.Rng.init(1);
    var guard: u32 = 0;
    while (harness.renderer.samples() < 4) : (guard += 1) {
        harness.renderer.setFrameBudget(5_000);
        if (!harness.renderer.work(&rng)) {
            try testing.expect(guard < 5_000_000);
            math.sleepMicros(100);
        }
    }

    const stats = imageStats(harness.renderer.resolve());
    // The frame is mostly black background, so judge the mean loosely and the
    // peak strictly.
    try testing.expect(stats.max > 40);
    try testing.expect(stats.mean > 0.2);
    try testing.expect(stats.coloured > 0);
}

test "the result does not depend on the number of workers" {
    var single = try test_scene.start(.{ .width = 64, .height = 48, .tile_size = 16, .worker_count = 1, .max_samples = 2, .frame_budget_ms = 5_000 });
    defer single.stop();
    var many = try test_scene.start(.{ .width = 64, .height = 48, .tile_size = 16, .worker_count = 4, .max_samples = 2, .frame_budget_ms = 5_000 });
    defer many.stop();

    for ([_]*Renderer{ single.renderer, many.renderer }) |renderer| {
        _ = renderer.setCamera(scene.Camera{ .aspect = 4.0 / 3.0 });
        var rng = math.Rng.init(5);
        var guard: u32 = 0;
        while (renderer.samples() < 2) : (guard += 1) {
            renderer.setFrameBudget(5_000);
            if (!renderer.work(&rng)) {
                try testing.expect(guard < 5_000_000);
                math.sleepMicros(100);
            }
        }
    }

    const a = single.renderer.resolve();
    const b = many.renderer.resolve();
    const stats_a = imageStats(a);
    const stats_b = imageStats(b);
    // Same picture, so the luminance has to match closely.
    try testing.expectApproxEqAbs(stats_a.mean, stats_b.mean, @max(stats_a.mean, 1.0) * 0.35);
    try testing.expectApproxEqAbs(@as(f64, stats_a.max), @as(f64, stats_b.max), 64.0);
}

test "moving the camera restarts the accumulation" {
    var harness = try test_scene.start(.{ .width = 64, .height = 48, .tile_size = 16, .worker_count = 2, .max_samples = 5, .frame_budget_ms = 5_000 });
    defer harness.stop();

    _ = harness.renderer.setCamera(scene.Camera{ .aspect = 4.0 / 3.0 });
    var rng = math.Rng.init(9);
    while (harness.renderer.samples() < 3) {
        harness.renderer.setFrameBudget(5_000);
        if (!harness.renderer.work(&rng)) math.sleepMicros(100);
    }
    try testing.expectEqual(@as(u32, 3), harness.renderer.samples());
    // Three of five: still refining, not converged.
    try testing.expect(!harness.renderer.converged());

    const moved = scene.Camera{ .yaw = 1.2, .aspect = 4.0 / 3.0 };
    try testing.expect(harness.renderer.setCamera(moved));
    try testing.expectEqual(@as(u32, 0), harness.renderer.samples());

    // Setting the same camera again is a no-op.
    try testing.expect(!harness.renderer.setCamera(moved));
    try testing.expect(harness.renderer.setCamera(scene.Camera{ .yaw = 1.3, .aspect = 4.0 / 3.0 }));

    while (harness.renderer.samples() < 5) {
        harness.renderer.setFrameBudget(5_000);
        if (!harness.renderer.work(&rng)) math.sleepMicros(100);
    }
    try testing.expect(harness.renderer.converged());
}

test "resize swaps the buffers and keeps rendering" {
    var harness = try test_scene.start(.{ .width = 64, .height = 48, .tile_size = 16, .worker_count = 2, .max_samples = 2, .frame_budget_ms = 5_000 });
    defer harness.stop();

    _ = harness.renderer.setCamera(scene.Camera{ .aspect = 16.0 / 9.0 });
    var rng = math.Rng.init(11);
    while (harness.renderer.samples() < 2) {
        harness.renderer.setFrameBudget(5_000);
        if (!harness.renderer.work(&rng)) math.sleepMicros(100);
    }

    try harness.renderer.resize(96, 64);
    try testing.expectEqual(@as(usize, 96), harness.renderer.width());
    try testing.expectEqual(@as(usize, 64), harness.renderer.height());
    try testing.expectEqual(@as(usize, 96 * 64 * 4), harness.renderer.resolve().len);

    // The aspect changed with the buffers, so the camera must be re-applied.
    _ = harness.renderer.setCamera(scene.Camera{ .aspect = 96.0 / 64.0 });
    while (harness.renderer.samples() < 2) {
        harness.renderer.setFrameBudget(5_000);
        if (!harness.renderer.work(&rng)) math.sleepMicros(100);
    }
    try testing.expect(imageStats(harness.renderer.resolve()).max > 40);
}
