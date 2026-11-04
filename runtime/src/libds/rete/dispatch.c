/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/dispatch.c — alpha dispatch table (IRET.1.7).
 */
#include <stdlib.h>

#include "libds.h"
#include "ds_alloc.h"

#include "rete/alpha.h"
#include "rete/beta.h"
#include "rete/dispatch.h"
#include "rete/engine.h"
#include "rete/eval.h"
#include "rete/fact.h"

#define DISPATCH_INIT_CAP 4u

ds_result_t ds_rete_dispatch_add(ds_rete_engine_t     *engine,
                                  uint16_t              schema_id,
                                  ds_rete_alpha_node_t *node)
{
    if (!engine || !node)
        return DS_ERR_R(DS_ERR_INVAL, "dispatch_add: NULL arg");
    if (schema_id >= engine->schema_count)
        return DS_ERR_R(DS_ERR_INVAL, "dispatch_add: schema_id out of range");

    ds_rete_dispatch_entry_t *entry = &engine->alpha_dispatch[schema_id];

    if (entry->count >= entry->cap) {
        uint32_t new_cap = entry->cap ? entry->cap * 2 : DISPATCH_INIT_CAP;
        ds_rete_alpha_node_t **nn =
            DS_REALLOC(entry->nodes, new_cap * sizeof(*nn));
        if (!nn) return DS_ERR_R(DS_ERR_OOM, "dispatch entry grow");
        entry->nodes = nn;
        entry->cap   = new_cap;
    }
    entry->nodes[entry->count++] = node;
    return DS_OK_R;
}

/* [LDET.5.5] A working-memory event: one fact entering or leaving. The matches
   it completes are held at their completing joins and minted in key order when
   the outermost event ends. A failed event releases them unpropagated. */
static ds_result_t dispatch_assert_event(ds_rete_engine_t *engine,
                                         ds_rete_fact_t   *fact);
static ds_result_t dispatch_retract_event(ds_rete_engine_t *engine,
                                          ds_rete_fact_t   *fact);

/* [LERR.1.4.12] Every event holds the faults its join tests raise and records
   the ones it derived once its propagation has completed: the outermost after
   flushing its completions, which can evaluate more pairs; a nested one, a
   truth-maintenance withdrawal, when it returns. A failed event records none:
   its unwind ends every pair it began. */
static ds_rete_match_trap_mark_t begin_event(ds_rete_engine_t *engine)
{
    if (engine->event_depth++ == 0) engine->match_trap_hold = true;
    return ds_rete_beta_match_trap_mark(engine);
}

static ds_result_t end_event(ds_rete_engine_t         *engine,
                             ds_rete_match_trap_mark_t mark,
                             ds_result_t               r)
{
    engine->event_depth--;
    if (engine->event_depth > 0) {
        if (r.status != DS_OK) ds_rete_beta_discard_match_traps(engine, mark);
        else                   ds_rete_beta_flush_match_traps(engine, mark);
        return r;
    }
    /* [LERR.1.4.7]: an event the halt reached is dropped, not finished. */
    if (r.status != DS_OK || engine->halted) {
        ds_rete_beta_discard_completions(engine);
        engine->match_trap_hold = false;
        ds_rete_beta_discard_match_traps(engine, mark);
        return r;
    }
    r = ds_rete_beta_flush_completions(engine);
    engine->match_trap_hold = false;
    if (r.status != DS_OK) {
        ds_rete_beta_discard_match_traps(engine, mark);
        return r;
    }
    ds_rete_beta_flush_match_traps(engine, mark);
    return r;
}

ds_result_t ds_rete_dispatch_assert(ds_rete_engine_t *engine,
                                     ds_rete_fact_t   *fact)
{
    if (!engine || !fact)
        return DS_ERR_R(DS_ERR_INVAL, "dispatch_assert: NULL arg");
    const ds_rete_match_trap_mark_t mark = begin_event(engine);
    return end_event(engine, mark, dispatch_assert_event(engine, fact));
}

