#!/usr/bin/env bash
#
# Wendet den kompletten M9 Pro (RK3326) Patch-Satz auf einen
# Halo CE Universal Source-Baum an.
#
#   ./apply_all.sh <source-root>
#
# Reihenfolge:
#   1. git apply patches/halo-ce-universal-knulli.patch   (Upstream + Knulli)
#   2. python3 patches/patch_memory_pools.py <src>        (Allocator + decals)
#   3. python3 patches/patch_neon_math.py    <src>        (NEON matrix + strings)
#
# Idempotent: die Python-Skripte überspringen bereits angewendete Änderungen.
#
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=${1:?usage: apply_all.sh <source-root>}

[ -d "$SRC" ] || { echo "FEHLER: $SRC ist kein Verzeichnis" >&2; exit 1; }
SRC=$(cd "$SRC" && pwd)

PATCHES=$HERE/patches
MAIN_PATCH=$PATCHES/halo-ce-universal-knulli.patch

# ── 1) Der große Git-Patch (Upstream + alle Knulli-Optimierungen) ─────
if [ ! -f "$MAIN_PATCH" ]; then
    echo "FEHLER: $MAIN_PATCH fehlt" >&2
    exit 1
fi

if git -C "$SRC" rev-parse --git-dir > /dev/null 2>&1; then
    # Schon gepatcht? Dann nicht noch einmal anwenden.
    if git -C "$SRC" apply --check --reverse "$MAIN_PATCH" > /dev/null 2>&1; then
        echo "== $MAIN_PATCH ist bereits angewendet – überspringe"
    else
        echo "== git apply $(basename "$MAIN_PATCH")"
        git -C "$SRC" apply --whitespace=nowarn "$MAIN_PATCH"
    fi
else
    # Kein Git-Repo: mit --directory arbeiten
    echo "== git apply --directory (kein .git gefunden)"
    git apply --whitespace=nowarn --directory="$SRC" "$MAIN_PATCH"
fi

# ── 2) Die beiden Python-Patches ──────────────────────────────────────
for script in patch_memory_pools.py patch_neon_math.py; do
    if [ ! -f "$PATCHES/$script" ]; then
        echo "== $script nicht vorhanden – überspringe"
        continue
    fi
    echo "== python3 $script"
    if ! python3 "$PATCHES/$script" "$SRC"; then
        # Die Skripte exitieren nur, wenn *beide* Änderungen scheitern.
        echo "WARNUNG: $script hat nichts geändert (evtl. schon gepatcht)" >&2
    fi
done

echo
echo "== fertig: $SRC enthält den vollständigen M9 Pro Patch-Satz"
echo "   cseries.h Debug-Allocator:   $(grep -c HALO_DEBUG_ALLOCATOR "$SRC/source/cseries/cseries.h" || true)"
echo "   decals.c __thread-Arrays:    $(grep -c 'static __thread long surface_queue' "$SRC/source/effects/decals.c" || true)"
echo "   matrix_math.c NEON:          $(grep -c vfmaq_n_f32 "$SRC/source/math/matrix_math.c" || true)"
echo "   guest_string.c NEON:         $(grep -c 'vld1q_u8' "$SRC/port/android/guest/runtime/guest_string.c" || true)"
