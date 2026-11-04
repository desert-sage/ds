/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/token.h — partial matches (IRET.7.1-7.3): one fact pointer per LHS pattern,
 * in declaration order. A left memory owns its tokens; a token owns its facts[]
 * array, and the WM the facts.
 */
#ifndef LIBDS2_INTERNAL_RETE_TOKEN_H
#define LIBDS2_INTERNAL_RETE_TOKEN_H

#include <stdbool.h>
#include <stdint.h>

#include "libds.h"
#include "ds_alloc.h"
#include "rete/fact.h"
#include "rete/pool.h"

/* ---- Token (IRET.7.1) --------------------------------------------- */

typedef struct ds_rete_token {
    uint32_t              fact_count;
    ds_rete_fact_t      **facts;           /* borrowed ptrs; array is owned */
    int64_t               creation_timetag;/* monotonic; for agenda ordering */
    uint32_t              hash;            /* XOR-rotation of fact IDs (7.3) */
    struct ds_rete_token *next;            /* intrusive list in left memories */
    struct ds_rete_token *prev;            /* NULL = head */
    /* Non-NULL when pool-allocated: facts[] then follows this header in the pool
       object, with no separate free. */
    ds_rete_pool_t       *tok_pool;
} ds_rete_token_t;

/*
 * The nil token (fact_count 0) seeds a root beta node, so right-activation produces
 * single-fact tokens.
 * pool:   engine token_pool when rt_mode, else NULL (uses malloc).
 * budget: &engine->token_budget when rt_mode, else NULL (unlimited).
 */
ds_rete_token_t *ds_rete_token_create_nil(ds_rete_pool_t *pool,
                                           uint32_t       *budget,
                                           ds_result_t    *err);

/* left is NULL for the first pattern. budget is decremented before allocation, and
   DS_ERR_TOKEN_BUDGET at 0. */
ds_rete_token_t *ds_rete_token_create(const ds_rete_token_t *left,
                                       ds_rete_fact_t        *right_fact,
                                       int64_t                timetag,
                                       ds_rete_pool_t        *pool,
                                       uint32_t              *budget,
                                       ds_result_t           *err);

void ds_rete_token_free(ds_rete_token_t *token);

/* IRET.7.3. */
bool ds_rete_tokens_equal(const ds_rete_token_t *a, const ds_rete_token_t *b);

ds_rete_token_t *ds_rete_token_copy(const ds_rete_token_t *src,
                                     int64_t                timetag,
                                     ds_rete_pool_t        *pool,
                                     uint32_t              *budget,
                                     ds_result_t           *err);

#endif /* LIBDS2_INTERNAL_RETE_TOKEN_H */
