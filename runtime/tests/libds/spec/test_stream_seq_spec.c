/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The stream event header, black-box through libds.h:
 *   IDAT.7.1 — seq strictly increases per engine, each engine's
 *              independently, and clock_ns is the engine clock at emit.
 *   IDAT.7.2 — the payload is read by kind; one mixed-kind scenario here,
 *              each verb's payload in its own spec test.
 *   NTST.3.3 — a mock-clock mutation records nothing; the next pump's
 *              sample does.
 */
#include "spec_common.h"

/* ============== Stream observation ring ============== */

#define MAX_OBS 256

typedef struct {
    ds_stream_ev_kind_t kind;
    uint64_t            seq;
    uint64_t            clock_ns;
} obs_t;

typedef struct {
    obs_t obs[MAX_OBS];
    int   n;
    int   overflow;     /* set if events exceeded MAX_OBS */
} obs_buf_t;

static ds_result_t stream_cb(ds_engine_t          *engine,
                             const ds_stream_ev_t *event,
                             void                 *user)
{
    (void) engine;
    obs_buf_t *b = (obs_buf_t *) user;
    if (b->n >= MAX_OBS) { b->overflow = 1; return DS_OK_R; }
    b->obs[b->n].kind     = event->kind;
    b->obs[b->n].seq      = event->seq;
    b->obs[b->n].clock_ns = event->clock_ns;
    b->n++;
    return DS_OK_R;
}

/* ============== Per-scenario fixture ==============
 * Fresh engine on the mock clock at the requested tick; compiles +
 * loads the scenario's DS program (schema "Trig" with a STRING "tag"
 * slot, plus rules) and returns the Trig handle for asserts. The obs
 * stream cb is registered AFTER load so the dsc loader's own events
 * aren't counted; pass buf=NULL to leave the cb unset (a scenario
 * that installs its own probe). */
static int build_engine(ds_engine_t **out_engine,
                        const ds_schema_t **out_trig,
                        obs_buf_t *buf,
                        uint64_t mock_clock_ns,
                        const char *ds_src)
{
    ds_engine_t *e = NULL;
    ds_result_t r = ds_engine_new(NULL, &e);
    if (r.status != DS_OK) return spec_fail("engine_new", r);
    r = ds_engine_clock_set_mode(e, DS_CLOCK_MOCK);
    if (r.status != DS_OK) return spec_fail("clock_mode", r);
    r = ds_engine_clock_set(e, mock_clock_ns);
    if (r.status != DS_OK) return spec_fail("clock_set", r);

    r = spec_load_ds(e, ds_src);
    if (r.status != DS_OK) return spec_fail("spec_load_ds", r);
    const ds_schema_t *trig = NULL;
    r = ds_engine_schema_find(e, "Trig", &trig);
    if (r.status != DS_OK || !trig) return spec_fail("find Trig", r);

    if (buf != NULL) {
        r = ds_engine_set_stream_callback(e, stream_cb, buf);
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

/* The stock Trig schema declaration prefix every scenario shares. */
#define TRIG_SCHEMA "schema Trig scope logical:\n    tag: String key\n\n"

/* Verify obs[lo..hi) is strictly increasing in seq. */
static int check_seq_strictly_increasing(const obs_buf_t *b,
                                         int lo, int hi,
                                         const char *what)
{
    if (b->overflow) {
        fprintf(stderr, "FAIL: %s: stream observation overflowed\n", what);
        return 1;
    }
    for (int i = lo + 1; i < hi; i++) {
        if (!(b->obs[i].seq > b->obs[i - 1].seq)) {
            fprintf(stderr,
                    "FAIL: %s: seq[%d]=%llu not > seq[%d]=%llu\n",
                    what, i, (unsigned long long) b->obs[i].seq,
                    i - 1, (unsigned long long) b->obs[i - 1].seq);
            return 1;
        }
    }
    return 0;
}

/* ============== Scenarios ============== */

/* IDAT.7.1 — within a single pump (one rule firing several action
   verbs in its RHS), every emitted event has a strictly greater
   seq than the previous. */
static int test_idat_7_1__seq_strictly_increasing_in_pump(void)
{
    obs_buf_t buf = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &buf, 100,
            TRIG_SCHEMA
            "schema Counter scope logical:\n    n: Int key\n\n"
            "rule multi:\n    Trig t where t.tag == \"x\"\n->\n"
            "    log info \"m\"\n"
            "    emit Counter logical n: 1\n"
            "    log critical \"hi\"\n")) return 1;
    if (fire(e, trig, "x")) return 1;
    int pre = buf.n;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (buf.n - pre < 4) {
        fprintf(stderr, "FAIL: expected >= 4 events in one pump, got %d\n",
                buf.n - pre);
        return 1;
    }
    if (check_seq_strictly_increasing(&buf, pre, buf.n, "in-pump"))
        return 1;
    ds_engine_free(e);
    return 0;
}

