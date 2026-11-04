/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * series/numeric_integral.c — SeriesBackendNumericIntegral backend for
 * `integral` (LSIG.2.3).
 */

#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "backend.h"          /* ds_series_time_model_t / gap enums */
#include "numeric_integral.h"
#include "ds_alloc.h"         /* DS_CALLOC/REALLOC/FREE -- IALC.9.1 routing */

ds_series_numeric_integral_t *ds_series_numeric_integral_new(
    uint64_t window_ns, uint32_t time_model, uint32_t gap_policy)
{
    ds_series_numeric_integral_t *ni = DS_CALLOC(1, sizeof(*ni));
    if (ni == NULL) return NULL;
    ni->window_ns  = window_ns;
    ni->time_model = time_model;
    ni->gap_policy = gap_policy;
    return ni;
}

void ds_series_numeric_integral_free(ds_series_numeric_integral_t *ni)
{
    if (ni == NULL) return;
    DS_FREE(ni->ring);
    DS_FREE(ni);
}

ds_series_numeric_integral_t *ds_series_numeric_integral_clone(
    const ds_series_numeric_integral_t *src)
{
    if (src == NULL) return NULL;
    ds_series_numeric_integral_t *ni = DS_CALLOC(1, sizeof(*ni));
    if (ni == NULL) return NULL;
    *ni = *src;
    ni->ring = NULL;   /* replace the shallow-copied pointer */
    if (src->cap > 0) {
        ni->ring = DS_CALLOC(src->cap, sizeof(*ni->ring));
        if (ni->ring == NULL) { DS_FREE(ni); return NULL; }
        memcpy(ni->ring, src->ring, src->n * sizeof(*ni->ring));
    }
    return ni;
}

static void ni_push(ds_series_numeric_integral_t *ni,
                    int64_t start_ns, double value)
{
    if (ni->n == ni->cap) {
        size_t new_cap = ni->cap == 0 ? 8 : ni->cap * 2;
        ds_series_ni_sample_t *na =
            DS_REALLOC(ni->ring, new_cap * sizeof(*ni->ring));
        if (na == NULL) return;   /* OOM — interval dropped (LSTO.3.5) */
        ni->ring = na;
        ni->cap = new_cap;
    }
    ni->ring[ni->n].start_ns = start_ns;
    ni->ring[ni->n].value    = value;
    ni->n++;
}

/* The end of ring entry i is the next entry's start, or the open interval's
   start for the last entry (LSIG.2.3.3). */
static int64_t ni_end_of(const ds_series_numeric_integral_t *ni, size_t i)
{
    return (i + 1 < ni->n) ? ni->ring[i + 1].start_ns : ni->open_start_ns;
}

/* Rebuild running_sum from the live ring intervals, fixed order — bounds
   subtractive round-off every K evictions (LSIG.2.3.4). */
static void ni_recompute(ds_series_numeric_integral_t *ni)
{
    double s = 0.0;
    for (size_t i = 0; i < ni->n; i++) {
        int64_t end = ni_end_of(ni, i);
        s += ni->ring[i].value * (double) (end - ni->ring[i].start_ns);
    }
    ni->running_sum = s;
}

/* LSIG.2.3.2. */
static void ni_evict(ds_series_numeric_integral_t *ni, int64_t cutoff)
{
    while (ni->n > 0) {
        int64_t end0 = ni_end_of(ni, 0);
        if (end0 > cutoff) break;                 /* interval still (partly) live */
        ni->running_sum -=
            ni->ring[0].value * (double) (end0 - ni->ring[0].start_ns);
        memmove(&ni->ring[0], &ni->ring[1],
                (ni->n - 1) * sizeof(*ni->ring));
        ni->n--;
        if (++ni->evict_count >= DS_SERIES_NI_RECOMPUTE_EVICTIONS) {
            ni_recompute(ni);
            ni->evict_count = 0;
        }
    }
}

