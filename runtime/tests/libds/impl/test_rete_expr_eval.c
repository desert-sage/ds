/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The expression evaluator (IRET.9), builtin dispatch (IRET.13), and join
 * tests in the beta network:
 *   - All literal kinds
 *   - VAR: reading from token / right_fact slots
 *   - BINOP: arithmetic, integer-only, comparison, logical, bitwise
 *   - Short-circuit AND/OR
 *   - UNOP: not, bit-not, negate
 *   - Type errors latch `ctx.faulted` ([LEXP.7.12]); the value is inert
 *   - NOW → clock value
 *   - IF conditional
 *   - BIND / BIND_REF (let bindings)
 *   - INTERP: an interpolated string's primitives ([LGRA.2.9.6.10])
 *   - CALL → builtin dispatch
 *   - join_tests_pass wired into beta right-activate (integration)
 */
#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "libds.h"
#include "builtin_fn.h"
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
#include "fn.h"
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
    ds_rete_schema_t    *schema;  /* two Int slots: "a", "b" */
} Ctx;

static const char *istr(ds_rete_engine_t *e, const char *s)
{
    const char *p; ds_rete_intern_cstr(e->intern, s, &p); return p;
}

static Ctx make_ctx(void)
{
    Ctx c = {0};
    ds_rete_engine_create(&c.engine);
    /* Int?: test_kleene_null asserts a fact with two null slots, and
       ds_rete_wm_assert_ex enforces [LNUL.3.1]. */
    ds_rete_slot_desc_t slots[2] = {
        { .name = "a", .type = DS_RETE_VAL_INT, .nullable = true },
        { .name = "b", .type = DS_RETE_VAL_INT, .nullable = true },
    };
    ds_rete_schema_register(c.engine, "S", DS_RETE_SCOPE_PLAIN, 0,
                             slots, 2, &c.schema);
    return c;
}

static void destroy_ctx(Ctx *c) { ds_rete_engine_destroy(c->engine); }

static ds_rete_fact_t *make_fact(Ctx *c, int64_t a, int64_t b)
{
    ds_rete_val_t vals[2] = { ds_rete_val_int(a), ds_rete_val_int(b) };
    ds_rete_fact_t *f = NULL;
    ds_rete_wm_assert(c->engine, 0, vals, &f);
    return f;
}

/* An eval context with one fact in the token (pattern 0). Its fault latch,
   ctx.faulted, is sticky, so each case clears it before an eval it judges. */
static ds_rete_eval_ctx_t make_eval_ctx(Ctx *c, ds_rete_fact_t *left_fact,
                                         ds_rete_fact_t *right_fact)
{
    static ds_rete_fact_t *facts[1];
    static ds_rete_token_t tok;
    facts[0]            = left_fact;
    tok.facts           = facts;
    tok.fact_count      = 1;
    tok.creation_timetag = 0;
    tok.hash            = 0;
    tok.next            = NULL;
    return (ds_rete_eval_ctx_t){
        .token      = &tok,
        .right_fact = right_fact,
        .bind_frame = NULL,
        .bind_count = 0,
        .engine     = c->engine,
    };
}

static int test_literals(void)
{
    Ctx c = make_ctx();
    ds_rete_eval_ctx_t ctx = make_eval_ctx(&c, NULL, NULL);
    ds_rete_expr_t *e;
    ds_rete_val_t v;

    e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_INT);
    e->lit_int = 42;
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e);
    ds_rete_expr_free_tree(e);
    if (v.kind != DS_RETE_VAL_INT || v.i != 42) return fail("LIT_INT");

    e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_FLOAT);
    e->lit_float = 3.14;
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e);
    ds_rete_expr_free_tree(e);
    if (v.kind != DS_RETE_VAL_FLOAT || v.f != 3.14) return fail("LIT_FLOAT");

    e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_BOOL);
    e->lit_bool = true;
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e);
    ds_rete_expr_free_tree(e);
    if (v.kind != DS_RETE_VAL_BOOL || !v.b) return fail("LIT_BOOL");

    e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_STR);
    e->lit_str = istr(c.engine, "hello");
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e);
    ds_rete_expr_free_tree(e);
    if (v.kind != DS_RETE_VAL_STR || v.s.ptr != istr(c.engine, "hello"))
        return fail("LIT_STR");

    destroy_ctx(&c);
    return 0;
}

static int test_var_from_token(void)
{
    Ctx c = make_ctx();
    ds_rete_fact_t *f = make_fact(&c, 7, 13);
    ds_rete_eval_ctx_t ctx = make_eval_ctx(&c, f, NULL);

    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
    e->var.pattern_index = 0;
    e->var.slot_index    = 1; /* slot "b" */
    ctx.faulted = false;
    ds_rete_val_t v = ds_rete_eval(&ctx, e);
    ds_rete_expr_free_tree(e);

    if (v.kind != DS_RETE_VAL_INT || v.i != 13) return fail("VAR from token");
    destroy_ctx(&c);
    return 0;
}

static int test_var_right_fact(void)
{
    Ctx c = make_ctx();
    ds_rete_fact_t *left  = make_fact(&c, 1, 2);
    ds_rete_fact_t *right = make_fact(&c, 99, 88);
    ds_rete_eval_ctx_t ctx = make_eval_ctx(&c, left, right);

    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
    e->var.pattern_index = DS_RETE_VAR_RIGHT_FACT;
    e->var.slot_index    = 0; /* slot "a" */
    ctx.faulted = false;
    ds_rete_val_t v = ds_rete_eval(&ctx, e);
    ds_rete_expr_free_tree(e);

    if (v.kind != DS_RETE_VAL_INT || v.i != 99) return fail("VAR right_fact");
    destroy_ctx(&c);
    return 0;
}

static ds_rete_expr_t *lit_int(int64_t i)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_INT);
    e->lit_int = i;
    return e;
}
static ds_rete_expr_t *lit_float(double f)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_FLOAT);
    e->lit_float = f;
    return e;
}
static ds_rete_expr_t *lit_bool(bool b)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_BOOL);
    e->lit_bool = b;
    return e;
}
static ds_rete_expr_t *lit_null(void)
{
    return ds_rete_expr_alloc(DS_RETE_EXPR_LIT_NULL);
}
static ds_rete_expr_t *binop(ds_rete_binop_t op,
                              ds_rete_expr_t *left, ds_rete_expr_t *right)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_BINOP);
    e->binop.op    = op;
    e->binop.left  = left;
    e->binop.right = right;
    return e;
}
static ds_rete_expr_t *unop(ds_rete_unop_t op, ds_rete_expr_t *operand)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_UNOP);
    e->unop.op      = op;
    e->unop.operand = operand;
    return e;
}

static int test_arith_int(void)
{
    Ctx c = make_ctx();
    ds_rete_eval_ctx_t ctx = make_eval_ctx(&c, NULL, NULL);
    ds_rete_val_t v;

    ds_rete_expr_t *e = binop(DS_RETE_BINOP_ADD, lit_int(10), lit_int(5));
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e); ds_rete_expr_free_tree(e);
    if (v.kind != DS_RETE_VAL_INT || v.i != 15) return fail("ADD int");

    e = binop(DS_RETE_BINOP_SUB, lit_int(10), lit_int(3));
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e); ds_rete_expr_free_tree(e);
    if (v.kind != DS_RETE_VAL_INT || v.i != 7)  return fail("SUB int");

    e = binop(DS_RETE_BINOP_MUL, lit_int(4), lit_int(7));
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e); ds_rete_expr_free_tree(e);
    if (v.kind != DS_RETE_VAL_INT || v.i != 28) return fail("MUL int");

    /* `/` is ALWAYS true division → Float even for Int/Int operands
       (LEXP.7.4 / LEXP.12.2, Python-3 semantics): 20 / 4 == 5.0, not 5.
       Floor division (`//`, IDIV below) is the Int-yielding operator. */
    e = binop(DS_RETE_BINOP_DIV, lit_int(20), lit_int(4));
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e); ds_rete_expr_free_tree(e);
    if (v.kind != DS_RETE_VAL_FLOAT || v.f != 5.0)  return fail("DIV int→float");

    e = binop(DS_RETE_BINOP_IDIV, lit_int(17), lit_int(3));
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e); ds_rete_expr_free_tree(e);
    if (v.kind != DS_RETE_VAL_INT || v.i != 5)  return fail("IDIV");

    e = binop(DS_RETE_BINOP_MOD, lit_int(17), lit_int(3));
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e); ds_rete_expr_free_tree(e);
    if (v.kind != DS_RETE_VAL_INT || v.i != 2)  return fail("MOD");

    destroy_ctx(&c);
    return 0;
}

static int test_arith_float(void)
{
    Ctx c = make_ctx();
    ds_rete_eval_ctx_t ctx = make_eval_ctx(&c, NULL, NULL);
    ds_rete_val_t v;

    ds_rete_expr_t *e = binop(DS_RETE_BINOP_ADD, lit_float(1.5), lit_float(2.5));
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e); ds_rete_expr_free_tree(e);
    if (v.kind != DS_RETE_VAL_FLOAT || v.f != 4.0) return fail("ADD float");

    /* Int + Float promotion */
    e = binop(DS_RETE_BINOP_MUL, lit_int(3), lit_float(2.0));
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e); ds_rete_expr_free_tree(e);
    if (v.kind != DS_RETE_VAL_FLOAT || v.f != 6.0) return fail("MUL int+float");

    destroy_ctx(&c);
    return 0;
}

