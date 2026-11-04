/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The per-pump token budget:
 *   - token_create_nil decrements budget; returns DS_ERR_TOKEN_BUDGET at 0
 *     (test_token_create_budget_depletes drives create_nil too, not
 *     token_create)
 *   - token_copy decrements budget; returns DS_ERR_TOKEN_BUDGET at 0
 *   - budget=NULL (non-RT) allows unlimited allocation
 *   - engine->token_budget is reset to token_pool_cap in ds_rete_run
 *   - ds_rete_engine_set_token_pool_cap sets explicit capacity
 *   - budget exhaustion does not corrupt pool (freed on error)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "libds.h"
#include "rete/engine.h"
#include "rete/fact.h"
#include "rete/pool.h"
#include "rete/schema.h"
#include "rete/schema_reg.h"
#include "rete/token.h"
#include "rete/val.h"
#include "rete/wm_rete.h"
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

static int expect_status(const char *what, ds_result_t r, int want)
{
    if (r.status != want) {
        fprintf(stderr, "FAIL: %s: want %d got %d (%s)\n",
                what, want, r.status, r.detail ? r.detail : "(null)");
        return 1;
    }
    return 0;
}

static int test_token_create_budget_depletes(void)
{
    /* budget=1: first create succeeds, second fails.
       Use create_nil to avoid needing real fact pointers. */
    ds_rete_pool_t pool = {0};
    size_t tok_sz = sizeof(ds_rete_token_t) + 4 * sizeof(ds_rete_fact_t *);
    ds_rete_pool_init(&pool, tok_sz, 8);

    uint32_t budget = 1;
    ds_result_t r = DS_OK_R;

    ds_rete_token_t *t1 = ds_rete_token_create_nil(&pool, &budget, &r);
    if (!t1 || r.status != DS_OK) return fail("first create should succeed");
    if (budget != 0) return fail("budget should be 0 after one alloc");

    ds_rete_token_t *t2 = ds_rete_token_create_nil(&pool, &budget, &r);
    if (t2) return fail("second create should fail (budget=0)");
    if (r.status != DS_ERR_TOKEN_BUDGET)
        return fail("expected DS_ERR_TOKEN_BUDGET");

    ds_rete_token_free(t1);
    ds_rete_pool_destroy(&pool);
    return 0;
}

static int test_token_copy_budget_depletes(void)
{
    ds_rete_pool_t pool = {0};
    size_t tok_sz = sizeof(ds_rete_token_t) + 4 * sizeof(ds_rete_fact_t *);
    ds_rete_pool_init(&pool, tok_sz, 8);

    /* Create a source token without budget (non-RT). */
    ds_result_t r = DS_OK_R;
    ds_rete_token_t *src = ds_rete_token_create_nil(NULL, NULL, &r);
    if (!src) return fail("src alloc");

    uint32_t budget = 1;
    ds_rete_token_t *c1 = ds_rete_token_copy(src, 10, &pool, &budget, &r);
    if (!c1 || r.status != DS_OK) return fail("first copy should succeed");
    if (budget != 0) return fail("budget should be 0");

    ds_rete_token_t *c2 = ds_rete_token_copy(src, 11, &pool, &budget, &r);
    if (c2) return fail("second copy should fail");
    if (r.status != DS_ERR_TOKEN_BUDGET) return fail("expected TOKEN_BUDGET");

    ds_rete_token_free(c1);
    ds_rete_token_free(src);
    ds_rete_pool_destroy(&pool);
    return 0;
}

static int test_token_nil_budget_depletes(void)
{
    ds_rete_pool_t pool = {0};
    size_t tok_sz = sizeof(ds_rete_token_t) + 4 * sizeof(ds_rete_fact_t *);
    ds_rete_pool_init(&pool, tok_sz, 4);

    uint32_t budget = 1;
    ds_result_t r = DS_OK_R;

    ds_rete_token_t *t1 = ds_rete_token_create_nil(&pool, &budget, &r);
    if (!t1 || r.status != DS_OK) return fail("nil create should succeed");

    ds_rete_token_t *t2 = ds_rete_token_create_nil(&pool, &budget, &r);
    if (t2) return fail("second nil should fail (budget=0)");
    if (r.status != DS_ERR_TOKEN_BUDGET) return fail("expected TOKEN_BUDGET");

    ds_rete_token_free(t1);
    ds_rete_pool_destroy(&pool);
    return 0;
}

static int test_null_budget_unlimited(void)
{
    /* budget=NULL: allocate many tokens without hitting any limit. */
    ds_rete_pool_t pool = {0};
    size_t tok_sz = sizeof(ds_rete_token_t) + 4 * sizeof(ds_rete_fact_t *);
    ds_rete_pool_init(&pool, tok_sz, 16);

    ds_rete_token_t *tokens[16];
    for (int i = 0; i < 16; i++) {
        ds_result_t r = DS_OK_R;
        tokens[i] = ds_rete_token_create_nil(&pool, NULL, &r);
        if (!tokens[i]) return fail("alloc should succeed with NULL budget");
    }
    for (int i = 0; i < 16; i++) ds_rete_token_free(tokens[i]);
    ds_rete_pool_destroy(&pool);
    return 0;
}

