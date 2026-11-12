/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * series/reservoir.c — Vitter, "Random Sampling with a Reservoir".
 */

#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "reservoir.h"
#include "ring_buffer.h"   /* the shared [LSER.17.2] quantile and signed order */
#include "ds_alloc.h"      /* DS_MALLOC/CALLOC/FREE/STRDUP -- IALC.9.1 routing */

#define SBRS_DEFAULT_K  100

/* ------------------------------------------------------------------ */
/*  PRNG (xorshift64)                                                 */
/* ------------------------------------------------------------------ */

static uint64_t xorshift64(uint64_t *state)
{
    uint64_t x = *state ? *state : UINT64_C(0xdeadbeefcafebabe);
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    *state = x;
    return x;
}

/* Uniform random integer in [0, bound). Slight modulo bias acceptable
   for sampling purposes. */
static uint64_t rand_below(uint64_t *rng, uint64_t bound)
{
    return xorshift64(rng) % bound;
}

/* ------------------------------------------------------------------ */
/*  Slot value management                                             */
/* ------------------------------------------------------------------ */

static void slot_set(ds_series_reservoir_t *rs, size_t idx,
                     const ds_slot_value_t *v)
{
    if (v->kind == DS_SLOT_STRING) {
        DS_FREE(rs->str_copies[idx]);
        rs->str_copies[idx] = v->v.s ? DS_STRDUP(v->v.s) : NULL;
        rs->samples[idx].kind = DS_SLOT_STRING;
        rs->samples[idx].v.s  = rs->str_copies[idx];
    } else {
        DS_FREE(rs->str_copies[idx]);
        rs->str_copies[idx] = NULL;
        rs->samples[idx] = *v;
    }
}

/* ------------------------------------------------------------------ */
/*  Public API                                                        */
/* ------------------------------------------------------------------ */

ds_series_reservoir_t *ds_series_reservoir_new(size_t k)
{
    if (k == 0) k = SBRS_DEFAULT_K;
    ds_series_reservoir_t *rs = DS_CALLOC(1, sizeof(*rs));
    if (rs == NULL) return NULL;
    rs->samples    = DS_CALLOC(k, sizeof(*rs->samples));
    rs->str_copies = DS_CALLOC(k, sizeof(*rs->str_copies));
    if (rs->samples == NULL || rs->str_copies == NULL) {
        DS_FREE(rs->samples);
        DS_FREE(rs->str_copies);
        DS_FREE(rs);
        return NULL;
    }
    rs->k   = k;
    rs->rng = UINT64_C(0x9e3779b97f4a7c15);  /* golden-ratio seed */
    return rs;
}

void ds_series_reservoir_free(ds_series_reservoir_t *rs)
{
    if (rs == NULL) return;
    for (size_t i = 0; i < rs->k; i++) DS_FREE(rs->str_copies[i]);
    DS_FREE(rs->samples);
    DS_FREE(rs->str_copies);
    DS_FREE(rs);
}

ds_series_reservoir_t *ds_series_reservoir_clone(
    const ds_series_reservoir_t *src)
{
    if (src == NULL) return NULL;
    ds_series_reservoir_t *rs = DS_CALLOC(1, sizeof(*rs));
    if (rs == NULL) return NULL;
    rs->samples    = DS_CALLOC(src->k, sizeof(*rs->samples));
    rs->str_copies = DS_CALLOC(src->k, sizeof(*rs->str_copies));
    if (rs->samples == NULL || rs->str_copies == NULL) {
        DS_FREE(rs->samples);
        DS_FREE(rs->str_copies);
        DS_FREE(rs);
        return NULL;
    }
    rs->k    = src->k;
    rs->fill = src->fill;
    rs->n    = src->n;
    rs->rng  = src->rng;           /* xorshift64 PRNG state — verbatim */
    for (size_t i = 0; i < src->k; i++) {
        rs->samples[i] = src->samples[i];
        if (src->str_copies[i] != NULL) {
            rs->str_copies[i] = DS_STRDUP(src->str_copies[i]);
            if (rs->str_copies[i] == NULL) {
                ds_series_reservoir_free(rs);
                return NULL;
            }
            if (rs->samples[i].kind == DS_SLOT_STRING)
                rs->samples[i].v.s = rs->str_copies[i];
        }
    }
    return rs;
}

void ds_series_reservoir_update(ds_series_reservoir_t *rs,
                                 const ds_slot_value_t *value,
                                 uint64_t               ts_ns)
{
    (void) ts_ns;
    rs->n++;

    if (rs->fill < rs->k) {
        slot_set(rs, rs->fill, value);
        rs->fill++;
    } else {
        /* Replacement phase: keep with probability k/n. */
        uint64_t j = rand_below(&rs->rng, rs->n);
        if (j < rs->k) slot_set(rs, (size_t) j, value);
    }
}

/* ------------------------------------------------------------------ */
/*  Aggregation over the sample bag                                   */
/* ------------------------------------------------------------------ */

ds_result_t ds_series_reservoir_percentile(
    const ds_series_reservoir_t *rs,
    unsigned                     pct,
    ds_slot_value_t             *out_value)
{
    size_t n = rs->fill;
    double *vals = n > 0 ? DS_MALLOC(n * sizeof(*vals)) : NULL;
    if (n > 0 && vals == NULL)
        return DS_ERR_R(DS_ERR_OOM, "ds-sbrs: percentile scratch alloc failed");
    size_t m = 0;
    for (size_t i = 0; i < n; i++) {
        if (rs->samples[i].kind == DS_SLOT_FLOAT)
            vals[m++] = rs->samples[i].v.f;
        else if (rs->samples[i].kind == DS_SLOT_INT)
            vals[m++] = (double) rs->samples[i].v.i;
    }
    if (m == 0) {
        /* An empty bag has no quantile: `null` ([LSER.19.8]). */
        out_value->kind = DS_SLOT_NULL;
    } else {
        ds_series_sort_for_quantile(vals, m);
        out_value->kind = DS_SLOT_FLOAT;
        out_value->v.f  = ds_series_quantile_type7(vals, m, pct);
    }
    DS_FREE(vals);
    return DS_OK_R;
}

