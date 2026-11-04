/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * Logical facts, black-box through libds.h:
 *   LLOG.1     — a fact emitted `logical` lives while its justifier does.
 *   LLOG.2     — two justifiers of the same fact coalesce; removing one is
 *                not enough.
 *   LLOG.2.7.2 — two justifiers emitting different values make two facts
 *                with separate lifetimes.
 *   IRET.12.2  — the clock tick's turnover withdraws no logical emit.
 *
 * LLOG.8.2 is not covered: the only public handle to an engine-created fact
 * is a stream event's, which libds.h makes valid only during the callback.
 */
#include "spec_common.h"

/* ---- per-schema assert/retract counting ----------------------------- */

typedef struct {
    char name[64];
    int  asserts;
    int  retracts;
} sc_count_t;

typedef struct {
    sc_count_t s[8];
    int        n;
    int        overflow;
} llog_probe_t;

static sc_count_t *probe_slot(llog_probe_t *p, const char *name)
{
    for (int i = 0; i < p->n; i++)
        if (strcmp(p->s[i].name, name) == 0) return &p->s[i];
    if (p->n == (int)(sizeof(p->s) / sizeof(p->s[0]))) { p->overflow = 1; return NULL; }
    sc_count_t *slot = &p->s[p->n++];
    snprintf(slot->name, sizeof slot->name, "%s", name);
    slot->asserts = slot->retracts = 0;
    return slot;
}

/* Asserts minus retracts; 0 for a schema never seen. */
static int probe_live(llog_probe_t *p, const char *name)
{
    for (int i = 0; i < p->n; i++)
        if (strcmp(p->s[i].name, name) == 0)
            return p->s[i].asserts - p->s[i].retracts;
    return 0;
}

static ds_result_t llog_cb(ds_engine_t          *engine,
                           const ds_stream_ev_t *ev,
                           void                 *user)
{
    llog_probe_t *p = user;
    ds_fact_t    *f = NULL;
    (void)engine;

    if      (ev->kind == DS_EV_FACT_ASSERT)  f = ev->p.fact_assert.fact;
    else if (ev->kind == DS_EV_FACT_RETRACT) f = ev->p.fact_retract.fact;
    else return DS_OK_R;
    if (!f) return DS_OK_R;

    const ds_schema_t *sc = NULL;
    if (ds_fact_get_schema(f, &sc).status != DS_OK || !sc) return DS_OK_R;
    const char *name = NULL;
    if (ds_schema_get_name(sc, &name).status != DS_OK || !name) return DS_OK_R;

    sc_count_t *slot = probe_slot(p, name);
    if (!slot) return DS_OK_R;
    if (ev->kind == DS_EV_FACT_ASSERT) slot->asserts++;
    else                               slot->retracts++;
    return DS_OK_R;
}

/* ---- fixture -------------------------------------------------------- */

static ds_engine_t *llog_engine(const char *rules, llog_probe_t *p)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    ds_result_t r = ds_engine_new(&cfg, &e);
    if (r.status != DS_OK) { spec_fail("llog: engine_new", r); return NULL; }
    r = ds_engine_clock_set_mode(e, DS_CLOCK_MOCK);
    if (r.status != DS_OK) { spec_fail("llog: clock_set_mode", r);
                             ds_engine_free(e); return NULL; }
    r = ds_engine_clock_set(e, 1000);
    if (r.status != DS_OK) { spec_fail("llog: clock_set", r);
                             ds_engine_free(e); return NULL; }
    r = spec_load_ds(e, rules);
    if (r.status != DS_OK) { spec_fail("llog: load rules", r);
                             ds_engine_free(e); return NULL; }
    r = ds_engine_set_stream_callback(e, llog_cb, p);
    if (r.status != DS_OK) { spec_fail("llog: set_stream_callback", r);
                             ds_engine_free(e); return NULL; }
    return e;
}

/* Assert one Trig with the given tag, pump, hand back the fact. */
static int trig_assert(ds_engine_t *e, const char *tag, ds_fact_t **out)
{
    const ds_schema_t *sc = NULL;
    ds_result_t r = ds_engine_schema_find(e, "Trig", &sc);
    EXPECT_OK("llog: schema_find Trig", r);
    ds_slot_value_t slots[1];
    slots[0].kind = DS_SLOT_STRING; slots[0].v.s = tag;
    r = ds_engine_assert(e, sc, slots, 1, out);
    EXPECT_OK("llog: assert Trig", r);
    r = ds_engine_pump(e);
    EXPECT_OK("llog: pump after assert", r);
    return 0;
}

static int retract_and_pump(ds_engine_t *e, ds_fact_t *f)
{
    ds_result_t r = ds_engine_retract(e, f);
    EXPECT_OK("llog: retract Trig", r);
    r = ds_engine_pump(e);
    EXPECT_OK("llog: pump after retract", r);
    return 0;
}

/* ---- LLOG.1 / LLOG.2 ------------------------------------------------ */

