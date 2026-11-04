/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * test_engine_rete_integration — end-to-end smoke test for the native
 * Rete backend wired through the public ds_engine_* API.
 *
 * Tests: ds_engine_new + ds_engine_assert + ds_engine_pump
 *        + ds_engine_retract, driven through the DSC integration path:
 *
 *  1. Create an engine; its rule-evaluation substrate is Rete.
 *  2. Register schemas and a network directly into engine->rete_engine
 *     (stand-in for DSC loading, which is the full integration path).
 *  3. Assert a fact via ds_engine_assert.
 *  4. Pump via ds_engine_pump — rule should fire.
 *  5. Verify the output fact exists in the Rete WM.
 *  6. Retract the input fact via ds_engine_retract.
 *  7. Verify the input fact is gone from the Rete WM.
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
#include "rete/wm_rete.h"

#define WM_TOMB ((ds_rete_fact_t *)(uintptr_t)1)

static int fail_msg(const char *msg)
{
    fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

static int expect_ok(const char *what, ds_result_t r)
{
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: %s: status=%d (%s)\n",
                what, r.status, r.detail ? r.detail : "");
        return 1;
    }
    return 0;
}

static int count_rete_facts(ds_rete_engine_t *re,
                             const ds_rete_schema_t *schema,
                             int64_t val)
{
    int n = 0;
    for (uint32_t i = 0; i < oa_len(&re->wm_map); i++) {
        ds_rete_fact_t *f = *(ds_rete_fact_t **)ds_oa_val_at(&re->wm_map, i);
        if (!f) continue;
        if (f->schema == schema && f->slots[0].i == val) n++;
    }
    return n;
}

/* Helper: register a DS schema and a matching Rete schema. */
static int setup_schemas(ds_engine_t *engine,
                          const char *name,
                          ds_slot_type_t slot_type,
                          ds_rete_val_kind_t rete_kind,
                          bool is_identity,
                          const ds_schema_t **out_ds,
                          const ds_rete_schema_t **out_rete)
{
    /* [LFAC.1.7]: a logical slot is KEY or MUTABLE. Registering also
       registers the schema into the Rete engine (DS_SLOT_TYPE_INT ->
       DS_RETE_VAL_INT). */
    (void)rete_kind;
    ds_slot_desc_t sd = { .name = "val", .type = slot_type,
                          .identity_role = is_identity ? DS_IDENTITY_KEY
                                                       : DS_IDENTITY_MUTABLE };
    ds_result_t r = ds_engine_register_schema(engine, name,
                                               DS_SCHEMA_LIFECYCLE_LOGICAL,
                                               0, &sd, 1, out_ds);
    if (r.status != DS_OK) { fprintf(stderr, "FAIL: DS schema reg %s: %d\n", name, r.status); return 1; }

    /* Fetch the Rete-side handle that register_schema just created. */
    const ds_rete_schema_t *rs = ds_rete_schema_by_name(engine->rete_engine, name);
    if (rs == NULL) { fprintf(stderr, "FAIL: Rete schema lookup %s\n", name); return 1; }
    *out_rete = rs;
    return 0;
}

static ds_rete_expr_t *lit_int(int64_t v)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_INT);
    e->lit_int = v; return e;
}
static ds_rete_expr_t *var(uint16_t pat, uint16_t slot)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
    e->var.pattern_index = pat; e->var.slot_index = slot; return e;
}
static ds_rete_expr_t *binop(ds_rete_binop_t op,
                              ds_rete_expr_t *l, ds_rete_expr_t *r)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_BINOP);
    e->binop.op = op; e->binop.left = l; e->binop.right = r; return e;
}

/* ---- test: assert → pump → rule fires → output fact in Rete WM ---- */

