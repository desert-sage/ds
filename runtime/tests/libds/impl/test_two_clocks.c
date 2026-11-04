/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The engine's two clocks, sampled once per step:
 *
 *   1. [LTIM.2.8.5] The first sample is recorded, and a sample is recorded
 *      BEFORE the record of the input it was taken for.
 *   2. [LTIM.2.8.5] An unchanged sample is not recorded again.
 *   3. [NTST.3.3] A mock mutation is not a sample: it records nothing, and
 *      the next step records the value two mutations left, once.
 *   4. [NTST.3.1] An advance moves the wall clock too when it is set; a wall
 *      step moves the wall clock alone.
 *   5. [NLFC.5.4] The mock wall clock is unset until ds_engine_wall_clock_set,
 *      and the TICK says so.
 *   6. [NTST.3.1] A backward clock_set is accepted before the first sample and
 *      refused after it, whether an input or a pump took that sample (6b),
 *      and the refusal leaves both clocks as they were.
 *   7. [NLFC.5.4] Switching to the mock clock is refused once the clock has
 *      been sampled, by an input or by a pump (7b).
 *   8. [NLFC.5.3] The wall setter, like the other two, is mock-only.
 *
 * No rules, so an assert's only events are its TICK and its FACT_ASSERT.
 */
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "engine.h"   /* ds_engine_register_schema, libds-internal */

static int g_fails;
#define CHECK(cond, msg)                                                     \
    do { if (!(cond)) {                                                      \
        fprintf(stderr, "FAIL [%s]: %s (%s:%d)\n",                           \
                __func__, (msg), __FILE__, __LINE__);                        \
        g_fails++;                                                           \
    } } while (0)

/* ---- observe the stream ---------------------------------------------- */

typedef struct {
    ds_stream_ev_kind_t kind;
    uint64_t            seq;
    uint64_t            clock_ns;
    bool                wall_set;   /* TICK only */
    int64_t             wall_ns;    /* TICK only */
} obs_t;

typedef struct { obs_t obs[32]; int n; } buf_t;

static ds_result_t observe(ds_engine_t *e, const ds_stream_ev_t *ev, void *user)
{
    (void) e;
    buf_t *b = (buf_t *) user;
    if (b->n >= (int) (sizeof(b->obs) / sizeof(b->obs[0]))) return DS_OK_R;
    obs_t *o = &b->obs[b->n++];
    o->kind     = ev->kind;
    o->seq      = ev->seq;
    o->clock_ns = ev->clock_ns;
    if (ev->kind == DS_EV_TICK) {
        o->wall_set = ev->p.tick.wall_set;
        o->wall_ns  = ev->p.tick.wall_ns;
    }
    return DS_OK_R;
}

/* An engine with one keyed Int schema, `S`. mock: switch to the mock clock
   before anything else, as a test does. */
static ds_engine_t *engine_with_schema(bool mock, const ds_schema_t **out_s)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK || e == NULL) return NULL;
    ds_slot_desc_t sd = { .name = "v", .type = DS_SLOT_TYPE_INT,
                          .identity_role = DS_IDENTITY_KEY };
    if (ds_engine_register_schema(e, "S", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                  &sd, 1, out_s).status != DS_OK) {
        ds_engine_free(e);
        return NULL;
    }
    if (mock && ds_engine_clock_set_mode(e, DS_CLOCK_MOCK).status != DS_OK) {
        ds_engine_free(e);
        return NULL;
    }
    return e;
}

static ds_result_t assert_v(ds_engine_t *e, const ds_schema_t *s, int64_t v)
{
    ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = v };
    return ds_engine_assert(e, s, &sv, 1, NULL);
}

/* ---- 1, 2, 5: the first sample, its order, and an unset wall --------- */

static void test_first_sample_recorded_before_its_input(void)
{
    const ds_schema_t *s = NULL;
    ds_engine_t *e = engine_with_schema(true, &s);
    if (e == NULL) { g_fails++; fprintf(stderr, "FAIL: engine\n"); return; }
    buf_t b = {0};
    ds_engine_set_stream_callback(e, observe, &b);

    CHECK(ds_engine_clock_set(e, 1000).status == DS_OK, "clock_set 1000");
    CHECK(assert_v(e, s, 1).status == DS_OK, "assert S(1)");

    CHECK(b.n == 2, "the first assert emits a TICK and its FACT_ASSERT");
    if (b.n == 2) {
        CHECK(b.obs[0].kind == DS_EV_TICK, "the TICK comes FIRST");
        CHECK(b.obs[0].clock_ns == 1000, "carrying the monotonic sample");
        CHECK(!b.obs[0].wall_set, "and an UNSET wall clock: mock, never set");
        CHECK(b.obs[1].kind == DS_EV_FACT_ASSERT, "then the input's own record");
        CHECK(b.obs[1].clock_ns == 1000, "at the same sample");
        CHECK(b.obs[1].seq > b.obs[0].seq, "seq increases");
    }

    /* 2: the clock did not move, so the next input records no TICK. */
    CHECK(assert_v(e, s, 2).status == DS_OK, "assert S(2)");
    CHECK(b.n == 3 && b.obs[2].kind == DS_EV_FACT_ASSERT,
          "an unchanged sample is not recorded again");
    ds_engine_free(e);
}

