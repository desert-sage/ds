/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/beta.h — beta (join) node, join tests, and the four join-algorithm
 * activation paths (IRET.7.4-7.9).
 *
 * A beta node owns the tokens in its left memory; downstream nodes own their
 * own.
 */
#ifndef LIBDS2_INTERNAL_RETE_BETA_H
#define LIBDS2_INTERNAL_RETE_BETA_H

#include <stdbool.h>
#include <stdint.h>

#include "libds.h"
#include "oa.h"
#include "rete/alpha.h"
#include "rete/expr.h"
#include "rete/fact.h"
#include "rete/token.h"

/* Forward declarations */
struct ds_rete_engine;
struct ds_rete_terminal;

/* ---- Join test (IRET.7.5) ----------------------------------------- */

typedef struct {
    ds_rete_expr_t *expr; /* NULL = always true */
} ds_rete_join_test_t;

/* ---- Beta node (IRET.7.4) ----------------------------------------- */

typedef struct ds_rete_beta_node {
    struct ds_rete_beta_node *left_parent;   /* NULL = WM root */
    ds_rete_alpha_node_t     *right_alpha;
    ds_rete_join_test_t      *join_tests;    /* array; owned */
    uint32_t                  join_test_count;
    bool                      is_negative;  /* NOT node */

    ds_rete_token_t          *left_head;    /* linked via token->next/prev */
    uint32_t                  left_count;

    /* Content lookup over left memory: token* (->hash / tokens_equal) -> stored
       token. The left_head list stays the ordered traversal. */
    oa_t                      lmem_map;

/* Inline slots per hash entry. Reduce on memory-constrained targets. */
#ifndef DS_RIDX_INLINE
#define DS_RIDX_INLINE 8u
#endif
    /* Reverse join index: fact_id -> oa_list of left-memory tokens joined with
       that fact. */
    oa_t                      ridx_map;

    /* Forward lmem join-key index, enabled when the first join test is
       EQ(left_slot, right_slot). Keyed by
       token.facts[lmem_idx_fact_idx]->slots[lmem_idx_left_slot]. */
    bool     lmem_idx_enabled;
    /* Whether the EQ key may be probed ([IRET.7.5.1], RLOW.5.5): 0 until both
       schemas have been seen, then +1 (probe) or -1 (scan). Both indexes are
       maintained either way. See `eq_key_decided` in beta.c. */
    int8_t   eq_key_decided;
    uint8_t  lmem_idx_fact_idx;
    uint8_t  lmem_idx_left_slot;
    uint8_t  lmem_idx_right_slot;
    /* Slot value -> oa_list<token*>. */
    oa_t     lmem_idx_map;

    /* Right-alpha join-key index, on the same key as lmem_idx. Keyed by
       right_fact.slots[ralpha_idx_right_slot]. */
    bool     ralpha_idx_enabled;
    uint8_t  ralpha_idx_right_slot;
    uint8_t  ralpha_idx_left_fact;
    uint8_t  ralpha_idx_left_slot;
    /* Right slot value -> oa_list<fact*>. */
    oa_t     ralpha_idx_map;

    /* Left-token join index, the inverse of ridx: token ptr -> oa_list<fact*> it
       joined with, or on a NOT node the facts blocking it (IRET.7.9.4). */
    oa_t                      ltok_idx_map;

    /* Set by ds_rete_go_live(): the per-entry lists refuse to grow. */
    bool rt_locked;

    struct ds_rete_beta_node **beta_children;
    uint32_t                   beta_child_count;
    uint32_t                   beta_child_cap;
    struct ds_rete_terminal  **terminal_children;
    uint32_t                   terminal_child_count;
    uint32_t                   terminal_child_cap;

    /* From the BetaNode atom. 0 when not from a DSC. */
    uint32_t                   node_id;
    /* `$beta_<node_id>`, the rule name a join-test fault carries ([LERR.9.11]). */
    char                       fault_rule[DS_RETE_FAULT_RULE_CAP];
    /* A node a fault handler's patterns use ([LERR.9.6]). */
    bool                       fault_handler;
    /* Token capacity from the realtime contract. 0 = no cap. */
    uint32_t                   contract_capacity;
    bool (*join_fn)(const ds_rete_token_t *token,
                    const ds_rete_fact_t  *fact);

    /* [LDET.5.5] Matches this node completes during one working-memory event,
       held until the event ends so their timetags are minted in key order.
       Intrusive through token->next, and the node through pending_next on the
       engine's list, so holding them allocates nothing. `completes`: 0 not yet
       known, +1 this is the last positive join of its chain, -1 it is not. */
    ds_rete_token_t          *pending_head;
    struct ds_rete_beta_node *pending_next;
    int8_t                    completes;
} ds_rete_beta_node_t;

