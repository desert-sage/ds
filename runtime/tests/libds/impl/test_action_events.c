/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * test_action_events — the SHARED impl target ([IDSP.3.6] / [4.7] / [5.7] /
 * [8.8] each name it).
 *
 * WHERE an action event lands in the stream relative to the rule firing that
 * caused it. Ordering needs a real firing, so this file builds a Rete network
 * directly into engine->rete_engine and pumps, as
 * test_engine_rete_integration.c does.
 *
 * `emit Out` lowers to ACTION_ASSERT, so a rule-RHS assert is the emit verb:
 * firing one runs emit_cb (FACT_ASSERT) and then emit_action_cb
 * (ACTION_EMIT), the pair [IDSP.3.6] orders.
 *
 * [IDSP.4.7]'s publish goes through the ds_publish CALL handler, not this
 * path; spec/test_publish_spec drives it through a compiled .dsc.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "dispatcher.h"
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

/* ---- the stream, recorded in arrival order --------------------------- */

#define MAX_EV 64
typedef struct {
    int      n;
    int      kind[MAX_EV];
    uint64_t seq[MAX_EV];
} trace_t;

static ds_result_t trace_cb(ds_engine_t *e, const ds_stream_ev_t *ev, void *user)
{
    (void) e;
    trace_t *t = (trace_t *) user;
    if (t->n < MAX_EV) {
        t->kind[t->n] = (int) ev->kind;
        t->seq[t->n]  = ev->seq;
        t->n++;
    }
    return DS_OK_R;
}

/* Index of the first event of `kind`, or -1. */
static int first_of(const trace_t *t, int kind)
{
    for (int i = 0; i < t->n; i++) if (t->kind[i] == kind) return i;
    return -1;
}
static int count_of(const trace_t *t, int kind)
{
    int n = 0;
    for (int i = 0; i < t->n; i++) if (t->kind[i] == kind) n++;
    return n;
}

/* ---- an ASSERT action, bracketed by RULE_FIRE_BEGIN/END -------------- */

static ds_rete_expr_t *var_ref(uint16_t pat, uint16_t slot)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
    e->var.pattern_index = pat; e->var.slot_index = slot; return e;
}

static int reg_schema(ds_engine_t *engine, const char *name, bool identity,
                      const ds_schema_t **out_ds,
                      const ds_rete_schema_t **out_rs)
{
    ds_slot_desc_t sd = { .name = "val", .type = DS_SLOT_TYPE_INT,
                          .identity_role = identity ? DS_IDENTITY_KEY
                                                    : DS_IDENTITY_MUTABLE };
    ds_result_t r = ds_engine_register_schema(engine, name,
                                              DS_SCHEMA_LIFECYCLE_LOGICAL,
                                              0, &sd, 1, out_ds);
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: register_schema %s: %d\n", name, r.status);
        return 1;
    }
    *out_rs = ds_rete_schema_by_name(engine->rete_engine, name);
    if (*out_rs == NULL) {
        fprintf(stderr, "FAIL: rete schema lookup %s\n", name);
        return 1;
    }
    return 0;
}

