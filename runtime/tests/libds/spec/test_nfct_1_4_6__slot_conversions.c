/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NFCT.1.4.6]
 * @spec [RDSC.5.5.9]
 * A slot that names a unit converts a host's number: ds_schema_slot_to_stored
 * computes what `x::<unit>` computes, ds_schema_slot_from_stored what a kwarg
 * of that unit receives, each through the conversion the compiler wrote on
 * the slot, and each refuses with the first condition of [NFCT.1.4.6]'s table
 * that holds.
 *
 * THE PATH, for every test here ([STYL.5.10.8]): the Slot's `to_stored` and
 * `from_stored` (dsc/loader.c handle_slot, onto the rete schema at apply),
 * evaluated by engine_rete_adapters.c's nfct_1_4_6_convert with bind_frame[0]
 * holding the host's number and every fault held.
 */
#include <math.h>
#include <stdint.h>

#include "spec_common.h"
#include "spec_tamper.h"

static const char *PROGRAM =
    "unit celsius: temperature = x + 273.15\n"
    "\n"
    "unit dimension area storage float64 base plot\n"
    "unit plot: area\n"
    "unit sq: area:\n"
    "    to_base:   x * x + 1.0\n"
    "    from_base: (x - 1.0) ** 0.5\n"
    "\n"
    "schema Reading scope logical:\n"
    "    id: String key\n"
    "    temp: celsius mutable\n"
    "    span: millisecond mutable\n"
    "    tick: nanosecond mutable\n"
    "    raw: Float mutable\n"
    "    heat: temperature mutable\n"
    "    side: sq mutable\n"
    "\n"
    "schema Out scope logical:\n"
    "    k: Int key\n"
    "    v: plot mutable\n"
    "\n"
    "schema Trig scope logical:\n"
    "    tag: String key\n"
    "\n"
    "service notify.ping:\n"
    "    \"ping\"\n"
    "    no response\n"
    "\n"
    "rule asserted:\n"
    "    Reading r\n"
    "->\n"
    "    emit Out logical k: 1 v: r.raw::sq\n"
    "\n"
    "rule ping:\n"
    "    Trig\n"
    "->\n"
    "    call notify.ping nocooldown as \"corr\"\n";

/* Reading's slots, in declaration order. */
enum { S_ID, S_TEMP, S_SPAN, S_TICK, S_RAW, S_HEAT, S_SIDE, S_COUNT };

static ds_slot_value_t ival(int64_t i)
{
    ds_slot_value_t v;
    memset(&v, 0, sizeof v);
    v.kind = DS_SLOT_INT;
    v.v.i = i;
    return v;
}

static ds_slot_value_t fval(double f)
{
    ds_slot_value_t v;
    memset(&v, 0, sizeof v);
    v.kind = DS_SLOT_FLOAT;
    v.v.f = f;
    return v;
}

static int load(ds_engine_t **e, const ds_schema_t **reading)
{
    EXPECT_OK("engine", ds_engine_new(NULL, e));
    EXPECT_OK("load", spec_load_ds(*e, PROGRAM));
    EXPECT_OK("find Reading", ds_engine_schema_find(*e, "Reading", reading));
    if (*reading == NULL) {
        fprintf(stderr, "FAIL: no Reading schema\n");
        return 1;
    }
    return 0;
}

static int want_float(const char *what, ds_result_t r, const ds_slot_value_t *out,
                      double want)
{
    EXPECT_OK(what, r);
    if (out->kind != DS_SLOT_FLOAT || out->v.f != want) {
        fprintf(stderr, "FAIL: %s: kind %d value %.17g, want a Float %.17g\n",
                what, (int) out->kind, out->v.f, want);
        return 1;
    }
    return 0;
}

