/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The fact stream as the stream callback delivers it, black-box through
 * libds.h:
 *   LFST.6.1.1 — an external assert and an external retract each emit
 *                their event.
 *   LFST.7.1.1 — an engine is the single writer of its stream: seq
 *                strictly increases.
 *   LFST.7.1.3 — each engine has a stream of its own.
 */
#include "spec_common.h"

/* ============== Stream probe ============== */

typedef struct {
    int n_fact_assert;
    int n_fact_retract;
    int n_rule_fire_begin;
    int n_rule_fire_end;
    int n_action_log;
    int n_action_emit;
    int n_action_publish;
    int n_other;
    uint64_t last_seq;
    int      seen_first;
    int      seq_violation;
} sp_t;

static ds_result_t stream_cb(ds_engine_t *e, const ds_stream_ev_t *ev,
                             void *u)
{
    (void) e;
    sp_t *s = (sp_t *) u;
    if (s->seen_first) {
        if (!(ev->seq > s->last_seq)) s->seq_violation = 1;
    }
    s->last_seq = ev->seq;
    s->seen_first = 1;
    switch (ev->kind) {
    case DS_EV_FACT_ASSERT:      s->n_fact_assert++;     break;
    case DS_EV_FACT_RETRACT:     s->n_fact_retract++;    break;
    case DS_EV_RULE_FIRE_BEGIN:  s->n_rule_fire_begin++; break;
    case DS_EV_RULE_FIRE_END:    s->n_rule_fire_end++;   break;
    case DS_EV_ACTION_LOG:       s->n_action_log++;      break;
    case DS_EV_ACTION_EMIT:      s->n_action_emit++;     break;
    case DS_EV_ACTION_PUBLISH:   s->n_action_publish++;  break;
    case DS_EV_RULE_LHS_FACTS:                           break;
    default:                     s->n_other++;           break;
    }
    return DS_OK_R;
}

/* ============== Per-scenario fixture ============== */

/* Load `ds_src` and resolve Trig. The stream callback is set after the load,
   so the loader's own load-time events are not counted. */
static int build_engine(ds_engine_t **out_engine,
                        const ds_schema_t **out_trig,
                        sp_t *sp, const char *ds_src)
{
    ds_engine_t *e = NULL;
    ds_result_t r = ds_engine_new(NULL, &e);
    if (r.status != DS_OK) return spec_fail("engine_new", r);

    r = spec_load_ds(e, ds_src);
    if (r.status != DS_OK) return spec_fail("spec_load_ds", r);

    const ds_schema_t *trig = NULL;
    r = ds_engine_schema_find(e, "Trig", &trig);
    if (r.status != DS_OK || trig == NULL)
        return spec_fail("schema_find Trig", r);

    if (sp != NULL) {
        r = ds_engine_set_stream_callback(e, stream_cb, sp);
        if (r.status != DS_OK) return spec_fail("set_stream_cb", r);
    }
    *out_engine = e;
    *out_trig = trig;
    return 0;
}

/* Trig, with no rule. */
static const char *TRIG_ONLY =
    "schema Trig scope logical:\n"
    "    tag: String key\n";

static int assert_trig(ds_engine_t *e, const ds_schema_t *trig,
                       const char *tag, ds_fact_t **out_f)
{
    ds_slot_value_t v[] = { { .kind = DS_SLOT_STRING, .v.s = tag } };
    ds_result_t r = ds_engine_assert(e, trig, v, 1, out_f);
    if (r.status != DS_OK) return spec_fail("assert trig", r);
    return 0;
}

/* ============== Scenarios ============== */

