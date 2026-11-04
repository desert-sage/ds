/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * series/state.h — the series-state registry, by (schema, slot, identity slot,
 * identity value, window). Opaque handles per ISBK.1.2. A row exists only once a
 * sample for its key has arrived (LSER.7.6, LSER.9.1.1).
 */
#ifndef LIBDS2_INTERNAL_SERIES_STATE_H
#define LIBDS2_INTERNAL_SERIES_STATE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "libds.h"

struct ds_engine;

/* backend_state is indexed by registration-time slot id; NULL is no instance yet.
   `last_absorbed_ts_ns` means something only with `has_absorbed`: 0 is a real
   instant. */
typedef struct ds_series_state_row {
    char *schema_name;
    char *slot_name;
    char *identity_slot_name;
    char *identity_value;
    uint64_t window_ns;   /* [RDSC.5a.8.1]: part of the key */

    void   **backend_state;
    size_t   n_slots;
    uint64_t last_absorbed_ts_ns;
    bool     has_absorbed;   /* false until the first successful sample */

    uint64_t absorb_count;

    /* [LSER.13.14]: the instants of the samples a step backing on a window has
       absorbed, oldest first, at most `max_samples`, since neither step backing
       stores its samples. The carry is not counted. NULL until the first such
       absorb; unused on every other backing. */
    uint64_t *cap_ts;
    uint32_t  cap_ts_n;
    uint32_t  cap_ts_cap;

    /* [LNUL.8.6] `nulls: hold`: the last value absorbed, whether or not the
       window still holds it. A STRING is copied into row-owned `held_str`. */
    ds_slot_value_t last_value;
    char    *held_str;
    bool     has_last_value;
} ds_series_state_row_t;

typedef struct {
    const char *schema_name;       /* points into row strings; NULL = empty */
    const char *slot_name;
    const char *identity_slot_name;
    const char *identity_value;
    uint64_t    window_ns;         /* RDSC.5a.8.1 — part of the key */
    size_t      row_idx;           /* index into rows[]; stable across realloc */
} ds_series_map_entry_t;

/* Engine-level series-state registry. */
typedef struct ds_series_state_registry {
    ds_series_state_row_t *rows;
    size_t                 n_rows;
    size_t                 cap_rows;
    ds_series_map_entry_t *row_map;   /* open addressing, key to row index */
    size_t                 row_map_cap;
    /* lookup_or_insert then refuses a new row with DS_ERR_RT_UNSAFE. */
    bool row_map_locked;
} ds_series_state_registry_t;

void ds_series_state_registry_init(ds_series_state_registry_t *reg);

void ds_series_state_registry_lock(ds_series_state_registry_t *reg);

/* Frees only the row bookkeeping: call after instance_free for every non-NULL
   slot. */
void ds_series_state_registry_dispose(
    ds_series_state_registry_t *reg);

ds_series_state_row_t *ds_series_state_lookup(
    ds_series_state_registry_t *reg,
    const char                 *schema_name,
    const char                 *slot_name,
    const char                 *identity_slot_name,
    const char                 *identity_value,
    uint64_t                    window_ns);

/* Look up or insert a row for the given key. The returned row's
   backend_state array is sized to fit current_slot_count so the
   caller can index into it without bounds checking. Returns NULL
   on OOM (the engine's pending-error slot is set). */
ds_series_state_row_t *ds_series_state_lookup_or_insert(
    struct ds_engine           *engine,
    ds_series_state_registry_t *reg,
    size_t                      current_slot_count,
    const char                 *schema_name,
    const char                 *slot_name,
    const char                 *identity_slot_name,
    const char                 *identity_value,
    uint64_t                    window_ns);

/* Grow every row's backend_state array to at least new_slot_count
   entries (zero-filled). Called when a backend registration
   pushes the engine's slot count above what existing rows know
   about. Returns DS_OK_R on success; DS_ERR_OOM on allocation
   failure (the engine's pending slot is set; partially-grown
   rows stay valid — n_slots reflects what was actually allocated). */
ds_result_t ds_series_state_registry_grow_slots(
    struct ds_engine           *engine,
    ds_series_state_registry_t *reg,
    size_t                      new_slot_count);

/* [LSER.9.3]. Two passes per row: evict_stale on each populated backend; then
   instance_free on a silent ring, monotonic or FIFO row, whose next absorb
   cold-starts. */
void ds_series_state_evict_stale(struct ds_engine *engine,
                                  uint64_t          now_ns);

/* [LSER.13.14] record one absorbed sample's instant on a refusing row,
   dropping instants that can no longer be inside the window. `cap` is the
   declared `max_samples`. Returns false on OOM (the engine's pending slot is
   set); the sample itself has already been absorbed. */
bool ds_series_state_note_capacity_sample(struct ds_engine      *engine,
                                          ds_series_state_row_t *row,
                                          uint32_t               cap,
                                          uint64_t               window_ns,
                                          uint64_t               ts_ns);

/* [LSER.13.14] how many of the row's noted samples are inside the window as
   of `now_ns` — `now_ns - ts < window_ns`, the carry excluded. 0 for NULL. */
uint32_t ds_series_state_capacity_retained(const ds_series_state_row_t *row,
                                           uint64_t now_ns,
                                           uint64_t window_ns);

/* Deep-copy a row's noted instants into another row (ds_engine_clone).
   Returns false on OOM. */
bool ds_series_state_copy_capacity(ds_series_state_row_t       *dst,
                                   const ds_series_state_row_t *src);

#endif  /* LIBDS2_INTERNAL_SERIES_STATE_H */
