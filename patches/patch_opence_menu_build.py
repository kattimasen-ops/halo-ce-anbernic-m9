#!/usr/bin/env python3
"""patch_opence_menu_build.py — registriert Expat + Menü-Dateien in den Builds.

Modifiziert:
  tools/linux_build.py    — EXPAT_DIR, -I{EXPAT_DIR}, Expat-Objekte
  tools/android_build.py  — dasselbe für den Android-Guest
  tools/embed_assets.py   — Bettet port/assets/menus/menus.json mit ein
  port/linux/port.json    — fügt "dl" zu libraries hinzu

Idempotent über Marker-Kommentare.
"""
import json
import os
import re
import sys

MARKER = "port: opence-menu"


def patch_linux_build(path):
    with open(path) as f:
        text = f.read()
    if MARKER in text:
        print("  linux_build.py: bereits gepatcht.")
        return
    # 1. EXPAT_DIR nach TOML_DIR
    anchor = 'TOML_DIR = Path("port/third_party/tomlc17")\n'
    add = anchor + (
        '# ' + MARKER + ': XML-Parser für port/linux/src/menu_files.c\n'
        'EXPAT_DIR = Path("port/third_party/expat")\n'
        'EXPAT_SOURCES = ("xmlparse.c", "xmlrole.c", "xmltok.c")\n'
    )
    if anchor not in text:
        print("FEHLER: TOML_DIR-Anker in linux_build.py fehlt.", file=sys.stderr)
        sys.exit(1)
    text = text.replace(anchor, add, 1)
    # 2. -I{EXPAT_DIR} in platform_cflags
    anchor = 'f"-I{TOML_DIR}",\n'
    if anchor in text:
        text = text.replace(anchor, anchor + '            f"-I{EXPAT_DIR}",\n', 1)
    # 3. Expat-Objekte kompilieren
    anchor = '        add_object(TOML_DIR / "tomlc17.c", " ".join([abi, "-std=gnu11", "-w"]))\n'
    add = anchor + (
        '        # ' + MARKER + ': Expat\n'
        '        for name in EXPAT_SOURCES:\n'
        '            add_object(EXPAT_DIR / name, " ".join([abi, "-std=gnu11", f"-I{EXPAT_DIR}", "-w"]))\n'
    )
    if anchor in text:
        text = text.replace(anchor, add, 1)
    with open(path, "w") as f:
        f.write(text)
    print("  linux_build.py gepatcht.")


def patch_android_build(path):
    with open(path) as f:
        text = f.read()
    if MARKER in text:
        print("  android_build.py: bereits gepatcht.")
        return
    anchor = 'TOML_DIR = Path("port/third_party/tomlc17")\n'
    add = anchor + (
        '# ' + MARKER + ': XML-Parser für port/linux/src/menu_files.c\n'
        'EXPAT_DIR = Path("port/third_party/expat")\n'
        'EXPAT_SOURCES = ("xmlparse.c", "xmlrole.c", "xmltok.c")\n'
    )
    if anchor not in text:
        print("FEHLER: TOML_DIR-Anker in android_build.py fehlt.", file=sys.stderr)
        sys.exit(1)
    text = text.replace(anchor, add, 1)
    # -I{EXPAT_DIR} in platform_cflags
    anchor = 'f"-I{TOML_DIR}",'
    if anchor in text:
        text = text.replace(anchor, anchor + ' f"-I{EXPAT_DIR}",', 1)
    # Expat-Objekte
    anchor = '    objects.append(guest_object(TOML_DIR / "tomlc17.c", platform_cflags))\n'
    add = anchor + (
        '    # ' + MARKER + ': Expat\n'
        '    for name in EXPAT_SOURCES:\n'
        '        objects.append(guest_object(EXPAT_DIR / name, platform_cflags))\n'
    )
    if anchor in text:
        text = text.replace(anchor, add, 1)
    with open(path, "w") as f:
        f.write(text)
    print("  android_build.py gepatcht.")


def patch_embed_assets(path):
    with open(path) as f:
        text = f.read()
    if MARKER in text:
        print("  embed_assets.py: bereits gepatcht.")
        return
    anchor = 'FONT_LIST = FONT_ASSETS / "fonts.json"\n'
    add = anchor + (
        '# ' + MARKER + ': die Menü-Dateien (tools/ce_menus.py schreibt sie)\n'
        'MENU_ASSETS = Path("port/assets/menus")\n'
        'MENU_LIST = MENU_ASSETS / "menus.json"\n'
    )
    if anchor not in text:
        print("FEHLER: FONT_LIST-Anker in embed_assets.py fehlt.", file=sys.stderr)
        sys.exit(1)
    text = text.replace(anchor, add, 1)
    # menu_files-Funktion + Einbettung sind umfangreicher; dieser Patch
    # fügt nur den Marker und die Konstanten ein. Der eigentliche
    # Einbettungs-Code ist bereits in OpenCEs embed_assets.py — wir
    # ersetzen die ganze Datei einfach durch die OpenCE-Version.
    # (Siehe Kommentar im build.sh-Fetch-Teil.)
    with open(path, "w") as f:
        f.write(text)
    print("  embed_assets.py: Marker gesetzt (echte Einbettung folgt aus OpenCE-Kopie).")


def patch_port_json(path):
    with open(path) as f:
        data = json.load(f)
    libs = data.get("libraries", [])
    if "dl" not in libs:
        libs.append("dl")
        data["libraries"] = libs
        with open(path, "w") as f:
            json.dump(data, f, indent=2)
        print("  port.json: dl hinzugefügt.")


def apply_patch(src_root):
    print("== Patch: OpenCE-Menü-Build-Registrierung ==")
    patch_linux_build(os.path.join(src_root, "tools", "linux_build.py"))
    patch_android_build(os.path.join(src_root, "tools", "android_build.py"))
    patch_port_json(os.path.join(src_root, "port", "linux", "port.json"))
    # embed_assets.py durch OpenCE-Version ersetzen — der Patch macht das
    # nicht, weil die Datei zu viele Änderungen hat. Stattdessen wird sie
    # in build.sh aus dem OpenCE-Clone kopiert.


if __name__ == "__main__":
    apply_patch(sys.argv[1] if len(sys.argv) > 1 else ".")
