#!/usr/bin/env python3
"""patch_credits.py — "St0len-One" als Credits/Wasserzeichen.

main.c wird immer gepatcht; port_settings.py nur, wenn sie existiert.
Der Patch prueft nach der Aenderung mit py_compile, ob port_settings.py
noch gueltiges Python ist. Falls nicht, wird die Datei unveraendert
gelassen und der Nutzer sieht einen klaren Fehler.
"""
import os
import py_compile
import sys
import tempfile

CREDITS = "St0len-One"

# main.c: die beiden Versions-Strings
MAIN_C_VERSIONS = [
    (
        '"halobeta xbox 01.01.14.2342 Jan 14 2002 12:49:20"',
        f'"halobeta xbox 01.01.14.2342 Jan 14 2002 12:49:20 | {CREDITS}"',
    ),
    (
        '"halobeta xbox 01.01.14.2342 built at: Jan 14 2002 12:49:20"',
        f'"halobeta xbox 01.01.14.2342 built at: Jan 14 2002 12:49:20 | {CREDITS}"',
    ),
]

# Wasserzeichen-Widget-Definition (wird in jede XML-Datei vor </menus>
# eingefuegt, damit jeder Screen das Widget kennt).
WATERMARK_WIDGET_LINES = [
    '\t<widget name="main_menu/credits_watermark" type="text" controller="1" '
    'left="480" top="456" width="150" height="20" '
    f'text="{CREDITS}" font="ui\\\\small_ui" color="#60FFFFFF" '
    'align="right" text_y="5" text_flags="no_focus_test">',
    '\t</widget>',
]

# Die vollstaendige Zeile in _screen, die den options_menu-Child hinzufuegt.
# Sie endet mit "'])": schliesst die innere Liste und den _widget-Aufruf.
# WICHTIG: Diese Zeile enthaelt beide fuehrenden und schliessenden Quotes,
# damit die Ersetzung zwei gueltige Python-Zeilen ergibt.
SCREEN_CHILDREN_ANCHOR = (
    "f'<child{attributes([(\"widget\", f\"{base}/options_menu\")])}/>'])"
)
SCREEN_CHILDREN_NEW = (
    "f'<child{attributes([(\"widget\", f\"{base}/options_menu\")])}/>',\n"
    "                      '<child widget=\"main_menu/credits_watermark\"/>'])"
)

# In settings_files(): das Wasserzeichen-Widget vor </menus> einfuegen.
FILES_RETURN_ANCHOR = (
    '<menus>", *lines, "</menus>", ""] for name, lines in files.items()}'
)
FILES_RETURN_NEW = (
    '<menus>", *lines, *WATERMARK_WIDGET_LINES, "</menus>", ""] '
    'for name, lines in files.items()}'
)


def find_port_settings(src_root):
    candidates = [
        os.path.join(src_root, "tools", "port_settings.py"),
        os.path.join(src_root, "port", "tools", "port_settings.py"),
        os.path.join(src_root, "port", "linux", "tools", "port_settings.py"),
        os.path.join(src_root, "port", "pc", "tools", "port_settings.py"),
        os.path.join(src_root, "port", "windows", "tools", "port_settings.py"),
    ]
    for p in candidates:
        if os.path.exists(p):
            return p
    return None


def patch_main_c(src_root):
    path = os.path.join(src_root, "source", "main", "main.c")
    if not os.path.exists(path):
        print(f"  WARNUNG: {path} nicht gefunden.")
        return
    with open(path) as f:
        text = f.read()
    if CREDITS in text:
        print("  main.c: Credits schon vorhanden - ueberspringe.")
        return
    changed = 0
    for old, new in MAIN_C_VERSIONS:
        if old in text:
            text = text.replace(old, new, 1)
            changed += 1
            print(f"  main.c: Version-String gepatcht.")
    if changed:
        with open(path, "w") as f:
            f.write(text)


def patch_port_settings(src_root):
    path = find_port_settings(src_root)
    if not path:
        print("  HINWEIS: port_settings.py nicht gefunden (Upstream ohne CE-Menus).")
        print("           Wasserzeichen im In-Game-Menue wird nicht eingebaut.")
        return
    with open(path) as f:
        text = f.read()
    if "credits_watermark" in text:
        print("  port_settings.py: Wasserzeichen schon vorhanden.")
        return

    # 1. WATERMARK_WIDGET_LINES-Konstante einfuegen (vor SCREENS = {).
    widget_block = (
        "\n"
        "# Wasserzeichen (patch_credits.py): in jedem generierten Menue.\n"
        "WATERMARK_WIDGET_LINES = [\n"
        + "".join(f"    {line!r},\n" for line in WATERMARK_WIDGET_LINES)
        + "]\n\n"
    )
    screens_anchor = "SCREENS = {"
    if screens_anchor not in text:
        print("  WARNUNG: SCREENS-Anker nicht gefunden.")
        return
    text = text.replace(screens_anchor, widget_block + screens_anchor, 1)

    # 2. Die options_menu-Zeile in _screen um den Wasserzeichen-Child erweitern.
    if SCREEN_CHILDREN_ANCHOR not in text:
        print("  WARNUNG: options_menu-Anker in _screen nicht gefunden.")
        print(f"           Anker: {SCREEN_CHILDREN_ANCHOR!r}")
        return
    text = text.replace(SCREEN_CHILDREN_ANCHOR, SCREEN_CHILDREN_NEW, 1)
    print("  - Wasserzeichen-Child in _screen eingefuegt.")

    # 3. In settings_files(): WATERMARK_WIDGET_LINES zurueckgeben.
    if FILES_RETURN_ANCHOR not in text:
        print("  WARNUNG: settings_files-Return-Anker nicht gefunden.")
        return
    text = text.replace(FILES_RETURN_ANCHOR, FILES_RETURN_NEW, 1)
    print("  - Wasserzeichen-Definition in settings_files eingefuegt.")

    # 4. Sicherheitspruefung: port_settings.py muss gueltiges Python sein.
    with tempfile.NamedTemporaryFile(mode="w", suffix=".py", delete=False) as tmp:
        tmp.write(text)
        tmp_path = tmp.name
    try:
        py_compile.compile(tmp_path, doraise=True)
    except py_compile.PyCompileError as e:
        print(f"  FEHLER: gepatchte port_settings.py hat Syntaxfehler:")
        print(f"          {e}")
        print(f"  Lasse port_settings.py unveraendert.")
        os.unlink(tmp_path)
        return
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)

    # 5. Wenn alles sauber ist: schreiben.
    with open(path, "w") as f:
        f.write(text)
    print("  port_settings.py: Wasserzeichen eingebaut (Child + Definition).")


def apply_patch(src_root):
    print("== Patch: Credits 'St0len-One' ==")
    patch_main_c(src_root)
    patch_port_settings(src_root)
    print("  Fertig.")


if __name__ == "__main__":
    apply_patch(sys.argv[1] if len(sys.argv) > 1 else ".")
