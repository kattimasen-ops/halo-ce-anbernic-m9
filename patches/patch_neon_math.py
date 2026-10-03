#!/usr/bin/env python3
"""
NEON/SIMD-Patch für Halo CE Universal.

Zwei Änderungen:
  1. matrix_math.c: matrix4x3_transform_point und matrix4x3_transform_vector
     laufen ueber NEON. Diese Funktionen werden pro Vertex aufgerufen
     (tausende pro Frame). Das Layout der real_matrix4x3-Struktur ist
     {scale; forward.i,j,k; left.i,j,k; up.i,j,k; position.x,y,z}, also
     13 aufeinanderfolgende Floats. Ein vld1q_f32 ueber forward.i liefert
     {fwd.i, fwd.j, fwd.k, left.i}; das sind vier nutzbare Lanes, weil
     result.x/y/z nur die ersten drei Lanes auswertet.
  2. guest_string.c: memcpy/memcmp mit NEON 16/64-Byte-Pfaden.
"""
import os
import sys


# ── matrix_math.c ─────────────────────────────────────────────────────
def patch_matrix_math(src_root):
    path = os.path.join(src_root, "source", "math", "matrix_math.c")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden – ueberspringe matrix_math.c-Patch")
        return False
    with open(path) as f:
        text = f.read()

    # ARM-NEON-Header einfuegen
    if "#include <arm_neon.h>" not in text:
        old_inc = '#include "cseries.h"\n#include "real_math.h"'
        new_inc = ('#include "cseries.h"\n#include "real_math.h"\n\n'
                   '#if defined(__aarch64__)\n#include <arm_neon.h>\n#endif')
        if old_inc in text:
            text = text.replace(old_inc, new_inc, 1)
        else:
            print("WARNUNG: cseries.h/real_math.h-Include nicht gefunden.")
            return False

    # matrix4x3_transform_point
    old_pt = """real_point3d *matrix4x3_transform_point(
	real_matrix4x3 const *matrix,
	real_point3d const *point,
	real_point3d *result)
{
	real x = point->x;
	real y = point->y;
	real z = point->z;

	if (matrix->scale != 1.f)
	{
		x *= matrix->scale;
		y *= matrix->scale;
		z *= matrix->scale;
	}

	result->x = matrix->up.i*z + matrix->left.i*y + matrix->forward.i*x + matrix->position.x;
	result->y = matrix->up.j*z + matrix->left.j*y + matrix->forward.j*x + matrix->position.y;
	result->z = matrix->up.k*z + matrix->left.k*y + matrix->forward.k*x + matrix->position.z;
	return result;
}"""
    new_pt = """real_point3d *matrix4x3_transform_point(
	real_matrix4x3 const *matrix,
	real_point3d const *point,
	real_point3d *result)
{
	real x = point->x;
	real y = point->y;
	real z = point->z;

	if (matrix->scale != 1.f)
	{
		x *= matrix->scale;
		y *= matrix->scale;
		z *= matrix->scale;
	}

#if defined(__aarch64__)
	{
		/* (port/android): NEON-Variante. Das Struct-Layout ist
		   {scale; forward.i,j,k; left.i,j,k; up.i,j,k; position.x,y,z}.
		   Ein vld1q_f32 ueber forward.i liefert {fwd.i, fwd.j, fwd.k,
		   left.i}. Wir nutzen nur die ersten drei Lanes jedes Vektors;
		   die vierte traegt ein nutzloses viertes Element, das in
		   result.x/y/z nicht eingeht. */
		float pos3[4];
		float32x4_t v_fwd, v_left, v_up, v_pos, v_res;
		float out[4];

		pos3[0] = matrix->position.x;
		pos3[1] = matrix->position.y;
		pos3[2] = matrix->position.z;
		pos3[3] = 0.0f;

		v_fwd = vld1q_f32(&matrix->forward.i);
		v_left = vld1q_f32(&matrix->left.i);
		v_up = vld1q_f32(&matrix->up.i);
		v_pos = vld1q_f32(pos3);

		v_res = vmulq_n_f32(v_fwd, x);
		v_res = vfmaq_n_f32(v_res, v_left, y);
		v_res = vfmaq_n_f32(v_res, v_up, z);
		v_res = vaddq_f32(v_res, v_pos);

		vst1q_f32(out, v_res);
		result->x = out[0];
		result->y = out[1];
		result->z = out[2];
	}
#else
	result->x = matrix->up.i*z + matrix->left.i*y + matrix->forward.i*x + matrix->position.x;
	result->y = matrix->up.j*z + matrix->left.j*y + matrix->forward.j*x + matrix->position.y;
	result->z = matrix->up.k*z + matrix->left.k*y + matrix->forward.k*x + matrix->position.z;
#endif
	return result;
}"""
    if old_pt in text:
        text = text.replace(old_pt, new_pt, 1)
        print("matrix_math.c: matrix4x3_transform_point mit NEON.")
    else:
        print("WARNUNG: matrix4x3_transform_point nicht gefunden – ueberspringe.")

    # matrix4x3_transform_vector
    old_vec = """real_vector3d *matrix4x3_transform_vector(
	real_matrix4x3 const *matrix,
	real_vector3d const *vector,
	real_vector3d *result)
{
	real i = vector->i;
	real j = vector->j;
	real k = vector->k;

	if (matrix->scale != 1.f)
	{
		i *= matrix->scale;
		j *= matrix->scale;
		k *= matrix->scale;
	}

	result->i = i*matrix->forward.i + j*matrix->left.i + k*matrix->up.i;
	result->j = i*matrix->forward.j + j*matrix->left.j + k*matrix->up.j;
	result->k = i*matrix->forward.k + j*matrix->left.k + k*matrix->up.k;

	return result;
}"""
    new_vec = """real_vector3d *matrix4x3_transform_vector(
	real_matrix4x3 const *matrix,
	real_vector3d const *vector,
	real_vector3d *result)
{
	real i = vector->i;
	real j = vector->j;
	real k = vector->k;

	if (matrix->scale != 1.f)
	{
		i *= matrix->scale;
		j *= matrix->scale;
		k *= matrix->scale;
	}

#if defined(__aarch64__)
	{
		float32x4_t v_fwd = vld1q_f32(&matrix->forward.i);
		float32x4_t v_left = vld1q_f32(&matrix->left.i);
		float32x4_t v_up = vld1q_f32(&matrix->up.i);
		float32x4_t v_res;
		float out[4];

		v_res = vmulq_n_f32(v_fwd, i);
		v_res = vfmaq_n_f32(v_res, v_left, j);
		v_res = vfmaq_n_f32(v_res, v_up, k);

		vst1q_f32(out, v_res);
		result->i = out[0];
		result->j = out[1];
		result->k = out[2];
	}
#else
	result->i = i*matrix->forward.i + j*matrix->left.i + k*matrix->up.i;
	result->j = i*matrix->forward.j + j*matrix->left.j + k*matrix->up.j;
	result->k = i*matrix->forward.k + j*matrix->left.k + k*matrix->up.k;
#endif

	return result;
}"""
    if old_vec in text:
        text = text.replace(old_vec, new_vec, 1)
        print("matrix_math.c: matrix4x3_transform_vector mit NEON.")
    else:
        print("WARNUNG: matrix4x3_transform_vector nicht gefunden – ueberspringe.")

    with open(path, "w") as f:
        f.write(text)
    return True


