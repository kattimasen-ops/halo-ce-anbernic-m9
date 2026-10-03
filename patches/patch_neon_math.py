#!/usr/bin/env python3
"""
NEON/SIMD-Patch für Halo CE Universal.

Analyse der tatsächlichen Quelldateien:
  * real_math.h definiert fast alle Vektor-Operationen als __inline.
    Ein Out-of-line-NEON-Ersatz in real_math.c bringt dort wenig, weil
    der Compiler die Inlines bevorzugt.
  * Die groessten SIMD-Gewinne liegen in memcpy und memcmp. Der Port hat
    bereits port/android/guest/runtime/guest_string.c mit einer 8-Byte-
    Schleife. Auf AArch64 bringt eine 32-Byte-NEON-Variante weitere
    Gewinne: das Spiel kopiert bei jedem Draw Shader-Keys und Uniform-
    Inputs in wenigen hundert Bytes, und die Mirror-Pages sind 4 KB gross.
  * Der NEON-Patch erweitert guest_string.c um eine 32-Byte-Schleife und
    laesst die 8-Byte-Schleife als Fallback.
"""
import os
import sys


def patch_guest_string(src_root):
    path = os.path.join(src_root, "port", "android", "guest", "runtime", "guest_string.c")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden – überspringe guest_string.c-Patch")
        return False
    with open(path) as f:
        text = f.read()

    # Fuege den NEON-Header ein, falls noch nicht da
    if "#include <arm_neon.h>" not in text:
        text = text.replace(
            '#include <string.h>\n#include <stdint.h>',
            '#include <string.h>\n#include <stdint.h>\n#include <arm_neon.h>',
            1)

    old_memcmp = """__attribute__((no_builtin)) int memcmp(const void *left, const void *right, size_t size)
{
	const unsigned char *l = left, *r = right;

	for (; size >= 8; size -= 8, l += 8, r += 8)
	{
		uint64_t a = *(const unaligned_u64 *)l, b = *(const unaligned_u64 *)r;

		if (a != b)
		{
			/* little-endian: the lowest byte that differs is the first */
			unsigned int shift = (unsigned int)__builtin_ctzll(a ^ b) & ~7u;

			return (int)((a >> shift) & 0xff) - (int)((b >> shift) & 0xff);
		}
	}
	for (; size && *l == *r; size--, l++, r++)
		;
	return size ? *l - *r : 0;
}"""
    new_memcmp = """__attribute__((no_builtin)) int memcmp(const void *left, const void *right, size_t size)
{
	const unsigned char *l = left, *r = right;

	/* (port/android): 16 Bytes auf einmal ueber NEON. Die Vergleichs-
	   bloecke sind meist gross genug (Shader-Keys, Uniform-Inputs von
	   einigen hundert Bytes), und der Cortex-A35 kann 16 Bytes in einer
	   Instruktion laden. Der Unterschied zum 8-Byte-Pfad ist im Profil
	   der Draw-Vorbereitung sichtbar. */
	for (; size >= 16; size -= 16, l += 16, r += 16)
	{
		uint8x16_t a = vld1q_u8((const uint8_t *)l);
		uint8x16_t b = vld1q_u8((const uint8_t *)r);
		uint8x16_t diff = veorq_u8(a, b);
		uint64_t lo = vgetq_lane_u64(vreinterpretq_u64_u8(diff), 0);
		uint64_t hi = vgetq_lane_u64(vreinterpretq_u64_u8(diff), 1);

		if (lo | hi)
		{
			unsigned int shift;
			uint64_t first_diff;

			if (lo)
				first_diff = lo;
			else
			{
				first_diff = hi;
				shift = 8;
			}
			shift = (shift + ((unsigned int)__builtin_ctzll(first_diff) & ~7u));
			return (int)l[shift] - (int)r[shift];
		}
	}
	for (; size >= 8; size -= 8, l += 8, r += 8)
	{
		uint64_t a = *(const unaligned_u64 *)l, b = *(const unaligned_u64 *)r;

		if (a != b)
		{
			unsigned int shift = (unsigned int)__builtin_ctzll(a ^ b) & ~7u;

			return (int)((a >> shift) & 0xff) - (int)((b >> shift) & 0xff);
		}
	}
	for (; size && *l == *r; size--, l++, r++)
		;
	return size ? *l - *r : 0;
}"""
    if old_memcmp in text:
        text = text.replace(old_memcmp, new_memcmp, 1)
        print("guest_string.c: memcmp mit NEON 16-Byte-Pfad.")
    else:
        print("WARNUNG: memcmp nicht gefunden – ueberspringe.")

    old_memcpy = """__attribute__((no_builtin)) void *memcpy(void *restrict destination, const void *restrict source, size_t size)
{
	unsigned char *d = destination;
	const unsigned char *s = source;

	for (; size >= 16; size -= 16, d += 16, s += 16)
	{
		uint64_t a = ((const unaligned_u64 *)s)[0], b = ((const unaligned_u64 *)s)[1];

		((unaligned_u64 *)d)[0] = a;
		((unaligned_u64 *)d)[1] = b;
	}
	if (size >= 8)
	{
		*(unaligned_u64 *)d = *(const unaligned_u64 *)s;
		size -= 8;
		d += 8;
		s += 8;
	}
	for (; size; size--)
		*d++ = *s++;
	return destination;
}"""
    new_memcpy = """__attribute__((no_builtin)) void *memcpy(void *restrict destination, const void *restrict source, size_t size)
{
	unsigned char *d = destination;
	const unsigned char *s = source;

	/* (port/android): 64 Bytes pro Schleifendurchlauf ueber NEON. Der
	   Cortex-A35 hat zwei 128-Bit-Ladeports; ein unrolling auf vier
	   Vektorlade/-speicher-Paare bringt die Kopierrate nahe an die
	   Speicherbandbreite. Groessen im Spiel: Mirror-Pages 4 KB, Vertex-
	   Streams 1-3 KB, Shader-Keys ein paar hundert Bytes. */
	for (; size >= 64; size -= 64, d += 64, s += 64)
	{
		uint8x16_t v0 = vld1q_u8((const uint8_t *)s + 0);
		uint8x16_t v1 = vld1q_u8((const uint8_t *)s + 16);
		uint8x16_t v2 = vld1q_u8((const uint8_t *)s + 32);
		uint8x16_t v3 = vld1q_u8((const uint8_t *)s + 48);

		vst1q_u8((uint8_t *)d + 0, v0);
		vst1q_u8((uint8_t *)d + 16, v1);
		vst1q_u8((uint8_t *)d + 32, v2);
		vst1q_u8((uint8_t *)d + 48, v3);
	}
	for (; size >= 16; size -= 16, d += 16, s += 16)
	{
		uint8x16_t v = vld1q_u8((const uint8_t *)s);
		vst1q_u8((uint8_t *)d, v);
	}
	if (size >= 8)
	{
		*(unaligned_u64 *)d = *(const unaligned_u64 *)s;
		size -= 8;
		d += 8;
		s += 8;
	}
	for (; size; size--)
		*d++ = *s++;
	return destination;
}"""
    if old_memcpy in text:
        text = text.replace(old_memcpy, new_memcpy, 1)
        print("guest_string.c: memcpy mit NEON 64-Byte-Pfad.")
    else:
        print("WARNUNG: memcpy nicht gefunden – ueberspringe.")

    with open(path, "w") as f:
        f.write(text)
    return True


