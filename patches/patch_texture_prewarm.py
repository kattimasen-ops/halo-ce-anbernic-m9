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

WICHTIG (2026-10-08):
  xgpu_texture_prewarm_begin wird direkt nach xgpu_texture_worker_start
  eingefuegt. Die Definition von texture_upload_queue steht in
  xbox_textures.c aber NACH xgpu_texture_worker_start. Vor dem Aufruf
  fehlt also eine Deklaration -> C99-Fehler:
    "call to undeclared function 'texture_upload_queue'"

Loesung:
  Forward-Deklaration direkt vor xgpu_texture_prewarm_begin, mit
  EXAKT derselben Signatur wie die Definition:
    static BOOL texture_upload_queue(struct texture_entry *entry,
                                     const D3DCOLOR *palette);
  Kein Stub, keine zweite Definition.

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
/* ''' + MARKER + ''': Texture-Prewarming beim Map-Load.

Die vorhandenen Texturen in der Cache-Tabelle werden auf einen
Schlag in die Worker-Queue geschoben, sobald die Map geladen ist.
Der Worker dekodiert sie im Hintergrund.

Forward-Deklaration: die Definition von texture_upload_queue steht
weiter unten in dieser Datei (im Knulli-Patch). C99 verlangt eine
Deklaration vor dem Aufruf. Signatur muss exakt zur Definition
passen. Kein Stub - nur eine Deklaration. */
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
