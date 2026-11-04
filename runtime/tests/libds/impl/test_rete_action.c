/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * RHS actions and truth maintenance (IRET.10, IRET.12): a CALL evaluated
 * for its effect, an ASSERT's slots evaluated into a fact, a LOGICAL_ASSERT
 * retracted with its supporting fact, a fact with two justifiers kept until
 * the last goes, and fire_fn on a terminal with no actions.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "builtin_fn.h"
#include "rete/action.h"
#include "rete/agenda.h"
#include "rete/alpha.h"
#include "rete/beta.h"
#include "rete/dispatch.h"
#include "rete/engine.h"
#include "rete/eval.h"
#include "rete/expr.h"
#include "rete/fact.h"
#include "rete/intern.h"
#include "rete/schema.h"
#include "rete/schema_reg.h"
#include "rete/terminal.h"
#include "rete/token.h"
#include "rete/tms.h"
#include "rete/val.h"
#include "rete/wm_rete.h"

static int fail(const char *msg)
{
    fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}
static int expect_ok(const char *what, ds_result_t r)
{
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: %s: status=%d (%s)\n",
                what, r.status, r.detail ? r.detail : "(null)");
        return 1;
    }
    return 0;
}

typedef struct {
    ds_rete_engine_t    *engine;
    ds_rete_schema_t    *schema_src;  /* Int slot "val" */
    ds_rete_schema_t    *schema_out;  /* Int slot "result" */
    ds_rete_alpha_node_t *alpha_src;
} Ctx;

static const char *istr(ds_rete_engine_t *e, const char *s)
{
    const char *p; ds_rete_intern_cstr(e->intern, s, &p); return p;
}

static Ctx make_ctx(void)
{
    Ctx c = {0};
    ds_rete_engine_create(&c.engine);

    ds_rete_slot_desc_t src_slots[] = {
        { .name = "val", .type = DS_RETE_VAL_INT },
    };
    ds_rete_schema_register(c.engine, "Src", DS_RETE_SCOPE_PLAIN, 0,
                             src_slots, 1, &c.schema_src);

    ds_rete_slot_desc_t out_slots[] = {
        { .name = "result", .type = DS_RETE_VAL_INT, .is_key = true },
    };
    ds_rete_schema_register(c.engine, "Out", DS_RETE_SCOPE_PLAIN, 0,
                             out_slots, 1, &c.schema_out);

    ds_rete_alpha_node_create(0, NULL, 0, &c.alpha_src);
    ds_rete_dispatch_add(c.engine, 0, c.alpha_src);
    return c;
}

static void destroy_ctx(Ctx *c)
{
    ds_rete_alpha_node_destroy(c->alpha_src);
    ds_rete_engine_destroy(c->engine);
}

static ds_rete_fact_t *assert_src(Ctx *c, int64_t val)
{
    ds_rete_val_t v = ds_rete_val_int(val);
    ds_rete_fact_t *f = NULL;
    ds_rete_wm_assert(c->engine, 0, &v, &f);
    return f;
}

static ds_rete_expr_t *lit_int(int64_t v)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_INT);
    e->lit_int = v; return e;
}
static ds_rete_expr_t *var(uint16_t pat, uint16_t slot)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
    e->var.pattern_index = pat;
    e->var.slot_index    = slot;
    return e;
}

/* Build a simple terminal with one ASSERT action:
 *   emit Out result: <val_expr> */
static ds_rete_terminal_t *make_assert_terminal(Ctx *c, uint16_t schema_id,
                                                 ds_rete_expr_t *val_expr,
                                                 bool logical)
{
    ds_rete_terminal_t *term = NULL;
    ds_rete_terminal_create(istr(c->engine, "rule"), 0, &term);

    ds_rete_slot_assign_t assign = { .slot_index = 0, .expr = val_expr };
    ds_rete_action_t action = {
        .kind         = logical ? DS_RETE_ACTION_LOGICAL_ASSERT
                                : DS_RETE_ACTION_ASSERT,
        .schema_id    = schema_id,
        .assigns      = &assign,
        .assign_count = 1,
    };
    ds_rete_terminal_add_action(term, &action);
    return term;
}

