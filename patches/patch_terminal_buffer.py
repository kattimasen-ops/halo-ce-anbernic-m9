#!/usr/bin/env python3
"""patch_terminal_buffer.py — vergroessert den Puffer in terminal_printf.

Problem:
  In Halo CE's terminal.c verwendet terminal_printf einen festen Puffer
  von 256 Zeichen. Manche Skript-Ereignisse (z. B. "den Kapitaen retten"
  am Ende von "Pillar of Autumn") erzeugen eine Debug-Meldung mit mehr
  als 256 Zeichen. Die Engine erkennt den Overflow und ruft
  EXCEPTION_HALT auf — das Spiel stuerzt ab.

Loesung:
  Den Puffer in terminal_printf auf 1024 Zeichen vergroessern. Andere
  Puffer in derselben Datei bleiben unangetastet, damit das Verhalten
  des Spiels an anderer Stelle nicht veraendert wird.

Idempotent ueber den Marker 'terminal_buffer_patch'.
"""
import os
import re
import sys


MARKER = "terminal_buffer_patch"
NEW_SIZE = 1024
OLD_SIZES = (256, 512)  # alles, was kleiner als 1024 ist und ueblicherweise dort steht


def patch_terminal(src_root):
    path = os.path.join(src_root, "source", "interface", "terminal.c")
    if not os.path.exists(path):
        print(f"FEHLER: {path} nicht gefunden.", file=sys.stderr)
        return 1

    with open(path) as f:
        text = f.read()

    if MARKER in text:
        print("  terminal.c: Puffer bereits vergroessert.")
        return 0

    # 1. terminal_printf-Funktion finden.
    #    Es gibt mehrere Definitionen (terminal_printf, terminal_printf_va,
    #    console_printf); wir suchen die erste Definition von terminal_printf.
    match = re.search(
        r'(?:^|\n)(?:void|short|long|int)\s+terminal_printf\s*\([^)]*\)\s*\n?\{',
        text)
    if not match:
        print("  WARNUNG: terminal_printf() in terminal.c nicht gefunden.")
        print("  Der Puffer kann nicht gezielt gesetzt werden.")
        return 1

    # 2. Innerhalb des Funktionsblocks nach dem Puffer suchen.
    #    Wir nehmen an, dass terminal_printf den Puffer in den ersten ~500
    #    Zeichen nach dem Funktionsanfang deklariert.
    block_start = match.start()
    block_end = min(len(text), block_start + 4000)
    block = text[block_start:block_end]

    buffer_match = re.search(
        r'(char\s+buffer\s*\[\s*)(\d+)(\s*\])',
        block, re.IGNORECASE)
    if not buffer_match:
        print("  WARNUNG: kein char buffer[N] in terminal_printf gefunden.")
        print("  Bitte die Datei manuell pruefen.")
        return 1

    old_size = int(buffer_match.group(2))
    if old_size >= NEW_SIZE:
        print(f"  terminal.c: Puffer ist bereits {old_size} Zeichen gross.")
        return 0

    # 3. Ersetzen (nur an dieser einen Stelle).
    new_buffer = f"{buffer_match.group(1)}{NEW_SIZE}{buffer_match.group(3)}"
    new_block = block[:buffer_match.start()] + new_buffer + block[buffer_match.end():]
    new_text = text[:block_start] + new_block + text[block_end:]

    # 4. Marker einfuegen (vor der Funktion, damit der Patch idempotent ist).
    marker_comment = (
        f"/* {MARKER}: terminal_printf's buffer raised from "
        f"{old_size} to {NEW_SIZE} chars (patch_terminal_buffer.py) */\n"
    )
    new_text = new_text[:block_start] + marker_comment + new_text[block_start:]

    with open(path, "w") as f:
        f.write(new_text)
    print(f"  terminal.c: Puffer von {old_size} auf {NEW_SIZE} Zeichen vergroessert.")
    return 0


def apply_patch(src_root):
    print("== Patch: terminal_printf Puffer ==")
    rc = patch_terminal(src_root)
    print("== Fertig." if rc == 0 else "== Fertig (mit Warnungen).")
    # Kein exit(1): der Build soll weiterlaufen, auch wenn der Patch nicht
    # griff. Der Fehler ist ein Laufzeit-Bug, kein Build-Blocker.
    return 0


if __name__ == "__main__":
    apply_patch(sys.argv[1] if len(sys.argv) > 1 else ".")
