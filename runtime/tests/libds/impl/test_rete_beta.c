/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * Tokens, the beta join and the NOT node (IRET.7, IRET.22.2, IRET.22.3).
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
#include "rete/fact.h"
#include "rete/schema.h"
#include "rete/schema_reg.h"
#include "rete/token.h"
#include "rete/val.h"
#include "rete/wm_rete.h"
#include "oa.h"               /* OA_LIST_INLINE — sizes the overflow trigger */

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

typedef struct {
    ds_rete_engine_t *engine;
    ds_rete_schema_t *schema;      /* two slots: Int "val", Str "id" (identity) */
    ds_rete_alpha_node_t *alpha_all; /* no tests — admits every fact */
    ds_rete_alpha_node_t *alpha_gt5; /* val > 5 */
} Ctx;

static const char *istr(ds_rete_engine_t *e, const char *s)
{
    const char *p; ds_rete_intern_cstr(e->intern, s, &p); return p;
}

static Ctx make_ctx(void)
{
    Ctx c = {0};
    ds_rete_engine_create(&c.engine);

    ds_rete_slot_desc_t slots[] = {
        { .name = "val", .type = DS_RETE_VAL_INT, .is_key = false },
        { .name = "id",  .type = DS_RETE_VAL_STR, .is_key = true  },
    };
    ds_rete_schema_register(c.engine, "Ev", DS_RETE_SCOPE_PLAIN, 0,
                             slots, 2, &c.schema);

    ds_rete_alpha_node_create(0, NULL, 0, &c.alpha_all);
    ds_rete_dispatch_add(c.engine, 0, c.alpha_all);

    ds_rete_alpha_test_t t = {
        .kind = DS_RETE_ALPHA_CMP, .slot_index = 0,
        .op = DS_RETE_CMP_GT, .literal = ds_rete_val_int(5),
    };
    ds_rete_alpha_node_create(0, &t, 1, &c.alpha_gt5);
    ds_rete_dispatch_add(c.engine, 0, c.alpha_gt5);

    return c;
}

static void destroy_ctx(Ctx *c)
{
    ds_rete_alpha_node_destroy(c->alpha_all);
    ds_rete_alpha_node_destroy(c->alpha_gt5);
    ds_rete_engine_destroy(c->engine);
}

static ds_rete_fact_t *assert_fact(Ctx *c, int64_t val, const char *id)
{
    ds_rete_val_t slots[] = {
        ds_rete_val_int(val),
        ds_rete_val_str(istr(c->engine, id), (uint32_t)strlen(id)),
    };
    ds_rete_fact_t *f = NULL;
    ds_rete_wm_assert(c->engine, 0, slots, &f);
    return f;
}

static int test_token_create_root(void)
{
    Ctx c = make_ctx();
    ds_rete_fact_t *f = assert_fact(&c, 1, "a");

    ds_result_t err;
    ds_rete_token_t *t = ds_rete_token_create(NULL, f, 0, NULL, NULL, &err);
    if (!t || err.status != DS_OK) return fail("token_create root failed");
    if (t->fact_count != 1) return fail("root token: fact_count != 1");
    if (t->facts[0] != f) return fail("root token: wrong fact ptr");

    ds_rete_token_free(t);
    destroy_ctx(&c);
    return 0;
}

static int test_token_extend(void)
{
    Ctx c = make_ctx();
    ds_rete_fact_t *f1 = assert_fact(&c, 1, "a");
    ds_rete_fact_t *f2 = assert_fact(&c, 2, "b");

    ds_result_t err;
    ds_rete_token_t *t1 = ds_rete_token_create(NULL, f1, 10, NULL, NULL, &err);
    ds_rete_token_t *t2 = ds_rete_token_create(t1, f2, 20, NULL, NULL, &err);

    if (t2->fact_count != 2) return fail("extended token: fact_count != 2");
    if (t2->facts[0] != f1) return fail("extended token: facts[0] wrong");
    if (t2->facts[1] != f2) return fail("extended token: facts[1] wrong");
    if (t2->creation_timetag != 20) return fail("timetag wrong");

    ds_rete_token_free(t1);
    ds_rete_token_free(t2);
    destroy_ctx(&c);
    return 0;
}

