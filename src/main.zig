//! Interactive viewer for the raytraced diorama.
//!
//! raylib only provides the window, the input and one textured quad; every pixel
//! is produced by the raytracer in `raytracer.zig`, which is free of raylib and
//! can therefore also be run headless with --selftest.
const std = @import("std");
const rl = @import("raylib");
const rt = @import("raytracer");

const math = rt.math;
const Renderer = rt.renderer.Renderer;

const min_distance: f32 = 2.2;
const max_distance: f32 = 20.0;
const min_pitch: f32 = -1.45;
const max_pitch: f32 = 1.45;

/// Render resolution as a fraction of the window, adapted to the frame time.
const min_quality: f32 = 0.2;
const max_quality: f32 = 1.0;
const max_pixels: usize = 640 * 360;

/// Rendering budget per display frame: short while the camera moves so input
/// stays responsive, longer while a still image refines.
const move_budget_ms: u32 = 3;
/// While nothing is being interacted with the workers may use the machine
/// freely: a still image converges several times faster than it did when this
/// was capped at the frame time.
const refine_budget_ms: u32 = 100;
const help_budget_ns: i64 = 6 * std.time.ns_per_ms;

/// Tonemap and upload at most this often while the image is changing. Resolving
/// every completed sample spent more main thread time than the tracer did.
const upload_interval_ns: i64 = 33 * std.time.ns_per_ms;

/// A refined sample slower or faster than this says the resolution is wrong.
const slow_sample_ms: f64 = 60.0;
const fast_sample_ms: f64 = 20.0;
const min_samples_per_adjust: u32 = 8;
/// Samples the turntable waits for before turning again.
const turntable_samples: u32 = 12;
const turntable_max_pause_ns: i64 = 2 * std.time.ns_per_s;

/// Never resize more often than this.
const adjust_interval_ns: i64 = 2 * std.time.ns_per_s;

