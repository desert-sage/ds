/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NDET.8.2] [IDSP.6.4]
 * A replay invokes no effect callback. Two rules over a hand-loaded network:
 *   r_effects (A a)  call svc.notify as "corr-1"; cache "k": "1";
 *                    cache_delete "k"
 *   r_ttl     (B b)  cache "t": "2" for 1s; cache "kept": "3"
 * recorded on a mock clock with counting call, cache-set and cache-delete
 * callbacks: A(1) pumped, B(1) pumped, then the clock moved past "t"'s
 * deadline and pumped. The recording engine's callbacks see one call, three
 * writes, a delete and an expiry.
 *
 * PATH: ds_rfcs_replay -> ds_rfcs_replay_begin (which enters the
 * replay's span) -> the recorded PumpBoundary pumps -> bridge_call ->
 * ds_dispatcher_call_typed; bridge_cache_set -> ds_dispatcher_notify_cache_set;
 * bridge_cache_delete and the pump-entry TTL sweep ->
 * ds_dispatcher_notify_cache_removal; then ds_rfcs_replay_finish, which leaves
 * it ([STYL.5.10.8]). The AOT slots reach the same three functions.
 *
 *   1. No callbacks registered: the replay is DS_OK with no divergence
 *      ([IDSP.6.4]'s exception). The re-derived CallIssued is still compared,
 *      and the engine's own cache still takes each write.
 *   2. Counting callbacks registered: DS_OK, and every count is zero.
 *   3. The span ends: on case 2's engine, a live firing after the replay
 *      reaches all three callbacks again.
 *   4. The span ends on an error path too: a recording cut mid-atom replays to
 *      DS_ERR_PARSE, invokes no callback before the cut, and a live firing
 *      afterwards reaches them.
 *
 * It is in impl/ because the replayer and recorder, rfcs/rfcs.h, are internal.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "builtin_fn.h"
#include "cache.h"
#include "engine.h"
#include "rete/action.h"
#include "rete/beta.h"
#include "rete/engine.h"
#include "rete/expr.h"
#include "rete/loader.h"
#include "rete/schema_reg.h"
#include "rete/terminal.h"
#include "rfcs/rfcs.h"

static int failures = 0;

#define CHECK(cond, msg)                                                      \
    do {                                                                      \
        if (!(cond)) {                                                        \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__); \
            failures++;                                                       \
        }                                                                     \
    } while (0)

#define CHECK_OK(r, msg)                                                      \
    do {                                                                      \
        ds_result_t rr_ = (r);                                                \
        if (rr_.status != DS_OK) {                                            \
            fprintf(stderr, "FAIL: %s: status=%d detail=%s (%s:%d)\n", (msg), \
                    rr_.status, rr_.detail ? rr_.detail : "(null)",           \
                    __FILE__, __LINE__);                                      \
            failures++;                                                       \
        }                                                                     \
    } while (0)

#define SEC UINT64_C(1000000000)

typedef struct {
    int calls;
    int sets;
    int removals;
    int removed_by_delete;
    int removed_by_ttl;
} fx_probe;

static ds_result_t probe_call(ds_engine_t *e, const ds_call_request_t *req,
                              void *user)
{
    (void) e; (void) req;
    ((fx_probe *) user)->calls++;
    return DS_OK_R;
}

static ds_result_t probe_set(ds_engine_t *e, const ds_cache_write_t *write,
                             void *user)
{
    (void) e; (void) write;
    ((fx_probe *) user)->sets++;
    return DS_OK_R;
}

static ds_result_t probe_delete(ds_engine_t *e, const ds_cache_removal_t *rm,
                                void *user)
{
    (void) e;
    fx_probe *p = (fx_probe *) user;
    p->removals++;
    if (rm->reason == DS_CACHE_REMOVED_DELETE) p->removed_by_delete++;
    if (rm->reason == DS_CACHE_REMOVED_TTL)    p->removed_by_ttl++;
    return DS_OK_R;
}

static int register_probe(ds_engine_t *e, fx_probe *p)
{
    return ds_engine_set_call_callback(e, probe_call, p).status != DS_OK
        || ds_engine_cache_callbacks(e, DS_CACHE_CB_ABI_VERSION, probe_set,
                                     probe_delete, p).status != DS_OK;
}

static ds_rete_expr_t *ex_str(const char *s)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_STR);
    e->lit_str = s;
    return e;
}