/* IDAT.7.1 — seq continues to increase across distinct pump calls;
   the second pump's first event has seq > the first pump's last.
   Pre-pump engine_assert events (FACT_ASSERT) lie in the same stream. */
static int test_idat_7_1__seq_strictly_increasing_across_pumps(void)
{
    obs_buf_t buf = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &buf, 100,
            TRIG_SCHEMA
            "rule p:\n    Trig t where t.tag == \"a\"\n->\n    log info \"a\"\n\n"
            "rule q:\n    Trig t where t.tag == \"b\"\n->\n    log info \"b\"\n")) return 1;
    if (fire(e, trig, "a")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump 1", r);
    if (fire(e, trig, "b")) return 1;
    r = ds_engine_pump(e);
    EXPECT_OK("pump 2", r);
    if (check_seq_strictly_increasing(&buf, 0, buf.n, "across-pumps"))
        return 1;
    ds_engine_free(e);
    return 0;
}

/* IDAT.7.1 — per-engine monotonic: two engines run the same workload
   independently; each seq series is strictly increasing, and because
   the workload is identical the two final seqs match (one engine's
   counter is not driven by the other's events). */
static int test_idat_7_1__seq_independent_across_engines(void)
{
    obs_buf_t ba = {0}, bb = {0};
    ds_engine_t *a = NULL, *bb_engine = NULL;
    const ds_schema_t *trig_a = NULL, *trig_b = NULL;
    const char *src =
        TRIG_SCHEMA
        "rule x:\n    Trig t where t.tag == \"x\"\n->\n    log info \"m\"\n";
    if (build_engine(&a,         &trig_a, &ba, 100, src)) return 1;
    if (build_engine(&bb_engine, &trig_b, &bb, 100, src)) return 1;
    if (fire(a, trig_a, "x")) return 1;
    if (fire(bb_engine, trig_b, "x")) return 1;
    ds_result_t r = ds_engine_pump(a); EXPECT_OK("pump a", r);
    r = ds_engine_pump(bb_engine); EXPECT_OK("pump b", r);
    if (check_seq_strictly_increasing(&ba, 0, ba.n, "engine a")) return 1;
    if (check_seq_strictly_increasing(&bb, 0, bb.n, "engine b")) return 1;
    if (ba.n == 0 || bb.n == 0) {
        fprintf(stderr, "FAIL: engines emitted no events\n"); return 1;
    }
    if (ba.obs[ba.n - 1].seq != bb.obs[bb.n - 1].seq) {
        fprintf(stderr,
                "FAIL: per-engine seq independent; same workload last seq A=%llu B=%llu\n",
                (unsigned long long) ba.obs[ba.n - 1].seq,
                (unsigned long long) bb.obs[bb.n - 1].seq);
        return 1;
    }
    ds_engine_free(a);
    ds_engine_free(bb_engine);
    return 0;
}

/* IDAT.7.1 — clock_ns on each event reflects the engine clock at emit.
   With the mock clock held constant, every event carries that value. */
static int test_idat_7_1__clock_ns_reflects_mock_clock(void)
{
    obs_buf_t buf = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &buf, 7777,
            TRIG_SCHEMA
            "rule p:\n    Trig t where t.tag == \"x\"\n->\n    log info \"m\"\n")) return 1;
    if (fire(e, trig, "x")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    for (int i = 0; i < buf.n; i++) {
        if (buf.obs[i].clock_ns != 7777) {
            fprintf(stderr, "FAIL: obs[%d] kind=%d clock_ns=%llu, want 7777\n",
                    i, (int) buf.obs[i].kind,
                    (unsigned long long) buf.obs[i].clock_ns);
            return 1;
        }
    }
    ds_engine_free(e);
    return 0;
}

