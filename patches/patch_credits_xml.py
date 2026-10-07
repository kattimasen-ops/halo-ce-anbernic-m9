#!/usr/bin/env python3
"""patch_credits_xml.py — Wasserzeichen "St0len-One" in statische Menue-XMLs.

Fuegt in jedes Menue-XML unter port/assets/menus/ce/ ein Wasserzeichen-
Widget unten rechts ein und haengt eine Child-Referenz an das erste
Screen-Widget der Datei (Widget, dessen Name auf "_screen" endet).

Laeuft NACH dem Regenerieren der Settings-Screens.
Idempotent.
"""
import os
import re
import sys

CREDITS = "St0len-One"

WATERMARK_DEF = (
    '\t<widget name="main_menu/credits_watermark" type="text" controller="1" '
    'left="480" top="456" width="150" height="20" '
    f'text="{CREDITS}" font="ui\\\\small_ui" color="#60FFFFFF" '
    'align="right" text_y="5" text_flags="no_focus_test">\n'
    '\t</widget>'
)
WATERMARK_CHILD = '<child widget="main_menu/credits_watermark"/>'

# Findet ein Screen-Widget (<widget name="..._screen" ...>) und fuegt
# vor seinem schliessenden </widget> das Wasserzeichen-Kind ein.
SCREEN_WIDGET_RE = re.compile(
    r'(<widget\s+name="[^"]*_screen"[^>]*>)'  # der Oeffnungs-Tag
    r'(.*?)'                                    # Inhalt
    r'(\n\t</widget>)',                         # schliessender Tag auf Spalten-Ebene
    re.DOTALL,
)


def add_watermark(path):
    with open(path) as f:
        text = f.read()
    if "credits_watermark" in text:
        return False
    if "</menus>" not in text:
        return False

    # 1. Wasserzeichen-Widget-Definition vor </menus>
    text = text.replace("</menus>", WATERMARK_DEF + "\n</menus>", 1)

    # 2. In jedes Screen-Widget die Child-Referenz einfuegen.
    def add_child(match):
        open_tag, body, close_tag = match.group(1), match.group(2), match.group(3)
        if WATERMARK_CHILD in body:
            return match.group(0)
        return open_tag + body + "\n\t\t" + WATERMARK_CHILD + close_tag

    text = SCREEN_WIDGET_RE.sub(add_child, text)

    with open(path, "w") as f:
        f.write(text)
    return True


def apply_patch(src_root):
    print("== Patch: Credits-Wasserzeichen in statische Menue-XMLs ==")
    menus_dir = os.path.join(src_root, "port", "assets", "menus", "ce")
    if not os.path.isdir(menus_dir):
        print(f"WARNUNG: {menus_dir} fehlt - ueberspringe.")
        return
    count = 0
    for root, _, files in os.walk(menus_dir):
        for name in files:
            if not name.endswith(".xml"):
                continue
            path = os.path.join(root, name)
            if add_watermark(path):
                rel = os.path.relpath(path, menus_dir)
                print(f"  + Wasserzeichen: {rel}")
                count += 1
    if count == 0:
        print("  (keine neuen Dateien; entweder schon gepatcht oder keine Menues da.)")


if __name__ == "__main__":
    apply_patch(sys.argv[1] if len(sys.argv) > 1 else ".")
