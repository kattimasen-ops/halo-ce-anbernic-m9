#!/usr/bin/env python3
"""
Tile-Renderer-Patch für Mali-G31.

Zwei Änderungen in port/linux/src/d3d8_gl.c:

  1. framebuffer_get: Die Funktion sucht bei jedem Draw den passenden
     Framebuffer in einer verketteten Liste. Bei aufeinanderfolgenden
     Draws mit denselben Render-Targets (typisch in einer Szene) ist das
     eine lineare Suche mit mehreren Cache-Misses. Ein Ein-Element-Cache
     fuer (color, depth) -> framebuffer spart die Suche.

  2. render_target_get: derselbe Ansatz fuer die Render-Target-Suche.
     Der Bucket ist eine kurze Liste, aber der Aufruf erfolgt zweimal
     pro Draw (color + depth), und die Suche nach der zur Oberflaeche
     passenden Textur vergleicht vier Felder. Ein Zwei-Element-Cache
     (letzter color, letzter depth) deckt die haeufigen Faelle ab.
"""
import os
import sys


def patch_d3d8_gl(src_root):
    path = os.path.join(src_root, "port", "linux", "src", "d3d8_gl.c")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden – ueberspringe d3d8_gl.c-Patch")
        return False
    with open(path) as f:
        text = f.read()

    if "last_framebuffer_color" in text:
        print("d3d8_gl.c enthaelt bereits den Framebuffer-Cache – ueberspringe.")
        return True

    old = """static GLuint framebuffer_get(GLuint color, GLuint depth)
{
	struct framebuffer_entry *entry;
	GLenum draw_buffer = color ? GL_COLOR_ATTACHMENT0 : GL_NONE;

	for (entry = framebuffers; entry; entry = entry->next)
	{
		if (entry->color == color && entry->depth == depth)
			return entry->framebuffer;
	}
	entry = calloc(1, sizeof(*entry));
	entry->color = color;
	entry->depth = depth;
	glGenFramebuffers(1, &entry->framebuffer);
	glBindFramebuffer(GL_FRAMEBUFFER, entry->framebuffer);
	if (color)
		glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, color, 0);
	if (depth)
		glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, depth, 0);
	glDrawBuffers(1, &draw_buffer);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
		platform_log("framebuffer %u/%u is incomplete", color, depth);
	xgpu_gl_state_invalidate();
	entry->next = framebuffers;
	framebuffers = entry;
	return entry->framebuffer;
}"""
    new = """static GLuint framebuffer_get(GLuint color, GLuint depth)
{
	/* (port/android, Mali-G31): Ein-Element-Cache fuer die zuletzt
	   gebundene (color, depth)-Kombination. Consecutive Draws derselben
	   Szene wechseln den Framebuffer nicht; die Suche durch die ge-
	   kettete Liste (mit mehreren Cache-Misses) entfaellt dann. */
	static GLuint last_color = 0, last_depth = 0, last_framebuffer = 0;
	struct framebuffer_entry *entry;
	GLenum draw_buffer = color ? GL_COLOR_ATTACHMENT0 : GL_NONE;

	if (last_framebuffer && last_color == color && last_depth == depth)
		return last_framebuffer;

	for (entry = framebuffers; entry; entry = entry->next)
	{
		if (entry->color == color && entry->depth == depth)
		{
			last_color = color;
			last_depth = depth;
			last_framebuffer = entry->framebuffer;
			return entry->framebuffer;
		}
	}
	entry = calloc(1, sizeof(*entry));
	entry->color = color;
	entry->depth = depth;
	glGenFramebuffers(1, &entry->framebuffer);
	glBindFramebuffer(GL_FRAMEBUFFER, entry->framebuffer);
	if (color)
		glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, color, 0);
	if (depth)
		glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, depth, 0);
	glDrawBuffers(1, &draw_buffer);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
		platform_log("framebuffer %u/%u is incomplete", color, depth);
	xgpu_gl_state_invalidate();
	entry->next = framebuffers;
	framebuffers = entry;
	last_color = color;
	last_depth = depth;
	last_framebuffer = entry->framebuffer;
	return entry->framebuffer;
}"""
    if old not in text:
        print("WARNUNG: framebuffer_get nicht gefunden – ueberspringe.")
        return False
    text = text.replace(old, new, 1)
    print("d3d8_gl.c: Framebuffer-Cache in framebuffer_get eingebaut.")

    # render_target_get Cache
    old_rt = """	for (entry = *render_target_bucket(surface->Data); entry; entry = entry->next_in_bucket)
	{
		if (entry->target.data == surface->Data && entry->target.width == width &&
			entry->target.height == height && entry->target.depth == depth &&
			entry->target.scale[0] == scale[0] && entry->target.scale[1] == scale[1])
		{
			return entry;
		}
	}"""
    new_rt = """	{
		/* (port/android): letzter Treffer als Cache. bind_targets ruft
		   render_target_get zweimal pro Draw auf (color + depth); in
		   einer Szene wechseln die Targets selten, also ist der
		   Ein-Element-Cache fast immer ein Treffer. */
		static struct render_target_entry *last_hit = NULL;
		static unsigned long last_hit_data = 0, last_hit_w = 0, last_hit_h = 0;
		static BOOL last_hit_depth = FALSE;
		static float last_hit_sx = 1.0f, last_hit_sy = 1.0f;

		if (last_hit && last_hit_data == surface->Data && last_hit_w == width &&
			last_hit_h == height && last_hit_depth == depth &&
			last_hit_sx == scale[0] && last_hit_sy == scale[1])
		{
			return last_hit;
		}
		for (entry = *render_target_bucket(surface->Data); entry; entry = entry->next_in_bucket)
		{
			if (entry->target.data == surface->Data && entry->target.width == width &&
				entry->target.height == height && entry->target.depth == depth &&
				entry->target.scale[0] == scale[0] && entry->target.scale[1] == scale[1])
			{
				last_hit = entry;
				last_hit_data = surface->Data;
				last_hit_w = width;
				last_hit_h = height;
				last_hit_depth = depth;
				last_hit_sx = scale[0];
				last_hit_sy = scale[1];
				return entry;
			}
		}
	}"""
    if old_rt in text:
        text = text.replace(old_rt, new_rt, 1)
        print("d3d8_gl.c: Render-Target-Cache in render_target_get eingebaut.")
    else:
        print("WARNUNG: render_target_get-Suche nicht gefunden – ueberspringe.")

    with open(path, "w") as f:
        f.write(text)
    return True


def apply_patch(src_root):
    print("== Patch 3: Tile-Renderer ==")
    ok = patch_d3d8_gl(src_root)
    if not ok:
        print("FEHLER: Patch 3 konnte nicht angewendet werden.")
        sys.exit(1)


if __name__ == "__main__":
    apply_patch(sys.argv[1])
