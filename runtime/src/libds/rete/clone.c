/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/clone.c — shared remap-context helpers for ds_engine_clone.
 */

#include "rete/clone.h"

#include <string.h>

#include "ds_alloc.h"
#include "libds.h"
#include "oa.h"
#include "rete/action.h"
#include "rete/expr.h"
#include "rete/fact.h"
#include "rete/intern.h"
#include "rete/schema.h"
#include "rete/val.h"

static uint64_t id2fact_hash(const void *key, void *ctx)
{
    (void) ctx;
    return (uint64_t) (*(const uint32_t *) key);
}
static bool id2fact_eq(const void *a, const void *b, void *ctx)
{
    (void) ctx;
    return *(const uint32_t *) a == *(const uint32_t *) b;
}

static uint64_t actptr_hash(const void *key, void *ctx)
{
    (void) ctx;
    return (uint64_t) (uintptr_t) *(void *const *) key;
}
static bool actptr_eq(const void *a, const void *b, void *ctx)
{
    (void) ctx;
    return *(void *const *) a == *(void *const *) b;
}

ds_result_t ds_rete_clone_ctx_init(ds_rete_clone_ctx_t *cx,
                                   ds_rete_intern_t *dst_intern)
{
    ds_oa_init(&cx->id2fact, sizeof(uint32_t), sizeof(ds_rete_fact_t *),
            0 /* default load */, id2fact_hash, id2fact_eq, NULL, NULL);
    ds_oa_init(&cx->act_map, sizeof(void *), sizeof(void *),
            0 /* default load */, actptr_hash, actptr_eq, NULL, NULL);
    cx->dst_intern = dst_intern;
    cx->oom = false;
    return DS_OK_R;
}

void ds_rete_clone_ctx_dispose(ds_rete_clone_ctx_t *cx)
{
    ds_oa_free(&cx->id2fact);
    ds_oa_free(&cx->act_map);
    cx->dst_intern = NULL;
}

struct ds_rete_activation *ds_rete_clone_act_lookup(
    ds_rete_clone_ctx_t *cx, const struct ds_rete_activation *old_act)
{
    if (old_act == NULL) return NULL;
    void *v = ds_oa_get(&cx->act_map, &old_act);
    return v ? *(struct ds_rete_activation **) v : NULL;
}

const char *ds_rete_clone_intern(ds_rete_clone_ctx_t *cx,
                                 const char *old_ptr, uint32_t len)
{
    if (old_ptr == NULL) return NULL;
    const char *np = NULL;
    ds_result_t r = ds_rete_intern(cx->dst_intern, old_ptr, len, &np);
    if (r.status != DS_OK) { cx->oom = true; return NULL; }
    return np;
}

const char *ds_rete_clone_intern_value(ds_rete_clone_ctx_t *cx,
                                       const char *old_ptr, uint32_t len)
{
    if (old_ptr == NULL) return NULL;
    const char *np = NULL;
    ds_result_t r = ds_rete_intern_value(cx->dst_intern, old_ptr, len, &np);
    if (r.status != DS_OK) { cx->oom = true; return NULL; }
    return np;
}

ds_rete_fact_t *ds_rete_clone_fact_lookup(ds_rete_clone_ctx_t *cx,
                                          uint32_t old_id)
{
    void *v = ds_oa_get(&cx->id2fact, &old_id);
    return v ? *(ds_rete_fact_t **) v : NULL;
}

ds_rete_val_t ds_rete_clone_val(ds_rete_clone_ctx_t *cx,
                                const ds_rete_val_t *src)
{
    ds_rete_val_t v = *src;
    switch (src->kind) {
    case DS_RETE_VAL_STR:
    case DS_RETE_VAL_BYTES:
        v.s.ptr = ds_rete_clone_intern_value(cx, src->s.ptr, src->s.len);
        v.s.len = src->s.len;
        break;
    case DS_RETE_VAL_JSON: {
        ds_json_t *j = NULL;
        ds_result_t r = ds_json_clone(src->json, &j);
        if (r.status != DS_OK) { cx->oom = true; v.json = NULL; }
        else v.json = j;
        break;
    }
    case DS_RETE_VAL_FACT_REF:
        /* The clone keeps every fact's id, so this needs no remap. */
        break;
    case DS_RETE_VAL_JSON_BORROW:   /* repointed with the DS-layer wrapper clone */
        v.json = NULL;
        break;
    default:
        break;
    }
    return v;
}

static const char *clone_cstr(ds_rete_clone_ctx_t *cx, const char *s)
{
    return s ? ds_rete_clone_intern(cx, s, (uint32_t) strlen(s)) : NULL;
}