/* [LDET.5.5] End of a working-memory event: every node holding completed
   matches, ascending by node_id, sorts them by their facts' entry ranks,
   mints their timetags in that order and propagates them. Returns the first
   error; every held token is released either way. */
ds_result_t ds_rete_beta_flush_completions(struct ds_rete_engine *engine);

/* The same release without propagating: the event failed and is unwound. */
void ds_rete_beta_discard_completions(struct ds_rete_engine *engine);

/* [LERR.1.4.12] Where one working-memory event's held traps begin: an event
   nested inside another -- a truth-maintenance withdrawal the outer one's
   propagation causes -- holds its own, after the outer's. */
typedef struct {
    uint32_t n;
    uint32_t ids_n;
} ds_rete_match_trap_mark_t;

ds_rete_match_trap_mark_t ds_rete_beta_match_trap_mark(
    const struct ds_rete_engine *engine);

/* [LERR.1.4.12] End of a working-memory event: of the TypeErrors and
   ComputationErrors its join tests raised since `mark`, record the ones whose
   pair the event derived, once each, ordered by the rule's terminal ordinal,
   the pair's facts as [LDET.5.5] ranks a match, then the node's depth. */
void ds_rete_beta_flush_match_traps(struct ds_rete_engine     *engine,
                                    ds_rete_match_trap_mark_t  mark);

/* Drop what an event held since `mark` without recording it: the event
   failed and is unwound, so none of its pairs is live. */
void ds_rete_beta_discard_match_traps(struct ds_rete_engine     *engine,
                                      ds_rete_match_trap_mark_t  mark);

void ds_rete_beta_free_match_traps(struct ds_rete_engine *engine);

ds_result_t ds_rete_beta_node_create(struct ds_rete_beta_node  *left_parent,
                                      ds_rete_alpha_node_t      *right_alpha,
                                      ds_rete_join_test_t       *join_tests,
                                      uint32_t                   join_test_count,
                                      bool                       is_negative,
                                      ds_rete_beta_node_t      **out);

/* Does not free beta_children: the engine's node graph owns them. */
void ds_rete_beta_node_destroy(ds_rete_beta_node_t *node);

/* Sets both directions of the edge. DS_ERR_INVAL if the child already has a
 * different left parent. */
ds_result_t ds_rete_beta_add_child(ds_rete_beta_node_t *node,
                                    ds_rete_beta_node_t *child);

/* Pre-size each hash map to at least cap entries. */
ds_result_t ds_rete_beta_presz_ridx(ds_rete_beta_node_t *node, uint32_t cap);
ds_result_t ds_rete_beta_presz_ralpha(ds_rete_beta_node_t *node, uint32_t cap);
ds_result_t ds_rete_beta_presz_ltok(ds_rete_beta_node_t *node, uint32_t cap);

#ifndef NDEBUG
/* Assert this node's index and counter invariants. */
void ds_rete_beta_check(const ds_rete_beta_node_t *node);
#endif

ds_result_t ds_rete_beta_presz_lmem_idx(ds_rete_beta_node_t *node, uint32_t cap);

ds_result_t ds_rete_beta_add_terminal(ds_rete_beta_node_t      *node,
                                       struct ds_rete_terminal  *terminal);

/* ---- Join algorithm activation paths (IRET.7.7) ------------------- */

/* A new fact was added to right_alpha. */
ds_result_t ds_rete_beta_right_activate(ds_rete_beta_node_t *node,
                                         ds_rete_fact_t      *fact,
                                         struct ds_rete_engine *engine);

/* A new token arrived from left_parent. */
ds_result_t ds_rete_beta_left_activate(ds_rete_beta_node_t  *node,
                                        ds_rete_token_t      *token,
                                        struct ds_rete_engine *engine);

/* A fact was removed from right_alpha. No join test is evaluated ([IRET.7.7]). */
ds_result_t ds_rete_beta_right_retract(ds_rete_beta_node_t *node,
                                        ds_rete_fact_t      *fact,
                                        struct ds_rete_engine *engine);

/* A token was retracted from left_parent. No join test is evaluated. */
ds_result_t ds_rete_beta_left_retract(ds_rete_beta_node_t  *node,
                                       ds_rete_token_t      *token,
                                       struct ds_rete_engine *engine);

#endif /* LIBDS2_INTERNAL_RETE_BETA_H */
