/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * ds_rete_load_network: build and exercise a Rete network from AlphaNode /
 * BetaNode / TerminalNode atoms (IRET.15, RDSC.4a).
 *
 * Schemas are registered before loading (they come from Slot atoms in
 * production; here we register them directly).
 *
 * Covers:
 *   - Single-pattern rule: assert Src → fires → ASSERT Out
 *   - Two-pattern rule: cross-schema join fires only when both patterns match
 *   - Join test expression: right.val > left.val
 *   - Logical ASSERT + TMS: retracting supporting fact cascades
 *   - Validation: DS_ERR_SCHEMA_UNKNOWN on unknown schema_name
 *   - Validation: DS_ERR_RETP_INDEX_OOB on bad right_alpha_id
 *   - Validation: DS_ERR_RETP_INVALID on a shared node_id and on node_id 0
 *   - An alpha REGEX test filters, and a bad pattern refuses the load
 *   - Engine owns all nodes: no manual destroy needed
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "rete/action.h"
#include "rete/alpha.h"
#include "rete/beta.h"
#include "rete/engine.h"
#include "rete/expr.h"
#include "rete/intern.h"
#include "rete/loader.h"
#include "rete/schema.h"
#include "rete/schema_reg.h"
#include "rete/terminal.h"
#include "rete/token.h"
#include "rete/val.h"
#include "rete/wm_rete.h"
#include "ds_re2.h"

/* Whether this build links RE2; see test_rete_builtins.c's copy. */
static int re2_linked(void)
{
    char err[64];
    ds_re2_t *re = ds_re2_compile("a", 0, err, sizeof err);
    if (re == NULL) return 0;
    ds_re2_free(re);
    return 1;
}

static int g_join_fires = 0;
static void fire_cnt(const char *r, ds_rete_token_t *t, void *ctx)
{
    (void)r; (void)t; (void)ctx;
    g_join_fires++;
}

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
static int expect_status(const char *what, ds_result_t r, int want)
{
    if (r.status != want) {
        fprintf(stderr, "FAIL: %s: want %d got %d (%s)\n",
                what, want, r.status, r.detail ? r.detail : "");
        return 1;
    }
    return 0;
}

