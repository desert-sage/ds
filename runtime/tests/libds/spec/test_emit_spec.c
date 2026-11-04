/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * test_emit_spec — spec conformance for the `emit` effect verb.
 *
 * Spec: IDSP.3 (and IDSP.1 cross-cutting).
 *
 * Rules and schemas are DS source loaded through spec_load_ds().
 * `emit <Schema> logical ...` lowers to a fact assert, so a successful emit
 * produces a FACT_ASSERT and a DS_EV_ACTION_EMIT carrying the same fact
 * pointer. The trigger fact stays in working memory, and fact counts include
 * it. An emit's target and slot values are checked by the compiler.
 *
 * Public API only — no internal headers.
 */
#include "spec_common.h"

/* ============== Probe ============== */

typedef struct {
    int        n_fact_assert;
    int        n_action_emit;
    int        n_rule_fire_begin;
    int        n_rule_fire_end;
    int        n_other_action;     /* anything not EMIT/FACT_x/RULE_FIRE_x */
    ds_fact_t *last_assert_fact;
    ds_fact_t *last_emit_fact;
    uint64_t   last_rfb_seq;
    uint64_t   last_assert_seq;
    uint64_t   last_emit_seq;
    uint64_t   last_rfe_seq;
} stream_probe_t;

static ds_result_t stream_cb(ds_engine_t          *engine,
                             const ds_stream_ev_t *event,
                             void                 *user)
{
    (void) engine;
    stream_probe_t *s = (stream_probe_t *) user;
    switch (event->kind) {
    case DS_EV_FACT_ASSERT:
        s->n_fact_assert++;
        s->last_assert_fact = event->p.fact_assert.fact;
        s->last_assert_seq  = event->seq;
        break;
    case DS_EV_ACTION_EMIT:
        s->n_action_emit++;
        s->last_emit_fact = event->p.action_emit.fact;
        s->last_emit_seq  = event->seq;
        break;
    case DS_EV_RULE_FIRE_BEGIN:
        s->n_rule_fire_begin++;
        s->last_rfb_seq = event->seq;
        break;
    case DS_EV_RULE_FIRE_END:
        s->n_rule_fire_end++;
        s->last_rfe_seq = event->seq;
        break;
    case DS_EV_FACT_RETRACT:
    case DS_EV_RULE_LHS_FACTS:
    /* The clock's tick and the pump's own event ([NCBK.2.3]) are the engine
       stepping, not actions. Faults still count. */
    case DS_EV_TICK:
    case DS_EV_PUMP:
        break;
    default:
        s->n_other_action++;
    }
    return DS_OK_R;
}

/* ============== Per-scenario fixture ============== */

#define TRIG_SCHEMA    "schema Trig scope logical:\n    tag: String key\n\n"
#define COUNTER_SCHEMA "schema Counter scope logical:\n    n: Int key\n\n"

static int build_engine(ds_engine_t **out_engine,
                        const ds_schema_t **out_trig,
                        stream_probe_t *sp,
                        const char *ds_src)
{
    ds_engine_t *e = NULL;
    ds_result_t r = ds_engine_new(NULL, &e);
    if (r.status != DS_OK) return spec_fail("engine_new", r);
    r = spec_load_ds(e, ds_src);
    if (r.status != DS_OK) return spec_fail("spec_load_ds", r);
    const ds_schema_t *trig = NULL;
    r = ds_engine_schema_find(e, "Trig", &trig);
    if (r.status != DS_OK || !trig) return spec_fail("find Trig", r);
    /* cb AFTER load so the dsc loader's own events aren't counted. */
    if (sp != NULL) {
        r = ds_engine_set_stream_callback(e, stream_cb, sp);
        if (r.status != DS_OK) return spec_fail("set_stream_cb", r);
    }
    *out_engine = e;
    if (out_trig) *out_trig = trig;
    return 0;
}

static int fire(ds_engine_t *e, const ds_schema_t *trig, const char *tag)
{
    ds_slot_value_t v[] = { { .kind = DS_SLOT_STRING, .v.s = tag } };
    ds_result_t r = ds_engine_assert(e, trig, v, 1, NULL);
    if (r.status != DS_OK) return spec_fail("assert trig", r);
    return 0;
}

static int assert_no_other_actions(const stream_probe_t *sp)
{
    if (sp->n_other_action != 0) {
        fprintf(stderr,
                "FAIL: stream observed %d unexpected action events\n",
                sp->n_other_action);
        return 1;
    }
    return 0;
}

/* ============== Scenarios ============== */

/* IDSP.3.2 — multi-slot schema round-trips INT + FLOAT + STRING + BOOL. The
   compiler decodes each declared type in the emit literal; the runtime asserts
   the fact. */
static int test_idsp_3_2__multi_type_slots_roundtrip(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &sp,
            TRIG_SCHEMA
            "schema Multi scope logical:\n"
            "    i: Int key\n    f: Float mutable\n    s: String mutable\n    b: Bool mutable\n\n"
            "rule e:\n    Trig t where t.tag == \"x\"\n"
            "->\n    emit Multi logical i: 7 f: 2.5 s: \"hi\" b: true\n"))
        return 1;
    if (fire(e, trig, "x")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump multi", r);
    if (sp.n_action_emit != 1) {
        fprintf(stderr, "FAIL: ACTION_EMIT count=%d\n", sp.n_action_emit);
        return 1;
    }
    size_t fc = 0;
    r = ds_engine_fact_count(e, &fc);
    EXPECT_OK("fact_count", r);
    /* Trig + Multi → 2. */
    if (fc != 2) {
        fprintf(stderr, "FAIL: fact_count=%zu, want 2\n", fc); return 1;
    }
    if (assert_no_other_actions(&sp)) return 1;
    ds_engine_free(e);
    return 0;
}

