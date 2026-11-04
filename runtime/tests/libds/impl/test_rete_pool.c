/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The pool allocator, and the engine's RT pools:
 *   - ds_rete_pool_init / alloc / free / destroy
 *   - Pool exhaustion returns NULL
 *   - Free and re-alloc within same pool
 *   - ds_rete_engine_init_rt_pools populates fact/token/act pools
 *   - Pool-backed facts are returned to pool on retract
 *   - Pool-backed tokens embed their facts array
 *   - A non-RT engine allocates facts outside any pool
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "libds.h"
#include "rete/agenda.h"
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

static const char *istr(ds_rete_engine_t *e, const char *s)
{
    const char *p;
    ds_rete_intern_cstr(e->intern, s, &p);
    return p;
}

/* Build an RT-mode engine with one schema (2 slots). */
static ds_rete_engine_t *make_rt_engine(ds_rete_schema_t **schema_out,
                                         uint32_t n_max)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    ds_rete_slot_desc_t slots[] = {
        { .name = "value", .type = DS_RETE_VAL_INT, .is_key = false },
        { .name = "name",  .type = DS_RETE_VAL_STR, .is_key = true  },
    };
    ds_rete_schema_register(e, "Sensor", DS_RETE_SCOPE_PLAIN, 0,
                             slots, 2, schema_out);
    ds_rete_engine_set_wm_max(e, n_max);
    ds_rete_engine_set_rt_mode(e, true);
    ds_rete_engine_set_token_depth(e, 4);
    ds_rete_engine_init_rt_pools(e);
    return e;
}

static int test_pool_basic_alloc_free(void)
{
    ds_rete_pool_t pool = {0};
    if (expect_ok("pool_init", ds_rete_pool_init(&pool, 32, 4))) return 1;

    void *a = ds_rete_pool_alloc(&pool);
    void *b = ds_rete_pool_alloc(&pool);
    void *c = ds_rete_pool_alloc(&pool);
    void *d = ds_rete_pool_alloc(&pool);
    if (!a || !b || !c || !d) return fail("pool should have 4 slots");

    /* Fifth alloc must fail */
    void *e = ds_rete_pool_alloc(&pool);
    if (e) return fail("pool should be exhausted after 4 allocs");

    /* Free one and re-alloc */
    ds_rete_pool_free(&pool, b);
    void *b2 = ds_rete_pool_alloc(&pool);
    if (!b2) return fail("pool should yield one slot after free");

    ds_rete_pool_free(&pool, a);
    ds_rete_pool_free(&pool, b2);
    ds_rete_pool_free(&pool, c);
    ds_rete_pool_free(&pool, d);
    ds_rete_pool_destroy(&pool);
    return 0;
}

static int test_pool_objects_distinct(void)
{
    /* Objects from the pool must not overlap. */
    ds_rete_pool_t pool = {0};
    ds_rete_pool_init(&pool, 16, 8);
    void *ptrs[8];
    for (int i = 0; i < 8; i++) {
        ptrs[i] = ds_rete_pool_alloc(&pool);
        if (!ptrs[i]) return fail("alloc should succeed");
        memset(ptrs[i], (uint8_t)i, 16);
    }
    /* Verify no overlap: check sentinel bytes */
    for (int i = 0; i < 8; i++) {
        uint8_t *p = ptrs[i];
        for (int j = 0; j < 16; j++) {
            if (p[j] != (uint8_t)i) return fail("pool object content clobbered");
        }
    }
    for (int i = 0; i < 8; i++) ds_rete_pool_free(&pool, ptrs[i]);
    ds_rete_pool_destroy(&pool);
    return 0;
}

static int test_pool_zero_base_not_initialised(void)
{
    ds_rete_pool_t pool = {0};
    /* Alloc on uninitialised pool must return NULL gracefully. */
    void *p = ds_rete_pool_alloc(&pool);
    if (p) return fail("uninitialised pool should return NULL");
    return 0;
}

