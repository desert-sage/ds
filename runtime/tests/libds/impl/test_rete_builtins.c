/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The pure builtins through the op dispatch (IRET.13.2): each test evaluates a
 * CALL expression and checks the result.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "builtins.h"
#include "builtin_fn.h"
#include "rete/adapters.h"
#include "rete/engine.h"
#include "rete/eval.h"
#include "rete/expr.h"
#include "rete/intern.h"
#include "rete/schema.h"
#include "rete/schema_reg.h"
#include "fn.h"
#include "rete/val.h"
#include "rete/wm_rete.h"
#include "ds_re2.h"
#include "internal/json.h"   /* ds_json_get_path_n, and a leaf's value */

/* Whether this build links RE2: the MSan lane builds `-D re2=stub`, where no
   pattern compiles by design, and the regex cases below can only fail there.
   They are skipped on that build, out loud, and run on every other. */
static int re2_linked(void)
{
    char err[64];
    ds_re2_t *re = ds_re2_compile("a", 0, err, sizeof err);
    if (re == NULL) return 0;
    ds_re2_free(re);
    return 1;
}

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

static ds_rete_engine_t *make_engine(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    ds_register_builtins(e);
    return e;
}

static const char *istr(ds_rete_engine_t *e, const char *s)
{
    const char *p; ds_rete_intern_cstr(e->intern, s, &p); return p;
}

/* Build a CALL expression node. args array is borrowed (freed by caller). */
static ds_rete_expr_t *call_expr(ds_rete_engine_t *e, ds_builtin_fn_t op,
                                  ds_rete_expr_t **args, uint32_t argc)
{
    (void) e;
    ds_rete_expr_t *node = ds_rete_expr_alloc(DS_RETE_EXPR_CALL);
    node->call.op        = op;
    node->call.arg_count = argc;
    if (argc > 0) {
        node->call.args = calloc(argc, sizeof(ds_rete_expr_t *));
        for (uint32_t i = 0; i < argc; i++)
            node->call.args[i] = args[i];
    }
    return node;
}

static ds_rete_expr_t *lit_str(ds_rete_engine_t *e, const char *s)
{
    ds_rete_expr_t *n = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_STR);
    n->lit_str = istr(e, s);
    return n;
}
static ds_rete_expr_t *lit_int(int64_t v)
{
    ds_rete_expr_t *n = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_INT);
    n->lit_int = v; return n;
}
static ds_rete_expr_t *lit_float(double v)
{
    ds_rete_expr_t *n = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_FLOAT);
    n->lit_float = v; return n;
}
static ds_rete_expr_t *lit_bool(bool v)
{
    ds_rete_expr_t *n = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_BOOL);
    n->lit_bool = v; return n;
}

/* The fault latch of the most recent eval1. A fault is not a value kind
   ([LEXP.7.12]), and the ctx is local to eval1. */
static bool g_eval1_faulted;

static ds_rete_val_t eval1(ds_rete_engine_t *e, ds_rete_expr_t *expr)
{
    ds_rete_eval_ctx_t ctx = { .engine = e };
    ds_rete_val_t v = ds_rete_eval(&ctx, expr);
    g_eval1_faulted = ctx.faulted;
    ds_rete_expr_free_tree(expr);
    return v;
}

static int test_error_code_matches(void)
{
    ds_rete_engine_t *e = make_engine();

    struct { const char *code; const char *pat; bool want; } cases[] = {
        { "auth",          "auth",    true  },
        { "auth.failed",   "auth",    true  },
        /* [LECC.1.2]: `_` is inside a segment, so it is no boundary. */
        { "auth_failed",   "auth",    false },
        { "auth_failed",   "auth_failed", true },
        { "auth_failed.x", "auth_failed", true },
        { "authorize",     "auth",    false },
        { "auth.failed",   "auth.failed", true },
        { "auth.failed",   "auth.foo",    false },
        { "anything",      "",        true  },
    };
    for (size_t i = 0; i < sizeof(cases)/sizeof(*cases); i++) {
        ds_rete_expr_t *args[2] = {
            lit_str(e, cases[i].code),
            lit_str(e, cases[i].pat)
        };
        ds_rete_val_t v = eval1(e, call_expr(e, DS_FN_ERROR_CODE_MATCHES, args, 2));
        if (v.kind != DS_RETE_VAL_BOOL || v.b != cases[i].want) {
            fprintf(stderr, "FAIL: error-code-matches(%s, %s): want %d got %d\n",
                    cases[i].code, cases[i].pat, cases[i].want, v.b);
            ds_rete_engine_destroy(e);
            return 1;
        }
    }
    ds_rete_engine_destroy(e);
    return 0;
}

/* [LSTR.2.1]: codepoints, "not the byte count, not the grapheme-cluster count,
   not the UTF-16 code-unit count". The clause's two examples separate all
   four: `café` is 4 codepoints in 5 bytes, and `👋🏽` (U+1F44B U+1F3FD) is 2
   codepoints, 1 grapheme cluster, 4 UTF-16 code units and 8 bytes. Escaped,
   so the source file's encoding cannot change what is measured. */
static int test_str_length(void)
{
    static const struct { const char *s; int64_t want; } cases[] = {
        { "hello",                                5 },
        { "",                                     0 },
        { "caf\xc3\xa9",                          4 },
        { "\xf0\x9f\x91\x8b\xf0\x9f\x8f\xbd",     2 },
    };
    for (size_t i = 0; i < sizeof cases / sizeof *cases; i++) {
        ds_rete_engine_t *e = make_engine();
        ds_rete_expr_t *a[1] = { lit_str(e, cases[i].s) };
        ds_rete_val_t v = eval1(e, call_expr(e, DS_FN_STR_LENGTH, a, 1));
        ds_rete_engine_destroy(e);
        if (v.kind != DS_RETE_VAL_INT || v.i != cases[i].want) {
            fprintf(stderr, "FAIL: str_length case %zu: want %lld got %lld\n",
                    i, (long long) cases[i].want, (long long) v.i);
            return 1;
        }
    }
    return 0;
}

static int test_math(void)
{
    ds_rete_engine_t *e = make_engine();
    ds_rete_val_t v;

    ds_rete_expr_t *a_floor[1] = { lit_float(3.7) };
    v = eval1(e, call_expr(e, DS_FN_FLOOR, a_floor, 1));
    if (v.kind != DS_RETE_VAL_INT || v.i != 3) { ds_rete_engine_destroy(e); return fail("floor"); }

    ds_rete_expr_t *a_ceil[1] = { lit_float(3.2) };
    v = eval1(e, call_expr(e, DS_FN_CEIL, a_ceil, 1));
    if (v.kind != DS_RETE_VAL_INT || v.i != 4) { ds_rete_engine_destroy(e); return fail("ceil"); }

    ds_rete_expr_t *a_trunc[1] = { lit_float(-3.9) };
    v = eval1(e, call_expr(e, DS_FN_TRUNC, a_trunc, 1));
    if (v.kind != DS_RETE_VAL_INT || v.i != -3) { ds_rete_engine_destroy(e); return fail("trunc"); }

    ds_rete_expr_t *a_sign_pos[1] = { lit_float(5.0) };
    v = eval1(e, call_expr(e, DS_FN_SIGN, a_sign_pos, 1));
    if (v.kind != DS_RETE_VAL_INT || v.i != 1) { ds_rete_engine_destroy(e); return fail("sign pos"); }

    ds_rete_expr_t *a_sign_neg[1] = { lit_float(-2.0) };
    v = eval1(e, call_expr(e, DS_FN_SIGN, a_sign_neg, 1));
    if (v.kind != DS_RETE_VAL_INT || v.i != -1) { ds_rete_engine_destroy(e); return fail("sign neg"); }

    ds_rete_expr_t *a_sign_zero[1] = { lit_float(0.0) };
    v = eval1(e, call_expr(e, DS_FN_SIGN, a_sign_zero, 1));
    if (v.kind != DS_RETE_VAL_INT || v.i != 0) { ds_rete_engine_destroy(e); return fail("sign zero"); }

    ds_rete_engine_destroy(e);
    return 0;
}

