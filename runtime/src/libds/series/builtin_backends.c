/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * series/builtin_backends.c — the six non-ring-buffer backends libds ships,
 * and the one call that registers all seven.
 *
 * `backend_name` and `backend_version` reach `ds_platform_signature.backends`,
 * whose seven entries [NDET.2.5] fixes; the runtime differential's platform
 * check holds the Mercury runtime's copy to that table.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "ds_alloc.h"    /* DS_FREE/STRDUP -- IALC.9.1 routing */

#include "reservoir.h"
#include "fifo_deque.h"
#include "monotonic_deque.h"
#include "welford_ewma.h"
#include "interval_pulse.h"
#include "numeric_integral.h"
#include "registry.h"
#include "builtin_backends.h"

/* ------------------------------------------------------------------ */
/*  SeriesBackendWelfordEwma — Welford-EWMA accumulator backend              */
/* ------------------------------------------------------------------ */

static ds_result_t sbwe_instance_new(const ds_series_decl_t *decl,
                                      void                  **out_state)
{
    /* Cumulative from boot, whatever the window says ([RDSC.5a.4.3]). */
    (void) decl;
    ds_series_welford_ewma_t *we = ds_series_welford_ewma_new();
    if (we == NULL) {
        return DS_ERR_R(DS_ERR_OOM, "ds-sbwe: instance_new alloc failed");
    }
    *out_state = we;
    return DS_OK_R;
}

static void sbwe_instance_free(void *state)
{
    ds_series_welford_ewma_free((ds_series_welford_ewma_t *) state);
}

static ds_result_t sbwe_instance_clone(const void *state, void **out_state)
{
    ds_series_welford_ewma_t *c = ds_series_welford_ewma_clone(
        (const ds_series_welford_ewma_t *) state);
    if (c == NULL)
        return DS_ERR_R(DS_ERR_OOM, "ds-sbwe: instance_clone alloc failed");
    *out_state = c;
    return DS_OK_R;
}

/* Store value into typed_last, managing the owned string copy. */
static void sbwe_set_typed(ds_slot_value_t *dst, char **dst_str,
                           const ds_slot_value_t *src)
{
    if (src->kind == DS_SLOT_STRING) {
        /* welford_ewma.c owns and frees the copy, through the same layer. */
        char *copy = (src->v.s && src->v.s[0]) ? DS_STRDUP(src->v.s) : NULL;
        DS_FREE(*dst_str);
        *dst_str = copy;
        dst->kind = DS_SLOT_STRING;
        dst->v.s  = copy;
    } else {
        DS_FREE(*dst_str);
        *dst_str = NULL;
        *dst = *src;
    }
}

static ds_result_t sbwe_update(void                   *state,
                                const ds_slot_value_t *value,
                                uint64_t                ts_ns)
{
    ds_series_welford_ewma_t *we = state;

    /* `direction`'s previous sample, numeric only ([LSER.10.9]). A numeric
       typed_last owns no string. */
    if (we->has_sample
        && (we->typed_last.kind == DS_SLOT_INT
            || we->typed_last.kind == DS_SLOT_FLOAT)) {
        we->typed_prev     = we->typed_last;
        we->has_typed_prev = true;
    }

    sbwe_set_typed(&we->typed_last, &we->typed_last_str, value);

    if (!we->has_typed_first) {
        sbwe_set_typed(&we->typed_first, &we->typed_first_str, value);
        we->has_typed_first = true;
    }

    double v;
    switch (value->kind) {
    case DS_SLOT_FLOAT:
        v = value->v.f;
        ds_series_welford_ewma_update(we, v, ts_ns);
        we->sum_f += v;
        break;
    case DS_SLOT_INT:
        v = (double) value->v.i;
        ds_series_welford_ewma_update(we, v, ts_ns);
        we->sum_f += v;
        /* [LSER.17.2], [LSER.16.2.2]: an Int sum wraps, as defined C. */
        we->sum_i = (int64_t) ((uint64_t) we->sum_i + (uint64_t) value->v.i);
        /* Exact Int extremes; the first Int sample seeds both. */
        if (!we->sum_is_int || value->v.i < we->min_i) we->min_i = value->v.i;
        if (!we->sum_is_int || value->v.i > we->max_i) we->max_i = value->v.i;
        we->sum_is_int = true;
        break;
    case DS_SLOT_BOOL:
        /* Count only: mean, stdev, min and max stay at 0. */
        ds_series_welford_ewma_update_count_only(we, ts_ns);
        we->bool_total_count++;
        if (value->v.b) we->bool_true_count++;
        break;
    default:
        ds_series_welford_ewma_update_count_only(we, ts_ns);
        break;
    }
    return DS_OK_R;
}