static int test_token_equality(void)
{
    Ctx c = make_ctx();
    ds_rete_fact_t *f1 = assert_fact(&c, 1, "a");
    ds_rete_fact_t *f2 = assert_fact(&c, 2, "b");

    ds_result_t err;
    ds_rete_token_t *ta = ds_rete_token_create(NULL, f1, 0, NULL, NULL, &err);
    ds_rete_token_t *tb = ds_rete_token_create(NULL, f1, 0, NULL, NULL, &err); /* same fact */
    ds_rete_token_t *tc = ds_rete_token_create(NULL, f2, 0, NULL, NULL, &err); /* diff fact */

    if (!ds_rete_tokens_equal(ta, tb)) return fail("equal tokens should be equal");
    if (ds_rete_tokens_equal(ta, tc))  return fail("different tokens should differ");

    ds_rete_token_free(ta);
    ds_rete_token_free(tb);
    ds_rete_token_free(tc);
    destroy_ctx(&c);
    return 0;
}

static int test_beta_node_create_destroy(void)
{
    Ctx c = make_ctx();
    ds_rete_beta_node_t *n = NULL;
    if (expect_ok("beta create",
                  ds_rete_beta_node_create(NULL, c.alpha_all, NULL, 0,
                                           false, &n))) return 1;
    if (!n) return fail("beta node is NULL");
    ds_rete_beta_node_destroy(n);
    destroy_ctx(&c);
    return 0;
}

/* ds_rete_beta_add_child sets both directions of the edge, and refuses a child
   that already has a different left parent, leaving the refusing node's
   children untouched. */
static int test_beta_add_child_sets_left_parent(void)
{
    Ctx c = make_ctx();
    ds_rete_beta_node_t *parent = NULL, *other = NULL, *child = NULL;
    ds_rete_beta_node_create(NULL, c.alpha_all, NULL, 0, false, &parent);
    ds_rete_beta_node_create(NULL, c.alpha_all, NULL, 0, false, &other);
    /* created with NO left parent: only add_child can link it */
    ds_rete_beta_node_create(NULL, c.alpha_all, NULL, 0, false, &child);

    if (expect_ok("add_child", ds_rete_beta_add_child(parent, child))) return 1;
    if (child->left_parent != parent)
        return fail("add_child did not set child->left_parent");
    if (parent->beta_child_count != 1 || parent->beta_children[0] != child)
        return fail("add_child did not append the child");

    ds_result_t r = ds_rete_beta_add_child(other, child);
    if (r.status != DS_ERR_INVAL)
        return fail("add_child accepted a child with another left parent");
    if (other->beta_child_count != 0)
        return fail("a refused add_child still appended the child");
    if (child->left_parent != parent)
        return fail("a refused add_child moved child->left_parent");

    ds_rete_beta_node_destroy(child);
    ds_rete_beta_node_destroy(other);
    ds_rete_beta_node_destroy(parent);
    destroy_ctx(&c);
    return 0;
}

typedef struct {
    ds_rete_token_t *tokens[32];
    uint32_t         count;
    bool             is_retract;
} TokenSink;

