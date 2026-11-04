/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/tms.h — truth maintenance dependency table (IRET.12).
 *
 * Activation timetag -> the fact ids of the logical facts it asserted.
 */
#ifndef LIBDS2_INTERNAL_RETE_TMS_H
#define LIBDS2_INTERNAL_RETE_TMS_H

#include <stdint.h>

#include "libds.h"
#include "oa.h"

#define DS_TMS_INLINE 16u

/* Memcpy-relocatable across an oa grow; the map's val_dtor frees heap_ids. */
typedef struct {
    const char  *rule_name;            /* interned */
    uint32_t     inline_ids[DS_TMS_INLINE];
    uint32_t     count;
    uint32_t    *heap_ids;             /* non-NULL when count > INLINE */
    uint32_t     heap_cap;
} ds_tms_just_t;

typedef struct {
    oa_t            map;
    /* DS_TMS_INLINE ids. A withdrawal of more hands the caller an owned
       array, never the scratch. */
    uint32_t       *withdraw_scratch;
    uint32_t        withdraw_scratch_cap;
    /* ds_tms_add answers DS_ERR_RT_UNSAFE rather than spill to heap_ids. */
    bool            rt_locked;
} ds_tms_table_t;

void ds_tms_table_init(ds_tms_table_t *tms);
void ds_tms_table_destroy(ds_tms_table_t *tms);

ds_result_t ds_tms_presz(ds_tms_table_t *tms, uint32_t cap);

ds_result_t ds_tms_add(ds_tms_table_t *tms, int64_t timetag,
                         const char *rule_name, uint32_t fact_id);

/*
 * All fact ids for timetag, removing the entry; count 0 if there is none. Up to
 * DS_TMS_INLINE ids, *ids_out is the table's scratch: copy it before any
 * cascade that might re-enter this. Above that, *ids_out is an array the
 * caller owns and frees (*caller_must_free), so a re-entered withdrawal cannot
 * reach it ([IRET.12.2]).
 */
ds_result_t ds_tms_withdraw(ds_tms_table_t *tms, int64_t timetag,
                              uint32_t **ids_out, uint32_t *count_out,
                              bool *caller_must_free);

/*
 * For an activation the tick carried across its turnover ([IRET.19.5]). A no-op
 * when from_timetag has no entry; to_timetag must have none.
 */
ds_result_t ds_tms_rekey(ds_tms_table_t *tms, int64_t from_timetag,
                          int64_t to_timetag);

#endif /* LIBDS2_INTERNAL_RETE_TMS_H */
