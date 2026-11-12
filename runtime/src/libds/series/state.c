/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * series/state.c — opaque per-key series-state registry. Engine teardown calls
 * each backend's instance_free before this module's dispose runs.
 */

#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "ds_alloc.h"

#include "engine.h"
#include "backend.h"
#include "state.h"

/* FNV-1a over the 4 key strings and the window ([RDSC.5a.8.1]). */
#define SMAP_MAX_LOAD 70u

static uint32_t smap_hash(const char *a, const char *b,
                            const char *c, const char *d,
                            uint64_t window_ns)
{
    uint32_t h = 2166136261u;
#define FNV_STR(s) do { \
    for (const char *_p = (s); *_p; _p++) { h ^= (uint8_t)*_p; h *= 16777619u; } \
    h ^= 0xFF; h *= 16777619u; /* separator */ \
} while (0)
    FNV_STR(a); FNV_STR(b); FNV_STR(c); FNV_STR(d);
#undef FNV_STR
    for (unsigned i = 0; i < 8; i++) {
        h ^= (uint8_t)(window_ns >> (i * 8));
        h *= 16777619u;
    }
    return h;
}

static bool smap_key_eq(const ds_series_map_entry_t *e,
                         const char *schema, const char *slot,
                         const char *id_slot, const char *id_val,
                         uint64_t window_ns)
{
    return e->window_ns == window_ns
        && strcmp(e->schema_name, schema) == 0
        && strcmp(e->slot_name, slot) == 0
        && strcmp(e->identity_slot_name, id_slot) == 0
        && strcmp(e->identity_value, id_val) == 0;
}

/* Rebuild or grow the hash map to fit need entries. */
static void smap_grow(ds_series_state_registry_t *reg, size_t need)
{
    size_t cap = reg->row_map_cap ? reg->row_map_cap : 8;
    while (cap * SMAP_MAX_LOAD / 100 < need) cap <<= 1;
    if (cap == reg->row_map_cap) return;

    ds_series_map_entry_t *nb = DS_CALLOC(cap, sizeof(*nb));
    if (!nb) { /* OOM: fall back to linear scan */
        DS_FREE(reg->row_map);
        reg->row_map = NULL;
        reg->row_map_cap = 0;
        return;
    }
    /* Rehash from row strings (stable across rows realloc). */
    for (size_t i = 0; i < reg->n_rows; i++) {
        ds_series_state_row_t *r = &reg->rows[i];
        uint32_t h = smap_hash(r->schema_name, r->slot_name,
                                r->identity_slot_name, r->identity_value,
                                r->window_ns)
                     & (uint32_t)(cap - 1);
        while (nb[h].schema_name) h = (h + 1) & (uint32_t)(cap - 1);
        nb[h].schema_name       = r->schema_name;
        nb[h].slot_name         = r->slot_name;
        nb[h].identity_slot_name = r->identity_slot_name;
        nb[h].identity_value    = r->identity_value;
        nb[h].window_ns         = r->window_ns;
        nb[h].row_idx           = i;
    }
    DS_FREE(reg->row_map);
    reg->row_map     = nb;
    reg->row_map_cap = cap;
}

void ds_series_state_registry_init(ds_series_state_registry_t *reg)
{
    reg->rows           = NULL;
    reg->n_rows         = 0;
    reg->cap_rows       = 0;
    reg->row_map        = NULL;
    reg->row_map_cap    = 0;
    reg->row_map_locked = false;
}

void ds_series_state_registry_lock(ds_series_state_registry_t *reg)
{
    if (reg) reg->row_map_locked = true;
}

static void row_dispose_keys(ds_series_state_row_t *row)
{
    DS_FREE(row->schema_name);
    DS_FREE(row->slot_name);
    DS_FREE(row->identity_slot_name);
    DS_FREE(row->identity_value);
    DS_FREE(row->backend_state);
    DS_FREE(row->cap_ts);
    row->cap_ts = NULL;
    row->cap_ts_n = 0;
    row->cap_ts_cap = 0;
    DS_FREE(row->held_str);
    row->held_str = NULL;
    row->has_last_value = false;
    row->schema_name = NULL;
    row->slot_name = NULL;
    row->identity_slot_name = NULL;
    row->identity_value = NULL;
    row->backend_state = NULL;
    row->n_slots = 0;
}

void ds_series_state_registry_dispose(
    ds_series_state_registry_t *reg)
{
    if (reg == NULL) return;
    for (size_t i = 0; i < reg->n_rows; i++) {
        row_dispose_keys(&reg->rows[i]);
    }
    DS_FREE(reg->rows);
    DS_FREE(reg->row_map);
    reg->rows        = NULL;
    reg->row_map     = NULL;
    reg->n_rows      = reg->cap_rows    = 0;
    reg->row_map_cap = 0;
}