ds_rete_expr_t *ds_rete_clone_expr(ds_rete_clone_ctx_t *cx,
                                   const ds_rete_expr_t *src)
{
    if (src == NULL) return NULL;
    ds_rete_expr_t *e = ds_rete_expr_alloc(src->kind);
    if (e == NULL) { cx->oom = true; return NULL; }
    e->json_tainted = src->json_tainted;

    /* No `default:`: -Wswitch names a kind this switch forgets. */
    switch (src->kind) {
    case DS_RETE_EXPR_LIT_INT:   e->lit_int   = src->lit_int;   break;
    case DS_RETE_EXPR_LIT_FLOAT: e->lit_float = src->lit_float; break;
    case DS_RETE_EXPR_LIT_BOOL:  e->lit_bool  = src->lit_bool;  break;
    case DS_RETE_EXPR_LIT_STR:   e->lit_str   = clone_cstr(cx, src->lit_str); break;
    case DS_RETE_EXPR_VAR:       e->var       = src->var;       break;
    case DS_RETE_EXPR_NOW:       break;
    case DS_RETE_EXPR_BIND_REF:  e->bind_ref  = src->bind_ref;  break;

    case DS_RETE_EXPR_BINOP:
        e->binop.op    = src->binop.op;
        e->binop.left  = ds_rete_clone_expr(cx, src->binop.left);
        e->binop.right = ds_rete_clone_expr(cx, src->binop.right);
        break;
    case DS_RETE_EXPR_UNOP:
        e->unop.op      = src->unop.op;
        e->unop.operand = ds_rete_clone_expr(cx, src->unop.operand);
        break;
    case DS_RETE_EXPR_CALL:
        e->call.op        = src->call.op;
        e->call.arg_count = src->call.arg_count;
        if (src->call.arg_count > 0) {
            e->call.args = DS_CALLOC(src->call.arg_count, sizeof(*e->call.args));
            if (e->call.args == NULL) { cx->oom = true; break; }
            for (uint32_t i = 0; i < src->call.arg_count; i++)
                e->call.args[i] = ds_rete_clone_expr(cx, src->call.args[i]);
        }
        break;
    case DS_RETE_EXPR_INTERP:
        if (src->interp.prim_count == 0) break;
        e->interp.prims = DS_CALLOC(src->interp.prim_count, sizeof(*e->interp.prims));
        if (e->interp.prims == NULL) { cx->oom = true; break; }
        e->interp.prim_count = src->interp.prim_count;
        for (uint32_t i = 0; i < src->interp.prim_count; i++) {
            const ds_rete_fprim_t *sp = &src->interp.prims[i];
            ds_rete_fprim_t       *dp = &e->interp.prims[i];
            *dp = *sp;
            dp->value = NULL;
            dp->items = NULL;
            dp->item_count = 0;
            if (sp->text != NULL)
                dp->text = ds_rete_clone_intern(cx, sp->text, sp->text_len);
            if (sp->value != NULL)
                dp->value = ds_rete_clone_expr(cx, sp->value);
            if (sp->item_count > 0) {
                dp->items = DS_CALLOC(sp->item_count, sizeof(*dp->items));
                if (dp->items == NULL) { cx->oom = true; break; }
                dp->item_count = sp->item_count;
                for (uint32_t k = 0; k < sp->item_count; k++) {
                    dp->items[k] = sp->items[k];
                    if (sp->items[k].text != NULL)
                        dp->items[k].text = ds_rete_clone_intern(
                            cx, sp->items[k].text, sp->items[k].text_len);
                }
            }
        }
        break;
    case DS_RETE_EXPR_JSON_PATH:
        e->json_path.val  = ds_rete_clone_expr(cx, src->json_path.val);
        e->json_path.path = ds_rete_clone_expr(cx, src->json_path.path);
        break;
    case DS_RETE_EXPR_IF:
        e->if_.cond  = ds_rete_clone_expr(cx, src->if_.cond);
        e->if_.then_ = ds_rete_clone_expr(cx, src->if_.then_);
        e->if_.else_ = ds_rete_clone_expr(cx, src->if_.else_);
        break;
    case DS_RETE_EXPR_BIND:
        e->bind.bind_index = src->bind.bind_index;
        e->bind.expr       = ds_rete_clone_expr(cx, src->bind.expr);
        break;

    case DS_RETE_EXPR_LIT_NULL: break;
    case DS_RETE_EXPR_COALESCE:
        e->coalesce.left  = ds_rete_clone_expr(cx, src->coalesce.left);
        e->coalesce.right = ds_rete_clone_expr(cx, src->coalesce.right);
        break;
    case DS_RETE_EXPR_IS_TEST:
        e->is_test.subject = src->is_test.subject;
        e->is_test.negated = src->is_test.negated;
        e->is_test.operand = ds_rete_clone_expr(cx, src->is_test.operand);
        break;
    case DS_RETE_EXPR_ENTRY_STAMP:
        e->entry_stamp = src->entry_stamp;
        break;
    }
    return e;
}

ds_result_t ds_rete_clone_action(ds_rete_clone_ctx_t *cx,
                                 const ds_rete_action_t *src,
                                 ds_rete_action_t *dst)
{
    dst->kind         = src->kind;
    dst->schema_id    = src->schema_id;
    dst->expr         = ds_rete_clone_expr(cx, src->expr);
    dst->assign_count = src->assign_count;
    dst->assigns      = NULL;
    dst->ttl_override = NULL;
    dst->withdraw_pattern_index = src->withdraw_pattern_index;

    if (src->assign_count > 0) {
        dst->assigns = DS_CALLOC(src->assign_count, sizeof(*dst->assigns));
        if (dst->assigns == NULL) {
            cx->oom = true;
            return DS_ERR_R(DS_ERR_OOM, "clone: action assigns");
        }
        for (uint32_t i = 0; i < src->assign_count; i++) {
            dst->assigns[i].slot_index = src->assigns[i].slot_index;
            dst->assigns[i].expr = ds_rete_clone_expr(cx, src->assigns[i].expr);
        }
    }
    dst->ttl_override = ds_rete_clone_expr(cx, src->ttl_override);

    return cx->oom ? DS_ERR_R(DS_ERR_OOM, "clone: action expr") : DS_OK_R;
}
