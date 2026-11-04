/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * series/fifo_deque.c — typed FIFO for exact sliding-window reads.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "fifo_deque.h"
#include "ds_alloc.h"    /* DS_MALLOC/CALLOC/FREE/STRDUP -- IALC.9.1 routing */

#define SBFD_INITIAL_CAP 16

/* ------------------------------------------------------------------ */
/*  Internal helpers                                                  */
/* ------------------------------------------------------------------ */

static size_t fd_size(const ds_series_fifo_deque_t *fd)
{
    return (fd->tail + fd->cap - fd->head) % fd->cap;
}

static bool fd_empty(const ds_series_fifo_deque_t *fd)
{
    return fd->head == fd->tail;
}

static bool fd_full(const ds_series_fifo_deque_t *fd)
{
    return (fd->tail + 1) % fd->cap == fd->head;
}

/* Grow buffer to 2× capacity. Returns false on OOM or fixed cap. */
static bool fd_grow(ds_series_fifo_deque_t *fd)
{
    if (fd->fixed_cap > 0) return false;
    size_t old_cap = fd->cap;
    size_t new_cap = old_cap * 2;
    ds_sbfd_entry_t *nb = DS_MALLOC(new_cap * sizeof(*nb));
    if (nb == NULL) return false;
    size_t n = fd_size(fd);
    for (size_t i = 0; i < n; i++)
        nb[i] = fd->buf[(fd->head + i) % old_cap];
    DS_FREE(fd->buf);
    fd->buf  = nb;
    fd->head = 0;
    fd->tail = n;
    fd->cap  = new_cap;
    return true;
}

static void entry_release(ds_sbfd_entry_t *e)
{
    DS_FREE(e->str_copy);
    e->str_copy  = NULL;
    e->value.v.s = NULL;
}

static void fd_pop_front(ds_series_fifo_deque_t *fd)
{
    if (fd_empty(fd)) return;
    ds_sbfd_entry_t *e = &fd->buf[fd->head];
    if (e->value.kind == DS_SLOT_BOOL && e->value.v.b)
        fd->bool_true_count--;
    entry_release(e);
    fd->head = (fd->head + 1) % fd->cap;
}

/* Silently drops on OOM. [LSER.13.14]: at a declared capacity the oldest sample
   goes. */
static void fd_push_back(ds_series_fifo_deque_t *fd,
                          ds_sbfd_entry_t        entry)
{
    if (fd_full(fd) && fd->fixed_cap > 0) fd_pop_front(fd);
    if (fd_full(fd) && !fd_grow(fd)) return;
    fd->buf[fd->tail] = entry;
    fd->tail = (fd->tail + 1) % fd->cap;
}

/* ------------------------------------------------------------------ */
/*  Public API                                                        */
/* ------------------------------------------------------------------ */

ds_series_fifo_deque_t *
ds_series_fifo_deque_new(uint64_t                 window_ns,
                          ds_series_element_type_t element_type,
                          size_t                   max_entries)
{
    ds_series_fifo_deque_t *fd = DS_CALLOC(1, sizeof(*fd));
    if (fd == NULL) return NULL;
    /* One slot of the circular buffer stays empty. */
    size_t init_cap = (max_entries > 0) ? max_entries + 1 : SBFD_INITIAL_CAP;
    fd->buf = DS_MALLOC(init_cap * sizeof(*fd->buf));
    if (fd->buf == NULL) { DS_FREE(fd); return NULL; }
    fd->cap          = init_cap;
    fd->fixed_cap    = (max_entries > 0) ? init_cap : 0;
    fd->window_ns    = window_ns;
    fd->element_type = element_type;
    return fd;
}

void ds_series_fifo_deque_free(ds_series_fifo_deque_t *fd)
{
    if (fd == NULL) return;
    while (!fd_empty(fd))
        fd_pop_front(fd);
    DS_FREE(fd->buf);
    DS_FREE(fd);
}

