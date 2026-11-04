/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/token.c — token lifecycle and equality (IRET.7.1-7.3).
 */
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "ds_alloc.h"
#include "rete/clone.h"
#include "rete/fact.h"
#include "rete/pool.h"
#include "rete/token.h"

/* XOR-rotation hash of fact IDs (IRET.7.3). */
static uint32_t compute_hash(ds_rete_fact_t **facts, uint32_t count)
{
    uint32_t h = 0;
    for (uint32_t i = 0; i < count; i++) {
        uint32_t id  = facts[i]->id;
        uint32_t rot = i & 31u;
        /* `id >> 32` is undefined. */
        h ^= (rot == 0u) ? id : ((id << rot) | (id >> (32u - rot)));
    }
    return h;
}

/* The budget is per pump cycle, reset at the top of ds_rete_run. */

ds_rete_token_t *ds_rete_token_create_nil(ds_rete_pool_t *pool,
                                           uint32_t       *budget,
                                           ds_result_t    *err)
{
    if (budget) {
        if (*budget == 0) {
            if (err) *err = DS_ERR_R(DS_ERR_TOKEN_BUDGET,
                                     "nil token: token budget exhausted");
            return NULL;
        }
        (*budget)--;
    }
    ds_rete_token_t *t;
    if (pool) {
        t = ds_rete_pool_alloc(pool);
        if (!t) {
            if (err) *err = DS_ERR_R(DS_ERR_OOM, "nil token: pool exhausted");
            return NULL;
        }
        memset(t, 0, sizeof(*t));
        t->tok_pool = pool;
        t->facts    = (ds_rete_fact_t **)(t + 1); /* embedded; count=0 */
    } else {
        t = DS_CALLOC(1, sizeof(*t));
        if (!t) { if (err) *err = DS_ERR_R(DS_ERR_OOM, "nil token"); return NULL; }
    }
    if (err) *err = DS_OK_R;
    return t;
}

ds_rete_token_t *ds_rete_token_create(const ds_rete_token_t *left,
                                       ds_rete_fact_t        *right_fact,
                                       int64_t                timetag,
                                       ds_rete_pool_t        *pool,
                                       uint32_t              *budget,
                                       ds_result_t           *err)
{
    if (budget) {
        if (*budget == 0) {
            if (err) *err = DS_ERR_R(DS_ERR_TOKEN_BUDGET,
                                     "token_create: budget exhausted");
            return NULL;
        }
        (*budget)--;
    }

    uint32_t parent_count = left ? left->fact_count : 0;
    uint32_t new_count    = parent_count + 1;

    ds_rete_token_t *t;
    if (pool) {
        t = ds_rete_pool_alloc(pool);
        if (!t) {
            if (err) *err = DS_ERR_R(DS_ERR_OOM, "token: pool exhausted");
            return NULL;
        }
        memset(t, 0, sizeof(*t));
        t->tok_pool = pool;
        t->facts = (ds_rete_fact_t **)(t + 1);
    } else {
        t = DS_CALLOC(1, sizeof(*t));
        if (!t) { if (err) *err = DS_ERR_R(DS_ERR_OOM, "token alloc"); return NULL; }
        t->facts = DS_CALLOC(new_count, sizeof(ds_rete_fact_t *));
        if (!t->facts) {
            DS_FREE(t);
            if (err) *err = DS_ERR_R(DS_ERR_OOM, "token facts array");
            return NULL;
        }
    }

    switch (parent_count) {
    case 0:  break;
    case 1:  t->facts[0] = left->facts[0]; break;
    case 2:  t->facts[0] = left->facts[0]; t->facts[1] = left->facts[1]; break;
    default: memcpy(t->facts, left->facts, parent_count * sizeof(ds_rete_fact_t *)); break;
    }
    t->facts[parent_count] = right_fact;
    t->fact_count          = new_count;
    t->creation_timetag    = timetag;
    t->hash                = compute_hash(t->facts, new_count);

    if (err) *err = DS_OK_R;
    return t;
}

