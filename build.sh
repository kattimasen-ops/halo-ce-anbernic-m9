#!/usr/bin/env bash
set -euo pipefail

# ══════════════════════════════════════════════════════════════════════
# Halo CE Universal — M9 Pro (RK3326 / Cortex-A35 + Mali-G31 MP2)
#
# Settings-Only: Knulli-Patch wie bisher, dazu das PC-Settings-Menü aus
# OpenCE (menu_files.c, menu_tags.c, halo_menus.h, Expat, ce_menus.py,
# port_settings.py, XML-Assets) plus eine reduzierte menu_functions.c, die
# nur die Settings-Callbacks bereitstellt.
# ══════════════════════════════════════════════════════════════════════
PGO_MODE=${PGO_MODE:-use}

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
OPEN_CE_URL=${OPEN_CE_URL:-https://github.com/OpenCommunityEdition/OpenCE.git}

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
    use|off|train) ;;
    *) die "PGO_MODE='$PGO_MODE' ungueltig; erlaubt: use, off, train" ;;
esac

echo "== Upstream: $UPSTREAM_URL @ $UPSTREAM_COMMIT"
echo "== PGO-Modus: $PGO_MODE"

WORK=${WORK:-$HERE/work}
DIST=${DIST:-$HERE/dist}
REJ=${REJ:-$HERE/rej}
mkdir -p "$WORK" "$DIST" "$REJ"
WORK=$(cd "$WORK" && pwd)
DIST=$(cd "$DIST" && pwd)
REJ=$(cd "$REJ" && pwd)
SRC=$WORK/halo-ce-universal
OPENCE=$WORK/opence

# ── OpenCE-Dateien holen (nur die, die wir brauchen) ─────────────────
fetch_opence_files() {
    local opence_dir="$WORK/opence-source"
    local opence_tarball="$WORK/opence-main.tar.gz"

    echo ""
    echo "== Hole OpenCE-Dateien (Menue-System + Assets) ..."
    rm -rf "$opence_dir"

    if git clone --depth 1 "$OPEN_CE_URL" "$opence_dir" > /dev/null 2>&1; then
        echo "   + Git-Clone erfolgreich."
    else
        echo "   Git-Clone fehlgeschlagen, versuche Tarball ..."
        rm -f "$opence_tarball"
        if ! curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 \
            -o "$opence_tarball" \
            "https://github.com/OpenCommunityEdition/OpenCE/archive/refs/heads/main.tar.gz"; then
            die "Konnte OpenCE nicht klonen und auch nicht als Tarball laden."
        fi
        mkdir -p "$opence_dir"
        if ! tar -xzf "$opence_tarball" -C "$opence_dir" --strip-components=1; then
            die "Konnte OpenCE-Tarball nicht entpacken."
        fi
        echo "   + Tarball erfolgreich."
    fi

    # 1. C-Quellen des Menue-Systems (in Upstream NICHT vorhanden)
    mkdir -p "$SRC/port/linux/include" "$SRC/port/linux/src" \
             "$SRC/port/linux/game" "$SRC/port/third_party"
    for f in \
        port/linux/include/halo_menus.h \
        port/linux/include/halo_keyboard.h \
        port/linux/src/menu_files.c \
        port/linux/src/menu_files.h \
        port/linux/game/menu_tags.c \
        ; do
        if [ -f "$opence_dir/$f" ]; then
            cp "$opence_dir/$f" "$SRC/$f"
            echo "   + $f"
        else
            die "OpenCE hat $f nicht."
        fi
    done

    # 2. Expat (XML-Parser)
    if [ -d "$opence_dir/port/third_party/expat" ]; then
        rm -rf "$SRC/port/third_party/expat"
        cp -a "$opence_dir/port/third_party/expat" "$SRC/port/third_party/"
        echo "   + port/third_party/expat/"
    else
        die "OpenCE hat keinen port/third_party/expat-Ordner."
    fi

    # 3. Tools (Menue-Generatoren)
    for t in tools/ce_menus.py tools/port_settings.py; do
        if [ -f "$opence_dir/$t" ]; then
            cp "$opence_dir/$t" "$SRC/$t"
            echo "   + $t"
        fi
    done

    # 4. embed_assets.py: wir nehmen die OpenCE-Version (sie bettet die
    # Menue-Dateien aus menus.json mit ein; die alten HUD/Titel/Fonts
    # funktionieren unveraendert weiter)
    if [ -f "$opence_dir/tools/embed_assets.py" ]; then
        cp "$opence_dir/tools/embed_assets.py" "$SRC/tools/embed_assets.py"
        echo "   + tools/embed_assets.py (OpenCE-Version)"
    fi

    # 5. Menue-Assets: XML, SVGs, port_svg
    if [ -d "$opence_dir/port/assets/menus" ]; then
        rm -rf "$SRC/port/assets/menus"
        mkdir -p "$SRC/port/assets"
        cp -a "$opence_dir/port/assets/menus" "$SRC/port/assets/menus"
        local count
        count=$(find "$SRC/port/assets/menus/ce" -name "*.xml" 2>/dev/null | wc -l)
        echo "   + port/assets/menus/ ($count XML-Dateien)"
    else
        die "OpenCE hat keinen port/assets/menus-Ordner."
    fi

    rm -rf "$opence_dir" "$opence_tarball"
    echo "== OpenCE-Dateien geholt."
}

