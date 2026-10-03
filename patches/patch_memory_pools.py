#!/usr/bin/env python3
"""
Memory-Pool-Patch für Halo CE Universal.
Ziel: Debug-Allocator in Release-Builds umgehen und große Stack-Arrays
in decals.c in thread-lokalen Speicher verlagern.

Erkenntnis aus der Quellcode-Analyse:
  * Halo CE verwendet BEREITS ein eigenes Memory-Pool-System
    (source/memory/memory_pool.c, data_array). Die Partikel und Decals
    werden über game_state_data_new / datum_new aus einem Pool vergeben.
  * Die 53.419 malloc-Aufrufe pro Frame stammen aus dem Debug-Memory-
    Manager, der in cseries.h ALLE malloc/free/realloc über
    match_malloc/match_free/match_realloc umleitet. Jeder Aufruf schreibt
    Dateiname und Zeile mit. In Release-Builds ist das reine
    Buchhaltungs-Last.
  * decals.c allokiert pro decal_new_from_collision vier große
    Stack-Arrays (je 4-8 KB), die auf dem __thread-Stack liegen und
    jedes Mal neu gemacht werden.
"""
import os
import sys


def patch_cseries_h(src_root):
    """Debug-Allocator nur aktiv, wenn HALO_DEBUG_ALLOCATOR definiert ist."""
    path = os.path.join(src_root, "source", "cseries", "cseries.h")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden – überspringe cseries.h-Patch")
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
   malloc/free direkt. Der Debug-Allocator (debug_memory.c) schreibt zu
   jeder Allokation Dateiname und Zeile mit und fuehrt eine Liste aller
   lebenden Bloecke. Auf dem Cortex-A35 war das bei mehreren tausend
   Aufrufen pro Frame messbar. Mit HALO_DEBUG_ALLOCATOR (build.sh-Env)
   laesst sich der Debug-Pfad weiterhin einschalten. */
#if defined(HALO_RELEASE) && !defined(HALO_DEBUG_ALLOCATOR)
/* nichts: malloc/free/realloc gehen an die libc */
#else
#define malloc(size) match_malloc(__FILE__, __LINE__, size)
#define free(ptr) match_free(__FILE__, __LINE__, ptr)
#define realloc(ptr, size) match_realloc(__FILE__, __LINE__, ptr, size)
#endif"""
    if old not in text:
        print("WARNUNG: Debug-Allocator-Makros nicht gefunden – cseries.h bereits gepatcht?")
        return False
    text = text.replace(old, new, 1)
    with open(path, "w") as f:
        f.write(text)
    print("cseries.h: Debug-Allocator auf HALO_DEBUG_ALLOCATOR beschraenkt.")
    return True


def patch_decals_c(src_root):
    """Die vier grossen Stack-Arrays in decal_new_from_collision werden
    __thread-Statics. Sie liegen dann nicht mehr auf dem Aufrufer-Stack
    und werden zwischen Aufrufen wiederverwendet (die Funktion ist nicht
    rekursiv, thread-lokal ist sicher)."""
    path = os.path.join(src_root, "source", "effects", "decals.c")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden – überspringe decals.c-Patch")
        return False
    with open(path) as f:
        text = f.read()
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
			/* (port/android): die grossen Arbeits-Arrays liegen im
			   thread-lokalen Speicher, nicht auf dem Aufrufer-Stack.
			   decal_new_from_collision ist nicht rekursiv; bei
			   aufeinanderfolgenden Decals derselben Karte bleibt der
			   Speicher warm. Die Groessen sind MAXIMUM_DECAL_* und damit
			   konstant. */
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
