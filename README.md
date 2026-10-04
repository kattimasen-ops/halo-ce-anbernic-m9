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
