#!/usr/bin/env python3
"""patch_settings_only.py — haengt das PC-Settings-Menue an den Knulli-Baum.

Setzt folgende Hooks:
  1. ui_widget.c: Forward-Deklaration `pc_menu_tag`
  2. ui_widget_event_handler_functions.c: Dispatcher + Name-Lookup
  3. ui_widget_game_data_input_functions.c: Dispatcher (robust, per Regex)
  4. cache_files.c: Tag-Accessors + menu_tags_loaded/unloaded
  5. menu_tags.c: Solo-Pause-Patch (SETTINGS auch in der Kampagne)
  6. tools/linux_build.py + tools/android_build.py: Expat
  7. port/linux/port.json: "dl" in libraries

Idempotent ueber Marker-Kommentare.
"""
import json
import os
import re
import sys


# ══════════════════════════════════════════════════════════════════════
# 1. ui_widget.c: pc_menu_tag forward decl
# ══════════════════════════════════════════════════════════════════════
def patch_ui_widget(src_root):
    path = os.path.join(src_root, "source", "interface", "ui_widget.c")
    if not os.path.exists(path):
        print(f"FEHLER: {path} nicht gefunden.", file=sys.stderr)
        sys.exit(1)
    with open(path) as f:
        text = f.read()
    if "settings_only: pc_menu_tag" in text:
        print("  ui_widget.c: bereits gepatcht.")
        return
    anchor = '#include "cseries.h"\n'
    if anchor not in text:
        print("FEHLER: ui_widget.c cseries.h-Include fehlt.", file=sys.stderr)
        sys.exit(1)
    add = anchor + (
        '\n'
        '/* settings_only: pc_menu_tag (definiert in menu_tags.c) */\n'
        'boolean pc_menu_tag(long tag_index);\n'
    )
    text = text.replace(anchor, add, 1)
    with open(path, "w") as f:
        f.write(text)
    print("  ui_widget.c: pc_menu_tag Forward-Decl eingebaut.")


# ══════════════════════════════════════════════════════════════════════
# 2. ui_widget_event_handler_functions.c: Dispatcher + Name-Lookup
# ══════════════════════════════════════════════════════════════════════
def patch_event_dispatcher(src_root):
    path = os.path.join(src_root, "source", "interface",
                        "ui_widget_event_handler_functions.c")
    if not os.path.exists(path):
        print(f"FEHLER: {path} nicht gefunden.", file=sys.stderr)
        sys.exit(1)
    with open(path) as f:
        text = f.read()
    if "settings_only: dispatcher" in text:
        print("  ui_widget_event_handler_functions.c: bereits gepatcht.")
        return

    # halo_menus.h-Include (fuer PC_MENU_FUNCTION_BASE)
    anchor = '#include "text/unicode.h"\n'
    if anchor in text and '#include "halo_menus.h"' not in text:
        text = text.replace(anchor,
            anchor + '#include "halo_menus.h" /* settings_only */\n', 1)

    # Robuste Suche: jede Funktionsdefinition, deren Name
    # "event_handler_function_invoke" enthaelt.
    pattern = re.compile(
        r'\n(?:void|boolean|short|long|int)\s+'
        r'([a-zA-Z_][a-zA-Z0-9_]*event_handler_function_invoke)\s*'
        r'\(([^)]*)\)\s*\n?\{',
        re.MULTILINE)

    match = None
    for m in pattern.finditer(text):
        if m.start() < len(text) // 2:
            match = m
            break

    if not match:
        print("  WARNUNG: event_handler_function_invoke-Dispatcher nicht gefunden.")
        print("           Menue-Aktionen werden nicht ausgefuehrt.")
    else:
        fn_name = match.group(1)
        args_str = match.group(2)
        args = [a.strip() for a in args_str.split(',')]
        param_name = "function_index"
        if args and args[-1]:
            parts = args[-1].split()
            if parts:
                param_name = parts[-1].lstrip('*')

        insert_at = match.end()
        dispatch = (
            '\n\t/* settings_only: dispatcher */\n'
            '\tif ((long)' + param_name + ' >= PC_MENU_FUNCTION_BASE && '
            '(long)' + param_name + ' < 0x8000)\n'
            '\t{\n'
            '\t\textern boolean pc_menu_event_function_invoke('
            'struct widget_instance *widget, struct event_record *event, '
            'long function_index, boolean *widget_deleted);\n'
            '\t\treturn pc_menu_event_function_invoke(widget, event, '
            '(long)' + param_name + ' - PC_MENU_FUNCTION_BASE, widget_deleted);\n'
            '\t}\n'
        )
        text = text[:insert_at] + dispatch + text[insert_at:]
        print(f"  ui_widget_event_handler_functions.c: Dispatcher in "
              f"{fn_name}() eingebaut (Parameter: {param_name}).")

    # Name-Lookup-Funktion am Ende anhaengen, falls nicht vorhanden
    if "ui_widget_event_handler_function_name" not in text:
        text += (
            '\n\n'
            '/* settings_only: name-lookup fuer menu_tags.c */\n'
            'char const *ui_widget_event_handler_function_name(long function_index)\n'
            '{\n'
            '\treturn function_index >= 0 && '
            'function_index < (long)NUMBEROF(event_handler_function_list.names) ?\n'
            '\t\tevent_handler_function_list.names[function_index] : NULL;\n'
            '}\n'
        )
        print("  ui_widget_event_handler_functions.c: Name-Lookup eingebaut.")
    else:
        print("  ui_widget_event_handler_functions.c: Name-Lookup bereits vorhanden.")

    with open(path, "w") as f:
        f.write(text)


