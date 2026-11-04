/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NCBK.2.12]
 * [NCBK.2.12]: one firing has one timetag, and every event it produces
 * carries it. One cooldown rule fires on one fact; its RULE_LHS_FACTS,
 * RULE_FIRE_BEGIN, RULE_FIRE_END and TIMER_ARMED, emitted by
 * engine_rete_adapters.c's _rete_before_fire and _rete_after_fire, carry one
 * timetag that is not 0. The AOT dispatch path is not reached.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "ds_alloc.h"
#include "engine.h"
#include "rete/action.h"
#include "rete/beta.h"
#include "rete/engine.h"
#include "rete/expr.h"
#include "rete/loader.h"
#include "rete/schema_reg.h"
#include "rete/terminal.h"

static int g_fails;
#define CHECK(cond, msg)                                                     \
    do { if (!(cond)) {                                                      \
        fprintf(stderr, "FAIL [%s]: %s (%s:%d)\n",                           \
                __func__, (msg), __FILE__, __LINE__);                        \
        g_fails++;                                                           \
    } } while (0)

#define COOL_WINDOW_NS 1000000000ull

#define MAX_EV 64
typedef struct {
    int     n;
    int     kind[MAX_EV];
    int64_t timetag[MAX_EV];
} trace_t;

static ds_result_t trace_cb(ds_engine_t *e, const ds_stream_ev_t *ev, void *user)
{
    (void) e;
    trace_t *t = (trace_t *) user;
    int64_t tt;
    switch (ev->kind) {
    case DS_EV_RULE_LHS_FACTS:  tt = ev->p.rule_lhs_facts.timetag;  break;
    case DS_EV_RULE_FIRE_BEGIN: tt = ev->p.rule_fire_begin.timetag; break;
    case DS_EV_RULE_FIRE_END:   tt = ev->p.rule_fire_end.timetag;   break;
    case DS_EV_TIMER_ARMED:     tt = ev->p.timer_armed.timetag;     break;
    default:                    return DS_OK_R;
    }
    if (t->n < MAX_EV) {
        t->kind[t->n]    = (int) ev->kind;
        t->timetag[t->n] = tt;
        t->n++;
    }
    return DS_OK_R;
}

/* The index of the only event of `kind`, or -1 if there is not exactly one. */
static int only(const trace_t *t, int kind)
{
    int at = -1;
    for (int i = 0; i < t->n; i++) {
        if (t->kind[i] != kind) continue;
        if (at >= 0) return -1;
        at = i;
    }
    return at;
}

static ds_rete_expr_t *var_ref(uint16_t pat, uint16_t slot)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
    e->var.pattern_index = pat; e->var.slot_index = slot; return e;
}

static int reg_schema(ds_engine_t *engine, const char *name,
                      const ds_schema_t **out_ds,
                      const ds_rete_schema_t **out_rs)
{
    ds_slot_desc_t sd = { .name = "val", .type = DS_SLOT_TYPE_INT,
                          .identity_role = DS_IDENTITY_KEY };
    if (ds_engine_register_schema(engine, name, DS_SCHEMA_LIFECYCLE_LOGICAL,
                                  0, &sd, 1, out_ds).status != DS_OK) {
        fprintf(stderr, "FAIL: register_schema %s\n", name);
        return 1;
    }
    *out_rs = ds_rete_schema_by_name(engine->rete_engine, name);
    if (*out_rs == NULL) {
        fprintf(stderr, "FAIL: rete schema lookup %s\n", name);
        return 1;
    }
    return 0;
}

/* Give `rule_name` a cooldown, as a loaded RuleCooldown atom would. engine_free
   releases it with the rest of rule_metas. */
static int set_cooldown(ds_engine_t *engine, const char *rule_name)
{
    engine->rule_metas = DS_CALLOC(1, sizeof(*engine->rule_metas));
    if (engine->rule_metas == NULL) return 1;
    engine->rule_metas[0].rule_name      = DS_STRDUP(rule_name);
    engine->rule_metas[0].has_cool       = true;
    engine->rule_metas[0].cool_window_ns = COOL_WINDOW_NS;
    engine->n_rule_metas   = 1;
    engine->cap_rule_metas = 1;
    if (engine->rule_metas[0].rule_name == NULL) return 1;
    return ds_engine_rule_meta_map_rebuild(engine).status != DS_OK;
}

