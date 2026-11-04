/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/action.h — RHS action types (IRET.10).
 *
 * An action is evaluated when an activation fires.  CALL actions evaluate
 * an expression for its side effects.  ASSERT / LOGICAL_ASSERT actions
 * build a fact from slot assignments and insert it into working memory;
 * LOGICAL_ASSERT additionally registers the fact in the TMS.
 */
#ifndef LIBDS2_INTERNAL_RETE_ACTION_H
#define LIBDS2_INTERNAL_RETE_ACTION_H

#include <stdint.h>

#include "libds.h"
#include "rete/expr.h"

/* ---- Action kind -------------------------------------------------- */

typedef enum {
    DS_RETE_ACTION_CALL,           /* evaluate expr for side effects (IRET.10.3) */
    DS_RETE_ACTION_ASSERT,         /* emit Schema …  (IRET.10.1) */
    DS_RETE_ACTION_LOGICAL_ASSERT, /* emit Schema … logical  (IRET.10.2) */
    DS_RETE_ACTION_WITHDRAW,       /* withdraw binding  (IRET.10.5) */
    DS_RETE_ACTION_WITHDRAW_BY_ID, /* withdraw, nested body (IRET.10.7) */
} ds_rete_action_kind_t;

/* ---- Slot assignment (used by ASSERT / LOGICAL_ASSERT) ------------ */

typedef struct {
    uint8_t         slot_index; /* 0..254, no marker ([RDSC.4a.9.1]) */
    ds_rete_expr_t *expr;       /* owned */
} ds_rete_slot_assign_t;

/* ---- Action ------------------------------------------------------- */

typedef struct {
    ds_rete_action_kind_t kind;

    /* CALL: evaluated for side effects; result discarded.
       WITHDRAW_BY_ID: `Action.withdraw_fact_id`, evaluating to the fact
       reference of the fact to withdraw. */
    ds_rete_expr_t       *expr;

    /* ASSERT / LOGICAL_ASSERT: target schema + slot assignments. */
    uint16_t              schema_id;
    ds_rete_slot_assign_t *assigns;   /* owned array */
    uint32_t              assign_count;

    /* [LDTL.4.1] `emit … retain: <dur>`: evaluated at fire time to a duration
       in ns, replacing the schema TTL. NULL: the schema TTL. Owned. */
    ds_rete_expr_t       *ttl_override;

    /* WITHDRAW: the token position of the fact to withdraw, 0..254 with no
       marker ([RDSC.4a.9.1]): the terminal's token has no candidate fact. */
    uint8_t               withdraw_pattern_index;
} ds_rete_action_t;

/* ---- Lifecycle ---------------------------------------------------- */

/*
 * ds_rete_action_free — free an action and all owned sub-trees.
 * Does NOT free the action struct itself (caller manages the array).
 */
void ds_rete_action_free(ds_rete_action_t *action);

#endif /* LIBDS2_INTERNAL_RETE_ACTION_H */
