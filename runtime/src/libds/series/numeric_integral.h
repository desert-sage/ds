/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * series/numeric_integral.h — SeriesBackendNumericIntegral backend for
 * `integral` (LSIG.2.3).
 *
 * Time-weighted integral ∫x dt of a piecewise-constant (zero-order-hold)
 * numeric signal. Three time models:
 *   sliding   — ring of closed (start, value) intervals + running_sum, with
 *               out-of-window portions discounted read-only at query time
 *               and fully-expired intervals evicted on assertion (LSIG.2.5).
 *   all_time  — running_sum accumulates every closed interval; no ring, no
 *               eviction. Always returns Float64 (LSIG.1.5.5).
 *   tumbling  — running_sum accrues within the current bucket; at each
 *               deterministic bucket boundary it is snapshot as the readable
 *               value and reset, with the held value carried over (LSIG.2.3.5).
 *
 * Determinism (LSIG.4.1): fixed-order Float64 add/sub only, and a running-sum
 * recompute every K evictions to bound subtractive round-off (LSIG.2.3.4).
 */
#ifndef LIBDS2_INTERNAL_SERIES_NUMERIC_INTEGRAL_H
#define LIBDS2_INTERNAL_SERIES_NUMERIC_INTEGRAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* LSIG.2.3.4. Not stored in the atom. */
#define DS_SERIES_NI_RECOMPUTE_EVICTIONS 128u

typedef struct ds_series_ni_sample {
    int64_t start_ns;   /* interval start; value held in [start, next_start) */
    double  value;
} ds_series_ni_sample_t;

typedef struct ds_series_numeric_integral {
    uint64_t window_ns;     /* sliding/tumbling window; 0 for all_time */
    uint32_t time_model;    /* ds_series_time_model_t */
    uint32_t gap_policy;    /* ds_series_gap_policy_t (LSIG.3) */

    /* Closed-interval ring (sliding only), oldest-first. */
    ds_series_ni_sample_t *ring;
    size_t   n;
    size_t   cap;

    bool     has_open;
    int64_t  open_start_ns;
    double   open_value;

    double   running_sum;   /* Σ closed intervals in window / bucket */
    unsigned evict_count;   /* for the K-eviction recompute */

    int64_t  last_ns;
    bool     has_last;

    /* Tumbling bucket state. */
    int64_t  bucket_end_ns;
    bool     has_bucket;    /* a completed-bucket snapshot exists */
    double   bucket_value;
} ds_series_numeric_integral_t;

/* window_ns is 0 for all_time. */
ds_series_numeric_integral_t *ds_series_numeric_integral_new(
    uint64_t window_ns, uint32_t time_model, uint32_t gap_policy);

void ds_series_numeric_integral_free(ds_series_numeric_integral_t *ni);

ds_series_numeric_integral_t *ds_series_numeric_integral_clone(
    const ds_series_numeric_integral_t *src);

void ds_series_numeric_integral_update(
    ds_series_numeric_integral_t *ni, double value, uint64_t ts_ns);

/* Over the window, or the most recently completed bucket. Read-only. 0.0 before
   any sample (tumbling: before the first bucket closes). The bare form reads as
   of the last absorb; `_at` as of a monotonic `query_ns` at or after it
   (LSIG.2.3.3, LSIG.3.6). */
double ds_series_numeric_integral_value(
    const ds_series_numeric_integral_t *ni);
double ds_series_numeric_integral_value_at(
    const ds_series_numeric_integral_t *ni, uint64_t query_ns);

#endif  /* LIBDS2_INTERNAL_SERIES_NUMERIC_INTEGRAL_H */