static void ni_update_tumbling(ds_series_numeric_integral_t *ni,
                               double value, uint64_t ts_ns)
{
    int64_t t = (int64_t) ts_ns;
    int64_t w = (int64_t) ni->window_ns;
    if (!ni->has_open) {
        ni->open_start_ns = t;
        ni->open_value = value;
        ni->has_open = true;
        /* First bucket ends at the next deterministic epoch (LSER.14.4.1). */
        ni->bucket_end_ns = (t / w + 1) * w;
        ni->last_ns = t;
        ni->has_last = true;
        return;
    }
    /* Close every bucket boundary crossed since the last sample. The held
       value carries over into each new bucket (LSIG.2.3.5). */
    while (w > 0 && t >= ni->bucket_end_ns) {
        ni->running_sum +=
            ni->open_value * (double) (ni->bucket_end_ns - ni->open_start_ns);
        ni->bucket_value = ni->running_sum;   /* snapshot completed bucket */
        ni->has_bucket = true;
        ni->running_sum = 0.0;
        ni->open_start_ns = ni->bucket_end_ns;
        ni->bucket_end_ns += w;
    }
    /* Accrue the held value up to the new sample within the current bucket. */
    ni->running_sum += ni->open_value * (double) (t - ni->open_start_ns);
    ni->open_start_ns = t;
    ni->open_value = value;
    ni->last_ns = t;
    ni->has_last = true;
}

void ds_series_numeric_integral_update(
    ds_series_numeric_integral_t *ni, double value, uint64_t ts_ns)
{
    if (ni->time_model == DS_SERIES_TIME_MODEL_TUMBLING) {
        ni_update_tumbling(ni, value, ts_ns);
        return;
    }
    int64_t t = (int64_t) ts_ns;
    if (ni->has_open) {
        ni->running_sum +=
            ni->open_value * (double) (t - ni->open_start_ns);
        if (ni->time_model == DS_SERIES_TIME_MODEL_SLIDING)
            ni_push(ni, ni->open_start_ns, ni->open_value);
    }
    ni->open_start_ns = t;
    ni->open_value = value;
    ni->has_open = true;
    if (ni->time_model == DS_SERIES_TIME_MODEL_SLIDING && ni->window_ns > 0)
        ni_evict(ni, t - (int64_t) ni->window_ns);
    ni->last_ns = t;
    ni->has_last = true;
}

/* The ring accumulates value·ns; the result is value·seconds (LSIG.1.5.1). */
#define DS_SERIES_NI_NS_PER_SEC 1000000000.0

double ds_series_numeric_integral_value(
    const ds_series_numeric_integral_t *ni)
{
    return ds_series_numeric_integral_value_at(
        ni, ni->has_last ? (uint64_t) ni->last_ns : 0);
}

double ds_series_numeric_integral_value_at(
    const ds_series_numeric_integral_t *ni, uint64_t query_ns)
{
    if (ni->time_model == DS_SERIES_TIME_MODEL_TUMBLING) {
        if (!ni->has_bucket) return 0.0;                  /* LSIG.2.3.5 */
        return ni->bucket_value / DS_SERIES_NI_NS_PER_SEC;
    }
    if (!ni->has_last) return 0.0;
    int64_t t = (int64_t) query_ns;
    bool sliding = (ni->time_model == DS_SERIES_TIME_MODEL_SLIDING
                    && ni->window_ns > 0);
    int64_t cutoff = sliding ? (t - (int64_t) ni->window_ns) : INT64_MIN;

    /* The open (currently-held) interval [open_start, t] is integrated forward
       to the query time only under `gap hold` (the default); `gap zero` /
       `gap skip` advance only on assertion (LSIG.3.6). Clip its start to the
       window boundary for the sliding model. */
    double open_contrib = 0.0;
    if (ni->has_open
        && (ni->gap_policy == DS_SERIES_GAP_POLICY_HOLD
            || ni->gap_policy == DS_SERIES_GAP_POLICY_UNSPECIFIED)) {
        int64_t lo = ni->open_start_ns;
        if (sliding && lo < cutoff) lo = cutoff;          /* max(open_start, t−W) */
        if (t > lo)
            open_contrib = ni->open_value * (double) (t - lo);
    }

    if (!sliding)   /* all_time / unwindowed */
        return (ni->running_sum + open_contrib) / DS_SERIES_NI_NS_PER_SEC;

    /* Discount the not-yet-evicted out-of-window closed portions, read-only
       (LSIG.2.3.3). */
    double stale = 0.0;
    for (size_t i = 0; i < ni->n && ni->ring[i].start_ns <= cutoff; i++) {
        int64_t end = ni_end_of(ni, i);
        int64_t out_end = end < cutoff ? end : cutoff;   /* min(end, t−W) */
        stale += ni->ring[i].value * (double) (out_end - ni->ring[i].start_ns);
    }
    return (ni->running_sum - stale + open_contrib) / DS_SERIES_NI_NS_PER_SEC;
}
