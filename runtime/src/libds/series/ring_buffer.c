/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * series/ring_buffer.c — sliding-window exact-samples backend.
 */

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "ring_buffer.h"
#include "ds_alloc.h"    /* DS_CALLOC/REALLOC/FREE/STRDUP — IALC.9.1 routing */

/* The caller has screened out non-numeric element types. */
static double ring_sample_as_double(const ds_series_ring_buffer_t *rb,
                                    size_t i)
{
    return rb->element_type == DS_SERIES_RING_ELEM_FLOAT
         ? rb->samples[i].value.f64
         : (double) rb->samples[i].value.i64;
}

static bool ring_is_numeric(const ds_series_ring_buffer_t *rb)
{
    return rb->element_type == DS_SERIES_RING_ELEM_FLOAT
        || rb->element_type == DS_SERIES_RING_ELEM_INT;
}

ds_series_ring_buffer_t *ds_series_ring_buffer_new(
    ds_series_ring_elem_t element_type,
    uint64_t              window_ns,
    uint32_t              max_samples)
{
    ds_series_ring_buffer_t *rb = DS_CALLOC(1, sizeof(*rb));
    if (rb == NULL) return NULL;
    rb->element_type = element_type;
    rb->window_ns    = window_ns;
    rb->max_samples  = max_samples;
    /* Pre-allocated, so neither an append nor a query allocates in the pump. */
    if (max_samples > 0) {
        rb->samples = DS_CALLOC(max_samples, sizeof(*rb->samples));
        if (rb->samples == NULL) { DS_FREE(rb); return NULL; }
        rb->cap_samples = max_samples;
        rb->pctl_scratch = DS_CALLOC(max_samples, sizeof(*rb->pctl_scratch));
        if (rb->pctl_scratch == NULL) {
            DS_FREE(rb->samples); DS_FREE(rb); return NULL;
        }
        rb->pctl_scratch_cap = max_samples;
        rb->distinct_scratch = DS_CALLOC(max_samples, 8);
        if (rb->distinct_scratch == NULL) {
            DS_FREE(rb->pctl_scratch); DS_FREE(rb->samples); DS_FREE(rb); return NULL;
        }
        rb->distinct_scratch_cap = max_samples;
    }
    return rb;
}

static void free_sample_string(ds_series_ring_buffer_t *rb,
                               ds_series_ring_sample_t *s)
{
    if (rb->element_type == DS_SERIES_RING_ELEM_STRING
        && s->value.str != NULL) {
        DS_FREE(s->value.str);
        s->value.str = NULL;
    }
}

ds_series_ring_buffer_t *ds_series_ring_buffer_clone(
    const ds_series_ring_buffer_t *src)
{
    if (src == NULL) return NULL;
    ds_series_ring_buffer_t *rb = DS_CALLOC(1, sizeof(*rb));
    if (rb == NULL) return NULL;
    rb->element_type   = src->element_type;
    rb->window_ns      = src->window_ns;
    rb->max_samples    = src->max_samples;
    rb->n_samples      = src->n_samples;
    rb->cap_samples    = src->cap_samples;
    rb->last_sample_ns = src->last_sample_ns;
    rb->has_sample     = src->has_sample;
    rb->has_last_bool  = src->has_last_bool;
    rb->last_bool      = src->last_bool;
    rb->first_ever_ns  = src->first_ever_ns;
    rb->has_first_ever = src->has_first_ever;
    if (src->n_edges > 0) {
        rb->edge_ts = DS_CALLOC(src->cap_edges, sizeof(*rb->edge_ts));
        if (rb->edge_ts == NULL) { DS_FREE(rb); return NULL; }
        memcpy(rb->edge_ts, src->edge_ts,
               src->n_edges * sizeof(*rb->edge_ts));
        rb->n_edges   = src->n_edges;
        rb->cap_edges = src->cap_edges;
    }
    if (src->cap_samples > 0) {
        rb->samples = DS_CALLOC(src->cap_samples, sizeof(*rb->samples));
        if (rb->samples == NULL) { DS_FREE(rb); return NULL; }
        for (size_t i = 0; i < src->n_samples; i++) {
            rb->samples[i] = src->samples[i];   /* copies ts + value union */
            if (src->element_type == DS_SERIES_RING_ELEM_STRING
                && src->samples[i].value.str != NULL) {
                rb->samples[i].value.str = DS_STRDUP(src->samples[i].value.str);
                if (rb->samples[i].value.str == NULL) {
                    rb->n_samples = i;
                    ds_series_ring_buffer_free(rb);
                    return NULL;
                }
            }
        }
    }
    /* Scratch carries no live state. */
    if (src->pctl_scratch_cap > 0) {
        rb->pctl_scratch = DS_CALLOC(src->pctl_scratch_cap, sizeof(*rb->pctl_scratch));
        if (rb->pctl_scratch == NULL) { ds_series_ring_buffer_free(rb); return NULL; }
        rb->pctl_scratch_cap = src->pctl_scratch_cap;
    }
    if (src->distinct_scratch_cap > 0) {
        rb->distinct_scratch = DS_CALLOC(src->distinct_scratch_cap, 8);
        if (rb->distinct_scratch == NULL) { ds_series_ring_buffer_free(rb); return NULL; }
        rb->distinct_scratch_cap = src->distinct_scratch_cap;
    }
    return rb;
}

