#!/usr/bin/env python3
"""patch_config_changes.py — ergaenzt config_changes() im Knulli-Port.

Die OpenCE-Version von hud_hires.c (die build.sh aus dem OpenCE-Repo
kopiert) ruft config_changes() auf, um zu erkennen, ob sich
display.high_res_hud geaendert hat. Der Knulli-Port kennt diese
Funktion nicht; der Compiler bricht mit

    error: call to undeclared function 'config_changes'

ab. Dieses Skript:

  1. Fuegt die Implementierung in port/linux/src/port_config.c ein
     (Zaehler + Getter, der bei jedem config_write inkrementiert wird).
  2. Fuegt eine extern-Deklaration direkt in port/linux/src/hud_hires.c
     ein, unmittelbar vor der ersten Verwendung.

Idempotent ueber Marker-Kommentare.
"""
import os
import re
import sys


MARKER_IMPL = "settings_only: config_changes_impl"
MARKER_HUD = "settings_only: config_changes_hud"


def patch_port_config(src_root):
    path = os.path.join(src_root, "port", "linux", "src", "port_config.c")
    if not os.path.exists(path):
        print(f"FEHLER: {path} nicht gefunden.", file=sys.stderr)
        sys.exit(1)
    with open(path) as f:
        text = f.read()
    if MARKER_IMPL in text:
        print("  port_config.c: config_changes() bereits vorhanden.")
        return

    impl = (
        "\n\n"
        f"/* {MARKER_IMPL} — OpenCE-Plattformfunktion.\n"
        "   Zaehlt Schreibzugriffe auf die Konfiguration; die OpenCE-Version\n"
        "   von hud_hires.c vergleicht den Zaehler mit dem Zeitpunkt des\n"
        "   letzten Einlesens, um display.high_res_hud zu erkennen.\n"
        "   Startwert 1, damit der erste Vergleich (read_at == 0) den\n"
        "   Reload-Block betritt. */\n"
        "static unsigned long config_change_counter = 1;\n"
        "unsigned long config_changes(void)\n"
        "{\n"
        "\treturn config_change_counter;\n"
        "}\n"
    )
    text = text.rstrip() + impl

    # Inkrement in config_write einfuegen (falls vorhanden).
    pattern = re.compile(
        r"^[ \t]*(?:void|int|BOOL|boolean)\s+config_write\s*\([^)]*\)\s*\n?[ \t]*\{",
        re.MULTILINE)
    m = pattern.search(text)
    if m:
        insert_at = m.end()
        increment = (
            f"\n\t/* {MARKER_IMPL} */\n"
            "\tconfig_change_counter++;\n"
        )
        text = text[:insert_at] + increment + text[insert_at:]
        print("  port_config.c: config_write inkrementiert config_changes().")
    else:
        print("  HINWEIS: config_write nicht gefunden.")
        print("           config_changes() bleibt konstant; die HUD-Texturen")
        print("           laden einmalig, ein Wechsel von display.high_res_hud")
        print("           zur Laufzeit loest keinen Reload aus.")

    with open(path, "w") as f:
        f.write(text)
    print("  port_config.c: config_changes() eingebaut.")


def patch_hud_hires(src_root):
    path = os.path.join(src_root, "port", "linux", "src", "hud_hires.c")
    if not os.path.exists(path):
        print(f"FEHLER: {path} nicht gefunden.", file=sys.stderr)
        sys.exit(1)
    with open(path) as f:
        text = f.read()
    if MARKER_HUD in text:
        print("  hud_hires.c: Deklaration bereits vorhanden.")
        return

    # Wir fuegen die Deklaration nach dem letzten #include-Block ein,
    # aber vor der ersten Verwendung (Zeile mit config_changes()).
    first_use = text.find("config_changes()")
    if first_use == -1:
        print("  WARNUNG: kein config_changes()-Aufruf in hud_hires.c gefunden.")
        return
    head = text[:first_use]
    last_include_end = 0
    for m in re.finditer(r"^#include [^\n]+\n", head, re.MULTILINE):
        last_include_end = m.end()
    decl = (
        f"\n/* {MARKER_HUD} — OpenCE-Plattformfunktion, in port_config.c\n"
        "   implementiert. */\n"
        "unsigned long config_changes(void);\n"
    )
    if last_include_end:
        text = text[:last_include_end] + decl + text[last_include_end:]
    else:
        text = decl + text
    with open(path, "w") as f:
        f.write(text)
    print("  hud_hires.c: extern-Deklaration eingefuegt.")


def apply_patch(src_root):
    print("== Patch: config_changes() fuer den Knulli-Port ==")
    patch_port_config(src_root)
    patch_hud_hires(src_root)
    print("== Fertig.")


if __name__ == "__main__":
    apply_patch(sys.argv[1] if len(sys.argv) > 1 else ".")
