# Diorama — a hand-rolled raytracer in Zig + raylib

Seven glass cubes in a Minecraft-style cross, lit by a single spot light, rendered
by a path tracer written from scratch. raylib only opens the window and blits one
textured quad; every pixel is computed on the CPU.

```
zig build --release            # build
zig build run --release        # run
zig build test                 # 32 unit tests, no graphics context needed
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
| `esc` | Quit |

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
- **Tone mapping.** ACES filmic fit plus sRGB gamma; single-sample clamp keeps a
  lucky refracted ray landing on the emitter from blowing out the average.

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
| 320x180 | ~2.5 | ~18 Mray/s |
| 480x270 | ~7.5 | ~18 Mray/s |
| 640x360 | ~13 | ~18 Mray/s |
| 1280x720 | ~49 | ~19 Mray/s |

Peak memory is about 8 MB at 640x360 (two RGBA32F accumulation buffers plus the
resolved RGBA8 image), so the project fits comfortably in a small RAM budget.

## Testing

`zig build test` runs 32 tests covering the slab test (including rays that start
inside a box and rays pointing away from it), Fresnel and its material wiring,
Beer-Lambert ordering, Snell's law including total internal reflection, the GGX
lobe and its sampler, light cone falloff, the cube layout and its adjacency, and
end-to-end renders (lit and coloured, identical output with 1 and 4 workers,
camera resets restarting the accumulation, and resizing).