ds_series_fifo_deque_t *ds_series_fifo_deque_clone(
    const ds_series_fifo_deque_t *src)
{
    if (src == NULL) return NULL;
    ds_series_fifo_deque_t *fd = DS_CALLOC(1, sizeof(*fd));
    if (fd == NULL) return NULL;
    fd->window_ns       = src->window_ns;
    fd->element_type    = src->element_type;
    fd->head            = src->head;
    fd->tail            = src->tail;
    fd->cap             = src->cap;
    fd->fixed_cap       = src->fixed_cap;
    fd->bool_true_count = src->bool_true_count;
    fd->has_sample      = src->has_sample;
    /* calloc: every slot's str_copy starts NULL, so a partial-OOM free walks
       the live ring safely (owned-or-NULL, never a borrowed source pointer). */
    fd->buf = DS_CALLOC(src->cap, sizeof(*fd->buf));
    if (fd->buf == NULL) { DS_FREE(fd); return NULL; }
    for (size_t i = src->head; i != src->tail; i = (i + 1) % src->cap) {
        fd->buf[i]          = src->buf[i];   /* ts + value union */
        fd->buf[i].str_copy = NULL;          /* drop the borrowed pointer */
        if (src->buf[i].value.kind == DS_SLOT_STRING
            && src->buf[i].str_copy != NULL) {
            fd->buf[i].str_copy = DS_STRDUP(src->buf[i].str_copy);
            if (fd->buf[i].str_copy == NULL) {
                ds_series_fifo_deque_free(fd);
                return NULL;
            }
            fd->buf[i].value.v.s = fd->buf[i].str_copy;
        }
    }
    return fd;
}

void ds_series_fifo_deque_evict_stale(ds_series_fifo_deque_t *fd,
                                       uint64_t                now_ns)
{
    /* Half-open (t−W, t] ([LSER.14.1], [LSIG.2.2.4]): an entry exactly W old
       is out. Before t reaches W nothing is. */
    if (fd->window_ns == 0 || now_ns < fd->window_ns) return;
    uint64_t threshold = now_ns - fd->window_ns;
    while (!fd_empty(fd)
           && fd->buf[fd->head].ts_ns <= threshold) {
        fd_pop_front(fd);
    }
}

void ds_series_fifo_deque_update(ds_series_fifo_deque_t *fd,
                                  const ds_slot_value_t  *value,
                                  uint64_t                ts_ns)
{
    ds_series_fifo_deque_evict_stale(fd, ts_ns);

    ds_sbfd_entry_t e = { .ts_ns = ts_ns, .value = *value, .str_copy = NULL };
    if (value->kind == DS_SLOT_STRING && value->v.s) {
        e.str_copy  = DS_STRDUP(value->v.s);
        e.value.v.s = e.str_copy;
    }

    if (value->kind == DS_SLOT_BOOL && value->v.b)
        fd->bool_true_count++;

    fd_push_back(fd, e);
    fd->has_sample = true;
}

ds_slot_value_t ds_series_fifo_deque_first(
    const ds_series_fifo_deque_t *fd)
{
    ds_slot_value_t def = { .kind = DS_SLOT_FLOAT, .v = { .f = 0.0 } };
    if (fd_empty(fd)) return def;
    return fd->buf[fd->head].value;
}

ds_slot_value_t ds_series_fifo_deque_last(
    const ds_series_fifo_deque_t *fd)
{
    ds_slot_value_t def = { .kind = DS_SLOT_FLOAT, .v = { .f = 0.0 } };
    if (fd_empty(fd)) return def;
    size_t last_idx = (fd->tail + fd->cap - 1) % fd->cap;
    return fd->buf[last_idx].value;
}

bool ds_series_fifo_deque_bool_or(const ds_series_fifo_deque_t *fd)
{
    return fd->bool_true_count > 0;
}

bool ds_series_fifo_deque_bool_and(const ds_series_fifo_deque_t *fd)
{
    size_t n = fd_size(fd);
    return n > 0 && fd->bool_true_count == n;
}
