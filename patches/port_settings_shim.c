/*
PORT_SETTINGS_SHIM.C

OpenCE-Plattformfunktionen, die die OpenCE-Versionen von menu_functions.c,
menu_tags.c und menu_files.c aufrufen, im Knulli-Port aber nicht
existieren. Diese Datei wird von patches/patch_settings_only.py nach
port/linux/game/ kopiert und dort automatisch kompiliert (glob "*.c").

Der Knulli-Port hat eine eigene Konfigurations-API (config_string,
config_boolean, config_integer, config_real in port_config.c). Die
OpenCE-API (config_text, config_write, config_default, config_folder)
wird darauf abgebildet, soweit moeglich; die plattformspezifischen
Funktionen sind Stubs, die den Link durchgehen lassen.
*/

#include "cseries.h"

#include <string.h>

/* ---------- Knulli-Konfigurations-API (port/linux/src/port_config.c) ---------- */

extern char const *config_string(char const *name);

/* ---------- ui_widget.c: struct widget_instance ---------- */

struct widget_instance;

/* ══════════════════════════════════════════════════════════════════════
   OpenCE-Konfigurations-API, auf Knulli gemappt
   ══════════════════════════════════════════════════════════════════════ */

/* settings_only: config_text (OpenCE) -> config_string (Knulli) */
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

/* settings_only: config_write — der Knulli-Port hat keine oeffentliche
   Schreib-API; wir tun so, als sei der Schreibvorgang erfolgreich. */
int config_write(char const *name, char const *value)
{
	(void)name;
	(void)value;
	return 1;
}

/* settings_only: config_default — Knulli unterscheidet nicht zwischen
   Wert und Standard; wir geben den aktuellen Wert zurueck. */
int config_default(char const *name, char *text, unsigned int size)
{
	return config_text(name, text, size);
}

/* settings_only: config_folder — Verzeichnis der config.toml. Der
   Knulli-Port legt sie ins Datenverzeichnis; wir melden "." als
   Naeherung. */
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

/* settings_only: platform_display_apply — Anzeige-Aenderungen anwenden.
   Der Knulli-Port wendet sie sofort an; nichts zu tun. */
void platform_display_apply(void)
{
	return;
}

/* settings_only: platform_request_quit — Beenden anfordern. Der
   Knulli-Port kennt keinen sauberen Beenden-Pfad aus dem Spiel heraus;
   wir tun nichts. */
void platform_request_quit(void)
{
	return;
}

/* settings_only: platform_window_sizes — verfuegbare Fenstergroessen.
   Knulli hat 480p; wir melden 640x480 und 800x480 als Auswahl. */
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

/* settings_only: platform_display_resolutions — verfuegbare
   Aufloesungen. Knulli hat 480p; wir melden sie. */
int platform_display_resolutions(long *widths, long *heights, int maximum)
{
	if (maximum >= 1)
	{
		widths[0] = 640; heights[0] = 480;
		return 1;
	}
	return 0;
}

/* ══════════════════════════════════════════════════════════════════════
   ui_widget_port_go_back
   ══════════════════════════════════════════════════════════════════════ */

/* settings_only: ui_widget_port_go_back — OpenCE ruft dies aus
   menu_functions.c, um im Widget-Stack einen Schritt zurueckzugehen.
   Der Knulli-Port exportiert die entsprechende Funktion nicht
   oeffentlich; wir machen sie zum No-op. Falls der Zurueck-Knopf in den
   Settings spaeter nicht funktioniert, muss die Knulli-Funktion
   widget_instance_go_back_to_previous oeffentlich gemacht werden. */
void ui_widget_port_go_back(struct widget_instance *widget)
{
	(void)widget;
	return;
}
