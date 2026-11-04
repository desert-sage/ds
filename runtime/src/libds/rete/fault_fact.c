/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/fault_fact.c — fault facts ([LERR.9]).
 */
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "ds_alloc.h"

#include "rete/alpha.h"
#include "rete/beta.h"
#include "rete/engine.h"
#include "rete/fault_fact.h"
#include "rete/intern.h"
#include "rete/schema_reg.h"
#include "rete/terminal.h"
#include "rete/val.h"
#include "rete/wm_rete.h"
#include "rfcs/rfcs.h"

extern ds_result_t ds_engine_retract_rete_fact(struct ds_rete_engine *re,
                                               struct ds_rete_fact   *rfact,
                                               uint8_t                cause);

static const char CE_NAME[] = "ComputationError";
static const char TE_NAME[] = "TypeError";

/* In place, whichever schema either is, so the queue keeps the order sites first
   faulted and is bounded by the site count ([LERR.9.10]). Rule names compare by
   content: a node's stored string, a terminal's interned one. */
void ds_rete_fault_fact_enqueue(ds_rete_engine_t           *engine,
                                const ds_rete_fault_fact_t *fault)
{
    if (engine == NULL || fault == NULL) return;
    for (uint32_t i = 0; i < engine->fault_queue_n; i++) {
        ds_rete_fault_fact_t *p = &engine->fault_queue[i];
        if (p->node == fault->node && strcmp(p->rule, fault->rule) == 0) {
            *p = *fault;
            return;
        }
    }
    if (engine->fault_queue_n == engine->fault_queue_cap) {
        uint32_t ncap = engine->fault_queue_cap ? engine->fault_queue_cap * 2u
                                                : 4u;
        ds_rete_fault_fact_t *nq =
            DS_REALLOC(engine->fault_queue, ncap * sizeof(*nq));
        if (nq == NULL) return;
        engine->fault_queue     = nq;
        engine->fault_queue_cap = ncap;
    }
    engine->fault_queue[engine->fault_queue_n++] = *fault;
}

/* NULL when the program does not carry it. */
static const ds_rete_schema_t *fault_schema(const ds_rete_engine_t *engine,
                                            bool                    type_error)
{
    const char *name = type_error ? TE_NAME : CE_NAME;
    const char *interned = NULL;
    if (ds_rete_intern_find(engine->intern, name, strlen(name), &interned)
            .status != DS_OK || interned == NULL)
        return NULL;
    return ds_rete_schema_by_name(engine, interned);
}

static int slot_named(const ds_rete_schema_t *schema, const char *name)
{
    for (uint16_t i = 0; i < schema->slot_count; i++)
        if (schema->slots[i].name != NULL
            && strcmp(schema->slots[i].name, name) == 0)
            return (int)i;
    return -1;
}

/* An absent name is the empty string: the slots are non-null Strings ([LERR.9.2]). */
static ds_result_t str_val(ds_rete_engine_t *engine, const char *s,
                           ds_rete_val_t *out)
{
    const char *p = NULL;
    ds_result_t r = ds_rete_intern_value_cstr(engine->intern, s ? s : "", &p);
    if (r.status != DS_OK) return r;
    *out = ds_rete_val_str(p, (uint32_t)strlen(p));
    return DS_OK_R;
}

/* By content: the fact's `rule` is a counted interned string, freed when a handler
   withdraws the fact, so the address may later hold another text. */
static ds_rete_fault_latch_t *latch_for(ds_rete_engine_t *engine,
                                        bool type_error, uint32_t node,
                                        const char *rule)
{
    for (uint32_t i = 0; i < engine->fault_latch_n; i++) {
        ds_rete_fault_latch_t *l = &engine->fault_latch[i];
        if (l->type_error == type_error && l->node == node
            && strcmp(l->rule, rule) == 0)
            return l;
    }
    return NULL;
}

static char *copy_str(const char *s)
{
    const size_t n = strlen(s) + 1u;
    char *c = DS_MALLOC(n);
    if (c != NULL) memcpy(c, s, n);
    return c;
}

static ds_result_t latch_set(ds_rete_engine_t *engine, bool type_error,
                             uint32_t node, const char *rule, uint32_t fact_id)
{
    ds_rete_fault_latch_t *l = latch_for(engine, type_error, node, rule);
    if (l == NULL) {
        if (engine->fault_latch_n == engine->fault_latch_cap) {
            uint32_t ncap = engine->fault_latch_cap
                ? engine->fault_latch_cap * 2u : 4u;
            ds_rete_fault_latch_t *nl =
                DS_REALLOC(engine->fault_latch, ncap * sizeof(*nl));
            if (nl == NULL)
                return DS_ERR_R(DS_ERR_OOM, "fault fact: latch table");
            engine->fault_latch     = nl;
            engine->fault_latch_cap = ncap;
        }
        char *own = copy_str(rule);
        if (own == NULL)
            return DS_ERR_R(DS_ERR_OOM, "fault fact: latch rule");
        l = &engine->fault_latch[engine->fault_latch_n++];
        l->type_error = type_error;
        l->node       = node;
        l->rule       = own;
    }
    l->fact_id = fact_id;
    return DS_OK_R;
}

