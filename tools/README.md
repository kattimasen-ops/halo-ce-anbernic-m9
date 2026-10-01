# Development tools

Scripts used to measure the port on the handheld. They talk to it with
`adb` over USB. Set `ADB` if `adb` is not on your
`PATH`, for example `ADB=/path/to/platform-tools/adb`. On Windows, run them
from Git Bash; under WSL, use a Linux `adb`.

| Script | Where it runs | What it does |
| --- | --- | --- |
| `bench.sh <level> <seconds> <label> [HALO_X=value ...]` | computer | One benchmark: waits until the CPU is below `COOL_TO` (50 °C), loads the level through `init.txt`, plays for the given time with `HALO_FPS_LOG=5`, takes two screenshots and the threads' CPU use, and saves everything in `bench/<label>/`. Extra `HALO_*` assignments are passed to the game. `INIT_EXTRA` adds console commands, separated by `;`. |
| `keepalive.sh [interval]` | computer | Keeps the handheld awake while EmulationStation is stopped, so that the battery saver does not suspend it and drop USB. |
| `device/keepalive.sh [hours]` | handheld | The same as `keepalive.sh`, run on the handheld itself (`setsid sh keepalive.sh 6 &` over `adb shell`), so that it keeps going when the computer sleeps. It stops after the given hours (default 6). |
| `device/run.sh <seconds> [HALO_X=value ...]` | handheld | The runner `bench.sh` copies to `/userdata/system/halo-dev/`. It pins the CPU and GPU clocks, sets the number of framebuffers (`HALO_FB_BUFFERS`), runs the game for the given time and writes `run.log`, then restores the clocks. |

Before benchmarking:

1. Install the port in `/userdata/roms/ports/halo/` (see the main README).
2. Stop EmulationStation: `adb shell /etc/init.d/S31emulationstation stop`.
3. Optionally run `tools/keepalive.sh` in another terminal.

Examples:

```sh
tools/bench.sh a30 80 a30-baseline HALO_RENDER_SCALE=0.75
tools/bench.sh b30 150 b30-gltiming HALO_RENDER_SCALE=0.75 HALO_GL_TIMING=1
INIT_EXTRA='rasterizer_lens_flares false' tools/bench.sh c10 80 c10-noflares
grep 'fps ' bench/a30-baseline/run.log
```

Start EmulationStation again afterwards with
`adb shell /etc/init.d/S31emulationstation start`, or reboot. The
environment variables the game understands are listed in
[port/knulli/README.md](../port/knulli/README.md#tools-for-performance-work).

## Microbenchmarks

`microbench/` holds three small OpenGL ES programs that measure the Mali
driver in isolation. Their results are in
[the Mali-G31 notes](../docs/MALI-G31-NOTES.md).

- `glbench.c`: the driver's CPU time per draw call under different state
  changes (uniform arrays of 192 and 16 registers, a uniform block range,
  attribute pointers, texture binds, program switches). `TEXMODE` chooses
  the textures (`plain`, `mip`, `swizzle`, `identity`, `sampler`, `unbound`).
- `glmap.c`: writing into persistently mapped buffers, per call and per
  byte, flushed or not, for four combinations of mapping flags, and how fast
  the mapping reads back (which shows whether the CPU caches it).
- `glupload.c`: the CPU time of making a texture with all its mip levels,
  with `glTexImage2D`, with immutable storage and `glTexSubImage2D`, and
  compressed (ASTC, ETC2), for the sizes and formats the port uploads.

Build them with the cross compiler, the SDL2 headers and the device's
libraries that [the build guide](../docs/BUILDING.md) sets up, then copy
them over and run them with EmulationStation stopped:

```sh
aarch64-linux-gnu-gcc -O2 -mcpu=cortex-a53 -DEGL_NO_X11 -I<SDL2 headers> \
    -I<GLES headers> glmap.c -o glmap -L<device libraries> \
    -Wl,--allow-shlib-undefined -lSDL2 -lmali
adb push glmap /tmp/ && adb shell /tmp/glmap
```
