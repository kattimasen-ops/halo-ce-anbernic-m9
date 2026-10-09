#!/bin/sh
# Builds the Knulli port into build/knulli:
#   halo            the aarch64 STATIC glibc host
#   halo_guest.elf  the game, the Android port's guest image
#   libs.aarch64/   die Laufzeitbibliotheken (SDL2 als Fallback)
#
# POSIX-sh-kompatibel (dash): set -eu statt set -euo pipefail.
#
# WICHTIG: Host wird STATISCH gelinkt, inklusive SDL2 (libSDL2.a).
# Grund: Die System-glibc auf dem M9 Pro (ArkOS) enthaelt LSE-Atomics
# (ARMv8.1); der Cortex-A35 ist ARMv8.0 und stirbt daran mit SIGILL.
# Eine statische glibc im Host umgeht das. libmali wird weiterhin per
# dlopen zur Laufzeit geladen (ueber /tmp/halo-mali in Halo.sh), aber
# SDL2 und glibc sind im Host eingebettet.
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
CC=${CC:-aarch64-clang}
JOBS=${JOBS:-$(nproc)}
OUT=build/knulli
OBJ=$OUT/obj

# Statisches SDL2 (aus $SDL2_LIB_DIR) fuer den Host-Link.
SDL2_LIB_DIR="${SDL2_LIB_DIR:-}"
STATIC_SDL2=""
if [ -n "$SDL2_LIB_DIR" ] && [ -f "$SDL2_LIB_DIR/libSDL2.a" ]; then
    STATIC_SDL2="$SDL2_LIB_DIR/libSDL2.a"
fi

ninja -j "$JOBS" build/android/halo_guest.elf build/android/host/host_import_table.c
mkdir -p "$OBJ" "$OUT/gl_include" "$OUT/lib" "$OUT/libs.aarch64"

KHRONOS=$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include
for name in EGL GLES2 GLES3 KHR; do
    ln -sfn "$KHRONOS/$name" "$OUT/gl_include/$name"
done

echo "== Inhalt von SYSROOT_LIB=$SYSROOT_LIB:"
ls -la "$SYSROOT_LIB" || true

echo "== Kopiere Laufzeitbibliotheken nach $OUT/libs.aarch64/"
copy_runtime_lib() {
    prefix=$1
    target=$2
    src=$(find "$SYSROOT_LIB" -maxdepth 1 -name "$prefix*" -type f 2>/dev/null | head -n 1)
    if [ -z "$src" ]; then
        src=$(find "$SYSROOT_LIB" -maxdepth 1 -name "$prefix*" 2>/dev/null | head -n 1)
    fi
    if [ -z "$src" ]; then
        echo "  WARNUNG: keine $prefix*-Datei in SYSROOT_LIB – $target wird nicht ausgeliefert"
        return 1
    fi
    cp -L "$src" "$OUT/libs.aarch64/$target"
    echo "  $target <- $(basename "$src") ($(stat -c%s "$OUT/libs.aarch64/$target") Bytes)"
    return 0
}

# Nur die dynamischen Bibliotheken ausliefern, die der Host zur Laufzeit
# braucht. libmali wird nicht mitgeliefert (kommt aus /tmp/halo-mali).
copy_runtime_lib "libSDL3"   "libSDL3.so.0"
copy_runtime_lib "libSDL2"   "libSDL2-2.0.so.0"
copy_runtime_lib "libdecor"  "libdecor-0.so.0"

link_library() {
    pattern=$1
    linkname=$2
    library=$(find "$SYSROOT_LIB" -maxdepth 1 -name "$pattern" -type f 2>/dev/null | head -n 1)
    if [ -z "$library" ]; then
        library=$(find "$SYSROOT_LIB" -maxdepth 1 -name "$pattern" 2>/dev/null | head -n 1)
    fi
    if [ -z "$library" ]; then
        echo "build.sh: no $pattern in SYSROOT_LIB=$SYSROOT_LIB" >&2
        return 1
    fi
    rm -f "$OUT/lib/$linkname"
    ln -sf "$library" "$OUT/lib/$linkname"
    echo "  linked $linkname -> $library"
    return 0
}

link_library "libSDL2*"  "libSDL2.so"    || exit 1
link_library "libSDL3*"  "libSDL3.so"    || exit 1
link_library "libdecor*" "libdecor.so"   || exit 1

CFLAGS="-O3 -mcpu=cortex-a35 -mtune=cortex-a35 -march=armv8-a -mno-outline-atomics \
        -fPIC -Wall -Wno-unused-function \
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

# ── LINK ─────────────────────────────────────────────────────────────
echo "LINK $OUT/halo"

if [ -n "$STATIC_SDL2" ]; then
    echo "  Modus: STATISCH (libSDL2.a + -static)"
    echo "  libSDL2.a: $STATIC_SDL2 ($(stat -c%s "$STATIC_SDL2") Bytes)"
    # --whole-archive fuer libSDL2.a: damit alle von SDL2 intern
    # referenzierten Objekte mit hineinkommen (SDL_main, Dynapi usw.).
    # Reihenfolge: objects -> SDL2.a -> weitere statische Systemlibs.
    $CC -static $CFLAGS -o "$OUT/halo" $objects \
        -Wl,--whole-archive "$STATIC_SDL2" -Wl,--no-whole-archive \
        -Wl,--allow-multiple-definition \
        -Wl,-O1 -Wl,--gc-sections \
        -lm -lpthread -ldl -lrt -lresolv
else
    echo "  Modus: DYNAMISCH (kein libSDL2.a gefunden)"
    echo "  WARNUNG: Ohne statisches SDL2 laedt der Host die System-glibc,"
    echo "           die auf dem M9 Pro LSE-Atomics enthaelt und SIGILL"
    echo "           ausloest. Baue SDL2 mit -DSDL_STATIC=ON in der"
    echo "           Root-build.sh, damit libSDL2.a entsteht."
    $CC $CFLAGS -o "$OUT/halo" $objects \
        -L"$OUT/lib" \
        -Wl,-rpath-link,"$OUT/lib" \
        -Wl,--allow-shlib-undefined \
        -Wl,--unresolved-symbols=ignore-all \
        -Wl,--as-needed -Wl,--gc-sections \
        -lSDL2 -lpthread -ldl -lm
fi

cp build/android/halo_guest.elf "$OUT/halo_guest.elf"

# ── DIAGNOSE ─────────────────────────────────────────────────────────
echo ""
echo "== Host-Binary-Diagnose:"
if command -v file > /dev/null 2>&1; then
    file "$OUT/halo" || true
fi
ls -l "$OUT/halo"
HOST_SIZE=$(stat -c%s "$OUT/halo")
echo "  Groesse: $HOST_SIZE Bytes"

if command -v readelf > /dev/null 2>&1; then
    echo "  Dynamische Abhaengigkeiten (leer = statisch):"
    readelf -d "$OUT/halo" 2>/dev/null | grep NEEDED || echo "    (keine)"
fi

if [ "$HOST_SIZE" -lt 400000 ]; then
    echo "  WARNUNG: Host-Binary ist unerwartet klein ($HOST_SIZE Bytes)."
    echo "           Erwartet: ueber 400 KB (SDL2 statisch eingebunden)."
fi

echo ""
echo "== Inhalt von $OUT/libs.aarch64/:"
ls -la "$OUT/libs.aarch64/"
echo "== $OUT/halo und $OUT/halo_guest.elf:"
ls -l "$OUT/halo" "$OUT/halo_guest.elf"
