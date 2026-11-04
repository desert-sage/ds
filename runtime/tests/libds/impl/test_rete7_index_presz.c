/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * Beta-node index presizing:
 *   - ds_rete_beta_presz_lmem_idx sizes an EQ join's lmem_idx map, and is a
 *     no-op on a node with no index;
 *   - an EQ key naming no slot, or the whole-fact marker, takes no index;
 *   - presz allocates ridx on an rt_locked node, and go_live succeeds on an
 *     engine with no betas.
 * The index adds are static, so no test here drives their rt_locked overflow
 * guard.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "rete/beta.h"
#include "rete/engine.h"
#include "rete/schema.h"
#include "rete/schema_reg.h"
#include "rete/val.h"

static int g_mode = 0;
#include "test_dual_mode.h"

static int fail(const char *msg)
{
    fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

static int expect_ok(const char *what, ds_result_t r)
{
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: %s: status=%d (%s)\n",
                what, r.status, r.detail ? r.detail : "(null)");
        return 1;
    }
    return 0;
}

static int64_t mock_clock(void *ctx) { (void)ctx; return 1000000000LL; }

static int test_presz_lmem_idx_sizes_map(void)
{
    ds_rete_beta_node_t *node = NULL;
    ds_rete_alpha_node_t *alpha = calloc(1, sizeof(*alpha));
    if (!alpha) return fail("alpha alloc");

    /* EQ(VAR(0,0), VAR(RIGHT,0)) enables lmem_idx. */
    ds_rete_expr_t *lvar = calloc(1, sizeof(*lvar));
    ds_rete_expr_t *rvar = calloc(1, sizeof(*rvar));
    if (!lvar || !rvar) { free(alpha); free(lvar); free(rvar); return fail("expr alloc"); }
    lvar->kind = DS_RETE_EXPR_VAR;
    lvar->var.pattern_index = 0;
    lvar->var.slot_index    = 0;
    rvar->kind = DS_RETE_EXPR_VAR;
    rvar->var.pattern_index = DS_RETE_VAR_RIGHT_FACT;
    rvar->var.slot_index    = 0;

    ds_rete_expr_t *eq = calloc(1, sizeof(*eq));
    if (!eq) { free(alpha); free(lvar); free(rvar); return fail("eq alloc"); }
    eq->kind        = DS_RETE_EXPR_BINOP;
    eq->binop.op    = DS_RETE_BINOP_EQ;
    eq->binop.left  = lvar;
    eq->binop.right = rvar;

    ds_rete_join_test_t jt = { .expr = eq };
    ds_result_t r = ds_rete_beta_node_create(NULL, alpha, &jt, 1, false, &node);
    free(alpha);
    if (r.status != DS_OK) {
        free(lvar); free(rvar); free(eq);
        return fail("beta_node_create");
    }
    if (!node->lmem_idx_enabled) {
        ds_rete_beta_node_destroy(node);
        return fail("lmem_idx_enabled not set after EQ join test");
    }

    uint32_t target = 32;
    int fails = 0;
    fails += expect_ok("presz_lmem_idx", ds_rete_beta_presz_lmem_idx(node, target));
    if (node->lmem_idx_map.cap < target) {
        fprintf(stderr, "FAIL: lmem_idx_cap=%u < target=%u\n",
                node->lmem_idx_map.cap, target);
        fails++;
    }
    ds_rete_beta_node_destroy(node);
    return fails;
}

/* With no join test there is no index, and presz_lmem_idx is a no-op. */
static int test_presz_lmem_idx_noop_when_disabled(void)
{
    ds_rete_alpha_node_t *alpha = calloc(1, sizeof(*alpha));
    ds_rete_beta_node_t  *node  = NULL;
    ds_rete_beta_node_create(NULL, alpha, NULL, 0, false, &node);
    free(alpha);
    int fails = 0;
    fails += expect_ok("presz_lmem_idx disabled",
                       ds_rete_beta_presz_lmem_idx(node, 64));
    if (node->lmem_idx_map.cap != 0) {
        fprintf(stderr, "FAIL: lmem_idx_cap should be 0 when disabled, got %u\n",
                node->lmem_idx_map.cap);
        fails++;
    }
    ds_rete_beta_node_destroy(node);
    return fails;
}

/* Whether a positive join on EQ(VAR(0, lslot), VAR(RIGHT, rslot)) takes an
   EQ index. -1 when the node cannot be built. */
