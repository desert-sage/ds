/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/pool.c — fixed-size slab pool.
 */
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "ds_alloc.h"
#include "rete/pool.h"

ds_result_t ds_rete_pool_init(ds_rete_pool_t *pool,
                               size_t          obj_size,
                               uint32_t        cap)
{
    if (!pool || obj_size == 0 || cap == 0)
        return DS_ERR_R(DS_ERR_INVAL, "pool_init: bad args");

    pool->base = DS_CALLOC(cap, obj_size);
    if (!pool->base)
        return DS_ERR_R(DS_ERR_OOM, "pool_init: object storage");

    pool->free_stack = DS_MALLOC(cap * sizeof(uint32_t));
    if (!pool->free_stack) {
        DS_FREE(pool->base);
        pool->base = NULL;
        return DS_ERR_R(DS_ERR_OOM, "pool_init: free stack");
    }

    pool->obj_size = obj_size;
    pool->cap      = cap;
    for (uint32_t i = 0; i < cap; i++)
        pool->free_stack[i] = i;
    pool->free_top = cap;

    return DS_OK_R;
}

void ds_rete_pool_destroy(ds_rete_pool_t *pool)
{
    if (!pool) return;
    DS_FREE(pool->base);
    DS_FREE(pool->free_stack);
    pool->base       = NULL;
    pool->free_stack = NULL;
    pool->cap        = 0;
    pool->free_top   = 0;
}

void *ds_rete_pool_alloc(ds_rete_pool_t *pool)
{
    if (!pool || pool->free_top == 0) return NULL;
    uint32_t idx = pool->free_stack[--pool->free_top];
    return pool->base + (size_t)idx * pool->obj_size;
}

void ds_rete_pool_free(ds_rete_pool_t *pool, void *ptr)
{
    if (!pool || !ptr) return;
    uint32_t idx = (uint32_t)(((uint8_t *)ptr - pool->base) / pool->obj_size);
    pool->free_stack[pool->free_top++] = idx;
}
