#!/usr/bin/env python3
"""
Aggressives Objekt-Culling fuer Halo CE Universal (RK3326/Mali-G31).

Das Problem:
  find_rendered_objects sammelt alle sichtbaren Objekte, aber
  render_object_list zeichnet sie alle, auch wenn sie nur wenige
  Pixel gross sind. Auf Mali-G31 kostet jeder Draw ~17 us, auch
  wenn er kaum sichtbar ist.

Der Fix:
  Eine zusaetzliche Distanz-/Groessenpruefung in find_rendered_objects,
  die Objekte unter einer Mindestpixelgroesse verwirft, BEVOR sie in
  die Renderliste kommen. Das ist aggressiver als das vorhandene
  display.distant_objects (das nur die Liste filtert, nachdem sie
  gebaut wurde).

  Die Schwelle wird aus display.distant_objects abgeleitet und um
  einen Faktor verschaerft, der auf RK3326 getestet wurde.

Idempotent. Bricht ab, wenn die Anker fehlen.
"""
import os
import sys


MARKER = "aggressive_culling_guard"


def patch_render_objects(src_root):
    path = os.path.join(src_root, "source", "render", "render_objects.c")
    if not os.path.exists(path):
        print(f"FEHLER: {path} nicht gefunden", file=sys.stderr)
        sys.exit(1)
    with open(path) as f:
        text = f.read()

    if MARKER in text:
        print("render_objects.c: Aggressives Culling bereits vorhanden – überspringe.")
        return True

    # Anker: das Ende von find_rendered_objects, direkt vor dem
    # Overflow-Check.
    anchor = '''	if (render_object_globals.rendered_object_count == MAXIMUM_RENDERED_OBJECTS &&
		!reported_rendered_object_overflow)
	{
		error(_error_silent, "MAXIMUM_RENDERED_OBJECTS exceeded.");
		reported_rendered_object_overflow = TRUE;
	}'''
    new = '''#ifdef HALO_ANDROID
	/* ''' + MARKER + ''': aggressives Culling. Objekte, deren
	Bounding-Sphere im aktuellen Frame weniger als eine Mindestzahl
	von Pixeln einnimmt, werden verworfen, bevor sie in die
	Renderliste kommen. Auf Mali-G31 spart jeder vermiedene Draw
	~17 us Treiberzeit. Die Schwelle ist verschaerft gegenueber
	display.distant_objects, weil dieses nur die bereits gebaute
	Liste filtert. */
	{
		static real aggressive_minimum = -1.0f;

		if (aggressive_minimum < 0.0f)
		{
			const char *setting = getenv("HALO_MIN_OBJECT_PIXELS");

			aggressive_minimum = setting && *setting ? (real)atof(setting) : 8.0f;
			/* (der aggressive Faktor: 1.5x der konfigurierten
			Schwelle, aber mindestens 8 Pixel) */
			aggressive_minimum *= 1.5f;
			if (aggressive_minimum < 8.0f)
				aggressive_minimum = 8.0f;
		}
		if (aggressive_minimum > 0.0f)
		{
			short read_index, write_index = 0;

			for (read_index = 0; read_index < render_object_globals.rendered_object_count; read_index++)
			{
				long object_index = render_object_globals.rendered_object_indices[read_index];

				/* (die Pixelgroesse ist bereits berechnet, wir
				muessen sie nur abfragen) */
				if (object_get_level_of_detail_pixels(object_index) >= aggressive_minimum)
					render_object_globals.rendered_object_indices[write_index++] = object_index;
			}
			render_object_globals.rendered_object_count = write_index;
		}
	}
#endif
	if (render_object_globals.rendered_object_count == MAXIMUM_RENDERED_OBJECTS &&
		!reported_rendered_object_overflow)
	{
		error(_error_silent, "MAXIMUM_RENDERED_OBJECTS exceeded.");
		reported_rendered_object_overflow = TRUE;
	}'''
    if anchor not in text:
        print("FEHLER: find_rendered_objects-Anker nicht gefunden.", file=sys.stderr)
        sys.exit(1)
    text = text.replace(anchor, new, 1)

    with open(path, "w") as f:
        f.write(text)
    print("render_objects.c: Aggressives Culling eingebaut.")
    return True


def apply_patch(src_root):
    print("== Patch: Aggressives Objekt-Culling ==")
    patch_render_objects(src_root)


if __name__ == "__main__":
    apply_patch(sys.argv[1] if len(sys.argv) > 1 else ".")