/* The child's left memory shows what the parent propagated. */
static int test_right_activate_flow(void)
{
    Ctx c = make_ctx();

    ds_rete_beta_node_t *parent = NULL, *child = NULL;
    ds_rete_beta_node_create(NULL, c.alpha_all, NULL, 0, false, &parent);
    ds_rete_beta_node_create(parent, c.alpha_all, NULL, 0, false, &child);
    ds_rete_beta_add_child(parent, child);
    ds_rete_alpha_add_beta_output(c.alpha_all, parent);

    /* parent has no left token yet, so these right-activations produce
     * nothing. */
    ds_rete_fact_t *f1 = assert_fact(&c, 10, "x");
    assert_fact(&c, 20, "y");

    /* The test, not the WM, left-activates the root node. */
    ds_result_t err;
    ds_rete_token_t *root_t1 = ds_rete_token_create(NULL, f1, 0, NULL, NULL, &err);
    if (expect_ok("left_activate parent with t1",
                  ds_rete_beta_left_activate(parent, root_t1,
                                              c.engine))) return 1;
    ds_rete_token_free(root_t1); /* caller retains ownership */
    /* (root_t1 + f1) and (root_t1 + f2) reach the child. */
    if (child->left_count != 2) {
        fprintf(stderr, "FAIL: child left_count: want 2 got %u\n",
                child->left_count);
        return 1;
    }

    /* f3 right-activates parent, which sends (root_t1 + f3) to the child. */
    assert_fact(&c, 30, "z");
    if (child->left_count != 3) {
        fprintf(stderr, "FAIL: child left_count after f3: want 3 got %u\n",
                child->left_count);
        return 1;
    }

    ds_rete_beta_node_destroy(child);
    ds_rete_beta_node_destroy(parent);
    destroy_ctx(&c);
    return 0;
}

static int test_right_retract_flow(void)
{
    Ctx c = make_ctx();
    ds_rete_beta_node_t *parent = NULL, *child = NULL;
    ds_rete_beta_node_create(NULL, c.alpha_all, NULL, 0, false, &parent);
    ds_rete_beta_node_create(parent, c.alpha_all, NULL, 0, false, &child);
    ds_rete_beta_add_child(parent, child);
    ds_rete_alpha_add_beta_output(c.alpha_all, parent);

    ds_rete_fact_t *f1 = assert_fact(&c, 1, "a");
    ds_rete_fact_t *f2 = assert_fact(&c, 2, "b");

    ds_result_t err;
    ds_rete_token_t *rt1 = ds_rete_token_create(NULL, f1, 0, NULL, NULL, &err);
    ds_rete_beta_left_activate(parent, rt1, c.engine);
    ds_rete_token_free(rt1);
    if (child->left_count != 2) return fail("pre-retract: want 2 tokens");

    /* Retracting f2 retracts (rt1+f2) from child. */
    ds_rete_wm_retract(c.engine, f2);
    if (child->left_count != 1) {
        fprintf(stderr, "FAIL: post-retract: want 1 got %u\n", child->left_count);
        return 1;
    }

    ds_rete_beta_node_destroy(child);
    ds_rete_beta_node_destroy(parent);
    destroy_ctx(&c);
    return 0;
}

/* [IRET.7.7]: a right-retraction evaluates no join test; it ends the pairs it
 * touches, and an ended pair records no fault ([LERR.1.4.12]). The join hook
 * counts its evaluations and answers false, so the node records no join and
 * its reverse index is never allocated. */
static int g_join_calls = 0;
static bool counting_false_join(const ds_rete_token_t *t,
                                const ds_rete_fact_t  *f)
{
    (void)t; (void)f;
    g_join_calls++;
    return false;
}

