/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The `log` action (IDSP.2, IDSP.1.3), black-box through libds.h: the log
 * callback's payload, a NULL callback's silent drop, the stream's ACTION_LOG
 * payload and its order after RULE_FIRE_BEGIN, and a callback error.
 *
 * A log event's category is the rule's name, so each test names its rule
 * for the category it checks.
 */
#include "spec_common.h"

/* ============== Probes ============== */

typedef struct {
    int            n_calls;
    ds_log_level_t last_level;
    char           last_category[64];
    char           last_message[128];
    ds_result_t    next_return;
} log_probe_t;

typedef struct {
    int n_action_log;
    int n_other_action;
    int n_rule_fire_begin;
    ds_log_level_t last_log_level;
    char           last_log_category[64];
    char           last_log_message[128];
    uint64_t       last_log_seq;
    uint64_t       last_rfb_seq;
} stream_probe_t;

static ds_result_t log_cb(ds_engine_t          *engine,
                          const ds_log_event_t *event,
                          void                 *user)
{
    (void) engine;
    log_probe_t *p = (log_probe_t *) user;
    p->n_calls++;
    p->last_level = event->level;
    p->last_category[0] = '\0';
    p->last_message[0]  = '\0';
    if (event->category) strncpy(p->last_category, event->category,
                                  sizeof(p->last_category) - 1);
    if (event->message)  strncpy(p->last_message,  event->message,
                                  sizeof(p->last_message) - 1);
    return p->next_return;
}

static ds_result_t stream_cb(ds_engine_t          *engine,
                             const ds_stream_ev_t *event,
                             void                 *user)
{
    (void) engine;
    stream_probe_t *s = (stream_probe_t *) user;
    switch (event->kind) {
    case DS_EV_ACTION_LOG:
        s->n_action_log++;
        s->last_log_seq = event->seq;
        s->last_log_level = event->p.action_log.level;
        s->last_log_category[0] = '\0';
        s->last_log_message[0]  = '\0';
        if (event->p.action_log.category)
            strncpy(s->last_log_category, event->p.action_log.category,
                    sizeof(s->last_log_category) - 1);
        if (event->p.action_log.message)
            strncpy(s->last_log_message, event->p.action_log.message,
                    sizeof(s->last_log_message) - 1);
        break;
    case DS_EV_RULE_FIRE_BEGIN:
        s->n_rule_fire_begin++;
        s->last_rfb_seq = event->seq;
        break;
    case DS_EV_FACT_ASSERT:
    case DS_EV_FACT_RETRACT:
    case DS_EV_RULE_FIRE_END:
    case DS_EV_RULE_LHS_FACTS:
    /* The clock's tick and the pump's own event are the engine stepping
       ([NCBK.2.3]), not actions. Faults still count. */
    case DS_EV_TICK:
    case DS_EV_PUMP:
        break;
    default:
        s->n_other_action++;
    }
    return DS_OK_R;
}

/* ============== Per-scenario fixture ============== */

/* A fresh engine with one `log` rule named `rule_name`. The callbacks are
 * set after the load: the loader logs under category "dsc-load", and a probe
 * set earlier would count those logs. */
