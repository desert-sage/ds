/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * series/interval_pulse.c — SeriesBackendIntervalPulse backend for
 * `active_fraction` (LSIG.2.2).
 */

#include <stdlib.h>
#include <string.h>

#include "interval_pulse.h"
#include "ds_alloc.h"    /* DS_CALLOC/REALLOC/FREE -- IALC.9.1 routing */

ds_series_interval_pulse_t *ds_series_interval_pulse_new(uint64_t window_ns)
{
    ds_series_interval_pulse_t *ip = DS_CALLOC(1, sizeof(*ip));
    if (ip == NULL) return NULL;
    ip->window_ns = window_ns;
    return ip;
}

void ds_series_interval_pulse_free(ds_series_interval_pulse_t *ip)
{
    if (ip == NULL) return;
    DS_FREE(ip->intervals);
    DS_FREE(ip);
}

ds_series_interval_pulse_t *ds_series_interval_pulse_clone(
    const ds_series_interval_pulse_t *src)
{
    if (src == NULL) return NULL;
    ds_series_interval_pulse_t *ip = DS_CALLOC(1, sizeof(*ip));
    if (ip == NULL) return NULL;
    *ip = *src;
    ip->intervals = NULL;   /* replace the shallow-copied pointer */
    if (src->cap > 0) {
        ip->intervals = DS_CALLOC(src->cap, sizeof(*ip->intervals));
        if (ip->intervals == NULL) { DS_FREE(ip); return NULL; }
        memcpy(ip->intervals, src->intervals,
               src->n * sizeof(*ip->intervals));
    }
    return ip;
}

/* LSIG.2.2.2. Intervals are appended in falling-edge order, so on_end ascends. */
static void evict_expired(ds_series_interval_pulse_t *ip, int64_t now_ns)
{
    if (ip->window_ns == 0) return;
    int64_t cutoff = now_ns - (int64_t) ip->window_ns;   /* t − W */
    size_t keep_from = 0;
    while (keep_from < ip->n && ip->intervals[keep_from].on_end_ns <= cutoff) {
        const ds_series_interval_t *iv = &ip->intervals[keep_from];
        ip->total_on_ns -= (iv->on_end_ns - iv->on_start_ns);
        keep_from++;
    }
    if (keep_from == 0) return;
    if (keep_from < ip->n) {
        memmove(&ip->intervals[0], &ip->intervals[keep_from],
                (ip->n - keep_from) * sizeof(*ip->intervals));
    }
    ip->n -= keep_from;
}

static void append_interval(ds_series_interval_pulse_t *ip,
                            int64_t start_ns, int64_t end_ns)
{
    if (ip->n == ip->cap) {
        size_t new_cap = ip->cap == 0 ? 8 : ip->cap * 2;
        ds_series_interval_t *na =
            DS_REALLOC(ip->intervals, new_cap * sizeof(*ip->intervals));
        if (na == NULL) return;   /* OOM — interval dropped (LSTO.3.5) */
        ip->intervals = na;
        ip->cap = new_cap;
    }
    ip->intervals[ip->n].on_start_ns = start_ns;
    ip->intervals[ip->n].on_end_ns   = end_ns;
    ip->n++;
}

void ds_series_interval_pulse_update(ds_series_interval_pulse_t *ip,
                                     bool value, uint64_t ts_ns)
{
    int64_t t = (int64_t) ts_ns;
    ip->last_ns = t;
    ip->has_last = true;
    bool rising  = value  && (!ip->has_last_bool || !ip->last_bool);
    bool falling = !value && ip->has_last_bool && ip->last_bool;
    if (rising) {
        ip->open_start_ns = t;
        ip->has_open = true;
        evict_expired(ip, t);
    } else if (falling && ip->has_open) {
        append_interval(ip, ip->open_start_ns, t);
        ip->total_on_ns += (t - ip->open_start_ns);
        ip->has_open = false;
        evict_expired(ip, t);
    } else {
        evict_expired(ip, t);
    }
    ip->has_last_bool = true;
    ip->last_bool = value;
}

double ds_series_interval_pulse_active_fraction(
    const ds_series_interval_pulse_t *ip)
{
    return ds_series_interval_pulse_active_fraction_at(
        ip, ip->has_last ? (uint64_t) ip->last_ns : 0);
}

double ds_series_interval_pulse_active_fraction_at(
    const ds_series_interval_pulse_t *ip, uint64_t query_ns)
{
    if (!ip->has_last || ip->window_ns == 0) return 0.0;
    int64_t t = (int64_t) query_ns;
    int64_t w = (int64_t) ip->window_ns;
    int64_t cutoff = t - w;                       /* t − W (exclusive left) */
    /* Discount the not-yet-evicted out-of-window portion, read-only
       (LSIG.2.2.3). */
    int64_t stale = 0;
    for (size_t i = 0; i < ip->n && ip->intervals[i].on_start_ns <= cutoff; i++) {
        int64_t e = ip->intervals[i].on_end_ns;
        int64_t out_end = e < cutoff ? e : cutoff;   /* min(e, t−W) */
        stale += out_end - ip->intervals[i].on_start_ns;
    }
    int64_t total_on = ip->total_on_ns - stale;
    if (ip->has_open) {
        int64_t lo = ip->open_start_ns > cutoff ? ip->open_start_ns : cutoff;
        total_on += t - lo;                        /* open interval's in-window part */
    }
    if (total_on < 0) total_on = 0;
    /* One correctly-rounded divide (LSIG.4.1). */
    return (double) total_on / (double) w;
}