const Ui = struct {
    camera: rt.scene.Camera = .{},
    auto_rotate: bool = false,
    show_hud: bool = true,
    quality: f32 = 0.55,
    /// Show the light fixture itself. Off by default: reflected rays would pick
    /// it up on top of the specular highlight already added by the direct term.
    light_visible: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var selftest = false;
    var frame_limit: ?u32 = null;
    var screenshot: ?[]const u8 = null;
    var scripted = false;
    var ui_camera = rt.scene.Camera{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--selftest")) {
            selftest = true;
        } else if (std.mem.eql(u8, args[i], "--frames") and i + 1 < args.len) {
            i += 1;
            frame_limit = try std.fmt.parseInt(u32, args[i], 10);
            scripted = true;
        } else if (std.mem.eql(u8, args[i], "--view") and i + 1 < args.len) {
            // Reproducible camera for screenshots and bug reports.
            i += 1;
            var iter = std.mem.splitScalar(u8, args[i], ',');
            ui_camera.yaw = std.fmt.parseFloat(f32, iter.next() orelse "0") catch 0;
            ui_camera.pitch = std.fmt.parseFloat(f32, iter.next() orelse "0.3") catch 0.3;
            ui_camera.distance = std.fmt.parseFloat(f32, iter.next() orelse "5.9") catch 5.9;
            scripted = true;
        } else if (std.mem.eql(u8, args[i], "--screenshot") and i + 1 < args.len) {
            i += 1;
            screenshot = args[i];
        } else {
            std.debug.print("unknown argument: {s}\n", .{args[i]});
        }
    }

    if (selftest) return runSelfTest(init.gpa);

    rl.setTraceLogLevel(.warning);
    rl.setConfigFlags(.{ .window_resizable = true });
    rl.initWindow(1280, 720, "diorama - raytraced glass cubes");
    defer rl.closeWindow();
    if (!rl.isWindowReady()) return error.WindowInitFailed;
    rl.setTargetFPS(60);

    var scene = rt.scene.Scene.init();
    var ui = Ui{ .camera = ui_camera };

    var size = renderSize(rl.getScreenWidth(), rl.getScreenHeight(), ui.quality);
    const tile: usize = 32;
    const renderer = try Renderer.init(init.gpa, .{
        .width = size.width,
        .height = size.height,
        .tile_size = tile,
    }, &scene);
    defer renderer.deinit();

    var target = try rl.RenderTexture.init(@intCast(size.width), @intCast(size.height));
    defer target.unload();
    rl.setTextureFilter(target.texture, .bilinear);

    std.debug.print("diorama: {d}x{d} window, {d}x{d} render, {d} worker threads\n", .{
        rl.getScreenWidth(), rl.getScreenHeight(), size.width, size.height, renderer.workerCount(),
    });

    renderer.setLightVisible(ui.light_visible);

    var rng = math.Rng.init(0x853c49e6748fea9b);
    var uploaded: u32 = 0;
    var last_upload = math.nowNanos();
    var samples_at_reset: u32 = 0;
    var last_sample = math.nowNanos();
    var last_adjust = math.nowNanos();
    var last_turn = math.nowNanos();
    var frames: u32 = 0;

    while (!rl.windowShouldClose()) {
        frames += 1;
        if (frame_limit) |limit| {
            if (frames >= limit) break;
        }

        // Scripted runs ignore input so screenshots and benchmarks reproduce.
        if (!scripted) updateInput(&ui);
        if (ui.auto_rotate) {
            // Turntable in steps: rotating every frame would reset the
            // accumulation every frame, so each step is allowed to settle first.
            const settled = renderer.samples() >= turntable_samples;
            if (settled or math.nowNanos() - last_turn > turntable_max_pause_ns) {
                ui.camera.yaw += 0.45;
                last_turn = math.nowNanos();
            }
        }

        // The window can be resized at any time; follow it and keep the render
        // aspect identical so the upscale is a plain stretch.
        const window_size = renderSize(rl.getScreenWidth(), rl.getScreenHeight(), ui.quality);
        if (!sameSize(window_size, size)) {
            size = window_size;
            try renderer.resize(size.width, size.height);
            target.unload();
            target = try rl.RenderTexture.init(@intCast(size.width), @intCast(size.height));
            rl.setTextureFilter(target.texture, .bilinear);
            uploaded = 0;
            samples_at_reset = 0;
        }
        ui.camera.aspect = @as(f32, @floatFromInt(size.width)) / @as(f32, @floatFromInt(size.height));

        // A moved camera throws the accumulation away and starts over; an idle
        // camera keeps refining the image sample by sample. While refining the
        // renderer gets a larger slice of the frame, because no interaction is
        // happening and the budget is otherwise just wasted waiting.
        if (ui.light_visible != renderer.isLightVisible()) renderer.setLightVisible(ui.light_visible);
        if (renderer.setCamera(ui.camera)) samples_at_reset = 0;
        const refining = renderer.samples() > 0;
        renderer.setFrameBudget(@intCast(if (refining) refine_budget_ms else move_budget_ms));

        const help_start = math.nowNanos();
        while (math.nowNanos() - help_start < help_budget_ns) {
            if (!renderer.work(&rng)) break;
        }

        const samples = renderer.samples();
        const now = math.nowNanos();
        // A restarted accumulation (camera moved, window resized) has to be
        // shown straight away; otherwise throttle, but never drop the final
        // frame of a converged image.
        const restarted = samples < uploaded;
        const due = restarted or renderer.converged() or now - last_upload >= upload_interval_ns;
        if (samples > 0 and samples != uploaded and due) {
            rl.updateTexture(target.texture, @ptrCast(renderer.resolve().ptr));
            uploaded = samples;
            last_upload = now;

            // Measure the time a whole sample took and only act on a verdict
            // from the steady state: the first sample after a reset is always
            // slow, and reacting to it would start an endless resize loop.
            const interval = now - last_sample;
            last_sample = now;
            if (samples - samples_at_reset >= min_samples_per_adjust and
                now - last_adjust > adjust_interval_ns and
                adaptQuality(&ui, interval))
            {
                last_adjust = now;
            }
        }

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.black);
        rl.drawTexturePro(
            target.texture,
            .{ .x = 0, .y = 0, .width = @floatFromInt(size.width), .height = @floatFromInt(size.height) },
            .{ .x = 0, .y = 0, .width = @floatFromInt(rl.getScreenWidth()), .height = @floatFromInt(rl.getScreenHeight()) },
            .{ .x = 0, .y = 0 },
            0,
            .white,
        );
        if (ui.show_hud) drawHud(renderer, size);
    }

    if (screenshot) |path| try savePpm(init.gpa, init.io, path);
}

