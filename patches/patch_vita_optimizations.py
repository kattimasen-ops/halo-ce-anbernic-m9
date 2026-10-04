#!/usr/bin/env python3
"""
PS Vita Port-Optimierungen für Halo CE Universal (M9 Pro / RK3326).

Drei Änderungen aus dem PS Vita Port (BirchWoodGod/halo-ce-vita), die auf
dem Cortex-A35 CPU-Zeit sparen ohne sichtbaren Unterschied:

  1. game_sound.c: HALO_SOUND_OBSTRUCTION_TICKS — ein Schall hinter Wänden
     wird nur alle N Ticks neu berechnet (Vita: "Sound occlusion").
  2. render_objects.c: HALO_MIN_OBJECT_PIXELS — Objekte kleiner als N Pixel
     werden übersprungen (Vita: "Hide distant objects").
  3. render_objects.c: HALO_LIGHTING_REFRESH_DIVISOR — statische Objekt-
     Beleuchtung nur jeden N-ten Tick (Vita: "Object lighting").
  4. port_config.c: setzt die HALO_* Umgebungsvariablen aus den config.toml
     Werten, damit der Guest-Code (game_sound.c, render_objects.c) sie auch
     über config.toml steuern kann.

Alle Änderungen sind idempotent: sie erkennen bereits angewendete Stellen
und überspringen sie.
"""
import os
import sys


# ── game_sound.c ──────────────────────────────────────────────────────
def patch_game_sound(src_root):
    path = os.path.join(src_root, "source", "sound", "game_sound.c")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden – überspringe game_sound.c-Patch")
        return False
    with open(path) as f:
        text = f.read()

    if "obstruction_interval_value" in text:
        print("game_sound.c: obstruction_interval_value bereits vorhanden – überspringe.")
        return True

    old_include = '#include "units/units.h"\n\n/* ---------- constants */'
    new_include = ('#include "units/units.h"\n\n'
                   '#include <stdlib.h>\n\n'
                   '/* ---------- constants */')
    if old_include in text:
        text = text.replace(old_include, new_include, 1)
    else:
        print("WARNUNG: units.h-Include-Marker in game_sound.c nicht gefunden.")

    old_fn = '''void compute_sound_obstruction(
	short local_player_index,
	struct sound_source *source,
	real distance)
{
	struct observer_result const *camera = observer_get_camera(local_player_index);
	long slot = obstruction_cache_slot(local_player_index, &source->location.position);
	long now = game_time_get();

	if (obstruction_cache[slot].valid &&
		obstruction_cache[slot].game_time == now &&'''
    new_fn = '''/* audio.obstruction_ticks (HALO_SOUND_OBSTRUCTION_TICKS): a sound's
obstruction is a collision test from the camera; it is recomputed at most
once every this many game ticks. 1 (the Xbox's own behaviour) recomputes
every tick; 3 or 4 saves a third to half of the sound update's collision
tests on a slow CPU. The value is read once from the environment (which
port_config.c fills from config.toml); out-of-range values are clamped to
[1, 60]. */
static long obstruction_interval;

static long obstruction_interval_value(void)
{
	if (!obstruction_interval)
	{
		const char *setting = getenv("HALO_SOUND_OBSTRUCTION_TICKS");
		long value = setting && *setting ? atol(setting) : 1;

		if (value < 1)
			value = 1;
		if (value > 60)
			value = 60;
		obstruction_interval = value;
	}
	return obstruction_interval;
}

void compute_sound_obstruction(
	short local_player_index,
	struct sound_source *source,
	real distance)
{
	struct observer_result const *camera = observer_get_camera(local_player_index);
	long slot = obstruction_cache_slot(local_player_index, &source->location.position);
	long now = game_time_get();
	long interval = obstruction_interval_value();

	if (obstruction_cache[slot].valid &&
		now >= obstruction_cache[slot].game_time &&
		now - obstruction_cache[slot].game_time < interval &&'''

    if old_fn not in text:
        print("WARNUNG: compute_sound_obstruction-Marker in game_sound.c nicht gefunden.")
        return False
    text = text.replace(old_fn, new_fn, 1)

    with open(path, "w") as f:
        f.write(text)
    print("game_sound.c: HALO_SOUND_OBSTRUCTION_TICKS eingebaut.")
    return True