static int test_div_by_zero(void)
{
    Ctx c = make_ctx();
    ds_rete_eval_ctx_t ctx = make_eval_ctx(&c, NULL, NULL);

    ds_rete_expr_t *e = binop(DS_RETE_BINOP_DIV, lit_int(10), lit_int(0));
    ctx.faulted = false;
    ds_rete_val_t v = ds_rete_eval(&ctx, e);
    ds_rete_expr_free_tree(e);

    if (!ctx.faulted) return fail("div by zero should be ERR");
    destroy_ctx(&c);
    return 0;
}

/* The FLOAT arm of `/`, which is a different branch of `ds_rete_eval` from the
 * Int arm `test_div_by_zero` covers: eval.c reaches the float switch whenever
 * either operand is a Float. A Float operand makes the division IEEE 754's
 * ([LEXP.7.15.1], [LDET.3.6.2]): a zero divisor gives ±Inf, or NaN for
 * `0.0 / 0.0`, and does not trap. Only an all-Int division traps.
 *
 * Three operand shapes, because `numeric_pair` promotes: Float/Float,
 * Float/Int and Int/Float. Each one answers IEEE's value with no fault, and the
 * sign of the infinity follows the signs of the operands. */
static int test_div_by_zero_float(void)
{
    Ctx c = make_ctx();
    ds_rete_eval_ctx_t ctx = make_eval_ctx(&c, NULL, NULL);
    ds_rete_val_t v;
    ds_rete_expr_t *e;

    e = binop(DS_RETE_BINOP_DIV, lit_float(10.0), lit_float(0.0));
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e);
    ds_rete_expr_free_tree(e);
    if (ctx.faulted || v.kind != DS_RETE_VAL_FLOAT || !(isinf(v.f) && v.f > 0))
        return fail("10.0 / 0.0 should be +inf");

    e = binop(DS_RETE_BINOP_DIV, lit_float(-10.0), lit_int(0));
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e);
    ds_rete_expr_free_tree(e);
    if (ctx.faulted || v.kind != DS_RETE_VAL_FLOAT || !(isinf(v.f) && v.f < 0))
        return fail("-10.0 / 0 should be -inf");

    e = binop(DS_RETE_BINOP_DIV, lit_int(10), lit_float(-0.0));
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e);
    ds_rete_expr_free_tree(e);
    if (ctx.faulted || v.kind != DS_RETE_VAL_FLOAT || !(isinf(v.f) && v.f < 0))
        return fail("10 / -0.0 should be -inf");

    e = binop(DS_RETE_BINOP_DIV, lit_float(0.0), lit_float(0.0));
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e);
    ds_rete_expr_free_tree(e);
    if (ctx.faulted || v.kind != DS_RETE_VAL_FLOAT || !isnan(v.f))
        return fail("0.0 / 0.0 should be NaN");

    /* A nonzero Float divisor divides, so a `/` that always faults fails. */
    e = binop(DS_RETE_BINOP_DIV, lit_float(10.0), lit_float(4.0));
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e);
    ds_rete_expr_free_tree(e);
    if (v.kind != DS_RETE_VAL_FLOAT || v.f != 2.5) return fail("10.0 / 4.0 should be 2.5");

    destroy_ctx(&c);
    return 0;
}

static int test_cmp(void)
{
    Ctx c = make_ctx();
    ds_rete_eval_ctx_t ctx = make_eval_ctx(&c, NULL, NULL);
    ds_rete_val_t v;

#define CHECK_CMP(op, lhs, rhs, want) do { \
    ds_rete_expr_t *e_ = binop(op, lit_int(lhs), lit_int(rhs)); \
    ctx.faulted = false; \
    v = ds_rete_eval(&ctx, e_); ds_rete_expr_free_tree(e_); \
    if (v.kind != DS_RETE_VAL_BOOL || v.b != (want)) \
        return fail(#op "(" #lhs "," #rhs ") wrong"); \
} while (0)

    CHECK_CMP(DS_RETE_BINOP_EQ,  5, 5, true);
    CHECK_CMP(DS_RETE_BINOP_EQ,  5, 6, false);
    CHECK_CMP(DS_RETE_BINOP_NE,  5, 6, true);
    CHECK_CMP(DS_RETE_BINOP_LT,  3, 7, true);
    CHECK_CMP(DS_RETE_BINOP_LT,  7, 3, false);
    CHECK_CMP(DS_RETE_BINOP_GT,  7, 3, true);
    CHECK_CMP(DS_RETE_BINOP_LE,  3, 3, true);
    CHECK_CMP(DS_RETE_BINOP_LE,  4, 3, false);
    CHECK_CMP(DS_RETE_BINOP_GE,  3, 3, true);
    CHECK_CMP(DS_RETE_BINOP_GE,  2, 3, false);

#undef CHECK_CMP
    destroy_ctx(&c);
    return 0;
}

static int test_logical(void)
{
    Ctx c = make_ctx();
    ds_rete_eval_ctx_t ctx = make_eval_ctx(&c, NULL, NULL);
    ds_rete_val_t v;

    /* AND: false && (would-be-type-error) → false without evaluating RHS */
    ds_rete_expr_t *and_e = binop(DS_RETE_BINOP_AND,
        lit_bool(false),
        binop(DS_RETE_BINOP_ADD, lit_int(1), lit_bool(true))); /* type error */
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, and_e);
    ds_rete_expr_free_tree(and_e);
    if (v.kind != DS_RETE_VAL_BOOL || v.b) return fail("AND short-circuit");

    /* OR: true || (would-be-type-error) → true without evaluating RHS */
    ds_rete_expr_t *or_e = binop(DS_RETE_BINOP_OR,
        lit_bool(true),
        binop(DS_RETE_BINOP_ADD, lit_int(1), lit_bool(true)));
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, or_e);
    ds_rete_expr_free_tree(or_e);
    if (v.kind != DS_RETE_VAL_BOOL || !v.b) return fail("OR short-circuit");

    /* AND both true */
    ds_rete_expr_t *both = binop(DS_RETE_BINOP_AND, lit_bool(true), lit_bool(true));
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, both); ds_rete_expr_free_tree(both);
    if (v.kind != DS_RETE_VAL_BOOL || !v.b) return fail("AND both true");

    destroy_ctx(&c);
    return 0;
}

static int test_unop(void)
{
    Ctx c = make_ctx();
    ds_rete_eval_ctx_t ctx = make_eval_ctx(&c, NULL, NULL);
    ds_rete_val_t v;

    ds_rete_expr_t *e = unop(DS_RETE_UNOP_NOT, lit_bool(true));
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e); ds_rete_expr_free_tree(e);
    if (v.kind != DS_RETE_VAL_BOOL || v.b) return fail("NOT true");

    e = unop(DS_RETE_UNOP_BNOT, lit_int(0));
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e); ds_rete_expr_free_tree(e);
    if (v.kind != DS_RETE_VAL_INT || v.i != ~(int64_t)0) return fail("BNOT 0");

    e = unop(DS_RETE_UNOP_NEG, lit_int(5));
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e); ds_rete_expr_free_tree(e);
    if (v.kind != DS_RETE_VAL_INT || v.i != -5) return fail("NEG int");

    e = unop(DS_RETE_UNOP_NEG, lit_float(2.5));
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e); ds_rete_expr_free_tree(e);
    if (v.kind != DS_RETE_VAL_FLOAT || v.f != -2.5) return fail("NEG float");

    destroy_ctx(&c);
    return 0;
}

static int test_bitwise(void)
{
    Ctx c = make_ctx();
    ds_rete_eval_ctx_t ctx = make_eval_ctx(&c, NULL, NULL);
    ds_rete_val_t v;

    ds_rete_expr_t *e = binop(DS_RETE_BINOP_BAND, lit_int(0xF0), lit_int(0x0F));
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e); ds_rete_expr_free_tree(e);
    if (v.kind != DS_RETE_VAL_INT || v.i != 0) return fail("BAND");

    e = binop(DS_RETE_BINOP_BOR, lit_int(0xF0), lit_int(0x0F));
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e); ds_rete_expr_free_tree(e);
    if (v.kind != DS_RETE_VAL_INT || v.i != 0xFF) return fail("BOR");

    e = binop(DS_RETE_BINOP_BXOR, lit_int(0xFF), lit_int(0x0F));
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e); ds_rete_expr_free_tree(e);
    if (v.kind != DS_RETE_VAL_INT || v.i != 0xF0) return fail("BXOR");

    e = binop(DS_RETE_BINOP_SHL, lit_int(1), lit_int(3));
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e); ds_rete_expr_free_tree(e);
    if (v.kind != DS_RETE_VAL_INT || v.i != 8) return fail("SHL");

    e = binop(DS_RETE_BINOP_SHR, lit_int(8), lit_int(2));
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e); ds_rete_expr_free_tree(e);
    if (v.kind != DS_RETE_VAL_INT || v.i != 2) return fail("SHR");

    destroy_ctx(&c);
    return 0;
}

