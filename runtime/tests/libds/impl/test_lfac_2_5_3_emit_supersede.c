/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [LFAC.2.5.3] [RFCS.6a.4]
 * A rule's emit that gives a live keyed fact a new value replaces it, visibly
 * ([LFAC.1.7.2], [LFAC.2.5.3]): `Seed s -> emit Made logical id: 1 n: s.n`
 * with two Seeds live. The second firing leaves one live Made, with the new
 * payload under a new fact_id, and records the new fact's FACT_ASSERT before
 * the old one's FACT_RETRACT, as a host upsert does (RFCS.6a.4). A supersede
 * whose successor is never wrapped still records the old FACT_RETRACT, through
 * ds_rete_wm_settle_supersede.
 *
 * What becomes of the old fact's justification is [LLOG.2.7.5]'s, held in
 * both runtimes by the lockstep pair 124/91_emit_supersede.
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
#include "rete/val.h"
#include "rete/wm_rete.h"

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

/* The Made events of one pump, in stream order. */
#define MAX_EV 16
static const ds_schema_t *g_made = NULL;
static ds_stream_ev_kind_t g_kind[MAX_EV];
static uint64_t            g_id[MAX_EV];
static int                 g_n = 0;

static ds_result_t on_event(ds_engine_t *e, const ds_stream_ev_t *ev, void *u)
{
    (void)e; (void)u;
    const ds_fact_t *f = NULL;
    if (ev->kind == DS_EV_FACT_ASSERT)       f = ev->p.fact_assert.fact;
    else if (ev->kind == DS_EV_FACT_RETRACT) f = ev->p.fact_retract.fact;
    if (f == NULL || g_n >= MAX_EV) return DS_OK_R;
    const ds_schema_t *sc = NULL;
    if (ds_fact_get_schema(f, &sc).status != DS_OK || sc != g_made)
        return DS_OK_R;
    g_kind[g_n] = ev->kind;
    (void)ds_fact_get_id(f, &g_id[g_n]);
    g_n++;
    return DS_OK_R;
}

/* The live Made facts: how many, and the last one's id and `n`. */
typedef struct { int count; uint64_t id; int64_t n; } made_view_t;

static ds_result_t visit_made(const ds_fact_t *f, void *user)
{
    made_view_t *v = (made_view_t *)user;
    ds_slot_value_t sv;
    v->count++;
    (void)ds_fact_get_id(f, &v->id);
    if (ds_fact_get_slot(f, 1, NULL, &sv).status == DS_OK
            && sv.kind == DS_SLOT_INT)
        v->n = sv.v.i;
    return DS_OK_R;
}

static made_view_t live_made(ds_engine_t *e)
{
    made_view_t v = { 0, 0, -1 };
    CHECK_OK(ds_engine_for_each_fact(e, g_made, visit_made, &v), "for_each Made");
    return v;
}

static ds_rete_expr_t *var(uint16_t pat, uint16_t slot)
{
    ds_rete_expr_t *x = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
    x->var.pattern_index = pat;
    x->var.slot_index    = slot;
    return x;
}