fn updateInput(ui: *Ui) void {
    // Drag rotates the diorama, the wheel moves the camera in and out.
    if (rl.isMouseButtonDown(.left)) {
        const delta = rl.getMouseDelta();
        ui.camera.yaw -= delta.x * 0.005;
        ui.camera.pitch = math.clamp(ui.camera.pitch + delta.y * 0.005, min_pitch, max_pitch);
    }
    const wheel = rl.getMouseWheelMove();
    if (wheel != 0) {
        ui.camera.distance = math.clamp(ui.camera.distance - wheel * 0.8, min_distance, max_distance);
    }
    if (rl.isKeyPressed(.space)) ui.auto_rotate = !ui.auto_rotate;
    if (rl.isKeyPressed(.h)) ui.show_hud = !ui.show_hud;
    if (rl.isKeyPressed(.r)) {
        ui.camera = .{};
        ui.auto_rotate = false;
    }
    if (rl.isKeyPressed(.l)) ui.light_visible = !ui.light_visible;
}

const Size = struct { width: usize, height: usize };

/// Window size scaled by the quality factor, capped in total pixels and snapped
/// to whole tiles so the renderer never sees a partial tile grid.
fn renderSize(window_width: i32, window_height: i32, quality: f32) Size {
    const tile: usize = 32;
    var width = @as(f32, @floatFromInt(@max(window_width, 1))) * quality;
    var height = @as(f32, @floatFromInt(@max(window_height, 1))) * quality;

    const pixels = width * height;
    if (pixels > @as(f32, @floatFromInt(max_pixels))) {
        const shrink = @sqrt(@as(f32, @floatFromInt(max_pixels)) / pixels);
        width *= shrink;
        height *= shrink;
    }

    return .{
        .width = @max((@as(usize, @intFromFloat(width)) / tile) * tile, tile),
        .height = @max((@as(usize, @intFromFloat(height)) / tile) * tile, tile),
    };
}

fn sameSize(a: Size, b: Size) bool {
    return a.width == b.width and a.height == b.height;
}

/// Trades resolution for frame rate. Resizing restarts the progressive
/// accumulation, so the decision is made rarely and only from measured
/// throughput; adjusting every frame would feed back on itself and the image
/// would never converge.
fn adaptQuality(ui: *Ui, sample_interval_nanos: i64) bool {
    const before = ui.quality;
    const interval_ms = @as(f64, @floatFromInt(sample_interval_nanos)) / 1e6;
    if (interval_ms > slow_sample_ms) {
        ui.quality = @max(ui.quality - 0.08, min_quality);
    } else if (interval_ms < fast_sample_ms) {
        ui.quality = @min(ui.quality + 0.02, max_quality);
    }
    return ui.quality != before;
}

fn drawHud(renderer: *const Renderer, size: Size) void {
    var line: [128]u8 = undefined;
    var y: i32 = 14;

    rl.drawRectangle(8, 8, 300, 106, .{ .r = 0, .g = 0, .b = 0, .a = 140 });

    y += drawLine("diorama  -  hand rolled raytracer", 18, y, 16, rl.Color.init(235, 235, 235, 255));
    const stats = tryLine(&line, "{d} fps   {d}/{d} spp   {d}x{d}   {d} workers", .{
        rl.getFPS(),
        renderer.samples(),
        renderer.maxSamples(),
        size.width,
        size.height,
        renderer.workerCount(),
    });
    y += drawLine(stats, 18, y, 16, rl.Color.init(255, 214, 120, 255));
    y += drawLine("drag: rotate   wheel: zoom", 18, y, 16, rl.Color.init(180, 190, 200, 255));
    y += drawLine("space: turntable   r: reset   h: hud   l: light", 18, y, 16, rl.Color.init(180, 190, 200, 255));
    y += drawLine(if (renderer.converged()) "refined: image fully converged" else "refining: image still accumulating", 18, y, 16, rl.Color.init(150, 210, 160, 255));

    // Material legend, drawn straight from the palette so it can never drift
    // out of sync with the scene.
    const x: i32 = rl.getScreenWidth() - 150;
    y = 14;
    rl.drawRectangle(x - 8, 8, 142, 14 + 18 * rt.scene.Scene.materials.len, .{ .r = 0, .g = 0, .b = 0, .a = 140 });
    for (rt.scene.Scene.materials) |m| {
        rl.drawRectangle(x, y, 12, 12, swatch(m));
        const label = tryLine(&line, "{s}", .{m.name});
        _ = drawLine(label, x + 18, y, 16, rl.Color.init(220, 220, 220, 255));
        y += 18;
    }
}

