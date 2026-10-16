// Step 0/6 driver: verifies the Zig + raylib toolchain and, with --selftest,
// renders the diorama headlessly so the raytracer can be checked without a
// window. Step 7 replaces this with the interactive application.
const std = @import("std");
const rl = @import("raylib");
const rt = @import("raytracer");

const math = rt.math;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var selftest = false;
    var frame_limit: ?u32 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--selftest")) {
            selftest = true;
        } else if (std.mem.eql(u8, args[i], "--frames") and i + 1 < args.len) {
            // Lets the smoke test exit on its own instead of waiting for input.
            i += 1;
            frame_limit = try std.fmt.parseInt(u32, args[i], 10);
        } else {
            std.debug.print("unknown argument: {s}\n", .{args[i]});
        }
    }

    if (selftest) try runSelfTest(init.gpa);

    rl.setTraceLogLevel(.warning);
    rl.setConfigFlags(.{ .window_resizable = true });
    rl.initWindow(1280, 720, "diorama");
    defer rl.closeWindow();

    if (!rl.isWindowReady()) {
        std.debug.print("FAIL: raylib window is not ready\n", .{});
        return error.WindowInitFailed;
    }
    std.debug.print("backend ok: window {d}x{d}\n", .{ rl.getScreenWidth(), rl.getScreenHeight() });

    var frames: u32 = 0;
    while (!rl.windowShouldClose() and !rl.isKeyDown(.escape)) {
        if (frame_limit) |limit| {
            if (frames >= limit) break;
        }
        frames += 1;

        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(.{ .r = 8, .g = 8, .b = 10, .a = 255 });
        rl.drawText("diorama: raylib toolchain OK", 20, 20, 20, .white);
        rl.drawFPS(20, 50);
    }

    std.debug.print("smoke test ok, {d} frames rendered\n", .{frames});
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
    const renderer = try rt.renderer.Renderer.init(gpa, cfg, &scene);
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