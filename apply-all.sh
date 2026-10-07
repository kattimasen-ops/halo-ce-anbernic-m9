#!/usr/bin/env bash
#
# Wendet den kompletten M9 Pro (RK3326) Patch-Satz auf einen
# Halo CE Universal Source-Baum an.
#
#   ./apply_all.sh <source-root>
#
# Reihenfolge:
#   1. git apply patches/halo-ce-universal-knulli.patch    (Upstream + Knulli)
#   2. Kopiere port/knulli in den Quellbaum
#   3. Python-Patches (ohne patch_glthread_health_check.py, das ist obsolet)
#   4. Fix 4a: glUniform4f -> glUniform4fv
#   5. Verifikation
#
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=${1:?usage: apply_all.sh <source-root>}

[ -d "$SRC" ] || { echo "FEHLER: $SRC ist kein Verzeichnis" >&2; exit 1; }
SRC=$(cd "$SRC" && pwd)

PATCHES=$HERE/patches
MAIN_PATCH=$PATCHES/halo-ce-universal-knulli.patch

# ── 1) Der große Git-Patch ────────────────────────────────────────────
if [ ! -f "$MAIN_PATCH" ]; then
    echo "FEHLER: $MAIN_PATCH fehlt" >&2
    exit 1
fi

if git -C "$SRC" rev-parse --git-dir > /dev/null 2>&1; then
    if git -C "$SRC" apply --check --reverse "$MAIN_PATCH" > /dev/null 2>&1; then
        echo "== $MAIN_PATCH ist bereits angewendet – überspringe"
    else
        echo "== git apply $(basename "$MAIN_PATCH")"
        git -C "$SRC" apply --whitespace=nowarn "$MAIN_PATCH"
    fi
else
    echo "== git apply --directory (kein .git gefunden)"
    git apply --whitespace=nowarn --directory="$SRC" "$MAIN_PATCH"
fi

# ── 2) port/knulli kopieren ──────────────────────────────────────────
if [ -d "$HERE/port/knulli" ]; then
    echo "== Kopiere port/knulli in den Quellbaum ..."
    rm -rf "$SRC/port/knulli"
    cp -a "$HERE/port/knulli" "$SRC/port/knulli"
    rm -rf "$SRC/port/knulli/__pycache__"
    chmod +x "$SRC/port/knulli/build.sh" 2>/dev/null || true
else
    echo "== port/knulli im Repo nicht vorhanden – überspringe"
fi

# ── 3) Python-Patches ────────────────────────────────────────────────
# patch_glthread_health_check.py ist NICHT dabei:
#   die neue host_glthread.c hat health_check() bereits eingebaut.
for script in \
    patch_memory_pools.py \
    patch_neon_math.py \
    patch_vita_optimizations.py \
    patch_button_remap.py \
    patch_index_extent_neon.py \
    patch_fps_overlay.py \
    patch_draw_framebuffer_bound.py; do
    if [ ! -f "$PATCHES/$script" ]; then
        echo "== $script nicht vorhanden – überspringe"
        continue
    fi
    echo "== python3 $script"
    if ! python3 "$PATCHES/$script" "$SRC"; then
        echo "WARNUNG: $script hat nichts geändert (evtl. schon gepatcht)" >&2
    fi
done

# ── 4) Fix 4a: glUniform4f -> glUniform4fv ───────────────────────────
if [ -f "$SRC/port/linux/src/d3d8_gl.c" ]; then
    python3 - "$SRC/port/linux/src/d3d8_gl.c" <<'PYEOF'
import re
import sys

path = sys.argv[1]
with open(path) as f:
    text = f.read()

if "fps_overlay_enabled" not in text:
    sys.exit(0)

pattern = re.compile(
    r'glUniform4f\(\s*fps_overlay_color\s*,\s*([^;]+?)\s*\)\s*;'
)

def repl(match):
    args = match.group(1).strip()
    return (
        '{ const float overlay_color[4] = { ' + args + ' }; '
        'glUniform4fv(fps_overlay_color, 1, overlay_color); }'
    )

new_text = pattern.sub(repl, text)
if new_text != text:
    with open(path, "w") as f:
        f.write(new_text)
    print("d3d8_gl.c: glUniform4f -> glUniform4fv")
else:
    print("d3d8_gl.c: keine glUniform4f-Aufrufe zu korrigieren")
PYEOF
fi

# ── 5) Verifikation ──────────────────────────────────────────────────
echo ""
echo "== Verifiziere Patch-Ergebnisse ..."
failed=0
check() {
    local file="$1" pattern="$2" name="$3"
    if [ -f "$SRC/$file" ] && grep -q -- "$pattern" "$SRC/$file"; then
        echo "   OK: $name"
    else
        echo "   FEHLT: $name ($file)"
        failed=1
    fi
}
check "source/cseries/cseries.h"                  "HALO_DEBUG_ALLOCATOR"                    "cseries.h Debug-Allocator"
check "source/effects/decals.c"                   "static __thread long surface_queue"      "decals.c __thread-Arrays"
check "source/math/matrix_math.c"                 "vmulq_n_f32"                             "matrix_math.c NEON"
check "port/android/guest/runtime/guest_string.c" "vld1q_u8"                                "guest_string.c NEON"
check "source/sound/game_sound.c"                 "obstruction_interval_value"              "game_sound.c Sound-Occlusion"
check "source/render/render_objects.c"            "HALO_MIN_OBJECT_PIXELS"                  "render_objects.c Distant-Object"
check "source/render/render_objects.c"            "HALO_LIGHTING_REFRESH_DIVISOR"           "render_objects.c Lighting"
check "port/linux/src/port_config.c"              "HALO_SOUND_OBSTRUCTION_TICKS"            "port_config.c Sound"
check "port/linux/src/port_config.c"              "HALO_MIN_OBJECT_PIXELS"                  "port_config.c Distant"
check "port/linux/src/port_config.c"              "HALO_LIGHTING_REFRESH_DIVISOR"           "port_config.c Lighting"
check "port/linux/src/port_config.c"              "HALO_FPS_OVERLAY_CORNER"                 "port_config.c FPS"
check "port/linux/src/xinput_sdl.c"               "button_remap"                            "xinput_sdl.c Button-Remap"
check "port/linux/src/d3d8_gl.c"                  "__builtin_elementwise_min"               "d3d8_gl.c index_extent NEON"
check "port/linux/src/d3d8_gl.c"                  "fps_overlay_enabled"                     "d3d8_gl.c FPS-Overlay"
check "port/linux/src/d3d8_gl.c"                  "static int draw_framebuffer_bound(void)" "d3d8_gl.c draw_framebuffer_bound"
check "port/linux/src/d3d8_gl.c"                  "if (draw_framebuffer_bound())"           "d3d8_gl.c Discard-Bedingung"

# host_glthread.c: health_check ist bereits in der Soll-Version
if [ -f "$SRC/port/knulli/host/host_glthread.c" ]; then
    check "port/knulli/host/host_glthread.c" "static void health_check(uint32_t frame)" "host_glthread.c health_check"
    check "port/knulli/host/host_glthread.c" "health_check(call->frame)"               "host_glthread.c health_check-Aufruf"
    check "port/knulli/host/host_glthread.c" "rockchip,rk3326"                          "host_glthread.c RK3326 (falls gepatcht)"
fi

if [ "$failed" -ne 0 ]; then
    echo ""
    echo "FEHLER: Einige Optimierungen fehlen."
    exit 1
fi
echo "== Alle Optimierungen sauber angewendet."