# ══════════════════════════════════════════════════════════════════════
# 3. ui_widget_game_data_input_functions.c: Dispatcher (robust)
#
# Sucht die Dispatch-Funktion per Regex, akzeptiert mehrere Rueckgabe-
# typen und Parameternamen. Bricht nicht ab, wenn sie fehlt (dann
# funktioniert das Menue trotzdem, nur der Live-Help-Text der Settings
# aktualisiert sich nicht).
# ══════════════════════════════════════════════════════════════════════
def patch_game_data_dispatcher(src_root):
    path = os.path.join(src_root, "source", "interface",
                        "ui_widget_game_data_input_functions.c")
    if not os.path.exists(path):
        print(f"  WARNUNG: {path} fehlt. Dispatcher wird uebersprungen.")
        return
    with open(path) as f:
        text = f.read()
    if "settings_only: game data dispatcher" in text:
        print("  ui_widget_game_data_input_functions.c: bereits gepatcht.")
        return

    # halo_menus.h-Include (fuer PC_MENU_FUNCTION_BASE)
    anchor = '#include "cseries.h"\n'
    if anchor in text and '#include "halo_menus.h"' not in text:
        text = text.replace(anchor,
            anchor + '#include "halo_menus.h" /* settings_only */\n', 1)

    # Robuste Suche: jede Funktionsdefinition, deren Name
    # "game_data_input" enthaelt.
    pattern = re.compile(
        r'\n(?:void|boolean|short|long|int)\s+'
        r'([a-zA-Z_][a-zA-Z0-9_]*game_data_input[a-zA-Z0-9_]*)\s*'
        r'\(([^)]*)\)\s*\n?\{',
        re.MULTILINE)

    match = None
    for m in pattern.finditer(text):
        if m.start() < len(text) // 2:
            match = m
            break

    if not match:
        print("  WARNUNG: game_data_input-Dispatcher nicht gefunden.")
        print("           Einstellungen werden trotzdem gespeichert; nur der")
        print("           Hilfe-Text der Settings aktualisiert sich nicht live.")
        with open(path, "w") as f:
            f.write(text)
        return

    fn_name = match.group(1)
    args_str = match.group(2)
    args = [a.strip() for a in args_str.split(',')]
    param_name = "function_index"
    if args and args[-1]:
        parts = args[-1].split()
        if parts:
            param_name = parts[-1].lstrip('*')

    insert_at = match.end()
    dispatch = (
        '\n\t/* settings_only: game data dispatcher */\n'
        '\tif ((long)' + param_name + ' >= PC_MENU_FUNCTION_BASE && '
        '(long)' + param_name + ' < 0x8000)\n'
        '\t{\n'
        '\t\textern void pc_menu_game_data_function_invoke('
        'struct widget_instance *widget, long function);\n'
        '\t\tpc_menu_game_data_function_invoke(widget, '
        '(long)' + param_name + ' - PC_MENU_FUNCTION_BASE);\n'
        '\t\treturn;\n'
        '\t}\n'
    )
    text = text[:insert_at] + dispatch + text[insert_at:]
    with open(path, "w") as f:
        f.write(text)
    print(f"  ui_widget_game_data_input_functions.c: Dispatcher in "
          f"{fn_name}() eingebaut (Parameter: {param_name}).")


