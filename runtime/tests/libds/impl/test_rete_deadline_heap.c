/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The TTL deadline min-heap under cap_dynamic_ttl: kept on assert and
 * retract, rooted at the earliest (deadline, fact id), drained by
 * wm_tick_ttl, allocated up front in RT mode and on the first TTL assert
 * otherwise. And the default mode's tick, which merges every schema's FIFO
 * front. main runs every test in both modes.
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

static const char *istr(ds_rete_engine_t *e, const char *s)
{
    const char *p;
    ds_rete_intern_cstr(e->intern, s, &p);
    return p;
}

/* Build an RT engine with TTL schema. */
static ds_rete_engine_t *make_rt_engine(ds_rete_schema_t **schema_out,
                                         uint32_t n_max,
                                         int64_t ttl_ns)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    e->cap_dynamic_ttl = true; /* heap-based TTL */
    ds_rete_slot_desc_t slots[] = {
        { .name = "v", .type = DS_RETE_VAL_INT, .is_key = false },
        { .name = "k", .type = DS_RETE_VAL_STR, .is_key = true  },
    };
    ds_rete_schema_register(e, "T", DS_RETE_SCOPE_TTL, ttl_ns,
                             slots, 2, schema_out);
    ds_rete_engine_set_wm_max(e, n_max);
    ds_rete_engine_set_rt_mode(e, true);
    ds_rete_engine_set_token_depth(e, 4);
    ds_rete_engine_init_rt_pools(e);

    ds_rete_set_clock(e, NULL, NULL); /* the default clock */
    return e;
}

/* Set a fixed mock clock on the engine. */
static int64_t g_mock_clock_ns = 0;
static int64_t mock_clock(void *ctx) { (void)ctx; return g_mock_clock_ns; }

static ds_rete_engine_t *make_rt_engine_mock(ds_rete_schema_t **schema_out,
                                               uint32_t n_max,
                                               int64_t ttl_ns)
{
    ds_rete_engine_t *e = make_rt_engine(schema_out, n_max, ttl_ns);
    ds_rete_set_clock(e, mock_clock, NULL);
    g_mock_clock_ns = 0;
    return e;
}

