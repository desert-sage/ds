/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * [NCBK.1.5]: a stream callback's non-OK status reaches whoever called, and
 * changes nothing the engine does.
 *
 *   1. The status comes out. A sink failing on FACT_ASSERT, RULE_FIRE_BEGIN or
 *      an ACTION_* event makes ds_engine_assert / ds_engine_pump return it.
 *   2. It is the FIRST one. A sink that fails with one code and then another
 *      reports the first.
 *   3. The engine did everything anyway. The pump still ran every firing, and
 *      the TTL sweep still retracted every expired fact. A sink is an observer
 *      ([NCBK.2.1]).
 *   4. Nothing carries. The next call, with a healthy sink, returns DS_OK.
 *
 * The network is built directly into engine->rete_engine, the idiom of
 * test_action_events.c, because the subject is the firing and not the loader.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "rete/action.h"
#include "rete/beta.h"
#include "rete/engine.h"
#include "rete/expr.h"
#include "rete/loader.h"
#include "rete/schema_reg.h"
#include "rete/terminal.h"
#include "rete/val.h"

static int g_fails;
#define CHECK(cond, msg)                                                     \
    do { if (!(cond)) {                                                      \
        fprintf(stderr, "FAIL [%s]: %s (%s:%d)\n",                           \
                __func__, (msg), __FILE__, __LINE__);                        \
        g_fails++;                                                           \
    } } while (0)

/* ---- a sink that fails on one event kind ----------------------------- */

typedef struct {
    int fail_kind;      /* the event kind to fail on; -1 for none */
    int failed;         /* how many times it has failed */
    int fire_begin;     /* RULE_FIRE_BEGIN seen */
    int fire_end;       /* RULE_FIRE_END seen */
} sink_t;

/* The FIRST failure is DS_ERR_IO and every later one DS_ERR_INTERNAL, so a
   call that reported a later failure instead of the first is visible. */
static ds_result_t sink_cb(ds_engine_t *e, const ds_stream_ev_t *ev, void *user)
{
    (void) e;
    sink_t *s = (sink_t *) user;
    if (ev->kind == DS_EV_RULE_FIRE_BEGIN) s->fire_begin++;
    if (ev->kind == DS_EV_RULE_FIRE_END)   s->fire_end++;
    if ((int) ev->kind != s->fail_kind) return DS_OK_R;
    s->failed++;
    return s->failed == 1
        ? DS_ERR_R(DS_ERR_IO, "sink: first failure")
        : DS_ERR_R(DS_ERR_INTERNAL, "sink: a later failure");
}

/* ---- Src(val) -> copy_rule -> Out(val) ------------------------------- */

/* The network's parts live here, not on fixture_new's stack: the loader is not
   promised to copy them, and test_action_events keeps them alive across its
   pump for the same reason. */
typedef struct {
    ds_engine_t           *engine;
    const ds_schema_t     *src;
    ds_rete_expr_t        *val;
    ds_rete_slot_assign_t  assign;
    ds_rete_action_t       action;
    ds_alfa_atom_t         alfas[1];
    ds_beta_atom_t         betas[1];
    ds_term_atom_t         terms[1];
    ds_rete_network_t      net;
} fixture_t;

static int reg_schema(ds_engine_t *engine, const char *name,
                      ds_schema_lifecycle_t lc, uint64_t ttl_ns,
                      const ds_schema_t **out_ds,
                      const ds_rete_schema_t **out_rs)
{
    ds_slot_desc_t sd = { .name = "val", .type = DS_SLOT_TYPE_INT,
                          .identity_role = DS_IDENTITY_KEY };
    if (ds_engine_register_schema(engine, name, lc, ttl_ns, &sd, 1,
                                  out_ds).status != DS_OK) {
        fprintf(stderr, "FAIL: register_schema %s\n", name);
        return 1;
    }
    if (out_rs != NULL) {
        *out_rs = ds_rete_schema_by_name(engine->rete_engine, name);
        if (*out_rs == NULL) {
            fprintf(stderr, "FAIL: rete schema lookup %s\n", name);
            return 1;
        }
    }
    return 0;
}

