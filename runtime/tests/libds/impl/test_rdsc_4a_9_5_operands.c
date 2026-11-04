/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * Every row of [RDSC.4a.9.5]. A call whose operand count or shape its op does
 * not admit raises ENGINE_FAULT_ARTEFACT_LIED ([RDSC.4a.9.3]). `eval_call`
 * reads `ds_fn_operands` (fn.c, generated from the clause) before any handler
 * runs.
 *
 * For every row of the generated table: a call one operand
 * short of `min`, one past `max` where it has one, and at a `pairs` row's
 * `min` + 1, is evaluated as the Rete evaluator evaluates any call, with its
 * fault HELD, and must hand back DS_FAULT_ARTEFACT, which `ds_rete_fault`
 * records as ARTEFACT_LIED. Every operand is a `null` literal, which evaluates
 * without a fault, so the count is the only thing wrong. A `none` row has no
 * count to step past, and a number with no member no row.
 *
 * No source reaches these calls, since the compiler emits the count each op
 * admits, so they are hand-built. The engine is a whole one (`ds_engine_new`),
 * so every handler is registered, the series reads included, and a row whose
 * op has no handler is a failure here rather than a case that passes on the
 * loader's refusal.
 *
 * The other side too: each row admits its `min`, its `max` where it has one,
 * and a `pairs` row its `min` + 2 below the `max`.
 *
 * Mercury's test_ds `test_rdsc_4a_9_5_every_row` asks the same of every row
 * of its generated `rdsc_4a_9_5_operands`, with the same answers.
 */
#include <stdio.h>
#include <stdlib.h>

#include "libds.h"
#include "builtin_fn.h"
#include "engine.h"
#include "fn.h"
#include "rete/engine.h"
#include "rete/eval.h"
#include "rete/expr.h"
#include "rete/val.h"

/* A CALL of `op` with `argc` `null` literals. Freed by the caller. */
static ds_rete_expr_t *call_of_nulls(uint32_t op, uint32_t argc)
{
    ds_rete_expr_t *node = ds_rete_expr_alloc(DS_RETE_EXPR_CALL);
    node->call.op        = op;
    node->call.arg_count = argc;
    if (argc > 0) {
        node->call.args = calloc(argc, sizeof(ds_rete_expr_t *));
        for (uint32_t i = 0; i < argc; i++)
            node->call.args[i] = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_NULL);
    }
    return node;
}

/* Whether a call of `op` with `argc` operands raises DS_FAULT_ARTEFACT. */
static int not_admitted(ds_rete_engine_t *re, uint32_t op, uint32_t argc)
{
    ds_rete_expr_t *call = call_of_nulls(op, argc);
    ds_rete_eval_ctx_t ctx = { .engine = re };
    ds_rete_held_t held = { .held = false };
    (void)ds_rete_eval_holding(&ctx, call, &held);
    ds_rete_expr_free_tree(call);
    if (ctx.faulted || !held.held || held.cause != DS_FAULT_ARTEFACT) {
        fprintf(stderr, "FAIL: op %u with %u operands: faulted=%d held=%d "
                "cause=%d, want DS_FAULT_ARTEFACT\n", op, argc,
                (int)ctx.faulted, (int)held.held, (int)held.cause);
        return 1;
    }
    return 0;
}

/* @spec [RDSC.4a.9.5] */
static int test_rdsc_4a_9_5__every_row_refuses_what_it_does_not_admit(void)
{
    ds_engine_t *e = NULL;
    if (ds_engine_new(NULL, &e).status != DS_OK) {
        fprintf(stderr, "FAIL: engine_new\n");
        return 1;
    }
    int      rc    = 0;
    unsigned rows  = 0;
    unsigned cases = 0;
    unsigned none_rows = 0;
    for (uint32_t op = 1; op < (uint32_t)DS_FN__MAX; op++) {
        const ds_fn_operands_t *row = &ds_fn_operands[op];
        /* A `none` row admits no count and has no handler: the loader
           refuses a call of it, DS_ERR_FN_NOT_FOUND ([RDSC.4a.9.3]). */
        if (row->shape == DS_FN_SHAPE_NONE) {
            none_rows++;
            if (ds_lookup_fn(op) != NULL) {
                fprintf(stderr, "FAIL: op %u is a none row and has a "
                        "handler\n", op);
                rc = 1;
            }
            continue;
        }
        if (row->shape == DS_FN_SHAPE_NO_ROW)
            continue;
        rows++;
        if (ds_lookup_fn(op) == NULL) {
            fprintf(stderr, "FAIL: op %u has a row and no handler\n", op);
            rc = 1;
            continue;
        }
        if (row->min > 0) {
            rc |= not_admitted(e->rete_engine, op, row->min - 1);
            cases++;
        }
        if (row->max != DS_FN_OPERANDS_ANY) {
            rc |= not_admitted(e->rete_engine, op, row->max + 1);
            cases++;
        }
        if (row->shape == DS_FN_SHAPE_PAIRS) {
            rc |= not_admitted(e->rete_engine, op, row->min + 1);
            cases++;
        }
    }
    if (rows == 0 || cases == 0 || none_rows == 0) {
        fprintf(stderr, "FAIL: the table judged %u rows in %u cases and %u "
                "none rows; it was read as empty\n", rows, cases, none_rows);
        rc = 1;
    }
    fprintf(stderr, "rdsc_4a_9_5: %u rows, %u not-admitted cases, %u none "
            "rows with no handler\n", rows, cases, none_rows);
    ds_engine_free(e);
    return rc;
}

/* @spec [RDSC.4a.9.5] */
static int test_rdsc_4a_9_5__every_row_admits_what_it_states(void)
{
    int rc = 0;
    for (uint32_t op = 1; op < (uint32_t)DS_FN__MAX; op++) {
        const ds_fn_operands_t *row = &ds_fn_operands[op];
        int ok = 1;
        switch (row->shape) {
        case DS_FN_SHAPE_NO_ROW:
        case DS_FN_SHAPE_NONE:
            ok = !ds_fn_operands_admitted(op, 0)
              && !ds_fn_operands_admitted(op, 1);
            break;
        case DS_FN_SHAPE_RANGE:
            ok = ds_fn_operands_admitted(op, row->min)
              && ds_fn_operands_admitted(op, row->max == DS_FN_OPERANDS_ANY
                                             ? row->min + 64u : row->max);
            break;
        case DS_FN_SHAPE_PAIRS:
            ok = ds_fn_operands_admitted(op, row->min)
              && (row->max < row->min + 2u
                  || ds_fn_operands_admitted(op, row->min + 2u));
            break;
        }
        if (!ok) {
            fprintf(stderr, "FAIL: op %u's row does not admit the counts it "
                    "states\n", op);
            rc = 1;
        }
    }
    return rc;
}

int main(void)
{
    int failed = 0;
    /* OR-store, never short-circuit (ITST): every scenario runs. */
    failed |= test_rdsc_4a_9_5__every_row_refuses_what_it_does_not_admit();
    failed |= test_rdsc_4a_9_5__every_row_admits_what_it_states();
    if (failed) {
        fprintf(stderr, "test_rdsc_4a_9_5_operands: FAILED\n");
        return 1;
    }
    printf("test_rdsc_4a_9_5_operands: OK\n");
    return 0;
}