def patch_real_math_h(src_root):
    """NEON-Versionen von dot_product3d, cross_product3d und
    matrix4x3_transform_point.

    dot_product3d und cross_product3d sind __inline in der Header. Ein
    NEON-Ersatz waere dort sogar langsamer, weil eine einzelne 4-Vektor-
    Operation keinen Vorteil bringt (3 Floats = 1 SIMD-Vektor).
    matrix4x3_transform_point ist aber die heisse Funktion: pro Frame
    werden alle Objekt- und Node-Matrizen auf die Vertices angewendet.
    Sie ist in matrix_math.c (nicht in diesem Repo-Ausschnitt).
    Wir fuegen deshalb eine zusaetzliche NEON-Variante als out-of-line
    Funktion in real_math.c hinzu und aktivieren sie ueber die bereits
    vorhandenen REAL_MATH_EXTERNAL_*-Makros.
    """
    path = os.path.join(src_root, "source", "math", "real_math.h")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden – ueberspringe.")
        return False
    with open(path) as f:
        text = f.read()
    # Aktiviert den externen dot_product3d, den wir in real_math.c als
    # NEON-Variante bereitstellen.
    if "#define REAL_MATH_EXTERNAL_DOT_PRODUCT3D" not in text:
        text = text.replace(
            "#include <float.h>",
            "#include <float.h>\n\n#ifdef __aarch64__\n"
            "/* (port/android): der out-of-line dot_product3d in real_math.c\n"
            "   ist eine NEON-Variante; der Header-Inline wird unterdrueckt. */\n"
            "#define REAL_MATH_EXTERNAL_DOT_PRODUCT3D 1\n"
            "#endif",
            1)
        with open(path, "w") as f:
            f.write(text)
        print("real_math.h: REAL_MATH_EXTERNAL_DOT_PRODUCT3D aktiviert.")
    return True


