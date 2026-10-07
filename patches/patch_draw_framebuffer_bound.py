#!/usr/bin/env python3
"""
Behebt den GL_INVALID_OPERATION-Fehler beim End-of-Frame-Discard.

Der Knulli-Patch fügt in D3DDevice_Present (d3d8_gl.c) einen
glInvalidateFramebuffer-Aufruf ein, der die Depth/Stencil-Attachments
des Game-Framebuffers nennt. Wenn der Window-Framebuffer (0) gebunden
ist, ist das ein GL_INVALID_OPERATION. Der Knulli-GL-Thread hat diesen
Fehler mit seinem health_check gefunden.

Der Fix: Der Discard läuft nur, wenn ein Game-Framebuffer gebunden ist
(draw_framebuffer_bound). Auf einem tiled GPU (Mali) spart das
zusätzlich einen Load/Store der Window-Kacheln.

Zwei Änderungen in port/linux/src/d3d8_gl.c:
  1. draw_framebuffer_bound() einfügen (static, direkt vor
     D3DDevice_Present).
  2. Den glInvalidateFramebuffer-Block mit if (draw_framebuffer_bound())
     umschließen.

Idempotent.
"""
import os
import re
import sys


BOUND_FUNCTION = '''/* (port/knulli): whether a game framebuffer (not the window's, 0) is
bound for drawing. The Knulli GL thread's health check found the
end-of-frame depth/stencil discard naming the game framebuffer's
attachments while the window's was bound: a GL_INVALID_OPERATION the
driver swallowed, and on a tiled GPU (Mali) a wasted load/store of the
window's tiles. */
static int draw_framebuffer_bound(void)
{
	GLint framebuffer = 0;

	glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &framebuffer);
	return framebuffer != 0;
}

'''


NEW_DISCARD = '''#ifdef HALO_ANDROID
		if (draw_framebuffer_bound())
		{
			/* the frame's depth and stencil are done with: a tiled GPU then
			does not write them out to memory at the end of the pass. Only
			with a game framebuffer bound: the window's own framebuffer
			names no depth/stencil attachment of a game target, and naming
			them while it is bound is a GL_INVALID_OPERATION (found by the
			Knulli GL thread's health check). */
			static const GLenum depth_stencil[] = { GL_DEPTH_ATTACHMENT, GL_STENCIL_ATTACHMENT };

			glInvalidateFramebuffer(GL_DRAW_FRAMEBUFFER, 2, depth_stencil);
		}
#endif'''


OLD_DISCARD_REGEX = re.compile(
    r'#ifdef HALO_ANDROID\s*\n'
    r'\s*\{\s*\n'
    r"\s*/\* the frame's depth and stencil are done with:.*?\*/\s*\n"
    r'\s*static const GLenum depth_stencil\[\] = \{[^}]*\};\s*\n'
    r'\s*glInvalidateFramebuffer\(GL_DRAW_FRAMEBUFFER, 2, depth_stencil\);\s*\n'
    r'\s*\}\s*\n'
    r'\s*#endif',
    re.DOTALL,
)


def apply_patch(src_root):
    print("== Patch 11: draw_framebuffer_bound (GL_INVALID_OPERATION-Fix) ==")
    path = os.path.join(src_root, "port", "linux", "src", "d3d8_gl.c")
    if not os.path.exists(path):
        print(f"FEHLER: {path} nicht gefunden", file=sys.stderr)
        sys.exit(1)
    with open(path) as f:
        text = f.read()

    if "draw_framebuffer_bound" in text and "if (draw_framebuffer_bound())" in text:
        print("d3d8_gl.c: draw_framebuffer_bound bereits vorhanden – überspringe.")
        return

    # 1) draw_framebuffer_bound() vor D3DDevice_Present einfügen
    if "static int draw_framebuffer_bound(void)" not in text:
        anchor = "void WINAPI D3DDevice_Present(CONST RECT *source_rectangle, CONST RECT *destination_rectangle,"
        if anchor not in text:
            print("FEHLER: D3DDevice_Present-Anker nicht gefunden", file=sys.stderr)
            sys.exit(1)
        text = text.replace(anchor, BOUND_FUNCTION + anchor, 1)
        print("d3d8_gl.c: draw_framebuffer_bound() eingefügt.")

    # 2) glInvalidateFramebuffer-Block umschließen
    if "if (draw_framebuffer_bound())" not in text:
        m = OLD_DISCARD_REGEX.search(text)
        if not m:
            print("FEHLER: glInvalidateFramebuffer-Block nicht gefunden.", file=sys.stderr)
            sys.exit(1)
        text = text[:m.start()] + NEW_DISCARD + text[m.end():]
        print("d3d8_gl.c: End-of-Frame-Discard mit draw_framebuffer_bound() umschlossen.")
    else:
        print("d3d8_gl.c: End-of-Frame-Discard war schon umschlossen.")

    with open(path, "w") as f:
        f.write(text)
    print("d3d8_gl.c: draw_framebuffer_bound fertig.")


if __name__ == "__main__":
    apply_patch(sys.argv[1] if len(sys.argv) > 1 else ".")
