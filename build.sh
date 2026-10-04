#!/usr/bin/env bash
set -euo pipefail

# ══════════════════════════════════════════════════════════════════════
# PGO-MODUS
# ══════════════════════════════════════════════════════════════════════
#   train  → instrumentierter Android-Guest (nur!), erzeugt .profraw
#   use    → Release-Build mit pgo/halo_android.profdata und LTO
#   off    → ohne PGO, LTO an
PGO_MODE=${PGO_MODE:-train}

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

if ! printf '%s' "$UPSTREAM_COMMIT" | grep -Eq '^[0-9a-f]{40}$'; then
    die "UPSTREAM_COMMIT='$UPSTREAM_COMMIT' ist kein 40-stelliger Hex-Hash"
fi

case "$PGO_MODE" in
    train|use|off) ;;
    *) die "PGO_MODE='$PGO_MODE' ungueltig; erlaubt: train, use, off" ;;
esac

echo "== Upstream: $UPSTREAM_URL @ $UPSTREAM_COMMIT"
echo "== PGO-Modus: $PGO_MODE"

WORK=${WORK:-$HERE/work}
DIST=${DIST:-$HERE/dist}
mkdir -p "$WORK" "$DIST"
WORK=$(cd "$WORK" && pwd)
DIST=$(cd "$DIST" && pwd)
SRC=$WORK/halo-ce-universal

# ── SDL3 ─────────────────────────────────────────────────────────────
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
        -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
        -DCMAKE_C_COMPILER="$HOST_CC" \
        -DCMAKE_FIND_ROOT_PATH=/usr/aarch64-linux-gnu \
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
        -DCMAKE_BUILD_TYPE=Release \
        -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
        -DSDL_INSTALL_TESTS=OFF -DSDL_WERROR=OFF -DSDL_UNIX_CONSOLE_BUILD=ON \
        -DSDL_X11=OFF -DSDL_WAYLAND=OFF -DSDL_KMSDRM=ON \
        -DSDL_OPENGLES=ON -DSDL_OPENGL=OFF \
        -DCMAKE_INSTALL_PREFIX="$SDL3_INSTALL"
    cmake --build "$SDL3_BUILD" -j "$JOBS"
    cmake --install "$SDL3_BUILD"
    SDL3_LIB=$(find "$SDL3_INSTALL" -name "libSDL3.so.0*" -type f | head -n 1)
    [ -n "$SDL3_LIB" ] || die "libSDL3.so.0 nicht gefunden"
    cp -L "$SDL3_LIB" "$SYSROOT_LIB/libSDL3.so.0"
    echo "== SDL3 kompiliert: $(stat -c%s "$SYSROOT_LIB/libSDL3.so.0") Bytes"
else
    echo "== libSDL3.so.0 bereits vorhanden"
fi

# ── SDL2 ─────────────────────────────────────────────────────────────
if [ ! -f "$SYSROOT_LIB/libSDL2-2.0.so.0" ]; then
    echo "== SDL2 $SDL2_TAG: kompiliere aus dem Quellcode"
    SDL2_SRC=$WORK/SDL2-src
    SDL2_BUILD=$WORK/sdl2-build
    SDL2_INSTALL=$WORK/sdl2-install
    rm -rf "$SDL2_SRC" "$SDL2_BUILD" "$SDL2_INSTALL"
    mkdir -p "$SDL2_SRC" "$SDL2_BUILD" "$SDL2_INSTALL"
    curl -L -o "$WORK/sdl2.tar.gz" "$SDL2_ARCHIVE"
    tar -xzf "$WORK/sdl2.tar.gz" -C "$SDL2_SRC" --strip-components=1

    # ── SDL2 KMSDRM Pageflip-Patch für Mali-G31 ─────────────────────
    # Verifiziert: https://github.com/libsdl-org/SDL/issues/16174
    # Der Pageflip-Aufruf liegt in SDL_kmsdrmopengles.c
    # (KMSDRM_GLES_SwapWindow), NICHT in SDL_kmsdrmvideo.c. Der
    # Mali-G31-Treiber auf dem RK3326 meldet DRM_CAP_ASYNC_PAGE_FLIP,
    # lehnt den Aufruf aber mit -EINVAL ab. SDL2 2.30.10 hat keinen
    # Fallback, sodass jeder Frame verloren geht.
    echo "== SDL2 KMSDRM Pageflip-Patch fuer Mali-G31 anwenden"
    python3 - "$SDL2_SRC/src/video/kmsdrm/SDL_kmsdrmopengles.c" <<'PATCH_EOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()

