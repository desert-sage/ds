/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * What RT mode enforces:
 *   - ds_rete_run returns DS_ERR_RT_UNSAFE when max_fires is 0 or below
 *     max_fires_rt;
 *   - a JSON path expression faults;
 *   - a builtin not registered rt_safe faults, and an rt_safe one runs;
 *   - init_rt_pools allocates bind_frame_scratch and seeds token_budget.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "libds.h"
#include "fn.h"
#include "rete/engine.h"
#include "rete/eval.h"
#include "rete/expr.h"
#include "rete/fact.h"
#include "rete/pool.h"
#include "rete/schema.h"
#include "rete/schema_reg.h"
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

static int expect_status(const char *what, ds_result_t r, int want)
{
    if (r.status != want) {
        fprintf(stderr, "FAIL: %s: want %d got %d (%s)\n",
                what, want, r.status, r.detail ? r.detail : "(null)");
        return 1;
    }
    return 0;
}

/* Minimal RT engine — no rules, just schemas. */
static ds_rete_engine_t *make_rt_engine(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    ds_rete_engine_set_wm_max(e, 64);
    ds_rete_engine_set_rt_mode(e, true);
    ds_rete_engine_init_rt_pools(e);
    return e;
}

static int test_run_zero_fires_rejected_in_rt(void)
{
    ds_rete_engine_t *e = make_rt_engine();
    uint32_t fired = 0;
    if (expect_status("run max_fires=0 in RT",
                      ds_rete_run(e, 0, &fired),
                      DS_ERR_RT_UNSAFE)) return 1;
    ds_rete_engine_destroy(e);
    return 0;
}

static int test_run_zero_fires_ok_non_rt(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    uint32_t fired = 0;
    if (expect_ok("run max_fires=0 non-RT", ds_rete_run(e, 0, &fired)))
        return 1;
    ds_rete_engine_destroy(e);
    return 0;
}

static int test_run_below_min_fires_rejected(void)
{
    ds_rete_engine_t *e = make_rt_engine();
    ds_rete_engine_set_max_fires_rt(e, 100);
    uint32_t fired = 0;
    /* max_fires=50 < max_fires_rt=100 → reject */
    if (expect_status("run below min_fires",
                      ds_rete_run(e, 50, &fired),
                      DS_ERR_RT_UNSAFE)) return 1;
    /* max_fires=100 == max_fires_rt → accept */
    if (expect_ok("run at min_fires", ds_rete_run(e, 100, &fired)))
        return 1;
    ds_rete_engine_destroy(e);
    return 0;
}

static int test_set_max_fires_rt(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    if (expect_ok("set_max_fires_rt",
                  ds_rete_engine_set_max_fires_rt(e, 42))) return 1;
    if (e->max_fires_rt != 42) return fail("max_fires_rt should be 42");
    ds_rete_engine_destroy(e);
    return 0;
}

static ds_rete_expr_t *lit_str_expr(ds_rete_engine_t *e, const char *s)
{
    ds_rete_expr_t *x = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_STR);
    const char *is;
    ds_rete_intern_cstr(e->intern, s, &is);
    x->lit_str = is;
    return x;
}

/* `[10, 20, 30]` at path `[1]`: a VALID Json read, which answers Int 20
   outside RT (test_rete_builtins.c's test_json_path_expr_node). So only the
   RT guard can fault the RT eval below, and the non-RT eval is checked for
   the value. */
static ds_rete_expr_t *make_json_path_expr(ds_rete_engine_t *e)
{
    ds_rete_expr_t *jp = ds_rete_expr_alloc(DS_RETE_EXPR_JSON_PATH);
    jp->json_path.val  = lit_str_expr(e, "[10, 20, 30]");
    jp->json_path.path = lit_str_expr(e, "[1]");
    return jp;
}

static int test_json_path_blocked_in_rt(void)
{
    ds_rete_engine_t *e = make_rt_engine();
    ds_rete_expr_t *json_expr = make_json_path_expr(e);

    ds_rete_eval_ctx_t ctx = { .engine = e };
    ctx.faulted = false;
    (void)ds_rete_eval(&ctx, json_expr);
    /* The read is valid, so only the RT guard can fault it. */
    if (!ctx.faulted)
        return fail("JSON path in RT mode should be refused by the RT guard");

    ds_rete_expr_free_tree(json_expr);
    ds_rete_engine_destroy(e);
    return 0;
}

static int test_json_path_allowed_non_rt(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    ds_rete_expr_t *json_expr = make_json_path_expr(e);

    ds_rete_eval_ctx_t ctx = { .engine = e };
    ctx.faulted = false;
    ds_rete_val_t result = ds_rete_eval(&ctx, json_expr);
    if (ctx.faulted)
        return fail("JSON path outside RT mode should evaluate, not fault");
    if (result.kind != DS_RETE_VAL_INT || result.i != 20)
        return fail("JSON path outside RT mode should read [10, 20, 30][1] = 20");

    ds_rete_expr_free_tree(json_expr);
    ds_rete_engine_destroy(e);
    return 0;
}

static ds_result_t dummy_fn(struct ds_rete_engine *eng,
                              struct ds_rete_eval_ctx *ctx,
                              ds_rete_val_t *args, uint32_t argc,
                              ds_rete_val_t *out)
{
    (void)eng; (void)ctx; (void)args; (void)argc;
    *out = ds_rete_val_int(42);
    return DS_OK_R;
}

