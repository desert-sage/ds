/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * test_call_spec — spec conformance for the `call` effect verb.
 *
 * Spec: IDSP.6 (and IDSP.1 cross-cutting), NCBK.6.10, RLOW.7.3.1,
 *   aligned with specs/language/CALL_RESPONSE/ (LCRS): correlation is
 *   author-authored (LCRS.3.1); adapters time out, not the engine (LCRS.7.3).
 *
 * call is an ESSENTIAL verb: a fire emits DS_EV_ACTION_CALL once the
 * arguments evaluate and BEFORE the callback ([IDSP.1.4]), then invokes
 * the typed call callback with a decoded ds_call_request_t; a missing or
 * failing callback surfaces from ds_engine_pump (NULL cb ->
 * DS_ERR_STORAGE_UNAVAILABLE, cb error -> propagated) and does not decide
 * whether the event appears.
 *
 * The arguments are typed ([NCBK.6.10]): `args` / `arg_count`, one ds_arg_t
 * per kwarg, sorted by name. The probes render them as `{"name":value,...}`
 * in the order received, so a test reads the names, the values and their
 * order in one string.
 *
 * Public API only — no internal headers.
 */
#include "spec_common.h"

/* ============== Rendering the typed arguments ============== */

static void render_args(const ds_arg_t *args, uint32_t n, char *out, size_t cap)
{
    size_t used = 0;
    out[0] = '\0';
#define PUT(...) do { int k = snprintf(out + used, cap - used, __VA_ARGS__); \
                      if (k < 0 || (size_t) k >= cap - used) return;        \
                      used += (size_t) k; } while (0)
    PUT("{");
    for (uint32_t i = 0; i < n; i++) {
        const ds_arg_value_t *v = &args[i].value;
        PUT("%s\"%s\":", i ? "," : "", args[i].name ? args[i].name : "");
        switch (v->kind) {
        case DS_ARG_INT:    PUT("%lld", (long long) v->v.i); break;
        case DS_ARG_FLOAT:  PUT("%.17g", v->v.f); break;
        case DS_ARG_STRING: PUT("\"%s\"", v->v.s ? v->v.s : ""); break;
        case DS_ARG_BOOL:   PUT("%s", v->v.b ? "true" : "false"); break;
        case DS_ARG_NULL:   PUT("null"); break;
        default:            PUT("<kind %d>", (int) v->kind); break;
        }
    }
    PUT("}");
#undef PUT
}

/* ============== Probes ============== */

typedef struct {
    int          n_calls;
    char         last_service[64];
    char         last_correlation[64];
    char         last_args[128];
    ds_result_t  next_return;
} call_probe_t;

typedef struct {
    int          n_action_call;
    int          n_action_log;     /* also counted in n_other_action */
    int          n_other_action;
    char         last_service[64];
    char         last_correlation[64];
    char         last_args[128];
} stream_probe_t;

static ds_result_t call_cb(ds_engine_t             *engine,
                           const ds_call_request_t *request,
                           void                    *user)
{
    (void) engine;
    call_probe_t *p = (call_probe_t *) user;
    p->n_calls++;
    p->last_service[0] = '\0';
    p->last_correlation[0] = '\0';
    if (request->service)
        strncpy(p->last_service, request->service,
                sizeof(p->last_service) - 1);
    if (request->correlation)
        strncpy(p->last_correlation, request->correlation,
                sizeof(p->last_correlation) - 1);
    render_args(request->args, request->arg_count, p->last_args,
                sizeof(p->last_args));
    return p->next_return;
}

