/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/eval.c — expression tree evaluator (IRET.9).
 */
#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "internal/json.h"
#include "ds_alloc.h"

#include "rete/alpha.h"
#include "rete/fault_fact.h"
#include "rete/engine.h"
#include "rete/eval.h"
#include "rete/expr.h"
#include "rete/intern.h"
#include "fn.h"
#include "rete/val.h"
#include "int_ops.h"
#include "ds_text.h"
#include "float_fmt.h"
#include "rete/adapters.h"
#include "wm.h"

static ds_rete_val_t eval_json_path_expr(ds_rete_eval_ctx_t   *ctx,
                                          const ds_rete_expr_t *expr);

/* The rete tree includes no DS-layer header. */
struct ds_engine;
extern ds_result_t ds_recorder_emit_type_error(struct ds_engine *engine,
                                                 uint32_t          node_id,
                                                 const char       *rule_name,
                                                 const char       *schema_name,
                                                 const char       *slot_name,
                                                 const char       *actual);
extern ds_result_t ds_recorder_emit_computation_error(struct ds_engine *engine,
                                                        ds_trap_kind_t    kind,
                                                        const char       *rule_name,
                                                        int64_t           timetag,
                                                        const char       *schema_name,
                                                        const char       *slot_name,
                                                        uint64_t          fact_id,
                                                        uint32_t          node_id);
extern ds_result_t ds_recorder_emit_engine_error(struct ds_engine  *engine,
                                                   ds_engine_fault_t  fault,
                                                   uint32_t           node_id,
                                                   const char        *rule_name);
/* A fault's fact_id is the wrapper's, not the rete fact's. */
extern ds_result_t ds_engine_fact_by_rete_id(struct ds_engine *engine,
                                             uint32_t          rete_id,
                                             ds_fact_t       **out);
extern uint64_t ds_recorder_input_fact_id(const struct ds_engine *engine,
                                          const char             *schema_name);

/* ---- Where a fault was raised over ---------------------------------- */

/*
 * [NCBK.2.10]: a fault's payload is the fields of its proto. Found from the node
 * that raised, without evaluating anything. Its offending operand is the first
 * whose value is known and `null` ([IRET.9.6]), else a division's divisor, else
 * the first. A value is known when it is a literal or a slot read. Where an
 * operand is neither, the fields stay unset: `100 / (x - x)` has no slot to name.
 */
typedef ds_rete_fault_origin_t fault_origin_t;

static const char *val_tag(const ds_rete_val_t *v)
{
    switch (v->kind) {
    case DS_RETE_VAL_INT:         return "Int";
    case DS_RETE_VAL_FLOAT:       return "Float";
    case DS_RETE_VAL_STR:         return "String";
    case DS_RETE_VAL_BOOL:        return "Bool";
    case DS_RETE_VAL_BYTES:       return "Bytes";
    case DS_RETE_VAL_JSON:
    case DS_RETE_VAL_JSON_BORROW: return "Json";
    case DS_RETE_VAL_FACT_REF:    return "FactRef";
    case DS_RETE_VAL_TIME:        return "Time";
    case DS_RETE_VAL_RATIO:       return "Ratio";
    case DS_RETE_VAL_NULL:        return "Null";
    case DS_RETE_VAL_UNBOUND:     return NULL;
    }
    return NULL;
}

/* NULL where `ds_rete_eval`'s VAR case would fault. */
static const ds_rete_fact_t *var_fact(const ds_rete_eval_ctx_t *ctx,
                                      const ds_rete_expr_t     *e)
{
    const uint8_t pi = e->var.pattern_index;
    if (pi == DS_RETE_VAR_RIGHT_FACT) return ctx->right_fact;
    if (!ctx->token || pi >= ctx->token->fact_count) return NULL;
    return ctx->token->facts[pi];
}

/* [LTIM.1.1.3]: a `Time` slot holds its instant as INT and reads back as a TIME
   at offset 0: `to_string` and `add_months` tell a `Time` from a `Date` by it.
   `is Int` still answers true ([LNUL.4.9]). */
static ds_rete_val_t slot_read(const ds_rete_fact_t *f, uint8_t si)
{
    const ds_rete_val_t v = f->slots[si];
    if (f->schema->slots[si].time && v.kind == DS_RETE_VAL_INT)
        return ds_rete_val_time(v.i, 0);
    return v;
}

static bool known_value(const ds_rete_eval_ctx_t *ctx, const ds_rete_expr_t *e,
                        ds_rete_val_t *out)
{
    switch (e->kind) {
    case DS_RETE_EXPR_LIT_INT:   *out = ds_rete_val_int(e->lit_int);     return true;
    case DS_RETE_EXPR_LIT_FLOAT: *out = ds_rete_val_float(e->lit_float); return true;
    case DS_RETE_EXPR_LIT_BOOL:  *out = ds_rete_val_bool(e->lit_bool);   return true;
    case DS_RETE_EXPR_LIT_NULL:  *out = ds_rete_val_null();              return true;
    case DS_RETE_EXPR_LIT_STR:   out->kind = DS_RETE_VAL_STR;            return true;
    case DS_RETE_EXPR_VAR: {
        const ds_rete_fact_t *f = var_fact(ctx, e);
        const uint8_t si = e->var.slot_index;
        if (!f || si == DS_RETE_VAR_WHOLE_FACT || si >= f->schema->slot_count)
            return false;
        *out = slot_read(f, si);
        return true;
    }
    default:
        return false;
    }
}

/* In evaluation order. A node with none is its own operand: a slot read that
   faulted names its fact. */
static uint32_t operands_of(const ds_rete_expr_t *e,
                            const ds_rete_expr_t *const **out,
                            const ds_rete_expr_t *pair[2])
{
    switch (e->kind) {
    case DS_RETE_EXPR_BINOP:
        pair[0] = e->binop.left; pair[1] = e->binop.right;
        *out = pair; return 2;
    case DS_RETE_EXPR_UNOP:
        pair[0] = e->unop.operand; *out = pair; return 1;
    case DS_RETE_EXPR_IS_TEST:
        pair[0] = e->is_test.operand; *out = pair; return 1;
    case DS_RETE_EXPR_IF:
        pair[0] = e->if_.cond; *out = pair; return 1;
    case DS_RETE_EXPR_JSON_PATH:
        pair[0] = e->json_path.val; pair[1] = e->json_path.path;
        *out = pair; return 2;
    case DS_RETE_EXPR_CALL:
        *out = (const ds_rete_expr_t *const *)e->call.args;
        return e->call.arg_count;
    default:
        pair[0] = e; *out = pair; return 1;
    }
}

/* Also how `eval_interval_check` names a pair's start. */
static fault_origin_t operand_origin(ds_rete_eval_ctx_t   *ctx,
                                     const ds_rete_expr_t *off,
                                     struct ds_engine     *de);

static fault_origin_t origin_at(ds_rete_eval_ctx_t   *ctx,
                                const ds_rete_expr_t *site,
                                struct ds_engine     *de)
{
    fault_origin_t o = { NULL, NULL, 0, NULL };
    if (ctx == NULL || site == NULL) return o;

    const ds_rete_expr_t *pair[2] = { NULL, NULL };
    const ds_rete_expr_t *const *ops = NULL;
    const uint32_t n = operands_of(site, &ops, pair);
    if (n == 0 || ops == NULL) return o;

    const ds_rete_expr_t *off = NULL;
    for (uint32_t i = 0; i < n && off == NULL; i++) {
        ds_rete_val_t v;
        if (ops[i] && known_value(ctx, ops[i], &v) && v.kind == DS_RETE_VAL_NULL)
            off = ops[i];
    }
    if (off == NULL && site->kind == DS_RETE_EXPR_BINOP
        && (site->binop.op == DS_RETE_BINOP_DIV
            || site->binop.op == DS_RETE_BINOP_IDIV
            || site->binop.op == DS_RETE_BINOP_MOD))
        off = site->binop.right;
    if (off == NULL) off = ops[0];
    return operand_origin(ctx, off, de);
}

static fault_origin_t operand_origin(ds_rete_eval_ctx_t   *ctx,
                                     const ds_rete_expr_t *off,
                                     struct ds_engine     *de)
{
    fault_origin_t o = { NULL, NULL, 0, NULL };
    if (ctx == NULL || off == NULL) return o;

    ds_rete_val_t v;
    if (known_value(ctx, off, &v)) o.actual = val_tag(&v);
    if (off->kind == DS_RETE_EXPR_VAR) {
        const ds_rete_fact_t *f = var_fact(ctx, off);
        if (f != NULL) {
            const uint8_t si = off->var.slot_index;
            o.schema_name = f->schema->name;
            if (si != DS_RETE_VAR_WHOLE_FACT && si < f->schema->slot_count)
                o.slot_name = f->schema->slots[si].name;
            ds_fact_t *w = NULL;
            if (de != NULL
                && ds_engine_fact_by_rete_id(de, f->id, &w).status == DS_OK
                && w != NULL)
                (void)ds_fact_get_id_unchecked(w, &o.fact_id);
            /* A join test raising during a host assert's propagation reads the
               arriving fact, whose wrapper is minted after the network returns. */
            else if (de != NULL)
                o.fact_id = ds_recorder_input_fact_id(de, f->schema->name);
        }
    }
    return o;
}

/* ---- The fault funnel ---------------------------------------------- */

/*
 * The kind half of [LNUL.4.2]'s order, lower first: EngineError by its
 * `EngineFault`, then TypeError, then the TrapKinds in value order. -1 for a
 * cause that is not an operand's fault.
 */
