#!/usr/bin/env python3
"""
Memory-Pool-Patch für Halo CE Universal.
Ersetzt häufige malloc/free-Aufrufe für Partikel, Decals und Projektile
durch einen vorallokierten Pool.

WICHTIG: Dieser Patch ist eine Vorlage. Die tatsächlichen Funktionsnamen
und -signaturen müssen aus dem Quellcode entnommen werden (grep -r malloc
source/effects/).
"""
import os
import sys

def apply_patch(src_root):
    pool_h = os.path.join(src_root, "source", "memory", "pool.h")
    os.makedirs(os.path.dirname(pool_h), exist_ok=True)
    with open(pool_h, "w") as f:
        f.write("""\
#ifndef __MEMORY_POOL_H
#define __MEMORY_POOL_H
#include <stddef.h>
typedef struct memory_pool {
    void *base;
    size_t object_size;
    size_t capacity;
    size_t used;
    void *free_list;
} memory_pool;
void memory_pool_create(memory_pool *pool, size_t object_size, size_t capacity);
void memory_pool_destroy(memory_pool *pool);
void *memory_pool_alloc(memory_pool *pool);
#endif
""")
    pool_c = os.path.join(src_root, "source", "memory", "pool.c")
    with open(pool_c, "w") as f:
        f.write("""\
#include "pool.h"
#include <stdlib.h>
void memory_pool_create(memory_pool *pool, size_t object_size, size_t capacity) {
    pool->object_size = object_size;
    pool->capacity = capacity;
    pool->used = 0;
    pool->free_list = NULL;
    pool->base = malloc(object_size * capacity);
    if (!pool->base) abort();
}
void memory_pool_destroy(memory_pool *pool) { free(pool->base); pool->base = NULL; pool->free_list = NULL; }
void *memory_pool_alloc(memory_pool *pool) {
    if (pool->free_list) { void *o = pool->free_list; pool->free_list = *(void **)o; return o; }
    if (pool->used >= pool->capacity) return NULL;
    return (char *)pool->base + pool->object_size * pool->used++;
}
""")
    print("pool.c und pool.h erstellt.")
    print("HINWEIS: Die Allokationsstellen in source/effects/particles.c und")
    print("source/effects/decals.c müssen manuell auf memory_pool_alloc")
    print("umgestellt werden. Dieser Patch legt nur die Infrastruktur an.")

if __name__ == "__main__":
    apply_patch(sys.argv[1])
