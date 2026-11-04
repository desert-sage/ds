/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/fact.h — fact representation (IRET.4.3-4.5).
 */
#ifndef LIBDS2_INTERNAL_RETE_FACT_H
#define LIBDS2_INTERNAL_RETE_FACT_H

#include <stdbool.h>
#include <stdint.h>

#include "rete/pool.h"
#include "rete/schema.h"
#include "rete/val.h"

/*
 * id:           never reused within a session.
 * deadline_ns:  for TTL facts; 0 = no deadline.
 * justif_count: TMS refcount; non-zero only for logical-scoped facts.
 * series_absorbed: set by the end-of-pump absorber and never reset, so a fact
 *                  gives one sample and a no-op reassert none.
 */
typedef struct ds_rete_fact {
    uint32_t                 id;
    const ds_rete_schema_t  *schema;
    int64_t                  assert_ns;
    int64_t                  deadline_ns;
    uint32_t                 justif_count;
    bool                     series_absorbed;
    /* Non-NULL when this fact was allocated from a pool. */
    ds_rete_pool_t          *owner_pool;
    /* Position in the deadline min-heap; UINT32_MAX is not in it. */
    uint32_t                 deadline_heap_idx;
    /* The per-schema FIFO TTL queue (LDTL.1.1 default mode), used when
       cap_dynamic_ttl is false. NULL when the fact is in no queue. */
    struct ds_rete_fact     *fifo_next; /* next to expire (newer) */
    struct ds_rete_fact     *fifo_prev; /* previous to expire (older) */
    ds_rete_val_t            slots[]; /* flexible array member */
} ds_rete_fact_t;

#endif /* LIBDS2_INTERNAL_RETE_FACT_H */