old = '''    ret = KMSDRM_drmModePageFlip(viddata->drm_fd, dispdata->crtc->crtc_id,
                                  fb_info->fb_id, flip_flags, &windata->waiting_for_flip);
    if (ret == 0) {
        windata->waiting_for_flip = SDL_TRUE;
    } else {
        SDL_LogError(SDL_LOG_CATEGORY_VIDEO, "Could not queue pageflip: %d", ret);
    }'''

new = '''    ret = KMSDRM_drmModePageFlip(viddata->drm_fd, dispdata->crtc->crtc_id,
                                  fb_info->fb_id, flip_flags, &windata->waiting_for_flip);
    /* Mali-G31 (RK3326) meldet DRM_CAP_ASYNC_PAGE_FLIP, lehnt den Aufruf
       aber mit -EINVAL ab. SDL2 hat keinen Fallback, sodass jeder Frame
       verloren geht. Hier: ohne Async-Flag wiederholen und Async dauerhaft
       deaktivieren, damit nur der erste Frame einen Fehler wirft. */
    if (ret != 0 && (flip_flags & DRM_MODE_PAGE_FLIP_ASYNC)) {
        viddata->async_pageflip_support = SDL_FALSE;
        flip_flags &= ~DRM_MODE_PAGE_FLIP_ASYNC;
        ret = KMSDRM_drmModePageFlip(viddata->drm_fd, dispdata->crtc->crtc_id,
                                      fb_info->fb_id, flip_flags, &windata->waiting_for_flip);
        if (ret == 0) {
            SDL_LogInfo(SDL_LOG_CATEGORY_VIDEO,
                        "Async pageflip rejected by the driver; using synchronous flips.");
        }
    }
    if (ret == 0) {
        windata->waiting_for_flip = SDL_TRUE;
    } else {
        SDL_LogError(SDL_LOG_CATEGORY_VIDEO, "Could not queue pageflip: %d", ret);
    }'''

if old not in text:
    import re
    pattern = re.compile(
        r'(ret = KMSDRM_drmModePageFlip\(viddata->drm_fd, dispdata->crtc->crtc_id,\s*\n'
        r'\s*fb_info->fb_id, flip_flags, &windata->waiting_for_flip\);\s*\n'
        r'\s*if \(ret == 0\) \{\s*\n'
        r'\s*windata->waiting_for_flip = SDL_TRUE;\s*\n'
        r'\s*\} else \{\s*\n'
        r'\s*SDL_LogError\(SDL_LOG_CATEGORY_VIDEO, "Could not queue pageflip: %d", ret\);\s*\n'
        r'\s*\})')
    match = pattern.search(text)
    if not match:
        print("FEHLER: Pageflip-Code nicht gefunden", file=sys.stderr)
        print("Bitte pruefen: SDL_kmsdrmopengles.c KMSDRM_GLES_SwapWindow", file=sys.stderr)
        sys.exit(1)
    text = text[:match.start()] + new + text[match.end():]
else:
    text = text.replace(old, new, 1)

with open(path, 'w') as f:
    f.write(text)
print("SDL2 KMSDRM Pageflip-Patch angewendet (SDL_kmsdrmopengles.c)")
PATCH_EOF

    cmake -S "$SDL2_SRC" -B "$SDL2_BUILD" \
        -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
        -DCMAKE_C_COMPILER="$HOST_CC" \
        -DCMAKE_FIND_ROOT_PATH=/usr/aarch64-linux-gnu \
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
        -DCMAKE_BUILD_TYPE=Release \
        -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF \
        -DSDL_X11=OFF -DSDL_WAYLAND=OFF -DSDL_KMSDRM=ON \
        -DSDL_OPENGLES=ON -DSDL_OPENGL=OFF \
        -DCMAKE_INSTALL_PREFIX="$SDL2_INSTALL"
    cmake --build "$SDL2_BUILD" -j "$JOBS"
    cmake --install "$SDL2_BUILD"
    SDL2_LIB=$(find "$SDL2_INSTALL" -name "libSDL2-2.0.so.0*" -type f | head -n 1)
    [ -n "$SDL2_LIB" ] || die "libSDL2-2.0.so.0 nicht gefunden"
    cp -L "$SDL2_LIB" "$SYSROOT_LIB/libSDL2-2.0.so.0"
    echo "== SDL2 kompiliert: $(stat -c%s "$SYSROOT_LIB/libSDL2-2.0.so.0") Bytes"
