/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * test_iret_19_4_one_tick_per_pump — [IRET.19.4]: the clock tick runs once
 * per pump, before the firing loop, and never between two firings of one pump.
 *
 * ds_engine_pump runs the TTL sweep, then ds_rete_engine_tick_clock, then
 * ds_rete_run. Each tick asserts a fresh $ClockTick fact, and every rete fact
 * takes its id from one counter, so in a pump whose cascade A -> B -> C fires
 * twice, exactly three facts are made and the tick's id is below B's.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "rete/action.h"
#include "rete/engine.h"
#include "rete/expr.h"
#include "rete/fact.h"
#include "rete/intern.h"
#include "rete/loader.h"
#include "rete/schema_reg.h"
#include "rete/terminal.h"

static int failures = 0;
#define CHECK(cond, msg)                                                      \
    do { if (!(cond)) {                                                       \
        fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__);     \
        failures++; } } while (0)
#define CHECK_OK(r, msg)                                                      \
    do { ds_result_t rr_ = (r);                                              \
        if (rr_.status != DS_OK) {                                            \
            fprintf(stderr, "FAIL: %s: status=%d detail=%s (%s:%d)\n", (msg), \
                    rr_.status, rr_.detail ? rr_.detail : "(null)",           \
                    __FILE__, __LINE__); failures++; } } while (0)

static const ds_slot_desc_t SLOTS[1] = {
    { .name = "v", .type = DS_SLOT_TYPE_INT, .identity_role = DS_IDENTITY_KEY },
};

static ds_rete_expr_t *lit(int64_t v)
{
    ds_rete_expr_t *x = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_INT);
    if (x) x->lit_int = v;
    return x;
}

static uint16_t rete_schema_id(ds_rete_engine_t *re, const char *name)
{
    const char *iname = NULL;
    if (ds_rete_intern_cstr(re->intern, name, &iname).status != DS_OK)
        return UINT16_MAX;
    const ds_rete_schema_t *s = ds_rete_schema_by_name(re, iname);
    return s ? s->id : UINT16_MAX;
}

/* The live fact of a schema, or NULL. */
static const ds_rete_fact_t *live_of(ds_rete_engine_t *re, uint16_t schema_id)
{
    for (uint32_t i = 0; i < oa_len(&re->wm_map); i++) {
        ds_rete_fact_t *f = *(ds_rete_fact_t **)ds_oa_val_at(&re->wm_map, i);
        if (f && f->schema && f->schema->id == schema_id) return f;
    }
    return NULL;
}

static void test_iret_19_4__one_tick_per_pump_before_the_firings(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (!e) return;
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "mock clock");
    CHECK_OK(ds_engine_clock_set(e, 0), "clock 0");

    const ds_schema_t *sa = NULL, *sb = NULL, *sc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "A", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       SLOTS, 1, &sa), "register A");
    CHECK_OK(ds_engine_register_schema(e, "B", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       SLOTS, 1, &sb), "register B");
    CHECK_OK(ds_engine_register_schema(e, "C", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       SLOTS, 1, &sc), "register C");
    ds_rete_engine_t *re = e->rete_engine;
    ds_rete_schema_t *tick_schema = NULL;
    CHECK_OK(ds_rete_schema_register(re, DS_RETE_CLOCK_TICK_NAME,
                                     DS_RETE_SCOPE_PLAIN, 0, NULL, 0, &tick_schema),
             "register the tick schema, so the pump ticks");
    if (!sa || !sb || !sc || !tick_schema) { ds_engine_free(e); return; }

    uint16_t id_b = rete_schema_id(re, "B");
    uint16_t id_c = rete_schema_id(re, "C");
    CHECK(id_b != UINT16_MAX && id_c != UINT16_MAX, "B and C have rete ids");

    /* `rule a_to_b: A -> emit B v: 1` and `rule b_to_c: B -> emit C v: 1`. */
    ds_rete_slot_assign_t emit_b[1] = {{ .slot_index = 0, .expr = lit(1) }};
    ds_rete_slot_assign_t emit_c[1] = {{ .slot_index = 0, .expr = lit(1) }};
    ds_rete_action_t act_b = { .kind = DS_RETE_ACTION_ASSERT, .schema_id = id_b,
                               .assigns = emit_b, .assign_count = 1 };
    ds_rete_action_t act_c = { .kind = DS_RETE_ACTION_ASSERT, .schema_id = id_c,
                               .assigns = emit_c, .assign_count = 1 };
    ds_alfa_atom_t alfas[2] = {
        { .node_id = 1, .schema_name = "A" },
        { .node_id = 2, .schema_name = "B" },
    };
    ds_beta_atom_t betas[2] = {
        { .node_id = 3, .right_alpha_id = 1 },
        { .node_id = 4, .right_alpha_id = 2 },
    };
    ds_term_atom_t terms[2] = {
        { .node_id = 5, .parent_beta_id = 3, .rule_name = "a_to_b",
          .actions = &act_b, .action_count = 1 },
        { .node_id = 6, .parent_beta_id = 4, .rule_name = "b_to_c",
          .actions = &act_c, .action_count = 1 },
    };
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 2,
                              .betas = betas, .beta_count = 2,
                              .terms = terms, .term_count = 2 };
    if (ds_rete_load_network(re, &net).status != DS_OK) {
        fprintf(stderr, "FAIL: load network\n");
        failures++;
        ds_engine_free(e);
        return;
    }

    /* Pump 1: the cascade fires twice. */
    ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = 1 };
    CHECK_OK(ds_engine_assert(e, sa, &sv, 1, NULL), "assert A");
    uint32_t before = re->next_fact_id;
    CHECK_OK(ds_engine_pump(e), "pump 1");
    const ds_rete_fact_t *b = live_of(re, id_b);
    const ds_rete_fact_t *c = live_of(re, id_c);
    const ds_rete_fact_t *t = re->clock_tick_fact;
    CHECK(b != NULL && c != NULL,
          "premise: pump 1 fired both rules, emitting B and C");
    CHECK(t != NULL, "pump 1 left a live tick fact");
    if (b && c && t) {
        CHECK(re->next_fact_id - before == 3,
              "pump 1 made three facts, one tick, B and C: one tick per pump");
        CHECK(t->id >= before, "the live tick is pump 1's");
        CHECK(t->id < b->id && b->id < c->id,
              "the tick came before the first firing, and none followed it");
    }

    /* Pump 2: nothing to fire, one tick. */
    CHECK_OK(ds_engine_clock_advance(e, 1000), "advance");
    uint32_t before2 = re->next_fact_id;
    CHECK_OK(ds_engine_pump(e), "pump 2");
    CHECK(re->next_fact_id - before2 == 1,
          "pump 2, with nothing to fire, made one fact: its tick");
    CHECK(re->clock_tick_fact != NULL && re->clock_tick_fact->id >= before2,
          "and that fact is the live tick");

    ds_engine_free(e);
}