static int fault_rank(ds_rete_fault_cause_t cause, bool tainted)
{
    switch (cause) {
    case DS_FAULT_TYPE_MISMATCH:
        return tainted ? 100 : 0 + DS_ENGINE_FAULT_ARTEFACT_LIED;
    case DS_FAULT_ARTEFACT:       return 0 + DS_ENGINE_FAULT_ARTEFACT_LIED;
    case DS_FAULT_PATTERN_INDEX:  return 0 + DS_ENGINE_FAULT_PATTERN_INDEX;
    case DS_FAULT_BINDING_ORDER:  return 0 + DS_ENGINE_FAULT_BINDING_ORDER;
    case DS_FAULT_NULL_OPERAND:   return 100;
    case DS_FAULT_DIVIDE_BY_ZERO: return 200 + DS_TRAP_DIVIDE_BY_ZERO;
    case DS_FAULT_DOMAIN:         return 200 + DS_TRAP_DOMAIN;
    case DS_FAULT_NOT_REPRESENTABLE:
        return 200 + DS_TRAP_NOT_REPRESENTABLE;
    case DS_FAULT_RESOURCE:       return -1;
    }
    return -1;
}

/* The arms of `fault_at`'s switch that record an EngineError ([IRET.9.6]). */
static bool cause_is_engine_error(ds_rete_fault_cause_t cause, bool tainted)
{
    switch (cause) {
    case DS_FAULT_TYPE_MISMATCH:  return !tainted;
    case DS_FAULT_RESOURCE:
    case DS_FAULT_ARTEFACT:
    case DS_FAULT_PATTERN_INDEX:
    case DS_FAULT_BINDING_ORDER:  return true;
    case DS_FAULT_NULL_OPERAND:
    case DS_FAULT_DIVIDE_BY_ZERO:
    case DS_FAULT_DOMAIN:
    case DS_FAULT_NOT_REPRESENTABLE:
        return false;
    }
    return false;
}

/* [LNUL.4.2]: by UTF-8 bytes as unsigned values, which is strcmp's order; an
   unset field is the protobuf default, "". */
static int field_cmp(const char *a, const char *b)
{
    return strcmp(a ? a : "", b ? b : "");
}

/*
 * [LNUL.4.2]: whether fault `a` ranks strictly before `b`: kind, then the record's
 * fields in field-number order. Only the offending operand's fields can differ,
 * the rest coming from one evaluation's `ctx`:
 *
 *   ComputationError: schema_name 4, slot_name 5, fact_id 6
 *   TypeError:        schema_name 2, slot_name 3, actual 4
 *   EngineError:      none, so two of one EngineFault record identically.
 */
static bool fault_before(ds_rete_fault_cause_t a_cause, bool a_tainted,
                         const fault_origin_t *a,
                         ds_rete_fault_cause_t b_cause, bool b_tainted,
                         const fault_origin_t *b)
{
    const int ra = fault_rank(a_cause, a_tainted);
    const int rb = fault_rank(b_cause, b_tainted);
    if (ra != rb) return ra < rb;
    if (ra < 100) return false;                  /* EngineError */
    int c = field_cmp(a->schema_name, b->schema_name);
    if (c != 0) return c < 0;
    c = field_cmp(a->slot_name, b->slot_name);
    if (c != 0) return c < 0;
    if (ra == 100)                                /* TypeError */
        return field_cmp(a->actual, b->actual) < 0;
    return a->fact_id < b->fact_id;               /* ComputationError */
}

static ds_rete_val_t fault_at(ds_rete_eval_ctx_t   *ctx,
                              const ds_rete_expr_t *expr,
                              ds_rete_fault_cause_t cause,
                              bool                  tainted,
                              const fault_origin_t *origin);

const char *ds_rete_fault_rule(const ds_rete_eval_ctx_t *ctx)
{
    if (ctx != NULL && ctx->rule_name != NULL && ctx->rule_name[0] != '\0')
        return ctx->rule_name;
    if (ctx != NULL && ctx->site_rule != NULL && ctx->site_rule[0] != '\0')
        return ctx->site_rule;
    return ds_rete_fault_rule_engine;
}

ds_rete_val_t ds_rete_fault(ds_rete_eval_ctx_t *ctx,
                            const ds_rete_expr_t *expr,
                            ds_rete_fault_cause_t cause)
{
    const bool tainted = expr ? expr->json_tainted
                              : (ctx ? ctx->json_tainted : false);
    /* A builtin's fault is at its CALL node, so the origin names an argument. */
    const ds_rete_expr_t *site = expr ? expr : (ctx ? ctx->call_site : NULL);
    return fault_at(ctx, site, cause, tainted, NULL);
}

/* `ds_rete_fault` with the provenance given, so a held fault is raised with the
   taint it had where it was met. `origin` NULL derives it at `expr`. Records if
   there is an engine; the latch is set either way. */
static ds_rete_val_t fault_at(ds_rete_eval_ctx_t   *ctx,
                              const ds_rete_expr_t *expr,
                              ds_rete_fault_cause_t cause,
                              bool                  tainted,
                              const fault_origin_t *origin)
{
    /* See `hold_faults` in eval.h. */
    const int rank = fault_rank(cause, tainted);
    if (ctx != NULL && ctx->hold_faults > 0 && rank >= 0) {
        struct ds_engine *hde = ctx->engine
            ? (struct ds_engine *)ctx->engine->ds_engine_back : NULL;
        const fault_origin_t og = origin ? *origin : origin_at(ctx, expr, hde);
        if (!ctx->fault_held
            || fault_before(cause, tainted, &og,
                            (ds_rete_fault_cause_t)ctx->held_cause,
                            ctx->held_tainted, &ctx->held_origin)) {
            ctx->fault_held   = true;
            ctx->held_cause   = (int)cause;
            ctx->held_tainted = tainted;
            ctx->held_expr    = expr;
            ctx->held_origin  = og;
        }
        ctx->faulted = true;
        return ds_rete_val_null();
    }
    struct ds_engine *de = (ctx && ctx->engine)
        ? (struct ds_engine *)ctx->engine->ds_engine_back : NULL;
    if (de != NULL) {
        const uint32_t node = ctx->node_id;
        const char *rule = ds_rete_fault_rule(ctx);
        const fault_origin_t og = origin ? *origin : origin_at(ctx, expr, de);
        /* A failing stream sink halts nothing ([NCBK.1.5]). */
        switch (cause) {
        case DS_FAULT_NULL_OPERAND:
            (void)ds_recorder_emit_type_error(de, node, rule, og.schema_name,
                                              og.slot_name, og.actual);
            break;
        case DS_FAULT_TYPE_MISMATCH:
            if (tainted)
                (void)ds_recorder_emit_type_error(de, node, rule,
                                                  og.schema_name,
                                                  og.slot_name, og.actual);
            else
                (void)ds_recorder_emit_engine_error(
                    de, DS_ENGINE_FAULT_ARTEFACT_LIED, node, rule);
            break;
        case DS_FAULT_DIVIDE_BY_ZERO:
            (void)ds_recorder_emit_computation_error(
                de, DS_TRAP_DIVIDE_BY_ZERO, rule, ctx->timetag,
                og.schema_name, og.slot_name, og.fact_id, node);
            break;
        case DS_FAULT_DOMAIN:
            (void)ds_recorder_emit_computation_error(
                de, DS_TRAP_DOMAIN, rule, ctx->timetag,
                og.schema_name, og.slot_name, og.fact_id, node);
            break;
        case DS_FAULT_NOT_REPRESENTABLE:
            (void)ds_recorder_emit_computation_error(
                de, DS_TRAP_NOT_REPRESENTABLE, rule, ctx->timetag,
                og.schema_name, og.slot_name, og.fact_id, node);
            break;
        case DS_FAULT_RESOURCE:
            (void)ds_recorder_emit_engine_error(
                de, DS_ENGINE_FAULT_ALLOCATION, node, rule);
            break;
        case DS_FAULT_ARTEFACT:
            (void)ds_recorder_emit_engine_error(
                de, DS_ENGINE_FAULT_ARTEFACT_LIED, node, rule);
            break;
        case DS_FAULT_PATTERN_INDEX:
            (void)ds_recorder_emit_engine_error(
                de, DS_ENGINE_FAULT_PATTERN_INDEX, node, rule);
            break;
        case DS_FAULT_BINDING_ORDER:
            (void)ds_recorder_emit_engine_error(
                de, DS_ENGINE_FAULT_BINDING_ORDER, node, rule);
            break;
        }
        /* [LERR.1.4.7]: beside the DS engine's latch, which the emit just set. */
        if (cause_is_engine_error(cause, tainted))
            ctx->engine->halted = true;

        /* [LERR.9.1]: a TypeError or ComputationError is then asserted as a
           fault fact by the drain ([LERR.9.7]). A handler's own faults are never
           queued ([LERR.9.6]). */
        ds_rete_fault_fact_t ff = { .rule = rule, .schema = og.schema_name,
                                    .slot = og.slot_name, .node = node };
        bool queue = !ctx->fault_handler_site;
        switch (cause) {
        case DS_FAULT_NULL_OPERAND:
            ff.type_error = true;  ff.what = og.actual;            break;
        case DS_FAULT_TYPE_MISMATCH:
            ff.type_error = true;  ff.what = og.actual;
            queue = queue && tainted;                              break;
        case DS_FAULT_DIVIDE_BY_ZERO:   ff.what = "DIVIDE_BY_ZERO";    break;
        case DS_FAULT_DOMAIN:           ff.what = "DOMAIN";            break;
        case DS_FAULT_NOT_REPRESENTABLE: ff.what = "NOT_REPRESENTABLE"; break;
        case DS_FAULT_RESOURCE:
        case DS_FAULT_ARTEFACT:
        case DS_FAULT_PATTERN_INDEX:
        case DS_FAULT_BINDING_ORDER:
            queue = false;                                         break;
        }
        if (queue) ds_rete_fault_fact_enqueue(ctx->engine, &ff);
    }
    /* The latch is the status; the value is inert ([LEXP.7.12]). `null`, so a
       consumer that skipped the check would decline to fire. */
    if (ctx != NULL) ctx->faulted = true;
    return ds_rete_val_null();
}