void ds_series_ring_buffer_free(ds_series_ring_buffer_t *rb)
{
    if (rb == NULL) return;
    for (size_t i = 0; i < rb->n_samples; i++) {
        free_sample_string(rb, &rb->samples[i]);
    }
    DS_FREE(rb->samples);
    DS_FREE(rb->pctl_scratch);
    DS_FREE(rb->distinct_scratch);
    DS_FREE(rb->edge_ts);
    DS_FREE(rb);
}

/* Half-open (t−W, t] ([LSER.14.1], [LSIG.2.2.4]): a sample exactly W old is out.
   The array is in time order. */
static void trim_stale_prefix(ds_series_ring_buffer_t *rb,
                              uint64_t cutoff_ns)
{
    size_t keep_from = 0;
    while (keep_from < rb->n_samples
           && rb->samples[keep_from].ts_ns <= cutoff_ns) {
        free_sample_string(rb, &rb->samples[keep_from]);
        keep_from++;
    }
    if (keep_from == 0) return;
    if (keep_from < rb->n_samples) {
        memmove(&rb->samples[0], &rb->samples[keep_from],
                (rb->n_samples - keep_from) * sizeof(*rb->samples));
    }
    rb->n_samples -= keep_from;
}

/* [LSIG.1.1]: the oldest `drop` samples go, their edges with them, and no other
   edge. An edge older than the oldest kept sample, t0, is a dropped sample's or
   one past the window. Samples can share a timestamp, so at t0 the kept samples'
   edges are counted, and the rest go: inside the ring a sample is an edge when it
   is `true` and the sample before it `false`, which is the test
   ds_series_ring_buffer_update_bool made of it against `last_bool` ([LSIG.1.4.1]).
   Called before the dropped samples are freed, so the oldest kept one's
   predecessor is still there. */
static void drop_edges_of(ds_series_ring_buffer_t *rb, size_t drop)
{
    if (rb->n_edges == 0 || drop == 0) return;
    if (drop >= rb->n_samples) { rb->n_edges = 0; return; }
    const uint64_t t0 = rb->samples[drop].ts_ns;
    size_t gone = 0;
    while (gone < rb->n_edges && rb->edge_ts[gone] < t0) gone++;
    size_t at_t0 = 0;
    while (gone + at_t0 < rb->n_edges && rb->edge_ts[gone + at_t0] == t0) at_t0++;
    size_t kept_at_t0 = 0;
    for (size_t i = drop; i < rb->n_samples && rb->samples[i].ts_ns == t0; i++) {
        if (rb->samples[i].value.b && !rb->samples[i - 1].value.b) kept_at_t0++;
    }
    if (at_t0 > kept_at_t0) gone += at_t0 - kept_at_t0;
    if (gone == 0) return;
    if (gone < rb->n_edges) {
        memmove(&rb->edge_ts[0], &rb->edge_ts[gone],
                (rb->n_edges - gone) * sizeof(*rb->edge_ts));
    }
    rb->n_edges -= gone;
}