static ds_rete_expr_t *lit_int(int64_t i)
{
    ds_rete_expr_t *x = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_INT);
    x->lit_int = i;
    return x;
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

    /* Seed: keyed on n, so two Seeds coexist. Made: keyed on id, n mutable. */
    ds_slot_desc_t seed_sd = { .name = "n", .type = DS_SLOT_TYPE_INT,
                               .identity_role = DS_IDENTITY_KEY };
    const ds_schema_t *seed = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Seed", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                       0, &seed_sd, 1, &seed), "reg Seed");
    ds_slot_desc_t made_sd[2] = {
        { .name = "id", .type = DS_SLOT_TYPE_INT,
          .identity_role = DS_IDENTITY_KEY },
        { .name = "n",  .type = DS_SLOT_TYPE_INT,
          .identity_role = DS_IDENTITY_MUTABLE },
    };
    CHECK_OK(ds_engine_register_schema(e, "Made", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                       0, made_sd, 2, &g_made), "reg Made");
    const ds_rete_schema_t *made_rs =
        ds_rete_schema_by_name(e->rete_engine, "Made");
    if (seed == NULL || g_made == NULL || made_rs == NULL) {
        fprintf(stderr, "FAIL: schemas\n"); ds_engine_free(e); return 1;
    }

    /* `rule make: Seed s -> emit Made logical id: 1 n: s.n` */
    ds_rete_expr_t *id_x = lit_int(1);
    ds_rete_expr_t *n_x  = var(0, 0);
    ds_rete_slot_assign_t assigns[2] = {
        { .slot_index = 0, .expr = id_x },
        { .slot_index = 1, .expr = n_x },
    };
    ds_rete_action_t action = { .kind = DS_RETE_ACTION_LOGICAL_ASSERT,
                                .schema_id = made_rs->id,
                                .assigns = assigns, .assign_count = 2 };
    ds_alfa_atom_t alfas[1] = {{ .node_id = 1, .schema_name = "Seed" }};
    ds_beta_atom_t betas[1] = {{ .node_id = 2, .right_alpha_id = 1,
                                 .left_parent_id = 0 }};
    ds_term_atom_t terms[1] = {{ .node_id = 3, .parent_beta_id = 2,
                                 .rule_name = "make",
                                 .actions = &action, .action_count = 1 }};
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 1,
                              .betas = betas, .beta_count = 1,
                              .terms = terms, .term_count = 1 };
    if (ds_rete_load_network(e->rete_engine, &net).status != DS_OK) {
        fprintf(stderr, "FAIL: load network\n");
        ds_rete_expr_free_tree(id_x);
        ds_rete_expr_free_tree(n_x);
        ds_engine_free(e);
        return 1;
    }
    CHECK_OK(ds_engine_set_stream_callback(e, on_event, NULL), "stream cb");

    /* Pump 1: Seed(4) derives Made(1, 4). */
    ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = 4 };
    ds_fact_t *s4 = NULL;
    CHECK_OK(ds_engine_assert(e, seed, &sv, 1, &s4), "assert Seed(4)");
    CHECK_OK(ds_engine_pump(e), "pump 1");
    made_view_t first = live_made(e);
    CHECK(first.count == 1 && first.n == 4,
          "premise: pump 1 derives one Made(1, 4)");

    /* Pump 2: Seed(5), with Seed(4) still live, derives Made(1, 5). */
    g_n = 0;
    CHECK_OK(ds_engine_clock_advance(e, 1000), "advance");
    sv.v.i = 5;
    ds_fact_t *s5 = NULL;
    CHECK_OK(ds_engine_assert(e, seed, &sv, 1, &s5), "assert Seed(5)");
    CHECK_OK(ds_engine_pump(e), "pump 2");

    made_view_t second = live_made(e);
    printf("  pump 2: %d live Made, n=%lld, id %llu -> %llu; %d Made event(s)\n",
           second.count, (long long)second.n,
           (unsigned long long)first.id, (unsigned long long)second.id, g_n);
    CHECK(second.count == 1,
          "exactly one live Made: the later emit supersedes ([LFAC.1.7.2])");
    CHECK(second.n == 5,
          "the live Made holds the NEW payload, n = 5 ([LFAC.1.7.2])");
    CHECK(second.id != first.id,
          "a meaningful change mints a fresh fact_id ([LFAC.2.5.3])");
    CHECK(g_n == 2, "two Made events in pump 2: the assert and the retract");
    if (g_n == 2) {
        CHECK(g_kind[0] == DS_EV_FACT_ASSERT && g_id[0] == second.id,
              "FACT_ASSERT of the new Made first ([LFAC.2.5.3], RFCS.6a.4)");
        CHECK(g_kind[1] == DS_EV_FACT_RETRACT && g_id[1] == first.id,
              "then FACT_RETRACT of the old Made ([LFAC.2.5.3], RFCS.6a.4)");
    }

    /* A supersede whose successor is never wrapped: a caller that fails
       before its emit_cb settles the pending pair instead. At the rete door,
       the assert replaces Made(1, 5) and nothing wraps Made(1, 9); the old
       fact's FACT_RETRACT must be recorded and its wrapper gone. */
    g_n = 0;
    ds_rete_val_t up[2] = { ds_rete_val_int(1), ds_rete_val_int(9) };
    ds_rete_fact_t *nine = NULL;
    CHECK_OK(ds_rete_wm_assert(e->rete_engine, made_rs->id, up, &nine),
             "rete assert Made(1, 9)");
    ds_rete_wm_settle_supersede(e->rete_engine);
    made_view_t third = live_made(e);
    CHECK(g_n == 1 && g_kind[0] == DS_EV_FACT_RETRACT && g_id[0] == second.id,
          "the settled supersede records FACT_RETRACT of the old Made "
          "(RFCS.6a.4)");
    CHECK(third.count == 0,
          "and the old Made's wrapper is gone, not left on a freed fact");

    CHECK_OK(ds_engine_set_stream_callback(e, NULL, NULL), "stream cb off");
    ds_engine_free(e);
    if (failures) {
        fprintf(stderr, "test_lfac_2_5_3_emit_supersede: %d failure(s)\n",
                failures);
        return 1;
    }
    printf("test_lfac_2_5_3_emit_supersede: OK\n");
    return 0;
}
