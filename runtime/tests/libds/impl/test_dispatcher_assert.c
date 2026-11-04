/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * test_dispatcher_assert — dispatch slots 0 and 1, the AOT assert surface:
 * ds_dispatcher_wm_assert and ds_dispatcher_publish, which a terminal's
 * rhs_fn calls for `emit` and `publish`, and slot 2, ds_dispatcher_call.
 * Called directly, as test_dispatcher_cache and test_dispatcher_log do: an
 * `emit`'s fact lands in WM and a `publish`'s does not ([LTIE.4.3]), a
 * `publish`'s values are judged as an `emit`'s ([LTIE.4.8]), and the right
 * callbacks fire for each verb.
 */
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "dispatcher.h"
#include "ds_alloc.h"
#include "engine.h"
#include "oa.h"
#include "rete/engine.h"
#include "rete/fact.h"
#include "rete/intern.h"
#include "rete/schema_reg.h"
#include "rete/token.h"
#include "rete/val.h"
#include "rete/wm_rete.h"

static int g_fails;
#define CHECK(cond, msg)                                                     \
    do { if (!(cond)) {                                                      \
        fprintf(stderr, "FAIL [%s]: %s (%s:%d)\n",                           \
                __func__, (msg), __FILE__, __LINE__);                        \
        g_fails++;                                                           \
    } } while (0)

static ds_engine_t *new_engine_with_schema_lc(const char *name,
                                               ds_schema_lifecycle_t lifecycle,
                                               const ds_rete_schema_t **out_rete)
{
    /* The assert surface works against engine->rete_engine, so the backend is
       not optional here the way it is for log. */
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK || e == NULL) {
        fprintf(stderr, "FAIL: ds_engine_new\n");
        return NULL;
    }
    /* [LFAC.1.7]: a logical slot is KEY or MUTABLE. Registering also creates
       the Rete-side schema. */
    ds_slot_desc_t sd = { .name = "val", .type = DS_SLOT_TYPE_INT,
                          .identity_role = DS_IDENTITY_KEY };
    const ds_schema_t *ds_schema = NULL;
    if (ds_engine_register_schema(e, name, lifecycle,
                                   lifecycle == DS_SCHEMA_LIFECYCLE_TTL
                                       ? 1000000000 : 0,
                                   &sd, 1, &ds_schema).status != DS_OK) {
        fprintf(stderr, "FAIL: register_schema %s\n", name);
        ds_engine_free(e);
        return NULL;
    }
    const ds_rete_schema_t *rs = ds_rete_schema_by_name(e->rete_engine, name);
    if (rs == NULL) {
        fprintf(stderr, "FAIL: Rete schema lookup %s\n", name);
        ds_engine_free(e);
        return NULL;
    }
    if (out_rete) *out_rete = rs;
    return e;
}

/* Count facts of `schema` currently in the Rete WM (same walk as
   test_engine_rete_integration's count_rete_facts). */
static int count_facts(ds_rete_engine_t *re, const ds_rete_schema_t *schema)
{
    int n = 0;
    for (uint32_t i = 0; i < oa_len(&re->wm_map); i++) {
        ds_rete_fact_t *f = *(ds_rete_fact_t **)ds_oa_val_at(&re->wm_map, i);
        if (!f) continue;
        if (f->schema == schema) n++;
    }
    return n;
}

/* ---- the assert actually happens ------------------------------------- */

static void test_wm_assert_lands_a_fact(void)
{
    const ds_rete_schema_t *rs = NULL;
    ds_engine_t *e = new_engine_with_schema_lc("Echo", DS_SCHEMA_LIFECYCLE_LOGICAL, &rs);
    if (!e) { g_fails++; return; }

    CHECK(count_facts(e->rete_engine, rs) == 0, "WM starts empty");

    ds_rete_val_t slots[1];
    slots[0] = ds_rete_val_int(42);
    ds_result_t r = ds_dispatcher_wm_assert(e, "Echo", slots, 1, false, NULL);

    CHECK(r.status == DS_OK, "wm_assert returns DS_OK");
    CHECK(count_facts(e->rete_engine, rs) == 1,
          "wm_assert put a fact in WM");
    ds_engine_free(e);
}

/* ---- refusals --------------------------------------------------------- */