static int g_call_count = 0;
static ds_result_t count_fn(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                              ds_rete_val_t *args, uint32_t argc,
                              ds_rete_val_t *out)
{
    (void)e; (void)ctx; (void)args; (void)argc;
    g_call_count++;
    *out = ds_rete_val_bool(true);
    return DS_OK_R;
}

static int test_call_action(void)
{
    Ctx c = make_ctx();
    g_call_count = 0;

    /* DS_FN_LATEST has no handler of its own. */
    ds_register_fn(DS_FN_LATEST, count_fn);

    ds_rete_terminal_t *term = NULL;
    ds_rete_terminal_create(istr(c.engine, "r"), 0, &term);

    ds_rete_expr_t *call_expr = ds_rete_expr_alloc(DS_RETE_EXPR_CALL);
    call_expr->call.op        = DS_FN_LATEST;
    call_expr->call.arg_count = 0;
    call_expr->call.args      = NULL;

    ds_rete_action_t action = { .kind = DS_RETE_ACTION_CALL, .expr = call_expr };
    ds_rete_terminal_add_action(term, &action);

    ds_rete_fact_t *f = assert_src(&c, 1);
    ds_result_t err;
    ds_rete_token_t *tok = ds_rete_token_create(NULL, f, 0, NULL, NULL, &err);
    c.engine->cycle_generation++;
    ds_rete_terminal_left_activate(term, tok, c.engine);
    ds_rete_token_free(tok);

    uint32_t fired = 0;
    if (expect_ok("run", ds_rete_run(c.engine, 0, &fired))) return 1;
    if (fired != 1) { ds_rete_terminal_destroy(term); destroy_ctx(&c); return fail("CALL: not fired"); }
    if (g_call_count != 1) { ds_rete_terminal_destroy(term); destroy_ctx(&c); return fail("CALL: count wrong"); }

    ds_rete_terminal_destroy(term);
    destroy_ctx(&c);
    return 0;
}

static int test_assert_action(void)
{
    Ctx c = make_ctx();

    /* Rule: on Src(val=V), emit Out(result=V*2). */
    ds_rete_expr_t *val_expr = ds_rete_expr_alloc(DS_RETE_EXPR_BINOP);
    val_expr->binop.op    = DS_RETE_BINOP_MUL;
    val_expr->binop.left  = var(0, 0); /* Src.val */
    val_expr->binop.right = lit_int(2);

    ds_rete_terminal_t *term = make_assert_terminal(&c, 1 /* Out */, val_expr, false);

    ds_rete_beta_node_t *beta = NULL;
    ds_rete_beta_node_create(NULL, c.alpha_src, NULL, 0, false, &beta);
    ds_rete_alpha_add_beta_output(c.alpha_src, beta);
    ds_rete_beta_add_terminal(beta, term);

    /* Seed root beta with nil token so right-activations produce 1-fact tokens. */
    ds_result_t err;
    ds_rete_token_t *nil = ds_rete_token_create_nil(NULL, NULL, &err);
    ds_rete_beta_left_activate(beta, nil, c.engine);
    ds_rete_token_free(nil);

    c.engine->cycle_generation++;
    assert_src(&c, 7);

    uint32_t fired = 0;
    if (expect_ok("run", ds_rete_run(c.engine, 0, &fired))) return 1;

    int found = 0;
    for (uint32_t i = 0; i < oa_len(&c.engine->wm_map); i++) {
        ds_rete_fact_t *f = *(ds_rete_fact_t **)ds_oa_val_at(&c.engine->wm_map, i);
        if (!f) continue;
        if (f->schema == c.schema_out &&
            f->slots[0].kind == DS_RETE_VAL_INT &&
            f->slots[0].i    == 14) { found = 1; break; }
    }

    ds_rete_beta_node_destroy(beta);
    ds_rete_terminal_destroy(term);
    destroy_ctx(&c);

    if (!found) return fail("ASSERT: Out(result=14) not in WM");
    return 0;
}

