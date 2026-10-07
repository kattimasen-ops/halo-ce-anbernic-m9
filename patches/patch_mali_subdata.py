#!/usr/bin/env python3
"""
Mali-G31-Mirror-Subdata-Schutz für Halo CE Universal (RK3326 / Cortex-A35).

Hintergrund (H700-Referenz, hardware-verifiziert auf Mali-G31):
  Mali kann bei glBufferSubData den kompletten Buffer intern kopieren,
  wenn bereits GPU-Draws auf diesen Buffer warten. Ein anschließender
  schneller Host-Write (host_gl_buffer_write, mapped memory) in dasselbe
  Segment kollidiert dann mit dem noch laufenden internen Copy. Im
  H700-Port sichtbar als "stick figures" bei Marines nach A30/B30.

Fix:
  1. Jedes Mirror-Segment bekommt einen Frame-Zeitstempel
     (mirror.subdata_frame[segment]).
  2. Bei der ersten Buffer-Erzeugung wird der Stempel auf
     device.frame - STREAM_BUFFER_RING gesetzt (sofort schreibbar).
  3. Der schnelle Host-Write-Pfad wird nur benutzt, wenn seit dem
     letzten glBufferSubData in dieses Segment mindestens
     STREAM_BUFFER_RING Frames vergangen sind; sonst glBufferSubData.
  4. Nach jedem glBufferSubData wird der Stempel aktualisiert.

Idempotent. Bricht ab, wenn die Anker fehlen.
"""
import os
import re
import sys


MARKER = "mali_subdata_guard"


def patch_d3d8_gl(src_root):
    path = os.path.join(src_root, "port", "linux", "src", "d3d8_gl.c")
    if not os.path.exists(path):
        print(f"FEHLER: {path} nicht gefunden", file=sys.stderr)
        sys.exit(1)
    with open(path) as f:
        text = f.read()

    if "subdata_frame" in text and MARKER in text:
        print("d3d8_gl.c: Mali-Subdata-Schutz bereits vorhanden – überspringe.")
        return True

    # ── 1. Struct-Feld hinzufügen ────────────────────────────────────
    struct_anchor = (
        "	unsigned long rewritten_frame[MIRROR_PAGE_COUNT];\n"
        "} mirror;"
    )
    struct_new = (
        "	unsigned long rewritten_frame[MIRROR_PAGE_COUNT];\n"
        "#ifdef HALO_ANDROID\n"
        "	/* " + MARKER + ": das Frame, in dem zuletzt ein glBufferSubData\n"
        "	in dieses Segment ging (Mali-G31 macht daraus einen internen\n"
        "	Copy ueber mehrere Frames, mit dem ein schneller Host-Write\n"
        "	nicht kollidieren darf). */\n"
        "	unsigned long subdata_frame[MIRROR_SEGMENT_COUNT];\n"
        "#endif\n"
        "} mirror;"
    )
    if struct_anchor not in text:
        print("FEHLER: mirror-Struktur-Anker nicht gefunden.", file=sys.stderr)
        sys.exit(1)
    text = text.replace(struct_anchor, struct_new, 1)
    print("d3d8_gl.c: mirror.subdata_frame[] hinzugefuegt.")

    # ── 2. Initialisierung bei der Buffer-Erzeugung ──────────────────
    init_anchor = (
        "			glBindBuffer(GL_COPY_WRITE_BUFFER, mirror.buffers[segment]);\n"
        "			glBufferData(GL_COPY_WRITE_BUFFER, MIRROR_SEGMENT_SIZE, NULL, GL_DYNAMIC_DRAW);\n"
        "		}"
    )
    init_new = (
        "			glBindBuffer(GL_COPY_WRITE_BUFFER, mirror.buffers[segment]);\n"
        "			glBufferData(GL_COPY_WRITE_BUFFER, MIRROR_SEGMENT_SIZE, NULL, GL_DYNAMIC_DRAW);\n"
        "#ifdef HALO_ANDROID\n"
        "			/* " + MARKER + ": der erste Write in dieses frische\n"
        "			Segment darf sofort schnell sein. */\n"
        "			mirror.subdata_frame[segment] = device.frame - STREAM_BUFFER_RING;\n"
        "#endif\n"
        "		}"
    )
    if init_anchor not in text:
        print("FEHLER: Buffer-Erzeugungs-Anker nicht gefunden.", file=sys.stderr)
        sys.exit(1)
    text = text.replace(init_anchor, init_new, 1)
    print("d3d8_gl.c: subdata_frame-Initialisierung eingefuegt.")

    # ── 3. Guard in der Upload-Auswahl ───────────────────────────────
    # Wir ersetzen die exakte if (unused)-Bedingung inklusive des
    # nachfolgenden #else/#endif-Bereichs, um die Stempel-Aktualisierung
    # in den Slow-Path zu legen (sie läuft in beiden Fällen: nur der
    # schnelle Pfad continue-t; der langsame fällt durch).
    guard_anchor = (
        "#ifdef HALO_ANDROID\n"
        "		/* Mali copies the whole buffer for a glBufferSubData that queued\n"
        "		draws might read (see STREAM_BUFFER_RING); unused pages can be\n"
        "		written without waiting for them */\n"
        "		if (unused)\n"
        "		{\n"
        "			host_gl_buffer_write(GL_COPY_WRITE_BUFFER,\n"
        "				(unsigned int)(address - PLATFORM_CONTIGUOUS_BASE - segment * MIRROR_SEGMENT_SIZE),\n"
        "				(unsigned int)size, (const void *)address);\n"
        "			continue;\n"
        "		}\n"
        "#else\n"
        "		(void)unused;\n"
        "#endif\n"
    )
    guard_new = (
        "#ifdef HALO_ANDROID\n"
        "		/* Mali copies the whole buffer for a glBufferSubData that queued\n"
        "		draws might read (see STREAM_BUFFER_RING); unused pages can be\n"
        "		written without waiting for them. " + MARKER + ": der schnelle\n"
        "		Host-Write ist erst dann sicher, wenn seit dem letzten\n"
        "		glBufferSubData in dieses Segment genug Frames vergangen sind,\n"
        "		damit der interne Mali-Copy abgeschlossen ist. */\n"
        "		if (unused &&\n"
        "			device.frame - mirror.subdata_frame[segment] >= STREAM_BUFFER_RING)\n"
        "		{\n"
        "			host_gl_buffer_write(GL_COPY_WRITE_BUFFER,\n"
        "				(unsigned int)(address - PLATFORM_CONTIGUOUS_BASE - segment * MIRROR_SEGMENT_SIZE),\n"
        "				(unsigned int)size, (const void *)address);\n"
        "			continue;\n"
        "		}\n"
        "		mirror.subdata_frame[segment] = device.frame;\n"
        "#else\n"
        "		(void)unused;\n"
        "#endif\n"
    )
    if guard_anchor not in text:
        print("FEHLER: Upload-Guard-Anker nicht gefunden.", file=sys.stderr)
        sys.exit(1)
    text = text.replace(guard_anchor, guard_new, 1)
    print("d3d8_gl.c: Upload-Guard eingebaut.")

    with open(path, "w") as f:
        f.write(text)
    print("d3d8_gl.c: Mali-Subdata-Schutz fertig.")
    return True


def apply_patch(src_root):
    print("== Patch: Mali-G31 Mirror-Subdata-Schutz ==")
    patch_d3d8_gl(src_root)


if __name__ == "__main__":
    apply_patch(sys.argv[1] if len(sys.argv) > 1 else ".")