static void test_unknown_schema_is_an_error(void)
{
    /* An emit naming an unregistered schema is a stale-artefact error. */
    ds_engine_t *e = new_engine_with_schema_lc("Echo", DS_SCHEMA_LIFECYCLE_LOGICAL, NULL);
    if (!e) { g_fails++; return; }

    ds_rete_val_t slots[1];
    slots[0] = ds_rete_val_int(1);
    ds_result_t r = ds_dispatcher_wm_assert(e, "NoSuchSchema", slots, 1,
                                             false, NULL);
    CHECK(r.status == DS_ERR_SCHEMA_UNKNOWN,
          "unknown schema → DS_ERR_SCHEMA_UNKNOWN, not DS_OK");
    ds_engine_free(e);
}

static void test_slot_count_disagreement_is_an_error(void)
{
    /* The compiled RHS sizes its array from the schema it was compiled
       against. A disagreement means the artefact and the loaded schema are
       out of step — truncating to the shorter one would assert a fact with
       silently wrong contents. */
    ds_engine_t *e = new_engine_with_schema_lc("Echo", DS_SCHEMA_LIFECYCLE_LOGICAL, NULL);
    if (!e) { g_fails++; return; }

    ds_rete_val_t slots[2];
    slots[0] = ds_rete_val_int(1);
    slots[1] = ds_rete_val_int(2);
    ds_result_t r = ds_dispatcher_wm_assert(e, "Echo", slots, 2, false, NULL);
    CHECK(r.status == DS_ERR_INVAL, "slot-count mismatch → DS_ERR_INVAL");
    ds_engine_free(e);
}

static void test_logical_outside_a_fire_is_an_error(void)
{
    /* A logical assert needs a firing activation to justify against
       ([LLOG.15.1]). Called outside one — as here, with no pump in flight —
       there is nothing to key the TMS entry on, and asserting the fact
       unjustified would make it permanent, the opposite of what `logical`
       asks for. */
    const ds_rete_schema_t *rs = NULL;
    ds_engine_t *e = new_engine_with_schema_lc("Echo", DS_SCHEMA_LIFECYCLE_LOGICAL, &rs);
    if (!e) { g_fails++; return; }

    ds_rete_val_t slots[1];
    slots[0] = ds_rete_val_int(3);
    ds_result_t r = ds_dispatcher_wm_assert(e, "Echo", slots, 1, true, NULL);
    CHECK(r.status == DS_ERR_INVAL,
          "logical assert with no firing activation → DS_ERR_INVAL");
    ds_engine_free(e);
}

/* ---- slot 2 carries the firing activation identity -------------------- */

typedef struct {
    int         n_calls;
    int64_t     timetag;
    int         had_rule;
    char        rule[64];
    char        names[128];    /* the argument names, comma-joined, as received */
    ds_result_t next_return;   /* zero-initialised: DS_OK */
} call_probe_t;

static void arg_names(const ds_arg_t *args, uint32_t n, char *out, size_t cap)
{
    size_t used = 0;
    out[0] = '\0';
    for (uint32_t i = 0; i < n; i++) {
        int k = snprintf(out + used, cap - used, "%s%s", i ? "," : "",
                         args[i].name ? args[i].name : "");
        if (k < 0 || (size_t) k >= cap - used) return;
        used += (size_t) k;
    }
}

static ds_result_t call_probe_cb(ds_engine_t *e,
                                  const ds_call_request_t *req, void *user)
{
    (void)e;
    call_probe_t *p = (call_probe_t *)user;
    p->n_calls++;
    p->timetag  = req->timetag;
    p->had_rule = (req->rule_name != NULL);
    p->rule[0]  = '\0';
    if (req->rule_name)
        strncpy(p->rule, req->rule_name, sizeof(p->rule) - 1);
    arg_names(req->args, req->arg_count, p->names, sizeof(p->names));
    return p->next_return;
}

/* ---- slot 2: ACTION_CALL before the callback, args as given ----------- */

typedef struct {
    int  n_call;
    int  cb_calls_at_event;
    char names[128];
    const call_probe_t *probe;
} call_stream_t;

static ds_result_t call_stream_cb(ds_engine_t *e, const ds_stream_ev_t *ev, void *user)
{
    (void)e;
    call_stream_t *s = (call_stream_t *)user;
    if (ev->kind == DS_EV_ACTION_CALL) {
        s->n_call++;
        s->cb_calls_at_event = s->probe ? s->probe->n_calls : -1;
        arg_names(ev->p.action_call.args, ev->p.action_call.arg_count,
                  s->names, sizeof(s->names));
    }
    return DS_OK_R;
}