/* [IRET.19.4]'s last sentence: `ds_rete_run` alone does not tick. */
static void test_iret_19_4__the_firing_loop_alone_does_not_tick(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "run alone: engine_new");
    if (!e) return;
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "run alone: mock clock");
    CHECK_OK(ds_engine_clock_set(e, 0), "run alone: clock 0");

    const ds_schema_t *sa = NULL, *sb = NULL, *sc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "A", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       SLOTS, 1, &sa), "run alone: register A");
    CHECK_OK(ds_engine_register_schema(e, "B", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       SLOTS, 1, &sb), "run alone: register B");
    CHECK_OK(ds_engine_register_schema(e, "C", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       SLOTS, 1, &sc), "run alone: register C");
    ds_rete_engine_t *re = e->rete_engine;
    ds_rete_schema_t *tick_schema = NULL;
    CHECK_OK(ds_rete_schema_register(re, DS_RETE_CLOCK_TICK_NAME,
                                     DS_RETE_SCOPE_PLAIN, 0, NULL, 0, &tick_schema),
             "run alone: register the tick schema, so a tick would show");
    if (!sa || !sb || !sc || !tick_schema) { ds_engine_free(e); return; }

    uint16_t id_b = rete_schema_id(re, "B");
    uint16_t id_c = rete_schema_id(re, "C");
    CHECK(id_b != UINT16_MAX && id_c != UINT16_MAX, "run alone: B and C have rete ids");

    ds_rete_slot_assign_t emit_b[1] = {{ .slot_index = 0, .expr = lit(1) }};
    ds_rete_slot_assign_t emit_c[1] = {{ .slot_index = 0, .expr = lit(1) }};
    ds_rete_action_t act_b = { .kind = DS_RETE_ACTION_ASSERT, .schema_id = id_b,
                               .assigns = emit_b, .assign_count = 1 };
    ds_rete_action_t act_c = { .kind = DS_RETE_ACTION_ASSERT, .schema_id = id_c,
                               .assigns = emit_c, .assign_count = 1 };
    ds_alfa_atom_t alfas[2] = {
        { .node_id = 1, .schema_name = "A" },
        { .node_id = 2, .schema_name = "B" },
    };
    ds_beta_atom_t betas[2] = {
        { .node_id = 3, .right_alpha_id = 1 },
        { .node_id = 4, .right_alpha_id = 2 },
    };
    ds_term_atom_t terms[2] = {
        { .node_id = 5, .parent_beta_id = 3, .rule_name = "a_to_b",
          .actions = &act_b, .action_count = 1 },
        { .node_id = 6, .parent_beta_id = 4, .rule_name = "b_to_c",
          .actions = &act_c, .action_count = 1 },
    };
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 2,
                              .betas = betas, .beta_count = 2,
                              .terms = terms, .term_count = 2 };
    if (ds_rete_load_network(re, &net).status != DS_OK) {
        fprintf(stderr, "FAIL: run alone: load network\n");
        failures++;
        ds_engine_free(e);
        return;
    }

    ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = 1 };
    CHECK_OK(ds_engine_assert(e, sa, &sv, 1, NULL), "run alone: assert A");
    const ds_rete_fact_t *tick_before = re->clock_tick_fact;
    uint32_t before = re->next_fact_id;
    uint32_t fired = 0;
    CHECK_OK(ds_rete_run(re, 0, &fired), "run alone: ds_rete_run");
    CHECK(fired == 2, "run alone: premise -- the cascade fired both rules");
    CHECK(live_of(re, id_b) != NULL && live_of(re, id_c) != NULL,
          "run alone: premise -- B and C were emitted");
    CHECK(re->next_fact_id - before == 2,
          "run alone: the firing loop made B and C and no tick fact");
    CHECK(re->clock_tick_fact == tick_before,
          "run alone: the live tick is the one the loop started with");

    ds_engine_free(e);
}

int main(void)
{
    test_iret_19_4__one_tick_per_pump_before_the_firings();
    test_iret_19_4__the_firing_loop_alone_does_not_tick();
    if (failures) {
        fprintf(stderr, "test_iret_19_4_one_tick_per_pump: %d failure(s)\n",
                failures);
        return 1;
    }
    printf("test_iret_19_4_one_tick_per_pump: OK\n");
    return 0;
}
