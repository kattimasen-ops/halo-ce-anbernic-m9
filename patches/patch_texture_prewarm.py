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

Android-Variante (Variante A):
  texture_upload_queue ist nur im Linux-Zweig des Knulli-Patches
  deklariert, nicht aber im Android-Guest-Build. Damit der Build
  linkt, wird eine Forward Declaration plus konservativer Stub
  bereitgestellt. Der Stub queued nichts und gibt 0 zurueck, d. h.
  im Android-Build findet aktuell kein Prewarming statt. Sobald
  die asynchrone Upload-Pipeline auch fuer Android verfuegbar ist,
  kann der Stub ersatzlos entfernt werden.

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

    # Android-Block: Forward Declaration + Stub + Prewarm-Funktion.
    # Reihenfolge ist wichtig:
    #   1. Forward Declaration von texture_upload_queue, damit der
    #      Aufruf weiter unten eine Deklaration sieht.
    #   2. Konservative Stub-Definition, damit der Linker zufrieden ist.
    #   3. xgpu_texture_prewarm_begin, das die Textur-Buckets durchgeht.
    new = anchor + '''

#ifdef HALO_ANDROID
/* ''' + MARKER + ''': texture_upload_queue ist im Linux-Zweig des
Knulli-Patches deklariert, nicht aber im Android-Guest-Build. Forward
Declaration plus Stub, damit der Android-Build sauber linkt. Der Stub
ist konservativ: er queued nichts und gibt 0 zurueck, damit kein
Prewarming stattfindet, solange die asynchrone Upload-Pipeline im
Android-Build fehlt. Sobald diese verfuegbar ist, kann der Stub
ersatzlos entfernt werden. */

int texture_upload_queue(struct texture_entry *entry, void *argument);

int texture_upload_queue(struct texture_entry *entry, void *argument)
{
	(void)entry;
	(void)argument;
	/* Kein Async-Upload im Android-Build: Texturen werden weiterhin
	synchron beim ersten Draw hochgeladen. */
	return 0;
}

/* ''' + MARKER + ''': Texture-Prewarming beim Map-Load.

Die vorhandenen Texturen in der Cache-Tabelle werden auf einen
Schlag in die Worker-Queue geschoben, sobald die Map geladen ist.
Der Worker dekodiert sie im Hintergrund. */

void xgpu_texture_prewarm_begin(void)
{
	static int prewarmed = 0;
	unsigned long bucket, index;
	unsigned long queued = 0;

	(void)index;
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
    print("xbox_textures.c: Texture-Prewarming eingebaut (Variante A, Android-Stub).")
    return True


def apply_patch(src_root):
    print("== Patch: Texture-Prewarming ==")
    patch_xbox_textures(src_root)


if __name__ == "__main__":
    apply_patch(sys.argv[1] if len(sys.argv) > 1 else ".")
