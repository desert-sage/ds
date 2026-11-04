/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * TTL-lifecycle schemas, black-box through libds.h ([IARC.3.3.3]): a fact's
 * deadline is the engine clock at its assert plus the schema's ttl_ns, and
 * the pump's sweep retracts an expired fact, with its FACT_RETRACT, before
 * the firing loop. Each scenario sets the mock clock, then pumps, then
 * counts.
 */
#include "spec_common.h"

/* ShortTTL's `scope ttl 100_ms`, in the source build_engine() loads. */
#define TTL_NS   ((uint64_t) 100000000)   /* 100_ms */
/* The assert-time clock. */
#define T0       ((uint64_t) 1000000000)  /* 1_s */
/* A clock value comfortably past any single TTL_NS deadline. */
#define FAR(t0)  ((uint64_t) ((t0) + 100 * TTL_NS))

/* ============== Stream probe ============== */

typedef struct {
    int        n_fact_retract;
    int        n_other_action;
    ds_fact_t *last_retract_fact;
    uint64_t   last_retract_seq;
    int        n_fact_assert;
} stream_probe_t;

static ds_result_t stream_cb(ds_engine_t          *engine,
                             const ds_stream_ev_t *event,
                             void                 *user)
{
    (void) engine;
    stream_probe_t *s = (stream_probe_t *) user;
    switch (event->kind) {
    case DS_EV_FACT_RETRACT:
        s->n_fact_retract++;
        s->last_retract_fact = event->p.fact_retract.fact;
        s->last_retract_seq  = event->seq;
        break;
    case DS_EV_FACT_ASSERT:
        s->n_fact_assert++;
        break;
    case DS_EV_RULE_FIRE_BEGIN:
    case DS_EV_RULE_FIRE_END:
    case DS_EV_RULE_LHS_FACTS:
    /* The clock's tick and the pump's own event are the engine stepping
       ([NCBK.2.3]), not actions. Faults still count. */
    case DS_EV_TICK:
    case DS_EV_PUMP:
        break;
    default:
        s->n_other_action++;
    }
    return DS_OK_R;
}

/* ============== Per-scenario fixture ==============
 * A fresh engine on the mock clock at `mock_clock_ns`, with two schemas of
 * one Int slot `v`:
 *   ShortTTL  — DS_SCHEMA_LIFECYCLE_TTL, ttl_ns = TTL_NS, no key
 *   Logical   — DS_SCHEMA_LIFECYCLE_LOGICAL, `v` its key */
static int build_engine(ds_engine_t **out_engine,
                        const ds_schema_t **out_ttl,
                        const ds_schema_t **out_log,
                        stream_probe_t *sp,
                        uint64_t mock_clock_ns)
{
    ds_engine_t *e = NULL;
    ds_result_t r = ds_engine_new(NULL, &e);
    if (r.status != DS_OK) return spec_fail("engine_new", r);
    r = ds_engine_clock_set_mode(e, DS_CLOCK_MOCK);
    if (r.status != DS_OK) return spec_fail("clock_mode", r);
    r = ds_engine_clock_set(e, mock_clock_ns);
    if (r.status != DS_OK) return spec_fail("clock_set", r);

    r = spec_load_ds(e,
        "schema ShortTTL scope ttl 100_ms:\n    v: Int\n\n"
        "schema Logical scope logical:\n    v: Int key\n");
    if (r.status != DS_OK) return spec_fail("spec_load_ds schemas", r);

    const ds_schema_t *ttl_s = NULL;
    r = ds_engine_schema_find(e, "ShortTTL", &ttl_s);
    if (r.status != DS_OK || !ttl_s) return spec_fail("find ShortTTL", r);
    const ds_schema_t *log_s = NULL;
    r = ds_engine_schema_find(e, "Logical", &log_s);
    if (r.status != DS_OK || !log_s) return spec_fail("find Logical", r);

    /* After the load, so the loader's own events are not counted. */
    if (sp != NULL) {
        r = ds_engine_set_stream_callback(e, stream_cb, sp);
        if (r.status != DS_OK) return spec_fail("set_stream_cb", r);
    }
    *out_engine = e;
    if (out_ttl) *out_ttl = ttl_s;
    if (out_log) *out_log = log_s;
    return 0;
}