static int test_type_error(void)
{
    Ctx c = make_ctx();
    ds_rete_eval_ctx_t ctx = make_eval_ctx(&c, NULL, NULL);

    /* Int + Bool → ERR */
    ds_rete_expr_t *e = binop(DS_RETE_BINOP_ADD, lit_int(1), lit_bool(true));
    ctx.faulted = false;
    ds_rete_val_t v = ds_rete_eval(&ctx, e);
    ds_rete_expr_free_tree(e);
    if (!ctx.faulted) return fail("type error should be ERR");

    destroy_ctx(&c);
    return 0;
}

static int test_now(void)
{
    Ctx c = make_ctx();
    ds_rete_eval_ctx_t ctx = make_eval_ctx(&c, NULL, NULL);

    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_NOW);
    ctx.faulted = false;
    ds_rete_val_t v = ds_rete_eval(&ctx, e);
    ds_rete_expr_free_tree(e);

    /* now() is a zoned Time (utc_ns, tz_offset 0); test_rete_time.c covers
       the Time kind. */
    if (v.kind != DS_RETE_VAL_TIME) return fail("NOW should return Time");
    if (v.time.utc_ns <= 0) return fail("NOW utc_ns should be positive");
    if (v.time.tz_offset_s != 0) return fail("NOW tz offset should be 0");

    destroy_ctx(&c);
    return 0;
}

static int test_if(void)
{
    Ctx c = make_ctx();
    ds_rete_eval_ctx_t ctx = make_eval_ctx(&c, NULL, NULL);
    ds_rete_val_t v;

    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_IF);
    e->if_.cond  = lit_bool(true);
    e->if_.then_ = lit_int(10);
    e->if_.else_ = lit_int(20);
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e); ds_rete_expr_free_tree(e);
    if (v.kind != DS_RETE_VAL_INT || v.i != 10) return fail("IF true branch");

    e = ds_rete_expr_alloc(DS_RETE_EXPR_IF);
    e->if_.cond  = lit_bool(false);
    e->if_.then_ = lit_int(10);
    e->if_.else_ = lit_int(20);
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, e); ds_rete_expr_free_tree(e);
    if (v.kind != DS_RETE_VAL_INT || v.i != 20) return fail("IF false branch");

    destroy_ctx(&c);
    return 0;
}

static int test_bind(void)
{
    Ctx c = make_ctx();
    ds_rete_val_t bind_frame[4] = {0};
    ds_rete_eval_ctx_t ctx = make_eval_ctx(&c, NULL, NULL);
    ctx.bind_frame = bind_frame;
    ctx.bind_count = 4;

    /* BIND index=2 ← 42; then BIND_REF index=2 */
    ds_rete_expr_t *bind_e = ds_rete_expr_alloc(DS_RETE_EXPR_BIND);
    bind_e->bind.bind_index = 2;
    bind_e->bind.expr       = lit_int(42);
    ctx.faulted = false;
    ds_rete_val_t v = ds_rete_eval(&ctx, bind_e);
    ds_rete_expr_free_tree(bind_e);
    if (v.kind != DS_RETE_VAL_INT || v.i != 42) return fail("BIND result");
    if (bind_frame[2].kind != DS_RETE_VAL_INT || bind_frame[2].i != 42)
        return fail("BIND frame stored");

    ds_rete_expr_t *ref_e = ds_rete_expr_alloc(DS_RETE_EXPR_BIND_REF);
    ref_e->bind_ref.bind_index = 2;
    ctx.faulted = false;
    v = ds_rete_eval(&ctx, ref_e);
    ds_rete_expr_free_tree(ref_e);
    if (v.kind != DS_RETE_VAL_INT || v.i != 42) return fail("BIND_REF read");

    destroy_ctx(&c);
    return 0;
}

/* INTERP ([RLOW.6.4], [LGRA.2.9.6.10], [LGRA.2.9.6.4]): an interpolated
 * string is one node over resolved primitives. The tests cover concatenation,
 * scalar coercion, and one vector per rendering rule. */

static ds_rete_expr_t *interp_new(uint32_t n)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_INTERP);
    e->interp.prim_count = n;
    e->interp.prims = calloc(n, sizeof(ds_rete_fprim_t));
    return e;
}

static ds_rete_expr_t *str_lit(ds_rete_engine_t *eng, const char *s)
{
    ds_rete_expr_t *x = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_STR);
    x->lit_str = istr(eng, s);
    return x;
}

static void prim_text(ds_rete_fprim_t *p, ds_rete_engine_t *eng, const char *s)
{
    p->kind = DS_RETE_FPRIM_TEXT;
    p->text = istr(eng, s);
    p->text_len = (uint32_t) strlen(s);
}

/* Render a whole INTERP; NULL when it faulted. The result lives in the arena. */
static const char *render(Ctx *c, ds_rete_eval_ctx_t *ctx, ds_rete_expr_t *e)
{
    (void)c;
    ctx->faulted = false;
    ds_rete_val_t v = ds_rete_eval(ctx, e);
    ds_rete_expr_free_tree(e);
    if (ctx->faulted || v.kind != DS_RETE_VAL_STR) return NULL;
    return v.s.ptr;
}

static int test_interp_concat(void)
{
    Ctx c = make_ctx();
    ds_rete_eval_ctx_t ctx = make_eval_ctx(&c, NULL, NULL);

    /* "cores=" {2} " ok=" {true} " t=" {1.5} -> "cores=2 ok=true t=1.5":
       text primitives as written, every value in its canonical text. */
    ds_rete_expr_t *e = interp_new(6);
    prim_text(&e->interp.prims[0], c.engine, "cores=");
    e->interp.prims[1].kind = DS_RETE_FPRIM_VALUE; e->interp.prims[1].value = lit_int(2);
    prim_text(&e->interp.prims[2], c.engine, " ok=");
    e->interp.prims[3].kind = DS_RETE_FPRIM_VALUE; e->interp.prims[3].value = lit_bool(true);
    prim_text(&e->interp.prims[4], c.engine, " t=");
    e->interp.prims[5].kind = DS_RETE_FPRIM_VALUE; e->interp.prims[5].value = lit_float(1.5);
    const char *s = render(&c, &ctx, e);
    if (!s || strcmp(s, "cores=2 ok=true t=1.5") != 0) {
        fprintf(stderr, "FAIL: INTERP concat: got '%s'\n", s ? s : "(fault)");
        return 1;
    }

    /* An empty INTERP is "" */
    s = render(&c, &ctx, interp_new(0));
    if (!s || s[0] != '\0') return fail("INTERP empty");

    destroy_ctx(&c);
    return 0;
}

/* One ValuePrim under a spec: render it alone and compare. */
typedef struct {
    ds_rete_ftype_t  type;
    ds_rete_falign_t align;
    bool             plus, zero, has_precision;
    uint32_t         width, precision;
} spec_t;

static int check_value(Ctx *c, ds_rete_eval_ctx_t *ctx, spec_t sp,
                       ds_rete_expr_t *value, const char *want, const char *what)
{
    ds_rete_expr_t *e = interp_new(1);
    ds_rete_fprim_t *p = &e->interp.prims[0];
    p->kind = DS_RETE_FPRIM_VALUE;
    p->value = value;
    p->type = sp.type; p->align = sp.align;
    p->plus = sp.plus; p->zero = sp.zero;
    p->has_precision = sp.has_precision;
    p->width = sp.width; p->precision = sp.precision;
    const char *s = render(c, ctx, e);
    if (want == NULL) {              /* a kind the spec does not take */
        if (s != NULL) {
            fprintf(stderr, "FAIL: %s: rendered '%s', want a fault\n", what, s);
            return 1;
        }
        return 0;
    }
    if (!s || strcmp(s, want) != 0) {
        fprintf(stderr, "FAIL: %s: got '%s', want '%s'\n", what, s ? s : "(fault)", want);
        return 1;
    }
    return 0;
}

