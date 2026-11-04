/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/fault_fact.h — fault facts ([LERR.9]).
 *
 * Queued, not asserted where raised ([LERR.9.7]): asserting part-way through a
 * propagation would propagate a second fact inside the first. The drain runs
 * before every agenda selection and when a host entry point returns.
 *
 * Latched per site ([LERR.9.5]): at most one live fault fact per schema per
 * `(node, rule)`. The artefact carries the fault schemas as plain explicit
 * schemas with no identity role, so the replacement rule lives here.
 *
 * Never from a handler site ([LERR.9.6]): a rule with any pattern, positive or
 * negated, on either schema. Sites are marked at load, derived from the network.
 *
 * A network built by hand without the schemas asserts nothing ([LERR.9.4]).
 */
#ifndef LIBDS_RETE_FAULT_FACT_H
#define LIBDS_RETE_FAULT_FACT_H

#include <stdbool.h>
#include <stdint.h>

#include "libds.h"

struct ds_rete_engine;

/* Every string is engine-lifetime, so the queue copies none of them. */
typedef struct ds_rete_fault_fact {
    bool        type_error;  /* TypeError; else ComputationError */
    const char *what;        /* ComputationError.kind / TypeError.actual */
    const char *rule;        /* [LERR.9.11]; never NULL */
    const char *schema;      /* NULL if none */
    const char *slot;        /* NULL if none */
    uint32_t    node;
} ds_rete_fault_fact_t;

/* A live fault fact, by site ([LERR.9.5]). `fact_id` is the rete id; a handler
   that `withdraw`s the fact leaves the entry, and the drain finds it not live. */
typedef struct ds_rete_fault_latch {
    bool        type_error;
    uint32_t    node;
    char       *rule;        /* owned copy, compared by content */
    uint32_t    fact_id;
} ds_rete_fault_latch_t;

/* [LERR.9.7]: a later fault at a site already pending replaces it in place. A
   failure to grow the queue drops the fault fact silently: the fault is already
   on the stream. */
void ds_rete_fault_fact_enqueue(struct ds_rete_engine      *engine,
                                const ds_rete_fault_fact_t *fault);

/* In occurrence order. Re-entrant calls return at once. */
ds_result_t ds_rete_fault_fact_drain(struct ds_rete_engine *engine);

/* Once the network is wired. */
void ds_rete_fault_fact_mark_handlers(struct ds_rete_engine *engine);

/* [LERR.9.10]: size the latch table and the queue at the site count, so neither
   grows during a pump. The latch's owned rule copy still allocates on a site's
   first fault. */
ds_result_t ds_rete_fault_fact_reserve(struct ds_rete_engine *engine);

void ds_rete_fault_fact_free(struct ds_rete_engine *engine);

/* The source's latch table: a clone keeps its fact ids. The queue is empty between
   API calls. */
ds_result_t ds_rete_fault_fact_clone(struct ds_rete_engine       *dst,
                                     const struct ds_rete_engine *src);

#endif /* LIBDS_RETE_FAULT_FACT_H */
