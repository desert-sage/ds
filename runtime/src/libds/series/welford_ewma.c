/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * series/welford_ewma.c — Welford running-stats backend.
 */

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "welford_ewma.h"
#include "ring_buffer.h" /* ds_series_signed_before, [LSER.17.2] */
#include "ds_alloc.h"    /* DS_MALLOC/CALLOC/FREE/STRDUP -- IALC.9.1 routing */

ds_series_welford_ewma_t *ds_series_welford_ewma_new(void)
{
    return DS_CALLOC(1, sizeof(ds_series_welford_ewma_t));
}

void ds_series_welford_ewma_free(ds_series_welford_ewma_t *we)
{
    if (we == NULL) return;
    DS_FREE(we->typed_last_str);
    DS_FREE(we->typed_first_str);
    DS_FREE(we);
}

ds_series_welford_ewma_t *ds_series_welford_ewma_clone(
    const ds_series_welford_ewma_t *src)
{
    if (src == NULL) return NULL;
    ds_series_welford_ewma_t *we = DS_MALLOC(sizeof(*we));
    if (we == NULL) return NULL;
    *we = *src;
    we->typed_last_str  = NULL;
    we->typed_first_str = NULL;
    if (src->typed_last_str != NULL) {
        we->typed_last_str = DS_STRDUP(src->typed_last_str);
        if (we->typed_last_str == NULL) { DS_FREE(we); return NULL; }
        if (we->typed_last.kind == DS_SLOT_STRING)
            we->typed_last.v.s = we->typed_last_str;
    }
    if (src->typed_first_str != NULL) {
        we->typed_first_str = DS_STRDUP(src->typed_first_str);
        if (we->typed_first_str == NULL) {
            DS_FREE(we->typed_last_str);
            DS_FREE(we);
            return NULL;
        }
        if (we->typed_first.kind == DS_SLOT_STRING)
            we->typed_first.v.s = we->typed_first_str;
    }
    return we;
}

void ds_series_welford_ewma_update(
    ds_series_welford_ewma_t *we,
    double                    value,
    uint64_t                  ts_ns)
{
    if (!we->has_sample) {
        we->w = 1.0;
        we->mean = value;
        we->m2 = 0.0;
        we->min_v = value;
        we->max_v = value;
        we->last_sample_ns = ts_ns;
        we->first_sample_ns = ts_ns;
        we->has_sample = true;
        return;
    }

    /* [LSER.16.3.3], `all_time`:
         W'   = W + 1
         δ    = x - μ
         μ'   = μ + δ / W'
         M2'  = M2 + δ * (x - μ') */
    double new_w = we->w + 1.0;
    double delta = value - we->mean;
    double new_mean = we->mean + delta / new_w;
    double new_m2 = we->m2 + delta * (value - new_mean);

    we->w = new_w;
    we->mean = new_mean;
    we->m2 = new_m2;
    if (ds_series_signed_before(value, we->min_v)) we->min_v = value;
    if (ds_series_signed_before(we->max_v, value)) we->max_v = value;
    we->last_sample_ns = ts_ns;
}

void ds_series_welford_ewma_update_count_only(
    ds_series_welford_ewma_t *we,
    uint64_t                  ts_ns)
{
    if (!we->has_sample) {
        we->w = 1.0;
        we->last_sample_ns = ts_ns;
        we->first_sample_ns = ts_ns;
        we->has_sample = true;
        return;
    }
    we->w = we->w + 1.0;
    we->last_sample_ns = ts_ns;
}

uint64_t ds_series_welford_ewma_count(
    const ds_series_welford_ewma_t *we)
{
    if (!we->has_sample) return 0;
    return (uint64_t) (we->w + 0.5);
}

double ds_series_welford_ewma_avg(
    const ds_series_welford_ewma_t *we)
{
    return we->has_sample ? we->mean : 0.0;
}

bool ds_series_welford_ewma_variance(
    const ds_series_welford_ewma_t *we, double *out)
{
    if (!we->has_sample || we->w <= 1.0) return false;
    *out = we->m2 / (we->w - 1.0);
    return true;
}

double ds_series_welford_ewma_pvariance(
    const ds_series_welford_ewma_t *we)
{
    if (!we->has_sample || we->w <= 0.0) return 0.0;
    return we->m2 / we->w;
}

/* [LSER.16.3.3]: the variance's square root, with +0 for a variance not
   greater than 0; no value where the variance has none. */
bool ds_series_welford_ewma_stdev(
    const ds_series_welford_ewma_t *we, double *out)
{
    double v;
    if (!ds_series_welford_ewma_variance(we, &v)) return false;
    *out = v > 0.0 ? sqrt(v) : 0.0;
    return true;
}

double ds_series_welford_ewma_pstdev(
    const ds_series_welford_ewma_t *we)
{
    double v = ds_series_welford_ewma_pvariance(we);
    return v > 0.0 ? sqrt(v) : 0.0;
}

double ds_series_welford_ewma_min(
    const ds_series_welford_ewma_t *we)
{
    return we->has_sample ? we->min_v : 0.0;
}

double ds_series_welford_ewma_max(
    const ds_series_welford_ewma_t *we)
{
    return we->has_sample ? we->max_v : 0.0;
}

/* An Int converts round-to-nearest-even ([LDET.3.6.1]). */
static bool typed_as_double(const ds_slot_value_t *v, double *out)
{
    if (v->kind == DS_SLOT_FLOAT) { *out = v->v.f;            return true; }
    if (v->kind == DS_SLOT_INT)   { *out = (double) v->v.i;   return true; }
    return false;
}

/* [LSER.16.9]: over the raw first and last samples. */
bool ds_series_welford_ewma_rate(
    const ds_series_welford_ewma_t *we, double *out)
{
    if (!we->has_sample || !we->has_typed_first) return false;
    if (we->last_sample_ns <= we->first_sample_ns) return false;
    double first, last;
    if (!typed_as_double(&we->typed_first, &first)
        || !typed_as_double(&we->typed_last, &last)) return false;
    const double dv = last - first;
    *out = (dv * 1e9) / (double) (we->last_sample_ns - we->first_sample_ns);
    return true;
}

/* [LSER.10.9]: by comparison in the slot's type. */
bool ds_series_welford_ewma_direction(
    const ds_series_welford_ewma_t *we, int64_t *out)
{
    if (!we->has_typed_prev) return false;
    const ds_slot_value_t *a = &we->typed_last;
    const ds_slot_value_t *b = &we->typed_prev;
    if (a->kind == DS_SLOT_INT && b->kind == DS_SLOT_INT) {
        *out = (a->v.i > b->v.i) - (a->v.i < b->v.i);
        return true;
    }
    double x, y;
    if (!typed_as_double(a, &x) || !typed_as_double(b, &y)) return false;
    *out = (x > y) - (x < y);   /* -0 and +0 compare equal */
    return true;
}