static int setup(ds_engine_t **out_e, const ds_schema_t **out_trig,
                 log_probe_t *probe, stream_probe_t *stream_probe,
                 const char *rule_name, const char *level, const char *message)
{
    ds_engine_t *e = NULL;
    ds_result_t r = ds_engine_new(NULL, &e);
    if (r.status != DS_OK) return spec_fail("engine_new", r);

    char src[512];
    snprintf(src, sizeof src,
             "schema Trig scope logical:\n"
             "    tag: String key\n"
             "\n"
             "rule %s:\n"
             "    Trig t where t.tag == \"x\"\n"
             "->\n"
             "    log %s \"%s\"\n",
             rule_name, level, message);
    r = spec_load_ds(e, src);
    if (r.status != DS_OK) return spec_fail("spec_load_ds", r);
    r = ds_engine_schema_find(e, "Trig", out_trig);
    if (r.status != DS_OK || *out_trig == NULL)
        return spec_fail("schema_find Trig", r);

    if (probe != NULL) {
        r = ds_engine_set_log_callback(e, log_cb, probe);
        if (r.status != DS_OK) return spec_fail("set_log_cb", r);
    }
    if (stream_probe != NULL) {
        r = ds_engine_set_stream_callback(e, stream_cb, stream_probe);
        if (r.status != DS_OK) return spec_fail("set_stream_cb", r);
    }
    *out_e = e;
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

/* IDSP.2.2 — each level keyword reaches the callback as its ds_log_level_t. */
static int test_idsp_2_2__every_level_decodes(void)
{
    struct { const char *kw; ds_log_level_t lvl; } cases[] = {
        { "debug",    DS_LOG_DEBUG },
        { "info",     DS_LOG_INFO },
        { "warning",  DS_LOG_WARNING },
        { "error",    DS_LOG_ERROR },
        { "critical", DS_LOG_CRITICAL },
    };
    for (size_t i = 0; i < 5; i++) {
        log_probe_t probe = { .next_return = DS_OK_R };
        ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
        if (setup(&e, &trig, &probe, NULL, "lvl", cases[i].kw, "m")) return 1;
        if (fire(e, trig, "x")) return 1;
        ds_result_t r = ds_engine_pump(e);
        EXPECT_OK("pump level", r);
        if (probe.n_calls != 1 || probe.last_level != cases[i].lvl) {
            fprintf(stderr, "FAIL: level %s decoded n=%d level=%d (want %d)\n",
                    cases[i].kw, probe.n_calls, (int) probe.last_level,
                    (int) cases[i].lvl);
            return 1;
        }
        ds_engine_free(e);
    }
    return 0;
}

/* IDSP.2.3 — typed cb sees ds_log_event_t with the decoded level, the
   rule-name category, and the message. */
static int test_idsp_2_3__cb_invoked_with_event(void)
{
    log_probe_t probe = { .next_return = DS_OK_R };
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (setup(&e, &trig, &probe, NULL, "sec", "warning", "login attempt")) return 1;
    if (fire(e, trig, "x")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (probe.n_calls != 1 ||
        probe.last_level != DS_LOG_WARNING ||
        strcmp(probe.last_category, "sec") != 0 ||         /* category = rule name */
        strcmp(probe.last_message,  "login attempt") != 0) {
        fprintf(stderr,
                "FAIL: cb payload (n=%d level=%d cat=\"%s\" msg=\"%s\")\n",
                probe.n_calls, (int) probe.last_level,
                probe.last_category, probe.last_message);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* IDSP.2.3 — NULL typed cb is a silent drop (no error, pump succeeds). */
static int test_idsp_2_3__null_cb_silent_drop(void)
{
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (setup(&e, &trig, NULL, NULL, "nc", "info", "m")) return 1;
    if (fire(e, trig, "x")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    ds_engine_free(e);
    return 0;
}

/* IDSP.2.4 — DS_EV_ACTION_LOG stream payload matches the decoded verb args. */
static int test_idsp_2_4__action_log_payload(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (setup(&e, &trig, NULL, &sp, "audit", "error", "oops")) return 1;
    if (fire(e, trig, "x")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_action_log != 1 ||
        sp.last_log_level != DS_LOG_ERROR ||
        strcmp(sp.last_log_category, "audit") != 0 ||
        strcmp(sp.last_log_message,  "oops") != 0) {
        fprintf(stderr, "FAIL: ACTION_LOG payload cat=\"%s\" msg=\"%s\"\n",
                sp.last_log_category, sp.last_log_message);
        return 1;
    }
    if (assert_no_other_actions(&sp)) return 1;
    ds_engine_free(e);
    return 0;
}

/* IDSP.2.4 — ACTION_LOG fires on the stream even with NULL typed cb. */
static int test_idsp_2_4__stream_fires_with_null_cb(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (setup(&e, &trig, NULL, &sp, "sn", "info", "m")) return 1;
    if (fire(e, trig, "x")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_action_log != 1) {
        fprintf(stderr, "FAIL: ACTION_LOG count=%d (NULL cb)\n",
                sp.n_action_log);
        return 1;
    }
    if (assert_no_other_actions(&sp)) return 1;
    ds_engine_free(e);
    return 0;
}

/* IDSP.2.4 — ACTION_LOG's seq follows its RULE_FIRE_BEGIN's. */
static int test_idsp_2_4__action_log_after_rule_fire_begin(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (setup(&e, &trig, NULL, &sp, "ord", "info", "m")) return 1;
    if (fire(e, trig, "x")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_rule_fire_begin != 1 || sp.n_action_log != 1) {
        fprintf(stderr, "FAIL: counts rfb=%d log=%d\n",
                sp.n_rule_fire_begin, sp.n_action_log);
        return 1;
    }
    if (!(sp.last_rfb_seq < sp.last_log_seq)) {
        fprintf(stderr, "FAIL: ordering rfb_seq=%llu log_seq=%llu\n",
                (unsigned long long) sp.last_rfb_seq,
                (unsigned long long) sp.last_log_seq);
        return 1;
    }
    if (assert_no_other_actions(&sp)) return 1;
    ds_engine_free(e);
    return 0;
}

/* `log` is observational: a log callback's error is not stashed, and the pump
   returns DS_OK. */
/* @spec [IDSP.1.3] [IDSP.2.3] */
static int test_idsp_2__log_cb_error_nonessential(void)
{
    log_probe_t probe = {0};
    probe.next_return = DS_ERR_R(DS_ERR_ACTION_FAILED, "probe-induced");
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (setup(&e, &trig, &probe, NULL, "err", "info", "m")) return 1;
    if (fire(e, trig, "x")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump (non-essential log cb error swallowed)", r);
    if (probe.n_calls != 1) {
        fprintf(stderr, "FAIL: cb didn't fire (n=%d)\n", probe.n_calls); return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* ============== Driver ============== */

int main(void)
{
    int failed = 0;
    failed |= test_idsp_2_2__every_level_decodes();
    failed |= test_idsp_2_3__cb_invoked_with_event();
    failed |= test_idsp_2_3__null_cb_silent_drop();
    failed |= test_idsp_2_4__action_log_payload();
    failed |= test_idsp_2_4__stream_fires_with_null_cb();
    failed |= test_idsp_2_4__action_log_after_rule_fire_begin();
    failed |= test_idsp_2__log_cb_error_nonessential();
    if (!failed) printf("test_log_spec: OK\n");
    return failed;
}
