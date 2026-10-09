/*
PORT_SETTINGS_SHIM.C

OpenCE-Plattformfunktionen, die die OpenCE-Versionen von menu_functions.c,
menu_tags.c und menu_files.c aufrufen, im Knulli-Port aber nicht
existieren. Diese Datei wird von patches/patch_settings_only.py nach
port/linux/game/ kopiert und dort automatisch kompiliert (glob "*.c").
*/

#include "cseries.h"

#include <string.h>
#include <stdlib.h>

/* ---------- Knulli-Konfigurations-API ---------- */

extern char const *config_string(char const *name);

/* ---------- ui_widget.c: struct widget_instance ---------- */

struct widget_instance;

/* ══════════════════════════════════════════════════════════════════════
   OpenCE-Konfigurations-API, auf Knulli gemappt
   ══════════════════════════════════════════════════════════════════════ */

int config_text(char const *name, char *text, unsigned int size)
{
	char const *value;

	if (size == 0)
		return 0;
	value = config_string(name);
	if (!value)
	{
		text[0] = 0;
		return 0;
	}
	{
		unsigned int length = (unsigned int)strlen(value);
		if (length >= size)
			length = size - 1;
		memcpy(text, value, length);
		text[length] = 0;
	}
	return 1;
}

int config_write(char const *name, char const *value)
{
	(void)name;
	(void)value;
	return 1;
}

int config_default(char const *name, char *text, unsigned int size)
{
	return config_text(name, text, size);
}

void config_folder(char *path, unsigned long size)
{
	if (size == 0)
		return;
	path[0] = '.';
	if (size > 1)
		path[1] = 0;
}

/* ══════════════════════════════════════════════════════════════════════
   OpenCE-Plattform-API, Stubs
   ══════════════════════════════════════════════════════════════════════ */

void platform_display_apply(void)
{
	return;
}

void platform_request_quit(void)
{
	return;
}

int platform_window_sizes(long *widths, long *heights, int maximum)
{
	if (maximum >= 2)
	{
		widths[0] = 640; heights[0] = 480;
		widths[1] = 800; heights[1] = 480;
		return 2;
	}
	if (maximum >= 1)
	{
		widths[0] = 640; heights[0] = 480;
		return 1;
	}
	return 0;
}

int platform_display_resolutions(long *widths, long *heights, int maximum)
{
	if (maximum >= 1)
	{
		widths[0] = 640; heights[0] = 480;
		return 1;
	}
	return 0;
}

/*
 * platform_audio_devices — menu_tags.c ruft dies auf, um die verfuegbaren
 * Audio-Ausgabegeraete aufzulisten. Im Knulli-Port gibt es keine
 * Geraeteliste; wir liefern eine statische Liste mit dem Standard-Geraet.
 */
int platform_audio_devices(char *names, int maximum, int name_size)
{
	const char *default_device = "Default Audio Device";
	int length;

	if (maximum <= 0 || name_size <= 0 || names == NULL)
		return 0;

	length = (int)strlen(default_device) + 1;
	if (length > name_size)
		length = name_size;

	memcpy(names, default_device, length - 1);
	names[length - 1] = '\0';

	return 1;
}

/* ══════════════════════════════════════════════════════════════════════
   ui_widget_port_go_back
   ══════════════════════════════════════════════════════════════════════ */

void ui_widget_port_go_back(struct widget_instance *widget)
{
	(void)widget;
	return;
}