static ds_result_t stream_cb(ds_engine_t          *engine,
                             const ds_stream_ev_t *event,
                             void                 *user)
{
    (void) engine;
    stream_probe_t *s = (stream_probe_t *) user;
    switch (event->kind) {
    case DS_EV_ACTION_CALL:
        s->n_action_call++;
        s->last_service[0] = '\0';
        s->last_correlation[0] = '\0';
        if (event->p.action_call.service)
            strncpy(s->last_service, event->p.action_call.service,
                    sizeof(s->last_service) - 1);
        if (event->p.action_call.correlation)
            strncpy(s->last_correlation, event->p.action_call.correlation,
                    sizeof(s->last_correlation) - 1);
        render_args(event->p.action_call.args, event->p.action_call.arg_count,
                    s->last_args, sizeof(s->last_args));
        break;
    case DS_EV_FACT_ASSERT:
    case DS_EV_FACT_RETRACT:
    case DS_EV_RULE_LHS_FACTS:
    case DS_EV_RULE_FIRE_BEGIN:
    case DS_EV_RULE_FIRE_END:
    /* The clock's tick and the pump's own event ([NCBK.2.3]) are the engine
       stepping, not actions. Faults still count. */
    case DS_EV_TICK:
    case DS_EV_PUMP:
        break;
    case DS_EV_ACTION_LOG:
        /* Counted on its own for the scenario that needs to see a firing go
           on past its call, and still an action other than a call. */
        s->n_action_log++;
        s->n_other_action++;
        break;
    default:
        s->n_other_action++;
    }
    return DS_OK_R;
}

/* ============== Per-scenario fixture ============== */

#define TRIG_SCHEMA "schema Trig scope logical:\n    tag: String key\n\n"
/* Declared services (DS_VALIDATE_UNKNOWN_SERVICE otherwise), each ending in
   its response line ([LGRA.23.1]). */
#define SVC_PING    "service notify.ping:\n    \"ping\"\n    no response\n\n"
#define SVC_WEATHER \
    "service weather.get_forecasts:\n    \"forecast\"\n" \
    "    kwarg entity_id: String\n    no response\n\n"
#define SVC_AUDIT   "service audit.event:\n    \"audit\"\n    kwarg id: Int\n" \
                    "    no response\n\n"

