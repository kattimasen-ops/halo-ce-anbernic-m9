# Performance of Halo CE on the RG35XX H

This page records how the port got from its first working build to the
current frame rates, what was measured along the way, and what turned out not
to matter. The current numbers are in the [README's performance
table](../README.md#performance).

All measurements are on an Anbernic RG35XX H (Allwinner H700: 4x Cortex-A53
at 1.5 GHz, Mali-G31 MP2, 1 GB RAM) with Knulli Gladiator II and stock
thermal limits.

## Method

- Each run loads a level through `init.txt` (`map_name levels\a30\a30`) and
  plays its opening for 60 to 150 seconds, with `HALO_FPS_LOG=5` writing the
  frame rate, the longest frame, the temperature and the clocks to the log
  every 5 seconds. The figures below are the last samples of a run.
- Runs start from the same temperature: the benchmark script waits until the
  CPU is below 50 °C. At 70 °C the kernel lowers the CPU from 1512 to 1416 MHz
  and the GPU from 648 to 600 MHz, which moves the result by several frames
  a second.
- The beach battle in b30 varies from run to run; a difference of 2 or 3 fps
  there is within the noise. The a30 opening is much more repeatable.
- The instruments are in the host and the renderer: `HALO_GL_TIMING` (the time
  of each GL function on the GL thread), `HALO_GPU_PASS_TIMING` (finishes the
  GPU at each render-target change and times each pass; it slows the game
  down, so only its relative numbers count), `HALO_DEBUG_TINY_SCISSOR` (each
  draw writes one pixel), `HALO_DEBUG_LOD_BIAS`, `HALO_DEBUG_FREEZE` and
  `HALO_DEBUG_SKIP_GL`, and a sampling profiler (`HALO_PROFILE_HZ`). They are
  listed in [port/knulli/README.md](../port/knulli/README.md#tools-for-performance-work).

## The two limits of this platform

### The Mali driver's CPU cost per draw call

On the Cortex-A53, Arm's driver spends about 28 µs of CPU time on each draw
call: validating state, building descriptors and job chains. Of that, a
texture bind costs about 8 µs and a program switch about 4.5 µs. A frame of
the a30 opening has about 450 draws. Before the GL thread this ran on the
game's own thread; with the GL thread it runs on another core, and at render
scale 0.75 that thread spends 23 to 28 ms a frame inside the driver. This is
the limit at the default settings: the driver alone allows at most about 35
to 40 fps in a busy scene.

### Render-target switches on a tile-based GPU

The Mali-G31 draws a render target a tile at a time in on-chip memory. When
the renderer switches to another target and back, the GPU writes the whole
main target out to memory and reads it back in. The Xbox renderer does this
freely. The clearest case is the object shadows: each shadow switched to the
shadow targets, drew the object's silhouette, blurred it in two more passes
and switched back. In the a30 opening at render scale 0.75 the game ran at
about 24 fps with shadows and about 38 fps with them turned off.

### GPU work at 640x480

At the full resolution the GPU itself is the limit: about 28 ms of fragment
(pixel) work and about 18 ms of vertex and tiler work per frame in a busy
scene. When every draw was limited to one pixel (`HALO_DEBUG_TINY_SCISSOR`)
the GPU-timed b30 run went from about 12.5 to about 22 fps, so pixels are a
large part of it; the rest is geometry. This is why the render scale helps
so much once the pipeline stalls were removed.

## The optimisation history

Approximate frame rates at each step. The early steps were measured at
640x480 in a30, the later ones at render scale 0.75; the build changed in
between, so compare within a step rather than across the whole list. The
batching runs in b30 predate the readback fix, when the render scale made
little difference to the frame rate.

| Step | Scene | Before | After |
| --- | --- | --- | --- |
| First working build (GPU at the governor's 420 MHz) | a30, 640x480 | — | 15 |
| CPU `performance` governor, GPU held at 648 MHz | a30, 640x480 | 15 | 18 |
| Ranged draws, right-sized constant arrays, sampler objects | a30, 640x480 | 18 | 19 |
| GL thread | a30, 640x480 | 19 | 20 |
| Program binary cache | a30, 640x480 | 20 | 20, without the 60 ms link stutters |
| Quad batching and decal ordering | b30 | about 22 | about 25 |
| Asynchronous occlusion readback | b30, 0.75 | about 23 | about 31 |
| Code-quality pass on the renderer and the GL thread | b30, 0.75 | about 31 | about 33–36 |
| Model LOD scaling (`display.model_detail` 0.5) | a30, 0.75 | 24.0 | 25.3 |
| Shadows in two passes | a30, 0.75 | 25.3 | 25.7 |
| Shadow blur folded into the projection shader | a30, 0.75 | 25.7 | 31–32 |
| Vertex shaders write only what the pixel shader reads, point size only for points | a30, 0.75 | 31–32 | 36 |
| Water bump map at the frame's start, alpha test dropped where it cannot fail, depth not written out | a30, 0.75 | 36 | 40 |
| Skinned models' constants in a uniform block; streaming buffers mapped for good | a30, 0.75 | 40 | 40 (GL thread time down, GPU now close to the limit) |
| Opaque models drawn sorted by shader | a30, 0.75 | 40 | 40 (program switches 190 to 109 a frame) |
| Water bump map levels drawn into the sampled texture, not copied | a30, 0.75 | 40 | 49 |
| Skinned models' constants in two blocks (per part, and per object's nodes, written only as far as the nodes go); streaming buffers mapped as cached memory | a30, 0.75 | 49 | 49–51 (buffer writes 2.9 ms to 1.9 ms a frame) |

Notes on the steps:

- **Clocks.** The GPU's devfreq governor kept it at 420 MHz under load.
  Writing the top frequency to `min_freq` holds it at 648 MHz while the game
  runs (the launcher restores the old value on exit).
- **GL thread.** At 640x480 the gain was small because the GPU was the limit.
  Its value shows at lower render scales, where the driver's CPU time is the
  limit and now overlaps with the game's own work.
- **Program binary cache.** A program link takes about 60 ms on this GPU.
  Caching the driver's binaries removed the stutters when new shader
  combinations appear; the average frame rate was unchanged.
- **Quad batching and decal ordering.** In the b30 battle about 700 decal
  draws a frame become about 20, and batches of about 500 quad draws become
  21 to 65 draws. This cuts the driver's per-draw time on the GL thread.
- **Asynchronous occlusion readback.** This was the largest pipeline fix.
  Before it, lowering the render scale in b30 barely helped (about 21 fps at
  1.0, about 23 at 0.75), because the game waited for the GPU's visibility
  results once a frame and so held the game, the GL thread and the GPU in
  lockstep. Reading results the GPU finished a frame or two earlier removed
  the wait, and the render scale started to pay off (about 31 fps at 0.75).
- **Code-quality pass.** A tidy-up of the renderer and the GL thread (one
  stream reservation per batch, a static quad index buffer, the GL thread's
  producer and consumer on separate cache lines). The b30 result rose from
  about 31 to 33–36 fps and the driver time fell from 27–28 to 23–27 ms a
  frame, but the battle varies between runs: read it as no regression rather
  than a proven gain.
- **Model LOD scaling.** Switching to simpler models sooner: 24.0 fps at the
  game's own switch points (1.0), 25.3 at 0.5, 26.4 at 0.3 in a30. The default
  is 0.5.
- **Shadows.** Drawing every shadow's texture first and then projecting all
  of them without leaving the main target gained little on its own, because
  the blur passes still switched targets. Folding the blur into the shader
  that projects the shadow removed those passes, which took a30 from 25.7 to
  31–32 fps. For comparison, turning the blur off entirely gave about 34 to
  35 fps, and turning the shadows off about 38.
- **Vertex shaders sized to their pixel shaders.** Arm's Mali Offline
  Compiler (`malioc -c Mali-G31`) showed every translated vertex shader bound
  by load/store (21 to 33 cycles a vertex) rather than arithmetic (3 to 24).
  The translator wrote every Xbox output register (four texture coordinates,
  four colours, fog) and the point size for every vertex. Writing
  `gl_PointSize` stops the Mali compiler from splitting the shader into a
  position shader and a varying shader, so every vertex paid the full cost,
  including those of triangles culled as back-facing or off screen. Now each
  program's vertex shader writes only the outputs its pixel shader reads, and
  the point size only for point draws. One shader went from 22 load/store
  cycles a vertex to 1 for the position shader and 7 for the rest. The GPU's
  vertex and tiler time in a30 fell from about 23 to 13.5 ms a frame, the
  driver's CPU time a draw from 26 to 19 µs, and a30 rose from 31–32 to 36
  fps.

- **Alpha test that cannot fail.** Most model pixel shaders ended in an alpha
  test (`discard`) of an opaque texture's alpha, which can never discard but
  makes Mali give up its hidden surface removal (forward pixel kill), so
  every overlapping layer of the Pelican's parts was shaded. Textures are
  now known to be opaque from their texels as they are decoded, and such
  draws use a shader without the test: a30 went from 36 to 40 fps with it,
  and stays at 36 without it (`HALO_ALPHA_TEST_ELISION=0`). It costs program
  switches (about 85 a frame became about 190), which the driver pays for.
- **Uniform arrays against uniform blocks.** A microbenchmark on the
  handheld (`glbench`): a draw costs the driver about 6.5 µs to submit; 17.6
  µs when a constant of a 192-register array changed (it copies the array
  whole), 7.0 µs with a 16-register array, and 9.6 µs with the constants in a
  uniform block whose range is bound per draw. The skinned models index their
  constants and so declare all 192; they now read them from a block.
- **What limits the a30 opening now.** A frame-time histogram (every frame
  22 to 28 ms, with and without vsync) and the game's thread's waits (none
  for results or room, about 5.7 ms a frame for the GL thread to finish the
  frame before) show the GL thread limits it, at about 25 ms a frame. Of 423
  indexed draws a frame, 244 draw the same geometry with the same shaders and
  textures as another draw of the frame (six marines, repeated parts).
  Freezing the textures and the program (every draw keeping the state it
  finds, a wrong picture) took the frame rate to 53–55 fps: program switches
  are the driver's biggest cost per draw. Drawing the models sorted by
  shader is the next step.

- **A stall hidden in the water.** Turning the water off took a30 from 40 to
  52 fps, though its drawing costs the GPU about 1 ms. The game draws the
  water's bump map one mip level at a time into four render targets, and
  the port copied them into one mipmapped texture (`glCopyImageSubData`)
  whenever the water was drawn, twice a frame: copies between render targets
  made Mali's driver wait for the GPU in the middle of the frame, taking the
  overlap of the CPU and the GPU away. The levels are now drawn into the
  sampled texture's own levels, and the copies are gone: 49 fps. Copying by
  blits instead was worse (30 fps).
- **Models sorted by shader.** Objects are kept between the model phase's
  begin and end and their parts drawn sorted by shader, permutation and
  geometry; objects with transparent parts or decals (drawn at once) are
  drawn in place. It cut the program switches from about 190 to 109 a frame
  and the texture binds from 594 to 393; on its own the frame rate stayed
  at 40, because the water's stall was the limit. Both the game's thread and
  the GL thread are now busy all of the frame, at about 20 ms each.

- **Writing to the GPU's buffers.** Skipping the copies into the streaming
  buffers (a wrong picture) took the buffer writes from 2.7 ms to 0.09 ms a
  frame: the time was the copying itself, into memory the CPU does not cache
  (about 370 MB/s), some 1 MB a frame of vertex constants. A mapping that may
  also be read is cached memory on Mali: writes then cost about 3 µs instead
  of 6. The skinned models' constants are now two blocks: the registers below
  60 (per part) and the object's nodes from 60, written only as far as its
  nodes go and found again when the same nodes are bound again.
- **Where a30 stands.** At about 50 fps the game's thread and the GL thread
  are both busy all the frame (about 20 ms each). The GL thread's time is
  the driver's (about 17 µs a draw, some 460 draws), the buffer writes, and
  waits at changes of render target; the game's thread spends about a
  quarter of its time in the renderer's per-draw work (`prepare_draw`).

## What did not help, or was not the limit

- **Texture bandwidth.** Sampling mip levels 16 times smaller
  (`HALO_DEBUG_LOD_BIAS=4`) changed the GPU-timed b30 run from about 12.5 to
  about 13 fps. Texture bandwidth is not what limits the GPU. The 16-bit
  textures are kept because they halve the texture memory.
- **fp16 arithmetic.** Half-precision shaders on and off gave the same GPU
  time within the noise (about 12.6 and 13 fps in the GPU-timed b30 runs).
  Shader arithmetic is not the limit either. The setting stays on, since it
  costs nothing.
- **Individual render features.** Turning the renderer's features off one at
  a time (fog, environment decals, specular lights, reflections, detail
  objects, lens flares, bump mapping, the motion sensor, screen effects)
  changed the b30 frame rate by about 2 fps or less each in an earlier build,
  close to the battle's run-to-run noise. No single feature was expensive;
  the cost is spread over many draws.
- **Three framebuffers instead of two.** No change (a30 at 0.75: 24.0 and
  23.9 fps).
- **Letting the game run two frames ahead of the GL thread**
  (`HALO_GL_THREAD_FRAMES=2`). No change (25.7 fps either way).
- **Clearing the blur target first**, so that the tiler does not read its old
  contents, and **batching the blur passes**. No measurable change (25.7 fps);
  the target switches themselves were the cost.
- **Skipping GL calls to measure them.** Skipping every `glBindTexture` gave
  black, invalid frames, so the numbers were meaningless. Freezing the state
  (`HALO_DEBUG_FREEZE`) was used instead to estimate the cost of each kind of
  state change.

## Where the time goes now

The goal is 60 fps (16.7 ms a frame) in the a30 opening. Measured there at
the default render scale of 0.75, the GPU's vertex and tiler work is about
13.5 ms a frame and its pixel work about 16 ms; the GL thread's driver time
is about 16 ms plus waits for the GPU; the game's own thread about 19 ms. All
of them have to come down. The ideas with the most expected payoff:

1. Draw the HUD at full resolution when the render scale is below 1.
2. Cut the driver's per-draw cost further: merge uniform uploads into one
   array, reduce texture rebinds, and merge the environment's lightmap and
   diffuse passes (a large engine change).
3. Train a profile-guided optimisation profile on the device (the guest uses
   upstream's x86 Linux profile).