/* IDAT.7.1 — clock_ns advances with the engine clock across pumps. */
static int test_idat_7_1__clock_ns_advances_with_clock(void)
{
    obs_buf_t buf = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &buf, 1000,
            TRIG_SCHEMA
            "rule p:\n    Trig t where t.tag == \"a\"\n->\n    log info \"a\"\n\n"
            "rule q:\n    Trig t where t.tag == \"b\"\n->\n    log info \"b\"\n")) return 1;
    if (fire(e, trig, "a")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump 1", r);
    int boundary = buf.n;
    r = ds_engine_clock_set(e, 5000);
    EXPECT_OK("clock 5000", r);
    if (fire(e, trig, "b")) return 1;
    r = ds_engine_pump(e);
    EXPECT_OK("pump 2", r);
    for (int i = 0; i < boundary; i++) {
        if (buf.obs[i].clock_ns != 1000) {
            fprintf(stderr, "FAIL: pre-advance obs[%d] clock_ns=%llu, want 1000\n",
                    i, (unsigned long long) buf.obs[i].clock_ns);
            return 1;
        }
    }
    for (int i = boundary; i < buf.n; i++) {
        if (buf.obs[i].clock_ns != 5000) {
            fprintf(stderr, "FAIL: post-advance obs[%d] clock_ns=%llu, want 5000\n",
                    i, (unsigned long long) buf.obs[i].clock_ns);
            return 1;
        }
    }
    ds_engine_free(e);
    return 0;
}

/* IDAT.7.1 — multiple events sharing the same clock_ns still have
   distinct, strictly-increasing seqs (timestamps may collide; seqs do not). */
