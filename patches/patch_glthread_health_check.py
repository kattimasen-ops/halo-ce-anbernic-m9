#!/usr/bin/env python3
"""
Fügt dem GL-Thread einen health_check hinzu (HALO_GL_HEALTH_CHECK=1).

Der GL-Thread replayed GL-Aufrufe in den Mali-Treiber. Ohne eine
regelmäßige glGetError-Prüfung bleiben Fehler wie GL_INVALID_OPERATION
unentdeckt. Der health_check läuft nur, wenn die Umgebungsvariable
HALO_GL_HEALTH_CHECK gesetzt ist, weil glGetError den Treiber zwingt,
auf die GPU zu warten.

Änderungen in port/knulli/host/host_glthread.c:
  1. draw_framebuffer_bound() und health_check() einfügen (nach den
     Includes, vor gl_thread_main).
  2. gl_thread_main: health_check() nach glthread_replay() aufrufen.

Ist die Datei nicht vorhanden (weil port/knulli nicht kopiert wurde),
gibt das Skript eine Warnung aus und kehrt zurück; es bricht den Build
nicht ab.

Idempotent.
"""
import os
import sys


HEALTH_FUNCTION = '''/* ---------- health check (HALO_GL_HEALTH_CHECK) and draw framebuffer bound

The GL thread replays the guest's GL calls. A wrong call (an attachment
named while another framebuffer is bound, a state the driver refuses)
leaves a GL error the guest never sees, and on a tiled GPU (Mali) it also
wastes a load or a store. HALO_GL_HEALTH_CHECK=1 drains the error queue
after each call and logs what it finds; it is off by default, because
glGetError forces the driver to wait for the GPU.

draw_framebuffer_bound tells whether the drawing target is a game
framebuffer (not the window's own, name 0): the end-of-frame
depth/stencil discard in d3d8_gl.c names game attachments, which is a
GL_INVALID_OPERATION while the window's is bound. */

static int draw_framebuffer_bound(void)
{
\tGLint framebuffer = 0;

\tglGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &framebuffer);
\treturn framebuffer != 0;
}

static int health_check_enabled = -1;

static void health_check(void)
{
\tGLenum error;

\tif (health_check_enabled < 0)
\t\thealth_check_enabled = getenv("HALO_GL_HEALTH_CHECK") != NULL;
\tif (!health_check_enabled)
\t\treturn;
\twhile ((error = glGetError()) != GL_NO_ERROR)
\t\thost_logf(HOST_LOG_WARN, "GL error %04x", (unsigned)error);
}

'''


def apply_patch(src_root):
    print("== Patch 12: GL-Thread health_check (HALO_GL_HEALTH_CHECK) ==")
    path = os.path.join(src_root, "port", "knulli", "host", "host_glthread.c")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden – überspringe health_check-Patch.")
        print("         (port/knulli/host/host_glthread.c ist in deinem Repo nicht vorhanden;")
        print("          das Kopieren des port/knulli-Verzeichnisses muss vor Fix 4 passieren.)")
        return
    with open(path) as f:
        text = f.read()

    if "static void health_check(void)" in text and "static int draw_framebuffer_bound(void)" in text:
        print("host_glthread.c: health_check + draw_framebuffer_bound bereits vorhanden – überspringe.")
        return

    # 1) Funktionen vor gl_thread_main einfügen
    if "static void health_check(void)" not in text or "static int draw_framebuffer_bound(void)" not in text:
        anchor = "static void *gl_thread_main(void *unused)"
        if anchor not in text:
            print("FEHLER: gl_thread_main-Anker nicht gefunden", file=sys.stderr)
            sys.exit(1)
        text = text.replace(anchor, HEALTH_FUNCTION + anchor, 1)
        print("host_glthread.c: health_check + draw_framebuffer_bound eingefügt.")

    # 2) health_check() nach glthread_replay im _command_call-Block aufrufen
    if "health_check();" not in text:
        old = "\t\t\t\tglthread_replay(command->function, command + 1);\n"
        new = "\t\t\t\tglthread_replay(command->function, command + 1);\n\t\t\t\thealth_check();\n"
        if old not in text:
            print("FEHLER: glthread_replay-Aufruf nicht gefunden", file=sys.stderr)
            sys.exit(1)
        text = text.replace(old, new, 1)
        print("host_glthread.c: health_check() nach glthread_replay aufgerufen.")

    with open(path, "w") as f:
        f.write(text)
    print("host_glthread.c: health_check fertig.")


if __name__ == "__main__":
    apply_patch(sys.argv[1] if len(sys.argv) > 1 else ".")