static int build_engine(ds_engine_t **out_engine,
                        const ds_schema_t **out_trig,
                        call_probe_t *probe,
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
    if (probe != NULL) {
        r = ds_engine_set_call_callback(e, call_cb, probe);
        if (r.status != DS_OK) return spec_fail("set_call_cb", r);
    }
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

/* IDSP.6.4 — a NULL cb is essential: DS_ERR_STORAGE_UNAVAILABLE, not a
   silent drop. ACTION_CALL still fires: an unregistered callback does not
   decide the event ([IDSP.1.4], [IDSP.6.5]). */
static int test_idsp_6_4__null_cb_essential(void)
{
    /* No call_probe → no typed cb registered. */
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, NULL, &sp,
            TRIG_SCHEMA SVC_PING
            "rule c:\n    Trig t where t.tag == \"x\"\n"
            "->\n    call notify.ping nocooldown as \"corr\"\n"))
        return 1;
    if (fire(e, trig, "x")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_STATUS("pump null-cb", r, DS_ERR_STORAGE_UNAVAILABLE);
    if (sp.n_action_call != 1) {
        fprintf(stderr, "FAIL: NULL cb: ACTION_CALL count=%d, want 1\n",
                sp.n_action_call);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* IDSP.6.3 / NCBK.6.10 — primary effect: cb invoked with the decoded
   ds_call_request_t (service = dotted path, correlation = `as` clause,
   args = one typed argument per kwarg). */
static int test_idsp_6_3__cb_invoked_with_request(void)
{
    call_probe_t probe = { .next_return = DS_OK_R };
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &probe, NULL,
            TRIG_SCHEMA SVC_WEATHER
            "rule p:\n    Trig t where t.tag == \"x\"\n"
            "->\n    call weather.get_forecasts entity_id: \"weather.home\""
            " nocooldown as \"fc-evening\"\n"))
        return 1;
    if (fire(e, trig, "x")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (probe.n_calls != 1) {
        fprintf(stderr, "FAIL: cb count=%d\n", probe.n_calls); return 1;
    }
    if (strcmp(probe.last_service, "weather.get_forecasts") != 0 ||
        strcmp(probe.last_correlation, "fc-evening") != 0 ||
        strcmp(probe.last_args, "{\"entity_id\":\"weather.home\"}") != 0) {
        fprintf(stderr,
                "FAIL: cb payload (service=\"%s\" corr=\"%s\" args=%s)\n",
                probe.last_service, probe.last_correlation, probe.last_args);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* IDSP.6.5 — DS_EV_ACTION_CALL payload matches the cb's request: same
   service, correlation, typed arguments. */
static int test_idsp_6_5__action_call_payload(void)
{
    call_probe_t probe = { .next_return = DS_OK_R };
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &probe, &sp,
            TRIG_SCHEMA SVC_AUDIT
            "rule p:\n    Trig t where t.tag == \"x\"\n"
            "->\n    call audit.event id: 7 nocooldown as \"a1\"\n"))
        return 1;
    if (fire(e, trig, "x")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_action_call != 1) {
        fprintf(stderr, "FAIL: ACTION_CALL count=%d\n", sp.n_action_call);
        return 1;
    }
    if (strcmp(sp.last_service, "audit.event") != 0 ||
        strcmp(sp.last_correlation, "a1") != 0 ||
        strcmp(sp.last_args, "{\"id\":7}") != 0) {
        fprintf(stderr,
                "FAIL: stream payload (service=\"%s\" corr=\"%s\" args=%s)\n",
                sp.last_service, sp.last_correlation, sp.last_args);
        return 1;
    }
    /* Same payload reached the typed cb. */
    if (strcmp(probe.last_service, sp.last_service) != 0 ||
        strcmp(probe.last_correlation, sp.last_correlation) != 0 ||
        strcmp(probe.last_args, sp.last_args) != 0) {
        fprintf(stderr, "FAIL: stream/cb payload mismatch\n"); return 1;
    }
    if (assert_no_other_actions(&sp)) return 1;
    ds_engine_free(e);
    return 0;
}

/* IDSP.6.5 — multi-fire count: N rule firings produce N typed-cb
   invocations and N ACTION_CALL events. */
static int test_idsp_6_5__multi_fire_count(void)
{
    call_probe_t probe = { .next_return = DS_OK_R };
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &probe, &sp,
            TRIG_SCHEMA SVC_PING
            "rule ma:\n    Trig t where t.tag == \"a\"\n"
            "->\n    call notify.ping nocooldown as \"a\"\n\n"
            "rule mb:\n    Trig t where t.tag == \"b\"\n"
            "->\n    call notify.ping nocooldown as \"b\"\n\n"
            "rule mc:\n    Trig t where t.tag == \"c\"\n"
            "->\n    call notify.ping nocooldown as \"c\"\n"))
        return 1;
    const char *tags[] = { "a", "b", "c" };
    for (int i = 0; i < 3; i++)
        if (fire(e, trig, tags[i])) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (probe.n_calls != 3 || sp.n_action_call != 3) {
        fprintf(stderr, "FAIL: counts cb=%d call=%d\n",
                probe.n_calls, sp.n_action_call);
        return 1;
    }
    if (assert_no_other_actions(&sp)) return 1;
    ds_engine_free(e);
    return 0;
}

/* IDSP.1.3 cross-cut — typed-cb error propagates verbatim through
   pump's pending slot. */