/* Strings are interned, so equal content is an equal pointer. */
static bool same_slots(const ds_rete_fact_t *live, const ds_rete_val_t *slots,
                       uint16_t n)
{
    for (uint16_t i = 0; i < n; i++) {
        const ds_rete_val_t *a = &live->slots[i], *b = &slots[i];
        if (a->kind != b->kind) return false;
        if (a->kind == DS_RETE_VAL_STR) {
            if (a->s.ptr != b->s.ptr) return false;
        } else if (a->kind == DS_RETE_VAL_INT) {
            if (a->i != b->i) return false;
        } else {
            return false;
        }
    }
    return true;
}

static void release_held(ds_rete_engine_t *engine, const ds_rete_val_t *slots)
{
    for (int i = 0; i < 5; i++)
        if (slots[i].kind == DS_RETE_VAL_STR)
            ds_rete_intern_release(engine->intern, slots[i].s.ptr,
                                   slots[i].s.len);
}

static ds_result_t assert_one(ds_rete_engine_t           *engine,
                              const ds_rete_fault_fact_t *f)
{
    const ds_rete_schema_t *schema = fault_schema(engine, f->type_error);
    if (schema == NULL) return DS_OK_R;

    const int i_what = slot_named(schema, f->type_error ? "actual" : "kind");
    const int i_rule = slot_named(schema, "rule");
    const int i_sch  = slot_named(schema, "schema");
    const int i_slot = slot_named(schema, "slot");
    const int i_node = slot_named(schema, "node");
    if (i_what < 0 || i_rule < 0 || i_sch < 0 || i_slot < 0 || i_node < 0
        || schema->slot_count != 5)
        return DS_OK_R;

    ds_rete_val_t slots[5];
    ds_result_t r;
    if ((r = str_val(engine, f->what, &slots[i_what])).status != DS_OK) return r;
    if ((r = str_val(engine, f->rule, &slots[i_rule])).status != DS_OK) return r;
    if ((r = str_val(engine, f->schema, &slots[i_sch])).status != DS_OK) return r;
    if ((r = str_val(engine, f->slot, &slots[i_slot])).status != DS_OK) return r;
    slots[i_node] = ds_rete_val_int((int64_t)f->node);
    const char *rule = slots[i_rule].s.ptr;

    ds_rete_fault_latch_t *l = latch_for(engine, f->type_error, f->node, rule);
    ds_rete_fact_t *live = l ? ds_rete_wm_find_by_id(engine, l->fact_id) : NULL;
    bool held = false;
    if (live != NULL && live->schema == schema) {
        if (same_slots(live, slots, 5))
            return DS_OK_R;   /* a suppressed no-op, as [LFAC.2.5.1]'s is */
        /* Hold the new slots across the retract: str_val takes no reference, so
           a string the live fact holds would be freed with it before the assert
           takes its own. */
        for (int i = 0; i < 5; i++)
            if (slots[i].kind == DS_RETE_VAL_STR)
                ds_rete_intern_acquire_ptr(engine->intern, slots[i].s.ptr,
                                           slots[i].s.len);
        held = true;
        r = ds_engine_retract_rete_fact(engine, live, DS_FWTH_CAUSE_SUPERSEDED);
        if (r.status != DS_OK) {
            release_held(engine, slots);
            return r;
        }
        /* [LERR.1.4.7] */
        if (engine->halted) {
            release_held(engine, slots);
            return DS_OK_R;
        }
    }

    ds_rete_fact_t *fact = NULL;
    r = ds_rete_wm_assert(engine, schema->id, slots, &fact);
    if (held) release_held(engine, slots);
    if (r.status != DS_OK || fact == NULL) return r;
    r = latch_set(engine, f->type_error, f->node, rule, fact->id);
    if (r.status != DS_OK) return r;

    /* Recorded as a rule's `emit` is ([LERR.9.8]). The recorder reads the rule from
       `current_fire_rule`, NULL between firings, where every drain runs. */
    const char *prev_rule = engine->current_fire_rule;
    engine->current_fire_rule = rule;
    ds_rete_emit_cb_t cb = engine->adapter.emit_cb;
    if (cb) cb(engine, fact, engine->adapter.emit_user);
    ds_rete_emit_cb_t mcb = engine->adapter.emit_action_cb;
    if (mcb) mcb(engine, fact, engine->adapter.emit_action_user);
    engine->current_fire_rule = prev_rule;
    return DS_OK_R;
}