ds_series_state_row_t *ds_series_state_lookup(
    ds_series_state_registry_t *reg,
    const char                 *schema_name,
    const char                 *slot_name,
    const char                 *identity_slot_name,
    const char                 *identity_value,
    uint64_t                    window_ns)
{
    if (reg->row_map && reg->row_map_cap) {
        uint32_t cap = (uint32_t)reg->row_map_cap;
        uint32_t h   = smap_hash(schema_name, slot_name,
                                  identity_slot_name, identity_value,
                                  window_ns)
                       & (cap - 1);
        for (;;) {
            ds_series_map_entry_t *e = &reg->row_map[h];
            if (!e->schema_name) return NULL;
            if (smap_key_eq(e, schema_name, slot_name,
                            identity_slot_name, identity_value, window_ns))
                return &reg->rows[e->row_idx];
            h = (h + 1) & (cap - 1);
        }
    }
    /* Fallback: linear scan (map not built or OOM). */
    for (size_t i = 0; i < reg->n_rows; i++) {
        ds_series_state_row_t *row = &reg->rows[i];
        if (row->window_ns == window_ns
            && strcmp(row->schema_name, schema_name) == 0
            && strcmp(row->slot_name, slot_name) == 0
            && strcmp(row->identity_slot_name, identity_slot_name) == 0
            && strcmp(row->identity_value, identity_value) == 0) {
            return row;
        }
    }
    return NULL;
}

/* Grow a single row's backend_state array up to new_slots, zero-
   filling new entries. Returns true on success; false (with the
   engine pending-error slot set) on OOM. */
static bool grow_row_slots(struct ds_engine *engine,
                           ds_series_state_row_t *row,
                           size_t new_slots)
{
    if (new_slots <= row->n_slots) return true;
    void **na = DS_REALLOC(row->backend_state,
                        new_slots * sizeof(*row->backend_state));
    if (na == NULL) {
        ds_engine_set_pending(
            engine,
            DS_ERR_R(DS_ERR_OOM,
                "series: row backend_state growth failed"));
        return false;
    }
    memset(na + row->n_slots, 0,
           (new_slots - row->n_slots) * sizeof(*na));
    row->backend_state = na;
    row->n_slots = new_slots;
    return true;
}

ds_series_state_row_t *ds_series_state_lookup_or_insert(
    struct ds_engine           *engine,
    ds_series_state_registry_t *reg,
    size_t                      current_slot_count,
    const char                 *schema_name,
    const char                 *slot_name,
    const char                 *identity_slot_name,
    const char                 *identity_value,
    uint64_t                    window_ns)
{
    ds_series_state_row_t *existing = ds_series_state_lookup(
        reg, schema_name, slot_name,
        identity_slot_name, identity_value, window_ns);
    if (existing != NULL) {
        if (existing->n_slots < current_slot_count) {
            if (!grow_row_slots(engine, existing, current_slot_count)) {
                return NULL;
            }
        }
        return existing;
    }

    if (reg->row_map_locked) {
        ds_engine_set_pending(
            engine,
            DS_ERR_R(DS_ERR_RT_UNSAFE,
                     "series: new identity key seen in LIVE mode; "
                     "all series keys must be present before go_live (RETE8)"));
        return NULL;
    }

    /* `rows == NULL` is never independently true. It is for the static
       analyzer, which cannot see an invariant spanning rows and cap_rows. */
    if (reg->rows == NULL || reg->n_rows == reg->cap_rows) {
        size_t new_cap = reg->cap_rows == 0 ? 8 : reg->cap_rows * 2;
        void *na = DS_REALLOC(reg->rows,
                           new_cap * sizeof(*reg->rows));
        if (na == NULL) {
            ds_engine_set_pending(
                engine,
                DS_ERR_R(DS_ERR_OOM,
                    "series: registry growth allocation failed"));
            return NULL;
        }
        reg->rows = na;
        memset(&reg->rows[reg->cap_rows], 0,
               (new_cap - reg->cap_rows) * sizeof(*reg->rows));
        reg->cap_rows = new_cap;
    }

    ds_series_state_row_t *row = &reg->rows[reg->n_rows];
    row->schema_name = DS_STRDUP(schema_name);
    row->slot_name = DS_STRDUP(slot_name);
    row->identity_slot_name = DS_STRDUP(identity_slot_name);
    row->identity_value = DS_STRDUP(identity_value);
    row->window_ns = window_ns;
    row->backend_state = NULL;
    row->n_slots = 0;
    row->last_absorbed_ts_ns = 0;
    row->has_absorbed = false;
    row->absorb_count = 0;
    row->cap_ts = NULL;
    row->cap_ts_n = 0;
    row->cap_ts_cap = 0;
    memset(&row->last_value, 0, sizeof(row->last_value));
    row->held_str = NULL;
    row->has_last_value = false;
    if (row->schema_name == NULL
        || row->slot_name == NULL
        || row->identity_slot_name == NULL
        || row->identity_value == NULL) {
        row_dispose_keys(row);
        ds_engine_set_pending(
            engine,
            DS_ERR_R(DS_ERR_OOM,
                "series: registry key strdup failed"));
        return NULL;
    }
    if (current_slot_count > 0) {
        if (!grow_row_slots(engine, row, current_slot_count)) {
            row_dispose_keys(row);
            return NULL;
        }
    }
    size_t new_idx = reg->n_rows++;

    smap_grow(reg, reg->n_rows);
    if (reg->row_map && reg->row_map_cap) {
        uint32_t cap = (uint32_t)reg->row_map_cap;
        uint32_t h   = smap_hash(row->schema_name, row->slot_name,
                                  row->identity_slot_name, row->identity_value,
                                  row->window_ns)
                       & (cap - 1);
        while (reg->row_map[h].schema_name)
            h = (h + 1) & (cap - 1);
        reg->row_map[h].schema_name        = row->schema_name;
        reg->row_map[h].slot_name          = row->slot_name;
        reg->row_map[h].identity_slot_name = row->identity_slot_name;
        reg->row_map[h].identity_value     = row->identity_value;
        reg->row_map[h].window_ns          = row->window_ns;
        reg->row_map[h].row_idx            = new_idx;
    }

    return row;
}