static void test_call_event_before_callback_and_body_as_given(void)
{
    /* [IDSP.1.4] / [IDSP.6.5]: the event is emitted before the callback,
       whether the callback fails or is missing. [RLOW.7.3.1]: the compiler
       owns the argument order, so libds hands
       the typed arguments on exactly as the artefact built them -- an
       out-of-order list stays out of order, which is what shows libds is not a
       second owner -- and the callback and the event receive one list. */
    ds_engine_t *e = new_engine_with_schema_lc("Echo",
                                                DS_SCHEMA_LIFECYCLE_LOGICAL,
                                                NULL);
    if (!e) { g_fails++; return; }
    call_probe_t  p = {0};
    call_stream_t s = { .probe = &p };
    CHECK(ds_engine_set_stream_callback(e, call_stream_cb, &s).status == DS_OK,
          "attach stream");
    CHECK(ds_engine_set_call_callback(e, call_probe_cb, &p).status == DS_OK,
          "attach call callback");

    const ds_arg_t given[2] = {
        { .name = "zeta",  .value = { .kind = DS_ARG_INT, .v.i = 2 } },
        { .name = "alpha", .value = { .kind = DS_ARG_INT, .v.i = 1 } },
    };
    ds_result_t r = ds_dispatcher_call(e, "light.turn_on", "c1", given, 2, 0);
    CHECK(r.status == DS_OK, "delivers");
    CHECK(strcmp(p.names, "zeta,alpha") == 0,
          "the callback's arguments are the ones handed in, not reordered");
    CHECK(strcmp(s.names, p.names) == 0, "and the event carries the same list");
    CHECK(s.n_call == 1 && s.cb_calls_at_event == 0,
          "the event came first");

    p.next_return = (ds_result_t){ .status = DS_ERR_IO };
    r = ds_dispatcher_call(e, "light.turn_on", "c2", NULL, 0, 0);
    CHECK(r.status == DS_ERR_IO, "a failing callback is the status");
    CHECK(s.n_call == 2, "...and the event still fired");

    CHECK(ds_engine_set_call_callback(e, NULL, NULL).status == DS_OK, "detach");
    r = ds_dispatcher_call(e, "light.turn_on", "c3", NULL, 0, 0);
    CHECK(r.status == DS_ERR_STORAGE_UNAVAILABLE, "no callback is the status");
    CHECK(s.n_call == 3, "...and the event still fired");
    ds_engine_free(e);
}

static void test_call_carries_the_firing_identity(void)
{
    /* rete/engine.c publishes the firing token and rule for the duration of
       the fire. Standing in for a pump: set the two fields engine.c sets,
       the state a compiled RHS observes when it calls slot 2. */
    ds_engine_t *e = new_engine_with_schema_lc("Echo",
                                                DS_SCHEMA_LIFECYCLE_LOGICAL,
                                                NULL);
    if (!e) { g_fails++; return; }

    call_probe_t p = {0};
    CHECK(ds_engine_set_call_callback(e, call_probe_cb, &p).status == DS_OK,
          "attach call callback");

    ds_rete_token_t tok = {0};
    tok.creation_timetag = 4242;
    e->rete_engine->current_fire_token = &tok;
    e->rete_engine->current_fire_rule  = "heat_alert";

    ds_result_t r = ds_dispatcher_call(e, "light.turn_on", "corr-1", NULL, 0, 0);
    CHECK(r.status == DS_OK, "dispatcher_call returns DS_OK");
    CHECK(p.n_calls == 1, "callback fired");
    CHECK(p.timetag == 4242, "timetag reaches the callback");
    CHECK(p.had_rule && strcmp(p.rule, "heat_alert") == 0,
          "rule_name reaches the callback");

    e->rete_engine->current_fire_token = NULL;
    e->rete_engine->current_fire_rule  = NULL;
    ds_engine_free(e);
}

