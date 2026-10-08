#!/usr/bin/env python3
"""
Texture-Prewarming fuer Halo CE Universal (RK3326/Mali-G31).

Fix ggue. dem urspruenglichen Patch:
  texture_upload_queue wird in xbox_textures.c erst NACH
  xgpu_texture_worker_start definiert (im Knulli-Patch unter
  #ifdef HALO_ANDROID). xgpu_texture_prewarm_begin wird direkt nach
  xgpu_texture_worker_start eingefuegt und ruft texture_upload_queue
  auf, ohne dass eine Deklaration sichtbar ist -> C99-Fehler
  "call to undeclared function".

Loesung:
  Forward-Deklaration von texture_upload_queue VOR
  xgpu_texture_prewarm_begin. Die echte Definition
  (static BOOL texture_upload_queue(struct texture_entry *,
  const D3DCOLOR *)) bleibt unveraendert; die Deklaration muss exakt
  dazu passen.

Idempotent. Bricht ab, wenn die Anker fehlen.
"""
import os
import sys

MARKER = "texture_prewarm_guard"

ANCHOR = '''void xgpu_texture_worker_start(void)
{
	pthread_t thread;

	if (config_boolean("debug.async_textures") && pthread_create(&thread, NULL, texture_worker, NULL) == 0)
		pthread_detach(thread);
}'''


def patch_xbox_textures(src_root):
    path = os.path.join(src_root, "port", "linux", "src", "xbox_textures.c")
    if not os.path.exists(path):
        print(f"FEHLER: {path} nicht gefunden", file=sys.stderr)
        sys.exit(1)
    with open(path) as f:
        text = f.read()

    if MARKER in text:
        print("xbox_textures.c: Texture-Prewarming bereits vorhanden – überspringe.")
        return True

    if ANCHOR not in text:
        print("FEHLER: xgpu_texture_worker_start-Anker nicht gefunden.", file=sys.stderr)
        sys.exit(1)

    new = ANCHOR + '''

#ifdef HALO_ANDROID
/* texture_prewarm_guard: Texture-Prewarming beim Map-Load.

Die vorhandenen Texturen in der Cache-Tabelle werden auf einen Schlag in
die Worker-Queue geschoben, sobald die Map geladen ist. Der Worker
dekodiert sie im Hintergrund.

Wichtig: texture_upload_queue wird weiter unten in dieser Datei definiert
(static BOOL texture_upload_queue(struct texture_entry *, const D3DCOLOR *)).
Die Deklaration hier muss exakt zu dieser Definition passen, sonst
meldet clang eine inkompatible Redefinition. */
static BOOL texture_upload_queue(struct texture_entry *entry, const D3DCOLOR *palette);

void xgpu_texture_prewarm_begin(void)
{
	static int prewarmed = 0;
	unsigned long bucket;
	unsigned long queued = 0;

	if (prewarmed)
		return;
	prewarmed = 1;
	if (!__atomic_load_n(&worker_running, __ATOMIC_ACQUIRE))
		return;
	for (bucket = 0; bucket < TEXTURE_BUCKET_COUNT; bucket++)
	{
		struct texture_entry *entry;

		for (entry = texture_buckets[bucket]; entry; entry = entry->next)
		{
			if (!entry->texture || entry->uploading || entry->ready)
				continue;
			if (texture_upload_queue(entry, NULL))
				queued++;
		}
	}
	platform_log("texture prewarm: %lu textures queued", queued);
}
#endif'''
    text = text.replace(ANCHOR, new, 1)

    with open(path, "w") as f:
        f.write(text)
    print("xbox_textures.c: Texture-Prewarming eingebaut (mit Forward-Deklaration).")
    return True


def apply_patch(src_root):
    print("== Patch: Texture-Prewarming ==")
    patch_xbox_textures(src_root)


if __name__ == "__main__":
    apply_patch(sys.argv[1] if len(sys.argv) > 1 else ".")