static ds_rete_expr_t *ex_int(int64_t v)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_INT);
    e->lit_int = v;
    return e;
}

/* (ds-call <service> <correlation>): no kwargs; the test is about who receives
   the call, not what it carries (RDSC.4a.9.4). */
static ds_rete_expr_t *ex_call(const char *service, const char *corr)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_CALL);
    e->call.op = DS_FN_CALL;
    e->call.args = calloc(2, sizeof(*e->call.args));
    e->call.args[0] = ex_str(service);
    e->call.args[1] = ex_str(corr);
    e->call.arg_count = 2;
    return e;
}

/* (ds-cache-set key json ttl_ns): the lowering of `cache key: json [for ttl]`,
   a ttl of 0 being none. */
static ds_rete_expr_t *ex_cache_set(const char *key, const char *json,
                                    int64_t ttl_ns)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_CALL);
    e->call.op = DS_FN_CACHE_SET;
    e->call.args = calloc(3, sizeof(*e->call.args));
    e->call.args[0] = ex_str(key);
    e->call.args[1] = ex_str(json);
    e->call.args[2] = ex_int(ttl_ns);
    e->call.arg_count = 3;
    return e;
}

static ds_rete_expr_t *ex_cache_delete(const char *key)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_CALL);
    e->call.op = DS_FN_CACHE_DELETE;
    e->call.args = calloc(1, sizeof(*e->call.args));
    e->call.args[0] = ex_str(key);
    e->call.arg_count = 1;
    return e;
}

/* The loader borrows the action arrays, so each engine's rig lives as long as
   the engine does. */
typedef struct {
    const ds_schema_t *a, *b;
    ds_rete_action_t   effects[3], ttl[2];
} rig;

static int rig_open(ds_engine_t *e, rig *g)
{
    static const ds_slot_desc_t VAL = {
        .name = "val", .type = DS_SLOT_TYPE_INT, .identity_role = DS_IDENTITY_KEY };
    memset(g, 0, sizeof(*g));
    if (ds_engine_register_schema(e, "A", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                  &VAL, 1, &g->a).status != DS_OK
        || ds_engine_register_schema(e, "B", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                     &VAL, 1, &g->b).status != DS_OK)
        return 1;

    g->effects[0] = (ds_rete_action_t){ .kind = DS_RETE_ACTION_CALL,
                                        .expr = ex_call("svc.notify", "corr-1") };
    g->effects[1] = (ds_rete_action_t){ .kind = DS_RETE_ACTION_CALL,
                                        .expr = ex_cache_set("k", "1", 0) };
    g->effects[2] = (ds_rete_action_t){ .kind = DS_RETE_ACTION_CALL,
                                        .expr = ex_cache_delete("k") };
    g->ttl[0] = (ds_rete_action_t){ .kind = DS_RETE_ACTION_CALL,
                                    .expr = ex_cache_set("t", "2",
                                                         (int64_t) SEC) };
    g->ttl[1] = (ds_rete_action_t){ .kind = DS_RETE_ACTION_CALL,
                                    .expr = ex_cache_set("kept", "3", 0) };

    ds_alfa_atom_t alfas[2] = {
        { .node_id = 1, .schema_name = "A" },
        { .node_id = 2, .schema_name = "B" },
    };
    ds_beta_atom_t betas[2] = {
        { .node_id = 3, .right_alpha_id = 1, .left_parent_id = 0 },
        { .node_id = 4, .right_alpha_id = 2, .left_parent_id = 0 },
    };
    ds_term_atom_t terms[2] = {
        { .node_id = 5, .parent_beta_id = 3, .rule_name = "r_effects",
          .actions = g->effects, .action_count = 3 },
        { .node_id = 6, .parent_beta_id = 4, .rule_name = "r_ttl",
          .actions = g->ttl, .action_count = 2 },
    };
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 2,
                              .betas = betas, .beta_count = 2,
                              .terms = terms, .term_count = 2 };
    return ds_rete_load_network(e->rete_engine, &net).status != DS_OK;
}

