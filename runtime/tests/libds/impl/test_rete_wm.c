/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * Working memory: assert and retract, dispatch, no-op reassertion, N_max and
 * the RT flag (IRET.19, IRET.22.6, IRET.22.9).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "libds.h"
#include "rete/alpha.h"
#include "rete/dispatch.h"
#include "rete/engine.h"
#include "rete/fact.h"
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

static int expect_status(const char *what, ds_result_t r, int want)
{
    if (r.status != want) {
        fprintf(stderr, "FAIL: %s: want %d got %d (%s)\n",
                what, want, r.status, r.detail ? r.detail : "(null)");
        return 1;
    }
    return 0;
}

/* Build an engine with a Sensor schema: Int "value", Str "name" (identity). */
static ds_rete_engine_t *make_engine(ds_rete_schema_t **schema_out)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    ds_rete_slot_desc_t slots[] = {
        { .name = "value", .type = DS_RETE_VAL_INT,  .is_key = false },
        { .name = "name",  .type = DS_RETE_VAL_STR,  .is_key = true  },
    };
    ds_rete_schema_register(e, "Sensor", DS_RETE_SCOPE_PLAIN, 0,
                             slots, 2, schema_out);
    apply_rt(e, 0);
    return e;
}

/* Intern a string in the engine. */
static const char *istr(ds_rete_engine_t *e, const char *s)
{
    const char *p;
    ds_rete_intern_cstr(e->intern, s, &p);
    return p;
}

static int test_assert_basic(void)
{
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);

    ds_rete_val_t slots[] = {
        ds_rete_val_int(42),
        ds_rete_val_str(istr(e, "sensor_1"), 8),
    };
    ds_rete_fact_t *f = NULL;
    if (expect_ok("assert", ds_rete_wm_assert(e, 0, slots, &f))) return 1;
    if (!f) return fail("assert: out is NULL");
    if (f->id != 1) return fail("first fact should have id 1");
    if (f->schema != schema) return fail("schema pointer wrong");
    if (f->slots[0].i != 42) return fail("slot[0] value wrong");
    if (ds_rete_wm_count(e) != 1) return fail("wm_count should be 1");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_retract_basic(void)
{
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);

    ds_rete_val_t slots[] = {
        ds_rete_val_int(1),
        ds_rete_val_str(istr(e, "s1"), 2),
    };
    ds_rete_fact_t *f = NULL;
    ds_rete_wm_assert(e, 0, slots, &f);
    if (ds_rete_wm_count(e) != 1) return fail("pre-retract count != 1");

    if (expect_ok("retract", ds_rete_wm_retract(e, f))) return 1;
    if (ds_rete_wm_count(e) != 0) return fail("post-retract count != 0");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_multiple_facts(void)
{
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);

    for (int i = 0; i < 5; i++) {
        char name[16];
        snprintf(name, sizeof(name), "s%d", i);
        ds_rete_val_t slots[] = {
            ds_rete_val_int(i),
            ds_rete_val_str(istr(e, name), (uint32_t)strlen(name)),
        };
        ds_rete_fact_t *f = NULL;
        if (expect_ok("assert multi", ds_rete_wm_assert(e, 0, slots, &f)))
            return 1;
    }
    if (ds_rete_wm_count(e) != 5)
        return fail("wm_count should be 5");

    ds_rete_engine_destroy(e);
    return 0;
}

static int count_facts(ds_rete_fact_t *f, void *ctx)
{
    (void)f; (*(int *)ctx)++; return 0;
}

static int test_for_each_api(void)
{
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);

    for (int i = 0; i < 4; i++) {
        char nm[8]; snprintf(nm, sizeof(nm), "f%d", i);
        ds_rete_val_t slots[] = {
            ds_rete_val_int(i),
            ds_rete_val_str(istr(e, nm), (uint32_t)strlen(nm)),
        };
        ds_rete_fact_t *f = NULL;
        ds_rete_wm_assert(e, 0, slots, &f);
    }
    int n = 0;
    ds_rete_wm_for_each(e, count_facts, &n);
    if (n != 4) { fprintf(stderr, "FAIL: for_each_api: want 4 got %d\n", n); return 1; }
    ds_rete_engine_destroy(e);
    return 0;
}

