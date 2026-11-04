/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/clone.h — shared remap context for ds_engine_clone.
 *
 * Each rete module has a `_clone` helper beside its `_init`/`_free`, so the
 * file-static oa callbacks stay encapsulated, and rete/engine.c orchestrates
 * them. The intern table is deep-copied, not shared: it grows at runtime, and
 * sharing would race parallel clones ([IARC.11.3]).
 */
#ifndef LIBDS2_INTERNAL_RETE_CLONE_H
#define LIBDS2_INTERNAL_RETE_CLONE_H

#include <stdbool.h>
#include <stdint.h>

#include "libds.h"
#include "oa.h"
#include "rete/action.h"
#include "rete/agenda.h"
#include "rete/expr.h"
#include "rete/tms.h"
#include "rete/val.h"

struct ds_rete_fact;
struct ds_rete_intern;
struct ds_rete_engine;
struct ds_rete_token;
struct ds_rete_alpha_node;
struct ds_rete_beta_node;
struct ds_rete_terminal;
struct ds_engine;   /* DS-level engine (engine.h) */

typedef struct {
    oa_t                   id2fact;    /* u32 old fact id -> new ds_rete_fact_t* */
    oa_t                   act_map;    /* old activation* -> new activation*, across
                                          all terminals, for the agenda heap */
    struct ds_rete_intern *dst_intern; /* borrowed from the clone's rete engine */
    bool                   oom;        /* sticky: an allocation failed */
} ds_rete_clone_ctx_t;

ds_result_t ds_rete_clone_ctx_init(ds_rete_clone_ctx_t *cx,
                                   struct ds_rete_intern *dst_intern);
void        ds_rete_clone_ctx_dispose(ds_rete_clone_ctx_t *cx);

/* The plain form re-interns pinned (expression literals); the _value form
   counted (fact-slot values: the caller acquires a reference per cloned fact). */
const char *ds_rete_clone_intern(ds_rete_clone_ctx_t *cx,
                                 const char *old_ptr, uint32_t len);
const char *ds_rete_clone_intern_value(ds_rete_clone_ctx_t *cx,
                                       const char *old_ptr, uint32_t len);

struct ds_rete_fact *ds_rete_clone_fact_lookup(ds_rete_clone_ctx_t *cx,
                                               uint32_t old_id);

struct ds_rete_activation *ds_rete_clone_act_lookup(
    ds_rete_clone_ctx_t *cx, const struct ds_rete_activation *old_act);

/* STR/BYTES re-interned; JSON via ds_json_clone; JSON_BORROW left for the
 * DS-layer bridge clone to repoint. */
ds_rete_val_t ds_rete_clone_val(ds_rete_clone_ctx_t *cx,
                                const ds_rete_val_t *src);

/* Each engine owns its own copy, so free-in-any-order holds ([NLFC.8.1]). On OOM
 * sets cx->oom and returns a partial tree, freeable by ds_rete_expr_free_tree. */
ds_rete_expr_t *ds_rete_clone_expr(ds_rete_clone_ctx_t *cx,
                                   const ds_rete_expr_t *src);

ds_result_t ds_rete_clone_action(ds_rete_clone_ctx_t *cx,
                                 const ds_rete_action_t *src,
                                 ds_rete_action_t *dst);

/* Re-registers each schema in id order into a freshly created dst, so its schema
 * ids are src's. */
ds_result_t ds_rete_schemas_clone(ds_rete_clone_ctx_t *cx,
                                  const struct ds_rete_engine *src,
                                  struct ds_rete_engine *dst);

/* Schemas must be cloned first. Keeps both the wm_map dense order and the TTL
 * FIFO order, and populates cx->id2fact for every later remap. */
ds_result_t ds_rete_wm_clone(ds_rete_clone_ctx_t *cx,
                             const struct ds_rete_engine *src,
                             struct ds_rete_engine *dst);

/* WM must be cloned first. next/prev are NULL: the caller links it. */
struct ds_rete_token *ds_rete_token_clone(ds_rete_clone_ctx_t *cx,
                                          const struct ds_rete_token *src);

/* WM must be cloned first. The alpha memory keeps its dense order, which is the
 * join scan's. `beta_outputs` is left for the orchestration to wire. */
ds_result_t ds_rete_alpha_node_clone(ds_rete_clone_ctx_t *cx,
                                     const struct ds_rete_alpha_node *src,
                                     struct ds_rete_alpha_node **out);

/* WM must be cloned first. Each index keeps its dense order. Inputs and outputs
 * are left for the orchestration to wire. */
ds_result_t ds_rete_beta_node_clone(ds_rete_clone_ctx_t *cx,
                                    const struct ds_rete_beta_node *src,
                                    struct ds_rete_beta_node **out);

/* WM must be cloned first. Beta-parent linkage is left for the orchestration. */
ds_result_t ds_rete_terminal_clone(ds_rete_clone_ctx_t *cx,
                                    const struct ds_rete_terminal *src,
                                    struct ds_rete_terminal **out);

ds_result_t ds_rete_tms_clone(ds_rete_clone_ctx_t *cx,
                              const ds_tms_table_t *src, ds_tms_table_t *dst);

/* Must run after every terminal is cloned: it reads cx->act_map. */
ds_result_t ds_rete_agenda_clone(ds_rete_clone_ctx_t *cx,
                                 const ds_rete_agenda_t *src,
                                 ds_rete_agenda_t *dst);

ds_result_t ds_rete_rate_table_clone(ds_rete_clone_ctx_t *cx,
                                     const struct ds_rete_engine *src,
                                     struct ds_rete_engine *dst);

/* Populates a freshly created dst as a structural clone of src. The adapter
 * callbacks, op-dispatch wiring and back-pointers are ds_engine_clone's. cx must
 * be init'd against dst->intern. */
ds_result_t ds_rete_engine_clone(ds_rete_clone_ctx_t *cx,
                                 const struct ds_rete_engine *src,
                                 struct ds_rete_engine *dst);

/* The ds_fact_t wrapper layer. The rete engine and DS schema registry must be
 * cloned first. Keeps wm.table's dense order and the per-schema fact lists. */
ds_result_t ds_wm_bridge_clone(ds_rete_clone_ctx_t *cx,
                               struct ds_engine *src, struct ds_engine *dst);

#endif /* LIBDS2_INTERNAL_RETE_CLONE_H */
