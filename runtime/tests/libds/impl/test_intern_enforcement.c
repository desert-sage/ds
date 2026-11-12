/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * What the intern table does on its own invariant broken ([IERR.1.7]), that legal
 * operations pass, and that the ds.intern.* gauges match its accounting.
 *
 * A release past zero has no reachable cause in a correct engine, so the cases
 * make one: `corrupt_held_slot` points a live fact's String slot at a counted
 * entry born with no references, and a release of that slot then finds it at
 * zero.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdbool.h>
#include <stdlib.h>

#include "libds.h"
#include "engine.h"
#include "rete/action.h"
#include "rete/beta.h"
#include "rete/engine.h"
#include "rete/expr.h"
#include "rete/intern.h"
#include "rete/loader.h"
#include "rete/schema_reg.h"
#include "rete/terminal.h"
#include "rfcs/rfcs.h"

static int g_fails;
#define CHECK(cond, msg)                                                     \
    do { if (!(cond)) {                                                      \
        fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__);    \
        g_fails++;                                                           \
    } } while (0)

#define VALUE_SLOT 1u

/* `Held`: an Int key, and the String slot the cases corrupt. */
static ds_engine_t *held_engine(const char *run_id, const char *schema,
                                const ds_schema_t **out)
{
    ds_engine_config_t cfg = { .run_id = run_id, .tier_id = run_id ? "t1" : NULL };
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK || e == NULL) {
        CHECK(false, "engine_new");
        return NULL;
    }
    ds_slot_desc_t sd[2] = {
        { .name = "id", .type = DS_SLOT_TYPE_INT, .identity_role = DS_IDENTITY_KEY },
        { .name = "v", .type = DS_SLOT_TYPE_STRING,
          .identity_role = DS_IDENTITY_MUTABLE },
    };
    CHECK(ds_engine_register_schema(e, schema, DS_SCHEMA_LIFECYCLE_LOGICAL, 0, sd, 2,
                                    out).status == DS_OK, "register schema");
    return e;
}

static ds_result_t assert_held(ds_engine_t *e, const ds_schema_t *s, ds_fact_t **out)
{
    ds_slot_value_t v[2] = {
        { .kind = DS_SLOT_INT, .v.i = 1 },
        { .kind = DS_SLOT_STRING, .v.s = "held" },
    };
    return ds_engine_assert(e, s, v, 2, out);
}

/* A counted entry born with no references. */
static const char *orphan(ds_engine_t *e)
{
    const char *p = NULL;
    CHECK(ds_rete_intern_value(e->rete_engine->intern, "orphan", 6, &p).status == DS_OK,
          "intern the orphan");
    return p;
}

/* The one live fact's String slot, repointed at the orphan. */
static void corrupt_held_slot(ds_engine_t *e)
{
    ds_rete_engine_t *re = e->rete_engine;
    CHECK(oa_len(&re->wm_map) == 1, "one live fact to corrupt");
    if (oa_len(&re->wm_map) != 1) return;
    ds_rete_fact_t *f = *(ds_rete_fact_t **)ds_oa_val_at(&re->wm_map, 0);
    f->slots[VALUE_SLOT].s.ptr = orphan(e);
    f->slots[VALUE_SLOT].s.len = 6;
}

typedef struct {
    int               events;
    int               engine_errors;
    int               asserts;
    int               last_kind;
    ds_engine_fault_t fault;
} stream_seen_t;

static ds_result_t saw_event(ds_engine_t *e, const ds_stream_ev_t *ev, void *user)
{
    (void)e;
    stream_seen_t *s = user;
    s->events++;
    s->last_kind = (int)ev->kind;
    if (ev->kind == DS_EV_FACT_ASSERT) s->asserts++;
    if (ev->kind == DS_EV_ENGINE_ERROR) {
        s->engine_errors++;
        s->fault = ev->p.engine_error.fault;
    }
    return DS_OK_R;
}

static ds_result_t refuse_event(ds_engine_t *e, const ds_stream_ev_t *ev, void *user)
{
    (void)e; (void)ev; (void)user;
    return DS_ERR_R(DS_ERR_INTERNAL, "a callback's own status");
}