/* IDSP.3.4 — primary effect: a successful emit asserts a fact;
   ds_engine_fact_count reflects it. */
static int test_idsp_3_4__primary_effect_asserts_fact(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &sp,
            TRIG_SCHEMA COUNTER_SCHEMA
            "rule p:\n    Trig t where t.tag == \"go\"\n"
            "->\n    emit Counter logical n: 42\n"))
        return 1;
    if (fire(e, trig, "go")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    size_t fc = 0;
    r = ds_engine_fact_count(e, &fc);
    EXPECT_OK("fact_count", r);
    /* Trig + Counter → 2. */
    if (fc != 2) {
        fprintf(stderr, "FAIL: fact_count=%zu, want 2\n", fc); return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* IDSP.3.5 — ACTION_EMIT carries the same fact pointer the wm listener
   emitted via FACT_ASSERT (the emitted fact, seen last during the pump). */
static int test_idsp_3_5__action_emit_payload_fact(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &sp,
            TRIG_SCHEMA COUNTER_SCHEMA
            "rule p:\n    Trig t where t.tag == \"x\"\n"
            "->\n    emit Counter logical n: 1\n"))
        return 1;
    if (fire(e, trig, "x")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_action_emit != 1) {
        fprintf(stderr, "FAIL: ACTION_EMIT count=%d\n", sp.n_action_emit);
        return 1;
    }
    if (sp.last_emit_fact == NULL) {
        fprintf(stderr, "FAIL: ACTION_EMIT fact ptr is NULL\n"); return 1;
    }
    /* The last FACT_ASSERT seen during the pump is Counter (the emit). */
    if (sp.last_assert_fact != sp.last_emit_fact) {
        fprintf(stderr,
                "FAIL: ACTION_EMIT fact (%p) != last FACT_ASSERT fact (%p)\n",
                (void *) sp.last_emit_fact, (void *) sp.last_assert_fact);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* IDSP.3.5 — per-pump observable order by seq:
   RULE_FIRE_BEGIN < FACT_ASSERT (the emit) < ACTION_EMIT < RULE_FIRE_END. */
static int test_idsp_3_5__per_pump_observable_order(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &sp,
            TRIG_SCHEMA COUNTER_SCHEMA
            "rule ord:\n    Trig t where t.tag == \"x\"\n"
            "->\n    emit Counter logical n: 1\n"))
        return 1;
    if (fire(e, trig, "x")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_rule_fire_begin != 1 || sp.n_action_emit != 1 ||
        sp.n_rule_fire_end != 1) {
        fprintf(stderr, "FAIL: counts rfb=%d emit=%d rfe=%d\n",
                sp.n_rule_fire_begin, sp.n_action_emit, sp.n_rule_fire_end);
        return 1;
    }
    if (!(sp.last_rfb_seq < sp.last_assert_seq)) {
        fprintf(stderr, "FAIL: rfb_seq=%llu not < assert_seq=%llu\n",
                (unsigned long long) sp.last_rfb_seq,
                (unsigned long long) sp.last_assert_seq);
        return 1;
    }
    if (!(sp.last_assert_seq < sp.last_emit_seq)) {
        fprintf(stderr, "FAIL: assert_seq=%llu not < emit_seq=%llu\n",
                (unsigned long long) sp.last_assert_seq,
                (unsigned long long) sp.last_emit_seq);
        return 1;
    }
    if (!(sp.last_emit_seq < sp.last_rfe_seq)) {
        fprintf(stderr, "FAIL: emit_seq=%llu not < rfe_seq=%llu\n",
                (unsigned long long) sp.last_emit_seq,
                (unsigned long long) sp.last_rfe_seq);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* IDSP.3.5 — N rule firings in one pump produce N ACTION_EMIT events and N
   emitted-fact FACT_ASSERTs. Three rules, three distinct Counter values (so
   the emitted facts don't dedup on their identity slot). */
static int test_idsp_3_5__multi_fire_count(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &sp,
            TRIG_SCHEMA COUNTER_SCHEMA
            "rule ma:\n    Trig t where t.tag == \"a\"\n"
            "->\n    emit Counter logical n: 1\n\n"
            "rule mb:\n    Trig t where t.tag == \"b\"\n"
            "->\n    emit Counter logical n: 2\n\n"
            "rule mc:\n    Trig t where t.tag == \"c\"\n"
            "->\n    emit Counter logical n: 3\n"))
        return 1;
    const char *tags[] = { "a", "b", "c" };
    for (int i = 0; i < 3; i++)
        if (fire(e, trig, tags[i])) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_action_emit != 3) {
        fprintf(stderr, "FAIL: ACTION_EMIT count=%d, want 3\n",
                sp.n_action_emit);
        return 1;
    }
    /* 3 Trig + 3 Counter = 6 FACT_ASSERT. */
    if (sp.n_fact_assert != 6) {
        fprintf(stderr, "FAIL: FACT_ASSERT count=%d, want 6\n",
                sp.n_fact_assert);
        return 1;
    }
    if (assert_no_other_actions(&sp)) return 1;
    ds_engine_free(e);
    return 0;
}

/* ============== Driver ============== */

int main(void)
{
    int failed = 0;
    failed |= test_idsp_3_2__multi_type_slots_roundtrip();
    failed |= test_idsp_3_4__primary_effect_asserts_fact();
    failed |= test_idsp_3_5__action_emit_payload_fact();
    failed |= test_idsp_3_5__per_pump_observable_order();
    failed |= test_idsp_3_5__multi_fire_count();
    if (!failed) printf("test_emit_spec: OK\n");
    return failed;
}