static void trim_to_cap(ds_series_ring_buffer_t *rb, size_t cap)
{
    if (rb->n_samples <= cap) return;
    size_t drop = rb->n_samples - cap;
    drop_edges_of(rb, drop);
    for (size_t i = 0; i < drop; i++) {
        free_sample_string(rb, &rb->samples[i]);
    }
    if (drop < rb->n_samples) {
        memmove(&rb->samples[0], &rb->samples[drop],
                (rb->n_samples - drop) * sizeof(*rb->samples));
    }
    rb->n_samples -= drop;
}

void ds_series_ring_buffer_evict_stale(
    ds_series_ring_buffer_t *rb, uint64_t now_ns)
{
    /* Before t reaches W nothing is stale. */
    if (rb->window_ns == 0 || now_ns < rb->window_ns) return;
    uint64_t cutoff = now_ns - rb->window_ns;
    trim_stale_prefix(rb, cutoff);
}

/* The caller fills in the value union. */
static ds_series_ring_sample_t *append_sample(
    ds_series_ring_buffer_t *rb, uint64_t ts_ns)
{
    ds_series_ring_buffer_evict_stale(rb, ts_ns);
    if (rb->max_samples > 0) {
        size_t target = rb->max_samples - 1;  /* room for the new one */
        if (rb->n_samples > target) trim_to_cap(rb, target);
    }
    if (rb->n_samples == rb->cap_samples) {
        if (rb->max_samples > 0) return NULL;
        size_t new_cap = rb->cap_samples == 0
                       ? 16 : rb->cap_samples * 2;
        void *na = DS_REALLOC(rb->samples,
                           new_cap * sizeof(*rb->samples));
        if (na == NULL) return NULL;
        rb->samples = na;
        rb->cap_samples = new_cap;
    }
    ds_series_ring_sample_t *s = &rb->samples[rb->n_samples++];
    s->ts_ns = ts_ns;
    rb->last_sample_ns = ts_ns;
    rb->has_sample = true;
    if (!rb->has_first_ever) {
        rb->first_ever_ns = ts_ns;
        rb->has_first_ever = true;
    }
    return s;
}

void ds_series_ring_buffer_update_float(
    ds_series_ring_buffer_t *rb, double value, uint64_t ts_ns)
{
    ds_series_ring_sample_t *s = append_sample(rb, ts_ns);
    if (s == NULL) return;  /* OOM: the sample is dropped */
    s->value.f64 = value;
}

void ds_series_ring_buffer_update_int(
    ds_series_ring_buffer_t *rb, int64_t value, uint64_t ts_ns)
{
    ds_series_ring_sample_t *s = append_sample(rb, ts_ns);
    if (s == NULL) return;
    s->value.i64 = value;
}

void ds_series_ring_buffer_update_string(
    ds_series_ring_buffer_t *rb, const char *value, uint64_t ts_ns)
{
    ds_series_ring_sample_t *s = append_sample(rb, ts_ns);
    if (s == NULL) return;
    s->value.str = DS_STRDUP(value != NULL ? value : "");
    if (s->value.str == NULL) {
        rb->n_samples--;
    }
}

static void evict_stale_edges(ds_series_ring_buffer_t *rb, uint64_t now_ns)
{
    if (rb->n_edges == 0 || rb->window_ns == 0 || now_ns < rb->window_ns)
        return;
    uint64_t cutoff = now_ns - rb->window_ns;   /* t − W (exclusive left) */
    size_t keep_from = 0;
    while (keep_from < rb->n_edges && rb->edge_ts[keep_from] <= cutoff)
        keep_from++;
    if (keep_from == 0) return;
    if (keep_from < rb->n_edges) {
        memmove(&rb->edge_ts[0], &rb->edge_ts[keep_from],
                (rb->n_edges - keep_from) * sizeof(*rb->edge_ts));
    }
    rb->n_edges -= keep_from;
}

static void push_edge(ds_series_ring_buffer_t *rb, uint64_t ts_ns)
{
    evict_stale_edges(rb, ts_ns);
    if (rb->n_edges == rb->cap_edges) {
        size_t new_cap = rb->cap_edges == 0 ? 8 : rb->cap_edges * 2;
        uint64_t *na = DS_REALLOC(rb->edge_ts, new_cap * sizeof(*rb->edge_ts));
        if (na == NULL) return;   /* OOM: the edge is dropped */
        rb->edge_ts = na;
        rb->cap_edges = new_cap;
    }
    rb->edge_ts[rb->n_edges++] = ts_ns;
}

