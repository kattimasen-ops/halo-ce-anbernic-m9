#!/usr/bin/env python3
"""
NEON-Vektorisierung von index_extent in port/linux/src/d3d8_gl.c.

Der Loop sucht das Minimum und Maximum ueber eine Liste von 16-Bit-Indizes.
Auf dem Cortex-A35 (in-order, eine Load/Store-Einheit) ist das ein Loop mit
einer langen Abhaengigkeitskette auf low/high. Die Vektorversion laedt 8
Indizes pro Iteration mit vld1q_u16, akkumuliert Minimum und Maximum mit
vminq_u16 / vmaxq_u16, und reduziert am Ende mit vminvq_u16 / vmaxvq_u16.

Idempotent.
"""
import os
import sys


OLD_INCLUDE = '''#include "xgpu.h"
#include "sdl_platform.h"
#include "halo_ui_pointer.h"
#include "port_config.h"

#include <math.h>'''

NEW_INCLUDE = '''#include "xgpu.h"
#include "sdl_platform.h"
#include "halo_ui_pointer.h"
#include "port_config.h"

#if defined(__aarch64__)
#include <arm_neon.h>
#endif

#include <math.h>'''

OLD_DECL = '\tunsigned long index, low = 0xffff, high = 0;'
NEW_DECL = '\tunsigned long low = 0xffff, high = 0;'

OLD_LOOP = '''	for (index = 0; index < count; index++)
	{
		if (indices[index] < low)
			low = indices[index];
		if (indices[index] > high)
			high = indices[index];
	}'''

NEW_LOOP = '''#if defined(__aarch64__)
	/* Vector path: 8 indices per iteration, min/max per lane, one
	horizontal reduction at the end. The scalar tail handles count % 8
	remaining indices (empty for the common case). */
	{
		uint16x8_t v_min = vdupq_n_u16(0xffff);
		uint16x8_t v_max = vdupq_n_u16(0);
		unsigned long i = 0;

		for (; i + 8 <= count; i += 8)
		{
			uint16x8_t v = vld1q_u16(indices + i);

			v_min = vminq_u16(v_min, v);
			v_max = vmaxq_u16(v_max, v);
		}
		low = vminvq_u16(v_min);
		high = vmaxvq_u16(v_max);
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
#endif'''


def apply_patch(src_root):
    print("== Patch 9: NEON fuer index_extent ==")
    path = os.path.join(src_root, "port", "linux", "src", "d3d8_gl.c")
    if not os.path.exists(path):
        print(f"FEHLER: {path} nicht gefunden")
        sys.exit(1)
    with open(path) as f:
        text = f.read()

    if "vminvq_u16" in text:
        print("d3d8_gl.c: index_extent bereits vektorisiert – überspringe.")
        return

    # 1) Include
    if OLD_INCLUDE in text:
        text = text.replace(OLD_INCLUDE, NEW_INCLUDE, 1)
    elif "#include <arm_neon.h>" in text:
        pass  # schon da
    else:
        print("WARNUNG: Include-Block nicht gefunden (arm_neon.h fehlt vielleicht)")

    # 2) Deklaration: index raus (wird im NEON-Pfad nicht mehr gebraucht)
    if OLD_DECL in text:
        text = text.replace(OLD_DECL, NEW_DECL, 1)
    elif NEW_DECL in text:
        pass
    else:
        print("WARNUNG: index/low/high-Deklaration nicht gefunden")

    # 3) Loop
    if OLD_LOOP not in text:
        print("FEHLER: Loop-Marker in index_extent nicht gefunden")
        sys.exit(1)
    text = text.replace(OLD_LOOP, NEW_LOOP, 1)

    with open(path, "w") as f:
        f.write(text)
    print("d3d8_gl.c: index_extent mit NEON (8 u16 pro Iteration).")


if __name__ == "__main__":
    apply_patch(sys.argv[1])
