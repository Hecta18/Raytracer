# Diorama — a hand-rolled raytracer in Zig + raylib

Seven glass cubes in a Minecraft-style cross, lit by a single spot light, rendered
by a path tracer written from scratch. raylib only opens the window and blits one
textured quad; every pixel is computed on the CPU.

```
zig build --release            # build
zig build run --release        # run
zig build test                 # 34 unit tests, no graphics context needed
zig build run --release -- --selftest   # headless render + statistics
zig build run --release -- --frames 600 --screenshot out.ppm
```

> `zig build` without `--release` builds Debug, which is roughly 6x slower. The
> raytracer wants ReleaseFast.

## Controls

| Input | Action |
|---|---|
| Left-drag | Rotate the diorama |
| Mouse wheel | Zoom (2.2 – 20 units) |
| `space` | Auto-rotate turntable |
| `r` | Reset the camera |
| `h` | Toggle the HUD |
| `l` | Show the light fixture itself (see below) |
| `esc` | Quit |

Command line: `--selftest` renders headlessly, `--view yaw,pitch,distance` sets a
reproducible camera, `--screenshot out.ppm` saves the window, `--frames N` exits
after N frames. Passing `--frames` or `--view` also disables input so scripted
runs are deterministic.

The image refines progressively: while the camera is still it trades resolution
for responsiveness, and once you stop it keeps accumulating samples up to 96 and
reports `refined: image fully converged`.

## How it is put together

| File | Role |
|---|---|
| `src/math.zig` | `Vec3` SIMD helpers, AABB slab test, PCG32, Halton, clock |
| `src/geometry.zig` | `Hit` records, cube intersection, face UVs |
| `src/material.zig` | Material parameters, Fresnel, GGX, Snell, Beer-Lambert, the five presets |
| `src/light.zig` | Penumbra spot light and its analytic emitter |
| `src/scene.zig` | Cube layout, camera, tinted shadow transmittance |
| `src/renderer.zig` | Tile scheduler, worker threads, path tracer, progressive accumulation, tonemap |
| `src/main.zig` | raylib window, input, texture upload, HUD, adaptive resolution |

The `raytracer` module never imports raylib, which is why `zig build test` and
`--selftest` work without a graphics context.

## Requirement mapping

| Requirement | Where |
|---|---|
| Diorama rotation | `src/main.zig` drag handling → `Camera.yaw/pitch` (`src/scene.zig`) |
| Camera zoom | wheel handling, clamped distance |
| Five unique materials | `material.palette` in `src/material.zig:211`, mapped onto the cubes in `scene.Scene.init` |
| Refraction | `material.refract` (`src/material.zig:87`) driven by `pathTrace` (`src/renderer.zig:342`) |
| Reflection | GGX visible-normal sampling (`src/material.zig:101`) and the Fresnel-weighted reflect branch |
| Shadows | one jittered shadow ray per shading point, `Scene.shadowTransmittance` (`src/scene.zig:111`) |
| Concurrency | persistent worker threads (`renderer.zig:250`), tile claiming under a spin lock (`renderer.zig:270`), main thread joins in via `Renderer.work` |
| Novel light type | penumbra spot light: smoothstep cone falloff (`src/light.zig:48`) plus a finite emitter radius sampled per shadow ray |
| Coloured translucent / reflective materials | Beer-Lambert absorption per channel (`src/material.zig:40`), coloured metal `F0`, and *tinted* shadow rays through the glass |

## Why the light is hidden by default

A surface already receives the fixture's specular highlight from the direct
term. Letting reflected rays pick the emitter up as well counts the same
reflection twice, which made the fixture appear doubled and left bright white
dots wherever a lucky ray found the small source through the glass. Camera rays
therefore do not see the fixture at all; rays that pass *through* the glass still
do, so the internal glow survives. Press `l` to compare.

## Rendering notes

- **Progressive accumulation.** Each pixel stores a radiance sum *and* its own
  sample count, so `resolve` stays correct even while the next frame is already
  being traced. Pixel positions are jittered with a Halton sequence, so the same
  code path antialiases, softens the penumbra and converges.
- **Concurrency.** Frames are split into 32x32 tiles that any thread claims.
  Workers stop claiming once a per-frame time budget is spent, which keeps input
  responsive on a slow CPU. Moving the camera drains in-flight tiles and flips to
  the other accumulation buffer, so a drag never corrupts the image being shown.
- **Adaptive resolution.** The renderer runs at a fraction of the window, capped
  at 640x360 and snapped to whole tiles. Quality adapts at most once every two
  seconds from measured throughput — reacting to every frame makes it thrash,
  because each resize restarts the accumulation.
- **Tone mapping.** ACES filmic fit plus sRGB gamma, the gamma part from a
  4096 entry table: a `pow` per channel per pixel used to cost more on the main
  thread than the entire trace. The resolve is throttled to ~30 Hz while the
  image changes and always runs once the image converges.
- **Fireflies.** Beyond the per-sample clamp, a sample far brighter than what a
  pixel has already gathered is pulled down to a multiple of its running mean,
  so an unlucky ray through the emitter stops looking like a white dot instead
  of slowly fading over a hundred frames.
- **Bounce budget.** Rays that miss the cluster dominate (they outnumber hits
  several times over), so `Scene.intersect` hoists the reciprocal direction out
  of the loop and rejects against the union box first: 96 ns -> 36 ns per miss
  ray in a micro-benchmark.

## Deliberate approximations

- The spot light has no visible mesh. `SpotLight.emission` intersects the emitter
  disk analytically, so escaped rays that point at the fixture pick it up. That
  is what lets glass transmit a glowing core without adding geometry.
- Transmissive surfaces also get a transmission-lighting term
  (`src/renderer.zig:352`): the same direct light evaluated from inside the
  stone, so its shadow ray picks up the Beer-Lambert tint. Without it, glass lit
  from the front reads as painted plastic.

## Performance

Measured on 8 hardware threads, ReleaseFast:

| Resolution | ms/frame | throughput |
|---|---|---|
| 320x180 | ~2.9 | ~19 Mray/s |
| 480x270 | ~7.1 | ~19 Mray/s |
| 640x360 | ~13 | ~18 Mray/s |
| 1280x720 | ~49 | ~19 Mray/s |

A fixed 128 sample pass at 320x180 went from 459 ms to 368 ms. Absolute numbers
move by 20-30% depending on what else the machine is running.

Peak memory is about 8 MB at 640x360 (two RGBA32F accumulation buffers plus the
resolved RGBA8 image), so the project fits comfortably in a small RAM budget.

## Testing

`zig build test` runs 34 tests covering the slab test (including rays that start
inside a box and rays pointing away from it), Fresnel and its material wiring,
Beer-Lambert ordering, Snell's law including total internal reflection, the GGX
lobe and its sampler, light cone falloff, the cube layout and its adjacency, and
end-to-end renders (lit and coloured, identical output with 1 and 4 workers,
camera resets restarting the accumulation, and resizing).

Two of them are regressions worth naming: a camera change must not leave the
previous pose in the buffer being refilled (it used to blend two viewpoints into
one ghosted image), and the fixture must stay invisible until it is toggled on.