static void test_one_firing_one_timetag(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *engine = NULL;
    if (ds_engine_new(&cfg, &engine).status != DS_OK || !engine) {
        fprintf(stderr, "FAIL: engine_new\n"); g_fails++; return;
    }

    const ds_schema_t *src_ds = NULL, *out_ds = NULL;
    const ds_rete_schema_t *src_rs = NULL, *out_rs = NULL;
    if (reg_schema(engine, "Src", &src_ds, &src_rs)) { g_fails++; goto done; }
    if (reg_schema(engine, "Out", &out_ds, &out_rs)) { g_fails++; goto done; }

    ds_rete_slot_assign_t assign = { .slot_index = 0, .expr = var_ref(0, 0) };
    ds_rete_action_t copy_action = {
        .kind = DS_RETE_ACTION_ASSERT, .schema_id = out_rs->id,
        .assigns = &assign, .assign_count = 1
    };
    ds_alfa_atom_t alfas[1] = {{ .node_id = 1, .schema_name = "Src" }};
    ds_beta_atom_t betas[1] = {
        { .node_id = 2, .right_alpha_id = 1, .left_parent_id = 0 },
    };
    ds_term_atom_t terms[1] = {
        { .node_id = 3, .parent_beta_id = 2, .rule_name = "cool_rule",
          .actions = &copy_action, .action_count = 1 },
    };
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 1,
                              .betas = betas, .beta_count = 1,
                              .terms = terms, .term_count = 1 };
    if (ds_rete_load_network(engine->rete_engine, &net).status != DS_OK) {
        fprintf(stderr, "FAIL: load_network\n");
        ds_rete_expr_free_tree(assign.expr);
        g_fails++; goto done;
    }
    if (set_cooldown(engine, "cool_rule")) {
        fprintf(stderr, "FAIL: set_cooldown\n"); g_fails++; goto done;
    }

    trace_t t = {0};
    CHECK(ds_engine_set_stream_callback(engine, trace_cb, &t).status == DS_OK,
          "attach stream");

    ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = 7 };
    ds_fact_t *f = NULL;
    CHECK(ds_engine_assert(engine, src_ds, &sv, 1, &f).status == DS_OK,
          "assert Src");
    CHECK(ds_engine_pump(engine).status == DS_OK, "pump");

    const int lhs   = only(&t, DS_EV_RULE_LHS_FACTS);
    const int begin = only(&t, DS_EV_RULE_FIRE_BEGIN);
    const int end   = only(&t, DS_EV_RULE_FIRE_END);
    const int armed = only(&t, DS_EV_TIMER_ARMED);
    CHECK(lhs >= 0,   "exactly one RULE_LHS_FACTS -- premise");
    CHECK(begin >= 0, "exactly one RULE_FIRE_BEGIN -- premise");
    CHECK(end >= 0,   "exactly one RULE_FIRE_END -- premise");
    CHECK(armed >= 0, "exactly one TIMER_ARMED -- premise (the cooldown armed)");
    if (lhs < 0 || begin < 0 || end < 0 || armed < 0) goto done;

    CHECK(lhs + 1 == begin, "RULE_LHS_FACTS immediately precedes the begin");
    CHECK(armed > end, "TIMER_ARMED follows the end");

    const int64_t tt = t.timetag[begin];
    CHECK(tt != 0, "the firing's timetag is not 0 off the AOT path");
    CHECK(t.timetag[lhs] == tt,
          "RULE_LHS_FACTS carries the firing's timetag ([NCBK.2.12])");
    CHECK(t.timetag[end] == tt, "RULE_FIRE_END carries the same timetag");
    CHECK(t.timetag[armed] == tt,
          "TIMER_ARMED carries the arming firing's timetag ([NCBK.2.12])");

done:
    if (engine) ds_engine_free(engine);
}

int main(void)
{
    printf("=== test_ncbk_2_12_firing_timetag ===\n");
    test_one_firing_one_timetag();
    if (g_fails) {
        fprintf(stderr, "test_ncbk_2_12_firing_timetag: %d FAILURE(S)\n",
                g_fails);
        return 1;
    }
    printf("=== test_ncbk_2_12_firing_timetag: ALL PASSED ===\n");
    return 0;
}
