# Profiling and measuring the port

This guide describes every instrument built into the port and the scripts
that drive it on the handheld: the frame-rate log and its frame-time
histogram, the GL call timer with the game's thread's waits and the GL
thread's own operations, the GPU pass timer and its traces, the sampling
profiler, the draw-caller statistics, the switches that remove one kind of
work to measure it, and the shader dump for Arm's Mali Offline Compiler. For
each it shows how to turn it on, what it prints, with short excerpts from
real benchmark logs, and how to read it. It ends with the method this
project used to find which of the game's thread, the GL thread and the GPU
limits a scene. The settings themselves are listed in
[Configuration](CONFIGURATION.md); the results are in
[Performance](PERFORMANCE.md) and [Mali-G31 notes](MALI-G31-NOTES.md).

The excerpts are shortened (timestamps and some lines removed). Most come
from runs of the a30 opening at render scale 0.75. Several are from earlier
builds and are marked so; their numbers illustrate the format, not the
current performance.

## Contents

- [Running measurements](#running-measurements)
- [The instruments at a glance](#the-instruments-at-a-glance)
- [HALO_FPS_LOG](#halo_fps_log)
- [debug.gpu_stats](#debuggpu_stats)
- [HALO_GL_TIMING](#halo_gl_timing)
- [HALO_GPU_PASS_TIMING](#halo_gpu_pass_timing)
- [HALO_PROFILE_HZ and profile.py](#halo_profile_hz-and-profilepy)
- [HALO_DEBUG_DRAW_CALLERS](#halo_debug_draw_callers)
- [Switches that remove work](#switches-that-remove-work)
- [HALO_GPU_DUMP_SHADERS and the Mali Offline Compiler](#halo_gpu_dump_shaders-and-the-mali-offline-compiler)
- [Method: finding what limits a scene](#method-finding-what-limits-a-scene)
- [Measurement hygiene](#measurement-hygiene)

## Running measurements

The scripts in `tools/` drive the handheld over ADB on USB
([tools/README.md](../tools/README.md)). Set `ADB` if `adb` is not on your
`PATH`. On Windows, run them from Git Bash; under WSL, use a Linux `adb`.

Before a session:

1. Install the port in `/userdata/roms/ports/halo/` ([Install](INSTALL.md)).
2. Stop EmulationStation, since the scripts start the game themselves:
   `adb shell /etc/init.d/S31emulationstation stop`.
3. Keep the handheld awake. Knulli's battery saver dims the screen after a
   while without input and later suspends the handheld, which drops USB.
   `tools/keepalive.sh` (on the computer) or `tools/device/keepalive.sh`
   (on the handheld, started with `setsid`) touches `/dev/input`, which the
   battery saver counts as activity. `tools/bench.sh` also holds the
   battery saver's pause file for the length of each run.

**`tools/bench.sh <level> <seconds> <label> [HALO_X=value ...]`** runs one
benchmark:

1. It writes an `init.txt` that turns on the game's frame-rate display
   (`display_framerate true`), runs the console commands in `INIT_EXTRA`
   (separated by `;`) and loads `levels\<level>\<level>`.
2. On the handheld it waits until the CPU is below `COOL_TO` (default
   50 °C), then starts `tools/device/run.sh`, which pins the clocks as the
   launcher does, sets the number of framebuffers (`HALO_FB_BUFFERS`,
   default 2), and runs the game with `HALO_FPS_LOG=5`,
   `HALO_EXIT_AFTER=<seconds>` and the extra `HALO_*` assignments.
3. It takes screenshots at 60% and 90% of the run, samples the threads' CPU
   use with `top`, and waits for the game to exit.
4. It saves everything in `bench/<label>/` on the computer: `run.log` (the
   game's log), `shot1.png`, `shot2.png`, `init.txt`, `device.sh` (the
   exact commands run on the handheld) and `profile.txt` if the profiler
   ran. It prints the `fps` lines and any errors.

```sh
tools/bench.sh a30 80 a30-baseline HALO_RENDER_SCALE=0.75
tools/bench.sh a30 80 a30-gltiming HALO_RENDER_SCALE=0.75 HALO_GL_TIMING=1
INIT_EXTRA='rasterizer_water false' tools/bench.sh a30 80 a30-nowater HALO_RENDER_SCALE=0.75
grep 'fps ' bench/a30-baseline/run.log
```

Start EmulationStation again afterwards
(`adb shell /etc/init.d/S31emulationstation start`), or reboot.

Without the scripts, set the variables in `Halo.sh` (`export HALO_FPS_LOG=5`
before `./halo`) and read `halo/log.txt` after the run.

## The instruments at a glance

| Instrument | Turn on with | Output | Cost to the run |
| --- | --- | --- | --- |
| Frame rate, histogram, temperature, clocks | `HALO_FPS_LOG=<seconds>` | `fps` and `frame times` lines | None measurable |
| Renderer statistics | `HALO_GPU_STATS=1` (`debug.gpu_stats`) | `frame N:`, `high constants`, `buffer writes`, `quad batches` lines | Small |
| GL call timer, waits, host operations | `HALO_GL_TIMING=1` with `HALO_FPS_LOG` | `gl:` lines | A timer stub around every GL call |
| GPU time per pass | `HALO_GPU_PASS_TIMING=1` | `gpu:` lines | Large: the GPU is finished at every change of target |
| One frame's passes, draws | `HALO_GPU_PASS_TIMING=2`, `3` | `trace:`, `draw:` lines | Large, for one frame |
| Slow calls | `HALO_GPU_PASS_TIMING=4` | `call:` lines | Small, for three frames |
| Sampling profiler | `HALO_PROFILE_HZ=<rate>` | `profile.txt`, read with `profile.py` | A signal per thread per sample |
| Draw callers, repeated draws, sorting | `HALO_DEBUG_DRAW_CALLERS=1` to `4` | `draw callers`, `draw signatures`, `sorted models` lines | Small; 4 removes draws |
| Frozen state | `HALO_DEBUG_FREEZE=textures,program,raster` | frame rate | Wrong picture |
| No pixels | `HALO_DEBUG_TINY_SCISSOR=1` | frame rate, GPU time | Wrong picture |
| Smaller mip levels | `HALO_DEBUG_LOD_BIAS=<levels>` | frame rate, GPU time | Blurry picture |
| Skipped GL calls | `HALO_DEBUG_SKIP_GL=glA,glB` | frame rate | Often an invalid picture |
| Generated shaders | `HALO_GPU_DUMP_SHADERS=<folder>` | GLSL files and `shaders.txt` | Small |

## HALO_FPS_LOG

`HALO_FPS_LOG=<seconds>` (`frame_statistics` in
`port/knulli/host/host_sdl2.c`) logs two lines at that interval, counted at
each buffer swap on the GL thread:

```
I halo: fps 51.3, longest frame 32.2 ms, resident 311 MB, 68 C, cpu 1512 MHz, gpu 648 MHz
I halo: frame times: 0 under 15 ms, 25 15-18, 219 18-22, 12 22-28, 1 28-35, 0 over 35
```

- `fps`: frames swapped over the interval.
- `longest frame`: the longest time between two swaps in the interval.
- `resident`: the process's resident memory.
- `C`: `/sys/class/thermal/thermal_zone0/temp`.
- `cpu` and `gpu`: the current frequencies (`cpu0`'s `scaling_cur_freq` and
  the GPU's devfreq `cur_freq`). At 70 °C the kernel lowers them to 1416 and
  600 MHz; a line that shows them marks a throttled sample.
- `frame times`: how many frames fell in each band. With vsync on a 60 Hz
  screen, frames paced by the display land on multiples of 16.7 ms (15 to
  18 ms, or 28 to 35 ms for two refreshes). Frames spread across 18 to
  28 ms mean a thread or the GPU sets the pace, not the display.

In the excerpt (a30 opening, about 51 fps) most frames take 18 to 22 ms:
something takes about 20 ms a frame. On an earlier build that ran at
40 fps, the same scene gave

```
I halo: frame times: 0 under 15 ms, 0 15-18, 2 18-22, 196 22-28, 2 28-35, 0 over 35
```

with vsync and nearly the same without it (`HALO_SWAP_INTERVAL=0`): every
frame 22 to 28 ms either way, so the display was not the limit.

The first interval includes the level's loading; read the later ones.

## debug.gpu_stats

`HALO_GPU_STATS=1` makes the renderer log its counts every 60 frames
(`D3DDevice_Present` in `d3d8_gl.c`):

```
W halo: halo-linux: frame 900: 421 draws, 20 immediate, 2 clears, 9 target changes; skipped 0 no program, 0 no target, 0 link; 2278 KB mirrored, 50 KB streamed
W halo: halo-linux: high constants: 59 found again, 106 written (a frame)
W halo: halo-linux: buffer writes: 625 a frame, 894 KB (vertex constants 337 KB, mirror pages 0 KB)
W halo: halo-linux: quad batches: 105 quad draws in 34 draws
```

- The first line gives per-frame averages: draws from vertex buffers,
  immediate-mode draws, clears, render-target changes, draws skipped (no
  program, no target, a failed link), and the vertex and index bytes drawn
  from the mirror and streamed.
- `high constants`: for programs with two constant blocks, how often an
  object's node matrices were found already written this frame, and how
  often they were written ([Architecture](ARCHITECTURE.md#vertex-constants)).
- `buffer writes`: the writes into the GL buffers a frame (the stream and
  index buffers, and pages of the mirror) and their bytes, with the vertex
  constants' and the mirror pages' share. Each is a host operation on the GL
  thread, which `HALO_GL_TIMING` times as `buffer write (named)`.
- `quad batches`: quad draws, and the draws the batching made of them.

## HALO_GL_TIMING

`HALO_GL_TIMING=1` wraps every GL function the guest imports in a timer
stub (`port/knulli/host/host_gl_timing.c` and `.S`): the stub reads the
generic timer before and after the driver's function and adds the time to
the function's slot. The report comes with each `HALO_FPS_LOG` interval, so
set both. It covers the thread that makes the GL calls: the GL thread, or
the game's thread with `HALO_GL_THREAD=0`.

Excerpt, a30 opening, about 51 fps:

```
I halo: gl: 15.46 ms a frame in the driver's functions
I halo: gl:   glDrawRangeElementsBaseVertex   456.0 calls   7.817 ms   17.1 us each, longest  1610.5 us from 55635f559c
I halo: gl:   glBindFramebuffer               25.0 calls   2.619 ms  104.8 us each, longest  1379.0 us from 55635f559c
I halo: gl:   glUniform4fv                   561.6 calls   1.311 ms    2.3 us each, longest   356.1 us from 55635f559c
I halo: gl:   glDrawArrays                    26.0 calls   0.930 ms   35.8 us each, longest  1096.4 us from 55635f559c
I halo: gl:   glClear                          9.0 calls   0.813 ms   90.3 us each, longest 11856.0 us from 55635f559c
I halo: gl:   glBindTexture                  386.0 calls   0.472 ms    1.2 us each, longest   423.7 us from 55635f559c
I halo: gl:   glUseProgram                   109.0 calls   0.202 ms    1.9 us each, longest   229.1 us from 55635f559c
...
I halo: gl:   draws after another with nothing between 0.0, vertex data only 42.0, and uniforms 2.0, other state 445.3
I halo: gl:   the game's thread waited: 0.0 synchronous calls 0.00 ms, 0.0 times for room 0.00 ms, for the frame before 0.47 ms (a frame)
I halo: gl:   (host) swap                      1.0 calls   0.161 ms
I halo: gl:   (host) ?                         1.0 calls   0.013 ms
I halo: gl:   (host) fence                     1.0 calls   0.046 ms
I halo: gl:   (host) wait for a frame          1.0 calls   0.010 ms
I halo: gl:   (host) buffer write (named)    623.5 calls   2.422 ms
```

**The function table.** The total time a frame in the driver's functions,
then the 16 most expensive functions: calls a frame, time a frame, time a
call, and the longest call with its return address. With the GL thread the
address is in the host's replay code, so it says little; the functions'
names and counts say more. A draw's time is where the driver does most of
its deferred work (validating the state changed since the last draw), so
the cost of a state change often shows up in the next draw rather than in
the call that changed it. `glBindFramebuffer` can include the driver's work
at the end of a pass, and a single very long `glClear` or
`glBindFramebuffer` can mean that the driver waited for the GPU;
`HALO_GPU_PASS_TIMING=4` tells which.

**The adjacency line** (`host_glthread.c`) sorts the draws by what came
between them and the draw before: nothing, only vertex data (buffer writes,
attribute pointers), vertex data and uniforms, or other state. Draws with
nothing or only vertex data between them could have been one draw.

**The game's thread's waits.** Per frame: how many synchronous calls it made
and how long it waited for them, how often and how long it waited for room
in the queue, and how long it waited at the swap for the GL thread to finish
the frame before (frame pacing). A long wait for the frame before means the
game's thread had time to spare: the GL thread, or the GPU behind it, set
the pace. A wait near zero means the game's thread was busy all the frame.

**The host operations** are the work the host queues to the GL thread,
timed there: `swap` (`SDL_GL_SwapWindow`, including any wait for the
display or for a free buffer), `fence`, `wait for a frame` (waiting on the
GPU's fence before reusing a stream-buffer slot), `buffer write (named)`
and `buffer write` (copies into the mapped stream buffers), and
`reserve names`. Operations without a name show as `?`: the one called once
a frame is the visibility counters' copy (`host_gl_visibility_frame`), and
the one at start-up gives the stream buffers their storage.

**Reading the excerpt.** At 51.3 fps a frame lasts about 19.5 ms. The GL
thread spent 15.46 ms in the driver and about 2.7 ms in host operations,
about 18 ms in all; the game's thread waited 0.47 ms a frame. Both threads
were busy nearly the whole frame. On the 40 fps build the same line read
`for the frame before 5.71 ms`: the game's thread waited more than 5 ms a
frame, and the GL thread was the limit. After the game's thread was made
cheaper (a faster `memcmp` and `memcpy` in the guest, and the GL queue
published in 4 KB steps), it waits about 1.5 to 1.9 ms a frame: the GL
thread is the limit again.

The timer's own clock reads cost the GL thread time, and they show in the
frame rate when the GL thread is the limit: in the a30 opening the current
build runs at 51.5 to 52 fps with `HALO_GL_TIMING` and 52 to 54 fps without
it. Take frame rates from runs without the timer.

## HALO_GPU_PASS_TIMING

The Mali driver has no timer queries, so the port measures the GPU by
finishing it. `HALO_GPU_PASS_TIMING` (`port/knulli/host/host_glthread.c`)
runs in the GL thread's replay loop and needs the GL thread.

**`=1`: time per render target.** At each change of draw framebuffer, the
GL thread flushes and then finishes the GPU. Mali starts a pass's work when
it is flushed, so each pass's time splits into the calls that made it
(issue, until the flush) and the GPU's work (from the flush to the finish).
Every 150 frames it logs the frame's total and the 16 longest targets
(framebuffer 0 is the window):

```
I halo: gpu: 66.73 ms a frame in 25 targets, 46.30 ms of it the GPU's
I halo: gpu:   framebuffer 511   61.05 ms (gpu  42.92)   4.0 passes  465.1 draws  1.0 clears
I halo: gpu:   framebuffer 510    0.97 ms (gpu   0.54)   1.0 passes    1.0 draws  0.0 clears
I halo: gpu:   framebuffer   0    0.91 ms (gpu   0.62)   2.0 passes    0.0 draws  1.0 clears
I halo: gpu:   framebuffer 484    0.50 ms (gpu   0.24)   1.0 passes    2.0 draws  1.0 clears
```

(An earlier build. The primary target, framebuffer 511, was drawn in four
passes a frame.) The waits slow the game down (this run showed 15 fps), and
nothing overlaps, so the absolute numbers are inflated: compare shares
between targets, and compare runs that differ in one thing. Turning the
renderer's features off one at a time under this timer, with `INIT_EXTRA`,
shows each feature's GPU time.

**`=2`: one frame's passes in order.** As 1, and frame 750 is traced: each
pass is logged as it ends, with its draws, clears and copies (copies, blits,
mipmap generation and invalidations):

```
I halo: trace: pass  6 framebuffer 511  332 draws 0 clears 4 copies, issue   9.87 ms, gpu  17.80 ms
I halo: trace: pass  7 framebuffer 500    1 draws 1 clears 0 copies, issue   0.65 ms, gpu   0.41 ms
...
I halo: trace: pass 13 framebuffer 511  129 draws 0 clears 4 copies, issue   5.28 ms, gpu   5.74 ms
I halo: trace: pass 14 framebuffer 484    2 draws 1 clears 0 copies, issue   0.54 ms, gpu   0.28 ms
I halo: trace: pass 15 framebuffer 511    5 draws 0 clears 0 copies, issue   0.34 ms, gpu   0.33 ms
```

(An earlier build.) This shows where the primary target's pass is split,
and by what: here by six small targets between passes 6 and 13, and by
target 484 before pass 15.

**`=3`: one frame's draws.** As 2, and in the traced frame every draw is
finished by itself and its GPU time logged, with the GL program's name and
the draw's count:

```
I halo: draw: pass  6 framebuffer 511 program   41 count     53 gpu   0.212 ms
I halo: draw: pass  6 framebuffer 511 program   42 count     53 gpu   0.625 ms
I halo: draw: pass  6 framebuffer 511 program   43 count    421 gpu   0.212 ms
```

Each time includes a load and a store of the target's tiles, so only the
differences between draws mean something. The program names match the
`program` lines of `shaders.txt` from `HALO_GPU_DUMP_SHADERS`, which name
the shader files to analyse (below).

**`=4`: slow calls.** No pass timing and no finishing. In frames 1500 to
1502, it logs every change of framebuffer, every GL call and host operation
that took more than 0.3 ms, and the swap, with the time since the frame
began:

```
call: at <ms into the frame> function <n> kind <k> (<first two arguments>) <ms>
call: at <ms into the frame> host <operation> <ms>
call: at <ms into the frame> the swap
```

`function` is the index in the generated function list
(`build/knulli/host_glthread_gen.c`); `kind` is 1 for a framebuffer bind, 2
a draw, 3 a clear, 4 vertex data, 5 a uniform, 6 a copy and 0 anything
else. With the GPU running as it normally does, a call that takes
milliseconds is the driver waiting for the GPU. This is how a stall in the
middle of the frame shows itself, such as the water's render-target copies
([Mali-G31 notes](MALI-G31-NOTES.md#copies-between-render-targets)).

## HALO_PROFILE_HZ and profile.py

The handheld has no `perf`. `HALO_PROFILE_HZ=<rate>`
(`port/knulli/host/host_profile.c`) starts a thread that sends `SIGPROF` to
every thread of the process at that rate, after `HALO_PROFILE_DELAY`
seconds. Each sample records the thread, the program counter, the link
register and up to eight frame records. Frame records are followed only on
stacks the host made for guest threads, so the game's threads get their
call chains, and the GL thread and the driver's threads get their function
and its caller only. Up to 262,144 samples are kept.

The samples are written when the game exits, to `HALO_PROFILE_FILE`
(default `profile.txt` in the data folder), after the process's memory map
and each thread's name and CPU time. The game must exit normally: use the
exit combination or `HALO_EXIT_AFTER` (as `tools/bench.sh` does, which also
sets `HALO_PROFILE_FILE=/tmp/profile.txt` and pulls the file). The thread
list alone is useful. From an a30 run at about 49 fps
(`HALO_PROFILE_HZ=500 HALO_PROFILE_DELAY=40`):

```
# threads: tid name utime stime (clock ticks)
thread 16414 halo 6440 126
thread 16423 mali-cmar-backe 678 532
thread 16424 halo-gl 5706 416
thread 16430 SDLAudioP2 27 32
```

The game's thread and the GL thread use similar CPU time; the Mali driver's
back-end thread comes next.

`port/knulli/profile.py` turns the file into a report:

```sh
python3 port/knulli/profile.py bench/a30-profile/profile.txt \
    --guest work/halo-ce-universal/build/android/halo_guest.elf \
    --lib <folder> [--top 40] [--thread <tid>]
```

- `--guest`: the guest image of the same build that ran. Addresses from
  `0x88000000` to `0x89000000` are symbolized against it.
- `--lib`: a folder with the host `halo` of the same build and the device's
  libraries, each named exactly as the memory map at the top of
  `profile.txt` names it on the device, for example `libc.so.6`,
  `libmali.so.0.20.0` and `libSDL2-2.0.so.0.3000.12`. Other addresses are
  symbolized against the file of the same name there. `libmali` is stripped,
  so its names are only the nearest exported symbol below the address (for
  example `glDrawRangeElementsBaseVertex+0x...`). Addresses in files that are
  not there show as the mapping's name.
- It needs `llvm-symbolizer-22` (or `llvm-symbolizer`) and `llvm-nm-22`.
  It calls the symbolizer with `--no-inlines`, so that each address gives
  one line and inlined frames in the host do not shift the names.

The report lists the samples per thread, with each thread's CPU ticks, and
then for the four busiest threads (or `--thread`) two tables: **self**, the
share of samples in each function, and **inclusive**, the share of samples
with the function anywhere on the recorded stack. On the game's thread,
the inclusive share of the renderer's per-draw functions (`prepare_draw` and
what it calls) is the cost of the Direct3D translation; in the a30 opening
it was about a quarter of the thread.

## HALO_DEBUG_DRAW_CALLERS

`HALO_DEBUG_DRAW_CALLERS` (`debug.draw_callers`) counts the draws of each
caller of the renderer's draw functions (`draw_caller_count` in
`d3d8_gl.c`) and logs, every 300 frames, the draws a frame and the 24
busiest callers with their draws and vertices a frame. `2` counts the
callers' callers instead:

```
W halo: halo-linux: draw callers: 335 draws a frame
W halo: halo-linux: draw callers:   880581c4  104.2 draws    36741 vertices
W halo: halo-linux: draw callers:   880c2fd0   52.1 draws      208 vertices
W halo: halo-linux: draw callers:   8813ae58   36.9 draws     2870 vertices
```

(An earlier build.) The addresses are return addresses in the guest image.
Symbolize them against the image of the same build:

```sh
llvm-symbolizer-22 --obj=work/halo-ce-universal/build/android/halo_guest.elf 0x880581c4
```

`3` adds two reports. Every 300 frames, how many indexed draws repeat a draw
of the same frame (the same vertex shader, textures, vertex buffer, index
data and count, primitive, blending, culling and pixel shader layout): these
could be drawn as instances.

```
W halo: halo-linux: draw signatures: 423 indexed draws a frame, 244 of them repeat a draw of the frame (55 groups), 36 repeat the draw just before
```

And every 600 model phases, how the model sorting fared: the draws kept for
sorting, how often the kept draws were flushed, and how often an object had
to be drawn in place for a transparent part or a decal:

```
W halo: halo-linux: sorted models: 112 kept draws, 7 flushes, drawn in place for a transparent part 15, for a decal 3 (a phase)
```

`4` is 3 with the repeated indexed draws left out (the picture misses
them), to measure what instancing could gain at most.

## Switches that remove work

These change the picture on purpose. Each removes one kind of work, and the
change in frame rate or GPU time is that work's cost. Run them in the same
scene as a baseline, one at a time.

| Switch | Removes | What it showed |
| --- | --- | --- |
| `HALO_DEBUG_FREEZE=textures`, `program`, `raster` | Draws keep the textures, program or raster state they find, after the first 600 frames. | a30, 40 fps build: `textures` 40 fps, `textures,program` 53 to 55 fps. Program switches were the driver's largest per-draw cost. |
| `HALO_DEBUG_TINY_SCISSOR=1` | All pixels but one per draw. | GPU-timed b30 at 640x480: about 12.5 to about 22 fps. Pixels were a large part of the GPU's work at full resolution. |
| `HALO_DEBUG_LOD_BIAS=4` | Texture bandwidth (levels 16 times smaller in each direction). | GPU-timed b30: about 12.5 to about 13 fps. Texture bandwidth is not the limit. |
| `HALO_FAST_SHADERS=0` | (Adds work) single precision everywhere. | GPU-timed b30: about 12.6 and 13 fps, the same within the noise. |
| `HALO_DEBUG_SKIP_GL=glA,glB` | The GL thread does not make these calls (with the GL thread only). | Skipping `glBindTexture` gave black, invalid frames; use the freeze instead for state. |
| `HALO_DEBUG_DRAW_CALLERS=4` | Repeated indexed draws. | An upper bound for instancing. |
| `INIT_EXTRA='<console global> false'` | A render feature, through the game's console globals: `rasterizer_water`, `render_shadows`, `rasterizer_models`, `rasterizer_lens_flares`, `rasterizer_environment_decals` and others. | Turning the water off took a30 from 40 to 52 fps though the water cost the GPU about 1 ms: a stall, not work ([Mali-G31 notes](MALI-G31-NOTES.md#copies-between-render-targets)). |

Temporary switches of this kind are also worth writing for a single
question and removing afterwards. One such switch, since removed, skipped
the copies into the mapped stream buffers (a wrong picture): the buffer
writes went from 2.7 ms to 0.09 ms a frame, so their time was the copying
itself, not the driver.

The optimisations can be turned off the same way, to measure them or to
rule them out: `HALO_SORT_MODELS=0`, `HALO_ALPHA_TEST_ELISION=0`,
`HALO_BATCH_QUADS=0`, `HALO_STABLE_STREAMS=0`, `HALO_GL_THREAD=0`,
`HALO_DEBUG_COPY_BY_BLIT=1` (the water's level copies as blits: 30 fps
against 40 with copies, before the copies were removed),
`HALO_GL_THREAD_FRAMES=2`, `HALO_SWAP_INTERVAL=0` and `HALO_FB_BUFFERS=3`
([Configuration](CONFIGURATION.md)).

## HALO_GPU_DUMP_SHADERS and the Mali Offline Compiler

`HALO_GPU_DUMP_SHADERS=<folder>` (`debug.gpu_dump_shaders`) writes each
shader the translators generate, as it is generated. The folder must exist.

| File | Contents |
| --- | --- |
| `vs<id>_<flags>.glsl` | A vertex shader: the vertex program's id (decimal) and the variant's flags (hex): bit 0 for immediate mode, and from bit 1 the outputs it writes (`XGPU_OUTPUT_*` in `xgpu.h` shifted left by one). |
| `ps_<hash>.glsl` | A pixel shader, named by the hash of its key. |
| `shaders.txt` | One line per shader, `shader <handle> <file>`, and one per program, `program <GL name> <vertex handle> <pixel handle>`. |

To find the shaders of a slow draw from `HALO_GPU_PASS_TIMING=3`, look up
its program name in `shaders.txt`, then the two handles.

Arm's Mali Offline Compiler, `malioc`, is part of the free Arm Performance
Studio. It compiles a shader for a given GPU and reports its cost per
vertex or per fragment on each unit (arithmetic, load/store, varying,
texture) and which unit bounds it:

```sh
malioc -c Mali-G31 --vertex vs012_01f.glsl
malioc -c Mali-G31 --fragment ps_1a2b3c4d.glsl
```

(The file names are examples of the pattern.) What to look for on the
Mali-G31:

- **Vertex shaders:** whether the compiler splits the shader into a
  position part and a varying part, and the load/store cycles. This project
  found every translated vertex shader bound by load/store (21 to 33 cycles
  a vertex) rather than arithmetic (3 to 24), because it wrote every Xbox
  output register and the point size. Writing `gl_PointSize` prevents the
  split. After the change, one shader went from 22 load/store cycles a
  vertex to 1 for the position part and 7 for the rest
  ([Mali-G31 notes](MALI-G31-NOTES.md#vertex-shader-outputs-and-gl_pointsize)).
- **Pixel shaders:** the bounding unit, and whether the shader can discard
  (an alpha test), which costs the GPU its hidden surface removal.

## Method: finding what limits a scene

A frame on this port is made by three workers that overlap: the game's
thread (simulation and the renderer's per-draw work), the GL thread (the
Mali driver's CPU work) and the GPU. The slowest sets the frame rate, and
the others wait. This is how the project found which one, scene by scene.

1. **Get a stable baseline.** Run the scene with `HALO_FPS_LOG=5` two or
   three times from the same temperature. Use the later samples and check
   the clocks in each `fps` line.
2. **Check the display.** If the frame-time histogram puts the frames on
   multiples of 16.7 ms, vsync sets the pace. If they spread in between,
   and turning vsync off (`HALO_SWAP_INTERVAL=0`) changes nothing, it does
   not.
3. **Compare the threads with the frame.** With `HALO_GL_TIMING=1`, add the
   driver's time and the host operations: that is the GL thread's work. If
   it is close to the frame time and the game's thread waits for the frame
   before, the GL thread (or a GPU stall inside it) is the limit. If the
   game's thread waits near zero and the GL thread has time to spare, the
   game's thread is the limit. If both are busy, both are.
4. **Check the GPU.** With `HALO_GPU_PASS_TIMING=1`, compare the GPU's share
   with the frame time, keeping in mind that the timer serialises everything.
   `HALO_DEBUG_TINY_SCISSOR` separates the pixel work from the vertex and
   tiler work; `HALO_DEBUG_LOD_BIAS` and `HALO_FAST_SHADERS=0` test texture
   bandwidth and arithmetic.
5. **Look for stalls.** A feature whose removal gains far more than its GPU
   time is a stall: something makes the driver or the game wait. Find it
   with `HALO_GPU_PASS_TIMING=4` (calls that take milliseconds) and
   `HALO_GPU_PASS_TIMING=2` (where the primary target's pass is split).
6. **Find the cost on the thread that limits.** For the GL thread:
   `HALO_GL_TIMING`'s table and `HALO_DEBUG_FREEZE` (which state changes
   cost the most), and `HALO_DEBUG_DRAW_CALLERS` (who makes the draws, and
   how many repeat). For the game's thread: the profiler.

The a30 opening went through these steps several times
([Performance](PERFORMANCE.md)):

- At 40 fps, every frame took 22 to 28 ms with and without vsync, and the
  game's thread waited about 5.7 ms a frame for the frame before: the GL
  thread limited, at about 25 ms a frame. Freezing the textures and the
  program gave 53 to 55 fps, so program switches were its largest cost. That
  led to drawing the models sorted by shader.
- Sorting cut the program switches from about 190 to 109 a frame, but the
  frame rate stayed at 40. Turning the water off gave 52 fps, although the
  water cost the GPU about 1 ms: a stall. The water's bump map levels were
  copied between render targets twice a frame, and the copies made the
  driver wait for the GPU in the middle of the frame. Drawing the levels
  into the sampled texture removed the copies: 49 fps.
- At about 50 fps, the GL thread spent about 18 ms of a 19.5 ms frame in
  the driver and in buffer writes, and the game's thread barely waited:
  both threads were busy all the frame, at about 20 ms each. The profiler
  showed musl's byte-by-byte `memcmp` at 6.2% of the game's thread (the
  renderer compares a few hundred bytes of state per draw) and the GL
  queue's publishing after every call at about 4.4%. With both fixed, a30
  runs at 52 to 54 fps and the game's thread waits 1.5 to 1.9 ms a frame:
  the GL thread is the limit, with 15.2 ms in the driver and 1.9 to 2.4 ms
  of buffer writes ([Roadmap](ROADMAP.md)).

## Measurement hygiene

- **The same scene, the same length.** Load the level through `init.txt`
  and play its opening for the same time. The a30 opening is much more
  repeatable than the b30 beach battle, which varies by 2 or 3 fps from run
  to run.
- **The same temperature.** Start each run below 50 °C (`COOL_TO`). At
  70 °C the kernel lowers the CPU from 1512 to 1416 MHz and the GPU from 648
  to 600 MHz, which moves the result by several frames a second. Check the
  clocks in the `fps` lines.
- **Before and after, back to back.** Build both versions, and run them one
  after the other under the same conditions.
- **Instruments change what they measure.** The pass timer serialises the
  GPU; the GL timer adds a stub to every call; the profiler interrupts every
  thread. Take frame rates with them off.
- **Check the picture.** `tools/bench.sh` takes two screenshots. An
  optimisation that changes the picture is a bug, and a measurement switch
  that breaks the frame (black frames, missing geometry) may measure
  nothing useful.