static ds_result_t sbwe_query(void                 *state,
                               ds_series_agg_kind_t  agg_kind,
                               uint64_t              window_ns,
                               ds_slot_value_t      *out_value)
{
    (void) window_ns;
    ds_series_welford_ewma_t *we = state;
    out_value->kind = DS_SLOT_FLOAT;
    switch (agg_kind) {
    case DS_SERIES_AGG_AVG:
        out_value->v.f = ds_series_welford_ewma_avg(we);
        break;
    /* [LSER.16.3.3]: the sample forms have no value at one sample. */
    case DS_SERIES_AGG_STDEV:
        if (!ds_series_welford_ewma_stdev(we, &out_value->v.f))
            out_value->kind = DS_SLOT_NULL;
        break;
    case DS_SERIES_AGG_PSTDEV:
        out_value->v.f = ds_series_welford_ewma_pstdev(we);
        break;
    case DS_SERIES_AGG_VARIANCE:
        if (!ds_series_welford_ewma_variance(we, &out_value->v.f))
            out_value->kind = DS_SLOT_NULL;
        break;
    case DS_SERIES_AGG_PVARIANCE:
        out_value->v.f = ds_series_welford_ewma_pvariance(we);
        break;
    /* Over an Int slot the exact track: two Ints above 2^53 can share a double
       ([LSER.17.2]). */
    case DS_SERIES_AGG_MIN:
        if (we->sum_is_int) {
            out_value->kind = DS_SLOT_INT;
            out_value->v.i  = we->min_i;
        } else {
            out_value->v.f = ds_series_welford_ewma_min(we);
        }
        break;
    case DS_SERIES_AGG_MAX:
        if (we->sum_is_int) {
            out_value->kind = DS_SLOT_INT;
            out_value->v.i  = we->max_i;
        } else {
            out_value->v.f = ds_series_welford_ewma_max(we);
        }
        break;
    case DS_SERIES_AGG_COUNT:
        out_value->kind = DS_SLOT_INT;
        out_value->v.i = (int64_t) ds_series_welford_ewma_count(we);
        break;
    /* [LSER.16.9], [LSER.10.9]: no elapsed time, or fewer than two samples, is
       `null` and not a measured 0. */
    case DS_SERIES_AGG_RATE:
        if (!ds_series_welford_ewma_rate(we, &out_value->v.f))
            out_value->kind = DS_SLOT_NULL;
        break;
    case DS_SERIES_AGG_DIRECTION:
        out_value->kind = DS_SLOT_INT;
        if (!ds_series_welford_ewma_direction(we, &out_value->v.i))
            out_value->kind = DS_SLOT_NULL;
        break;
    case DS_SERIES_AGG_LAST:
        if (!we->has_sample) {
            out_value->kind = DS_SLOT_FLOAT;
            out_value->v.f  = 0.0;
        } else {
            *out_value = we->typed_last;
        }
        break;
    case DS_SERIES_AGG_FIRST:
        if (!we->has_typed_first) {
            out_value->kind = DS_SLOT_FLOAT;
            out_value->v.f  = 0.0;
        } else {
            *out_value = we->typed_first;
        }
        break;
    case DS_SERIES_AGG_SUM:
        if (we->sum_is_int) {
            out_value->kind = DS_SLOT_INT;
            out_value->v.i  = we->sum_i;
        } else {
            out_value->kind = DS_SLOT_FLOAT;
            out_value->v.f  = we->sum_f;
        }
        break;
    case DS_SERIES_AGG_BOOL_OR:
        out_value->kind = DS_SLOT_BOOL;
        out_value->v.b  = (we->bool_true_count > 0);
        break;
    case DS_SERIES_AGG_BOOL_AND:
        out_value->kind = DS_SLOT_BOOL;
        out_value->v.b  = (we->bool_total_count > 0)
                        && (we->bool_true_count == we->bool_total_count);
        break;
    default:
        return DS_ERR_R(
            DS_ERR_INVAL,
            "ds-sbwe: agg_kind not supported by this backend");
    }
    return DS_OK_R;
}