static void test_call_outside_a_fire_has_no_identity(void)
{
    /* Outside a fire there is no activation, so (0, NULL). */
    ds_engine_t *e = new_engine_with_schema_lc("Echo",
                                                DS_SCHEMA_LIFECYCLE_LOGICAL,
                                                NULL);
    if (!e) { g_fails++; return; }

    call_probe_t p = {0};
    p.timetag = -1;
    CHECK(ds_engine_set_call_callback(e, call_probe_cb, &p).status == DS_OK,
          "attach call callback");
    CHECK(ds_dispatcher_call(e, "light.turn_on", "corr-2", NULL, 0, 0).status
              == DS_OK, "dispatcher_call outside a fire still delivers");
    CHECK(p.timetag == 0 && !p.had_rule,
          "no firing activation → (0, NULL)");
    ds_engine_free(e);
}

/* ---- IDSP.3.6: a multi-type schema round-trips through slot 0 --------- */

static void test_wm_assert_carries_every_slot_type(void)
{
    /* [IDSP.3.6] asks the impl path for "multi-type schema (INT + FLOAT +
       STRING + BOOL)". The single-INT case above proves a fact appears; this
       proves the VALUES survive, which is the half a fact-count check cannot
       see — a slot array marshalled by kind can be wrong per kind.

       JSON is left out deliberately: the entry point takes already-evaluated
       ds_rete_val_t slots, so a JSON slot here would be a hand-built
       ds_json_t rather than anything the dispatch surface decides, and
       spec/test_emit_spec covers the JSON round trip black-box. */
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK || !e) {
        fprintf(stderr, "FAIL: ds_engine_new\n"); g_fails++; return;
    }

    ds_slot_desc_t sd[4] = {
        { .name = "i", .type = DS_SLOT_TYPE_INT,    .identity_role = DS_IDENTITY_KEY },
        { .name = "f", .type = DS_SLOT_TYPE_FLOAT,  .identity_role = DS_IDENTITY_MUTABLE },
        { .name = "s", .type = DS_SLOT_TYPE_STRING, .identity_role = DS_IDENTITY_MUTABLE },
        { .name = "b", .type = DS_SLOT_TYPE_BOOL,   .identity_role = DS_IDENTITY_MUTABLE },
    };
    const ds_schema_t *dss = NULL;
    if (ds_engine_register_schema(e, "Multi", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                   0, sd, 4, &dss).status != DS_OK) {
        fprintf(stderr, "FAIL: register_schema Multi\n");
        ds_engine_free(e); g_fails++; return;
    }
    const ds_rete_schema_t *rs =
        ds_rete_schema_by_name(e->rete_engine, "Multi");
    if (!rs) { fprintf(stderr, "FAIL: rete lookup Multi\n");
               ds_engine_free(e); g_fails++; return; }

    const char *interned = NULL;
    CHECK(ds_rete_intern_cstr(e->rete_engine->intern, "hello",
                              &interned).status == DS_OK, "intern");

    ds_rete_val_t slots[4];
    slots[0] = ds_rete_val_int(7);
    slots[1] = ds_rete_val_float(2.5);
    slots[2] = ds_rete_val_str(interned, 5);
    slots[3] = ds_rete_val_bool(true);
    CHECK(ds_dispatcher_wm_assert(e, "Multi", slots, 4, false, NULL).status
              == DS_OK, "multi-type wm_assert returns DS_OK");

    /* Find the fact and read every slot back. */
    ds_rete_fact_t *found = NULL;
    for (uint32_t i = 0; i < oa_len(&e->rete_engine->wm_map); i++) {
        ds_rete_fact_t *f =
            *(ds_rete_fact_t **)ds_oa_val_at(&e->rete_engine->wm_map, i);
        if (f && f->schema == rs) { found = f; break; }
    }
    CHECK(found != NULL, "the multi-type fact is in WM");
    if (found) {
        CHECK(found->slots[0].kind == DS_RETE_VAL_INT
              && found->slots[0].i == 7, "Int slot survives");
        CHECK(found->slots[1].kind == DS_RETE_VAL_FLOAT
              && found->slots[1].f == 2.5, "Float slot survives");
        CHECK(found->slots[2].kind == DS_RETE_VAL_STR
              && found->slots[2].s.ptr != NULL
              && strcmp(found->slots[2].s.ptr, "hello") == 0,
              "String slot survives");
        CHECK(found->slots[3].kind == DS_RETE_VAL_BOOL
              && found->slots[3].b, "Bool slot survives");
    }
    ds_engine_free(e);
}

/* ---- IDSP.4.6: publish fires ACTION_PUBLISH and NOT ACTION_EMIT ------- */

#define MAX_EV 64
typedef struct { int n; int kind[MAX_EV]; } evtrace_t;

