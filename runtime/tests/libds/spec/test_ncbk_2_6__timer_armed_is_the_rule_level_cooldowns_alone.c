/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NCBK.2.6]
 * For a firing of a `cooldown` rule that the rate gate admits, the engine
 * "must emit TIMER_ARMED immediately after RULE_FIRE_END, with no intervening
 * event"; for a firing the gate suppresses it "must not emit one". A
 * `cooldown:` on a `call` is not a `cooldown` rule, so its gate arms nothing
 * either way ([LCRS.8.2]).
 *
 * THE PATH: _rete_after_fire (engine_rete_adapters.c), which emits on the
 * rule's rm->has_cool unless current_fire_gate_denied, read through the public
 * stream callback ([STYL.5.10.8]).
 *
 * `cooled` has a rule-level cooldown and logs; `gated`'s only cooldown is on
 * its call. Each is driven by its own fact, at 0 s and again at 2 s, inside
 * both 10 s windows, by a mutable-slot change under the same key, so the same
 * activation key:
 *
 *   rule     0 s (admitted)                     2 s (suppressed)
 *   cooled   ACTION_LOG in the bracket, then    an empty bracket, no TIMER_ARMED
 *            TIMER_ARMED straight after the end
 *   gated    ACTION_CALL in the bracket,        an empty bracket, no call,
 *            no TIMER_ARMED                     no TIMER_ARMED
 *
 * Each suppressed step shows its firing's bracket with no action in it, and
 * `cooled`'s first step shows the trace sees a TIMER_ARMED. Each trace holds
 * every event from the assert on, so a TIMER_ARMED anywhere fails. The call
 * callback's count checks the call apart from its stream event.
 *
 * Every firing here matches a live fact, so the walk also holds the clause's
 * other order: RULE_LHS_FACTS immediately before RULE_FIRE_BEGIN.
 */
#include "spec_common.h"

static const char *PROGRAM =
    "service svc.read:\n"
    "    kwarg n: Int\n"
    "    no response\n"
    "\n"
    "schema Cool scope logical:\n"
    "    k: Int key\n"
    "    n: Int mutable\n"
    "\n"
    "schema Trig scope logical:\n"
    "    k: Int key\n"
    "    n: Int mutable\n"
    "\n"
    "rule cooled cooldown 10_s:\n"
    "    Cool c\n"
    "->\n"
    "    log info \"fire {c.n}\"\n"
    "\n"
    "rule gated:\n"
    "    Trig t\n"
    "->\n"
    "    call svc.read n: t.n cooldown: 10_s\n";

#define WINDOW_NS 10000000000ull
#define STEP_NS    2000000000ull
#define MAX_EVENTS 64

typedef struct {
    int                 n;
    int                 overflow;
    ds_stream_ev_kind_t kind[MAX_EVENTS];
    char                rule[MAX_EVENTS][16];
    uint64_t            window_ns[MAX_EVENTS];
} trace_t;

