/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [LERR.1.4.7]
 * An EngineError stops the work in progress where it is raised, and is the
 * tier's last record. From it on the engine runs no further action of the
 * activation that raised it, fires no further activation, and records nothing
 * more, not even that activation's close.
 *
 * The EngineError comes from an artefact that lies (spec_tamper.h): slot
 * `lied` is compiled as Int and declared String in the artefact, so reading
 * it as an Int is ENGINE_FAULT_ARTEFACT_LIED.
 *
 * THE PATH: ds_engine_pump -> ds_rete_run -> the firing -> the faulting
 * evaluation (rete/eval.c's fault_at, which sets the rete engine's halt flag
 * beside the DS engine's latch) -> ds_rete_run's halt check at the next
 * selection, eval_actions' at the next action, the after-fire hook's, and the
 * recorder's `closed` ([STYL.5.10.8]).
 *
 * Two rules on one fact, in source order. Each case has a control on the
 * unedited artefact, which shows the rule order, the actions running and the
 * close being recorded, so the lying case's absences are the halt's.
 *
 *   (a) The fault in the firing's own expression. `bad` emits `p.lied + 1`;
 *       `later` logs and calls. With the lie: the stream's last event is
 *       DS_EV_ENGINE_ERROR, no RULE_FIRE_END for `bad` and no record of
 *       `later` follows it, and `later`'s call is never made.
 *   (b) The fault in an action's propagation. `bad` emits a Mark, whose join
 *       in `watch` reads `p.lied`, then calls. With the lie: the stream's last
 *       event is DS_EV_ENGINE_ERROR, and `bad`'s call, the action after the
 *       one whose propagation raised it, is never made. The call callback is
 *       not the recorder, so this shows the action did not run, not only that
 *       it went unrecorded.
 */
#include "spec_common.h"
#include "spec_tamper.h"

#include <stdbool.h>

/* ---- the programs ------------------------------------------------------ */

#define SVC_AFTER "service notify.after:\n    \"after\"\n    no response\n\n"
#define SCHEMA_P  "schema P scope logical:\n    id: Int key\n    lied: Int mutable\n\n"

/* (a): `bad` reads the lie in its own action, then `later` fires. `later`
   reads nothing of P, so its pattern binds no name: a binding never
   referenced is a compile error ([LGRA.8.6]). */
static const char *AT_FIRE =
    SVC_AFTER
    SCHEMA_P
    "schema Out scope logical:\n"
    "    id: Int key\n"
    "    v: Int mutable\n"
    "\n"
    "rule bad:\n"
    "    P p\n"
    "->\n"
    "    emit Out logical id: p.id v: p.lied + 1\n"
    "\n"
    "rule later:\n"
    "    P\n"
    "->\n"
    "    log info \"later\"\n"
    "    call notify.after nocooldown\n";

/* (b): `bad`'s emit propagates to `watch`, whose join reads the lie; `bad`'s
   call is the action after it. P is asserted before any Mark exists, so the
   join is first evaluated under the emit. */
static const char *AT_PROPAGATION =
    SVC_AFTER
    SCHEMA_P
    "schema Mark scope logical:\n"
    "    id: Int key\n"
    "\n"
    "rule bad:\n"
    "    P p\n"
    "->\n"
    "    emit Mark logical id: p.id\n"
    "    call notify.after nocooldown\n"
    "\n"
    "rule watch:\n"
    "    Mark m\n"
    "    P p where p.id == m.id and p.lied + 1 > m.id\n"
    "->\n"
    "    log info \"watched\"\n";

/* ---- the probes -------------------------------------------------------- */

#define MAX_EVENTS 256

typedef struct {
    int             n;
    ds_stream_ev_kind_t kind[MAX_EVENTS];
    char            rule[MAX_EVENTS][32];   /* RULE_FIRE_BEGIN / _END only */
    bool            overflow;
} trace_t;

static ds_result_t trace_cb(ds_engine_t *engine, const ds_stream_ev_t *ev,
                            void *user)
{
    (void) engine;
    trace_t *t = (trace_t *) user;
    if (t->n >= MAX_EVENTS) { t->overflow = true; return DS_OK_R; }
    t->kind[t->n] = ev->kind;
    t->rule[t->n][0] = '\0';
    const char *rule = NULL;
    if (ev->kind == DS_EV_RULE_FIRE_BEGIN) rule = ev->p.rule_fire_begin.rule_name;
    if (ev->kind == DS_EV_RULE_FIRE_END)   rule = ev->p.rule_fire_end.rule_name;
    if (rule != NULL)
        strncpy(t->rule[t->n], rule, sizeof t->rule[t->n] - 1);
    t->n++;
    return DS_OK_R;
}

static ds_result_t count_call(ds_engine_t *engine, const ds_call_request_t *rq,
                              void *user)
{
    (void) engine; (void) rq;
    (*(int *) user)++;
    return DS_OK_R;
}

/* The index of the first `kind` event naming `rule` (any rule when NULL), at
   or after `from`, or -1. */
static int find(const trace_t *t, int from, ds_stream_ev_kind_t kind,
                const char *rule)
{
    for (int i = from; i < t->n; i++)
        if (t->kind[i] == kind && (rule == NULL || strcmp(t->rule[i], rule) == 0))
            return i;
    return -1;
}

/* ---- the run ----------------------------------------------------------- */

typedef struct {
    trace_t trace;
    int     calls;
    bool    halted;
} run_t;

/* Compile `src`, lie about it when `lying`, load it, assert P(1, lied), pump
   once, and say what happened. The pump's status is not this clause's
   ([NCBK.2.9] decides it), so it is not judged here. */
static int run(const char *src, bool lying, run_t *out)
{
    memset(out, 0, sizeof *out);
    uint8_t *dsc = NULL;
    size_t   len = 0;
    ds_result_t r = spec_compile_ds(src, &dsc, &len);
    if (r.status != DS_OK) return spec_fail("compile", r);
    if (lying && lie(dsc, len)) { free(dsc); return 1; }
    ds_engine_t *e = NULL;
    r = ds_engine_new(NULL, &e);
    if (r.status != DS_OK) { free(dsc); return spec_fail("engine_new", r); }
    r = ds_engine_load_dsc(e, dsc, len);
    free(dsc);
    int rc = 0;
    const ds_schema_t *p = NULL;
    if (r.status != DS_OK) { rc = spec_fail("load_dsc", r); goto done; }
    r = ds_engine_schema_find(e, "P", &p);
    if (r.status != DS_OK || p == NULL) { rc = spec_fail("find P", r); goto done; }
    r = ds_engine_set_call_callback(e, count_call, &out->calls);
    if (r.status != DS_OK) { rc = spec_fail("set_call_callback", r); goto done; }
    r = ds_engine_set_stream_callback(e, trace_cb, &out->trace);
    if (r.status != DS_OK) { rc = spec_fail("set_stream_callback", r); goto done; }

    ds_slot_value_t v[2];
    memset(v, 0, sizeof v);
    v[0].kind = DS_SLOT_INT;
    v[0].v.i  = 1;
    if (lying) { v[1].kind = DS_SLOT_STRING; v[1].v.s = "x"; }
    else       { v[1].kind = DS_SLOT_INT;    v[1].v.i = 1;   }
    r = ds_engine_assert(e, p, v, 2, NULL);
    if (r.status != DS_OK) {
        rc = spec_fail("premise: the assert is admitted; the lie is read when "
                       "a rule fires", r);
        goto done;
    }
    (void) ds_engine_pump(e);
    r = ds_engine_halted(e, &out->halted, NULL);
    if (r.status != DS_OK) { rc = spec_fail("ds_engine_halted", r); goto done; }
    if (out->trace.overflow) {
        fprintf(stderr, "FAIL: more than %d events; raise MAX_EVENTS\n", MAX_EVENTS);
        rc = 1;
    }
done:
    ds_engine_free(e);
    return rc;
}

static int fail(const char *what)
{
    fprintf(stderr, "FAIL: %s\n", what);
    return 1;
}

/* ---- the cases --------------------------------------------------------- */

static int test_a_control(void)
{
    run_t c;
    if (run(AT_FIRE, false, &c)) return 1;
    const trace_t *t = &c.trace;
    int bad_begin   = find(t, 0, DS_EV_RULE_FIRE_BEGIN, "bad");
    int bad_end     = find(t, 0, DS_EV_RULE_FIRE_END, "bad");
    int later_begin = find(t, 0, DS_EV_RULE_FIRE_BEGIN, "later");
    if (c.halted) return fail("(a) control: the unedited program halted");
    if (bad_begin < 0 || bad_end < 0 || later_begin < 0)
        return fail("(a) control: `bad` and `later` both fire, `bad` bracketed");
    if (!(bad_begin < later_begin))
        return fail("(a) control: `bad` fires before `later`, in source order; "
                    "the lying case below depends on it");
    if (c.calls != 1)
        return fail("(a) control: `later`'s call is made once");
    if (find(t, 0, DS_EV_ENGINE_ERROR, NULL) >= 0)
        return fail("(a) control: no EngineError");
    return 0;
}

static int test_a_fault_in_the_firing_stops_the_pump(void)
{
    run_t c;
    if (run(AT_FIRE, true, &c)) return 1;
    const trace_t *t = &c.trace;
    int fault = find(t, 0, DS_EV_ENGINE_ERROR, NULL);
    if (!c.halted || fault < 0)
        return fail("(a) premise: the lie raises an EngineError and halts");
    if (find(t, 0, DS_EV_RULE_FIRE_BEGIN, "bad") < 0
            || find(t, 0, DS_EV_RULE_FIRE_BEGIN, "bad") > fault)
        return fail("(a) premise: the EngineError is raised in `bad`'s firing");
    if (fault != t->n - 1) {
        fprintf(stderr, "FAIL: (a) the EngineError is the last record: it is "
                        "event %d of %d, followed by kind %d\n",
                fault, t->n, (int) t->kind[fault + 1]);
        return 1;
    }
    if (find(t, 0, DS_EV_RULE_FIRE_END, "bad") >= 0)
        return fail("(a) `bad`'s close is not recorded");
    if (find(t, 0, DS_EV_RULE_FIRE_BEGIN, "later") >= 0)
        return fail("(a) `later` never fires");
    if (c.calls != 0)
        return fail("(a) `later`'s call is never made");
    return 0;
}

static int test_b_control(void)
{
    run_t c;
    if (run(AT_PROPAGATION, false, &c)) return 1;
    if (c.halted) return fail("(b) control: the unedited program halted");
    if (c.calls != 1) return fail("(b) control: `bad`'s call is made once");
    if (find(&c.trace, 0, DS_EV_RULE_FIRE_BEGIN, "watch") < 0)
        return fail("(b) control: `watch` fires, so its join is reached");
    return 0;
}

static int test_b_fault_in_an_actions_propagation_stops_the_firing(void)
{
    run_t c;
    if (run(AT_PROPAGATION, true, &c)) return 1;
    const trace_t *t = &c.trace;
    int fault = find(t, 0, DS_EV_ENGINE_ERROR, NULL);
    if (!c.halted || fault < 0)
        return fail("(b) premise: the lie raises an EngineError and halts");
    if (fault != t->n - 1) {
        fprintf(stderr, "FAIL: (b) the EngineError is the last record: it is "
                        "event %d of %d\n", fault, t->n);
        return 1;
    }
    if (c.calls != 0)
        return fail("(b) `bad`'s call, the action after the emit whose "
                    "propagation raised the EngineError, is never made");
    if (find(t, 0, DS_EV_RULE_FIRE_BEGIN, "watch") >= 0)
        return fail("(b) `watch` never fires");
    return 0;
}

int main(void)
{
    int failed = 0;
    failed |= test_a_control();
    failed |= test_a_fault_in_the_firing_stops_the_pump();
    failed |= test_b_control();
    failed |= test_b_fault_in_an_actions_propagation_stops_the_firing();
    if (failed) {
        fprintf(stderr, "test_lerr_1_4_7__engine_error_stops_the_pump: FAILED\n");
        return 1;
    }
    printf("test_lerr_1_4_7__engine_error_stops_the_pump: OK\n");
    return 0;
}