static void check_halted_internal(ds_engine_t *e)
{
    bool halted = false;
    ds_engine_fault_t fault = DS_ENGINE_FAULT_UNSPECIFIED;
    CHECK(ds_engine_halted(e, &halted, &fault).status == DS_OK, "read the latch");
    CHECK(halted, "the latch is set");
    CHECK(fault == DS_ENGINE_FAULT_INTERNAL, "the latch names ENGINE_FAULT_INTERNAL");
}

/* @spec [IERR.1.7] */
static void test_ierr_1_7__pinned_insert_after_freeze_is_refused(void)
{
    const ds_schema_t *s = NULL;
    ds_engine_t *e = held_engine(NULL, "Held", &s);
    if (e == NULL) return;
    CHECK(ds_engine_pump(e).status == DS_OK, "the first pump arms the freeze");
    ds_rete_intern_freeze(e->rete_engine->intern);

    size_t before = 0, after = 0;
    ds_rete_intern_mem(e->rete_engine->intern, &before, NULL, NULL);
    const char *p = NULL;
    ds_result_t r = ds_rete_intern_cstr(e->rete_engine->intern, "pin_after_freeze", &p);
    CHECK(r.status == DS_ERR_INTERNAL, "a new pinned insert is DS_ERR_INTERNAL");
    ds_rete_intern_mem(e->rete_engine->intern, &after, NULL, NULL);
    CHECK(before == after, "the table is unchanged");

    CHECK(assert_held(e, s, NULL).status == DS_OK, "the engine still asserts");
    CHECK(ds_engine_pump(e).status == DS_OK, "the engine still pumps");
    bool halted = true;
    CHECK(ds_engine_halted(e, &halted, NULL).status == DS_OK, "read the latch");
    CHECK(!halted, "the engine has not halted");
    ds_engine_free(e);
}

/* @spec [IERR.1.7] */
static void test_ierr_1_7__release_past_zero_halts(void)
{
    const ds_schema_t *s = NULL;
    ds_engine_t *e = held_engine(NULL, "Held", &s);
    if (e == NULL) return;
    ds_fact_t *f = NULL;
    CHECK(assert_held(e, s, &f).status == DS_OK, "assert");
    CHECK(ds_engine_pump(e).status == DS_OK, "pump");
    corrupt_held_slot(e);

    stream_seen_t seen = { 0 };
    CHECK(ds_engine_set_stream_callback(e, saw_event, &seen).status == DS_OK, "stream");
    ds_result_t r = ds_engine_retract(e, f);
    CHECK(r.status == DS_ERR_ENGINE_HALTED, "the call reports the halt");
    CHECK(seen.engine_errors == 1, "one EngineError");
    CHECK(seen.fault == DS_ENGINE_FAULT_INTERNAL, "of ENGINE_FAULT_INTERNAL");
    CHECK(seen.last_kind == (int)DS_EV_ENGINE_ERROR, "the EngineError is the last event");
    check_halted_internal(e);
    ds_engine_free(e);
}

static ds_rete_expr_t *lit_int(int64_t i)
{
    ds_rete_expr_t *x = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_INT);
    x->lit_int = i;
    return x;
}

/* @spec [IERR.1.7]
 * `end: Held t -> withdraw t; emit Later val: 1`. The withdraw's release finds the
 * count at zero, so the emit does not run. */