static int want_int(const char *what, ds_result_t r, const ds_slot_value_t *out,
                    int64_t want)
{
    EXPECT_OK(what, r);
    if (out->kind != DS_SLOT_INT || out->v.i != want) {
        fprintf(stderr, "FAIL: %s: kind %d value %lld, want an Int %lld\n",
                what, (int) out->kind, (long long) out->v.i, (long long) want);
        return 1;
    }
    return 0;
}

/* A tier-1 unit's affine map, both ways: `celsius` is `x + 273.15`, and back
   `x - 273.15`, each computed here in C ([RLOW.6.1.10], [RLOW.7.3.9]). */
static int test_nfct_1_4_6__tier1_float(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *s = NULL;
    if (load(&e, &s)) return 1;
    ds_slot_value_t in = fval(27.0), out;
    const double stored = 27.0 + 273.15;
    if (want_float("to_stored(27.0) on celsius",
                   ds_schema_slot_to_stored(s, S_TEMP, &in, &out), &out, stored))
        return 1;
    in = fval(stored);
    if (want_float("from_stored on celsius",
                   ds_schema_slot_from_stored(s, S_TEMP, &in, &out), &out,
                   stored - 273.15))
        return 1;
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

/* An integer-stored dimension: a `millisecond` slot through FN_DURATION_MUL
   and FN_INT_DIV_EXACT; a `nanosecond` one, the base unit, through
   FN_DURATION_MUL(x, 1), which gives 0 for a negative number ([LTIM.1.3.1]). */
static int test_nfct_1_4_6__int64_storage(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *s = NULL;
    if (load(&e, &s)) return 1;
    ds_slot_value_t in = ival(2), out;
    if (want_int("to_stored(2) on millisecond",
                 ds_schema_slot_to_stored(s, S_SPAN, &in, &out), &out, 2000000))
        return 1;
    in = ival(2000000);
    if (want_int("from_stored(2000000) on millisecond",
                 ds_schema_slot_from_stored(s, S_SPAN, &in, &out), &out, 2))
        return 1;
    in = ival(-5);
    if (want_int("to_stored(-5) on nanosecond",
                 ds_schema_slot_to_stored(s, S_TICK, &in, &out), &out, 0))
        return 1;
    in = ival(7);
    if (want_int("to_stored(7) on nanosecond",
                 ds_schema_slot_to_stored(s, S_TICK, &in, &out), &out, 7))
        return 1;
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

/* FN_INT_DIV_EXACT's NOT_REPRESENTABLE: 1500 ns is no whole number of
   milliseconds. *out is not written. */
static int test_nfct_1_4_6__not_whole_is_refused(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *s = NULL;
    if (load(&e, &s)) return 1;
    ds_slot_value_t in = ival(1500), out = fval(-1.0);
    EXPECT_STATUS("from_stored(1500) on millisecond",
                  ds_schema_slot_from_stored(s, S_SPAN, &in, &out),
                  DS_ERR_NOT_REPRESENTABLE);
    if (out.kind != DS_SLOT_FLOAT || out.v.f != -1.0) {
        fprintf(stderr, "FAIL: a refused from_stored wrote *out\n");
        return 1;
    }
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

/* FN_DURATION_MUL past the Duration range ([LTIM.4.1.1]). */
static int test_nfct_1_4_6__past_the_range_is_refused(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *s = NULL;
    if (load(&e, &s)) return 1;
    ds_slot_value_t in = ival(INT64_MAX), out;
    EXPECT_STATUS("to_stored(INT64_MAX) on millisecond",
                  ds_schema_slot_to_stored(s, S_SPAN, &in, &out),
                  DS_ERR_NOT_REPRESENTABLE);
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

static double g_out_v;
static int g_out_seen;

static ds_result_t on_event(ds_engine_t *e, const ds_stream_ev_t *ev, void *user)
{
    (void) e; (void) user;
    if (ev->kind != DS_EV_FACT_ASSERT) return DS_OK_R;
    const ds_schema_t *sc = NULL;
    const char *name = NULL;
    ds_slot_value_t v;
    if (ds_fact_get_schema(ev->p.fact_assert.fact, &sc).status == DS_OK
        && ds_schema_get_name(sc, &name).status == DS_OK
        && name != NULL && strcmp(name, "Out") == 0
        && ds_fact_get_slot(ev->p.fact_assert.fact, 1, NULL, &v).status == DS_OK
        && v.kind == DS_SLOT_FLOAT) {
        g_out_v = v.v.f;
        g_out_seen++;
    }
    return DS_OK_R;
}

/* A tier-2 unit's `to_base` and `from_base` bodies ([LUNI.4.3]): to_stored(3.0)
   equals what the rule's `r.raw::sq` computes for the same number, read off the
   `Out` fact it emits, and from_stored takes it back. */
static int test_nfct_1_4_6__tier2(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *s = NULL;
    if (load(&e, &s)) return 1;
    EXPECT_OK("stream", ds_engine_set_stream_callback(e, on_event, NULL));
    ds_slot_value_t row[S_COUNT];
    memset(row, 0, sizeof row);
    row[S_ID].kind = DS_SLOT_STRING;
    row[S_ID].v.s = "r";
    row[S_TEMP] = fval(300.0);
    row[S_SPAN] = ival(0);
    row[S_TICK] = ival(0);
    row[S_RAW] = fval(3.0);
    row[S_HEAT] = fval(300.0);
    row[S_SIDE] = fval(10.0);
    g_out_seen = 0;
    EXPECT_OK("assert Reading", ds_engine_assert(e, s, row, S_COUNT, NULL));
    EXPECT_OK("pump", ds_engine_pump(e));
    if (g_out_seen != 1) {
        fprintf(stderr, "FAIL: the rule emitted %d Out facts, want 1\n",
                g_out_seen);
        return 1;
    }
    ds_slot_value_t in = fval(3.0), out;
    if (want_float("to_stored(3.0) on sq, against the rule's 3.0::sq",
                   ds_schema_slot_to_stored(s, S_SIDE, &in, &out), &out,
                   g_out_v))
        return 1;
    if (g_out_v != 3.0 * 3.0 + 1.0) {
        fprintf(stderr, "FAIL: the rule's 3.0::sq is %.17g, want 10.0\n",
                g_out_v);
        return 1;
    }
    in = fval(10.0);
    if (want_float("from_stored(10.0) on sq",
                   ds_schema_slot_from_stored(s, S_SIDE, &in, &out), &out, 3.0))
        return 1;
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

/* [NFCT.1.4.6]'s table, each row with every earlier one passing, and the
   earliest of two that both hold. */
static int test_nfct_1_4_6__refusals_in_order(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *s = NULL;
    if (load(&e, &s)) return 1;
    ds_slot_value_t in = fval(1.0), out;
    EXPECT_STATUS("a NULL out", ds_schema_slot_to_stored(s, S_TEMP, &in, NULL),
                  DS_ERR_INVAL);
    EXPECT_STATUS("a NULL schema",
                  ds_schema_slot_from_stored(NULL, S_TEMP, &in, &out),
                  DS_ERR_INVAL);
    EXPECT_STATUS("an index past the slots",
                  ds_schema_slot_to_stored(s, S_COUNT, &in, &out),
                  DS_ERR_NOT_FOUND);
    EXPECT_STATUS("a Float slot names no unit",
                  ds_schema_slot_to_stored(s, S_RAW, &in, &out), DS_ERR_INVAL);
    EXPECT_STATUS("a dimension-typed slot names no unit",
                  ds_schema_slot_from_stored(s, S_HEAT, &in, &out),
                  DS_ERR_INVAL);
    in = ival(1);
    EXPECT_STATUS("an Int on a celsius slot",
                  ds_schema_slot_to_stored(s, S_TEMP, &in, &out),
                  DS_ERR_SLOT_TYPE_MISMATCH);
    in = fval(1.0);
    EXPECT_STATUS("a Float on a millisecond slot",
                  ds_schema_slot_from_stored(s, S_SPAN, &in, &out),
                  DS_ERR_SLOT_TYPE_MISMATCH);
    in = fval(NAN);
    EXPECT_STATUS("a NaN", ds_schema_slot_to_stored(s, S_TEMP, &in, &out),
                  DS_ERR_NAN_REJECTED);
    EXPECT_STATUS("a NaN on a slot that names no unit",
                  ds_schema_slot_to_stored(s, S_RAW, &in, &out), DS_ERR_INVAL);
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

typedef struct {
    const ds_schema_t *reading;
    int                calls;
    int                in_state;
    ds_result_t        to, from;
    ds_slot_value_t    to_out, from_out;
} cb_probe_t;

static ds_result_t on_call(ds_engine_t *e, const ds_call_request_t *req,
                           void *user)
{
    (void) req;
    cb_probe_t *p = (cb_probe_t *) user;
    size_t n = 0;
    p->calls++;
    p->in_state = ds_engine_fact_count(e, &n).status == DS_ERR_STATE;
    ds_slot_value_t in = ival(2);
    p->to = ds_schema_slot_to_stored(p->reading, S_SPAN, &in, &p->to_out);
    in = ival(2000000);
    p->from = ds_schema_slot_from_stored(p->reading, S_SPAN, &in, &p->from_out);
    return DS_OK_R;
}

/* Neither call is a ds_engine_* call, so [RARC.13.16] does not refuse one made
   from a callback: from the call callback, where ds_engine_fact_count is
   DS_ERR_STATE, each answers. */
static int test_nfct_1_4_6__in_a_callback(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *s = NULL, *trig = NULL;
    if (load(&e, &s)) return 1;
    EXPECT_OK("find Trig", ds_engine_schema_find(e, "Trig", &trig));
    cb_probe_t p;
    memset(&p, 0, sizeof p);
    p.reading = s;
    EXPECT_OK("call callback", ds_engine_set_call_callback(e, on_call, &p));
    ds_slot_value_t tag;
    memset(&tag, 0, sizeof tag);
    tag.kind = DS_SLOT_STRING;
    tag.v.s = "t";
    EXPECT_OK("assert Trig", ds_engine_assert(e, trig, &tag, 1, NULL));
    EXPECT_OK("pump", ds_engine_pump(e));
    if (p.calls != 1 || !p.in_state) {
        fprintf(stderr, "FAIL: %d calls, and a ds_engine_* call %s refused "
                "inside: want one, refused\n", p.calls,
                p.in_state ? "was" : "was not");
        return 1;
    }
    if (want_int("to_stored inside the callback", p.to, &p.to_out, 2000000))
        return 1;
    if (want_int("from_stored inside the callback", p.from, &p.from_out, 2))
        return 1;
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

/* "After an EngineError each returns DS_ERR_ENGINE_HALTED", and `*out` is
   written only on DS_OK; a NULL pointer stays the table's earlier row,
   DS_ERR_INVAL. The halt is spec_tamper.h's negative fixture: `halt` reads the
   slot `lied`, which the edited artefact declares String, so the pump raises
   ENGINE_FAULT_ARTEFACT_LIED ([NCBK.2.9]). The `U` schema handle is taken
   before the halt, and its `span` slot converts before it: the control. */
static const char *HALT_PROGRAM =
    "schema P scope logical:\n"
    "    id: Int key\n"
    "    lied: Int mutable\n"
    "\n"
    "schema Out scope logical:\n"
    "    id: Int key\n"
    "    v: Int mutable\n"
    "\n"
    "schema U scope logical:\n"
    "    id: String key\n"
    "    span: millisecond mutable\n"
    "\n"
    "rule halt:\n"
    "    P p\n"
    "->\n"
    "    emit Out logical id: p.id v: p.lied + 1\n";

static int test_nfct_1_4_6__halted_engine(void)
{
    uint8_t *dsc = NULL;
    size_t len = 0;
    ds_result_t r = spec_compile_ds(HALT_PROGRAM, &dsc, &len);
    if (r.status != DS_OK) return spec_fail("compile", r);
    if (lie(dsc, len)) { free(dsc); return 1; }
    ds_engine_t *e = NULL;
    r = ds_engine_new(NULL, &e);
    if (r.status != DS_OK) { free(dsc); return spec_fail("engine", r); }
    r = ds_engine_load_dsc(e, dsc, len);
    free(dsc);
    EXPECT_OK("load the edited artefact", r);
    const ds_schema_t *u = NULL, *p = NULL;
    EXPECT_OK("find U", ds_engine_schema_find(e, "U", &u));
    EXPECT_OK("find P", ds_engine_schema_find(e, "P", &p));
    enum { U_SPAN = 1 };

    ds_slot_value_t in = ival(2), out;
    if (want_int("the control: to_stored(2) before the halt",
                 ds_schema_slot_to_stored(u, U_SPAN, &in, &out), &out, 2000000))
        return 1;

    ds_slot_value_t row[2];
    memset(row, 0, sizeof row);
    row[0] = ival(1);
    row[1].kind = DS_SLOT_STRING;
    row[1].v.s = "x";
    EXPECT_OK("assert P", ds_engine_assert(e, p, row, 2, NULL));
    EXPECT_STATUS("the pump that reads the lie", ds_engine_pump(e),
                  DS_ERR_ENGINE_HALTED);
    bool halted = false;
    EXPECT_OK("ds_engine_halted", ds_engine_halted(e, &halted, NULL));
    if (!halted) {
        fprintf(stderr, "FAIL: premise: the engine did not halt\n");
        return 1;
    }

    in = ival(2);
    out = fval(-1.0);
    EXPECT_STATUS("to_stored(2) after the halt",
                  ds_schema_slot_to_stored(u, U_SPAN, &in, &out),
                  DS_ERR_ENGINE_HALTED);
    in = ival(2000000);
    EXPECT_STATUS("from_stored(2000000) after the halt",
                  ds_schema_slot_from_stored(u, U_SPAN, &in, &out),
                  DS_ERR_ENGINE_HALTED);
    if (out.kind != DS_SLOT_FLOAT || out.v.f != -1.0) {
        fprintf(stderr, "FAIL: a call after the halt wrote *out\n");
        return 1;
    }
    EXPECT_STATUS("a NULL out after the halt",
                  ds_schema_slot_to_stored(u, U_SPAN, &in, NULL), DS_ERR_INVAL);
    ds_engine_free(e);
    return 0;
}

/* "Neither call changes the engine, records an event or asserts a fault
   fact." A refused conversion's fault is held ([NFCT.1.4.6]), not queued for
   the next pump: from_stored(1500) on the `millisecond` slot is refused,
   to_stored(2) taken, and neither streams an event; the pump after them
   finds no ComputationError, so `caught` does not fire and working memory
   stays empty. THE CONTROL: a `where` that divides by zero raises a real
   ComputationError, whose fact `caught` matches and logs, so the empty pump
   is the conversions' and not a rule that cannot fire. */
static const char *RECORD_PROGRAM =
    "schema R scope logical:\n"
    "    id: String key\n"
    "    span: millisecond mutable\n"
    "\n"
    "schema Div scope logical:\n"
    "    n: Int key\n"
    "\n"
    "rule divides:\n"
    "    Div d where 1 // d.n > 0\n"
    "->\n"
    "    log info \"divided\"\n"
    "\n"
    "rule caught:\n"
    "    ComputationError e\n"
    "->\n"
    "    log info \"caught {e.kind}\"\n";

typedef struct {
    int events;
    int logs;
} seen_t;

static ds_result_t count_events(ds_engine_t *e, const ds_stream_ev_t *ev,
                                void *user)
{
    (void) e;
    seen_t *s = (seen_t *) user;
    s->events++;
    if (ev->kind == DS_EV_ACTION_LOG) s->logs++;
    return DS_OK_R;
}

static int test_nfct_1_4_6__records_nothing(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *r = NULL, *div = NULL;
    EXPECT_OK("engine", ds_engine_new(NULL, &e));
    EXPECT_OK("load", spec_load_ds(e, RECORD_PROGRAM));
    EXPECT_OK("find R", ds_engine_schema_find(e, "R", &r));
    EXPECT_OK("find Div", ds_engine_schema_find(e, "Div", &div));
    enum { R_SPAN = 1 };
    seen_t seen;
    memset(&seen, 0, sizeof seen);
    EXPECT_OK("stream", ds_engine_set_stream_callback(e, count_events, &seen));

    ds_slot_value_t in = ival(1500), out;
    EXPECT_STATUS("from_stored(1500) on millisecond",
                  ds_schema_slot_from_stored(r, R_SPAN, &in, &out),
                  DS_ERR_NOT_REPRESENTABLE);
    in = ival(2);
    if (want_int("to_stored(2) on millisecond",
                 ds_schema_slot_to_stored(r, R_SPAN, &in, &out), &out, 2000000))
        return 1;
    if (seen.events != 0) {
        fprintf(stderr, "FAIL: the two calls streamed %d events, want none\n",
                seen.events);
        return 1;
    }

    EXPECT_OK("the pump after the calls", ds_engine_pump(e));
    size_t facts = 0;
    EXPECT_OK("fact_count", ds_engine_fact_count(e, &facts));
    if (seen.logs != 0 || facts != 0) {
        fprintf(stderr, "FAIL: the pump after the calls logged %d times and "
                "holds %zu facts, want none: a fault was queued\n",
                seen.logs, facts);
        return 1;
    }

    ds_slot_value_t zero = ival(0);
    EXPECT_OK("the control: assert Div n=0", ds_engine_assert(e, div, &zero, 1, NULL));
    EXPECT_OK("the control: pump", ds_engine_pump(e));
    if (seen.logs < 1) {
        fprintf(stderr, "FAIL: the control: a real ComputationError did not "
                "fire `caught`\n");
        return 1;
    }
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

/* "Its result is NaN" is DS_ERR_NOT_REPRESENTABLE: the tier-2 `sq` slot's
   from_stored(0.5) is `(0.5 - 1.0) ** 0.5`, a NaN, from an input that is no
   NaN. `*out` is not written. The control is from_stored(10.0), 3.0, in
   test_nfct_1_4_6__tier2. */
static int test_nfct_1_4_6__a_nan_result_is_not_representable(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *s = NULL;
    if (load(&e, &s)) return 1;
    ds_slot_value_t in = fval(0.5), out = ival(-7);
    EXPECT_STATUS("from_stored(0.5) on sq",
                  ds_schema_slot_from_stored(s, S_SIDE, &in, &out),
                  DS_ERR_NOT_REPRESENTABLE);
    if (out.kind != DS_SLOT_INT || out.v.i != -7) {
        fprintf(stderr, "FAIL: a NaN result wrote *out\n");
        return 1;
    }
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

int main(void)
{
    if (test_nfct_1_4_6__tier1_float()) return 1;
    if (test_nfct_1_4_6__int64_storage()) return 1;
    if (test_nfct_1_4_6__not_whole_is_refused()) return 1;
    if (test_nfct_1_4_6__past_the_range_is_refused()) return 1;
    if (test_nfct_1_4_6__tier2()) return 1;
    if (test_nfct_1_4_6__refusals_in_order()) return 1;
    if (test_nfct_1_4_6__in_a_callback()) return 1;
    if (test_nfct_1_4_6__halted_engine()) return 1;
    if (test_nfct_1_4_6__records_nothing()) return 1;
    if (test_nfct_1_4_6__a_nan_result_is_not_representable()) return 1;
    printf("test_nfct_1_4_6__slot_conversions: OK\n");
    return 0;
}