static int assert_int(ds_engine_t *e, const ds_schema_t *s, int64_t i)
{
    ds_slot_value_t v[] = { { .kind = DS_SLOT_INT, .v.i = i } };
    ds_result_t r = ds_engine_assert(e, s, v, 1, NULL);
    if (r.status != DS_OK) return spec_fail("assert", r);
    return 0;
}

/* ============== Scenarios ============== */

/* Past the deadline, a pump retracts the fact and fact_count drops it. */
static int test_e4__sweep_retracts_expired_fact(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL;
    const ds_schema_t *ttl = NULL;
    if (build_engine(&e, &ttl, NULL, &sp, T0)) return 1;
    if (assert_int(e, ttl, 1)) return 1;
    /* deadline = T0 + TTL_NS. Move well past it. */
    ds_result_t r = ds_engine_clock_set(e, FAR(T0));
    EXPECT_OK("clock far", r);
    r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_fact_retract != 1) {
        fprintf(stderr, "FAIL: retract count=%d, want 1\n",
                sp.n_fact_retract);
        return 1;
    }
    size_t fc = 0;
    r = ds_engine_fact_count(e, &fc);
    EXPECT_OK("fact_count", r);
    if (fc != 0) {
        fprintf(stderr, "FAIL: fact_count=%zu, want 0\n", fc); return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* Before the deadline, a pump does not retract. */
static int test_e4__sweep_skips_unexpired_fact(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL;
    const ds_schema_t *ttl = NULL;
    if (build_engine(&e, &ttl, NULL, &sp, T0)) return 1;
    if (assert_int(e, ttl, 1)) return 1;
    /* deadline = T0 + TTL_NS. Move halfway there — still alive. */
    ds_result_t r = ds_engine_clock_set(e, T0 + TTL_NS / 2);
    EXPECT_OK("clock pre-deadline", r);
    r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_fact_retract != 0) {
        fprintf(stderr, "FAIL: pre-deadline retract count=%d\n",
                sp.n_fact_retract);
        return 1;
    }
    size_t fc = 0;
    r = ds_engine_fact_count(e, &fc);
    EXPECT_OK("fact_count", r);
    if (fc != 1) {
        fprintf(stderr, "FAIL: fc=%zu, want 1 (still alive)\n", fc);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* At the deadline the fact is retracted: the sweep keeps a fact only while
   its deadline is after now. */
static int test_e4__sweep_at_deadline_retracts(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL;
    const ds_schema_t *ttl = NULL;
    if (build_engine(&e, &ttl, NULL, &sp, T0)) return 1;
    if (assert_int(e, ttl, 1)) return 1;
    /* deadline = T0 + TTL_NS. Set clock exactly to deadline. */
    ds_result_t r = ds_engine_clock_set(e, T0 + TTL_NS);
    EXPECT_OK("clock at-deadline", r);
    r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_fact_retract != 1) {
        fprintf(stderr,
                "FAIL: at-deadline retract count=%d, want 1\n",
                sp.n_fact_retract);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* One ns before the deadline the fact survives. */
static int test_e4__sweep_one_ns_before_deadline_skips(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL;
    const ds_schema_t *ttl = NULL;
    if (build_engine(&e, &ttl, NULL, &sp, T0)) return 1;
    if (assert_int(e, ttl, 1)) return 1;
    /* deadline = T0 + TTL_NS. Set clock one ns before. */
    ds_result_t r = ds_engine_clock_set(e, T0 + TTL_NS - 1);
    EXPECT_OK("clock one-ns-before", r);
    r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_fact_retract != 0) {
        fprintf(stderr,
                "FAIL: 1-ns-before-deadline retract count=%d\n",
                sp.n_fact_retract);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* The sweep never retracts a LOGICAL fact. */
static int test_e4__sweep_skips_logical_fact(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL;
    const ds_schema_t *log = NULL;
    if (build_engine(&e, NULL, &log, &sp, T0)) return 1;
    if (assert_int(e, log, 7)) return 1;
    ds_result_t r = ds_engine_clock_set(e, FAR(T0));
    EXPECT_OK("clock far-future", r);
    r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_fact_retract != 0) {
        fprintf(stderr,
                "FAIL: LOGICAL fact retracted by sweep (count=%d)\n",
                sp.n_fact_retract);
        return 1;
    }
    size_t fc = 0;
    r = ds_engine_fact_count(e, &fc);
    if (fc != 1) {
        fprintf(stderr, "FAIL: LOGICAL fc=%zu, want 1\n", fc); return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* Two TTL facts expire: two FACT_RETRACT events, seq increasing, and no
   FACT_ASSERT. */
static int test_e4__sweep_emits_fact_retract_stream_event(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL;
    const ds_schema_t *ttl = NULL;
    if (build_engine(&e, &ttl, NULL, &sp, T0)) return 1;
    if (assert_int(e, ttl, 1)) return 1;
    if (assert_int(e, ttl, 2)) return 1;
    int pre_assert = sp.n_fact_assert;
    ds_result_t r = ds_engine_clock_set(e, FAR(T0));
    EXPECT_OK("clock far", r);
    uint64_t pre_seq = sp.last_retract_seq;
    r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_fact_retract != 2) {
        fprintf(stderr, "FAIL: retract count=%d, want 2\n",
                sp.n_fact_retract);
        return 1;
    }
    if (!(sp.last_retract_seq > pre_seq)) {
        fprintf(stderr, "FAIL: last retract seq did not advance\n");
        return 1;
    }
    /* No new asserts during the sweep. */
    if (sp.n_fact_assert != pre_assert) {
        fprintf(stderr, "FAIL: sweep emitted FACT_ASSERT events\n");
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* Of three TTL facts, the sweep retracts only those whose deadline has
   passed. */
static int test_e4__sweep_partial_in_multi_fact(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL;
    const ds_schema_t *ttl = NULL;
    /* The clock moves between asserts, so the three deadlines are more than
       TTL_NS apart. */
    if (build_engine(&e, &ttl, NULL, &sp, T0)) return 1;
    /* fact A: assert at T0 → deadline T0 + TTL_NS */
    if (assert_int(e, ttl, 1)) return 1;
    uint64_t tB = T0 + 5 * TTL_NS;
    ds_result_t r = ds_engine_clock_set(e, tB);
    EXPECT_OK("clock B", r);
    /* fact B: assert at tB → deadline tB + TTL_NS */
    if (assert_int(e, ttl, 2)) return 1;
    uint64_t tC = T0 + 7 * TTL_NS;
    r = ds_engine_clock_set(e, tC);
    EXPECT_OK("clock C", r);
    /* fact C: assert at tC → deadline tC + TTL_NS */
    if (assert_int(e, ttl, 3)) return 1;
    /* Past B's deadline and before C's: A and B expired, C alive. The
       sweep point follows C's assert, since a monotonic clock run back is
       refused ([LTIM.2.8.2]). */
    r = ds_engine_clock_set(e, tC + TTL_NS / 2);
    EXPECT_OK("clock sweep-point", r);
    r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_fact_retract != 2) {
        fprintf(stderr, "FAIL: partial-sweep retract count=%d, want 2\n",
                sp.n_fact_retract);
        return 1;
    }
    size_t fc = 0;
    r = ds_engine_fact_count(e, &fc);
    if (fc != 1) {
        fprintf(stderr, "FAIL: fc=%zu, want 1 (C survives)\n", fc);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* The deadline is reckoned from the clock at each assert: two facts asserted
   at different clocks have different deadlines. */
static int test_e4__deadline_relative_to_assert_time(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL;
    const ds_schema_t *ttl = NULL;
    if (build_engine(&e, &ttl, NULL, &sp, T0)) return 1;
    /* Assert A at clock=T0 → deadline T0 + TTL_NS. */
    if (assert_int(e, ttl, 1)) return 1;
    /* Advance the clock and assert B → later deadline. */
    uint64_t tB = T0 + 4 * TTL_NS;
    ds_result_t r = ds_engine_clock_set(e, tB);
    EXPECT_OK("clock B", r);
    if (assert_int(e, ttl, 2)) return 1;
    /* Between the two deadlines, and after B's assert, since a monotonic
       clock run back is refused ([LTIM.2.8.2]). */
    r = ds_engine_clock_set(e, tB + TTL_NS / 2);
    EXPECT_OK("clock between", r);
    r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_fact_retract != 1) {
        fprintf(stderr,
                "FAIL: retract count=%d, want 1 (only A)\n",
                sp.n_fact_retract);
        return 1;
    }
    size_t fc = 0;
    r = ds_engine_fact_count(e, &fc);
    if (fc != 1) {
        fprintf(stderr, "FAIL: fc=%zu, want 1 (B survives)\n", fc);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* Past the deadline, the first pump retracts the fact and a second, with
   the clock unchanged, records no further retract. */
static int test_e4__sweep_only_once_per_pump(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL;
    const ds_schema_t *ttl = NULL;
    if (build_engine(&e, &ttl, NULL, &sp, T0)) return 1;
    if (assert_int(e, ttl, 1)) return 1;
    ds_result_t r = ds_engine_clock_set(e, FAR(T0));
    EXPECT_OK("clock far", r);
    r = ds_engine_pump(e);
    EXPECT_OK("pump 1", r);
    if (sp.n_fact_retract != 1) {
        fprintf(stderr, "FAIL: pump1 retract=%d\n", sp.n_fact_retract);
        return 1;
    }
    int pre = sp.n_fact_retract;
    /* Second pump, no clock change, no new asserts. */
    r = ds_engine_pump(e);
    EXPECT_OK("pump 2", r);
    if (sp.n_fact_retract != pre) {
        fprintf(stderr,
                "FAIL: second pump emitted FACT_RETRACT (count=%d, was %d)\n",
                sp.n_fact_retract, pre);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* After a sweep retracts a TTL fact, an assert of the same schema at a
   later clock has a deadline of its own. */
static int test_e4__reassert_after_sweep_gets_new_deadline(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL;
    const ds_schema_t *ttl = NULL;
    if (build_engine(&e, &ttl, NULL, &sp, T0)) return 1;
    /* Assert at T0, deadline T0 + TTL_NS. */
    if (assert_int(e, ttl, 1)) return 1;
    ds_result_t r = ds_engine_clock_set(e, T0 + 2 * TTL_NS);
    EXPECT_OK("clock past first deadline", r);
    r = ds_engine_pump(e);
    EXPECT_OK("pump 1", r);
    if (sp.n_fact_retract != 1) {
        fprintf(stderr, "FAIL: pump1 retract=%d\n", sp.n_fact_retract);
        return 1;
    }
    /* Reassert at clock = T0 + 2*TTL_NS → new deadline T0 + 3*TTL_NS. */
    uint64_t t_reassert = T0 + 2 * TTL_NS;
    if (assert_int(e, ttl, 2)) return 1;
    /* Past the old deadline and before the new one. */
    r = ds_engine_clock_set(e, t_reassert + TTL_NS / 2);
    EXPECT_OK("clock before new deadline", r);
    int pre = sp.n_fact_retract;
    r = ds_engine_pump(e);
    EXPECT_OK("pump 2", r);
    if (sp.n_fact_retract != pre) {
        fprintf(stderr,
                "FAIL: reasserted fact retracted at old deadline\n");
        return 1;
    }
    /* Past the new deadline. */
    r = ds_engine_clock_set(e, t_reassert + 2 * TTL_NS);
    EXPECT_OK("clock past new deadline", r);
    r = ds_engine_pump(e);
    EXPECT_OK("pump 3", r);
    if (sp.n_fact_retract != pre + 1) {
        fprintf(stderr,
                "FAIL: reasserted fact not retracted at new deadline\n");
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* ============== Driver ============== */

int main(void)
{
    int failed = 0;
    failed |= test_e4__sweep_retracts_expired_fact();
    failed |= test_e4__sweep_skips_unexpired_fact();
    failed |= test_e4__sweep_at_deadline_retracts();
    failed |= test_e4__sweep_one_ns_before_deadline_skips();
    failed |= test_e4__sweep_skips_logical_fact();
    failed |= test_e4__sweep_emits_fact_retract_stream_event();
    failed |= test_e4__sweep_partial_in_multi_fact();
    failed |= test_e4__deadline_relative_to_assert_time();
    failed |= test_e4__sweep_only_once_per_pump();
    failed |= test_e4__reassert_after_sweep_gets_new_deadline();
    if (!failed) printf("test_ttl_spec: OK\n");
    return failed;
}