# ── render_objects.c ──────────────────────────────────────────────────
def patch_render_objects(src_root):
    path = os.path.join(src_root, "source", "render", "render_objects.c")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden – überspringe render_objects.c-Patch")
        return False
    with open(path) as f:
        text = f.read()

    if "HALO_MIN_OBJECT_PIXELS" in text and "HALO_LIGHTING_REFRESH_DIVISOR" in text:
        print("render_objects.c: beide Optimierungen bereits vorhanden – überspringe.")
        return True

    old_include = '#include "rasterizer/rasterizer_model_types.h"\n\n/* ---------- constants */'
    new_include = ('#include "rasterizer/rasterizer_model_types.h"\n\n'
                   '#include <stdlib.h>\n\n'
                   '/* ---------- constants */')
    if old_include in text:
        text = text.replace(old_include, new_include, 1)
    else:
        print("WARNUNG: rasterizer_model_types.h-Include-Marker in render_objects.c nicht gefunden.")

    if "HALO_MIN_OBJECT_PIXELS" not in text:
        old_find = '''	object_marker_end();

	if (render_object_globals.rendered_object_count == MAXIMUM_RENDERED_OBJECTS &&'''
        new_find = '''	object_marker_end();

#ifdef HALO_ANDROID
	/* display.distant_objects (HALO_MIN_OBJECT_PIXELS): skip objects whose
	bounding sphere is smaller than this many pixels across, the way the
	PS Vita port's "Hide distant objects" does. The index list has already
	been built; this only walks it and writes the passing indices back into
	the front. The threshold is read once. */
	{
		static real minimum = -1.0f;

		if (minimum < 0.0f)
		{
			const char *setting = getenv("HALO_MIN_OBJECT_PIXELS");

			minimum = setting && *setting ? (real)atof(setting) : 0.0f;
			if (minimum < 0.0f)
				minimum = 0.0f;
		}
		if (minimum > 0.0f)
		{
			short read_index, write_index = 0;

			for (read_index = 0; read_index < render_object_globals.rendered_object_count; read_index++)
			{
				long object_index = render_object_globals.rendered_object_indices[read_index];

				if (object_get_level_of_detail_pixels(object_index) >= minimum)
					render_object_globals.rendered_object_indices[write_index++] = object_index;
			}
			render_object_globals.rendered_object_count = write_index;
		}
	}
#endif

	if (render_object_globals.rendered_object_count == MAXIMUM_RENDERED_OBJECTS &&'''
        if old_find not in text:
            print("WARNUNG: object_marker_end-Marker in render_objects.c nicht gefunden.")
            return False
        text = text.replace(old_find, new_find, 1)

    if "HALO_LIGHTING_REFRESH_DIVISOR" not in text:
        old_refresh = '''	if (TEST_FLAG(object_get(object_index)->object.flags, _object_static_lighting_recompute_bit))
	{
		if (level_of_detail_pixels > OBJECT_RENDER_STATE_LARGE_PIXELS)
		{
			refresh = refresh_age > 0;
		}
		else if (level_of_detail_pixels > OBJECT_RENDER_STATE_SMALL_PIXELS)
		{
			refresh = refresh_age > OBJECT_RENDER_STATE_LARGE_INTERVAL;
		}
		else
		{
			refresh = refresh_age > OBJECT_RENDER_STATE_SMALL_INTERVAL;
		}
	}'''
        new_refresh = '''	if (TEST_FLAG(object_get(object_index)->object.flags, _object_static_lighting_recompute_bit))
	{
#ifdef HALO_ANDROID
		/* debug.lighting_refresh_divisor (HALO_LIGHTING_REFRESH_DIVISOR):
		a static object's lighting is kept for a multiple of the Xbox's own
		intervals (1, 3, 10 ticks); 1 leaves the Xbox's timing, 2 or 3 is
		the PS Vita port's "Object lighting" of Half or Third. The value is
		read once. */
		static long divisor;

		if (!divisor)
		{
			const char *setting = getenv("HALO_LIGHTING_REFRESH_DIVISOR");

			divisor = setting && *setting ? atol(setting) : 1;
			if (divisor < 1)
				divisor = 1;
			if (divisor > 16)
				divisor = 16;
		}
		if (level_of_detail_pixels > OBJECT_RENDER_STATE_LARGE_PIXELS)
		{
			refresh = refresh_age >= divisor;
		}
		else if (level_of_detail_pixels > OBJECT_RENDER_STATE_SMALL_PIXELS)
		{
			refresh = refresh_age > OBJECT_RENDER_STATE_LARGE_INTERVAL * divisor;
		}
		else
		{
			refresh = refresh_age > OBJECT_RENDER_STATE_SMALL_INTERVAL * divisor;
		}
#else
		if (level_of_detail_pixels > OBJECT_RENDER_STATE_LARGE_PIXELS)
		{
			refresh = refresh_age > 0;
		}
		else if (level_of_detail_pixels > OBJECT_RENDER_STATE_SMALL_PIXELS)
		{
			refresh = refresh_age > OBJECT_RENDER_STATE_LARGE_INTERVAL;
		}
		else
		{
			refresh = refresh_age > OBJECT_RENDER_STATE_SMALL_INTERVAL;
		}
#endif
	}'''
        if old_refresh not in text:
            print("WARNUNG: object_render_state_refresh-Marker in render_objects.c nicht gefunden.")
            return False
        text = text.replace(old_refresh, new_refresh, 1)

    with open(path, "w") as f:
        f.write(text)
    print("render_objects.c: distant_objects und lighting_refresh_divisor eingebaut.")
    return True


