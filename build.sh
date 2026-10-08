#!/usr/bin/env bash
set -euo pipefail

# ══════════════════════════════════════════════════════════════════════
# Halo CE Universal — M9 Pro (RK3326 / Cortex-A35 + Mali-G31 MP2)
#
# Option 2: Upstream + Knulli-Patch + OpenCE-Merge per git apply --3way.
# Nach dem Knulli-Patch wird committet, damit --3way einen sauberen Index
# hat; bei Konflikten werden die betroffenen Dateien als rej/-Artefakt
# bereitgestellt.
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

# ══════════════════════════════════════════════════════════════════════
# 1. OpenCE klonen und OpenCE-Patch gegen den Merge-Base erzeugen
# ══════════════════════════════════════════════════════════════════════
echo ""
echo "== Klone OpenCE (vollstaendig, fuer den Merge-Base) ..."
if [ ! -d "$OPENCE/.git" ]; then
    rm -rf "$OPENCE"
    if ! git clone --quiet "$OPEN_CE_URL" "$OPENCE"; then
        die "Konnte OpenCE nicht klonen."
    fi
fi
git -C "$OPENCE" remote remove upstream 2>/dev/null || true
git -C "$OPENCE" remote add upstream "$UPSTREAM_URL"
echo "== Hole Upstream-Commit $UPSTREAM_COMMIT in OpenCE ..."
git -C "$OPENCE" fetch --quiet upstream "$UPSTREAM_COMMIT" ||
    die "Konnte $UPSTREAM_COMMIT nicht von $UPSTREAM_URL holen."
OPENCE_MERGE_BASE=$(git -C "$OPENCE" merge-base "$UPSTREAM_COMMIT" HEAD 2>/dev/null || true)
if [ -z "$OPENCE_MERGE_BASE" ]; then
    echo "== Kein gemeinsamer Vorfahre; nehme OpenCE-Root als Basis."
    OPENCE_MERGE_BASE=$(git -C "$OPENCE" rev-list --max-parents=0 HEAD | tail -1)
fi
echo "== OpenCE merge-base: $OPENCE_MERGE_BASE"

OPENCE_PATCH=$WORK/opence-all.patch
echo "== Erzeuge OpenCE-Patch gegen merge-base ..."
git -C "$OPENCE" diff --binary "$OPENCE_MERGE_BASE"..HEAD > "$OPENCE_PATCH"
OPENCE_PATCH_SIZE=$(stat -c%s "$OPENCE_PATCH")
OPENCE_PATCH_HASH=$(sha256sum "$OPENCE_PATCH" | cut -d' ' -f1)
echo "== OpenCE-Patch: $OPENCE_PATCH_SIZE Bytes, sha256=$OPENCE_PATCH_HASH"

# ══════════════════════════════════════════════════════════════════════
# 2. XML-Hunk aus dem Knulli-Patch entfernen (idempotent)
# ══════════════════════════════════════════════════════════════════════
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
# 3. SDL3: nur bauen, wenn die .so im sysroot fehlt
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
    echo "== libSDL3.so.0 bereits vorhanden (sysroot)"
fi

# ══════════════════════════════════════════════════════════════════════
# 4. SDL2: Header immer bereitstellen; .so nur bauen, wenn sie fehlt
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
    if [ ! -f "$SYSROOT_LIB/libSDL2-2.0.so.0" ]; then
        cp -L "$SDL2_LIB" "$SYSROOT_LIB/libSDL2-2.0.so.0"
        echo "== SDL2 nach sysroot kopiert: $(stat -c%s "$SYSROOT_LIB/libSDL2-2.0.so.0") Bytes"
    else
        echo "== libSDL2-2.0.so.0 liegt bereits in sysroot; nur Header bereitgestellt."
    fi
else
    echo "== SDL2-Header bereits in $SDL2_INSTALL"
    if [ ! -f "$SYSROOT_LIB/libSDL2-2.0.so.0" ]; then
        if [ -f "$SDL2_INSTALL/lib/libSDL2-2.0.so.0" ]; then
            cp -L "$SDL2_INSTALL/lib/libSDL2-2.0.so.0" "$SYSROOT_LIB/libSDL2-2.0.so.0"
            echo "== SDL2 .so aus $SDL2_INSTALL nach sysroot kopiert."
        else
            die "SDL2 .so fehlt in sysroot und $SDL2_INSTALL."
        fi
    fi
fi
export SDL2_INCLUDE="$SDL2_INSTALL/include"
[ -f "$SDL2_INCLUDE/SDL2/SDL.h" ] || die "SDL2_INCLUDE=$SDL2_INCLUDE enthaelt kein SDL2/SDL.h"
echo "== SDL2_INCLUDE=$SDL2_INCLUDE"

# ══════════════════════════════════════════════════════════════════════
# 5. Upstream klonen, Knulli-Patch anwenden und committen, dann OpenCE mergen
# ══════════════════════════════════════════════════════════════════════
if [ ! -d "$SRC/.git" ]; then
    echo "== Klone Upstream in $SRC ..."
    git init -q "$SRC"
    git -C "$SRC" remote add origin "$UPSTREAM_URL"
