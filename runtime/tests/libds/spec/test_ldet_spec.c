/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * Determinism, black-box through libds.h and the stream sink:
 *   LDET.2.1 — two fresh engines given one mock-clock timeline, rule load
 *              and input sequence produce the same event stream.
 *   LDET.5.3 — refraction: an activation does not re-fire until its LHS
 *              changes, and retract-reassert releases it.
 */
#include <stdarg.h>

#include "spec_common.h"

/* ---- event trace ---------------------------------------------------- */

/* The trace records kind, sequence, clock and rule identity only: pointers
 * differ between two engines and are not part of the observable stream. */
#define TRACE_CAP 8192

typedef struct {
    char   buf[TRACE_CAP];
    size_t len;
    int    overflow;
} trace_t;

static void trace_addf(trace_t *t, const char *fmt, ...)
{
    va_list ap;
    if (t->overflow) return;
    va_start(ap, fmt);
    int n = vsnprintf(t->buf + t->len, TRACE_CAP - t->len, fmt, ap);
    va_end(ap);
    if (n < 0 || (size_t)n >= TRACE_CAP - t->len) { t->overflow = 1; return; }
    t->len += (size_t)n;
}

static ds_result_t trace_cb(ds_engine_t          *engine,
                            const ds_stream_ev_t *ev,
                            void                 *user)
{
    trace_t *t = user;
    (void)engine;
    switch (ev->kind) {
    case DS_EV_RULE_FIRE_BEGIN:
        trace_addf(t, "%llu %llu FIRE_BEGIN %s\n",
                   (unsigned long long)ev->seq,
                   (unsigned long long)ev->clock_ns,
                   ev->p.rule_fire_begin.rule_name
                       ? ev->p.rule_fire_begin.rule_name : "(null)");
        break;
    case DS_EV_RULE_FIRE_END:
        trace_addf(t, "%llu %llu FIRE_END %s\n",
                   (unsigned long long)ev->seq,
                   (unsigned long long)ev->clock_ns,
                   ev->p.rule_fire_end.rule_name
                       ? ev->p.rule_fire_end.rule_name : "(null)");
        break;
    case DS_EV_FACT_ASSERT:
        trace_addf(t, "%llu %llu FACT_ASSERT\n",
                   (unsigned long long)ev->seq,
                   (unsigned long long)ev->clock_ns);
        break;
    case DS_EV_FACT_RETRACT:
        trace_addf(t, "%llu %llu FACT_RETRACT\n",
                   (unsigned long long)ev->seq,
                   (unsigned long long)ev->clock_ns);
        break;
    case DS_EV_ACTION_LOG:
        trace_addf(t, "%llu %llu LOG %s\n",
                   (unsigned long long)ev->seq,
                   (unsigned long long)ev->clock_ns,
                   ev->p.action_log.message
                       ? ev->p.action_log.message : "(null)");
        break;
    default:
        /* An undecoded kind keeps its place in the order. */
        trace_addf(t, "%llu %llu KIND=%d\n",
                   (unsigned long long)ev->seq,
                   (unsigned long long)ev->clock_ns,
                   (int)ev->kind);
        break;
    }
    return DS_OK_R;
}

/* ---- shared fixture ------------------------------------------------- */

static const char *k_rules =
    "schema Reading scope logical:\n"
    "    sensor: String key\n"
    "    level: Float mutable\n"
    "\n"
    "rule hot:\n"
    "    Reading r where r.level > 30.0\n"
    "->\n"
    "    log critical \"hot\"\n";

/* Build an engine on the mock clock with k_rules loaded and the trace sink
 * attached. Returns NULL on any failure, having reported it. */
static ds_engine_t *make_engine(trace_t *t)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    ds_result_t r = ds_engine_new(&cfg, &e);
    if (r.status != DS_OK) { spec_fail("ldet: engine_new", r); return NULL; }

    /* Mock clock BEFORE loading, so no wall-clock reading can leak into the
       run and make a determinism comparison depend on how fast it ran. */
    r = ds_engine_clock_set_mode(e, DS_CLOCK_MOCK);
    if (r.status != DS_OK) { spec_fail("ldet: clock_set_mode", r);
                             ds_engine_free(e); return NULL; }
    r = ds_engine_clock_set(e, 1000);
    if (r.status != DS_OK) { spec_fail("ldet: clock_set", r);
                             ds_engine_free(e); return NULL; }

    r = spec_load_ds(e, k_rules);
    if (r.status != DS_OK) { spec_fail("ldet: load rules", r);
                             ds_engine_free(e); return NULL; }

    r = ds_engine_set_stream_callback(e, trace_cb, t);
    if (r.status != DS_OK) { spec_fail("ldet: set_stream_callback", r);
                             ds_engine_free(e); return NULL; }
    return e;
}

/* Drive one identical timeline: same asserts, same clock advances, same
 * pumps, in the same order. */
static int drive(ds_engine_t *e)
{
    const ds_schema_t *sc = NULL;
    ds_result_t r = ds_engine_schema_find(e, "Reading", &sc);
    EXPECT_OK("ldet: schema_find Reading", r);

    const double temps[] = { 21.5, 35.0, 12.25, 31.75 };
    for (size_t i = 0; i < sizeof(temps) / sizeof(temps[0]); i++) {
        ds_slot_value_t slots[2];
        slots[0].kind = DS_SLOT_STRING; slots[0].v.s = "die";
        slots[1].kind = DS_SLOT_FLOAT;  slots[1].v.f = temps[i];
        ds_fact_t *f = NULL;
        r = ds_engine_assert(e, sc, slots, 2, &f);
        EXPECT_OK("ldet: assert Reading", r);
        r = ds_engine_clock_advance(e, 1000);
        EXPECT_OK("ldet: clock_advance", r);
        r = ds_engine_pump(e);
        EXPECT_OK("ldet: pump", r);
    }
    return 0;
}

