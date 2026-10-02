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

# --- Fix 1 (entfernt): Der frühere SetEvent-Aufruf in ReadFileEx/WriteFileEx
# war falsch. Microsoft dokumentiert, dass diese Funktionen das hEvent-Feld
# ignorieren ("ReadFileEx 函数忽略 OVERLAPPED 结构的 hEvent 成员"). Die
# Engine nutzt hEvent für eigene Zwecke, der Wert ist kein Host-Handle.
# SetEvent(0xa) führte zum Absturz bei Adresse 0xa (signal 11).
#
# --- Fix 2: Die APCs (Completion-Routinen) wurden in WaitForSingleObjectEx
# und SleepEx nur VOR dem Warten ausgeführt, nicht WÄHREND. Die Engine wartet
# in WaitForSingleObjectEx auf eine abgeschlossene asynchrone Profil-I/O,
# die APC lief nie, nach 6 Sekunden Timeout meldete die Engine "checksum
# failed on persistent storage". Die Warteschleifen werden so erweitert,
# dass APCs auch während des Wartens ausgeführt werden.
python3 - "$SRC/port/linux/src/xbox_kernel.c" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    text = f.read()

# --- WaitForSingleObjectEx ---
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

# --- SleepEx ---
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

export ANDROID_NDK SYSROOT_LIB
export SDL2_INCLUDE
export GUEST_CC HOST_CC JOBS

cd "$SRC"
python3 configure.py --release --android-ndk "$ANDROID_NDK" --android-guest-cc "$GUEST_CC"
ninja -j "$JOBS" build/android/halo_guest.elf

bash "$SRC/port/knulli/build.sh"

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