static int test_interp_value_rules(void)
{
    Ctx c = make_ctx();
    ds_rete_eval_ctx_t ctx = make_eval_ctx(&c, NULL, NULL);
    int bad = 0;
    const spec_t none = { 0 };
    #define SPEC(...) ((spec_t){ __VA_ARGS__ })
    #define STR(s) str_lit(c.engine, (s))

    /* No type: the canonical text of each kind. */
    bad += check_value(&c, &ctx, none, lit_int(-42), "-42", "canonical Int");
    bad += check_value(&c, &ctx, none, lit_float(42.0), "42.0", "canonical Float keeps .0");
    bad += check_value(&c, &ctx, none, lit_float(-0.0), "-0.0", "canonical -0.0");
    bad += check_value(&c, &ctx, none, lit_bool(false), "false", "canonical Bool");
    bad += check_value(&c, &ctx, none, STR("ab"), "ab", "canonical String");

    /* The width, and the default alignment: a number right, a String left. */
    bad += check_value(&c, &ctx, SPEC(.width = 5), lit_int(42), "   42", "number aligns right");
    bad += check_value(&c, &ctx, SPEC(.width = 5), STR("ab"), "ab   ", "String aligns left");
    bad += check_value(&c, &ctx, SPEC(.width = 6), lit_bool(true), "true  ", "Bool aligns left");
    bad += check_value(&c, &ctx, SPEC(.width = 5, .align = DS_RETE_FALIGN_LEFT), lit_int(42),
                       "42   ", "explicit <");
    bad += check_value(&c, &ctx, SPEC(.width = 5, .align = DS_RETE_FALIGN_RIGHT), STR("ab"),
                       "   ab", "explicit >");
    bad += check_value(&c, &ctx, SPEC(.width = 2), lit_int(12345), "12345", "never truncated");

    /* The sign, and zero padding between it and the digits. */
    bad += check_value(&c, &ctx, SPEC(.type = DS_RETE_FTYPE_D, .plus = true), lit_int(42),
                       "+42", "+ on a positive");
    bad += check_value(&c, &ctx, SPEC(.type = DS_RETE_FTYPE_D, .plus = true), lit_int(0),
                       "+0", "+ on zero");
    bad += check_value(&c, &ctx, SPEC(.type = DS_RETE_FTYPE_D, .zero = true, .width = 6),
                       lit_int(-42), "-00042", "0 after the sign");
    bad += check_value(&c, &ctx, SPEC(.type = DS_RETE_FTYPE_D, .width = 6), lit_int(-42),
                       "   -42", "spaces before the sign");

    /* x, X, b: the magnitude, a `-` for a negative, no prefix. */
    bad += check_value(&c, &ctx, SPEC(.type = DS_RETE_FTYPE_X_LOWER), lit_int(255), "ff", "x");
    bad += check_value(&c, &ctx, SPEC(.type = DS_RETE_FTYPE_X_UPPER), lit_int(255), "FF", "X");
    bad += check_value(&c, &ctx, SPEC(.type = DS_RETE_FTYPE_X_LOWER), lit_int(-255), "-ff",
                       "negative hexadecimal is sign-magnitude");
    bad += check_value(&c, &ctx, SPEC(.type = DS_RETE_FTYPE_B), lit_int(5), "101", "b");
    bad += check_value(&c, &ctx, SPEC(.type = DS_RETE_FTYPE_B, .zero = true, .width = 6),
                       lit_int(-5), "-00101", "b, zero padded");
    bad += check_value(&c, &ctx, SPEC(.type = DS_RETE_FTYPE_X_LOWER), lit_int(INT64_MIN),
                       "-8000000000000000", "x of INT64_MIN");

    /* f: the binary value correctly rounded to the precision, ties to even
       ([LDET.3.2.8]), six decimals by default; an Int as the Float of its
       value. 2.675 is below 2.675 in binary, so it rounds to 2.67. */
    bad += check_value(&c, &ctx, SPEC(.type = DS_RETE_FTYPE_F, .has_precision = true,
                       .precision = 2), lit_float(3.14159), "3.14", "f .2");
    bad += check_value(&c, &ctx, SPEC(.type = DS_RETE_FTYPE_F, .has_precision = true,
                       .precision = 2), lit_float(2.675), "2.67", "f .2 of binary 2.675");
    bad += check_value(&c, &ctx, SPEC(.type = DS_RETE_FTYPE_F), lit_float(0.5), "0.500000",
                       "f defaults to six");
    bad += check_value(&c, &ctx, SPEC(.type = DS_RETE_FTYPE_F, .has_precision = true,
                       .precision = 1), lit_int(3), "3.0", "f of an Int");
    bad += check_value(&c, &ctx, SPEC(.type = DS_RETE_FTYPE_F, .has_precision = true,
                       .precision = 1), lit_float(-0.0), "-0.0", "f keeps -0.0's sign");
    bad += check_value(&c, &ctx, SPEC(.type = DS_RETE_FTYPE_F, .width = 6), lit_float(-INFINITY),
                       "  -inf", "f of -inf");
    bad += check_value(&c, &ctx, SPEC(.type = DS_RETE_FTYPE_F, .has_precision = true,
                       .precision = 0), lit_float(1e20), "100000000000000000000", "f of 1e20");

    /* s, and code points: precision keeps at most that many, width counts them. */
    bad += check_value(&c, &ctx, SPEC(.type = DS_RETE_FTYPE_S, .has_precision = true,
                       .precision = 2), STR("h\xc3\xa9llo"), "h\xc3\xa9",
                       "s precision cuts on a code point");
    bad += check_value(&c, &ctx, SPEC(.type = DS_RETE_FTYPE_S, .width = 3), STR("\xc3\xa9"),
                       "\xc3\xa9  ", "width counts code points");
    bad += check_value(&c, &ctx, SPEC(.has_precision = true, .precision = 1), STR("ab"), "a",
                       "a String takes a precision with no type");

    /* Null is "", with no padding ([LGRA.2.9.6.2]). */
    bad += check_value(&c, &ctx, SPEC(.width = 5), lit_null(), "", "null renders empty");

    /* A kind the spec does not take faults rather than rendering somehow. */
    bad += check_value(&c, &ctx, SPEC(.type = DS_RETE_FTYPE_D), lit_float(1.5), NULL, "d on Float");
    bad += check_value(&c, &ctx, SPEC(.type = DS_RETE_FTYPE_S), lit_int(1), NULL, "s on Int");
    bad += check_value(&c, &ctx, SPEC(.type = DS_RETE_FTYPE_F), lit_bool(true), NULL, "f on Bool");

    /* A PART the kind does not take faults too, never rendered with the part
       dropped ([LGRA.2.9.6.5], at run time by LGRA.2.9.6.11): a sign or `0`
       on a String or a Bool, a precision with no type on anything but a
       String, a precision on an integer type. */
    bad += check_value(&c, &ctx, SPEC(.plus = true), lit_bool(true), NULL, "+ on Bool");
    bad += check_value(&c, &ctx, SPEC(.plus = true), STR("ab"), NULL, "+ on String");
    bad += check_value(&c, &ctx, SPEC(.zero = true, .width = 5), STR("ab"), NULL, "0 on String");
    bad += check_value(&c, &ctx, SPEC(.type = DS_RETE_FTYPE_S, .plus = true), STR("ab"), NULL,
                       "+s on String");
    bad += check_value(&c, &ctx, SPEC(.has_precision = true, .precision = 3), lit_int(7), NULL,
                       ".3 on Int");
    bad += check_value(&c, &ctx, SPEC(.has_precision = true, .precision = 3), lit_float(1.5), NULL,
                       ".3 on Float");
    bad += check_value(&c, &ctx, SPEC(.has_precision = true, .precision = 3), lit_bool(false),
                       NULL, ".3 on Bool");
    bad += check_value(&c, &ctx, SPEC(.type = DS_RETE_FTYPE_D, .has_precision = true,
                       .precision = 3), lit_int(7), NULL, ".3d on Int");
    bad += check_value(&c, &ctx, SPEC(.type = DS_RETE_FTYPE_X_LOWER, .has_precision = true,
                       .precision = 3), lit_int(7), NULL, ".3x on Int");

    #undef STR
    #undef SPEC
    destroy_ctx(&c);
    return bad ? 1 : 0;
}

static int test_interp_time(void)
{
    Ctx c = make_ctx();
    ds_rete_eval_ctx_t ctx = make_eval_ctx(&c, NULL, NULL);
    int bad = 0;

    /* 2026-10-01T21:34:05.123456789Z in +05:30 is 2026-10-02T03:04:05.123456
       local: every field in the value's own offset, %f truncated. The third is
       the first instant, 1677-09-21T00:12:43.145224192Z: INT64_MIN is no
       multiple of a second, so its floored second times 1e9 has no int64, and
       render_time takes the nanosecond of the second as a floored modulus
       (test_rete_time.c's test_first_partial_day_splits_without_overflow).
       The last two ([LGRA.2.9.6.4]) are 1677-09-21T03:00:00Z at -08:00
       and 2262-04-11T20:00:00Z at +09:00, whose `utc_ns + offset` passes
       int64. Every field comes from ds_rete_local_split, so they are the
       local 1677-09-20 and 2262-04-12, never a wrapped date at the other
       end. */
    ds_rete_val_t frame[5] = {
        ds_rete_val_time(1790890445LL * 1000000000LL + 123456789LL, 19800),
        ds_rete_val_time(0, -3661),                    /* -01:01:01 */
        ds_rete_val_time(INT64_MIN, 0),
        ds_rete_val_time(INT64_C(-9223362000000000000), -8 * 3600),
        ds_rete_val_time(INT64_C(9223358400000000000), 9 * 3600),
    };
    ctx.bind_frame = frame;
    ctx.bind_count = 5;

    static const struct { int field; const char *text; } pat[] = {
        { DS_RETE_TFIELD_YEAR, NULL }, { 0, "-" }, { DS_RETE_TFIELD_MONTH, NULL }, { 0, "-" },
        { DS_RETE_TFIELD_DAY, NULL }, { 0, "T" }, { DS_RETE_TFIELD_HOUR, NULL }, { 0, ":" },
        { DS_RETE_TFIELD_MINUTE, NULL }, { 0, ":" }, { DS_RETE_TFIELD_SECOND, NULL },
        { 0, "." }, { DS_RETE_TFIELD_MICROSECOND, NULL }, { DS_RETE_TFIELD_UTC_OFFSET, NULL },
    };
    const uint32_t n = sizeof pat / sizeof pat[0];

    static const char *const want_at[5] = {
        "2026-10-02T03:04:05.123456+0530",
        "1969-12-31T22:58:59.000000-010101",
        "1677-09-21T00:12:43.145224+0000",
        "1677-09-20T19:00:00.000000-0800",
        "2262-04-12T05:00:00.000000+0900",
    };
    for (uint32_t which = 0; which < 5; which++) {
        ds_rete_expr_t *e = interp_new(1);
        ds_rete_fprim_t *p = &e->interp.prims[0];
        p->kind = DS_RETE_FPRIM_TIME;
        p->value = ds_rete_expr_alloc(DS_RETE_EXPR_BIND_REF);
        p->value->bind_ref.bind_index = which;
        p->items = calloc(n, sizeof(ds_rete_titem_t));
        p->item_count = n;
        for (uint32_t k = 0; k < n; k++) {
            if (pat[k].text) {
                p->items[k].text = istr(c.engine, pat[k].text);
                p->items[k].text_len = (uint32_t) strlen(pat[k].text);
            } else {
                p->items[k].field = (ds_rete_tfield_t) pat[k].field;
            }
        }
        const char *want = want_at[which];
        const char *s = render(&c, &ctx, e);
        if (!s || strcmp(s, want) != 0) {
            fprintf(stderr, "FAIL: INTERP time %u: got '%s', want '%s'\n",
                    which, s ? s : "(fault)", want);
            bad++;
        }
    }
    destroy_ctx(&c);
    return bad ? 1 : 0;
}

