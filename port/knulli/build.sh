#!/bin/sh
# Builds the Knulli port (port/knulli/README.md) into build/knulli:
#   halo            the aarch64 glibc host (the loader, SDL2, OpenGL ES)
#   halo_guest.elf  the game, the Android port's guest image
#
# Needs: python configure.py run with --android-ndk (the guest build), the
# aarch64-linux-gnu cross compiler, SDL2 headers (SDL2_INCLUDE) and the
# device's libraries to link against (SYSROOT_LIB: libSDL2-2.0.so.0 and
# libmali.so.0, which has OpenGL ES and EGL, from /usr/lib of the device).
set -eu

cd "$(dirname "$0")/../.."
SDL2_INCLUDE=${SDL2_INCLUDE:?the folder that holds SDL2/SDL.h}
SYSROOT_LIB=${SYSROOT_LIB:?the device libraries}
NDK=${ANDROID_NDK:?the Android NDK (for the OpenGL ES and EGL headers)}
CC=${CC:-aarch64-linux-gnu-gcc}
JOBS=${JOBS:-$(nproc)}
OUT=build/knulli
OBJ=$OUT/obj

ninja -j "$JOBS" build/android/halo_guest.elf build/android/host/host_import_table.c

mkdir -p "$OBJ" "$OUT/gl_include" "$OUT/lib"
KHRONOS=$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include
for name in EGL GLES2 GLES3 KHR; do
	ln -sfn "$KHRONOS/$name" "$OUT/gl_include/$name"
done
# link names for the device's libraries
for name in libSDL2-2.0.so.0:libSDL2.so libmali.so.0:libmali.so; do
	library=$(ls "$SYSROOT_LIB/${name%%:*}"* | head -n 1)
	ln -sf "$library" "$OUT/lib/${name##*:}"
done

CFLAGS="-O2 -g -mcpu=cortex-a53 -fPIC -Wall -Wno-unused-function -D_GNU_SOURCE -DEGL_NO_X11 -DMESA_EGL_NO_X11_HEADERS"
INCLUDES="-Iport/knulli/compat -Iport/knulli/host -Iport/android/include -Iport/android/host -Iport/linux/src
	-Iport/third_party/tomlc17 -I$OUT/gl_include -I$SDL2_INCLUDE"
MINIUPNPC="-Iport/third_party/miniupnpc/include -Iport/third_party/miniupnpc/src -DMINIUPNP_STATICLIB
	-DMINIUPNPC_SET_SOCKET_TIMEOUT -DMINIUPNPC_GET_SRC_ADDR -D_BSD_SOURCE -D_DEFAULT_SOURCE -w"

objects=""
compile() {
	source=$1
	shift
	object=$OBJ/$(echo "$source" | tr / _).o
	if [ ! -f "$object" ] || [ "$source" -nt "$object" ] || [ "$0" -nt "$object" ]; then
		echo "CC $source"
		# shellcheck disable=SC2086
		$CC $CFLAGS $INCLUDES "$@" -c "$source" -o "$object"
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
# the GL thread's recording functions, from the functions the guest imports
python3 port/knulli/glthread_gen.py build/android/guest/gen/gl_imports.list "$KHRONOS/GLES3/gl32.h" \
	"$OUT/host_glthread_gen.c.new"
cmp -s "$OUT/host_glthread_gen.c.new" "$OUT/host_glthread_gen.c" || mv "$OUT/host_glthread_gen.c.new" "$OUT/host_glthread_gen.c"
rm -f "$OUT/host_glthread_gen.c.new"
compile port/knulli/host/host_glthread.c
compile "$OUT/host_glthread_gen.c"
compile port/knulli/host/host_sdl3_events.c -Ibuild/android/third_party/SDL3/include
compile port/linux/src/posix_files.c
compile port/linux/src/posix_net.c
# shellcheck disable=SC2086
compile port/linux/src/posix_upnp.c $MINIUPNPC
for source in port/third_party/miniupnpc/src/*.c; do
	# shellcheck disable=SC2086
	compile "$source" $MINIUPNPC
done
compile port/third_party/tomlc17/tomlc17.c -w
compile build/android/host/host_import_table.c

echo "LINK $OUT/halo"
# shellcheck disable=SC2086
$CC -o "$OUT/halo" $objects -L"$OUT/lib" -Wl,-rpath-link,"$OUT/lib" -Wl,--allow-shlib-undefined \
	-lSDL2 -lmali -lpthread -ldl -lm
cp build/android/halo_guest.elf "$OUT/halo_guest.elf"
ls -l "$OUT/halo" "$OUT/halo_guest.elf"