ds_result_t ds_series_state_registry_grow_slots(
    struct ds_engine           *engine,
    ds_series_state_registry_t *reg,
    size_t                      new_slot_count)
{
    for (size_t i = 0; i < reg->n_rows; i++) {
        if (!grow_row_slots(engine, &reg->rows[i], new_slot_count)) {
            return DS_ERR_R(
                DS_ERR_OOM,
                "series: registry slot growth failed mid-row");
        }
    }
    return DS_OK_R;
}

static bool str_eq(const char *a, const char *b)
{
    return strcmp(a != NULL ? a : "", b != NULL ? b : "") == 0;
}

/* Whether `d` is one of the backings that feed `row`: the row's whole key but
   the identity value ([RDSC.5a.8.1]), so two labelled windows on one slot are
   two rows, each fed by its own decls. */
static bool decl_feeds_row(const struct ds_series_decl_record *d,
                           const ds_series_state_row_t        *row)
{
    return str_eq(d->schema_name, row->schema_name)
        && str_eq(d->slot_name, row->slot_name)
        && str_eq(d->identity_slot_name, row->identity_slot_name)
        && d->window_ns == row->window_ns;
}

/* [LSER.9.3.1]: a sliding backing that a window of silence leaves empty. The
   ring, monotonic and FIFO backings hold samples alone, except a Bool ring
   buffer: it carries `onset_rate`'s rising edges, its last value and `t_first`
   ([LSER.19.7], [LSIG.1.4.1]), and the backing cannot tell whether the program
   reads them. This reads [LSER.9.3.1]'s signal-state exception as covering
   every backing a signal aggregation can read, whatever else reads it. The step
   backings (interval pulse, numeric integral) are signal state ([LSIG.1.1]) and
   never evicted. */
static bool decl_evicts_on_silence(const struct ds_series_decl_record *d)
{
    switch (d->atom_field) {
    case DS_ATOM_SERIES_BACKEND_RING_BUFFER:
        return d->element_type != (uint32_t) DS_SERIES_ELEMENT_BOOL;
    case DS_ATOM_SERIES_BACKEND_MONOTONIC_DEQUE:
    case DS_ATOM_SERIES_BACKEND_FIFO_DEQUE:
        return true;
    default:
        return false;
    }
}

/* Whether a window of silence frees `row`. One row holds every backing on its
   (schema, slot, identity, window), and a free is the whole row's
   ([LSER.9.3.2]: the next sample cold-starts it), so one backing that must
   persist keeps the row. A row with no decl feeding it is left alone. */
static bool row_evicts_on_silence(struct ds_engine            *engine,
                                  const ds_series_state_row_t *row)
{
    bool fed = false;
    for (size_t i = 0; i < engine->n_series_decls; i++) {
        const struct ds_series_decl_record *d = &engine->series_decls[i];
        if (!decl_feeds_row(d, row)) continue;
        if (!decl_evicts_on_silence(d)) return false;
        fed = true;
    }
    return fed;
}