ds_rete_val_t ds_rete_fault_slot_refused(ds_rete_eval_ctx_t  *ctx,
                                         const char          *schema_name,
                                         const char          *slot_name,
                                         const ds_rete_val_t *value)
{
    if (ctx == NULL) return ds_rete_val_null();
    struct ds_engine *de = ctx->engine
        ? (struct ds_engine *)ctx->engine->ds_engine_back : NULL;
    const char *actual = value ? val_tag(value) : NULL;
    if (de != NULL) {
        const uint32_t node = ctx->node_id;
        const char *rule = ds_rete_fault_rule(ctx);
        (void)ds_recorder_emit_type_error(de, node, rule, schema_name,
                                          slot_name, actual);
        if (!ctx->fault_handler_site) {
            ds_rete_fault_fact_t ff = { .rule = rule, .schema = schema_name,
                                        .slot = slot_name, .node = node,
                                        .type_error = true, .what = actual };
            ds_rete_fault_fact_enqueue(ctx->engine, &ff);
        }
    }
    ctx->faulted = true;
    return ds_rete_val_null();
}

ds_rete_val_t ds_rete_eval_holding(ds_rete_eval_ctx_t   *ctx,
                                   const ds_rete_expr_t *expr,
                                   ds_rete_held_t       *held)
{
    /* An enclosing combinator's held fault is set aside and put back. */
    const bool                   outer_held    = ctx->fault_held;
    const int                    outer_cause   = ctx->held_cause;
    const bool                   outer_tainted = ctx->held_tainted;
    const struct ds_rete_expr   *outer_expr    = ctx->held_expr;
    const ds_rete_fault_origin_t outer_origin  = ctx->held_origin;
    ctx->fault_held = false;

    ctx->hold_faults++;
    ds_rete_val_t v = ds_rete_eval(ctx, expr);
    ctx->hold_faults--;

    held->held = false;
    held->origin = (ds_rete_fault_origin_t){ NULL, NULL, 0, NULL };
    if (ctx->faulted && ctx->fault_held) {
        held->held    = true;
        held->cause   = (ds_rete_fault_cause_t)ctx->held_cause;
        held->tainted = ctx->held_tainted;
        held->expr    = ctx->held_expr;
        held->origin  = ctx->held_origin;
        ctx->faulted  = false;
    }
    ctx->fault_held   = outer_held;
    ctx->held_cause   = outer_cause;
    ctx->held_tainted = outer_tainted;
    ctx->held_expr    = outer_expr;
    ctx->held_origin  = outer_origin;
    return v;
}

/* Over the origin it was held with, which `ds_rete_held_select` ranked it by. */
ds_rete_val_t ds_rete_raise_held(ds_rete_eval_ctx_t *ctx,
                                 const ds_rete_held_t *held)
{
    return fault_at(ctx, held->expr, held->cause, held->tainted,
                    &held->origin);
}

ds_rete_held_t ds_rete_held_mismatch(ds_rete_eval_ctx_t   *ctx,
                                     const ds_rete_expr_t *expr)
{
    struct ds_engine *de = (ctx && ctx->engine)
        ? (struct ds_engine *)ctx->engine->ds_engine_back : NULL;
    ds_rete_held_t h = {
        .held    = true,
        .cause   = DS_FAULT_TYPE_MISMATCH,
        .tainted = expr ? expr->json_tainted : false,
        .expr    = expr,
        .origin  = origin_at(ctx, expr, de),
    };
    return h;
}

void ds_rete_held_select(ds_rete_held_t *into, const ds_rete_held_t *other)
{
    if (!other->held) return;
    if (!into->held
        || fault_before(other->cause, other->tainted, &other->origin,
                        into->cause, into->tainted, &into->origin))
        *into = *other;
}

/* An Int beside a Float promotes. False unless both operands are numeric. */
static bool numeric_pair(const ds_rete_val_t *a, const ds_rete_val_t *b,
                          int64_t *ai, int64_t *bi,
                          double  *af, double  *bf,
                          bool    *is_float)
{
    if (a->kind == DS_RETE_VAL_INT && b->kind == DS_RETE_VAL_INT) {
        *ai = a->i; *bi = b->i; *is_float = false; return true;
    }
    if (a->kind == DS_RETE_VAL_FLOAT && b->kind == DS_RETE_VAL_FLOAT) {
        *af = a->f; *bf = b->f; *is_float = true; return true;
    }
    if (a->kind == DS_RETE_VAL_INT && b->kind == DS_RETE_VAL_FLOAT) {
        *af = (double)a->i; *bf = b->f; *is_float = true; return true;
    }
    if (a->kind == DS_RETE_VAL_FLOAT && b->kind == DS_RETE_VAL_INT) {
        *af = a->f; *bf = (double)b->i; *is_float = true; return true;
    }
    return false;
}

/* ---- Float `//` and `%` ([LEXP.7.5], [LEXP.7.6]) -------------------- */

static uint64_t f64_bits(double d)  { uint64_t u; memcpy(&u, &d, 8); return u; }
static double   f64_from(uint64_t u) { double d; memcpy(&d, &u, 8); return d; }

#define F64_SIGN 0x8000000000000000ull
#define F64_FRAC 0x000FFFFFFFFFFFFFull
#define F64_NAN  0x7FF8000000000000ull

/* copysign(0.0, x), bitwise, so no libm. */
static double signed_zero(double x) { return f64_from(f64_bits(x) & F64_SIGN); }

/* C's fmod without libm ([IARC.7.12]). `a - n*b` for n = trunc(a/b) is always
   representable, so it is found by shift-and-subtract over the two integer
   mantissas. */
static double exact_fmod(double a, double b)
{
    const uint64_t ua = f64_bits(a), ub = f64_bits(b);
    const uint64_t sign = ua & F64_SIGN;
    int ea = (int)((ua >> 52) & 0x7FF), eb = (int)((ub >> 52) & 0x7FF);
    uint64_t ma = ua & F64_FRAC, mb = ub & F64_FRAC;

    if (ea == 0x7FF || (eb == 0x7FF && mb != 0) || (ub << 1) == 0)
        return f64_from(F64_NAN);
    if (eb == 0x7FF) return a;                 /* finite / ±inf */
    if ((ua << 1) == 0) return a;              /* ±0, its sign kept */

    /* |x| = m * 2^(e - 1075), with the implicit bit for a normal number and
       e = 1 for a subnormal one. */
    if (ea == 0) ea = 1; else ma |= 1ull << 52;
    if (eb == 0) eb = 1; else mb |= 1ull << 52;
    if (ea < eb || (ea == eb && ma < mb)) return a;   /* |a| < |b| */

    for (; ea > eb; ea--) {
        if (ma >= mb) ma -= mb;
        ma <<= 1;                              /* ma < 2 * mb < 2^54 */
    }
    if (ma >= mb) ma -= mb;
    if (ma == 0) return f64_from(sign);        /* ±0, the dividend's sign */

    while (ma < (1ull << 52) && ea > 1) { ma <<= 1; ea--; }
    const uint64_t r = (ma < (1ull << 52))
        ? ma                                   /* subnormal: field 0 */
        : ((uint64_t)ea << 52) | (ma & F64_FRAC);
    return f64_from(r | sign);
}

/* [LEXP.7.5], [LEXP.7.6]: CPython 3.12's `_float_div_mod`, in its own order. Every
   operation is exact ([LDET.3.3a.4]). */
static void float_divmod(double a, double b, double *mod_out, double *div_out)
{
    double mod = exact_fmod(a, b);
    double div = (a - mod) / b;
    if (mod != 0.0) {
        if ((b < 0.0) != (mod < 0.0)) { mod += b; div -= 1.0; }
    } else {
        mod = signed_zero(b);
    }
    double floordiv;
    if (div != 0.0) {
        floordiv = floor(div);
        if (div - floordiv > 0.5) floordiv += 1.0;
    } else {
        floordiv = signed_zero(a / b);
    }
    *mod_out = mod;
    *div_out = floordiv;
}

/* val_cmp's answers beside -1/0/1. */
#define CMP_INCOMPAT  INT_MIN
#define CMP_UNORDERED (INT_MIN + 1)

/* IEEE 754's four-way comparison ([LDET.3.6.2]): a NaN is unordered with
   everything. `x != x` is the NaN test, with no libm symbol. */
static int dbl_cmp(double a, double b)
{
    if (a != a || b != b) return CMP_UNORDERED;
    return (a > b) - (a < b);
}