/* The fourteen transcendentals of [LEXP.3.9.1], through the op dispatch to
 * CORE-MATH. Each row's correctly rounded result is known to the last bit
 * (RN(pi), RN(pi/2), RN(pi/4), RN(e), RN(ln 2)) or is exact, so the test fails
 * on a builtin that is unregistered, mis-wired to another function, or not
 * correctly rounded at these points. It tests the dispatch; the
 * correct-rounding evidence is the probe's and the conformance vectors'.
 *
 * The special rows are [LEXP.3.9.3]'s and none faults: a pole is ±inf and an
 * argument outside the domain is NaN ([LDET.3.6.2]). An Int argument is taken
 * as its Float. */
static int test_transcendentals(void)
{
    struct { ds_builtin_fn_t op; const char *name; double x, y; int argc;
             double want; int nan; } rows[] = {
        { DS_FN_EXP,   "exp(0)",       0.0,  0, 1, 1.0,                     0 },
        { DS_FN_EXP,   "exp(1)",       1.0,  0, 1, 0x1.5bf0a8b145769p+1,    0 },
        { DS_FN_LN,    "ln(1)",        1.0,  0, 1, 0.0,                     0 },
        { DS_FN_LN,    "ln(2)",        2.0,  0, 1, 0x1.62e42fefa39efp-1,    0 },
        { DS_FN_LN,    "ln(0)",        0.0,  0, 1, -INFINITY,               0 },
        { DS_FN_LN,    "ln(-1)",      -1.0,  0, 1, 0.0,                     1 },
        { DS_FN_LOG2,  "log2(8)",      8.0,  0, 1, 3.0,                     0 },
        { DS_FN_LOG10, "log10(1000)",  1000.0, 0, 1, 3.0,                   0 },
        { DS_FN_SIN,   "sin(0)",       0.0,  0, 1, 0.0,                     0 },
        { DS_FN_COS,   "cos(0)",       0.0,  0, 1, 1.0,                     0 },
        { DS_FN_TAN,   "tan(0)",       0.0,  0, 1, 0.0,                     0 },
        { DS_FN_ASIN,  "asin(1)",      1.0,  0, 1, 0x1.921fb54442d18p+0,    0 },
        { DS_FN_ASIN,  "asin(2)",      2.0,  0, 1, 0.0,                     1 },
        { DS_FN_ACOS,  "acos(-1)",    -1.0,  0, 1, 0x1.921fb54442d18p+1,    0 },
        { DS_FN_ATAN,  "atan(1)",      1.0,  0, 1, 0x1.921fb54442d18p-1,    0 },
        { DS_FN_ATAN2, "atan2(1, 1)",  1.0,  1.0, 2, 0x1.921fb54442d18p-1,  0 },
        { DS_FN_ATAN2, "atan2(1, -1)", 1.0, -1.0, 2, 0x1.2d97c7f3321d2p+1,  0 },
        { DS_FN_SINH,  "sinh(0)",      0.0,  0, 1, 0.0,                     0 },
        { DS_FN_COSH,  "cosh(0)",      0.0,  0, 1, 1.0,                     0 },
        { DS_FN_TANH,  "tanh(0)",      0.0,  0, 1, 0.0,                     0 },
    };
    ds_rete_engine_t *e = make_engine();
    for (size_t i = 0; i < sizeof rows / sizeof *rows; i++) {
        ds_rete_expr_t *args[2] = { lit_float(rows[i].x), lit_float(rows[i].y) };
        ds_rete_val_t v = eval1(e, call_expr(e, rows[i].op, args, (uint32_t)rows[i].argc));
        if (rows[i].argc == 1) ds_rete_expr_free_tree(args[1]);
        bool ok = !g_eval1_faulted && v.kind == DS_RETE_VAL_FLOAT &&
                  (rows[i].nan ? isnan(v.f) : v.f == rows[i].want);
        if (!ok) {
            fprintf(stderr, "FAIL: %s: faulted=%d kind=%d got %a want %s%a\n",
                    rows[i].name, g_eval1_faulted, (int)v.kind, v.f,
                    rows[i].nan ? "NaN, not " : "", rows[i].want);
            ds_rete_engine_destroy(e);
            return 1;
        }
    }
    /* An Int argument is taken as its Float. */
    ds_rete_expr_t *a_int[1] = { lit_int(1) };
    ds_rete_val_t v = eval1(e, call_expr(e, DS_FN_EXP, a_int, 1));
    ds_rete_engine_destroy(e);
    if (g_eval1_faulted || v.kind != DS_RETE_VAL_FLOAT || v.f != 0x1.5bf0a8b145769p+1)
        return fail("exp(Int 1) should be RN(e)");
    return 0;
}

/* `**` answers as IEEE 754 does, and never faults ([LEXP.7.3a], [LEXP.3.9.3],
 * [LDET.3.6.2]): `0 ** negative` is `+inf` (`-inf` for `-0.0` under an odd
 * negative integer exponent), and a negative base under a non-integral
 * exponent is NaN.
 *
 * The computing cases fail a `pow` that answers NaN for everything: `2 ** -3`
 * is 0.125, `(-2.0) ** 3.0` is -8.0, and `2.0 ** 0.5` is sqrt(2), correctly
 * rounded. */
static int test_pow_ieee(void)
{
    ds_rete_engine_t *e = make_engine();
    ds_rete_val_t v;

    ds_rete_expr_t *a_zero_neg[2] = { lit_int(0), lit_int(-1) };
    v = eval1(e, call_expr(e, DS_FN_POW, a_zero_neg, 2));
    if (g_eval1_faulted || v.kind != DS_RETE_VAL_FLOAT || !(isinf(v.f) && v.f > 0)) { ds_rete_engine_destroy(e); return fail("0 ** -1 should be +inf"); }

    ds_rete_expr_t *a_negzero_odd[2] = { lit_float(-0.0), lit_float(-3.0) };
    v = eval1(e, call_expr(e, DS_FN_POW, a_negzero_odd, 2));
    if (g_eval1_faulted || v.kind != DS_RETE_VAL_FLOAT || !(isinf(v.f) && v.f < 0)) { ds_rete_engine_destroy(e); return fail("-0.0 ** -3.0 should be -inf"); }

    ds_rete_expr_t *a_neg_frac[2] = { lit_float(-8.0), lit_float(0.5) };
    v = eval1(e, call_expr(e, DS_FN_POW, a_neg_frac, 2));
    if (g_eval1_faulted || v.kind != DS_RETE_VAL_FLOAT || !isnan(v.f)) { ds_rete_engine_destroy(e); return fail("-8.0 ** 0.5 should be NaN"); }

    ds_rete_expr_t *a_recip[2] = { lit_int(2), lit_int(-3) };
    v = eval1(e, call_expr(e, DS_FN_POW, a_recip, 2));
    if (g_eval1_faulted || v.kind != DS_RETE_VAL_FLOAT || v.f != 0.125) { ds_rete_engine_destroy(e); return fail("2 ** -3 should be 0.125"); }

    ds_rete_expr_t *a_neg_int[2] = { lit_float(-2.0), lit_float(3.0) };
    v = eval1(e, call_expr(e, DS_FN_POW, a_neg_int, 2));
    if (g_eval1_faulted || v.kind != DS_RETE_VAL_FLOAT || v.f != -8.0) { ds_rete_engine_destroy(e); return fail("-2.0 ** 3.0 should be -8.0"); }

    ds_rete_expr_t *a_root2[2] = { lit_float(2.0), lit_float(0.5) };
    v = eval1(e, call_expr(e, DS_FN_POW, a_root2, 2));
    if (g_eval1_faulted || v.kind != DS_RETE_VAL_FLOAT || v.f != 0x1.6a09e667f3bcdp+0) { ds_rete_engine_destroy(e); return fail("2.0 ** 0.5 should be sqrt(2), correctly rounded"); }

    ds_rete_engine_destroy(e);
    return 0;
}