static int eq_join_indexed(uint8_t lslot, uint8_t rslot)
{
    ds_rete_alpha_node_t *alpha = calloc(1, sizeof(*alpha));
    ds_rete_expr_t *lvar = calloc(1, sizeof(*lvar));
    ds_rete_expr_t *rvar = calloc(1, sizeof(*rvar));
    ds_rete_expr_t *eq   = calloc(1, sizeof(*eq));
    if (!alpha || !lvar || !rvar || !eq) {
        free(alpha); free(lvar); free(rvar); free(eq);
        return -1;
    }
    lvar->kind = DS_RETE_EXPR_VAR;
    lvar->var.pattern_index = 0;
    lvar->var.slot_index    = lslot;
    rvar->kind = DS_RETE_EXPR_VAR;
    rvar->var.pattern_index = DS_RETE_VAR_RIGHT_FACT;
    rvar->var.slot_index    = rslot;
    eq->kind        = DS_RETE_EXPR_BINOP;
    eq->binop.op    = DS_RETE_BINOP_EQ;
    eq->binop.left  = lvar;
    eq->binop.right = rvar;

    ds_rete_join_test_t jt = { .expr = eq };
    ds_rete_beta_node_t *node = NULL;
    ds_result_t r = ds_rete_beta_node_create(NULL, alpha, &jt, 1, false, &node);
    free(alpha);
    if (r.status != DS_OK) {
        free(lvar); free(rvar); free(eq);
        return -1;
    }
    const int indexed = node->lmem_idx_enabled ? 1 : 0;
    ds_rete_beta_node_destroy(node);
    return indexed;
}

/* [RDSC.4a.9.1]: an index that names no slot takes no EQ index, or the index
   probes the wrong slot's values. Indexes are bytes and 255 is the
   whole-fact marker, so slot 254 is the last that names a slot. */
static int test_eq_key_past_uint8_takes_no_index(void)
{
    int fails = 0;
    const struct { uint8_t l, r; int want; const char *what; } cases[] = {
        { 254, 254, 1, "slot 254, the last that names a slot" },
        { 0,   0,   1, "slot 0" },
        { DS_RETE_VAR_WHOLE_FACT, DS_RETE_VAR_WHOLE_FACT, 0,
          "the whole-fact marker on both sides" },
        { DS_RETE_VAR_WHOLE_FACT, 0, 0, "the whole-fact marker on the left" },
        { 0, DS_RETE_VAR_WHOLE_FACT, 0, "the whole-fact marker on the right" },
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        const int got = eq_join_indexed(cases[i].l, cases[i].r);
        if (got != cases[i].want) {
            fprintf(stderr, "FAIL: %s: indexed=%d, want %d\n",
                    cases[i].what, got, cases[i].want);
            fails++;
        }
    }
    return fails;
}

/* presz allocates ridx on an rt_locked node. ridx_add is static, so the
   overflow guard itself is not driven here. */
static int test_ridx_overflow_blocked_when_rt_locked(void)
{
    ds_rete_alpha_node_t *alpha = calloc(1, sizeof(*alpha));
    ds_rete_beta_node_t  *node  = NULL;
    ds_rete_beta_node_create(NULL, alpha, NULL, 0, false, &node);
    free(alpha);

    node->rt_locked = true;
    ds_rete_beta_presz_ridx(node, 16);

    if (node->ridx_map.cap == 0) {
        ds_rete_beta_node_destroy(node);
        return fail("ridx not allocated after presz");
    }
    if (!node->rt_locked) {
        ds_rete_beta_node_destroy(node);
        return fail("rt_locked not set");
    }
    ds_rete_beta_node_destroy(node);
    return 0;
}

/* go_live locks every owned beta. This engine has none, so the loop below
   checks nothing; go_live's status is what is checked. */
static int test_go_live_sets_beta_rt_locked(void)
{
    ds_rete_engine_t *engine = NULL;
    if (ds_rete_engine_create(&engine).status != DS_OK)
        return fail("engine_create");

    ds_rete_set_clock(engine, mock_clock, NULL);
    ds_rete_engine_set_wm_max(engine, 16);
    ds_rete_engine_set_rt_mode(engine, true);
    ds_rete_engine_set_max_fires_rt(engine, 4);
    ds_rete_engine_init_rt_pools(engine);
    ds_rete_engine_presz_rt_tables(engine);

    int fails = 0;
    fails += expect_ok("go_live", ds_rete_go_live(engine));

    if (engine->owned_beta_count > 0) {
        for (uint32_t i = 0; i < engine->owned_beta_count; i++) {
            if (!engine->owned_betas[i]->rt_locked) {
                fprintf(stderr, "FAIL: owned_betas[%u]->rt_locked is false after go_live\n", i);
                fails++;
            }
        }
    }
    ds_rete_engine_destroy(engine);
    return fails;
}

int main(void)
{
    int fails = 0;

    fails += test_presz_lmem_idx_sizes_map();
    fails += test_presz_lmem_idx_noop_when_disabled();
    fails += test_eq_key_past_uint8_takes_no_index();
    fails += test_ridx_overflow_blocked_when_rt_locked();
    fails += test_go_live_sets_beta_rt_locked();

    if (fails == 0)
        printf("OK  test_rete7_index_presz (%d tests)\n", 5);
    else
        fprintf(stderr, "FAILED: %d test(s) failed\n", fails);

    return fails ? 1 : 0;
}
