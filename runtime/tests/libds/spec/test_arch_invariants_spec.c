/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * test_arch_invariants_spec — spec conformance for the
 * load-bearing architecture invariants.
 *
 * Spec:
 *   IARC.1.11 — One ds_engine_t = one Rete environment;
 *     multiple engines coexist independently; no global state.
 *   IARC.1.12 — ds_result_t at every call site; corollary:
 *     the engine's pending-error slot preserves first-error-wins
 *     when a later sibling action succeeds ([IDSP.1.6]).
 *
 * Rules and schemas are DS source loaded through spec_load_ds(), since an
 * artefact is the only way a schema reaches an engine. Public API only.
 */
#include "spec_common.h"

/* ============== Helpers ============== */

typedef struct {
    int n_fact_assert;
    int n_action_log;
    int n_action_emit;
    int n_rule_fire_begin;
} sp_t;

static ds_result_t stream_cb(ds_engine_t *e, const ds_stream_ev_t *ev, void *u)
{
    (void) e;
    sp_t *s = (sp_t *) u;
    switch (ev->kind) {
    case DS_EV_FACT_ASSERT:      s->n_fact_assert++;     break;
    case DS_EV_ACTION_LOG:       s->n_action_log++;      break;
    case DS_EV_ACTION_EMIT:      s->n_action_emit++;     break;
    case DS_EV_RULE_FIRE_BEGIN:  s->n_rule_fire_begin++; break;
    default:                                              break;
    }
    return DS_OK_R;
}

typedef struct {
    int n_calls;
    char last_msg[64];
} log_probe_t;

static ds_result_t log_cb(ds_engine_t *e, const ds_log_event_t *ev, void *u)
{
    (void) e;
    log_probe_t *p = (log_probe_t *) u;
    p->n_calls++;
    p->last_msg[0] = '\0';
    if (ev->message)
        strncpy(p->last_msg, ev->message, sizeof(p->last_msg) - 1);
    return DS_OK_R;
}

/* The stock Trig schema declaration every scenario shares. */
#define TRIG_SCHEMA "schema Trig scope logical:\n    tag: String key\n\n"

/* A rule that fires once on Trig(tag=="x") and logs "from-a". */
#define RULE_LOGA \
    "rule loga:\n" \
    "    Trig t where t.tag == \"x\"\n" \
    "->\n" \
    "    log info \"from-a\"\n"

/* Fresh engine that compiles+loads the given DS program and returns
   the Trig handle. Callbacks are registered by the caller AFTER load
   so the dsc loader's own events aren't counted. */
