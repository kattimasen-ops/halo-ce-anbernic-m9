# Developing the port

This guide is for contributors who change the code: where each kind of
change goes, how upstream changes are carried as a patch and kept in step
with the pinned upstream commit, how to build and try a change on the
handheld quickly, how to benchmark it before and after so that the numbers
mean something, and the coding and comment style the code base uses. The
general rules for contributions (hardware testing, no game files, the CC0
licence) are in the root [CONTRIBUTING.md](../CONTRIBUTING.md); building
from scratch is in [Building](BUILDING.md), and the design is in
[Architecture](ARCHITECTURE.md).

## Contents

- [Where changes go](#where-changes-go)
- [Changing the Knulli host](#changing-the-knulli-host)
- [Changing upstream files](#changing-upstream-files)
- [Moving to a newer upstream commit](#moving-to-a-newer-upstream-commit)
- [Trying a change on the handheld](#trying-a-change-on-the-handheld)
- [Benchmarking before and after](#benchmarking-before-and-after)
- [Common kinds of change](#common-kinds-of-change)
- [Coding style](#coding-style)
- [Documentation](#documentation)
- [Proposing a change](#proposing-a-change)

## Where changes go

The repository holds only this port's own files and a patch; `build.sh`
assembles the full source tree in `work/halo-ce-universal/`.

| You change | Edit it in | It reaches the build by |
| --- | --- | --- |
| The Knulli host, launcher or scripts (`port/knulli/`) | this repository's `port/knulli/` | `build.sh` copying `port/knulli/` into the tree at every run |
| Any upstream file (`source/`, `port/linux/src/`, `port/android/`, `tools/`) | `work/halo-ce-universal/`, then regenerate the patch | `build.sh` applying `patches/halo-ce-universal-knulli.patch` |
| A new file inside upstream's directories | `work/halo-ce-universal/`, marked for the patch (below) | the patch |
| The pinned upstream commit | `UPSTREAM_COMMIT` | `build.sh` fetching and checking it out |
| Benchmark tools | `tools/` | used from the computer |
| Documentation | `README.md`, `docs/` | |

Two things `build.sh` does make the rule strict:

- It deletes the tree's `port/knulli/` and copies this repository's in at
  every run, so edits made in `work/halo-ce-universal/port/knulli/` are lost.
- It resets the upstream tree (`git reset --hard`, `git clean -fd`) whenever
  the tree's diff differs from the patch file, so edits to upstream files in
  `work/` are lost if you run `build.sh` before regenerating the patch.

Generic fixes to upstream code, which are not specific to the handheld,
are also worth sending to
[halo-ce-universal](https://github.com/cybersecurity/halo-ce-universal).

## Changing the Knulli host

1. Edit the files in `port/knulli/` in this repository.
2. Run `./build.sh` with `ANDROID_NDK` and `SYSROOT_LIB` set
   ([Building](BUILDING.md)). It copies `port/knulli/` in, notices through
   `work/source.stamp` that it changed, rebuilds all the host's objects and
   links `halo`.

The generated GL thread code (`build/knulli/host_glthread_gen.c`) is made
from `port/knulli/glthread_gen.py` at every host build.

## Changing upstream files

1. Build once, so that `work/halo-ce-universal/` exists at the pinned
   commit with the patch applied.
2. Edit the files in `work/halo-ce-universal/`.
3. Regenerate the patch **before** running `build.sh` again:

   ```sh
   git -C work/halo-ce-universal diff > patches/halo-ce-universal-knulli.patch
   ```

4. Run `./build.sh`. It finds the tree already matching the patch, keeps
   it, and builds incrementally.

`git diff` shows only files that git tracks. To carry a **new file** in the
patch, mark it first, once:

```sh
git -C work/halo-ce-universal add -N port/android/guest/runtime/<new file>.c
git -C work/halo-ce-universal diff > patches/halo-ce-universal-knulli.patch
```

Check that the patch lists it (`grep '^diff --git' patches/*.patch`).
Files only the Knulli host needs belong in `port/knulli/` instead.

For faster turns while you work, you can skip `build.sh` and build in the
tree directly:

```sh
cd work/halo-ce-universal
SDL2_INCLUDE=$PWD/../sdl2-include SYSROOT_LIB=<device libraries> \
    ANDROID_NDK=<ndk> sh port/knulli/build.sh
```

This rebuilds the guest with ninja and the host files whose sources are
newer than their objects. It does not notice a changed header in the host's
files; delete `build/knulli/obj` when you change one. Regenerate the patch
before you next run `build.sh`.

Keep changes to upstream files inside `#ifdef HALO_ANDROID` (or the
existing `#ifdef HALO_LINUX` blocks where they belong), so that the desktop
builds stay as upstream has them. Remember that `HALO_ANDROID` code is also
built into upstream's Android app, which uses the same guest image and the
same `port/android/host/` files.

## Moving to a newer upstream commit

1. In `work/halo-ce-universal`, fetch the new commit with enough history
   for a three-way apply (`git fetch --unshallow origin`, or fetch the
   commit), and check it out.
2. Apply the patch with `git apply -3 ../../patches/halo-ce-universal-knulli.patch`
   and resolve any conflicts.
3. Build and test on the handheld: the menus, a30, b30 and c10, a save and
   a load, and the frame rates against the previous commit.
4. Regenerate the patch (with `add -N` for new files), and write the new
   commit's full hash to `UPSTREAM_COMMIT`.

## Trying a change on the handheld

The quickest way is over USB with ADB, with EmulationStation stopped
(`adb shell /etc/init.d/S31emulationstation stop`):

```sh
adb push dist/halo dist/halo_guest.elf /userdata/roms/ports/halo/
tools/bench.sh a30 60 my-change HALO_RENDER_SCALE=0.75
```

`tools/bench.sh` starts the game at a level, logs the frame rate and takes
screenshots ([Profiling](PROFILING.md#running-measurements)). To play the
change normally, start EmulationStation again and launch Halo from Ports.
Symbolize crash addresses from `halo/log.txt` against
`work/halo-ce-universal/build/android/halo_guest.elf` with `llvm-symbolizer`.

## Benchmarking before and after

A change to the renderer, the host or the game's drawing needs numbers
from the handheld, taken so that they can be compared:

- **The same scene.** Use `tools/bench.sh` with the same level and length
  for both builds. The a30 opening is the most repeatable scene; c10 is
  also steady; the b30 battle varies by 2 or 3 fps between runs, so a change
  there within that range is noise.
- **The same temperature.** `tools/bench.sh` waits until the CPU is below
  `COOL_TO` (50 °C by default). Check the `cpu` and `gpu` clocks in the
  `fps` lines: samples at 1416 MHz and 600 MHz were throttled.
- **Back to back.** Run the old and new builds one after the other, more
  than once if the difference is small, and compare the later samples of
  each run.
- **Instruments off for the frame rate.** `HALO_GL_TIMING` costs the GL
  thread time (a30: 51.5 to 52 fps with it, 52 to 54 without), and the pass
  timer serialises the GPU. Use them to explain a result, and take the
  frame rate from runs without them.
- **Check the picture.** Compare the screenshots of both runs. A faster
  frame with a wrong picture is a bug.
- **Say what you ran.** In the pull request, give the device, the Knulli
  release, the level, the render scale, the starting temperature, the `fps`
  lines of both builds, and the `gl:` lines if they explain the change.

## Common kinds of change

**A new setting.** Add a row to `config_settings` in
`port/linux/src/port_config.c`: the name, the type, the default as written
in TOML, the `HALO_*` variable and its style, the platforms
(`_platform_android` for the handheld), and a comment that the game writes
into `config.toml`. Place it next to the settings of its section: the table's
order is the order of a newly written file. Renderer switches are read once
in `gl_initialize` into `debug_settings`. Document it in
[Configuration](CONFIGURATION.md).

**A new GL function in the renderer.** Add it to the lists in
`port/linux/src/gl.h`, as the patch does for `glDrawRangeElementsBaseVertex`.
The guest's stubs and the `hostgl_` import are generated from there. If it
returns a value or writes through a pointer, add it to `SYNC` in
`port/knulli/glthread_gen.py`; if it reads memory through a pointer, give it
a `PAYLOAD` rule, or an `OFFSETS` entry if the pointer is an offset into a
bound buffer. The generator stops the build with a message when a rule is
missing.

**A new host function.** Add its name to `port/android/host_imports.list`,
declare it for the guest in `port/android/guest/runtime/guest_host.h` (and in
`port/linux/src/xgpu.h` if the renderer calls it), and implement it in the
host. If it makes GL calls, add a queued or synchronous version to the
table in `host_import_wrap` (`port/knulli/host/host_glthread.c`), or the GL
thread and the game's thread will call the driver at the same time.

**A new measurement.** Instruments that only log belong behind a setting or
a `HALO_*` variable that is off by default. A switch that removes work to
measure it (and breaks the picture) should say so in its comment. Remove
one-off switches once they have answered their question, and keep the
result in [Performance](PERFORMANCE.md).

## Coding style

Follow the code around you. The port's files and the platform layer share
one style:

- C with tabs for indentation, braces on lines of their own, and lines up to
  about 120 columns. Names are `snake_case`; functions and data private to a
  file are `static`. The host builds with `-Wall` and should build without
  warnings.
- The game's code (`source/`) is C89 (`-std=gnu89`): declare variables at
  the start of a block. It also keeps the decompilation's own layout
  (parameters on lines of their own, `return;` at the end of `void`
  functions); match it in the functions you touch.
- The platform layer and the guest runtime are C11 (`-std=gnu11`).
- Python scripts use the standard library only. `halo_extract.py` and
  `sdl_mapping.py` run on the handheld, which has nothing else.

**Comments** are plain prose that says why, in block comments without
leading asterisks. A comment on a declaration or a function often starts
in lower case and reads as a description of the thing:

```c
/* the high registers the latest write from XGPU_CONSTANT_SPLIT covers (an
object's nodes: the programs read no further), or all of them */
static unsigned long constants_high_extent = XGPU_VERTEX_CONSTANT_COUNT - XGPU_CONSTANT_SPLIT;
```

A section of a file starts with a marker and a paragraph that explains the
design, including the measurement that motivated it:

```c
/* ---------- batched quad draws

Decals are drawn a quad or two at a time (rasterizer_xbox_decals.c), each
with its colour in a constant vertex attribute: in a battle, half the
frame's draws, and every draw costs the Mali driver about 30 us whatever its
size. Consecutive quad draws that change nothing between them but constant
attributes are gathered here and drawn as one: ...
```

A new file starts with its name in capitals and a paragraph on what it is
for:

```c
/*
HOST_GLTHREAD.C

The GL thread of the Knulli port. On the handheld's Cortex-A53 the Mali
driver's own work (validating state, building descriptors and job chains)
is most of a frame, and it ran on the game's thread. ...
*/
```

Comments name the functions and files they refer to, so that a reader can
follow them, and they are kept true when the code changes.

## Documentation

Update the documentation with the code:

- A new setting or variable: [Configuration](CONFIGURATION.md), and
  [Profiling](PROFILING.md) if it is an instrument.
- A change to how something works: [Architecture](ARCHITECTURE.md), and
  [How it works](HOW-IT-WORKS.md) if the overview changes.
- A measured gain or a finding: [Performance](PERFORMANCE.md), and
  [Mali-G31 notes](MALI-G31-NOTES.md) for a lesson about the platform.
- Planned work done or found: [Roadmap](ROADMAP.md).
- New frame rates: the README's performance table and the other places that
  quote the frame rates (the README's opening and FAQ, `docs/FAQ.md`,
  `docs/index.html` and `llms.txt`).

## Proposing a change

1. Open an issue first for a large change, such as a change to the game's
   rasterizer or to the GL thread's design.
2. Make one change per pull request, with the patch regenerated and
   `port/knulli/` edited in this repository.
3. Include the benchmark results described above, and say which device and
   Knulli release you tested on.
4. Never include game files, disc images, maps, built binaries, the device's
   libraries or anything from the Mali driver ([legal notice](LEGAL.md)).
