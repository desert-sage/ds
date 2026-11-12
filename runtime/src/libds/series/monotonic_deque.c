/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * series/monotonic_deque.c — exact O(1) sliding min/max: min_dq non-decreasing
 * and max_dq non-increasing, front to back. An insert trims dominated values off
 * the back; eviction trims the front.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "monotonic_deque.h"
#include "ring_buffer.h"    /* ds_series_signed_before, [LSER.17.2] */
#include "ds_alloc.h"    /* DS_MALLOC/CALLOC/FREE -- IALC.9.1 routing */

#define SBMD_INITIAL_CAP 16

/* ------------------------------------------------------------------ */
/*  Low-level circular deque operations                               */
/* ------------------------------------------------------------------ */

static bool dq_empty(const ds_mono_deque_t *dq)
{
    return dq->head == dq->tail;
}

static size_t dq_size(const ds_mono_deque_t *dq)
{
    return (dq->tail + dq->cap - dq->head) % dq->cap;
}

static ds_mono_deque_entry_t *dq_front(ds_mono_deque_t *dq)
{
    return &dq->buf[dq->head];
}

static ds_mono_deque_entry_t *dq_back(ds_mono_deque_t *dq)
{
    return &dq->buf[(dq->tail + dq->cap - 1) % dq->cap];
}

static void dq_pop_front(ds_mono_deque_t *dq)
{
    if (!dq_empty(dq))
        dq->head = (dq->head + 1) % dq->cap;
}

static void dq_pop_back(ds_mono_deque_t *dq)
{
    if (!dq_empty(dq))
        dq->tail = (dq->tail + dq->cap - 1) % dq->cap;
}

/* Grow the buffer to 2× capacity. Returns false on OOM or fixed cap. */
static bool dq_grow(ds_mono_deque_t *dq)
{
    if (dq->fixed_cap > 0) return false;
    size_t old_cap = dq->cap;
    size_t new_cap = old_cap * 2;
    ds_mono_deque_entry_t *new_buf = DS_MALLOC(
        new_cap * sizeof(ds_mono_deque_entry_t));
    if (new_buf == NULL) return false;

    size_t n = dq_size(dq);
    for (size_t i = 0; i < n; i++) {
        new_buf[i] = dq->buf[(dq->head + i) % old_cap];
    }
    DS_FREE(dq->buf);
    dq->buf  = new_buf;
    dq->head = 0;
    dq->tail = n;
    dq->cap  = new_cap;
    return true;
}

/* Silently drops on OOM. */
static void dq_push_back(ds_mono_deque_t *dq, ds_mono_deque_entry_t entry)
{
    /* Full when one slot remains (tail+1 == head mod cap). */
    if ((dq->tail + 1) % dq->cap == dq->head) {
        if (!dq_grow(dq)) return;
    }
    dq->buf[dq->tail] = entry;
    dq->tail = (dq->tail + 1) % dq->cap;
}

static bool dq_init(ds_mono_deque_t *dq, size_t initial_cap, size_t fixed_cap)
{
    dq->buf = DS_MALLOC(initial_cap * sizeof(ds_mono_deque_entry_t));
    if (dq->buf == NULL) return false;
    dq->head      = 0;
    dq->tail      = 0;
    dq->cap       = initial_cap;
    dq->fixed_cap = fixed_cap;
    return true;
}

static void dq_dispose(ds_mono_deque_t *dq)
{
    DS_FREE(dq->buf);
    dq->buf  = NULL;
    dq->head = dq->tail = dq->cap = 0;
}

/* ------------------------------------------------------------------ */
/*  Public API                                                        */
/* ------------------------------------------------------------------ */

ds_series_mono_deque_t *
ds_series_mono_deque_new(uint64_t                 window_ns,
                          ds_series_element_type_t element_type,
                          size_t                   max_entries)
{
    ds_series_mono_deque_t *md = DS_CALLOC(1, sizeof(*md));
    if (md == NULL) return NULL;

    /* One slot of the circular buffer stays empty. */
    size_t init_cap  = (max_entries > 0) ? max_entries + 1 : SBMD_INITIAL_CAP;
    size_t fixed_cap = (max_entries > 0) ? init_cap         : 0;
    if (!dq_init(&md->min_dq, init_cap, fixed_cap)
        || !dq_init(&md->max_dq, init_cap, fixed_cap)) {
        dq_dispose(&md->min_dq);
        dq_dispose(&md->max_dq);
        DS_FREE(md);
        return NULL;
    }
    md->window_ns    = window_ns;
    md->element_type = element_type;
    md->max_entries  = max_entries;
    md->next_seq     = 0;
    return md;
}

void ds_series_mono_deque_free(ds_series_mono_deque_t *md)
{
    if (md == NULL) return;
    dq_dispose(&md->min_dq);
    dq_dispose(&md->max_dq);
    DS_FREE(md);
}

static bool dq_clone_into(const ds_mono_deque_t *src, ds_mono_deque_t *dst)
{
    dst->buf = DS_MALLOC(src->cap * sizeof(ds_mono_deque_entry_t));
    if (dst->buf == NULL) return false;
    memcpy(dst->buf, src->buf, src->cap * sizeof(ds_mono_deque_entry_t));
    dst->head      = src->head;
    dst->tail      = src->tail;
    dst->cap       = src->cap;
    dst->fixed_cap = src->fixed_cap;
    return true;
}

