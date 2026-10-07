#!/usr/bin/env bash
#
# Wendet den kompletten M9 Pro (RK3326) Patch-Satz auf einen
# Halo CE Universal Source-Baum an.
#
#   ./apply_all.sh <source-root>
#
# Reihenfolge:
#   1. XML-Hunk aus dem Knulli-Patch entfernen (der Regenerator unten
#      baut die Menue-XMLs neu; der Hunk im Patch wuerde sonst kollidieren)
#   2. git apply patches/halo-ce-universal-knulli.patch
#   3. port/knulli in den Quellbaum kopieren
#   4. Fix 3b: -DHALO_ANDROID in port/knulli/build.sh
#   5. Alle Python-Patches in fester Reihenfolge
#   6. Fix 4a: glUniform4f -> glUniform4fv
#   7. In-Game-Settings-Menus aus port_settings.py regenerieren
#   8. Credits-Wasserzeichen in statische Menue-XMLs
#   9. Verifikation
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

# XML-Hunk aus dem Knulli-Patch entfernen. Der Regenerator (Schritt 7)
# erzeugt die video_settings.xml neu; der Hunk im Patch wuerde sonst mit
# "patch does not apply" abbrechen.
echo "== Entferne den video_settings.xml-Hunk aus dem Knulli-Patch (einmalig) ..."
python3 - "$MAIN_PATCH" <<'PYEOF'
import re
import sys

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

# ── 3) Fix 3b: -DHALO_ANDROID in port/knulli/build.sh ────────────────
if [ -f "$SRC/port/knulli/build.sh" ]; then
    if grep -q -- "-DHALO_ANDROID" "$SRC/port/knulli/build.sh"; then
        echo "port/knulli/build.sh: -DHALO_ANDROID bereits vorhanden"
    else
        python3 - "$SRC/port/knulli/build.sh" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
if "-DHALO_ANDROID" in text:
    sys.exit(0)
old = '-D_GNU_SOURCE -DEGL_NO_X11 -DMESA_EGL_NO_X11_HEADERS \\'
new = '-D_GNU_SOURCE -DEGL_NO_X11 -DMESA_EGL_NO_X11_HEADERS \\\n        -DHALO_ANDROID \\'
if old not in text:
    sys.exit(0)
text = text.replace(old, new, 1)
with open(path, 'w') as f:
    f.write(text)
print("port/knulli/build.sh: -DHALO_ANDROID in CFLAGS eingefuegt")
PYEOF
    fi
fi

# ── 4) Python-Patches (feste Reihenfolge) ────────────────────────────
# Reihenfolge ist wichtig:
#   - memory/neon/vita/button zuerst (Basisschicht)
#   - index_extent_neon + fps_overlay + draw_framebuffer_bound
#     (d3d8_gl.c / port_config.c)
#   - settings_menu (port_settings.py erweitern)
#   - config_defaults (port_config.c Defaults festnageln)
#   - credits (main.c + port_settings.py Wasserzeichen)
# patch_credits_xml.py laeuft NICHT hier, sondern nach der Regeneration
# (Schritt 8).
for script in \
    patch_memory_pools.py \
    patch_neon_math.py \
    patch_vita_optimizations.py \
    patch_button_remap.py \
    patch_index_extent_neon.py \
    patch_fps_overlay.py \
    patch_draw_framebuffer_bound.py \
    patch_settings_menu.py \
    patch_config_defaults.py \
    patch_credits.py; do
    if [ ! -f "$PATCHES/$script" ]; then
        echo "== $script nicht vorhanden – überspringe"
        continue
    fi
    echo "== python3 $script"
    if ! python3 "$PATCHES/$script" "$SRC"; then
        echo "WARNUNG: $script hat nichts geändert (evtl. schon gepatcht)" >&2
    fi
done

# ── 5) Fix 4a: glUniform4f -> glUniform4fv ───────────────────────────
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
    print("d3d8_gl.c: glUniform4f -> glUniform4fv (Sicherheitskorrektur)")
else:
    print("d3d8_gl.c: keine glUniform4f-Aufrufe zu korrigieren")
PYEOF
fi

# ── 6) In-Game-Settings-Menus aus port_settings.py regenerieren ─────
# Läuft NACH allen Patches, damit die neuen Rows schon in port_settings.py
# stehen (patch_settings_menu.py) und das Wasserzeichen-Widget definiert ist
# (patch_credits.py).
echo ""
echo "== Regeneriere die In-Game-Settings-Menus aus port_settings.py ..."
python3 - "$SRC" <<'PYEOF'
import os
import sys

src = sys.argv[1]
sys.path.insert(0, os.path.join(src, "tools"))

try:
    import port_settings
except ImportError as e:
    print(f"  WARNUNG: port_settings.py nicht importierbar: {e}")
    sys.exit(0)

if not hasattr(port_settings, "settings_files"):
    print("  WARNUNG: port_settings.settings_files() fehlt; Regeneration uebersprungen.")
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

# ── 7) Credits-Wasserzeichen in statische Menue-XMLs ─────────────────
echo ""
echo "== Injiziere das Credits-Wasserzeichen in die statischen Menue-XMLs ..."
if [ -f "$PATCHES/patch_credits_xml.py" ]; then
    python3 "$PATCHES/patch_credits_xml.py" "$SRC"