static int test_right_retract_evaluates_no_join_test(void)
{
    Ctx c = make_ctx();
    ds_rete_beta_node_t *n = NULL;
    ds_rete_beta_node_create(NULL, c.alpha_all, NULL, 0, false, &n);
    n->join_fn = counting_false_join;
    ds_rete_alpha_add_beta_output(c.alpha_all, n);

    ds_rete_fact_t *seed = assert_fact(&c, 1, "seed");
    ds_result_t err;
    ds_rete_token_t *root = ds_rete_token_create(NULL, seed, 0, NULL, NULL, &err);
    if (!root || err.status != DS_OK) return fail("retract_no_join: token_create");
    ds_rete_beta_left_activate(n, root, c.engine);
    ds_rete_token_free(root);

    g_join_calls = 0;
    ds_rete_fact_t *f = assert_fact(&c, 2, "f");
    int rc = 0;
    if (g_join_calls != 1) {
        fprintf(stderr, "FAIL: retract_no_join: the assert evaluated %d join "
                "test(s), want 1\n", g_join_calls);
        rc = 1;
    }
    ds_rete_wm_retract(c.engine, f);
    if (rc == 0 && g_join_calls != 1) {
        fprintf(stderr, "FAIL: retract_no_join: the retraction evaluated %d "
                "join test(s), want 0 ([IRET.7.7])\n", g_join_calls - 1);
        rc = 1;
    }

    ds_rete_beta_node_destroy(n);
    destroy_ctx(&c);
    return rc;
}

static int test_not_node_blocking(void)
{
    Ctx c = make_ctx();
    ds_rete_beta_node_t *pos = NULL, *neg = NULL, *sink = NULL;
    ds_rete_beta_node_create(NULL, c.alpha_all, NULL, 0, false, &pos);
    /* neg: a NOT node with alpha_gt5 on the right */
    ds_rete_beta_node_create(pos, c.alpha_gt5, NULL, 0, true, &neg);
    ds_rete_beta_add_child(pos, neg);
    ds_rete_beta_node_create(neg, c.alpha_all, NULL, 0, false, &sink);
    ds_rete_beta_add_child(neg, sink);
    ds_rete_alpha_add_beta_output(c.alpha_all,  pos);
    ds_rete_alpha_add_beta_output(c.alpha_gt5,  neg);

    ds_rete_fact_t *f_lo = assert_fact(&c, 3, "lo");  /* val=3; NOT matches (3>5=false) */
    ds_rete_fact_t *f_hi = assert_fact(&c, 9, "hi");  /* val=9; blocks NOT (9>5=true) */

    ds_result_t err;
    ds_rete_token_t *rt_lo = ds_rete_token_create(NULL, f_lo, 0, NULL, NULL, &err);
    ds_rete_beta_left_activate(pos, rt_lo, c.engine);
    ds_rete_token_free(rt_lo);
    /* pos sends (rt_lo+f_lo) and (rt_lo+f_hi) to neg, and f_hi blocks both. */
    if (sink->left_count != 0) {
        fprintf(stderr, "FAIL: NOT block: sink want 0 got %u\n",
                sink->left_count);
        return 1;
    }
#ifndef NDEBUG
    /* The invariants hold with both tokens blocked. */
    ds_rete_beta_check(pos); ds_rete_beta_check(neg); ds_rete_beta_check(sink);
#endif

    /* Retracting f_hi, in order:
     * (1) alpha_all right-retracts pos, which left-retracts the blocked
     *     (rt_lo+f_hi) from neg; nothing propagates.
     * (2) alpha_gt5 right-retracts neg, which unblocks (rt_lo+f_lo) to sink. */
    ds_rete_wm_retract(c.engine, f_hi);
    if (sink->left_count != 1) {
        fprintf(stderr, "FAIL: NOT unblock: sink want 1 got %u\n",
                sink->left_count);
        return 1;
    }
#ifndef NDEBUG
    /* The invariants hold after the blocker retracts: no ridx or ltok entry
       is left for the freed fact. */
    ds_rete_beta_check(pos); ds_rete_beta_check(neg); ds_rete_beta_check(sink);
#endif

    ds_rete_beta_node_destroy(sink);
    ds_rete_beta_node_destroy(neg);
    ds_rete_beta_node_destroy(pos);
    destroy_ctx(&c);
    return 0;
}