static ds_result_t ev_cb(ds_engine_t *e, const ds_stream_ev_t *ev, void *user)
{
    (void)e;
    evtrace_t *t = (evtrace_t *)user;
    if (t->n < MAX_EV) t->kind[t->n++] = (int)ev->kind;
    return DS_OK_R;
}

static int ev_count(const evtrace_t *t, int kind)
{
    int n = 0;
    for (int i = 0; i < t->n; i++) if (t->kind[i] == kind) n++;
    return n;
}

static void test_publish_fires_publish_not_emit(void)
{
    /* [IDSP.4.6] via the impl path: publish must not leak ACTION_EMIT, or a
       consumer cannot tell the two verbs apart ([IDSP.4.5]). */
    const ds_rete_schema_t *rs = NULL;
    ds_engine_t *e = new_engine_with_schema_lc("Out", DS_SCHEMA_LIFECYCLE_TTL,
                                                &rs);
    if (!e) { g_fails++; return; }

    evtrace_t t = {0};
    CHECK(ds_engine_set_stream_callback(e, ev_cb, &t).status == DS_OK,
          "attach stream");

    ds_rete_val_t slots[1];
    slots[0] = ds_rete_val_int(3);
    CHECK(ds_dispatcher_publish(e, "Out", slots, 1, false, 0).status == DS_OK,
          "publish returns DS_OK");

    CHECK(ev_count(&t, DS_EV_ACTION_PUBLISH) == 1,
          "publish fires exactly one ACTION_PUBLISH");
    CHECK(ev_count(&t, DS_EV_ACTION_EMIT) == 0,
          "publish must not leak ACTION_EMIT ([IDSP.4.5])");

    ds_engine_set_stream_callback(e, NULL, NULL);
    ds_engine_free(e);
}

/* [LTIE.4.3]: a `publish` puts nothing in this tier's working memory, whatever
   the target schema's lifecycle. A LOGICAL-scoped target is the sharp case:
   an assert there needs a firing to justify against ([LLOG.15.1]), and outside
   one it is refused, so a `publish` that still asserted would be refused here
   too. One ACTION_PUBLISH and no FACT_ASSERT, the fact count unmoved. */
static void publish_lands_nothing_on(const char *name,
                                     ds_schema_lifecycle_t lifecycle)
{
    const ds_rete_schema_t *rs = NULL;
    ds_engine_t *e = new_engine_with_schema_lc(name, lifecycle, &rs);
    if (!e) { g_fails++; return; }

    evtrace_t t = {0};
    CHECK(ds_engine_set_stream_callback(e, ev_cb, &t).status == DS_OK,
          "attach stream");

    ds_rete_val_t slots[1];
    slots[0] = ds_rete_val_int(7);
    ds_result_t r = ds_dispatcher_publish(e, name, slots, 1, false, 0);
    CHECK(r.status == DS_OK, "publish returns DS_OK outside a fire");
    CHECK(ev_count(&t, DS_EV_ACTION_PUBLISH) == 1, "one ACTION_PUBLISH");
    CHECK(ev_count(&t, DS_EV_FACT_ASSERT) == 0,
          "no FACT_ASSERT: nothing entered working memory");
    CHECK(count_facts(e->rete_engine, rs) == 0, "no fact in the rete WM");
    ds_engine_set_stream_callback(e, NULL, NULL);
    size_t n = 99;
    CHECK(ds_engine_fact_count(e, &n).status == DS_OK && n == 0,
          "the engine's fact count is 0");
    ds_engine_free(e);
}

static void test_ltie_4_3__publish_lands_nothing(void)
{
    publish_lands_nothing_on("Out", DS_SCHEMA_LIFECYCLE_TTL);
    publish_lands_nothing_on("Tracked", DS_SCHEMA_LIFECYCLE_LOGICAL);
}

/* [LTIE.4.8]: a `publish`'s values are judged as an `emit`'s, and a refused
   one sends nothing. The compiled RHS has no activation to abandon, so the
   refusal is the code a ctx-less `emit` of the same values gets: each pair is
   checked against ds_dispatcher_wm_assert as well as against the code, so the
   two entry points cannot drift apart. */
