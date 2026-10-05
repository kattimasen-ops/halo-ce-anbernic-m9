#!/usr/bin/env python3
"""
Ersetzt die ganze index_extent-Funktion in port/linux/src/d3d8_gl.c
durch eine Version, die Clangs C-Vektor-Erweiterung nutzt.

Robust: statt nach einem Loop zu suchen (was mit frueheren Patch-Versionen
und unterschiedlichem Whitespace fehlschlagen kann), wird die Funktion per
Regex gefunden und der ganze Body ersetzt.

Kein <arm_neon.h>: die Builtins __builtin_elementwise_min/max werden von
Clang auf AArch64 zu vminq_u16/vmaxq_u16. Das umgeht die Apple-arm_neon.h,
die auf dem arm64_32-Ziel die Basistypen (uint16x8_t) nicht definiert,
wenn __ARM_NEON nicht gesetzt ist.

Idempotent. Entfernt auch alte arm_neon.h-Includes, die ein frueherer
Patch-Versuch hinterlassen haben koennte.
"""

import os
import re
import sys


FUNCTION_RE = re.compile(
    r'static void index_extent\(const WORD \*indices, unsigned long count,'
    r' unsigned long generation, BOOL cached,\s*\n'
    r'\tunsigned long \*minimum, unsigned long \*maximum\)\s*\n'
    r'\{.*?\n\}',
    re.DOTALL,
)


NEW_FUNCTION = '''static void index_extent(const WORD *indices, unsigned long count, unsigned long generation, BOOL cached,
	unsigned long *minimum, unsigned long *maximum)
{
	unsigned long slot = (((unsigned long)indices >> 1) ^ (count * 2654435761UL)) % INDEX_RANGE_SLOTS;
	unsigned long low = 0xffff, high = 0;

	if (cached && index_ranges[slot].address == (unsigned long)indices && index_ranges[slot].count == count &&
		index_ranges[slot].generation == generation)
	{
		*minimum = index_ranges[slot].minimum;
		*maximum = index_ranges[slot].maximum;
		return;
	}
#if defined(__aarch64__) && defined(__clang__)
	/* Vector path: 8 indices per iteration with Clang's C vector extension
	and the __builtin_elementwise_min/max builtins, which lower to NEON on
	AArch64. Deliberately avoids <arm_neon.h>: on the arm64_32-apple-watchos
	target that header does not define its base types (uint16x8_t etc.)
	unless __ARM_NEON happens to be set, which it is not here. */
	{
		typedef unsigned short u16x8 __attribute__((__vector_size__(16), __aligned__(2), __may_alias__));
		u16x8 v_min = (u16x8){ 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff };
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
	{
		unsigned long index;

		for (index = 0; index < count; index++)
		{
			if (indices[index] < low)
				low = indices[index];
			if (indices[index] > high)
				high = indices[index];
		}
	}
#endif
	if (cached)
	{
		index_ranges[slot].address = (unsigned long)indices;
		index_ranges[slot].count = count;
		index_ranges[slot].generation = generation;
		index_ranges[slot].minimum = (WORD)low;
		index_ranges[slot].maximum = (WORD)high;
	}
	*minimum = low;
	*maximum = high;
}'''


def apply_patch(src_root):
    print("== Patch 9: NEON fuer index_extent (Vektor-Erweiterung) ==")
    path = os.path.join(src_root, "port", "linux", "src", "d3d8_gl.c")
    if not os.path.exists(path):
        print(f"FEHLER: {path} nicht gefunden", file=sys.stderr)
        sys.exit(1)
    with open(path) as f:
        text = f.read()

    # 1) Reste eines frueheren Versuchs entfernen: den arm_neon.h-Include,
    #    den ein anderer Patch am Anfang eingefuegt haben koennte.
    removed_include = False
    for candidate in (
        '#if defined(__aarch64__)\n#include <arm_neon.h>\n#endif\n\n',
        '#include <arm_neon.h>\n',
    ):
        while candidate in text:
            text = text.replace(candidate, "", 1)
            removed_include = True

    # 2) Falls die Funktion bereits die neue Form hat, nichts tun.
    if "__builtin_elementwise_min" in text and "u16x8 v_min" in text:
        if removed_include:
            with open(path, "w") as f:
                f.write(text)
            print("d3d8_gl.c: alten Include entfernt; "
                  "index_extent war schon vektorisiert.")
        else:
            print("d3d8_gl.c: index_extent bereits mit Builtins vektorisiert "
                  "– überspringe.")
        return

    # 3) Die ganze Funktion suchen und ersetzen.
    m = FUNCTION_RE.search(text)
    if not m:
        print("FEHLER: index_extent-Funktion nicht gefunden.", file=sys.stderr)
        sys.exit(1)
    text = text[:m.start()] + NEW_FUNCTION + text[m.end():]

    with open(path, "w") as f:
        f.write(text)
    print(f"d3d8_gl.c: index_extent komplett ersetzt "
          f"(Include entfernt={removed_include}).")


if __name__ == "__main__":
    apply_patch(sys.argv[1])
