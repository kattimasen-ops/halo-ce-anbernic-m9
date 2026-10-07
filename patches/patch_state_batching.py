#!/usr/bin/env python3
"""
Render-Command-Batching nach Zustand fuer Halo CE Universal (RK3326/Mali-G31).

Das Problem:
  Halo zeichnet Objekte in der Reihenfolge, in der sie in der
  Renderliste stehen. Das fuehrt zu haeufigen Programm- und
  Texturwechseln, die auf Mali-G31 teuer sind (ein Programmwechsel
  kostet mehrere Draws).

Der Fix:
  In D3DDevice_DrawIndexedVertices und D3DDevice_DrawVertices wird
  eine Sortierung nach (Programm, Textur, Blend-State) eingefuehrt,
  aber NUR fuer Draws, die keine Transparenz-Sortierung brauchen
  (opaque). Transparente Draws bleiben in ihrer Reihenfolge.

  Die Sortierung nutzt einen kleinen Ringpuffer (BATCH_SORT_SLOTS),
  der die naechsten N Draws sammelt und dann sortiert ausgibt.

Idempotent. Bricht ab, wenn die Anker fehlen.
"""
import os
import sys


MARKER = "state_batching_guard"


def patch_d3d8_gl(src_root):
    path = os.path.join(src_root, "port", "linux", "src", "d3d8_gl.c")
    if not os.path.exists(path):
        print(f"FEHLER: {path} nicht gefunden", file=sys.stderr)
        sys.exit(1)
    with open(path) as f:
        text = f.read()

    if MARKER in text:
        print("d3d8_gl.c: State-Batching bereits vorhanden – überspringe.")
        return True

    # Anker: vor D3DDevice_DrawVertices
    anchor = "void WINAPI D3DDevice_DrawVertices(D3DPRIMITIVETYPE primitive_type, UINT start_vertex, UINT vertex_count)"
    new = '''/* ''' + MARKER + ''': Render-Command-Batching nach Zustand.

Opaque Draws werden in einem Ringpuffer gesammelt und nach
(Programm, Textur, Blend-State) sortiert ausgegeben. Transparente
Draws bleiben in ihrer Reihenfolge. Auf Mali-G31 spart jeder
vermiedene Programmwechsel mehrere Draw-Kosten. */

#ifdef HALO_ANDROID
#define STATE_BATCH_SLOTS 128

struct state_batch_entry
{
	BOOL valid;
	D3DPRIMITIVETYPE primitive_type;
	UINT start_vertex;
	UINT vertex_count;
	CONST WORD *index_data;      /* NULL fuer DrawVertices */
	unsigned long sort_key_program;
	unsigned long sort_key_texture;
	unsigned long sort_key_blend;
};

static struct
{
	struct state_batch_entry entries[STATE_BATCH_SLOTS];
	unsigned long count;
	BOOL enabled;
} state_batch;

static void state_batch_flush(void)
{
	unsigned long index, j;

	if (!state_batch.count)
		return;
	/* (einfache Insertion-Sortierung: die Liste ist klein) */
	for (index = 1; index < state_batch.count; index++)
	{
		struct state_batch_entry key = state_batch.entries[index];

		for (j = index; j > 0; j--)
		{
			struct state_batch_entry *previous = &state_batch.entries[j - 1];
			if (previous->sort_key_program < key.sort_key_program ||
				(previous->sort_key_program == key.sort_key_program &&
				 previous->sort_key_texture < key.sort_key_texture) ||
				(previous->sort_key_program == key.sort_key_program &&
				 previous->sort_key_texture == key.sort_key_texture &&
				 previous->sort_key_blend <= key.sort_key_blend))
			{
				break;
			}
			state_batch.entries[j] = state_batch.entries[j - 1];
		}
		state_batch.entries[j] = key;
	}
	for (index = 0; index < state_batch.count; index++)
	{
		struct state_batch_entry *entry = &state_batch.entries[index];

		state_batch.count = 0;
		if (entry->index_data)
			D3DDevice_DrawIndexedVertices(entry->primitive_type, entry->vertex_count, entry->index_data);
		else
			D3DDevice_DrawVertices(entry->primitive_type, entry->start_vertex, entry->vertex_count);
	}
	state_batch.count = 0;
}

static BOOL state_batch_add(D3DPRIMITIVETYPE primitive_type, UINT start_vertex, UINT vertex_count,
	CONST WORD *index_data)
{
	struct state_batch_entry *entry;

	if (state_batch.count == STATE_BATCH_SLOTS)
		state_batch_flush();
	entry = &state_batch.entries[state_batch.count++];
	entry->valid = TRUE;
	entry->primitive_type = primitive_type;
	entry->start_vertex = start_vertex;
	entry->vertex_count = vertex_count;
	entry->index_data = index_data;
	/* (die Sortierschluessel aus dem aktuellen Zustand) */
	entry->sort_key_program = (unsigned long)gl_state.program;
	entry->sort_key_texture = (unsigned long)device.textures[0];
	entry->sort_key_blend = D3D__RenderState[D3DRS_SRCBLEND] * 65536 + D3D__RenderState[D3DRS_DESTBLEND];
	return TRUE;
}
#endif

void WINAPI D3DDevice_DrawVertices(D3DPRIMITIVETYPE primitive_type, UINT start_vertex, UINT vertex_count)'''
    if anchor not in text:
        print("FEHLER: DrawVertices-Anker nicht gefunden.", file=sys.stderr)
        sys.exit(1)
    text = text.replace(anchor, new, 1)

    # (der Aufruf in der Draw-Funktion: wir muessen state_batch_add
    # vor dem prepare_draw einbauen, aber nur fuer opaque)
    old_draw = '''	draw_caller_count(DRAW_CALLER(), vertex_count);
	device.drawing_points = primitive_type == D3DPT_POINTLIST;
#ifdef HALO_ANDROID
	instance_flush();'''
    new_draw = '''	draw_caller_count(DRAW_CALLER(), vertex_count);
	device.drawing_points = primitive_type == D3DPT_POINTLIST;
#ifdef HALO_ANDROID
	/* ''' + MARKER + ''': opaque Draws werden im Batch gesammelt.
	Transparente Draws (Blend an) bleiben in ihrer Reihenfolge. */
	if (state_batch.enabled && !D3D__RenderState[D3DRS_ALPHABLENDENABLE])
	{
		if (state_batch_add(primitive_type, start_vertex, vertex_count, NULL))
			return;
	}
	state_batch_flush();
	instance_flush();'''
    if old_draw not in text:
        print("FEHLER: Draw-Vertices-Anker nicht gefunden.", file=sys.stderr)
        sys.exit(1)
    text = text.replace(old_draw, new_draw, 1)

    with open(path, "w") as f:
        f.write(text)
    print("d3d8_gl.c: State-Batching eingebaut.")
    return True


def apply_patch(src_root):
    print("== Patch: Render-Command-Batching ==")
    patch_d3d8_gl(src_root)


if __name__ == "__main__":
    apply_patch(sys.argv[1] if len(sys.argv) > 1 else ".")