/// Palette colours are deliberately dark for glass; brighten them for the legend.
fn swatch(m: rt.material.Material) rl.Color {
    const boosted = @min(math.scale(m.albedo, 2.6), @as(math.Vec3, @splat(1.0)));
    return .{ .r = @intFromFloat(boosted[0] * 255), .g = @intFromFloat(boosted[1] * 255), .b = @intFromFloat(boosted[2] * 255), .a = 255 };
}

fn tryLine(buffer: []u8, comptime format: []const u8, args: anytype) [:0]const u8 {
    return std.fmt.bufPrintZ(buffer, format, args) catch buffer[0..0 :0];
}

fn drawLine(text: [:0]const u8, x: i32, y: i32, size: i32, color: rl.Color) i32 {
    rl.drawText(text, x, y, size, color);
    return y + size + 6;
}

/// Writes the window contents as a binary PPM, HUD included.
fn savePpm(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const image = try rl.Image.fromScreen();
    defer image.unload();

    const width: usize = @intCast(image.width);
    const height: usize = @intCast(image.height);
    var header: [64]u8 = undefined;
    const header_text = try std.fmt.bufPrint(&header, "P6\n{d} {d}\n255\n", .{ width, height });
    const bytes = try gpa.alloc(u8, header_text.len + width * height * 3);
    defer gpa.free(bytes);
    @memcpy(bytes[0..header_text.len], header_text);

    const pixels: [*]const u8 = @ptrCast(image.data);
    for (0..width * height) |pixel| {
        const offset = header_text.len + pixel * 3;
        bytes[offset + 0] = pixels[pixel * 4 + 0];
        bytes[offset + 1] = pixels[pixel * 4 + 1];
        bytes[offset + 2] = pixels[pixel * 4 + 2];
    }

    std.debug.print("wrote {s} ({d}x{d})\n", .{ path, width, height });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn runSelfTest(gpa: std.mem.Allocator) !void {
    var scene = rt.scene.Scene.init();
    var rng = math.Rng.init(12345);

    const cfg = rt.renderer.Config{
        .width = 320,
        .height = 180,
        .tile_size = 16,
        .max_samples = 128,
        .frame_budget_ms = 10_000,
    };
    const renderer = try Renderer.init(gpa, cfg, &scene);
    defer renderer.deinit();

    const camera = rt.scene.Camera{ .aspect = @as(f32, @floatFromInt(cfg.width)) / @as(f32, @floatFromInt(cfg.height)) };
    _ = renderer.setCamera(camera);

    const start = math.nowNanos();
    var reported: u32 = 0;
    while (renderer.samples() < cfg.max_samples) {
        renderer.setFrameBudget(cfg.frame_budget_ms);
        if (!renderer.work(&rng)) {
            if (renderer.samples() == reported) math.sleepMicros(200);
            reported = renderer.samples();
        }
    }
    const elapsed_ms = @as(f64, @floatFromInt(math.nowNanos() - start)) / 1e6;
    const image = renderer.resolve();

    var sum: f64 = 0;
    var max_luma: f64 = 0;
    var coloured: u64 = 0;
    for (0..cfg.width * cfg.height) |pixel| {
        const r = @as(f64, image[pixel * 4 + 0]) / 255.0;
        const g = @as(f64, image[pixel * 4 + 1]) / 255.0;
        const b = @as(f64, image[pixel * 4 + 2]) / 255.0;
        const luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        sum += luma;
        max_luma = @max(max_luma, luma);
        const brightest = @max(r, @max(g, b));
        const darkest = @min(r, @min(g, b));
        if (brightest > 0.05 and brightest - darkest > 0.05) coloured += 1;
    }

    const pixel_count: f64 = @floatFromInt(cfg.width * cfg.height);
    std.debug.print(
        \\selftest: {d} spp in {d:.0} ms on {d} workers ({d:.2} ms/frame, {d}x{d})
        \\  mean luma {d:.4}  max luma {d:.3}  coloured pixels {d:.1}%
        \\
    , .{
        cfg.max_samples,
        elapsed_ms,
        renderer.workerCount(),
        elapsed_ms / @as(f64, @floatFromInt(cfg.max_samples)),
        cfg.width,
        cfg.height,
        sum / pixel_count,
        max_luma,
        100.0 * @as(f64, @floatFromInt(coloured)) / pixel_count,
    });

    if (max_luma < 0.05) std.debug.print("FAIL: image is black\n", .{});
    if (coloured == 0) std.debug.print("FAIL: no coloured pixels\n", .{});
}