static void test_assert_action_is_bracketed(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *engine = NULL;
    if (ds_engine_new(&cfg, &engine).status != DS_OK || !engine) {
        fprintf(stderr, "FAIL: engine_new\n"); g_fails++; return;
    }

    const ds_schema_t *src_ds = NULL, *out_ds = NULL;
    const ds_rete_schema_t *src_rs = NULL, *out_rs = NULL;
    if (reg_schema(engine, "Src", false, &src_ds, &src_rs)) { g_fails++; goto done; }
    if (reg_schema(engine, "Out", true,  &out_ds, &out_rs)) { g_fails++; goto done; }

    ds_rete_expr_t *val = var_ref(0, 0);
    ds_rete_slot_assign_t assign = { .slot_index = 0, .expr = val };
    ds_rete_action_t action = {
        .kind = DS_RETE_ACTION_ASSERT, .schema_id = out_rs->id,
        .assigns = &assign, .assign_count = 1
    };
    ds_alfa_atom_t alfas[1] = {{ .node_id = 1, .schema_name = "Src" }};
    ds_beta_atom_t betas[1] = {{ .node_id = 2, .right_alpha_id = 1,
                                 .left_parent_id = 0 }};
    ds_term_atom_t terms[1] = {{ .node_id = 3, .parent_beta_id = 2,
                                 .rule_name = "copy_rule",
                                 .actions = &action, .action_count = 1 }};
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 1,
                              .betas = betas, .beta_count = 1,
                              .terms = terms, .term_count = 1 };
    if (ds_rete_load_network(engine->rete_engine, &net).status != DS_OK) {
        fprintf(stderr, "FAIL: load_network\n");
        ds_rete_expr_free_tree(val);
        g_fails++; goto done;
    }

    /* Attach the trace AFTER loading, so the network's own construction does
       not appear in it — the subject is the firing, not the load. */
    trace_t t = {0};
    CHECK(ds_engine_set_stream_callback(engine, trace_cb, &t).status == DS_OK,
          "attach stream");

    ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = 7 };
    ds_fact_t *src_fact = NULL;
    CHECK(ds_engine_assert(engine, src_ds, &sv, 1, &src_fact).status == DS_OK,
          "assert Src(7)");
    CHECK(ds_engine_pump(engine).status == DS_OK, "pump");

    int rfb = first_of(&t, DS_EV_RULE_FIRE_BEGIN);
    int rfe = first_of(&t, DS_EV_RULE_FIRE_END);
    CHECK(rfb >= 0, "RULE_FIRE_BEGIN was emitted");
    CHECK(rfe >= 0, "RULE_FIRE_END was emitted");

    /* The bracket. The rule's own ASSERT produces a FACT_ASSERT, and it must
       land INSIDE the firing that caused it — that containment is what lets a
       stream consumer attribute an effect to a rule at all. The INPUT fact's
       FACT_ASSERT comes from ds_engine_assert before the pump, so the search
       for the rule's one starts after RULE_FIRE_BEGIN. */
    int inner_assert = -1;
    for (int i = rfb + 1; i >= 0 && i < t.n; i++) {
        if (t.kind[i] == DS_EV_FACT_ASSERT) { inner_assert = i; break; }
    }
    CHECK(inner_assert > rfb, "the rule's FACT_ASSERT follows RULE_FIRE_BEGIN");
    CHECK(rfe > inner_assert, "and precedes RULE_FIRE_END");

    /* seq is per-engine monotonic, so the ordering above is not an artefact of
       callback delivery order. */
    int monotonic = 1;
    for (int i = 1; i < t.n; i++) if (t.seq[i] <= t.seq[i - 1]) monotonic = 0;
    CHECK(monotonic, "stream seq is strictly increasing");

    /* [IDSP.3.6] — the ACTION_EMIT marker follows the FACT_ASSERT it names,
       so a consumer seeing it can resolve the fact. */
    int emit_marker = first_of(&t, DS_EV_ACTION_EMIT);
    CHECK(emit_marker > 0, "a rule-RHS assert emits ACTION_EMIT");
    CHECK(inner_assert >= 0 && emit_marker > inner_assert,
          "ACTION_EMIT follows the FACT_ASSERT it refers to");
    CHECK(rfe > emit_marker, "and both sit inside the firing bracket");

    /* PUBLISH goes through the ds_publish CALL handler, not this path
       ([IDSP.4.5]). */
    CHECK(count_of(&t, DS_EV_ACTION_PUBLISH) == 0,
          "an assert does not masquerade as a publish");

done:
    if (engine) ds_engine_free(engine);
}

/* ---- direct dispatcher action events share the same seq space -------- */

static void test_dispatcher_events_are_sequenced(void)
{
    /* One engine, three verbs, one increasing sequence. */
    ds_engine_t *engine = NULL;
    if (ds_engine_new(NULL, &engine).status != DS_OK || !engine) {
        fprintf(stderr, "FAIL: engine_new\n"); g_fails++; return;
    }

    trace_t t = {0};
    CHECK(ds_engine_set_stream_callback(engine, trace_cb, &t).status == DS_OK,
          "attach stream");

    CHECK(ds_dispatcher_cache_set(engine, "k", "{\"v\":1}", 0).status == DS_OK,
          "cache_set");
    CHECK(ds_dispatcher_log(engine, DS_LOG_INFO, "r", "third").status == DS_OK,
          "log");
    CHECK(ds_dispatcher_cache_delete(engine, "k").status == DS_OK, "cache_delete");

    int s = first_of(&t, DS_EV_ACTION_CACHE_SET);
    int l = first_of(&t, DS_EV_ACTION_LOG);
    int d = first_of(&t, DS_EV_ACTION_CACHE_DELETE);
    CHECK(s >= 0 && l >= 0 && d >= 0, "all three events were emitted");
    CHECK(s < l && l < d, "in call order");

    int monotonic = 1;
    for (int i = 1; i < t.n; i++) if (t.seq[i] <= t.seq[i - 1]) monotonic = 0;
    CHECK(monotonic, "with strictly increasing seq");

    ds_engine_free(engine);
}

int main(void)
{
    printf("=== test_action_events ===\n");
    test_assert_action_is_bracketed();
    test_dispatcher_events_are_sequenced();
    if (g_fails) {
        fprintf(stderr, "test_action_events: %d FAILURE(S)\n", g_fails);
        return 1;
    }
    printf("=== test_action_events: ALL PASSED ===\n");
    return 0;
}
