/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [IRET.12.2] [LLOG.15.1]
 * A match that ends inside its own firing justifies nothing after:
 *   hold: Keep k -> emit L logical v: 1
 *   end:  Trig t -> withdraw t; emit L logical v: 2; emit L logical v: 1
 * After `withdraw t`, L(2) has no justification and is retracted as it is
 * made; L(1) stays on `hold`'s, and goes when Keep does, so the ended
 * activation added none. The Mercury runtime is held to the same shape by the
 * lockstep pair 117_self_ending_match.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
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

static const ds_schema_t *g_l = NULL;

/* The live L facts: how many, and whether L(1) and L(2) are among them. */
typedef struct { int count; bool one; bool two; } l_view_t;

static ds_result_t visit_l(const ds_fact_t *f, void *user)
{
    l_view_t *v = (l_view_t *)user;
    ds_slot_value_t sv;
    v->count++;
    if (ds_fact_get_slot(f, 0, NULL, &sv).status == DS_OK
            && sv.kind == DS_SLOT_INT) {
        if (sv.v.i == 1) v->one = true;
        if (sv.v.i == 2) v->two = true;
    }
    return DS_OK_R;
}

static l_view_t live_l(ds_engine_t *e)
{
    l_view_t v = { 0, false, false };
    CHECK_OK(ds_engine_for_each_fact(e, g_l, visit_l, &v), "for_each L");
    return v;
}

static ds_rete_expr_t *lit_int(int64_t i)
{
    ds_rete_expr_t *x = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_INT);
    x->lit_int = i;
    return x;
}

static const ds_schema_t *reg(ds_engine_t *e, const char *name,
                              ds_schema_lifecycle_t lc, ds_identity_role_t role)
{
    ds_slot_desc_t sd = { .name = "v", .type = DS_SLOT_TYPE_INT,
                          .identity_role = role };
    const ds_schema_t *s = NULL;
    CHECK_OK(ds_engine_register_schema(e, name, lc, 0, &sd, 1, &s), name);
    return s;
}

int main(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK) {
        fprintf(stderr, "FAIL: engine_new\n"); return 1;
    }
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "mock clock");
    CHECK_OK(ds_engine_clock_set(e, 0), "clock 0");

    const ds_schema_t *keep = reg(e, "Keep", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                  DS_IDENTITY_KEY);
    const ds_schema_t *trig = reg(e, "Trig", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                  DS_IDENTITY_KEY);
    g_l = reg(e, "L", DS_SCHEMA_LIFECYCLE_LOGICAL, DS_IDENTITY_KEY);
    const ds_rete_schema_t *l_rs = ds_rete_schema_by_name(e->rete_engine, "L");
    if (keep == NULL || trig == NULL || g_l == NULL || l_rs == NULL) {
        fprintf(stderr, "FAIL: schemas\n"); ds_engine_free(e); return 1;
    }

    /* `hold: Keep k -> emit L logical v: 1` */
    ds_rete_slot_assign_t hold_v1[1] = {{ .slot_index = 0, .expr = lit_int(1) }};
    ds_rete_action_t hold_actions[1] = {
        { .kind = DS_RETE_ACTION_LOGICAL_ASSERT, .schema_id = l_rs->id,
          .assigns = hold_v1, .assign_count = 1 },
    };
    /* `end: Trig t -> withdraw t; emit L logical v: 2; emit L logical v: 1` */
    ds_rete_slot_assign_t end_v2[1] = {{ .slot_index = 0, .expr = lit_int(2) }};
    ds_rete_slot_assign_t end_v1[1] = {{ .slot_index = 0, .expr = lit_int(1) }};
    ds_rete_action_t end_actions[3] = {
        { .kind = DS_RETE_ACTION_WITHDRAW, .withdraw_pattern_index = 0 },
        { .kind = DS_RETE_ACTION_LOGICAL_ASSERT, .schema_id = l_rs->id,
          .assigns = end_v2, .assign_count = 1 },
        { .kind = DS_RETE_ACTION_LOGICAL_ASSERT, .schema_id = l_rs->id,
          .assigns = end_v1, .assign_count = 1 },
    };
    ds_alfa_atom_t alfas[2] = {
        { .node_id = 1, .schema_name = "Keep" },
        { .node_id = 4, .schema_name = "Trig" },
    };
    ds_beta_atom_t betas[2] = {
        { .node_id = 2, .right_alpha_id = 1, .left_parent_id = 0 },
        { .node_id = 5, .right_alpha_id = 4, .left_parent_id = 0 },
    };
    ds_term_atom_t terms[2] = {
        { .node_id = 3, .parent_beta_id = 2, .rule_name = "hold",
          .actions = hold_actions, .action_count = 1 },
        { .node_id = 6, .parent_beta_id = 5, .rule_name = "end",
          .actions = end_actions, .action_count = 3 },
    };
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 2,
                              .betas = betas, .beta_count = 2,
                              .terms = terms, .term_count = 2 };
    if (ds_rete_load_network(e->rete_engine, &net).status != DS_OK) {
        fprintf(stderr, "FAIL: load network\n");
        ds_engine_free(e);
        return 1;
    }

    /* Pump 1: Keep(1) fires `hold`, which derives L(1). */
    ds_slot_value_t one = { .kind = DS_SLOT_INT, .v.i = 1 };
    ds_fact_t *k1 = NULL;
    CHECK_OK(ds_engine_assert(e, keep, &one, 1, &k1), "assert Keep(1)");
    CHECK_OK(ds_engine_pump(e), "pump 1");
    l_view_t p1 = live_l(e);
    CHECK(p1.count == 1 && p1.one, "premise: `hold` derives L(1)");

    /* Pump 2: Trig(1) fires `end`, whose `withdraw t` ends its own match. */
    CHECK_OK(ds_engine_clock_advance(e, 1000), "advance");
    CHECK_OK(ds_engine_assert(e, trig, &one, 1, NULL), "assert Trig(1)");
    CHECK_OK(ds_engine_pump(e), "pump 2");
    l_view_t p2 = live_l(e);
    printf("  pump 2: %d live L, L(1) %s, L(2) %s\n", p2.count,
           p2.one ? "live" : "gone", p2.two ? "live" : "gone");
    CHECK(!p2.two,
          "L(2), made after `end`'s match ended and justified by nothing "
          "else, is retracted as it is made ([IRET.12.2])");
    CHECK(p2.one,
          "L(1), which `hold`'s live activation justifies, stays ([IRET.12.2]: "
          "\"unless another live justification already holds it\")");

    /* Pump 3: retracting Keep(1) ends `hold`, L(1)'s only justification. */
    CHECK_OK(ds_engine_clock_advance(e, 1000), "advance");
    if (k1 != NULL) CHECK_OK(ds_engine_retract(e, k1), "retract Keep(1)");
    CHECK_OK(ds_engine_pump(e), "pump 3");
    l_view_t p3 = live_l(e);
    CHECK(p3.count == 0,
          "L(1) goes with `hold`: the ended activation entered no second "
          "justification for it ([IRET.12.2])");
    size_t n = (size_t)-1;
    CHECK_OK(ds_engine_fact_count(e, &n), "fact_count");
    CHECK(n == 0, "nothing is left live: no orphan");

    ds_engine_free(e);
    if (failures) {
        fprintf(stderr, "test_iret_12_2_self_ending_match: %d failure(s)\n",
                failures);
        return 1;
    }
    printf("test_iret_12_2_self_ending_match: OK\n");
    return 0;
}