static const ds_series_backend_vtable_t sbwe_vtable = {
    .abi_version     = DS_SERIES_BACKEND_ABI_VERSION,
    .backend_name    = "ds-welford-ewma",
    .backend_version = "0.1.0",
    .atom_field      = DS_ATOM_SERIES_BACKEND_WELFORD_EWMA,
    .supported_aggs  =
          DS_SERIES_AGG_BIT(DS_SERIES_AGG_AVG)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_STDEV)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_PSTDEV)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_VARIANCE)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_PVARIANCE)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_MIN)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_MAX)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_COUNT)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_RATE)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_DIRECTION)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_LAST)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_FIRST)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_SUM)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_BOOL_AND)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_BOOL_OR),
    .instance_new    = sbwe_instance_new,
    .instance_free   = sbwe_instance_free,
    .instance_clone  = sbwe_instance_clone,
    .update          = sbwe_update,
    .query           = sbwe_query,
    .evict_stale     = NULL,
};

/* ------------------------------------------------------------------ */
/*  SeriesBackendReservoir                                                  */
/* ------------------------------------------------------------------ */

static ds_result_t sbrs_instance_new(const ds_series_decl_t *decl,
                                      void                  **out_state)
{
    ds_series_reservoir_t *rs = ds_series_reservoir_new(
        (size_t) decl->max_samples);
    if (rs == NULL)
        return DS_ERR_R(DS_ERR_OOM, "ds-sbrs: instance_new alloc failed");
    *out_state = rs;
    return DS_OK_R;
}

static void sbrs_instance_free(void *state)
{
    ds_series_reservoir_free((ds_series_reservoir_t *) state);
}

static ds_result_t sbrs_instance_clone(const void *state, void **out_state)
{
    ds_series_reservoir_t *c = ds_series_reservoir_clone(
        (const ds_series_reservoir_t *) state);
    if (c == NULL)
        return DS_ERR_R(DS_ERR_OOM, "ds-sbrs: instance_clone alloc failed");
    *out_state = c;
    return DS_OK_R;
}

static ds_result_t sbrs_update(void                  *state,
                                const ds_slot_value_t *value,
                                uint64_t               ts_ns)
{
    ds_series_reservoir_update(
        (ds_series_reservoir_t *) state, value, ts_ns);
    return DS_OK_R;
}

static ds_result_t sbrs_query(void                 *state,
                               ds_series_agg_kind_t  agg_kind,
                               uint64_t              window_ns,
                               ds_slot_value_t      *out_value)
{
    (void) window_ns;
    return ds_series_reservoir_query(
        (const ds_series_reservoir_t *) state, agg_kind, out_value);
}

/* `pXX` over a `sample N` bag ([LSER.17.2]): N is the value argument. */
static ds_result_t sbrs_query_with_value(void                  *state,
                                          ds_series_agg_kind_t   agg_kind,
                                          uint64_t               window_ns,
                                          const ds_slot_value_t *lookup_value,
                                          uint32_t               k_param,
                                          ds_slot_value_t       *out_value)
{
    (void) window_ns; (void) k_param;
    if (agg_kind != DS_SERIES_AGG_PERCENTILE)
        return DS_ERR_R(DS_ERR_INVAL,
                        "ds-sbrs: agg_kind not supported by query_with_value");
    int64_t n = (lookup_value != NULL && lookup_value->kind == DS_SLOT_INT)
                    ? lookup_value->v.i : 50;
    unsigned pct = n < 0 ? 0u : n > 100 ? 100u : (unsigned) n;
    return ds_series_reservoir_percentile(
        (const ds_series_reservoir_t *) state, pct, out_value);
}

