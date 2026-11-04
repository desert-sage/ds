/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * In realtime mode (rt_mode, pools ready, presz_rt_tables done) a pump makes
 * no malloc, calloc or realloc call, and the intern table, locked by
 * ds_rete_engine_presz_rt_tables, does not resize.
 *
 * The allocators are wrapped (libds.build's ImplTest `wrap` column) and count
 * calls while g_alloc_counting is set. The rule has a fire_fn and no ASSERT
 * action, so ridx_add never runs and DS_RIDX_INLINE overflow is excluded;
 * join rules are allocation-free while left_mem_size <= DS_RIDX_INLINE.
 */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include "libds.h"
#include "rete/beta.h"
#include "rete/engine.h"
#include "rete/intern.h"
#include "rete/loader.h"
#include "rete/pool.h"
#include "rete/schema.h"
#include "rete/schema_reg.h"
#include "rete/terminal.h"
#include "rete/token.h"
#include "rete/val.h"
#include "rete/wm_rete.h"

static volatile int  g_alloc_counting = 0;
static volatile long g_alloc_count    = 0;

void *__real_malloc(size_t sz);
void *__real_calloc(size_t n, size_t sz);
void *__real_realloc(void *p, size_t sz);

void *__wrap_malloc(size_t sz)
{
    if (g_alloc_counting) g_alloc_count++;
    return __real_malloc(sz);
}
void *__wrap_calloc(size_t n, size_t sz)
{
    if (g_alloc_counting) g_alloc_count++;
    return __real_calloc(n, sz);
}
void *__wrap_realloc(void *p, size_t sz)
{
    if (g_alloc_counting) g_alloc_count++;
    return __real_realloc(p, sz);
}

static int fail_msg(const char *msg)
{
    fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

static int g_fired = 0;
static void fire_cb(const char *r, ds_rete_token_t *t, void *ctx)
{
    (void)r; (void)t; (void)ctx;
    g_fired++;
}

/* Schema Trig(val:Int); one single-pattern rule with fire_fn (no actions). */
static ds_rete_engine_t *build_rt_engine(uint32_t wm_max)
{
    ds_rete_engine_t *e = NULL;
    if (ds_rete_engine_create(&e).status != DS_OK) return NULL;

    ds_rete_slot_desc_t slots[] = {{ .name="val", .type=DS_RETE_VAL_INT }};
    ds_rete_schema_t *sc = NULL;
    if (ds_rete_schema_register(e, "Trig", DS_RETE_SCOPE_PLAIN, 0,
                                slots, 1, &sc).status != DS_OK) goto fail;

    ds_alfa_atom_t alfa = { .node_id=1, .schema_name="Trig",
                            .tests=NULL, .test_count=0 };
    ds_beta_atom_t beta = { .node_id=2, .right_alpha_id=1,
                            .left_parent_id=0, .join_tests=NULL,
                            .join_test_count=0, .is_negative=false };
    ds_term_atom_t term = { .node_id=3, .parent_beta_id=2,
                            .rule_name="trig_rule",
                            .bind_count=1,
                            .actions=NULL, .action_count=0 };
    ds_rete_network_t net = { .alfas=&alfa, .alfa_count=1,
                              .betas=&beta, .beta_count=1,
                              .terms=&term, .term_count=1 };
    if (ds_rete_load_network(e, &net).status != DS_OK) goto fail;

    if (e->owned_terminal_count > 0)
        e->owned_terminals[0]->fire_fn = fire_cb;

    if (ds_rete_engine_set_wm_max(e, wm_max).status != DS_OK) goto fail;
    if (ds_rete_engine_set_rt_mode(e, true).status != DS_OK) goto fail;
    if (ds_rete_engine_init_rt_pools(e).status != DS_OK) goto fail;
    if (ds_rete_engine_presz_rt_tables(e).status != DS_OK) goto fail;
    /* ds_rete_run resets token_budget at cycle start: one empty cycle primes
       it before callers assert facts. */
    ds_rete_run(e, e->max_fires_rt, NULL);
    return e;

fail:
    ds_rete_engine_destroy(e);
    return NULL;
}

static int test_intern_zero_resize_after_lock(void)
{
    ds_rete_engine_t *e = build_rt_engine(64);
    if (!e) return fail_msg("build_rt_engine failed (intern test)");

    size_t before = ds_rete_intern_resize_count(e->intern);

    e->cycle_generation++;
    ds_rete_schema_t *sc = e->schemas_by_id[0];
    for (int i = 0; i < 32; i++) {
        ds_rete_val_t v = ds_rete_val_int((int64_t)i);
        ds_rete_fact_t *f = NULL;
        ds_rete_wm_assert(e, sc->id, &v, &f);
    }
    uint32_t fired = 0;
    g_fired = 0;
    ds_rete_run(e, 64, &fired);

    size_t after = ds_rete_intern_resize_count(e->intern);
    ds_rete_engine_destroy(e);

    if (after != before) {
        fprintf(stderr,
                "FAIL: intern resize_count changed %zu→%zu during RT pump\n",
                before, after);
        return 1;
    }
    if (g_fired == 0) return fail_msg("intern: no rules fired (setup problem)");
    return 0;
}

static int test_zero_malloc_during_rt_pump(void)
{
    ds_rete_engine_t *e = build_rt_engine(64);
    if (!e) return fail_msg("build_rt_engine failed (malloc test)");

    ds_rete_schema_t *sc = e->schemas_by_id[0];

    e->cycle_generation++;
    for (int i = 0; i < 16; i++) {
        ds_rete_val_t v = ds_rete_val_int((int64_t)i);
        ds_rete_fact_t *f = NULL;
        ds_rete_wm_assert(e, sc->id, &v, &f);
    }

    g_alloc_count = 0;
    g_alloc_counting = 1;

    uint32_t fired = 0;
    g_fired = 0;
    ds_rete_run(e, 64, &fired);

    g_alloc_counting = 0;
    long allocs = g_alloc_count;
    ds_rete_engine_destroy(e);

    if (allocs != 0) {
        fprintf(stderr,
                "FAIL: %ld malloc/calloc/realloc during RT pump (pre-filled)\n",
                allocs);
        return 1;
    }
    if (g_fired == 0) return fail_msg("malloc: no rules fired (setup problem)");
    return 0;
}

static int test_zero_malloc_assert_and_pump(void)
{
    ds_rete_engine_t *e = build_rt_engine(64);
    if (!e) return fail_msg("build_rt_engine failed (assert+pump test)");

    e->cycle_generation++;

    g_alloc_count = 0;
    g_alloc_counting = 1;

    ds_rete_val_t v = ds_rete_val_int(42);
    ds_rete_schema_t *sc = e->schemas_by_id[0];
    ds_rete_fact_t *f = NULL;
    ds_rete_wm_assert(e, sc->id, &v, &f);

    uint32_t fired = 0;
    g_fired = 0;
    ds_rete_run(e, e->max_fires_rt, &fired);

    g_alloc_counting = 0;
    long allocs = g_alloc_count;
    ds_rete_engine_destroy(e);

    if (allocs != 0) {
        fprintf(stderr,
                "FAIL: %ld malloc calls during RT assert+pump\n", allocs);
        return 1;
    }
    return 0;
}

int main(void)
{
    int fail = 0;

    printf("--- intern zero resize ---\n");
    fail |= test_intern_zero_resize_after_lock();

    printf("--- zero malloc during pump (pre-filled WM) ---\n");
    fail |= test_zero_malloc_during_rt_pump();

    printf("--- zero malloc during assert+pump ---\n");
    fail |= test_zero_malloc_assert_and_pump();

    if (!fail) printf("PASS: test_rete4_alloc\n");
    return fail;
}