static int test_noop_reassertion_equal(void)
{
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);

    ds_rete_val_t slots[] = {
        ds_rete_val_int(100),
        ds_rete_val_str(istr(e, "sensor_1"), 8),
    };
    ds_rete_fact_t *f1 = NULL;
    ds_rete_wm_assert(e, 0, slots, &f1);
    uint32_t id1 = f1->id;

    /* Re-assert identical slots → should return same fact, no new alloc */
    ds_rete_fact_t *f2 = NULL;
    if (expect_ok("noop assert", ds_rete_wm_assert(e, 0, slots, &f2))) return 1;
    if (f2 != f1) return fail("noop: should return same fact pointer");
    if (f2->id != id1) return fail("noop: fact id changed");
    if (ds_rete_wm_count(e) != 1) return fail("noop: count should stay 1");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_update_reassertion(void)
{
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);

    ds_rete_val_t s1[] = {
        ds_rete_val_int(10),
        ds_rete_val_str(istr(e, "sensor_1"), 8),
    };
    ds_rete_fact_t *f1 = NULL;
    ds_rete_wm_assert(e, 0, s1, &f1);
    uint32_t id1 = f1->id;

    /* Same identity key, different value → should retract old, assert new */
    ds_rete_val_t s2[] = {
        ds_rete_val_int(99),
        ds_rete_val_str(istr(e, "sensor_1"), 8),
    };
    ds_rete_fact_t *f2 = NULL;
    if (expect_ok("update assert", ds_rete_wm_assert(e, 0, s2, &f2))) return 1;
    /* Don't compare pointers — allocator may reuse the freed address. */
    if (f2->id == id1) return fail("update: should have a new id");
    if (f2->slots[0].i != 99) return fail("update: new slot value wrong");
    if (ds_rete_wm_count(e) != 1) return fail("update: count should still be 1");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_dispatch_to_alpha(void)
{
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);

    /* Alpha node: value == 42 */
    ds_rete_alpha_test_t test = {
        .kind       = DS_RETE_ALPHA_EQ,
        .slot_index = 0,
        .op         = DS_RETE_CMP_EQ,
        .literal    = ds_rete_val_int(42),
    };
    ds_rete_alpha_node_t *n = NULL;
    ds_rete_alpha_node_create(0, &test, 1, &n);
    if (expect_ok("dispatch_add", ds_rete_dispatch_add(e, 0, n))) return 1;

    ds_rete_val_t match[] = {
        ds_rete_val_int(42),
        ds_rete_val_str(istr(e, "a"), 1),
    };
    ds_rete_val_t miss[] = {
        ds_rete_val_int(99),
        ds_rete_val_str(istr(e, "b"), 1),
    };

    ds_rete_fact_t *fm = NULL, *fn2 = NULL;
    if (expect_ok("assert match", ds_rete_wm_assert(e, 0, match, &fm))) return 1;
    if (expect_ok("assert miss",  ds_rete_wm_assert(e, 0, miss,  &fn2))) return 1;

    /* Matching fact should be in the alpha node's memory. */
    if (!ds_rete_alpha_mem_contains(&n->memory, fm))
        return fail("dispatch: matching fact not in alpha memory");
    if (ds_rete_alpha_mem_contains(&n->memory, fn2))
        return fail("dispatch: non-matching fact should not be in alpha memory");
    if ((size_t)oa_len(&n->memory.map) != 1)
        return fail("dispatch: alpha memory n should be 1");

    /* Retract matching fact → should leave alpha memory. */
    if (expect_ok("retract match", ds_rete_wm_retract(e, fm))) return 1;
    if (ds_rete_alpha_mem_contains(&n->memory, fm))
        return fail("dispatch: fact still in alpha memory after retract");
    if ((size_t)oa_len(&n->memory.map) != 0)
        return fail("dispatch: alpha memory n should be 0 after retract");

    ds_rete_alpha_node_destroy(n);
    ds_rete_engine_destroy(e);
    return 0;
}

