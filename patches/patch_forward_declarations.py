#!/usr/bin/env python3
"""patch_forward_declarations.py — Fixt fehlende Forward-Deklarationen.

Problem:
  Mehrere Patches fuegen einen Aufruf an einer fruehen Stelle in eine
  .c-Datei ein, waehrend die Definition der aufgerufenen Funktion
  spaeter in derselben Datei steht. C99 verbietet implizite
  Funktionsdeklarationen; clang meldet:
    "call to undeclared function 'xyz';
     ISO C99 and later do not support implicit function declarations"

Betroffene Stellen (Stand 2026-10-08):
  1. port/linux/src/d3d8_gl.c
     - Aufruf:     xgpu_shader_prewarm_begin(current)  (in halo_screen_commit)
     - Definition: void xgpu_shader_prewarm_begin(const char *map_name);
     - eingefuegt durch: patch_shader_prewarm.py

  2. port/linux/src/xbox_textures.c
     - Aufruf:     texture_upload_queue(entry, NULL)
     - Definition: static BOOL texture_upload_queue(struct texture_entry *entry,
                                                    const D3DCOLOR *palette);
     - eingefuegt durch: patch_texture_prewarm.py (korrigierte Version
       setzt die Deklaration bereits selbst; hier nur als Sicherheitsnetz)

Loesung:
  Forward-Deklaration direkt nach dem letzten #include-Block, vor dem
  ersten Code. Idempotent ueber eigene Marker (nicht die der
  urspruenglichen Patches, damit die check_patch-Verifikation aus
  build.sh nicht gestoert wird).

Laeuft NACH patch_shader_prewarm.py und patch_texture_prewarm.py,
VOR den check_patch-Verifikationen.
"""
import os
import sys


# ---------- d3d8_gl.c: xgpu_shader_prewarm_begin ----------

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
        print("  d3d8_gl.c: Forward-Deklaration bereits vorhanden.")
        return True
    # Wenn patch_shader_prewarm.py die Deklaration schon korrekt eingefuegt
    # hat, brauchen wir nichts zu tun.
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


# ---------- xbox_textures.c: texture_upload_queue (Sicherheitsnetz) ----------

TEX_MARKER = "texture_upload_queue_fwd_decl"
TEX_ANCHOR = '#include <stdio.h>\n'
TEX_DECL = (
    '#include <stdio.h>\n'
    '\n'
    '#ifdef HALO_ANDROID\n'
    '/* ' + TEX_MARKER + ': Forward-Deklaration fuer texture_upload_queue.\n'
    '\n'
    'Die Definition steht weiter unten in dieser Datei (im Knulli-Patch).\n'
    'C99 verlangt eine Deklaration vor dem Aufruf. Signatur muss exakt zur\n'
    'Definition passen. */\n'
    'static BOOL texture_upload_queue(struct texture_entry *entry, const D3DCOLOR *palette);\n'
    '#endif\n'
)


def patch_xbox_textures(src_root):
    path = os.path.join(src_root, "port", "linux", "src", "xbox_textures.c")
    if not os.path.exists(path):
        print(f"  WARNUNG: {path} nicht gefunden - ueberspringe.")
        return False
    with open(path) as f:
        text = f.read()
    if TEX_MARKER in text:
        print("  xbox_textures.c: Forward-Deklaration bereits vorhanden.")
        return True
    # korrigierter patch_texture_prewarm.py setzt sie bereits — dann reicht's
    if "static BOOL texture_upload_queue(struct texture_entry *entry, const D3DCOLOR *palette);" in text[:4096]:
        print("  xbox_textures.c: Forward-Deklaration bereits durch patch_texture_prewarm.py gesetzt.")
        return True
    if TEX_ANCHOR not in text:
        print("  WARNUNG: xbox_textures.c-Anker '#include <stdio.h>' fehlt - ueberspringe.")
        return False
    text = text.replace(TEX_ANCHOR, TEX_DECL, 1)
    with open(path, "w") as f:
        f.write(text)
    print("  xbox_textures.c: Forward-Deklaration fuer texture_upload_queue eingefuegt.")
    return True


def apply_patch(src_root):
    print("== Patch: Forward-Deklarationen (C99) ==")
    ok = patch_d3d8_gl(src_root)
    patch_xbox_textures(src_root)  # optional, nicht kritisch
    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    apply_patch(sys.argv[1] if len(sys.argv) > 1 else ".")
