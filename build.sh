#!/usr/bin/env bash
# Builds Halo: Combat Evolved for the port.
# Refer to README.md, "Build from source".
#
# ANDROID_NDK=/path/to/android-ndk-r28c SYSROOT_LIB=/path/to/sysroot ./build.sh
#
# Environment:
#   ANDROID_NDK   the Android NDK r28c (the guest build, the GLES and EGL headers)
#   SYSROOT_LIB   a folder with libSDL2-2.0.so.0*, libSDL3.so.0* and
#                 libmali.so.0* (the runtime libraries; they are also
#                 shipped in the artifact under libs.aarch64/)
#   GUEST_CC      a clang with the arm64_32 target (default: clang-22)
#   HOST_CC       the aarch64 glibc cross compiler (default: aarch64-linux-gnu-gcc)
#   WORK          the working folder (default: work/ next to this script)
#   DIST          the output folder (default: dist/ next to this script)
#   JOBS          parallel jobs (default: the number of processors)

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

die() { echo "build.sh: $*" >&2; exit 1; }
need() { command -v "$1" > /dev/null 2>&1 || die "$1 not found: $2"; }

# ---------- tools and inputs
need git "install git"
need python3 "install python3"
need ninja "install ninja-build"
need curl "install curl (the build downloads musl and the SDL2 headers)"
need tar "install tar"
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
for library in libSDL2-2.0.so.0 libSDL3.so.0 libmali.so.0; do
    compgen -G "$SYSROOT_LIB/$library*" > /dev/null || die "no $library* in SYSROOT_LIB=$SYSROOT_LIB"
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

# ---------- SDL2 headers
if [ ! -d "$SDL2_INCLUDE/SDL2" ]; then
    echo "== downloading SDL2 $SDL2_TAG headers"
    mkdir -p "$SDL2_INCLUDE"
    curl -L -o "$WORK/sdl2.tar.gz" "$SDL2_ARCHIVE"
    tar -xzf "$WORK/sdl2.tar.gz" -C "$WORK" --strip-components=1 \
        -C "$SDL2_INCLUDE" "SDL-$SDL2_TAG/include"
fi

# ---------- guest and host
export ANDROID_NDK SYSROOT_LIB
export SDL2_INCLUDE
export GUEST_CC HOST_CC JOBS

cd "$SRC"
python3 configure.py --release --android-ndk "$ANDROID_NDK" --android-guest-cc "$GUEST_CC"
ninja -j "$JOBS" build/android/halo_guest.elf

# port/knulli/build.sh ist eine Shell-Datei, deren x-Bit je nach Checkout
# fehlen kann. Über "sh" aufrufen, damit die Datei unabhängig von den
# Dateirechten ausgeführt wird.
sh "$HERE/port/knulli/build.sh"

# ---------- dist
echo "== copying the build into $DIST"
rm -rf "$DIST"
mkdir -p "$DIST"

cp "$SRC/build/knulli/halo" "$DIST/halo"
cp "$SRC/build/knulli/halo_guest.elf" "$DIST/halo_guest.elf"
cp "$HERE/port/knulli/Halo.sh" "$DIST/Halo.sh"
cp "$HERE/port/knulli/halo_extract.py" "$DIST/halo_extract.py"
cp "$HERE/port/knulli/halo_screen.py" "$DIST/halo_screen.py"
cp "$HERE/port/knulli/sdl_mapping.py" "$DIST/sdl_mapping.py"

# ── Laufzeitbibliotheken mit in das Artifact kopieren ───────────────────
# Sie liegen nach dem Host-Build in build/knulli/libs.aarch64/ und werden
# unverändert nach dist/libs.aarch64/ übernommen. Halo.sh nimmt diesen
# Ordner über LD_LIBRARY_PATH auf, sodass das Gerät libSDL3 und libmali
# findet, auch wenn sie dort nicht (in der passenden Version) installiert
# sind.
if [ -d "$SRC/build/knulli/libs.aarch64" ]; then
    mkdir -p "$DIST/libs.aarch64"
    cp -a "$SRC/build/knulli/libs.aarch64/." "$DIST/libs.aarch64/"
    echo "== Laufzeitbibliotheken in dist/libs.aarch64/:"
    ls -la "$DIST/libs.aarch64/"
else
    echo "WARNUNG: $SRC/build/knulli/libs.aarch64 fehlt – Artifact enthält keine Bibliotheken." >&2
fi

# Die Skripte müssen auf dem Gerät ausführbar sein; im ZIP werden die
# Rechte möglicherweise nicht erhalten. Ein Hinweis für den Benutzer.
chmod +x "$DIST/Halo.sh" 2>/dev/null || true

echo "== Inhalt von $DIST:"
ls -laR "$DIST"