else
    echo "  WARNUNG: patch_credits_xml.py nicht vorhanden - ueberspringe."
fi

# ── 8) Verifikation ──────────────────────────────────────────────────
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

# Kern-Patches
check "source/cseries/cseries.h"                  "HALO_DEBUG_ALLOCATOR"                        "cseries.h Debug-Allocator"
check "source/effects/decals.c"                   "static __thread long surface_queue"          "decals.c __thread-Arrays"
check "source/math/matrix_math.c"                 "vmulq_n_f32"                                 "matrix_math.c NEON"
check "port/android/guest/runtime/guest_string.c" "vld1q_u8"                                    "guest_string.c NEON memcmp"
check "port/android/guest/runtime/guest_string.c" "vst1q_u8"                                    "guest_string.c NEON memcpy"
check "source/sound/game_sound.c"                 "obstruction_interval_value"                  "game_sound.c Sound-Occlusion"
check "source/render/render_objects.c"            "HALO_MIN_OBJECT_PIXELS"                      "render_objects.c Distant-Object"
check "source/render/render_objects.c"            "HALO_LIGHTING_REFRESH_DIVISOR"               "render_objects.c Lighting"

# port_config.c-Eintraege
check "port/linux/src/port_config.c"              "HALO_SOUND_OBSTRUCTION_TICKS"                "port_config.c audio.obstruction_ticks"
check "port/linux/src/port_config.c"              "HALO_MIN_OBJECT_PIXELS"                      "port_config.c display.distant_objects"
check "port/linux/src/port_config.c"              "HALO_LIGHTING_REFRESH_DIVISOR"               "port_config.c debug.lighting_refresh_divisor"
check "port/linux/src/port_config.c"              "HALO_FPS_OVERLAY_CORNER"                     "port_config.c FPS-Eintraege"
check "port/linux/src/port_config.c"              "HALO_FAST_SHADERS"                           "port_config.c Knulli-Eintraege"
check "port/linux/src/port_config.c"              'display.model_detail", _config_real, "0.35"' "port_config.c default model_detail=0.35"
check "port/linux/src/port_config.c"              'lighting_refresh_divisor", _config_integer, "2"' "port_config.c default lighting_refresh_divisor=2"

# Input und Renderer
check "port/linux/src/xinput_sdl.c"               "button_remap"                                "xinput_sdl.c Button-Remap"
check "port/linux/src/d3d8_gl.c"                  "__builtin_elementwise_min"                   "d3d8_gl.c index_extent NEON"
check "port/linux/src/d3d8_gl.c"                  "fps_overlay_enabled"                         "d3d8_gl.c FPS-Overlay"
check "port/linux/src/d3d8_gl.c"                  "static int draw_framebuffer_bound(void)"     "d3d8_gl.c draw_framebuffer_bound"
check "port/linux/src/d3d8_gl.c"                  "if (draw_framebuffer_bound())"               "d3d8_gl.c Discard-Bedingung"

# Build-Skripte
check "tools/android_build.py"                    '"-DHALO_ANDROID"'                            "android_build.py -DHALO_ANDROID"

# port_settings.py
check "tools/port_settings.py"                    "display.fast_shaders"                        "port_settings.py Video-Rows"
check "tools/port_settings.py"                    "button_top"                                  "port_settings.py button_top"
check "tools/port_settings.py"                    "credits_watermark"                           "port_settings.py Credits-Wasserzeichen"

# main.c Credits
check "source/main/main.c"                        "St0len-One"                                  "main.c Credits-String"

# Regenerierte XMLs
check "port/assets/menus/ce/main_menu.settings_select.player_setup.player_profile_edit.video_settings.xml" \
    "op_fast_shaders" "video_settings.xml op_fast_shaders"
check "port/assets/menus/ce/main_menu.settings_select.player_setup.player_profile_edit.video_settings.xml" \
    "op_alpha_test_elision" "video_settings.xml op_alpha_test_elision"
check "port/assets/menus/ce/main_menu.settings_select.player_setup.player_profile_edit.video_settings.xml" \
    "credits_watermark" "video_settings.xml Wasserzeichen"

# host_glthread.c: health_check ist optional
if [ -f "$SRC/port/knulli/host/host_glthread.c" ]; then
    if grep -q "health_check" "$SRC/port/knulli/host/host_glthread.c"; then
        echo "   OK: host_glthread.c health_check (beliebige Form)"
    else
        echo "   HINWEIS: host_glthread.c ohne health_check (optional)"
    fi
fi

# Negativchecks
if grep -q '#include <arm_neon.h>' "$SRC/port/linux/src/d3d8_gl.c"; then
    echo "   FEHLT: d3d8_gl.c hat noch arm_neon.h (unerwartet)"
    failed=1
fi
if grep -q 'glUniform4f(fps_overlay_color' "$SRC/port/linux/src/d3d8_gl.c"; then
    echo "   FEHLT: d3d8_gl.c enthaelt noch glUniform4f"
    failed=1
fi

if [ "$failed" -ne 0 ]; then
    echo ""
    echo "FEHLER: Einige Optimierungen fehlen."
    exit 1
fi
echo ""
echo "== Alle Optimierungen sauber angewendet."
