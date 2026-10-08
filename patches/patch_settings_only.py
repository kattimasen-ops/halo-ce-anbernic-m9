#!/usr/bin/env python3
"""patch_settings_only.py — haengt das PC-Settings-Menue an den Knulli-Baum.

Nach dem Knulli-Patch werden folgende Hooks gesetzt:
  1. ui_widget.c: Forward-Deklaration `pc_menu_tag`
  2. ui_widget_event_handler_functions.c: Dispatcher + Name-Lookup
  3. ui_widget_game_data_input_functions.c: Dispatcher
  4. cache_files.c: Tag-Accessors + menu_tags_loaded/unloaded
  5. tools/linux_build.py + tools/android_build.py: Expat
  6. port/linux/port.json: "dl" in libraries

Idempotent ueber Marker-Kommentare.
"""
import json
import os
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

    # 1. halo_menus.h Include
    anchor = '#include "text/unicode.h"\n'
    if anchor in text and '#include "halo_menus.h"' not in text:
        text = text.replace(anchor, anchor + '#include "halo_menus.h" /* settings_only */\n', 1)

    # 2. Dispatcher in ui_widget_event_handler_function_invoke
    # Suche den Anfang der Funktion
    needle = 'boolean ui_widget_event_handler_function_invoke(\n'
    idx = text.find(needle)
    if idx < 0:
        print("FEHLER: ui_widget_event_handler_function_invoke fehlt.", file=sys.stderr)
        sys.exit(1)
    # Finde die schliessende Klammer des Funktionskopfes, dann die erste Anweisung
    close = text.find(')\n{', idx)
    if close < 0:
        print("FEHLER: Funktion-Rumpf nicht gefunden.", file=sys.stderr)
        sys.exit(1)
    insert_at = close + 3  # hinter "{\n"
    dispatch = (
        '\n\t/* settings_only: dispatcher */\n'
        '\tif (function_index >= PC_MENU_FUNCTION_BASE && function_index < 0x8000)\n'
        '\t{\n'
        '\t\textern boolean pc_menu_event_function_invoke(struct widget_instance *widget,\n'
        '\t\t\tstruct event_record *event, long function_index, boolean *widget_deleted);\n'
        '\t\treturn pc_menu_event_function_invoke(widget, event,\n'
        '\t\t\tfunction_index - PC_MENU_FUNCTION_BASE, widget_deleted);\n'
        '\t}\n'
    )
    text = text[:insert_at] + dispatch + text[insert_at:]

    # 3. Name-Lookup-Funktion am Ende anhaengen
    text += (
        '\n\n'
        '/* settings_only: name-lookup fuer menu_tags.c */\n'
        'char const *ui_widget_event_handler_function_name(long function_index)\n'
        '{\n'
        '\treturn function_index >= 0 && function_index < (long)NUMBEROF(event_handler_function_list.names) ?\n'
        '\t\tevent_handler_function_list.names[function_index] : NULL;\n'
        '}\n'
    )
    with open(path, "w") as f:
        f.write(text)
    print("  ui_widget_event_handler_functions.c: Dispatcher + Name-Lookup eingebaut.")


# ══════════════════════════════════════════════════════════════════════
# 3. ui_widget_game_data_input_functions.c: Dispatcher
# ══════════════════════════════════════════════════════════════════════
def patch_game_data_dispatcher(src_root):
    path = os.path.join(src_root, "source", "interface",
                        "ui_widget_game_data_input_functions.c")
    if not os.path.exists(path):
        print(f"FEHLER: {path} nicht gefunden.", file=sys.stderr)
        sys.exit(1)
    with open(path) as f:
        text = f.read()
    if "settings_only: game data dispatcher" in text:
        print("  ui_widget_game_data_input_functions.c: bereits gepatcht.")
        return

    # halo_menus.h Include
    anchor = '#include "cseries.h"\n'
    if anchor in text and '#include "halo_menus.h"' not in text:
        text = text.replace(anchor, anchor + '#include "halo_menus.h" /* settings_only */\n', 1)

    # Suche die Dispatcher-Funktion
    needle = 'void ui_widget_game_data_input_function_invoke(\n'
    idx = text.find(needle)
    if idx < 0:
        print("FEHLER: ui_widget_game_data_input_function_invoke fehlt.", file=sys.stderr)
        sys.exit(1)
    close = text.find(')\n{', idx)
    if close < 0:
        print("FEHLER: Funktion-Rumpf nicht gefunden.", file=sys.stderr)
        sys.exit(1)
    insert_at = close + 3
    dispatch = (
        '\n\t/* settings_only: game data dispatcher */\n'
        '\tif (function >= PC_MENU_FUNCTION_BASE && function < 0x8000)\n'
        '\t{\n'
        '\t\textern void pc_menu_game_data_function_invoke(struct widget_instance *widget, long function);\n'
        '\t\tpc_menu_game_data_function_invoke(widget, function - PC_MENU_FUNCTION_BASE);\n'
        '\t\treturn;\n'
        '\t}\n'
    )
    text = text[:insert_at] + dispatch + text[insert_at:]
    with open(path, "w") as f:
        f.write(text)
    print("  ui_widget_game_data_input_functions.c: Dispatcher eingebaut.")


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

    # 1. global_tag_count Variable
    anchor = 'extern struct cache_file_tag_instance *global_tag_instances;\n'
    if anchor not in text:
        print("FEHLER: global_tag_instances-Anker fehlt.", file=sys.stderr)
        sys.exit(1)
    add = anchor + (
        '/* settings_only: Menue-Tags wachsen die Tabelle ueber den Header hinaus */\n'
        'static long global_tag_count;\n'
    )
    text = text.replace(anchor, add, 1)

    # 2. tag_count -> global_tag_count in tag_loaded und iterator
    text = text.replace(
        'absolute_index < cache_file_globals.tag_header->tag_count',
        'absolute_index < global_tag_count',
    )

    # 3. Accessors einfuegen (vor tag_files_open)
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

    # 4. menu_tags_unloaded in scenario_tags_unload
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

    # 5. menu_tags_loaded in scenario_tags_load (nach tags_loaded = TRUE)
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
# 5. tools/linux_build.py + android_build.py: Expat
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

    # EXPAT_DIR nach TOML_DIR
    anchor = 'TOML_DIR = Path("port/third_party/tomlc17")\n'
    if anchor in text:
        add = anchor + (
            '# settings_only: XML-Parser fuer menu_files.c\n'
            'EXPAT_DIR = Path("port/third_party/expat")\n'
            'EXPAT_SOURCES = ("xmlparse.c", "xmlrole.c", "xmltok.c")\n'
        )
        text = text.replace(anchor, add, 1)

    # -I{EXPAT_DIR} in platform_cflags
    anchor = 'f"-I{TOML_DIR}",\n'
    if anchor in text:
        text = text.replace(anchor, anchor + '            f"-I{EXPAT_DIR}",\n', 1)

    # Expat-Objekte kompilieren
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
# 6. port/linux/port.json: "dl" in libraries
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
    patch_linux_build(src_root)
    patch_android_build(src_root)
    patch_port_json(src_root)
    print("== Fertig.")


if __name__ == "__main__":
    apply_patch(sys.argv[1] if len(sys.argv) > 1 else ".")