# ── XML-Hunk aus dem Knulli-Patch entfernen (idempotent) ────────────
echo ""
echo "== Entferne den video_settings.xml-Hunk aus dem Knulli-Patch ..."
python3 - "$PATCH" <<'PYEOF'
import re, sys
path = sys.argv[1]
text = open(path).read()
pattern = re.compile(
    r'diff --git a/port/assets/menus/ce/'
    r'main_menu\.settings_select\.player_setup\.player_profile_edit\.'
    r'video_settings\.xml[^\n]*\n'
    r'(?:(?!diff --git ).)*',
    re.DOTALL,
)
if not pattern.search(text):
    print("  XML-Hunk war nicht vorhanden (bereits entfernt).")
    sys.exit(0)
new_text = pattern.sub('', text)
open(path, 'w').write(new_text)
print("  XML-Hunk entfernt; Patch ist jetzt %d Bytes kleiner." % (len(text) - len(new_text)))
PYEOF

# ══════════════════════════════════════════════════════════════════════
# 3. SDL3 (nur bauen, wenn .so fehlt)
# ══════════════════════════════════════════════════════════════════════
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

# ══════════════════════════════════════════════════════════════════════
# 4. SDL2 (Header immer; .so nur kopieren, wenn fehlt)
# ══════════════════════════════════════════════════════════════════════
SDL2_SRC=$WORK/SDL2-src
SDL2_BUILD=$WORK/sdl2-build
SDL2_INSTALL=$WORK/sdl2-install

if [ ! -d "$SDL2_INSTALL/include/SDL2" ]; then
    echo "== SDL2 $SDL2_TAG: Quellcode holen und Header bereitstellen"
    rm -rf "$SDL2_SRC" "$SDL2_BUILD" "$SDL2_INSTALL"
    mkdir -p "$SDL2_SRC" "$SDL2_BUILD" "$SDL2_INSTALL"
    curl -L -o "$WORK/sdl2.tar.gz" "$SDL2_ARCHIVE"
    tar -xzf "$WORK/sdl2.tar.gz" -C "$SDL2_SRC" --strip-components=1

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
        sys.exit(1)
    text = text[:match.start()] + new + text[match.end():]
else:
    text = text.replace(old, new, 1)
with open(path, 'w') as f:
    f.write(text)
print("SDL2 KMSDRM Pageflip-Patch angewendet")
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
    if [ ! -f "$SYSROOT_LIB/libSDL2-2.0.so.0" ]; then
        cp -L "$SDL2_LIB" "$SYSROOT_LIB/libSDL2-2.0.so.0"
        echo "== SDL2 nach sysroot kopiert: $(stat -c%s "$SYSROOT_LIB/libSDL2-2.0.so.0") Bytes"
    else
        echo "== libSDL2-2.0.so.0 liegt bereits in sysroot."
    fi
else
    echo "== SDL2-Header bereits in $SDL2_INSTALL"
    if [ ! -f "$SYSROOT_LIB/libSDL2-2.0.so.0" ]; then
        if [ -f "$SDL2_INSTALL/lib/libSDL2-2.0.so.0" ]; then
            cp -L "$SDL2_INSTALL/lib/libSDL2-2.0.so.0" "$SYSROOT_LIB/libSDL2-2.0.so.0"
        else
            die "SDL2 .so fehlt in sysroot und $SDL2_INSTALL."
        fi
    fi
fi
export SDL2_INCLUDE="$SDL2_INSTALL/include"
[ -f "$SDL2_INCLUDE/SDL2/SDL.h" ] || die "SDL2_INCLUDE=$SDL2_INCLUDE enthaelt kein SDL2/SDL.h"
echo "== SDL2_INCLUDE=$SDL2_INCLUDE"

# ══════════════════════════════════════════════════════════════════════
# 5. Upstream klonen + Knulli-Patch + OpenCE-Dateien
# ══════════════════════════════════════════════════════════════════════
if [ ! -d "$SRC/.git" ]; then
    echo "== Klone Upstream in $SRC ..."
    git init -q "$SRC"
    git -C "$SRC" remote add origin