static ds_engine_t *engine_open(rig *g)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK || e == NULL)
        return NULL;
    if (rig_open(e, g) != 0) {
        ds_engine_free(e);
        return NULL;
    }
    return e;
}

static ds_result_t assert_val(ds_engine_t *e, const ds_schema_t *sc, int64_t v)
{
    ds_slot_value_t sv;
    memset(&sv, 0, sizeof(sv));
    sv.kind = DS_SLOT_INT;
    sv.v.i = v;
    return ds_engine_assert(e, sc, &sv, 1, NULL);
}

static bool cache_holds(ds_engine_t *e, const char *key)
{
    const char *val = NULL;
    return ds_cache_get(&e->cache, key, 3 * SEC, &val, NULL) && val != NULL;
}

typedef struct { uint8_t buf[16384]; size_t len; } recording;

static ds_result_t sink(const uint8_t *bytes, size_t len, void *user)
{
    recording *r = user;
    if (r->len + len > sizeof(r->buf))
        return (ds_result_t){ DS_ERR_INVAL, "sink overflow" };
    memcpy(r->buf + r->len, bytes, len);
    r->len += len;
    return (ds_result_t){ DS_OK, NULL };
}

static void record_run(recording *out)
{
    static rig g;
    ds_engine_t *e = engine_open(&g);
    CHECK(e != NULL, "the recording engine opens");
    if (e == NULL)
        return;

    fx_probe p = {0};
    CHECK(register_probe(e, &p) == 0, "the recording engine registers its callbacks");
    /* RuleFireAnnotation carries clock_ns, so the run is on a mock clock; each
       clock_set is a ClockAdvance the replay reproduces. */
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "mock clock");

    static uint8_t recbuf[8192];
    ds_rfcs_recorder_t rec;
    out->len = 0;
    CHECK_OK(ds_rfcs_record_to(e, &rec, sink, out, recbuf, sizeof(recbuf)),
             "record_to");
    CHECK_OK(ds_engine_clock_set(e, 1 * SEC), "clock at 1s");
    CHECK_OK(assert_val(e, g.a, 1), "assert A(1)");
    CHECK_OK(ds_engine_pump(e), "r_effects calls, writes \"k\", deletes it");
    CHECK_OK(assert_val(e, g.b, 1), "assert B(1)");
    CHECK_OK(ds_engine_pump(e), "r_ttl writes \"t\" for 1s and \"kept\"");
    CHECK_OK(ds_engine_clock_set(e, 3 * SEC), "clock at 3s, past \"t\"'s deadline");
    CHECK_OK(ds_engine_pump(e), "the pump-entry sweep expires \"t\"");
    CHECK_OK(rec.last, "the recorder had no error");

    /* The premise: what a live engine's callbacks see of this run. */
    CHECK(p.calls == 1, "premise: the recording made one call");
    CHECK(p.sets == 3, "premise: the recording wrote \"k\", \"t\" and \"kept\"");
    CHECK(p.removals == 2 && p.removed_by_delete == 1 && p.removed_by_ttl == 1,
          "premise: the recording removed \"k\" by delete and \"t\" by expiry");

    ds_engine_set_stream_callback(e, NULL, NULL);
    ds_engine_free(e);
}

/* A live firing of r_effects on `e` after a replay: what the callbacks hear
   once the replay's span is over. */
static void live_effects_reach(ds_engine_t *e, const rig *g, fx_probe *p,
                               const char *what)
{
    fx_probe before = *p;
    CHECK_OK(assert_val(e, g->a, 2), what);
    CHECK_OK(ds_engine_pump(e), what);
    CHECK(p->calls == before.calls + 1, what);
    CHECK(p->sets == before.sets + 1, what);
    CHECK(p->removed_by_delete == before.removed_by_delete + 1, what);
}