static int test_multiple_alpha_nodes(void)
{
    /* Two alpha nodes for the same schema; different filters. */
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);

    ds_rete_alpha_test_t t1 = {
        .kind = DS_RETE_ALPHA_CMP, .slot_index = 0,
        .op = DS_RETE_CMP_GT, .literal = ds_rete_val_int(50),
    };
    ds_rete_alpha_test_t t2 = {
        .kind = DS_RETE_ALPHA_CMP, .slot_index = 0,
        .op = DS_RETE_CMP_LT, .literal = ds_rete_val_int(20),
    };
    ds_rete_alpha_node_t *n1 = NULL, *n2 = NULL;
    ds_rete_alpha_node_create(0, &t1, 1, &n1);
    ds_rete_alpha_node_create(0, &t2, 1, &n2);
    ds_rete_dispatch_add(e, 0, n1);
    ds_rete_dispatch_add(e, 0, n2);

    /* value=70 → passes n1 (>50), fails n2 (<20) */
    ds_rete_val_t s1[] = {
        ds_rete_val_int(70),
        ds_rete_val_str(istr(e, "x"), 1),
    };
    ds_rete_fact_t *f1 = NULL;
    ds_rete_wm_assert(e, 0, s1, &f1);

    /* value=10 → fails n1, passes n2 */
    ds_rete_val_t s2[] = {
        ds_rete_val_int(10),
        ds_rete_val_str(istr(e, "y"), 1),
    };
    ds_rete_fact_t *f2 = NULL;
    ds_rete_wm_assert(e, 0, s2, &f2);

    if (!ds_rete_alpha_mem_contains(&n1->memory, f1))
        return fail("multi: f1 should be in n1");
    if (ds_rete_alpha_mem_contains(&n2->memory, f1))
        return fail("multi: f1 should not be in n2");
    if (ds_rete_alpha_mem_contains(&n1->memory, f2))
        return fail("multi: f2 should not be in n1");
    if (!ds_rete_alpha_mem_contains(&n2->memory, f2))
        return fail("multi: f2 should be in n2");

    ds_rete_alpha_node_destroy(n1);
    ds_rete_alpha_node_destroy(n2);
    ds_rete_engine_destroy(e);
    return 0;
}

static int test_null_rejection(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);

    ds_rete_fact_t *f = NULL;
    if (expect_status("assert NULL engine",
                      ds_rete_wm_assert(NULL, 0, NULL, &f),
                      DS_ERR_INVAL)) return 1;
    if (expect_status("assert NULL out",
                      ds_rete_wm_assert(e, 0, NULL, NULL),
                      DS_ERR_INVAL)) return 1;
    if (expect_status("assert unknown schema",
                      ds_rete_wm_assert(e, 99, NULL, &f),
                      DS_ERR_NOT_FOUND)) return 1;
    if (expect_status("retract NULL fact",
                      ds_rete_wm_retract(e, NULL),
                      DS_ERR_INVAL)) return 1;

    ds_rete_engine_destroy(e);
    return 0;
}

static int64_t fixed_clock(void *ctx) { return *(int64_t *)ctx; }