static void test_ltie_4_8__publish_refuses_what_an_emit_refuses(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK || !e) {
        fprintf(stderr, "FAIL: ds_engine_new\n"); g_fails++; return;
    }
    ds_slot_desc_t sd[2] = {
        { .name = "k", .type = DS_SLOT_TYPE_INT,   .identity_role = DS_IDENTITY_KEY },
        { .name = "f", .type = DS_SLOT_TYPE_FLOAT, .identity_role = DS_IDENTITY_MUTABLE },
    };
    const ds_schema_t *dss = NULL;
    if (ds_engine_register_schema(e, "Pair", DS_SCHEMA_LIFECYCLE_TTL,
                                   1000000000, sd, 2, &dss).status != DS_OK) {
        fprintf(stderr, "FAIL: register_schema Pair\n");
        ds_engine_free(e); g_fails++; return;
    }
    evtrace_t t = {0};
    CHECK(ds_engine_set_stream_callback(e, ev_cb, &t).status == DS_OK,
          "attach stream");

    /* A Bool in the Int slot. */
    ds_rete_val_t pub[2], emit[2];
    pub[0] = emit[0] = ds_rete_val_bool(true);
    pub[1] = emit[1] = ds_rete_val_float(1.0);
    ds_result_t rp = ds_dispatcher_publish(e, "Pair", pub, 2, false, 0);
    ds_result_t re = ds_dispatcher_wm_assert(e, "Pair", emit, 2, false, NULL);
    CHECK(rp.status == DS_ERR_SLOT_TYPE_MISMATCH,
          "a kind its slot does not admit -> DS_ERR_SLOT_TYPE_MISMATCH");
    CHECK(rp.status == re.status, "...the code the emit gets");

    /* A NaN in the Float slot ([LEXP.4.2]). */
    pub[0] = emit[0] = ds_rete_val_int(1);
    pub[1] = emit[1] = ds_rete_val_float(NAN);
    rp = ds_dispatcher_publish(e, "Pair", pub, 2, false, 0);
    re = ds_dispatcher_wm_assert(e, "Pair", emit, 2, false, NULL);
    CHECK(rp.status == DS_ERR_NAN_REJECTED, "a NaN -> DS_ERR_NAN_REJECTED");
    CHECK(rp.status == re.status, "...the code the emit gets");

    CHECK(ev_count(&t, DS_EV_ACTION_PUBLISH) == 0,
          "a refused publish sends nothing");
    ds_engine_set_stream_callback(e, NULL, NULL);
    ds_engine_free(e);
}

/* [NCBK.10.1]: the ACTION_PUBLISH event carries the published fact's
   FactExternal, the bytes ds_fact_external_pack writes for it. The fact is a
   view, valid for the callback only ([NCBK.2.5]), so it is read here: its id
   is 0, its slot holds the published value, and packed again it gives the
   event's bytes. */
typedef struct {
    int      n;
    size_t   len;
    int      repacks_to_the_event_bytes;
    int      id_is_zero;
    int      slot0_ok;
    int64_t  slot0;
} pubtrace_t;

static ds_result_t pub_cb(ds_engine_t *e, const ds_stream_ev_t *ev, void *user)
{
    (void)e;
    pubtrace_t *t = (pubtrace_t *)user;
    if (ev->kind != DS_EV_ACTION_PUBLISH) return DS_OK_R;
    t->n++;
    const ds_fact_t *f   = ev->p.action_publish.fact;
    const uint8_t   *ext = ev->p.action_publish.external;
    t->len = ev->p.action_publish.external_len;
    if (f == NULL) return DS_OK_R;

    uint64_t id = 1;
    t->id_is_zero = ds_fact_get_id(f, &id).status == DS_OK && id == 0;

    ds_slot_value_t v;
    if (ds_fact_get_slot(f, 0, NULL, &v).status == DS_OK
            && v.kind == DS_SLOT_INT) {
        t->slot0_ok = 1;
        t->slot0    = v.v.i;
    }

    uint8_t *again = NULL;
    size_t   again_len = 0;
    t->repacks_to_the_event_bytes =
        ext != NULL
        && ds_fact_external_pack(f, &again, &again_len).status == DS_OK
        && again != NULL && again_len == t->len
        && memcmp(again, ext, t->len) == 0;
    DS_FREE(again);
    return DS_OK_R;
}

