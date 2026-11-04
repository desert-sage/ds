/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * series/ring_buffer_backend.c — the vtable over ring_buffer.c. backend_name and
 * backend_version surface only in the platform signature (LDET.2.3).
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "libds.h"
#include "../engine.h"
#include "ring_buffer.h"

/* ------------------------------------------------------------------ */
/*  Element-type mapping                                               */
/* ------------------------------------------------------------------ */

static ds_series_ring_elem_t to_ring_elem(ds_series_element_type_t et)
{
    switch (et) {
    case DS_SERIES_ELEMENT_FLOAT:  return DS_SERIES_RING_ELEM_FLOAT;
    case DS_SERIES_ELEMENT_INT:    return DS_SERIES_RING_ELEM_INT;
    case DS_SERIES_ELEMENT_STRING: return DS_SERIES_RING_ELEM_STRING;
    case DS_SERIES_ELEMENT_BOOL:   return DS_SERIES_RING_ELEM_BOOL;
    default:                       return DS_SERIES_RING_ELEM_FLOAT;
    }
}

/* ------------------------------------------------------------------ */
/*  SeriesBackendRingBuffer vtable                                           */
/* ------------------------------------------------------------------ */

static ds_result_t sbrb_instance_new(const ds_series_decl_t *decl,
                                      void                  **out_state)
{
    ds_series_ring_buffer_t *rb = ds_series_ring_buffer_new(
        to_ring_elem(decl->element_type),
        decl->window_ns,
        decl->max_samples);
    if (rb == NULL) {
        return DS_ERR_R(DS_ERR_OOM, "ds-ring-buffer: instance_new alloc failed");
    }
    *out_state = rb;
    return DS_OK_R;
}

static void sbrb_instance_free(void *state)
{
    ds_series_ring_buffer_free((ds_series_ring_buffer_t *) state);
}

static ds_result_t sbrb_instance_clone(const void *state, void **out_state)
{
    ds_series_ring_buffer_t *c = ds_series_ring_buffer_clone(
        (const ds_series_ring_buffer_t *) state);
    if (c == NULL)
        return DS_ERR_R(DS_ERR_OOM, "ds-ring-buffer: instance_clone alloc failed");
    *out_state = c;
    return DS_OK_R;
}

static ds_result_t sbrb_update(void                   *state,
                                const ds_slot_value_t *value,
                                uint64_t                ts_ns)
{
    ds_series_ring_buffer_t *rb = state;
    switch (value->kind) {
    case DS_SLOT_FLOAT:
        ds_series_ring_buffer_update_float(rb, value->v.f, ts_ns);
        break;
    case DS_SLOT_INT:
        ds_series_ring_buffer_update_int(rb, value->v.i, ts_ns);
        break;
    case DS_SLOT_STRING:
        ds_series_ring_buffer_update_string(rb, value->v.s, ts_ns);
        break;
    case DS_SLOT_BOOL:
        ds_series_ring_buffer_update_bool(rb, value->v.b, ts_ns);
        break;
    default:
        return DS_ERR_R(
            DS_ERR_INVAL,
            "ds-ring-buffer: update value kind unsupported");
    }
    return DS_OK_R;
}

/* [LSER.17.2]: a cold window reads `null`; an OOM is a failed query. */
static ds_result_t sbrb_percentile(ds_series_ring_buffer_t *rb, unsigned pct,
                                   ds_slot_value_t *out_value)
{
    switch (ds_series_ring_buffer_percentile(rb, pct, &out_value->v.f)) {
    case DS_SERIES_RING_PCTL_VALUE:
        out_value->kind = DS_SLOT_FLOAT;
        return DS_OK_R;
    case DS_SERIES_RING_PCTL_EMPTY:
        out_value->kind = DS_SLOT_NULL;
        return DS_OK_R;
    case DS_SERIES_RING_PCTL_OOM:
    default:
        return DS_ERR_R(DS_ERR_OOM,
                        "ds-ring-buffer: percentile scratch alloc failed");
    }
}

