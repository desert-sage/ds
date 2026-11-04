/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * series/dispatch.h — series-aggregation absorb path.
 *
 * The read path is engine_rete_adapters.c::register_series_read_adapters.
 */
#ifndef LIBDS2_INTERNAL_SERIES_DISPATCH_H
#define LIBDS2_INTERNAL_SERIES_DISPATCH_H

#include "libds.h"

#include <stdbool.h>

struct ds_engine;
struct ds_series_decl_record;

/* [LSER.13.14] true for a backing that REFUSES at its declared capacity:
   SeriesBackendIntervalPulse or SeriesBackendNumericIntegral, with a capacity
   and a window. */
bool ds_series_refuses_at_capacity(const struct ds_series_decl_record *d);

/* `SeriesNullPolicy` (`proto/series_backend_ring_buffer.proto`), field 11 on
   every backend atom: the declaration's `nulls:` option ([LNUL.8.6]). The
   numbers are the proto's; UNSPECIFIED is a series over a non-nullable
   source, and a `null` reaching one absorbs nothing. */
enum {
    DS_SERIES_NULLS_UNSPECIFIED = 0,
    DS_SERIES_NULLS_SKIP        = 1,
    DS_SERIES_NULLS_HOLD        = 2,
    DS_SERIES_NULLS_ZERO        = 3,
};

/* Absorb one sample into every series_decl matching (schema, slot). */
void ds_series_absorb_one(struct ds_engine        *engine,
                          const char              *schema_name,
                          const char              *slot_name,
                          const char              *id_slot,
                          const char              *id_value,
                          const ds_slot_value_t   *value,
                          uint64_t                 ts_ns);

#endif  /* LIBDS2_INTERNAL_SERIES_DISPATCH_H */
