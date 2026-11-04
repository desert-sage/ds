/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * series/reservoir.h — uniform reservoir sampling, Vitter's Algorithm R. Queries
 * compute from the bag, O(k). `first` and `last` are not supported (LSER.16.9.3).
 */
#ifndef LIBDS2_INTERNAL_SERIES_RESERVOIR_H
#define LIBDS2_INTERNAL_SERIES_RESERVOIR_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "libds.h"
#include "backend.h"

typedef struct ds_series_reservoir {
    ds_slot_value_t  *samples;    /* k slots (typed values) */
    char            **str_copies; /* owned strings for STRING kind */
    size_t            k;          /* reservoir capacity */
    size_t            fill;       /* samples currently in bag (≤ k) */
    uint64_t          n;          /* total elements seen */
    uint64_t          rng;        /* xorshift64 PRNG state */
} ds_series_reservoir_t;

/* k 0 is the default, 100. */
ds_series_reservoir_t *ds_series_reservoir_new(size_t k);

void ds_series_reservoir_free(ds_series_reservoir_t *rs);

ds_series_reservoir_t *ds_series_reservoir_clone(
    const ds_series_reservoir_t *src);

void ds_series_reservoir_update(
    ds_series_reservoir_t *rs,
    const ds_slot_value_t *value,
    uint64_t               ts_ns);

ds_result_t ds_series_reservoir_query(
    const ds_series_reservoir_t *rs,
    ds_series_agg_kind_t         agg_kind,
    ds_slot_value_t             *out_value);

/* [LSER.17.2]: `pXX` over the bag. An empty bag writes DS_SLOT_NULL. */
ds_result_t ds_series_reservoir_percentile(
    const ds_series_reservoir_t *rs,
    unsigned                     pct,
    ds_slot_value_t             *out_value);

#endif  /* LIBDS2_INTERNAL_SERIES_RESERVOIR_H */