static int val_cmp(const ds_rete_val_t *a, const ds_rete_val_t *b)
{
    /* Time compares on utc_ns ([LTIM.5.2]), numerically against Int and Float:
       the compiler gates true cross-type errors ([LTIM.5.5]). */
    if (a->kind == DS_RETE_VAL_TIME || b->kind == DS_RETE_VAL_TIME) {
        bool a_int = (a->kind == DS_RETE_VAL_TIME || a->kind == DS_RETE_VAL_INT);
        bool b_int = (b->kind == DS_RETE_VAL_TIME || b->kind == DS_RETE_VAL_INT);
        if (a_int && b_int) {
            int64_t ia = (a->kind == DS_RETE_VAL_TIME) ? a->time.utc_ns : a->i;
            int64_t ib = (b->kind == DS_RETE_VAL_TIME) ? b->time.utc_ns : b->i;
            return (ia > ib) - (ia < ib);
        }
        bool a_num = a_int || a->kind == DS_RETE_VAL_FLOAT;
        bool b_num = b_int || b->kind == DS_RETE_VAL_FLOAT;
        if (a_num && b_num) {
            double da = (a->kind == DS_RETE_VAL_TIME) ? (double)a->time.utc_ns
                      : (a->kind == DS_RETE_VAL_INT)  ? (double)a->i : a->f;
            double db = (b->kind == DS_RETE_VAL_TIME) ? (double)b->time.utc_ns
                      : (b->kind == DS_RETE_VAL_INT)  ? (double)b->i : b->f;
            return dbl_cmp(da, db);
        }
        return CMP_INCOMPAT;
    }
    if (a->kind != b->kind) {
        if ((a->kind == DS_RETE_VAL_INT || a->kind == DS_RETE_VAL_FLOAT) &&
            (b->kind == DS_RETE_VAL_INT || b->kind == DS_RETE_VAL_FLOAT)) {
            double da = (a->kind == DS_RETE_VAL_INT) ? (double)a->i : a->f;
            double db = (b->kind == DS_RETE_VAL_INT) ? (double)b->i : b->f;
            return dbl_cmp(da, db);
        }
        return CMP_INCOMPAT;
    }
    switch (a->kind) {
    case DS_RETE_VAL_INT:
        return (a->i > b->i) - (a->i < b->i);
    case DS_RETE_VAL_FLOAT:
        return dbl_cmp(a->f, b->f);
    case DS_RETE_VAL_STR: {
        /* By content: a computed string is not interned. */
        if (a->s.ptr == b->s.ptr) return 0;
        uint32_t la = a->s.len, lb = b->s.len;
        uint32_t m  = la < lb ? la : lb;
        int c = m ? memcmp(a->s.ptr, b->s.ptr, m) : 0;
        if (c != 0) return c < 0 ? -1 : 1;
        return (la > lb) - (la < lb);
    }
    case DS_RETE_VAL_BOOL:
        return (int)a->b - (int)b->b;
    default:
        break;
    }
    return CMP_INCOMPAT;
}

/* LEXP.7.19, LEXP.7.20: `Bytes`, a whole `Json` value and a fact reference admit
   `==` / `!=` and no ordering. 1 equal, 0 not, -1 when the pair is not two of one
   of them: val_cmp's to judge.

   Bytes by content: a value may hold a NUL ([LFAC.2.5.4]). Json by
   ds_json_deep_equal, as [LFAC.2.5.1]'s de-duplication, so a comparison and a
   no-op reassertion cannot disagree. Fact references by rete id, which a no-op
   reassertion keeps, a meaningful change replaces, and nothing reuses. */
static int val_eq_unordered(const ds_rete_val_t *a, const ds_rete_val_t *b)
{
    const bool a_json = a->kind == DS_RETE_VAL_JSON
                     || a->kind == DS_RETE_VAL_JSON_BORROW;
    const bool b_json = b->kind == DS_RETE_VAL_JSON
                     || b->kind == DS_RETE_VAL_JSON_BORROW;
    if (a_json && b_json)
        return ds_json_deep_equal(a->json, b->json) ? 1 : 0;
    if (a->kind == DS_RETE_VAL_BYTES && b->kind == DS_RETE_VAL_BYTES) {
        if (a->s.len != b->s.len) return 0;
        if (a->s.len == 0 || a->s.ptr == b->s.ptr) return 1;
        if (a->s.ptr == NULL || b->s.ptr == NULL) return 0;
        return memcmp(a->s.ptr, b->s.ptr, a->s.len) == 0 ? 1 : 0;
    }
    if (a->kind == DS_RETE_VAL_FACT_REF && b->kind == DS_RETE_VAL_FACT_REF)
        return a->fact_ref_id == b->fact_ref_id ? 1 : 0;
    return -1;
}

#define STR_CAT_LIMIT 4096   /* the engine's str_cat_scratch */

/* CALL and INTERP need sizeable buffers, so they stay in noinline helpers: in
 * ds_rete_eval's frame, every recursion level would reserve them, overflowing a
 * small embedded stack. */

/* ---- FN_INTERVAL_CHECK ------------------------------------------------- *
 *
 * [RLOW.6.1.7]: `(s1, e1, v)` or `(s1, e1, s2, e2, v)`, evaluated as [LINT.7.2]
 * evaluates `..`. Every argument is evaluated with faults held ([LNUL.4.10]), and
 * each pair whose non-null endpoints are not `s <= e` adds a DOMAIN naming the
 * pair's start ([LERR.9.12]). The call yields the one fault [LNUL.4.2]'s order
 * selects, or `v`. Not behind `eval_call`'s generic path, which would raise an
 * argument's fault before these are added, and answer a `null` `v` before the
 * pairs were checked.
 *
 * `<=` is `val_cmp`'s. Endpoints of two kinds cannot come from a conforming
 * compiler ([LINT.2.2]): ARTEFACT.
 *
 * Reached only for three or five operands. */
static __attribute__((noinline)) ds_rete_val_t
eval_interval_check(ds_rete_eval_ctx_t *ctx, const ds_rete_expr_t *expr)
{
    const uint32_t argc  = expr->call.arg_count;
    const uint32_t pairs = (argc - 1) / 2;
    ds_rete_val_t  argv[5];
    ds_rete_held_t held[5];
    ds_rete_held_t sel = { .held = false };
    struct ds_engine *de = ctx->engine
        ? (struct ds_engine *)ctx->engine->ds_engine_back : NULL;

    for (uint32_t i = 0; i < argc; i++) {
        argv[i] = ds_rete_eval_holding(ctx, expr->call.args[i], &held[i]);
        if (ctx->faulted) return argv[i];
        ds_rete_held_select(&sel, &held[i]);
    }
    for (uint32_t p = 0; p < pairs; p++) {
        const uint32_t s = 2 * p, e = 2 * p + 1;
        if (held[s].held || held[e].held) continue;
        if (argv[s].kind == DS_RETE_VAL_NULL || argv[e].kind == DS_RETE_VAL_NULL)
            continue;   /* a `null` endpoint is valid ([LINT.7.2]) */
        const int cmp = val_cmp(&argv[s], &argv[e]);
        if (cmp != CMP_INCOMPAT && cmp != CMP_UNORDERED && cmp <= 0)
            continue;
        const ds_rete_held_t invalid = {
            .held    = true,
            .cause   = cmp == CMP_INCOMPAT ? DS_FAULT_ARTEFACT : DS_FAULT_DOMAIN,
            .tainted = expr->json_tainted,
            .expr    = expr,
            .origin  = operand_origin(ctx, expr->call.args[s], de),
        };
        ds_rete_held_select(&sel, &invalid);
    }
    if (sel.held) return ds_rete_raise_held(ctx, &sel);
    return argv[argc - 1];
}

static __attribute__((noinline)) ds_rete_val_t
eval_call(ds_rete_eval_ctx_t *ctx, const ds_rete_expr_t *expr)
{
    const ds_fn_slot_t *slot = ds_lookup_fn(expr->call.op);
    /* The loader refuses an unregistered op; a hand-built network may not. */
    if (!slot) return ds_rete_fault(ctx, expr, DS_FAULT_ARTEFACT);
    if (ctx->engine->rt_mode && !slot->rt_safe)
        return ds_rete_fault(ctx, expr, DS_FAULT_ARTEFACT);
    if (expr->call.op == (uint32_t)DS_FN_INTERVAL_CHECK
        && ds_fn_operands_admitted(expr->call.op, expr->call.arg_count))
        return eval_interval_check(ctx, expr);

    uint32_t argc = expr->call.arg_count;
    ds_rete_val_t argv_buf[32];
    ds_rete_val_t *argv = argv_buf;
    if (argc > 32) {
        argv = DS_MALLOC(argc * sizeof(*argv));
        if (!argv) return ds_rete_fault(ctx, expr, DS_FAULT_RESOURCE);
    }
    /* [LNUL.4.10]: every argument is evaluated with faults held, and the call
       yields the one [LNUL.4.2]'s order selects ([LERR.1.4.11]). */
    ds_rete_held_t sel = { .held = false };
    for (uint32_t i = 0; i < argc; i++) {
        ds_rete_held_t h;
        argv[i] = ds_rete_eval_holding(ctx, expr->call.args[i], &h);
        if (ctx->faulted) {
            ds_rete_val_t v = argv[i];
            if (argv != argv_buf) DS_FREE(argv);
            return v;
        }
        ds_rete_held_select(&sel, &h);
    }
    if (sel.held) {
        if (argv != argv_buf) DS_FREE(argv);
        return ds_rete_raise_held(ctx, &sel);
    }
    /* [LCST.4.3.4]: a null source converts to null. The conversions `::` compiles
       to their own ops; the temporal casts ([LCST.4.5.9]) share their ops with
       the member forms, whose adapters answer null themselves. */
    if (argc == 1 && argv[0].kind == DS_RETE_VAL_NULL) {
        switch (expr->call.op) {
        case DS_FN_FLOAT_TO_INT:
        case DS_FN_FLOAT_TO_STRING:
        case DS_FN_INT_TO_STRING:
        case DS_FN_BOOL_TO_STRING:
        case DS_FN_STRING_TO_FLOAT:
        case DS_FN_STRING_TO_INT:
        case DS_FN_STRING_TO_BOOL:
        case DS_FN_INT_TO_FLOAT:
            if (argv != argv_buf) DS_FREE(argv);
            return ds_rete_val_null();
        default:
            break;
        }
    }
    ds_rete_val_t result = ds_rete_val_null();
    /* A builtin receives no expr, so it reads its taint and site from the ctx.
       Restored after: leaving them set would mis-attribute a clean sibling's
       fault. */
    const bool saved_tainted = ctx->json_tainted;
    const ds_rete_expr_t *saved_site = ctx->call_site;
    ctx->json_tainted = expr->json_tainted;
    ctx->call_site = expr;
    /* [RDSC.4a.9.3]: the one count, for every op, from [RDSC.4a.9.5]'s generated
       table. After the operands are evaluated, so an operand's fault comes first.
       A `none` row has no handler, so the loader refuses every call of one. */
    if (ds_fn_operands[expr->call.op].shape != DS_FN_SHAPE_NONE
        && !ds_fn_operands_admitted(expr->call.op, argc))
        result = ds_rete_fault(ctx, NULL, DS_FAULT_ARTEFACT);
    else
        slot->fn(ctx->engine, ctx, argv, argc, &result);
    ctx->json_tainted = saved_tainted;
    ctx->call_site = saved_site;
    if (argv != argv_buf) DS_FREE(argv);
    return result;
}