static void test_publish_carries_the_fact_external(void)
{
    const ds_rete_schema_t *rs = NULL;
    ds_engine_t *e = new_engine_with_schema_lc("Out", DS_SCHEMA_LIFECYCLE_TTL,
                                                &rs);
    if (!e) { g_fails++; return; }

    pubtrace_t t = {0};
    CHECK(ds_engine_set_stream_callback(e, pub_cb, &t).status == DS_OK,
          "attach stream");

    ds_rete_val_t slots[1];
    slots[0] = ds_rete_val_int(5);
    CHECK(ds_dispatcher_publish(e, "Out", slots, 1, false, 0).status == DS_OK,
          "publish returns DS_OK");

    CHECK(t.n == 1, "one ACTION_PUBLISH");
    CHECK(t.len > 0, "the event carries a FactExternal");
    CHECK(t.repacks_to_the_event_bytes,
          "the event's bytes are the view's own FactExternal");
    CHECK(t.id_is_zero, "the view has no fact id ([NCBK.2.5])");
    CHECK(t.slot0_ok && t.slot0 == 5, "the view holds the published value");

    ds_engine_set_stream_callback(e, NULL, NULL);
    ds_engine_free(e);
}

static void test_wm_assert_fires_emit_not_publish(void)
{
    /* The converse through the SAME entry-point family, so the pair is
       readable in one place rather than split across two binaries. */
    const ds_rete_schema_t *rs = NULL;
    ds_engine_t *e = new_engine_with_schema_lc("Echo",
                                                DS_SCHEMA_LIFECYCLE_LOGICAL,
                                                &rs);
    if (!e) { g_fails++; return; }

    evtrace_t t = {0};
    CHECK(ds_engine_set_stream_callback(e, ev_cb, &t).status == DS_OK,
          "attach stream");

    ds_rete_val_t slots[1];
    slots[0] = ds_rete_val_int(11);
    CHECK(ds_dispatcher_wm_assert(e, "Echo", slots, 1, false, NULL).status
              == DS_OK, "wm_assert returns DS_OK");

    CHECK(ev_count(&t, DS_EV_ACTION_EMIT) == 1,
          "wm_assert fires exactly one ACTION_EMIT");
    CHECK(ev_count(&t, DS_EV_ACTION_PUBLISH) == 0,
          "wm_assert must not fire ACTION_PUBLISH");

    ds_engine_set_stream_callback(e, NULL, NULL);
    ds_engine_free(e);
}

/* ---- null guards ------------------------------------------------------ */

static void test_null_arguments(void)
{
    ds_engine_t *e = new_engine_with_schema_lc("Echo", DS_SCHEMA_LIFECYCLE_LOGICAL, NULL);
    if (!e) { g_fails++; return; }

    ds_rete_val_t slots[1];
    slots[0] = ds_rete_val_int(1);
    CHECK(ds_dispatcher_wm_assert(NULL, "Echo", slots, 1, false, NULL).status
              == DS_ERR_INVAL, "null engine → DS_ERR_INVAL");
    CHECK(ds_dispatcher_wm_assert(e, NULL, slots, 1, false, NULL).status
              == DS_ERR_INVAL, "null schema name → DS_ERR_INVAL");
    CHECK(ds_dispatcher_wm_assert(e, "Echo", NULL, 1, false, NULL).status
              == DS_ERR_INVAL, "null slots with slot_count>0 → DS_ERR_INVAL");
    CHECK(ds_dispatcher_publish(NULL, "Out", slots, 1, false, 0).status
              == DS_ERR_INVAL, "publish null engine → DS_ERR_INVAL");
    ds_engine_free(e);
}

int main(void)
{
    test_wm_assert_lands_a_fact();
    test_ltie_4_3__publish_lands_nothing();
    test_ltie_4_8__publish_refuses_what_an_emit_refuses();
    test_unknown_schema_is_an_error();
    test_slot_count_disagreement_is_an_error();
    test_logical_outside_a_fire_is_an_error();
    test_wm_assert_carries_every_slot_type();
    test_publish_fires_publish_not_emit();
    test_publish_carries_the_fact_external();
    test_wm_assert_fires_emit_not_publish();
    test_call_carries_the_firing_identity();
    test_call_outside_a_fire_has_no_identity();
    test_call_event_before_callback_and_body_as_given();
    test_null_arguments();

    if (g_fails) {
        fprintf(stderr, "test_dispatcher_assert: %d failure(s)\n", g_fails);
        return 1;
    }
    printf("test_dispatcher_assert: OK\n");
    return 0;
}
