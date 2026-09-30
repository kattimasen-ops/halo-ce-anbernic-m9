# How the Halo CE port for the RG35XX H works

This document describes the architecture of the native port of Halo: Combat
Evolved to the Anbernic RG35XX H and the other Allwinner H700 handhelds that
run Knulli. The port's own technical README,
[port/knulli/README.md](../port/knulli/README.md), is the reference for file
names and settings; this page gives the overview.

## The pieces

```
upstream: halo-ce-universal (pinned commit, UPSTREAM_COMMIT)
  source/                 the decompiled game (C), Xbox build 01.01.14.2342
  port/linux/src/         the platform layer: Direct3D 8 on OpenGL, files, sockets
  port/android/guest/     the guest runtime and the arm64_32 musl C library
  port/android/host/      the Android host: loader, memory, threads, system calls
this repository
  patches/…knulli.patch   renderer and host changes to upstream files
  port/knulli/            the new host for Knulli (copied into the upstream tree)
```

The build produces two files:

- `halo_guest.elf`: the game, as the Android port builds it. A static ILP32
  AArch64 image.
- `halo`: the host, an ordinary aarch64 glibc Linux executable that loads the
  image, links it to the firmware's SDL2 and Mali driver, and runs it.

## Why a guest image

Halo's data has the layout of the Xbox's memory: its map (cache) files, its
saved games and its Direct3D resources hold 32-bit pointers and addresses.
Compiling the game with 64-bit pointers would change the layout of every
structure the game reads from those files. The upstream Android port solves
this by compiling the game as ILP32 AArch64 code: 64-bit ARM instructions
with 32-bit `int`, `long` and pointers. clang's only ILP32 AArch64 target is
Apple's `arm64_32`, so the guest is compiled for it, the assembly is
converted to ELF, and `ld.lld` links a static image at a fixed address above
the emulated Xbox memory region. The guest's C library is a port of musl to
that ABI, and its system calls go to the host.

This is native code. The Cortex-A53 cores execute the game's instructions
directly; there is no instruction translation or emulation of the Xbox.

## The Knulli host

Android's host is a JNI library started by SDL3's Java activity. Knulli has
no Android runtime and no SDL3 with a Mali video driver, so this port
replaces the Android-specific parts of the host:

| Part | File | What it does |
| --- | --- | --- |
| Entry point | `host/host_main.c` | Replaces Android's JNI start-up. Through the Android host's memory, loader and thread code it reserves the guest's address space below 4 GB, loads `halo_guest.elf` from next to the executable, and starts the game's `main` on a stack in guest memory. The data, save and image paths can be overridden from the environment. |
| SDL bridge | `host/host_sdl2.c`, `host/host_sdl3_events.c` | The guest was built against SDL3. These answer its SDL3 calls with the firmware's SDL2, which has the only video driver for the Mali framebuffer. SDL objects are 64-bit pointers, so the guest holds small handles instead. Event layouts, GL attributes and gamepad types are translated. |
| GL thread | `host/host_glthread.c`, `glthread_gen.py` | Records the guest's OpenGL ES calls into a queue that another thread replays into the driver (below). |
| Logging | `compat/android/log.h` | The NDK's log functions, written to the standard error stream (`halo/log.txt`). |
| Profiling | `host/host_profile.c`, `host/host_gl_timing.c`, `profile.py` | A sampling profiler and a per-function timer of the driver's calls. |
| Launcher | `Halo.sh`, `halo_extract.py`, `sdl_mapping.py` | Extracts `maps/` from the disc image on the first launch, writes the handheld's defaults to `config.toml`, maps the controls, pins the clocks and restores them on exit. |

The loader, memory manager, thread and system-call code are the Android
host's (`port/android/host`), compiled with the aarch64 glibc cross compiler
and linked against the device's `libSDL2-2.0.so.0` and `libmali.so.0`.

## The Mali-G31 and its driver

The H700's GPU is a Mali-G31 MP2, a small tile-based GPU. Knulli drives it
with Arm's proprietary OpenGL ES driver on the Linux framebuffer: there is no
X11, Wayland, DRM/KMS or Vulkan path. Two properties of this platform shape
the port:

1. **The driver's CPU cost per draw call is high.** On the Cortex-A53 the
   driver spends about 28 µs of CPU time on each draw call (validating state,
   building descriptors and job chains). A battle frame has several hundred
   draws, so the driver alone can take most of a frame.
