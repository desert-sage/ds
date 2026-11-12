/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/eval.h — expression evaluation context and evaluator (IRET.9.2).
 *
 * A fault is recorded on the stream where it is raised ([NCBK.2.8]) and latched
 * as `ctx->faulted`; the returned value is inert ([LEXP.7.12]). Every consumer
 * tests the latch, and the action loop abandons the activation on it ([LERR.1]).
 */
#ifndef LIBDS2_INTERNAL_RETE_EVAL_H
#define LIBDS2_INTERNAL_RETE_EVAL_H

#include <stdbool.h>
#include <stdint.h>

#include "libds.h"
#include "rete/expr.h"
#include "rete/fact.h"
#include "rete/token.h"
#include "rete/val.h"

struct ds_rete_engine;

/*
 * What a fault was raised over: the offending operand's schema, slot and fact
 * when it is a slot read, and its value's tag when known. [LNUL.4.2]'s order
 * compares them. NULL / 0 is unset. The strings are engine-lifetime.
 */
typedef struct {
    const char *schema_name;
    const char *slot_name;
    uint64_t    fact_id;
    const char *actual;
} ds_rete_fault_origin_t;

/* ---- Evaluation context (IRET.9.2) -------------------------------- */

typedef struct ds_rete_eval_ctx {
    ds_rete_token_t  *token;       /* current partial match (NULL at engine root) */
    ds_rete_fact_t   *right_fact;  /* candidate right fact; NULL when in RHS      */
    ds_rete_val_t    *bind_frame;  /* let bindings; may be NULL                   */
    uint32_t          bind_count;
    struct ds_rete_engine *engine;
    /* One now() per firing ([IRET.25.4.1]). `fire_now_valid` is the occupancy,
       since 0 is a legitimate clock reading; false in alpha and join tests. */
    int64_t           fire_now_ns;
    bool              fire_now_valid;
    /* The firing activation, during eval_actions: for adapters that stamp it on
       what they deliver ([RFCS.15]) and on the faults raised in the action
       ([LERR.9.11]). `rule_name` is engine-lifetime. */
    int64_t           timetag;
    const char       *rule_name;
    /* The rule name of a fault raised with no activation ([LERR.9.11]); see
       `ds_rete_fault_rule`. NULL outside matching. */
    const char       *site_rule;
    /* A fault raised here is recorded and passed to the callback, not queued as
       a fault fact ([LERR.9.6]). */
    bool              fault_handler_site;
    /* The network node this evaluation belongs to, the identity of a TypeError
       record. 0 means no node: node 0 is the WM root, no fault site. */
    uint32_t          node_id;
    /* Json provenance for a fault raised with no expr in hand: `eval_call` stamps
       it from the CALL node, whose taint is transitive, around a builtin. */
    bool              json_tainted;
    /* The CALL node a builtin runs under, stamped beside `json_tainted`: the site
       `origin_at` reads to name the offending argument ([LERR.9.2], [LERR.9.3]).
       NULL outside a builtin. */
    const struct ds_rete_expr *call_site;
    /* The fault latch ([LEXP.7.12]): a fault is a property of the evaluation, not
       of a value. Set by `ds_rete_fault`, never cleared: each evaluation unit
       builds a fresh zero-filled ctx. */
    bool              faulted;
    /* [LNUL.4.2]'s absorbing `and` / `or` ([IRET.9.5]): a fault in one operand is
       decided away by a `false` in the other, so it cannot be recorded when
       raised. While `hold_faults` is non-zero, `ds_rete_fault` holds an operand
       fault, keeping the one the order ranks first, and `ds_rete_eval_holding`
       hands it to the combinator. DS_FAULT_RESOURCE is not held: it is no
       operand's fault.

       `held_tainted` is the provenance at the raise, and `held_origin` what it
       was raised over, which `ds_rete_held_select` has no ctx to take.
       `held_cause` is an `int` only because the enum is declared below. */
    uint32_t                    hold_faults;
    bool                        fault_held;
    int                         held_cause;
    bool                        held_tainted;
    const struct ds_rete_expr  *held_expr;
    ds_rete_fault_origin_t      held_origin;
    /* Whether the last `Json` path resolved reached an object or an array, which
       interpolating is a TypeError (LGRA.2.9.6.11). The value's kind cannot tell
       that from a whole Json slot's document. Read by `eval_interp` alone. */
    bool                        json_composite;
    /* A bound refused this action's effect (LSTO.4.7.5, [LERR.1.5]). A `cache`
       write is a CALL whose status `eval_call` does not return, so `ds-cache-set`
       sets this and `eval_actions` stops on it. Not a fault. */
    bool                        bounds_refused;
} ds_rete_eval_ctx_t;