/* ---- INTERP (RLOW.6.4, [LGRA.2.9.6.10]) ----------------------------- *
 *
 * No printf ([IARC.1.16]), and no length limit: the engine's scratch buffer is
 * the fast path, and a result that outgrows it moves to a heap buffer. */

typedef struct {
    char  *buf;
    size_t cap;
    size_t len;
    char  *heap;      /* non-NULL once buf has moved to the heap */
    bool   oom;
} grow_t;

static void gw_put(grow_t *g, const char *s, size_t n)
{
    if (g->oom) return;
    if (g->len + n + 1u > g->cap) {
        size_t ncap = g->cap * 2u;
        if (ncap < g->len + n + 1u) ncap = g->len + n + 1u;
        char *nb = g->heap ? DS_REALLOC(g->heap, ncap) : DS_MALLOC(ncap);
        if (nb == NULL) { g->oom = true; return; }
        if (g->heap == NULL) memcpy(nb, g->buf, g->len);
        g->heap = nb; g->buf = nb; g->cap = ncap;
    }
    memcpy(g->buf + g->len, s, n);
    g->len += n;
}

static void gw_char(grow_t *g, char c) { gw_put(g, &c, 1); }

static void gw_repeat(grow_t *g, char c, size_t n)
{
    for (size_t i = 0; i < n; i++) gw_char(g, c);
}

/* Code points in UTF-8 text: every byte that is not a continuation byte. */
static size_t code_points(const char *s, size_t n)
{
    size_t k = 0;
    for (size_t i = 0; i < n; i++)
        if (((unsigned char)s[i] & 0xC0u) != 0x80u) k++;
    return k;
}

/* The byte length of the first `cp` code points of `s`. */
static size_t prefix_bytes(const char *s, size_t n, size_t cp)
{
    size_t i = 0, seen = 0;
    while (i < n) {
        if (((unsigned char)s[i] & 0xC0u) != 0x80u) {
            if (seen == cp) break;
            seen++;
        }
        i++;
    }
    return i;
}

static void magnitude_in_base(ds_text_t *t, uint64_t m, unsigned base, bool upper)
{
    static const char lo[] = "0123456789abcdef", up[] = "0123456789ABCDEF";
    const char *digits = upper ? up : lo;
    char d[64];
    int n = 0;
    do { d[n++] = digits[m % base]; m /= base; } while (m);
    while (n > 0) ds_text_char(t, d[--n]);
}

/* One ValuePrim. Writes nothing for null ([LGRA.2.9.6.10] "Null"); returns
   false, with the raised fault in *raised, when the value's kind does not take
   the spec. */
#define KIND_MISMATCH() do { *raised = type_error_at(ctx, expr); return false; } while (0)

static bool render_value(ds_rete_eval_ctx_t *ctx, const ds_rete_expr_t *expr,
                         const ds_rete_fprim_t *p, ds_rete_val_t v, grow_t *g,
                         ds_rete_val_t *raised)
{
    if (v.kind == DS_RETE_VAL_NULL) return true;
    /* A Time renders as its instant, as an Int. A timestamp spec is a TimePrim. */
    if (v.kind == DS_RETE_VAL_TIME) v = ds_rete_val_int(v.time.utc_ns);

    bool is_number = v.kind == DS_RETE_VAL_INT || v.kind == DS_RETE_VAL_FLOAT;

    /* [LGRA.2.9.6.5]'s per-kind refusals at run time (LGRA.2.9.6.11): the compiler
       refuses them wherever it knows the kind, so this is a `Json` leaf. */
    if ((v.kind == DS_RETE_VAL_STR || v.kind == DS_RETE_VAL_BOOL)
            && (p->plus || p->zero))
        KIND_MISMATCH();              /* a sign or `0` on a String or a Bool */
    if (p->has_precision && v.kind != DS_RETE_VAL_STR
            && (p->type == DS_RETE_FTYPE_CANONICAL || p->type == DS_RETE_FTYPE_D
                || p->type == DS_RETE_FTYPE_X_LOWER
                || p->type == DS_RETE_FTYPE_X_UPPER
                || p->type == DS_RETE_FTYPE_B))
        KIND_MISMATCH();              /* decimal places are `f`'s alone */
    /* The longest text is min_int64's magnitude in binary: 64 digits and a NUL. */
    char num[72];
    ds_text_t t = ds_text(num, sizeof num);
    const char *body = NULL;    /* the text, sign excluded */
    size_t body_len = 0;
    bool negative = false;
    char *fixed = NULL;

    switch (p->type) {
    case DS_RETE_FTYPE_CANONICAL:
        if (v.kind == DS_RETE_VAL_INT) {
            negative = v.i < 0;
            ds_text_u64(&t, negative ? (uint64_t)(-(v.i + 1)) + 1u : (uint64_t)v.i);
        } else if (v.kind == DS_RETE_VAL_FLOAT) {
            /* Every NaN is `nan` ([LCST.4.5.6]); x86's default NaN has the sign
               bit. */
            negative = signbit(v.f) != 0 && !isnan(v.f);
            ds_text_float(&t, negative ? -v.f : v.f);
        } else if (v.kind == DS_RETE_VAL_BOOL) {
            ds_text_str(&t, v.b ? "true" : "false");
        } else if (v.kind == DS_RETE_VAL_STR) {
            body = v.s.ptr; body_len = v.s.len;
            if (p->has_precision)
                body_len = prefix_bytes(body, body_len, p->precision);
        } else {
            KIND_MISMATCH();
        }
        break;
    case DS_RETE_FTYPE_D:
    case DS_RETE_FTYPE_X_LOWER:
    case DS_RETE_FTYPE_X_UPPER:
    case DS_RETE_FTYPE_B: {
        if (v.kind != DS_RETE_VAL_INT) KIND_MISMATCH();
        negative = v.i < 0;
        uint64_t m = negative ? (uint64_t)(-(v.i + 1)) + 1u : (uint64_t)v.i;
        if (p->type == DS_RETE_FTYPE_D) ds_text_u64(&t, m);
        else if (p->type == DS_RETE_FTYPE_B) magnitude_in_base(&t, m, 2, false);
        else magnitude_in_base(&t, m, 16, p->type == DS_RETE_FTYPE_X_UPPER);
        break;
    }
    case DS_RETE_FTYPE_F: {
        double f;
        if (v.kind == DS_RETE_VAL_FLOAT) f = v.f;
        else if (v.kind == DS_RETE_VAL_INT) f = (double)v.i;
        else KIND_MISMATCH();
        negative = signbit(f) != 0 && !isnan(f);
        unsigned prec = p->has_precision ? p->precision : 6u;
        /* A whole double can need ~310 digits before the point. */
        int need = ds_fmt_float_fixed(NULL, 0, negative ? -f : f, prec);
        fixed = DS_MALLOC((size_t)need + 1u);
        if (fixed == NULL) { g->oom = true; return true; }
        ds_fmt_float_fixed(fixed, (size_t)need + 1u, negative ? -f : f, prec);
        body = fixed; body_len = (size_t)need;
        break;
    }
    case DS_RETE_FTYPE_S:
        if (v.kind != DS_RETE_VAL_STR) KIND_MISMATCH();
        body = v.s.ptr; body_len = v.s.len;
        if (p->has_precision) body_len = prefix_bytes(body, body_len, p->precision);
        break;
    }
    if (body == NULL) { body = num; body_len = (size_t)ds_text_len(&t); }

    const char *sign = negative ? "-" : (p->plus && is_number ? "+" : "");
    size_t sign_len = strlen(sign);
    size_t used = sign_len + code_points(body, body_len);
    size_t pad  = p->width > used ? p->width - used : 0;
    bool left = p->align == DS_RETE_FALIGN_LEFT
             || (p->align == DS_RETE_FALIGN_DEFAULT && !is_number);

    if (p->zero && is_number && !left) {
        gw_put(g, sign, sign_len);
        gw_repeat(g, '0', pad);
        gw_put(g, body, body_len);
    } else if (left) {
        gw_put(g, sign, sign_len);
        gw_put(g, body, body_len);
        gw_repeat(g, ' ', pad);
    } else {
        gw_repeat(g, ' ', pad);
        gw_put(g, sign, sign_len);
        gw_put(g, body, body_len);
    }
    DS_FREE(fixed);
    return true;
}