else
    echo "== libSDL2-2.0.so.0 bereits vorhanden"
    : "${SDL2_INSTALL:=$WORK/sdl2-install}"
fi
export SDL2_INCLUDE="$SDL2_INSTALL/include"
echo "== SDL2_INCLUDE=$SDL2_INCLUDE"

# ── Repository klonen und patchen ────────────────────────────────────
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
        die "commit $UPSTREAM_COMMIT not in $UPSTREAM_URL"
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
# PGO-Konfiguration
# ══════════════════════════════════════════════════════════════════════
PGO_FLAG="--pgo=off"
PGO_EXTRA_ARGS=""
LTO_FLAG="--lto=full"

if [ "$PGO_MODE" = "use" ]; then
    LOCAL_PGO="$HERE/pgo/halo_android.profdata"
    PGO_ANDROID_URL="https://raw.githubusercontent.com/Andiweli/HaloCE-Android-AAOS/main/pgo/halo_linux.profdata"
    PGO_LINUX_URL="https://raw.githubusercontent.com/cybersecurity/halo-ce-universal/main/pgo/halo_linux.profdata"
    if [ -f "$LOCAL_PGO" ]; then
        echo "== PGO: use (lokales Profil)"
        PGO_FLAG="--pgo=use"
        PGO_EXTRA_ARGS="--pgo-profile $LOCAL_PGO"
    elif curl -fsSL -o "$WORK/halo_android.profdata" "$PGO_ANDROID_URL" 2>/dev/null; then
        echo "== PGO: use (Profil aus dem Netz)"
        PGO_FLAG="--pgo=use"
        PGO_EXTRA_ARGS="--pgo-profile $WORK/halo_android.profdata"
    elif curl -fsSL -o "$WORK/halo_linux.profdata" "$PGO_LINUX_URL" 2>/dev/null; then
        echo "== PGO: use (Linux-Profil)"
        PGO_FLAG="--pgo=use"
        PGO_EXTRA_ARGS="--pgo-profile $WORK/halo_linux.profdata"
    else
        echo "== PGO: kein Profil gefunden, baue ohne PGO"
        PGO_FLAG="--pgo=off"
    fi
elif [ "$PGO_MODE" = "off" ]; then
    echo "== PGO: aus"
elif [ "$PGO_MODE" = "train" ]; then
    echo "== PGO: Trainings-Build (Android-Guest wird manuell instrumentiert, kein LTO)"
    LTO_FLAG="--lto=off"
fi

# ── Fix 1: APCs ─────────────────────────────────────────────────────
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
    print("FEHLER: WaitForSingleObjectEx nicht gefunden", file=sys.stderr); sys.exit(1)
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
    print("FEHLER: SleepEx nicht gefunden", file=sys.stderr); sys.exit(1)
text = text.replace(sleep_old, sleep_new, 1)
with open(path, 'w') as f:
    f.write(text)
print("xbox_kernel.c gepatcht")
PYEOF

# ── Fix 2: android_build.py (mcpu, O3) ───────────────────────────────
python3 - "$SRC/tools/android_build.py" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
if '"-mcpu=cortex-a35"' in text and '"+dotprod"' not in text:
    print("android_build.py hat bereits cortex-a35 ohne dotprod")
    sys.exit(0)
old_mcpu = '"-mcpu=cortex-a53"'
new_mcpu = '"-mcpu=cortex-a35",\n    "-mtune=cortex-a35"'
count_mcpu = text.count(old_mcpu)
if count_mcpu > 0:
    text = text.replace(old_mcpu, new_mcpu)