/* A NOT node with no right fact propagates the token at once. */
static int test_not_node_no_blocking(void)
{
    Ctx c = make_ctx();
    ds_rete_beta_node_t *pos = NULL, *neg = NULL, *sink = NULL;
    ds_rete_beta_node_create(NULL, c.alpha_all, NULL, 0, false, &pos);
    ds_rete_beta_node_create(pos, c.alpha_gt5, NULL, 0, true, &neg);
    ds_rete_beta_add_child(pos, neg);
    ds_rete_beta_node_create(neg, c.alpha_all, NULL, 0, false, &sink);
    ds_rete_beta_add_child(neg, sink);
    ds_rete_alpha_add_beta_output(c.alpha_all, pos);
    ds_rete_alpha_add_beta_output(c.alpha_gt5, neg);

    /* alpha_gt5 stays empty. */
    ds_rete_fact_t *f_lo = assert_fact(&c, 2, "lo");
    ds_result_t err;
    ds_rete_token_t *rt = ds_rete_token_create(NULL, f_lo, 0, NULL, NULL, &err);
    ds_rete_beta_left_activate(pos, rt, c.engine);
    ds_rete_token_free(rt);

    if (sink->left_count != 1) {
        fprintf(stderr, "FAIL: NOT no-block: sink want 1 got %u\n",
                sink->left_count);
        return 1;
    }

    ds_rete_beta_node_destroy(sink);
    ds_rete_beta_node_destroy(neg);
    ds_rete_beta_node_destroy(pos);
    destroy_ctx(&c);
    return 0;
}

/* A right fact asserted after the token is in place still blocks it once the
 * NOT node's reverse index exists. The first join allocates that index, so
 * the test makes one first. */
static int test_not_late_right_fact_after_ridx_alloc(void)
{
    Ctx c = make_ctx();
    ds_rete_beta_node_t *neg = NULL, *sink = NULL;
    /* NOT node on alpha_gt5, no join tests (any >5 fact blocks any token). */
    ds_rete_beta_node_create(NULL, c.alpha_gt5, NULL, 0, true,  &neg);
    ds_rete_beta_node_create(neg,  c.alpha_all,  NULL, 0, false, &sink);
    ds_rete_beta_add_child(neg, sink);
    ds_rete_alpha_add_beta_output(c.alpha_gt5, neg);

    /* (1) T1 joins the existing f_hi1, which allocates the index; T1 is
     *     blocked. */
    ds_rete_fact_t *f_hi1 = assert_fact(&c, 9, "hi1");
    ds_result_t err;
    ds_rete_token_t *t1 = ds_rete_token_create(NULL, f_hi1, 0, NULL, NULL, &err);
    if (!t1 || err.status != DS_OK) return fail("late_right: token_create");
    ds_rete_beta_left_activate(neg, t1, c.engine);
    ds_rete_token_free(t1);
    if (sink->left_count != 0)
        return fail("late_right: T1 should be blocked by pre-existing f_hi1");

    /* (2) Retracting f_hi1 unblocks T1; the index stays allocated. */
    ds_rete_wm_retract(c.engine, f_hi1);
    if (sink->left_count != 1)
        return fail("late_right: T1 should unblock to sink after f_hi1 retract");

    /* (3) A new high fact blocks T1 again and retracts it from sink. */
    assert_fact(&c, 9, "hi2");
    if (sink->left_count != 0) {
        fprintf(stderr,
                "FAIL: late_right: new f_hi2 did not block T1 "
                "(sink=%u, want 0) — negation missed a late right fact\n",
                sink->left_count);
        ds_rete_beta_node_destroy(sink);
        ds_rete_beta_node_destroy(neg);
        destroy_ctx(&c);
        return 1;
    }

    ds_rete_beta_node_destroy(sink);
    ds_rete_beta_node_destroy(neg);
    destroy_ctx(&c);
    return 0;
}

