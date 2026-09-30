#!/usr/bin/env bash
# Builds Halo: Combat Evolved for Knulli on the Allwinner H700 handhelds
# (Anbernic RG35XX H and its family) from the upstream decompilation, this
# repository's patch and port/knulli. The result is in dist/. Refer to
# README.md, "Build from source".
#
#   ANDROID_NDK=/path/to/android-ndk-r28c SYSROOT_LIB=/path/to/device-libs ./build.sh
#
# Environment:
#   ANDROID_NDK  the Android NDK r28c (the guest build, the GLES and EGL headers)
#   SYSROOT_LIB  a folder with libSDL2-2.0.so.0* and libmali.so.0* copied from
#                the handheld's /usr/lib (used to link only)
#   GUEST_CC     a clang with the arm64_32 target (default: clang-22)
#   HOST_CC      the aarch64 glibc cross compiler (default: aarch64-linux-gnu-gcc)
#   WORK         the working folder (default: work/ next to this script)
#   DIST         the output folder (default: dist/ next to this script)
#   JOBS         parallel jobs (default: the number of processors)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
UPSTREAM_URL=${UPSTREAM_URL:-https://github.com/cybersecurity/halo-ce-universal.git}
UPSTREAM_COMMIT=$(tr -d '[:space:]' < "$HERE/UPSTREAM_COMMIT")
PATCH=$HERE/patches/halo-ce-universal-knulli.patch
SDL2_TAG=release-2.30.12
SDL2_ARCHIVE=https://github.com/libsdl-org/SDL/archive/refs/tags/$SDL2_TAG.tar.gz
GUEST_CC=${GUEST_CC:-clang-22}
HOST_CC=${HOST_CC:-aarch64-linux-gnu-gcc}
JOBS=${JOBS:-$(nproc)}

die() {
	echo "build.sh: $*" >&2
	exit 1
}

need() {
	command -v "$1" > /dev/null 2>&1 || die "$1 not found: $2"
}

# ---------- tools and inputs

need git "install git"
need python3 "install python3"
need ninja "install ninja-build"
need curl "install curl (the build downloads musl and the SDL2 headers)"
need tar "install tar"
need "$HOST_CC" "install gcc-aarch64-linux-gnu, or set HOST_CC"
need "$GUEST_CC" "install clang-22 from apt.llvm.org, or set GUEST_CC to a clang with the arm64_32 target"
"$GUEST_CC" -print-targets 2> /dev/null | grep -q aarch64_32 ||
	die "$GUEST_CC has no arm64_32 (aarch64_32) target; use clang 22 from apt.llvm.org"

[ -n "${ANDROID_NDK:-}" ] ||
	die "set ANDROID_NDK to the Android NDK r28c folder (it builds the guest and has the GLES and EGL headers)"
[ -d "$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64" ] ||
	die "ANDROID_NDK=$ANDROID_NDK is not an Android NDK (no toolchains/llvm/prebuilt/linux-x86_64)"
ANDROID_NDK=$(cd "$ANDROID_NDK" && pwd)

[ -n "${SYSROOT_LIB:-}" ] ||
	die "set SYSROOT_LIB to a folder with libSDL2-2.0.so.0* and libmali.so.0* copied from the handheld's /usr/lib"
[ -d "$SYSROOT_LIB" ] || die "SYSROOT_LIB=$SYSROOT_LIB is not a folder"
SYSROOT_LIB=$(cd "$SYSROOT_LIB" && pwd)
for library in libSDL2-2.0.so.0 libmali.so.0; do
	compgen -G "$SYSROOT_LIB/$library*" > /dev/null ||
		die "no $library* in SYSROOT_LIB=$SYSROOT_LIB (copy it from the handheld's /usr/lib)"
done

WORK=${WORK:-$HERE/work}
DIST=${DIST:-$HERE/dist}
mkdir -p "$WORK" "$DIST"
WORK=$(cd "$WORK" && pwd)
DIST=$(cd "$DIST" && pwd)
SRC=$WORK/halo-ce-universal
SDL2_INCLUDE=$WORK/sdl2-include

# ---------- upstream at the pinned commit

if [ ! -d "$SRC/.git" ]; then
	echo "== cloning $UPSTREAM_URL into $SRC"
	git init -q "$SRC"
	git -C "$SRC" remote add origin "$UPSTREAM_URL"
fi
if ! git -C "$SRC" cat-file -e "$UPSTREAM_COMMIT^{commit}" 2> /dev/null; then
	echo "== fetching $UPSTREAM_COMMIT"
	git -C "$SRC" fetch -q --depth 1 origin "$UPSTREAM_COMMIT" || git -C "$SRC" fetch -q origin
	git -C "$SRC" cat-file -e "$UPSTREAM_COMMIT^{commit}" 2> /dev/null ||
		die "commit $UPSTREAM_COMMIT is not in $UPSTREAM_URL"
fi

# The tree is reset only when it is not already the pinned commit with the
# patch applied, so that unchanged files keep their times and a rebuild is
# incremental. git clean without -x keeps the ignored build/ and build.ninja.
# The "index" lines are left out of the comparison: their abbreviated object
# names are longer in a full clone than in this shallow one.
tree_is_patched() {
	[ "$(git -C "$SRC" rev-parse HEAD 2> /dev/null || true)" = "$UPSTREAM_COMMIT" ] &&
		cmp -s <(git -C "$SRC" diff | grep -v '^index ') <(grep -v '^index ' "$PATCH")
}
if ! tree_is_patched; then
	echo "== checking out $UPSTREAM_COMMIT and applying $(basename "$PATCH")"
	git -C "$SRC" checkout -q --force --detach "$UPSTREAM_COMMIT"
	git -C "$SRC" reset -q --hard
	git -C "$SRC" clean -q -fd
	git -C "$SRC" apply "$PATCH"
fi
rm -rf "$SRC/port/knulli"
cp -a "$HERE/port/knulli" "$SRC/port/knulli"
rm -rf "$SRC/port/knulli/__pycache__"

# port/knulli/build.sh rebuilds a host file when the file itself is newer
# than its object, not when a header it includes changes: start the host's
# objects afresh whenever the patch or port/knulli changes.
stamp=$({
	cat "$PATCH"
	(cd "$HERE/port/knulli" && find . -type f ! -path '*/__pycache__/*' -print0 | sort -z | xargs -0 sha256sum)
} | sha256sum | cut -d ' ' -f 1)
if [ "$(cat "$WORK/source.stamp" 2> /dev/null || true)" != "$stamp" ]; then
	rm -rf "$SRC/build/knulli/obj"
	echo "$stamp" > "$WORK/source.stamp"
fi

# ---------- SDL2 headers (the device's SDL2 is 2.30.12)

if [ ! -f "$SDL2_INCLUDE/SDL2/SDL.h" ]; then
	echo "== downloading the SDL2 headers ($SDL2_TAG)"
	rm -rf "$SDL2_INCLUDE" "$SDL2_INCLUDE.tmp"
	mkdir -p "$SDL2_INCLUDE.tmp"
	curl -sSfL "$SDL2_ARCHIVE" |
		tar -xz -C "$SDL2_INCLUDE.tmp" --strip-components=2 --wildcards "SDL-$SDL2_TAG/include/*"
	mkdir -p "$SDL2_INCLUDE"
	mv "$SDL2_INCLUDE.tmp" "$SDL2_INCLUDE/SDL2"
fi

# ---------- build

cd "$SRC"
if [ ! -f build.ninja ]; then
	echo "== configuring"
	python3 configure.py --release --android-ndk "$ANDROID_NDK" --android-guest-cc "$GUEST_CC" \
		--linux-cc "$GUEST_CC"
fi
grep -q 'halo_guest\.elf' build.ninja ||
	die "build.ninja has no Android guest build: delete $SRC/build.ninja and check configure's output (it downloads musl and SDL3)"

echo "== building (this takes a while the first time)"
SDL2_INCLUDE=$SDL2_INCLUDE SYSROOT_LIB=$SYSROOT_LIB ANDROID_NDK=$ANDROID_NDK CC=$HOST_CC JOBS=$JOBS \
	sh port/knulli/build.sh

# ---------- dist

cp build/knulli/halo build/knulli/halo_guest.elf "$DIST/"
cp port/knulli/Halo.sh port/knulli/halo_extract.py port/knulli/sdl_mapping.py "$DIST/"
chmod 755 "$DIST/halo" "$DIST/Halo.sh" "$DIST/halo_extract.py" "$DIST/sdl_mapping.py"
echo "== done: $DIST"
ls -l "$DIST"