/* One TimePrim ([LGRA.2.9.6.4]): every field in the value's own UTC offset. */
static bool render_time(ds_rete_eval_ctx_t *ctx, const ds_rete_expr_t *expr,
                        const ds_rete_fprim_t *p, ds_rete_val_t v, grow_t *g,
                        ds_rete_val_t *raised)
{
    if (v.kind == DS_RETE_VAL_NULL) return true;
    int64_t utc_ns; int32_t off = 0;
    if (v.kind == DS_RETE_VAL_TIME) { utc_ns = v.time.utc_ns; off = v.time.tz_offset_s; }
    else if (v.kind == DS_RETE_VAL_INT) utc_ns = v.i;
    else KIND_MISMATCH();

    int64_t days, ns_of_day;
    ds_rete_local_split(utc_ns, off, &days, &ns_of_day);
    int64_t frac  = ns_of_day % 1000000000LL;
    int64_t sod   = ns_of_day / 1000000000LL;
    int64_t y; unsigned mo, d;
    ds_rete_civil_from_days(days, &y, &mo, &d);

    for (uint32_t k = 0; k < p->item_count; k++) {
        const ds_rete_titem_t *it = &p->items[k];
        if (it->text != NULL) { gw_put(g, it->text, it->text_len); continue; }
        char b[32];
        ds_text_t t = ds_text(b, sizeof b);
        switch (it->field) {
        case DS_RETE_TFIELD_YEAR:        ds_text_i64_zpad(&t, y, 4); break;
        case DS_RETE_TFIELD_MONTH:       ds_text_i64_zpad(&t, mo, 2); break;
        case DS_RETE_TFIELD_DAY:         ds_text_i64_zpad(&t, d, 2); break;
        case DS_RETE_TFIELD_HOUR:        ds_text_i64_zpad(&t, sod / 3600, 2); break;
        case DS_RETE_TFIELD_MINUTE:      ds_text_i64_zpad(&t, (sod % 3600) / 60, 2); break;
        case DS_RETE_TFIELD_SECOND:      ds_text_i64_zpad(&t, sod % 60, 2); break;
        /* the nanoseconds below the microsecond are truncated, never rounded */
        case DS_RETE_TFIELD_MICROSECOND: ds_text_i64_zpad(&t, frac / 1000, 6); break;
        case DS_RETE_TFIELD_UTC_OFFSET: {
            int32_t a = off < 0 ? -off : off;
            ds_text_char(&t, off < 0 ? '-' : '+');
            ds_text_i64_zpad(&t, a / 3600, 2);
            ds_text_i64_zpad(&t, (a % 3600) / 60, 2);
            if (a % 60 != 0) ds_text_i64_zpad(&t, a % 60, 2);
            break;
        }
        }
        gw_put(g, b, (size_t)ds_text_len(&t));
    }
    return true;
}

#undef KIND_MISMATCH

static __attribute__((noinline)) ds_rete_val_t
eval_interp(ds_rete_eval_ctx_t *ctx, const ds_rete_expr_t *expr)
{
    grow_t g = { ctx->engine->str_cat_scratch, ctx->engine->str_cat_scratch_cap,
                 0, NULL, false };
    if (g.buf == NULL || g.cap < STR_CAT_LIMIT)
        return ds_rete_fault(ctx, expr, DS_FAULT_RESOURCE);

    /* [LNUL.4.10]: every value is evaluated first with faults held, and the one
       [LNUL.4.2]'s order selects is raised before anything is rendered
       ([LERR.1.4.11]). */
    const uint32_t n = expr->interp.prim_count;
    ds_rete_val_t vals_buf[16];
    ds_rete_val_t *vals = vals_buf;
    if (n > 16) {
        vals = DS_MALLOC(n * sizeof(*vals));
        if (!vals) return ds_rete_fault(ctx, expr, DS_FAULT_RESOURCE);
    }
    ds_rete_held_t sel = { .held = false };
    bool composite = false;
    for (uint32_t i = 0; i < n; i++) {
        const ds_rete_fprim_t *p = &expr->interp.prims[i];
        if (p->kind == DS_RETE_FPRIM_TEXT) continue;
        ds_rete_held_t h;
        ctx->json_composite = false;
        vals[i] = ds_rete_eval_holding(ctx, p->value, &h);
        if (ctx->faulted) {
            ds_rete_val_t v = vals[i];
            if (vals != vals_buf) DS_FREE(vals);
            return v;
        }
        ds_rete_held_select(&sel, &h);
        /* LGRA.2.9.6.11: only a leaf renders. Only a path at the top of the value
           is read: the compiler lowers each segment through its path lowering
           alone. */
        if (p->value != NULL && ctx->json_composite
                && (p->value->kind == DS_RETE_EXPR_JSON_PATH
                    || (p->value->kind == DS_RETE_EXPR_CALL
                        && p->value->call.op == DS_FN_JSON_PATH)))
            composite = true;
    }
    if (sel.held) {
        if (vals != vals_buf) DS_FREE(vals);
        return ds_rete_raise_held(ctx, &sel);
    }
    if (composite) {
        if (vals != vals_buf) DS_FREE(vals);
        return type_error_at(ctx, expr);
    }

    for (uint32_t i = 0; i < n && !g.oom; i++) {
        const ds_rete_fprim_t *p = &expr->interp.prims[i];
        if (p->kind == DS_RETE_FPRIM_TEXT) {
            gw_put(&g, p->text, p->text_len);
            continue;
        }
        ds_rete_val_t v = vals[i];
        ds_rete_val_t raised = ds_rete_val_null();
        bool ok = p->kind == DS_RETE_FPRIM_VALUE
                ? render_value(ctx, expr, p, v, &g, &raised)
                : render_time(ctx, expr, p, v, &g, &raised);
        if (!ok) {
            if (vals != vals_buf) DS_FREE(vals);
            DS_FREE(g.heap);
            return raised;
        }
    }
    if (vals != vals_buf) DS_FREE(vals);
    if (g.oom) { DS_FREE(g.heap); return ds_rete_fault(ctx, expr, DS_FAULT_RESOURCE); }

    /* Transient: arena, not interned, until an emit commits it. */
    const char *s = ds_rete_arena_dup(&ctx->engine->comp_arena, g.buf, g.len);
    DS_FREE(g.heap);
    if (s == NULL) return ds_rete_fault(ctx, expr, DS_FAULT_RESOURCE);
    return ds_rete_val_str(s, (uint32_t)g.len);
}

int64_t ds_rete_eval_now_ns(const ds_rete_eval_ctx_t *ctx)
{
    if (ctx->fire_now_valid)
        return ctx->fire_now_ns;
    if (ctx->engine->rt_mode && ctx->engine->cached_clock_valid)
        return ctx->engine->cached_clock_ns;
    return ctx->engine->clock_fn(ctx->engine->clock_ctx);
}

/* No snapshot: under a DS engine the held sample is one value per step
   ([LTIM.2.8.4]). */
bool ds_rete_eval_wall_ns(const ds_rete_eval_ctx_t *ctx, int64_t *out_utc_ns)
{
    return ctx->engine->wall_fn(ctx->engine->clock_ctx, out_utc_ns);
}

/* ---- Main evaluator ----------------------------------------------- */