/* Keyed Src, so three distinct values are three facts and three firings. */
static int fixture_new(fixture_t *f)
{
    memset(f, 0, sizeof(*f));
    ds_engine_config_t cfg = {0};
    if (ds_engine_new(&cfg, &f->engine).status != DS_OK || !f->engine) {
        fprintf(stderr, "FAIL: engine_new\n");
        return 1;
    }
    const ds_schema_t *out_ds = NULL;
    const ds_rete_schema_t *src_rs = NULL, *out_rs = NULL;
    if (reg_schema(f->engine, "Src", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                   &f->src, &src_rs)) return 1;
    if (reg_schema(f->engine, "Out", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                   &out_ds, &out_rs)) return 1;

    f->val = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
    f->val->var.pattern_index = 0;
    f->val->var.slot_index = 0;
    f->assign = (ds_rete_slot_assign_t) { .slot_index = 0, .expr = f->val };
    f->action = (ds_rete_action_t) {
        .kind = DS_RETE_ACTION_ASSERT, .schema_id = out_rs->id,
        .assigns = &f->assign, .assign_count = 1
    };
    f->alfas[0] = (ds_alfa_atom_t) { .node_id = 1, .schema_name = "Src" };
    f->betas[0] = (ds_beta_atom_t) { .node_id = 2, .right_alpha_id = 1,
                                     .left_parent_id = 0 };
    f->terms[0] = (ds_term_atom_t) { .node_id = 3, .parent_beta_id = 2,
                                     .rule_name = "copy_rule",
                                     .actions = &f->action, .action_count = 1 };
    f->net = (ds_rete_network_t) { .alfas = f->alfas, .alfa_count = 1,
                                   .betas = f->betas, .beta_count = 1,
                                   .terms = f->terms, .term_count = 1 };
    if (ds_rete_load_network(f->engine->rete_engine, &f->net).status != DS_OK) {
        fprintf(stderr, "FAIL: load_network\n");
        ds_rete_expr_free_tree(f->val);
        return 1;
    }
    return 0;
}

static void fixture_free(fixture_t *f)
{
    if (f->engine) ds_engine_free(f->engine);
}

static ds_result_t assert_src(fixture_t *f, int64_t v)
{
    ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = v };
    ds_fact_t *fact = NULL;
    return ds_engine_assert(f->engine, f->src, &sv, 1, &fact);
}

static size_t fact_count(ds_engine_t *e)
{
    size_t n = 0;
    ds_engine_fact_count(e, &n);
    return n;
}

/* ---- 1, 3, 4: FACT_ASSERT, through ds_engine_assert ------------------ */

static void test_fact_assert_status_reaches_assert(void)
{
    fixture_t f;
    if (fixture_new(&f)) { g_fails++; fixture_free(&f); return; }
    sink_t s = { .fail_kind = DS_EV_FACT_ASSERT };
    ds_engine_set_stream_callback(f.engine, sink_cb, &s);

    ds_result_t r = assert_src(&f, 1);
    CHECK(r.status == DS_ERR_IO, "the sink's FACT_ASSERT status is assert's");
    CHECK(fact_count(f.engine) == 1, "and the fact is in working memory anyway");

    s.fail_kind = -1;
    CHECK(assert_src(&f, 2).status == DS_OK,
          "the next assert, with a healthy sink, is DS_OK -- nothing carries");
    CHECK(fact_count(f.engine) == 2, "two facts");
    fixture_free(&f);
}

/* ---- 1, 2, 3, 4: RULE_FIRE_BEGIN, through ds_engine_pump ------------- */

static void test_fire_begin_status_reaches_pump_and_every_firing_runs(void)
{
    fixture_t f;
    if (fixture_new(&f)) { g_fails++; fixture_free(&f); return; }
    sink_t s = { .fail_kind = -1 };
    ds_engine_set_stream_callback(f.engine, sink_cb, &s);
    CHECK(assert_src(&f, 1).status == DS_OK, "assert Src(1)");
    CHECK(assert_src(&f, 2).status == DS_OK, "assert Src(2)");
    CHECK(assert_src(&f, 3).status == DS_OK, "assert Src(3)");

    s.fail_kind = DS_EV_RULE_FIRE_BEGIN;
    ds_result_t r = ds_engine_pump(f.engine);
    CHECK(r.status == DS_ERR_IO,
          "pump returns the FIRST failure, not a later one");
    CHECK(s.failed == 3, "the sink was asked about all three firings");
    CHECK(s.fire_end == 3, "every firing ran to its RULE_FIRE_END");
    CHECK(fact_count(f.engine) == 6, "and every firing's Out fact exists");

    s.fail_kind = -1;
    CHECK(ds_engine_pump(f.engine).status == DS_OK,
          "the next pump, with a healthy sink, is DS_OK");
    fixture_free(&f);
}

/* ---- 1, 3: an ACTION_* event, through ds_engine_pump ----------------- */