static ds_result_t trace_cb(ds_engine_t *engine, const ds_stream_ev_t *ev,
                            void *user)
{
    (void) engine;
    trace_t *t = user;
    if (t->n >= MAX_EVENTS) { t->overflow = 1; return DS_OK_R; }
    const char *rule = NULL;
    t->kind[t->n] = ev->kind;
    t->window_ns[t->n] = 0;
    if (ev->kind == DS_EV_RULE_FIRE_BEGIN) rule = ev->p.rule_fire_begin.rule_name;
    if (ev->kind == DS_EV_RULE_FIRE_END)   rule = ev->p.rule_fire_end.rule_name;
    if (ev->kind == DS_EV_TIMER_ARMED) {
        rule = ev->p.timer_armed.rule_name;
        t->window_ns[t->n] = ev->p.timer_armed.window_ns;
    }
    t->rule[t->n][0] = '\0';
    if (rule != NULL) {
        strncpy(t->rule[t->n], rule, sizeof t->rule[t->n] - 1);
        t->rule[t->n][sizeof t->rule[t->n] - 1] = '\0';
    }
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

static int count_kind(const trace_t *t, ds_stream_ev_kind_t kind)
{
    int c = 0;
    for (int i = 0; i < t->n; i++)
        if (t->kind[i] == kind) c++;
    return c;
}

/* The index of the first event of `kind`, or -1. */
static int first_of(const trace_t *t, ds_stream_ev_kind_t kind)
{
    for (int i = 0; i < t->n; i++)
        if (t->kind[i] == kind) return i;
    return -1;
}

static int fail(const char *what, const char *why)
{
    fprintf(stderr, "FAIL: %s: %s\n", what, why);
    return 1;
}

/* One firing of `rule`: its RULE_LHS_FACTS straight before its begin,
   `want_actions` of `action` inside the bracket and none outside it, and
   TIMER_ARMED straight after the end when `want_armed`, or none anywhere. */
static int judge(const char *what, const trace_t *t, const char *rule,
                 ds_stream_ev_kind_t action, int want_actions, int want_armed)
{
    if (t->overflow) return fail(what, "more events than MAX_EVENTS");
    if (count_kind(t, DS_EV_RULE_FIRE_BEGIN) != 1
            || count_kind(t, DS_EV_RULE_FIRE_END) != 1)
        return fail(what, "premise: not one firing's bracket");
    const int begin = first_of(t, DS_EV_RULE_FIRE_BEGIN);
    const int end   = first_of(t, DS_EV_RULE_FIRE_END);
    if (end < begin
            || strcmp(t->rule[begin], rule) != 0
            || strcmp(t->rule[end], rule) != 0)
        return fail(what, "premise: the bracket is not this rule's");
    if (begin == 0 || t->kind[begin - 1] != DS_EV_RULE_LHS_FACTS)
        return fail(what, "RULE_LHS_FACTS is not immediately before the begin");

    int inside = 0;
    for (int i = begin + 1; i < end; i++)
        if (t->kind[i] == action) inside++;
    if (inside != want_actions || count_kind(t, action) != want_actions)
        return fail(what, "the action count in the bracket is wrong");

    const int armed = count_kind(t, DS_EV_TIMER_ARMED);
    if (!want_armed)
        return armed == 0 ? 0 : fail(what, "a TIMER_ARMED it must not have");
    if (armed != 1) return fail(what, "not one TIMER_ARMED");
    if (end + 1 >= t->n || t->kind[end + 1] != DS_EV_TIMER_ARMED)
        return fail(what, "TIMER_ARMED is not immediately after the end");
    if (strcmp(t->rule[end + 1], rule) != 0
            || t->window_ns[end + 1] != WINDOW_NS)
        return fail(what, "TIMER_ARMED does not name this rule's window");
    return 0;
}

/* Assert (k=1, n) and pump, tracing every event from the assert on. */
static int drive(ds_engine_t *e, const ds_schema_t *schema, int64_t n, trace_t *t)
{
    ds_slot_value_t v[2];
    memset(v, 0, sizeof v);
    v[0].kind = DS_SLOT_INT; v[0].v.i = 1;
    v[1].kind = DS_SLOT_INT; v[1].v.i = n;
    memset(t, 0, sizeof *t);
    EXPECT_OK("assert", ds_engine_assert(e, schema, v, 2, NULL));
    EXPECT_OK("pump", ds_engine_pump(e));
    return 0;
}

int main(void)
{
    static trace_t t;
    int calls = 0;
    ds_engine_t *e = NULL;
    const ds_schema_t *cool = NULL, *trig = NULL;
    EXPECT_OK("engine", ds_engine_new(NULL, &e));
    EXPECT_OK("load", spec_load_ds(e, PROGRAM));
    EXPECT_OK("mock clock", ds_engine_clock_set_mode(e, DS_CLOCK_MOCK));
    EXPECT_OK("find Cool", ds_engine_schema_find(e, "Cool", &cool));
    EXPECT_OK("find Trig", ds_engine_schema_find(e, "Trig", &trig));
    EXPECT_OK("call callback", ds_engine_set_call_callback(e, count_call, &calls));
    EXPECT_OK("stream", ds_engine_set_stream_callback(e, trace_cb, &t));

    if (drive(e, cool, 0, &t)) return 1;
    if (judge("cooled, admitted", &t, "cooled", DS_EV_ACTION_LOG, 1, 1)) return 1;

    if (drive(e, trig, 0, &t)) return 1;
    if (judge("gated, admitted", &t, "gated", DS_EV_ACTION_CALL, 1, 0)) return 1;
    if (calls != 1) return fail("gated, admitted", "the callback did not see one call");

    EXPECT_OK("advance", ds_engine_clock_advance(e, STEP_NS));

    if (drive(e, cool, 1, &t)) return 1;
    if (judge("cooled, suppressed", &t, "cooled", DS_EV_ACTION_LOG, 0, 0)) return 1;

    if (drive(e, trig, 1, &t)) return 1;
    if (judge("gated, suppressed", &t, "gated", DS_EV_ACTION_CALL, 0, 0)) return 1;
    if (calls != 1) return fail("gated, suppressed", "the gate let a second call through");

    EXPECT_OK("free", ds_engine_free(e));
    printf("test_ncbk_2_6__timer_armed_is_the_rule_level_cooldowns_alone: OK\n");
    return 0;
}