static const ds_series_backend_vtable_t sbrs_vtable = {
    .abi_version     = DS_SERIES_BACKEND_ABI_VERSION,
    .backend_name    = "ds-reservoir",
    .backend_version = "0.1.0",
    .atom_field      = DS_ATOM_SERIES_BACKEND_RESERVOIR,
    .supported_aggs  =
          DS_SERIES_AGG_BIT(DS_SERIES_AGG_AVG)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_STDEV)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_PSTDEV)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_VARIANCE)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_PVARIANCE)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_MIN)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_MAX)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_SUM)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_COUNT)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_MEDIAN)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_PERCENTILE)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_BOOL_AND)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_BOOL_OR),
    .instance_new    = sbrs_instance_new,
    .instance_free   = sbrs_instance_free,
    .instance_clone  = sbrs_instance_clone,
    .update          = sbrs_update,
    .query           = sbrs_query,
    .evict_stale     = NULL,  /* all_time; no window */
    .query_with_value = sbrs_query_with_value,
};

/* ------------------------------------------------------------------ */
/*  SeriesBackendFifoDeque                                                  */
/* ------------------------------------------------------------------ */

static ds_result_t sbfd_instance_new(const ds_series_decl_t *decl,
                                      void                  **out_state)
{
    ds_series_fifo_deque_t *fd = ds_series_fifo_deque_new(
        decl->window_ns, decl->element_type, (size_t)decl->max_samples);
    if (fd == NULL)
        return DS_ERR_R(DS_ERR_OOM, "ds-sbfd: instance_new alloc failed");
    *out_state = fd;
    return DS_OK_R;
}

static void sbfd_instance_free(void *state)
{
    ds_series_fifo_deque_free((ds_series_fifo_deque_t *) state);
}

static ds_result_t sbfd_instance_clone(const void *state, void **out_state)
{
    ds_series_fifo_deque_t *c = ds_series_fifo_deque_clone(
        (const ds_series_fifo_deque_t *) state);
    if (c == NULL)
        return DS_ERR_R(DS_ERR_OOM, "ds-sbfd: instance_clone alloc failed");
    *out_state = c;
    return DS_OK_R;
}

static ds_result_t sbfd_update(void                  *state,
                                const ds_slot_value_t *value,
                                uint64_t               ts_ns)
{
    ds_series_fifo_deque_update((ds_series_fifo_deque_t *) state,
                                 value, ts_ns);
    return DS_OK_R;
}

static ds_result_t sbfd_query(void                 *state,
                               ds_series_agg_kind_t  agg_kind,
                               uint64_t              window_ns,
                               ds_slot_value_t      *out_value)
{
    (void) window_ns;
    ds_series_fifo_deque_t *fd = state;
    switch (agg_kind) {
    case DS_SERIES_AGG_FIRST:
        *out_value = ds_series_fifo_deque_first(fd);
        break;
    case DS_SERIES_AGG_LAST:
        *out_value = ds_series_fifo_deque_last(fd);
        break;
    case DS_SERIES_AGG_BOOL_OR:
        out_value->kind = DS_SLOT_BOOL;
        out_value->v.b  = ds_series_fifo_deque_bool_or(fd);
        break;
    case DS_SERIES_AGG_BOOL_AND:
        out_value->kind = DS_SLOT_BOOL;
        out_value->v.b  = ds_series_fifo_deque_bool_and(fd);
        break;
    default:
        return DS_ERR_R(DS_ERR_INVAL,
            "ds-sbfd: agg_kind not supported by this backend");
    }
    return DS_OK_R;
}

static void sbfd_evict_stale(void *state, uint64_t now_ns)
{
    ds_series_fifo_deque_evict_stale((ds_series_fifo_deque_t *) state,
                                      now_ns);
}

static const ds_series_backend_vtable_t sbfd_vtable = {
    .abi_version     = DS_SERIES_BACKEND_ABI_VERSION,
    .backend_name    = "ds-fifo-deque",
    .backend_version = "0.1.0",
    .atom_field      = DS_ATOM_SERIES_BACKEND_FIFO_DEQUE,
    .supported_aggs  =
          DS_SERIES_AGG_BIT(DS_SERIES_AGG_FIRST)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_LAST)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_BOOL_OR)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_BOOL_AND),
    .instance_new    = sbfd_instance_new,
    .instance_free   = sbfd_instance_free,
    .instance_clone  = sbfd_instance_clone,
    .update          = sbfd_update,
    .query           = sbfd_query,
    .evict_stale     = sbfd_evict_stale,
};