void ds_series_ring_buffer_update_bool(
    ds_series_ring_buffer_t *rb, bool value, uint64_t ts_ns)
{
    ds_series_ring_sample_t *s = append_sample(rb, ts_ns);
    if (s == NULL) return;
    s->value.b = value;
    /* [LSIG.1.4.1]: an edge is a `true` absorbed while the slot holds `false`.
       Before the first absorption it holds nothing, which is not `false`. */
    if (value && rb->has_last_bool && !rb->last_bool)
        push_edge(rb, ts_ns);
    else
        evict_stale_edges(rb, ts_ns);
    rb->has_last_bool = true;
    rb->last_bool = value;
}

size_t ds_series_ring_buffer_count(
    const ds_series_ring_buffer_t *rb)
{
    return rb->n_samples;
}

bool ds_series_ring_buffer_rate(
    const ds_series_ring_buffer_t *rb, double *out)
{
    if (rb == NULL || out == NULL) return false;
    if (!ring_is_numeric(rb)) return false;
    if (rb->n_samples < 2) return false;

    const size_t last = rb->n_samples - 1;
    const uint64_t t0 = rb->samples[0].ts_ns;
    const uint64_t t1 = rb->samples[last].ts_ns;
    if (t1 <= t0) return false;

    const double dv = ring_sample_as_double(rb, last)
                    - ring_sample_as_double(rb, 0);
    /* No libm ([LDET.3.4]). */
    *out = (dv * 1e9) / (double) (t1 - t0);
    return true;
}

double ds_series_ring_buffer_onset_rate(
    const ds_series_ring_buffer_t *rb)
{
    return ds_series_ring_buffer_onset_rate_at(
        rb, rb->has_first_ever ? rb->last_sample_ns : 0);
}

double ds_series_ring_buffer_onset_rate_at(
    const ds_series_ring_buffer_t *rb, uint64_t query_ns)
{
    /* No edge yet, or no history: 0.0 (cold-start, LSIG.8). */
    if (rb->n_edges == 0 || !rb->has_first_ever) return 0.0;
    int64_t t = (int64_t) query_ns;
    int64_t elapsed = t - (int64_t) rb->first_ever_ns;
    if (elapsed <= 0) return 0.0;   /* LSIG.1.4.2 — 0 until elapsed > 0 */
    /* Rising edges in (t−W, t], discounting those aged out since the last
       assertion, read-only. */
    size_t count = rb->n_edges;
    if (rb->window_ns != 0) {
        int64_t lo = t - (int64_t) rb->window_ns;   /* t−W (exclusive) */
        count = 0;
        for (size_t i = 0; i < rb->n_edges; i++) {
            if ((int64_t) rb->edge_ts[i] > lo) count++;
        }
    }
    if (count == 0) return 0.0;
    /* LSIG.1.4.2. */
    int64_t denom_ns = (rb->window_ns != 0 && (int64_t) rb->window_ns < elapsed)
                     ? (int64_t) rb->window_ns : elapsed;
    if (denom_ns <= 0) return 0.0;
    /* One correctly-rounded divide (LSIG.4.1). */
    double numer = (double) ((int64_t) count * INT64_C(1000000000));
    return numer / (double) denom_ns;
}

double ds_series_ring_buffer_avg(
    const ds_series_ring_buffer_t *rb)
{
    if (rb->n_samples == 0) return 0.0;
    if (rb->element_type != DS_SERIES_RING_ELEM_FLOAT
        && rb->element_type != DS_SERIES_RING_ELEM_INT) {
        return 0.0;
    }
    double sum = 0.0;
    for (size_t i = 0; i < rb->n_samples; i++) {
        sum += rb->element_type == DS_SERIES_RING_ELEM_FLOAT
             ? rb->samples[i].value.f64
             : (double) rb->samples[i].value.i64;
    }
    return sum / (double) rb->n_samples;
}

double ds_series_ring_buffer_min(
    const ds_series_ring_buffer_t *rb)
{
    if (rb->n_samples == 0) return 0.0;
    if (rb->element_type != DS_SERIES_RING_ELEM_FLOAT
        && rb->element_type != DS_SERIES_RING_ELEM_INT) {
        return 0.0;
    }
    double m = rb->element_type == DS_SERIES_RING_ELEM_FLOAT
             ? rb->samples[0].value.f64
             : (double) rb->samples[0].value.i64;
    for (size_t i = 1; i < rb->n_samples; i++) {
        double v = rb->element_type == DS_SERIES_RING_ELEM_FLOAT
                 ? rb->samples[i].value.f64
                 : (double) rb->samples[i].value.i64;
        if (ds_series_signed_before(v, m)) m = v;
    }
    return m;
}

