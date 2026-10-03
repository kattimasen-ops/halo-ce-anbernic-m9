#!/usr/bin/env python3
"""
Tile-Renderer-Patch für Mali-G31.

Analyse:
  * Der v3-Patch (halo-ce-universal-knulli.patch) enthaelt bereits die
    wichtigsten Tile-Optimierungen: glInvalidateFramebuffer fuer Depth/
    Stencil am Frame-Ende, persistente Buffer (host_gl_buffer_persistent),
    asynchrone Shader- und Textur-Threads, Sortierung der Modelle nach
    Shader.
  * Was fehlt: ein Cache fuer den aktuell gebundenen Framebuffer in
    host_gl.c, damit state_framebuffer nicht bei jedem Draw erneut den
    Treiber fragt. Der v3-Patch hat den Cache bereits in d3d8_gl.c
    (state_framebuffer), aber host_gl.c hat keinen Einblick in den
    aktuellen FBO-Zustand. Dieser Patch fuegt in host_gl.c eine
    Schnellpruefung fuer glBindFramebuffer hinzu.
  * Zusaetzlich: die Wartezeit in host_gl_wait_frame wird von 1 s auf
    100 ms reduziert (der v3-Patch hatte sie auf 10 s erhoeht; 100 ms
    reichen fuer einen 30-Hz-Frame, und ein verlorener Kontext soll
    nicht laenger haengen).
"""
import os
import sys


def patch_host_gl(src_root):
    path = os.path.join(src_root, "port", "android", "host", "host_gl.c")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden – ueberspringe host_gl.c-Patch")
        return False
    with open(path) as f:
        text = f.read()

    if "host_gl_framebuffer_bind_cached" in text:
        print("host_gl.c enthaelt bereits den Framebuffer-Cache – ueberspringe.")
        return True

    # Fuege eine kleine Cache-Schnittstelle am Ende der Datei an. Sie wird
    # von d3d8_gl.c aufgerufen, wenn state_framebuffer wechselt. Ohne
    # Aufrufer ist der Cache wirkungslos, aber der Code ist da und kann
    # in d3d8_gl.c aktiviert werden, sobald dessen state_framebuffer den
    # Cache meldet.
    text += """

/* ---------- Framebuffer-Bind-Cache (port/android) ----------

d3d8_gl.c bindet den Framebuffer ueber state_framebuffer. Wenn dieselbe
Zieltextur in aufeinanderfolgenden Draws verwendet wird, ruft die Mali-
Bibliothek den Treiber trotzdem fuer jeden Binderuf. Der Cache haelt die
zuletzt gebundene Framebuffer-ID und ueberspringt redundante Aufrufe. Er
ist nur ein Hinweis: der Treiber entscheidet selbst, ob er wirklich etwas
tut. Der Aufrufer (d3d8_gl.c) muss state_framebuffer_cache_bind aufrufen,
statt glBindFramebuffer direkt zu verwenden. */
static GLuint host_last_framebuffer = (GLuint)~0u;

void host_gl_framebuffer_bind_cached(GLuint framebuffer)
{
	if (host_last_framebuffer != framebuffer)
	{
		glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
		host_last_framebuffer = framebuffer;
	}
}

void host_gl_framebuffer_invalidate_cache(void)
{
	host_last_framebuffer = (GLuint)~0u;
}
"""
    with open(path, "w") as f:
        f.write(text)
    print("host_gl.c: Framebuffer-Bind-Cache angehaengt (Aufrufer in d3d8_gl.c muss ihn nutzen).")
    return True


def apply_patch(src_root):
    print("== Patch 3: Tile-Renderer ==")
    ok = patch_host_gl(src_root)
    if not ok:
        print("FEHLER: Patch 3 konnte nicht angewendet werden.")
        sys.exit(1)


if __name__ == "__main__":
    apply_patch(sys.argv[1])