static void test_ierr_1_7__release_past_zero_stops_the_work(void)
{
    const ds_schema_t *s = NULL;
    ds_engine_t *e = held_engine(NULL, "Held", &s);
    if (e == NULL) return;
    ds_slot_desc_t sd = { .name = "val", .type = DS_SLOT_TYPE_INT,
                          .identity_role = DS_IDENTITY_KEY };
    const ds_schema_t *later = NULL;
    CHECK(ds_engine_register_schema(e, "Later", DS_SCHEMA_LIFECYCLE_LOGICAL, 0, &sd, 1,
                                    &later).status == DS_OK, "register Later");
    const ds_rete_schema_t *later_rs = ds_rete_schema_by_name(e->rete_engine, "Later");
    CHECK(later_rs != NULL, "Later is in the rete");
    if (later_rs == NULL) { ds_engine_free(e); return; }

    ds_rete_slot_assign_t val[1] = {{ .slot_index = 0, .expr = lit_int(1) }};
    ds_rete_action_t actions[2] = {
        { .kind = DS_RETE_ACTION_WITHDRAW, .withdraw_pattern_index = 0 },
        { .kind = DS_RETE_ACTION_ASSERT, .schema_id = later_rs->id,
          .assigns = val, .assign_count = 1 },
    };
    ds_alfa_atom_t alfas[1] = {{ .node_id = 1, .schema_name = "Held" }};
    ds_beta_atom_t betas[1] = {{ .node_id = 2, .right_alpha_id = 1, .left_parent_id = 0 }};
    ds_term_atom_t terms[1] = {{ .node_id = 3, .parent_beta_id = 2, .rule_name = "end",
                                 .actions = actions, .action_count = 2 }};
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 1,
                              .betas = betas, .beta_count = 1,
                              .terms = terms, .term_count = 1 };
    CHECK(ds_rete_load_network(e->rete_engine, &net).status == DS_OK, "load network");

    CHECK(assert_held(e, s, NULL).status == DS_OK, "assert");
    corrupt_held_slot(e);
    stream_seen_t seen = { 0 };
    CHECK(ds_engine_set_stream_callback(e, saw_event, &seen).status == DS_OK, "stream");
    ds_result_t r = ds_engine_pump(e);
    CHECK(r.status == DS_ERR_ENGINE_HALTED, "the pump reports the halt");
    CHECK(seen.engine_errors == 1, "one EngineError");
    CHECK(seen.asserts == 0, "the emit after the withdraw did not run");
    CHECK(seen.last_kind == (int)DS_EV_ENGINE_ERROR, "the EngineError is the last event");
    check_halted_internal(e);
    ds_engine_free(e);
}

/* @spec [IERR.1.7] */
static void test_ierr_1_7__release_past_zero_during_free_raises_nothing(void)
{
    const ds_schema_t *s = NULL;
    ds_engine_t *e = held_engine(NULL, "Held", &s);
    if (e == NULL) return;
    ds_fact_t *f = NULL;
    CHECK(assert_held(e, s, &f).status == DS_OK, "assert");
    CHECK(ds_engine_pump(e).status == DS_OK, "pump");
    /* Teardown releases a wrapper's slots, so the wrapper's is the one repointed. */
    if (f != NULL) f->slots[VALUE_SLOT].v.s = orphan(e);

    stream_seen_t seen = { 0 };
    CHECK(ds_engine_set_stream_callback(e, saw_event, &seen).status == DS_OK, "stream");
    CHECK(ds_engine_free(e).status == DS_OK, "free finishes");
    CHECK(seen.events == 0, "and raises nothing");
}

/* @spec [IERR.1.7] */
static void test_ierr_1_7__a_callback_status_halts_nothing(void)
{
    const ds_schema_t *s = NULL;
    ds_engine_t *e = held_engine(NULL, "Held", &s);
    if (e == NULL) return;
    CHECK(ds_engine_set_stream_callback(e, refuse_event, NULL).status == DS_OK, "stream");
    ds_result_t r = assert_held(e, s, NULL);
    CHECK(r.status == DS_ERR_INTERNAL, "the callback's status is reported");
    bool halted = true;
    CHECK(ds_engine_halted(e, &halted, NULL).status == DS_OK, "read the latch");
    CHECK(!halted, "the engine has not halted");
    CHECK(ds_engine_set_stream_callback(e, NULL, NULL).status == DS_OK, "clear the stream");
    CHECK(ds_engine_pump(e).status == DS_OK, "the engine still pumps");
    ds_engine_free(e);
}

typedef struct { uint8_t bytes[16384]; size_t len; } capture_t;

static ds_result_t capture_sink(const uint8_t *bytes, size_t n, void *user)
{
    capture_t *c = user;
    if (c->len + n > sizeof(c->bytes))
        return DS_ERR_R(DS_ERR_INVAL, "capture overflow");
    memcpy(c->bytes + c->len, bytes, n);
    c->len += n;
    return DS_OK_R;
}

/* @spec [IERR.1.7] [RFCS.6.7]
 * A replay re-derives the EngineError, so the replaying engine's fact is
 * corrupted as the recorded run's was: at the FactRetract, fed in two parts. */
