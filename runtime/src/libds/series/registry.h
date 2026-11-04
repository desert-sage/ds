/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * series/registry.h — the series-backend registry, all of it internal
 * ([NSBK.2.3], ISBK.3). A backing is named by its atom's field number,
 * DS_ATOM_SERIES_BACKEND_* (series/backend.h).
 */
#ifndef LIBDS2_INTERNAL_SERIES_REGISTRY_H
#define LIBDS2_INTERNAL_SERIES_REGISTRY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "libds.h"
#include "backend.h"

struct ds_engine;

/* False when no backend is registered for the atom. */
bool ds_engine_series_backend_slot_by_atom(
    const struct ds_engine *engine,
    uint32_t                atom_field,
    size_t                 *out_slot);

/* Caller ensures slot < engine->n_backend_slots. */
const ds_series_backend_vtable_t *
ds_engine_series_backend_vtable_at(
    const struct ds_engine *engine, size_t slot);

/* The upper bound for a vtable's supported_aggs, by backing atom; 0 for a field
   number that names no backing. */
uint64_t ds_series_static_supported_aggs(uint32_t atom_field);

/* Dispose after every series_state row's instance_free. */
void ds_engine_series_registry_init(struct ds_engine *engine);
void ds_engine_series_registry_dispose(struct ds_engine *engine);

/*
 * Each vtable gets a stable slot id; a second registration of a backing atom is
 * DS_ERR_STATE. `opaque_handle` is held and never dereferenced.
 *
 * Errors: DS_ERR_INVAL (NULL engine/vtables), DS_ERR_BACKEND_ABI_VERSION,
 * DS_ERR_BACKEND_BAD_MAGIC, DS_ERR_BACKEND_BAD_AGGS.
 */
ds_result_t ds_engine_register_series_backend(
    struct ds_engine                         *engine,
    const ds_series_backend_vtable_t * const *vtables,
    size_t                                    n_vtables,
    void                                     *opaque_handle);

/* The ring buffer alone, for C unit tests that register a narrow set. */
ds_result_t ds_engine_register_ring_buffer_backend(struct ds_engine *engine);

#endif  /* LIBDS2_INTERNAL_SERIES_REGISTRY_H */