/* Two rules emit the same logical fact, d: "x". */
static const char *k_rules_same =
    "schema Trig scope logical:\n"
    "    tag: String key\n"
    "\n"
    "schema Derived scope logical:\n"
    "    d: String key\n"
    "\n"
    "rule from_a:\n"
    "    Trig t where t.tag == \"a\"\n"
    "->\n"
    "    emit Derived logical d: \"x\"\n"
    "\n"
    "rule from_b:\n"
    "    Trig t where t.tag == \"b\"\n"
    "->\n"
    "    emit Derived logical d: \"x\"\n";

static int test_llog_1__logical_fact_follows_its_justifier(void)
{
    llog_probe_t p = { .n = 0, .overflow = 0 };
    ds_engine_t *e = llog_engine(k_rules_same, &p);
    if (!e) return 1;

    ds_fact_t *ta = NULL;
    if (trig_assert(e, "a", &ta)) { ds_engine_free(e); return 1; }
    if (probe_live(&p, "Derived") != 1) {
        fprintf(stderr, "FAIL: llog.1: want 1 live Derived after its "
                        "justifier, got %d\n", probe_live(&p, "Derived"));
        ds_engine_free(e); return 1;
    }

    /* The sole justifier goes, and the logical fact with it. */
    if (retract_and_pump(e, ta)) { ds_engine_free(e); return 1; }
    if (probe_live(&p, "Derived") != 0) {
        fprintf(stderr, "FAIL: llog.1: Derived outlived its only justifier "
                        "(%d still live)\n", probe_live(&p, "Derived"));
        ds_engine_free(e); return 1;
    }
    ds_engine_free(e);
    return 0;
}

