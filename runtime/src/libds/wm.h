/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * wm.h — the working-memory bridge: ds_fact_t's allocation and lifetime, and the mapping
 * from Rete facts to wrappers ([IARC.3.3], [IDAT.4]).
 */
#ifndef LIBDS2_INTERNAL_WM_H
#define LIBDS2_INTERNAL_WM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "libds.h"
#include "oa.h"

struct ds_engine;
struct ds_schema;

struct ds_fact {
    uint64_t                fact_id;
    const struct ds_schema *schema;
    void                   *rete_fact;      /* ds_rete_fact_t *, and the key in the
                                                 tracking table */
    uint32_t                rete_id;         /* to detect pool-reuse of a Rete fact
                                                 slot */
    struct ds_engine       *engine;          /* non-owning */
    uint64_t                asserted_ns;     /* engine clock at assert time */
    /* [RFCS.23.5]: what a fact needs to leave the engine as a FactExternal.

       assert_seq: the `seq` of this fact's first FactAssert record, from which `event_id`
       derives ([LFST.5.6]), stamped when that record is numbered.

       asserted_wall_ns: the held wall sample when the fact entered working memory, UTC ns;
       asserted_wall_set is false when the wall clock had no value ([LTIM.2.8.3]). */
    uint64_t                assert_seq;
    int64_t                 asserted_wall_ns;
    bool                    assert_seq_set;
    bool                    asserted_wall_set;
    uint64_t                ttl_deadline_ns; /* 0 for logical-schema facts */
    uint32_t                n_slots;
    /* Set when a rule produced this fact, by nothing else. It cannot be inferred from
       being inside a firing: a synchronous call callback asserts on the pump stack. */
    bool                    rule_emitted;
    /* [NCBK.2.5]: a `publish`'s view (ds_wm_publish_view), in no working
       memory, with no rete fact. A fact-ref slot resolves through the id
       index. */
    bool                    publish_view;
    struct ds_fact         *schema_prev;
    struct ds_fact         *schema_next;
    /* The live facts with a non-zero ttl_deadline_ns, off ds_wm_state.deadline_head. Keyed
       on the deadline, not the lifecycle: an override wins regardless ([LHYD.10.5.1]). */
    struct ds_fact         *deadline_prev;
    struct ds_fact         *deadline_next;
    bool                    in_deadline_list;
    ds_slot_value_t         slots[];         /* must be last */
};

struct ds_rete_intern;

typedef struct ds_wm_state {
    struct ds_engine *engine;   /* non-owning */

    /* [IRET.1.4]: a wrapper holds one intern reference on a value it borrowed from a rete
       fact, so the value survives a buffered cascade retract read after the rete fact
       has gone. Non-owning. */
    struct ds_rete_intern *intern;

    oa_t        table;          /* key=rete_fact*, val=ds_fact_t* (owning) */

    /* [NFCT.6.4]: the same live facts. A detached wrapper is not found: it is no longer
       live. */
    oa_t        by_id;          /* key=uint64_t fact_id, val=ds_fact_t* */

    struct ds_fact *deadline_head;

    /* A literal or an engine-lifetime borrow. */
    const char *retract_reason;

    /* The same retraction, typed, for the FactWithdraw atom's Cause ([RFCS.7a]):
       DS_FWTH_CAUSE_* in rfcs/rfcs.h. 0 is UNSPECIFIED, which the encoder refuses. Set with
       retract_reason at the originating site, never at the shared bridge, under the same
       prev/set/restore scoping: a FactWithdraw naming the wrong cause is well-formed, so
       nothing downstream would catch it. */
    uint8_t     retract_cause;

    /* [RFCS.6.7]: the FactAssert being emitted is a host input, though its wrapper may say
       a rule produced the fact. Set by the bridge's no-op arm alone, around its emit. */
    bool        assert_from_host;

    /* [IDSP.9.5], [LHYD.6.2]: zero outside ds_engine_assert_with_ttl. */
    uint64_t    ttl_override_ns;

    uint8_t    *fact_slab;       /* raw slab; NULL = pool not active */
    size_t      fact_stride;     /* bytes per wrapper slot (max schema size) */
    uint32_t    fact_pool_cap;   /* total wrapper slots in slab */
    ds_fact_t **fact_free_stack; /* stack of free slot pointers */
    uint32_t    fact_free_n;     /* number of items on free stack */
} ds_wm_state_t;

ds_result_t ds_wm_init(ds_wm_state_t *wm, struct ds_engine *engine);

/* Pre-allocates n wrapper slots of stride bytes each, so entities in RT mode never call
   malloc. */