/* ---- Faults ------------------------------------------------------- */

/*
 * The cause of a failed evaluation: one funnel, shared by the evaluator, the
 * builtins and the adapters. A second one is what the ratchet in
 * runtime/tests/libds/source/ refuses.
 */
typedef enum {
    /* An operation is invalid for the value it got: TypeError when `json_tainted`
       ([LADP.5.5.3]), else EngineError, the artefact having lied. Not for a null
       operand. */
    DS_FAULT_TYPE_MISMATCH = 0,
    /* TypeError whatever the taint ([IRET.9.6]): a `null` in a `T?` slot is a
       value the artefact declared. A separate cause, so it cannot be reordered
       into the wrong answer. */
    DS_FAULT_NULL_OPERAND,
    /* ComputationError / TRAP_DIVIDE_BY_ZERO ([LEXP.7.15.1], [LERR.1.4.9]). */
    DS_FAULT_DIVIDE_BY_ZERO,
    /* ComputationError / TRAP_DOMAIN ([LERR.1.4.9]): undefined at that input, or a
       read with no answer: no `TimeZoneOffset` fact ([LTIM.10.7]), an unset wall
       clock. */
    DS_FAULT_DOMAIN,
    /* An allocation failure: EngineError / ENGINE_FAULT_ALLOCATION. */
    DS_FAULT_RESOURCE,
    /* The artefact does not match its own declaration: EngineError /
       ENGINE_FAULT_ARTEFACT_LIED. */
    DS_FAULT_ARTEFACT,
    /* ComputationError / TRAP_NOT_REPRESENTABLE: `Float :: Int` outside int64
       ([LCST.4.5.4]), currency arithmetic leaving int64. */
    DS_FAULT_NOT_REPRESENTABLE,
    /* EngineError / ENGINE_FAULT_PATTERN_INDEX: a position the match never bound. */
    DS_FAULT_PATTERN_INDEX,
    /* EngineError / ENGINE_FAULT_BINDING_ORDER: a `let` read before its binding. */
    DS_FAULT_BINDING_ORDER,
} ds_rete_fault_cause_t;

/*
 * Record a fault, latch `ctx->faulted`, and return an inert value the caller must
 * not read. `expr` may be NULL in a builtin: provenance then comes from the ctx.
 * Once per occurrence, at the site that detects the condition.
 */
/* [IERR.1.7]: the intern table's fault hook, its `ctx` a ds_rete_engine_t. An
   EngineError of ENGINE_FAULT_INTERNAL, and the halt. */
void ds_rete_raise_intern_fault(void *ctx);

ds_rete_val_t ds_rete_fault(ds_rete_eval_ctx_t   *ctx,
                            const ds_rete_expr_t *expr,
                            ds_rete_fault_cause_t cause);

/*
 * [RARC.5.2.7] A rule's action would put into a slot a value the schema does
 * not admit: a TypeError whatever the value's taint, naming the schema, the slot
 * and the value's tag. The caller abandons the activation.
 */
ds_rete_val_t ds_rete_fault_slot_refused(ds_rete_eval_ctx_t  *ctx,
                                         const char          *schema_name,
                                         const char          *slot_name,
                                         const ds_rete_val_t *value);

/*
 * [LERR.9.11]: the activation's rule, else the node's `$alpha_<id>` /
 * `$beta_<id>`, else `$engine`. Never NULL or "". Engine-lifetime.
 */
const char *ds_rete_fault_rule(const ds_rete_eval_ctx_t *ctx);

/*
 * A fault held while an operand of an absorbing combinator was evaluated; see
 * `hold_faults`. `origin` is derived from `expr` as [LERR.9.12] derives it,
 * except that `FN_INTERVAL_CHECK` sets it to the invalid pair's start
 * ([RLOW.6.1.7]).
 */
typedef struct {
    bool                   held;
    ds_rete_fault_cause_t  cause;
    bool                   tainted;
    const ds_rete_expr_t  *expr;
    ds_rete_fault_origin_t origin;
} ds_rete_held_t;

