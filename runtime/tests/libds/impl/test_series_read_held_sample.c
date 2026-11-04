/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * A rule's series read answers as of the step's held sample, never the
 * clock source ([LTIM.2.8.4]), as the Mercury runtime's
 * `ds.eval.series_read` does. A time-sensitive aggregation answers through
 * the backend's `query_at`, at that instant.
 *
 * Mock clocks cannot move inside a pump ([RARC.13.16]), so the clock is live
 * and its source scripted: the link wraps clock_gettime (libds.build's row).
 * A step holds 10 s; the source then reads 20 s, with no step between. The
 * series state is built directly: one row of a `gap hold`, all_time integral
 * that absorbed 1.0 at t = 0. FN_SERIES_INTEGRAL's adapter, called as the
 * Rete CALL evaluator calls it, gives the backend's answer at 10 s, which
 * differs from its answer at 20 s.
 */
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "libds.h"
#include "builtin_fn.h"
#include "clock.h"
#include "engine.h"
#include "fn.h"
#include "rete/engine.h"
#include "rete/eval.h"
#include "rete/val.h"
#include "series/backend.h"
#include "series/state.h"

#define SEC 1000000000ULL

/* ---- The scripted monotonic source ------------------------------------- */

int __real_clock_gettime(clockid_t id, struct timespec *ts);

/* The next CLOCK_MONOTONIC reading, as the platform gives it. The engine's
   source is that less its live base (clock.c), so script_reading sets it
   from the base the engine took. */
static uint64_t g_next_mono_ns = 0;

int __wrap_clock_gettime(clockid_t id, struct timespec *ts)
{
    if (id != CLOCK_MONOTONIC) return __real_clock_gettime(id, ts);
    ts->tv_sec  = (time_t) (g_next_mono_ns / 1000000000ull);
    ts->tv_nsec = (long) (g_next_mono_ns % 1000000000ull);
    return 0;
}

/* Make the engine's next read of its source `source_ns`. */
static void script_reading(const ds_engine_t *e, uint64_t source_ns)
{
    g_next_mono_ns = source_ns + e->clock.live_base_ns;
}

static int fail(const char *msg)
{
    fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

/* The backend slot ds_engine_new registered SeriesBackendNumericIntegral in. */
static bool integral_slot(const ds_engine_t *e, size_t *out)
{
    for (size_t s = 0; s < e->n_backend_slots; s++) {
        const ds_series_backend_vtable_t *vt = e->backend_slots[s].vtable;
        if (vt != NULL && vt->atom_field == DS_ATOM_SERIES_BACKEND_NUMERIC_INTEGRAL) {
            *out = s;
            return true;
        }
    }
    return false;
}

/* @spec [LTIM.2.8.4] */
static int test_ltim_2_8_4__series_read_takes_the_held_sample(void)
{
    g_next_mono_ns = 0;
    ds_engine_t *e = NULL;
    if (ds_engine_new(NULL, &e).status != DS_OK) return fail("engine_new");
    if (e->clock.mode != DS_CLOCK_LIVE) {
        ds_engine_free(e);
        return fail("the engine's clock is not live");
    }

    /* The step's sample: the source read once, at 10 s, and held. */
    script_reading(e, 10 * SEC);
    if (ds_engine_clock_step(e, DS_CLOCK_STEP_PUMP).status != DS_OK
        || e->clock.held_mono_ns != 10 * SEC) {
        ds_engine_free(e);
        return fail("the step did not hold the 10 s reading");
    }

    size_t slot = 0;
    if (!integral_slot(e, &slot)) {
        ds_engine_free(e);
        return fail("SeriesBackendNumericIntegral is not registered");
    }
    const ds_series_backend_vtable_t *vt = e->backend_slots[slot].vtable;

    /* One row, its integral instance holding 1.0 from t = 0. all_time (window
       0) so no window can empty it; gap hold so the value accrues to `now`. */
    ds_series_state_row_t *row = ds_series_state_lookup_or_insert(
        e, &e->series_state, e->n_backend_slots,
        "Meter", "w", "id", "m1", 0);
    if (row == NULL) { ds_engine_free(e); return fail("row insert"); }
    ds_series_decl_t decl = {
        .schema_name = "Meter", .slot_name = "w", .identity_slot_name = "id",
        .window_ns = 0, .atom_field = DS_ATOM_SERIES_BACKEND_NUMERIC_INTEGRAL,
        .time_model = DS_SERIES_TIME_MODEL_ALL_TIME,
        .gap_policy = DS_SERIES_GAP_POLICY_HOLD,
    };
    void *st = NULL;
    if (vt->instance_new(&decl, &st).status != DS_OK) {
        ds_engine_free(e);
        return fail("integral instance_new");
    }
    row->backend_state[slot] = st;   /* the engine frees it at teardown */
    ds_slot_value_t one = { .kind = DS_SLOT_FLOAT, .v.f = 1.0 };
    if (vt->update(st, &one, 0).status != DS_OK) {
        ds_engine_free(e);
        return fail("integral update");
    }
    row->has_absorbed        = true;
    row->last_absorbed_ts_ns = 0;

    /* The live source moves on: a read of it now would see 20 s. No step
       samples it. */
    script_reading(e, 20 * SEC);

    /* What the backend answers at each instant. */
    ds_slot_value_t at_held, at_source;
    memset(&at_held, 0, sizeof(at_held));
    memset(&at_source, 0, sizeof(at_source));
    if (vt->query_at(st, DS_SERIES_AGG_INTEGRAL, 0, 10 * SEC, &at_held).status != DS_OK
        || vt->query_at(st, DS_SERIES_AGG_INTEGRAL, 0, 20 * SEC, &at_source).status != DS_OK) {
        ds_engine_free(e);
        return fail("integral query_at");
    }
    /* CONTROL: the two instants give different answers. */
    if (at_held.v.f == at_source.v.f) {
        ds_engine_free(e);
        return fail("control: the integral is the same at 10 s and 20 s, so "
                    "this test cannot tell the held sample from the source");
    }

    /* The read a rule makes, through its registered adapter, as the Rete CALL
       evaluator makes it. */
    const ds_fn_slot_t *fn = ds_lookup_fn((uint32_t) DS_FN_SERIES_INTEGRAL);
    if (fn == NULL || fn->fn == NULL) {
        ds_engine_free(e);
        return fail("FN_SERIES_INTEGRAL is not registered");
    }
    ds_rete_val_t args[5] = {
        ds_rete_val_str("Meter", 5u), ds_rete_val_str("w", 1u),
        ds_rete_val_str("id", 2u),    ds_rete_val_str("m1", 2u),
        ds_rete_val_int(0),
    };
    ds_rete_val_t out;
    memset(&out, 0, sizeof(out));
    int fails = 0;
    if (fn->fn(e->rete_engine, NULL, args, 5u, &out).status != DS_OK) {
        ds_engine_free(e);
        return fail("the integral read returned an error");
    }
    printf("    integral read %g; held sample (10 s) %g, source (20 s) %g\n",
           out.kind == DS_RETE_VAL_FLOAT ? out.f : NAN,
           at_held.v.f, at_source.v.f);
    if (out.kind != DS_RETE_VAL_FLOAT || out.f != at_held.v.f) {
        fprintf(stderr,
                "FAIL: the integral read is not the held sample's answer. A "
                "rule's read takes the step's sample ([LTIM.2.8.4]), not the "
                "clock source\n");
        fails = 1;
    }
    ds_engine_free(e);
    return fails;
}

int main(void)
{
    printf("=== test_series_read_held_sample ===\n");
    int fails = test_ltim_2_8_4__series_read_takes_the_held_sample();
    if (fails == 0)
        printf("OK  test_series_read_held_sample (1 test)\n");
    else
        fprintf(stderr, "FAILED: test_series_read_held_sample\n");
    return fails ? 1 : 0;
}
