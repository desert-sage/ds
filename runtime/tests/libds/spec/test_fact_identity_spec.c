/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * test_fact_identity_spec — spec conformance for fact identity +
 * no-op reassertion semantics.
 *
 * Spec: IDAT.4.3 (fact identity is
 *   schema + slot-tuple) and IDAT.4.4 (LOGICAL no-op
 *   reassertion preserves the existing ds_fact_t — same pointer,
 *   same fact_id; meaningful-change reassertion is retract +
 *   assert).
 *
 * The checks are by pointer identity (out_fact equality across asserts).
 *
 * Public API only — no internal headers.
 */
#include "spec_common.h"

/* ============== Stream probe ============== */

typedef struct {
    int n_fact_assert;
    int n_fact_retract;
} stream_probe_t;

static ds_result_t stream_cb(ds_engine_t          *engine,
                             const ds_stream_ev_t *event,
                             void                 *user)
{
    (void) engine;
    stream_probe_t *s = (stream_probe_t *) user;
    if (event->kind == DS_EV_FACT_ASSERT)  s->n_fact_assert++;
    if (event->kind == DS_EV_FACT_RETRACT) s->n_fact_retract++;
    return DS_OK_R;
}

/* ============== Per-scenario fixture ============== */

typedef struct {
    ds_engine_t       *engine;
    const ds_schema_t *trig;     /* one STRING "tag" slot */
    const ds_schema_t *counter;  /* one INT "n" slot — distinct schema */
    const ds_schema_t *multi;    /* INT "i" + STRING "s" slots */
} fixture_t;

static int build(fixture_t *f, stream_probe_t *sp)
{
    ds_engine_t *e = NULL;
    ds_result_t r = ds_engine_new(NULL, &e);
    if (r.status != DS_OK) return spec_fail("engine_new", r);

    /* A schema reaches an engine only from an artefact, so the schemas are
       declared in DS and loaded. */
    r = spec_load_ds(e,
        "schema Trig scope logical:\n    tag: String key\n\n"
        "schema Counter scope logical:\n    n: Int key\n\n"
        "schema Multi scope logical:\n    i: Int key\n    s: String mutable\n");
    if (r.status != DS_OK) return spec_fail("spec_load_ds schemas", r);
    r = ds_engine_schema_find(e, "Trig", &f->trig);
    if (r.status != DS_OK || !f->trig) return spec_fail("find Trig", r);
    r = ds_engine_schema_find(e, "Counter", &f->counter);
    if (r.status != DS_OK || !f->counter) return spec_fail("find Counter", r);
    r = ds_engine_schema_find(e, "Multi", &f->multi);
    if (r.status != DS_OK || !f->multi) return spec_fail("find Multi", r);

    /* Stream cb AFTER load so the dsc loader's own events aren't counted. */
    if (sp != NULL) {
        r = ds_engine_set_stream_callback(e, stream_cb, sp);
        if (r.status != DS_OK) return spec_fail("set_stream_cb", r);
    }
    f->engine = e;
    return 0;
}

static int assert_trig(fixture_t *f, const char *tag, ds_fact_t **out)
{
    ds_slot_value_t v[] = { { .kind = DS_SLOT_STRING, .v.s = tag } };
    ds_result_t r = ds_engine_assert(f->engine, f->trig, v, 1, out);
    if (r.status != DS_OK) return spec_fail("assert Trig", r);
    return 0;
}

static int assert_counter(fixture_t *f, int64_t n, ds_fact_t **out)
{
    ds_slot_value_t v[] = { { .kind = DS_SLOT_INT, .v.i = n } };
    ds_result_t r = ds_engine_assert(f->engine, f->counter, v, 1, out);
    if (r.status != DS_OK) return spec_fail("assert Counter", r);
    return 0;
}

/* ============== Scenarios ============== */