ds_result_t ds_rete_fault_fact_drain(ds_rete_engine_t *engine)
{
    if (engine == NULL || engine->fault_draining) return DS_OK_R;
    if (engine->fault_queue_n == 0) return DS_OK_R;
    engine->fault_draining = true;
    ds_result_t first = DS_OK_R;
    /* An index, not a pop: an assertion may append. */
    for (uint32_t i = 0; i < engine->fault_queue_n; i++) {
        /* [LERR.1.4.7]: the rest of the queue is dropped below. */
        if (engine->halted) break;
        const ds_rete_fault_fact_t f = engine->fault_queue[i];
        ds_result_t r = assert_one(engine, &f);
        if (r.status != DS_OK && first.status == DS_OK) first = r;
    }
    engine->fault_queue_n  = 0;
    engine->fault_draining = false;
    return first;
}

/* ---- handler sites ([LERR.9.6]) -------------------------------------- */

static bool alpha_is_fault(const ds_rete_engine_t     *engine,
                           const ds_rete_alpha_node_t *a)
{
    if (a == NULL) return false;
    const ds_rete_schema_t *s = ds_rete_schema_by_id(engine, a->schema_id);
    return s != NULL && s->name != NULL
        && (strcmp(s->name, CE_NAME) == 0 || strcmp(s->name, TE_NAME) == 0);
}

/* A negated pattern is a beta over the same alpha, so one walk covers both. */
static bool chain_is_handler(const ds_rete_engine_t    *engine,
                             const ds_rete_beta_node_t *b)
{
    for (; b != NULL; b = b->left_parent)
        if (alpha_is_fault(engine, b->right_alpha)) return true;
    return false;
}

static void mark_chain(ds_rete_beta_node_t *b)
{
    for (; b != NULL; b = b->left_parent) {
        b->fault_handler = true;
        if (b->right_alpha != NULL) b->right_alpha->fault_handler = true;
    }
}

void ds_rete_fault_fact_mark_handlers(ds_rete_engine_t *engine)
{
    if (engine == NULL) return;
    for (uint32_t i = 0; i < engine->owned_beta_count; i++) {
        ds_rete_beta_node_t *b = engine->owned_betas[i];
        if (b == NULL || b->terminal_child_count == 0) continue;
        if (!chain_is_handler(engine, b)) continue;
        mark_chain(b);
        for (uint32_t t = 0; t < b->terminal_child_count; t++)
            if (b->terminal_children[t] != NULL)
                b->terminal_children[t]->fault_handler = true;
    }
}

/* ---- the pool ([LERR.9.10]) ------------------------------------------ */

ds_result_t ds_rete_fault_fact_reserve(ds_rete_engine_t *engine)
{
    if (engine == NULL || engine->fault_fact_sites == 0) return DS_OK_R;
    if (engine->fault_latch_cap < engine->fault_fact_sites) {
        ds_rete_fault_latch_t *nl = DS_REALLOC(engine->fault_latch,
            (size_t)engine->fault_fact_sites * sizeof(*nl));
        if (nl == NULL)
            return DS_ERR_R(DS_ERR_OOM, "fault fact: latch table reserve");
        engine->fault_latch     = nl;
        engine->fault_latch_cap = engine->fault_fact_sites;
    }
    if (engine->fault_queue_cap < engine->fault_fact_sites) {
        ds_rete_fault_fact_t *nq = DS_REALLOC(engine->fault_queue,
            (size_t)engine->fault_fact_sites * sizeof(*nq));
        if (nq == NULL)
            return DS_ERR_R(DS_ERR_OOM, "fault fact: queue reserve");
        engine->fault_queue     = nq;
        engine->fault_queue_cap = engine->fault_fact_sites;
    }
    return DS_OK_R;
}

void ds_rete_fault_fact_free(ds_rete_engine_t *engine)
{
    if (engine == NULL) return;
    DS_FREE(engine->fault_queue);
    engine->fault_queue = NULL;
    engine->fault_queue_n = engine->fault_queue_cap = 0;
    for (uint32_t i = 0; i < engine->fault_latch_n; i++)
        DS_FREE(engine->fault_latch[i].rule);
    DS_FREE(engine->fault_latch);
    engine->fault_latch = NULL;
    engine->fault_latch_n = engine->fault_latch_cap = 0;
}

ds_result_t ds_rete_fault_fact_clone(ds_rete_engine_t       *dst,
                                     const ds_rete_engine_t *src)
{
    if (dst == NULL || src == NULL) return DS_OK_R;
    if (src->fault_latch_n == 0) return DS_OK_R;
    dst->fault_latch = DS_CALLOC(src->fault_latch_n, sizeof(*dst->fault_latch));
    if (dst->fault_latch == NULL)
        return DS_ERR_R(DS_ERR_OOM, "fault fact: clone latch table");
    dst->fault_latch_cap = src->fault_latch_n;
    for (uint32_t i = 0; i < src->fault_latch_n; i++) {
        ds_rete_fault_latch_t *d = &dst->fault_latch[i];
        *d = src->fault_latch[i];
        d->rule = copy_str(src->fault_latch[i].rule);
        if (d->rule == NULL) {
            dst->fault_latch_n = i;
            return DS_ERR_R(DS_ERR_OOM, "fault fact: clone latch rule");
        }
        dst->fault_latch_n = i + 1u;
    }
    return DS_OK_R;
}