/* @spec [IRET.12.1] [IRET.12.2] */
static int test_logical_assert_tms(void)
{
    Ctx c = make_ctx();

    /* Rule: on Src(val=V), logical emit Out(result=V). */
    ds_rete_terminal_t *term = make_assert_terminal(
        &c, 1 /* Out */, var(0, 0) /* Src.val */, true /* logical */);

    ds_rete_beta_node_t *beta = NULL;
    ds_rete_beta_node_create(NULL, c.alpha_src, NULL, 0, false, &beta);
    ds_rete_alpha_add_beta_output(c.alpha_src, beta);
    ds_rete_beta_add_terminal(beta, term);

    ds_result_t err;
    ds_rete_token_t *nil = ds_rete_token_create_nil(NULL, NULL, &err);
    ds_rete_beta_left_activate(beta, nil, c.engine);
    ds_rete_token_free(nil);

    c.engine->cycle_generation++;
    ds_rete_fact_t *trig = assert_src(&c, 42);

    uint32_t fired = 0;
    ds_rete_run(c.engine, 0, &fired);

    ds_rete_fact_t *out_fact = NULL;
    for (uint32_t i = 0; i < oa_len(&c.engine->wm_map); i++) {
        ds_rete_fact_t *f = *(ds_rete_fact_t **)ds_oa_val_at(&c.engine->wm_map, i);
        if (!f) continue;
        if (f->schema == c.schema_out &&
            f->slots[0].kind == DS_RETE_VAL_INT &&
            f->slots[0].i    == 42) { out_fact = f; break; }
    }
    if (!out_fact) {
        ds_rete_beta_node_destroy(beta);
        ds_rete_terminal_destroy(term);
        destroy_ctx(&c);
        return fail("TMS: Out(42) not in WM after fire");
    }
    if (out_fact->justif_count != 1) {
        fprintf(stderr, "FAIL: TMS: justif_count want 1 got %u\n",
                out_fact->justif_count);
        ds_rete_beta_node_destroy(beta);
        ds_rete_terminal_destroy(term);
        destroy_ctx(&c);
        return 1;
    }

    uint32_t out_id = out_fact->id; /* save before retract frees the fact */
    ds_rete_wm_retract(c.engine, trig);

    ds_rete_fact_t *still = ds_rete_wm_find_by_id(c.engine, out_id);
    ds_rete_beta_node_destroy(beta);
    ds_rete_terminal_destroy(term);
    destroy_ctx(&c);

    if (still) return fail("TMS: Out(42) should be retracted after supporting fact gone");
    return 0;
}