else:
    old_mcpu = '"-mcpu=cortex-a35+dotprod",\n    "-mtune=cortex-a35"'
    new_mcpu = '"-mcpu=cortex-a35",\n    "-mtune=cortex-a35"'
    count_mcpu = text.count(old_mcpu)
    if count_mcpu == 0:
        print("WARNUNG: keine mcpu-Zeile")
    else:
        text = text.replace(old_mcpu, new_mcpu)
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
        print("WARNUNG: GUEST_ABI_FLAGS-Marker fehlt", file=sys.stderr)
    else:
        text = text.replace(old_flags, new_flags, 1)
else:
    text = text.replace(old_flags, new_flags, 1)
with open(path, 'w') as f:
    f.write(text)
print(f"android_build.py gepatcht: {count_mcpu}x mcpu, {count_flags}x O2->O3")
PYEOF

# ── Fix 2b: clang-Builtin-Shim ───────────────────────────────────────
python3 - "$SRC/tools/android_build.py" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
if "_clang_builtin_shim" in text:
    print("shim bereits aktiv")
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
    try:
        result = subprocess.run([cc, "-print-resource-dir"],
                                capture_output=True, text=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError, OSError) as error:
        print(f"WARNING: cannot query {cc} for its resource directory "
              f"({error})", file=sys.stderr)
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
    print("FEHLER: alte Funktion in unerwarteter Form", file=sys.stderr); sys.exit(1)
else:
    anchor = """    for sdk in (Path.home() / "Android/Sdk", Path("/opt/android-sdk")):
        if (sdk / "ndk").is_dir():
            versions = sorted((sdk / "ndk").iterdir())
            if versions:
                return versions[-1]
    return None
"""
    if anchor not in text:
        print("FEHLER: _find_ndk-Anker fehlt", file=sys.stderr); sys.exit(1)
    text = text.replace(anchor, anchor + "\n\n" + new_fn, 1)
if "_clang_builtin_shim(guest_cc)" not in text:
    old_abi = ('    guest_abi = " ".join(GUEST_ABI_FLAGS + '
               '(["-DHALO_RELEASE"] if getattr(sln, "port_release", False) else []))')
    new_abi = ('    guest_abi = " ".join(\n'
               '        GUEST_ABI_FLAGS\n'
               '        + _clang_builtin_shim(guest_cc)\n'
               '        + (["-DHALO_RELEASE"] if getattr(sln, "port_release", False) else []))')
    if old_abi in text:
        text = text.replace(old_abi, new_abi, 1)
    else:
        print("WARNUNG: guest_abi-Berechnung nicht gefunden", file=sys.stderr)
with open(path, 'w') as f:
    f.write(text)
print("clang-Builtin-Shim aktiv")
PYEOF

# ── Fix 2c: NUR im Trainings-Modus: PGO-Instrumentierung ─────────────
if [ "$PGO_MODE" = "train" ]; then
    python3 - "$SRC/tools/android_build.py" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
if "-fprofile-instr-generate" in text:
    print("android_build.py hat bereits -fprofile-instr-generate")
    sys.exit(0)
for old in ('"-O3",', '"-O3"'):
    if old in text:
        new = old.replace('"-O3"', '"-O3",\n    "-fprofile-instr-generate"')
        text = text.replace(old, new, 1)
        with open(path, 'w') as f:
            f.write(text)
        print("android_build.py: -fprofile-instr-generate hinzugefuegt")
        sys.exit(0)
print("FEHLER: O3-Flag nicht gefunden", file=sys.stderr)
sys.exit(1)
PYEOF
fi

# ── Fix 2d: NUR im Trainings-Modus: Profiling-Runtime zum Link ───────
if [ "$PGO_MODE" = "train" ]; then
    python3 - "$SRC/tools/android_build.py" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
if "guest_profile_runtime" in text:
    print("android_build.py hat bereits guest_profile_runtime")
    sys.exit(0)
old = '''    n.rule(
        name="android_guest_link",
        command=(f"$android_ndk_bin/ld.lld -m aarch64linux -static -nostdlib -T {linker_script} "
                 f"-Map $out.map -o $out @$out.rsp {libguestc} "
                 "$$($android_host_cc -print-libgcc-file-name)"),
        description="ANDROID LINK $out",
        rspfile="$out.rsp",
        rspfile_content="$in_newline",
    )'''