static int test_ttl_deadline(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    /* Use a fixed clock so deadline is deterministic */
    int64_t mock_time = 5000000000LL;
    ds_rete_set_clock(e, fixed_clock, &mock_time);
    ds_rete_slot_desc_t slots[] = {
        { .name = "id", .type = DS_RETE_VAL_STR, .is_key = true },
    };
    ds_rete_schema_t *ttl_schema = NULL;
    ds_rete_schema_register(e, "TtlFact", DS_RETE_SCOPE_TTL, 30000000000LL,
                             slots, 1, &ttl_schema);

    ds_rete_val_t sv[] = {
        ds_rete_val_str(istr(e, "k1"), 2),
    };
    ds_rete_fact_t *f = NULL;
    if (expect_ok("ttl assert", ds_rete_wm_assert(e, ttl_schema->id, sv, &f)))
        return 1;
    if (f->deadline_ns == 0)
        return fail("TTL fact: deadline_ns should be non-zero");
    /* deadline = assert_ns + 30s */
    if (f->deadline_ns != f->assert_ns + 30000000000LL)
        return fail("TTL fact: deadline_ns wrong");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_wm_max_rejects_at_limit(void)
{
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);

    /* Set N_max = 2 */
    if (expect_ok("set_wm_max", ds_rete_engine_set_wm_max(e, 2))) return 1;

    ds_rete_fact_t *f = NULL;
    ds_rete_val_t s1[] = { ds_rete_val_int(1), ds_rete_val_str(istr(e,"a"),1) };
    ds_rete_val_t s2[] = { ds_rete_val_int(2), ds_rete_val_str(istr(e,"b"),1) };
    ds_rete_val_t s3[] = { ds_rete_val_int(3), ds_rete_val_str(istr(e,"c"),1) };

    if (expect_ok("assert 1", ds_rete_wm_assert(e, 0, s1, &f))) return 1;
    if (expect_ok("assert 2", ds_rete_wm_assert(e, 0, s2, &f))) return 1;
    /* Third assert must fail with DS_ERR_WM_FULL */
    if (expect_status("assert 3 at limit",
                      ds_rete_wm_assert(e, 0, s3, &f),
                      DS_ERR_WM_FULL)) return 1;
    if (ds_rete_wm_count(e) != 2) return fail("wm_count should still be 2");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_wm_max_update_does_not_count(void)
{
    /* An identity update (retract old, insert new) is a replacement, not a
       net addition, so it does not hit N_max. */
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);

    if (expect_ok("set_wm_max", ds_rete_engine_set_wm_max(e, 1))) return 1;

    ds_rete_fact_t *f = NULL;
    ds_rete_val_t s1[] = { ds_rete_val_int(10), ds_rete_val_str(istr(e,"x"),1) };
    ds_rete_val_t s2[] = { ds_rete_val_int(20), ds_rete_val_str(istr(e,"x"),1) };

    if (expect_ok("assert", ds_rete_wm_assert(e, 0, s1, &f))) return 1;
    /* Same identity slot "x", different value → update.  Must succeed. */
    if (expect_ok("update", ds_rete_wm_assert(e, 0, s2, &f))) return 1;
    if (ds_rete_wm_count(e) != 1) return fail("wm_count should be 1 after update");
    if (f->slots[0].i != 20) return fail("updated value should be 20");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_wm_max_noop_does_not_count(void)
{
    /* A no-op reassertion (same value) must not count against N_max. */
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);

    if (expect_ok("set_wm_max", ds_rete_engine_set_wm_max(e, 1))) return 1;

    ds_rete_fact_t *f = NULL;
    ds_rete_val_t s1[] = { ds_rete_val_int(5), ds_rete_val_str(istr(e,"y"),1) };

    if (expect_ok("assert",  ds_rete_wm_assert(e, 0, s1, &f))) return 1;
    if (expect_ok("noop",    ds_rete_wm_assert(e, 0, s1, &f))) return 1;
    if (ds_rete_wm_count(e) != 1) return fail("wm_count should be 1 after noop");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_wm_max_zero_is_unlimited(void)
{
    /* wm_max_facts == 0 means unlimited — existing non-RT behaviour. */
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);

    /* Default is 0; just assert more than would normally fit in a small N_max */
    ds_rete_fact_t *f = NULL;
    char name[4] = {0};
    for (int i = 0; i < 10; i++) {
        name[0] = 'a' + (char)i;
        ds_rete_val_t s[] = {
            ds_rete_val_int(i),
            ds_rete_val_str(istr(e, name), 1),
        };
        if (expect_ok("assert unlimited", ds_rete_wm_assert(e, 0, s, &f)))
            return 1;
    }
    if (ds_rete_wm_count(e) != 10) return fail("wm_count should be 10");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_rt_mode_requires_wm_max(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);

    /* rt_mode with wm_max_facts == 0 must return DS_ERR_RT_UNSAFE */
    if (expect_status("rt_mode without wm_max",
                      ds_rete_engine_set_rt_mode(e, true),
                      DS_ERR_RT_UNSAFE)) return 1;

    /* Set N_max first, then enable rt_mode */
    if (expect_ok("set_wm_max", ds_rete_engine_set_wm_max(e, 100))) return 1;
    if (expect_ok("rt_mode ok", ds_rete_engine_set_rt_mode(e, true))) return 1;
    if (!e->rt_mode) return fail("rt_mode should be true");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_rt_mode_false_is_default(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    if (e->rt_mode) return fail("rt_mode should default to false");
    if (e->wm_max_facts != 0) return fail("wm_max_facts should default to 0");
    ds_rete_engine_destroy(e);
    return 0;
}

/* The WM table and the per-schema identity hash delete by backward shift; a
 * hole left mid probe chain would make a surviving fact unreachable by
 * ds_rete_wm_find_by_id. N distinct facts force rehashes; after each retract,
 * in insertion order, the removed id is gone and every surviving id is found.
 * Non-RT only: RT mode pre-sizes the tables and caps wm_max. */
static int test_wm_delete_under_collision(void)
{
    if (g_mode != 0) return 0;
    enum { N = 200 };
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);

    ds_rete_fact_t *facts[N];
    uint32_t ids[N];
    for (int i = 0; i < N; i++) {
        char name[24];
        snprintf(name, sizeof name, "wmcol%d", i);
        ds_rete_val_t slots[] = {
            ds_rete_val_int(i),
            ds_rete_val_str(istr(e, name), (uint32_t)strlen(name)),
        };
        facts[i] = NULL;
        if (expect_ok("assert", ds_rete_wm_assert(e, 0, slots, &facts[i]))) return 1;
        ids[i] = facts[i]->id;
    }
    if (ds_rete_wm_count(e) != N) return fail("count != N after asserts");

    for (int i = 0; i < N; i++) {
        if (expect_ok("retract", ds_rete_wm_retract(e, facts[i]))) return 1;
        if (ds_rete_wm_find_by_id(e, ids[i]) != NULL) {
            fprintf(stderr, "FAIL: retracted id %u still found\n", ids[i]);
            return 1;
        }
        if (ds_rete_wm_count(e) != (size_t)(N - 1 - i))
            return fail("wm_count wrong mid-retract");
        for (int j = i + 1; j < N; j++) {
            if (ds_rete_wm_find_by_id(e, ids[j]) == NULL) {
                fprintf(stderr, "FAIL: surviving id %u unreachable after "
                        "retracting %u (probe chain broken)\n", ids[j], ids[i]);
                return 1;
            }
        }
    }
    ds_rete_engine_destroy(e);
    return 0;
}

