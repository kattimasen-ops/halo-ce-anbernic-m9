# Development tools

Scripts used to measure the port on the handheld. They talk to it with
`adb` over USB. Set `ADB` if `adb` is not on your
`PATH`, for example `ADB=/path/to/platform-tools/adb`. On Windows, run them
from Git Bash; under WSL, use a Linux `adb`.

| Script | Where it runs | What it does |
| --- | --- | --- |
| `bench.sh <level> <seconds> <label> [HALO_X=value ...]` | computer | One benchmark: waits until the CPU is below `COOL_TO` (50 °C), loads the level through `init.txt`, plays for the given time with `HALO_FPS_LOG=5`, takes two screenshots and the threads' CPU use, and saves everything in `bench/<label>/`. Extra `HALO_*` assignments are passed to the game. `INIT_EXTRA` adds console commands, separated by `;`. |
| `keepalive.sh [interval]` | computer | Keeps the handheld awake while EmulationStation is stopped, so that the battery saver does not suspend it and drop USB. |
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