ds_rete_val_t ds_rete_eval(ds_rete_eval_ctx_t *ctx,
                             const ds_rete_expr_t *expr)
{
    if (!expr) return ds_rete_fault(ctx, NULL, DS_FAULT_ARTEFACT);

    switch (expr->kind) {

    case DS_RETE_EXPR_LIT_INT:
        return ds_rete_val_int(expr->lit_int);
    case DS_RETE_EXPR_LIT_FLOAT:
        return ds_rete_val_float(expr->lit_float);
    case DS_RETE_EXPR_LIT_BOOL:
        return ds_rete_val_bool(expr->lit_bool);
    case DS_RETE_EXPR_LIT_STR:
        return ds_rete_val_str(expr->lit_str,
                               (uint32_t)strlen(expr->lit_str));
    case DS_RETE_EXPR_LIT_NULL:
        return ds_rete_val_null();

    case DS_RETE_EXPR_IS_TEST: {
        /* [LNUL.4.9]: total; this arm has no error path of its own. A constant
           subject tests tag and value; a tag name tests the tag alone. */
        ds_rete_val_t v = ds_rete_eval(ctx, expr->is_test.operand);
        if (ctx->faulted) return v;
        bool hit;
        switch (expr->is_test.subject) {
        case DS_RETE_IS_NULL:    hit = (v.kind == DS_RETE_VAL_NULL);  break;
        case DS_RETE_IS_TRUE:    hit = (v.kind == DS_RETE_VAL_BOOL) &&  v.b; break;
        case DS_RETE_IS_FALSE:   hit = (v.kind == DS_RETE_VAL_BOOL) && !v.b; break;
        case DS_RETE_IS_INF:     hit = (v.kind == DS_RETE_VAL_FLOAT) && isinf(v.f) && v.f > 0; break;
        case DS_RETE_IS_NEG_INF: hit = (v.kind == DS_RETE_VAL_FLOAT) && isinf(v.f) && v.f < 0; break;
        case DS_RETE_IS_NAN:     hit = (v.kind == DS_RETE_VAL_FLOAT) && isnan(v.f); break;
        /* A tag names a representation, not a declared type ([LNUL.4.9]): one
           `Time` slot may hold TIME or INT ([LNUL.8.7]). */
        case DS_RETE_IS_INT:     hit = (v.kind == DS_RETE_VAL_INT) ||
                                       (v.kind == DS_RETE_VAL_TIME); break;
        case DS_RETE_IS_FLOAT:   hit = (v.kind == DS_RETE_VAL_FLOAT); break;
        case DS_RETE_IS_BOOL:    hit = (v.kind == DS_RETE_VAL_BOOL);  break;
        case DS_RETE_IS_STRING:  hit = (v.kind == DS_RETE_VAL_STR);   break;
        case DS_RETE_IS_BYTES:   hit = (v.kind == DS_RETE_VAL_BYTES); break;
        case DS_RETE_IS_JSON:    hit = (v.kind == DS_RETE_VAL_JSON) ||
                                       (v.kind == DS_RETE_VAL_JSON_BORROW); break;
        /* The loader range-checks the subject. */
        case DS_RETE_IS_UNSPECIFIED:
        default:                 hit = false; break;
        }
        return ds_rete_val_bool(expr->is_test.negated ? !hit : hit);
    }

    case DS_RETE_EXPR_COALESCE: {
        /* [LNUL.8.9]. The latch before the kind: a faulted evaluation returns
           `null`, and `??` rescues absence, not a fault. */
        ds_rete_val_t lv = ds_rete_eval(ctx, expr->coalesce.left);
        if (ctx->faulted) return lv;
        if (lv.kind == DS_RETE_VAL_NULL)
            return ds_rete_eval(ctx, expr->coalesce.right);
        return lv;
    }

    case DS_RETE_EXPR_ENTRY_STAMP: {
        /* [LTIM.2.8.6]: a retract-and-replace mints a new fact and so a new
           stamp; a suppressed no-op reassertion keeps the old one. */
        uint8_t pi = expr->entry_stamp.pattern_index;
        const ds_rete_fact_t *f;
        if (pi == DS_RETE_VAR_RIGHT_FACT) {
            if (!ctx->right_fact) return ds_rete_fault(ctx, expr, DS_FAULT_ARTEFACT);
            f = ctx->right_fact;
        } else {
            if (!ctx->token || pi >= ctx->token->fact_count)
                return ds_rete_fault(ctx, expr, DS_FAULT_PATTERN_INDEX);
            f = ctx->token->facts[pi];
        }
        if (!f) return ds_rete_fault(ctx, expr, DS_FAULT_ARTEFACT);
        return ds_rete_val_int((int64_t) f->assert_ns);
    }

    case DS_RETE_EXPR_VAR: {
        uint8_t pi = expr->var.pattern_index;
        uint8_t si = expr->var.slot_index;
        const ds_rete_fact_t *f;
        if (pi == DS_RETE_VAR_RIGHT_FACT) {
            if (!ctx->right_fact) return ds_rete_fault(ctx, expr, DS_FAULT_ARTEFACT);
            f = ctx->right_fact;
        } else {
            if (!ctx->token || pi >= ctx->token->fact_count)
                return ds_rete_fault(ctx, expr, DS_FAULT_PATTERN_INDEX);
            f = ctx->token->facts[pi];
        }
        /* The fact itself ([RDSC.4a.9.1]), by id: a capture outlives the firing,
           and its parent may leave WM first. */
        if (si == DS_RETE_VAR_WHOLE_FACT) {
            ds_rete_val_t r;
            r.kind = DS_RETE_VAL_FACT_REF;
            r.fact_ref_id = f->id;
            return r;
        }
        if (si >= f->schema->slot_count) return ds_rete_fault(ctx, expr, DS_FAULT_ARTEFACT);
        return slot_read(f, si);
    }

    case DS_RETE_EXPR_BINOP: {
        ds_rete_binop_t op = expr->binop.op;

        /* Kleene and absorbing ([LNUL.4.2], [IRET.9.5]): the deciding value
           decides wherever it stands, the selected fault only if none decides
           ([LERR.1.4.11]), and `null` only if none faults. A deciding left
           operand may stop early. */
        if (op == DS_RETE_BINOP_AND || op == DS_RETE_BINOP_OR) {
            const bool decider = (op == DS_RETE_BINOP_OR);
            ds_rete_held_t lh, rh;
            ds_rete_val_t lv = ds_rete_eval_holding(ctx, expr->binop.left, &lh);
            if (ctx->faulted) return lv;
            if (!lh.held) {
                if (lv.kind == DS_RETE_VAL_BOOL && lv.b == decider)
                    return ds_rete_val_bool(decider);
                if (lv.kind != DS_RETE_VAL_BOOL && lv.kind != DS_RETE_VAL_NULL)
                    lh = ds_rete_held_mismatch(ctx, expr);
            }
            ds_rete_val_t rv = ds_rete_eval_holding(ctx, expr->binop.right, &rh);
            if (ctx->faulted) return rv;
            if (!rh.held) {
                if (rv.kind == DS_RETE_VAL_BOOL && rv.b == decider)
                    return ds_rete_val_bool(decider);
                if (rv.kind != DS_RETE_VAL_BOOL && rv.kind != DS_RETE_VAL_NULL)
                    rh = ds_rete_held_mismatch(ctx, expr);
            }
            ds_rete_held_select(&lh, &rh);
            if (lh.held) return ds_rete_raise_held(ctx, &lh);
            if (lv.kind == DS_RETE_VAL_NULL || rv.kind == DS_RETE_VAL_NULL)
                return ds_rete_val_null();
            return ds_rete_val_bool(!decider);
        }

        /* [LNUL.4.10]: both operands with faults held; the one [LNUL.4.2]'s order
           selects is raised ([LERR.1.4.11]). A `null` beside a fault does not
           absorb it. */
        ds_rete_held_t lh, rh;
        ds_rete_val_t lv = ds_rete_eval_holding(ctx, expr->binop.left, &lh);
        if (ctx->faulted) return lv;
        ds_rete_val_t rv = ds_rete_eval_holding(ctx, expr->binop.right, &rh);
        if (ctx->faulted) return rv;
        ds_rete_held_select(&lh, &rh);
        if (lh.held) return ds_rete_raise_held(ctx, &lh);

        /* [LNUL.4.1]: before every type and zero check, so `null / 0` is null. */
        if (lv.kind == DS_RETE_VAL_NULL || rv.kind == DS_RETE_VAL_NULL)
            return ds_rete_val_null();

        /* [LTIM.4.1]: Time +/- Duration -> Time, Time - Time -> Duration. A
           Duration arrives as INT, and the result keeps the operand's offset
           ([LTIM.1.1.3]). */
        if ((lv.kind == DS_RETE_VAL_TIME || rv.kind == DS_RETE_VAL_TIME) &&
            (op == DS_RETE_BINOP_ADD || op == DS_RETE_BINOP_SUB)) {
            if (op == DS_RETE_BINOP_ADD) {
                if (lv.kind == DS_RETE_VAL_TIME && rv.kind == DS_RETE_VAL_INT)
                    return ds_rete_val_time(ds_i64_add(lv.time.utc_ns, rv.i),
                                            lv.time.tz_offset_s);
                if (lv.kind == DS_RETE_VAL_INT && rv.kind == DS_RETE_VAL_TIME)
                    return ds_rete_val_time(ds_i64_add(lv.i, rv.time.utc_ns),
                                            rv.time.tz_offset_s);
                return type_error_at(ctx, expr);
            }
            if (lv.kind == DS_RETE_VAL_TIME && rv.kind == DS_RETE_VAL_TIME)
                return ds_rete_val_int(ds_i64_sub(lv.time.utc_ns,
                                                  rv.time.utc_ns));
            if (lv.kind == DS_RETE_VAL_TIME && rv.kind == DS_RETE_VAL_INT)
                return ds_rete_val_time(ds_i64_sub(lv.time.utc_ns, rv.i),
                                        lv.time.tz_offset_s);
            return type_error_at(ctx, expr);
        }

        if (op <= DS_RETE_BINOP_DIV) {
            int64_t ai, bi; double af, bf; bool is_float;
            if (!numeric_pair(&lv, &rv, &ai, &bi, &af, &bf, &is_float))
                return type_error_at(ctx, expr);
            if (is_float) {
                double result;
                switch (op) {
                case DS_RETE_BINOP_ADD: result = af + bf; break;
                case DS_RETE_BINOP_SUB: result = af - bf; break;
                case DS_RETE_BINOP_MUL: result = af * bf; break;
                case DS_RETE_BINOP_DIV:
                    /* IEEE 754's ([LEXP.7.15.1], [LDET.3.6.2]): a zero divisor
                       does not trap. */
                    result = af / bf;
                    break;
                default: return type_error_at(ctx, expr);
                }
                return ds_rete_val_float(result);
            } else {
                /* `/` always yields Float (LEXP.7.4, LEXP.12.2). */
                if (op == DS_RETE_BINOP_DIV) {
                    if (bi == 0) return ds_rete_fault(ctx, expr, DS_FAULT_DIVIDE_BY_ZERO); /* LEXP.7.15 */
                    return ds_rete_val_float((double)ai / (double)bi);
                }
                /* Wraps two's-complement (LEXP.7.13.1). */
                int64_t result;
                switch (op) {
                case DS_RETE_BINOP_ADD: result = ds_i64_add(ai, bi); break;
                case DS_RETE_BINOP_SUB: result = ds_i64_sub(ai, bi); break;
                case DS_RETE_BINOP_MUL: result = ds_i64_mul(ai, bi); break;
                default: return type_error_at(ctx, expr);
                }
                return ds_rete_val_int(result);
            }
        }

        /* Floor division (LEXP.7.5), and modulo with the divisor's sign (LEXP.7.6). */
        if (op == DS_RETE_BINOP_IDIV || op == DS_RETE_BINOP_MOD) {
            if (lv.kind == DS_RETE_VAL_INT && rv.kind == DS_RETE_VAL_INT) {
                if (rv.i == 0) return ds_rete_fault(ctx, expr, DS_FAULT_DIVIDE_BY_ZERO); /* LEXP.7.15, LEXP.7.16 */
                return ds_rete_val_int(op == DS_RETE_BINOP_IDIV
                                       ? ds_i64_floordiv(lv.i, rv.i)
                                       : ds_i64_floormod(lv.i, rv.i));
            }
            /* A zero divisor is [LEXP.7.15.1]'s: `//` is IEEE division's, `%` is
               NaN. Through `fmod(a, 0)`, `//` would be NaN too. */
            int64_t ai, bi; double af, bf; bool is_float;
            if (!numeric_pair(&lv, &rv, &ai, &bi, &af, &bf, &is_float))
                return type_error_at(ctx, expr);
            if (bf == 0.0)
                return ds_rete_val_float(op == DS_RETE_BINOP_IDIV
                                         ? af / bf : f64_from(F64_NAN));
            double mod, div;
            float_divmod(af, bf, &mod, &div);
            return ds_rete_val_float(op == DS_RETE_BINOP_IDIV ? div : mod);
        }

        if (op >= DS_RETE_BINOP_EQ && op <= DS_RETE_BINOP_GE) {
            if (op == DS_RETE_BINOP_EQ || op == DS_RETE_BINOP_NE) {
                int eq = val_eq_unordered(&lv, &rv);
                if (eq >= 0)
                    return ds_rete_val_bool(op == DS_RETE_BINOP_EQ ? eq == 1
                                                                   : eq == 0);
            }
            int cmp = val_cmp(&lv, &rv);
            if (cmp == CMP_INCOMPAT) return type_error_at(ctx, expr);
            if (cmp == CMP_UNORDERED)
                return ds_rete_val_bool(op == DS_RETE_BINOP_NE);
            bool result;
            switch (op) {
            case DS_RETE_BINOP_EQ: result = (cmp == 0); break;
            case DS_RETE_BINOP_NE: result = (cmp != 0); break;
            case DS_RETE_BINOP_LT: result = (cmp <  0); break;
            case DS_RETE_BINOP_GT: result = (cmp >  0); break;
            case DS_RETE_BINOP_LE: result = (cmp <= 0); break;
            case DS_RETE_BINOP_GE: result = (cmp >= 0); break;
            default: return type_error_at(ctx, expr);
            }
            return ds_rete_val_bool(result);
        }

        if (op >= DS_RETE_BINOP_BAND) {
            if (lv.kind != DS_RETE_VAL_INT || rv.kind != DS_RETE_VAL_INT)
                return type_error_at(ctx, expr);
            /* [LEXP.7.14.1]. The helpers take count >= 0. */
            if ((op == DS_RETE_BINOP_SHL || op == DS_RETE_BINOP_SHR)
                && rv.i < 0)
                return ds_rete_fault(ctx, expr, DS_FAULT_DOMAIN);
            int64_t result;
            switch (op) {
            case DS_RETE_BINOP_BAND: result = lv.i & rv.i;          break;
            case DS_RETE_BINOP_BOR:  result = lv.i | rv.i;          break;
            case DS_RETE_BINOP_BXOR: result = lv.i ^ rv.i;          break;
            case DS_RETE_BINOP_SHL:  result = ds_i64_shl(lv.i, rv.i); break;
            case DS_RETE_BINOP_SHR:  result = ds_i64_shr(lv.i, rv.i); break;
            default: return type_error_at(ctx, expr);
            }
            return ds_rete_val_int(result);
        }
        return type_error_at(ctx, expr);
    }

    case DS_RETE_EXPR_UNOP: {
        ds_rete_val_t v = ds_rete_eval(ctx, expr->unop.operand);
        if (ctx->faulted) return v;
        /* [LNUL.4.1], [LNUL.4.2] */
        if (v.kind == DS_RETE_VAL_NULL) return v;
        switch (expr->unop.op) {
        case DS_RETE_UNOP_NOT:
            if (v.kind != DS_RETE_VAL_BOOL) return type_error_at(ctx, expr);
            return ds_rete_val_bool(!v.b);
        case DS_RETE_UNOP_BNOT:
            if (v.kind != DS_RETE_VAL_INT) return type_error_at(ctx, expr);
            return ds_rete_val_int(~v.i);
        case DS_RETE_UNOP_NEG:
            /* `-INT64_MIN` is UB in C, and [LEXP.7.13.1] requires the wrap. */
            if (v.kind == DS_RETE_VAL_INT)
                return ds_rete_val_int(ds_i64_neg(v.i));
            if (v.kind == DS_RETE_VAL_FLOAT)  return ds_rete_val_float(-v.f);
            return type_error_at(ctx, expr);
        }
        return type_error_at(ctx, expr);
    }

    case DS_RETE_EXPR_NOW: {
        /* The wall clock's held sample ([LTIM.2.1.1], [LTIM.2.8.3]). With no
           value: DOMAIN ([LERR.1.4.10]). */
        int64_t wall = 0;
        if (!ds_rete_eval_wall_ns(ctx, &wall))
            return ds_rete_fault(ctx, expr, DS_FAULT_DOMAIN);
        return ds_rete_val_time(wall, 0);
    }

    case DS_RETE_EXPR_CALL:
        return eval_call(ctx, expr);

    case DS_RETE_EXPR_INTERP:
        return eval_interp(ctx, expr);

    case DS_RETE_EXPR_JSON_PATH:
        /* ds_json_parse allocates without bound. */
        if (ctx->engine->rt_mode)
            return type_error_at(ctx, expr);
        return eval_json_path_expr(ctx, expr);

    case DS_RETE_EXPR_IF: {
        ds_rete_val_t cond = ds_rete_eval(ctx, expr->if_.cond);
        if (ctx->faulted) return cond;
        if (cond.kind != DS_RETE_VAL_BOOL) return type_error_at(ctx, expr);
        return cond.b ? ds_rete_eval(ctx, expr->if_.then_)
                      : ds_rete_eval(ctx, expr->if_.else_);
    }

    case DS_RETE_EXPR_BIND: {
        uint32_t idx = expr->bind.bind_index;
        if (!ctx->bind_frame || idx >= ctx->bind_count)
            return ds_rete_fault(ctx, expr, DS_FAULT_ARTEFACT);
        ds_rete_val_t v = ds_rete_eval(ctx, expr->bind.expr);
        ctx->bind_frame[idx] = v;
        return v;
    }

    case DS_RETE_EXPR_BIND_REF: {
        uint32_t idx = expr->bind_ref.bind_index;
        if (!ctx->bind_frame || idx >= ctx->bind_count)
            return ds_rete_fault(ctx, expr, DS_FAULT_ARTEFACT);
        /* [RARC.5.6.11]: a read ahead of its binding is not an absent value. */
        if (ctx->bind_frame[idx].kind == DS_RETE_VAL_UNBOUND)
            return ds_rete_fault(ctx, expr, DS_FAULT_BINDING_ORDER);
        return ctx->bind_frame[idx];
    }

    default:
        return type_error_at(ctx, expr);
    }
}