/* ------------------------------------------------------------------ */
/*  SeriesBackendMonotonicDeque                                             */
/* ------------------------------------------------------------------ */

static ds_result_t sbmd_instance_new(const ds_series_decl_t *decl,
                                      void                  **out_state)
{
    ds_series_mono_deque_t *md = ds_series_mono_deque_new(
        decl->window_ns, decl->element_type, (size_t)decl->max_samples);
    if (md == NULL)
        return DS_ERR_R(DS_ERR_OOM, "ds-sbmd: instance_new alloc failed");
    *out_state = md;
    return DS_OK_R;
}

static void sbmd_instance_free(void *state)
{
    ds_series_mono_deque_free((ds_series_mono_deque_t *) state);
}

static ds_result_t sbmd_instance_clone(const void *state, void **out_state)
{
    ds_series_mono_deque_t *c = ds_series_mono_deque_clone(
        (const ds_series_mono_deque_t *) state);
    if (c == NULL)
        return DS_ERR_R(DS_ERR_OOM, "ds-sbmd: instance_clone alloc failed");
    *out_state = c;
    return DS_OK_R;
}

static ds_result_t sbmd_update(void                  *state,
                                const ds_slot_value_t *value,
                                uint64_t               ts_ns)
{
    ds_series_mono_deque_t *md = state;
    switch (value->kind) {
    case DS_SLOT_FLOAT:
        ds_series_mono_deque_update(md, value->v.f, ts_ns);
        break;
    case DS_SLOT_INT:
        /* Compared as int64: two Ints above 2^53 can share a double. */
        ds_series_mono_deque_update_int(md, value->v.i, ts_ns);
        break;
    default:
        return DS_ERR_R(DS_ERR_INVAL,
            "ds-sbmd: update value kind must be FLOAT or INT");
    }
    return DS_OK_R;
}

static ds_result_t sbmd_query(void                 *state,
                               ds_series_agg_kind_t  agg_kind,
                               uint64_t              window_ns,
                               ds_slot_value_t      *out_value)
{
    (void) window_ns;
    ds_series_mono_deque_t *md = state;
    /* An Int slot's deque is read off its exact track. The decl's
       element_type can be unspecified, so what was absorbed decides too. */
    bool is_int = md->int_samples
               || md->element_type == DS_SERIES_ELEMENT_INT;

    switch (agg_kind) {
    case DS_SERIES_AGG_MIN:
        if (is_int) {
            out_value->kind = DS_SLOT_INT;
            out_value->v.i  = ds_series_mono_deque_min_int(md);
        } else {
            out_value->kind = DS_SLOT_FLOAT;
            out_value->v.f  = ds_series_mono_deque_min(md);
        }
        break;
    case DS_SERIES_AGG_MAX:
        if (is_int) {
            out_value->kind = DS_SLOT_INT;
            out_value->v.i  = ds_series_mono_deque_max_int(md);
        } else {
            out_value->kind = DS_SLOT_FLOAT;
            out_value->v.f  = ds_series_mono_deque_max(md);
        }
        break;
    default:
        return DS_ERR_R(DS_ERR_INVAL,
            "ds-sbmd: agg_kind not supported by this backend");
    }
    return DS_OK_R;
}

static void sbmd_evict_stale(void *state, uint64_t now_ns)
{
    ds_series_mono_deque_evict_stale((ds_series_mono_deque_t *) state,
                                      now_ns);
}

static const ds_series_backend_vtable_t sbmd_vtable = {
    .abi_version     = DS_SERIES_BACKEND_ABI_VERSION,
    .backend_name    = "ds-monotonic-deque",
    .backend_version = "0.1.0",
    .atom_field      = DS_ATOM_SERIES_BACKEND_MONOTONIC_DEQUE,
    .supported_aggs  =
          DS_SERIES_AGG_BIT(DS_SERIES_AGG_MIN)
        | DS_SERIES_AGG_BIT(DS_SERIES_AGG_MAX),
    .instance_new    = sbmd_instance_new,
    .instance_free   = sbmd_instance_free,
    .instance_clone  = sbmd_instance_clone,
    .update          = sbmd_update,
    .query           = sbmd_query,
    .evict_stale     = sbmd_evict_stale,
};

