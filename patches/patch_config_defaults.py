#!/usr/bin/env python3
"""Aendert die Standardwerte in port_config.c auf die Werte, die bisher
Halo.sh als HALO_*-Umgebungsvariablen gesetzt hat.

Laeuft NACH dem Knulli-Patch und patch_vita_optimizations.py (die die
Eintraege erst anlegen). Idempotent: prueft, ob der neue Wert schon
dasteht.
"""
import os
import re
import sys


# (Setting-Name, alter Default, neuer Default) - nur Werte, die vom
# bisherigen Halo.sh-Export ueberschrieben wurden und daher neu
# festgenagelt werden muessen.
CHANGES = [
    ("display.dynamic_resolution",     "true", "false"),
    ("display.dynamic_resolution_min", "0.5",  "1.0"),
    ("display.model_detail",           "0.5",  "0.35"),
    ("audio.obstruction_ticks",        "1",    "3"),
    ("display.distant_objects",        "0.0",  "8.0"),
    ("debug.lighting_refresh_divisor", "1",    "2"),
]


def apply_patch(src_root):
    print("== Patch: Default-Werte aus Halo.sh in port_config.c festnageln ==")
    path = os.path.join(src_root, "port", "linux", "src", "port_config.c")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden - ueberspringe.")
        return
    with open(path) as f:
        text = f.read()

    for name, old_default, new_default in CHANGES:
        # Anker: der Eintrag beginnt mit "{ "name", _config_..., "old_default","
        pattern = re.compile(
            r'(\{\s*"' + re.escape(name) + r'"\s*,\s*_config_\w+\s*,\s*")'
            + re.escape(old_default) + r'(")'
        )
        if not pattern.search(text):
            # Vielleicht schon geaendert?
            already = re.compile(
                r'\{\s*"' + re.escape(name) + r'"\s*,\s*_config_\w+\s*,\s*"'
                + re.escape(new_default) + r'"'
            )
            if already.search(text):
                print(f"  {name}: schon {new_default} - ueberspringe.")
                continue
            print(f"  WARNUNG: {name} nicht gefunden (Anker fehlt).")
            continue
        text = pattern.sub(r'\g<1>' + new_default + r'\g<2>', text, count=1)
        print(f"  {name}: {old_default} -> {new_default}")

    with open(path, "w") as f:
        f.write(text)
    print("port_config.c: Defaults angepasst.")


if __name__ == "__main__":
    apply_patch(sys.argv[1] if len(sys.argv) > 1 else ".")
