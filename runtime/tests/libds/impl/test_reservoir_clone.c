/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * ds_series_reservoir_clone, which `sbrs_instance_clone` invokes, copies the
 * reservoir verbatim, including the xorshift64 PRNG state ([IARC.11.2]). The
 * post-clone state matches, and source and clone fed one further sequence
 * stay in lockstep, since Algorithm R's replacements are driven by the PRNG.
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>

#include "series/reservoir.h"

static int g_fails;
#define CHECK(cond, msg)                                                     \
    do { if (!(cond)) {                                                      \
        fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__);    \
        g_fails++;                                                           \
    } } while (0)

static void feed(ds_series_reservoir_t *rs, int64_t v)
{
    ds_slot_value_t sv;
    memset(&sv, 0, sizeof(sv));
    sv.kind = DS_SLOT_FLOAT;
    sv.v.f  = (double) v;
    ds_series_reservoir_update(rs, &sv, (uint64_t) v);
}

static double bag_avg(const ds_series_reservoir_t *rs)
{
    ds_slot_value_t out;
    memset(&out, 0, sizeof(out));
    ds_series_reservoir_query(rs, DS_SERIES_AGG_AVG, &out);
    return out.v.f;
}

int main(void)
{
    /* Small k so the bag fills and Algorithm R's PRNG-driven replacement (n > k)
       is exercised well before the clone. */
    ds_series_reservoir_t *src = ds_series_reservoir_new(8);
    CHECK(src != NULL, "new");
    if (!src) { printf("test_reservoir_clone: FAILURES\n"); return 1; }
    for (int64_t i = 0; i < 50; i++) feed(src, i);   /* n=50 > k=8 → replacements */
    CHECK(src->n == 50 && src->fill == src->k, "source filled + saw 50");

    ds_series_reservoir_t *cl = ds_series_reservoir_clone(src);
    CHECK(cl != NULL, "clone");
    if (!cl) { printf("test_reservoir_clone: FAILURES\n"); return 1; }

    CHECK(cl->k == src->k, "k verbatim");
    CHECK(cl->fill == src->fill, "fill verbatim");
    CHECK(cl->n == src->n, "n verbatim");
    CHECK(cl->rng == src->rng, "xorshift64 PRNG state verbatim");
    CHECK(cl != src && cl->samples != src->samples && cl->str_copies != src->str_copies,
          "independent allocations");
    bool bag_ok = true;
    for (size_t i = 0; i < src->fill; i++)
        if (src->samples[i].v.f != cl->samples[i].v.f) bag_ok = false;
    CHECK(bag_ok, "sample bag copied verbatim");
    CHECK(bag_avg(src) == bag_avg(cl), "aggregation identical at clone point");

    for (int64_t i = 50; i < 400; i++) { feed(src, i); feed(cl, i); }
    CHECK(src->rng == cl->rng, "PRNG in lockstep after identical drive");
    CHECK(src->n == cl->n && src->fill == cl->fill, "counts in lockstep");
    bool lock_ok = true;
    for (size_t i = 0; i < src->fill; i++)
        if (src->samples[i].v.f != cl->samples[i].v.f) lock_ok = false;
    CHECK(lock_ok, "sample bags identical after identical drive (PRNG cloned exactly)");
    CHECK(bag_avg(src) == bag_avg(cl), "aggregation identical after identical drive");

    uint64_t cl_rng = cl->rng, cl_n = cl->n;
    for (int64_t i = 400; i < 480; i++) feed(src, i);
    CHECK(cl->rng == cl_rng && cl->n == cl_n, "clone untouched by source-only feed");

    ds_series_reservoir_free(src);
    CHECK(cl->k == 8, "clone intact after source freed");
    (void) bag_avg(cl);   /* no use-after-free */
    ds_series_reservoir_free(cl);

    if (g_fails) { printf("test_reservoir_clone: %d FAILURES\n", g_fails); return 1; }
    printf("test_reservoir_clone: ALL PASSED\n");
    return 0;
}