/* ------------------------------------------------------------------ */
/*  SeriesBackendIntervalPulse (LSIG.2.2)                                   */
/* ------------------------------------------------------------------ */

static ds_result_t sbip_instance_new(const ds_series_decl_t *decl,
                                      void                  **out_state)
{
    ds_series_interval_pulse_t *ip =
        ds_series_interval_pulse_new(decl->window_ns);
    if (ip == NULL)
        return DS_ERR_R(DS_ERR_OOM, "ds-sbip: instance_new alloc failed");
    *out_state = ip;
    return DS_OK_R;
}

static void sbip_instance_free(void *state)
{
    ds_series_interval_pulse_free((ds_series_interval_pulse_t *) state);
}

static ds_result_t sbip_instance_clone(const void *state, void **out_state)
{
    ds_series_interval_pulse_t *c = ds_series_interval_pulse_clone(
        (const ds_series_interval_pulse_t *) state);
    if (c == NULL)
        return DS_ERR_R(DS_ERR_OOM, "ds-sbip: instance_clone alloc failed");
    *out_state = c;
    return DS_OK_R;
}

static ds_result_t sbip_update(void                  *state,
                                const ds_slot_value_t *value,
                                uint64_t               ts_ns)
{
    if (value->kind != DS_SLOT_BOOL) {
        return DS_ERR_R(DS_ERR_INVAL,
                        "ds-sbip: update value kind must be BOOL");
    }
    ds_series_interval_pulse_update(
        (ds_series_interval_pulse_t *) state, value->v.b, ts_ns);
    return DS_OK_R;
}

static ds_result_t sbip_query(void                 *state,
                               ds_series_agg_kind_t  agg_kind,
                               uint64_t              window_ns,
                               ds_slot_value_t      *out_value)
{
    (void) window_ns;
    if (agg_kind != DS_SERIES_AGG_ACTIVE_FRACTION) {
        return DS_ERR_R(DS_ERR_INVAL,
                        "ds-sbip: agg_kind not supported by this backend");
    }
    out_value->kind = DS_SLOT_FLOAT;
    out_value->v.f  = ds_series_interval_pulse_active_fraction(
        (const ds_series_interval_pulse_t *) state);
    return DS_OK_R;
}

static ds_result_t sbip_query_at(void                 *state,
                                  ds_series_agg_kind_t  agg_kind,
                                  uint64_t              window_ns,
                                  uint64_t              now_ns,
                                  ds_slot_value_t      *out_value)
{
    (void) window_ns;
    if (agg_kind != DS_SERIES_AGG_ACTIVE_FRACTION) {
        return DS_ERR_R(DS_ERR_INVAL,
                        "ds-sbip: agg_kind not supported by this backend");
    }
    out_value->kind = DS_SLOT_FLOAT;
    out_value->v.f  = ds_series_interval_pulse_active_fraction_at(
        (const ds_series_interval_pulse_t *) state, now_ns);
    return DS_OK_R;
}

static const ds_series_backend_vtable_t sbip_vtable = {
    .abi_version     = DS_SERIES_BACKEND_ABI_VERSION,
    .backend_name    = "ds-interval-pulse",
    .backend_version = "0.1.0",
    .atom_field      = DS_ATOM_SERIES_BACKEND_INTERVAL_PULSE,
    .supported_aggs  = DS_SERIES_AGG_BIT(DS_SERIES_AGG_ACTIVE_FRACTION),
    .instance_new    = sbip_instance_new,
    .instance_free   = sbip_instance_free,
    .instance_clone  = sbip_instance_clone,
    .update          = sbip_update,
    .query           = sbip_query,
    .evict_stale     = NULL,   /* eviction is assertion-driven (LSIG.2.5) */
    .query_at        = sbip_query_at,
};

/* ------------------------------------------------------------------ */
/*  SeriesBackendNumericIntegral (LSIG.2.3)                                 */
/* ------------------------------------------------------------------ */

static ds_result_t sbni_instance_new(const ds_series_decl_t *decl,
                                      void                  **out_state)
{
    ds_series_numeric_integral_t *ni = ds_series_numeric_integral_new(
        decl->window_ns, decl->time_model, decl->gap_policy);
    if (ni == NULL)
        return DS_ERR_R(DS_ERR_OOM, "ds-sbni: instance_new alloc failed");
    *out_state = ni;
    return DS_OK_R;
}