# ══════════════════════════════════════════════════════════════════════
# 4. cache_files.c: Tag-Accessors + menu_tags_loaded/unloaded
# ══════════════════════════════════════════════════════════════════════
def patch_cache_files(src_root):
    path = os.path.join(src_root, "source", "cache", "cache_files.c")
    if not os.path.exists(path):
        print(f"FEHLER: {path} nicht gefunden.", file=sys.stderr)
        sys.exit(1)
    with open(path) as f:
        text = f.read()
    if "settings_only: cache_files" in text:
        print("  cache_files.c: bereits gepatcht.")
        return

    anchor = 'extern struct cache_file_tag_instance *global_tag_instances;\n'
    if anchor not in text:
        print("FEHLER: global_tag_instances-Anker fehlt.", file=sys.stderr)
        sys.exit(1)
    add = anchor + (
        '/* settings_only: Menue-Tags wachsen die Tabelle ueber den Header hinaus */\n'
        'static long global_tag_count;\n'
    )
    text = text.replace(anchor, add, 1)

    text = text.replace(
        'absolute_index < cache_file_globals.tag_header->tag_count',
        'absolute_index < global_tag_count',
    )

    anchor = 'void tag_files_open(\n\tvoid)\n'
    add = (
        '/* settings_only: cache_files */\n'
        'void *cache_files_tag_instances(long *count)\n'
        '{\n'
        '\t*count = cache_file_globals.tags_loaded ? global_tag_count : 0;\n'
        '\treturn cache_file_globals.tags_loaded ? global_tag_instances : NULL;\n'
        '}\n\n'
        'void cache_files_set_tag_instances(void *instances, long count)\n'
        '{\n'
        '\tglobal_tag_instances = instances;\n'
        '\tglobal_tag_count = count;\n'
        '}\n\n'
    ) + anchor
    if anchor in text:
        text = text.replace(anchor, add, 1)

    anchor = '\tcache_file_globals.tags_loaded = FALSE;\n'
    add = (
        '\t/* settings_only: Menue-Tags zuerst freigeben */\n'
        '\t{\n'
        '\t\textern void menu_tags_unloaded(void);\n'
        '\t\tmenu_tags_unloaded();\n'
        '\t}\n'
    ) + anchor
    if anchor in text:
        text = text.replace(anchor, add, 1)

    anchor = '\t\t\tcache_file_globals.tags_loaded = TRUE;\n'
    add = anchor + (
        '\t\t\t/* settings_only: Menue-Tags an die Tag-Tabelle anhaengen */\n'
        '\t\t\t{\n'
        '\t\t\t\textern void menu_tags_loaded(char const *map_name);\n'
        '\t\t\t\tmenu_tags_loaded(cache_file_globals.header.name);\n'
        '\t\t\t}\n'
    )
    if anchor in text:
        text = text.replace(anchor, add, 1)

    with open(path, "w") as f:
        f.write(text)
    print("  cache_files.c: Tag-Accessors + Menue-Hooks eingebaut.")