/* A partial alpha dispatch leaves no orphan: ds_rete_dispatch_assert inserts
 * into alpha nodes left to right and, when a later node refuses (here a
 * per-node contract capacity), rolls the earlier inserts back; the caller
 * frees the fact. Two no-test alpha nodes A and B share the schema, and B's
 * capacity is 1: the second assert fills A, breaches B, and must fail with A
 * holding only the first fact. */
static int test_dispatch_assert_atomic_on_breach(void)
{
    if (g_mode != 0) return 0;
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);

    ds_rete_alpha_node_t *A = NULL, *B = NULL;   /* no tests: match every fact */
    ds_rete_alpha_node_create(0, NULL, 0, &A);
    ds_rete_alpha_node_create(0, NULL, 0, &B);
    if (expect_ok("dispatch_add A", ds_rete_dispatch_add(e, 0, A))) return 1;
    if (expect_ok("dispatch_add B", ds_rete_dispatch_add(e, 0, B))) return 1;
    B->contract_capacity = 1;   /* white-box: normally set by the RT contract */

    ds_rete_val_t f1[] = { ds_rete_val_int(1), ds_rete_val_str(istr(e, "x1"), 2) };
    ds_rete_fact_t *fp = NULL;
    if (expect_ok("assert f1", ds_rete_wm_assert(e, 0, f1, &fp))) return 1;
    if ((size_t)oa_len(&A->memory.map) != 1 || (size_t)oa_len(&B->memory.map) != 1) return fail("setup: A,B should each hold f1");

    /* Second assert fills A then breaches B's cap → dispatch_assert must roll
       back, leaving A with only f1 and WM with only f1. */
    ds_rete_val_t f2[] = { ds_rete_val_int(2), ds_rete_val_str(istr(e, "x2"), 2) };
    ds_rete_fact_t *fp2 = NULL;
    ds_result_t r = ds_rete_wm_assert(e, 0, f2, &fp2);
    if (r.status != DS_ERR_CONTRACT_BREACH)
        return fail("expected CONTRACT_BREACH on the over-cap assert");
    if ((size_t)oa_len(&A->memory.map) != 1) {
        fprintf(stderr, "FAIL: (size_t)oa_len(&A->memory.map)=%zu after rolled-back assert (want 1) "
                "— orphaned (now-freed) fact left in alpha\n", (size_t)oa_len(&A->memory.map));
        return 1;
    }
    if (ds_rete_wm_count(e) != 1) return fail("WM should hold only f1 after breach");

    ds_rete_alpha_node_destroy(A);
    ds_rete_alpha_node_destroy(B);
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
        printf("\n=== test_rete_wm [%s] ===\n", tag);

#define RUN(t) do { \
    int _r = (t)(); \
    if (_r) { fprintf(stderr, "  FAIL [%s]: " #t "\n", tag); fails++; } \
    else    { printf("  pass [%s]: " #t "\n", tag); } \
} while (0)

        RUN(test_assert_basic);
        RUN(test_retract_basic);
        RUN(test_multiple_facts);
        RUN(test_for_each_api);
        RUN(test_noop_reassertion_equal);
        RUN(test_update_reassertion);
        RUN(test_dispatch_to_alpha);
        RUN(test_multiple_alpha_nodes);
        RUN(test_null_rejection);
        RUN(test_ttl_deadline);
        RUN(test_wm_max_rejects_at_limit);
        RUN(test_wm_max_update_does_not_count);
        RUN(test_wm_max_noop_does_not_count);
        RUN(test_wm_max_zero_is_unlimited);
        RUN(test_rt_mode_requires_wm_max);
        RUN(test_rt_mode_false_is_default);
        RUN(test_wm_delete_under_collision);
        RUN(test_dispatch_assert_atomic_on_breach);

#undef RUN

        if (fails == 0)
            printf("=== test_rete_wm [%s]: ALL PASSED ===\n", tag);
        else
            fprintf(stderr, "=== test_rete_wm [%s]: %d FAILED ===\n", tag, fails);
        total_fails += fails;
    }
    return total_fails ? 1 : 0;
}