ds_series_mono_deque_t *ds_series_mono_deque_clone(
    const ds_series_mono_deque_t *src)
{
    if (src == NULL) return NULL;
    ds_series_mono_deque_t *md = DS_CALLOC(1, sizeof(*md));
    if (md == NULL) return NULL;
    md->window_ns    = src->window_ns;
    md->element_type = src->element_type;
    md->has_sample   = src->has_sample;
    md->max_entries  = src->max_entries;
    md->next_seq     = src->next_seq;
    md->int_samples  = src->int_samples;
    if (!dq_clone_into(&src->min_dq, &md->min_dq)
        || !dq_clone_into(&src->max_dq, &md->max_dq)) {
        dq_dispose(&md->min_dq);
        dq_dispose(&md->max_dq);
        DS_FREE(md);
        return NULL;
    }
    return md;
}

void ds_series_mono_deque_evict_stale(ds_series_mono_deque_t *md,
                                       uint64_t                now_ns)
{
    /* Half-open (t−W, t] ([LSER.14.1], [LSIG.2.2.4]): an entry exactly W old
       is out. Before t reaches W nothing is. */
    if (md->window_ns == 0 || now_ns < md->window_ns) return;
    uint64_t threshold = now_ns - md->window_ns;

    while (!dq_empty(&md->min_dq)
           && dq_front(&md->min_dq)->ts_ns <= threshold) {
        dq_pop_front(&md->min_dq);
    }
    while (!dq_empty(&md->max_dq)
           && dq_front(&md->max_dq)->ts_ns <= threshold) {
        dq_pop_front(&md->max_dq);
    }
}

/* [LSER.13.14]: before the push, so the fixed buffer always has room. */
static void md_drop_over_capacity(ds_series_mono_deque_t *md)
{
    if (md->max_entries > 0 && md->next_seq >= md->max_entries) {
        uint64_t oldest_kept = md->next_seq - md->max_entries + 1u;
        while (!dq_empty(&md->min_dq)
               && dq_front(&md->min_dq)->seq < oldest_kept)
            dq_pop_front(&md->min_dq);
        while (!dq_empty(&md->max_dq)
               && dq_front(&md->max_dq)->seq < oldest_kept)
            dq_pop_front(&md->max_dq);
    }
}

void ds_series_mono_deque_update(ds_series_mono_deque_t *md,
                                  double                  value,
                                  uint64_t                ts_ns)
{
    ds_series_mono_deque_evict_stale(md, ts_ns);
    md_drop_over_capacity(md);

    ds_mono_deque_entry_t entry = { .ts_ns = ts_ns, .value = value,
                                    .ivalue = 0, .seq = md->next_seq++ };

    /* The trims keep each deque strictly monotone under [LSER.17.2]'s signed
       order, so its front is the signed extreme: -0 is below +0, and a `>=`
       trim would keep whichever zero arrived last. */
    while (!dq_empty(&md->min_dq)
           && !ds_series_signed_before(dq_back(&md->min_dq)->value, value)) {
        dq_pop_back(&md->min_dq);
    }
    dq_push_back(&md->min_dq, entry);

    while (!dq_empty(&md->max_dq)
           && !ds_series_signed_before(value, dq_back(&md->max_dq)->value)) {
        dq_pop_back(&md->max_dq);
    }
    dq_push_back(&md->max_dq, entry);

    md->has_sample = true;
}

/* `value` carries the double too, so a stray double read answers the nearest
   one. */
void ds_series_mono_deque_update_int(ds_series_mono_deque_t *md,
                                      int64_t                 value,
                                      uint64_t                ts_ns)
{
    ds_series_mono_deque_evict_stale(md, ts_ns);
    md_drop_over_capacity(md);

    ds_mono_deque_entry_t entry = { .ts_ns = ts_ns, .value = (double) value,
                                    .ivalue = value, .seq = md->next_seq++ };

    while (!dq_empty(&md->min_dq)
           && dq_back(&md->min_dq)->ivalue >= value) {
        dq_pop_back(&md->min_dq);
    }
    dq_push_back(&md->min_dq, entry);

    while (!dq_empty(&md->max_dq)
           && dq_back(&md->max_dq)->ivalue <= value) {
        dq_pop_back(&md->max_dq);
    }
    dq_push_back(&md->max_dq, entry);

    md->has_sample  = true;
    md->int_samples = true;
}

int64_t ds_series_mono_deque_min_int(const ds_series_mono_deque_t *md)
{
    const ds_mono_deque_t *dq = &md->min_dq;
    if (!md->has_sample || dq->head == dq->tail) return 0;
    return dq->buf[dq->head].ivalue;
}

int64_t ds_series_mono_deque_max_int(const ds_series_mono_deque_t *md)
{
    const ds_mono_deque_t *dq = &md->max_dq;
    if (!md->has_sample || dq->head == dq->tail) return 0;
    return dq->buf[dq->head].ivalue;
}

double ds_series_mono_deque_min(const ds_series_mono_deque_t *md)
{
    const ds_mono_deque_t *dq = &md->min_dq;
    if (!md->has_sample || dq->head == dq->tail) return 0.0;
    return dq->buf[dq->head].value;
}

double ds_series_mono_deque_max(const ds_series_mono_deque_t *md)
{
    const ds_mono_deque_t *dq = &md->max_dq;
    if (!md->has_sample || dq->head == dq->tail) return 0.0;
    return dq->buf[dq->head].value;
}