static int test_timetag_monotone(void)
{
    Ctx c = make_ctx();
    ds_rete_beta_node_t *n = NULL;
    ds_rete_beta_node_create(NULL, c.alpha_all, NULL, 0, false, &n);
    ds_rete_alpha_add_beta_output(c.alpha_all, n);

    ds_rete_beta_node_t *sink = NULL;
    ds_rete_beta_node_create(n, c.alpha_all, NULL, 0, false, &sink);
    ds_rete_beta_add_child(n, sink);

    ds_rete_fact_t *f1 = assert_fact(&c, 1, "a");
    ds_result_t err;
    ds_rete_token_t *rt = ds_rete_token_create(NULL, f1, 0, NULL, NULL, &err);
    ds_rete_beta_left_activate(n, rt, c.engine);
    ds_rete_token_free(rt);

    assert_fact(&c, 2, "b");
    assert_fact(&c, 3, "c");

    /* Three tokens at sink, with distinct timetags. */
    if (sink->left_count != 3) {
        fprintf(stderr, "FAIL: timetag: want 3 tokens got %u\n", sink->left_count);
        ds_rete_beta_node_destroy(sink);
        ds_rete_beta_node_destroy(n);
        destroy_ctx(&c);
        return 1;
    }
    int64_t timetags[3] = {-1, -1, -1};
    uint32_t ti = 0;
    ds_rete_token_t *t = sink->left_head;
    while (t && ti < 3) { timetags[ti++] = t->creation_timetag; t = t->next; }
    if (timetags[0] == timetags[1] || timetags[0] == timetags[2] ||
        timetags[1] == timetags[2]) {
        fprintf(stderr, "FAIL: timetags not distinct: %" PRId64 " %" PRId64 " %" PRId64 "\n",
                timetags[0], timetags[1], timetags[2]);
        ds_rete_beta_node_destroy(sink);
        ds_rete_beta_node_destroy(n);
        destroy_ctx(&c);
        return 1;
    }

    ds_rete_beta_node_destroy(sink);
    ds_rete_beta_node_destroy(n);
    destroy_ctx(&c);
    return 0;
}

/* Repeated block and unblock cycles leave no stale entry in the NOT node's
 * ltok map, which is its block count, and each unblock reaches the sink. neg
 * is left-activated directly with NLO root tokens of val 1, which alpha_gt5
 * never admits, so its left memory is fixed. */
static int test_not_block_table_stability(void)
{
    Ctx c = make_ctx();
    ds_rete_beta_node_t *neg = NULL, *sink = NULL;
    ds_rete_beta_node_create(NULL, c.alpha_gt5, NULL, 0, true,  &neg);
    ds_rete_beta_node_create(neg,  c.alpha_all,  NULL, 0, false, &sink);
    ds_rete_beta_add_child(neg, sink);
    ds_rete_alpha_add_beta_output(c.alpha_gt5, neg);

#define NLO 8
    ds_rete_fact_t *lo[NLO];
    for (int i = 0; i < NLO; i++) {
        char id[8];
        snprintf(id, sizeof id, "lo%d", i);
        lo[i] = assert_fact(&c, 1, id);
        ds_result_t err;
        ds_rete_token_t *rt = ds_rete_token_create(NULL, lo[i], (uint32_t)i,
                                                    NULL, NULL, &err);
        if (!rt || err.status != DS_OK) return fail("block_stability: token_create");
        ds_rete_beta_left_activate(neg, rt, c.engine);
        ds_rete_token_free(rt);
    }
    if (sink->left_count != (uint32_t)NLO) {
        fprintf(stderr, "FAIL: block_stability: initial sink want %u got %u\n",
                (uint32_t)NLO, sink->left_count);
        goto fail_cleanup;
    }

    /* Each cycle asserts f_hi (val 9), which blocks every token and retracts
     * it from sink, then retracts f_hi, which unblocks them all. Each
     * unblock exercises oa's backward-shift delete. */
#define NCYCLES 40
    for (int cy = 0; cy < NCYCLES; cy++) {
        char id[16];
        snprintf(id, sizeof id, "hi%d", cy);
        ds_rete_fact_t *f_hi = assert_fact(&c, 9, id);
        uint32_t before = sink->left_count;  /* normally 0 */

        ds_rete_wm_retract(c.engine, f_hi);
        uint32_t expected_after = before + (uint32_t)neg->left_count;

        /* 1. sink grew by exactly neg's left memory. */
        if (sink->left_count != expected_after) {
            fprintf(stderr,
                    "FAIL: block_stability cy=%d: sink want %u got %u (before=%u)\n",
                    cy, expected_after, sink->left_count, before);
            goto fail_cleanup;
        }

        /* 2. With every token unblocked, ltok is empty. oa has no tombstones,
           so an empty map has len 0 and every probe slot clear: check both. */
        if (oa_len(&neg->ltok_idx_map) != 0) {
            fprintf(stderr, "FAIL: block_stability cy=%d: blocked tokens want 0 got %u\n",
                    cy, oa_len(&neg->ltok_idx_map));
            goto fail_cleanup;
        }
        for (uint32_t bi = 0; bi < neg->ltok_idx_map.cap; bi++) {
            if (neg->ltok_idx_map.slots[bi] != 0) {
                fprintf(stderr,
                        "FAIL: block_stability cy=%d: zombie slot %u"
                        " (cap=%u)\n",
                        cy, bi, neg->ltok_idx_map.cap);
                goto fail_cleanup;
            }
        }
    }
#undef NCYCLES
#undef NLO

    ds_rete_beta_node_destroy(sink);
    ds_rete_beta_node_destroy(neg);
    destroy_ctx(&c);
    return 0;

fail_cleanup:
    ds_rete_beta_node_destroy(sink);
    ds_rete_beta_node_destroy(neg);
    destroy_ctx(&c);
    return 1;
}

