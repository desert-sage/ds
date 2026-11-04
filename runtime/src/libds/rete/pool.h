/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/pool.h — fixed-size slab pool. alloc and free are O(1), with no system
 * allocator after init. All access is from the engine's pump thread.
 */
#ifndef LIBDS2_INTERNAL_RETE_POOL_H
#define LIBDS2_INTERNAL_RETE_POOL_H

#include <stddef.h>
#include <stdint.h>

#include "libds.h"

typedef struct ds_rete_pool {
    uint8_t  *base;       /* pre-allocated block; NULL = not initialised */
    size_t    obj_size;   /* bytes per object (constant after init) */
    uint32_t  cap;        /* total objects */
    uint32_t  free_top;   /* top-of-stack index into free_stack */
    uint32_t *free_stack; /* stack of free slot indices (cap entries) */
} ds_rete_pool_t;

ds_result_t ds_rete_pool_init(ds_rete_pool_t *pool,
                               size_t          obj_size,
                               uint32_t        cap);

void ds_rete_pool_destroy(ds_rete_pool_t *pool);

/* NULL when exhausted. The memory may hold a previous object's data. */
void *ds_rete_pool_alloc(ds_rete_pool_t *pool);

void ds_rete_pool_free(ds_rete_pool_t *pool, void *ptr);

#endif /* LIBDS2_INTERNAL_RETE_POOL_H */
