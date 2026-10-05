# Halo: Combat Evolved on M9 Pro — native port for ArkOS4Clone (Rockchip RK3326)

A native AArch64 port of the Halo: Combat Evolved decompilation,
[halo-ce-universal](https://github.com/cybersecurity/halo-ce-universal),
to the Rockchip RK3326 and its ARM Mali-G31 MP2 GPU, running ArkOS4Clone.

There is no emulation: no xemu, no Box64, no Wine. The game's own logic is
compiled for the Cortex-A35 cores and draws with OpenGL ES 3.2 directly on
the Mali-G31. You need your own copy of the original Xbox game: this
repository holds only source code, documentation and ready-made releases
built from that source — no game data.

- Game: Halo: Combat Evolved, Xbox build `01.01.14.2342`, decompiled to C.
- Target: M9 Pro (Rockchip RK3326, 4× Cortex-A35, ARM Mali-G31 MP2, 1 GB
  RAM shared with the GPU, 640×480 display) running ArkOS4Clone
  (GLIBC 2.31 / Ubuntu 20.04 base).
- Native render resolution: **640×480 (`display.render_scale = 1.0`)**,
  matching the M9 Pro's screen.
- Status: builds, starts and runs on the M9 Pro. Frame-rate measurements
  after the SDL2 pageflip fix are pending (see [Performance](#performance)).
- Licence: CC0 1.0, like upstream.

## Contents

- [Features](#features)
- [Performance](#performance)
- [Supported devices](#supported-devices)
- [Requirements](#requirements)
- [Install](#install)
- [Configuration](#configuration)
- [Environment variables](#environment-variables)
- [Build from source](#build-from-source)
- [PGO (profile-guided optimisation)](#pgo-profile-guided-optimisation)
- [How it works](#how-it-works)
- [Documentation](#documentation)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Legal notice](#legal-notice)
- [Credits](#credits)

## Features

### Rendering

- **A dedicated GL thread** takes the Mali driver's per-draw CPU cost
  (measured at about 17 µs a draw call on this GPU) off the game's core.
- **Program binary cache** — every shader program is compiled once,
  asynchronously, and stored in `halo-ce/save/shaders`. Later launches load
  the driver binary instead of recompiling.
- **Half-precision shaders** (`display.fast_shaders = true`): colours and
  combiner arithmetic in fp16, which Mali GPUs execute at twice the rate.
- **16-bit textures** (`display.fast_textures = true`): DXT1 and 16-bit
  Xbox formats are uploaded as 16-bit texels, halving the texture memory
  and the bandwidth of every lookup.
- **Alpha-test elision**: where the alpha test provably cannot fail, it is
  removed from the generated shader, so the Mali forward pixel kill (HSR)
  can discard occluded fragments.
- **Asynchronous occlusion readback** via atomic counters: visibility
  results are read a few frames behind the GPU rather than waiting for it.
- **Batched quad draws** (`HALO_BATCH_QUADS`): consecutive same-state quads
  (decals) are combined into one draw.
- **Instanced model draws** (`HALO_INSTANCE_MODELS`): consecutive draws of
  the same skinned model part are drawn as one instanced draw.
- **Sorted models** (`HALO_SORT_MODELS`): model draws are reordered by
  shader, permutation and geometry to reduce the Mali driver's per-draw
  state changes.
- **Shadows in two passes**, avoiding the render-target switches that a
  tiled GPU pays for at each pass.
- **Water bump-map prebuild** at the start of the frame, so the primary
  render target's pass is not split.
- **Vertex-output pruning**: the vertex shader writes only the outputs the
  pixel shader actually reads.
- **Native render resolution by default**: `display.render_scale = 1.0`,
  the full 640×480 of the M9 Pro's screen. The HUD is drawn at the same
  resolution.
- **Adjustable render scale**, `0.5` to `1.0`: below `1.0` the 3D picture
  is drawn at fewer pixels and scaled up at the end of the frame. Optional
  lever if the native resolution's frame rate is too low for a scene.
- **Dynamic resolution** (`display.dynamic_resolution = false` by default
  on this port): can be enabled to lower the render scale a step of 1/16
  at a time while the GPU falls behind, and raise it again once it catches
  up. Kept off on the M9 Pro so the native 640×480 stays constant.
- **Model LOD scaling** (`display.model_detail`): objects switch to their
  simpler models sooner, reducing vertex work.

### Platform

- **Native AArch64** for both the game (as an ILP32 guest image) and the
  host, an ordinary aarch64 glibc program.
- Uses the firmware's own ARM Mali driver (`libmali-bifrost-g31-rxp0-gbm`)
  through SDL2 2.30.10's KMSDRM video driver. No additional libraries
  beyond a bundled SDL2 are needed.
- **SDL2 KMSDRM pageflip fix for the Mali-G31.** The Mali-G31 driver on
  the RK3326 advertises `DRM_CAP_ASYNC_PAGE_FLIP` but rejects the actual
  `drmModePageFlip` call with `-EINVAL`. SDL2 2.30.10 has no fallback, so
  every frame is dropped and the display either tears or stalls. The build
  ships a patched `libSDL2-2.0.so.0` that retries without the async flag
  and disables it for the rest of the session.
- **CPU and GPU clocks pinned while the game runs** and restored on exit,
  so the game is not fighting the kernel's governor. The kernel still
  lowers the clocks at 70 °C.
- **First launch extracts `maps/`** from your Xbox disc image on the
  handheld, with progress on the screen.
- **Controls read from ArkOS4Clone's** EmulationStation configuration
  (`sdl_mapping.py`), with an optional Xbox-layout remap (`HALO_BUTTON_REMAP`).
- **FN-key-free quit**: hold the hotkey (MENU, or SELECT) and press START.

### Code generation

- **Cortex-A35-specific code**: `-mcpu=cortex-a35 -mtune=cortex-a35` for
  the guest, `-O3` with `-funroll-loops`, `-fno-math-errno`,
  `-fno-trapping-math`, `-fmerge-all-constants` and `-fno-strict-aliasing`.
- **NEON matrix maths**: `matrix4x3_transform_point` and
  `matrix4x3_transform_vector` are vectorised with `vmulq_n_f32` +
  `vaddq_f32`. FMA is deliberately avoided, because the guest is compiled
  with `-ffp-contract=off` to keep the Xbox's mul+add rounding.
- **NEON `memcpy` and `memcmp`**: 64-byte and 16-byte vector paths in the
  guest runtime, which the Cortex-A35's dual 128-bit load ports exploit.
- **Vectorised index-extent calculation** using Clang's C vector extension
  (`__builtin_elementwise_min/max`), lowering to NEON `umin`/`umax`. This
  avoids the Apple `arm_neon.h`, which does not define its base types on
  the `arm64_32` target.
- **Smaller allocator footprint**: the debug allocator (which recorded
  file and line for every allocation) is disabled in release builds.
- **Thread-local decal scratch**: the large decal work arrays live in
  `__thread` storage instead of on the caller's stack.

### Ported from other Halo CE ports

- **Sound-obstruction interval** (`HALO_SOUND_OBSTRUCTION_TICKS`, default
  `3`): a sound's muffling behind walls is rechecked every third tick,
  from the PS Vita port's "Sound occlusion".
- **Distant-object culling** (`HALO_MIN_OBJECT_PIXELS`, default `8`):
  objects whose bounding sphere is smaller than this many pixels across
  are skipped, from the PS Vita port's "Hide distant objects".
- **Lighting-refresh divisor** (`HALO_LIGHTING_REFRESH_DIVISOR`, default
  `2`): a static object's lighting is kept for a multiple of the Xbox's
  own intervals, from the PS Vita port's "Object lighting".
- **Debug allocator switch** (`HALO_DEBUG_ALLOCATOR`): on-demand debug
  allocation tracking in release builds.

### Diagnostics

- **In-game FPS overlay** (`display.fps_overlay = true`, `HALO_FPS_OVERLAY=1`):
  a small yellow counter in the corner of the screen, drawn in GLSL with a
  3×5 bitmap font. Position with `display.fps_overlay_corner` (0 top-left,
  1 top-right, 2 bottom-left, 3 bottom-right — the default).
- **Hitch log** (`debug.hitch_log`): every frame longer than a threshold is
  logged, with what it did (programs linked, textures decoded, geometry
  uploaded) and where its time went.
- **Frame-time log** (`HALO_FPS_LOG=1`): 5-second averages in
  `halo-ce/log.txt`.
- **Draw-caller statistics** (`HALO_DEBUG_DRAW_CALLERS`): counts the draws
  each caller of the draw functions makes, and the draws that repeat
  another's geometry and state.

## Performance

The RK3326's Cortex-A35 cores have a lower IPC than the Cortex-A53 cores in
the H700-based handhelds the upstream port was tuned for. The stock render
resolution on the M9 Pro is **`display.render_scale = 1.0`, the native
640×480 of the screen**; the numbers below are what to expect at that
resolution and at lower render scales if a scene needs headroom. Precise
measurements on the M9 Pro after the SDL2 pageflip fix are pending.

<!-- performance table: fill in after measuring on the M9 Pro -->
Last updated: pending measurement.

| Scene | `render_scale = 1.0` (640×480, stock) | `render_scale = 0.75` (480×360) | `render_scale = 0.5` (320×240) |
| --- | --- | --- | --- |
| Main menu | pending | pending | pending |
| c10, 343 Guilty Spark (swamp) | pending | pending | pending |
| b30, The Silent Cartographer (beach battle) | pending | pending | pending |
| a30, Halo (level opening) | pending | pending | pending |
<!-- end of performance table -->

At the native 640×480 the GPU's pixel and vertex work is the limit; at
lower render scales the limit becomes the Mali driver's CPU time per draw
call on the GL thread. The kernel's thermal governor lowers the clocks at
70 °C.

**Recommended settings for the M9 Pro:**

- `display.render_scale = 1.0` — the native 640×480 of the M9 Pro's screen,
  the default of this port.
- `display.dynamic_resolution = false` — the launcher keeps this off, so
  the resolution stays fixed at the native 640×480.
- `display.model_detail = 0.3` — objects switch to their simpler models
  sooner; saves vertex work the Cortex-A35 cannot afford.
- `display.frame_pacing = true` — shows each frame at the refresh it was
  drawn for. Switch to `false` if the frame rate is below 30, where pacing
  adds latency without a smoother picture.
- `display.high_res_hud = false`, `display.high_res_text = false` — saves
  about 300 MB of RAM on a device with 1 GB shared with the GPU.

If a scene drops below a comfortable frame rate at the native 640×480,
lower `display.render_scale` step by step:

- `1.0` → 640×480 (stock, native).
- `0.75` → 480×360, about 56 % of the pixels.
- `0.5` → 320×240, about 25 % of the pixels.

To measure yourself, set `HALO_FPS_OVERLAY=1` for the on-screen counter,
`HALO_FPS_LOG=1` for the 5-second averages in `/roms/ports/halo-ce/log.txt`,
and `debug.hitch_log = 1` in `config.toml` to log each long frame with what
it did.

## Supported devices

The port needs a Rockchip RK3326 (4× Cortex-A35, ARM Mali-G31 MP2, 1 GB RAM)
running ArkOS4Clone with GLIBC 2.31 or newer.

| Device | SoC | Screen | Status |
| --- | --- | --- | --- |
| M9 Pro | RK3326 | 640×480 | Tested |
| Other RK3326 handhelds | RK3326 | 640×480 | Untested, expected to work |

Allwinner H700 devices (Anbernic RG35XX H and family) run the upstream
Knulli port instead; the two are separate builds. Devices with other SoCs
(TrimUI, Allwinner, Amlogic) are not supported: they have different GPUs
and drivers.

## Requirements

- An RK3326 handheld with ArkOS4Clone (tested with the 20260825 image,
  GLIBC 2.31).
- Your own disc image of Halo: Combat Evolved for the original Xbox
  (`.iso` or `.xiso`), North American or European. The Xbox version's maps
  are required; the PC version's files do not work.
- About 3 GB free on the card: the extracted `maps/` (1.8 GB) and the cache
  the game sets up at its first start (0.8 GB), plus room for the disc
  image until the maps are copied.
- The latest release, or the files built as described in
  [Build from source](#build-from-source).

## Install

1. Download the latest release archive from the repository's Releases page.
2. Unzip it onto the SD card, into the partition that holds the `roms`
   folder. It adds `roms/ports/Halo.sh` and the folder
   `roms/ports/halo-ce/`.
3. Copy your Xbox Halo disc image (`.iso`) into `roms/ports/halo-ce/`.
4. On the handheld, start Halo from Ports. If it is not listed, update the
   game lists in ArkOS4Clone's menu, or restart the handheld.

The first start copies `maps/` out of the disc image, with progress on the
screen (about four minutes); the image can be deleted afterwards. The
game's own first start then takes about a minute more with a black screen
while it sets up its cache (the screen says so first); later starts take
seconds. Instead of a disc image you can also copy an extracted Xbox
`maps/` folder into `halo-ce/`. To quit, hold the hotkey (MENU, or SELECT)
and press START. To update, unzip a newer release over the old files:
`maps/`, `save/` and `config.toml` stay.

The resulting layout:

```
/roms/ports/
├── Halo.sh
└── halo-ce/
    ├── halo
    ├── halo_guest.elf
    ├── halo_extract.py
    ├── halo_screen.py
    ├── sdl_mapping.py
    ├── config.toml      written at the first launch
    ├── log.txt          the log of the last launch
    ├── maps/            extracted from your disc image
    └── save/            saved games and the shader cache
```

The first time each shader combination is used, the driver compiles it, on
a thread of its own: what it draws appears a moment late, rather than the
game stopping for it. The compiled programs are kept in
`halo-ce/save/shaders`, so later launches load them instead.

## Configuration

The settings are in `halo-ce/config.toml`, written at the first launch. The
defaults for the M9 Pro:

| Setting | Default | Effect |
| --- | --- | --- |
| `display.render_scale` | `1.0` | The 3D picture's resolution as a fraction of the screen's, `0.5` to `1.0`. **`1.0` is the stock native 640×480 of the M9 Pro's screen**; below `1.0` fewer pixels are drawn and the picture is scaled up at the end of the frame. |
| `display.dynamic_resolution` | `false` | When `true`, the render scale is lowered a step of 1/16 at a time while the GPU falls behind, and raised again once it catches up. Kept `false` on the M9 Pro so the native 640×480 stays constant. |
| `display.dynamic_resolution_min` | `1.0` | The lowest the dynamic resolution goes, when it is enabled. `1.0` keeps the native resolution. |
| `display.model_detail` | `0.3` | How early objects switch to their simpler models (1.0 is the game's own switch point), multiplied by the render scale. |
| `display.fast_shaders` | `true` | Colours and combiner arithmetic in half precision (fp16). |
| `display.fast_textures` | `true` | DXT1 and 16-bit Xbox textures sent to the GPU as 16-bit texels. |
| `display.screen_width` | `640` | The columns of the 480-line picture (640 for the Xbox's 4:3). |
| `display.interpolation` | `true` | Draws a frame for every display refresh, blending between the game's 30 ticks a second; `false` keeps 30 fps. |
| `display.frame_pacing` | `true` | Shows each frame at the display refresh it was drawn for, so that most frames show the world as it is when they are seen. Set to `false` if the framerate is low and pacing adds stutter. |
| `display.vsync` | `true` | Waits for the display between frames. |
| `display.fps_overlay` | `false` | Draw a small FPS counter in the corner of the screen. |
| `display.fps_overlay_corner` | `3` | Where the counter goes: `0` top-left, `1` top-right, `2` bottom-left, `3` bottom-right. |
| `update.auto` | `false` | The upstream updater, which fetches upstream's builds rather than this port's; off. |
| `network.online` | `false` | Internet play through invite links; off. |

Environment variables such as `HALO_RENDER_SCALE=0.75` override a setting
for one run. The `debug.*` settings and the profiling variables are also in
`port/knulli/README.md`.

A file `halo-ce/init.txt` runs console commands at start-up, for example
`map_name levels\b30\b30` to start a level directly.

## Environment variables

The launcher `Halo.sh` sets a base set of options on every run. All of them
can be overridden by exporting the same variable before calling `Halo.sh`.

| Variable | Default | Effect |
| --- | --- | --- |
| `HALO_RENDER_SCALE` | `1.0` | The picture's resolution as a fraction of the screen's. Kept at `1.0` by the launcher: native 640×480 on the M9 Pro. Lower it only if a scene needs the headroom. |
| `HALO_DYNAMIC_RESOLUTION` | `0` | Disabled by the launcher so the render scale stays at the native 640×480. |
| `HALO_DYNAMIC_RESOLUTION_MIN` | `1.0` | The lowest step dynamic resolution would go to, if enabled. `1.0` keeps the native resolution. |
| `HALO_MODEL_DETAIL` | `0.35` | How early objects switch to their simpler models. |
| `HALO_FAST_SHADERS` | `1` | Colours and combiner arithmetic in fp16. |
| `HALO_FAST_TEXTURES` | `1` | 16-bit texels for DXT1 and 16-bit formats. |
| `HALO_INTERPOLATION` | `1` | Blends between the game's 30 ticks a second. |
| `HALO_SWAP_INTERVAL` | `1` | Hard VSync (interval 1). |
| `HALO_FRAME_PACING` | `1` | Show each frame at the refresh it was drawn for. |
| `HALO_HIGH_RES_HUD` | `0` | Draw the HUD from the maps' own bitmaps (saves RAM). |
| `HALO_HIGH_RES_TEXT` | `0` | Draw text with the maps' bitmap fonts (saves RAM). |
| `HALO_SORT_MODELS` | `1` | Sort model draws by shader, permutation, geometry. |
| `HALO_INSTANCE_MODELS` | `1` | Draw consecutive same-part draws as one instanced draw. |
| `HALO_BATCH_QUADS` | `1` | Batch consecutive same-state quad draws. |
| `HALO_ALPHA_TEST_ELISION` | `1` | Remove the alpha test from the shader where it cannot fail. |
| `HALO_STABLE_STREAMS` | `1` | Rebase indexed draws to their base vertex. |
| `HALO_GL_THREAD` | `1` | Run the renderer on its own thread. |
| `HALO_GL_THREAD_FRAMES` | `1` | Pipeline depth for the GL thread. |
| `HALO_ASYNC_TEXTURES` | `1` | Decode textures beside the renderer. |
| `HALO_ASYNC_SHADERS` | `1` | Translate shaders beside the renderer. |
| `HALO_ASYNC_PROGRAMS` | `1` | Link programs beside the renderer. |
| `HALO_BUTTON_REMAP` | `1` | Swap A↔B, X↔Y, LB↔LT, RB↔RT to the Xbox layout. |
| `HALO_SOUND_OBSTRUCTION_TICKS` | `3` | How many ticks a sound's muffling is kept before rechecking. |
| `HALO_MIN_OBJECT_PIXELS` | `8` | Skip objects smaller than this many pixels across. |
| `HALO_LIGHTING_REFRESH_DIVISOR` | `2` | Multiplier on the Xbox's own static-lighting intervals. |
| `HALO_FPS_OVERLAY` | `0` | Draw the in-game FPS counter. |
| `HALO_FPS_OVERLAY_CORNER` | `3` | Corner for the counter (0–3). |

See `Halo.sh` for the complete list and the individual comments.

## Build from source

The build runs on Linux x86-64. It was done on Ubuntu 20.04 as the container
base of the GitHub Actions workflow (`.github/workflows/buildHCE.yml`), with
cross-toolchains for aarch64.

### Tools

- Ubuntu 20.04 (the workflow uses the `ubuntu:20.04` container image),
  `python3`, `ninja-build`, `git`, `curl`, `cmake`, `pkg-config`.
- clang 22 from [apt.llvm.org](https://apt.llvm.org/): the guest is compiled
  for the `arm64_32` (ILP32 AArch64) target.
- Android NDK r28c: it builds the guest and provides the GLES and EGL
  headers.
- `gcc-aarch64-linux-gnu` (9.x from Ubuntu 20.04): the host, an ordinary
  aarch64 glibc program.
- SDL2 sources from the SDL `release-2.30.10` tag. `build.sh` downloads and
  patches them (the KMSDRM pageflip fix above). SDL3 3.2.10 is downloaded
  too, for the guest.

```sh
sudo apt install python3 python3-pip ninja-build git curl wget tar unzip \
    xz-utils build-essential cmake pkg-config \
    gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
    libc6-dev-arm64-cross linux-libc-dev-arm64-cross
wget https://apt.llvm.org/llvm.sh && sudo bash llvm.sh 22
curl -LO https://dl.google.com/android/repository/android-ndk-r28c-linux.zip
unzip -q android-ndk-r28c-linux.zip
```

### The device's libraries

The host links against the handheld's own `libmali.so.0` (Arm's driver,
which provides OpenGL ES and EGL) and a patched SDL2. Copy the Mali driver
from the handheld's `/usr/lib` into a `sysroot/` folder; SDL2 is built from
source by the build script. They are used only at link time and must not be
committed.

```sh
mkdir -p sysroot
scp 'root@<handheld>:/usr/local/lib/aarch64-linux-gnu/libmali-bifrost-g31-rxp0-gbm.so' sysroot/libmali.so.0
# or: adb pull /usr/local/lib/aarch64-linux-gnu/libmali-bifrost-g31-rxp0-gbm.so sysroot/libmali.so.0
```

### Build

```sh
ANDROID_NDK=$PWD/android-ndk-r28c SYSROOT_LIB=$PWD/sysroot ./build.sh
```

`build.sh`:

1. clones
   [halo-ce-universal](https://github.com/cybersecurity/halo-ce-universal)
   into `work/halo-ce-universal` and checks out the commit in
   `UPSTREAM_COMMIT`;
2. downloads and patches SDL2 (`release-2.30.10`, the KMSDRM pageflip fix)
   and SDL3 (`release-3.2.10`), installs their shared libraries into
   `sysroot/`;
3. applies `patches/halo-ce-universal-knulli.patch` and copies
   `port/knulli` into the upstream tree;
4. applies the host and guest compile-time fixes: `-mcpu=cortex-a35
   -mtune=cortex-a35`, `-O3 -funroll-loops -fno-math-errno
   -fno-trapping-math -fmerge-all-constants -fno-strict-aliasing`, the
   NEON patches and the memory-pool patches;
5. applies `patch_memory_pools.py`, `patch_neon_math.py`,
   `patch_vita_optimizations.py`, `patch_button_remap.py`,
   `patch_index_extent_neon.py` and `patch_fps_overlay.py`;
6. runs
   `python3 configure.py --release --android-ndk <ndk> --android-guest-cc clang-22`,
   then `port/knulli/build.sh`;
7. copies `halo`, `halo_guest.elf`, `Halo.sh`, `halo_extract.py`,
   `halo_screen.py` and `sdl_mapping.py` into `dist/`.

The first build takes 10 to 30 minutes; later builds are incremental.
Optional variables: `GUEST_CC` (default `clang-22`), `HOST_CC` (default
`aarch64-linux-gnu-gcc`), `WORK`, `DIST`, `JOBS`, `PGO_MODE`.

### Compiler flags applied to the guest

The build patches `tools/android_build.py` and `tools/linux_build.py` to:

- Set `-mcpu=cortex-a35 -mtune=cortex-a35` (the RK3326's core, replacing
  the upstream default `-mcpu=cortex-a53`).
- Upgrade `-O2` to `-O3` and add `-funroll-loops`, `-fno-math-errno`,
  `-fno-trapping-math`, `-fmerge-all-constants` and `-fno-strict-aliasing`.
- Remove `-fno-omit-frame-pointer` so `-fomit-frame-pointer` (added by
  the patch) takes effect. This saves code size and a few instructions per
  function prologue. It also means no frame-pointer backtraces in release:
  diagnostics rely on the log markers and `host_fatal` messages instead.
  For a debug build, re-add `-fno-omit-frame-pointer` to
  `GUEST_CODE_FLAGS` in `tools/android_build.py`.

The build also patches `port/linux/src/xbox_kernel.c` to run APC callbacks
during `WaitForSingleObjectEx` and `SleepEx`, so the game's deferred work
runs while it waits.

### Compiler flags applied to the host

Same as the guest, minus the guest-only flags: `-O3`, `-funroll-loops`,
`-fno-math-errno`, `-fno-trapping-math`, `-fmerge-all-constants`,
`-fno-strict-aliasing`. LTO is controlled by `--lto` (see
`configure.py --help`).

## PGO (profile-guided optimisation)

The workflow supports training the guest for PGO, which lets the compiler
lay out the code along the paths the game actually takes and reduces the
per-frame cost meaningfully.

```sh
# 1. Training build: instrumented guest, no LTO
PGO_MODE=train ./build.sh

# 2. Copy dist/ to the handheld, play for 10 minutes.
#    The guest writes .profraw files into /roms/ports/halo-ce/.
# 3. Pull the .profraw files back and merge them:
llvm-profdata-22 merge -output=pgo/halo_android.profdata halo-*.profraw

# 4. Release build with the profile
PGO_MODE=use ./build.sh
```

The training build requires the LLVM profiling runtime for `aarch64` from
the NDK; `build.sh` locates it under the clang resource directory and links
it into the guest. A small shim (`guest_pgo_shim.c`) provides the bionic
symbols the runtime expects (`__errno`, `__sF`, `prctl`, `getpagesize`) and
flushes the profile manually, because the bionic `atexit` handler is not
registered in the musl guest.

The release build uses a local profile at `pgo/halo_linux.profdata` if it
is present. If not, it tries upstream's profile, then a fallback mirror,
then falls back to `--pgo=off` and logs the choice.

## How it works

The upstream project decompiled Halo CE's Xbox build to C and ported it to
Linux, Windows and Android. Its Android port compiles the game as an ILP32
AArch64 "guest image" (32-bit pointers, as on the Xbox, in 64-bit ARM code)
that a small host program loads and serves.

This port reuses that guest image and adds a new host in `port/knulli/`:
an aarch64 glibc Linux program instead of an Android app. It answers the
guest's SDL3 calls with SDL2 (the only SDL with the Mali framebuffer video
driver on ArkOS4Clone) and runs the guest's OpenGL ES calls on a GL thread.
The renderer changes for the Mali-G31 are in the patch against upstream
(`port/linux/src` and `source/`).

The device-specific changes for the M9 Pro are:

- the SDL2 KMSDRM pageflip fix (built into `libSDL2-2.0.so.0`);
- the `-mcpu=cortex-a35` tuning in `tools/android_build.py` and
  `tools/linux_build.py`;
- the NEON matrix-maths and string patches;
- the memory-pool patches (debug allocator off, thread-local decals);
- the PS Vita port's sound-obstruction, distant-object and
  lighting-refresh optimisations;
- the button-remap patch for the Xbox layout;
- the vectorised index-extent calculation;
- the in-game FPS overlay;
- the native 640×480 render resolution (`display.render_scale = 1.0`) as
  the stock default, matching the M9 Pro's screen.

### Note on AFBC

The Mali-G31 supports Arm Frame Buffer Compression in hardware, but the
RK3326's display controller (VOPL) does not, and the Rockchip 4.4 kernel
ArkOS4Clone uses does not enable AFBC for the VOP. It is therefore not
available on this device and is not used.

## Documentation

- `docs/INSTALL.md`: the player's guide, from copying the files to the
  controls, the saves and what the launcher does to the clocks.
- `docs/CONFIGURATION.md`: every setting and `HALO_*` variable, with its
  default and effect.
- `docs/BUILDING.md`: building from source, step by step, with the common
  build errors.
- `docs/HOW-IT-WORKS.md`: the architecture in brief.
- `docs/ARCHITECTURE.md`: the guest and the host, the GL thread, the
  renderer and the rasterizer changes in depth.
- `docs/PERFORMANCE.md`: the optimisation history and its measurements.
- `docs/PROFILING.md`: the measuring tools and how to read them.
- `docs/MALI-G31-NOTES.md`: lessons for porting a Direct3D-era renderer to
  this GPU.

## Troubleshooting

- **Halo returns to the menu at once.** The screen says why first (no disc
  image, not an Xbox disc image, an incomplete one, not enough free space);
  `halo-ce/log.txt` has the details.
- **The first start seems stuck.** Copying `maps/` out of the disc image
  takes about four minutes, with its progress on the screen; then the game
  sets up its cache for about a minute with a black screen.
- **The maps do not load.** The PC version's files do not work; use an Xbox
  disc image or an Xbox `maps/` folder.
- **The buttons are wrong.** `sdl_mapping.py` builds the SDL mapping from
  ArkOS4Clone's controller configuration. Check that the handheld's
  controls are configured in EmulationStation's menu.
- **Objects appear late the first time.** Each new shader combination is
  compiled once, beside the game, and cached in `halo-ce/save/shaders`;
  what it draws is skipped until it is ready. Deleting that folder is
  safe; the programs are compiled again.
- **The picture tears or the framerate is very low.** Verify that the SDL2
  shipped with the build is being used, not the firmware's. Check
  `halo-ce/log.txt` for `Could not queue pageflip`; if those lines appear
  more than once, an old SDL2 is in the library path.
- **The frame rate drops after a while.** At 70 °C the kernel lowers the
  CPU and GPU clocks. Lower `display.render_scale` from the native `1.0`
  to `0.75` or `0.5` for more headroom.
- **The clocks stay high after a crash.** `Halo.sh` restores the CPU
  governor and the GPU's minimum clock on exit; the next start, or a
  reboot, restores them too.
- **`unknown type name 'uint16x8_t'` at build time.** The NEON patch was
  not applied, or an old `arm_neon.h` include is still present in
  `port/linux/src/d3d8_gl.c`. The current patch uses Clang's C vector
  extension and does not include `arm_neon.h`; the build verifies this
  and fails early if the include is still there.
- **`undefined symbol: glUniform4f` at link time.** The FPS-overlay patch
  was not updated, or the wrong version is in the tree. Use the current
  `patches/patch_fps_overlay.py`, which calls `glUniform4fv` (the only
  uniform-vec4 form in the guest's import list).

## FAQ

### Can the M9 Pro run Halo: Combat Evolved?

Yes. This port runs Halo CE natively on the M9 Pro under ArkOS4Clone, as
AArch64 code on the RK3326's Cortex-A35 cores with the Mali-G31 MP2 GPU.
It is built from the halo-ce-universal decompilation; you supply the Xbox
game's data.

### What frame rate does Halo CE get on the M9 Pro?

Pending measurement after the SDL2 pageflip fix. The port runs at the
native 640×480 (`render_scale = 1.0`) by default; the Cortex-A35 is slower
per clock than the Cortex-A53 in the H700 handhelds the upstream port was
tuned for, so if a scene is too slow for you, lower `display.render_scale`
to `0.75` (480×360) or `0.5` (320×240).

### Does it work with the Xbox version or the PC version of Halo?

The Xbox version. The decompilation is of the Xbox build, and it reads the
Xbox maps. The PC version (Gearbox's port) has different map files that
this code cannot load.

### Is this legal?

The repository contains only source code and documentation, and its
releases only the port's programs built from that source: the upstream
decompilation's authors released their code under CC0, and so does this
port. Neither contains game files, disc images or maps. You need your own
copy of the Xbox game. See the legal notice.

### Does it need PortMaster?

No. It is a plain ArkOS4Clone port: a launcher script in `roms/ports` and a
folder. It uses the firmware's Mali driver and a bundled SDL2.

### Why not run the PC version with Box64 and Wine?

The PC version is a 32-bit x86 Windows program that draws with Direct3D 9.
Running it on the RK3326 would need x86 translation, Wine, and a Direct3D
to OpenGL ES translation layer, all on four Cortex-A35 cores and 1 GB of
RAM. Each layer costs CPU time the device does not have. The native port
runs the game's own logic as ARM64 code and draws with OpenGL ES directly.

### Why not use xemu?

xemu emulates the whole original Xbox, its Pentium III CPU and its NV2A
GPU, and needs a fast desktop CPU and a desktop OpenGL or Vulkan GPU. The
RK3326's Cortex-A35 cores and its OpenGL ES-only Mali driver are far below
that. A native port of the decompiled code avoids the emulation entirely.

### Why is AFBC not used?

AFBC (Arm Frame Buffer Compression) is supported by the Mali-G31 but not by
the RK3326's display controller (VOPL) in the Rockchip 4.4 kernel ArkOS4Clone
uses. The necessary kernel patches are not present, and VOPL is not designed
for AFBC. It is therefore not available and not used.

### Which other handhelds does it work on?

Any Rockchip RK3326 handheld running ArkOS4Clone with GLIBC 2.31 or newer
and Arm's Mali-G31 driver should work. Only the M9 Pro has been tested.
Allwinner H700 devices (Anbernic RG35XX H and family) use the upstream
Knulli port instead.

## Legal notice

This is an unofficial fan project. It is not affiliated with, endorsed by
or sponsored by Microsoft, Xbox Game Studios, Halo Studios or Bungie.
Halo, Halo: Combat Evolved and Xbox are trademarks of Microsoft
Corporation.

The repository and its releases contain no Halo game files: no disc
images, maps, XBE or extracted assets. They contain no Arm Mali driver
binaries and no device libraries; the releases hold only the port's own
programs, built from this source. To play, you need your own copy of the
original Xbox game.

## Credits

- [halo-ce-universal](https://github.com/cybersecurity/halo-ce-universal)
  and its contributors: the decompilation's Linux, Windows and Android
  ports, on which this port is built. It starts from
  [bnunu/halo-1](https://github.com/bnunu/halo-1), a fork of
  [punpckhdq/halo](https://github.com/punpckhdq/halo).
- [kirklandsig/halo-ce-anbernic-rg35xx](https://github.com/kirklandsig/halo-ce-anbernic-rg35xx):
  the Knulli fork of the decompilation that this port's build applies as
  `patches/halo-ce-universal-knulli.patch`. It provides the tile-based
  renderer work (Mali-G31 pipeline, GL thread, batched quads, instanced
  models, sorted models, shadow restructure, water prebuild, program
  cache, fast shaders, fast textures, alpha-test elision) and much of the
  configuration layer.
- Bungie, who made Halo: Combat Evolved. Halo is a trademark of Microsoft
  Corporation.
- [SDL](https://www.libsdl.org/) (zlib licence): the sources are patched at
  build time, and the resulting shared library is bundled in the releases.
- The PS Vita port
  [BirchWoodGod/halo-ce-vita](https://github.com/BirchWoodGod/halo-ce-vita):
  the sound-obstruction interval, distant-object culling and lighting-refresh
  divisor optimisations, ported to this target by
  `patches/patch_vita_optimizations.py`.
- The authors of the ARM Cortex-A35 and Mali-G31 documentation, from which
  the tuning choices (`-mcpu=cortex-a35`, no FMA, dual-load-port `memcpy`,
  hidden surface removal) were derived.
