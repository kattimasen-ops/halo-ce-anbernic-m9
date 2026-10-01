# Roadmap and known limits

This page says where the port stands, what limits it now, and what is
planned, in order of expected payoff. The goal is 60 fps (16.7 ms a frame)
in the opening of the a30 level at the default render scale of 0.75, the
scene looking out of the Pelican. The limits are stated with the
measurements that show them; the measurements were taken with the tools in
[Profiling](PROFILING.md), and the history that led here is in
[Performance](PERFORMANCE.md). Items move from here into the performance
history as they land.

## Where it stands

On the RG35XX H at render scale 0.75, the menus run at 60 fps. The a30
opening (Halo) runs at 53 to 57 fps in the latest build, most frames at
16.7 ms, the b30 beach battle (The Silent Cartographer) at 35 to 46 fps
(about 40), and the c10 opening (343 Guilty Spark) at about 44 fps. With
the repeated model draws instanced, a30 is limited by the GPU, and the
environment shadows are its largest cost: without them a30 holds 57.5 to
59.9 fps. The next steps are to draw the shadows' textures without
splitting the primary target's pass (a first attempt made every other frame
slow), and to cut the GPU's work in b30 and c10. The [README's performance table](../README.md#performance)
has the published figures.

In the a30 opening, a frame is made by three workers that overlap: the
game's thread, the GL thread that runs the Mali driver, and the GPU. For
60 fps each must take less than 16.7 ms a frame.

| Worker | Measured | Limit? |
| --- | --- | --- |
| GL thread | 15.2 ms a frame in the driver's functions, plus 1.9 to 2.4 ms of buffer writes and the waits at changes of render target | The limit: the game's thread waits 1.5 to 1.9 ms a frame for it. |
| Game's thread | About 20 ms a frame before its latest improvements (a faster `memcmp` and `memcpy`, the GL queue published in 4 KB steps); the renderer's per-draw work (`prepare_draw`) was about a quarter of it | Close behind: it barely waits. |
| GPU | About 13.5 ms of vertex and tiler work and about 16 ms of pixel work a frame, measured on an earlier build | Close: with the alpha test elision turned off, a30 becomes GPU-bound. |

The GL thread's frame, in the driver's functions:

| Function | Calls a frame | Time a frame |
| --- | --- | --- |
| `glDrawRangeElementsBaseVertex` | 456 | 7.8 ms (17.2 µs each) |
| `glBindFramebuffer` | 25 | 2.6 ms |
| `glUniform4fv` | about 560 | 1.3 ms |
| Everything else | | about 3.5 ms |

## Planned work

### 1. Fewer and cheaper draws on the GL thread

The driver's per-draw cost is the largest single item. The ways to cut it:

- **Draw repeated geometry as instances.** Of 423 indexed draws a frame in
  a30, 244 draw the same geometry with the same shaders, textures and
  blending as another draw of the frame (six marines, repeated parts).
  `HALO_DEBUG_DRAW_CALLERS=4` measures the upper bound by leaving the
  repeats out.
- **Fewer uniform uploads.** Merge the per-draw uniforms into one array
  or block, so that a draw sets them with one call rather than several.
- **Fewer texture rebinds.** Sorting the models cut the binds from 594 to
  393 a frame; the remaining binds are the next target.
- **Fewer changes of render target.** 25 framebuffer binds cost 2.6 ms a
  frame. Drawing the shadow textures and the motion sensor's target before
  the primary target's first pass would stop them splitting that pass.
- **Merge the environment's lightmap and diffuse passes.** The level
  geometry is drawn in more than one pass; combining these two would cut
  its draws. This is a large change to the game's rasterizer.
- **Write less into the stream buffers.** The 1.9 to 2.4 ms of buffer
  writes a frame is the copying itself (deferring the flushes changed
  nothing), so only writing fewer bytes helps.

### 2. The game's thread

- **Cheaper per-draw work in the renderer.** `prepare_draw` rebuilds and
  compares the pixel shader key (252 bytes), the per-draw uniform inputs
  (308 bytes) and the uniform shadows on every draw. Tracking what changed
  (dirty flags set by the state functions) would avoid most of it.
- **Sound obstruction.** The profiler showed the sound manager's
  obstruction tests (collision rays from the camera) among the game's
  thread's costs. Upstream already caches each sound's result for the
  frames of one game tick (`compute_sound_obstruction` in
  `source/sound/game_sound.c`); how much they still cost at the current
  frame rate needs measuring before anything is changed.
- **Profile-guided optimisation for the device.** The guest is optimised
  with upstream's profile, recorded by the x86 Linux build. A profile
  recorded on the handheld would match its code paths.

### 3. The GPU and the picture

- **The HUD at full resolution.** At a render scale below 1, the HUD and
  text are drawn at the lower resolution too. Drawing them at the screen's
  resolution would keep them sharp, and would let the 3D picture go to a
  lower scale without making the HUD harder to read.
- **Vertex work.** Models are most of the GPU's vertex work;
  `display.model_detail` already switches to simpler models sooner, and
  fewer passes over the level's geometry (above) would also cut it.

### 4. Devices and firmware

- Only the RG35XX H has been tested. The other 640x480 H700 handhelds
  (RG35XX Plus, SP, 2024, RG40XX H and V) are expected to work; the
  RG CubeXX (720x720) and RG34XX (720x480) have other screen shapes
  (`display.screen_width`).
- Other firmware for the H700 (muOS, ROCKNIX) is untested. The host is
  built against Knulli's SDL2 (2.30.12), whose video driver drives the Mali
  framebuffer, and Arm's driver; firmware with another graphics stack would
  need the host's SDL2 and EGL bridge to support it.

Reports from other devices and firmware are welcome
([Contributing](../CONTRIBUTING.md)).

## Known limits

- **Frame rate.** Below 60 fps in the campaign at the default settings; the
  b30 battle varies by several frames a second from moment to moment.
- **Heat.** Long sessions reach 70 °C, where the kernel lowers the CPU from
  1512 to 1416 MHz and the GPU from 648 to 600 MHz, and the frame rate
  drops by a few frames a second.
- **Render scale.** The whole picture, the HUD included, is drawn at the
  render scale (0.75 by default) and scaled up.
- **Movies.** Bink video is not available in the upstream port, so the game
  skips its movies.
- **Network play.** The launcher turns internet play off
  (`network.online = false`).
- **Late objects.** The first time each combination of shaders is drawn,
  it is compiled on the program builder's thread (220 to 250 ms) and what
  it draws is skipped until then; the cache in `save/shaders/` keeps it for
  later launches. Loading a cached program takes about 2 ms, also beside
  the GL thread.
- **New-area frames.** Shaders are translated, and textures decoded and
  uploaded, beside the game's thread; what they are drawn on appears a frame
  or a few late the first time. Instanced model variants are still
  translated on the game's thread.
- **Checkpoints.** A checkpoint copies the 16 MB game state in about 14 ms
  of the game's thread.
- **Late frames.** Where the GPU is the limit (the b30 battle, big
  translucent effects) a frame it finishes after about 1.5 ms before its
  refresh is shown a refresh late, and the frames after it follow it until
  one is due two refreshes after the one before: the motion steps on about
  one frame in six. Next: a render scale that drops while the GPU is behind
  (dynamic resolution), and cheaper large translucent effects.
