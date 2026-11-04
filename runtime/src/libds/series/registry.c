/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * series/registry.c — series-backend registry (NSBK.2, ISBK.3).
 */

#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "ds_alloc.h"

#include "engine.h"
#include "registry.h"
#include "state.h"

/* ---- Per-backing static aggregation upper bound ---- */

#define SBWE_AGGS                                                \
    (DS_SERIES_AGG_BIT(DS_SERIES_AGG_AVG)            |          \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_STDEV)          |          \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_PSTDEV)         |          \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_VARIANCE)       |          \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_PVARIANCE)      |          \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_MIN)            |          \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_MAX)            |          \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_RATE)           |          \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_DIRECTION)      |          \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_COUNT)          |          \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_SUM)            |          \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_FIRST)          |          \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_LAST)           |          \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_BOOL_AND)       |          \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_BOOL_OR))

#define SBRB_AGGS                                                \
    (SBWE_AGGS |                                                  \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_MEDIAN)         |          \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_COUNT_DISTINCT)  |          \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_COUNT_OF)        |          \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_CONTAINS)        |          \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_PERCENTILE)      |          \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_ONSET_RATE))

#define SBMD_AGGS \
    (DS_SERIES_AGG_BIT(DS_SERIES_AGG_MIN) | DS_SERIES_AGG_BIT(DS_SERIES_AGG_MAX))

#define SBFD_AGGS \
    (DS_SERIES_AGG_BIT(DS_SERIES_AGG_FIRST)    | \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_LAST)     | \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_BOOL_OR)  | \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_BOOL_AND))

#define SBRS_AGGS \
    (DS_SERIES_AGG_BIT(DS_SERIES_AGG_AVG)          | \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_STDEV)        | \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_PSTDEV)       | \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_VARIANCE)     | \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_PVARIANCE)    | \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_MIN)          | \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_MAX)          | \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_SUM)          | \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_COUNT)        | \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_MEDIAN)       | \
     /* `pXX` rides the value-arg hook, as on SeriesBackendRingBuffer ([LSER.17.2]). */ \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_PERCENTILE)   | \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_BOOL_AND)     | \
     DS_SERIES_AGG_BIT(DS_SERIES_AGG_BOOL_OR))

#define SBIP_AGGS \
    (DS_SERIES_AGG_BIT(DS_SERIES_AGG_ACTIVE_FRACTION))

#define SBNI_AGGS \
    (DS_SERIES_AGG_BIT(DS_SERIES_AGG_INTEGRAL))

uint64_t ds_series_static_supported_aggs(uint32_t atom_field)
{
    switch (atom_field) {
    case DS_ATOM_SERIES_BACKEND_WELFORD_EWMA:     return SBWE_AGGS;
    case DS_ATOM_SERIES_BACKEND_RING_BUFFER:      return SBRB_AGGS;
    case DS_ATOM_SERIES_BACKEND_MONOTONIC_DEQUE:  return SBMD_AGGS;
    case DS_ATOM_SERIES_BACKEND_FIFO_DEQUE:       return SBFD_AGGS;
    case DS_ATOM_SERIES_BACKEND_RESERVOIR:        return SBRS_AGGS;
    case DS_ATOM_SERIES_BACKEND_INTERVAL_PULSE:   return SBIP_AGGS;
    case DS_ATOM_SERIES_BACKEND_NUMERIC_INTEGRAL: return SBNI_AGGS;
    default:                                      return 0;
    }
}

static bool backing_atom_known(uint32_t atom_field)
{
    return ds_series_static_supported_aggs(atom_field) != 0;
}

/* ---- Slot lookup ---- */

bool ds_engine_series_backend_slot_by_atom(
    const struct ds_engine *engine,
    uint32_t                atom_field,
    size_t                 *out_slot)
{
    for (size_t i = 0; i < engine->n_backend_slots; i++) {
        if (engine->backend_slots[i].vtable != NULL
            && engine->backend_slots[i].vtable->atom_field == atom_field) {
            *out_slot = i;
            return true;
        }
    }
    return false;
}

const ds_series_backend_vtable_t *
ds_engine_series_backend_vtable_at(
    const struct ds_engine *engine, size_t slot)
{
    return engine->backend_slots[slot].vtable;
}

/* ---- Init / dispose ---- */

void ds_engine_series_registry_init(struct ds_engine *engine)
{
    engine->backend_slots = NULL;
    engine->n_backend_slots = 0;
    engine->cap_backend_slots = 0;
}

void ds_engine_series_registry_dispose(struct ds_engine *engine)
{
    /* The caller disposes the series-state registry first: its rows hold
       instances these vtables free. */
    DS_FREE(engine->backend_slots);
    engine->backend_slots = NULL;
    engine->n_backend_slots = 0;
    engine->cap_backend_slots = 0;
}

/* ---- Registration primitive ---- */