static ds_result_t sbrb_query(void                 *state,
                               ds_series_agg_kind_t  agg_kind,
                               uint64_t              window_ns,
                               ds_slot_value_t      *out_value)
{
    (void) window_ns;
    ds_series_ring_buffer_t *rb = state;
    out_value->kind = DS_SLOT_FLOAT;
    switch (agg_kind) {
    case DS_SERIES_AGG_AVG:
        out_value->v.f = ds_series_ring_buffer_avg(rb);
        break;
    case DS_SERIES_AGG_MIN:
        out_value->v.f = ds_series_ring_buffer_min(rb);
        break;
    case DS_SERIES_AGG_MAX:
        out_value->v.f = ds_series_ring_buffer_max(rb);
        break;
    case DS_SERIES_AGG_COUNT:
        out_value->kind = DS_SLOT_INT;
        out_value->v.i = (int64_t) ds_series_ring_buffer_count(rb);
        break;
    case DS_SERIES_AGG_SUM:
        if (rb->element_type == DS_SERIES_RING_ELEM_INT) {
            out_value->kind = DS_SLOT_INT;
            out_value->v.i  = ds_series_ring_buffer_sum_int(rb);
        } else {
            out_value->v.f  = ds_series_ring_buffer_sum(rb);
        }
        break;
    case DS_SERIES_AGG_STDEV:
        if (!ds_series_ring_buffer_stdev(rb, &out_value->v.f))
            out_value->kind = DS_SLOT_NULL;
        break;
    case DS_SERIES_AGG_PSTDEV:
        out_value->v.f = ds_series_ring_buffer_pstdev(rb);
        break;
    case DS_SERIES_AGG_VARIANCE:
        if (!ds_series_ring_buffer_variance(rb, &out_value->v.f))
            out_value->kind = DS_SLOT_NULL;
        break;
    case DS_SERIES_AGG_PVARIANCE:
        out_value->v.f = ds_series_ring_buffer_pvariance(rb);
        break;
    case DS_SERIES_AGG_MEDIAN: return sbrb_percentile(rb, 50, out_value);
    case DS_SERIES_AGG_DIRECTION:
        out_value->kind = DS_SLOT_INT;
        if (!ds_series_ring_buffer_direction(rb, &out_value->v.i))
            out_value->kind = DS_SLOT_NULL;
        break;
    case DS_SERIES_AGG_COUNT_DISTINCT:
        out_value->kind = DS_SLOT_INT;
        out_value->v.i = (int64_t) ds_series_ring_buffer_count_distinct(rb);
        break;
    case DS_SERIES_AGG_ONSET_RATE:
        out_value->v.f = ds_series_ring_buffer_onset_rate(rb);
        break;
    case DS_SERIES_AGG_RATE:
        if (!ds_series_ring_buffer_rate(rb, &out_value->v.f))
            out_value->kind = DS_SLOT_NULL;
        break;
    default:
        return DS_ERR_R(
            DS_ERR_INVAL,
            "ds-ring-buffer: agg_kind not supported by this backend");
    }
    return DS_OK_R;
}

static void sbrb_evict_stale(void *state, uint64_t now_ns)
{
    ds_series_ring_buffer_evict_stale((ds_series_ring_buffer_t *) state,
                                       now_ns);
}

static ds_result_t sbrb_query_with_value(void                  *state,
                                          ds_series_agg_kind_t   agg_kind,
                                          uint64_t               window_ns,
                                          const ds_slot_value_t *lookup_value,
                                          uint32_t               k_param,
                                          ds_slot_value_t       *out_value)
{
    (void) window_ns; (void) k_param;
    ds_series_ring_buffer_t *rb = state;
    switch (agg_kind) {
    case DS_SERIES_AGG_COUNT_OF:
        out_value->kind = DS_SLOT_INT;
        out_value->v.i  =
            (int64_t) ds_series_ring_buffer_count_of(rb, lookup_value);
        return DS_OK_R;
    case DS_SERIES_AGG_CONTAINS:
        out_value->kind = DS_SLOT_BOOL;
        out_value->v.b  = ds_series_ring_buffer_contains(rb, lookup_value);
        return DS_OK_R;
    /* [LSER.17.2]: the percentile N arrives as the lookup value. */
    case DS_SERIES_AGG_PERCENTILE: {
        int64_t n = (lookup_value != NULL && lookup_value->kind == DS_SLOT_INT)
                        ? lookup_value->v.i : 50;
        unsigned pct = n < 0 ? 0u : n > 100 ? 100u : (unsigned) n;
        return sbrb_percentile(rb, pct, out_value);
    }
    default:
        return DS_ERR_R(
            DS_ERR_INVAL,
            "ds-ring-buffer: agg_kind not supported by query_with_value");
    }
}

/* Only onset_rate depends on t. */
static ds_result_t sbrb_query_at(void                 *state,
                                  ds_series_agg_kind_t  agg_kind,
                                  uint64_t              window_ns,
                                  uint64_t              now_ns,
                                  ds_slot_value_t      *out_value)
{
    if (agg_kind == DS_SERIES_AGG_ONSET_RATE) {
        out_value->kind = DS_SLOT_FLOAT;
        out_value->v.f  = ds_series_ring_buffer_onset_rate_at(
            (const ds_series_ring_buffer_t *) state, now_ns);
        return DS_OK_R;
    }
    return sbrb_query(state, agg_kind, window_ns, out_value);
}

static const ds_series_backend_vtable_t sbrb_vtable = {
    .abi_version     = DS_SERIES_BACKEND_ABI_VERSION,
    .backend_name    = "ds-ring-buffer",
    .backend_version = "1.0.0",
    .atom_field      = DS_ATOM_SERIES_BACKEND_RING_BUFFER,
    .supported_aggs  =
          DS_SERIES_AGG_BIT(DS_SERIES_AGG_AVG)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_MIN)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_MAX)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_COUNT)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_SUM)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_STDEV)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_PSTDEV)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_VARIANCE)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_PVARIANCE)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_MEDIAN)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_COUNT_DISTINCT)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_COUNT_OF)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_CONTAINS)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_PERCENTILE)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_ONSET_RATE)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_RATE)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_DIRECTION),
    .instance_new    = sbrb_instance_new,
    .instance_free   = sbrb_instance_free,
    .instance_clone  = sbrb_instance_clone,
    .update          = sbrb_update,
    .query           = sbrb_query,
    .evict_stale     = sbrb_evict_stale,
    .query_with_value = sbrb_query_with_value,
    .query_at        = sbrb_query_at,
};

/* ------------------------------------------------------------------ */
/*  Registration                                                       */
/* ------------------------------------------------------------------ */

ds_result_t ds_engine_register_ring_buffer_backend(ds_engine_t *engine)
{
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    static const ds_series_backend_vtable_t *const vtables[] = {
        &sbrb_vtable,
    };
    return ds_engine_register_series_backend(engine, vtables, 1, NULL);
}