static void test_ierr_1_7__a_recording_that_halted_replays(void)
{
    static capture_t cap;
    static uint8_t recbuf[16384];
    const ds_schema_t *s = NULL;
    ds_engine_t *e = held_engine("r1", "Held", &s);
    if (e == NULL) return;
    CHECK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK).status == DS_OK, "mock clock");
    cap.len = 0;
    ds_rfcs_recorder_t rec;
    CHECK(ds_rfcs_record_to(e, &rec, capture_sink, &cap, recbuf, sizeof(recbuf)).status == DS_OK,
          "record");
    CHECK(ds_engine_clock_set(e, 1000000000ull).status == DS_OK, "clock");
    ds_fact_t *f = NULL;
    CHECK(assert_held(e, s, &f).status == DS_OK, "assert");
    CHECK(ds_engine_pump(e).status == DS_OK, "pump");
    corrupt_held_slot(e);
    CHECK(ds_engine_retract(e, f).status == DS_ERR_ENGINE_HALTED, "the run halts");
    ds_engine_free(e);

    /* The FactRetract's body: everything before it is applied by the first feed. */
    size_t split = 0;
    ds_rfcs_reader_t rd;
    ds_rfcs_reader_init(&rd, cap.bytes, cap.len);
    for (;;) {
        uint32_t atom = 0;
        const uint8_t *body = NULL;
        size_t blen = 0;
        bool done = false;
        if (ds_rfcs_next(&rd, &atom, &body, &blen, &done).status != DS_OK || done) break;
        if (atom == DS_ATOM_FACT_RETRACT) { split = (size_t)(body - cap.bytes); break; }
    }
    CHECK(split > 0, "the recording holds a FactRetract");
    if (split == 0) return;

    const ds_schema_t *rs = NULL;
    ds_engine_t *r = held_engine("r1", "Held", &rs);
    if (r == NULL) return;
    ds_rfcs_replay_ctx_t *ctx = NULL;
    CHECK(ds_rfcs_replay_begin(r, NULL, &ctx).status == DS_OK, "replay begin");
    CHECK(ds_rfcs_replay_feed(ctx, cap.bytes, split).status == DS_OK, "feed to the retract");
    corrupt_held_slot(r);
    CHECK(ds_rfcs_replay_feed(ctx, cap.bytes + split, cap.len - split).status == DS_OK,
          "feed the rest: the re-derived EngineError is compared");
    ds_rfcs_replay_result_t out;
    memset(&out, 0, sizeof(out));
    CHECK(ds_rfcs_replay_finish(ctx, &out).status == DS_OK, "the replay returns DS_OK");
    check_halted_internal(r);
    ds_engine_free(r);
}

/* After the freeze, re-pinning a known string and a counted insert are legal. */
static void test_freeze_allows_legal_ops(void)
{
    ds_rete_engine_t *e = NULL;
    CHECK(ds_rete_engine_create(&e).status == DS_OK, "create engine");
    if (e == NULL) return;
    const char *a = NULL, *b = NULL, *c = NULL;
    CHECK(ds_rete_intern_cstr(e->intern, "known", &a).status == DS_OK, "pin known pre-freeze");
    ds_rete_intern_freeze(e->intern);
    CHECK(ds_rete_intern_cstr(e->intern, "known", &b).status == DS_OK, "re-pin known post-freeze ok");
    CHECK(a == b, "existing pinned string returns same pointer (no new insert)");
    CHECK(ds_rete_intern_value(e->intern, "counted", 7, &c).status == DS_OK,
          "counted insert post-freeze is legal");
    ds_rete_engine_destroy(e);
}

/* The first pump arms the freeze; a second pump interning a new counted value
   does not trip it. */
static void test_second_pump_after_freeze_arm_ok(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK(ds_engine_new(&cfg, &e).status == DS_OK, "engine_new");
    if (e == NULL) return;
    ds_slot_desc_t sd = { .name = "v", .type = DS_SLOT_TYPE_STRING,
                          .identity_role = DS_IDENTITY_KEY };
    const ds_schema_t *sc = NULL;
    CHECK(ds_engine_register_schema(e, "S", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                    0, &sd, 1, &sc).status == DS_OK, "reg S");
    ds_slot_value_t v1 = { .kind = DS_SLOT_STRING, .v.s = "one" };
    CHECK(ds_engine_assert(e, sc, &v1, 1, NULL).status == DS_OK, "assert one");
    CHECK(ds_engine_pump(e).status == DS_OK, "first pump (arms freeze)");
    ds_slot_value_t v2 = { .kind = DS_SLOT_STRING, .v.s = "two" };
    CHECK(ds_engine_assert(e, sc, &v2, 1, NULL).status == DS_OK, "assert two post-arm");
    CHECK(ds_engine_pump(e).status == DS_OK, "second pump post-arm does not trip");
    ds_engine_free(e);
}

