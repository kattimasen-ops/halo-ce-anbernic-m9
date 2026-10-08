#!/usr/bin/env python3
"""patch_forward_declarations.py — Fixt fehlende Forward-Deklarationen.

Problem:
  Mehrere Patches fuegen einen Aufruf an einer fruehen Stelle in eine
  .c-Datei ein, waehrend die Definition der aufgerufenen Funktion
  spaeter in derselben Datei steht. C99 verbietet implizite
  Funktionsdeklarationen; clang meldet:
    "call to undeclared function 'xyz';
     ISO C99 and later do not support implicit function declarations"

  Betroffene Stelle (Stand 2026-10-08):
    port/linux/src/d3d8_gl.c
      Aufruf:     xgpu_shader_prewarm_begin(current)   (in halo_screen_commit)
      Definition: void xgpu_shader_prewarm_begin(const char *map_name);
      eingefuegt durch: patch_shader_prewarm.py

  xbox_textures.c wird BEWUSST NICHT angefasst:
    Die korrigierte patch_texture_prewarm.py setzt ihre Forward-Deklaration
    fuer texture_upload_queue selbst, direkt vor xgpu_texture_prewarm_begin.
    Wenn dieser Patch sie ZUSAETZLICH vor der struct-Definition einfuegt,
    sieht clang-22 zwei Deklarationen desselben Namens mit unterschiedlichem
    Tag-Scope und meldet "conflicting types" sowie absurde Meldungen wie
    "passing 'struct texture_entry *' to parameter of type
    'struct texture_entry *'".

Idempotent: prueft Marker und vorhandene Deklaration, bevor sie etwas tut.
"""
import os
import sys


D3D8_MARKER = "shader_prewarm_fwd_decl"
D3D8_ANCHOR = '#include <string.h>\n'
D3D8_DECL = (
    '#include <string.h>\n'
    '\n'
    '#ifdef HALO_ANDROID\n'
    '/* ' + D3D8_MARKER + ': Forward-Deklaration fuer xgpu_shader_prewarm_begin.\n'
    '\n'
    'patch_shader_prewarm.py fuegt den Aufruf in halo_screen_commit (weiter\n'
    'oben in dieser Datei) ein, die Definition steht aber weiter unten in\n'
    'dieser Datei. C99 verlangt eine Deklaration vor dem Aufruf. Signatur\n'
    'muss exakt zur Definition passen:\n'
    '    void xgpu_shader_prewarm_begin(const char *map_name); */\n'
    'void xgpu_shader_prewarm_begin(const char *map_name);\n'
    '#endif\n'
)


def patch_d3d8_gl(src_root):
    path = os.path.join(src_root, "port", "linux", "src", "d3d8_gl.c")
    if not os.path.exists(path):
        print(f"  WARNUNG: {path} nicht gefunden - ueberspringe.")
        return False
    with open(path) as f:
        text = f.read()

    if D3D8_MARKER in text:
        print("  d3d8_gl.c: Forward-Deklaration bereits vorhanden (Marker).")
        return True

    if "void xgpu_shader_prewarm_begin(const char *map_name);" in text[:4096]:
        print("  d3d8_gl.c: Forward-Deklaration bereits durch patch_shader_prewarm.py gesetzt.")
        return True

    if D3D8_ANCHOR not in text:
        print("  FEHLER: d3d8_gl.c-Anker '#include <string.h>' fehlt.", file=sys.stderr)
        return False

    text = text.replace(D3D8_ANCHOR, D3D8_DECL, 1)
    with open(path, "w") as f:
        f.write(text)
    print("  d3d8_gl.c: Forward-Deklaration fuer xgpu_shader_prewarm_begin eingefuegt.")
    return True


def apply_patch(src_root):
    print("== Patch: Forward-Deklarationen (C99) ==")
    ok = patch_d3d8_gl(src_root)
    if not ok:
        sys.exit(1)
    print("== Fertig.")


if __name__ == "__main__":
    apply_patch(sys.argv[1] if len(sys.argv) > 1 else ".")
