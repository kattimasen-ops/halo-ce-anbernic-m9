#!/usr/bin/env bash
set -euo pipefail

SRC="${1:?usage: apply-all.sh <source-root>}"
PATCHES="$(cd "$(dirname "$0")/.." && pwd)/patches"

cd "$SRC"

echo "== Schritt 1: Upstream-Patch (6) =="
git apply --whitespace=nowarn "$PATCHES/halo-ce-universal-knulli (6).patch"

echo "== Schritt 2: Memory-Pool-Patch =="
python3 "$PATCHES/patch_memory_pools.py" .

echo "== Schritt 3: NEON-Patch =="
python3 "$PATCHES/patch_neon_math.py" .

echo "== Fertig =="
