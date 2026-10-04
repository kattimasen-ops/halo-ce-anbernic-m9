# Halo: Combat Evolved on M9 Pro — native port for ArkOS4Clone (Rockchip RK3326)

This is a native ARM64 (AArch64) port of the Halo: Combat Evolved
decompilation, [halo-ce-universal](https://github.com/cybersecurity/halo-ce-universal),
to the Rockchip RK3326 and its Mali-G31 MP2 GPU, running ArkOS4Clone.
There is no emulation: no xemu, no Box64, no Wine. You need your own copy
of the original Xbox game. This repository has the source code, the
documentation, and ready-made releases that need only your disc image:
they hold no game data.

- Game: Halo: Combat Evolved, Xbox build 01.01.14.2342, decompiled to C.
- Target: M9 Pro (Rockchip RK3326, 4x Cortex-A35, Mali-G31 MP2, 1 GB RAM,
  640x480) running ArkOS4Clone (Ubuntu 20.04 / GLIBC 2.31 base).
- Status: builds and starts on the M9 Pro; performance measurement after
  the SDL2 pageflip fix is pending (see [Performance](#performance)).
- Licence: CC0 1.0, like upstream.

## Contents

- [Features](#features)
- [Performance](#performance)
- [Supported devices](#supported-devices)
- [Requirements](#requirements)
- [Install](#install)
- [Build from source](#build-from-source)
- [How it works](#how-it-works)
- [Documentation](#documentation)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Legal notice](#legal-notice)
- [Credits](#credits)

## Features

- Native AArch64 code for the game and the host. The CPU runs the game's
  own logic compiled for ARM64; nothing is translated or emulated.
- Uses the firmware's own SDL2 (2.30.10) and Arm's Mali-G31 OpenGL ES 3.2
  driver on the framebuffer, so it runs on stock ArkOS4Clone with no extra
  libraries beyond the ones the launcher ships.
- **SDL2 KMSDRM pageflip fix for Mali-G31.** The Mali-G31 driver on the
  RK3326 advertises `DRM_CAP_ASYNC_PAGE_FLIP` but rejects the actual
  `drmModePageFlip` call with `-EINVAL`. SDL2 2.30.10 has no fallback, so
  every frame is dropped and the display tears. The build ships a patched
  `libSDL2-2.0.so.0` that retries without the async flag and disables it
  for the rest of the session.
- A dedicated GL thread takes the Mali driver's per-draw CPU cost (about
  17 µs a draw call) off the game's core.
- Renderer changes for a tile-based mobile GPU: program binary cache, fp16
  shaders, 16-bit textures, asynchronous occlusion readback, quad batching
  and decal ordering, model LOD scaling, and shadows restructured to avoid
  render-target switches.
- Adjustable render scale (default 0.5 on the M9 Pro, 320x240 scaled to
  640x480; see [Configuration](#configuration)).
- CPU and GPU clocks pinned while the game runs and restored on exit.
- First launch extracts `maps/` from your Xbox disc image on the handheld.
- The handheld's own controls, read from ArkOS4Clone's controller
  configuration.
- Quit with the hotkey: hold MENU (or SELECT) and press START.

## Performance

The RK3326's Cortex-A35 cores have a lower IPC than the Cortex-A53 cores in
the H700-based handhelds the upstream port was tuned for. The numbers below
are therefore expected to be lower than the upstream reference (about 40 to
55 fps on the H700 at `render_scale = 0.75`). Precise measurements on the
M9 Pro after the SDL2 pageflip fix are pending.

<!-- performance table: fill in after measuring on the M9 Pro -->
Last updated: pending measurement.

| Scene | `render_scale = 0.5` (320x240) | `render_scale = 0.75` (480x360) |
| --- | --- | --- |
| Main menu | pending | pending |
| c10, 343 Guilty Spark (swamp) | pending | pending |
| b30, The Silent Cartographer (beach battle) | pending | pending |
| a30, Halo (level opening) | pending | pending |
<!-- end of performance table -->

At high render scales the GPU's pixel and vertex work is the limit; at
lower scales the limit becomes the Mali driver's CPU time per draw call on
the GL thread. The kernel's thermal governor lowers the clocks at 70 °C.

To measure yourself, set `HALO_FPS_LOG=1` and read the 5-second averages in
`/roms/ports/halo-ce/log.txt`; `debug.hitch_log = 1` in `config.toml` logs
each long frame with what it did.

## Supported devices

The port needs a Rockchip RK3326 (4x Cortex-A35, Mali-G31 MP2, 1 GB RAM)
running ArkOS4Clone with GLIBC 2.31 or newer.

| Device | SoC | Screen | Status |
| --- | --- | --- | --- |
| M9 Pro | RK3326 | 640x480 | Tested (build verified; performance pending) |
| Other RK3326 handhelds | RK3326 | 640x480 | Untested, expected to work |

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
- The latest release (`halo-ce-arkos-<version>.zip`), or the files built as
  described in [Build from source](#build-from-source).

## Install

1. Download `halo-ce-arkos-<version>.zip` from the latest release.
2. Unzip it onto the SD card, into the partition that holds the `roms`
   folder. It adds `roms/ports/Halo.sh` and the folder `roms/ports/halo-ce/`.
3. Copy your Xbox Halo disc image (`.iso`) into `roms/ports/halo-ce/`.
4. On the handheld, start Halo from Ports. If it is not listed, update the
   game lists in ArkOS4Clone's menu, or restart the handheld.

The first start copies `maps/` out of the disc image, with its progress on
the screen (about four minutes); the image can be deleted afterwards. The
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

## Build from source

The build runs on Linux x86-64. It was done on Ubuntu 20.04 as the container
base of the GitHub Actions workflow (`.github/workflows/buildHCE.yml`), with
cross-toolchains for aarch64.

### Tools

- Ubuntu 20.04 (the workflow uses the `ubuntu:20.04` container image),
  `python3`, `ninja-build`, `git`, `curl`, `cmake`, `pkg-config`.
- clang 22 from [apt.llvm.org](https://apt.llvm.org/): the guest is compiled
  for the `arm64_32` (ILP32 AArch64) target.
- Android NDK r28c: it builds the guest and provides the GLES and EGL headers.
- `gcc-aarch64-linux-gnu` (9.x from Ubuntu 20.04): the host, an ordinary
  aarch64 glibc program.
- SDL2 sources from the SDL `release-2.30.10` tag. `build.sh` downloads and
  patches them (the KMSDRM pageflip fix above).

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
scp 'root@<handheld>:/usr/lib/libmali.so.0*' sysroot/
# or: adb pull /usr/lib/libmali.so.0 sysroot/
```

### Build

```sh
ANDROID_NDK=$PWD/android-ndk-r28c SYSROOT_LIB=$PWD/sysroot ./build.sh
```

`build.sh`:

1. clones [halo-ce-universal](https://github.com/cybersecurity/halo-ce-universal)
   into `work/halo-ce-universal` and checks out the commit in
   `UPSTREAM_COMMIT`;
2. downloads and patches SDL3 and SDL2 (the KMSDRM pageflip fix), installs
   their shared libraries into `sysroot/`;
3. applies `patches/halo-ce-universal-knulli.patch` and copies
   `port/knulli` into the upstream tree;
4. applies the host and guest compile-time fixes: `-mcpu=cortex-a35`,
   `-O3`, `-funroll-loops`, `-fno-math-errno`, `-fmerge-all-constants`,
   `-fno-strict-aliasing`, the NEON patches and the memory-pool patches;
5. runs `python3 configure.py --release --android-ndk <ndk> --android-guest-cc clang-22`
   (the first time, and again for another upstream commit; it downloads
   musl and SDL3 for the guest), then `port/knulli/build.sh`;
6. copies `halo`, `halo_guest.elf`, `Halo.sh`, `halo_extract.py`,
   `halo_screen.py` and `sdl_mapping.py` into `dist/`.

The first build takes 10 to 30 minutes; later builds are incremental.
Optional variables: `GUEST_CC` (default `clang-22`), `HOST_CC` (default
`aarch64-linux-gnu-gcc`), `WORK`, `DIST`, `JOBS`, `PGO_MODE`.

### PGO (profile-guided optimisation)

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

The two device-specific changes for the M9 Pro are the SDL2 KMSDRM pageflip
fix (built into `libSDL2-2.0.so.0`) and the `-mcpu=cortex-a35` tuning in
`tools/android_build.py` and `tools/linux_build.py`.

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

## Configuration

The settings are in `halo-ce/config.toml`, written at the first launch. The
defaults for the M9 Pro:

| Setting | Default | Effect |
| --- | --- | --- |
| `display.render_scale` | `0.5` | The 3D picture's resolution as a fraction of the screen's, 0.5 to 1.0, scaled up at the end of the frame. Lower is faster. On the M9 Pro 0.5 is 320x240. |
| `display.dynamic_resolution` | `true` | Lowers the render scale a step of 1/16 at a time while the GPU falls behind. |
| `display.dynamic_resolution_min` | `0.5` | The lowest the dynamic resolution goes. |
| `display.model_detail` | `0.3` | How early objects switch to their simpler models (1.0 is the game's own switch point), multiplied by the render scale. |
| `display.fast_shaders` | `true` | Colours and combiner arithmetic in half precision (fp16). |
| `display.fast_textures` | `true` | DXT1 and 16-bit Xbox textures sent to the GPU as 16-bit texels. |
| `display.screen_width` | `640` | The columns of the 480-line picture (640 for the Xbox's 4:3). |
| `display.interpolation` | `true` | Draws a frame for every display refresh, blending between the game's 30 ticks a second; `false` keeps 30 fps. |
| `display.frame_pacing` | `true` | Shows each frame at the display refresh it was drawn for, so that most frames show the world as it is when they are seen. Set to `false` if the framerate is low and pacing adds stutter. |
| `display.vsync` | `true` | Waits for the display between frames. |
| `update.auto` | `false` | The upstream updater, which fetches upstream's builds rather than this port's; off. |
| `network.online` | `false` | Internet play through invite links; off. |

Environment variables such as `HALO_RENDER_SCALE=0.5` override a setting for
one run. The `debug.*` settings and the profiling variables are also in
`port/knulli/README.md`.

A file `halo-ce/init.txt` runs console commands at start-up, for example
`map_name levels\b30\b30` to start a level directly.

### Performance settings for the M9 Pro

The Cortex-A35 is slower per clock than the Cortex-A53 the upstream port
targets. Recommended starting points:

- `render_scale = 0.5` — 75 % fewer pixels than 640x480.
- `model_detail = 0.3` — fewer vertices, which the A35 does not help with.
- `frame_pacing = false` — if the framerate is below 30, pacing adds
  latency without a smoother picture.
- `high_res_hud = false`, `high_res_text = false` — saves about 300 MB of
  RAM on a device with 1 GB shared with the GPU.

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
  CPU and GPU clocks. Lower `display.render_scale` for more headroom.
- **The clocks stay high after a crash.** `Halo.sh` restores the CPU
  governor and the GPU's minimum clock on exit; the next start, or a
  reboot, restores them too.

## FAQ

### Can the M9 Pro run Halo: Combat Evolved?

Yes. This port runs Halo CE natively on the M9 Pro under ArkOS4Clone, as
AArch64 code on the RK3326's Cortex-A35 cores with the Mali-G31 MP2 GPU.
It is built from the halo-ce-universal decompilation; you supply the Xbox
game's data.

### What frame rate does Halo CE get on the M9 Pro?

Pending measurement after the SDL2 pageflip fix. The Cortex-A35 is slower
per clock than the Cortex-A53 in the H700 handhelds the upstream port was
tuned for, so expect lower numbers than the upstream reference (about 40
to 55 fps at `render_scale = 0.75`). Start at `render_scale = 0.5`.

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

xemu emulates the whole original Xbox, its Pentium III CPU and its NV2A GPU,
and needs a fast desktop CPU and a desktop OpenGL or Vulkan GPU. The
RK3326's Cortex-A35 cores and its OpenGL ES-only Mali driver are far below
that. A native port of the decompiled code avoids the emulation entirely.

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
- Bungie, who made Halo: Combat Evolved. Halo is a trademark of Microsoft
  Corporation.
- [SDL](https://www.libsdl.org/) (zlib licence): the sources are patched at
  build time, and the resulting s
