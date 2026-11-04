/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * fn.h — DS builtin dispatch, indexed by op (builtin_fn.h). The table is global and
 * shared across engines.
 */
#ifndef LIBDS2_FN_H
#define LIBDS2_FN_H

#include <stdbool.h>
#include <stdint.h>

#include "libds.h"
#include "rete/val.h"
#include "builtin_fn.h"

struct ds_rete_engine;
struct ds_rete_eval_ctx;

typedef ds_result_t (*ds_fn_t)(
    struct ds_rete_engine   *engine,
    struct ds_rete_eval_ctx *ctx,
    ds_rete_val_t           *args,
    uint32_t                 arg_count,
    ds_rete_val_t           *result_out
);

typedef struct {
    ds_fn_t fn;        /* NULL = op unregistered */
    bool    rt_safe;   /* O(1)/bounded, no alloc */
} ds_fn_slot_t;

extern ds_fn_slot_t ds_builtin_dispatch[DS_FN__MAX];

/* Idempotent: engines re-register identically. In rt_mode the CALL evaluator rejects
   a builtin not registered with `_rt`. */
ds_result_t ds_register_fn(ds_builtin_fn_t op, ds_fn_t fn);
ds_result_t ds_register_fn_rt(ds_builtin_fn_t op, ds_fn_t fn);

static inline const ds_fn_slot_t *ds_lookup_fn(uint32_t op)
{
    if (op == 0u || op >= (uint32_t) DS_FN__MAX || !ds_builtin_dispatch[op].fn)
        return NULL;
    return &ds_builtin_dispatch[op];
}

/* ---- Operand counts, [RDSC.4a.9.5] --------------------------------- */

/* How a row reads its counts ([RDSC.4a.9.3]). RANGE admits every count from
   `min` to `max`. PAIRS admits `min` and then any whole number of pairs,
   `min` + 2n, up to `max`. NONE admits no count: no clause in force has the
   compiler emit the op as a call. NO_ROW is a number with no member, or a
   retired member with no constant here; it admits nothing either. */
typedef enum {
    DS_FN_SHAPE_NO_ROW = 0,
    DS_FN_SHAPE_RANGE,
    DS_FN_SHAPE_PAIRS,
    DS_FN_SHAPE_NONE
} ds_fn_shape_t;

/* An empty `Max`: no upper bound. */
#define DS_FN_OPERANDS_ANY UINT32_MAX

typedef struct {
    uint32_t      min;
    uint32_t      max;
    ds_fn_shape_t shape;
} ds_fn_operands_t;

/* Generated into fn.c from [RDSC.4a.9.5].
   `eval_call` (rete/eval.c) reads it before a handler runs, so no handler counts
   its operands. Mercury: `ds.builtins.rdsc_4a_9_5_operands`, from the same rows. */
extern const ds_fn_operands_t ds_fn_operands[DS_FN__MAX];

static inline bool ds_fn_operands_admitted(uint32_t op, uint32_t argc)
{
    if (op >= (uint32_t) DS_FN__MAX) return false;
    const ds_fn_operands_t *row = &ds_fn_operands[op];
    switch (row->shape) {
    case DS_FN_SHAPE_RANGE:
        return argc >= row->min && argc <= row->max;
    case DS_FN_SHAPE_PAIRS:
        return argc >= row->min && argc <= row->max
            && (argc - row->min) % 2u == 0u;
    case DS_FN_SHAPE_NONE:
    case DS_FN_SHAPE_NO_ROW:
        return false;
    }
    return false;
}

#endif /* LIBDS2_FN_H */