double ds_series_ring_buffer_max(
    const ds_series_ring_buffer_t *rb)
{
    if (rb->n_samples == 0) return 0.0;
    if (rb->element_type != DS_SERIES_RING_ELEM_FLOAT
        && rb->element_type != DS_SERIES_RING_ELEM_INT) {
        return 0.0;
    }
    double m = rb->element_type == DS_SERIES_RING_ELEM_FLOAT
             ? rb->samples[0].value.f64
             : (double) rb->samples[0].value.i64;
    for (size_t i = 1; i < rb->n_samples; i++) {
        double v = rb->element_type == DS_SERIES_RING_ELEM_FLOAT
                 ? rb->samples[i].value.f64
                 : (double) rb->samples[i].value.i64;
        if (ds_series_signed_before(m, v)) m = v;
    }
    return m;
}

double ds_series_ring_buffer_sum(
    const ds_series_ring_buffer_t *rb)
{
    if (rb->n_samples == 0 || !ring_is_numeric(rb)) return 0.0;
    double sum = 0.0;
    for (size_t i = 0; i < rb->n_samples; i++)
        sum += ring_sample_as_double(rb, i);
    return sum;
}

int64_t ds_series_ring_buffer_sum_int(
    const ds_series_ring_buffer_t *rb)
{
    if (rb->n_samples == 0
        || rb->element_type != DS_SERIES_RING_ELEM_INT) return 0;
    /* An Int sum wraps, as defined C. */
    uint64_t sum = 0;
    for (size_t i = 0; i < rb->n_samples; i++)
        sum += (uint64_t) rb->samples[i].value.i64;
    return (int64_t) sum;
}

/* Two-pass sum of squared deviations. *out_n 0 is an empty or non-numeric window. */
static void ring_sumsq_dev(const ds_series_ring_buffer_t *rb,
                           size_t *out_n, double *out_ss)
{
    size_t n = rb->n_samples;
    if (n == 0 || !ring_is_numeric(rb)) { *out_n = 0; *out_ss = 0.0; return; }
    double sum = 0.0;
    for (size_t i = 0; i < n; i++) sum += ring_sample_as_double(rb, i);
    double mean = sum / (double) n;
    double ss = 0.0;
    for (size_t i = 0; i < n; i++) {
        double d = ring_sample_as_double(rb, i) - mean;
        ss += d * d;
    }
    *out_n = n;
    *out_ss = ss;
}

bool ds_series_ring_buffer_variance(
    const ds_series_ring_buffer_t *rb, double *out)
{
    size_t n; double ss;
    ring_sumsq_dev(rb, &n, &ss);
    if (n <= 1) return false;
    *out = ss / (double) (n - 1);
    return true;
}

double ds_series_ring_buffer_pvariance(
    const ds_series_ring_buffer_t *rb)
{
    size_t n; double ss;
    ring_sumsq_dev(rb, &n, &ss);
    if (n == 0) return 0.0;
    return ss / (double) n;
}

/* [LSER.16.3.3]: the variance's square root, with +0 for a variance not
   greater than 0; no value where the variance has none. */
bool ds_series_ring_buffer_stdev(
    const ds_series_ring_buffer_t *rb, double *out)
{
    double v;
    if (!ds_series_ring_buffer_variance(rb, &v)) return false;
    *out = v > 0.0 ? sqrt(v) : 0.0;
    return true;
}

double ds_series_ring_buffer_pstdev(
    const ds_series_ring_buffer_t *rb)
{
    double v = ds_series_ring_buffer_pvariance(rb);
    return v > 0.0 ? sqrt(v) : 0.0;
}

static int ring_cmp_double(const void *a, const void *b)
{
    double da = *(const double *) a;
    double db = *(const double *) b;
    return (da > db) - (da < db);
}

/* Ascending, with -0 before +0 ([LSER.17.2]): `<` calls the zeros equal, and qsort
   is not stable. Total over every value a slot admits (no NaN, [LEXP.4.2]). */