ds_result_t ds_series_reservoir_query(
    const ds_series_reservoir_t *rs,
    ds_series_agg_kind_t         agg_kind,
    ds_slot_value_t             *out_value)
{
    size_t n = rs->fill;

    if (agg_kind == DS_SERIES_AGG_BOOL_OR ||
        agg_kind == DS_SERIES_AGG_BOOL_AND) {
        uint64_t true_count = 0, total = 0;
        for (size_t i = 0; i < n; i++) {
            if (rs->samples[i].kind != DS_SLOT_BOOL) continue;
            total++;
            if (rs->samples[i].v.b) true_count++;
        }
        out_value->kind = DS_SLOT_BOOL;
        out_value->v.b  = (agg_kind == DS_SERIES_AGG_BOOL_OR)
                        ? (true_count > 0)
                        : (total > 0 && true_count == total);
        return DS_OK_R;
    }

    if (agg_kind == DS_SERIES_AGG_COUNT) {
        out_value->kind = DS_SLOT_INT;
        out_value->v.i  = (int64_t) n;
        return DS_OK_R;
    }

    if (n == 0) {
        out_value->kind = DS_SLOT_FLOAT;
        out_value->v.f  = 0.0;
        return DS_OK_R;
    }

    double *vals = DS_MALLOC(n * sizeof(*vals));
    if (vals == NULL) {
        out_value->kind = DS_SLOT_FLOAT;
        out_value->v.f  = 0.0;
        return DS_OK_R;  /* OOM: return 0 */
    }
    size_t m = 0;
    /* [LSER.17.2]: over an Int slot `sum`, `min` and `max` are exact int64. */
    bool     all_int = true;
    uint64_t sum_u   = 0;        /* wraps as [LSER.16.2.2] requires */
    int64_t  min_i   = 0, max_i = 0;
    for (size_t i = 0; i < n; i++) {
        if (rs->samples[i].kind == DS_SLOT_FLOAT) {
            vals[m++] = rs->samples[i].v.f;
            all_int = false;
        } else if (rs->samples[i].kind == DS_SLOT_INT) {
            int64_t iv = rs->samples[i].v.i;
            if (m == 0 || iv < min_i) min_i = iv;
            if (m == 0 || iv > max_i) max_i = iv;
            sum_u += (uint64_t) iv;
            vals[m++] = (double) iv;
        }
    }

    out_value->kind = DS_SLOT_FLOAT;
    out_value->v.f  = 0.0;

    if (m == 0) { DS_FREE(vals); return DS_OK_R; }

    if (all_int && (agg_kind == DS_SERIES_AGG_SUM
                    || agg_kind == DS_SERIES_AGG_MIN
                    || agg_kind == DS_SERIES_AGG_MAX)) {
        out_value->kind = DS_SLOT_INT;
        out_value->v.i  = agg_kind == DS_SERIES_AGG_SUM ? (int64_t) sum_u
                        : agg_kind == DS_SERIES_AGG_MIN ? min_i
                        : max_i;
        DS_FREE(vals);
        return DS_OK_R;
    }

    double sum = 0.0, min_v = vals[0], max_v = vals[0];
    double mean = 0.0, m2 = 0.0;
    for (size_t i = 0; i < m; i++) {
        double v = vals[i];
        sum += v;
        if (ds_series_signed_before(v, min_v)) min_v = v;
        if (ds_series_signed_before(max_v, v)) max_v = v;
        double delta = v - mean;
        mean  += delta / (double)(i + 1);
        double delta2 = v - mean;
        m2    += delta * delta2;
    }
    /* [LSER.16.3.3]: the sample forms have no value over a bag of one. */
    const bool has_sample_var = m > 1;
    double sample_var = has_sample_var ? m2 / (double)(m - 1) : 0.0;
    double pop_var    = m2 / (double) m;

    switch (agg_kind) {
    case DS_SERIES_AGG_AVG:       out_value->v.f = mean;                    break;
    case DS_SERIES_AGG_SUM:       out_value->v.f = sum;                     break;
    case DS_SERIES_AGG_MIN:       out_value->v.f = min_v;                   break;
    case DS_SERIES_AGG_MAX:       out_value->v.f = max_v;                   break;
    case DS_SERIES_AGG_VARIANCE:
        if (has_sample_var) out_value->v.f = sample_var;
        else                out_value->kind = DS_SLOT_NULL;
        break;
    case DS_SERIES_AGG_PVARIANCE: out_value->v.f = pop_var;                 break;
    case DS_SERIES_AGG_STDEV:
        if (has_sample_var) out_value->v.f = sqrt(sample_var);
        else                out_value->kind = DS_SLOT_NULL;
        break;
    case DS_SERIES_AGG_PSTDEV:    out_value->v.f = sqrt(pop_var);           break;

    case DS_SERIES_AGG_MEDIAN:
        ds_series_sort_for_quantile(vals, m);
        out_value->v.f = ds_series_quantile_type7(vals, m, 50);
        break;

    default:
        DS_FREE(vals);
        return DS_ERR_R(DS_ERR_INVAL,
            "ds-sbrs: agg_kind not supported by reservoir backend");
    }

    DS_FREE(vals);
    return DS_OK_R;
}