new = '''    # PGO-Training: die Profiling-Runtime an den Guest-Link anhaengen.
    guest_profile_runtime = ""
    for _cc_candidate in (guest_cc, str(ndk_bin / "clang")):
        if not _cc_candidate:
            continue
        try:
            _rd = subprocess.run([_cc_candidate, "-print-resource-dir"],
                                 capture_output=True, text=True, check=True).stdout.strip()
        except Exception as _e:
            print(f"WARNING: cannot query {_cc_candidate}: {_e}", file=sys.stderr)
            continue
        for _name in ("libclang_rt.profile-aarch64-android.a",
                      "libclang_rt.profile-aarch64.a"):
            _candidate = Path(_rd) / "lib" / "linux" / _name
            if _candidate.is_file():
                guest_profile_runtime = str(_candidate)
                print(f"== using profile runtime from {_cc_candidate}: {guest_profile_runtime}")
                break
        if guest_profile_runtime:
            break
    if not guest_profile_runtime:
        print("WARNING: no profile runtime found; link may fail", file=sys.stderr)
    n.rule(
        name="android_guest_link",
        command=(f"$android_ndk_bin/ld.lld -m aarch64linux -static -nostdlib -T {linker_script} "
                 f"-Map $out.map -o $out @$out.rsp {libguestc} {guest_profile_runtime} "
                 "$$($android_host_cc -print-libgcc-file-name)"),
        description="ANDROID LINK $out",
        rspfile="$out.rsp",
        rspfile_content="$in_newline",
    )'''
if old not in text:
    print("FEHLER: android_guest_link rule nicht gefunden", file=sys.stderr)
    sys.exit(1)
text = text.replace(old, new, 1)
with open(path, 'w') as f:
    f.write(text)
print("android_build.py: Profiling-Runtime zum Link hinzugefuegt")
PYEOF
fi

# ── Fix 3: linux_build.py ────────────────────────────────────────────
python3 - "$SRC/tools/linux_build.py" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
if 'OPTIMISATION = "-O3"' in text:
    print("linux_build.py hat bereits -O3")
    sys.exit(0)
old_opt = 'OPTIMISATION = "-O2"'
new_opt = 'OPTIMISATION = "-O3"'
count_opt = text.count(old_opt)
if count_opt == 0:
    print("WARNUNG: OPTIMISATION = -O2 fehlt", file=sys.stderr)
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
    print("WARNUNG: LINUX_ABI_FLAGS-Marker fehlt", file=sys.stderr)
with open(path, 'w') as f:
    f.write(text)
print(f"linux_build.py: {count_opt}x O2->O3, {count_abi}x zusaetzliche Flags")
PYEOF

# ── Fix 4: Python-Patches ────────────────────────────────────────────
echo ""
echo "== Fix 4: Quellcode-Optimierungen ..."
for patch_script in patch_memory_pools.py patch_neon_math.py; do
    if [ -f "$HERE/patches/$patch_script" ]; then
        echo "== Wende $patch_script an ..."
        if ! python3 "$HERE/patches/$patch_script" "$SRC"; then
            echo "WARNUNG: $patch_script fehlgeschlagen"
        fi
    else
        echo "== $patch_script nicht vorhanden"
    fi
done

# ── Fix 4b: Verifikation der Patches ─────────────────────────────────
echo ""
echo "== Fix 4b: Verifiziere Patch-Ergebnisse ..."
verification_failed=0
check_patch() {
    local file="$1" pattern="$2" name="$3"
    if grep -q -- "$pattern" "$SRC/$file"; then
        echo "   OK: $name"
    else
        echo "   FEHLT: $name ($file)"
        verification_failed=1
    fi
}
check_patch "source/cseries/cseries.h"                    "HALO_DEBUG_ALLOCATOR"               "cseries.h Debug-Allocator"
check_patch "source/effects/decals.c"                     "static __thread long surface_queue" "decals.c __thread-Arrays"
check_patch "source/math/matrix_math.c"                   "vfmaq_n_f32"                        "matrix_math.c NEON"
check_patch "port/android/guest/runtime/guest_string.c"   "vld1q_u8"                           "guest_string.c NEON memcmp"
check_patch "port/android/guest/runtime/guest_string.c"   "vst1q_u8"                           "guest_string.c NEON memcpy"
if [ "$PGO_MODE" = "train" ]; then
    check_patch "tools/android_build.py" "-fprofile-instr-generate" "android_build.py PGO-Instrumentierung"
    check_patch "tools/android_build.py" "guest_profile_runtime"    "android_build.py Profiling-Runtime"