/* `sqrt` of a negative is NaN, as IEEE 754's is ([LDET.3.6.2]), and
 * [LEXP.4.2]'s slot check keeps the NaN out of working memory. The last two
 * cases fail a `sqrt` that answers NaN for everything: a positive argument
 * computes, and `sqrt(-0.0)` is `-0.0`. */
static int test_sqrt_ieee(void)
{
    ds_rete_engine_t *e = make_engine();
    ds_rete_val_t v;

    ds_rete_expr_t *a_neg[1] = { lit_float(-1.0) };
    v = eval1(e, call_expr(e, DS_FN_SQRT, a_neg, 1));
    if (g_eval1_faulted || v.kind != DS_RETE_VAL_FLOAT || !isnan(v.f)) { ds_rete_engine_destroy(e); return fail("sqrt(-1.0) should be NaN"); }

    ds_rete_expr_t *a_neg_int[1] = { lit_int(-4) };
    v = eval1(e, call_expr(e, DS_FN_SQRT, a_neg_int, 1));
    if (g_eval1_faulted || v.kind != DS_RETE_VAL_FLOAT || !isnan(v.f)) { ds_rete_engine_destroy(e); return fail("sqrt(-4) should be NaN"); }

    ds_rete_expr_t *a_pos[1] = { lit_float(4.0) };
    v = eval1(e, call_expr(e, DS_FN_SQRT, a_pos, 1));
    if (v.kind != DS_RETE_VAL_FLOAT || v.f != 2.0) { ds_rete_engine_destroy(e); return fail("sqrt(4.0) should be 2.0"); }

    ds_rete_expr_t *a_negzero[1] = { lit_float(-0.0) };
    v = eval1(e, call_expr(e, DS_FN_SQRT, a_negzero, 1));
    if (v.kind != DS_RETE_VAL_FLOAT || v.f != 0.0 || !signbit(v.f)) { ds_rete_engine_destroy(e); return fail("sqrt(-0.0) should be -0.0"); }

    ds_rete_engine_destroy(e);
    return 0;
}

/* `cosine_distance`, EXACT by [LDET.3.3a.4]. Every expectation is exact: the
 * norms are whole numbers (5 and 3). The three 2-D values are the ends and
 * middle of [LEXP.5.7.1]'s `[0, 2]` range (identical, orthogonal, opposed),
 * so a stub returning a constant fails.
 *
 * A zero vector gives NaN, the pinned formula's `0.0 / 0.0` ([LEXP.5.7.3],
 * [LDET.3.6.2]), and [LEXP.4.2] keeps the NaN out of working memory. */