static void test_action_event_status_reaches_pump(void)
{
    fixture_t f;
    if (fixture_new(&f)) { g_fails++; fixture_free(&f); return; }
    sink_t s = { .fail_kind = -1 };
    ds_engine_set_stream_callback(f.engine, sink_cb, &s);
    CHECK(assert_src(&f, 7).status == DS_OK, "assert Src(7)");

    /* A rule-RHS assert IS the emit verb, so the firing produces ACTION_EMIT
       (see test_action_events.c). */
    s.fail_kind = DS_EV_ACTION_EMIT;
    CHECK(ds_engine_pump(f.engine).status == DS_ERR_IO,
          "the sink's ACTION_EMIT status is pump's");
    CHECK(s.failed == 1, "the sink saw the ACTION_EMIT");
    CHECK(fact_count(f.engine) == 2, "and the emitted fact exists anyway");
    fixture_free(&f);
}

/* ---- 1, 3, 4: the TTL path ------------------------------------------- */

static void test_ttl_sweep_retracts_whatever_the_sink_says(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK || !e) {
        fprintf(stderr, "FAIL: engine_new\n"); g_fails++; return;
    }
    const ds_schema_t *tmp = NULL;
    if (reg_schema(e, "Tmp", DS_SCHEMA_LIFECYCLE_TTL, 1000, &tmp, NULL)) {
        g_fails++; ds_engine_free(e); return;
    }
    CHECK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK).status == DS_OK, "mock");
    CHECK(ds_engine_clock_set(e, 1000).status == DS_OK, "clock 1000");

    sink_t s = { .fail_kind = -1 };
    ds_engine_set_stream_callback(e, sink_cb, &s);
    ds_slot_value_t a = { .kind = DS_SLOT_INT, .v.i = 1 };
    ds_slot_value_t b = { .kind = DS_SLOT_INT, .v.i = 2 };
    ds_fact_t *fa = NULL, *fb = NULL;
    CHECK(ds_engine_assert(e, tmp, &a, 1, &fa).status == DS_OK, "assert Tmp(1)");
    CHECK(ds_engine_assert(e, tmp, &b, 1, &fb).status == DS_OK, "assert Tmp(2)");
    CHECK(fact_count(e) == 2, "two live TTL facts");

    /* A clock mutation is not a sample ([NTST.3.3]): the advance emits
       nothing, so a sink failing on TICK cannot fail it. */
    s.fail_kind = DS_EV_TICK;
    CHECK(ds_engine_clock_advance(e, 5000).status == DS_OK,
          "clock_advance emits no TICK, so the sink cannot fail it");
    CHECK(s.failed == 0, "and the sink saw no TICK");
    uint64_t now = 0;
    ds_engine_clock_now(e, &now);
    CHECK(now == 6000, "the clock source advanced");

    /* The pump samples the advanced clock and records it as a TICK
       ([LTIM.2.8.5]): that TICK's status is the pump's, and the sweep it
       precedes still retracts both expired facts. */
    CHECK(ds_engine_pump(e).status == DS_ERR_IO,
          "the sink's TICK status is the observing pump's");
    CHECK(s.failed == 1, "one TICK for the one observed value");
    CHECK(fact_count(e) == 0, "and the sweep retracted both expired facts anyway");

    /* The sweep: a failing FACT_RETRACT stops no retraction. */
    s.fail_kind = -1;
    CHECK(ds_engine_assert(e, tmp, &a, 1, &fa).status == DS_OK, "assert Tmp(1) again");
    CHECK(ds_engine_assert(e, tmp, &b, 1, &fb).status == DS_OK, "assert Tmp(2) again");
    CHECK(ds_engine_clock_advance(e, 5000).status == DS_OK, "advance past their ttl");
    s.fail_kind = DS_EV_FACT_RETRACT;
    s.failed = 0;
    CHECK(ds_engine_pump(e).status == DS_ERR_IO,
          "the sweep's FACT_RETRACT status is pump's");
    CHECK(s.failed == 2, "the sink was told about both expiries");
    CHECK(fact_count(e) == 0, "and both expired facts are gone");

    s.fail_kind = -1;
    CHECK(ds_engine_pump(e).status == DS_OK,
          "the next pump, with a healthy sink, is DS_OK");
    ds_engine_free(e);
}

int main(void)
{
    printf("=== test_stream_status ===\n");
    test_fact_assert_status_reaches_assert();
    test_fire_begin_status_reaches_pump_and_every_firing_runs();
    test_action_event_status_reaches_pump();
    test_ttl_sweep_retracts_whatever_the_sink_says();
    if (g_fails) {
        fprintf(stderr, "test_stream_status: %d FAILURE(S)\n", g_fails);
        return 1;
    }
    printf("=== test_stream_status: ALL PASSED ===\n");
    return 0;
}