static int test_idat_7_1__same_clock_distinct_seqs(void)
{
    obs_buf_t buf = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &buf, 4242,
            TRIG_SCHEMA
            "rule p:\n    Trig t where t.tag == \"x\"\n->\n"
            "    log info \"a\"\n    log info \"b\"\n    log info \"c\"\n")) return 1;
    if (fire(e, trig, "x")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    for (int i = 0; i < buf.n; i++) {
        if (buf.obs[i].clock_ns != 4242) {
            fprintf(stderr, "FAIL: obs[%d] clock_ns=%llu, want 4242\n",
                    i, (unsigned long long) buf.obs[i].clock_ns);
            return 1;
        }
    }
    if (check_seq_strictly_increasing(&buf, 0, buf.n, "same-clock"))
        return 1;
    int n_log = 0;
    for (int i = 0; i < buf.n; i++)
        if (buf.obs[i].kind == DS_EV_ACTION_LOG) n_log++;
    if (n_log != 3) {
        fprintf(stderr, "FAIL: ACTION_LOG count=%d, want 3\n", n_log);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* The IDAT.7.2 scenario's callback and counters: ACTION_LOG
   (p.action_log.message) and FACT_ASSERT (p.fact_assert.fact), two union
   members, each read by its own field. */
static int  s_kdc_n_log;
static int  s_kdc_n_assert;
static char s_kdc_last_log_msg[64];
static int  s_kdc_assert_has_fact;

static ds_result_t kind_dispatch_cb(ds_engine_t          *engine,
                                    const ds_stream_ev_t *ev,
                                    void                 *user)
{
    (void) engine; (void) user;
    switch (ev->kind) {
    case DS_EV_ACTION_LOG:
        s_kdc_n_log++;
        s_kdc_last_log_msg[0] = '\0';
        if (ev->p.action_log.message)
            strncpy(s_kdc_last_log_msg, ev->p.action_log.message,
                    sizeof(s_kdc_last_log_msg) - 1);
        break;
    case DS_EV_FACT_ASSERT:
        s_kdc_n_assert++;
        if (ev->p.fact_assert.fact != NULL) s_kdc_assert_has_fact = 1;
        break;
    default:
        break;
    }
    return DS_OK_R;
}

/* IDAT.7.2 — kind-discriminated tagged union: a single stream cb over
   a mixed-kind workload reads each event's payload via the matching
   union field without corruption. */
static int test_idat_7_2__kind_discriminates_payload(void)
{
    s_kdc_n_log = 0;
    s_kdc_n_assert = 0;
    s_kdc_last_log_msg[0] = '\0';
    s_kdc_assert_has_fact = 0;
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    /* buf=NULL: this scenario installs its own kind-dispatch probe. */
    if (build_engine(&e, &trig, NULL, 1,
            TRIG_SCHEMA
            "rule p:\n    Trig t where t.tag == \"x\"\n->\n"
            "    log warning \"log-msg\"\n")) return 1;
    ds_result_t r = ds_engine_set_stream_callback(e, kind_dispatch_cb, NULL);
    EXPECT_OK("set stream cb", r);
    if (fire(e, trig, "x")) return 1;     /* FACT_ASSERT (fact_assert.fact) */
    r = ds_engine_pump(e);       /* ACTION_LOG (action_log.message) */
    EXPECT_OK("pump", r);
    if (s_kdc_n_log != 1 || strcmp(s_kdc_last_log_msg, "log-msg") != 0) {
        fprintf(stderr, "FAIL: log payload n=%d msg=\"%s\"\n",
                s_kdc_n_log, s_kdc_last_log_msg);
        return 1;
    }
    /* fact_assert.fact is a non-NULL ds_fact_t*. */
    if (s_kdc_n_assert < 1 || !s_kdc_assert_has_fact) {
        fprintf(stderr, "FAIL: fact_assert payload n=%d has_fact=%d\n",
                s_kdc_n_assert, s_kdc_assert_has_fact);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* [NTST.3.3] / [LTIM.2.8.5] — a mock-clock mutation is not a sample: it
   emits nothing. The next pump samples the clock and emits ONE DS_EV_TICK
   carrying the value the mutations left -- two mutations between samples
   leave one record -- and seq stays strictly increasing. Pure C-API; no
   rules, so a pump's only events are its TICK, when the sample moved, and
   its PUMP, always ([RFCS.22]: one per host pump, including one that fires
   nothing, after the sample's TICK). */
static int test_ntst_3_3__tick_on_the_sample_not_the_mutation(void)
{
    obs_buf_t buf = {0};
    ds_engine_t *e = NULL;
    ds_result_t r = ds_engine_new(NULL, &e);
    EXPECT_OK("engine_new", r);
    r = ds_engine_clock_set_mode(e, DS_CLOCK_MOCK);
    EXPECT_OK("clock_mode mock", r);
    r = ds_engine_set_stream_callback(e, stream_cb, &buf);
    EXPECT_OK("set_stream_cb", r);

    r = ds_engine_clock_set(e, 1000);
    EXPECT_OK("clock_set 1000", r);
    r = ds_engine_clock_advance(e, 500);
    EXPECT_OK("clock_advance 500", r);
    if (buf.n != 0) {
        fprintf(stderr, "FAIL: a mutation emitted %d event(s) (want 0)\n", buf.n);
        return 1;
    }

    r = ds_engine_pump(e);
    EXPECT_OK("pump 1", r);
    if (buf.n != 2 || buf.obs[0].kind != DS_EV_TICK ||
        buf.obs[0].clock_ns != 1500 || buf.obs[1].kind != DS_EV_PUMP ||
        buf.obs[1].clock_ns != 1500) {
        fprintf(stderr,
                "FAIL: first pump: n=%d kind=%d clock_ns=%llu (want 2: TICK 1500, PUMP 1500)\n",
                buf.n, buf.n > 0 ? (int) buf.obs[0].kind : -1,
                buf.n > 0 ? (unsigned long long) buf.obs[0].clock_ns : 0ULL);
        return 1;
    }

    /* An unchanged clock is not recorded again ([LTIM.2.8.5]); the pump
       still is ([RFCS.22]). */
    r = ds_engine_pump(e);
    EXPECT_OK("pump 2", r);
    if (buf.n != 3 || buf.obs[2].kind != DS_EV_PUMP) {
        fprintf(stderr,
                "FAIL: second pump: n=%d kind=%d (want 3, the third a PUMP and no TICK)\n",
                buf.n, buf.n > 2 ? (int) buf.obs[2].kind : -1);
        return 1;
    }

    r = ds_engine_clock_advance(e, 250);
    EXPECT_OK("clock_advance 250", r);
    r = ds_engine_pump(e);
    EXPECT_OK("pump 3", r);
    if (buf.n != 5 || buf.obs[3].kind != DS_EV_TICK ||
        buf.obs[3].clock_ns != 1750 || buf.obs[4].kind != DS_EV_PUMP) {
        fprintf(stderr,
                "FAIL: third pump: n=%d kind=%d clock_ns=%llu (want 5: TICK 1750, PUMP)\n",
                buf.n, buf.n > 3 ? (int) buf.obs[3].kind : -1,
                buf.n > 3 ? (unsigned long long) buf.obs[3].clock_ns : 0ULL);
        return 1;
    }
    if (check_seq_strictly_increasing(&buf, 0, buf.n, "ticks-and-pumps"))
        return 1;
    ds_engine_free(e);
    return 0;
}

/* ============== Driver ============== */

int main(void)
{
    int failed = 0;
    failed |= test_idat_7_1__seq_strictly_increasing_in_pump();
    failed |= test_idat_7_1__seq_strictly_increasing_across_pumps();
    failed |= test_idat_7_1__seq_independent_across_engines();
    failed |= test_idat_7_1__clock_ns_reflects_mock_clock();
    failed |= test_idat_7_1__clock_ns_advances_with_clock();
    failed |= test_idat_7_1__same_clock_distinct_seqs();
    failed |= test_idat_7_2__kind_discriminates_payload();
    failed |= test_ntst_3_3__tick_on_the_sample_not_the_mutation();
    if (!failed) printf("test_stream_seq_spec: OK\n");
    return failed;
}