# ══════════════════════════════════════════════════════════════════════
# 5. menu_tags.c: Solo-Pause-Patch
# ══════════════════════════════════════════════════════════════════════
def patch_menu_tags_solo_pause(src_root):
    path = os.path.join(src_root, "port", "linux", "game", "menu_tags.c")
    if not os.path.exists(path):
        print(f"FEHLER: {path} nicht gefunden.", file=sys.stderr)
        sys.exit(1)
    with open(path) as f:
        text = f.read()
    if "settings_only: solo_pause" in text:
        print("  menu_tags.c: Solo-Pause-Patch bereits aktiv.")
        return

    # 5a. SOLO_COLLECTION define
    anchor = '#define MULTIPLAYER_COLLECTION "ui\\\\shell\\\\multiplayer"\n'
    if anchor not in text:
        print("FEHLER: MULTIPLAYER_COLLECTION-Anker fehlt.", file=sys.stderr)
        sys.exit(1)
    add = anchor + (
        '/* settings_only: solo_pause — Kampagnen-Pause-Collection */\n'
        '#define SOLO_COLLECTION "ui\\\\shell\\\\solo_game"\n'
    )
    text = text.replace(anchor, add, 1)

    # 5b. pause_patch -> pause_patch_multiplayer umbenennen
    old_def = 'static void pause_patch(struct cache_file_tag_instance *instances)\n'
    new_def = ('static void pause_patch_multiplayer('
               'struct cache_file_tag_instance *instances) '
               '/* settings_only: solo_pause */\n')
    if old_def not in text:
        print("FEHLER: pause_patch-Definition nicht gefunden.", file=sys.stderr)
        sys.exit(1)
    text = text.replace(old_def, new_def, 1)

    # 5c. pause_patch_solo vor menu_tags_loaded einfuegen
    anchor = 'void menu_tags_loaded(\n'
    if anchor not in text:
        print("FEHLER: menu_tags_loaded-Anker fehlt.", file=sys.stderr)
        sys.exit(1)

    solo_fn = r'''
/* settings_only: solo_pause — findet den letzten Button einer Liste, der
tatsaechlich einen Event-Handler hat. Das ist im Pause-Menue der QUIT-Button. */
static long pause_last_button(struct ui_widget_definition const *list)
{
	struct ui_widget_child_reference const *children = list->child_widgets.address;
	long child, last = NONE;

	for (child = 0; child < list->child_widgets.count; child++)
	{
		struct ui_widget_definition const *button;

		if (children[child].widget_tag.index == NONE)
			continue;
		button = tag_get(UI_WIDGET_DEFINITION_TAG, children[child].widget_tag.index);
		if (button->event_handlers.count > 0)
			last = child;
	}
	return last;
}

/* settings_only: solo_pause — haengt einen SETTINGS-Button an die
Pause-Liste der Kampagne (ui\shell\solo_game\pause_game). Der Button
oeffnet denselben Settings-Screen wie der Multiplayer-Patch. Kein
END GAME (das gibt es nur im Multiplayer). */
static void pause_patch_solo(struct cache_file_tag_instance *instances)
{
	long collection = tag_loaded('Soul', SOLO_COLLECTION);
	struct tag_block const *screens;
	long patched_list = NONE, buttons = 0, screen;
	boolean box_redrawn = FALSE;

	if (collection == NONE)
	{
		platform_log("menus: solo_pause: no solo collection found");
		return;
	}
	screens = tag_get('Soul', collection);
	platform_log("menus: solo_pause: %ld screens in solo collection", screens->count);
	for (screen = 0; screen < screens->count; screen++)
	{
		long screen_tag = ((struct tag_reference const *)screens->address)[screen].index;
		struct ui_widget_definition *definition;
		struct ui_widget_child_reference *children;
		long child, list_child = NONE, box_child = NONE, quit;
		short grow, list_top;

		if (screen_tag == NONE)
			continue;
		definition = tag_get(UI_WIDGET_DEFINITION_TAG, screen_tag);
		children = definition->child_widgets.address;
		for (child = 0; child < definition->child_widgets.count && list_child == NONE; child++)
		{
			struct ui_widget_definition *list;
			long added;

			if (children[child].widget_tag.index == NONE)
				continue;
			list = tag_get(UI_WIDGET_DEFINITION_TAG, children[child].widget_tag.index);
			if (list->type != _widget_type_column_list)
				continue;
			if (children[child].widget_tag.index == patched_list)
			{
				list_child = child;
				continue;
			}
			quit = pause_last_button(list);
			if (quit == NONE || patched_list != NONE)
				continue;
			added = pause_list_patch(instances, list, quit, FALSE);
			if (!added)
				return;
			buttons = list->child_widgets.count;
			patched_list = children[child].widget_tag.index;
			list_child = child;
		}
		if (list_child == NONE)
			continue;
		for (child = 0; child < definition->child_widgets.count; child++)
		{
			if (child != list_child && children[child].widget_tag.index != NONE &&
				pause_box_stock(tag_get(UI_WIDGET_DEFINITION_TAG, children[child].widget_tag.index)))
			{
				box_child = child;
			}
		}
		grow = (short)(1 * PAUSE_BUTTON_SPACING);
		list_top = children[list_child].vertical_offset;
		for (child = 0; child < definition->child_widgets.count; child++)
		{
			if (box_child != NONE && (child == box_child || child == list_child))
				children[child].vertical_offset -= grow / 2;
			else if (children[child].vertical_offset > list_top)
				children[child].vertical_offset += box_child != NONE ? grow - grow / 2 : grow;
		}
		if (box_child != NONE && !box_redrawn)
		{
			pause_box_redraw(tag_get(UI_WIDGET_DEFINITION_TAG, children[box_child].widget_tag.index), buttons);
			box_redrawn = TRUE;
		}
	}
	if (patched_list != NONE)
		platform_log("menus: the solo pause menu has SETTINGS");
	else
		platform_log("menus: solo_pause: no column list patched");
}

'''
    text = text.replace(anchor, solo_fn + anchor, 1)

    # 5d. Guard in menu_tags_loaded erweitern
    old_guard = '''	boolean game_map = strcmp(map_name, "ui") != 0;

	/* (ui.map, and a multiplayer map: its pause menu's SETTINGS) */
	if ((game_map && tag_loaded('Soul', MULTIPLAYER_COLLECTION) == NONE) ||
		strcmp(config_string("display.menus"), "pc"))
	{
		return;
	}'''
    new_guard = '''	boolean game_map = strcmp(map_name, "ui") != 0;
	/* settings_only: solo_pause — Menue-Tags werden geladen, wenn eine
	der beiden Pause-Collections vorhanden ist, unabhaengig von
	display.menus. Auf ui.map nur, wenn PC-Menues aktiv sind. */
	boolean use_pc_menus = !strcmp(config_string("display.menus"), "pc");
	boolean has_mp_collection = tag_loaded('Soul', MULTIPLAYER_COLLECTION) != NONE;
	boolean has_solo_collection = tag_loaded('Soul', SOLO_COLLECTION) != NONE;

	if (!game_map && !use_pc_menus)
		return;
	if (game_map && !has_mp_collection && !has_solo_collection)
		return;'''
    if old_guard not in text:
        print("FEHLER: menu_tags_loaded-Guard nicht gefunden.", file=sys.stderr)
        sys.exit(1)
    text = text.replace(old_guard, new_guard, 1)

    # 5e. pause_patch-Aufruf ersetzen
    old_call = '''	if (game_map)
	{
		pause_patch(instances);
		if (build.failed)
			goto failed;
		/* (those it made) */
		cache_files_set_tag_instances(instances, build.first_index + build.next);
	}
	else if (widget_named(menus->root) != NONE)'''
    new_call = '''	if (game_map)
	{
		if (has_mp_collection)
			pause_patch_multiplayer(instances);
		if (has_solo_collection)
			pause_patch_solo(instances);
		if (build.failed)
			goto failed;
		/* (those it made) */
		cache_files_set_tag_instances(instances, build.first_index + build.next);
	}
	else if (use_pc_menus && widget_named(menus->root) != NONE)'''
    if old_call not in text:
        print("FEHLER: pause_patch-Aufruf in menu_tags_loaded nicht gefunden.", file=sys.stderr)
        sys.exit(1)
    text = text.replace(old_call, new_call, 1)

    with open(path, "w") as f:
        f.write(text)
    print("  menu_tags.c: Solo-Pause-Patch eingebaut.")