/* LFST.6.1.1 — ds_engine_assert emits a FACT_ASSERT. */
static int test_lfst_6_1_1__external_assert_emits_fact_assert(void)
{
    sp_t sp = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &sp, TRIG_ONLY)) return 1;
    if (assert_trig(e, trig, "x", NULL)) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_fact_assert != 1) {
        fprintf(stderr, "FAIL: assert FACT_ASSERT count=%d, want 1\n",
                sp.n_fact_assert);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* LFST.6.1.1 — ds_engine_retract emits a FACT_RETRACT. */
static int test_lfst_6_1_1__external_retract_emits_fact_retract(void)
{
    sp_t sp = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &sp, TRIG_ONLY)) return 1;
    ds_fact_t *p = NULL;
    if (assert_trig(e, trig, "x", &p)) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump after assert", r);
    int pre_retract = sp.n_fact_retract;
    r = ds_engine_retract(e, p);
    EXPECT_OK("retract", r);
    r = ds_engine_pump(e);
    EXPECT_OK("pump after retract", r);
    if (sp.n_fact_retract != pre_retract + 1) {
        fprintf(stderr, "FAIL: retract FACT_RETRACT count=%d, want +1\n",
                sp.n_fact_retract - pre_retract);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* LFST.7.1.1 — over a mix of fact, firing and log events, every event's
   seq is greater than the one before. */
static int test_lfst_7_1_1__per_engine_single_writer_seq_monotonic(void)
{
    sp_t sp = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    static const char *src =
        "schema Trig scope logical:\n"
        "    tag: String key\n"
        "\n"
        "rule p:\n"
        "    Trig t where t.tag == \"x\"\n"
        "->\n"
        "    log info \"m\"\n";
    if (build_engine(&e, &trig, &sp, src)) return 1;
    /* Three distinct facts, so none is a no-op. */
    ds_fact_t *f1 = NULL, *f2 = NULL, *f3 = NULL;
    if (assert_trig(e, trig, "x", &f1)) return 1;
    if (assert_trig(e, trig, "y", &f2)) return 1;
    if (assert_trig(e, trig, "z", &f3)) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump after asserts", r);
    r = ds_engine_retract(e, f1);
    EXPECT_OK("retract f1", r);
    r = ds_engine_retract(e, f2);
    EXPECT_OK("retract f2", r);
    r = ds_engine_retract(e, f3);
    EXPECT_OK("retract f3", r);
    r = ds_engine_pump(e);
    EXPECT_OK("pump after retracts", r);
    if (sp.seq_violation) {
        fprintf(stderr,
                "FAIL: seq monotonicity violated within single engine\n");
        return 1;
    }
    /* The workload produced the mix: only "x" matches the rule. */
    if (sp.n_fact_assert < 3 || sp.n_fact_retract < 3 ||
        sp.n_action_log < 1) {
        fprintf(stderr,
                "FAIL: workload produced too few events fa=%d fr=%d log=%d\n",
                sp.n_fact_assert, sp.n_fact_retract, sp.n_action_log);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* LFST.7.1.3 — one stream per tier, which in libds is one per engine. */
static int test_lfst_7_1_3__per_engine_independent_streams(void)
{
    sp_t spa = {0}, spb = {0};
    ds_engine_t *a = NULL, *b = NULL;
    const ds_schema_t *trig_a = NULL, *trig_b = NULL;
    if (build_engine(&a, &trig_a, &spa, TRIG_ONLY)) return 1;
    if (build_engine(&b, &trig_b, &spb, TRIG_ONLY)) return 1;
    if (assert_trig(a, trig_a, "x", NULL)) return 1;
    if (assert_trig(a, trig_a, "y", NULL)) return 1;
    if (assert_trig(b, trig_b, "z", NULL)) return 1;
    ds_result_t r = ds_engine_pump(a);
    EXPECT_OK("pump a", r);
    r = ds_engine_pump(b);
    EXPECT_OK("pump b", r);
    if (spa.n_fact_assert != 2) {
        fprintf(stderr, "FAIL: A FACT_ASSERT=%d, want 2\n",
                spa.n_fact_assert);
        return 1;
    }
    if (spb.n_fact_assert != 1) {
        fprintf(stderr, "FAIL: B FACT_ASSERT=%d, want 1\n",
                spb.n_fact_assert);
        return 1;
    }
    if (spa.seq_violation || spb.seq_violation) {
        fprintf(stderr, "FAIL: seq monotonicity broken on a=%d b=%d\n",
                spa.seq_violation, spb.seq_violation);
        return 1;
    }
    ds_engine_free(a);
    ds_engine_free(b);
    return 0;
}

/* ============== Driver ============== */

int main(void)
{
    int failed = 0;
    failed |= test_lfst_6_1_1__external_assert_emits_fact_assert();
    failed |= test_lfst_6_1_1__external_retract_emits_fact_retract();
    failed |= test_lfst_7_1_1__per_engine_single_writer_seq_monotonic();
    failed |= test_lfst_7_1_3__per_engine_independent_streams();
    if (!failed) printf("test_lfst_spec: OK\n");
    return failed;
}