static int test_llog_2__multi_justifier_coalescence(void)
{
    llog_probe_t p = { .n = 0, .overflow = 0 };
    ds_engine_t *e = llog_engine(k_rules_same, &p);
    if (!e) return 1;

    ds_fact_t *ta = NULL, *tb = NULL;
    if (trig_assert(e, "a", &ta)) { ds_engine_free(e); return 1; }
    if (trig_assert(e, "b", &tb)) { ds_engine_free(e); return 1; }

    /* Two justifiers, one fact. */
    if (probe_live(&p, "Derived") != 1) {
        fprintf(stderr, "FAIL: llog.2: two justifiers of the same value did "
                        "not coalesce (%d live Derived)\n",
                probe_live(&p, "Derived"));
        ds_engine_free(e); return 1;
    }

    /* Losing one justifier is not enough: the other still supports it. */
    if (retract_and_pump(e, ta)) { ds_engine_free(e); return 1; }
    if (probe_live(&p, "Derived") != 1) {
        fprintf(stderr, "FAIL: llog.2: Derived died with one justifier still "
                        "standing (%d live)\n", probe_live(&p, "Derived"));
        ds_engine_free(e); return 1;
    }

    /* Losing the last one is. */
    if (retract_and_pump(e, tb)) { ds_engine_free(e); return 1; }
    if (probe_live(&p, "Derived") != 0) {
        fprintf(stderr, "FAIL: llog.2: Derived outlived its last justifier "
                        "(%d live)\n", probe_live(&p, "Derived"));
        ds_engine_free(e); return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* ---- LLOG.2.7.2 ----------------------------------------------------- */

/* Each Trig emits its own value. */
static const char *k_rules_distinct =
    "schema Trig scope logical:\n"
    "    tag: String key\n"
    "\n"
    "schema Derived scope logical:\n"
    "    d: String key\n"
    "\n"
    "rule mirror:\n"
    "    Trig t\n"
    "->\n"
    "    emit Derived logical d: t.tag\n";

static int test_llog_2_7_2__distinct_values_stay_independent(void)
{
    llog_probe_t p = { .n = 0, .overflow = 0 };
    ds_engine_t *e = llog_engine(k_rules_distinct, &p);
    if (!e) return 1;

    ds_fact_t *ta = NULL, *tb = NULL;
    if (trig_assert(e, "a", &ta)) { ds_engine_free(e); return 1; }
    if (trig_assert(e, "b", &tb)) { ds_engine_free(e); return 1; }

    if (probe_live(&p, "Derived") != 2) {
        fprintf(stderr, "FAIL: llog.2.7.2: want 2 distinct Derived facts, "
                        "got %d\n", probe_live(&p, "Derived"));
        ds_engine_free(e); return 1;
    }

    /* Retracting one justifier takes exactly its fact. */
    if (retract_and_pump(e, ta)) { ds_engine_free(e); return 1; }
    if (probe_live(&p, "Derived") != 1) {
        fprintf(stderr, "FAIL: llog.2.7.2: retracting one justifier left %d "
                        "live Derived, want 1\n", probe_live(&p, "Derived"));
        ds_engine_free(e); return 1;
    }

    if (p.overflow) {
        fprintf(stderr, "FAIL: llog: probe overflowed its schema table — the "
                        "counts above are incomplete\n");
        ds_engine_free(e); return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* ---- IRET.12.2: the clock tick's turnover ends no activation --------- */

/* A `within` rule's match carries the tick: the compiler puts `$ClockTick`
 * in its LHS, and each pump turns the tick over. [IRET.12.2]: the tick is not a
 * supporting fact, so a match that persists across ticks is the same
 * activation ([IRET.19.5]), and its logical emit must not be withdrawn and
 * re-emitted on each tick. It goes on the tick at which the window closes
 * ([LTIM.2.7.2]).
 *
 * The Sensor arrives at 1 us. Two pumps inside the 3 s window turn the tick
 * over twice, and Occupied stays at one assert and no retract. The pump past
 * the window retracts it once. */
static const char *k_rules_within =
    "schema Sensor scope logical:\n"
    "    state: String key\n"
    "\n"
    "schema Occupied scope logical:\n"
    "    dummy: Int key\n"
    "\n"
    "rule occupy:\n"
    "    Sensor within 3_s\n"
    "->\n"
    "    emit Occupied logical dummy: 0\n";

static int sc_asserts(llog_probe_t *p, const char *name)
{
    for (int i = 0; i < p->n; i++)
        if (strcmp(p->s[i].name, name) == 0) return p->s[i].asserts;
    return 0;
}

static int sc_retracts(llog_probe_t *p, const char *name)
{
    for (int i = 0; i < p->n; i++)
        if (strcmp(p->s[i].name, name) == 0) return p->s[i].retracts;
    return 0;
}

static int test_iret_12_2__the_tick_turnover_withdraws_nothing(void)
{
    llog_probe_t p = { .n = 0, .overflow = 0 };
    ds_engine_t *e = llog_engine(k_rules_within, &p);
    if (!e) return 1;

    const ds_schema_t *sc = NULL;
    ds_result_t r = ds_engine_schema_find(e, "Sensor", &sc);
    if (r.status != DS_OK) { ds_engine_free(e); return spec_fail("iret.12.2: schema_find Sensor", r); }
    ds_slot_value_t slots[1];
    slots[0].kind = DS_SLOT_STRING; slots[0].v.s = "on";
    r = ds_engine_assert(e, sc, slots, 1, NULL);
    if (r.status != DS_OK) { ds_engine_free(e); return spec_fail("iret.12.2: assert Sensor", r); }
    r = ds_engine_pump(e);
    if (r.status != DS_OK) { ds_engine_free(e); return spec_fail("iret.12.2: pump 1", r); }
    if (sc_asserts(&p, "Occupied") != 1 || sc_retracts(&p, "Occupied") != 0) {
        fprintf(stderr, "FAIL: iret.12.2: premise -- want Occupied emitted once, "
                        "got %d asserts, %d retracts\n",
                sc_asserts(&p, "Occupied"), sc_retracts(&p, "Occupied"));
        ds_engine_free(e); return 1;
    }

    /* Two turnovers inside the window: 1 s and 2 s after the Sensor. */
    for (int i = 0; i < 2; i++) {
        r = ds_engine_clock_advance(e, 1000000000ull);
        if (r.status != DS_OK) { ds_engine_free(e); return spec_fail("iret.12.2: advance", r); }
        r = ds_engine_pump(e);
        if (r.status != DS_OK) { ds_engine_free(e); return spec_fail("iret.12.2: pump in window", r); }
    }
    if (sc_asserts(&p, "Occupied") != 1 || sc_retracts(&p, "Occupied") != 0) {
        fprintf(stderr, "FAIL: iret.12.2: the tick's turnover withdrew the "
                        "activation's emit -- want 1 assert and 0 retracts of "
                        "Occupied inside the window, got %d and %d\n",
                sc_asserts(&p, "Occupied"), sc_retracts(&p, "Occupied"));
        ds_engine_free(e); return 1;
    }

    /* Past the window (4 s after the Sensor): the test goes false, and the
       activation ends on this tick. */
    r = ds_engine_clock_advance(e, 2000000000ull);
    if (r.status != DS_OK) { ds_engine_free(e); return spec_fail("iret.12.2: advance past", r); }
    r = ds_engine_pump(e);
    if (r.status != DS_OK) { ds_engine_free(e); return spec_fail("iret.12.2: pump past", r); }
    if (sc_retracts(&p, "Occupied") != 1 || probe_live(&p, "Occupied") != 0) {
        fprintf(stderr, "FAIL: iret.12.2: the closed window did not withdraw "
                        "Occupied once (%d retracts, %d live)\n",
                sc_retracts(&p, "Occupied"), probe_live(&p, "Occupied"));
        ds_engine_free(e); return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* ---- main ----------------------------------------------------------- */

int main(void)
{
    int failed = 0;
    failed |= test_llog_1__logical_fact_follows_its_justifier();
    failed |= test_llog_2__multi_justifier_coalescence();
    failed |= test_llog_2_7_2__distinct_values_stay_independent();
    failed |= test_iret_12_2__the_tick_turnover_withdraws_nothing();
    if (!failed) printf("test_llog_spec: OK\n");
    return failed;
}