# ── port_config.c ─────────────────────────────────────────────────────
def patch_port_config(src_root):
    path = os.path.join(src_root, "port", "linux", "src", "port_config.c")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden – überspringe port_config.c-Patch")
        return False
    with open(path) as f:
        text = f.read()

    if "HALO_SOUND_OBSTRUCTION_TICKS" in text and "HALO_MIN_OBJECT_PIXELS" in text:
        print("port_config.c: neue Einträge bereits vorhanden – überspringe.")
        return True

    if "HALO_SOUND_OBSTRUCTION_TICKS" not in text:
        old_audio = '''	{ "audio.volume", _config_real, "1.0", "HALO_VOLUME", _environment_value, _platform_all,
		"The volume of everything, 0.0 to 1.0." },
'''
        new_audio = '''	{ "audio.volume", _config_real, "1.0", "HALO_VOLUME", _environment_value, _platform_all,
		"The volume of everything, 0.0 to 1.0." },
	{ "audio.obstruction_ticks", _config_integer, "1", "HALO_SOUND_OBSTRUCTION_TICKS", _environment_value,
		_platform_all,
		"How many game ticks a sound's muffling behind walls is kept before\\n"
		"it is rechecked: 1 every tick, as the Xbox; 3 or 4 saves a third\\n"
		"to half of the sound update's collision tests on a slow CPU." },
'''
        if old_audio not in text:
            print("WARNUNG: audio.volume-Eintrag in port_config.c nicht gefunden.")
            return False
        text = text.replace(old_audio, new_audio, 1)

    if "HALO_MIN_OBJECT_PIXELS" not in text:
        old_model = '''	{ "display.model_detail", _config_real, "0.5", "HALO_MODEL_DETAIL", _environment_value, _platform_android,
		"How early objects switch to their simpler models, as a fraction of the\\n"
		"size the game switches at (1.0), times render_scale. Models are most of\\n"
		"the GPU's vertex work, which limits large scenes on this GPU." },
'''
        new_model = '''	{ "display.model_detail", _config_real, "0.5", "HALO_MODEL_DETAIL", _environment_value, _platform_android,
		"How early objects switch to their simpler models, as a fraction of the\\n"
		"size the game switches at (1.0), times render_scale. Models are most of\\n"
		"the GPU's vertex work, which limits large scenes on this GPU." },
	{ "display.distant_objects", _config_real, "0.0", "HALO_MIN_OBJECT_PIXELS", _environment_value,
		_platform_android,
		"Skip objects whose bounding sphere is smaller than this many pixels\\n"
		"across: 0 draws all, 8 to 12 hides objects too small to notice. The\\n"
		"PS Vita port's \\"Hide distant objects\\"." },
'''
        if old_model not in text:
            print("WARNUNG: display.model_detail-Eintrag in port_config.c nicht gefunden.")
            return False
        text = text.replace(old_model, new_model, 1)

    if "HALO_LIGHTING_REFRESH_DIVISOR" not in text:
        old_debug_tail = '''	{ "debug.no_program_cache", _config_boolean, "false", "HALO_NO_PROGRAM_CACHE", _environment_value, _platform_android,
		"Do not keep linked shader programs in the save folder's shaders\\n"
		"folder; every start compiles them again." },
'''
        new_debug_tail = '''	{ "debug.no_program_cache", _config_boolean, "false", "HALO_NO_PROGRAM_CACHE", _environment_value, _platform_android,
		"Do not keep linked shader programs in the save folder's shaders\\n"
		"folder; every start compiles them again." },
	{ "debug.lighting_refresh_divisor", _config_integer, "1", "HALO_LIGHTING_REFRESH_DIVISOR", _environment_value,
		_platform_android,
		"How many ticks a static object's lighting is kept before it is\\n"
		"recomputed, a multiple of the Xbox's own 1, 3, 10: 1 leaves the\\n"
		"Xbox's timing, 2 or 3 saves CPU on a slow machine. The PS Vita\\n"
		"port's \\"Object lighting\\"." },
'''
        if old_debug_tail not in text:
            print("WARNUNG: debug.no_program_cache-Eintrag in port_config.c nicht gefunden.")
            return False
        text = text.replace(old_debug_tail, new_debug_tail, 1)

    if "setenv(setting->environment" not in text:
        old_load_end = '''		case _environment_set_is_false:
			config_values[index].boolean = 0;
			break;
		}
	}
}'''
        new_load_end = '''		case _environment_set_is_false:
			config_values[index].boolean = 0;
			break;
		}
	}

	/* (the guest code that reads raw HALO_* variables — game_sound.c,
	render_objects.c — sees the config.toml value too: the process
	environment is what it reads, and an environment variable that was set
	wins over config.toml, so the setenv writes the same value back.) */
	for (index = 0; index < NUMBER_OF_CONFIG_SETTINGS; index++)
	{
		const struct config_setting *setting = &config_settings[index];
		char value[64];

		if (!(setting->platforms & CONFIG_PLATFORM) || !setting->environment[0])
			continue;
		switch (setting->type)
		{
		case _config_boolean:
			snprintf(value, sizeof(value), "%s", config_values[index].boolean ? "1" : "0");
			break;
		case _config_integer:
			snprintf(value, sizeof(value), "%ld", config_values[index].integer);
			break;
		case _config_real:
			snprintf(value, sizeof(value), "%.15g", config_values[index].real);
			break;
		default:
			continue;
		}
		setenv(setting->environment, value, 1);
	}
}'''
        if old_load_end not in text:
            print("WARNUNG: Ende von config_load in port_config.c nicht gefunden.")
            return False
        text = text.replace(old_load_end, new_load_end, 1)

    with open(path, "w") as f:
        f.write(text)
    print("port_config.c: neue Config-Einträge + setenv-Loop eingebaut.")
    return True


def apply_patch(src_root):
    print("== Patch 6: PS Vita Port-Optimierungen ==")
    ok_sound = patch_game_sound(src_root)
    ok_render = patch_render_objects(src_root)
    ok_config = patch_port_config(src_root)
    if not (ok_sound or ok_render or ok_config):
        print("FEHLER: keine der Änderungen konnte angewendet werden.")
        sys.exit(1)


if __name__ == "__main__":
    apply_patch(sys.argv[1])
