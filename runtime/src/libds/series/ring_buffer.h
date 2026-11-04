/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * series/ring_buffer.h — exact-samples backend: a sliding window of (ts_ns, value).
 * An optional `max_samples` drops the oldest, even within the window. The element
 * type is fixed at allocation (LSER.10.3).
 */
#ifndef LIBDS2_INTERNAL_SERIES_RING_BUFFER_H
#define LIBDS2_INTERNAL_SERIES_RING_BUFFER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "libds.h"

/* Matches SeriesElementType on the atom (RDSC.5a.5). */
typedef enum ds_series_ring_elem {
    DS_SERIES_RING_ELEM_FLOAT  = 1,
    DS_SERIES_RING_ELEM_INT    = 2,
    DS_SERIES_RING_ELEM_STRING = 3,
    DS_SERIES_RING_ELEM_BOOL   = 4,
} ds_series_ring_elem_t;

typedef struct ds_series_ring_sample {
    uint64_t ts_ns;
    union {
        double  f64;
        int64_t i64;
        char   *str;   /* owned (strdup); free on eviction */
        bool    b;
    } value;
} ds_series_ring_sample_t;

typedef struct ds_series_ring_buffer {
    ds_series_ring_elem_t element_type;
    uint64_t              window_ns;
    uint32_t              max_samples;     /* 0 = window-only bound */

    ds_series_ring_sample_t *samples;
    size_t                   n_samples;
    size_t                   cap_samples;

    /* Sorted-copy scratch for percentiles: pre-sized when bounded, so the query
       does not allocate on the pump path, and otherwise grown lazily. */
    double                  *pctl_scratch;
    size_t                   pctl_scratch_cap;

    /* The same for count_distinct: 8-byte slots, reused per element type. */
    void                    *distinct_scratch;
    size_t                   distinct_scratch_cap;  /* in 8-byte slots */

    uint64_t last_sample_ns;                /* engine clock at most-recent absorb */
    bool     has_sample;

    /* LSIG.2.4: empty for non-Bool element types. */
    uint64_t *edge_ts;                      /* rising-edge timestamps, insert order */
    size_t    n_edges;
    size_t    cap_edges;
    bool      has_last_bool;
    bool      last_bool;

    /* t_first (LSER.19.7), never evicted: onset_rate's elapsed denominator. */
    uint64_t  first_ever_ns;
    bool      has_first_ever;
} ds_series_ring_buffer_t;

/* max_samples 0: the window is the only bound. */
ds_series_ring_buffer_t *ds_series_ring_buffer_new(
    ds_series_ring_elem_t element_type,
    uint64_t              window_ns,
    uint32_t              max_samples);

void ds_series_ring_buffer_free(ds_series_ring_buffer_t *rb);

ds_series_ring_buffer_t *ds_series_ring_buffer_clone(
    const ds_series_ring_buffer_t *src);

/* The caller dispatches on element_type. A String is copied. */
void ds_series_ring_buffer_update_float(
    ds_series_ring_buffer_t *rb, double value, uint64_t ts_ns);
void ds_series_ring_buffer_update_int(
    ds_series_ring_buffer_t *rb, int64_t value, uint64_t ts_ns);
void ds_series_ring_buffer_update_string(
    ds_series_ring_buffer_t *rb, const char *value, uint64_t ts_ns);
void ds_series_ring_buffer_update_bool(
    ds_series_ring_buffer_t *rb, bool value, uint64_t ts_ns);

void ds_series_ring_buffer_evict_stale(
    ds_series_ring_buffer_t *rb, uint64_t now_ns);

/* Pre-sample queries return zeros. */
size_t ds_series_ring_buffer_count(
    const ds_series_ring_buffer_t *rb);
double ds_series_ring_buffer_avg(
    const ds_series_ring_buffer_t *rb);
double ds_series_ring_buffer_min(
    const ds_series_ring_buffer_t *rb);
double ds_series_ring_buffer_max(
    const ds_series_ring_buffer_t *rb);

/* LSER.18.2. Numeric element types only; 0 on an empty window. `_sum` accumulates
   as double, `_sum_int` as int64. The sample forms return false for n <= 1: the
   read is `null` ([LSER.16.3.3]). */
double  ds_series_ring_buffer_sum(
    const ds_series_ring_buffer_t *rb);
int64_t ds_series_ring_buffer_sum_int(
    const ds_series_ring_buffer_t *rb);
bool    ds_series_ring_buffer_variance(
    const ds_series_ring_buffer_t *rb, double *out);
double  ds_series_ring_buffer_pvariance(
    const ds_series_ring_buffer_t *rb);
bool    ds_series_ring_buffer_stdev(
    const ds_series_ring_buffer_t *rb, double *out);
double  ds_series_ring_buffer_pstdev(
    const ds_series_ring_buffer_t *rb);

/* [LSER.17.2], Hyndman-Fan type 7, shared with the reservoir: sort ascending, then
   the value over `n >= 1` sorted samples, `pct` clamped to [0, 100]. */
void   ds_series_sort_for_quantile(double *vals, size_t n);
double ds_series_quantile_type7(const double *sorted, size_t n, unsigned pct);

typedef enum ds_series_ring_pctl {
    DS_SERIES_RING_PCTL_VALUE,
    DS_SERIES_RING_PCTL_EMPTY,
    DS_SERIES_RING_PCTL_OOM,
} ds_series_ring_pctl_t;

/* EMPTY reads `null` ([LSER.19.8]); OOM is a failure, not an answer. Not `const`:
   it sorts into the scratch. */
ds_series_ring_pctl_t ds_series_ring_buffer_percentile(
    ds_series_ring_buffer_t *rb, unsigned pct, double *out);

/* [LSER.10.9]: -1, 0 or +1. False with fewer than two samples or a non-numeric
   element type: the read is `null`. */
bool ds_series_ring_buffer_direction(
    const ds_series_ring_buffer_t *rb, int64_t *out);

/* LSER.16.5.2. Not `const`: it sorts into the scratch. */
size_t ds_series_ring_buffer_count_distinct(
    ds_series_ring_buffer_t *rb);

/* LSER.16.6.1. A kind mismatch is not equal. */
size_t ds_series_ring_buffer_count_of(
    const ds_series_ring_buffer_t *rb, const ds_slot_value_t *value);

/* LSER.16.9: Δv × 1e9, then ÷ Δt_ns. False with no elapsed time or a non-numeric
   element type: the read is `null` ([LSER.19.8]). */
bool ds_series_ring_buffer_rate(
    const ds_series_ring_buffer_t *rb, double *out);

/* LSIG.1.4: rising edges per second over min(window_ns, elapsed) (LSER.19.7). 0.0
   before any edge or while elapsed is 0. Bool element type only. */
double ds_series_ring_buffer_onset_rate(
    const ds_series_ring_buffer_t *rb);
/* As of `query_ns`, at or after the last absorb (LSIG.2.5). */
double ds_series_ring_buffer_onset_rate_at(
    const ds_series_ring_buffer_t *rb, uint64_t query_ns);

/* LSER.16.7.1. Compares as count_of does. */
bool ds_series_ring_buffer_contains(
    const ds_series_ring_buffer_t *rb, const ds_slot_value_t *value);

#endif  /* LIBDS2_INTERNAL_SERIES_RING_BUFFER_H */