static int test_interp_grows(void)
{
    Ctx c = make_ctx();
    ds_rete_eval_ctx_t ctx = make_eval_ctx(&c, NULL, NULL);

    /* Longer than the engine's 4 KB scratch: the result moves to the heap and
       is rendered whole, with no length limit. */
    char chunk[1001];
    memset(chunk, 'z', 1000); chunk[1000] = '\0';
    ds_rete_expr_t *e = interp_new(9);
    for (uint32_t i = 0; i < 9; i++) prim_text(&e->interp.prims[i], c.engine, chunk);
    const char *s = render(&c, &ctx, e);
    if (!s || strlen(s) != 9000 || s[8999] != 'z') return fail("INTERP past the scratch");
    destroy_ctx(&c);
    return 0;
}

static ds_result_t fn_add_one(ds_rete_engine_t *engine,
                                ds_rete_eval_ctx_t *ctx,
                                ds_rete_val_t *args, uint32_t argc,
                                ds_rete_val_t *out)
{
    (void)engine; (void)ctx;
    if (argc != 1 || args[0].kind != DS_RETE_VAL_INT)
        return DS_ERR_R(DS_ERR_INVAL, "fn_add_one: bad args");
    *out = ds_rete_val_int(args[0].i + 1);
    return DS_OK_R;
}

static int test_fn_call(void)
{
    Ctx c = make_ctx();
    /* fn_add_one is hosted on FN_LATEST, which has no runtime handler
       (test_builtin_coverage's KNOWN_UNHANDLED) and whose [RDSC.4a.9.5] row
       is `none`, which `eval_call` does not count. A reserved number such as
       100 has no row, so a call of it is ARTEFACT_LIED before any handler
       runs. */
    if (expect_ok("register_fn",
                  ds_register_fn(DS_FN_LATEST, fn_add_one))) return 1;

    ds_rete_eval_ctx_t ctx = make_eval_ctx(&c, NULL, NULL);

    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_CALL);
    e->call.op        = DS_FN_LATEST;
    e->call.arg_count = 1;
    e->call.args      = calloc(1, sizeof(ds_rete_expr_t *));
    e->call.args[0]   = lit_int(41);

    ctx.faulted = false;
    ds_rete_val_t v = ds_rete_eval(&ctx, e);
    ds_rete_expr_free_tree(e);

    if (v.kind != DS_RETE_VAL_INT || v.i != 42) return fail("builtin call result");

    destroy_ctx(&c);
    return 0;
}

static int test_fn_unknown(void)
{
    Ctx c = make_ctx();
    ds_rete_eval_ctx_t ctx = make_eval_ctx(&c, NULL, NULL);

    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_CALL);
    /* 100 is reserved, so nothing registers it. FN_LATEST hosts
       test_fn_call's handler above, and the dispatch is global. */
    e->call.op        = 100u;
    e->call.arg_count = 0;
    e->call.args      = NULL;

    ctx.faulted = false;
    ds_rete_val_t v = ds_rete_eval(&ctx, e);
    ds_rete_expr_free_tree(e);

    if (!ctx.faulted) return fail("unknown builtin should be ERR");
    destroy_ctx(&c);
    return 0;
}

static int g_join_fire_count = 0;
static void join_fire_fn(const char *r, ds_rete_token_t *t, void *ctx)
{
    (void)r; (void)t; (void)ctx;
    g_join_fire_count++;
}

static int test_join_test_expr_real(void)
{
    Ctx c = make_ctx();
    g_join_fire_count = 0;

    ds_rete_alpha_node_t *alpha = NULL;
    ds_rete_alpha_node_create(0, NULL, 0, &alpha);
    ds_rete_dispatch_add(c.engine, 0, alpha);

    /* Join test: right.a > left.a (i.e., right slot[0] > token[0].slot[0]) */
    /* Expr: VAR(RIGHT_FACT, 0) > VAR(0, 0) */
    ds_rete_expr_t *jexpr = ds_rete_expr_alloc(DS_RETE_EXPR_BINOP);
    jexpr->binop.op = DS_RETE_BINOP_GT;
    jexpr->binop.left  = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
    jexpr->binop.left->var.pattern_index  = DS_RETE_VAR_RIGHT_FACT;
    jexpr->binop.left->var.slot_index     = 0;
    jexpr->binop.right = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
    jexpr->binop.right->var.pattern_index = 0;
    jexpr->binop.right->var.slot_index    = 0;

    ds_rete_join_test_t jtest = { .expr = jexpr };

    ds_rete_beta_node_t *beta = NULL;
    ds_rete_beta_node_create(NULL, alpha, &jtest, 1, false, &beta);
    ds_rete_alpha_add_beta_output(alpha, beta);

    ds_rete_terminal_t *term = NULL;
    ds_rete_terminal_create(istr(c.engine, "jtest_rule"), 0, &term);
    term->fire_fn  = join_fire_fn;
    ds_rete_beta_add_terminal(beta, term);

    /* Seed beta left memory with a root token for fact(a=5, b=0). */
    ds_rete_fact_t *seed = make_fact(&c, 5, 0);
    ds_result_t rc;
    ds_rete_token_t *root = ds_rete_token_create(NULL, seed, 0, NULL, NULL, &rc);
    ds_rete_beta_left_activate(beta, root, c.engine);
    ds_rete_token_free(root);

    /* Assert three right facts: a=3 (fails), a=5 (fails), a=8 (passes). */
    c.engine->cycle_generation++;
    make_fact(&c, 3, 0);  /* right.a=3 < left.a=5 → test fails */
    make_fact(&c, 5, 0);  /* right.a=5 == left.a=5 → test fails (GT not GE) */
    make_fact(&c, 8, 0);  /* right.a=8 > left.a=5 → test passes → activation */

    uint32_t fired = 0;
    if (expect_ok("run", ds_rete_run(c.engine, 0, &fired))) {
        /* jexpr owned by beta → freed by beta_node_destroy */
        ds_rete_beta_node_destroy(beta);
        ds_rete_terminal_destroy(term);
        ds_rete_alpha_node_destroy(alpha);
        destroy_ctx(&c);
        return 1;
    }

    /* jexpr freed by beta_node_destroy (IRET.20) */
    ds_rete_beta_node_destroy(beta);
    ds_rete_terminal_destroy(term);
    ds_rete_alpha_node_destroy(alpha);
    destroy_ctx(&c);

    if (g_join_fire_count != 1) {
        fprintf(stderr, "FAIL: join_test: want 1 fire, got %d\n",
                g_join_fire_count);
        return 1;
    }
    return 0;
}

static int k_true (ds_rete_val_t v) { return v.kind == DS_RETE_VAL_BOOL && v.b; }
static int k_false(ds_rete_val_t v) { return v.kind == DS_RETE_VAL_BOOL && !v.b; }
static int k_null (ds_rete_val_t v) { return v.kind == DS_RETE_VAL_NULL; }

static ds_rete_val_t eval_free(ds_rete_eval_ctx_t *ctx, ds_rete_expr_t *e)
{
    ds_rete_val_t v = ds_rete_eval(ctx, e);
    ds_rete_expr_free_tree(e);
    return v;
}
static ds_rete_expr_t *var_slot(uint16_t si)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
    e->var.pattern_index = 0;
    e->var.slot_index    = si;
    return e;
}

