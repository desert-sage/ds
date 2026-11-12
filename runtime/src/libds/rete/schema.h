/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/schema.h — schema and slot descriptor types (IRET.4.1-4.2).
 */
#ifndef LIBDS2_INTERNAL_RETE_SCHEMA_H
#define LIBDS2_INTERNAL_RETE_SCHEMA_H

#include <stdbool.h>
#include <stdint.h>

#include "oa.h"
#include "rete/val.h"

/* Schema scope per IRET.4.2 / LSCP */
typedef enum {
    DS_RETE_SCOPE_PLAIN      = 0,  /* scope explicit (default) */
    DS_RETE_SCOPE_LOGICAL    = 1,  /* scope logical            */
    DS_RETE_SCOPE_TTL        = 2,  /* scope ttl <dur>          */
    DS_RETE_SCOPE_ACTIVATION = 3,  /* scope activation (LSCP.2.4) */
    DS_RETE_SCOPE_AMBIENT    = 4,  /* scope ambient    (LSCP.2.5) */
} ds_rete_scope_t;

/* Slot descriptor per IRET.4.1 */
typedef struct {
    const char         *name;        /* interned */
    uint16_t            index;       /* position in fact's slot array */
    ds_rete_val_kind_t  type;
    double              tolerance;   /* 0.0 = exact; >0 only for INT/FLOAT */
    bool                sampled;
    bool                retained;
    bool                is_key;      /* LFAC.1.7 — part of the identity key */
    bool                is_marked;   /* LFAC.1.7 — carries an explicit identity
                                        role. Tells a logical schema, which
                                        dedups, from an explicit one, which
                                        accumulates: both are SchemaLogical. */
    bool                is_engine;   /* LFAC.9.1 — `ts` on a logical schema
                                        (IDENTITY_ROLE_ENGINE): outside the
                                        identity key and outside the no-op
                                        comparison (slots_equal). */
    bool                nullable;    /* [LNUL.3.1] — mirrors
                                        ds_slot_desc_t.nullable for the
                                        assert-time typing check in
                                        ds_rete_wm_assert_ex. */
    bool                duration;    /* [NFCT.2.3] — the slot was declared
                                        `Duration`, which `type` carries as
                                        INT. A negative value is stored as 0
                                        on a rule's path as at the host's door
                                        (ds_rete_lnul_3_4_canonical). */
    bool                time;        /* [LTIM.1.1.3] — the slot was declared
                                        `Time`, which `type` carries as INT. A
                                        read yields a TIME at offset 0 (eval.c's
                                        slot_read). */
    uint32_t            capacity;    /* [LSTR.11.1] — a `String` slot's
                                        declared `capacity`, in codepoints;
                                        0 = none (Slot field 12). Checked at
                                        ds_rete_wm_assert_ex beside the kind,
                                        for the same reason as `nullable`. */
    /* [RDSC.5.5.9] — a slot that names a unit: its two conversions, each over
       `bind_ref` 0, both or neither (Slot fields 13 and 14). Owned by the
       registered schema; ds_schema_slot_to_stored and _from_stored evaluate
       them ([NFCT.1.4.6]). */
    struct ds_rete_expr *to_stored;
    struct ds_rete_expr *from_stored;
} ds_rete_slot_desc_t;

/* Schema descriptor per IRET.4.2 */
typedef struct ds_rete_fact ds_rete_fact_t_fwd; /* fwd ref for id_buckets */
typedef struct {
    const char          *name;           /* interned */
    uint16_t             id;             /* compact schema index */
    uint16_t             slot_count;
    ds_rete_scope_t      scope;
    int64_t              default_ttl_ns; /* 0 when scope != SCOPE_TTL */
    ds_rete_slot_desc_t *slots;          /* flat array [slot_count]; owned */

    /* The identity-key map (LFAC.1.7). id_dedup: this schema dedups by identity
     * (logical or ambient scope). id_key_count 0 with id_dedup is the singleton;
     * id_key_count == slot_count is the relation case.
     * id_map: key ds_rete_val_t* (a slots pointer; ctx = this schema), value
     * ds_rete_fact_t*. */
    bool                 id_dedup;
    uint16_t            *id_key_slots;  /* owned; length id_key_count */
    uint16_t             id_key_count;
    oa_t                 id_map;

    /* The FIFO TTL queue (LDTL.1.1 default mode), used when cap_dynamic_ttl is
     * false: the TTL is fixed per schema, so assertion order is expiry order.
     * The head expires first. */
    struct ds_rete_fact *ttl_fifo_head;
    struct ds_rete_fact *ttl_fifo_tail;

    /* [LERR.9.4]: `ComputationError` or `TypeError`. Their facts are the
     * fault-fact pool's and never count against `wm_max` ([LERR.9.10]):
     * wm_rete.c keeps `fault_fact_live` from this flag. */
    bool                 fault_fact;

    /* [LTIM.10.6]: the built-in `TimeZoneOffset`, whose facts are the zone
     * index's ([LTIM.10.7]): wm_rete.c keeps the index from this flag. Its
     * slots are zone, valid_from, valid_until, offset_s, in that order
     * ([LIMP.12.2] declares it exactly so). */
    bool                 tz_offset;
} ds_rete_schema_t;

#endif /* LIBDS2_INTERNAL_RETE_SCHEMA_H */