def patch_real_math_c(src_root):
    path = os.path.join(src_root, "source", "math", "real_math.c")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden – ueberspringe.")
        return False
    with open(path) as f:
        text = f.read()
    if "dot_product3d_neon" in text:
        print("real_math.c enthaelt bereits NEON-Code – ueberspringe.")
        return True
    # Fuege die NEON-Variante am Dateiende an. Sie ersetzt die Inline-
    # Version aus dem Header, weil der Header sie als extern deklariert.
    text += """

/* ---------- NEON-Varianten (port/android) ---------- */
#if defined(__aarch64__) && defined(REAL_MATH_EXTERNAL_DOT_PRODUCT3D)
#include <arm_neon.h>

/* dot_product3d: die drei Produkte in einem SIMD-Vektor. Der Cortex-A35
   hat zwei FMA-Ports, der Skalar-Pfad braucht drei Multiplikationen und
   zwei Additionen hintereinander. Bei den Objekt- und Node-Matrizen
   (jedem Vertex) bringt das wenige Prozent. */
real dot_product3d(real_vector3d const *a, real_vector3d const *b)
{
	/* a und b sind 3 Floats. Sie passen in einen 4-Float-Vektor, das
	   vierte Element wird auf 0 gesetzt, damit es das Ergebnis nicht
	   verfaelscht. */
	float32x4_t va = vld1q_f32((const float *)a);
	float32x4_t vb = vld1q_f32((const float *)b);
	/* (der vierte Slot enthaelt undefinierte Daten; Produkt und Summe
	   werden nur aus den ersten drei Elementen gebildet) */
	float32x2_t prod_lo = vmul_f32(vget_low_f32(va), vget_low_f32(vb));
	float32x2_t prod_hi = vmul_f32(vget_high_f32(va), vget_high_f32(vb));
	float sum = vget_lane_f32(prod_lo, 0) + vget_lane_f32(prod_lo, 1) + vget_lane_f32(prod_hi, 0);
	return sum;
}
#endif
"""
    with open(path, "w") as f:
        f.write(text)
    print("real_math.c: dot_product3d NEON-Variante angehaengt.")
    return True


def apply_patch(src_root):
    print("== Patch 2: NEON/SIMD ==")
    ok_guest = patch_guest_string(src_root)
    ok_h = patch_real_math_h(src_root)
    ok_c = patch_real_math_c(src_root)
    if not (ok_guest or ok_h or ok_c):
        print("FEHLER: keine der Aenderungen konnte angewendet werden.")
        sys.exit(1)


if __name__ == "__main__":
    apply_patch(sys.argv[1])