# ── guest_string.c ────────────────────────────────────────────────────
def patch_guest_string(src_root):
    path = os.path.join(src_root, "port", "android", "guest", "runtime",
                        "guest_string.c")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden – ueberspringe guest_string.c-Patch")
        return False
    with open(path) as f:
        text = f.read()

    if "#include <arm_neon.h>" not in text:
        text = text.replace(
            '#include <string.h>\n#include <stdint.h>',
            '#include <string.h>\n#include <stdint.h>\n#include <arm_neon.h>',
            1)

    # memcmp mit 16-Byte-NEON
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
	   bloecke sind meist gross genug (Shader-Keys und Uniform-Inputs von
	   einigen hundert Bytes), und der Cortex-A35 laedt 16 Bytes in einer
	   Instruktion. Der Unterschied zum 8-Byte-Pfad ist im Profil der
	   Draw-Vorbereitung sichtbar. */
	for (; size >= 16; size -= 16, l += 16, r += 16)
	{
		uint8x16_t a = vld1q_u8((const uint8_t *)l);
		uint8x16_t b = vld1q_u8((const uint8_t *)r);
		uint8x16_t diff = veorq_u8(a, b);
		uint64_t lo = vgetq_lane_u64(vreinterpretq_u64_u8(diff), 0);
		uint64_t hi = vgetq_lane_u64(vreinterpretq_u64_u8(diff), 1);

		if (lo | hi)
		{
			uint64_t first_diff = lo ? lo : hi;
			unsigned int byte = (unsigned int)__builtin_ctzll(first_diff) >> 3;

			if (!lo)
				byte += 8;
			return (int)l[byte] - (int)r[byte];
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

    # memcpy mit 64-Byte-NEON
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
	   Cortex-A35 hat zwei 128-Bit-Ladeports; vier Vektorlade/-speicher-
	   Paare pro Iteration bringen die Kopierrate nahe an die Speicher-
	   bandbreite. Groessen im Spiel: Mirror-Pages 4 KB, Vertex-Streams
	   1-3 KB, Shader-Keys ein paar hundert Bytes. */
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


def apply_patch(src_root):
    print("== Patch 2: NEON/SIMD ==")
    ok_a = patch_matrix_math(src_root)
    ok_b = patch_guest_string(src_root)
    if not (ok_a or ok_b):
        print("FEHLER: keine der Aenderungen konnte angewendet werden.")
        sys.exit(1)


if __name__ == "__main__":
    apply_patch(sys.argv[1])