static int test_cosine_distance(void)
{
    ds_rete_engine_t *e = make_engine();
    ds_rete_val_t v;

    ds_rete_expr_t *same[4] = { lit_float(3.0), lit_float(4.0),
                                lit_float(3.0), lit_float(4.0) };
    v = eval1(e, call_expr(e, DS_FN_COSINE_2D, same, 4));
    if (v.kind != DS_RETE_VAL_FLOAT || v.f != 0.0) { ds_rete_engine_destroy(e); return fail("cosine 2d identical should be 0.0"); }

    ds_rete_expr_t *orth[4] = { lit_float(1.0), lit_float(0.0),
                                lit_float(0.0), lit_float(1.0) };
    v = eval1(e, call_expr(e, DS_FN_COSINE_2D, orth, 4));
    if (v.kind != DS_RETE_VAL_FLOAT || v.f != 1.0) { ds_rete_engine_destroy(e); return fail("cosine 2d orthogonal should be 1.0"); }

    ds_rete_expr_t *opp[4] = { lit_float(1.0), lit_float(0.0),
                               lit_float(-1.0), lit_float(0.0) };
    v = eval1(e, call_expr(e, DS_FN_COSINE_2D, opp, 4));
    if (v.kind != DS_RETE_VAL_FLOAT || v.f != 2.0) { ds_rete_engine_destroy(e); return fail("cosine 2d opposed should be 2.0"); }

    /* Int operands take the same path — GEO_REQUIRE admits INT and FLOAT. */
    ds_rete_expr_t *ints[4] = { lit_int(3), lit_int(4), lit_int(3), lit_int(4) };
    v = eval1(e, call_expr(e, DS_FN_COSINE_2D, ints, 4));
    if (v.kind != DS_RETE_VAL_FLOAT || v.f != 0.0) { ds_rete_engine_destroy(e); return fail("cosine 2d over Int operands"); }

    ds_rete_expr_t *zero[4] = { lit_float(0.0), lit_float(0.0),
                                lit_float(1.0), lit_float(1.0) };
    v = eval1(e, call_expr(e, DS_FN_COSINE_2D, zero, 4));
    if (g_eval1_faulted || v.kind != DS_RETE_VAL_FLOAT || !isnan(v.f)) { ds_rete_engine_destroy(e); return fail("cosine 2d zero vector should be NaN"); }

    ds_rete_expr_t *same3[6] = { lit_float(1.0), lit_float(2.0), lit_float(2.0),
                                 lit_float(1.0), lit_float(2.0), lit_float(2.0) };
    v = eval1(e, call_expr(e, DS_FN_COSINE_3D, same3, 6));
    if (v.kind != DS_RETE_VAL_FLOAT || v.f != 0.0) { ds_rete_engine_destroy(e); return fail("cosine 3d identical should be 0.0"); }

    ds_rete_expr_t *orth3[6] = { lit_float(1.0), lit_float(0.0), lit_float(0.0),
                                 lit_float(0.0), lit_float(1.0), lit_float(0.0) };
    v = eval1(e, call_expr(e, DS_FN_COSINE_3D, orth3, 6));
    if (v.kind != DS_RETE_VAL_FLOAT || v.f != 1.0) { ds_rete_engine_destroy(e); return fail("cosine 3d orthogonal should be 1.0"); }

    ds_rete_expr_t *zero3[6] = { lit_float(0.0), lit_float(0.0), lit_float(0.0),
                                 lit_float(1.0), lit_float(1.0), lit_float(1.0) };
    v = eval1(e, call_expr(e, DS_FN_COSINE_3D, zero3, 6));
    if (g_eval1_faulted || v.kind != DS_RETE_VAL_FLOAT || !isnan(v.f)) { ds_rete_engine_destroy(e); return fail("cosine 3d zero vector should be NaN"); }

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_bitwise(void)
{
    ds_rete_engine_t *e = make_engine();
    ds_rete_val_t v;

    ds_rete_expr_t *ab[2] = { lit_int(0xF0), lit_int(0x0F) };
    v = eval1(e, call_expr(e, DS_FN_BIT_AND, ab, 2));
    if (v.kind != DS_RETE_VAL_INT || v.i != 0) { ds_rete_engine_destroy(e); return fail("bit_and"); }

    ds_rete_expr_t *ob[2] = { lit_int(0xF0), lit_int(0x0F) };
    v = eval1(e, call_expr(e, DS_FN_BIT_OR, ob, 2));
    if (v.kind != DS_RETE_VAL_INT || v.i != 0xFF) { ds_rete_engine_destroy(e); return fail("bit_or"); }

    ds_rete_expr_t *xb[2] = { lit_int(0xFF), lit_int(0x0F) };
    v = eval1(e, call_expr(e, DS_FN_BIT_XOR, xb, 2));
    if (v.kind != DS_RETE_VAL_INT || v.i != 0xF0) { ds_rete_engine_destroy(e); return fail("bit_xor"); }

    ds_rete_expr_t *nb[1] = { lit_int(0) };
    v = eval1(e, call_expr(e, DS_FN_BIT_NOT, nb, 1));
    if (v.kind != DS_RETE_VAL_INT || v.i != ~(int64_t)0) { ds_rete_engine_destroy(e); return fail("bit_not"); }

    ds_rete_expr_t *sl[2] = { lit_int(1), lit_int(4) };
    v = eval1(e, call_expr(e, DS_FN_BIT_SHL, sl, 2));
    if (v.kind != DS_RETE_VAL_INT || v.i != 16) { ds_rete_engine_destroy(e); return fail("bit_shl"); }

    ds_rete_expr_t *sr[2] = { lit_int(16), lit_int(2) };
    v = eval1(e, call_expr(e, DS_FN_BIT_SHR, sr, 2));
    if (v.kind != DS_RETE_VAL_INT || v.i != 4) { ds_rete_engine_destroy(e); return fail("bit_shr"); }

    ds_rete_engine_destroy(e);
    return 0;
}

/* FN_NOW is the WALL clock as a Time ([LTIM.2.8.3]), UTC. A standalone rete
   engine's default wall source is the host's CLOCK_REALTIME, so the instant
   is after 2020-01-01 -- a bound a monotonic read (near boot or engine
   start) does not meet, which is what tells the two clocks apart here. */
static int test_now(void)
{
    ds_rete_engine_t *e = make_engine();
    ds_rete_val_t v = eval1(e, call_expr(e, DS_FN_NOW, NULL, 0));
    ds_rete_engine_destroy(e);
    if (v.kind != DS_RETE_VAL_TIME) return fail("now builtin: kind != TIME");
    if (v.time.utc_ns < 1577836800000000000LL)
        return fail("now builtin: not a wall-clock instant");
    if (v.time.tz_offset_s != 0) return fail("now builtin: offset != 0");
    return 0;
}

static int test_json_path(void)
{
    ds_rete_engine_t *e = make_engine();

    ds_rete_expr_t *args[2] = {
        lit_str(e, "{\"a\": 42, \"b\": {\"c\": \"hello\"}}"),
        lit_str(e, "a")
    };
    ds_rete_val_t v = eval1(e, call_expr(e, DS_FN_JSON_PATH, args, 2));
    if (v.kind != DS_RETE_VAL_INT || v.i != 42) {
        ds_rete_engine_destroy(e);
        return fail("json-path: top-level int");
    }

    ds_rete_expr_t *args2[2] = {
        lit_str(e, "{\"a\": 42, \"b\": {\"c\": \"hello\"}}"),
        lit_str(e, "b.c")
    };
    v = eval1(e, call_expr(e, DS_FN_JSON_PATH, args2, 2));
    /* Compare before engine_destroy. */
    int rc = 0;
    if (v.kind != DS_RETE_VAL_STR)
        rc = fail("json-path: nested string kind");
    else if (strcmp(v.s.ptr, "hello") != 0)
        rc = fail("json-path: nested string value");
    ds_rete_engine_destroy(e);
    return rc;
}

static int test_json_path_expr_node(void)
{
    ds_rete_engine_t *e = make_engine();
    ds_rete_eval_ctx_t ctx = { .engine = e };

    ds_rete_expr_t *expr = ds_rete_expr_alloc(DS_RETE_EXPR_JSON_PATH);
    expr->json_path.val  = lit_str(e, "[10, 20, 30]");
    expr->json_path.path = lit_str(e, "[1]");
    ds_rete_val_t v = ds_rete_eval(&ctx, expr);
    ds_rete_expr_free_tree(expr);
    ds_rete_engine_destroy(e);

    if (v.kind != DS_RETE_VAL_INT || v.i != 20) return fail("json-path expr node");
    return 0;
}

/* [RLOW.6.3.4]: the traversal returns the leaf, and an object or an array is a
   Json value, not its text. Over a String's text the path walks a tree parsed
   for it, and the value borrows into that tree, so the engine keeps it until
   the next pump (ds_rete_transient_json_free; this test calls it as the pump
   entry does). A scalar leaf keeps nothing: its tree is freed at once. The
   memcheck lanes run this under valgrind, which shows the borrow valid until
   the free and the tree freed exactly once. */
static int test_json_path_composite(void)
{
    ds_rete_engine_t *e = make_engine();
    int rc = 0;

    ds_rete_expr_t *obj[2] = {
        lit_str(e, "{\"a\": 42, \"b\": {\"c\": \"hello\", \"d\": [1, 2]}}"),
        lit_str(e, "b")
    };
    ds_rete_val_t v = eval1(e, call_expr(e, DS_FN_JSON_PATH, obj, 2));
    char  *text = NULL;
    size_t len  = 0;
    if (v.kind != DS_RETE_VAL_JSON_BORROW || v.json == NULL)
        rc = fail("json-path composite: an object is not a Json value");
    else if (ds_json_serialize(v.json, &text, &len).status != DS_OK
             || strcmp(text, "{\"c\":\"hello\",\"d\":[1,2]}") != 0)
        rc = fail("json-path composite: the object is not the subtree");
    else if (e->transient_json_n != 1)
        rc = fail("json-path composite: the parsed tree is not kept");
    ds_free(text);

    ds_rete_expr_t *leaf[2] = {
        lit_str(e, "{\"a\": 42}"),
        lit_str(e, "a")
    };
    v = eval1(e, call_expr(e, DS_FN_JSON_PATH, leaf, 2));
    if (rc == 0 && (v.kind != DS_RETE_VAL_INT || v.i != 42))
        rc = fail("json-path composite: a scalar leaf");
    else if (rc == 0 && e->transient_json_n != 1)
        rc = fail("json-path composite: a scalar leaf kept its tree");

    ds_rete_eval_ctx_t ctx = { .engine = e };
    ds_rete_expr_t *expr = ds_rete_expr_alloc(DS_RETE_EXPR_JSON_PATH);
    expr->json_path.val  = lit_str(e, "{\"xs\": [10, 20, 30]}");
    expr->json_path.path = lit_str(e, "xs");
    v = ds_rete_eval(&ctx, expr);
    ds_json_kind_t kind = DS_JSON_NULL;
    if (rc == 0 && (v.kind != DS_RETE_VAL_JSON_BORROW || v.json == NULL
                    || ds_json_get_kind(v.json, &kind).status != DS_OK
                    || kind != DS_JSON_ARRAY))
        rc = fail("json-path composite: the expr node's array");
    else if (rc == 0 && e->transient_json_n != 2)
        rc = fail("json-path composite: the expr node's tree is not kept");
    ds_rete_expr_free_tree(expr);

    ds_rete_transient_json_free(e);
    if (rc == 0 && e->transient_json_n != 0)
        rc = fail("json-path composite: the pump-entry free left a tree");
    ds_rete_engine_destroy(e);
    return rc;
}

/* 53, 77 and 110 are `reserved` in builtin_fn.proto. The loader refuses a
   CALL naming an op with no handler (DS_ERR_FN_NOT_FOUND), so a handler
   registered for one would load an artefact the proto says cannot exist. */
static int test_retired_ops_have_no_handler(void)
{
    ds_rete_engine_t *e = make_engine();
    static const uint32_t retired[] = { 53u, 77u, 110u };
    int bad = 0;
    for (size_t i = 0; i < sizeof retired / sizeof retired[0]; i++) {
        if (ds_lookup_fn(retired[i]) != NULL) {
            fprintf(stderr, "FAIL: reserved op %u has a handler\n",
                    (unsigned)retired[i]);
            bad = 1;
        }
    }
    ds_rete_engine_destroy(e);
    return bad;
}

static int test_regex_match_flags(void)
{
    ds_rete_engine_t *e = make_engine();
    ds_rete_val_t v;

    /* Case-insensitive */
    ds_rete_expr_t *ci[3] = { lit_str(e, "HELLO"), lit_str(e, "hello"), lit_str(e, "i") };
    v = eval1(e, call_expr(e, DS_FN_REGEX_MATCH, ci, 3));
    if (v.kind != DS_RETE_VAL_BOOL || !v.b) { ds_rete_engine_destroy(e); return fail("regex-match case-insensitive"); }

    /* Case-sensitive (no flag) → no match */
    ds_rete_expr_t *cs[2] = { lit_str(e, "HELLO"), lit_str(e, "hello") };
    v = eval1(e, call_expr(e, DS_FN_REGEX_MATCH, cs, 2));
    if (v.kind != DS_RETE_VAL_BOOL || v.b) { ds_rete_engine_destroy(e); return fail("regex-match case-sensitive"); }

    ds_rete_engine_destroy(e);
    return 0;
}

/* [LNUL.4.1] with [LREG.1.3]: a null subject propagates. The match is null,
   not false and not a fault, so `!~`, the match's `not`, does not continue on
   it either. Mercury's test_ds checks the same answer. */
static int test_regex_match_null_subject(void)
{
    ds_rete_engine_t *e = make_engine();
    ds_rete_expr_t *a[3] = {
        ds_rete_expr_alloc(DS_RETE_EXPR_LIT_NULL), lit_str(e, "x"),
        lit_str(e, ""),
    };
    ds_rete_val_t v = eval1(e, call_expr(e, DS_FN_REGEX_MATCH, a, 3));
    int rc = (!g_eval1_faulted && v.kind == DS_RETE_VAL_NULL)
           ? 0 : fail("regex-match null subject → null");
    ds_rete_engine_destroy(e);
    return rc;
}

/* [LREG.4.1]'s captures. These build the engine by hand, so
   engine->regex_cache is NULL and the builtin compiles per call. A loaded
   artefact takes the precompiled path, whose walk (regex_walk_expr) visits
   FN_REGEX_CAPTURE too. */
static int test_regex_capture_groups(void)
{
    ds_rete_engine_t *e = make_engine();
    ds_rete_val_t v;
    int rc = 0;

    /* Two named groups, bound left to right — the order [LREG.4.1]'s binding
       list is bound in. Group numbering is 1-based; group 0 (the whole match)
       is deliberately unreachable. */
    ds_rete_expr_t *g1[4] = {
        lit_str(e, "sensor7 on 42"),
        lit_str(e, "(?<device>\\w+) on (?<code>\\d+)"),
        lit_str(e, ""), lit_int(1),
    };
    v = eval1(e, call_expr(e, DS_FN_REGEX_CAPTURE, g1, 4));
    if (v.kind != DS_RETE_VAL_STR || strcmp(v.s.ptr, "sensor7") != 0)
        rc = fail("regex-capture group 1");

    ds_rete_expr_t *g2[4] = {
        lit_str(e, "sensor7 on 42"),
        lit_str(e, "(?<device>\\w+) on (?<code>\\d+)"),
        lit_str(e, ""), lit_int(2),
    };
    v = eval1(e, call_expr(e, DS_FN_REGEX_CAPTURE, g2, 4));
    if (!rc && (v.kind != DS_RETE_VAL_STR || strcmp(v.s.ptr, "42") != 0))
        rc = fail("regex-capture group 2");

    ds_rete_engine_destroy(e);
    return rc;
}

static int test_regex_capture_no_match_is_err(void)
{
    /* A fault, not "", which a group that captured empty also gives. The
       lowering gates the activation on the match ([LREG.1.2]), so an
       artefact does not reach this; if anything does, it must not answer
       plausibly. */
    ds_rete_engine_t *e = make_engine();
    ds_rete_expr_t *a[4] = {
        lit_str(e, "nothing here"), lit_str(e, "(\\d+)"),
        lit_str(e, ""), lit_int(1),
    };
    ds_rete_val_t v = eval1(e, call_expr(e, DS_FN_REGEX_CAPTURE, a, 4));
    int rc = (g_eval1_faulted) ? 0 : fail("regex-capture no match → ERR");
    ds_rete_engine_destroy(e);
    return rc;
}

static int test_regex_capture_flags_apply(void)
{
    /* The gate and the extraction must agree about which strings match, so
       the flags have to reach both. */
    ds_rete_engine_t *e = make_engine();
    ds_rete_expr_t *a[4] = {
        lit_str(e, "DEVICE42"), lit_str(e, "device(\\d+)"),
        lit_str(e, "i"), lit_int(1),
    };
    ds_rete_val_t v = eval1(e, call_expr(e, DS_FN_REGEX_CAPTURE, a, 4));
    int rc = (v.kind == DS_RETE_VAL_STR && strcmp(v.s.ptr, "42") == 0)
           ? 0 : fail("regex-capture honours flags");
    ds_rete_engine_destroy(e);
    return rc;
}

static int test_regex_capture_group_out_of_range(void)
{
    ds_rete_engine_t *e = make_engine();
    ds_rete_val_t v;
    int rc = 0;

    /* Group 0 is the whole match in RE2's numbering and has no DS syntax that
       binds it; asking for it is a caller bug, not an empty capture. */
    ds_rete_expr_t *z[4] = {
        lit_str(e, "abc"), lit_str(e, "(b)"), lit_str(e, ""), lit_int(0),
    };
    v = eval1(e, call_expr(e, DS_FN_REGEX_CAPTURE, z, 4));
    if (!g_eval1_faulted) rc = fail("regex-capture group 0 → ERR");

    /* Past the pattern's group count. The compiler enforces name count ==
       capture count ([LREG.4.2]), so this means artefact and pattern
       disagree. */
    ds_rete_expr_t *hi[4] = {
        lit_str(e, "abc"), lit_str(e, "(b)"), lit_str(e, ""), lit_int(9),
    };
    v = eval1(e, call_expr(e, DS_FN_REGEX_CAPTURE, hi, 4));
    if (!rc && !g_eval1_faulted)
        rc = fail("regex-capture group past the count → ERR");

    ds_rete_engine_destroy(e);
    return rc;
}

static int test_regex_capture_nonparticipating_group(void)
{
    /* An alternation branch not taken. [LREG.4.4] makes every captured value
       a String "regardless of pattern shape", so it is the empty string. That
       is a reading: no clause tells it from a group that matched empty. */
    ds_rete_engine_t *e = make_engine();
    ds_rete_expr_t *a[4] = {
        lit_str(e, "b"), lit_str(e, "(a)?(b)"), lit_str(e, ""), lit_int(1),
    };
    ds_rete_val_t v = eval1(e, call_expr(e, DS_FN_REGEX_CAPTURE, a, 4));
    int rc = (v.kind == DS_RETE_VAL_STR && v.s.len == 0)
           ? 0 : fail("regex-capture non-participating group → \"\"");
    ds_rete_engine_destroy(e);
    return rc;
}

/* [RDSC.4a.9.3]: a call whose operands its op does not admit is
   ARTEFACT_LIED. test_rdsc_4a_9_5_operands covers every row of
   [RDSC.4a.9.5]'s counts; these helpers build the calls the cases below ask,
   each evaluated with its fault held, which hands back the cause the call
   raised: DS_FAULT_ARTEFACT, which `ds_rete_fault` records as ARTEFACT_LIED. */
static ds_rete_expr_t *lit_null(void)
{
    return ds_rete_expr_alloc(DS_RETE_EXPR_LIT_NULL);
}

static int raises_cause(ds_rete_engine_t *e, const char *what,
                        ds_builtin_fn_t op, ds_rete_expr_t **args,
                        uint32_t argc, ds_rete_fault_cause_t want)
{
    ds_rete_expr_t *call = call_expr(e, op, args, argc);
    ds_rete_eval_ctx_t ctx = { .engine = e };
    ds_rete_held_t held = { .held = false };
    (void)ds_rete_eval_holding(&ctx, call, &held);
    ds_rete_expr_free_tree(call);
    if (ctx.faulted || !held.held || held.cause != want) {
        fprintf(stderr, "FAIL: %s: faulted=%d held=%d cause=%d, want %d\n",
                what, (int)ctx.faulted, (int)held.held, (int)held.cause,
                (int)want);
        return 1;
    }
    return 0;
}

static int not_admitted(ds_rete_engine_t *e, const char *what,
                        ds_builtin_fn_t op, ds_rete_expr_t **args,
                        uint32_t argc)
{
    return raises_cause(e, what, op, args, argc, DS_FAULT_ARTEFACT);
}

/* @spec [RDSC.4a.9.3]: what no [RDSC.4a.9.5] row states. A `publish` carries
   one value per slot of its schema past the schema name, so a call the row
   admits can still not match the schema it names; the adapter judges that,
   holding the schema. And a call that is not admitted is a fault an absorbing
   `and` still absorbs. Mercury's test_ds `test_rdsc_4a_9_3_operands` and
   `test_rdsc_4a_9_3_verbs` ask the same. */
static int test_rdsc_4a_9_3__what_no_row_states(void)
{
    ds_rete_engine_t *e = make_engine();
    ds_rete_register_adapters(e, NULL);
    /* A zero-slot schema for `publish`'s count: its name and no value. */
    ds_rete_schema_register(e, "P0", DS_RETE_SCOPE_PLAIN, 0, NULL, 0, NULL);
    /* And a one-slot schema, for a publish with fewer values than slots. */
    ds_rete_slot_desc_t p1_slots[] = { { .name = "v", .type = DS_RETE_VAL_INT } };
    ds_rete_schema_register(e, "P1", DS_RETE_SCOPE_PLAIN, 0, p1_slots, 1, NULL);
    int rc = 0;

    /* Fewer values than slots: nothing fills the missing slot. */
    ds_rete_expr_t *pub1[1] = { lit_str(e, "P1") };
    rc |= not_admitted(e, "publish with fewer values than slots",
                       DS_FN_PUBLISH, pub1, 1);
    ds_rete_expr_t *pub2[2] = { lit_str(e, "P0"), lit_int(1) };
    rc |= not_admitted(e, "publish with more values than slots",
                       DS_FN_PUBLISH, pub2, 2);

    /* AN ABSORBING `and` STILL ABSORBS IT ([IRET.9.6], [LERR.1.4.11]): `false`
       decides the conjunction, so the fault is not raised and nothing halts. */
    ds_rete_expr_t *and_ = ds_rete_expr_alloc(DS_RETE_EXPR_BINOP);
    and_->binop.op    = DS_RETE_BINOP_AND;
    and_->binop.left  = lit_bool(false);
    and_->binop.right = call_expr(e, DS_FN_ABS, NULL, 0);
    ds_rete_val_t v = eval1(e, and_);
    if (g_eval1_faulted || v.kind != DS_RETE_VAL_BOOL || v.b)
        rc |= fail("false and abs() → false, no fault");

    ds_rete_engine_destroy(e);
    return rc;
}

/* @spec [IRET.9.6]: a `String ::` conversion handed a present value that is
   not a String is an ill-typed operation -- a TypeError when the value is
   Json-sourced, ARTEFACT_LIED otherwise -- and not `null`, which only a
   string the conversion does not accept answers ([LCST.4.5.5],
   [LCST.4.5.7], [LCST.4.5.8]). Mercury's test_ds
   `test_string_conversion_kinds` asks the same. */
static int test_iret_9_6__string_conversion_of_a_non_string(void)
{
    ds_rete_engine_t *e = make_engine();
    ds_rete_register_adapters(e, NULL);
    int rc = 0;
    ds_rete_expr_t *i1[1] = { lit_int(1) };
    rc |= raises_cause(e, "string_to_int(1)", DS_FN_STRING_TO_INT, i1, 1,
                       DS_FAULT_TYPE_MISMATCH);
    ds_rete_expr_t *f1[1] = { lit_bool(true) };
    rc |= raises_cause(e, "string_to_float(true)", DS_FN_STRING_TO_FLOAT, f1, 1,
                       DS_FAULT_TYPE_MISMATCH);
    ds_rete_expr_t *b1[1] = { lit_float(1.0) };
    rc |= raises_cause(e, "string_to_bool(1.0)", DS_FN_STRING_TO_BOOL, b1, 1,
                       DS_FAULT_TYPE_MISMATCH);
    /* The control: a string the conversion does not accept is `null`. */
    ds_rete_expr_t *s1[1] = { lit_str(e, "x") };
    ds_rete_val_t v = eval1(e, call_expr(e, DS_FN_STRING_TO_INT, s1, 1));
    if (g_eval1_faulted || v.kind != DS_RETE_VAL_NULL)
        rc |= fail("string_to_int(\"x\") → null");
    ds_rete_engine_destroy(e);
    return rc;
}

static ds_rete_expr_t *binop(int op, ds_rete_expr_t *l, ds_rete_expr_t *r)
{
    ds_rete_expr_t *n = ds_rete_expr_alloc(DS_RETE_EXPR_BINOP);
    n->binop.op = op; n->binop.left = l; n->binop.right = r;
    return n;
}

/* The check's call, its fault held: the held record when it faulted, and its
   value otherwise. `*call_out` is the call, freed by the caller, so a case can
   ask which node the held fault was raised at. */
static ds_rete_val_t check_held(ds_rete_engine_t *e, ds_rete_expr_t **args,
                                uint32_t argc, ds_rete_held_t *held,
                                ds_rete_expr_t **call_out)
{
    ds_rete_expr_t *call = call_expr(e, DS_FN_INTERVAL_CHECK, args, argc);
    ds_rete_eval_ctx_t ctx = { .engine = e };
    ds_rete_val_t v = ds_rete_eval_holding(&ctx, call, held);
    *call_out = call;
    return v;
}

/* @spec [RLOW.6.1.7] @spec [LINT.7.2]: the check
   yields `v` when every pair is `s <= e` or has a `null` endpoint, `null` `v`
   included; otherwise one fault, chosen by [LNUL.4.2]'s order among the
   arguments' faults and a DOMAIN for each invalid pair, a complete tie keeping
   the argument's. A DOMAIN's origin is its pair's start ([LERR.9.12]); with
   no fact in this harness, a start is told apart by its value's tag, the
   origin's `actual`. Mercury's test_ds
   `test_rlow_6_1_7_interval_check` asks the same questions, with the same
   answers. */
static int test_rlow_6_1_7__interval_check(void)
{
    ds_rete_engine_t *e = make_engine();
    ds_rete_register_adapters(e, NULL);
    int rc = 0;
    ds_rete_held_t h;
    ds_rete_expr_t *call;
    ds_rete_val_t v;

    /* VALID: `v`, whatever it is. */
    ds_rete_expr_t *ok[3] = { lit_int(1), lit_int(2), lit_bool(true) };
    v = check_held(e, ok, 3, &h, &call);
    if (h.held || v.kind != DS_RETE_VAL_BOOL || !v.b)
        rc |= fail("check(1, 2, true) → true");
    ds_rete_expr_free_tree(call);
    /* An empty interval is valid ([LINT.7.1]). */
    ds_rete_expr_t *empty[3] = { lit_int(5), lit_int(5), lit_bool(false) };
    v = check_held(e, empty, 3, &h, &call);
    if (h.held || v.kind != DS_RETE_VAL_BOOL || v.b)
        rc |= fail("check(5, 5, false) → false, no fault");
    ds_rete_expr_free_tree(call);
    /* A `null` endpoint is valid, and a `null` `v` is the answer. */
    ds_rete_expr_t *nul[3] = { lit_null(), lit_int(3), lit_null() };
    v = check_held(e, nul, 3, &h, &call);
    if (h.held || v.kind != DS_RETE_VAL_NULL)
        rc |= fail("check(null, 3, null) → null, no fault");
    ds_rete_expr_free_tree(call);

    /* INVALID: DOMAIN, naming the pair's start. */
    ds_rete_expr_t *inv[3] = { lit_int(5), lit_int(3), lit_bool(false) };
    v = check_held(e, inv, 3, &h, &call);
    if (!h.held || h.cause != DS_FAULT_DOMAIN || h.origin.actual == NULL
        || strcmp(h.origin.actual, "Int") != 0)
        rc |= fail("check(5, 3, false) → DOMAIN at 5");
    ds_rete_expr_free_tree(call);
    /* A NaN endpoint: `s <= e` is false. */
    ds_rete_expr_t *nan_[3] = { lit_float(nan("")), lit_float(5.0),
                                lit_bool(false) };
    v = check_held(e, nan_, 3, &h, &call);
    if (!h.held || h.cause != DS_FAULT_DOMAIN)
        rc |= fail("check(NaN, 5.0, false) → DOMAIN");
    ds_rete_expr_free_tree(call);
    /* A `null` `v` does not prevent the check ([LNUL.4.10]). */
    ds_rete_expr_t *nulv[3] = { lit_int(5), lit_int(3), lit_null() };
    v = check_held(e, nulv, 3, &h, &call);
    if (!h.held || h.cause != DS_FAULT_DOMAIN)
        rc |= fail("check(5, 3, null) → DOMAIN, not null");
    ds_rete_expr_free_tree(call);
    /* The SECOND pair invalid: its start is the offending operand, not the
       call's first. The first pair is Float and the second Int, so an origin
       taken at the call's first operand would read `Float`. */
    ds_rete_expr_t *two[5] = { lit_float(1.0), lit_float(2.0), lit_int(5),
                               lit_int(3), lit_bool(false) };
    v = check_held(e, two, 5, &h, &call);
    if (!h.held || h.cause != DS_FAULT_DOMAIN || h.origin.actual == NULL
        || strcmp(h.origin.actual, "Int") != 0)
        rc |= fail("check(1.0, 2.0, 5, 3, false) → DOMAIN at the second start");
    ds_rete_expr_free_tree(call);

    /* AN ARGUMENT'S FAULT COMPETES: DIVIDE_BY_ZERO is TrapKind 1, DOMAIN 2, so
       `v`'s division by zero is the fault, beside an invalid pair. */
    ds_rete_expr_t *dz[3] = { lit_int(5), lit_int(3),
                              binop(DS_RETE_BINOP_IDIV, lit_int(1),
                                    lit_int(0)) };
    v = check_held(e, dz, 3, &h, &call);
    if (!h.held || h.cause != DS_FAULT_DIVIDE_BY_ZERO)
        rc |= fail("check(5, 3, 1 // 0) → DIVIDE_BY_ZERO");
    ds_rete_expr_free_tree(call);
    /* A COMPLETE TIE KEEPS THE ARGUMENT'S: `v`'s own DOMAIN (a negative shift
       count, [LEXP.7.14.1]) beside an invalid Float pair, neither naming a
       slot or a fact, is one record ([LNUL.4.2]; a ComputationError's
       `actual` is not a field it records). The one held is `v`'s, at `v`'s
       site, whose first operand is the Int 1. */
    ds_rete_expr_t *shl = binop(DS_RETE_BINOP_SHL, lit_int(1), lit_int(-1));
    ds_rete_expr_t *tie[3] = { lit_float(5.0), lit_float(3.0), shl };
    v = check_held(e, tie, 3, &h, &call);
    if (!h.held || h.cause != DS_FAULT_DOMAIN || h.expr != shl
        || h.origin.actual == NULL || strcmp(h.origin.actual, "Int") != 0)
        rc |= fail("check(5.0, 3.0, 1 << -1) → v's DOMAIN");
    ds_rete_expr_free_tree(call);

    /* ENDPOINTS OF TWO KINDS: no conforming compiler writes them, so the
       artefact lied. */
    ds_rete_expr_t *kinds[3] = { lit_int(1), lit_str(e, "a"), lit_bool(true) };
    v = check_held(e, kinds, 3, &h, &call);
    if (!h.held || h.cause != DS_FAULT_ARTEFACT)
        rc |= fail("check(1, \"a\", true) → ARTEFACT");
    ds_rete_expr_free_tree(call);
    /* A COUNT THAT IS NOT THREE OR FIVE ([RDSC.4a.9.3]). */
    ds_rete_expr_t *four[4] = { lit_int(1), lit_int(2), lit_int(3),
                                lit_bool(true) };
    rc |= not_admitted(e, "interval_check of four", DS_FN_INTERVAL_CHECK,
                       four, 4);
    (void)v;
    ds_rete_engine_destroy(e);
    return rc;
}

/* A String value over the first `len` bytes of `buf`, whose byte at `len` is
   NOT a NUL. A reader that walks to a terminator instead of stopping at `len`
   reads the bytes after it, and each case below is built so that those bytes
   change the answer. */
static ds_rete_val_t unterminated(const char *buf, uint32_t len)
{
    if (buf[len] == '\0') {
        fprintf(stderr, "FIXTURE: the byte at len is a NUL: \"%s\"\n", buf);
        abort();
    }
    return ds_rete_val_str(buf, len);
}

/* A terminated literal, for the operands a case does not test. */
static ds_rete_val_t term_str(const char *s)
{
    return ds_rete_val_str(s, (uint32_t)strlen(s));
}

/* The op's handler, called as eval_call calls it, on `args` as given: nothing
   copies or re-terminates them on the way in. */
static ds_rete_val_t call_on(ds_rete_engine_t *e, ds_builtin_fn_t op,
                             ds_rete_val_t *args, uint32_t argc, bool *faulted)
{
    ds_rete_val_t out = ds_rete_val_null();
    const ds_fn_slot_t *slot = ds_lookup_fn(op);
    *faulted = true;
    if (slot == NULL) return out;
    ds_rete_eval_ctx_t ctx = { .engine = e };
    ds_result_t r = slot->fn(e, &ctx, args, argc, &out);
    *faulted = ctx.faulted || r.status != DS_OK;
    return out;
}

/* Each reader of a string value, handed one whose byte at `len` is not a NUL,
   answers from its `len` bytes alone: the regex subject, pattern and
   flags, a capture's subject, error_code_matches' two codes, a Json root's
   text and its path, `has` and `len`'s paths, String→Bool and `to_string`'s
   format. Every answer here differs from the one the bytes past `len` would
   give. */
static int test_string_value_is_its_length(void)
{
    ds_rete_engine_t *e = make_engine();
    ds_rete_register_adapters(e, NULL);
    int  rc = 0;
    bool f;
    ds_rete_val_t v;

    if (re2_linked()) {
        /* The subject "abc" of "abcX": `c$` matches it and not "abcX". */
        ds_rete_val_t m1[2] = { unterminated("abcX", 3), term_str("c$") };
        v = call_on(e, DS_FN_REGEX_MATCH, m1, 2, &f);
        if (f || v.kind != DS_RETE_VAL_BOOL || !v.b)
            rc |= fail("regex subject: \"abc\" ~ /c$/ reads past its length");
        /* The pattern "c$" of "c$Q": a hand-built network compiles it per
           call, and "c$Q" matches nothing. */
        ds_rete_val_t m2[2] = { term_str("abc"), unterminated("c$Q", 2) };
        v = call_on(e, DS_FN_REGEX_MATCH, m2, 2, &f);
        if (f || v.kind != DS_RETE_VAL_BOOL || !v.b)
            rc |= fail("regex pattern: /c$/ compiled past its length");
        /* No flags, "" of "i": read past, `i` would fold the case. */
        ds_rete_val_t m3[3] = { term_str("ABC"), term_str("abc"), unterminated("i", 0) };
        v = call_on(e, DS_FN_REGEX_MATCH, m3, 3, &f);
        if (f || v.kind != DS_RETE_VAL_BOOL || v.b)
            rc |= fail("regex flags: an empty flag set read past its length");
        /* The capture's subject "k=v" of "k=vZ": group 1 is "v", not "vZ". */
        ds_rete_val_t c1[4] = { unterminated("k=vZ", 3), term_str("=(.*)"), term_str(""),
                                ds_rete_val_int(1) };
        v = call_on(e, DS_FN_REGEX_CAPTURE, c1, 4, &f);
        if (f || v.kind != DS_RETE_VAL_STR || v.s.len != 1 || v.s.ptr[0] != 'v')
            rc |= fail("regex capture: the subject read past its length");
    } else {
        printf("  skip: the regex readers (this build links no RE2)\n");
    }

    /* error_code_matches: code "auth" of "authx" is a whole segment; pattern
       "auth" of "authZ" is a prefix of "auth". */
    ds_rete_val_t ec1[2] = { unterminated("authx", 4), term_str("auth") };
    v = call_on(e, DS_FN_ERROR_CODE_MATCHES, ec1, 2, &f);
    if (f || v.kind != DS_RETE_VAL_BOOL || !v.b)
        rc |= fail("error_code_matches: the code read past its length");
    ds_rete_val_t ec2[2] = { term_str("auth"), unterminated("authZ", 4) };
    v = call_on(e, DS_FN_ERROR_CODE_MATCHES, ec2, 2, &f);
    if (f || v.kind != DS_RETE_VAL_BOOL || !v.b)
        rc |= fail("error_code_matches: the pattern read past its length");

    /* json_path: the text `{"a":1}` of `{"a":1}}` parses, and the path "a" of
       "a.b" reaches the 1. Past either length the text does not parse, or the
       path misses. */
    ds_rete_val_t jp[2] = { unterminated("{\"a\":1}}", 7),
                            unterminated("a.b", 1) };
    v = call_on(e, DS_FN_JSON_PATH, jp, 2, &f);
    if (f || v.kind != DS_RETE_VAL_INT || v.i != 1)
        rc |= fail("json_path: the text or the path read past its length");
    /* has: the path "a" of "ab" is present; "ab" is not. */
    ds_rete_val_t jh[2] = { term_str("{\"a\":1}"), unterminated("ab", 1) };
    v = call_on(e, DS_FN_JSON_HAS, jh, 2, &f);
    if (f || v.kind != DS_RETE_VAL_BOOL || !v.b)
        rc |= fail("has: the path read past its length");
    /* len: the path "a" of "ax" is an array of two; "ax" misses. */
    ds_rete_val_t jl[2] = { term_str("{\"a\":[1,2]}"), unterminated("ax", 1) };
    v = call_on(e, DS_FN_JSON_LEN, jl, 2, &f);
    if (f || v.kind != DS_RETE_VAL_INT || v.i != 2)
        rc |= fail("len: the path read past its length");

    /* String→Bool: "true" of "trueX". */
    ds_rete_val_t sb[1] = { unterminated("trueX", 4) };
    v = call_on(e, DS_FN_STRING_TO_BOOL, sb, 1, &f);
    if (f || v.kind != DS_RETE_VAL_BOOL || !v.b)
        rc |= fail("String->Bool: the string read past its length");

    /* to_string's format "epoch_seconds" of "epoch_secondsX": an unknown
       format is NOT_REPRESENTABLE, so a read past the length faults. */
    ds_rete_val_t ts[2] = { ds_rete_val_time(0, 0),
                            unterminated("epoch_secondsX", 13) };
    v = call_on(e, DS_FN_TO_STRING, ts, 2, &f);
    if (f || v.kind != DS_RETE_VAL_STR || v.s.len != 1 || v.s.ptr[0] != '0')
        rc |= fail("to_string: the format read past its length");

    ds_rete_engine_destroy(e);
    return rc;
}

/* ds_json_get_path_n: a path ends at its length, and an index is digits alone
   ([IDAT.3.3.10]). An index past uint32 is a miss, not an index truncated to
   32 bits. */
static int test_json_path_ends_at_its_length(void)
{
    int rc = 0;
    ds_json_t *root = NULL;
    const char text[] = "{\"a\":[5,6]}";
    if (ds_json_parse(text, sizeof text - 1, &root).status != DS_OK)
        return fail("parse {\"a\":[5,6]}");
    const ds_json_t *n = NULL;
    ds_result_t r;

    r = ds_json_get_path_n(root, "a[1]7", 4, &n);
    if (r.status != DS_OK || n == NULL || n->kind != DS_JSON_INT || n->v.i != 6)
        rc |= fail("a[1] of \"a[1]7\" is 6");
    r = ds_json_get_path_n(root, "a[1]", 3, &n);
    if (r.status != DS_ERR_INVAL)
        rc |= fail("a[1 of \"a[1]\" has no close: malformed, not 6");
    r = ds_json_get_path(root, "a[ 1]", &n);
    if (r.status != DS_ERR_INVAL)
        rc |= fail("a[ 1] is malformed: white space");
    r = ds_json_get_path(root, "a[-0]", &n);
    if (r.status != DS_ERR_INVAL)
        rc |= fail("a[-0] is malformed: a sign");
    r = ds_json_get_path(root, "a[-1]", &n);
    if (r.status != DS_ERR_INVAL)
        rc |= fail("a[-1] is malformed");
    n = root;
    r = ds_json_get_path(root, "a[4294967296]", &n);
    if (r.status != DS_OK || n != NULL)
        rc |= fail("a[4294967296] is a miss, not slot 0's check");
    n = root;
    r = ds_json_get_path(root, "a[99999999999999999999999]", &n);
    if (r.status != DS_OK || n != NULL)
        rc |= fail("an index past every integer is a miss");

    ds_json_free(root);
    return rc;
}

static int test_double_register_idempotent(void)
{
    ds_rete_engine_t *e = make_engine();
    /* The op dispatch table is global: a second ds_register_builtins
       overwrites each slot with the same handler and answers OK. */
    ds_result_t r = ds_register_builtins(e);
    ds_rete_engine_destroy(e);
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: double register: want OK got %d\n", r.status);
        return 1;
    }
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
#define RUN_RE2(t) do { \
    if (re2_linked()) RUN(t); \
    else printf("  skip: " #t " (this build links no RE2)\n"); \
} while (0)

    printf("=== test_rete_builtins ===\n");
    RUN(test_error_code_matches);
    RUN(test_str_length);
    RUN(test_math);
    RUN(test_transcendentals);
    RUN(test_sqrt_ieee);
    RUN(test_pow_ieee);
    RUN(test_cosine_distance);
    RUN(test_bitwise);
    RUN(test_now);
    RUN(test_json_path);
    RUN(test_json_path_expr_node);
    RUN(test_json_path_composite);
    RUN(test_retired_ops_have_no_handler);
    RUN_RE2(test_regex_match_flags);
    RUN_RE2(test_regex_match_null_subject);
    RUN_RE2(test_regex_capture_groups);
    RUN_RE2(test_regex_capture_no_match_is_err);
    RUN_RE2(test_regex_capture_flags_apply);
    RUN_RE2(test_regex_capture_group_out_of_range);
    RUN_RE2(test_regex_capture_nonparticipating_group);
    RUN(test_rdsc_4a_9_3__what_no_row_states);
    RUN(test_iret_9_6__string_conversion_of_a_non_string);
    RUN(test_rlow_6_1_7__interval_check);
    RUN(test_string_value_is_its_length);
    RUN(test_json_path_ends_at_its_length);
    RUN(test_double_register_idempotent);
#undef RUN

    if (fail_count == 0) {
        printf("=== test_rete_builtins: ALL PASSED ===\n");
        return 0;
    }
    fprintf(stderr, "=== test_rete_builtins: %d FAILED ===\n", fail_count);
    return 1;
}