fi
if [ "$verification_failed" -ne 0 ]; then
    echo "FEHLER: Optimierungen fehlen"
    exit 1
fi
echo "== Alle Optimierungen sauber angewendet."

# ── Fix 5: PGO-Shim für bionische Runtime-Symbole ────────────────────
# Die NDK-Profiling-Runtime ist gegen bionic gebaut und ruft Symbole,
# die in unserem musl-Guest fehlen: __errno, __sF, prctl, getpagesize.
#
# KRITISCH: `atexit` allein genügt NICHT, weil der Trainingslauf mit
# `timeout --signal=TERM` beendet wird und der Kernel bei SIGTERM direkt
# terminiert, ohne die atexit-Kette auszuführen. Der Shim installiert
# deshalb SIGTERM/SIGINT/SIGHUP-Handler, die __llvm_profile_write_file()
# aufrufen, bevor der Prozess stirbt.
if [ "$PGO_MODE" = "train" ]; then
    SHIM="$SRC/port/android/guest/runtime/guest_pgo_shim.c"
    cat > "$SHIM" <<'CEOF'
/*
GUEST_PGO_SHIM.C

Bionic-Symbole, die die NDK-LLVM-Profiling-Runtime referenziert, im
musl-Guest aber nicht unter diesen Namen existieren. Ohne diese
Definitionen scheitert der Guest-Link mit:
    ld.lld: error: undefined symbol: __errno / __sF / prctl / getpagesize

Zusätzlich: SIGTERM/SIGINT/SIGHUP-Handler, der das Profil vor dem
Prozessende schreibt. `atexit` allein genügt NICHT, weil der Kernel bei
SIGTERM (das timeout im Trainingslauf schickt) direkt terminiert und die
atexit-Kette überspringt — der Profiling-Handler würde nie ausgeführt,
und es entstünde keine .profraw-Datei.
*/

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

/* Bionics __errno: eine Funktion, die int* zurückgibt, im Unterschied
   zu musls __errno_location. */
static int pgo_errno_value;
int *__errno(void) { return &pgo_errno_value; }

/* Bionics __sF: ein Array von FILE-Objekten. Nur referenziert von
   fprintf(stderr, ...) für LLVM_PROFILE_VERBOSE. */
char __sF[3 * 256];

/* prctl: nur für den SIGKILL-Schutz der Runtime. No-op genügt. */
int prctl(int option, unsigned long a2, unsigned long a3, unsigned long a4, unsigned long a5)
{
    (void)option; (void)a2; (void)a3; (void)a4; (void)a5;
    return 0;
}

/* getpagesize: POSIX, auf AArch64 immer 4096. */
int getpagesize(void) { return 4096; }

/* LLVM-Profiling-API. */
extern int __llvm_profile_write_file(void);

/* Signal-Handler: Profil schreiben, dann mit dem Signal sterben, damit
   der Exit-Code korrekt bleibt. */
static void pgo_write_and_die(int sig)
{
    __llvm_profile_write_file();
    signal(sig, SIG_DFL);
    raise(sig);
}

__attribute__((constructor)) static void pgo_install_handlers(void)
{
    struct sigaction sa;

    sa.sa_handler = pgo_write_and_die;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT,  &sa, NULL);
    sigaction(SIGHUP,  &sa, NULL);

    /* Fallback für den normalen Exit (Hotkey, exit()). */
    atexit((void (*)(void))__llvm_profile_write_file);
}
CEOF
    if [ -f "$SHIM" ]; then
        echo "== Fix 5: guest_pgo_shim.c erzeugt ($(stat -c%s "$SHIM") Bytes)"
    else
        die "Fix 5: guest_pgo_shim.c konnte nicht erzeugt werden"
    fi
fi

# ── Port-Verzeichnis kopieren ────────────────────────────────────────
if [ ! -d "$HERE/port/knulli" ]; then
    die "port/knulli/ existiert nicht im Repo"
fi
rm -rf "$SRC/port/knulli"
cp -a "$HERE/port/knulli" "$SRC/port/knulli"
rm -rf "$SRC/port/knulli/__pycache__"
chmod +x "$SRC/port/knulli/build.sh" 2>/dev/null || true