/* A join that cannot be indexed at an RT-locked NOT node is DS_ERR_RT_UNSAFE,
 * not a block counted with no index entry. One left token joining
 * OA_LIST_INLINE+1 right facts fills its ltok list's inline slots, so the last
 * add must grow the heap while locked; record_join rolls back its ridx add and
 * not_left_activate returns the error. */
static int test_not_node_record_join_loud_fault(void)
{
    Ctx c = make_ctx();
    ds_rete_beta_node_t *pos = NULL, *neg = NULL, *sink = NULL;
    ds_rete_beta_node_create(NULL, c.alpha_all, NULL, 0, false, &pos);
    /* NOT node, right = alpha_all so every right fact blocks (no join test). */
    ds_rete_beta_node_create(pos, c.alpha_all, NULL, 0, true, &neg);
    ds_rete_beta_add_child(pos, neg);
    ds_rete_beta_node_create(neg, c.alpha_all, NULL, 0, false, &sink);
    ds_rete_beta_add_child(neg, sink);

    /* OA_LIST_INLINE+1 distinct right facts in neg's right alpha (= alpha_all). */
    ds_rete_fact_t *anchor = NULL;
    for (int i = 0; i <= OA_LIST_INLINE; i++) {
        char id[16];
        snprintf(id, sizeof id, "b%d", i);
        ds_rete_fact_t *f = assert_fact(&c, 9, id);
        if (i == 0) anchor = f;
    }

    /* Lock the NOT node's per-key lists, then left-activate one token; it joins
       every right fact, so the OA_LIST_INLINE+1'th record_join overflows ltok. */
    neg->rt_locked = true;
    ds_result_t err;
    ds_rete_token_t *tok = ds_rete_token_create(NULL, anchor, 0, NULL, NULL, &err);
    if (!tok) { destroy_ctx(&c); return fail("token_create"); }

    ds_result_t r = ds_rete_beta_left_activate(neg, tok, c.engine);
    ds_rete_token_free(tok);

    int rc = 0;
    if (r.status != DS_ERR_RT_UNSAFE) {
        fprintf(stderr,
            "FAIL: locked NOT-node index overflow not surfaced: want "
            "DS_ERR_RT_UNSAFE got %d (%s) — a block counted with no index "
            "entry\n", r.status, r.detail ? r.detail : "(null)");
        rc = 1;
    }

    ds_rete_beta_node_destroy(sink);
    ds_rete_beta_node_destroy(neg);
    ds_rete_beta_node_destroy(pos);
    destroy_ctx(&c);
    return rc;
}