void ds_series_state_evict_stale(struct ds_engine *engine,
                                  uint64_t          now_ns)
{
    if (engine == NULL) return;
    ds_series_state_registry_t *reg = &engine->series_state;

    for (size_t i = 0; i < reg->n_rows; i++) {
        ds_series_state_row_t *row = &reg->rows[i];

        /* Pass 1: backend-internal stale-sample eviction. */
        for (size_t s = 0;
             s < row->n_slots && s < engine->n_backend_slots;
             s++) {
            if (row->backend_state[s] == NULL) continue;
            const ds_series_backend_vtable_t *vt =
                engine->backend_slots[s].vtable;
            if (vt == NULL || vt->evict_stale == NULL) continue;
            vt->evict_stale(row->backend_state[s], now_ns);
        }

        /* Pass 2: row-level free, by the row's own window ([LSER.9.3.1]).
           `has_absorbed`, since 0 is a real instant. */
        if (!row->has_absorbed) continue;
        if (row->window_ns == 0) continue;  /* bounded by max_samples instead */
        if (now_ns <= row->last_absorbed_ts_ns) continue;
        /* Free once the newest sample is at least W old: under the half-open
           (t−W, t] window ([LSER.14.1]) a sample exactly W old is already
           out, so the row holds nothing in its window. */
        if (now_ns - row->last_absorbed_ts_ns < row->window_ns) {
            continue;
        }
        if (!row_evicts_on_silence(engine, row)) continue;

        for (size_t s = 0;
             s < row->n_slots && s < engine->n_backend_slots;
             s++) {
            if (row->backend_state[s] == NULL) continue;
            const ds_series_backend_vtable_t *vt =
                engine->backend_slots[s].vtable;
            if (vt != NULL && vt->instance_free != NULL) {
                vt->instance_free(row->backend_state[s]);
            }
            row->backend_state[s] = NULL;
        }
        /* Row resets to "no samples": the next absorb cold-starts a
           fresh instance (LSER.9.3.1). The value `nulls: hold` repeats is not
           evicted ([LNUL.8.6]), so `last_value` and `held_str` stay. */
        row->last_absorbed_ts_ns = 0;
        row->has_absorbed        = false;
    }
}

/* [LSER.13.14]: the half-open (t−W, t] every series read uses. An instant after
   `now` counts as inside. */
static bool capacity_in_window(uint64_t ts, uint64_t now_ns, uint64_t window_ns)
{
    return ts > now_ns || now_ns - ts < window_ns;
}

bool ds_series_state_note_capacity_sample(struct ds_engine      *engine,
                                          ds_series_state_row_t *row,
                                          uint32_t               cap,
                                          uint64_t               window_ns,
                                          uint64_t               ts_ns)
{
    if (row == NULL || cap == 0 || window_ns == 0) return true;
    if (row->cap_ts == NULL) {
        row->cap_ts = DS_CALLOC(cap, sizeof(*row->cap_ts));
        if (row->cap_ts == NULL) {
            ds_engine_set_pending(engine, DS_ERR_R(DS_ERR_OOM,
                "series: capacity instants allocation failed"));
            return false;
        }
        row->cap_ts_cap = cap;
        row->cap_ts_n   = 0;
    }
    /* Front-trim what has left the window as of this sample. Instants are
       appended in absorb order, which is assert order, so they ascend. */
    uint32_t keep = 0;
    while (keep < row->cap_ts_n
           && !capacity_in_window(row->cap_ts[keep], ts_ns, window_ns))
        keep++;
    /* The assert-time check keeps the in-window count at or below `cap`, so
       the array is never full here. If it is anyway, the oldest goes: losing
       an instant under-counts by one, which is the direction that admits. */
    if (row->cap_ts_n - keep >= row->cap_ts_cap) keep++;
    if (keep > 0) {
        memmove(&row->cap_ts[0], &row->cap_ts[keep],
                (row->cap_ts_n - keep) * sizeof(*row->cap_ts));
        row->cap_ts_n -= keep;
    }
    row->cap_ts[row->cap_ts_n++] = ts_ns;
    return true;
}

uint32_t ds_series_state_capacity_retained(const ds_series_state_row_t *row,
                                           uint64_t now_ns,
                                           uint64_t window_ns)
{
    if (row == NULL || row->cap_ts == NULL) return 0;
    uint32_t n = 0;
    for (uint32_t i = 0; i < row->cap_ts_n; i++)
        if (capacity_in_window(row->cap_ts[i], now_ns, window_ns)) n++;
    return n;
}

bool ds_series_state_copy_capacity(ds_series_state_row_t       *dst,
                                   const ds_series_state_row_t *src)
{
    if (src->cap_ts == NULL) return true;
    dst->cap_ts = DS_CALLOC(src->cap_ts_cap, sizeof(*dst->cap_ts));
    if (dst->cap_ts == NULL) return false;
    memcpy(dst->cap_ts, src->cap_ts, src->cap_ts_n * sizeof(*dst->cap_ts));
    dst->cap_ts_n   = src->cap_ts_n;
    dst->cap_ts_cap = src->cap_ts_cap;
    return true;
}