bool ds_rete_eval_as_bool(ds_rete_eval_ctx_t *ctx,
                           const ds_rete_expr_t *expr)
{
    ds_rete_val_t v = ds_rete_eval(ctx, expr);
    /* Recorded where it faulted. */
    if (ctx->faulted) return false;
    if (v.kind == DS_RETE_VAL_BOOL) return v.b;
    /* [LNUL.4.3], [LNUL.9.2] */
    if (v.kind == DS_RETE_VAL_NULL) return false;
    (void)type_error_at(ctx, expr);
    return false;
}

/* ---- JSON_PATH traversal ------------------------------------------ */

/*
 * Both missings are `null`: `has()` reads presence off the node pointer
 * (builtins.c). A borrow is the caller's to keep valid: a fact's own tree outlives
 * the firing, and a tree parsed from text goes to ds_rete_transient_json_keep.
 */
ds_rete_val_t ds_rete_json_to_val(ds_rete_eval_ctx_t *ctx,
                                  ds_rete_engine_t *engine,
                                  const ds_json_t  *node)
{
    if (!node) return ds_rete_val_null();
    switch (node->kind) {
    case DS_JSON_NULL:   return ds_rete_val_null();
    case DS_JSON_BOOL:   return ds_rete_val_bool(node->v.b);
    case DS_JSON_INT:    return ds_rete_val_int(node->v.i);
    case DS_JSON_FLOAT:  return ds_rete_val_float(node->v.f);
    case DS_JSON_STRING: {
        /* Transient: arena, not interned. */
        const char *src = node->v.s ? node->v.s : "";
        size_t      slen = strlen(src);
        const char *p = ds_rete_arena_dup(&engine->comp_arena, src, slen);
        if (p == NULL) return ds_rete_fault(ctx, NULL, DS_FAULT_RESOURCE);
        return ds_rete_val_str(p, (uint32_t)slen);
    }
    case DS_JSON_ARRAY:
    case DS_JSON_OBJECT:
        return ds_rete_val_json_borrow(node);
    }
    return ds_rete_fault(ctx, NULL, DS_FAULT_ARTEFACT);
}

ds_rete_val_t ds_rete_json_path_result(ds_rete_eval_ctx_t *ctx,
                                       ds_rete_engine_t   *engine,
                                       const ds_json_t    *found,
                                       ds_json_t          *owned)
{
    ds_rete_val_t result = ds_rete_json_to_val(ctx, engine, found);
    if (owned == NULL)
        return result;
    if (result.kind != DS_RETE_VAL_JSON_BORROW) {
        ds_json_free(owned);
        return result;
    }
    if (ds_rete_transient_json_keep(engine, owned).status != DS_OK) {
        ds_json_free(owned);
        return ds_rete_fault(ctx, NULL, DS_FAULT_RESOURCE);
    }
    return result;
}

static ds_rete_val_t eval_json_path_expr(ds_rete_eval_ctx_t   *ctx,
                                          const ds_rete_expr_t *expr)
{
    /* [LNUL.4.10] */
    ds_rete_held_t vh, ph;
    ds_rete_val_t val  = ds_rete_eval_holding(ctx, expr->json_path.val, &vh);
    if (ctx->faulted) return val;
    ds_rete_val_t path = ds_rete_eval_holding(ctx, expr->json_path.path, &ph);
    if (ctx->faulted) return path;
    ds_rete_held_select(&vh, &ph);
    if (vh.held) return ds_rete_raise_held(ctx, &vh);
    if (path.kind != DS_RETE_VAL_STR) return type_error_at(ctx, expr);

    ds_json_t       *owned = NULL;
    const ds_json_t *root  = NULL;

    if (val.kind == DS_RETE_VAL_JSON || val.kind == DS_RETE_VAL_JSON_BORROW) {
        root = val.json;
    } else if (val.kind == DS_RETE_VAL_STR) {
        /* Over a limit of [LGRA.5.8.6] is NOT_REPRESENTABLE. Text that is not JSON
           is data: the expr's taint decides the class. */
        ds_result_t pr = ds_json_parse(val.s.ptr, val.s.len, &owned);
        if (pr.status == DS_ERR_JSON_LIMIT)
            return ds_rete_fault(ctx, expr, DS_FAULT_NOT_REPRESENTABLE);
        if (pr.status != DS_OK)
            return type_error_at(ctx, expr);
        root = owned;
    } else {
        return type_error_at(ctx, expr);
    }

    const ds_json_t *found = NULL;
    ds_json_get_path_n(root, path.s.ptr, path.s.len, &found);
    ctx->json_composite = found != NULL
        && (found->kind == DS_JSON_ARRAY || found->kind == DS_JSON_OBJECT);
    return ds_rete_json_path_result(ctx, ctx->engine, found, owned);
}
