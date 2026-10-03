#!/usr/bin/env python3
"""
NEON/SIMD-Patch für Halo CE Universal.
Vektorisiert die 4x4-Matrixmultiplikation in source/math/real_math.c.

WICHTIG: Dieser Patch ist eine Vorlage. Die tatsächliche Funktion heißt
möglicherweise anders (matrix_multiply, matrix4x3_multiply, etc.).
Prüfe mit: grep -rn "matrix.*multiply" source/math/
"""
import os
import sys

def apply_patch(src_root):
    math_c = os.path.join(src_root, "source", "math", "real_math.c")
    if not os.path.exists(math_c):
        print(f"WARNUNG: {math_c} nicht gefunden – NEON-Patch übersprungen.")
        return
    with open(math_c) as f:
        text = f.read()
    if "arm_neon.h" in text:
        print("real_math.c enthält bereits NEON-Code – überspringe.")
        return
    # Füge NEON-Header hinzu, aber ändere die Funktion nicht automatisch.
    # Die tatsächliche Vektorisierung muss manuell erfolgen.
    text = "#include <arm_neon.h>\n" + text
    with open(math_c, "w") as f:
        f.write(text)
    print("real_math.c mit NEON-Header versehen.")
    print("HINWEIS: Die Matrixmultiplikation muss manuell auf NEON-Intrinsics")
    print("umgestellt werden. Der Header allein reicht nicht.")

if __name__ == "__main__":
    apply_patch(sys.argv[1])
