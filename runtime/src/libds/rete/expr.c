/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/expr.c — expression node allocation and tree freeing.
 */
#include <stdlib.h>
#include <string.h>

#include "rete/expr.h"
#include "ds_alloc.h"

ds_rete_expr_t *ds_rete_expr_alloc(ds_rete_expr_kind_t kind)
{
    ds_rete_expr_t *e = DS_CALLOC(1, sizeof(*e));
    if (e) e->kind = kind;
    return e;
}

void ds_rete_expr_free_tree(ds_rete_expr_t *expr)
{
    if (!expr) return;
    switch (expr->kind) {
    case DS_RETE_EXPR_BINOP:
        ds_rete_expr_free_tree(expr->binop.left);
        ds_rete_expr_free_tree(expr->binop.right);
        break;
    case DS_RETE_EXPR_UNOP:
        ds_rete_expr_free_tree(expr->unop.operand);
        break;
    case DS_RETE_EXPR_CALL:
        for (uint32_t i = 0; i < expr->call.arg_count; i++)
            ds_rete_expr_free_tree(expr->call.args[i]);
        DS_FREE(expr->call.args);
        break;
    case DS_RETE_EXPR_INTERP:
        for (uint32_t i = 0; i < expr->interp.prim_count; i++) {
            ds_rete_expr_free_tree(expr->interp.prims[i].value);
            DS_FREE(expr->interp.prims[i].items);  /* texts are interned */
        }
        DS_FREE(expr->interp.prims);
        break;
    case DS_RETE_EXPR_JSON_PATH:
        ds_rete_expr_free_tree(expr->json_path.val);
        ds_rete_expr_free_tree(expr->json_path.path);
        break;
    case DS_RETE_EXPR_IF:
        ds_rete_expr_free_tree(expr->if_.cond);
        ds_rete_expr_free_tree(expr->if_.then_);
        ds_rete_expr_free_tree(expr->if_.else_);
        break;
    case DS_RETE_EXPR_BIND:
        ds_rete_expr_free_tree(expr->bind.expr);
        break;
    case DS_RETE_EXPR_COALESCE:
        ds_rete_expr_free_tree(expr->coalesce.left);
        ds_rete_expr_free_tree(expr->coalesce.right);
        break;
    case DS_RETE_EXPR_IS_TEST:
        ds_rete_expr_free_tree(expr->is_test.operand);
        break;
    default:
        break;
    }
    DS_FREE(expr);
}