fi
if ! git -C "$SRC" cat-file -e "$UPSTREAM_COMMIT^{commit}" 2> /dev/null; then
    echo "== fetching $UPSTREAM_COMMIT"
    git -C "$SRC" fetch -q --depth 1 origin "$UPSTREAM_COMMIT" ||
        git -C "$SRC" fetch -q origin
fi
git -C "$SRC" cat-file -e "$UPSTREAM_COMMIT^{commit}" 2> /dev/null ||
    die "commit $UPSTREAM_COMMIT not in $UPSTREAM_URL"

# git-Identitaet fuer den Commit im CI
git -C "$SRC" config user.email "halo-build@localhost"
git -C "$SRC" config user.name "Halo CE RK3326 Build"

OPENCE_APPLIED_MARKER=$SRC/.opence-merge-hash
CURRENT_MERGE_HASH="${OPENCE_MERGE_BASE}:${OPENCE_PATCH_HASH}"

NEED_RESET=0
if [ ! -f "$OPENCE_APPLIED_MARKER" ] || [ "$(cat "$OPENCE_APPLIED_MARKER" 2>/dev/null)" != "$CURRENT_MERGE_HASH" ]; then
    NEED_RESET=1
fi
# Auch zuruecksetzen, wenn der Baum noch Knulli-Aenderungen hat, die nicht
# committet sind (alte Zustaende aus vorherigen Runs ohne Commit).
if [ "$(git -C "$SRC" status --porcelain 2>/dev/null | wc -l)" -gt 0 ] && [ ! -f "$OPENCE_APPLIED_MARKER" ]; then
    NEED_RESET=1
fi

if [ "$NEED_RESET" = "1" ]; then
    echo ""
    echo "== Setze Upstream auf $UPSTREAM_COMMIT zurueck ..."
    git -C "$SRC" checkout -q --force --detach "$UPSTREAM_COMMIT"
    git -C "$SRC" reset -q --hard
    git -C "$SRC" clean -q -fd -e work -e dist -e rej 2>/dev/null || git -C "$SRC" clean -q -fdx

    echo ""
    echo "== Pruefe und wende Knulli-Patch an ..."
    if ! git -C "$SRC" apply --check "$PATCH" 2>&1; then
        die "Knulli-Patch kann auf $UPSTREAM_COMMIT NICHT sauber angewendet werden."
    fi
    git -C "$SRC" apply "$PATCH"
    git -C "$SRC" add -A
    echo "== Committe Knulli-Patch fuer sauberen Index (noetig fuer --3way) ..."
    git -C "$SRC" commit -q -m "knulli-patch (for --3way base)"
    echo "== Knulli-Patch angewendet und committet."
    rm -f "$OPENCE_APPLIED_MARKER"
fi

