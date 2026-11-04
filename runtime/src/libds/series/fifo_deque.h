/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * series/fifo_deque.h — exact sliding `first`, `last`, `bool_or` and `bool_and`,
 * all O(1), over a circular FIFO of (ts_ns, value).
 */
#ifndef LIBDS2_INTERNAL_SERIES_FIFO_DEQUE_H
#define LIBDS2_INTERNAL_SERIES_FIFO_DEQUE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "libds.h"
#include "backend.h"

typedef struct ds_sbfd_entry {
    uint64_t        ts_ns;
    ds_slot_value_t value;
    char           *str_copy;  /* owned if value.kind == DS_SLOT_STRING */
} ds_sbfd_entry_t;

typedef struct ds_series_fifo_deque {
    uint64_t                  window_ns;
    ds_series_element_type_t  element_type;
    ds_sbfd_entry_t          *buf;
    size_t                    head, tail, cap;
    /* Non-zero: cap was pre-allocated, and fd_grow will not realloc. */
    size_t                    fixed_cap;
    uint64_t                  bool_true_count;  /* cached for O(1) bool queries */
    bool                      has_sample;
} ds_series_fifo_deque_t;

/* window_ns must be > 0. max_entries 0 is unlimited; non-zero pre-allocates. */
ds_series_fifo_deque_t *ds_series_fifo_deque_new(
    uint64_t                 window_ns,
    ds_series_element_type_t element_type,
    size_t                   max_entries);

void ds_series_fifo_deque_free(ds_series_fifo_deque_t *fd);

ds_series_fifo_deque_t *ds_series_fifo_deque_clone(
    const ds_series_fifo_deque_t *src);

void ds_series_fifo_deque_update(
    ds_series_fifo_deque_t *fd,
    const ds_slot_value_t  *value,
    uint64_t                ts_ns);

void ds_series_fifo_deque_evict_stale(
    ds_series_fifo_deque_t *fd,
    uint64_t                now_ns);

/* A zero / false default when the window is empty. */
ds_slot_value_t ds_series_fifo_deque_first(
    const ds_series_fifo_deque_t *fd);
ds_slot_value_t ds_series_fifo_deque_last(
    const ds_series_fifo_deque_t *fd);
bool ds_series_fifo_deque_bool_or(
    const ds_series_fifo_deque_t *fd);
bool ds_series_fifo_deque_bool_and(
    const ds_series_fifo_deque_t *fd);

#endif  /* LIBDS2_INTERNAL_SERIES_FIFO_DEQUE_H */