/* ---- 3, 4: mutations are not samples; advance and wall_set ----------- */

static void test_mutations_are_observed_by_the_next_step(void)
{
    const ds_schema_t *s = NULL;
    ds_engine_t *e = engine_with_schema(true, &s);
    if (e == NULL) { g_fails++; fprintf(stderr, "FAIL: engine\n"); return; }
    buf_t b = {0};
    ds_engine_set_stream_callback(e, observe, &b);

    const int64_t W = 1700000000000000000LL;    /* 2023-11-14T22:13:20Z */
    CHECK(ds_engine_clock_set(e, 100).status == DS_OK, "clock_set 100");
    CHECK(ds_engine_wall_clock_set(e, W).status == DS_OK, "wall_clock_set W");
    CHECK(ds_engine_clock_advance(e, 50).status == DS_OK, "advance 50");
    CHECK(b.n == 0, "three mutations, no events");

    CHECK(ds_engine_pump(e).status == DS_OK, "pump");
    CHECK(b.n == 2, "the pump records ONE TICK for what they left, then its PUMP");
    if (b.n >= 2) {
        CHECK(b.obs[0].kind == DS_EV_TICK, "a TICK");
        CHECK(b.obs[0].clock_ns == 150, "monotonic: set 100, then +50");
        CHECK(b.obs[0].wall_set && b.obs[0].wall_ns == W + 50,
              "wall: set W, then the advance moved it +50 too");
        /* [RFCS.22]: the boundary follows the sample it was taken under. */
        CHECK(b.obs[1].kind == DS_EV_PUMP && b.obs[1].clock_ns == 150,
              "then the PUMP, at the same sample");
    }

    /* A wall step moves the wall clock alone, backward included. */
    CHECK(ds_engine_wall_clock_set(e, W - 1000).status == DS_OK, "wall back 1000");
    CHECK(assert_v(e, s, 1).status == DS_OK, "assert S(1)");
    CHECK(b.n == 4, "a TICK and a FACT_ASSERT");
    if (b.n == 4) {
        CHECK(b.obs[2].kind == DS_EV_TICK && b.obs[2].clock_ns == 150,
              "the monotonic clock did not move");
        CHECK(b.obs[2].wall_set && b.obs[2].wall_ns == W - 1000,
              "the wall clock moved backward");
    }
    ds_engine_free(e);
}

/* ---- 6: a backward clock_set before and after the first input --------
   [NTST.3.1]: before the first sample a set takes any value; after it
   a set below the current value returns DS_ERR_STATE and leaves BOTH clocks
   as they were. libds.h has no wall-clock read, so the wall half is read off
   the stream: a step records a TICK only when a clock moved ([LTIM.2.8.5]),
   so a pump after the refusal that records no TICK shows neither clock did. */

static bool pump_records_no_tick(ds_engine_t *e, buf_t *b)
{
    const int before = b->n;
    if (ds_engine_pump(e).status != DS_OK) return false;
    for (int i = before; i < b->n; i++)
        if (b->obs[i].kind == DS_EV_TICK) return false;
    return b->n == before + 1 && b->obs[before].kind == DS_EV_PUMP;
}