static int count_facts(ds_rete_engine_t *engine,
                        const ds_rete_schema_t *schema,
                        int64_t val)
{
    int n = 0;
    for (uint32_t i = 0; i < oa_len(&engine->wm_map); i++) {
        ds_rete_fact_t *f = *(ds_rete_fact_t **)ds_oa_val_at(&engine->wm_map, i);
        if (!f) continue;
        if (f->schema == schema && f->slots[0].i == val) n++;
    }
    return n;
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

static ds_rete_fact_t *assert_fact(ds_rete_engine_t *eng,
                                    uint16_t sid, int64_t val)
{
    ds_rete_val_t v = ds_rete_val_int(val);
    ds_rete_fact_t *f = NULL;
    ds_rete_wm_assert(eng, sid, &v, &f);
    return f;
}

static int test_single_pattern_rule(void)
{
    /*
     * Schemas: Src(val:Int)[id=0], Out(result:Int identity)[id=1]
     * AlphaNode 1 → Src, no tests
     * BetaNode 2 → left=root(0), right=AlphaNode 1, no join tests
     * TerminalNode 3 → parent=BetaNode 2, ASSERT Out(result=var(0,0)*2)
     */
    ds_rete_engine_t *engine = NULL;
    ds_rete_engine_create(&engine);

    ds_rete_slot_desc_t src_slots[] = {{ .name="val",    .type=DS_RETE_VAL_INT }};
    ds_rete_slot_desc_t out_slots[] = {{ .name="result", .type=DS_RETE_VAL_INT,
                                         .is_key=true }};
    ds_rete_schema_t *src_s = NULL, *out_s = NULL;
    if (expect_ok("reg Src", ds_rete_schema_register(engine, "Src",
            DS_RETE_SCOPE_PLAIN, 0, src_slots, 1, &src_s))) goto fail;
    if (expect_ok("reg Out", ds_rete_schema_register(engine, "Out",
            DS_RETE_SCOPE_PLAIN, 0, out_slots, 1, &out_s))) goto fail;

    ds_rete_expr_t *result_expr = binop(DS_RETE_BINOP_MUL, var(0,0), lit_int(2));
    ds_rete_slot_assign_t assign = { .slot_index=0, .expr=result_expr };
    ds_rete_action_t action = {
        .kind=DS_RETE_ACTION_ASSERT, .schema_id=out_s->id,
        .assigns=&assign, .assign_count=1
    };

    ds_alfa_atom_t alfas[1] = {{
        .node_id=1, .schema_name="Src", .tests=NULL, .test_count=0
    }};
    ds_beta_atom_t betas[1] = {{
        .node_id=2, .right_alpha_id=1, .left_parent_id=0,
        .join_tests=NULL, .join_test_count=0, .is_negative=false
    }};
    ds_term_atom_t terms[1] = {{
        .node_id=3, .parent_beta_id=2, .rule_name="double_rule",
        .bind_count=0,
        .actions=&action, .action_count=1
    }};
    ds_rete_network_t net = {
        .alfas=alfas, .alfa_count=1,
        .betas=betas, .beta_count=1,
        .terms=terms, .term_count=1,
    };

    if (expect_ok("load_network", ds_rete_load_network(engine, &net))) {
        ds_rete_expr_free_tree(result_expr);
        ds_rete_engine_destroy(engine);
        return 1;
    }

    engine->cycle_generation++;
    assert_fact(engine, src_s->id, 7);
    ds_rete_run(engine, 0, NULL);

    int n = count_facts(engine, out_s, 14);
    ds_rete_engine_destroy(engine);
    if (n != 1) {
        fprintf(stderr, "FAIL: single_pattern: Out(14) count=%d want 1\n", n);
        return 1;
    }
    return 0;
fail:
    ds_rete_engine_destroy(engine);
    return 1;
}

static int test_two_pattern_join(void)
{
    /*
     * Schemas: A(val:Int)[0], B(val:Int)[1], Out(sum:Int identity)[2]
     * AlphaNode 1 → A
     * AlphaNode 2 → B
     * BetaNode 3 → left=root(0), right=AlphaNode 1
     * BetaNode 4 → left=BetaNode 3, right=AlphaNode 2
     * TerminalNode 5 → parent=BetaNode 4, ASSERT Out(sum=var(0,0)+var(1,0))
     */
    ds_rete_engine_t *engine = NULL;
    ds_rete_engine_create(&engine);

    ds_rete_slot_desc_t a_slots[] = {{ .name="val", .type=DS_RETE_VAL_INT }};
    ds_rete_slot_desc_t b_slots[] = {{ .name="val", .type=DS_RETE_VAL_INT }};
    ds_rete_slot_desc_t o_slots[] = {{ .name="sum", .type=DS_RETE_VAL_INT,
                                        .is_key=true }};
    ds_rete_schema_t *sa = NULL, *sb = NULL, *so = NULL;
    if (expect_ok("reg A", ds_rete_schema_register(engine, "A",
            DS_RETE_SCOPE_PLAIN, 0, a_slots, 1, &sa))) goto fail;
    if (expect_ok("reg B", ds_rete_schema_register(engine, "B",
            DS_RETE_SCOPE_PLAIN, 0, b_slots, 1, &sb))) goto fail;
    if (expect_ok("reg Out", ds_rete_schema_register(engine, "Out",
            DS_RETE_SCOPE_PLAIN, 0, o_slots, 1, &so))) goto fail;

    ds_rete_expr_t *sum_expr = binop(DS_RETE_BINOP_ADD, var(0,0), var(1,0));
    ds_rete_slot_assign_t assign = { .slot_index=0, .expr=sum_expr };
    ds_rete_action_t action = {
        .kind=DS_RETE_ACTION_ASSERT, .schema_id=so->id,
        .assigns=&assign, .assign_count=1
    };

    ds_alfa_atom_t alfas[2] = {
        { .node_id=1, .schema_name="A" },
        { .node_id=2, .schema_name="B" },
    };
    ds_beta_atom_t betas[2] = {
        { .node_id=3, .right_alpha_id=1, .left_parent_id=0 },
        { .node_id=4, .right_alpha_id=2, .left_parent_id=3 },
    };
    ds_term_atom_t terms[1] = {{
        .node_id=5, .parent_beta_id=4, .rule_name="join_rule",
        .actions=&action, .action_count=1
    }};
    ds_rete_network_t net = {
        .alfas=alfas, .alfa_count=2,
        .betas=betas, .beta_count=2,
        .terms=terms, .term_count=1,
    };

    if (expect_ok("load_network (join)", ds_rete_load_network(engine, &net))) {
        ds_rete_expr_free_tree(sum_expr);
        ds_rete_engine_destroy(engine);
        return 1;
    }

    engine->cycle_generation++;
    assert_fact(engine, sa->id, 3);
    ds_rete_run(engine, 0, NULL);
    if (count_facts(engine, so, -1) != 0) {
        ds_rete_engine_destroy(engine);
        return fail_msg("join: rule fired with only A asserted");
    }

    engine->cycle_generation++;
    assert_fact(engine, sb->id, 4);
    ds_rete_run(engine, 0, NULL);
    int n = count_facts(engine, so, 7);
    ds_rete_engine_destroy(engine);
    if (n != 1) {
        fprintf(stderr, "FAIL: join: Out(sum=7) count=%d want 1\n", n);
        return 1;
    }
    return 0;
fail:
    ds_rete_engine_destroy(engine);
    return 1;
}

static int test_join_test_expr(void)
{
    /*
     * Schema: Src(val:Int)[0]
     * AlphaNode 1 → Src
     * BetaNode 2 → left=root(0), right=AlphaNode 1        (root × Src)
     * BetaNode 3 → left=BetaNode 2,  right=AlphaNode 1, test: right.val > left[0].val
     * TerminalNode 4 → parent=BetaNode 3, no actions (fire_fn counts)
     */
    ds_rete_engine_t *engine = NULL;
    ds_rete_engine_create(&engine);

    ds_rete_slot_desc_t src_slots[] = {{ .name="val", .type=DS_RETE_VAL_INT }};
    ds_rete_schema_t *ss = NULL;
    if (expect_ok("reg Src", ds_rete_schema_register(engine, "Src",
            DS_RETE_SCOPE_PLAIN, 0, src_slots, 1, &ss))) goto fail;

    ds_rete_expr_t *jexpr = binop(DS_RETE_BINOP_GT,
        var(DS_RETE_VAR_RIGHT_FACT, 0), var(0, 0));
    ds_rete_join_test_t jtest = { .expr = jexpr };

    ds_alfa_atom_t alfas[1] = {{ .node_id=1, .schema_name="Src" }};
    ds_beta_atom_t betas[2] = {
        { .node_id=2, .right_alpha_id=1, .left_parent_id=0 },
        { .node_id=3, .right_alpha_id=1, .left_parent_id=2,
          .join_tests=&jtest, .join_test_count=1 },
    };
    ds_term_atom_t terms[1] = {{
        .node_id=4, .parent_beta_id=3, .rule_name="gt_rule",
        .actions=NULL, .action_count=0
    }};
    ds_rete_network_t net = {
        .alfas=alfas, .alfa_count=1,
        .betas=betas, .beta_count=2,
        .terms=terms, .term_count=1,
    };

    g_join_fires = 0;

    if (expect_ok("load (jtest)", ds_rete_load_network(engine, &net))) {
        ds_rete_expr_free_tree(jexpr);
        ds_rete_engine_destroy(engine);
        return 1;
    }

    engine->owned_terminals[0]->fire_fn  = fire_cnt;
    engine->owned_terminals[0]->fire_ctx = NULL;

    engine->cycle_generation++;
    assert_fact(engine, ss->id, 1);
    engine->cycle_generation++;
    assert_fact(engine, ss->id, 3);
    engine->cycle_generation++;
    ds_rete_run(engine, 0, NULL);

    ds_rete_engine_destroy(engine);

    if (g_join_fires != 1) {
        fprintf(stderr, "FAIL: join_test: want 1 fire got %d\n", g_join_fires);
        return 1;
    }
    return 0;
fail:
    ds_rete_engine_destroy(engine);
    return 1;
}

static int test_validation(void)
{
    int fail_count = 0;

    /* 4a: unknown schema_name → DS_ERR_SCHEMA_UNKNOWN */
    {
        ds_rete_engine_t *engine = NULL;
        ds_rete_engine_create(&engine);

        ds_alfa_atom_t alfas[1] = {{
            .node_id=1, .schema_name="NoSuchSchema"
        }};
        ds_rete_network_t net = { .alfas=alfas, .alfa_count=1 };
        ds_result_t r = ds_rete_load_network(engine, &net);
        ds_rete_engine_destroy(engine);
        fail_count += expect_status("unknown schema", r, DS_ERR_SCHEMA_UNKNOWN);
    }

    /* 4a2: the detail belongs to the engine that produced it. Two engines
       refuse two different schemas, and the first engine's detail still names
       its schema after the second refusal. */
    {
        ds_rete_engine_t *e1 = NULL, *e2 = NULL;
        ds_rete_engine_create(&e1);
        ds_rete_engine_create(&e2);
        ds_alfa_atom_t a1[1] = {{ .node_id=1, .schema_name="FirstMissing" }};
        ds_alfa_atom_t a2[1] = {{ .node_id=1, .schema_name="SecondMissing" }};
        ds_rete_network_t n1 = { .alfas=a1, .alfa_count=1 };
        ds_rete_network_t n2 = { .alfas=a2, .alfa_count=1 };
        ds_result_t r1 = ds_rete_load_network(e1, &n1);
        ds_result_t r2 = ds_rete_load_network(e2, &n2);
        fail_count += expect_status("e1 unknown schema", r1, DS_ERR_SCHEMA_UNKNOWN);
        fail_count += expect_status("e2 unknown schema", r2, DS_ERR_SCHEMA_UNKNOWN);
        if (!r1.detail || !strstr(r1.detail, "'FirstMissing'"))
            fail_count += fail_msg("e1's detail no longer names its own schema "
                                   "after e2's refusal");
        if (!r2.detail || !strstr(r2.detail, "'SecondMissing'"))
            fail_count += fail_msg("e2's detail names its schema");
        if (r1.detail == r2.detail)
            fail_count += fail_msg("two engines share one detail buffer");
        ds_rete_engine_destroy(e1);
        ds_rete_engine_destroy(e2);
    }

    /* 4b: BetaNode right_alpha_id not found → DS_ERR_RETP_INDEX_OOB */
    {
        ds_rete_engine_t *engine = NULL;
        ds_rete_engine_create(&engine);

        ds_rete_slot_desc_t s[] = {{ .name="v", .type=DS_RETE_VAL_INT }};
        ds_rete_schema_t *ss = NULL;
        ds_rete_schema_register(engine, "S", DS_RETE_SCOPE_PLAIN, 0, s, 1, &ss);

        ds_alfa_atom_t alfas[1] = {{ .node_id=1, .schema_name="S" }};
        ds_beta_atom_t betas[1] = {{
            .node_id=2, .right_alpha_id=999 /* no such node */, .left_parent_id=0
        }};
        ds_rete_network_t net = {
            .alfas=alfas, .alfa_count=1,
            .betas=betas, .beta_count=1,
        };
        ds_result_t r = ds_rete_load_network(engine, &net);
        ds_rete_engine_destroy(engine);
        fail_count += expect_status("bad right_alpha_id", r, DS_ERR_RETP_INDEX_OOB);
    }

    /* 4c: [RDSC.4a.3] a node_id an AlphaNode and a BetaNode share, and a node_id of
       0, are both DS_ERR_RETP_INVALID: the node map refuses a second key and
       the reserved null (`nm_insert`). The Mercury runtime answers both with
       the same code (`ds.network` / `ds.dsc_network`, test_ds.m). Each detail
       is checked, so neither passes on another refusal. */
    {
        ds_rete_engine_t *engine = NULL;
        ds_rete_engine_create(&engine);
        ds_rete_slot_desc_t s[] = {{ .name="v", .type=DS_RETE_VAL_INT }};
        ds_rete_schema_t *ss = NULL;
        ds_rete_schema_register(engine, "S", DS_RETE_SCOPE_PLAIN, 0, s, 1, &ss);

        ds_alfa_atom_t alfas[1] = {{ .node_id=1, .schema_name="S" }};
        ds_beta_atom_t betas[1] = {{
            .node_id=1 /* AlphaNode 1's */, .right_alpha_id=1, .left_parent_id=0
        }};
        ds_rete_network_t net = {
            .alfas=alfas, .alfa_count=1,
            .betas=betas, .beta_count=1,
        };
        ds_result_t r = ds_rete_load_network(engine, &net);
        fail_count += expect_status("[RDSC.4a.3] shared node_id", r,
                                    DS_ERR_RETP_INVALID);
        if (!r.detail || !strstr(r.detail, "duplicate node_id"))
            fail_count += fail_msg("a shared node_id is refused, but not by "
                                   "the node map's duplicate check");
        ds_rete_engine_destroy(engine);
    }
    {
        ds_rete_engine_t *engine = NULL;
        ds_rete_engine_create(&engine);
        ds_rete_slot_desc_t s[] = {{ .name="v", .type=DS_RETE_VAL_INT }};
        ds_rete_schema_t *ss = NULL;
        ds_rete_schema_register(engine, "S", DS_RETE_SCOPE_PLAIN, 0, s, 1, &ss);

        ds_alfa_atom_t alfas[1] = {{ .node_id=0, .schema_name="S" }};
        ds_rete_network_t net = { .alfas=alfas, .alfa_count=1 };
        ds_result_t r = ds_rete_load_network(engine, &net);
        fail_count += expect_status("[RDSC.4a.3] node_id 0", r,
                                    DS_ERR_RETP_INVALID);
        if (!r.detail || !strstr(r.detail, "node_id 0 is reserved"))
            fail_count += fail_msg("node_id 0 is refused, but not as the "
                                   "reserved null");
        ds_rete_engine_destroy(engine);
    }

    return fail_count;
}

static int test_logical_tms_via_loader(void)
{
    /*
     * Schemas: Src(val:Int)[0], Out(result:Int identity)[1]
     * AlphaNode 1 → Src
     * BetaNode 2 → left=root(0), right=AlphaNode 1
     * TerminalNode 3 → parent=BetaNode 2, LOGICAL_ASSERT Out(result=var(0,0))
     * Assert Src(42) → Out(42) with justif=1.
     * Retract Src(42) → TMS cascade → Out(42) retracted.
     */
    ds_rete_engine_t *engine = NULL;
    ds_rete_engine_create(&engine);

    ds_rete_slot_desc_t src_slots[] = {{ .name="val",    .type=DS_RETE_VAL_INT }};
    ds_rete_slot_desc_t out_slots[] = {{ .name="result", .type=DS_RETE_VAL_INT,
                                         .is_key=true }};
    ds_rete_schema_t *src_s = NULL, *out_s = NULL;
    if (expect_ok("reg Src", ds_rete_schema_register(engine, "Src",
            DS_RETE_SCOPE_PLAIN, 0, src_slots, 1, &src_s))) goto fail;
    if (expect_ok("reg Out", ds_rete_schema_register(engine, "Out",
            DS_RETE_SCOPE_PLAIN, 0, out_slots, 1, &out_s))) goto fail;

    ds_rete_expr_t *ve = var(0, 0);
    ds_rete_slot_assign_t assign = { .slot_index=0, .expr=ve };
    ds_rete_action_t action = {
        .kind=DS_RETE_ACTION_LOGICAL_ASSERT, .schema_id=out_s->id,
        .assigns=&assign, .assign_count=1
    };

    ds_alfa_atom_t alfas[1] = {{ .node_id=1, .schema_name="Src" }};
    ds_beta_atom_t betas[1] = {{
        .node_id=2, .right_alpha_id=1, .left_parent_id=0
    }};
    ds_term_atom_t terms[1] = {{
        .node_id=3, .parent_beta_id=2, .rule_name="logical_rule",
        .actions=&action, .action_count=1
    }};
    ds_rete_network_t net = {
        .alfas=alfas, .alfa_count=1,
        .betas=betas, .beta_count=1,
        .terms=terms, .term_count=1,
    };

    if (expect_ok("load (tms)", ds_rete_load_network(engine, &net))) {
        ds_rete_expr_free_tree(ve);
        ds_rete_engine_destroy(engine);
        return 1;
    }

    engine->cycle_generation++;
    ds_rete_fact_t *src = assert_fact(engine, src_s->id, 42);
    ds_rete_run(engine, 0, NULL);

    int n = count_facts(engine, out_s, 42);
    if (n != 1) {
        fprintf(stderr, "FAIL: logical_tms: Out(42) count=%d want 1\n", n);
        ds_rete_engine_destroy(engine);
        return 1;
    }

    uint32_t out_id = 0;
    for (uint32_t i = 0; i < oa_len(&engine->wm_map); i++) {
        ds_rete_fact_t *f = *(ds_rete_fact_t **)ds_oa_val_at(&engine->wm_map, i);
        if (!f) continue;
        if (f->schema == out_s && f->slots[0].i == 42) { out_id = f->id; break; }
    }

    ds_rete_wm_retract(engine, src);

    ds_rete_fact_t *still = ds_rete_wm_find_by_id(engine, out_id);
    ds_rete_engine_destroy(engine);

    if (still) return fail_msg("logical_tms: Out(42) should be retracted");
    return 0;
fail:
    ds_rete_engine_destroy(engine);
    return 1;
}

/* An alpha REGEX test loads and filters. Both verdicts are driven: only a
 * fact that must be rejected tells a pattern the evaluator consults from one
 * it compiles and ignores. */
static int test_alpha_regex_filters(void)
{
    int fail_count = 0;

    ds_rete_engine_t *engine = NULL;
    ds_rete_engine_create(&engine);

    ds_rete_slot_desc_t s[] = {{ .name="name", .type=DS_RETE_VAL_STR }};
    ds_rete_schema_t *ss = NULL;
    ds_rete_schema_register(engine, "S", DS_RETE_SCOPE_PLAIN, 0, s, 1, &ss);

    ds_retp_alpha_test_t t = {
        .kind = DS_RETE_ALPHA_REGEX, .slot_index = 0, .pattern = "^ab+c$"
    };
    ds_alfa_atom_t alfas[1] = {{
        .node_id=1, .schema_name="S", .tests=&t, .test_count=1
    }};
    ds_rete_network_t net = { .alfas=alfas, .alfa_count=1 };
    ds_result_t r = ds_rete_load_network(engine, &net);
    fail_count += expect_status("alpha REGEX loads", r, DS_OK);
    if (r.status != DS_OK || engine->owned_alpha_count < 1) {
        ds_rete_engine_destroy(engine);
        return fail_count + fail_msg("alpha REGEX: no node built");
    }
    ds_rete_alpha_node_t *node = engine->owned_alphas[0];

    /* Two facts, one of each verdict; an evaluator that admits everything
     * fails the second. */
    const char *py = NULL, *pn = NULL;
    ds_rete_intern_cstr(engine->intern, "abbc", &py);
    ds_rete_intern_cstr(engine->intern, "xyz",  &pn);
    ds_rete_val_t yes = ds_rete_val_str(py, 4);
    ds_rete_val_t no  = ds_rete_val_str(pn, 3);
    ds_rete_fact_t *fy = NULL, *fn = NULL;
    ds_rete_wm_assert(engine, ss->id, &yes, &fy);
    ds_rete_wm_assert(engine, ss->id, &no,  &fn);

    if (fy && !ds_rete_alpha_test_fact(node, fy, NULL))
        fail_count += fail_msg("alpha REGEX: 'abbc' should match ^ab+c$");
    if (fn && ds_rete_alpha_test_fact(node, fn, NULL))
        fail_count += fail_msg("alpha REGEX: 'xyz' should NOT match ^ab+c$");

    ds_rete_engine_destroy(engine);
    return fail_count;
}

/* A pattern that does not compile is a malformed artefact, and the load
 * refuses it with DS_ERR_DSC_SEMANTIC ([RDSC.4a.6.1]) rather than building a
 * test that never matches. */
/* @spec [RDSC.4a.6.1] */
static int test_alpha_regex_bad_pattern_refuses_load(void)
{
    int fail_count = 0;

    ds_rete_engine_t *engine = NULL;
    ds_rete_engine_create(&engine);

    ds_rete_slot_desc_t s[] = {{ .name="name", .type=DS_RETE_VAL_STR }};
    ds_rete_schema_t *ss = NULL;
    ds_rete_schema_register(engine, "S", DS_RETE_SCOPE_PLAIN, 0, s, 1, &ss);

    ds_retp_alpha_test_t t = {
        .kind = DS_RETE_ALPHA_REGEX, .slot_index = 0, .pattern = "ab+(c"
    };
    ds_alfa_atom_t alfas[1] = {{
        .node_id=1, .schema_name="S", .tests=&t, .test_count=1
    }};
    ds_rete_network_t net = { .alfas=alfas, .alfa_count=1 };
    ds_result_t r = ds_rete_load_network(engine, &net);
    ds_rete_engine_destroy(engine);

    fail_count += expect_status("alpha REGEX bad pattern refused", r,
                                DS_ERR_DSC_SEMANTIC);
    return fail_count;
}

int main(void)
{
    int fail_count = 0;

#define RUN(t) do { \
    int _r = (t)(); \
    if (_r) { fprintf(stderr, "  FAIL: " #t "\n"); fail_count += _r; } \
    else    { printf("  pass: " #t "\n"); } \
} while (0)

    printf("=== test_rete_loader ===\n");
    RUN(test_single_pattern_rule);
    RUN(test_two_pattern_join);
    RUN(test_join_test_expr);
    RUN(test_validation);
    RUN(test_logical_tms_via_loader);
    /* Both regex cases need RE2: on the stub every pattern is refused, so the
       second would pass for the wrong reason. */
    if (re2_linked()) {
        RUN(test_alpha_regex_filters);
        RUN(test_alpha_regex_bad_pattern_refuses_load);
    } else {
        printf("  skip: test_alpha_regex_filters, "
               "test_alpha_regex_bad_pattern_refuses_load (this build links no RE2)\n");
    }
#undef RUN

    if (fail_count == 0) {
        printf("=== test_rete_loader: ALL PASSED ===\n");
        return 0;
    }
    fprintf(stderr, "=== test_rete_loader: %d FAILED ===\n", fail_count);
    return 1;
}