/* Build a CALL expression for a builtin op. Dispatch is by op (no names). */
static ds_rete_expr_t *make_call_expr(uint32_t op)
{
    ds_rete_expr_t *call = ds_rete_expr_alloc(DS_RETE_EXPR_CALL);
    call->call.op        = op;
    call->call.args      = NULL;
    call->call.arg_count = 0;
    return call;
}

/* The handler-less op that hosts the test dummy_fn: FN_LATEST, on
   test_builtin_coverage's KNOWN_UNHANDLED list, so the runtime registers
   nothing there, and its [RDSC.4a.9.5] row is `none`, which `eval_call` does
   not count. So the rt_safe gate is the only thing that can refuse these
   calls. A reserved number cannot host one: it has no row, so `eval_call`
   refuses every call of it as ARTEFACT_LIED before a handler runs. Each test
   registers the dummy, with its own flag, before it evaluates, so sharing the
   op keeps them independent. */
#define TEST_OP_NONSAFE DS_FN_LATEST         /* 112 */
#define TEST_OP_RTSAFE  DS_FN_LATEST
#define TEST_OP_NONRT   DS_FN_LATEST

static int test_non_rt_safe_fn_blocked_in_rt(void)
{
    ds_rete_engine_t *e = make_rt_engine();
    if (expect_ok("register non-safe fn",
                  ds_register_fn(TEST_OP_NONSAFE, dummy_fn))) return 1;

    ds_rete_expr_t *call = make_call_expr(TEST_OP_NONSAFE);
    ds_rete_eval_ctx_t ctx = { .engine = e };
    ctx.faulted = false;
    ds_rete_val_t result = ds_rete_eval(&ctx, call);
    if (!ctx.faulted)
        return fail("non-rt_safe builtin in RT mode should return ERR");

    ds_rete_expr_free_tree(call);
    ds_rete_engine_destroy(e);
    return 0;
}

static int test_rt_safe_fn_allowed_in_rt(void)
{
    ds_rete_engine_t *e = make_rt_engine();
    if (expect_ok("register rt_safe fn",
                  ds_register_fn_rt(TEST_OP_RTSAFE, dummy_fn))) return 1;

    ds_rete_expr_t *call = make_call_expr(TEST_OP_RTSAFE);
    ds_rete_eval_ctx_t ctx = { .engine = e };
    ctx.faulted = false;
    ds_rete_val_t result = ds_rete_eval(&ctx, call);
    if (result.kind != DS_RETE_VAL_INT || result.i != 42)
        return fail("rt_safe builtin should return 42");

    ds_rete_expr_free_tree(call);
    ds_rete_engine_destroy(e);
    return 0;
}

static int test_fn_allowed_non_rt(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    if (expect_ok("register fn non-RT",
                  ds_register_fn(TEST_OP_NONRT, dummy_fn))) return 1;

    ds_rete_expr_t *call = make_call_expr(TEST_OP_NONRT);
    ds_rete_eval_ctx_t ctx = { .engine = e };
    ctx.faulted = false;
    ds_rete_val_t result = ds_rete_eval(&ctx, call);
    if (result.kind != DS_RETE_VAL_INT || result.i != 42)
        return fail("non-RT builtin should work without rt_safe flag");

    ds_rete_expr_free_tree(call);
    ds_rete_engine_destroy(e);
    return 0;
}

static int test_bind_frame_scratch_allocated(void)
{
    ds_rete_engine_t *e = make_rt_engine();
    if (e->bind_frame_scratch == NULL)
        return fail("bind_frame_scratch should be allocated in RT mode");
    if (e->bind_frame_scratch_cap < 16)
        return fail("bind_frame_scratch_cap should be at least 16");
    ds_rete_engine_destroy(e);
    return 0;
}

static int test_bind_frame_scratch_null_non_rt(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    if (e->bind_frame_scratch != NULL)
        return fail("bind_frame_scratch should be NULL in non-RT mode");
    ds_rete_engine_destroy(e);
    return 0;
}

/* init_rt_pools seeds token_budget to the pool capacity: ds_rete_run resets
 * it per pump, and a fact asserted in RT mode before the first pump
 * propagates on it. */
static int test_token_budget_seeded_by_init_rt_pools(void)
{
    ds_rete_engine_t *e = make_rt_engine();
    if (e->token_pool_cap == 0)
        return fail("token_pool_cap should be set after init_rt_pools");
    if (e->token_budget != e->token_pool_cap)
        return fail("token_budget should be seeded to token_pool_cap by "
                    "init_rt_pools (pre-first-pump assert must not -607)");
    ds_rete_engine_destroy(e);
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

    printf("=== test_rete_rt_guards ===\n");
    RUN(test_run_zero_fires_rejected_in_rt);
    RUN(test_run_zero_fires_ok_non_rt);
    RUN(test_run_below_min_fires_rejected);
    RUN(test_set_max_fires_rt);
    RUN(test_json_path_blocked_in_rt);
    RUN(test_json_path_allowed_non_rt);
    RUN(test_non_rt_safe_fn_blocked_in_rt);
    RUN(test_rt_safe_fn_allowed_in_rt);
    RUN(test_fn_allowed_non_rt);
    RUN(test_bind_frame_scratch_allocated);
    RUN(test_bind_frame_scratch_null_non_rt);
    RUN(test_token_budget_seeded_by_init_rt_pools);
#undef RUN

    if (fail_count == 0) {
        printf("=== test_rete_rt_guards: ALL PASSED ===\n");
        return 0;
    }
    fprintf(stderr, "=== test_rete_rt_guards: %d FAILED ===\n", fail_count);
    return 1;
}
