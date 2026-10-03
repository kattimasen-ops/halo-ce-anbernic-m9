#!/usr/bin/env bash
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
UPSTREAM_URL=${UPSTREAM_URL:-https://github.com/cybersecurity/halo-ce-universal.git}
UPSTREAM_COMMIT=$(tr -d '[:space:]' < "$HERE/UPSTREAM_COMMIT")
PATCH=$HERE/patches/halo-ce-universal-knulli.patch
SDL3_TAG=release-3.2.10
SDL2_TAG=release-2.30.10
SDL2_ARCHIVE=https://github.com/libsdl-org/SDL/archive/refs/tags/$SDL2_TAG.tar.gz
GUEST_CC=${GUEST_CC:-clang-22}
HOST_CC=${HOST_CC:-aarch64-linux-gnu-gcc}
JOBS=${JOBS:-$(nproc)}

die() { echo "build.sh: $*" >&2; exit 1; }
need() { command -v "$1" > /dev/null 2>&1 || die "$1 not found: $2"; }

need git "install git"
need python3 "install python3"
need ninja "install ninja-build"
need curl "install curl"
need tar "install tar"
need cmake "install cmake"
need "$HOST_CC" "install gcc-aarch64-linux-gnu, or set HOST_CC"
need "$GUEST_CC" "install clang-22 from apt.llvm.org, or set GUEST_CC"
"$GUEST_CC" -print-targets 2> /dev/null | grep -q aarch64_32 ||
    die "$GUEST_CC has no arm64_32 (aarch64_32) target; use clang 22 from apt.llvm.org"
[ -n "${ANDROID_NDK:-}" ] || die "set ANDROID_NDK to the Android NDK r28c folder"
[ -d "$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64" ] || die "ANDROID_NDK=$ANDROID_NDK is not an Android NDK"
ANDROID_NDK=$(cd "$ANDROID_NDK" && pwd)
[ -n "${SYSROOT_LIB:-}" ] || die "set SYSROOT_LIB to the folder with the runtime libraries"
[ -d "$SYSROOT_LIB" ] || die "SYSROOT_LIB=$SYSROOT_LIB is not a folder"
SYSROOT_LIB=$(cd "$SYSROOT_LIB" && pwd)

for library in libdecor-0.so.0 libmali.so.0; do
    compgen -G "$SYSROOT_LIB/$library*" > /dev/null ||
        die "no $library* in SYSROOT_LIB=$SYSROOT_LIB"
done

WORK=${WORK:-$HERE/work}
DIST=${DIST:-$HERE/dist}
mkdir -p "$WORK" "$DIST"
WORK=$(cd "$WORK" && pwd)
DIST=$(cd "$DIST" && pwd)
SRC=$WORK/halo-ce-universal

# ── SDL3 ───────────────────────────────────────────────────────────────
if [ ! -f "$SYSROOT_LIB/libSDL3.so.0" ]; then
    echo "== SDL3 $SDL3_TAG: kompiliere aus dem Quellcode"
    SDL3_SRC=$WORK/SDL3-${SDL3_TAG#release-}
    SDL3_BUILD=$WORK/sdl3-build
    SDL3_INSTALL=$WORK/sdl3-install

    if [ ! -d "$SDL3_SRC" ]; then
        curl -L -o "$WORK/sdl3.tar.gz" \
            "https://github.com/libsdl-org/SDL/releases/download/$SDL3_TAG/SDL3-${SDL3_TAG#release-}.tar.gz"
        tar -xzf "$WORK/sdl3.tar.gz" -C "$WORK"
    fi
    rm -rf "$SDL3_BUILD" "$SDL3_INSTALL"
    mkdir -p "$SDL3_BUILD" "$SDL3_INSTALL"

    cmake -S "$SDL3_SRC" -B "$SDL3_BUILD" \
        -DCMAKE_SYSTEM_NAME=Linux \
        -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
        -DCMAKE_C_COMPILER="$HOST_CC" \
        -DCMAKE_FIND_ROOT_PATH=/usr/aarch64-linux-gnu \
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
        -DCMAKE_BUILD_TYPE=Release \
        -DSDL_SHARED=ON \
        -DSDL_STATIC=OFF \
        -DSDL_TESTS=OFF \
        -DSDL_EXAMPLES=OFF \
        -DSDL_INSTALL_TESTS=OFF \
        -DSDL_WERROR=OFF \
        -DSDL_UNIX_CONSOLE_BUILD=ON \
        -DSDL_X11=OFF \
        -DSDL_WAYLAND=OFF \
        -DSDL_KMSDRM=ON \
        -DSDL_OPENGLES=ON \
        -DSDL_OPENGL=OFF \
        -DCMAKE_INSTALL_PREFIX="$SDL3_INSTALL"
    cmake --build "$SDL3_BUILD" -j "$JOBS"
    cmake --install "$SDL3_BUILD"

    SDL3_LIB=$(find "$SDL3_INSTALL" -name "libSDL3.so.0*" -type f | head -n 1)
    [ -n "$SDL3_LIB" ] || die "libSDL3.so.0 wurde nicht gefunden"
    cp -L "$SDL3_LIB" "$SYSROOT_LIB/libSDL3.so.0"
    echo "== SDL3 kompiliert: $(stat -c%s "$SYSROOT_LIB/libSDL3.so.0") Bytes"
else
    echo "== libSDL3.so.0 bereits vorhanden – überspringe SDL3"
fi

# ── SDL2 ───────────────────────────────────────────────────────────────
if [ ! -f "$SYSROOT_LIB/libSDL2-2.0.so.0" ]; then
    echo "== SDL2 $SDL2_TAG: kompiliere aus dem Quellcode"
    SDL2_SRC=$WORK/SDL2-src
    SDL2_BUILD=$WORK/sdl2-build
    SDL2_INSTALL=$WORK/sdl2-install

    rm -rf "$SDL2_SRC" "$SDL2_BUILD" "$SDL2_INSTALL"
    mkdir -p "$SDL2_SRC" "$SDL2_BUILD" "$SDL2_INSTALL"

    curl -L -o "$WORK/sdl2.tar.gz" "$SDL2_ARCHIVE"
    tar -xzf "$WORK/sdl2.tar.gz" -C "$SDL2_SRC" --strip-components=1

    cmake -S "$SDL2_SRC" -B "$SDL2_BUILD" \
        -DCMAKE_SYSTEM_NAME=Linux \
        -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
        -DCMAKE_C_COMPILER="$HOST_CC" \
        -DCMAKE_FIND_ROOT_PATH=/usr/aarch64-linux-gnu \
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
        -DCMAKE_BUILD_TYPE=Release \
        -DSDL_SHARED=ON \
        -DSDL_STATIC=OFF \
        -DSDL_TESTS=OFF \
        -DSDL_X11=OFF \
        -DSDL_WAYLAND=OFF \
        -DSDL_KMSDRM=ON \
        -DSDL_OPENGLES=ON \
        -DSDL_OPENGL=OFF \
        -DCMAKE_INSTALL_PREFIX="$SDL2_INSTALL"
    cmake --build "$SDL2_BUILD" -j "$JOBS"
    cmake --install "$SDL2_BUILD"

    SDL2_LIB=$(find "$SDL2_INSTALL" -name "libSDL2-2.0.so.0*" -type f | head -n 1)
    [ -n "$SDL2_LIB" ] || die "libSDL2-2.0.so.0 wurde nicht gefunden"
    cp -L "$SDL2_LIB" "$SYSROOT_LIB/libSDL2-2.0.so.0"
    echo "== SDL2 kompiliert: $(stat -c%s "$SYSROOT_LIB/libSDL2-2.0.so.0") Bytes"
else
    echo "== libSDL2-2.0.so.0 bereits vorhanden – überspringe SDL2"
fi

export SDL2_INCLUDE="$SDL2_INSTALL/include"
echo "== SDL2_INCLUDE=$SDL2_INCLUDE"

# ── Repository klonen und patchen ─────────────────────────────────────
if [ ! -d "$SRC/.git" ]; then
    echo "== cloning $UPSTREAM_URL into $SRC"
    git init -q "$SRC"
    git -C "$SRC" remote add origin "$UPSTREAM_URL"
fi
if ! git -C "$SRC" cat-file -e "$UPSTREAM_COMMIT^{commit}" 2> /dev/null; then
    echo "== fetching $UPSTREAM_COMMIT"
    git -C "$SRC" fetch -q --depth 1 origin "$UPSTREAM_COMMIT" ||
        git -C "$SRC" fetch -q origin
    git -C "$SRC" cat-file -e "$UPSTREAM_COMMIT^{commit}" 2> /dev/null ||
        die "commit $UPSTREAM_COMMIT is not in $UPSTREAM_URL"
fi

tree_is_patched() {
    [ "$(git -C "$SRC" rev-parse HEAD 2> /dev/null || true)" = "$UPSTREAM_COMMIT" ] &&
        cmp -s <(git -C "$SRC" diff HEAD | grep -v '^index ') <(grep -v '^index ' "$PATCH")
}
if ! tree_is_patched; then
    echo "== checking out $UPSTREAM_COMMIT and applying $(basename "$PATCH")"
    git -C "$SRC" checkout -q --force --detach "$UPSTREAM_COMMIT"
    git -C "$SRC" reset -q --hard
    git -C "$SRC" clean -q -fd
    git -C "$SRC" apply "$PATCH"
    git -C "$SRC" apply --summary "$PATCH" | awk '$1 == "create" { print $4 }' | xargs -r git -C "$SRC" add -N --
fi

# ══════════════════════════════════════════════════════════════════════
# PGO: Android-Profil verwenden
# ══════════════════════════════════════════════════════════════════════
#
# Herkunft: Andiweli/HaloCE-Android-AAOS. Der Commit "Improve performance
# by 2x to 3x" zeigt mit PGO einen Sprung von 132 auf 197 fps auf Android
# und von 171 auf 201 fps auf Linux. Der Effekt ist auf dem Cortex-A35
# besonders gross, weil PGO die Branch-Vorhersage und die Inline-
# Entscheidungen auf die tatsaechliche Ausfuehrung abstimmt.
#
# Reihenfolge: erst Android-Profil, dann Linux-Profil, dann ohne PGO.
PGO_PROFILE=""
PGO_FLAG="--pgo=off"

PGO_ANDROID_URL="https://raw.githubusercontent.com/Andiweli/HaloCE-Android-AAOS/main/pgo/halo_android.profdata"
PGO_LINUX_URL="https://raw.githubusercontent.com/cybersecurity/halo-ce-universal/main/pgo/halo_linux.profdata"

mkdir -p "$SRC/pgo"

echo "== Lade Android-PGO-Profil von Andiweli/HaloCE-Android-AAOS ..."
if curl -fsSL -o "$SRC/pgo/halo_android.profdata" "$PGO_ANDROID_URL" 2>/dev/null; then
    PGO_PROFILE="$SRC/pgo/halo_android.profdata"
    PGO_FLAG="--pgo=use"
    echo "== Android-PGO-Profil geladen: $(stat -c%s "$PGO_PROFILE") Bytes"
    echo "== Baue mit PGO (--pgo=use) unter Verwendung des Android-Profils"
else
    echo "== Android-PGO-Profil nicht erreichbar; versuche Linux-Profil ..."
    if curl -fsSL -o "$SRC/pgo/halo_linux.profdata" "$PGO_LINUX_URL" 2>/dev/null; then
        PGO_PROFILE="$SRC/pgo/halo_linux.profdata"
        PGO_FLAG="--pgo=use"
        echo "== Linux-PGO-Profil geladen: $(stat -c%s "$PGO_PROFILE") Bytes"
        echo "== Baue mit PGO (--pgo=use) unter Verwendung des Linux-Profils"
    else
        echo "== Kein PGO-Profil verfuegbar. Baue ohne PGO (--pgo=off)"
        PGO_FLAG="--pgo=off"
    fi
fi

PGO_EXTRA_ARGS=""
if [ -n "$PGO_PROFILE" ]; then
    PGO_EXTRA_ARGS="--pgo-profile $PGO_PROFILE"
fi

# ══════════════════════════════════════════════════════════════════════
# HINWEIS ZU -march=native
# ══════════════════════════════════════════════════════════════════════
#
# Der AAOS-Port hat -march=native in seinem Benchmark als weiteren
# Optimierungsschritt aufgefuehrt (201 -> 224 fps auf Linux). Das gilt
# aber nur fuer NATIVE Builds (x86_64 -> x86_64).
#
# Wir cross-compilen von x86_64 nach ARM64. -march=native wuerde dort
# die CPU des Build-Rechners (x86_64) erkennen und x86_64-Code erzeugen.
# Ergebnis: entweder Compiler-Fehler oder ein Binary, das auf dem M9 Pro
# sofort mit SIGILL abstuerzt.
#
# Der korrekte Cross-Compile-Weg ist das, was wir bereits verwenden:
#   -mcpu=cortex-a35+dotprod -mtune=cortex-a35
# Das aktiviert ARMv8-A, NEON, CRC und die Dot-Product-Instruktion
# (die die A35 unterstuetzt) und optimiert Scheduling fuer die A35-
# Pipeline. Im Fix-2-Block unten wird das gesetzt.

# ── Fix 1: APCs in WaitForSingleObjectEx/SleepEx ─────────────────────
python3 - "$SRC/port/linux/src/xbox_kernel.c" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    text = f.read()

wait_old = '''\tif (milliseconds == INFINITE)
\t\t{
\t\t\tpthread_cond_wait(&handle->condition, &handle->lock);
\t\t}
\t\telse if (pthread_cond_timedwait(&handle->condition, &handle->lock, &deadline) == ETIMEDOUT)
\t\t{
\t\t\tif (!handle_try_acquire(handle))
\t\t\t\tresult = WAIT_TIMEOUT;
\t\t\tbreak;
\t\t}'''

wait_new = '''\tif (alertable && platform_run_apcs())
\t\t{
\t\t\tpthread_mutex_unlock(&handle->lock);
\t\t\treturn WAIT_IO_COMPLETION;
\t\t}
\t\tif (milliseconds == INFINITE)
\t\t{
\t\t\t/* 10 ms aufwachen, damit fertige APCs laufen können */
\t\t\tstruct timespec short_wait;
\t\t\tclock_gettime(CLOCK_REALTIME, &short_wait);
\t\t\tshort_wait.tv_nsec += 10000000;
\t\t\tif (short_wait.tv_nsec >= 1000000000L)
\t\t\t{
\t\t\t\tshort_wait.tv_sec++;
\t\t\t\tshort_wait.tv_nsec -= 1000000000L;
\t\t\t}
\t\t\tpthread_cond_timedwait(&handle->condition, &handle->lock, &short_wait);
\t\t}
\t\telse if (pthread_cond_timedwait(&handle->condition, &handle->lock, &deadline) == ETIMEDOUT)
\t\t{
\t\t\tif (alertable && platform_run_apcs())
\t\t\t{
\t\t\t\tpthread_mutex_unlock(&handle->lock);
\t\t\t\treturn WAIT_IO_COMPLETION;
\t\t\t}
\t\t\tif (!handle_try_acquire(handle))
\t\t\t\tresult = WAIT_TIMEOUT;
\t\t\tbreak;
\t\t}'''

if wait_old not in text:
    print("FEHLER: WaitForSingleObjectEx-Warteschleife nicht gefunden", file=sys.stderr)
    sys.exit(1)
text = text.replace(wait_old, wait_new, 1)

sleep_old = '''\tif (milliseconds == INFINITE)
\t{
\t\tfor (;;)
\t\t\tpause();
\t}
\tduration.tv_sec = milliseconds / 1000;
\tduration.tv_nsec = (long)(milliseconds % 1000) * 1000000L;
\twhile (nanosleep(&duration, &duration) == -1 && errno == EINTR)
\t\t;
\tif (alertable && platform_run_apcs())
\t\treturn WAIT_IO_COMPLETION;
\treturn 0;'''

sleep_new = '''\tif (milliseconds == INFINITE)
\t{
\t\tfor (;;)
\t\t{
\t\t\tif (alertable && platform_run_apcs())
\t\t\t\treturn WAIT_IO_COMPLETION;
\t\t\tpause();
\t\t}
\t}
\tduration.tv_sec = milliseconds / 1000;
\tduration.tv_nsec = (long)(milliseconds % 1000) * 1000000L;
\twhile (duration.tv_sec > 0 || duration.tv_nsec > 0)
\t{
\t\tstruct timespec step;
\t\tstep.tv_sec = duration.tv_sec > 0 ? 1 : 0;
\t\tstep.tv_nsec = duration.tv_sec > 0 ? 0 : (duration.tv_nsec > 10000000L ? 10000000L : duration.tv_nsec);
\t\tif (nanosleep(&step, NULL) == -1 && errno != EINTR)
\t\t\tbreak;
\t\tif (step.tv_sec == 0 && step.tv_nsec == 10000000L)
\t\t\tduration.tv_nsec -= 10000000L;
\t\telse if (step.tv_sec == 1)
\t\t\tduration.tv_sec--;
\t\telse
\t\t\tduration.tv_nsec = 0;
\t\tif (alertable && platform_run_apcs())
\t\t\treturn WAIT_IO_COMPLETION;
\t}
\treturn 0;'''

if sleep_old not in text:
    print("FEHLER: SleepEx-Schleife nicht gefunden", file=sys.stderr)
    sys.exit(1)
text = text.replace(sleep_old, sleep_new, 1)

with open(path, 'w') as f:
    f.write(text)

print("xbox_kernel.c gepatcht: APCs laufen jetzt auch während WaitForSingleObjectEx/SleepEx")
PYEOF

# ══════════════════════════════════════════════════════════════════════
# Fix 2: android_build.py (Guest-ELF) optimieren
# ══════════════════════════════════════════════════════════════════════
#
# ACHTUNG: cortex-a35+dotprod statt cortex-a35. Die Dot-Product-
# Instruktion (UDOT/SDOT) ist Teil der ARMv8.2-A-Erweiterung und wird
# von der Cortex-A35 unterstuetzt. Sie beschleunigt die NEON-Berechnung
# von Matrix-Produkten (die Halo fuer die Transformationsmatrizen nutzt)
# erheblich.
#
# KEIN -march=native: siehe Kommentarblock oben.
python3 - "$SRC/tools/android_build.py" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    text = f.read()

if '"-mcpu=cortex-a35+dotprod"' in text:
    print("android_build.py enthält bereits cortex-a35+dotprod – überspringe.")
    sys.exit(0)

# Ersetze: "-mcpu=cortex-a53" oder "-mcpu=cortex-a35" -> "+dotprod"
old_mcpu = '"-mcpu=cortex-a53"'
new_mcpu = '"-mcpu=cortex-a35+dotprod",\n    "-mtune=cortex-a35"'
count_mcpu = text.count(old_mcpu)
if count_mcpu == 0:
    # Vielleicht schon gepatcht auf cortex-a35 ohne dotprod
    old_mcpu = '"-mcpu=cortex-a35",\n    "-mtune=cortex-a35"'
    new_mcpu = '"-mcpu=cortex-a35+dotprod",\n    "-mtune=cortex-a35"'
    count_mcpu = text.count(old_mcpu)
    if count_mcpu == 0:
        print("WARNUNG: keine mcpu-Zeile gefunden, weder cortex-a53 noch cortex-a35+mtune")
        print("         Setze cortex-a35+dotprod manuell in GUEST_ABI_FLAGS.")
    else:
        text = text.replace(old_mcpu, new_mcpu)
else:
    text = text.replace(old_mcpu, new_mcpu)

# -O3 statt -O2 und zusätzliche Optimierungen
old_flags = '"-ffp-contract=off",\n    "-O2",'
new_flags = '''"-ffp-contract=off",
    "-O3",
    "-fomit-frame-pointer",
    "-funroll-loops",
    "-fno-math-errno",
    "-fno-trapping-math",
    "-fmerge-all-constants",
    "-fno-strict-aliasing",'''
count_flags = text.count(old_flags)
if count_flags == 0:
    old_flags = '"-ffp-contract=off",'
    new_flags = '''"-ffp-contract=off",
    "-O3",
    "-fomit-frame-pointer",
    "-funroll-loops",
    "-fno-math-errno",
    "-fno-trapping-math",
    "-fmerge-all-constants",
    "-fno-strict-aliasing",'''
    count_flags = text.count(old_flags)
    if count_flags == 0:
        print("WARNUNG: GUEST_ABI_FLAGS-Marker nicht gefunden", file=sys.stderr)
    else:
        text = text.replace(old_flags, new_flags, 1)
else:
    text = text.replace(old_flags, new_flags, 1)

with open(path, 'w') as f:
    f.write(text)

print(f"android_build.py gepatcht: {count_mcpu}x mcpu -> cortex-a35+dotprod, {count_flags}x O2 -> O3 + extra flags")
PYEOF

# ── Fix 2b: clang-Builtin-Shim für den Guest-Build ───────────────────
python3 - "$SRC/tools/android_build.py" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    text = f.read()

if "_clang_builtin_shim" in text:
    print("android_build.py enthält bereits _clang_builtin_shim – überspringe.")
    sys.exit(0)

old_fn = '''def _clang_resource_include(cc: str) -> List[str]:
    # Include directory of cc's own built-in headers (arm_neon.h etc.).
    #
    # The guest build compiles with -nostdinc so the host's glibc headers
    # do not leak into a foreign target. That flag also hides clang's
    # built-in headers, which live under <resource-dir>/include rather
    # than a system path (arm_neon.h, immintrin.h, stddef.h ...). Query
    # the compiler for its resource directory and re-add only that
    # subfolder as a system include, so -nostdinc keeps doing its job
    # everywhere else.
    try:
        result = subprocess.run([cc, "-print-resource-dir"],
                                capture_output=True, text=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError, OSError) as error:
        print(f"WARNING: cannot query {cc} for its resource directory "
              f"({error}); arm_neon.h and other compiler builtins may be "
              f"missing", file=sys.stderr)
        return []
    include = Path(result.stdout.strip()) / "include"
    if not include.is_dir():
        print(f"WARNING: {cc} reports a resource directory but {include} "
              f"is missing", file=sys.stderr)
        return []
    return ["-isystem", str(include)]'''

new_fn = '''def _clang_builtin_shim(cc: str) -> List[str]:
    # A shim directory with symlinks to the compiler's own built-in
    # ARM vector headers (arm_neon.h and friends). The guest build
    # compiles with -nostdinc so the host's glibc headers do not leak
    # into a foreign target; that also hides clang's built-in headers,
    # which live under <resource-dir>/include. Putting the whole
    # <resource-dir>/include on the search path is not an option:
    # clang's stddef.h would then define size_t as __SIZE_TYPE__
    # (unsigned long on arm64_32), while musl's bits/alltypes.h defines
    # it as unsigned int (via _Addr), and the two incompatible typedefs
    # break the build. Copying just the ARM vector headers into a shim
    # keeps -nostdinc effective for everything else.
    try:
        result = subprocess.run([cc, "-print-resource-dir"],
                                capture_output=True, text=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError, OSError) as error:
        print(f"WARNING: cannot query {cc} for its resource directory "
              f"({error}); arm_neon.h and other compiler builtins may be "
              f"missing", file=sys.stderr)
        return []
    include = Path(result.stdout.strip()) / "include"
    if not include.is_dir():
        print(f"WARNING: {cc} reports a resource directory but {include} "
              f"is missing", file=sys.stderr)
        return []
    shim = BUILD / "guest" / "clang_builtin_shim"
    shim.mkdir(parents=True, exist_ok=True)
    for name in ("arm_neon.h", "arm_vector_types.h", "arm_acle.h",
                 "arm_fp16.h", "arm_bf16.h"):
        source = include / name
        if not source.is_file():
            continue
        target = shim / name
        if target.exists() or target.is_symlink():
            try:
                target.unlink()
            except OSError:
                pass
        try:
            target.symlink_to(source)
        except OSError:
            shutil.copy2(source, target)
    return ["-isystem", str(shim)]'''

if old_fn in text:
    text = text.replace(old_fn, new_fn, 1)
    text = text.replace("_clang_resource_include(guest_cc)",
                        "_clang_builtin_shim(guest_cc)")
elif "_clang_resource_include" in text:
    print("FEHLER: alte _clang_resource_include-Funktion gefunden, aber "
          "Text stimmt nicht mit dem erwarteten Muster ueberein.", file=sys.stderr)
    sys.exit(1)
else:
    anchor = """    for sdk in (Path.home() / "Android/Sdk", Path("/opt/android-sdk")):
        if (sdk / "ndk").is_dir():
            versions = sorted((sdk / "ndk").iterdir())
            if versions:
                return versions[-1]
    return None
"""
    if anchor not in text:
        print("FEHLER: _find_ndk-Anker nicht gefunden", file=sys.stderr)
        sys.exit(1)
    text = text.replace(anchor, anchor + "\n\n" + new_fn, 1)

if "_clang_builtin_shim(guest_cc)" not in text:
    old_abi = (
        '    guest_abi = " ".join(GUEST_ABI_FLAGS + '
        '(["-DHALO_RELEASE"] if getattr(sln, "port_release", False) else []))'
    )
    new_abi = (
        '    guest_abi = " ".join(\n'
        '        GUEST_ABI_FLAGS\n'
        '        + _clang_builtin_shim(guest_cc)\n'
        '        + (["-DHALO_RELEASE"] if getattr(sln, "port_release", False) else []))'
    )
    if old_abi in text:
        text = text.replace(old_abi, new_abi, 1)
    else:
        print("WARNUNG: guest_abi-Berechnung nicht gefunden.", file=sys.stderr)

with open(path, 'w') as f:
    f.write(text)

print("android_build.py gepatcht: clang-Builtin-Shim für Guest-Build aktiv")
PYEOF

# ── Fix 3: linux_build.py (Host-Binary) optimieren ──────────────────
python3 - "$SRC/tools/linux_build.py" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    text = f.read()

if 'OPTIMISATION = "-O3"' in text:
    print("linux_build.py enthält bereits -O3 – überspringe.")
    sys.exit(0)

old_opt = 'OPTIMISATION = "-O2"'
new_opt = 'OPTIMISATION = "-O3"'
count_opt = text.count(old_opt)
if count_opt == 0:
    print("WARNUNG: OPTIMISATION = \"-O2\" nicht gefunden", file=sys.stderr)
else:
    text = text.replace(old_opt, new_opt)

old_abi = '"-ffp-contract=off",\n    OPTIMISATION,'
new_abi = '''"-ffp-contract=off",
    "-funroll-loops",
    "-fno-math-errno",
    "-fno-trapping-math",
    "-fmerge-all-constants",
    "-fno-strict-aliasing",
    OPTIMISATION,'''
count_abi = text.count(old_abi)
if count_abi > 0:
    text = text.replace(old_abi, new_abi, 1)
else:
    print("WARNUNG: LINUX_ABI_FLAGS-Marker nicht gefunden", file=sys.stderr)

with open(path, 'w') as f:
    f.write(text)

print(f"linux_build.py gepatcht: {count_opt}x O2 -> O3, {count_abi}x zusätzliche Flags")
PYEOF

# ── Fix 4: Quellcode-Optimierungen (Memory, NEON) ────────────────────
echo ""
echo "== Fix 4: Quellcode-Optimierungen ..."
for patch_script in patch_memory_pools.py patch_neon_math.py; do
    if [ -f "$HERE/patches/$patch_script" ]; then
        echo "== Wende $patch_script an ..."
        if ! python3 "$HERE/patches/$patch_script" "$SRC"; then
            echo "WARNUNG: $patch_script fehlgeschlagen (nicht kritisch)"
        fi
    else
        echo "== $patch_script nicht vorhanden – ueberspringe"
    fi
done

# ── Port-Verzeichnis kopieren ─────────────────────────────────────────
rm -rf "$SRC/port/knulli"
cp -a "$HERE/port/knulli" "$SRC/port/knulli"
rm -rf "$SRC/port/knulli/__pycache__"
chmod +x "$SRC/port/knulli/build.sh" 2>/dev/null || true

stamp=$({ cat "$PATCH"
    (cd "$HERE/port/knulli" && find . -type f ! -path '*/__pycache__/*' -print0 | sort -z | xargs -0 cat)
} | sha256sum | cut -d' ' -f1)
if [ -f "$SRC/.port-stamp" ] && [ "$(cat "$SRC/.port-stamp")" = "$stamp" ]; then
    rm -rf "$SRC/build/knulli"
fi
echo "$stamp" > "$SRC/.port-stamp"

# ── Build mit LTO + PGO ──────────────────────────────────────────────
export ANDROID_NDK SYSROOT_LIB
export SDL2_INCLUDE
export GUEST_CC HOST_CC JOBS

cd "$SRC"

echo "== Konfiguriere mit --lto=full $PGO_FLAG $PGO_EXTRA_ARGS ..."
python3 configure.py --release --lto=full $PGO_FLAG $PGO_EXTRA_ARGS \
    --android-ndk "$ANDROID_NDK" --android-guest-cc "$GUEST_CC"

echo "== Baue Guest-ELF (halo_guest.elf) ..."
ninja -j "$JOBS" build/android/halo_guest.elf

echo "== Baue Host-Binary (halo) über port/knulli/build.sh ..."
bash "$SRC/port/knulli/build.sh"

# ── Distribution zusammenstellen ──────────────────────────────────────
echo "== copying the build into $DIST"
rm -rf "$DIST"
mkdir -p "$DIST"

cp "$SRC/build/knulli/halo" "$DIST/halo"
cp "$SRC/build/knulli/halo_guest.elf" "$DIST/halo_guest.elf"
cp "$SRC/port/knulli/Halo.sh" "$DIST/Halo.sh"
cp "$SRC/port/knulli/halo_extract.py" "$DIST/halo_extract.py"
cp "$SRC/port/knulli/halo_screen.py" "$DIST/halo_screen.py"
cp "$SRC/port/knulli/sdl_mapping.py" "$DIST/sdl_mapping.py"

if [ -d "$SRC/build/knulli/libs.aarch64" ]; then
    mkdir -p "$DIST/libs.aarch64"
    cp -a "$SRC/build/knulli/libs.aarch64/." "$DIST/libs.aarch64/"
    echo "== Laufzeitbibliotheken in dist/libs.aarch64/:"
    ls -la "$DIST/libs.aarch64/"
else
    echo "WARNUNG: $SRC/build/knulli/libs.aarch64 fehlt" >&2
fi

chmod +x "$DIST/Halo.sh" 2>/dev/null || true

echo "== Inhalt von $DIST:"
ls -laR "$DIST"