/* IDAT.4.3 — different slot values produce different facts. */
static int test_idat_4_3__different_slot_values_different_facts(void)
{
    fixture_t f = {0};
    if (build(&f, NULL)) return 1;
    ds_fact_t *p1 = NULL, *p2 = NULL;
    if (assert_counter(&f, 1, &p1)) return 1;
    if (assert_counter(&f, 2, &p2)) return 1;
    if (p1 == NULL || p2 == NULL) {
        fprintf(stderr, "FAIL: out_fact NULL\n"); return 1;
    }
    if (p1 == p2) {
        fprintf(stderr,
                "FAIL: distinct slot values produced same fact ptr\n");
        return 1;
    }
    size_t fc = 0;
    ds_result_t r = ds_engine_fact_count(f.engine, &fc);
    EXPECT_OK("fact_count", r);
    if (fc != 2) {
        fprintf(stderr, "FAIL: fact_count=%zu, want 2\n", fc); return 1;
    }
    ds_engine_free(f.engine);
    return 0;
}

/* IDAT.4.3 — same slot tuple, different schemas → different facts.
   Schema is part of the identity. Trig and Counter both have one
   slot, but they're distinct schemas, so even slot-tuples that
   happen to be type-compatible point to different facts. */
static int test_idat_4_3__different_schema_same_slots_different_facts(void)
{
    fixture_t f = {0};
    if (build(&f, NULL)) return 1;
    /* Trig has STRING; Counter has INT — slot kinds differ but
       both schemas have one slot. Use distinct values per schema's
       declared kind; the point is "different schema → different
       fact" regardless of slot values. */
    ds_fact_t *p1 = NULL, *p2 = NULL;
    if (assert_trig(&f, "x", &p1)) return 1;
    if (assert_counter(&f, 7, &p2)) return 1;
    if (p1 == p2) {
        fprintf(stderr, "FAIL: different schemas got same fact ptr\n");
        return 1;
    }
    size_t fc = 0;
    ds_result_t r = ds_engine_fact_count(f.engine, &fc);
    EXPECT_OK("fact_count", r);
    if (fc != 2) {
        fprintf(stderr, "FAIL: fact_count=%zu, want 2\n", fc); return 1;
    }
    ds_engine_free(f.engine);
    return 0;
}

/* IDAT.4.4 — for LOGICAL schemas, no-op reassertion (same schema +
   same slot tuple) returns the SAME ds_fact_t pointer. */
static int test_idat_4_4__no_op_reassertion_returns_same_pointer(void)
{
    fixture_t f = {0};
    if (build(&f, NULL)) return 1;
    ds_fact_t *p1 = NULL, *p2 = NULL;
    if (assert_trig(&f, "abc", &p1)) return 1;
    if (assert_trig(&f, "abc", &p2)) return 1;
    if (p1 == NULL) {
        fprintf(stderr, "FAIL: first assert out_fact NULL\n"); return 1;
    }
    if (p1 != p2) {
        fprintf(stderr,
                "FAIL: no-op reassert returned different ptr (p1=%p p2=%p)\n",
                (void *) p1, (void *) p2);
        return 1;
    }
    ds_engine_free(f.engine);
    return 0;
}

/* [RFCS.6.7] — a no-op reassertion is recorded. A FactAssert records an
   assert arriving, not a fact entering working memory; the change to working
   memory is suppressed and the atom is written anyway. */
static int test_rfcs_6_7__no_op_reassertion_is_recorded(void)
{
    stream_probe_t sp = {0};
    fixture_t f = {0};
    if (build(&f, &sp)) return 1;
    /* Two asserts of the same tuple, then a pump: both are recorded. */
    if (assert_trig(&f, "abc", NULL)) return 1;
    if (assert_trig(&f, "abc", NULL)) return 1;   /* no-op dedup */
    ds_result_t r = ds_engine_pump(f.engine);
    EXPECT_OK("pump", r);
    if (sp.n_fact_assert != 2) {
        fprintf(stderr,
                "FAIL: dedup'd asserts emitted %d FACT_ASSERT, want 2 "
                "(the no-op re-assert is recorded)\n",
                sp.n_fact_assert);
        return 1;
    }
    ds_engine_free(f.engine);
    return 0;
}