/* Retracting a NOT-node blocker clears it from each blocked token's ltok
 * list, so retracting the token afterwards reads no freed fact; the valgrind
 * run flags such a read. */
static int test_not_node_retract_blocker_then_token(void)
{
    Ctx c = make_ctx();
    ds_rete_beta_node_t *pos = NULL, *neg = NULL, *sink = NULL;
    ds_rete_beta_node_create(NULL, c.alpha_all, NULL, 0, false, &pos);
    ds_rete_beta_node_create(pos, c.alpha_gt5, NULL, 0, true, &neg);
    ds_rete_beta_add_child(pos, neg);
    ds_rete_beta_node_create(neg, c.alpha_all, NULL, 0, false, &sink);
    ds_rete_beta_add_child(neg, sink);
    ds_rete_alpha_add_beta_output(c.alpha_all, pos);
    ds_rete_alpha_add_beta_output(c.alpha_gt5, neg);

    ds_rete_fact_t *f_lo = assert_fact(&c, 3, "lo");   /* val 3: NOT-matches, no block */
    ds_rete_fact_t *f_hi = assert_fact(&c, 9, "hi");   /* val 9: blocks (>5) */

    ds_result_t err;
    ds_rete_token_t *rt = ds_rete_token_create(NULL, f_lo, 0, NULL, NULL, &err);
    /* (rt+f_lo),(rt+f_hi) reach neg; both blocked by f_hi -> sink stays 0. */
    ds_rete_beta_left_activate(pos, rt, c.engine);

    /* Frees f_hi. */
    ds_rete_wm_retract(c.engine, f_hi);

    /* not_left_retract walks ltok[stored], which must no longer hold f_hi. */
    ds_rete_beta_left_retract(pos, rt, c.engine);
    ds_rete_token_free(rt);

    int rc = 0;
    if (sink->left_count != 0) {
        fprintf(stderr, "FAIL: NOT retract-token: sink want 0 got %u\n",
                sink->left_count);
        rc = 1;
    }

    ds_rete_beta_node_destroy(sink);
    ds_rete_beta_node_destroy(neg);
    ds_rete_beta_node_destroy(pos);
    destroy_ctx(&c);
    return rc;
}

int main(void)
{
    int fail_count = 0;

#define RUN(t) do { \
    int _r = (t)(); \
    if (_r) { fprintf(stderr, "  FAIL: " #t "\n"); fail_count++; } \
    else    { printf("  pass: " #t "\n"); } \
} while (0)

    printf("=== test_rete_beta ===\n");
    RUN(test_token_create_root);
    RUN(test_token_extend);
    RUN(test_token_equality);
    RUN(test_beta_node_create_destroy);
    RUN(test_beta_add_child_sets_left_parent);
    RUN(test_right_activate_flow);
    RUN(test_right_retract_flow);
    RUN(test_right_retract_evaluates_no_join_test);
    RUN(test_not_node_blocking);
    RUN(test_not_node_no_blocking);
    RUN(test_not_block_table_stability);
    RUN(test_not_late_right_fact_after_ridx_alloc);
    RUN(test_not_node_record_join_loud_fault);
    RUN(test_not_node_retract_blocker_then_token);
    RUN(test_timetag_monotone);
#undef RUN

    if (fail_count == 0) {
        printf("=== test_rete_beta: ALL PASSED ===\n");
        return 0;
    }
    fprintf(stderr, "=== test_rete_beta: %d FAILED ===\n", fail_count);
    return 1;
}
