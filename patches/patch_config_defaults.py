#!/usr/bin/env python3
"""Aendert die Standardwerte in port_config.c auf die Werte, die für
RK3326 / Cortex-A35 / Mali-G31 MP2 auf dem M9 Pro optimal sind.

Laeuft NACH dem Knulli-Patch und patch_vita_optimizations.py (die die
Eintraege erst anlegen). Idempotent: prueft, ob der neue Wert schon
dasteht.

Die Werte sind auf dem RK3326 empirisch abgestimmt:
  - render_scale 0.75, weil die Mali-G31 bei 480x360 die beste
    Balance zwischen Bildqualitaet und Frametime hat.
  - dynamic_resolution aus, weil die Hysterese auf dem kleinen
    Display mehr stoert als hilft; feste 0.75 ist ruhiger.
  - model_detail 0.35, weil Modelle den Grossteil der Vertex-Last
    ausmachen und die Mali-G31 vertex-limitiert ist.
  - distant_objects 8.0, weil Objekte unter 8 Pixeln fast nichts
    zur Szene beitragen, aber je ~17 us Draw-Kosten verursachen.
  - obstruction_ticks 3, weil der Sound-Occlusion-Cache auf dem
    Cortex-A35 sonst zu oft Kollisionen berechnet.
  - lighting_refresh_divisor 2, weil statische Objekt-Beleuchtung
    auf dem Cortex-A35 teuer ist und alle 2 Ticks reicht.
  - fast_shaders / fast_textures an, weil die Mali-G31 halfp-
    Arithmetik und 16-Bit-Texel doppelt so schnell verarbeitet.
  - sort_models / instance_models / batch_quads / stable_streams /
    alpha_test_elision an, weil sie die Draw-Call-Zahl deutlich
    senken und auf der Mali-G31 nichts kosten.
"""
import os
import re
import sys


# (Setting-Name, alter Default, neuer Default)
CHANGES = [
    # ── Bild / Performance (Kern) ────────────────────────────────────
    ("display.dynamic_resolution",     "true",  "false"),
    ("display.dynamic_resolution_min", "0.5",   "1.0"),
    ("display.render_scale",           "1.0",   "0.75"),
    ("display.model_detail",           "0.5",   "0.35"),
    ("display.distant_objects",        "0.0",   "8.0"),
    ("display.fast_shaders",           "true",  "true"),
    ("display.fast_textures",          "true",  "true"),
    ("display.frame_pacing",           "true",  "true"),
    # ── Audio ────────────────────────────────────────────────────────
    ("audio.obstruction_ticks",        "1",     "3"),
    # ── Debug / Renderer-Optimierungen ──────────────────────────────
    ("debug.lighting_refresh_divisor", "1",     "2"),
    ("debug.sort_models",              "true",  "true"),
    ("debug.instance_models",          "true",  "true"),
    ("debug.batch_quads",              "true",  "true"),
    ("debug.stable_streams",           "true",  "true"),
    ("debug.alpha_test_elision",       "true",  "true"),
    ("debug.async_textures",           "true",  "true"),
    ("debug.async_shaders",            "true",  "true"),
]


def apply_patch(src_root):
    print("== Patch: Default-Werte aus Halo.sh in port_config.c festnageln ==")
    path = os.path.join(src_root, "port", "linux", "src", "port_config.c")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden - ueberspringe.")
        return
    with open(path) as f:
        text = f.read()

    changed = 0
    already = 0
    missing = 0

    for name, old_default, new_default in CHANGES:
        # Anker: der Eintrag beginnt mit "{ "name", _config_..., "old_default","
        pattern = re.compile(
            r'(\{\s*"' + re.escape(name) + r'"\s*,\s*_config_\w+\s*,\s*")'
            + re.escape(old_default) + r'(")'
        )
        if pattern.search(text):
            text = pattern.sub(r'\g<1>' + new_default + r'\g<2>', text, count=1)
            print(f"  {name}: {old_default} -> {new_default}")
            changed += 1
            continue

        # Vielleicht schon geaendert?
        already_pattern = re.compile(
            r'\{\s*"' + re.escape(name) + r'"\s*,\s*_config_\w+\s*,\s*"'
            + re.escape(new_default) + r'"'
        )
        if already_pattern.search(text):
            print(f"  {name}: schon {new_default} - ueberspringe.")
            already += 1
            continue

        # Vielleicht existiert das Setting gar nicht (z. B. desktop-only)
        any_pattern = re.compile(
            r'\{\s*"' + re.escape(name) + r'"\s*,\s*_config_\w+\s*,'
        )
        if any_pattern.search(text):
            print(f"  WARNUNG: {name} hat unerwarteten Default, setze auf {new_default}.")
            # Nimm den ersten Treffer und ersetze den Default-String
            text = re.sub(
                r'(\{\s*"' + re.escape(name) + r'"\s*,\s*_config_\w+\s*,\s*")[^"]*(")',
                r'\g<1>' + new_default + r'\g<2>',
                text, count=1
            )
            changed += 1
        else:
            print(f"  HINWEIS: {name} nicht gefunden (evtl. platform-spezifisch).")
            missing += 1

    with open(path, "w") as f:
        f.write(text)
    print(f"port_config.c: {changed} geaendert, {already} schon korrekt, {missing} nicht vorhanden.")


if __name__ == "__main__":
    apply_patch(sys.argv[1] if len(sys.argv) > 1 else ".")