ds_result_t ds_rete_dispatch_retract(ds_rete_engine_t *engine,
                                      ds_rete_fact_t   *fact)
{
    if (!engine || !fact)
        return DS_ERR_R(DS_ERR_INVAL, "dispatch_retract: NULL arg");
    const ds_rete_match_trap_mark_t mark = begin_event(engine);
    return end_event(engine, mark, dispatch_retract_event(engine, fact));
}

static ds_result_t dispatch_assert_event(ds_rete_engine_t *engine,
                                         ds_rete_fact_t   *fact)
{
    uint16_t sid = fact->schema->id;
    if (sid >= engine->schema_count) return DS_OK_R;

    ds_rete_dispatch_entry_t *entry = &engine->alpha_dispatch[sid];
    ds_result_t r = DS_OK_R;
    for (uint32_t i = 0; i < entry->count; i++) {
        /* [LERR.1.4.7]: an alpha test raises its fault at once, so this is the
           first place its halt can stop the assert. Nothing is unwound. */
        if (engine->halted) return DS_OK_R;
        ds_rete_alpha_node_t *n = entry->nodes[i];
        /* A fault here is identified by the node: at alpha time there is no
           token, binding frame or firing activation. */
        ds_rete_eval_ctx_t actx = { 0 };
        actx.engine  = engine;
        actx.node_id   = n->node_id;
        actx.site_rule = n->fault_rule;   /* [LERR.9.11] */
        actx.fault_handler_site = n->fault_handler;   /* [LERR.9.6] */
        if (!ds_rete_alpha_test_fact(n, fact, &actx)) continue;
        if (n->contract_capacity > 0 &&
            oa_len(&n->memory.map) >= n->contract_capacity) {
            ds_rete_emit_breach(engine, DS_CAP_NODE_CAPACITY,
                                n->contract_capacity,
                                (uint64_t)oa_len(&n->memory.map) + 1u,
                                NULL, 0);
            r = DS_ERR_R(DS_ERR_CONTRACT_BREACH,
                         "alpha: contract per-node capacity exceeded");
            goto unwind;
        }
        r = ds_rete_alpha_mem_insert(&n->memory, fact);
        if (r.status != DS_OK && r.status != DS_ERR_STATE)
            goto unwind;
        if (r.status == DS_ERR_STATE) continue; /* already in memory */
        for (uint32_t b = 0; b < n->beta_output_count; b++) {
            r = ds_rete_beta_right_activate(n->beta_outputs[b], fact, engine);
            if (r.status != DS_OK) goto unwind;
        }
    }
    return DS_OK_R;

unwind:
    /* An all-or-nothing assert: the caller frees the fact on this error, so it
       must leave every alpha memory visited so far. The held completions go
       first: the retract must not find them half-propagated. */
    ds_rete_beta_discard_completions(engine);
    (void)ds_rete_dispatch_retract(engine, fact);
    return r;
}

static ds_result_t dispatch_retract_event(ds_rete_engine_t *engine,
                                          ds_rete_fact_t   *fact)
{
    uint16_t sid = fact->schema->id;
    if (sid >= engine->schema_count) return DS_OK_R;

    ds_rete_dispatch_entry_t *entry = &engine->alpha_dispatch[sid];
    for (uint32_t i = 0; i < entry->count; i++) {
        if (engine->halted) return DS_OK_R;   /* [LERR.1.4.7] */
        ds_rete_alpha_node_t *n = entry->nodes[i];
        ds_result_t r = ds_rete_alpha_mem_remove(&n->memory, fact);
        if (r.status == DS_ERR_NOT_FOUND) continue;
        if (r.status != DS_OK) return r;
        for (uint32_t b = 0; b < n->beta_output_count; b++) {
            r = ds_rete_beta_right_retract(n->beta_outputs[b], fact, engine);
            if (r.status != DS_OK) return r;
        }
    }
    return DS_OK_R;
}
