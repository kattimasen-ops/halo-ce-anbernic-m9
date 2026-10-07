#!/usr/bin/env python3
"""Erweitert tools/port_settings.py um 13 neue Video-Settings-Zeilen.

Ohne Anpassung der Button-Bar-Position wuerde button_bar bei y=414 kleben
und die neuen Zeilen (y=361+) ueberlappen. Der Patch setzt deshalb
"button_top" im video_settings-Spec und laesst _screen den Wert aus dem
Spec lesen.

Wird von build.sh nach dem Knulli-Patch angewendet. Danach regeneriert
build.sh die XML-Dateien aus port_settings.py.
"""
import os
import sys


NEW_ROWS = """            ("FAST SHADERS:", "display.fast_shaders", ON_OFF,
             "Compute colours in half precision, which Mali\\nGPUs do at twice the rate.", "android"),
            ("FAST TEXTURES:", "display.fast_textures", ON_OFF,
             "Give DXT1 and 16-bit textures to the GPU as\\n16-bit texels, halving memory and bandwidth.", "android"),
            ("MODEL DETAIL:", "display.model_detail",
             [("0.25", "0.25"), ("0.35", "0.35"), ("0.5", "0.5"), ("0.75", "0.75"), ("1.0", "1.0")],
             "How early objects switch to simpler models,\\nas a fraction of the size the game switches at.", "android"),
            ("RENDER SCALE:", "display.render_scale",
             [("0.5", "0.5"), ("0.625", "0.625"), ("0.75", "0.75"), ("0.875", "0.875"), ("1.0", "1.0")],
             "The picture's resolution as a fraction of the\\nscreen's: below 1.0 the GPU draws fewer pixels.", "android"),
            ("DYNAMIC RESOLUTION:", "display.dynamic_resolution", ON_OFF,
             "Lower the resolution a step at a time while\\nthe GPU falls behind, and raise it when it keeps up.", "android"),
            ("FRAME PACING:", "display.frame_pacing", ON_OFF,
             "Show each frame at the display refresh it was\\ndrawn for, holding one ready early.", "android"),
            ("SORT MODELS:", "debug.sort_models", ON_OFF,
             "Draw objects' models sorted by shader,\\nrather than object by object.", "android"),
            ("ASYNC TEXTURES:", "debug.async_textures", ON_OFF,
             "Decode and upload textures on a thread of\\ntheir own, drawing with them once they are in.", "android"),
            ("ASYNC SHADERS:", "debug.async_shaders", ON_OFF,
             "Translate shaders on a thread of their own,\\ndrawing with them once they are in.", "android"),
            ("INSTANCE MODELS:", "debug.instance_models", ON_OFF,
             "Draw consecutive draws of the same model part\\nthat differ only in constants as one.", "android"),
            ("BATCH QUADS:", "debug.batch_quads", ON_OFF,
             "Draw consecutive quad draws of the same state\\n(decals) as one.", "android"),
            ("STABLE STREAMS:", "debug.stable_streams", ON_OFF,
             "Point indexed draws' attributes at their base\\nvertex, so draws from one buffer share them.", "android"),
            ("ALPHA TEST ELISION:", "debug.alpha_test_elision", ON_OFF,
             "Draw without the alpha test when it cannot fail,\\nkeeping Mali's hidden surface removal.", "android"),
"""

VIDEO_SPEC_ANCHOR = '''    "video_settings": {
        "screen": "video_settings_screen",
        "header": ("header_profile_video_settings", f"{PE}/video_settings/header_profile_video_settings"),
        # (closer than the other screens' rows, and the help lower, for all
        # twelve places to fit above it)
        "spacing": 24,
        "help_top": 364,
'''

VIDEO_SPEC_NEW = '''    "video_settings": {
        "screen": "video_settings_screen",
        "header": ("header_profile_video_settings", f"{PE}/video_settings/header_profile_video_settings"),
        # (closer than the other screens' rows, and the help lower, for all
        # twelve places to fit above it; button_top weiter unten, seit die
        # Port-eigenen Zeilen darunter stehen)
        "spacing": 24,
        "help_top": 364,
        "button_top": 750,
'''

SCREEN_ANCHOR = '''    children.append(f'<child{attributes([("widget", f"{base}/button_bar"), ("y", 414)])}/>')'''
SCREEN_NEW = '''    children.append(f'<child{attributes([("widget", f"{base}/button_bar"), ("y", spec.get("button_top", 414))])}/>')'''


def apply_patch(src_root):
    print("== Patch: In-Game-Settings-Menue erweitern ==")
    path = os.path.join(src_root, "tools", "port_settings.py")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden - ueberspringe.")
        return

    with open(path) as f:
        text = f.read()

    if "display.fast_shaders" in text:
        print("port_settings.py: neue Video-Rows bereits vorhanden - ueberspringe.")
        return

    # 1. Neue Rows einfuegen (der Knulli-Patch hat PER-PIXEL LIGHTING auf
    # "desktop" gesetzt; ohne Patch steht dort noch None).
    anchors = [
        '            ("PER-PIXEL LIGHTING:", "display.per_pixel_lighting", ON_OFF,\n'
        '             "Light models for each pixel, without the facets\\nof the Xbox\'s lighting for each vertex.", "desktop"),\n',
        '            ("PER-PIXEL LIGHTING:", "display.per_pixel_lighting", ON_OFF,\n'
        '             "Light models for each pixel, without the facets\\nof the Xbox\'s lighting for each vertex.", None),\n',
    ]
    inserted = False
    for anchor in anchors:
        if anchor in text:
            text = text.replace(anchor, anchor + NEW_ROWS, 1)
            inserted = True
            break
    if not inserted:
        print("FEHLER: PER-PIXEL LIGHTING-Anker nicht gefunden.", file=sys.stderr)
        sys.exit(1)
    print("  - 13 neue Video-Rows eingefuegt.")

    # 2. button_top im video_settings-Spec ergaenzen.
    if "button_top" not in text:
        if VIDEO_SPEC_ANCHOR not in text:
            print("FEHLER: video_settings-Spec-Anker nicht gefunden.", file=sys.stderr)
            sys.exit(1)
        text = text.replace(VIDEO_SPEC_ANCHOR, VIDEO_SPEC_NEW, 1)
        print("  - button_top im video_settings-Spec ergaenzt.")
    else:
        print("  - button_top bereits vorhanden.")

    # 3. _screen: button_top aus dem Spec lesen.
    if 'spec.get("button_top", 414)' not in text:
        if SCREEN_ANCHOR not in text:
            print("FEHLER: _screen-button_bar-Anker nicht gefunden.", file=sys.stderr)
            sys.exit(1)
        text = text.replace(SCREEN_ANCHOR, SCREEN_NEW, 1)
        print("  - _screen liest jetzt button_top aus dem Spec.")
    else:
        print("  - _screen verwendet bereits button_top.")

    with open(path, "w") as f:
        f.write(text)
    print("port_settings.py: fertig.")


if __name__ == "__main__":
    apply_patch(sys.argv[1] if len(sys.argv) > 1 else ".")