static int test_idsp_1_3__cb_error_propagates(void)
{
    call_probe_t probe = {0};
    probe.next_return = DS_ERR_R(DS_ERR_ACTION_FAILED, "probe-induced");
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &probe, NULL,
            TRIG_SCHEMA SVC_PING
            "rule e:\n    Trig t where t.tag == \"x\"\n"
            "->\n    call notify.ping nocooldown as \"corr\"\n"))
        return 1;
    if (fire(e, trig, "x")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_STATUS("pump", r, DS_ERR_ACTION_FAILED);
    if (probe.n_calls != 1) {
        fprintf(stderr, "FAIL: cb didn't fire\n"); return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* IDSP.1.4 cross-cut — a callback that returned non-OK does not decide the
   event: ACTION_CALL fires, the failure is the pump's status, and the firing
   goes on to its next action. */
static int test_idsp_1_4__failed_cb_still_emits_action_call(void)
{
    call_probe_t probe = {0};
    probe.next_return = DS_ERR_R(DS_ERR_ACTION_FAILED, "probe-induced");
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &probe, &sp,
            TRIG_SCHEMA SVC_PING
            "rule fne:\n    Trig t where t.tag == \"x\"\n"
            "->\n    call notify.ping nocooldown as \"corr\"\n"
            "    log info \"after the call\"\n"))
        return 1;
    if (fire(e, trig, "x")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_STATUS("pump", r, DS_ERR_ACTION_FAILED);
    if (probe.n_calls != 1) {
        fprintf(stderr, "FAIL: cb didn't fire\n"); return 1;
    }
    if (sp.n_action_call != 1) {
        fprintf(stderr, "FAIL: failed cb: ACTION_CALL count=%d, want 1\n",
                sp.n_action_call);
        return 1;
    }
    if (sp.n_action_log != 1) {
        fprintf(stderr, "FAIL: failed cb: the firing's log ran %d times, "
                "want 1\n", sp.n_action_log);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* RLOW.7.3.1 / NCBK.6.10 — a call's typed arguments arrive sorted by name
   whatever order the kwargs were written in, each with its own value, in the
   callback's request and in the ACTION_CALL event alike. The compiler sorts
   the operands ([RDSC.4a.9.4]) and libds passes them in the artefact's
   order. */
static int test_rlow_7_3_1__call_args_sorted(void)
{
    call_probe_t probe = { .next_return = DS_OK_R };
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &probe, &sp,
            TRIG_SCHEMA
            "service audit.pair:\n    \"pair\"\n"
            "    kwarg zeta: Int\n    kwarg alpha: String\n    no response\n\n"
            "rule s:\n    Trig t where t.tag == \"x\"\n"
            "->\n    call audit.pair zeta: 2 alpha: \"a\" nocooldown as \"s1\"\n"))
        return 1;
    if (fire(e, trig, "x")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    const char *want = "{\"alpha\":\"a\",\"zeta\":2}";
    if (strcmp(probe.last_args, want) != 0 || strcmp(sp.last_args, want) != 0) {
        fprintf(stderr, "FAIL: args cb=%s stream=%s, want %s\n",
                probe.last_args, sp.last_args, want);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* IDSP.6 / NULL-after-unregister — passing cb=NULL to the setter
   re-essentializes the verb: subsequent invocations return
   DS_ERR_STORAGE_UNAVAILABLE. */
/* @spec [IDSP.6.4] */
static int test_idsp_6__set_null_re_essentializes(void)
{
    call_probe_t probe = { .next_return = DS_OK_R };
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &probe, NULL,
            TRIG_SCHEMA SVC_PING
            "rule a:\n    Trig t where t.tag == \"a\"\n"
            "->\n    call notify.ping nocooldown as \"a\"\n\n"
            "rule b:\n    Trig t where t.tag == \"b\"\n"
            "->\n    call notify.ping nocooldown as \"b\"\n"))
        return 1;
    /* First fire: cb registered. */
    if (fire(e, trig, "a")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump 1", r);
    if (probe.n_calls != 1) {
        fprintf(stderr, "FAIL: pre-unregister cb=%d\n", probe.n_calls);
        return 1;
    }
    /* Unregister. */
    r = ds_engine_set_call_callback(e, NULL, NULL);
    EXPECT_OK("set NULL", r);
    /* Second fire: must fail with DS_ERR_STORAGE_UNAVAILABLE. */
    if (fire(e, trig, "b")) return 1;
    r = ds_engine_pump(e);
    EXPECT_STATUS("pump 2", r, DS_ERR_STORAGE_UNAVAILABLE);
    if (probe.n_calls != 1) {
        fprintf(stderr, "FAIL: cb fired after unregister (n=%d)\n",
                probe.n_calls);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* ============== Driver ============== */

int main(void)
{
    int failed = 0;
    failed |= test_idsp_6_4__null_cb_essential();
    failed |= test_idsp_6_3__cb_invoked_with_request();
    failed |= test_idsp_6_5__action_call_payload();
    failed |= test_idsp_6_5__multi_fire_count();
    failed |= test_idsp_1_3__cb_error_propagates();
    failed |= test_idsp_1_4__failed_cb_still_emits_action_call();
    failed |= test_rlow_7_3_1__call_args_sorted();
    failed |= test_idsp_6__set_null_re_essentializes();
    if (!failed) printf("test_call_spec: OK\n");
    return failed;
}
