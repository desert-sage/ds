/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * series/monotonic_deque.h — exact O(1) sliding min/max via two monotonic
 * deques.
 *
 * An Int slot's values are compared as int64 (the `_int` entry points): two Ints
 * above 2^53 can share one double, and [LSER.17.2]'s min/max select an observed
 * value.
 */
#ifndef LIBDS2_INTERNAL_SERIES_MONOTONIC_DEQUE_H
#define LIBDS2_INTERNAL_SERIES_MONOTONIC_DEQUE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "libds.h"
#include "backend.h"

typedef struct ds_mono_deque_entry {
    uint64_t ts_ns;
    double   value;     /* a Float slot's sample */
    int64_t  ivalue;    /* an Int slot's sample, exact */
    uint64_t seq;       /* absorption ordinal; see `max_entries` */
} ds_mono_deque_entry_t;

typedef struct ds_mono_deque {
    ds_mono_deque_entry_t *buf;
    size_t                 head;    /* index of front element */
    size_t                 tail;    /* index one past back (next push slot) */
    size_t                 cap;     /* allocated capacity */
    /* Non-zero: cap was pre-allocated, and dq_grow will not realloc. */
    size_t                 fixed_cap;
} ds_mono_deque_t;

typedef struct ds_series_mono_deque {
    uint64_t                  window_ns;
    ds_series_element_type_t  element_type;  /* for query return kind */
    ds_mono_deque_t           min_dq;        /* non-decreasing values */
    ds_mono_deque_t           max_dq;        /* non-increasing values */
    bool                      has_sample;
    /* [LSER.13.14]: the extremum is over the newest `max_entries` samples in the
       window; 0 is the window alone. A deque holds only candidates, so its length
       is not the retained count, and each entry carries its absorption ordinal. */
    size_t                    max_entries;
    uint64_t                  next_seq;
    /* Read the exact `ivalue` track. From what was absorbed, since a decl may
       leave `element_type` unspecified. */
    bool                      int_samples;
} ds_series_mono_deque_t;

/* window_ns must be > 0. max_entries 0 is unlimited; non-zero pre-allocates. */
ds_series_mono_deque_t *ds_series_mono_deque_new(
    uint64_t                 window_ns,
    ds_series_element_type_t element_type,
    size_t                   max_entries);

void ds_series_mono_deque_free(ds_series_mono_deque_t *md);

ds_series_mono_deque_t *ds_series_mono_deque_clone(
    const ds_series_mono_deque_t *src);

void ds_series_mono_deque_update(
    ds_series_mono_deque_t *md,
    double                  value,
    uint64_t                ts_ns);

/* A deque takes one kind for its life: an Int slot's through this, a Float
   slot's through the double one. */
void ds_series_mono_deque_update_int(
    ds_series_mono_deque_t *md,
    int64_t                 value,
    uint64_t                ts_ns);

void ds_series_mono_deque_evict_stale(
    ds_series_mono_deque_t *md,
    uint64_t                now_ns);

/* 0.0 if no samples are in window. */
double ds_series_mono_deque_min(const ds_series_mono_deque_t *md);
double ds_series_mono_deque_max(const ds_series_mono_deque_t *md);

/* The same over a deque fed by ds_series_mono_deque_update_int. 0 if no
   samples are in window. */
int64_t ds_series_mono_deque_min_int(const ds_series_mono_deque_t *md);
int64_t ds_series_mono_deque_max_int(const ds_series_mono_deque_t *md);

#endif  /* LIBDS2_INTERNAL_SERIES_MONOTONIC_DEQUE_H */