static int test_assert_pump_rule_fires(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *engine = NULL;
    if (expect_ok("engine_new", ds_engine_new(&cfg, &engine))) return 1;

    const ds_schema_t *src_ds = NULL, *out_ds = NULL;
    const ds_rete_schema_t *src_rs = NULL, *out_rs = NULL;

    if (setup_schemas(engine, "Src", DS_SLOT_TYPE_INT, DS_RETE_VAL_INT, false, &src_ds, &src_rs)) goto fail;
    if (setup_schemas(engine, "Out", DS_SLOT_TYPE_INT, DS_RETE_VAL_INT, true,  &out_ds, &out_rs)) goto fail;

    /* Build network: single-pattern rule, double the value.
     * AlphaNode 1 → Src
     * BetaNode 2 → root × AlphaNode 1
     * TerminalNode 3 → ASSERT Out(val = var(0,0) * 2)  */
    ds_rete_expr_t *result_expr = binop(DS_RETE_BINOP_MUL, var(0,0), lit_int(2));
    ds_rete_slot_assign_t assign = { .slot_index=0, .expr=result_expr };
    ds_rete_action_t action = {
        .kind=DS_RETE_ACTION_ASSERT, .schema_id=out_rs->id,
        .assigns=&assign, .assign_count=1
    };

    ds_alfa_atom_t alfas[1] = {{ .node_id=1, .schema_name="Src" }};
    ds_beta_atom_t betas[1] = {{ .node_id=2, .right_alpha_id=1, .left_parent_id=0 }};
    ds_term_atom_t terms[1] = {{
        .node_id=3, .parent_beta_id=2, .rule_name="double_rule",
        .actions=&action, .action_count=1
    }};
    ds_rete_network_t net = { .alfas=alfas,.alfa_count=1,
                               .betas=betas,.beta_count=1,
                               .terms=terms,.term_count=1 };

    if (expect_ok("load_network", ds_rete_load_network(engine->rete_engine, &net))) {
        ds_rete_expr_free_tree(result_expr);
        goto fail;
    }

    /* Assert Src(val=5) via the public API. */
    ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = 5 };
    ds_fact_t *src_fact = NULL;
    if (expect_ok("assert Src(5)", ds_engine_assert(engine, src_ds, &sv, 1, &src_fact))) goto fail;
    if (!src_fact) { fail_msg("assert returned NULL fact"); goto fail; }

    /* Pump — should fire the double rule. */
    if (expect_ok("pump", ds_engine_pump(engine))) goto fail;

    /* Check Out(10) exists in the Rete WM. */
    int n = count_rete_facts(engine->rete_engine, out_rs, 10);
    if (n != 1) {
        fprintf(stderr, "FAIL: Out(10) count=%d want 1\n", n);
        goto fail;
    }

    /* Retract via the public API. */
    if (expect_ok("retract Src(5)", ds_engine_retract(engine, src_fact))) goto fail;

    /* Check Src(5) is gone from Rete WM. */
    int m = count_rete_facts(engine->rete_engine, src_rs, 5);
    if (m != 0) {
        fprintf(stderr, "FAIL: Src(5) still in WM after retract, count=%d\n", m);
        goto fail;
    }

    ds_engine_free(engine);
    printf("  pass: test_assert_pump_rule_fires\n");
    return 0;

fail:
    ds_engine_free(engine);
    return 1;
}

/* ---- ds_engine_register_schema (internal, engine.h) registers into the
 * Rete engine too, so register-then-assert works with NO .dsc loaded: the
 * schema comes in through it alone, with no network and no manual Rete
 * registration, and a bare fact is asserted. */
static int test_register_then_assert_no_dsc(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *engine = NULL;
    if (expect_ok("engine_new", ds_engine_new(&cfg, &engine))) return 1;

    /* No ds_rete_schema_register by hand. */
    ds_slot_desc_t sd = { .name = "val", .type = DS_SLOT_TYPE_INT,
                          .identity_role = DS_IDENTITY_KEY };
    const ds_schema_t *reg_ds = NULL;
    if (expect_ok("register_schema RegOnly",
                  ds_engine_register_schema(engine, "RegOnly",
                                            DS_SCHEMA_LIFECYCLE_LOGICAL,
                                            0, &sd, 1, &reg_ds))) goto fail;

    ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = 7 };
    ds_fact_t *f = NULL;
    if (expect_ok("assert RegOnly(7) after register",
                  ds_engine_assert(engine, reg_ds, &sv, 1, &f))) goto fail;
    if (!f) { fail_msg("assert returned NULL fact"); goto fail; }

    size_t n = 0;
    if (expect_ok("fact_count", ds_engine_fact_count(engine, &n))) goto fail;
    if (n != 1) {
        fprintf(stderr, "FAIL: fact_count=%zu want 1\n", n);
        goto fail;
    }

    ds_engine_free(engine);
    printf("  pass: test_register_then_assert_no_dsc\n");
    return 0;

fail:
    ds_engine_free(engine);
    return 1;
}

int main(void)
{
    int fail_count = 0;
    printf("=== test_engine_rete_integration ===\n");

    if (test_assert_pump_rule_fires()) {
        fprintf(stderr, "  FAIL: test_assert_pump_rule_fires\n");
        fail_count++;
    }

    if (test_register_then_assert_no_dsc()) {
        fprintf(stderr, "  FAIL: test_register_then_assert_no_dsc\n");
        fail_count++;
    }

    if (fail_count == 0) {
        printf("=== test_engine_rete_integration: ALL PASSED ===\n");
        return 0;
    }
    fprintf(stderr, "=== test_engine_rete_integration: %d FAILED ===\n", fail_count);
    return 1;
}