static int test_heap_enabled_in_rt_mode(void)
{
    SKIP_IF_NON_RT;
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_rt_engine_mock(&schema, 8, 1000);

    if (e->deadline_heap_items == NULL)
        return fail("deadline_heap_items should be non-NULL in RT mode");
    if (e->deadline_heap_cap != 8)
        return fail("deadline_heap_cap should equal N_max");
    if (e->deadline_heap_count != 0)
        return fail("heap count should start at 0");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_heap_null_in_non_rt_mode(void)
{
    SKIP_IF_RT;
    /* The heap starts NULL before any TTL fact is asserted. */
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    e->cap_dynamic_ttl = true; /* heap-based TTL */
    if (e->deadline_heap_items != NULL)
        return fail("deadline_heap_items should be NULL before any TTL assert");
    ds_rete_engine_destroy(e);
    return 0;
}

static int test_fact_added_to_heap_on_assert(void)
{
    SKIP_IF_NON_RT;
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_rt_engine_mock(&schema, 8, 1000);

    ds_rete_val_t s[] = { ds_rete_val_int(1), ds_rete_val_str(istr(e,"a"),1) };
    ds_rete_fact_t *f = NULL;
    if (expect_ok("assert", ds_rete_wm_assert(e, 0, s, &f))) return 1;

    /* TTL fact should be in heap */
    if (f->deadline_heap_idx == UINT32_MAX)
        return fail("TTL fact should have valid heap index");
    if (e->deadline_heap_count != 1)
        return fail("heap count should be 1");
    if (e->deadline_heap_items[f->deadline_heap_idx] != f)
        return fail("heap item at idx should point back to fact");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_no_deadline_not_in_heap(void)
{
    SKIP_IF_NON_RT;
    /* A plain-scoped fact with no TTL should NOT be in the heap. */
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    e->cap_dynamic_ttl = true; /* heap-based TTL */
    ds_rete_slot_desc_t slots[] = {
        { .name = "v", .type = DS_RETE_VAL_INT, .is_key = false },
        { .name = "k", .type = DS_RETE_VAL_STR, .is_key = true  },
    };
    ds_rete_schema_t *schema = NULL;
    ds_rete_schema_register(e, "P", DS_RETE_SCOPE_PLAIN, 0, slots, 2, &schema);
    ds_rete_engine_set_wm_max(e, 8);
    ds_rete_engine_set_rt_mode(e, true);
    ds_rete_engine_init_rt_pools(e);
    ds_rete_set_clock(e, mock_clock, NULL);
    g_mock_clock_ns = 0;

    ds_rete_val_t s[] = { ds_rete_val_int(7), ds_rete_val_str(istr(e,"x"),1) };
    ds_rete_fact_t *f = NULL;
    if (expect_ok("assert plain", ds_rete_wm_assert(e, 0, s, &f))) return 1;

    if (f->deadline_ns != 0)
        return fail("plain fact should have no deadline");
    if (f->deadline_heap_idx != UINT32_MAX)
        return fail("plain fact should not be in heap");
    if (e->deadline_heap_count != 0)
        return fail("heap should remain empty for plain facts");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_fact_removed_from_heap_on_retract(void)
{
    SKIP_IF_NON_RT;
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_rt_engine_mock(&schema, 8, 1000);

    ds_rete_val_t s[] = { ds_rete_val_int(1), ds_rete_val_str(istr(e,"a"),1) };
    ds_rete_fact_t *f = NULL;
    if (expect_ok("assert", ds_rete_wm_assert(e, 0, s, &f))) return 1;
    if (e->deadline_heap_count != 1) return fail("heap count should be 1");

    if (expect_ok("retract", ds_rete_wm_retract(e, f))) return 1;
    if (e->deadline_heap_count != 0)
        return fail("heap count should be 0 after retract");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_heap_order_earliest_first(void)
{
    SKIP_IF_NON_RT;
    /* Assert three TTL facts with different deadlines.
       The heap should order them by earliest deadline. */
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_rt_engine_mock(&schema, 8, 0);

    ds_rete_fact_t *f1 = NULL, *f2 = NULL, *f3 = NULL;

    /* A schema with ttl=0 gives its facts no deadline, so this engine cannot
       order anything: it is dropped for one whose schema carries a TTL. */
    ds_rete_engine_destroy(e);

    schema = NULL;
    e = NULL;
    ds_rete_engine_create(&e);
    e->cap_dynamic_ttl = true; /* heap-based TTL */
    ds_rete_slot_desc_t slots[] = {
        { .name = "v", .type = DS_RETE_VAL_INT, .is_key = false },
        { .name = "k", .type = DS_RETE_VAL_STR, .is_key = true  },
    };
    ds_rete_schema_register(e, "T", DS_RETE_SCOPE_TTL, 1000 /* ns */,
                             slots, 2, &schema);
    ds_rete_engine_set_wm_max(e, 8);
    ds_rete_engine_set_rt_mode(e, true);
    ds_rete_engine_set_token_depth(e, 4);
    ds_rete_engine_init_rt_pools(e);
    ds_rete_set_clock(e, mock_clock, NULL);

    /* Assert at t=100: deadline = 100+1000 = 1100 */
    g_mock_clock_ns = 100;
    ds_rete_val_t sa[] = { ds_rete_val_int(1), ds_rete_val_str(istr(e,"a"),1) };
    if (expect_ok("assert a", ds_rete_wm_assert(e, 0, sa, &f1))) return 1;

    /* Assert at t=50: deadline = 50+1000 = 1050 (earlier!) */
    g_mock_clock_ns = 50;
    ds_rete_val_t sb[] = { ds_rete_val_int(2), ds_rete_val_str(istr(e,"b"),1) };
    if (expect_ok("assert b", ds_rete_wm_assert(e, 0, sb, &f2))) return 1;

    /* Assert at t=200: deadline = 200+1000 = 1200 (latest) */
    g_mock_clock_ns = 200;
    ds_rete_val_t sc[] = { ds_rete_val_int(3), ds_rete_val_str(istr(e,"c"),1) };
    if (expect_ok("assert c", ds_rete_wm_assert(e, 0, sc, &f3))) return 1;

    if (e->deadline_heap_count != 3)
        return fail("heap count should be 3");

    /* Heap root (index 0) must be the fact with the earliest deadline. */
    ds_rete_fact_t *root = e->deadline_heap_items[0];
    if (root->deadline_ns != 1050)
        return fail("heap root should be earliest deadline (1050)");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_tick_ttl_uses_heap(void)
{
    SKIP_IF_NON_RT;
    /* Assert 3 TTL facts with different deadlines.
       Advance clock past 2 of them and verify tick_ttl retracts exactly 2,
       leaving the third. Heap should have 1 entry after tick. */
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    e->cap_dynamic_ttl = true; /* heap-based TTL */
    ds_rete_slot_desc_t slots[] = {
        { .name = "v", .type = DS_RETE_VAL_INT, .is_key = false },
        { .name = "k", .type = DS_RETE_VAL_STR, .is_key = true  },
    };
    ds_rete_schema_t *schema = NULL;
    ds_rete_schema_register(e, "T", DS_RETE_SCOPE_TTL, 100,
                             slots, 2, &schema);
    ds_rete_engine_set_wm_max(e, 8);
    ds_rete_engine_set_rt_mode(e, true);
    ds_rete_engine_set_token_depth(e, 4);
    ds_rete_engine_init_rt_pools(e);
    ds_rete_set_clock(e, mock_clock, NULL);

    /* deadlines: 0+100=100, 50+100=150, 200+100=300 */
    ds_rete_fact_t *f1 = NULL, *f2 = NULL, *f3 = NULL;
    g_mock_clock_ns = 0;
    ds_rete_val_t sa[] = { ds_rete_val_int(1), ds_rete_val_str(istr(e,"a"),1) };
    if (expect_ok("a", ds_rete_wm_assert(e, 0, sa, &f1))) return 1;
    g_mock_clock_ns = 50;
    ds_rete_val_t sb[] = { ds_rete_val_int(2), ds_rete_val_str(istr(e,"b"),1) };
    if (expect_ok("b", ds_rete_wm_assert(e, 0, sb, &f2))) return 1;
    g_mock_clock_ns = 200;
    ds_rete_val_t sc[] = { ds_rete_val_int(3), ds_rete_val_str(istr(e,"c"),1) };
    if (expect_ok("c", ds_rete_wm_assert(e, 0, sc, &f3))) return 1;

    if (e->deadline_heap_count != 3)
        return fail("heap count should be 3 before tick");

    /* Advance clock to 160 — facts at 100 and 150 expire, 300 doesn't. */
    size_t retracted = 0;
    if (expect_ok("tick_ttl", ds_rete_wm_tick_ttl(e, 160, &retracted)))
        return 1;

    if (retracted != 2)
        return fail("should retract 2 facts");
    if (ds_rete_wm_count(e) != 1)
        return fail("WM should have 1 fact remaining");
    if (e->deadline_heap_count != 1)
        return fail("heap count should be 1 after tick");

    /* Remaining fact in heap must be f3 (deadline=300). */
    if (e->deadline_heap_items[0]->deadline_ns != 300)
        return fail("remaining heap entry should have deadline 300");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_tick_ttl_non_rt_scan(void)
{
    SKIP_IF_RT;
    /* Outside RT mode the heap is allocated on the first TTL assert. */
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    e->cap_dynamic_ttl = true; /* heap-based TTL */
    ds_rete_slot_desc_t slots[] = {
        { .name = "v", .type = DS_RETE_VAL_INT, .is_key = false },
        { .name = "k", .type = DS_RETE_VAL_STR, .is_key = true  },
    };
    ds_rete_schema_t *schema = NULL;
    ds_rete_schema_register(e, "T", DS_RETE_SCOPE_TTL, 100, slots, 2, &schema);
    ds_rete_set_clock(e, mock_clock, NULL);

    g_mock_clock_ns = 0;
    ds_rete_fact_t *f = NULL;
    ds_rete_val_t s[] = { ds_rete_val_int(1), ds_rete_val_str(istr(e,"x"),1) };
    if (expect_ok("assert non-RT", ds_rete_wm_assert(e, 0, s, &f))) return 1;

    /* After asserting a TTL fact the heap is lazily allocated. */
    if (e->deadline_heap_items == NULL)
        return fail("deadline_heap should be lazily allocated after TTL assert");
    if (e->deadline_heap_count != 1)
        return fail("heap should contain 1 fact after assert");

    size_t retracted = 0;
    if (expect_ok("tick_ttl non-RT",
                  ds_rete_wm_tick_ttl(e, 200, &retracted))) return 1;
    if (retracted != 1)
        return fail("non-RT heap should retract 1 expired fact");
    if (ds_rete_wm_count(e) != 0)
        return fail("WM should be empty");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_heap_consistent_after_retract_mid_heap(void)
{
    SKIP_IF_NON_RT;
    /* Retract the middle-priority fact; heap should remain valid. */
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    e->cap_dynamic_ttl = true; /* heap-based TTL */
    ds_rete_slot_desc_t slots[] = {
        { .name = "v", .type = DS_RETE_VAL_INT, .is_key = false },
        { .name = "k", .type = DS_RETE_VAL_STR, .is_key = true  },
    };
    ds_rete_schema_t *schema = NULL;
    ds_rete_schema_register(e, "T", DS_RETE_SCOPE_TTL, 100, slots, 2, &schema);
    ds_rete_engine_set_wm_max(e, 8);
    ds_rete_engine_set_rt_mode(e, true);
    ds_rete_engine_set_token_depth(e, 4);
    ds_rete_engine_init_rt_pools(e);
    ds_rete_set_clock(e, mock_clock, NULL);

    /* Deadlines: a=100, b=150, c=300 */
    ds_rete_fact_t *fa=NULL, *fb=NULL, *fc=NULL;
    g_mock_clock_ns = 0;
    ds_rete_val_t sa[] = { ds_rete_val_int(1), ds_rete_val_str(istr(e,"a"),1) };
    ds_rete_wm_assert(e, 0, sa, &fa);
    g_mock_clock_ns = 50;
    ds_rete_val_t sb[] = { ds_rete_val_int(2), ds_rete_val_str(istr(e,"b"),1) };
    ds_rete_wm_assert(e, 0, sb, &fb);
    g_mock_clock_ns = 200;
    ds_rete_val_t sc[] = { ds_rete_val_int(3), ds_rete_val_str(istr(e,"c"),1) };
    ds_rete_wm_assert(e, 0, sc, &fc);

    /* Retract the middle fact (b, deadline=150). */
    if (expect_ok("retract b", ds_rete_wm_retract(e, fb))) return 1;
    if (e->deadline_heap_count != 2)
        return fail("heap count should be 2 after retract");

    /* Root must still be the earliest deadline (a=100). */
    if (e->deadline_heap_items[0]->deadline_ns != 100)
        return fail("heap root should be 100 after removing middle");

    /* Tick at 110 — only a (100) expires. */
    size_t retracted = 0;
    if (expect_ok("tick 110", ds_rete_wm_tick_ttl(e, 110, &retracted))) return 1;
    if (retracted != 1) return fail("should retract 1");
    if (e->deadline_heap_count != 1) return fail("heap count should be 1");
    if (e->deadline_heap_items[0]->deadline_ns != 300)
        return fail("remaining should have deadline 300");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_ttl_expiry_correctness(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    e->cap_dynamic_ttl = true; /* heap-based TTL */
    ds_rete_slot_desc_t slots[] = {
        { .name = "v", .type = DS_RETE_VAL_INT, .is_key = false },
        { .name = "k", .type = DS_RETE_VAL_STR, .is_key = true  },
    };
    ds_rete_schema_t *schema = NULL;
    ds_rete_schema_register(e, "T", DS_RETE_SCOPE_TTL, 100, slots, 2, &schema);
    apply_rt(e, 16);
    ds_rete_set_clock(e, mock_clock, NULL);

    /* deadline = assert_ns + 100 */
    g_mock_clock_ns = 0;
    ds_rete_fact_t *fa = NULL;
    ds_rete_val_t sa[] = { ds_rete_val_int(1), ds_rete_val_str(istr(e,"a"),1) };
    if (expect_ok("assert a", ds_rete_wm_assert(e, 0, sa, &fa))) return 1;

    g_mock_clock_ns = 50;
    ds_rete_fact_t *fb = NULL;
    ds_rete_val_t sb[] = { ds_rete_val_int(2), ds_rete_val_str(istr(e,"b"),1) };
    if (expect_ok("assert b", ds_rete_wm_assert(e, 0, sb, &fb))) return 1;

    g_mock_clock_ns = 200;
    ds_rete_fact_t *fc = NULL;
    ds_rete_val_t sc[] = { ds_rete_val_int(3), ds_rete_val_str(istr(e,"c"),1) };
    if (expect_ok("assert c", ds_rete_wm_assert(e, 0, sc, &fc))) return 1;

    /* deadlines: a=100, b=150, c=300 */
    if (ds_rete_wm_count(e) != 3) return fail("expect 3 facts");

    /* tick at 160: a and b expire, c stays */
    size_t retracted = 0;
    if (expect_ok("tick 160", ds_rete_wm_tick_ttl(e, 160, &retracted))) return 1;
    if (retracted != 2) return fail("should retract 2 at t=160");
    if (ds_rete_wm_count(e) != 1) return fail("1 fact should remain");

    /* tick at 400: c expires */
    if (expect_ok("tick 400", ds_rete_wm_tick_ttl(e, 400, &retracted))) return 1;
    if (retracted != 1) return fail("should retract 1 at t=400");
    if (ds_rete_wm_count(e) != 0) return fail("WM should be empty");

    ds_rete_engine_destroy(e);
    return 0;
}

/* [LDET.5.11]: facts that fall due at one deadline leave
 * in working-memory entry order, which is the fact id. The drain pops the
 * heap's root, so the property is that the root of a tie is the oldest fact,
 * whatever the heap's history.
 *
 * The history: a, b, c, d asserted at one instant (one deadline), then a
 * retracted. A heap removal moves the last item (d) into the hole and sifts
 * it. Compared on the deadline alone, d ties with its children and stays at
 * the root, so d would leave before b and c, its elders. Compared on
 * (deadline, id), b rises. */
/* @spec [LDET.5.11] */
static int test_equal_deadlines_leave_in_entry_order(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    e->cap_dynamic_ttl = true;
    ds_rete_slot_desc_t slots[] = {
        { .name = "v", .type = DS_RETE_VAL_INT, .is_key = false },
        { .name = "k", .type = DS_RETE_VAL_STR, .is_key = true  },
    };
    ds_rete_schema_t *schema = NULL;
    ds_rete_schema_register(e, "T", DS_RETE_SCOPE_TTL, 100, slots, 2, &schema);
    apply_rt(e, 16);
    ds_rete_set_clock(e, mock_clock, NULL);

    g_mock_clock_ns = 0;                    /* every deadline is 100 */
    ds_rete_fact_t *fa = NULL, *fb = NULL, *fc = NULL, *fd = NULL;
    ds_rete_val_t sa[] = { ds_rete_val_int(1), ds_rete_val_str(istr(e,"a"),1) };
    ds_rete_val_t sb[] = { ds_rete_val_int(2), ds_rete_val_str(istr(e,"b"),1) };
    ds_rete_val_t sc[] = { ds_rete_val_int(3), ds_rete_val_str(istr(e,"c"),1) };
    ds_rete_val_t sd[] = { ds_rete_val_int(4), ds_rete_val_str(istr(e,"d"),1) };
    if (expect_ok("assert a", ds_rete_wm_assert(e, 0, sa, &fa))) return 1;
    if (expect_ok("assert b", ds_rete_wm_assert(e, 0, sb, &fb))) return 1;
    if (expect_ok("assert c", ds_rete_wm_assert(e, 0, sc, &fc))) return 1;
    if (expect_ok("assert d", ds_rete_wm_assert(e, 0, sd, &fd))) return 1;
    if (!(fa->id < fb->id && fb->id < fc->id && fc->id < fd->id))
        return fail("precondition: ids increase with entry");
    if (fa->deadline_ns != fd->deadline_ns)
        return fail("precondition: one deadline for all four");
    if (e->deadline_heap_items[0] != fa)
        return fail("the root of a tie is the oldest fact (a)");

    if (expect_ok("retract a", ds_rete_wm_retract(e, fa))) return 1;
    if (e->deadline_heap_items[0] != fb)
        return fail("after a leaves, the root is b, the oldest left -- "
                    "not d, which the removal moved into the hole");

    /* The drain, one pop at a time: b, then c, then d. */
    const ds_rete_fact_t *want[] = { fb, fc, fd };
    for (int i = 0; i < 3; i++) {
        ds_rete_fact_t *root = e->deadline_heap_items[0];
        if (root != want[i])
            return fail("equal deadlines drain in entry order: b, c, d");
        if (expect_ok("retract root", ds_rete_wm_retract(e, root))) return 1;
    }
    if (e->deadline_heap_count != 0) return fail("heap empty after the drain");

    ds_rete_engine_destroy(e);
    return 0;
}

/* [LDET.5.11], [LDTL.6.1]: the default-mode tick merges the TTL schemas' FIFO
 * fronts rather than draining each schema in load order. Slow (ttl 300) is
 * registered before Fast (ttl 100); Slow's fact enters at 0 (deadline 300)
 * and Fast's at 150 (deadline 250), so the tick at 300 has two fronts due,
 * from two schemas.
 *
 * WHAT THIS PINS: the merge expires exactly what is due -- nothing at 200,
 * both at 300 -- and returns. It does not pin the ORDER of the two: the rete
 * engine has no retraction hook to observe it by. The order is pinned where a
 * DS engine expires facts, the wrapper sweep, by the lockstep pairs of
 * 129_ttl_cross_schema with 96_ttl_cross_host and 97_ttl_cross_emit. */
static int test_default_ttl_tick_merges_schemas(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);            /* default mode: cap_dynamic_ttl false */
    ds_rete_slot_desc_t slots[] = {
        { .name = "v", .type = DS_RETE_VAL_INT, .is_key = false },
        { .name = "k", .type = DS_RETE_VAL_STR, .is_key = true  },
    };
    ds_rete_schema_t *slow = NULL, *fast = NULL;
    ds_rete_schema_register(e, "Slow", DS_RETE_SCOPE_TTL, 300, slots, 2, &slow);
    ds_rete_schema_register(e, "Fast", DS_RETE_SCOPE_TTL, 100, slots, 2, &fast);
    apply_rt(e, 16);
    ds_rete_set_clock(e, mock_clock, NULL);

    ds_rete_fact_t *fs = NULL, *ff = NULL;
    g_mock_clock_ns = 0;
    ds_rete_val_t ss[] = { ds_rete_val_int(1), ds_rete_val_str(istr(e,"s"),1) };
    if (expect_ok("assert slow", ds_rete_wm_assert(e, slow->id, ss, &fs))) return 1;
    g_mock_clock_ns = 150;
    ds_rete_val_t sf[] = { ds_rete_val_int(2), ds_rete_val_str(istr(e,"f"),1) };
    if (expect_ok("assert fast", ds_rete_wm_assert(e, fast->id, sf, &ff))) return 1;
    if (fs->deadline_ns != 300 || ff->deadline_ns != 250)
        return fail("precondition: deadlines 300 (Slow) and 250 (Fast)");

    size_t retracted = 0;
    if (expect_ok("tick 200", ds_rete_wm_tick_ttl(e, 200, &retracted))) return 1;
    if (retracted != 0 || ds_rete_wm_count(e) != 2)
        return fail("nothing is due at 200");
    if (expect_ok("tick 300", ds_rete_wm_tick_ttl(e, 300, &retracted))) return 1;
    if (retracted != 2 || ds_rete_wm_count(e) != 0)
        return fail("both fronts are due at 300, from two schemas");

    ds_rete_engine_destroy(e);
    return 0;
}

/* @spec [RARC.5.2.4]
 * The default-mode tick expires a fact with a deadline whatever its schema's
 * scope. A capture fact ([LCCO.5.3]) is the case: its schema is explicit, and
 * the compiler asserts it with its lifetime as an override. One explicit fact
 * carries a 100 ns override and one carries none; the first leaves at 100, the
 * second stays. A tick that merges only `ttl` schemas leaves both. */
static int test_rarc_5_2_4__a_deadline_expires_whatever_the_scope(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);            /* default mode: cap_dynamic_ttl false */
    ds_rete_slot_desc_t slots[] = {
        { .name = "v", .type = DS_RETE_VAL_INT, .is_key = false },
        { .name = "k", .type = DS_RETE_VAL_STR, .is_key = true  },
    };
    ds_rete_schema_t *plain = NULL;
    ds_rete_schema_register(e, "Cap", DS_RETE_SCOPE_PLAIN, 0, slots, 2, &plain);
    if (!plain) return fail("schema register");
    apply_rt(e, 16);
    ds_rete_set_clock(e, mock_clock, NULL);

    g_mock_clock_ns = 0;
    ds_rete_fact_t *kept = NULL, *timed = NULL;
    ds_rete_val_t sk[] = { ds_rete_val_int(1), ds_rete_val_str(istr(e,"a"),1) };
    if (expect_ok("assert kept", ds_rete_wm_assert(e, plain->id, sk, &kept)))
        return 1;
    e->pending_ttl_override_ns = 100;
    ds_rete_val_t st[] = { ds_rete_val_int(2), ds_rete_val_str(istr(e,"b"),1) };
    ds_result_t r = ds_rete_wm_assert(e, plain->id, st, &timed);
    e->pending_ttl_override_ns = 0;
    if (expect_ok("assert timed", r)) return 1;
    if (kept->deadline_ns != 0 || timed->deadline_ns != 100)
        return fail("precondition: deadlines 0 and 100");
    const uint32_t kept_id = kept->id;

    size_t retracted = 0;
    if (expect_ok("tick 99", ds_rete_wm_tick_ttl(e, 99, &retracted))) return 1;
    if (retracted != 0 || ds_rete_wm_count(e) != 2)
        return fail("nothing is due at 99");
    if (expect_ok("tick 100", ds_rete_wm_tick_ttl(e, 100, &retracted))) return 1;
    if (retracted != 1 || ds_rete_wm_count(e) != 1)
        return fail("the explicit fact due at 100 is expired");
    if (ds_rete_wm_find_by_id(e, kept_id) == NULL)
        return fail("the fact with no deadline stays");

    ds_rete_engine_destroy(e);
    return 0;
}

/* More TTL schemas than the merge's stack heap holds (TTL_FRONT_STACK, 32).
 * Outside the realtime pools the heap is allocated; with them engaged the
 * tick takes the linear-scan merge instead and allocates nothing. This file
 * runs in both modes, so the two passes drive the two paths. */
static int test_default_ttl_tick_many_schemas(void)
{
    enum { N = 40 };
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    ds_rete_slot_desc_t slots[] = {
        { .name = "v", .type = DS_RETE_VAL_INT, .is_key = false },
        { .name = "k", .type = DS_RETE_VAL_STR, .is_key = true  },
    };
    static char names[N][8];
    ds_rete_schema_t *sch[N];
    for (int i = 0; i < N; i++) {
        snprintf(names[i], sizeof names[i], "S%d", i);
        sch[i] = NULL;
        ds_rete_schema_register(e, names[i], DS_RETE_SCOPE_TTL, 100,
                                slots, 2, &sch[i]);
        if (!sch[i]) return fail("schema register");
    }
    apply_rt(e, 64);
    ds_rete_set_clock(e, mock_clock, NULL);

    g_mock_clock_ns = 0;
    for (int i = 0; i < N; i++) {
        ds_rete_fact_t *f = NULL;
        ds_rete_val_t s[] = { ds_rete_val_int(i), ds_rete_val_str(istr(e,"k"),1) };
        if (expect_ok("assert", ds_rete_wm_assert(e, sch[i]->id, s, &f))) return 1;
    }
    size_t retracted = 0;
    if (expect_ok("tick 50", ds_rete_wm_tick_ttl(e, 50, &retracted))) return 1;
    if (retracted != 0 || ds_rete_wm_count(e) != N)
        return fail("nothing is due at 50");
    if (expect_ok("tick 100", ds_rete_wm_tick_ttl(e, 100, &retracted))) return 1;
    if (retracted != N || ds_rete_wm_count(e) != 0)
        return fail("every schema's front is due at 100");

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
        printf("\n=== test_rete_deadline_heap [%s] ===\n", tag);

#define RUN(t) do { \
    int _r = (t)(); \
    if (_r) { fprintf(stderr, "  FAIL [%s]: " #t "\n", tag); fails++; } \
    else    { printf("  pass [%s]: " #t "\n", tag); } \
} while (0)

        RUN(test_heap_enabled_in_rt_mode);
        RUN(test_heap_null_in_non_rt_mode);
        RUN(test_fact_added_to_heap_on_assert);
        RUN(test_no_deadline_not_in_heap);
        RUN(test_fact_removed_from_heap_on_retract);
        RUN(test_heap_order_earliest_first);
        RUN(test_tick_ttl_uses_heap);
        RUN(test_tick_ttl_non_rt_scan);
        RUN(test_heap_consistent_after_retract_mid_heap);
        RUN(test_ttl_expiry_correctness);
        RUN(test_equal_deadlines_leave_in_entry_order);
        RUN(test_default_ttl_tick_merges_schemas);
        RUN(test_rarc_5_2_4__a_deadline_expires_whatever_the_scope);
        RUN(test_default_ttl_tick_many_schemas);

#undef RUN

        if (fails == 0)
            printf("=== test_rete_deadline_heap [%s]: ALL PASSED ===\n", tag);
        else
            fprintf(stderr, "=== test_rete_deadline_heap [%s]: %d FAILED ===\n",
                    tag, fails);
        total_fails += fails;
    }
    return total_fails ? 1 : 0;
}