/* IDAT.4.4 — no-op reassertion does not change ds_engine_fact_count. */
static int test_idat_4_4__no_op_reassertion_does_not_change_fact_count(void)
{
    fixture_t f = {0};
    if (build(&f, NULL)) return 1;
    if (assert_trig(&f, "abc", NULL)) return 1;
    size_t before = 0;
    ds_result_t r = ds_engine_fact_count(f.engine, &before);
    EXPECT_OK("fact_count first", r);
    if (assert_trig(&f, "abc", NULL)) return 1;
    size_t after = 0;
    r = ds_engine_fact_count(f.engine, &after);
    EXPECT_OK("fact_count second", r);
    if (before != after) {
        fprintf(stderr, "FAIL: fact_count went %zu → %zu on no-op\n",
                before, after);
        return 1;
    }
    if (after != 1) {
        fprintf(stderr, "FAIL: fact_count=%zu, want 1\n", after);
        return 1;
    }
    ds_engine_free(f.engine);
    return 0;
}

/* IDAT.4.4 — retract followed by reassert with the same values
   yields a new ds_fact_t (the original wrapper was freed; this is
   a fresh fact, not a "preserved existing"). The integrator
   sees one retract event and one assert event in that order. */
static int test_idat_4_4__retract_then_reassert_yields_new_pointer(void)
{
    stream_probe_t sp = {0};
    fixture_t f = {0};
    if (build(&f, &sp)) return 1;
    ds_fact_t *p1 = NULL, *p2 = NULL;
    /* A pump after each mutation; the out_fact pointer is synchronous. */
    if (assert_trig(&f, "abc", &p1)) return 1;
    ds_result_t r = ds_engine_pump(f.engine);
    EXPECT_OK("pump after assert", r);
    int n_assert_1 = sp.n_fact_assert;
    /* Capture address as integer — retract frees the wrapper; don't deref p1. */
    uintptr_t old_addr = (uintptr_t) p1;
    r = ds_engine_retract(f.engine, p1);
    EXPECT_OK("retract", r);
    r = ds_engine_pump(f.engine);
    EXPECT_OK("pump after retract", r);
    if (sp.n_fact_retract != 1) {
        fprintf(stderr, "FAIL: retract emitted %d FACT_RETRACT, want 1\n",
                sp.n_fact_retract);
        return 1;
    }
    if (assert_trig(&f, "abc", &p2)) return 1;
    r = ds_engine_pump(f.engine);
    EXPECT_OK("pump after reassert", r);
    if (p2 == NULL) {
        fprintf(stderr, "FAIL: reassert out_fact NULL\n"); return 1;
    }
    /* Reassert after retract is a fresh fact (the previous one is gone, so this
       is not a no-op) — a new FACT_ASSERT fires. */
    if (sp.n_fact_assert != n_assert_1 + 1) {
        fprintf(stderr, "FAIL: reassert FACT_ASSERT count (%d → %d)\n",
                n_assert_1, sp.n_fact_assert);
        return 1;
    }
    (void) old_addr;  /* pointer reuse is allowed but not required */
    ds_engine_free(f.engine);
    return 0;
}

/* IDAT.4.3 / sanity — fact_count tracks distinct facts as
   asserts accumulate. */
static int test_idat_4_3__fact_count_tracks_distinct_facts(void)
{
    fixture_t f = {0};
    if (build(&f, NULL)) return 1;
    if (assert_counter(&f, 1, NULL)) return 1;
    if (assert_counter(&f, 2, NULL)) return 1;
    if (assert_counter(&f, 3, NULL)) return 1;
    if (assert_trig(&f, "x", NULL))  return 1;
    if (assert_trig(&f, "y", NULL))  return 1;
    size_t fc = 0;
    ds_result_t r = ds_engine_fact_count(f.engine, &fc);
    EXPECT_OK("fact_count", r);
    if (fc != 5) {
        fprintf(stderr, "FAIL: fact_count=%zu, want 5\n", fc); return 1;
    }
    ds_engine_free(f.engine);
    return 0;
}

/* ============== Driver ============== */

int main(void)
{
    int failed = 0;
    failed |= test_idat_4_3__different_slot_values_different_facts();
    failed |= test_idat_4_3__different_schema_same_slots_different_facts();
    failed |= test_idat_4_4__no_op_reassertion_returns_same_pointer();
    failed |= test_rfcs_6_7__no_op_reassertion_is_recorded();
    failed |= test_idat_4_4__no_op_reassertion_does_not_change_fact_count();
    failed |= test_idat_4_4__retract_then_reassert_yields_new_pointer();
    failed |= test_idat_4_3__fact_count_tracks_distinct_facts();
    if (!failed) printf("test_fact_identity_spec: OK\n");
    return failed;
}
