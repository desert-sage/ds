/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [RDSC.5a.4.3] [LSER.16.3.3]
 * SeriesBackendWelfordEwma is cumulative-from-boot whatever window its
 * declaration names ([RDSC.5a.4.3]): the backing does not read `window_ns`.
 *
 * Two instances from the engine's own vtable, one declared with a 10-second
 * window and one with none, each absorb 1.0 at 0 s, 3.0 at 20 s and 8.0 at
 * 60 s. [LSER.16.3.3]'s `all_time` steps give mean 4 and M = 26, so variance
 * 13, pvariance 26/3 and count 3, each one correctly rounded operation from
 * exact inputs; both instances answer exactly that, bit for bit. The Mercury
 * runtime's `ds.series` reads this backing as `all_time` only.
 */
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "series/backend.h"
#include "series/registry.h"

static int failures = 0;

#define CHECK(cond, msg)                                                      \
    do {                                                                      \
        if (!(cond)) {                                                        \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__); \
            failures++;                                                       \
        }                                                                     \
    } while (0)

static bool same_bits(double a, double b)
{
    return memcmp(&a, &b, sizeof a) == 0;
}

/* Query one aggregation as a Float; false when it is null or not a Float. */
static bool query_f(const ds_series_backend_vtable_t *vt, void *st,
                    ds_series_agg_kind_t agg, double *out)
{
    ds_slot_value_t v;
    memset(&v, 0, sizeof v);
    if (vt->query(st, agg, 0, &v).status != DS_OK) return false;
    if (v.kind != DS_SLOT_FLOAT) return false;
    *out = v.v.f;
    return true;
}

static void check_instance(const ds_series_backend_vtable_t *vt,
                           uint64_t window_ns, const char *what)
{
    ds_series_decl_t decl;
    memset(&decl, 0, sizeof decl);
    decl.schema_name        = "S";
    decl.slot_name          = "v";
    decl.identity_slot_name = "";
    decl.atom_field         = DS_ATOM_SERIES_BACKEND_WELFORD_EWMA;
    decl.window_ns          = window_ns;

    void *st = NULL;
    CHECK(vt->instance_new(&decl, &st).status == DS_OK && st != NULL, what);
    if (st == NULL) return;

    static const struct { double x; uint64_t ts_ns; } k_samples[] = {
        { 1.0, 0 },
        { 3.0, UINT64_C(20000000000) },
        { 8.0, UINT64_C(60000000000) },
    };
    for (size_t i = 0; i < sizeof k_samples / sizeof *k_samples; i++) {
        ds_slot_value_t v = { .kind = DS_SLOT_FLOAT, .v.f = k_samples[i].x };
        CHECK(vt->update(st, &v, k_samples[i].ts_ns).status == DS_OK, what);
        if (i == 1) {
            double mean2 = 0.0;
            CHECK(query_f(vt, st, DS_SERIES_AGG_AVG, &mean2)
                      && same_bits(mean2, 2.0),
                  "after two samples the mean is 2, unweighted");
        }
    }

    double mean = 0.0, var = 0.0, pvar = 0.0;
    CHECK(query_f(vt, st, DS_SERIES_AGG_AVG, &mean) && same_bits(mean, 4.0),
          "mean is 4 ([LSER.16.3.3] all_time)");
    CHECK(query_f(vt, st, DS_SERIES_AGG_VARIANCE, &var) && same_bits(var, 13.0),
          "variance is M / (n - 1) = 26 / 2");
    CHECK(query_f(vt, st, DS_SERIES_AGG_PVARIANCE, &pvar)
              && same_bits(pvar, 26.0 / 3.0),
          "pvariance is M / n = 26 / 3");
    ds_slot_value_t c;
    memset(&c, 0, sizeof c);
    CHECK(vt->query(st, DS_SERIES_AGG_COUNT, 0, &c).status == DS_OK
              && c.kind == DS_SLOT_INT && c.v.i == 3,
          "count is 3");
    if (failures)
        fprintf(stderr, "  (instance: %s; mean %.17g, variance %.17g)\n",
                what, mean, var);
    vt->instance_free(st);
}

int main(void)
{
    ds_engine_t *e = NULL;
    if (ds_engine_new(NULL, &e).status != DS_OK || e == NULL) {
        fprintf(stderr, "FAIL: engine_new\n");
        return 1;
    }
    size_t slot = 0;
    CHECK(ds_engine_series_backend_slot_by_atom(
              e, DS_ATOM_SERIES_BACKEND_WELFORD_EWMA, &slot),
          "SeriesBackendWelfordEwma is registered");
    const ds_series_backend_vtable_t *vt =
        ds_engine_series_backend_vtable_at(e, slot);
    CHECK(vt != NULL, "its vtable");
    if (vt != NULL) {
        check_instance(vt, 0, "window 0");
        check_instance(vt, UINT64_C(10000000000), "window 10 s");
    }
    ds_engine_free(e);

    if (failures) {
        fprintf(stderr, "test_sbwe_cumulative: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_sbwe_cumulative: OK\n");
    return 0;
}