/* ---- LDET.2.1 ------------------------------------------------------- */

static int test_ldet_2_1__same_input_same_output(void)
{
    trace_t ta = { .len = 0, .overflow = 0 };
    trace_t tb = { .len = 0, .overflow = 0 };

    ds_engine_t *ea = make_engine(&ta);
    if (!ea) return 1;
    if (drive(ea)) { ds_engine_free(ea); return 1; }
    ds_engine_free(ea);

    ds_engine_t *eb = make_engine(&tb);
    if (!eb) return 1;
    if (drive(eb)) { ds_engine_free(eb); return 1; }
    ds_engine_free(eb);

    /* An overflowed trace compares equal to another overflowed trace while
       having discarded the tail, which would be a pass for work not done. */
    if (ta.overflow || tb.overflow) {
        fprintf(stderr, "FAIL: ldet.2.1: trace overflowed TRACE_CAP (%d) — "
                        "the comparison would be truncated, not clean\n",
                TRACE_CAP);
        return 1;
    }
    if (ta.len == 0) {
        fprintf(stderr, "FAIL: ldet.2.1: empty trace — the sink saw nothing, "
                        "so equality here would prove nothing\n");
        return 1;
    }
    if (ta.len != tb.len || memcmp(ta.buf, tb.buf, ta.len) != 0) {
        fprintf(stderr, "FAIL: ldet.2.1: replay diverged\n--- run A ---\n%s"
                        "--- run B ---\n%s", ta.buf, tb.buf);
        return 1;
    }
    return 0;
}

/* ---- LDET.5.3 ------------------------------------------------------- */

/* Count FIRE_BEGIN for the rule under test. */
typedef struct { int fires; } fire_count_t;

static ds_result_t fire_count_cb(ds_engine_t          *engine,
                                 const ds_stream_ev_t *ev,
                                 void                 *user)
{
    fire_count_t *fc = user;
    (void)engine;
    if (ev->kind == DS_EV_RULE_FIRE_BEGIN) fc->fires++;
    return DS_OK_R;
}

static int test_ldet_5_3__refraction_no_refire_until_lhs_changes(void)
{
    fire_count_t fc = { .fires = 0 };
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;

    ds_result_t r = ds_engine_new(&cfg, &e);
    EXPECT_OK("ldet.5.3: engine_new", r);
    r = ds_engine_clock_set_mode(e, DS_CLOCK_MOCK);
    EXPECT_OK("ldet.5.3: clock_set_mode", r);
    r = ds_engine_clock_set(e, 1000);
    EXPECT_OK("ldet.5.3: clock_set", r);
    r = spec_load_ds(e, k_rules);
    EXPECT_OK("ldet.5.3: load rules", r);
    r = ds_engine_set_stream_callback(e, fire_count_cb, &fc);
    EXPECT_OK("ldet.5.3: set_stream_callback", r);

    const ds_schema_t *sc = NULL;
    r = ds_engine_schema_find(e, "Reading", &sc);
    EXPECT_OK("ldet.5.3: schema_find", r);

    ds_slot_value_t slots[2];
    slots[0].kind = DS_SLOT_STRING; slots[0].v.s = "die";
    slots[1].kind = DS_SLOT_FLOAT;  slots[1].v.f = 35.0;

    ds_fact_t *f = NULL;
    r = ds_engine_assert(e, sc, slots, 2, &f);
    EXPECT_OK("ldet.5.3: first assert", r);
    r = ds_engine_pump(e);
    EXPECT_OK("ldet.5.3: first pump", r);

    int after_first = fc.fires;
    if (after_first != 1) {
        fprintf(stderr, "FAIL: ldet.5.3: want 1 fire after first pump, got %d\n",
                after_first);
        ds_engine_free(e);
        return 1;
    }

    /* A second pump with the LHS unchanged does not re-fire. */
    r = ds_engine_pump(e);
    EXPECT_OK("ldet.5.3: second pump", r);
    if (fc.fires != after_first) {
        fprintf(stderr, "FAIL: ldet.5.3: re-fired on an unchanged LHS "
                        "(%d -> %d)\n", after_first, fc.fires);
        ds_engine_free(e);
        return 1;
    }

    /* Retract-reassert releases the refraction: the binding tuple is new,
       so the activation is allowed to fire again. */
    r = ds_engine_retract(e, f);
    EXPECT_OK("ldet.5.3: retract", r);
    r = ds_engine_pump(e);
    EXPECT_OK("ldet.5.3: pump after retract", r);

    ds_fact_t *f2 = NULL;
    r = ds_engine_assert(e, sc, slots, 2, &f2);
    EXPECT_OK("ldet.5.3: reassert", r);
    r = ds_engine_pump(e);
    EXPECT_OK("ldet.5.3: pump after reassert", r);

    if (fc.fires != after_first + 1) {
        fprintf(stderr, "FAIL: ldet.5.3: retract-reassert did not release "
                        "refraction (want %d fires, got %d)\n",
                after_first + 1, fc.fires);
        ds_engine_free(e);
        return 1;
    }

    ds_engine_free(e);
    return 0;
}

/* ---- main ----------------------------------------------------------- */

int main(void)
{
    int failed = 0;
    failed |= test_ldet_2_1__same_input_same_output();
    failed |= test_ldet_5_3__refraction_no_refire_until_lhs_changes();
    if (!failed) printf("test_ldet_spec: OK\n");
    return failed;
}