static ds_result_t validate_one_vtable(
    const ds_series_backend_vtable_t *v)
{
    if (v == NULL) {
        return DS_ERR_R(DS_ERR_INVAL,
                        "series-backend: NULL vtable in list");
    }
    if (v->abi_version != DS_SERIES_BACKEND_ABI_VERSION) {
        return DS_ERR_R(
            DS_ERR_BACKEND_ABI_VERSION,
            "series-backend: vtable abi_version mismatch");
    }
    if (!backing_atom_known(v->atom_field)) {
        return DS_ERR_R(
            DS_ERR_BACKEND_BAD_MAGIC,
            "series-backend: vtable atom_field names no backing");
    }
    uint64_t static_set = ds_series_static_supported_aggs(v->atom_field);
    if ((v->supported_aggs & ~static_set) != 0) {
        return DS_ERR_R(
            DS_ERR_BACKEND_BAD_AGGS,
            "series-backend: supported_aggs claims aggs outside the "
            "backing's static set (per ISBK.3.2)");
    }
    if (v->instance_new == NULL
        || v->instance_free == NULL
        || v->update == NULL
        || v->query == NULL) {
        return DS_ERR_R(
            DS_ERR_INVAL,
            "series-backend: vtable missing required function pointer");
    }
    return DS_OK_R;
}

static ds_result_t append_slot(
    ds_engine_t                       *engine,
    const ds_series_backend_vtable_t  *vtable,
    void                              *opaque_handle,
    size_t                            *out_slot)
{
    size_t existing;
    if (ds_engine_series_backend_slot_by_atom(
            engine, vtable->atom_field, &existing)) {
        return DS_ERR_R(
            DS_ERR_INVAL,
            "series-backend: replacement of an already-registered "
            "backing is not supported in v1 (engine state migration "
            "is the gating concern)");
    }
    if (engine->n_backend_slots == engine->cap_backend_slots) {
        size_t new_cap = engine->cap_backend_slots == 0
                       ? 4 : engine->cap_backend_slots * 2;
        void *na = DS_REALLOC(engine->backend_slots,
                           new_cap * sizeof(*engine->backend_slots));
        if (na == NULL) {
            return DS_ERR_R(
                DS_ERR_OOM,
                "series-backend: slot table growth allocation failed");
        }
        engine->backend_slots = na;
        memset((char *) engine->backend_slots
                 + engine->cap_backend_slots * sizeof(*engine->backend_slots),
               0,
               (new_cap - engine->cap_backend_slots)
                 * sizeof(*engine->backend_slots));
        engine->cap_backend_slots = new_cap;
    }
    size_t slot = engine->n_backend_slots;
    engine->backend_slots[slot].vtable = vtable;
    engine->backend_slots[slot].opaque_handle = opaque_handle;
    engine->n_backend_slots++;
    ds_result_t gr = ds_series_state_registry_grow_slots(
        engine, &engine->series_state, engine->n_backend_slots);
    if (gr.status != DS_OK) {
        engine->n_backend_slots--;
        engine->backend_slots[slot].vtable = NULL;
        engine->backend_slots[slot].opaque_handle = NULL;
        return gr;
    }
    *out_slot = slot;
    return DS_OK_R;
}

ds_result_t ds_engine_register_series_backend(
    ds_engine_t                              *engine,
    const ds_series_backend_vtable_t * const *vtables,
    size_t                                    n_vtables,
    void                                     *opaque_handle)
{
    if (engine == NULL || (vtables == NULL && n_vtables > 0)) {
        return DS_ERR_R(DS_ERR_INVAL,
            "ds_engine_register_series_backend: NULL engine or vtables");
    }
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    /* Validated first, so a bad entry mid-list registers nothing. */
    for (size_t i = 0; i < n_vtables; i++) {
        ds_result_t vr = validate_one_vtable(vtables[i]);
        if (vr.status != DS_OK) return vr;
    }
    /* One backend per backing ([NSBK.2.3]), refused whole: checked against the
       registered slots and within the list before anything is appended. */
    for (size_t i = 0; i < n_vtables; i++) {
        size_t existing;
        if (ds_engine_series_backend_slot_by_atom(
                engine, vtables[i]->atom_field, &existing))
            return DS_ERR_R(DS_ERR_STATE,
                "ds_engine_register_series_backend: a backend for this "
                "backing is already registered (ds_engine_new registers the "
                "closed set)");
        for (size_t j = 0; j < i; j++) {
            if (vtables[j]->atom_field == vtables[i]->atom_field)
                return DS_ERR_R(DS_ERR_STATE,
                    "ds_engine_register_series_backend: two vtables for one "
                    "backing in the list");
        }
    }
    /* opaque_handle attaches to the first slot only. */
    bool first = true;
    for (size_t i = 0; i < n_vtables; i++) {
        size_t slot;
        ds_result_t ar = append_slot(
            engine, vtables[i],
            first ? opaque_handle : NULL,
            &slot);
        if (ar.status != DS_OK) return ar;
        first = false;
    }
    return DS_OK_R;
}