if [ ! -f "$OPENCE_APPLIED_MARKER" ] || [ "$(cat "$OPENCE_APPLIED_MARKER" 2>/dev/null)" != "$CURRENT_MERGE_HASH" ]; then
    echo ""
    echo "== Wende OpenCE-Patch per --3way an ..."
    rm -f "$OPENCE_APPLIED_MARKER"

    set +e
    git -C "$SRC" apply --3way "$OPENCE_PATCH" > "$WORK/opence-apply.log" 2>&1
    APPLY_STATUS=$?
    set -e
    # Nur die Fehlerzeilen ausgeben, nicht die tausenden "Applied patch ..."-
    head -50 "$WORK/opence-apply.log"

    # Konflikte finden: unmerged paths (git-Index) UND Datei-Marker
    UNMERGED=$(git -C "$SRC" diff --name-only --diff-filter=U 2>/dev/null | sort || true)
    CONFLICT_FILES=$(grep -rl '^<<<<<<< ' "$SRC" 2>/dev/null | grep -v '/\.git/' | sort || true)

    if [ -n "$UNMERGED" ] || [ -n "$CONFLICT_FILES" ]; then
        echo ""
        echo "════════════════════════════════════════════════════════════"
        echo "  OPENCE-MERGE HAT KONFLIKTE — BUILD STOPPT HIER"
        echo "════════════════════════════════════════════════════════════"
        echo ""
        if [ -n "$UNMERGED" ]; then
            echo "Unmerged paths:"
            echo "$UNMERGED" | sed 's|^|  |'
        fi
        if [ -n "$CONFLICT_FILES" ]; then
            echo "Dateien mit <<<<<<<-Markern:"
            for f in $CONFLICT_FILES; do
                rel=${f#"$SRC/"}
                echo "  $rel"
            done
        fi
        echo ""
        rm -rf "$REJ"
        mkdir -p "$REJ"

        # Alle betroffenen Dateien sammeln (vereinigt)
        ALL_FILES=$(printf '%s\n%s\n' "$UNMERGED" "$(for f in $CONFLICT_FILES; do echo "${f#"$SRC/"}"; done)" | sort -u | grep -v '^$' || true)

        for rel in $ALL_FILES; do
            [ -f "$SRC/$rel" ] || continue
            mkdir -p "$REJ/conflict-$(dirname "$rel")"
            cp "$SRC/$rel" "$REJ/conflict-$rel" 2>/dev/null || true
            if [ -f "$OPENCE/$rel" ]; then
                mkdir -p "$REJ/opence-$(dirname "$rel")"
                cp "$OPENCE/$rel" "$REJ/opence-$rel"
            fi
            mkdir -p "$REJ/knulli-$(dirname "$rel")"
            # Knulli-Version: aus dem Commit (HEAD) extrahieren
            git -C "$SRC" show "HEAD:$rel" > "$REJ/knulli-$rel" 2>/dev/null || true
        done

        echo "$ALL_FILES" > "$REJ/conflict-files.txt"
        cp "$WORK/opence-apply.log" "$REJ/opence-apply.log" 2>/dev/null || true
        exit 2
    fi

    if [ "$APPLY_STATUS" -ne 0 ]; then
        echo "== git apply --3way meldete Status $APPLY_STATUS, aber keine Konfliktdateien."
        cat "$WORK/opence-apply.log"
        die "OpenCE-Patch-Anwendung fehlgeschlagen."
    fi

    # ─── p2p-Header und -Quellen komplett aus OpenCE übernehmen ──────
    echo ""
    echo "== Uebernehme p2p-Header und -Quellen aus OpenCE ..."
    for f in \
        port/linux/src/p2p.h \
        port/linux/src/p2p_internal.h \
        port/linux/src/p2p_crypto.c \
        port/linux/src/p2p_signal.c \
        port/linux/src/p2p_discord.c \
        port/linux/src/p2p_lobby.c \
        ; do
        if [ -f "$OPENCE/$f" ]; then
            mkdir -p "$SRC/$(dirname "$f")"
            cp "$OPENCE/$f" "$SRC/$f"
            echo "   + $f (OpenCE-Version)"
        fi
    done

    # ─── Post-Merge-Sanity: kritische Symbole pruefen ───────────────
    echo ""
    echo "== Post-Merge-Sanity-Check ..."
    SANITY_FAIL=0
    check_symbol() {
        local file="$1" symbol="$2"
        if ! grep -q -- "$symbol" "$SRC/$file" 2>/dev/null; then
            echo "   FEHLT: $symbol in $file"
            SANITY_FAIL=1
        fi
    }
    check_symbol "port/linux/src/p2p_internal.h" "P2P_LOBBY_SLOT_PREFIX"
    check_symbol "port/linux/src/p2p_internal.h" "P2P_SEALED_TOKEN_SIZE"
    check_symbol "port/linux/src/p2p_internal.h" "P2P_SIGNATURE_SIZE"
    check_symbol "port/linux/src/p2p.h"          "p2p_lobby"
    check_symbol "port/linux/src/menu_files.c"   "halo_menus_load"
    check_symbol "port/linux/game/menu_tags.c"   "menu_tags_loaded"
    check_symbol "port/linux/game/menu_functions.c" "pc_menu_event_function_invoke"
    check_symbol "source/interface/ui_widget.c"  "pc_menu_tag"
    check_symbol "source/cache/cache_files.c"    "menu_tags_loaded"
    check_symbol "port/third_party/expat/expat.h" "XML_ParserCreate"
    if [ "$SANITY_FAIL" -ne 0 ]; then
        echo ""
        echo "════════════════════════════════════════════════════════════"
        echo "  POST-MERGE-SANITY-CHECK FEHLGESCHLAGEN"
        echo "════════════════════════════════════════════════════════════"
        rm -rf "$REJ"
        mkdir -p "$REJ"
        for f in port/linux/src/p2p_internal.h port/linux/src/p2p.h \
                 port/linux/src/menu_files.c port/linux/game/menu_tags.c; do
            [ -f "$OPENCE/$f" ] || continue
            mkdir -p "$REJ/opence-$(dirname "$f")"
            cp "$OPENCE/$f" "$REJ/opence-$f"
            mkdir -p "$REJ/knulli-$(dirname "$f")"
            git -C "$SRC" show "HEAD:$f" > "$REJ/knulli-$f" 2>/dev/null || true
        done
        exit 3
    fi
    echo "   OK: alle kritischen Symbole vorhanden."

    echo "$CURRENT_MERGE_HASH" > "$OPENCE_APPLIED_MARKER"
    echo "== OpenCE-Merge erfolgreich."
fi

# ─── OpenCE-Assets und -Tools ins Repo kopieren ──────────────────────
echo ""
echo "== Kopiere OpenCE-Assets und -Tools ..."
for t in tools/ce_menus.py tools/port_settings.py tools/custom_edition_script_names.py; do
    [ -f "$OPENCE/$t" ] && cp "$OPENCE/$t" "$SRC/$t" && echo "   + $t" || true
done
if [ -d "$OPENCE/port/assets/menus" ]; then
    rm -rf "$SRC/port/assets/menus"
    mkdir -p "$SRC/port/assets"
    cp -a "$OPENCE/port/assets/menus" "$SRC/port/assets/menus"
    echo "   + port/assets/menus/"
fi
[ -d "$SRC/port/assets/menus/ce" ] || die "port/assets/menus/ce fehlt nach dem Merge."

# ══════════════════════════════════════════════════════════════════════
# 6. PGO-Konfiguration
# ══════════════════════════════════════════════════════════════════════
PGO_FLAG="--pgo=off"
PGO_EXTRA_ARGS=""
LTO_FLAG="--lto=full"

if [ "$PGO_MODE" = "use" ]; then
    LOCAL_PGO="$HERE/pgo/halo_linux.profdata"
    LOCAL_PGO_ANDROID="$HERE/pgo/halo_android.profdata"
    PGO_LINUX_URL="https://raw.githubusercontent.com/cybersecurity/halo-ce-universal/main/pgo/halo_linux.profdata"
    PGO_FALLBACK_URL="https://raw.githubusercontent.com/Andiweli/HaloCE-Android-AAOS/main/pgo/halo_linux.profdata"

    if [ -f "$LOCAL_PGO" ]; then
        echo "== PGO: use (lokales Linux-Profil)"
        PGO_FLAG="--pgo=use"; PGO_EXTRA_ARGS="--pgo-profile $LOCAL_PGO"
    elif curl -fsSL --retry 2 --connect-timeout 30 -o "$WORK/halo_linux.profdata" "$PGO_LINUX_URL" 2>/dev/null; then
        echo "== PGO: use (Upstream-Linux-Profil)"
        PGO_FLAG="--pgo=use"; PGO_EXTRA_ARGS="--pgo-profile $WORK/halo_linux.profdata"
    elif curl -fsSL --retry 2 --connect-timeout 30 -o "$WORK/halo_linux.profdata" "$PGO_FALLBACK_URL" 2>/dev/null; then
        echo "== PGO: use (Fallback-Linux-Profil)"
        PGO_FLAG="--pgo=use"; PGO_EXTRA_ARGS="--pgo-profile $WORK/halo_linux.profdata"
    elif [ -f "$LOCAL_PGO_ANDROID" ]; then
        echo "== PGO: use (lokales Android-Profil)"
        PGO_FLAG="--pgo=use"; PGO_EXTRA_ARGS="--pgo-profile $LOCAL_PGO_ANDROID"
    else
        echo "== PGO: kein Profil gefunden, baue ohne PGO (--pgo=off)"
        PGO_FLAG="--pgo=off"
    fi
elif [ "$PGO_MODE" = "off" ]; then
    echo "== PGO: aus"
elif [ "$PGO_MODE" = "train" ]; then
    echo "== PGO: Trainings-Build (kein LTO)"
    LTO_FLAG="--lto=off"
fi

# ══════════════════════════════════════════════════════════════════════
# 7. Fix 1: APCs in xbox_kernel.c
# ══════════════════════════════════════════════════════════════════════
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
    print("WARNUNG: WaitForSingleObjectEx-Muster nicht gefunden.")
else:
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
    print("WARNUNG: SleepEx-Muster nicht gefunden.")
else:
    text = text.replace(sleep_old, sleep_new, 1)
with open(path, 'w') as f:
    f.write(text)
print("xbox_kernel.c geprueft")
PYEOF

# ══════════════════════════════════════════════════════════════════════
# 8. Fix 2: android_build.py
# ══════════════════════════════════════════════════════════════════════
python3 - "$SRC/tools/android_build.py" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
old_mcpu = '"-mcpu=cortex-a53"'
new_mcpu = '"-mcpu=cortex-a35",\n    "-mtune=cortex-a35"'
if text.count(old_mcpu) > 0:
    text = text.replace(old_mcpu, new_mcpu)
    print("android_build.py: mcpu=cortex-a53 -> cortex-a35")
else:
    print("android_build.py: mcpu war bereits cortex-a35")
old_flags = '"-ffp-contract=off",\n    "-O2",'
new_flags = '''"-ffp-contract=off",
    "-O3",
    "-fomit-frame-pointer",
    "-funroll-loops",
    "-fno-math-errno",
    "-fno-trapping-math",
    "-fmerge-all-constants",
    "-fno-strict-aliasing",'''
if old_flags in text:
    text = text.replace(old_flags, new_flags, 1)
    print("android_build.py: O2 -> O3 + Flags")
else:
    print("android_build.py: O-Flags unveraendert")
if '"-fno-omit-frame-pointer"' in text:
    text = text.replace('    "-fno-omit-frame-pointer",\n', '')
    print("android_build.py: -fno-omit-frame-pointer entfernt")
with open(path, 'w') as f:
    f.write(text)
PYEOF

python3 - "$SRC/tools/android_build.py" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
if '"-DHALO_ANDROID"' in text:
    print("android_build.py: -DHALO_ANDROID bereits vorhanden")
    sys.exit(0)
anchor = '"-DHALO_RELEASE"'
if anchor in text:
    text = text.replace(anchor, '"-DHALO_ANDROID",\n    "-DHALO_RELEASE"', 1)
    print("android_build.py: -DHALO_ANDROID vor -DHALO_RELEASE")
    with open(path, 'w') as f:
        f.write(text)
PYEOF

python3 - "$SRC/tools/android_build.py" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
if "_clang_builtin_shim" in text:
    print("clang-Builtin-Shim bereits aktiv")
    sys.exit(0)
anchor = '''    for sdk in (Path.home() / "Android/Sdk", Path("/opt/android-sdk")):
        if (sdk / "ndk").is_dir():
            versions = sorted((sdk / "ndk").iterdir())
            if versions:
                return versions[-1]
    return None
'''
new_fn = '''def _clang_builtin_shim(cc: str) -> list:
    import shutil
    try:
        result = subprocess.run([cc, "-print-resource-dir"],
                                capture_output=True, text=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError, OSError):
        return []
    include = Path(result.stdout.strip()) / "include"
    if not include.is_dir():
        return []
    shim = BUILD / "guest" / "clang_builtin_shim"
    shim.mkdir(parents=True, exist_ok=True)
    for name in ("arm_neon.h", "arm_vector_types.h", "arm_acle.h", "arm_fp16.h", "arm_bf16.h"):
        source = include / name
        if not source.is_file():
            continue
        target = shim / name
        if target.exists() or target.is_symlink():
            try: target.unlink()
            except OSError: pass
        try: target.symlink_to(source)
        except OSError: shutil.copy2(source, target)
    return ["-isystem", str(shim)]
'''
if anchor in text:
    text = text.replace(anchor, anchor + "\n\n" + new_fn, 1)
    text = text.replace("_clang_resource_include(guest_cc)", "_clang_builtin_shim(guest_cc)")
    if "guest_abi = " in text and "_clang_builtin_shim(guest_cc)" not in text:
        text = re.sub(r'(guest_abi\s*=\s*"[^"]*"\s*\.join\(\s*\n?\s*GUEST_ABI_FLAGS\b)',
                      r'\1\n        + _clang_builtin_shim(guest_cc)', text, count=1)
    print("clang-Builtin-Shim eingebaut")
with open(path, 'w') as f:
    f.write(text)
PYEOF

if [ "$PGO_MODE" = "train" ]; then
    python3 - "$SRC/tools/android_build.py" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
if "-fprofile-instr-generate" in text:
    print("android_build.py: -fprofile-instr-generate bereits vorhanden")
    sys.exit(0)
for old in ('"-O3",', '"-O3"'):
    if old in text:
        text = text.replace(old, old.replace('"-O3"', '"-O3",\n    "-fprofile-instr-generate"'), 1)
        with open(path, 'w') as f:
            f.write(text)
        print("android_build.py: -fprofile-instr-generate")
        sys.exit(0)
PYEOF
    python3 - "$SRC/tools/android_build.py" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
if "guest_profile_runtime" in text:
    print("android_build.py: guest_profile_runtime bereits vorhanden")
    sys.exit(0)
old = '''    n.rule(
        name="android_guest_link",
        command=(f"$android_ndk_bin/ld.lld -m aarch64linux -static -nostdlib -T {linker_script} "
                 f"-Map $out.map -o $out @$out.rsp {libguestc} "
                 "$$($android_host_cc -print-libgcc-file-name)"),'''
new = '''    guest_profile_runtime = ""
    for _cc_candidate in (guest_cc, str(ndk_bin / "clang")):
        if not _cc_candidate:
            continue
        try:
            _rd = subprocess.run([_cc_candidate, "-print-resource-dir"],
                                 capture_output=True, text=True, check=True).stdout.strip()
        except Exception:
            continue
        for _name in ("libclang_rt.profile-aarch64-android.a", "libclang_rt.profile-aarch64.a"):
            _candidate = Path(_rd) / "lib" / "linux" / _name
            if _candidate.is_file():
                guest_profile_runtime = str(_candidate)
                print(f"== profile runtime: {guest_profile_runtime}")
                break
        if guest_profile_runtime:
            break
    n.rule(
        name="android_guest_link",
        command=(f"$android_ndk_bin/ld.lld -m aarch64linux -static -nostdlib -T {linker_script} "
                 f"-Map $out.map -o $out @$out.rsp {libguestc} {guest_profile_runtime} "
                 "$$($android_host_cc -print-libgcc-file-name)"),'''
if old in text:
    text = text.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(text)
    print("android_build.py: Profiling-Runtime zum Link")
PYEOF
fi

# ══════════════════════════════════════════════════════════════════════
# 9. Fix 3: linux_build.py
# ══════════════════════════════════════════════════════════════════════
python3 - "$SRC/tools/linux_build.py" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
if 'OPTIMISATION = "-O3"' in text:
    print("linux_build.py: -O3 bereits vorhanden")
else:
    text = text.replace('OPTIMISATION = "-O2"', 'OPTIMISATION = "-O3"')
    print("linux_build.py: O2 -> O3")
old_abi = '"-ffp-contract=off",\n    OPTIMISATION,'
new_abi = '''"-ffp-contract=off",
    "-funroll-loops",
    "-fno-math-errno",
    "-fno-trapping-math",
    "-fmerge-all-constants",
    "-fno-strict-aliasing",
    OPTIMISATION,'''
if old_abi in text:
    text = text.replace(old_abi, new_abi, 1)
    print("linux_build.py: zusaetzliche Flags")
with open(path, 'w') as f:
    f.write(text)
PYEOF

# ══════════════════════════════════════════════════════════════════════
# 10. port/knulli kopieren + Fix 3b
# ══════════════════════════════════════════════════════════════════════
echo ""
echo "== Kopiere port/knulli in den Quellbaum ..."
if [ ! -d "$HERE/port/knulli" ]; then
    die "port/knulli/ existiert nicht im Repo"
fi
rm -rf "$SRC/port/knulli"
cp -a "$HERE/port/knulli" "$SRC/port/knulli"
rm -rf "$SRC/port/knulli/__pycache__"
chmod +x "$SRC/port/knulli/build.sh" 2>/dev/null || true

if [ -f "$SRC/port/knulli/build.sh" ]; then
    python3 - "$SRC/port/knulli/build.sh" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
if "-DHALO_ANDROID" in text:
    print("port/knulli/build.sh: -DHALO_ANDROID bereits vorhanden")
    sys.exit(0)
old = '-D_GNU_SOURCE -DEGL_NO_X11 -DMESA_EGL_NO_X11_HEADERS \\'
new = '-D_GNU_SOURCE -DEGL_NO_X11 -DMESA_EGL_NO_X11_HEADERS \\\n        -DHALO_ANDROID \\'
if old in text:
    text = text.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(text)
    print("port/knulli/build.sh: -DHALO_ANDROID in CFLAGS")
PYEOF
fi

# ══════════════════════════════════════════════════════════════════════
# 11. Restliche Python-Patches
# ══════════════════════════════════════════════════════════════════════
echo ""
echo "== Wende restliche Patch-Skripte an ..."
for patch_script in \
        patch_memory_pools.py patch_neon_math.py \
        patch_vita_optimizations.py patch_button_remap.py \
        patch_index_extent_neon.py patch_fps_overlay.py \
        patch_draw_framebuffer_bound.py patch_mali_subdata.py \
        patch_shader_prewarm.py patch_aggressive_culling.py \
        patch_state_batching.py patch_texture_prewarm.py \
        patch_settings_menu.py patch_config_defaults.py \
        patch_credits.py patch_forward_declarations.py; do
    if [ -f "$HERE/patches/$patch_script" ]; then
        echo "== $patch_script"
        if ! python3 "$HERE/patches/$patch_script" "$SRC"; then
            echo "WARNUNG: $patch_script fehlgeschlagen"
        fi
    fi
done

if [ -f "$SRC/port/linux/src/d3d8_gl.c" ]; then
    python3 - "$SRC/port/linux/src/d3d8_gl.c" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
if "fps_overlay_enabled" not in text:
    sys.exit(0)
pattern = re.compile(r'glUniform4f\(\s*fps_overlay_color\s*,\s*([^;]+?)\s*\)\s*;')
new_text = pattern.sub(
    lambda m: '{ const float overlay_color[4] = { ' + m.group(1).strip() + ' }; '
              'glUniform4fv(fps_overlay_color, 1, overlay_color); }',
    text)
if new_text != text:
    with open(path, "w") as f:
        f.write(new_text)
    print("d3d8_gl.c: glUniform4f -> glUniform4fv")
PYEOF
fi

echo ""
echo "== Regeneriere die In-Game-Settings-Menus ..."
python3 - "$SRC" <<'PYEOF'
import os, sys
src = sys.argv[1]
sys.path.insert(0, os.path.join(src, "tools"))
try:
    import port_settings
except ImportError as e:
    print(f"  HINWEIS: port_settings.py nicht importierbar ({e}).")
    sys.exit(0)
if not hasattr(port_settings, "settings_files"):
    print("  WARNUNG: port_settings.settings_files() fehlt.")
    sys.exit(0)
files = port_settings.settings_files()
target_dir = os.path.join(src, "port", "assets", "menus", "ce")
os.makedirs(target_dir, exist_ok=True)
for name, lines in files.items():
    path = os.path.join(target_dir, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("\n".join(lines))
    print(f"  geschrieben: {name}")
PYEOF

if [ -f "$HERE/patches/patch_credits_xml.py" ]; then
    echo ""
    echo "== Credits-Wasserzeichen in Menue-XMLs ..."
    python3 "$HERE/patches/patch_credits_xml.py" "$SRC"
fi

# ══════════════════════════════════════════════════════════════════════
# 12. Verifikation
# ══════════════════════════════════════════════════════════════════════
echo ""
echo "== Verifiziere Patch-Ergebnisse ..."
verification_failed=0
check_patch() {
    local file="$1" pattern="$2" name="$3"
    if grep -q -- "$pattern" "$SRC/$file" 2>/dev/null; then
        echo "   OK: $name"
    else
        echo "   FEHLT: $name ($file)"
        verification_failed=1
    fi
}
check_file() {
    local file="$1" name="$2"
    if [ -f "$SRC/$file" ]; then
        echo "   OK: $name"
    else
        echo "   FEHLT: $name ($file)"
        verification_failed=1
    fi
}
check_patch "source/cseries/cseries.h"          "HALO_DEBUG_ALLOCATOR"          "cseries.h Debug-Allocator"
check_patch "source/effects/decals.c"           "static __thread long surface_queue" "decals.c __thread"
check_patch "source/math/matrix_math.c"         "vmulq_n_f32"                   "matrix_math.c NEON"
check_patch "source/sound/game_sound.c"         "obstruction_interval_value"    "game_sound.c Sound"
check_patch "source/render/render_objects.c"    "HALO_MIN_OBJECT_PIXELS"        "render_objects.c Distant"
check_patch "source/render/render_objects.c"    "HALO_LIGHTING_REFRESH_DIVISOR" "render_objects.c Lighting"
check_patch "source/render/render_objects.c"    "aggressive_culling_guard"      "render_objects.c Culling"
check_patch "port/linux/src/port_config.c"      "HALO_SOUND_OBSTRUCTION_TICKS"  "port_config.c Sound"
check_patch "port/linux/src/port_config.c"      "HALO_MIN_OBJECT_PIXELS"        "port_config.c Distant"
check_patch "port/linux/src/port_config.c"      "HALO_LIGHTING_REFRESH_DIVISOR" "port_config.c Lighting"
check_patch "port/linux/src/port_config.c"      "HALO_FPS_OVERLAY_CORNER"       "port_config.c FPS"
check_patch "port/linux/src/port_config.c"      "HALO_FAST_SHADERS"             "port_config.c Knulli"
check_patch "port/linux/src/xinput_sdl.c"       "button_remap"                  "xinput_sdl.c Remap"
check_patch "port/linux/src/d3d8_gl.c"          "__builtin_elementwise_min"     "d3d8_gl.c index_extent"
check_patch "port/linux/src/d3d8_gl.c"          "fps_overlay_enabled"           "d3d8_gl.c FPS-Overlay"
check_patch "port/linux/src/d3d8_gl.c"          "mali_subdata_guard"            "d3d8_gl.c Mali-Subdata"
check_patch "port/linux/src/d3d8_gl.c"          "shader_prewarm_guard"          "d3d8_gl.c Shader-Prewarm"
check_patch "port/linux/src/d3d8_gl.c"          "state_batching_guard"          "d3d8_gl.c State-Batching"
check_patch "port/linux/src/d3d8_gl.c"          "shader_prewarm_fwd_decl"       "d3d8_gl.c Fwd-Decl"
check_patch "port/linux/src/xbox_textures.c"    "texture_prewarm_guard"         "xbox_textures.c Prewarm"
check_patch "tools/android_build.py"            '"-DHALO_ANDROID"'              "android_build.py HALO_ANDROID"
check_patch "source/main/main.c"                "St0len-One"                    "main.c Credits"
check_file  "port/linux/include/halo_menus.h"                                   "halo_menus.h"
check_file  "port/linux/src/menu_files.c"                                       "menu_files.c"
check_file  "port/linux/game/menu_tags.c"                                       "menu_tags.c"
check_file  "port/linux/game/menu_functions.c"                                  "menu_functions.c"
check_file  "port/linux/game/custom_edition_cache.c"                            "custom_edition_cache.c"
check_file  "port/linux/game/custom_edition_maps.c"                             "custom_edition_maps.c"
check_file  "port/linux/game/network_coop.c"                                    "network_coop.c"
check_file  "port/third_party/expat/expat.h"                                    "expat.h"
check_file  "port/linux/src/p2p_lobby.c"                                        "p2p_lobby.c"
check_patch "port/linux/src/p2p_internal.h"     "P2P_LOBBY_SLOT_PREFIX"         "p2p_internal.h Lobby"
check_patch "port/linux/src/p2p_internal.h"     "P2P_SEALED_TOKEN_SIZE"         "p2p_internal.h SealedToken"
check_patch "source/cache/cache_files.c"        "menu_tags_loaded"              "cache_files.c Menue-Hooks"
check_patch "source/interface/ui_widget.c"      "pc_menu_tag"                   "ui_widget.c pc_menu_tag"

if [ -f "$SRC/tools/port_settings.py" ]; then
    check_patch "tools/port_settings.py" "display.fast_shaders"  "port_settings.py Video-Rows"
fi
if [ -f "$SRC/port/assets/menus/ce/main_menu.settings_select.player_setup.player_profile_edit.video_settings.xml" ]; then
    check_patch "port/assets/menus/ce/main_menu.settings_select.player_setup.player_profile_edit.video_settings.xml" \
        "op_fast_shaders" "video_settings.xml op_fast_shaders"
fi
if [ "$verification_failed" -ne 0 ]; then
    echo ""
    echo "FEHLER: Verifikation fehlgeschlagen."
    exit 1
fi
echo "== Alle Optimierungen sauber."

# ══════════════════════════════════════════════════════════════════════
# 13. Fix 5: PGO-Shim (nur train)
# ══════════════════════════════════════════════════════════════════════
if [ "$PGO_MODE" = "train" ]; then
    SHIM="$SRC/port/android/guest/runtime/guest_pgo_shim.c"
    cat > "$SHIM" <<'CEOF'
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
static int pgo_errno_value;
int *__errno(void) { return &pgo_errno_value; }
char __sF[3 * 256];
int prctl(int o, unsigned long a, unsigned long b, unsigned long c, unsigned long d)
{ (void)o;(void)a;(void)b;(void)c;(void)d; return 0; }
int getpagesize(void) { return 4096; }
extern int __llvm_profile_write_file(void);
static void pgo_write_and_die(int sig)
{ __llvm_profile_write_file(); signal(sig, SIG_DFL); raise(sig); }
__attribute__((constructor)) static void pgo_install_handlers(void)
{
    struct sigaction sa;
    sa.sa_handler = pgo_write_and_die;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT,  &sa, NULL);
    sigaction(SIGHUP,  &sa, NULL);
    atexit((void (*)(void))__llvm_profile_write_file);
}
CEOF
    echo "== Fix 5: guest_pgo_shim.c erzeugt"
fi

# ══════════════════════════════════════════════════════════════════════
# 14. Stamp
# ══════════════════════════════════════════════════════════════════════
stamp=$({
    cat "$PATCH"
    echo "opence-merge=$OPENCE_MERGE_BASE"
    echo "opence-patch=$OPENCE_PATCH_HASH"
    for p in patch_memory_pools.py patch_neon_math.py \
             patch_vita_optimizations.py patch_button_remap.py \
             patch_index_extent_neon.py patch_fps_overlay.py \
             patch_draw_framebuffer_bound.py patch_mali_subdata.py \
             patch_shader_prewarm.py patch_aggressive_culling.py \
             patch_state_batching.py patch_texture_prewarm.py \
             patch_settings_menu.py patch_config_defaults.py \
             patch_credits.py patch_credits_xml.py \
             patch_forward_declarations.py; do
        cat "$HERE/patches/$p" 2>/dev/null || true
    done
    [ -f "$HERE/pgo/halo_linux.profdata" ] && sha256sum "$HERE/pgo/halo_linux.profdata" | cut -d' ' -f1
    [ -f "$HERE/pgo/halo_android.profdata" ] && sha256sum "$HERE/pgo/halo_android.profdata" | cut -d' ' -f1
    echo "pgo-mode=$PGO_MODE"
    echo "opence-menu=option2-v4"
    (cd "$HERE/port/knulli" && find . -type f ! -path '*/__pycache__/*' -print0 | sort -z | xargs -0 cat)
} | sha256sum | cut -d' ' -f1)
echo "$stamp" > "$SRC/.port-stamp"

# ══════════════════════════════════════════════════════════════════════
# 15. Build
# ══════════════════════════════════════════════════════════════════════
export ANDROID_NDK SYSROOT_LIB SDL2_INCLUDE GUEST_CC HOST_CC JOBS
cd "$SRC"

echo "== Konfiguriere mit $LTO_FLAG $PGO_FLAG $PGO_EXTRA_ARGS ..."
python3 configure.py --release "$LTO_FLAG" "$PGO_FLAG" $PGO_EXTRA_ARGS \
    --android-ndk "$ANDROID_NDK" --android-guest-cc "$GUEST_CC"

echo "== Baue Guest-ELF (halo_guest.elf) ..."
ninja -j "$JOBS" build/android/halo_guest.elf

echo "== Baue Host-Binary (halo) ueber port/knulli/build.sh ..."
bash "$SRC/port/knulli/build.sh"

# ══════════════════════════════════════════════════════════════════════
# 16. Distribution
# ══════════════════════════════════════════════════════════════════════
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
    cat <<'TRAINING'

────────────────────────────────────────────────────────────────────────
TRAININGS-BUILD FERTIG
────────────────────────────────────────────────────────────────────────
TRAINING
else
    cat <<'RELEASE'

────────────────────────────────────────────────────────────────────────
RELEASE-BUILD FERTIG (PGO use, LTO full, Frame-Pointer Option A)
────────────────────────────────────────────────────────────────────────
Aktiv: HALO_ANDROID, PC-Menus aus OpenCE (Option 2), RK3326-Defaults.
FERTIG.
────────────────────────────────────────────────────────────────────────
RELEASE
fi