static int test_budget_exhaustion_no_pool_corruption(void)
{
    /* After budget exhaustion, free an existing token and re-alloc: pool
       must be consistent (exhaustion doesn't corrupt the pool state). */
    ds_rete_pool_t pool = {0};
    size_t tok_sz = sizeof(ds_rete_token_t) + 4 * sizeof(ds_rete_fact_t *);
    ds_rete_pool_init(&pool, tok_sz, 4);

    uint32_t budget = 2;
    ds_result_t r = DS_OK_R;
    ds_rete_token_t *t1 = ds_rete_token_create_nil(&pool, &budget, &r);
    ds_rete_token_t *t2 = ds_rete_token_create_nil(&pool, &budget, &r);
    if (!t1 || !t2) return fail("first two allocs should succeed");
    if (budget != 0) return fail("budget should be 0");

    /* Budget exhausted; attempt fails. */
    ds_rete_token_t *t3 = ds_rete_token_create_nil(&pool, &budget, &r);
    if (t3) return fail("third alloc should fail");

    /* Free t1; pool now has a free slot. Re-alloc with fresh budget. */
    ds_rete_token_free(t1);
    budget = 1;
    ds_rete_token_t *t4 = ds_rete_token_create_nil(&pool, &budget, &r);
    if (!t4 || r.status != DS_OK) return fail("alloc after free should succeed");

    ds_rete_token_free(t2);
    ds_rete_token_free(t4);
    ds_rete_pool_destroy(&pool);
    return 0;
}

static int test_engine_budget_set_on_run(void)
{
    SKIP_IF_NON_RT;
    /* After init_rt_pools, calling ds_rete_run resets token_budget to
       token_pool_cap.  We verify by checking the field directly. */
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    ds_rete_slot_desc_t slots[] = {
        { .name = "v", .type = DS_RETE_VAL_INT, .is_key = false },
    };
    ds_rete_schema_t *schema = NULL;
    ds_rete_schema_register(e, "X", DS_RETE_SCOPE_PLAIN, 0, slots, 1, &schema);
    ds_rete_engine_set_wm_max(e, 16);
    ds_rete_engine_set_rt_mode(e, true);
    ds_rete_engine_set_token_pool_cap(e, 64);
    ds_rete_engine_init_rt_pools(e);

    /* init_rt_pools seeds token_budget to token_pool_cap, so a fact asserted
       in RT mode before the first pump propagates. */
    if (e->token_budget != 64)
        return fail("budget should be seeded to token_pool_cap=64 at pool init");

    /* ds_rete_run resets budget to token_pool_cap.
       In RT mode max_fires must be > 0; use 1000. */
    ds_rete_engine_set_max_fires_rt(e, 1000);
    uint32_t fired = 0;
    ds_rete_run(e, 1000, &fired);
    if (e->token_budget != 64)
        return fail("budget should be token_pool_cap=64 after run");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_set_token_pool_cap(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    if (expect_ok("set_token_pool_cap",
                  ds_rete_engine_set_token_pool_cap(e, 128))) return 1;
    if (e->token_pool_cap != 128)
        return fail("token_pool_cap should be 128");
    ds_rete_engine_destroy(e);
    return 0;
}

static int test_non_rt_no_budget(void)
{
    SKIP_IF_RT;
    /* Non-RT engine: token_budget stays 0 across runs (unlimited). */
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    ds_rete_slot_desc_t slots[] = {
        { .name = "v", .type = DS_RETE_VAL_INT, .is_key = false },
    };
    ds_rete_schema_t *schema = NULL;
    ds_rete_schema_register(e, "X", DS_RETE_SCOPE_PLAIN, 0, slots, 1, &schema);

    uint32_t fired = 0;
    ds_rete_run(e, 0, &fired);
    if (e->token_budget != 0)
        return fail("non-RT token_budget should remain 0 (unlimited)");

    ds_rete_engine_destroy(e);
    return 0;
}

int main(void)
{
    int total_fails = 0;
    const char *tags[] = {"non-RT", "RT"};

    for (int mode = 0; mode <= 1; mode++) {
        g_mode = mode;
        const char *tag = tags[mode];
        int fails = 0;
        printf("\n=== test_rete_token_budget [%s] ===\n", tag);

#define RUN(t) do { \
    int _r = (t)(); \
    if (_r) { fprintf(stderr, "  FAIL [%s]: " #t "\n", tag); fails++; } \
    else    { printf("  pass [%s]: " #t "\n", tag); } \
} while (0)

        RUN(test_token_create_budget_depletes);
        RUN(test_token_copy_budget_depletes);
        RUN(test_token_nil_budget_depletes);
        RUN(test_null_budget_unlimited);
        RUN(test_budget_exhaustion_no_pool_corruption);
        RUN(test_engine_budget_set_on_run);
        RUN(test_set_token_pool_cap);
        RUN(test_non_rt_no_budget);

#undef RUN

        if (fails == 0)
            printf("=== test_rete_token_budget [%s]: ALL PASSED ===\n", tag);
        else
            fprintf(stderr, "=== test_rete_token_budget [%s]: %d FAILED ===\n",
                    tag, fails);
        total_fails += fails;
    }
    return total_fails ? 1 : 0;
}