/* @spec [IRET.12.3] [IRET.12.1] [IRET.12.2] */
static int test_multiple_justifiers(void)
{
    Ctx c = make_ctx();

    /* Rule: on Src, logical emit Out(result=1). Two Src facts justify it. */
    ds_rete_terminal_t *term = make_assert_terminal(
        &c, 1 /* Out */, lit_int(1), true);

    ds_rete_beta_node_t *beta = NULL;
    ds_rete_beta_node_create(NULL, c.alpha_src, NULL, 0, false, &beta);
    ds_rete_alpha_add_beta_output(c.alpha_src, beta);
    ds_rete_beta_add_terminal(beta, term);

    ds_result_t err;
    ds_rete_token_t *nil = ds_rete_token_create_nil(NULL, NULL, &err);
    ds_rete_beta_left_activate(beta, nil, c.engine);
    ds_rete_token_free(nil);

    /* Assert A and B in different cycles so both fire (no refraction). */
    c.engine->cycle_generation++;
    ds_rete_fact_t *fa = assert_src(&c, 10);
    c.engine->cycle_generation++;
    ds_rete_fact_t *fb = assert_src(&c, 20);
    c.engine->cycle_generation++;
    ds_rete_run(c.engine, 0, NULL);

    /* The second emit is a no-op on working memory ([IRET.12.1] step 1), so
       there is one Out(1), and both activations justify it ([IRET.12.3]). */
    ds_rete_fact_t *out = NULL;
    uint32_t outs = 0;
    for (uint32_t i = 0; i < oa_len(&c.engine->wm_map); i++) {
        ds_rete_fact_t *f = *(ds_rete_fact_t **)ds_oa_val_at(&c.engine->wm_map, i);
        if (!f) continue;
        if (f->schema == c.schema_out &&
            f->slots[0].i == 1) { out = f; outs++; }
    }
    if (!out) {
        ds_rete_beta_node_destroy(beta);
        ds_rete_terminal_destroy(term);
        destroy_ctx(&c);
        return fail("multi-just: Out(1) not found");
    }
    if (outs != 1 || out->justif_count != 2) {
        fprintf(stderr, "FAIL: multi-just: want one Out(1) with justif_count 2, "
                "got %u Out(1), justif_count %u\n", outs, out->justif_count);
        ds_rete_beta_node_destroy(beta);
        ds_rete_terminal_destroy(term);
        destroy_ctx(&c);
        return 1;
    }

    uint32_t out_id = out->id;

    ds_rete_wm_retract(c.engine, fa);
    ds_rete_fact_t *still = ds_rete_wm_find_by_id(c.engine, out_id);
    if (!still) {
        ds_rete_beta_node_destroy(beta);
        ds_rete_terminal_destroy(term);
        destroy_ctx(&c);
        return fail("multi-just: Out(1) gone after first retract (should stay)");
    }
    if (still->justif_count != 1) {
        fprintf(stderr, "FAIL: multi-just: after first retract, justif=%u want 1\n",
                still->justif_count);
        ds_rete_beta_node_destroy(beta);
        ds_rete_terminal_destroy(term);
        destroy_ctx(&c);
        return 1;
    }

    ds_rete_wm_retract(c.engine, fb);
    ds_rete_fact_t *gone = ds_rete_wm_find_by_id(c.engine, out_id);

    ds_rete_beta_node_destroy(beta);
    ds_rete_terminal_destroy(term);
    destroy_ctx(&c);

    if (gone) return fail("multi-just: Out(1) should be gone after second retract");
    return 0;
}

static int g_stub_count = 0;
static void stub_fn(const char *r, ds_rete_token_t *t, void *ctx)
{
    (void)r; (void)t; (void)ctx;
    g_stub_count++;
}

static int test_fire_fn_fallback(void)
{
    Ctx c = make_ctx();
    g_stub_count = 0;

    ds_rete_terminal_t *term = NULL;
    ds_rete_terminal_create(istr(c.engine, "r"), 0, &term);
    term->fire_fn = stub_fn;

    ds_rete_fact_t *f = assert_src(&c, 1);
    ds_result_t err;
    ds_rete_token_t *tok = ds_rete_token_create(NULL, f, 0, NULL, NULL, &err);
    c.engine->cycle_generation++;
    ds_rete_terminal_left_activate(term, tok, c.engine);
    ds_rete_token_free(tok);

    ds_rete_run(c.engine, 0, NULL);

    ds_rete_terminal_destroy(term);
    destroy_ctx(&c);

    if (g_stub_count != 1) return fail("fire_fn fallback: not called");
    return 0;
}

int main(void)
{
    int fail_count = 0;

#define RUN(t) do { \
    int _r = (t)(); \
    if (_r) { fprintf(stderr, "  FAIL: " #t "\n"); fail_count++; } \
    else    { printf("  pass: " #t "\n"); } \
} while (0)

    printf("=== test_rete_action ===\n");
    RUN(test_call_action);
    RUN(test_assert_action);
    RUN(test_logical_assert_tms);
    RUN(test_multiple_justifiers);
    RUN(test_fire_fn_fallback);
#undef RUN

    if (fail_count == 0) {
        printf("=== test_rete_action: ALL PASSED ===\n");
        return 0;
    }
    fprintf(stderr, "=== test_rete_action: %d FAILED ===\n", fail_count);
    return 1;
}