/*
 * Evaluate `expr` with operand faults held. On return:
 *   `ctx->faulted` set  -- resource exhaustion, already recorded.
 *   `held->held` set    -- the operand faulted; nothing recorded, `faulted`
 *                          cleared, the value inert.
 *   neither             -- the operand's value.
 */
ds_rete_val_t ds_rete_eval_holding(ds_rete_eval_ctx_t   *ctx,
                                   const ds_rete_expr_t *expr,
                                   ds_rete_held_t       *held);

/* Held again if an enclosing combinator is still holding. */
ds_rete_val_t ds_rete_raise_held(ds_rete_eval_ctx_t *ctx,
                                 const ds_rete_held_t *held);

/* Whether `held` holds a fault that `ds_rete_raise_held` would record as an
   EngineError, and so halt the tier ([LERR.1.4.7]). */
bool ds_rete_held_is_engine_error(const ds_rete_held_t *held);

/* The mismatch for an operand that is neither a Bool nor `null`, held because a
 * `false` elsewhere absorbs it ([LNUL.4.2]). */
ds_rete_held_t ds_rete_held_mismatch(ds_rete_eval_ctx_t   *ctx,
                                     const ds_rete_expr_t *expr);

/* [LNUL.4.2]: keep in `*into` whichever of the two the order selects. */
void ds_rete_held_select(ds_rete_held_t *into, const ds_rete_held_t *other);

#define type_error_at(ctx, expr) \
    ds_rete_fault((ctx), (expr), DS_FAULT_TYPE_MISMATCH)

/*
 * [IRET.9.6]: NULL_OPERAND if any argument is `null`, wherever it stands, since
 * `ds_rete_fault` is not handed the operands. */
static inline ds_rete_fault_cause_t
ds_rete_mismatch_cause(const ds_rete_val_t *args, uint32_t argc)
{
    for (uint32_t i = 0; i < argc; i++)
        if (args[i].kind == DS_RETE_VAL_NULL) return DS_FAULT_NULL_OPERAND;
    return DS_FAULT_TYPE_MISMATCH;
}

/* ---- Json projection ---------------------------------------------- */

/*
 * [LNUL.8.4], RLOW.6.3.4: an unresolved path (NULL) and a JSON `null` are `null`;
 * a scalar leaf is the value of its kind; an array or an object is a `Json` value
 * borrowed from the walked tree. `ctx` may be NULL, hence `engine`, whose arena
 * takes a String leaf. `struct ds_rete_engine`, since engine.h would cycle.
 */
struct ds_json;
ds_rete_val_t ds_rete_json_to_val(ds_rete_eval_ctx_t *ctx,
                                  struct ds_rete_engine *engine,
                                  const struct ds_json *node);

/* A path's result, `found`, projected; `owned` is the tree the path walked
 * when the caller parsed it from text, else NULL. Takes `owned`: freed, or,
 * when the result borrows into it (an object or an array), kept by the engine
 * until the next pump. */
ds_rete_val_t ds_rete_json_path_result(ds_rete_eval_ctx_t *ctx,
                                       struct ds_rete_engine *engine,
                                       const struct ds_json *found,
                                       struct ds_json *owned);

/* ---- Evaluator ---------------------------------------------------- */

/*
 * Check `ctx->faulted` before reading the result: on a fault it is inert.
 */
ds_rete_val_t ds_rete_eval(ds_rete_eval_ctx_t *ctx,
                             const ds_rete_expr_t *expr);

/*
 * False on a fault and on `null` ([LNUL.4.3]). Any other kind raises and answers
 * false. The latch is tested first, since a faulted evaluation returns `null`.
 */
bool ds_rete_eval_as_bool(ds_rete_eval_ctx_t *ctx,
                           const ds_rete_expr_t *expr);

/*
 * The monotonic clock's read ([LTIM.2.8.2]): per-fire snapshot, then RT per-cycle
 * cache, then clock_fn.
 */
int64_t ds_rete_eval_now_ns(const ds_rete_eval_ctx_t *ctx);

/*
 * The wall clock's read ([LTIM.2.8.3]). False while it has no value.
 */
bool ds_rete_eval_wall_ns(const ds_rete_eval_ctx_t *ctx, int64_t *out_utc_ns);

#endif /* LIBDS2_INTERNAL_RETE_EVAL_H */
