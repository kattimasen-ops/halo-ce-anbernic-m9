#!/bin/sh
# Builds the Knulli port into build/knulli:
#   halo            the aarch64 STATIC glibc host
#   halo_guest.elf  the game, the Android port's guest image
#
# Kein libs.aarch64 mehr: der Host ist statisch, bringt seine eigene
# glibc mit und braucht weder libmali noch libSDL2 auf dem Geraet.
#
# POSIX-sh-kompatibel (dash): set -eu statt set -euo pipefail.
set -eu

folder() {
    resolved=$(cd "$1" && pwd) || { echo "build.sh: $1: no such folder" >&2; exit 1; }
    case "$resolved" in
        *" "*) echo "build.sh: $resolved: a path with spaces is not supported" >&2; exit 1 ;;
    esac
    echo "$resolved"
}

SDL2_INCLUDE=$(folder "${SDL2_INCLUDE:?the folder that holds SDL2/SDL.h}")
SYSROOT_LIB=$(folder "${SYSROOT_LIB:?the device libraries}")
NDK=$(folder "${ANDROID_NDK:?the Android NDK (for the OpenGL ES and EGL headers)}")

cd "$(dirname "$0")/../.."
ROOT=$(folder .)
CC=${CC:-aarch64-linux-gnu-gcc}
JOBS=${JOBS:-$(nproc)}
OUT=build/knulli
OBJ=$OUT/obj

# Statisches SDL2 (von der Root-build.sh gebaut)
SDL2_LIB_DIR="${SDL2_LIB_DIR:?SDL2_LIB_DIR not set}"

ninja -j "$JOBS" build/android/halo_guest.elf build/android/host/host_import_table.c
mkdir -p "$OBJ" "$OUT/gl_include" "$OUT/lib"

KHRONOS=$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include
for name in EGL GLES2 GLES3 KHR; do
    ln -sfn "$KHRONOS/$name" "$OUT/gl_include/$name"
done

CFLAGS="-O3 -mcpu=cortex-a35 -mtune=cortex-a35 -fPIC -Wall -Wno-unused-function \
        -D_GNU_SOURCE -DEGL_NO_X11 -DMESA_EGL_NO_X11_HEADERS \
        -DHALO_ANDROID \
        -fomit-frame-pointer -ffunction-sections -fdata-sections \
        -fno-plt -fno-semantic-interposition"

CFLAGS="$CFLAGS -ffile-prefix-map=$ROOT=. -ffile-prefix-map=$SDL2_INCLUDE=sdl2"
INCLUDES="-Iport/knulli/compat -Iport/knulli/host -Iport/android/include \
          -Iport/android/host -Iport/linux/src -Iport/third_party/tomlc17 \
          -I$OUT/gl_include -I$SDL2_INCLUDE"
MINIUPNPC="-Iport/third_party/miniupnpc/include -Iport/third_party/miniupnpc/src \
           -DMINIUPNP_STATICLIB -DMINIUPNPC_SET_SOCKET_TIMEOUT -DMINIUPNPC_GET_SRC_ADDR \
           -D_BSD_SOURCE -D_DEFAULT_SOURCE -w"

FLAGS=$OUT/flags
printf '%s\n' "$CC $CFLAGS $INCLUDES $MINIUPNPC" > "$FLAGS.new"
cmp -s "$FLAGS.new" "$FLAGS" || mv "$FLAGS.new" "$FLAGS"
rm -f "$FLAGS.new"

objects=""
stale() {
    object=$1
    [ ! -f "$object" ] || [ ! -f "$object.d" ] || [ "$0" -nt "$object" ] || [ "$FLAGS" -nt "$object" ] && return 0
    dependencies=$(sed -e 's/^[^:]*://' -e 's/\\$//' "$object.d") || return 0
    for dependency in $dependencies; do
        [ -f "$dependency" ] || return 0
        [ "$dependency" -nt "$object" ] && return 0
    done
    return 1
}

compile() {
    source=$1
    shift
    object=$OBJ/$(echo "$source" | tr / _).o
    if stale "$object"; then
        echo "CC $source"
        $CC $CFLAGS $INCLUDES "$@" -MMD -MF "$object.d" -c "$source" -o "$object"
    fi
    objects="$objects $object"
}

for source in host_debug host_gl host_loader host_memory host_syscall host_thread; do
    compile port/android/host/$source.c
done
compile port/knulli/host/host_main.c
compile port/knulli/host/host_sdl2.c
compile port/knulli/host/host_profile.c
compile port/knulli/host/host_gl_timing.c
compile port/knulli/host/host_gl_timing.S

python3 port/knulli/glthread_gen.py build/android/guest/gen/gl_imports.list \
    "$KHRONOS/GLES3/gl32.h" \
    "$OUT/host_glthread_gen.c.new"
cmp -s "$OUT/host_glthread_gen.c.new" "$OUT/host_glthread_gen.c" || \
    mv "$OUT/host_glthread_gen.c.new" "$OUT/host_glthread_gen.c"
rm -f "$OUT/host_glthread_gen.c.new"

compile port/knulli/host/host_glthread.c
compile "$OUT/host_glthread_gen.c"
compile port/knulli/host/host_sdl3_events.c -Ibuild/android/third_party/SDL3/include
compile port/linux/src/posix_files.c
compile port/linux/src/posix_net.c
compile port/linux/src/posix_upnp.c $MINIUPNPC
for source in port/third_party/miniupnpc/src/*.c; do
    compile "$source" $MINIUPNPC
done
compile port/third_party/tomlc17/tomlc17.c -w
compile build/android/host/host_import_table.c

echo "LINK $OUT/halo (statisch)"
# STATISCH: -static + libSDL2.a. Die glibc kommt aus dem Binary,
# das Geraet braucht keine passende System-glibc mehr.
# --allow-multiple-definition: einige Symbole (z. B. dlopen) sind in
# glibc sowohl in libc.a als auch in libdl.a enthalten.
$CC -static -o "$OUT/halo" $objects \
    "$SDL2_LIB_DIR/libSDL2.a" \
    -Wl,--allow-multiple-definition \
    -Wl,-O1 -Wl,--gc-sections \
    -lm -lpthread -ldl -lrt -lresolv

cp build/android/halo_guest.elf "$OUT/halo_guest.elf"

echo "== Pruefe auf dynamische Abhaengigkeiten:"
if command -v file > /dev/null 2>&1; then
    file "$OUT/halo" || true
fi
if command -v readelf > /dev/null 2>&1; then
    echo "  NEEDED-Bibliotheken (leer = statisch):"
    readelf -d "$OUT/halo" 2>/dev/null | grep NEEDED || echo "  (keine — statisch)"
    echo "  GLIBC-Versionsbedarf (leer = keine):"
    readelf --dyn-syms "$OUT/halo" 2>/dev/null | grep -E "GLIBC_[0-9]" || echo "  (keine — statisch)"
fi

echo "== $OUT/halo und $OUT/halo_guest.elf:"
ls -l "$OUT/halo" "$OUT/halo_guest.elf"