ds_result_t ds_wm_init_rt_pool(ds_wm_state_t *wm, uint32_t n, size_t stride);

ds_result_t ds_wm_destroy(ds_wm_state_t *wm);

/* The schema and rete_fact are borrowed. slots[] are zero-initialised, and callers
   populate them before publishing the fact. */
ds_result_t ds_wm_fact_new(ds_wm_state_t          *wm,
                           const struct ds_schema *schema,
                           void                   *rete_fact,
                           ds_fact_t             **out);

/* For the rete bridge, which assigns ttl_deadline_ns after the wrapper is tracked: without
   this, such a wrapper is never swept. Idempotent, and a no-op when ttl_deadline_ns is 0. */
void ds_wm_deadline_track(ds_wm_state_t *wm, ds_fact_t *fact);

/* `fact` must still be live: this reads fact->rete_fact, so a second call on one wrapper is
   an undetected use-after-free. DS_ERR_NOT_FOUND means this live wrapper is not tracked
   here, never that it was already freed. */
ds_result_t ds_wm_fact_free(ds_wm_state_t *wm, ds_fact_t *fact);

/* A wrapper already detached (ds_wm_fact_detach): no second table removal. Safe on NULL. */
void ds_wm_fact_release_detached(ds_wm_state_t *wm, ds_fact_t *fact);

/* Writes NULL to *out when not tracked. */
ds_result_t ds_wm_fact_lookup(const ds_wm_state_t  *wm,
                              void                 *rete_fact,
                              ds_fact_t           **out);

/* [NFCT.6.4]: or NULL. */
ds_fact_t *ds_wm_fact_by_id(const ds_wm_state_t *wm, uint64_t fact_id);

/* For a wrapper the clone inserted into `table` directly. DS_ERR_OOM leaves the index
   unchanged. */
ds_result_t ds_wm_index_id(ds_wm_state_t *wm, ds_fact_t *fact);

static inline ds_result_t ds_wm_fact_from_rete_fact(
    ds_wm_state_t *wm, void *rete_fact, ds_fact_t **out)
{
    return ds_wm_fact_lookup(wm, rete_fact, out);
}

/* A wrapper's DS_SLOT_FACT_REF slot holds the target's fact_id, in `v.i`, never a
   ds_fact_t *: a fact_id is never reused. The public `v.ref` exists only on the way in and
   on the way out. Only these two touch the representation. 0 means no target; ids start
   at 1. */
static inline uint64_t ds_wm_slot_ref_id(const ds_slot_value_t *v)
{
    return (uint64_t) v->v.i;
}

static inline ds_slot_value_t ds_wm_slot_of_ref_id(uint64_t target_fact_id)
{
    ds_slot_value_t v;
    v.kind = DS_SLOT_FACT_REF;
    v.v.i  = (int64_t) target_fact_id;
    return v;
}

/* The live target, or NULL once it has left working memory. Defined in wm_rete_bridge.c,
   which sees both layers. */
ds_fact_t *ds_wm_fact_ref_resolve(const ds_fact_t *referrer, uint32_t index);

ds_result_t ds_wm_fact_count(const ds_wm_state_t *wm, size_t *out);

/* For libds's own reads: each is its public namesake less the halt-latch check
   ([NCBK.2.9]). */
ds_result_t ds_fact_get_id_unchecked(const ds_fact_t *fact, uint64_t *out);
ds_result_t ds_fact_get_schema_unchecked(const ds_fact_t          *fact,
                                          const struct ds_schema **out);
ds_result_t ds_fact_get_asserted_ns_unchecked(const ds_fact_t *fact,
                                               uint64_t        *out);
ds_result_t ds_fact_get_ttl_deadline_ns_unchecked(const ds_fact_t *fact,
                                                   uint64_t        *out);
ds_result_t ds_fact_get_slot_count_unchecked(const ds_fact_t *fact,
                                              uint32_t        *out);
ds_result_t ds_fact_get_slot_unchecked(const ds_fact_t *fact,
                                        uint32_t          index,
                                        const char      **out_name,
                                        ds_slot_value_t  *out_value);
ds_result_t ds_fact_get_slot_ref_id_unchecked(const ds_fact_t *fact,
                                              uint32_t         index,
                                              uint64_t        *out);

/* [LTIM.10.9]: why a `TimeZoneOffset` row is malformed, or NULL for a well-formed row and
   for any other schema. */
const char *ds_wm_tz_row_malformed(const struct ds_schema *schema,
                                   const ds_slot_value_t  *values,
                                   uint32_t                n_values);

#endif /* LIBDS2_INTERNAL_WM_H */
