/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * series/welford_ewma.h — running-stats backend (LSER.14.3): Welford's online
 * algorithm, cumulative from boot ([LSER.16.3.3]), with no window and no decay
 * ([RDSC.5a.4.3]). `rate` and `direction` read the raw samples, never the running
 * statistics ([LSER.16.9], [LSER.10.9]).
 */
#ifndef LIBDS2_INTERNAL_SERIES_WELFORD_EWMA_H
#define LIBDS2_INTERNAL_SERIES_WELFORD_EWMA_H

#include <stdbool.h>
#include <stdint.h>

#include "libds.h"

typedef struct ds_series_welford_ewma {
    double w;                 /* the sample count ([LSER.16.3.3]'s k) */
    double mean;
    double m2;
    double min_v;
    double max_v;
    bool   has_sample;
    uint64_t last_sample_ns;
    uint64_t first_sample_ns;

    /* Most recent sample; a String's copy is owned by typed_last_str. */
    ds_slot_value_t typed_last;
    char           *typed_last_str;

    /* The sample before typed_last, numeric only, in the slot's type: two Ints
       above 2^53 can convert to one double. */
    ds_slot_value_t typed_prev;
    bool            has_typed_prev;

    ds_slot_value_t typed_first;
    char           *typed_first_str;
    bool            has_typed_first;

    /* sum_is_int is set on the first Int absorb. */
    double   sum_f;
    int64_t  sum_i;
    bool     sum_is_int;

    /* Exact over an Int slot ([LSER.17.2]): valid when sum_is_int. */
    int64_t  min_i;
    int64_t  max_i;

    uint64_t bool_true_count;
    uint64_t bool_total_count;
} ds_series_welford_ewma_t;

ds_series_welford_ewma_t *ds_series_welford_ewma_new(void);

void ds_series_welford_ewma_free(ds_series_welford_ewma_t *we);

ds_series_welford_ewma_t *ds_series_welford_ewma_clone(
    const ds_series_welford_ewma_t *src);

/* ts_ns is kept for `rate`; it weights nothing. */
void ds_series_welford_ewma_update(
    ds_series_welford_ewma_t *we,
    double                    value,
    uint64_t                  ts_ns);

/* For a non-numeric slot: the count and sample times move; mean, m2, min_v and
   max_v stay 0. */
void ds_series_welford_ewma_update_count_only(
    ds_series_welford_ewma_t *we,
    uint64_t                  ts_ns);

/* All answer before the first sample, these with 0. */
uint64_t ds_series_welford_ewma_count(
    const ds_series_welford_ewma_t *we);
double   ds_series_welford_ewma_avg(
    const ds_series_welford_ewma_t *we);
/* [LSER.16.3.3]: the sample forms. False while w <= 1: the read is `null`. */
bool     ds_series_welford_ewma_variance(
    const ds_series_welford_ewma_t *we, double *out);
double   ds_series_welford_ewma_pvariance(
    const ds_series_welford_ewma_t *we);
bool     ds_series_welford_ewma_stdev(
    const ds_series_welford_ewma_t *we, double *out);
double   ds_series_welford_ewma_pstdev(
    const ds_series_welford_ewma_t *we);
double   ds_series_welford_ewma_min(
    const ds_series_welford_ewma_t *we);
double   ds_series_welford_ewma_max(
    const ds_series_welford_ewma_t *we);

/* [LSER.16.9]: Δv × 1e9, then ÷ Δt_ns. False when no time elapses or the samples
   are not numeric: the read is `null`. */
bool     ds_series_welford_ewma_rate(
    const ds_series_welford_ewma_t *we, double *out);

/* [LSER.10.9]: -1, 0 or +1, the two newest samples compared in the slot's type.
   False before a second sample: the read is `null`. */
bool     ds_series_welford_ewma_direction(
    const ds_series_welford_ewma_t *we, int64_t *out);

#endif  /* LIBDS2_INTERNAL_SERIES_WELFORD_EWMA_H */