static int ring_cmp_double_signed(const void *a, const void *b)
{
    double da = *(const double *) a;
    double db = *(const double *) b;
    if (da < db) return -1;
    if (da > db) return 1;
    return (signbit(db) != 0) - (signbit(da) != 0);
}

bool ds_series_signed_before(double a, double b)
{
    if (a < b) return true;
    if (a > b) return false;
    return signbit(a) != 0 && signbit(b) == 0;
}

void ds_series_sort_for_quantile(double *vals, size_t n)
{
    qsort(vals, n, sizeof(*vals), ring_cmp_double_signed);
}

double ds_series_quantile_type7(const double *x, size_t n, unsigned pct)
{
    if (pct > 100u) pct = 100u;
    /* [LSER.17.2]: the rank in exact integers, since 0.29 * 100 is 28.999... */
    const uint64_t num  = (uint64_t) (n - 1) * (uint64_t) pct;
    const size_t   lo   = (size_t) (num / 100u);
    const unsigned frac = (unsigned) (num % 100u);
    const double   x_lo = x[lo];
    if (frac == 0) return x_lo;
    const double   x_hi = x[lo + 1];   /* frac != 0 => lo < n-1 */
    /* Only a [-inf, +inf] pair among the infinities falls through, and reads NaN
       as the clause says. */
    if (x_lo == x_hi || (x_lo == -INFINITY && x_hi != INFINITY)) return x_lo;
    /* Four correctly rounded operations in the clause's order. libds builds with
       `-ffp-contract=off`, so this is no fused multiply-add. */
    const double d = x_hi - x_lo;
    const double f = (double) frac / 100.0;
    const double m = f * d;
    return x_lo + m;
}

ds_series_ring_pctl_t ds_series_ring_buffer_percentile(
    ds_series_ring_buffer_t *rb, unsigned pct, double *out)
{
    if (!ring_is_numeric(rb)) {
        return DS_SERIES_RING_PCTL_EMPTY;
    }
    size_t n = rb->n_samples;
    if (n == 0) return DS_SERIES_RING_PCTL_EMPTY;   /* cold: `null` */
    if (n > rb->pctl_scratch_cap) {
        double *grown = DS_REALLOC(rb->pctl_scratch, n * sizeof(*grown));
        if (grown == NULL) return DS_SERIES_RING_PCTL_OOM;  /* old scratch intact */
        rb->pctl_scratch     = grown;
        rb->pctl_scratch_cap = n;
    }
    /* An Int converts round-to-nearest-even in the API funnel's mode
       ([LDET.3.6.1]). */
    for (size_t i = 0; i < n; i++)
        rb->pctl_scratch[i] = ring_sample_as_double(rb, i);
    ds_series_sort_for_quantile(rb->pctl_scratch, n);
    *out = ds_series_quantile_type7(rb->pctl_scratch, n, pct);
    return DS_SERIES_RING_PCTL_VALUE;
}

bool ds_series_ring_buffer_direction(
    const ds_series_ring_buffer_t *rb, int64_t *out)
{
    if (rb == NULL || out == NULL || !ring_is_numeric(rb)) return false;
    if (rb->n_samples < 2) return false;
    const size_t newest = rb->n_samples - 1;
    const size_t prev   = newest - 1;
    /* Compared, never subtracted: INT64_MAX - (-1) wraps, and a Float difference
       can round to zero. */
    if (rb->element_type == DS_SERIES_RING_ELEM_INT) {
        const int64_t a = rb->samples[newest].value.i64;
        const int64_t b = rb->samples[prev].value.i64;
        *out = (a > b) - (a < b);
    } else {
        const double a = rb->samples[newest].value.f64;
        const double b = rb->samples[prev].value.f64;
        *out = (a > b) - (a < b);
    }
    return true;
}

static int ring_cmp_i64(const void *a, const void *b)
{
    int64_t x = *(const int64_t *) a;
    int64_t y = *(const int64_t *) b;
    return (x > y) - (x < y);
}

static int ring_cmp_str(const void *a, const void *b)
{
    const char *x = *(const char *const *) a;
    const char *y = *(const char *const *) b;
    return strcmp(x, y);
}