static int test_kleene_null(void)
{
    Ctx c = make_ctx();
    /* A fact with two null slots, for dynamic-null (VAR) reads. */
    ds_rete_val_t nullvals[2] = { ds_rete_val_null(), ds_rete_val_null() };
    ds_rete_fact_t *nf = NULL;
    if (ds_rete_wm_assert(c.engine, 0, nullvals, &nf).status != DS_OK || !nf)
        return fail("assert null-slot fact");
    ds_rete_eval_ctx_t ctx = make_eval_ctx(&c, nf, NULL);

    if (!k_null(eval_free(&ctx, lit_null()))) return fail("LIT_NULL -> null");

    /* [LNUL.4.1] comparison propagates null. */
    if (!k_null(eval_free(&ctx, binop(DS_RETE_BINOP_GT, lit_int(5), lit_null()))))
        return fail("5 > null -> null");
    if (!k_null(eval_free(&ctx, binop(DS_RETE_BINOP_LT, lit_int(5), lit_null()))))
        return fail("5 < null -> null");

    /* [LNUL.4.1]: a null literal operand propagates like any other. `== null`
       is a compile error and `is null` lowers to DS_RETE_EXPR_IS_TEST, so no
       artefact holds these node shapes; a hand-built network can, and the
       evaluator answers for them. */
    if (!k_null(eval_free(&ctx, binop(DS_RETE_BINOP_EQ, lit_null(), lit_null()))))
        return fail("null == null -> null");
    if (!k_null(eval_free(&ctx, binop(DS_RETE_BINOP_EQ, lit_int(5), lit_null()))))
        return fail("5 == null -> null");
    if (!k_null(eval_free(&ctx, binop(DS_RETE_BINOP_NE, lit_int(5), lit_null()))))
        return fail("5 != null -> null");
    if (!k_null(eval_free(&ctx, binop(DS_RETE_BINOP_EQ, var_slot(0), lit_null()))))
        return fail("s.x(null) == null -> null");

    /* [LNUL.8.2]: two dynamic nulls compared for equality propagate, so a
       null join key never joins. */
    if (!k_null(eval_free(&ctx, binop(DS_RETE_BINOP_EQ, var_slot(0), var_slot(1)))))
        return fail("null == null (dynamic) -> null (join non-match)");

    /* [LNUL.4.2] Kleene AND. */
    if (!k_null (eval_free(&ctx, binop(DS_RETE_BINOP_AND, lit_bool(true),  lit_null()))))     return fail("T and N = N");
    if (!k_false(eval_free(&ctx, binop(DS_RETE_BINOP_AND, lit_bool(false), lit_null()))))     return fail("F and N = F");
    if (!k_null (eval_free(&ctx, binop(DS_RETE_BINOP_AND, lit_null(),      lit_null()))))     return fail("N and N = N");
    if (!k_false(eval_free(&ctx, binop(DS_RETE_BINOP_AND, lit_null(),      lit_bool(false))))) return fail("N and F = F");
    if (!k_null (eval_free(&ctx, binop(DS_RETE_BINOP_AND, lit_null(),      lit_bool(true)))))  return fail("N and T = N");

    /* [LNUL.4.2] Kleene OR. */
    if (!k_true(eval_free(&ctx, binop(DS_RETE_BINOP_OR, lit_bool(true),  lit_null()))))     return fail("T or N = T");
    if (!k_null(eval_free(&ctx, binop(DS_RETE_BINOP_OR, lit_bool(false), lit_null()))))     return fail("F or N = N");
    if (!k_null(eval_free(&ctx, binop(DS_RETE_BINOP_OR, lit_null(),      lit_null()))))     return fail("N or N = N");
    if (!k_true(eval_free(&ctx, binop(DS_RETE_BINOP_OR, lit_null(),      lit_bool(true)))))  return fail("N or T = T");
    if (!k_null(eval_free(&ctx, binop(DS_RETE_BINOP_OR, lit_null(),      lit_bool(false))))) return fail("N or F = N");

    /* [LNUL.4.2] not null = null; not T = F; not F = T. */
    if (!k_null (eval_free(&ctx, unop(DS_RETE_UNOP_NOT, lit_null()))))      return fail("not N = N");
    if (!k_false(eval_free(&ctx, unop(DS_RETE_UNOP_NOT, lit_bool(true)))))  return fail("not T = F");
    if (!k_true (eval_free(&ctx, unop(DS_RETE_UNOP_NOT, lit_bool(false))))) return fail("not F = T");

    /* [LNUL.4.3]/[LNUL.9.2] eval_as_bool collapses null -> false (no fire),
       both positively (`s.state > 85`) and under negation (`not (...)`,
       [LNUL.4.5] — a missing reading must not spuriously fire "cool"). */
    {
        ds_rete_expr_t *hot = binop(DS_RETE_BINOP_GT, lit_int(5), lit_null());
        bool b = ds_rete_eval_as_bool(&ctx, hot);
        ds_rete_expr_free_tree(hot);
        if (b) return fail("eval_as_bool(null) must be false");
    }
    {
        ds_rete_expr_t *cool = unop(DS_RETE_UNOP_NOT,
                                    binop(DS_RETE_BINOP_GT, lit_int(5), lit_null()));
        bool b = ds_rete_eval_as_bool(&ctx, cool);
        ds_rete_expr_free_tree(cool);
        if (b) return fail("eval_as_bool(not null) must be false");
    }

    destroy_ctx(&c);
    return 0;
}

/* A deciding operand of a connective absorbs every operand fault; with no
   decider, one fault is yielded, chosen by kind. */

/* `1 // 0 > 1`: DIVIDE_BY_ZERO. */
static ds_rete_expr_t *x_div0(void)
{
    return binop(DS_RETE_BINOP_GT,
                 binop(DS_RETE_BINOP_IDIV, lit_int(1), lit_int(0)), lit_int(1));
}
/* `1 << -1 > 0`: DOMAIN ([LEXP.7.14.1]). */
static ds_rete_expr_t *x_domain(void)
{
    return binop(DS_RETE_BINOP_GT,
                 binop(DS_RETE_BINOP_SHL, lit_int(1), lit_int(-1)), lit_int(0));
}
/* `true + 1` on a clean node: EngineError ARTEFACT_LIED ([IRET.9.6]). */
static ds_rete_expr_t *x_lied(void)
{
    return binop(DS_RETE_BINOP_ADD, lit_bool(true), lit_int(1));
}
/* The same on a `Json`-tainted node: a TypeError. */
static ds_rete_expr_t *x_typed(void)
{
    ds_rete_expr_t *e = x_lied();
    e->json_tainted = true;
    return e;
}

/* Evaluate `e` the way an enclosing `and` evaluates an operand, so the
   SELECTED fault is visible -- the harness has no recorder to read it from.
   A fresh ctx per case, because the fault latch never clears. `want_fault`
   false means the value must be the Bool `want_bool`. */
static int v5_case(Ctx *c, const char *name, ds_rete_expr_t *e,
                   bool want_fault, ds_rete_fault_cause_t want_cause,
                   bool want_tainted, bool want_bool)
{
    ds_rete_eval_ctx_t ctx = make_eval_ctx(c, NULL, NULL);
    ds_rete_held_t h;
    ds_rete_val_t v = ds_rete_eval_holding(&ctx, e, &h);
    ds_rete_expr_free_tree(e);
    if (ctx.faulted) return fail(name);  /* only a resource fault escapes */
    if (want_fault) {
        if (!h.held || h.cause != want_cause || h.tainted != want_tainted)
            return fail(name);
    } else {
        if (h.held || v.kind != DS_RETE_VAL_BOOL || v.b != want_bool)
            return fail(name);
    }
    return 0;
}