# ══════════════════════════════════════════════════════════════════════
# 6. tools/linux_build.py + tools/android_build.py: Expat
# ══════════════════════════════════════════════════════════════════════
def patch_linux_build(src_root):
    path = os.path.join(src_root, "tools", "linux_build.py")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden.")
        return
    with open(path) as f:
        text = f.read()
    if "EXPAT_DIR" in text:
        print("  linux_build.py: Expat bereits aktiv.")
        return
    anchor = 'TOML_DIR = Path("port/third_party/tomlc17")\n'
    if anchor in text:
        add = anchor + (
            '# settings_only: XML-Parser fuer menu_files.c\n'
            'EXPAT_DIR = Path("port/third_party/expat")\n'
            'EXPAT_SOURCES = ("xmlparse.c", "xmlrole.c", "xmltok.c")\n'
        )
        text = text.replace(anchor, add, 1)
    anchor = 'f"-I{TOML_DIR}",\n'
    if anchor in text:
        text = text.replace(anchor, anchor + '            f"-I{EXPAT_DIR}",\n', 1)
    anchor = '        add_object(TOML_DIR / "tomlc17.c", " ".join([abi, "-std=gnu11", "-w"]))\n'
    if anchor in text:
        add = anchor + (
            '        # settings_only: Expat\n'
            '        for name in EXPAT_SOURCES:\n'
            '            add_object(EXPAT_DIR / name, " ".join([abi, "-std=gnu11", f"-I{EXPAT_DIR}", "-w"]))\n'
        )
        text = text.replace(anchor, add, 1)
    with open(path, "w") as f:
        f.write(text)
    print("  linux_build.py: Expat eingebaut.")


