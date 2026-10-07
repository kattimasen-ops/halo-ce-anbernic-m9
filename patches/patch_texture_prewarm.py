#!/usr/bin/env python3
"""
Texture-Prewarming fuer Halo CE Universal (RK3326/Mali-G31).

Das Problem:
  Der Texture-Worker dekodiert Texturen asynchron, aber die erste
  Textur einer Map wird immer noch im Gameplay hochgeladen, was zu
  einem Spike fuehrt.

Der Fix:
  Beim Map-Load werden alle Texturen, die in den Tags der Map
  referenziert werden, in die Upload-Queue des Workers geschoben.
  Der Worker dekodiert sie im Hintergrund, waehrend die Map schon
  spielbar ist.

Idempotent. Bricht ab, wenn die Anker fehlen.
"""
import os
import sys


MARKER = "texture_prewarm_guard"


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

    # Anker: nach xgpu_texture_worker_start
    anchor = '''void xgpu_texture_worker_start(void)
{
	pthread_t thread;

	if (config_boolean("debug.async_textures") && pthread_create(&thread, NULL, texture_worker, NULL) == 0)
		pthread_detach(thread);
}'''
    new = '''void xgpu_texture_worker_start(void)
{
	pthread_t thread;

	if (config_boolean("debug.async_textures") && pthread_create(&thread, NULL, texture_worker, NULL) == 0)
		pthread_detach(thread);
}

#ifdef HALO_ANDROID
/* ''' + MARKER + ''': Texture-Prewarming beim Map-Load.

Die vorhandenen Texturen in der Cache-Tabelle werden auf einen
Schlag in die Worker-Queue geschoben, sobald die Map geladen ist.
Der Worker dekodiert sie im Hintergrund. */

void xgpu_texture_prewarm_begin(void)
{
	static int prewarmed = 0;
	unsigned long bucket, index;
	unsigned long queued = 0;

	if (prewarmed)
		return;
	prewarmed = 1;
	if (!__atomic_load_n(&worker_running, __ATOMIC_ACQUIRE))
		return;
	/* (die Texture-Buckets durchgehen und alle gueltigen Eintraege
	in die Queue schieben) */
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
    if anchor not in text:
        print("FEHLER: xgpu_texture_worker_start-Anker nicht gefunden.", file=sys.stderr)
        sys.exit(1)
    text = text.replace(anchor, new, 1)

    with open(path, "w") as f:
        f.write(text)
    print("xbox_textures.c: Texture-Prewarming eingebaut.")
    return True


def apply_patch(src_root):
    print("== Patch: Texture-Prewarming ==")
    patch_xbox_textures(src_root)


if __name__ == "__main__":
    apply_patch(sys.argv[1] if len(sys.argv) > 1 else ".")