static int test_v5_absorbing(void)
{
    Ctx c = make_ctx();
    const ds_rete_fault_cause_t NONE = DS_FAULT_TYPE_MISMATCH;
    int r = 0;

    /* A deciding operand absorbs a TypeError and an EngineError, not only a
       trap, on either side ([LNUL.4.2], [IRET.9.5]). */
    r |= v5_case(&c, "V5: EngineError and false is false",
                 binop(DS_RETE_BINOP_AND, x_lied(), lit_bool(false)),
                 false, NONE, false, false);
    r |= v5_case(&c, "V5: false and TypeError is false",
                 binop(DS_RETE_BINOP_AND, lit_bool(false), x_typed()),
                 false, NONE, false, false);
    r |= v5_case(&c, "V5: EngineError or true is true",
                 binop(DS_RETE_BINOP_OR, x_lied(), lit_bool(true)),
                 false, NONE, false, true);

    /* No decider: the kind order selects, whatever the position. */
    r |= v5_case(&c, "V5: DIVIDE_BY_ZERO outranks DOMAIN (left)",
                 binop(DS_RETE_BINOP_AND, x_domain(), x_div0()),
                 true, DS_FAULT_DIVIDE_BY_ZERO, false, false);
    r |= v5_case(&c, "V5: DIVIDE_BY_ZERO outranks DOMAIN (right)",
                 binop(DS_RETE_BINOP_AND, x_div0(), x_domain()),
                 true, DS_FAULT_DIVIDE_BY_ZERO, false, false);
    r |= v5_case(&c, "V5: a TypeError outranks a trap (left)",
                 binop(DS_RETE_BINOP_AND, x_div0(), x_typed()),
                 true, DS_FAULT_TYPE_MISMATCH, true, false);
    r |= v5_case(&c, "V5: a TypeError outranks a trap (right)",
                 binop(DS_RETE_BINOP_AND, x_typed(), x_div0()),
                 true, DS_FAULT_TYPE_MISMATCH, true, false);
    r |= v5_case(&c, "V5: an EngineError outranks a TypeError (left)",
                 binop(DS_RETE_BINOP_OR, x_typed(), x_lied()),
                 true, DS_FAULT_TYPE_MISMATCH, false, false);
    r |= v5_case(&c, "V5: an EngineError outranks a TypeError (right)",
                 binop(DS_RETE_BINOP_OR, x_lied(), x_typed()),
                 true, DS_FAULT_TYPE_MISMATCH, false, false);

    /* Within a kind, the lower recorded value wins. Two EngineErrors: a
       right-fact read with no right fact is ARTEFACT_LIED (1), a token position past the one-fact test token is
       PATTERN_INDEX (2). The first is selected, either side. */
    {
        ds_rete_expr_t *pat_a = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
        pat_a->var.pattern_index = 5;
        pat_a->var.slot_index    = 0;
        ds_rete_expr_t *lied_a = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
        lied_a->var.pattern_index = DS_RETE_VAR_RIGHT_FACT;
        lied_a->var.slot_index    = 0;
        r |= v5_case(&c, "V5: ARTEFACT_LIED beats PATTERN_INDEX (left)",
                     binop(DS_RETE_BINOP_OR, pat_a, lied_a),
                     true, DS_FAULT_ARTEFACT, false, false);
        ds_rete_expr_t *pat_b = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
        pat_b->var.pattern_index = 5;
        pat_b->var.slot_index    = 0;
        ds_rete_expr_t *lied_b = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
        lied_b->var.pattern_index = DS_RETE_VAR_RIGHT_FACT;
        lied_b->var.slot_index    = 0;
        r |= v5_case(&c, "V5: ARTEFACT_LIED beats PATTERN_INDEX (right)",
                     binop(DS_RETE_BINOP_OR, lied_b, pat_b),
                     true, DS_FAULT_ARTEFACT, false, false);
    }

    /* The connective's own mismatch -- an operand that is neither a Bool nor
       `null` -- is held too, classified by the connective's taint. */
    r |= v5_case(&c, "V5: a non-Bool operand beside a false is absorbed",
                 binop(DS_RETE_BINOP_AND, lit_int(7), lit_bool(false)),
                 false, NONE, false, false);
    r |= v5_case(&c, "V5: a non-Bool operand of a clean `and` is ARTEFACT_LIED",
                 binop(DS_RETE_BINOP_AND, lit_int(7), lit_bool(true)),
                 true, DS_FAULT_TYPE_MISMATCH, false, false);
    {
        ds_rete_expr_t *e = binop(DS_RETE_BINOP_AND, lit_int(7), lit_bool(true));
        e->json_tainted = true;
        r |= v5_case(&c, "V5: ... and of a tainted `and`, a TypeError",
                     e, true, DS_FAULT_TYPE_MISMATCH, true, false);
    }

    destroy_ctx(&c);
    return r;
}

static ds_rete_expr_t *is_test(ds_rete_expr_t *operand,
                               ds_rete_is_subject_t subject, bool negated)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_IS_TEST);
    e->is_test.operand = operand;
    e->is_test.subject = subject;
    e->is_test.negated = negated;
    return e;
}

/* [LNUL.4.9]'s `is` and `is not`, the total tag test. Every assertion
   demands a Bool: k_true and k_false are false for any other kind, so a null
   or a fault fails. */
static int test_is_test_total(void)
{
    Ctx c = make_ctx();
    ds_rete_val_t nullvals[2] = { ds_rete_val_null(), ds_rete_val_null() };
    ds_rete_fact_t *nf = NULL;
    if (ds_rete_wm_assert(c.engine, 0, nullvals, &nf).status != DS_OK || !nf)
        return fail("assert null-slot fact");
    ds_rete_eval_ctx_t ctx = make_eval_ctx(&c, nf, NULL);

    /* A constant tests tag AND value. */
    if (!k_true (eval_free(&ctx, is_test(lit_null(),      DS_RETE_IS_NULL,  false))))
        return fail("null is null");
    if (!k_true (eval_free(&ctx, is_test(lit_bool(true),  DS_RETE_IS_TRUE,  false))))
        return fail("true is true");
    if (!k_false(eval_free(&ctx, is_test(lit_bool(false), DS_RETE_IS_TRUE,  false))))
        return fail("false is true -> false");
    if (!k_true (eval_free(&ctx, is_test(lit_bool(false), DS_RETE_IS_FALSE, false))))
        return fail("false is false");

    /* A tag name tests the tag ALONE — so `is Bool` holds of `false`. */
    if (!k_true (eval_free(&ctx, is_test(lit_bool(false), DS_RETE_IS_BOOL,  false))))
        return fail("false is Bool");
    if (!k_true (eval_free(&ctx, is_test(lit_int(5),      DS_RETE_IS_INT,   false))))
        return fail("5 is Int");
    if (!k_false(eval_free(&ctx, is_test(lit_int(5),      DS_RETE_IS_FLOAT, false))))
        return fail("5 is Float -> false");
    if (!k_true (eval_free(&ctx, is_test(lit_float(1.5),  DS_RETE_IS_FLOAT, false))))
        return fail("1.5 is Float");

    /* `is Float` is true of inf, -inf and NaN alike — the tag, not the value. */
    if (!k_true (eval_free(&ctx, is_test(lit_float(INFINITY),  DS_RETE_IS_FLOAT, false))))
        return fail("inf is Float");
    if (!k_true (eval_free(&ctx, is_test(lit_float(-INFINITY), DS_RETE_IS_FLOAT, false))))
        return fail("-inf is Float");
    if (!k_true (eval_free(&ctx, is_test(lit_float(NAN),       DS_RETE_IS_FLOAT, false))))
        return fail("NaN is Float");

    /* ...while the constants discriminate among them — including NaN, which
       `==` cannot express at all, since NaN == NaN is false. */
    if (!k_true (eval_free(&ctx, is_test(lit_float(INFINITY),  DS_RETE_IS_INF,     false))))
        return fail("inf is inf");
    if (!k_false(eval_free(&ctx, is_test(lit_float(-INFINITY), DS_RETE_IS_INF,     false))))
        return fail("-inf is inf -> false");
    if (!k_true (eval_free(&ctx, is_test(lit_float(-INFINITY), DS_RETE_IS_NEG_INF, false))))
        return fail("-inf is -inf");
    if (!k_true (eval_free(&ctx, is_test(lit_float(NAN),       DS_RETE_IS_NAN,     false))))
        return fail("NaN is NaN");
    if (!k_false(eval_free(&ctx, is_test(lit_float(1.5),       DS_RETE_IS_NAN,     false))))
        return fail("1.5 is NaN -> false");
    if (!k_false(eval_free(&ctx, is_test(lit_float(INFINITY),  DS_RETE_IS_NAN,     false))))
        return fail("inf is NaN -> false");

    /* TOTALITY: a null operand answers false for every non-null subject —
       never null, never an error. Tested against a literal null and against a
       dynamic one read from a slot, because those are different paths. */
    if (!k_false(eval_free(&ctx, is_test(lit_null(),  DS_RETE_IS_INT,   false))))
        return fail("null is Int -> false");
    if (!k_false(eval_free(&ctx, is_test(lit_null(),  DS_RETE_IS_TRUE,  false))))
        return fail("null is true -> false");
    if (!k_false(eval_free(&ctx, is_test(lit_null(),  DS_RETE_IS_NAN,   false))))
        return fail("null is NaN -> false");
    if (!k_true (eval_free(&ctx, is_test(var_slot(0), DS_RETE_IS_NULL,  false))))
        return fail("s.x(null) is null");
    if (!k_false(eval_free(&ctx, is_test(var_slot(0), DS_RETE_IS_FLOAT, false))))
        return fail("s.x(null) is Float -> false");

    /* `is not` inverts AFTER the test — one operator, not `not (is)`. */
    if (!k_false(eval_free(&ctx, is_test(lit_null(),     DS_RETE_IS_NULL, true))))
        return fail("null is not null -> false");
    if (!k_true (eval_free(&ctx, is_test(lit_int(5),     DS_RETE_IS_NULL, true))))
        return fail("5 is not null");
    if (!k_true (eval_free(&ctx, is_test(lit_null(),     DS_RETE_IS_INT,  true))))
        return fail("null is not Int");
    if (!k_false(eval_free(&ctx, is_test(lit_bool(true), DS_RETE_IS_BOOL, true))))
        return fail("true is not Bool -> false");

    /* A string literal answers `is String` and nothing else. */
    ds_rete_expr_t *s = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_STR);
    s->lit_str = istr(c.engine, "hello");
    if (!k_true (eval_free(&ctx, is_test(s, DS_RETE_IS_STRING, false))))
        return fail("\"hello\" is String");
    s = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_STR);
    s->lit_str = istr(c.engine, "hello");
    if (!k_false(eval_free(&ctx, is_test(s, DS_RETE_IS_INT, false))))
        return fail("\"hello\" is Int -> false");

    destroy_ctx(&c);
    return 0;
}

