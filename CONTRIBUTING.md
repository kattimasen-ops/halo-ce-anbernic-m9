# Contributing

Contributions are welcome: performance work, fixes, and reports from other
H700 devices and firmware. For changes to the code, see
[docs/CONTRIBUTING-DEV.md](docs/CONTRIBUTING-DEV.md): where each change goes,
the patch workflow, benchmarking and the coding style.

- **Test on hardware.** Changes to the host or the renderer need a run on a
  real H700 handheld. Say which device and which Knulli release you used.
- **Report frame rates with `HALO_FPS_LOG`.** Run with `HALO_FPS_LOG=5` (or
  use `tools/bench.sh`) and paste the `fps` lines from the log, with the
  level, the render scale and the temperature the run started at. Battles
  vary between runs, so compare repeatable scenes (the a30 opening, c10) and
  runs that start at the same temperature. `tools/bench.sh` waits until the
  CPU is below 50 °C.
- **No game files.** Do not add disc images, maps, XBE files, extracted
  assets, prebuilt `halo` or `halo_guest.elf` binaries, Mali driver files or
  any library from the device to a pull request, an issue or a comment.
- **Upstream changes go in the patch.** Changes to upstream files belong in
  `patches/halo-ce-universal-knulli.patch`: make them in
  `work/halo-ce-universal` after a `./build.sh`, then regenerate the patch
  with `git -C work/halo-ce-universal diff > patches/halo-ce-universal-knulli.patch`
  (mark a new file with `git -C work/halo-ce-universal add -N <file>` first,
  or `git diff` leaves it out). New files for the Knulli host go in
  `port/knulli/` in this repository.
  Generic fixes are better sent to
  [halo-ce-universal](https://github.com/cybersecurity/halo-ce-universal)
  as well.
- **Licence.** By contributing you agree to release your contribution under
  CC0 1.0, like the rest of the project.

When reporting a problem, attach `halo/log.txt` and say how you installed
the game (disc image or an extracted `maps/` folder).
