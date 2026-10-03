#!/usr/bin/env python3
"""
Memory-Pool-Patch für Halo CE Universal.

Zwei Änderungen, basierend auf dem tatsächlichen Quellcode:
  1. cseries.h leitet ALLE malloc/free/realloc durch den Debug-Allocator
     (debug_memory.c), der Dateiname und Zeile pro Aufruf mitschreibt.
     Bei mehreren tausend Aufrufen pro Frame war das auf dem Cortex-A35
     messbar. Im Release-Build werden die Makros jetzt nur definiert,
     wenn HALO_DEBUG_ALLOCATOR gesetzt ist.
  2. decals.c allokiert pro decal_new_from_collision vier große
     Stack-Arrays (surface_queue 8 KB, deviant_surface_list 8 KB,
     deviant_surface_bunch 8 KB, render_vertices 4-8 KB). Sie werden
     zu __thread-lokalen Statics: decal_new_from_collision ist nicht
     rekursiv, der Speicher bleibt zwischen Aufrufen warm.
"""
import os
import sys


def patch_cseries_h(src_root):
    path = os.path.join(src_root, "source", "cseries", "cseries.h")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden – ueberspringe cseries.h-Patch")
        return False
    with open(path) as f:
        text = f.read()
    old = """#define match_malloc(file, line, size) debug_malloc(size, FALSE, MATCH_FILE(file), MATCH_LINE(line))
#define match_free(file, line, ptr) debug_free(ptr, MATCH_FILE(file), MATCH_LINE(line))
#define match_realloc(file, line, ptr, size) debug_realloc(ptr, size, MATCH_FILE(file), MATCH_LINE(line))

#define malloc(size) match_malloc(__FILE__, __LINE__, size)
#define free(ptr) match_free(__FILE__, __LINE__, ptr)
#define realloc(ptr, size) match_realloc(__FILE__, __LINE__, ptr, size)"""
    new = """#define match_malloc(file, line, size) debug_malloc(size, FALSE, MATCH_FILE(file), MATCH_LINE(line))
#define match_free(file, line, ptr) debug_free(ptr, MATCH_FILE(file), MATCH_LINE(line))
#define match_realloc(file, line, ptr, size) debug_realloc(ptr, size, MATCH_FILE(file), MATCH_LINE(line))

/* (port/android, HALO_RELEASE): im Release-Build ruft das Spiel libc-
   malloc/free/realloc direkt. Der Debug-Allocator (debug_memory.c)
   schreibt zu jeder Allokation Dateiname und Zeile mit und fuehrt eine
   Liste aller lebenden Bloecke. Auf dem Cortex-A35 war das bei mehreren
   tausend Aufrufen pro Frame messbar. Mit HALO_DEBUG_ALLOCATOR laesst
   sich der Debug-Pfad weiterhin einschalten (Build mit
   -DHALO_DEBUG_ALLOCATOR). */
#if !defined(HALO_RELEASE) || defined(HALO_DEBUG_ALLOCATOR)
#define malloc(size) match_malloc(__FILE__, __LINE__, size)
#define free(ptr) match_free(__FILE__, __LINE__, ptr)
#define realloc(ptr, size) match_realloc(__FILE__, __LINE__, ptr, size)
#endif"""
    if old not in text:
        print("WARNUNG: cseries.h Debug-Allocator-Makros nicht gefunden "
              "(bereits gepatcht?)")
        return False
    text = text.replace(old, new, 1)
    with open(path, "w") as f:
        f.write(text)
    print("cseries.h: Debug-Allocator auf HALO_DEBUG_ALLOCATOR beschraenkt.")
    return True


def patch_decals_c(src_root):
    path = os.path.join(src_root, "source", "effects", "decals.c")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden – ueberspringe decals.c-Patch")
        return False
    with open(path) as f:
        text = f.read()

    if "__thread long surface_queue" in text:
        print("decals.c enthaelt bereits __thread-Arrays – ueberspringe.")
        return True

    old = """		{
			struct decal_projection projection;
			long surface_queue[MAXIMUM_DECAL_SURFACE_QUEUE_SIZE];
			long deviant_surface_list[MAXIMUM_DECAL_SURFACE_QUEUE_SIZE];
			long deviant_surface_bunch[MAXIMUM_DECAL_SURFACE_QUEUE_SIZE];
			struct decal_render_vertex render_vertices[MAXIMUM_DECAL_VERTICES];
			short surface_queue_write_index;
			real_rectangle3d normal_bounds;
"""
    new = """		{
			struct decal_projection projection;
			/* (port/android): die vier grossen Arbeits-Arrays liegen im
			   thread-lokalen Speicher statt auf dem Aufrufer-Stack.
			   decal_new_from_collision ist nicht rekursiv, ein Thread
			   kann also hoechstens eine Instanz gleichzeitig halten.
			   Die Groessen sind konstant (MAXIMUM_DECAL_*); der Speicher
			   bleibt zwischen aufeinanderfolgenden Decals warm. */
			static __thread long surface_queue[MAXIMUM_DECAL_SURFACE_QUEUE_SIZE];
			static __thread long deviant_surface_list[MAXIMUM_DECAL_SURFACE_QUEUE_SIZE];
			static __thread long deviant_surface_bunch[MAXIMUM_DECAL_SURFACE_QUEUE_SIZE];
			static __thread struct decal_render_vertex render_vertices[MAXIMUM_DECAL_VERTICES];
			short surface_queue_write_index;
			real_rectangle3d normal_bounds;
"""
    if old not in text:
        print("WARNUNG: Stack-Arrays in decal_new_from_collision nicht gefunden.")
        return False
    text = text.replace(old, new, 1)
    with open(path, "w") as f:
        f.write(text)
    print("decals.c: grosse Stack-Arrays nach __thread verschoben.")
    return True


def apply_patch(src_root):
    print("== Patch 1: Memory-Pool / Allocator ==")
    ok_cseries = patch_cseries_h(src_root)
    ok_decals = patch_decals_c(src_root)
    if not ok_cseries and not ok_decals:
        print("FEHLER: keine der Aenderungen konnte angewendet werden.")
        sys.exit(1)


if __name__ == "__main__":
    apply_patch(sys.argv[1])
