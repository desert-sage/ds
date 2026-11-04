/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/action.c — RHS action lifecycle (IRET.10).
 */
#include <stdlib.h>

#include "rete/action.h"
#include "ds_alloc.h"
#include "rete/expr.h"

void ds_rete_action_free(ds_rete_action_t *action)
{
    if (!action) return;
    ds_rete_expr_free_tree(action->expr);
    if (action->assigns) {
        for (uint32_t i = 0; i < action->assign_count; i++)
            ds_rete_expr_free_tree(action->assigns[i].expr);
        DS_FREE(action->assigns);
    }
    ds_rete_expr_free_tree(action->ttl_override);
}