static int test_init_rt_pools_sets_ready(void)
{
    SKIP_IF_NON_RT;
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_rt_engine(&schema, 8);
    if (!e->pools_ready) return fail("pools_ready should be true after init");
    if (e->fact_pool.base  == NULL) return fail("fact_pool not initialised");
    if (e->token_pool.base == NULL) return fail("token_pool not initialised");
    if (e->act_pool.base   == NULL) return fail("act_pool not initialised");
    if (e->fact_pool.cap   != 8)    return fail("fact_pool cap should be N_max");
    ds_rete_engine_destroy(e);
    return 0;
}

static int test_init_rt_pools_requires_rt_mode(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    ds_rete_engine_set_wm_max(e, 10);
    /* rt_mode not set → init_rt_pools must return DS_ERR_RT_UNSAFE */
    if (expect_status("init_rt_pools without rt_mode",
                      ds_rete_engine_init_rt_pools(e),
                      DS_ERR_RT_UNSAFE)) return 1;
    ds_rete_engine_destroy(e);
    return 0;
}

static int test_pool_fact_alloc_on_assert(void)
{
    SKIP_IF_NON_RT;
    /* In pool mode, asserted facts must come from the fact pool. */
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_rt_engine(&schema, 4);

    ds_rete_fact_t *f = NULL;
    ds_rete_val_t s[] = {
        ds_rete_val_int(99),
        ds_rete_val_str(istr(e, "x"), 1),
    };
    if (expect_ok("assert", ds_rete_wm_assert(e, 0, s, &f))) return 1;
    if (!f) return fail("fact pointer is NULL");
    if (f->owner_pool != &e->fact_pool)
        return fail("fact should be pool-owned");
    /* Verify fact is within pool base..base+cap*obj_size */
    uint8_t *base = e->fact_pool.base;
    uint8_t *ptr  = (uint8_t *)f;
    if (ptr < base || ptr >= base + e->fact_pool.cap * e->fact_pool.obj_size)
        return fail("fact pointer outside pool range");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_pool_fact_returned_on_retract(void)
{
    SKIP_IF_NON_RT;
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_rt_engine(&schema, 2);

    /* Assert 2 facts — fills pool. */
    ds_rete_fact_t *f1 = NULL, *f2 = NULL;
    ds_rete_val_t s1[] = { ds_rete_val_int(1), ds_rete_val_str(istr(e,"a"),1) };
    ds_rete_val_t s2[] = { ds_rete_val_int(2), ds_rete_val_str(istr(e,"b"),1) };
    if (expect_ok("assert 1", ds_rete_wm_assert(e, 0, s1, &f1))) return 1;
    if (expect_ok("assert 2", ds_rete_wm_assert(e, 0, s2, &f2))) return 1;

    /* Pool exhausted — third assert must fail. */
    ds_rete_fact_t *f3 = NULL;
    ds_rete_val_t s3[] = { ds_rete_val_int(3), ds_rete_val_str(istr(e,"c"),1) };
    if (expect_status("assert 3 full", ds_rete_wm_assert(e, 0, s3, &f3),
                      DS_ERR_WM_FULL)) return 1;

    /* Retract one — pool slot returned. */
    if (expect_ok("retract 1", ds_rete_wm_retract(e, f1))) return 1;

    /* Now assert should succeed. */
    if (expect_ok("assert 3 after retract",
                  ds_rete_wm_assert(e, 0, s3, &f3))) return 1;

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_pool_token_embedded_facts(void)
{
    /* Token allocated from pool must have facts[] pointing into the pool
       object (immediately after the token header). */
    ds_rete_pool_t pool = {0};
    size_t k_max = 4;
    size_t tok_sz = sizeof(ds_rete_token_t) + k_max * sizeof(ds_rete_fact_t *);
    ds_rete_pool_init(&pool, tok_sz, 8);

    ds_result_t r = DS_OK_R;
    ds_rete_token_t *nil = ds_rete_token_create_nil(&pool, NULL, &r);
    if (!nil || r.status != DS_OK) return fail("nil token alloc from pool");
    if (nil->tok_pool != &pool) return fail("tok_pool not set on nil token");

    /* The nil token has fact_count=0; facts ptr points to embedded area. */
    uint8_t *expected_facts = (uint8_t *)(nil + 1);
    if ((uint8_t *)nil->facts != expected_facts)
        return fail("nil token facts[] not embedded after header");

    ds_rete_token_free(nil);

    /* After free, pool has the slot back — alloc again succeeds. */
    ds_rete_token_t *t2 = ds_rete_token_create_nil(&pool, NULL, &r);
    if (!t2) return fail("second token alloc should succeed after free");
    ds_rete_token_free(t2);

    ds_rete_pool_destroy(&pool);
    return 0;
}

static int test_pool_token_copy_embedded(void)
{
    ds_rete_pool_t pool = {0};
    size_t k_max = 4;
    size_t tok_sz = sizeof(ds_rete_token_t) + k_max * sizeof(ds_rete_fact_t *);
    ds_rete_pool_init(&pool, tok_sz, 8);

    ds_result_t r = DS_OK_R;
    ds_rete_token_t *src = ds_rete_token_create_nil(NULL, NULL, &r); /* malloc */
    if (!src) return fail("src token alloc");
    src->hash = 0xDEADBEEFu;

    ds_rete_token_t *copy = ds_rete_token_copy(src, 42, &pool, NULL, &r);
    if (!copy || r.status != DS_OK) return fail("pool copy alloc");
    if (copy->tok_pool != &pool)    return fail("copy tok_pool not set");
    if (copy->hash != src->hash)    return fail("copy hash mismatch");
    if (copy->creation_timetag != 42) return fail("copy timetag wrong");

    ds_rete_token_free(copy);
    ds_rete_token_free(src);
    ds_rete_pool_destroy(&pool);
    return 0;
}

static int test_pool_non_rt_mode_unchanged(void)
{
    SKIP_IF_RT;
    /* A non-RT engine has no pools: its facts come from the heap. */
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    ds_rete_slot_desc_t slots[] = {
        { .name = "v", .type = DS_RETE_VAL_INT, .is_key = false },
    };
    ds_rete_schema_t *schema = NULL;
    ds_rete_schema_register(e, "X", DS_RETE_SCOPE_PLAIN, 0, slots, 1, &schema);

    if (e->pools_ready) return fail("pools_ready should be false in non-RT");

    ds_rete_val_t s[] = { ds_rete_val_int(7) };
    ds_rete_fact_t *f = NULL;
    if (expect_ok("assert non-RT", ds_rete_wm_assert(e, 0, s, &f))) return 1;
    if (!f) return fail("fact must be non-NULL");
    if (f->owner_pool != NULL) return fail("non-RT fact should not be pool-owned");
    if (ds_rete_wm_count(e) != 1) return fail("wm_count should be 1");

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
        printf("\n=== test_rete_pool [%s] ===\n", tag);

#define RUN(t) do { \
    int _r = (t)(); \
    if (_r) { fprintf(stderr, "  FAIL [%s]: " #t "\n", tag); fails++; } \
    else    { printf("  pass [%s]: " #t "\n", tag); } \
} while (0)

        RUN(test_pool_basic_alloc_free);
        RUN(test_pool_objects_distinct);
        RUN(test_pool_zero_base_not_initialised);
        RUN(test_init_rt_pools_sets_ready);
        RUN(test_init_rt_pools_requires_rt_mode);
        RUN(test_pool_fact_alloc_on_assert);
        RUN(test_pool_fact_returned_on_retract);
        RUN(test_pool_token_embedded_facts);
        RUN(test_pool_token_copy_embedded);
        RUN(test_pool_non_rt_mode_unchanged);

#undef RUN

        if (fails == 0)
            printf("=== test_rete_pool [%s]: ALL PASSED ===\n", tag);
        else
            fprintf(stderr, "=== test_rete_pool [%s]: %d FAILED ===\n", tag, fails);
        total_fails += fails;
    }
    return total_fails ? 1 : 0;
}