2. **Switching render targets is expensive.** A tile-based GPU keeps the
   current target in on-chip tile memory. Switching to another target and
   back makes it write the whole target out to memory and read it back in.

## The GL thread

The guest's OpenGL ES calls are recorded into an 8 MB ring buffer and
replayed by a thread of their own, so the driver's work runs on another core
while the game prepares the next frame.

- Calls that return nothing are queued with a copy of the memory their
  pointers refer to, and the game continues at once. The recording functions
  are generated from the list of GL functions the guest imports
  (`glthread_gen.py`).
- Calls that return a value wait for the GL thread. None occurs in a normal
  frame: `glGen*` names come from a reserve the GL thread keeps filled.
- The game can be at most one frame ahead (`HALO_GL_THREAD_FRAMES`).
- Each side spins briefly before sleeping on a futex; long spinning heats the
  handheld towards its throttling temperature.

`HALO_GL_THREAD=0` turns the thread off.

## Renderer changes

The renderer (`port/linux/src/d3d8_gl.c`) implements the Xbox's Direct3D 8
and NV2A register combiners on OpenGL ES 3. The patch adds these changes for
`HALO_ANDROID` builds (which include this port):

- **Render scale** (`display.render_scale`): the 3D picture is drawn at a
  fraction of the screen's resolution and scaled up at Present.
- **Program binary cache**: linked shader programs are saved as the driver's
  binaries in `save/shaders`. A link takes about 60 ms on this GPU, a
  visible stutter; with the cache each combination is linked once. If the
  driver rejects a saved binary, the program is compiled again.
- **fp16 shaders** (`display.fast_shaders`): colours and combiner arithmetic
  in half precision; texture coordinates stay in single precision.
- **16-bit textures** (`display.fast_textures`): Mali has no S3TC, so DXT
  textures are decoded on the CPU. DXT1 and 16-bit Xbox textures are now
  decoded to 16-bit texels, the colours they hold, instead of 32-bit ones.
- **Smaller uniform arrays**: vertex programs declare only the constant
  registers they read, since Mali processes a uniform array whole whenever
  one element changes.
- **Sampler objects**: one per sampler configuration, bound rather than
  reconfigured.
- **Ranged draws**: `glDrawRangeElementsBaseVertex` with the index range the
  renderer already knows, which spares the driver a scan of the indices.
- **Asynchronous occlusion readback**: the visibility tests (lens flares,
  lights) count samples with an atomic counter. The counters are copied at
  the end of each frame into three read-back buffers, and the game reads a
  copy the GPU has finished. Reading them directly held the game, the GL
  thread and the GPU in lockstep once a frame.
- **Quad batching and decal ordering**: consecutive quad draws that change
  only constant vertex attributes are drawn as one, and decals whose blend
  function does not depend on draw order are grouped by bitmap
  (`rasterizer_xbox_decals.c`). In a battle about 700 decal draws a frame
  become about 20.
- **Stable streams**: indexed draws point their attributes at the base
  vertex, so draws from the same vertex buffer share the attribute setup.
- **Model LOD scaling** (`display.model_detail`): objects switch to their
  simpler models sooner, by a factor times the render scale
  (`source/models/models.c`). Models are most of the GPU's vertex work.
- **Shadows for a tile-based GPU** (`rasterizer_xbox_shadows.c`,
  `render_objects.c`): on the Xbox each object's shadow switches to the
  shadow targets, draws the silhouette, blurs it in extra passes, and
  switches back to the main target to project it onto the environment. Here
  the objects are walked twice: the first pass draws every shadow's
  silhouette into a texture of its own, and the second projects them all
  without leaving the main target. The blur is folded into the projection
  shader, which removes the blur passes and their target switches.
- **vDSO clock**: the guest's clock reads go through the C library's vDSO
  instead of a system call.

## Clocks

The launcher sets the CPU governor to `performance` and holds the GPU at its
top frequency (648 MHz) by writing it to the devfreq `min_freq`; otherwise
the GPU governor keeps it at 420 MHz. Both are restored on exit. The
kernel's thermal governor still lowers the clocks at 70 °C.

## Controls

SDL2's built-in database takes the H700 handhelds' controls (they all report
the same generic GUID) for another pad, with the wrong buttons.
`sdl_mapping.py` reads EmulationStation's controller configuration and prints
an `SDL_GAMECONTROLLERCONFIG` mapping for each connected device, converting
EmulationStation's Nintendo-style button names to SDL's Xbox-style ones.