void ds_rete_token_free(ds_rete_token_t *token)
{
    if (!token) return;
    if (token->tok_pool) {
        ds_rete_pool_free(token->tok_pool, token);
    } else {
        DS_FREE(token->facts);
        DS_FREE(token);
    }
}

ds_rete_token_t *ds_rete_token_copy(const ds_rete_token_t *src,
                                     int64_t                timetag,
                                     ds_rete_pool_t        *pool,
                                     uint32_t              *budget,
                                     ds_result_t           *err)
{
    if (!src) {
        if (err) *err = DS_ERR_R(DS_ERR_INVAL, "token_copy: NULL");
        return NULL;
    }

    if (budget) {
        if (*budget == 0) {
            if (err) *err = DS_ERR_R(DS_ERR_TOKEN_BUDGET,
                                     "token_copy: budget exhausted");
            return NULL;
        }
        (*budget)--;
    }

    ds_rete_token_t *t;
    if (pool) {
        t = ds_rete_pool_alloc(pool);
        if (!t) {
            if (err) *err = DS_ERR_R(DS_ERR_OOM, "token_copy: pool exhausted");
            return NULL;
        }
        memset(t, 0, sizeof(*t));
        t->tok_pool = pool;
        t->facts    = (ds_rete_fact_t **)(t + 1);
    } else {
        t = DS_CALLOC(1, sizeof(*t));
        if (!t) { if (err) *err = DS_ERR_R(DS_ERR_OOM, "token_copy alloc"); return NULL; }
        t->facts = DS_CALLOC(src->fact_count ? src->fact_count : 1u,
                          sizeof(ds_rete_fact_t *));
        if (!t->facts) {
            DS_FREE(t);
            if (err) *err = DS_ERR_R(DS_ERR_OOM, "token_copy facts");
            return NULL;
        }
    }

    switch (src->fact_count) {
    case 0:  break;
    case 1:  t->facts[0] = src->facts[0]; break;
    case 2:  t->facts[0] = src->facts[0]; t->facts[1] = src->facts[1]; break;
    default: memcpy(t->facts, src->facts, src->fact_count * sizeof(ds_rete_fact_t *)); break;
    }
    t->fact_count       = src->fact_count;
    t->creation_timetag = timetag;
    t->hash             = src->hash;
    if (err) *err = DS_OK_R;
    return t;
}

bool ds_rete_tokens_equal(const ds_rete_token_t *a, const ds_rete_token_t *b)
{
    if (!a || !b) return false;
    if (a->hash != b->hash || a->fact_count != b->fact_count) return false;
    for (uint32_t i = 0; i < a->fact_count; i++)
        if (a->facts[i] != b->facts[i]) return false;
    return true;
}

/* ---- token deep-copy ------------------------------------------------ */

ds_rete_token_t *ds_rete_token_clone(ds_rete_clone_ctx_t *cx,
                                     const ds_rete_token_t *src)
{
    if (!src) return NULL;

    ds_rete_token_t *t = DS_CALLOC(1, sizeof(*t));
    if (!t) { cx->oom = true; return NULL; }

    t->fact_count       = src->fact_count;
    t->creation_timetag = src->creation_timetag;   /* verbatim: agenda order */
    t->hash             = src->hash;                /* fact-id XOR: stable */
    t->tok_pool         = NULL;                     /* non-RT clone */
    t->next = t->prev   = NULL;                     /* caller links into memory */

    t->facts = DS_CALLOC(src->fact_count ? src->fact_count : 1u,
                         sizeof(*t->facts));
    if (!t->facts) { DS_FREE(t); cx->oom = true; return NULL; }

    for (uint32_t i = 0; i < src->fact_count; i++)
        t->facts[i] = src->facts[i]
                      ? ds_rete_clone_fact_lookup(cx, src->facts[i]->id)
                      : NULL;

    return t;
}