static int build_engine(ds_engine_t **out_e,
                        const ds_schema_t **out_trig,
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
    *out_e = e;
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

/* ============== Scenarios ============== */

/* IARC.1.11 — facts asserted on engine A do not appear in engine B's
   working memory. ds_engine_fact_count is per-engine. */
static int test_iarc_1_11__multi_engine_facts_independent(void)
{
    ds_engine_t *a = NULL, *b = NULL;
    const ds_schema_t *trig_a = NULL, *trig_b = NULL;
    if (build_engine(&a, &trig_a, TRIG_SCHEMA)) return 1;
    if (build_engine(&b, &trig_b, TRIG_SCHEMA)) return 1;
    /* Assert two (distinct-identity) facts on A, zero on B. */
    if (fire(a, trig_a, "x")) return 1;
    if (fire(a, trig_a, "y")) return 1;
    size_t fa = 0, fb = 0;
    ds_result_t r = ds_engine_fact_count(a, &fa);
    EXPECT_OK("fact_count a", r);
    r = ds_engine_fact_count(b, &fb);
    EXPECT_OK("fact_count b", r);
    if (fa != 2) {
        fprintf(stderr, "FAIL: A fc=%zu, want 2\n", fa); return 1;
    }
    if (fb != 0) {
        fprintf(stderr, "FAIL: B fc=%zu, want 0 (cross-talk)\n", fb);
        return 1;
    }
    ds_engine_free(a);
    ds_engine_free(b);
    return 0;
}

/* IARC.1.11 — each engine has its own clock state. Setting engine
   A's mock clock does not affect engine B's clock. (Pure C-API; no
   rules or facts involved.) */
static int test_iarc_1_11__multi_engine_clocks_independent(void)
{
    ds_engine_t *a = NULL, *b = NULL;
    ds_result_t r = ds_engine_new(NULL, &a); EXPECT_OK("new a", r);
    r = ds_engine_new(NULL, &b);              EXPECT_OK("new b", r);
    r = ds_engine_clock_set_mode(a, DS_CLOCK_MOCK); EXPECT_OK("mock a", r);
    r = ds_engine_clock_set_mode(b, DS_CLOCK_MOCK); EXPECT_OK("mock b", r);
    r = ds_engine_clock_set(a, 10000); EXPECT_OK("set a 10000", r);
    r = ds_engine_clock_set(b,    50); EXPECT_OK("set b 50",    r);
    uint64_t na = 0, nb = 0;
    r = ds_engine_clock_now(a, &na); EXPECT_OK("now a", r);
    r = ds_engine_clock_now(b, &nb); EXPECT_OK("now b", r);
    if (na != 10000 || nb != 50) {
        fprintf(stderr,
                "FAIL: clocks bled across engines (a=%llu b=%llu)\n",
                (unsigned long long) na, (unsigned long long) nb);
        return 1;
    }
    /* Advance A; B unchanged. */
    r = ds_engine_clock_advance(a, 500); EXPECT_OK("adv a", r);
    r = ds_engine_clock_now(a, &na);     EXPECT_OK("now a 2", r);
    r = ds_engine_clock_now(b, &nb);     EXPECT_OK("now b 2", r);
    if (na != 10500 || nb != 50) {
        fprintf(stderr,
                "FAIL: advancing A clock changed B (a=%llu b=%llu)\n",
                (unsigned long long) na, (unsigned long long) nb);
        return 1;
    }
    ds_engine_free(a);
    ds_engine_free(b);
    return 0;
}

/* IARC.1.11 — stream callbacks are per-engine. Events emitted on
   engine A reach A's stream cb only; B's cb does not see them. */
static int test_iarc_1_11__multi_engine_streams_isolated(void)
{
    sp_t spa = {0}, spb = {0};
    ds_engine_t *a = NULL, *b = NULL;
    const ds_schema_t *trig_a = NULL, *trig_b = NULL;
    if (build_engine(&a, &trig_a, TRIG_SCHEMA)) return 1;
    if (build_engine(&b, &trig_b, TRIG_SCHEMA)) return 1;
    ds_result_t r = ds_engine_set_stream_callback(a, stream_cb, &spa);
    EXPECT_OK("set_stream a", r);
    r = ds_engine_set_stream_callback(b, stream_cb, &spb);
    EXPECT_OK("set_stream b", r);
    /* All work happens on A. */
    if (fire(a, trig_a, "x")) return 1;
    if (fire(a, trig_a, "y")) return 1;
    if (spa.n_fact_assert != 2) {
        fprintf(stderr, "FAIL: A FACT_ASSERT=%d\n", spa.n_fact_assert);
        return 1;
    }
    if (spb.n_fact_assert != 0) {
        fprintf(stderr,
                "FAIL: B saw %d FACT_ASSERT events from A's work\n",
                spb.n_fact_assert);
        return 1;
    }
    ds_engine_free(a);
    ds_engine_free(b);
    return 0;
}

/* IARC.1.11 — typed callbacks are per-engine: a log verb on engine A
   invokes A's log callback only. */
static int test_iarc_1_11__multi_engine_callbacks_isolated(void)
{
    log_probe_t pa = {0}, pb = {0};
    ds_engine_t *a = NULL, *b = NULL;
    const ds_schema_t *trig_a = NULL, *trig_b = NULL;
    /* A has the logging rule; B has the schema but no rule. */
    if (build_engine(&a, &trig_a, TRIG_SCHEMA RULE_LOGA)) return 1;
    if (build_engine(&b, &trig_b, TRIG_SCHEMA)) return 1;
    ds_result_t r = ds_engine_set_log_callback(a, log_cb, &pa);
    EXPECT_OK("set_log a", r);
    r = ds_engine_set_log_callback(b, log_cb, &pb);
    EXPECT_OK("set_log b", r);
    if (fire(a, trig_a, "x")) return 1;
    r = ds_engine_pump(a);
    EXPECT_OK("pump a", r);
    if (pa.n_calls != 1 || strcmp(pa.last_msg, "from-a") != 0) {
        fprintf(stderr,
                "FAIL: A log cb n=%d msg=\"%s\"\n",
                pa.n_calls, pa.last_msg);
        return 1;
    }
    if (pb.n_calls != 0) {
        fprintf(stderr,
                "FAIL: B log cb fired (n=%d) on A's pump\n", pb.n_calls);
        return 1;
    }
    ds_engine_free(a);
    ds_engine_free(b);
    return 0;
}

/* IARC.1.11 — rules loaded on engine A do not exist on engine B.
   Asserting a matching trigger on B fires nothing because the
   rule isn't there. Verified through stream RULE_FIRE_BEGIN
   counts. */
static int test_iarc_1_11__multi_engine_rules_isolated(void)
{
    sp_t spa = {0}, spb = {0};
    ds_engine_t *a = NULL, *b = NULL;
    const ds_schema_t *trig_a = NULL, *trig_b = NULL;
    /* Rule on A only; B gets the schema so the assert is accepted. */
    if (build_engine(&a, &trig_a, TRIG_SCHEMA RULE_LOGA)) return 1;
    if (build_engine(&b, &trig_b, TRIG_SCHEMA)) return 1;
    ds_result_t r = ds_engine_set_stream_callback(a, stream_cb, &spa);
    EXPECT_OK("set_stream a", r);
    r = ds_engine_set_stream_callback(b, stream_cb, &spb);
    EXPECT_OK("set_stream b", r);
    /* Fire matching trigger on BOTH engines. */
    if (fire(a, trig_a, "x")) return 1;
    if (fire(b, trig_b, "x")) return 1;
    r = ds_engine_pump(a); EXPECT_OK("pump a", r);
    r = ds_engine_pump(b); EXPECT_OK("pump b", r);
    if (spa.n_rule_fire_begin != 1) {
        fprintf(stderr,
                "FAIL: A RULE_FIRE_BEGIN=%d, want 1\n",
                spa.n_rule_fire_begin);
        return 1;
    }
    if (spb.n_rule_fire_begin != 0) {
        fprintf(stderr,
                "FAIL: B RULE_FIRE_BEGIN=%d, rules bled across engines\n",
                spb.n_rule_fire_begin);
        return 1;
    }
    if (spa.n_action_log != 1) {
        fprintf(stderr, "FAIL: A ACTION_LOG=%d\n", spa.n_action_log);
        return 1;
    }
    if (spb.n_action_log != 0) {
        fprintf(stderr,
                "FAIL: B ACTION_LOG=%d (rule fired on B)\n",
                spb.n_action_log);
        return 1;
    }
    ds_engine_free(a);
    ds_engine_free(b);
    return 0;
}

/* IARC.1.12 — first-error-wins for sibling RHS actions when the later sibling
   SUCCEEDS. Sibling 1 is an essential verb (call) fired with NO callback
   registered → DS_ERR_STORAGE_UNAVAILABLE, stashed in the engine pending slot;
   sibling 2 (emit Counter) still runs, and ds_engine_pump surfaces the first
   error while sibling 2's effect (ACTION_EMIT) lands. */
static int test_iarc_1_12__first_error_wins_when_later_succeeds(void)
{
    sp_t sp = {0};
    ds_engine_t *e = NULL;
    const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig,
            TRIG_SCHEMA
            "schema Counter scope logical:\n    n: Int key\n\n"
            "service audit.put:\n    kwarg id: Int\n    no response\n\n"
            "rule first_err:\n"
            "    Trig t where t.tag == \"x\"\n"
            "->\n"
            "    call audit.put id: 1 nocooldown\n"
            "    emit Counter logical n: 1\n"))
        return 1;
    /* No call callback registered → the call (sibling 1) fails. */
    ds_result_t r = ds_engine_set_stream_callback(e, stream_cb, &sp);
    EXPECT_OK("set_stream", r);
    if (fire(e, trig, "x")) return 1;
    r = ds_engine_pump(e);
    /* The first (essential) verb's error surfaces from the pump... */
    EXPECT_STATUS("pump surfaces first error", r, DS_ERR_STORAGE_UNAVAILABLE);
    /* ...and the later sibling still fired its emit. */
    if (sp.n_action_emit != 1) {
        fprintf(stderr,
                "FAIL: later sibling emit did not fire (ACTION_EMIT=%d)\n",
                sp.n_action_emit);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* ============== Driver ============== */

int main(void)
{
    int failed = 0;
    failed |= test_iarc_1_11__multi_engine_facts_independent();
    failed |= test_iarc_1_11__multi_engine_clocks_independent();
    failed |= test_iarc_1_11__multi_engine_streams_isolated();
    failed |= test_iarc_1_11__multi_engine_callbacks_isolated();
    failed |= test_iarc_1_11__multi_engine_rules_isolated();
    failed |= test_iarc_1_12__first_error_wins_when_later_succeeds();
    if (!failed) printf("test_arch_invariants_spec: OK\n");
    return failed;
}
