/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * A positive beta records each joining right fact in its right index (ridx)
 * through record_join, and a retraction drops the entry (ridx_drop_fact). An
 * entry left behind leaks one map entry per churned fact_id, since fact ids
 * are unique.
 *
 * The test seeds a left token, churns thousands of distinct right facts
 * (assert, run, retract), and checks that the live join-index counts (ridx,
 * ltok_idx, lmem) stay bounded rather than growing with the iteration count.
 * It does not exercise the `within` window's lowering.
 */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "libds.h"
#include "rete/alpha.h"
#include "rete/beta.h"
#include "rete/dispatch.h"
#include "rete/engine.h"
#include "rete/expr.h"
#include "rete/fact.h"
#include "rete/intern.h"
#include "rete/schema.h"
#include "rete/schema_reg.h"
#include "rete/terminal.h"
#include "rete/token.h"
#include "rete/val.h"
#include "rete/wm_rete.h"

static const char *istr(ds_rete_engine_t *e, const char *s)
{
    const char *p; ds_rete_intern_cstr(e->intern, s, &p); return p;
}

static int g_fires = 0;
static void fire_fn(const char *r, ds_rete_token_t *t, void *ctx)
{ (void)r; (void)t; (void)ctx; g_fires++; }

/* right.a == left.a — every churned right fact (a=5) joins the seed token. */
static ds_rete_expr_t *build_join_expr(void)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_BINOP);
    e->binop.op = DS_RETE_BINOP_EQ;
    e->binop.left  = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
    e->binop.left->var.pattern_index  = DS_RETE_VAR_RIGHT_FACT;
    e->binop.left->var.slot_index     = 0;
    e->binop.right = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
    e->binop.right->var.pattern_index = 0;
    e->binop.right->var.slot_index    = 0;
    return e;
}

int main(void)
{
    ds_rete_engine_t *engine = NULL;
    ds_rete_engine_create(&engine);
    ds_rete_slot_desc_t slots[2] = {
        { .name = "a", .type = DS_RETE_VAL_INT },
        { .name = "b", .type = DS_RETE_VAL_INT },
    };
    ds_rete_schema_t *schema = NULL;
    ds_rete_schema_register(engine, "S", DS_RETE_SCOPE_PLAIN, 0, slots, 2, &schema);

    ds_rete_alpha_node_t *alpha = NULL;
    ds_rete_alpha_node_create(0, NULL, 0, &alpha);
    ds_rete_dispatch_add(engine, 0, alpha);

    ds_rete_join_test_t jtest = { .expr = build_join_expr() };
    ds_rete_beta_node_t *beta = NULL;
    ds_rete_beta_node_create(NULL, alpha, &jtest, 1, false, &beta);
    ds_rete_alpha_add_beta_output(alpha, beta);

    ds_rete_terminal_t *term = NULL;
    ds_rete_terminal_create(istr(engine, "churn_rule"), 0, &term);
    term->fire_fn = fire_fn;
    ds_rete_beta_add_terminal(beta, term);

    /* Seed left memory with a root token for fact(a=5). */
    ds_rete_val_t seed_vals[2] = { ds_rete_val_int(5), ds_rete_val_int(0) };
    ds_rete_fact_t *seed = NULL;
    ds_rete_wm_assert(engine, 0, seed_vals, &seed);
    ds_result_t rc;
    ds_rete_token_t *root = ds_rete_token_create(NULL, seed, 0, NULL, NULL, &rc);
    ds_rete_beta_left_activate(beta, root, engine);
    ds_rete_token_free(root);

    const int N = 4000;
    uint32_t ridx_warm = 0, ltok_warm = 0, lmem_warm = 0;
    int rv = 0;

    for (int i = 0; i < N; i++) {
        engine->cycle_generation++;
        ds_rete_val_t vals[2] = { ds_rete_val_int(5), ds_rete_val_int(i) };
        ds_rete_fact_t *f = NULL;
        ds_rete_wm_assert(engine, 0, vals, &f);   /* right-activate -> record_join */
        uint32_t fired = 0;
        ds_rete_run(engine, 0, &fired);
        ds_rete_wm_retract(engine, f);            /* -> beta_right_retract -> ridx_drop_fact */

        /* Snapshot the live join-index entry counts once the churn has warmed
         * up (past the initial map-grow to steady state). These are the direct
         * leak signal: each churned fact's entry must be dropped on retract, so
         * the live counts hold only the bounded set of currently-joined facts. */
        if (i == 100) {
            ridx_warm = beta->ridx_map.len;
            ltok_warm = beta->ltok_idx_map.len;
            lmem_warm = beta->lmem_map.len;
        }
    }

    /* The live counts must not have grown with N — a per-churn leak would show
     * ~N entries by i=4000 vs the steady-state at i=100. Small slack absorbs a
     * bounded number of in-flight entries. */
    uint32_t ridx_fin = beta->ridx_map.len;
    uint32_t ltok_fin = beta->ltok_idx_map.len;
    uint32_t lmem_fin = beta->lmem_map.len;
    if (ridx_fin > ridx_warm + 8)
        rv |= (fprintf(stderr, "FAIL: ridx_map grew %u->%u over %d churns\n",
                       ridx_warm, ridx_fin, N), 1);
    if (ltok_fin > ltok_warm + 8)
        rv |= (fprintf(stderr, "FAIL: ltok_idx_map grew %u->%u\n",
                       ltok_warm, ltok_fin), 1);
    if (lmem_fin > lmem_warm + 8)
        rv |= (fprintf(stderr, "FAIL: lmem_map grew %u->%u\n",
                       lmem_warm, lmem_fin), 1);

    if (rv == 0)
        printf("  pass: join indices bounded under %d-fact churn "
               "(ridx %u->%u, ltok %u->%u, lmem %u->%u)\n",
               N, ridx_warm, ridx_fin, ltok_warm, ltok_fin, lmem_warm, lmem_fin);

    ds_rete_engine_destroy(engine);
    if (rv == 0) { printf("=== test_rete_ridx_churn: ALL PASSED ===\n"); return 0; }
    fprintf(stderr, "=== test_rete_ridx_churn: FAILED ===\n");
    return 1;
}
