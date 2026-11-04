/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * series/interval_pulse.h — SeriesBackendIntervalPulse backend for
 * `active_fraction` (LSIG.2.2).
 *
 * One instance per (schema, slot, identity-value). Holds a deque of closed
 * true-intervals (on_start, on_end) plus one possibly-open interval and a
 * running int64-ns sum of the closed on-time within the window. The query
 * is read-only (LSIG.2.2.3); eviction is assertion-driven (LSIG.2.5).
 */
#ifndef LIBDS2_INTERNAL_SERIES_INTERVAL_PULSE_H
#define LIBDS2_INTERNAL_SERIES_INTERVAL_PULSE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct ds_series_interval {
    int64_t on_start_ns;
    int64_t on_end_ns;
} ds_series_interval_t;

typedef struct ds_series_interval_pulse {
    uint64_t window_ns;

    ds_series_interval_t *intervals;   /* closed intervals, oldest-first */
    size_t   n;
    size_t   cap;

    bool     has_open;                 /* slot currently true */
    int64_t  open_start_ns;
    int64_t  total_on_ns;              /* Σ closed on-time in window */

    int64_t  last_ns;                  /* most-recent absorb time (= query t) */
    bool     has_last;
    bool     has_last_bool;            /* previous asserted value, for edges */
    bool     last_bool;
} ds_series_interval_pulse_t;

/* window_ns must be > 0: active_fraction is sliding only. */
ds_series_interval_pulse_t *ds_series_interval_pulse_new(uint64_t window_ns);

void ds_series_interval_pulse_free(ds_series_interval_pulse_t *ip);

ds_series_interval_pulse_t *ds_series_interval_pulse_clone(
    const ds_series_interval_pulse_t *src);

void ds_series_interval_pulse_update(ds_series_interval_pulse_t *ip,
                                     bool value, uint64_t ts_ns);

/* Total on-time ÷ window_ns, one correctly-rounded divide (LSIG.2.2.3, LSIG.4.1).
   0.0 before any assertion. The bare form reads as of the last absorb; `_at` as
   of a monotonic `query_ns` at or after it (LSIG.2.5). */
double ds_series_interval_pulse_active_fraction(
    const ds_series_interval_pulse_t *ip);
double ds_series_interval_pulse_active_fraction_at(
    const ds_series_interval_pulse_t *ip, uint64_t query_ns);

#endif  /* LIBDS2_INTERNAL_SERIES_INTERVAL_PULSE_H */