stamp=$({
    cat "$PATCH"
    cat "$HERE/patches/patch_memory_pools.py" 2>/dev/null || true
    cat "$HERE/patches/patch_neon_math.py"    2>/dev/null || true
    if [ -f "$HERE/pgo/halo_android.profdata" ]; then
        sha256sum "$HERE/pgo/halo_android.profdata" | cut -d' ' -f1
    fi
    echo "pgo-mode=$PGO_MODE"
    (cd "$HERE/port/knulli" && find . -type f ! -path '*/__pycache__/*' -print0 | sort -z | xargs -0 cat)
} | sha256sum | cut -d' ' -f1)
if [ -f "$SRC/.port-stamp" ] && [ "$(cat "$SRC/.port-stamp")" = "$stamp" ]; then
    rm -rf "$SRC/build/knulli"
fi
echo "$stamp" > "$SRC/.port-stamp"

# ── Build ────────────────────────────────────────────────────────────
export ANDROID_NDK SYSROOT_LIB
export SDL2_INCLUDE
export GUEST_CC HOST_CC JOBS

cd "$SRC"

echo "== Konfiguriere mit $LTO_FLAG --pgo=off $PGO_EXTRA_ARGS ..."
python3 configure.py --release $LTO_FLAG --pgo=off $PGO_EXTRA_ARGS \
    --android-ndk "$ANDROID_NDK" --android-guest-cc "$GUEST_CC"

echo "== Baue Guest-ELF (halo_guest.elf) ..."
ninja -j "$JOBS" build/android/halo_guest.elf

echo "== Baue Host-Binary (halo) ueber port/knulli/build.sh ..."
bash "$SRC/port/knulli/build.sh"

# ── Distribution zusammenstellen ─────────────────────────────────────
echo "== copying the build into $DIST"
rm -rf "$DIST"
mkdir -p "$DIST"
cp "$SRC/build/knulli/halo" "$DIST/halo"
cp "$SRC/build/knulli/halo_guest.elf" "$DIST/halo_guest.elf"
cp "$SRC/port/knulli/Halo.sh" "$DIST/Halo.sh"
cp "$SRC/port/knulli/halo_extract.py" "$DIST/halo_extract.py" 2>/dev/null || true
cp "$SRC/port/knulli/halo_screen.py" "$DIST/halo_screen.py" 2>/dev/null || true
cp "$SRC/port/knulli/sdl_mapping.py" "$DIST/sdl_mapping.py" 2>/dev/null || true
if [ -d "$SRC/build/knulli/libs.aarch64" ]; then
    mkdir -p "$DIST/libs.aarch64"
    cp -a "$SRC/build/knulli/libs.aarch64/." "$DIST/libs.aarch64/"
fi
chmod +x "$DIST/Halo.sh" 2>/dev/null || true

GUEST_SIZE=$(stat -c%s "$DIST/halo_guest.elf")
GUEST_SIZE_MB=$((GUEST_SIZE / 1048576))
echo "== halo_guest.elf: $GUEST_SIZE Bytes (~${GUEST_SIZE_MB} MB)"

if [ "$PGO_MODE" = "train" ]; then
    if [ "$GUEST_SIZE" -lt 11500000 ]; then
        die "Trainings-Build ist nur ${GUEST_SIZE_MB} MB – Instrumentierung hat nicht gegriffen."
    fi
    cat <<'TRAINING'

────────────────────────────────────────────────────────────────────────
TRAININGS-BUILD FERTIG
────────────────────────────────────────────────────────────────────────

Naechste Schritte auf dem M9 Pro:

1. dist/Halo.sh           nach /roms/ports/Halo.sh
2. dist/halo_guest.elf    nach /roms/ports/halo-ce/halo_guest.elf
3. dist/halo              nach /roms/ports/halo-ce/halo

4. Spiel starten. Beendet sich nach 10 Minuten selbst (SIGTERM).
5. .profraw-Dateien vom Geraet holen.
6. llvm-profdata merge -output=pgo/halo_android.profdata halo-*.profraw
7. PGO_MODE=use ./build.sh

FERTIG.
────────────────────────────────────────────────────────────────────────
TRAINING
fi