def patch_android_build(src_root):
    path = os.path.join(src_root, "tools", "android_build.py")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden.")
        return
    with open(path) as f:
        text = f.read()
    if "EXPAT_DIR" in text:
        print("  android_build.py: Expat bereits aktiv.")
        return
    anchor = 'TOML_DIR = Path("port/third_party/tomlc17")\n'
    if anchor in text:
        add = anchor + (
            '# settings_only: XML-Parser fuer menu_files.c\n'
            'EXPAT_DIR = Path("port/third_party/expat")\n'
            'EXPAT_SOURCES = ("xmlparse.c", "xmlrole.c", "xmltok.c")\n'
        )
        text = text.replace(anchor, add, 1)
    anchor = 'f"-I{TOML_DIR}",'
    if anchor in text:
        text = text.replace(anchor, anchor + ' f"-I{EXPAT_DIR}",', 1)
    anchor = '    objects.append(guest_object(TOML_DIR / "tomlc17.c", platform_cflags))\n'
    if anchor in text:
        add = anchor + (
            '    # settings_only: Expat\n'
            '    for name in EXPAT_SOURCES:\n'
            '        objects.append(guest_object(EXPAT_DIR / name, platform_cflags))\n'
        )
        text = text.replace(anchor, add, 1)
    with open(path, "w") as f:
        f.write(text)
    print("  android_build.py: Expat eingebaut.")


# ══════════════════════════════════════════════════════════════════════
# 7. port/linux/port.json: "dl" in libraries
# ══════════════════════════════════════════════════════════════════════
def patch_port_json(src_root):
    path = os.path.join(src_root, "port", "linux", "port.json")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden.")
        return
    with open(path) as f:
        data = json.load(f)
    libs = data.get("libraries", [])
    if "dl" not in libs:
        libs.append("dl")
        data["libraries"] = libs
        with open(path, "w") as f:
            json.dump(data, f, indent=2)
        print("  port.json: dl hinzugefuegt.")


# ══════════════════════════════════════════════════════════════════════
def apply_patch(src_root):
    print("== Patch: Settings-Only Hooks ==")
    patch_ui_widget(src_root)
    patch_event_dispatcher(src_root)
    patch_game_data_dispatcher(src_root)
    patch_cache_files(src_root)
    patch_menu_tags_solo_pause(src_root)
    patch_linux_build(src_root)
    patch_android_build(src_root)
    patch_port_json(src_root)
    print("== Fertig.")


if __name__ == "__main__":
    apply_patch(sys.argv[1] if len(sys.argv) > 1 else ".")