struct si3_capture {
    double entries, bytes, pinned, arena;
    bool got_entries, got_bytes, got_pinned, got_arena;
};

static ds_result_t si3_cb(ds_engine_t *engine, const ds_metric_t *m, void *user)
{
    (void)engine;
    struct si3_capture *c = user;
    if      (strcmp(m->name, "ds.intern.entries") == 0)        { c->entries = m->value; c->got_entries = true; }
    else if (strcmp(m->name, "ds.intern.bytes") == 0)          { c->bytes   = m->value; c->got_bytes   = true; }
    else if (strcmp(m->name, "ds.intern.pinned_entries") == 0) { c->pinned  = m->value; c->got_pinned  = true; }
    else if (strcmp(m->name, "ds.intern.arena_high_water_bytes") == 0) { c->arena = m->value; c->got_arena = true; }
    return DS_OK_R;
}

/* The ds.intern.* gauges ([RMET.4]) equal the table's accounting. With no
   rule, the pump-entry snapshot equals the post-pump accessors. */
static void test_si3_gauge_accuracy(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK(ds_engine_new(&cfg, &e).status == DS_OK, "engine_new");
    if (e == NULL) return;

    struct si3_capture cap = {0};
    CHECK(ds_engine_set_metric_callback(e, si3_cb, &cap).status == DS_OK, "set metric cb");

    ds_slot_desc_t sd = { .name = "v", .type = DS_SLOT_TYPE_STRING,
                          .identity_role = DS_IDENTITY_KEY };
    const ds_schema_t *sc = NULL;
    CHECK(ds_engine_register_schema(e, "S", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                    0, &sd, 1, &sc).status == DS_OK, "reg S");
    ds_slot_value_t v1 = { .kind = DS_SLOT_STRING, .v.s = "alpha" };
    ds_slot_value_t v2 = { .kind = DS_SLOT_STRING, .v.s = "beta" };
    ds_engine_assert(e, sc, &v1, 1, NULL);
    ds_engine_assert(e, sc, &v2, 1, NULL);
    CHECK(ds_engine_pump(e).status == DS_OK, "pump emits gauges");

    CHECK(cap.got_entries && cap.got_bytes && cap.got_pinned && cap.got_arena,
          "all four ds.intern.* gauges emitted");

    size_t ic = 0, ib = 0;
    ds_rete_intern_mem(e->rete_engine->intern, &ic, &ib, NULL);
    size_t pin = ds_rete_intern_pinned_count(e->rete_engine->intern);
    uint64_t hw = e->rete_engine->comp_arena.high_water;

    CHECK(cap.entries == (double)ic,  "entries gauge matches ds_rete_intern_mem count");
    CHECK(cap.bytes   == (double)ib,  "bytes gauge matches string_bytes");
    CHECK(cap.pinned  == (double)pin, "pinned gauge matches pinned_count");
    CHECK(cap.arena   == (double)hw,  "arena gauge matches comp_arena.high_water");

    ds_engine_free(e);
}

int main(void)
{
    g_fails = 0;

    test_ierr_1_7__pinned_insert_after_freeze_is_refused();
    test_ierr_1_7__release_past_zero_halts();
    test_ierr_1_7__release_past_zero_stops_the_work();
    test_ierr_1_7__release_past_zero_during_free_raises_nothing();
    test_ierr_1_7__a_callback_status_halts_nothing();
    test_ierr_1_7__a_recording_that_halted_replays();
    test_freeze_allows_legal_ops();
    test_second_pump_after_freeze_arm_ok();
    test_si3_gauge_accuracy();

    if (g_fails) { printf("test_intern_enforcement: %d FAILURES\n", g_fails); return 1; }
    printf("test_intern_enforcement: ALL PASSED\n");
    return 0;
}