/* @spec [NTST.3.1] */
static void test_backward_set_refused_after_first_input(void)
{
    const ds_schema_t *s = NULL;
    ds_engine_t *e = engine_with_schema(true, &s);
    if (e == NULL) { g_fails++; fprintf(stderr, "FAIL: engine\n"); return; }
    buf_t b = {0};
    ds_engine_set_stream_callback(e, observe, &b);
    const int64_t W = 1700000000000000000LL;

    uint64_t now = 0;
    CHECK(ds_engine_clock_set(e, 5000).status == DS_OK, "clock_set 5000");
    CHECK(ds_engine_clock_set(e, 2000).status == DS_OK,
          "before the first input any value fixes the epoch, backward included");
    ds_engine_clock_now(e, &now);
    CHECK(now == 2000, "and the backward set before it was taken");
    CHECK(ds_engine_wall_clock_set(e, W).status == DS_OK, "wall_clock_set W");
    CHECK(assert_v(e, s, 1).status == DS_OK, "the first input");
    CHECK(b.n == 2 && b.obs[0].kind == DS_EV_TICK && b.obs[0].clock_ns == 2000
              && b.obs[0].wall_set && b.obs[0].wall_ns == W,
          "the first input samples 2000 and W");

    CHECK(ds_engine_clock_set(e, 1999).status == DS_ERR_STATE,
          "after it, a backward set is refused");
    ds_engine_clock_now(e, &now);
    CHECK(now == 2000, "the refused set left the monotonic clock where it was");
    CHECK(pump_records_no_tick(e, &b),
          "and both clocks: the next pump samples no change");

    CHECK(ds_engine_clock_set(e, 2000).status == DS_OK, "the same value is not backward");
    CHECK(ds_engine_clock_set(e, 3000).status == DS_OK, "forward is fine");
    ds_engine_clock_now(e, &now);
    CHECK(now == 3000, "and moves the clock");
    ds_engine_free(e);
}

/* ---- 6b: the first sample closes the window, a pump's included -------
   [NTST.3.1]: a pump before any input samples the clock, and a backward set
   after it would record a ClockAdvance that goes backward ([LTIM.2.8.2]). */

/* @spec [NTST.3.1] */
static void test_backward_set_refused_after_first_pump(void)
{
    const ds_schema_t *s = NULL;
    ds_engine_t *e = engine_with_schema(true, &s);
    if (e == NULL) { g_fails++; fprintf(stderr, "FAIL: engine\n"); return; }
    buf_t b = {0};
    ds_engine_set_stream_callback(e, observe, &b);
    const int64_t W = 1700000000000000000LL;

    uint64_t now = 0;
    CHECK(ds_engine_clock_set(e, 5000).status == DS_OK, "clock_set 5000");
    CHECK(ds_engine_wall_clock_set(e, W).status == DS_OK, "wall_clock_set W");
    CHECK(ds_engine_pump(e).status == DS_OK, "a pump, before any input");
    CHECK(ds_engine_clock_set(e, 2000).status == DS_ERR_STATE,
          "after the pump's sample, a backward set is refused");
    ds_engine_clock_now(e, &now);
    CHECK(now == 5000, "the refused set left the monotonic clock where it was");
    CHECK(pump_records_no_tick(e, &b),
          "and both clocks: the next pump samples no change");
    CHECK(ds_engine_clock_set(e, 6000).status == DS_OK, "forward is fine");
    ds_engine_free(e);
}

/* ---- 7, 8: the mode switch and the wall setter ----------------------- */

static void test_mock_switch_refused_after_first_input(void)
{
    const ds_schema_t *s = NULL;
    ds_engine_t *e = engine_with_schema(false, &s);    /* LIVE */
    if (e == NULL) { g_fails++; fprintf(stderr, "FAIL: engine\n"); return; }

    CHECK(ds_engine_wall_clock_set(e, 1).status == DS_ERR_STATE,
          "wall_clock_set is mock-only");
    CHECK(assert_v(e, s, 1).status == DS_OK, "a live input");
    CHECK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK).status == DS_ERR_STATE,
          "switching to mock after an input is refused");
    ds_clock_mode_t m = DS_CLOCK_MOCK;
    ds_engine_clock_mode(e, &m);
    CHECK(m == DS_CLOCK_LIVE, "and the engine stays live");
    ds_engine_free(e);

    /* 7b: a pump samples the live clock too, so a pump with no input closes
       the switch as well ([NLFC.5.4]). */
    e = engine_with_schema(false, &s);
    if (e == NULL) { g_fails++; fprintf(stderr, "FAIL: engine\n"); return; }
    CHECK(ds_engine_pump(e).status == DS_OK, "a live pump, before any input");
    CHECK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK).status == DS_ERR_STATE,
          "switching to mock after a pump's sample is refused");
    ds_engine_free(e);

    e = engine_with_schema(false, &s);
    if (e == NULL) { g_fails++; fprintf(stderr, "FAIL: engine\n"); return; }
    CHECK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK).status == DS_OK,
          "before any sample the switch is allowed");
    ds_engine_free(e);
}

int main(void)
{
    printf("=== test_two_clocks ===\n");
    test_first_sample_recorded_before_its_input();
    test_mutations_are_observed_by_the_next_step();
    test_backward_set_refused_after_first_input();
    test_backward_set_refused_after_first_pump();
    test_mock_switch_refused_after_first_input();
    if (g_fails) {
        fprintf(stderr, "test_two_clocks: %d FAILURE(S)\n", g_fails);
        return 1;
    }
    printf("=== test_two_clocks: ALL PASSED ===\n");
    return 0;
}
