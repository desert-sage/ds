/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/wm_rete.h — working memory operations (IRET.19).
 */
#ifndef LIBDS2_INTERNAL_RETE_WM_RETE_H
#define LIBDS2_INTERNAL_RETE_WM_RETE_H

#include <stdbool.h>
#include <stdint.h>

#include "libds.h"
#include "rete/engine.h"
#include "rete/fact.h"
#include "rete/val.h"

/*
 * IRET.19.1. *out is the live fact: the standing one when a no-op reassertion
 * is suppressed. DS_ERR_NOT_FOUND for an unknown schema_id.
 */
ds_result_t ds_rete_wm_assert(ds_rete_engine_t    *engine,
                                uint16_t             schema_id,
                                const ds_rete_val_t *slot_values,
                                ds_rete_fact_t     **out);

/*
 * Whether a fact of `schema` entered at `now_ns` has its deadline inside the
 * `Time` range ([LTIM.1.1.5]): the engine's pending override, else the schema's
 * TTL, added to the stamp. A fact with no deadline is in range. Every door asks
 * it: the host's assert refuses with DS_ERR_TIME_RANGE ([RFCS.6.7]), a rule's
 * `emit` or `publish` raises NOT_REPRESENTABLE, and ds_rete_wm_assert_ex refuses
 * rather than wrap.
 */
bool ds_rete_deadline_in_range(const ds_rete_engine_t *engine,
                               const ds_rete_schema_t *schema,
                               int64_t                 now_ns);

/*
 * As ds_rete_wm_assert; *out_replaced is the fact an identity update replaced,
 * else NULL. It is freed by then: a key for ds_wm_fact_lookup, never
 * dereferenced.
 */
ds_result_t ds_rete_wm_assert_ex(ds_rete_engine_t    *engine,
                                  uint16_t             schema_id,
                                  const ds_rete_val_t *slot_values,
                                  ds_rete_fact_t     **out,
                                  ds_rete_fact_t     **out_replaced);

/*
 * Finish the supersede the last assert left pending (supersede_old) with no
 * successor to record: the old fact's FACT_RETRACT, cause SUPERSEDED, then the
 * activation facts waiting on it (RFCS.6a.4). For a caller that failed before its
 * emit_cb wrapped the new fact. A no-op when nothing is pending.
 */
void ds_rete_wm_settle_supersede(ds_rete_engine_t *engine);

/*
 * The first slot `schema` does not admit, or -1: a kind the type does not accept
 * (RARC.5.2.6), `null` outside `T?` ([LNUL.3.1]), or a NaN ([LEXP.4.2]); kind
 * and null over every slot first, then NaN. ds_rete_wm_assert refuses the same
 * with DS_ERR_SLOT_TYPE_MISMATCH or DS_ERR_NAN_REJECTED; a rule's action asks
 * first, so its refusal is a TypeError (RARC.5.2.7).
 */
int32_t ds_rete_slot_refused(const ds_rete_schema_t *schema,
                             const ds_rete_val_t    *slot_values);

/*
 * The no-op reassertion's comparison ([LFAC.2.5.1], [LFAC.2.5.4]), under each
 * slot's tolerance, and [RFCS.23.7]'s "equal". A String compares by interned
 * pointer, a fact reference by its target's rete id; Json and Bytes are never
 * equal.
 */
bool ds_rete_slots_equal(const ds_rete_schema_t *schema,
                         const ds_rete_val_t    *a,
                         const ds_rete_val_t    *b);

/*
 * Every `Json` slot's root-null document becomes the canonical null
 * ([LNUL.3.4]), and every `Duration` slot's negative count 0 ([NFCT.2.3]). Called
 * before ds_rete_slot_refused. Nothing is freed: a replaced value is a borrow or
 * an Int.
 */
void ds_rete_lnul_3_4_canonical(const ds_rete_schema_t *schema,
                                ds_rete_val_t          *slot_values);