static bool ensure_distinct_scratch(ds_series_ring_buffer_t *rb, size_t n)
{
    if (n <= rb->distinct_scratch_cap) return true;
    void *grown = DS_REALLOC(rb->distinct_scratch, n * 8);
    if (grown == NULL) return false;
    rb->distinct_scratch     = grown;
    rb->distinct_scratch_cap = n;
    return true;
}

size_t ds_series_ring_buffer_count_distinct(
    ds_series_ring_buffer_t *rb)
{
    size_t n = rb->n_samples;
    if (n == 0) return 0;

    if (rb->element_type == DS_SERIES_RING_ELEM_BOOL) {
        bool seen_true = false, seen_false = false;
        for (size_t i = 0; i < n; i++) {
            if (rb->samples[i].value.b) seen_true = true;
            else                        seen_false = true;
            if (seen_true && seen_false) break;
        }
        return (size_t) seen_true + (size_t) seen_false;
    }

    if (!ensure_distinct_scratch(rb, n)) return 0;  /* soft on OOM */

    size_t distinct = 1;  /* n >= 1 here */
    switch (rb->element_type) {
    case DS_SERIES_RING_ELEM_FLOAT: {
        double *buf = rb->distinct_scratch;
        for (size_t i = 0; i < n; i++) buf[i] = rb->samples[i].value.f64;
        qsort(buf, n, sizeof(double), ring_cmp_double);
        for (size_t i = 1; i < n; i++) if (buf[i] != buf[i - 1]) distinct++;
        break;
    }
    case DS_SERIES_RING_ELEM_INT: {
        int64_t *buf = rb->distinct_scratch;
        for (size_t i = 0; i < n; i++) buf[i] = rb->samples[i].value.i64;
        qsort(buf, n, sizeof(int64_t), ring_cmp_i64);
        for (size_t i = 1; i < n; i++) if (buf[i] != buf[i - 1]) distinct++;
        break;
    }
    case DS_SERIES_RING_ELEM_STRING: {
        char **buf = rb->distinct_scratch;
        for (size_t i = 0; i < n; i++) buf[i] = rb->samples[i].value.str;
        qsort(buf, n, sizeof(char *), ring_cmp_str);
        for (size_t i = 1; i < n; i++)
            if (strcmp(buf[i], buf[i - 1]) != 0) distinct++;
        break;
    }
    default:
        return 0;
    }
    return distinct;
}

/* A numeric element type takes a FLOAT or an INT lookup; a non-matching kind is
   never equal. */
static bool value_matches_sample(ds_series_ring_elem_t et,
                                 const ds_series_ring_sample_t *s,
                                 const ds_slot_value_t *v)
{
    switch (et) {
    case DS_SERIES_RING_ELEM_FLOAT:
        if (v->kind == DS_SLOT_FLOAT) return s->value.f64 == v->v.f;
        if (v->kind == DS_SLOT_INT)   return s->value.f64 == (double) v->v.i;
        return false;
    case DS_SERIES_RING_ELEM_INT:
        if (v->kind == DS_SLOT_INT)   return s->value.i64 == v->v.i;
        if (v->kind == DS_SLOT_FLOAT) return (double) s->value.i64 == v->v.f;
        return false;
    case DS_SERIES_RING_ELEM_STRING:
        if (v->kind != DS_SLOT_STRING) return false;
        return strcmp(s->value.str ? s->value.str : "",
                      v->v.s ? v->v.s : "") == 0;
    case DS_SERIES_RING_ELEM_BOOL:
        if (v->kind != DS_SLOT_BOOL) return false;
        return s->value.b == v->v.b;
    default:
        return false;
    }
}

size_t ds_series_ring_buffer_count_of(
    const ds_series_ring_buffer_t *rb, const ds_slot_value_t *value)
{
    if (value == NULL) return 0;
    size_t count = 0;
    for (size_t i = 0; i < rb->n_samples; i++) {
        if (value_matches_sample(rb->element_type, &rb->samples[i], value))
            count++;
    }
    return count;
}

bool ds_series_ring_buffer_contains(
    const ds_series_ring_buffer_t *rb, const ds_slot_value_t *value)
{
    if (value == NULL) return false;
    for (size_t i = 0; i < rb->n_samples; i++) {
        if (value_matches_sample(rb->element_type, &rb->samples[i], value))
            return true;
    }
    return false;
}