static void sbni_instance_free(void *state)
{
    ds_series_numeric_integral_free((ds_series_numeric_integral_t *) state);
}

static ds_result_t sbni_instance_clone(const void *state, void **out_state)
{
    ds_series_numeric_integral_t *c = ds_series_numeric_integral_clone(
        (const ds_series_numeric_integral_t *) state);
    if (c == NULL)
        return DS_ERR_R(DS_ERR_OOM, "ds-sbni: instance_clone alloc failed");
    *out_state = c;
    return DS_OK_R;
}

static ds_result_t sbni_update(void                  *state,
                                const ds_slot_value_t *value,
                                uint64_t               ts_ns)
{
    double v;
    switch (value->kind) {
    case DS_SLOT_FLOAT: v = value->v.f;          break;
    case DS_SLOT_INT:   v = (double) value->v.i; break;
    default:
        return DS_ERR_R(DS_ERR_INVAL,
                        "ds-sbni: update value kind must be FLOAT or INT");
    }
    ds_series_numeric_integral_update(
        (ds_series_numeric_integral_t *) state, v, ts_ns);
    return DS_OK_R;
}

static ds_result_t sbni_query(void                 *state,
                               ds_series_agg_kind_t  agg_kind,
                               uint64_t              window_ns,
                               ds_slot_value_t      *out_value)
{
    (void) window_ns;
    if (agg_kind != DS_SERIES_AGG_INTEGRAL) {
        return DS_ERR_R(DS_ERR_INVAL,
                        "ds-sbni: agg_kind not supported by this backend");
    }
    out_value->kind = DS_SLOT_FLOAT;
    out_value->v.f  = ds_series_numeric_integral_value(
        (const ds_series_numeric_integral_t *) state);
    return DS_OK_R;
}

static ds_result_t sbni_query_at(void                 *state,
                                  ds_series_agg_kind_t  agg_kind,
                                  uint64_t              window_ns,
                                  uint64_t              now_ns,
                                  ds_slot_value_t      *out_value)
{
    (void) window_ns;
    if (agg_kind != DS_SERIES_AGG_INTEGRAL) {
        return DS_ERR_R(DS_ERR_INVAL,
                        "ds-sbni: agg_kind not supported by this backend");
    }
    out_value->kind = DS_SLOT_FLOAT;
    out_value->v.f  = ds_series_numeric_integral_value_at(
        (const ds_series_numeric_integral_t *) state, now_ns);
    return DS_OK_R;
}

static const ds_series_backend_vtable_t sbni_vtable = {
    .abi_version     = DS_SERIES_BACKEND_ABI_VERSION,
    .backend_name    = "ds-numeric-integral",
    .backend_version = "0.1.0",
    .atom_field      = DS_ATOM_SERIES_BACKEND_NUMERIC_INTEGRAL,
    .supported_aggs  = DS_SERIES_AGG_BIT(DS_SERIES_AGG_INTEGRAL),
    .instance_new    = sbni_instance_new,
    .instance_free   = sbni_instance_free,
    .instance_clone  = sbni_instance_clone,
    .update          = sbni_update,
    .query           = sbni_query,
    .evict_stale     = NULL,   /* eviction is assertion-driven (LSIG.2.5) */
    .query_at        = sbni_query_at,
};

/* ------------------------------------------------------------------ */
/*  Registration                                                       */
/* ------------------------------------------------------------------ */

static const ds_series_backend_vtable_t *const k_vtables[] = {
    &sbwe_vtable,
    &sbmd_vtable,
    &sbfd_vtable,
    &sbrs_vtable,
    &sbip_vtable,
    &sbni_vtable,
};

ds_result_t ds_series_register_builtin_backends(ds_engine_t *engine)
{
    const size_t n = sizeof(k_vtables) / sizeof(k_vtables[0]);
    ds_result_t r = ds_engine_register_series_backend(engine, k_vtables, n,
                                                       NULL);
    if (r.status != DS_OK) return r;
    return ds_engine_register_ring_buffer_backend(engine);
}