/* [LEXP.7.19]: Bytes and whole Json admit equality only. */

/* A two-slot fact built by hand, NOT asserted. Working memory interns a Bytes
   value, so two equal Bytes slots of an asserted fact share one pointer and
   val_eq_unordered's pointer test answers them; this fact holds two separate
   buffers, so the content compare is what answers. Nothing here enters WM. */
static ds_rete_fact_t *pair_fact(const ds_rete_schema_t *s,
                                 ds_rete_val_t a, ds_rete_val_t b)
{
    ds_rete_fact_t *f = calloc(1, sizeof(*f) + 2 * sizeof(ds_rete_val_t));
    if (!f) return NULL;
    f->schema   = s;
    f->slots[0] = a;
    f->slots[1] = b;
    return f;
}

/* The comparison `slot0 op slot1` over `f`, with the fault latch cleared so
   `*faulted` is this evaluation's. */
static ds_rete_val_t cmp_pair(Ctx *c, ds_rete_fact_t *f, ds_rete_binop_t op,
                              bool *faulted)
{
    ds_rete_eval_ctx_t ctx = make_eval_ctx(c, f, NULL);
    ctx.faulted = false;
    ds_rete_val_t v = eval_free(&ctx, binop(op, var_slot(0), var_slot(1)));
    *faulted = ctx.faulted;
    return v;
}

/* @spec [LEXP.7.19] */
static int test_lexp_7_19_bytes_equality(void)
{
    Ctx c = make_ctx();
    ds_rete_slot_desc_t sd[2] = {
        { .name = "a", .type = DS_RETE_VAL_BYTES },
        { .name = "b", .type = DS_RETE_VAL_BYTES },
    };
    ds_rete_schema_t *s = NULL;
    if (ds_rete_schema_register(c.engine, "B", DS_RETE_SCOPE_PLAIN, 0,
                                sd, 2, &s).status != DS_OK || !s)
        return fail("register B");

    /* Separate buffers; the NUL in the middle rules out a C-string compare. */
    char x[4] = { 'a', 'b', 0, 'c' };
    char y[4] = { 'a', 'b', 0, 'c' };
    char z[4] = { 'a', 'b', 0, 'd' };
    struct { const char *pa; uint32_t la; const char *pb; uint32_t lb;
             bool equal; const char *what; } rows[] = {
        { x, 4, y, 4, true,  "equal content in separate buffers" },
        { x, 4, z, 4, false, "same length, last octet differs" },
        { x, 2, x, 3, false, "a prefix of the other (\"ab\" against \"ab\\0\")" },
        { x, 3, z, 3, true,  "equal up to a shared NUL, lengths equal" },
        { x, 0, z, 0, true,  "two empty values" },
    };
    for (size_t i = 0; i < sizeof rows / sizeof rows[0]; i++) {
        ds_rete_fact_t *f = pair_fact(s, ds_rete_val_bytes(rows[i].pa, rows[i].la),
                                         ds_rete_val_bytes(rows[i].pb, rows[i].lb));
        if (!f) return fail("alloc");
        bool fe = false, fn = false;
        ds_rete_val_t eq = cmp_pair(&c, f, DS_RETE_BINOP_EQ, &fe);
        ds_rete_val_t ne = cmp_pair(&c, f, DS_RETE_BINOP_NE, &fn);
        free(f);
        if (fe || fn) {
            fprintf(stderr, "FAIL: Bytes ==/!= faulted: %s\n", rows[i].what);
            return 1;
        }
        if (!(rows[i].equal ? k_true(eq) : k_false(eq))
            || !(rows[i].equal ? k_false(ne) : k_true(ne))) {
            fprintf(stderr, "FAIL: Bytes ==/!= wrong: %s\n", rows[i].what);
            return 1;
        }
    }

    /* Ordering is refused: the compiler never emits it, and a hand-built node
       faults. */
    ds_rete_fact_t *f = pair_fact(s, ds_rete_val_bytes(x, 4), ds_rete_val_bytes(y, 4));
    if (!f) return fail("alloc");
    bool faulted = false;
    (void)cmp_pair(&c, f, DS_RETE_BINOP_LT, &faulted);
    free(f);
    if (!faulted) return fail("Bytes < Bytes must fault");

    destroy_ctx(&c);
    return 0;
}

static ds_json_t *parse_json(const char *text)
{
    ds_json_t *t = NULL;
    if (ds_json_parse(text, strlen(text), &t).status != DS_OK) return NULL;
    return t;
}

/* @spec [LEXP.7.19] */
static int test_lexp_7_19_json_equality(void)
{
    Ctx c = make_ctx();
    ds_rete_slot_desc_t sd[2] = {
        { .name = "a", .type = DS_RETE_VAL_JSON },
        { .name = "b", .type = DS_RETE_VAL_JSON },
    };
    ds_rete_schema_t *s = NULL;
    if (ds_rete_schema_register(c.engine, "J", DS_RETE_SCOPE_PLAIN, 0,
                                sd, 2, &s).status != DS_OK || !s)
        return fail("register J");

    /* Owned against borrowed: the two holdings of a Json value. */
    struct { const char *a; ds_rete_val_kind_t ka; const char *b;
             ds_rete_val_kind_t kb; bool equal; const char *what; } rows[] = {
        { "{\"x\": 1, \"y\": [1, 2]}", DS_RETE_VAL_JSON,
          "{\"y\": [1, 2], \"x\": 1}", DS_RETE_VAL_JSON, true,
          "an object equal with its members in another order" },
        { "{\"x\": 1, \"y\": [1, 2]}", DS_RETE_VAL_JSON,
          "{\"y\": [1, 2], \"x\": 1}", DS_RETE_VAL_JSON_BORROW, true,
          "an owned tree against an equal borrowed one" },
        { "{\"y\": [1, 2]}", DS_RETE_VAL_JSON_BORROW,
          "{\"y\": [2, 1]}", DS_RETE_VAL_JSON, false,
          "an array is ordered" },
        { "{\"x\": 1}", DS_RETE_VAL_JSON,
          "{\"x\": 1.0}", DS_RETE_VAL_JSON, false,
          "1 and 1.0 are different kinds ([LFAC.2.5.1])" },
    };
    for (size_t i = 0; i < sizeof rows / sizeof rows[0]; i++) {
        ds_json_t *ta = parse_json(rows[i].a), *tb = parse_json(rows[i].b);
        if (!ta || !tb) return fail("ds_json_parse");
        ds_rete_val_t va = { .kind = rows[i].ka, .json = ta };
        ds_rete_val_t vb = { .kind = rows[i].kb, .json = tb };
        ds_rete_fact_t *f = pair_fact(s, va, vb);
        if (!f) return fail("alloc");
        bool fe = false, fn = false;
        ds_rete_val_t eq = cmp_pair(&c, f, DS_RETE_BINOP_EQ, &fe);
        ds_rete_val_t ne = cmp_pair(&c, f, DS_RETE_BINOP_NE, &fn);
        free(f);
        ds_json_free(ta);
        ds_json_free(tb);
        if (fe || fn) {
            fprintf(stderr, "FAIL: Json ==/!= faulted: %s\n", rows[i].what);
            return 1;
        }
        if (!(rows[i].equal ? k_true(eq) : k_false(eq))
            || !(rows[i].equal ? k_false(ne) : k_true(ne))) {
            fprintf(stderr, "FAIL: Json ==/!= wrong: %s\n", rows[i].what);
            return 1;
        }
    }

    destroy_ctx(&c);
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

    printf("=== test_rete_expr_eval ===\n");
    RUN(test_literals);
    RUN(test_var_from_token);
    RUN(test_var_right_fact);
    RUN(test_arith_int);
    RUN(test_arith_float);
    RUN(test_div_by_zero);
    RUN(test_div_by_zero_float);
    RUN(test_cmp);
    RUN(test_logical);
    RUN(test_unop);
    RUN(test_bitwise);
    RUN(test_type_error);
    RUN(test_now);
    RUN(test_if);
    RUN(test_bind);
    RUN(test_interp_concat);
    RUN(test_interp_value_rules);
    RUN(test_interp_time);
    RUN(test_interp_grows);
    RUN(test_fn_call);
    RUN(test_fn_unknown);
    RUN(test_join_test_expr_real);
    RUN(test_kleene_null);
    RUN(test_v5_absorbing);
    RUN(test_is_test_total);
    RUN(test_lexp_7_19_bytes_equality);
    RUN(test_lexp_7_19_json_equality);

#undef RUN

    if (fail_count == 0) {
        printf("=== test_rete_expr_eval: ALL PASSED ===\n");
        return 0;
    }
    fprintf(stderr, "=== test_rete_expr_eval: %d FAILED ===\n", fail_count);
    return 1;
}
