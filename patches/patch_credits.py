#!/usr/bin/env python3
"""patch_credits.py — "St0len-One" als Credits/Wasserzeichen.

1. source/main/main.c: die beiden Versions-Strings erhalten
   " | St0len-One".
2. tools/port_settings.py: jeder generierte Settings-Screen erhaelt ein
   Wasserzeichen-Widget unten rechts (halbtransparent weiss).

Laeuft nach dem Knulli-Patch und patch_settings_menu.py.
Idempotent.
"""
import os
import sys

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

# port_settings.py: Wasserzeichen-Widget-Definition und Child-Referenz
WATERMARK_WIDGET_LINES = [
    '\t<widget name="main_menu/credits_watermark" type="text" controller="1" '
    'left="480" top="456" width="150" height="20" '
    f'text="{CREDITS}" font="ui\\\\small_ui" color="#60FFFFFF" '
    'align="right" text_y="5" text_flags="no_focus_test">',
    '\t</widget>',
]
WATERMARK_CHILD_LINE = '\t\t\t\t\t  \'<child widget="main_menu/credits_watermark"/>\'])'

# Anker in port_settings.py
SCREEN_CHILDREN_ANCHOR = 'options_menu")])}/>\'])'
SCREEN_CHILDREN_NEW = (
    'options_menu")])}/>',
    '                      \'<child widget="main_menu/credits_watermark"/>\'])',
)
FILES_RETURN_ANCHOR = '<menus>", *lines, "</menus>", ""] for name, lines in files.items()}'
FILES_RETURN_NEW = '<menus>", *lines, *WATERMARK_WIDGET_LINES, "</menus>", ""] for name, lines in files.items()}'


def patch_main_c(src_root):
    path = os.path.join(src_root, "source", "main", "main.c")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden.")
        return
    with open(path) as f:
        text = f.read()
    if CREDITS in text:
        print("main.c: Credits schon vorhanden - ueberspringe.")
        return
    changed = 0
    for old, new in MAIN_C_VERSIONS:
        if old in text:
            text = text.replace(old, new, 1)
            changed += 1
            print(f"main.c: Version-String gepatcht.")
        else:
            print(f"WARNUNG: Version-String nicht gefunden: {old[:50]}...")
    if changed:
        with open(path, "w") as f:
            f.write(text)


def patch_port_settings(src_root):
    path = os.path.join(src_root, "tools", "port_settings.py")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden.")
        return
    with open(path) as f:
        text = f.read()
    if "credits_watermark" in text:
        print("port_settings.py: Wasserzeichen schon vorhanden - ueberspringe.")
        return

    # 1. Wasserzeichen-Widget-Konstante einfuegen (nach den VOLUMES-Definitionen
    # oder direkt vor SCREENS).
    widget_block = (
        "\n"
        "# Wasserzeichen (patch_credits.py): in jedem generierten Menue.\n"
        "WATERMARK_WIDGET_LINES = [\n"
        + "".join(f"    {line!r},\n" for line in WATERMARK_WIDGET_LINES)
        + "]\n\n"
    )
    anchor = "SCREENS = {"
    if anchor not in text:
        print("WARNUNG: SCREENS-Anker nicht gefunden.")
        return
    text = text.replace(anchor, widget_block + anchor, 1)

    # 2. Screen-Widget: Wasserzeichen-Kind hinzufuegen.
    if SCREEN_CHILDREN_ANCHOR not in text:
        print("WARNUNG: options_menu-Anker in _screen nicht gefunden.")
        return
    replacement = SCREEN_CHILDREN_NEW[0] + ",\n" + SCREEN_CHILDREN_NEW[1]
    text = text.replace(SCREEN_CHILDREN_ANCHOR, replacement, 1)

    # 3. settings_files: Wasserzeichen-Definition in jede Datei.
    if FILES_RETURN_ANCHOR not in text:
        print("WARNUNG: settings_files-Return-Anker nicht gefunden.")
        return
    text = text.replace(FILES_RETURN_ANCHOR, FILES_RETURN_NEW, 1)

    with open(path, "w") as f:
        f.write(text)
    print("port_settings.py: Wasserzeichen eingebaut (Child + Definition).")


def apply_patch(src_root):
    print("== Patch: Credits 'St0len-One' ==")
    patch_main_c(src_root)
    patch_port_settings(src_root)
    print("== Fertig.")


if __name__ == "__main__":
    apply_patch(sys.argv[1] if len(sys.argv) > 1 else ".")
