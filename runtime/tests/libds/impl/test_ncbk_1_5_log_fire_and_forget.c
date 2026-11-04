/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * [NCBK.1.5]: the log callback is fire-and-forget. One that returns an error
 * during a pump leaves the pump DS_OK, and every firing still runs: two rules
 * on each of two `Src` facts, one logging through the failing callback, the
 * other asserting an `Out`.
 *
 * The status is dropped in `ds_telemetry_emit_log`, which every log line
 * passes; test_dispatcher_log.c's `test_cb_error_is_dropped` pins the same
 * drop on the AOT entry point.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "builtin_fn.h"
#include "engine.h"
#include "rete/action.h"
#include "rete/beta.h"
#include "rete/engine.h"
#include "rete/expr.h"
#include "rete/intern.h"
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

static int g_log_calls;

static ds_result_t failing_log_cb(ds_engine_t          *engine,
                                  const ds_log_event_t *event,
                                  void                 *user)
{
    (void) engine; (void) event; (void) user;
    g_log_calls++;
    return DS_ERR_R(DS_ERR_IO, "the integrator's log sink is down");
}

#define MAX_EV 128
typedef struct {
    int n;
    int kind[MAX_EV];
} trace_t;

static ds_result_t trace_cb(ds_engine_t *e, const ds_stream_ev_t *ev, void *user)
{
    (void) e;
    trace_t *t = (trace_t *) user;
    if (t->n < MAX_EV) t->kind[t->n++] = (int) ev->kind;
    return DS_OK_R;
}

static int count_of(const trace_t *t, int kind)
{
    int n = 0;
    for (int i = 0; i < t->n; i++) if (t->kind[i] == kind) n++;
    return n;
}

static const char *istr(ds_engine_t *engine, const char *s)
{
    const char *p = NULL;
    ds_rete_intern_cstr(engine->rete_engine->intern, s, &p);
    return p;
}

static ds_rete_expr_t *lit_int(int64_t i)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_INT);
    e->lit_int = i; return e;
}

static ds_rete_expr_t *lit_str(ds_engine_t *engine, const char *s)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_STR);
    e->lit_str = istr(engine, s); return e;
}

static ds_rete_expr_t *var_ref(uint16_t pat, uint16_t slot)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
    e->var.pattern_index = pat; e->var.slot_index = slot; return e;
}

/* (ds-log <level> <category> <message>) -- adapter_ds_log's argument order. */
static ds_rete_expr_t *log_call(ds_engine_t *engine)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_CALL);
    e->call.op = DS_FN_LOG;
    e->call.args = calloc(3, sizeof(*e->call.args));
    e->call.args[0] = lit_int(DS_LOG_ERROR);
    e->call.args[1] = lit_str(engine, "log_rule");
    e->call.args[2] = lit_str(engine, "a line nobody can receive");
    e->call.arg_count = 3;
    return e;
}

static int reg_schema(ds_engine_t *engine, const char *name, bool identity,
                      const ds_schema_t **out_ds,
                      const ds_rete_schema_t **out_rs)
{
    ds_slot_desc_t sd = { .name = "val", .type = DS_SLOT_TYPE_INT,
                          .identity_role = identity ? DS_IDENTITY_KEY
                                                    : DS_IDENTITY_MUTABLE };
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

static void test_failing_log_callback_leaves_the_pump_ok(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *engine = NULL;
    if (ds_engine_new(&cfg, &engine).status != DS_OK || !engine) {
        fprintf(stderr, "FAIL: engine_new\n"); g_fails++; return;
    }

    const ds_schema_t *src_ds = NULL, *out_ds = NULL;
    const ds_rete_schema_t *src_rs = NULL, *out_rs = NULL;
    /* Keyed, so the two asserts below are two facts. */
    if (reg_schema(engine, "Src", true,  &src_ds, &src_rs)) { g_fails++; goto done; }
    if (reg_schema(engine, "Out", true,  &out_ds, &out_rs)) { g_fails++; goto done; }

    ds_rete_action_t log_action = {
        .kind = DS_RETE_ACTION_CALL, .expr = log_call(engine)
    };
    ds_rete_slot_assign_t assign = { .slot_index = 0, .expr = var_ref(0, 0) };
    ds_rete_action_t copy_action = {
        .kind = DS_RETE_ACTION_ASSERT, .schema_id = out_rs->id,
        .assigns = &assign, .assign_count = 1
    };

    ds_alfa_atom_t alfas[1] = {{ .node_id = 1, .schema_name = "Src" }};
    ds_beta_atom_t betas[2] = {
        { .node_id = 2, .right_alpha_id = 1, .left_parent_id = 0 },
        { .node_id = 4, .right_alpha_id = 1, .left_parent_id = 0 },
    };
    ds_term_atom_t terms[2] = {
        { .node_id = 3, .parent_beta_id = 2, .rule_name = "log_rule",
          .actions = &log_action, .action_count = 1 },
        { .node_id = 5, .parent_beta_id = 4, .rule_name = "copy_rule",
          .actions = &copy_action, .action_count = 1 },
    };
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 1,
                              .betas = betas, .beta_count = 2,
                              .terms = terms, .term_count = 2 };
    if (ds_rete_load_network(engine->rete_engine, &net).status != DS_OK) {
        fprintf(stderr, "FAIL: load_network\n");
        ds_rete_expr_free_tree(log_action.expr);
        ds_rete_expr_free_tree(assign.expr);
        g_fails++; goto done;
    }

    g_log_calls = 0;
    CHECK(ds_engine_set_log_callback(engine, failing_log_cb, NULL).status
              == DS_OK, "attach the failing log callback");
    trace_t t = {0};
    CHECK(ds_engine_set_stream_callback(engine, trace_cb, &t).status == DS_OK,
          "attach stream");

    for (int64_t v = 1; v <= 2; v++) {
        ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = v };
        ds_fact_t *f = NULL;
        CHECK(ds_engine_assert(engine, src_ds, &sv, 1, &f).status == DS_OK,
              "assert Src");
    }

    ds_result_t r = ds_engine_pump(engine);
    CHECK(r.status == DS_OK,
          "a failing log callback leaves the pump DS_OK ([NCBK.1.5])");

    CHECK(g_log_calls == 2, "the log callback ran for both log firings");
    CHECK(count_of(&t, DS_EV_RULE_FIRE_BEGIN) == 4, "four firings began");
    CHECK(count_of(&t, DS_EV_RULE_FIRE_END) == 4, "and all four ended");
    CHECK(count_of(&t, DS_EV_ACTION_EMIT) == 2,
          "the copy rule's two asserts both happened");

done:
    if (engine) ds_engine_free(engine);
}

int main(void)
{
    printf("=== test_ncbk_1_5_log_fire_and_forget ===\n");
    test_failing_log_callback_leaves_the_pump_ok();
    if (g_fails) {
        fprintf(stderr, "test_ncbk_1_5_log_fire_and_forget: %d FAILURE(S)\n",
                g_fails);
        return 1;
    }
    printf("=== test_ncbk_1_5_log_fire_and_forget: ALL PASSED ===\n");
    return 0;
}
