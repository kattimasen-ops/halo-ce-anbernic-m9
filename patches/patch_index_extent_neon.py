#!/usr/bin/env python3
"""
NEON-Vektorisierung von index_extent in port/linux/src/d3d8_gl.c.

Statt arm_neon.h-Intrinsics verwendet dieser Patch Clangs C-Vektor-
Erweiterung (__attribute__((vector_size(16)))) und die generischen
Builtins __builtin_elementwise_min/max. Das umgeht das Problem, dass
die Apple-arm_neon.h auf dem arm64_32-Ziel die Basistypen (uint16x8_t)
nicht definiert, wenn __ARM_NEON nicht gesetzt ist.

Idempotent. Entfernt auch die fruehere arm_neon.h-basierte Version.
"""

import os
import re
import sys


# Die drei Bloecke, die im d3d8_gl.c vorkommen koennen:

# A) Vorheriger Patch: arm_neon.h-Include (wird entfernt)
OLD_NEON_INCLUDE = '''#if defined(__aarch64__)
#include <arm_neon.h>
#endif

'''

# B) Alter NEON-Block mit Intrinsics (wird durch den Builtin-Block ersetzt)
OLD_NEON_BLOCK_RE = re.compile(
    r'#if defined\(__aarch64__\)\n'
    r'\t/\* Vector path: 8 indices per iteration.*?\n'
    r'#endif',
    re.DOTALL,
)

# C) Sauberer, skalarer Loop (wird durch den neuen Block ersetzt)
OLD_SCALAR_LOOP = '''	for (index = 0; index < count; index++)
	{
		if (indices[index] < low)
			low = indices[index];
		if (indices[index] > high)
			high = indices[index];
	}'''

NEW_BLOCK = '''#if defined(__aarch64__) && defined(__clang__)
	/* Vector path: 8 indices per iteration, using Clang's C vector
	extension. No <arm_neon.h> is needed: the builtins
	__builtin_elementwise_min/max lower to the same NEON instructions
	(vminq_u16/vmaxq_u16) on AArch64, and the manual horizontal reduction
	runs once per call. This avoids the Apple arm_neon.h, which on the
	arm64_32 target does not define its base types (uint16x8_t) unless
	__ARM_NEON happens to be set. */
	{
		typedef unsigned short u16x8 __attribute__((__vector_size__(16), __aligned__(2), __may_alias__));
		u16x8 v_min = (u16x8){ 0xffff, 0xffff, 0xffff, 0xffff,
		                       0xffff, 0xffff, 0xffff, 0xffff };
		u16x8 v_max = (u16x8){ 0 };
		unsigned long i = 0;
		int k;

		for (; i + 8 <= count; i += 8)
		{
			u16x8 v = *(const u16x8 *)(const void *)(indices + i);

			v_min = __builtin_elementwise_min(v_min, v);
			v_max = __builtin_elementwise_max(v_max, v);
		}
		low = v_min[0];
		high = v_max[0];
		for (k = 1; k < 8; k++)
		{
			if (v_min[k] < low)
				low = v_min[k];
			if (v_max[k] > high)
				high = v_max[k];
		}
		for (; i < count; i++)
		{
			if (indices[i] < low)
				low = indices[i];
			if (indices[i] > high)
				high = indices[i];
		}
	}
#else
	for (index = 0; index < count; index++)
	{
		if (indices[index] < low)
			low = indices[index];
		if (indices[index] > high)
			high = indices[index];
	}
#endif'''


def apply_patch(src_root):
    print("== Patch 9: NEON fuer index_extent (Vektor-Erweiterung) ==")
    path = os.path.join(src_root, "port", "linux", "src", "d3d8_gl.c")
    if not os.path.exists(path):
        print(f"FEHLER: {path} nicht gefunden")
        sys.exit(1)
    with open(path) as f:
        text = f.read()

    # Idempotenz: bereits die neue Variante drin?
    if "__builtin_elementwise_min" in text:
        print("d3d8_gl.c: index_extent bereits mit Builtins vektorisiert "
              "– überspringe.")
        return

    # 1) Alten arm_neon.h-Include entfernen, falls vorhanden
    removed_include = False
    if OLD_NEON_INCLUDE in text:
        text = text.replace(OLD_NEON_INCLUDE, "", 1)
        removed_include = True

    # 2) Alten NEON-Block (aus früherem Patch) durch den neuen ersetzen
    replaced_block = False
    m = OLD_NEON_BLOCK_RE.search(text)
    if m:
        text = text[:m.start()] + NEW_BLOCK + text[m.end():]
        replaced_block = True

    # 3) Sonst: den sauberen, skalaren Loop ersetzen
    if not replaced_block:
        if OLD_SCALAR_LOOP not in text:
            print("FEHLER: weder ein alter NEON-Block noch der skalare Loop "
                  "wurde in index_extent gefunden.")
            sys.exit(1)
        text = text.replace(OLD_SCALAR_LOOP, NEW_BLOCK, 1)

    with open(path, "w") as f:
        f.write(text)
    print(f"d3d8_gl.c: index_extent mit Vektor-Erweiterung "
          f"(Include entfernt={removed_include}, "
          f"alter Block ersetzt={replaced_block}).")


if __name__ == "__main__":
    apply_patch(sys.argv[1])