static void test_ndet_8_2__replay_invokes_no_effect_callback(void)
{
    static recording r;
    record_run(&r);
    CHECK(r.len > 0, "the run recorded something");
    if (r.len == 0)
        return;

    static uint8_t strbuf[16384];
    ds_rfcs_replay_result_t rr;

    /* Case 1 — no callbacks registered. */
    {
        static rig g;
        ds_engine_t *e = engine_open(&g);
        CHECK(e != NULL, "case 1: the replaying engine opens");
        if (e != NULL) {
            memset(&rr, 0, sizeof(rr));
            CHECK_OK(ds_rfcs_replay(e, r.buf, r.len, strbuf, sizeof(strbuf), &rr),
                     "case 1: a replay with no callbacks registered is DS_OK, "
                     "with no divergence ([NDET.8.2], [IDSP.6.4])");
            CHECK(rr.calls == 1,
                  "case 1: the recorded CallIssued was read and compared");
            CHECK(e->dispatcher.replay_depth == 0,
                  "case 1: the replay's span is over");
            CHECK(cache_holds(e, "kept"),
                  "case 1: the engine's own cache took the replay's write");
            CHECK(!cache_holds(e, "k") && !cache_holds(e, "t"),
                  "case 1: and its delete and its expiry");
            ds_engine_free(e);
        }
    }

    /* Cases 2 and 3 — counting callbacks registered, then a live firing. */
    {
        static rig g;
        ds_engine_t *e = engine_open(&g);
        CHECK(e != NULL, "case 2: the replaying engine opens");
        if (e != NULL) {
            fx_probe p = {0};
            CHECK(register_probe(e, &p) == 0, "case 2: callbacks registered");
            memset(&rr, 0, sizeof(rr));
            CHECK_OK(ds_rfcs_replay(e, r.buf, r.len, strbuf, sizeof(strbuf), &rr),
                     "case 2: a replay with callbacks registered is DS_OK");
            CHECK(p.calls == 0, "case 2: no call reached the call callback");
            CHECK(p.sets == 0, "case 2: no write reached the cache-set callback");
            CHECK(p.removals == 0,
                  "case 2: no delete or expiry reached the cache-delete callback");
            CHECK(cache_holds(e, "kept"),
                  "case 2: the engine's own cache took the write all the same");

            live_effects_reach(e, &g, &p,
                               "case 3: after the replay, a live firing reaches "
                               "the call, cache-set and cache-delete callbacks");
            ds_engine_free(e);
        }
    }

    /* Case 4 — a replay that fails ends its span too. */
    {
        static rig g;
        ds_engine_t *e = engine_open(&g);
        CHECK(e != NULL, "case 4: the replaying engine opens");
        if (e != NULL) {
            fx_probe p = {0};
            CHECK(register_probe(e, &p) == 0, "case 4: callbacks registered");
            memset(&rr, 0, sizeof(rr));
            ds_result_t rc = ds_rfcs_replay(e, r.buf, r.len - 1, strbuf,
                                            sizeof(strbuf), &rr);
            CHECK(rc.status == DS_ERR_PARSE,
                  "case 4: a recording cut mid-atom is refused (RFCS.19.2)");
            CHECK(rr.calls == 1,
                  "case 4: premise: the replay got past the firing before the cut");
            CHECK(p.calls == 0 && p.sets == 0 && p.removals == 0,
                  "case 4: and no callback ran before it");
            CHECK(e->dispatcher.replay_depth == 0,
                  "case 4: the failed replay's span is over");

            live_effects_reach(e, &g, &p,
                               "case 4: after the failed replay, a live firing "
                               "reaches the callbacks");
            ds_engine_free(e);
        }
    }
}

int main(void)
{
    printf("=== test_ndet_8_2_replay_no_effect_callbacks ===\n");
    test_ndet_8_2__replay_invokes_no_effect_callback();
    if (failures) {
        fprintf(stderr, "test_ndet_8_2_replay_no_effect_callbacks: %d failure(s)\n",
                failures);
        return 1;
    }
    printf("=== test_ndet_8_2_replay_no_effect_callbacks: ALL PASSED ===\n");
    return 0;
}