/* IRET.19.2. Frees the fact, unless the engine is halted. */
ds_result_t ds_rete_wm_retract(ds_rete_engine_t *engine,
                                 ds_rete_fact_t   *fact);

size_t ds_rete_wm_count(const ds_rete_engine_t *engine);

/* NULL when the fact is not live. */
ds_rete_fact_t *ds_rete_wm_find_by_id(const ds_rete_engine_t *engine,
                                        uint32_t                id);

/* visitor returns non-zero to stop. */
int ds_rete_wm_for_each(const ds_rete_engine_t *engine,
                          int (*visitor)(ds_rete_fact_t *fact, void *ctx),
                          void *ctx);

/*
 * Retract every fact whose nonzero deadline_ns is at or before now_ns: the
 * rule-emitted facts with no DS wrapper, after the pump's wrapper sweep.
 * out_retracted may be NULL. The first failing retract's status.
 */
ds_result_t ds_rete_wm_tick_ttl(ds_rete_engine_t *engine,
                                  int64_t            now_ns,
                                  size_t            *out_retracted);

ds_result_t ds_rete_wm_presz(ds_rete_engine_t *engine, size_t cap);
ds_result_t ds_rete_wm_rebuild_id_hashes(ds_rete_engine_t *engine, size_t cap);

/* Identity tuple -> fact*. Safe to query for a schema that does not dedup. */
void ds_rete_schema_id_map_init(ds_rete_schema_t *s);

/*
 * The live fact whose key tuple ([LFAC.1.7]) matches `slot_values`, a slot array
 * of which only the key positions are read. A key=∅ schema answers its one fact;
 * a schema that does not dedup answers NULL. Strings compare by interned
 * pointer, so a key never interned answers NULL: NULL means "not found" only
 * when the key was interned.
 */
ds_rete_fact_t *ds_rete_wm_find_by_identity(ds_rete_engine_t       *e,
                                            const ds_rete_schema_t *schema,
                                            const ds_rete_val_t    *slot_values);

/* [LSTR.11.3]: `len` bytes of well-formed text are longer, in codepoints, than
 * slot `slot`'s `capacity`. No bound is 0. A delivery's plan asks this
 * ([NCBK.10.4]); it raises nothing, so the caller says what follows. */
bool ds_rete_slot_over_capacity(const ds_rete_schema_t *schema, uint16_t slot,
                                const char *text, size_t len);

/* [LSTR.11.3]: the first `String` in `slot_values` longer than its slot's
 * `capacity` records the BoundsError naming CAP_VALUE_CAPACITY and answers
 * DS_ERR_CONTRACT_BREACH; DS_OK when every value fits. Working memory's door
 * and a `publish` both ask it ([LTIE.4.8]). */
ds_result_t ds_rete_capacity_refused(ds_rete_engine_t       *engine,
                                     const ds_rete_schema_t *schema,
                                     const ds_rete_val_t    *slot_values);

/* fact->id -> fact*. */
void ds_rete_wm_map_init(ds_rete_engine_t *e);

/*
 * `zone` at `utc_ns` ([LTIM.10.7]): "UTC" is 0 with no fact read ([LTIM.10.8]);
 * any other zone answers by the live `TimeZoneOffset` with the greatest
 * `valid_from` not after `utc_ns`, while its `valid_until` is after it. False
 * when nothing answers: a DOMAIN fault ([LTIM.10.5.3]). O(log r) in the zone's
 * facts.
 */
bool ds_rete_tz_resolve(const ds_rete_engine_t *engine, const char *zone,
                        uint32_t len, int64_t utc_ns, int32_t *out_offset_s);

/* Zones with a live row. */
uint32_t ds_rete_tz_zone_count(const ds_rete_engine_t *engine);

void ds_rete_tz_index_free(ds_rete_engine_t *engine);

#endif /* LIBDS2_INTERNAL_RETE_WM_RETE_H */
