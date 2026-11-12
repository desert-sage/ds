/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NTST.3.1]
 * On a mock clock, ds_engine_clock_set and ds_engine_clock_advance "must return
 * DS_ERR_TIME_RANGE and leave the engine as it was" when the monotonic clock
 * would end above 2^63 - 1, and the advance when a wall clock with a value
 * would. One that lands on the top of a range is taken, and a wall clock with
 * no value limits nothing.
 *
 * THE PATH: ds_engine_clock_set -> engine_clock_set_body -> ds_clock_set, and
 * ds_engine_clock_advance -> engine_clock_advance_body -> ds_clock_advance,
 * read through libds.h ([STYL.5.10.8]).
 *
 * Each refusal asserts the status and then that nothing moved: the monotonic
 * clock by ds_engine_clock_now, ds.clock.advance_total by its metric, and the
 * wall clock by the next pump recording no TICK, since a sample that changes
 * neither clock records none ([LTIM.2.8.5]). Each taken advance is the control:
 * it counts, and its TICK carries the value.
 *
 * In live mode each is DS_ERR_STATE, and on a halted engine
 * DS_ERR_ENGINE_HALTED, ahead of the range.
 */
#include "spec_common.h"

#define TOP ((uint64_t) INT64_MAX)

typedef struct {
    int      ticks;
    uint64_t clock_ns;
    bool     wall_set;
    int64_t  wall_ns;
    int      advances;
} seen_t;

static ds_result_t on_stream(ds_engine_t *engine, const ds_stream_ev_t *ev,
                             void *user)
{
    (void) engine;
    seen_t *s = user;
    if (ev->kind == DS_EV_TICK) {
        s->ticks++;
        s->clock_ns = ev->clock_ns;
        s->wall_set = ev->p.tick.wall_set;
        s->wall_ns  = ev->p.tick.wall_ns;
    }
    return DS_OK_R;
}

static ds_result_t on_metric(ds_engine_t *engine, const ds_metric_t *m,
                             void *user)
{
    (void) engine;
    seen_t *s = user;
    if (strcmp(m->name, "ds.clock.advance_total") == 0) s->advances++;
    return DS_OK_R;
}

static int fail(const char *what, const char *why)
{
    fprintf(stderr, "FAIL: %s: %s\n", what, why);
    return 1;
}

/* A fresh engine on the mock clock, observed. */
static int mock_engine(ds_engine_t **e, seen_t *s)
{
    memset(s, 0, sizeof *s);
    *e = NULL;
    EXPECT_OK("engine", ds_engine_new(NULL, e));
    EXPECT_OK("mock clock", ds_engine_clock_set_mode(*e, DS_CLOCK_MOCK));
    EXPECT_OK("stream", ds_engine_set_stream_callback(*e, on_stream, s));
    EXPECT_OK("metric", ds_engine_set_metric_callback(*e, on_metric, s));
    return 0;
}

/* The refusal, the monotonic clock unmoved, and the metric not counted. */
static int refused_without_a_sample(const char *what, ds_engine_t *e, seen_t *s,
                                    uint64_t delta)
{
    uint64_t before = 0, after = 0;
    const int counted = s->advances;
    EXPECT_OK("clock_now", ds_engine_clock_now(e, &before));
    EXPECT_STATUS(what, ds_engine_clock_advance(e, delta), DS_ERR_TIME_RANGE);
    EXPECT_OK("clock_now", ds_engine_clock_now(e, &after));
    if (after != before) return fail(what, "the monotonic clock moved");
    if (s->advances != counted) return fail(what, "ds.clock.advance_total counted it");
    return 0;
}

/* As above, on an engine that has sampled: a pump after it records no TICK, so
   neither clock moved. */
static int refused(const char *what, ds_engine_t *e, seen_t *s, uint64_t delta)
{
    if (refused_without_a_sample(what, e, s, delta)) return 1;
    const int ticks = s->ticks;
    EXPECT_OK("pump", ds_engine_pump(e));
    if (s->ticks != ticks) return fail(what, "a clock moved, so the pump recorded a TICK");
    return 0;
}

/* A wall clock at `wall`, sampled by a pump, so a later TICK means a move. */
static int wall_at(ds_engine_t *e, seen_t *s, int64_t wall)
{
    EXPECT_OK("wall_clock_set", ds_engine_wall_clock_set(e, wall));
    EXPECT_OK("pump", ds_engine_pump(e));
    if (s->ticks != 1 || !s->wall_set || s->wall_ns != wall)
        return fail("wall_at", "premise: the first pump's TICK does not carry the wall");
    return 0;
}

static int the_wall_clocks_top(void)
{
    ds_engine_t *e;
    seen_t s;
    if (mock_engine(&e, &s) || wall_at(e, &s, INT64_MAX)) return 1;
    if (refused("wall at 2^63 - 1, advance 1", e, &s, 1)) return 1;
    EXPECT_OK("free", ds_engine_free(e));

    if (mock_engine(&e, &s) || wall_at(e, &s, INT64_MAX - 1)) return 1;
    EXPECT_OK("wall at 2^63 - 2, advance 1", ds_engine_clock_advance(e, 1));
    EXPECT_OK("pump", ds_engine_pump(e));
    if (s.advances != 1 || s.ticks != 2 || s.wall_ns != INT64_MAX)
        return fail("wall at 2^63 - 2", "the advance did not land on the top");
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

static int a_negative_wall_and_a_duration_past_any(void)
{
    ds_engine_t *e;
    seen_t s;
    if (mock_engine(&e, &s) || wall_at(e, &s, -5)) return 1;
    /* The sum is in range: the duration is what is refused. */
    if (refused("wall -5, duration 2^63", e, &s, TOP + 1u)) return 1;
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

static int no_wall_limits_nothing(void)
{
    ds_engine_t *e;
    seen_t s;
    if (mock_engine(&e, &s)) return 1;
    EXPECT_OK("no wall, duration 2^63 - 1", ds_engine_clock_advance(e, TOP));
    EXPECT_OK("pump", ds_engine_pump(e));
    if (s.advances != 1 || s.ticks != 1 || s.clock_ns != TOP || s.wall_set)
        return fail("no wall, duration 2^63 - 1", "not taken with the wall still unset");
    EXPECT_OK("free", ds_engine_free(e));

    if (mock_engine(&e, &s)) return 1;
    if (refused_without_a_sample("no wall, duration 2^63", e, &s, TOP + 1u)) return 1;
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

static int the_monotonic_clocks_top(void)
{
    ds_engine_t *e;
    seen_t s;
    uint64_t now = 0;
    if (mock_engine(&e, &s)) return 1;
    EXPECT_STATUS("clock_set to 2^63", ds_engine_clock_set(e, TOP + 1u),
                  DS_ERR_TIME_RANGE);
    EXPECT_OK("clock_now", ds_engine_clock_now(e, &now));
    if (now != 0) return fail("clock_set to 2^63", "the monotonic clock moved");
    EXPECT_OK("clock_set to 2^63 - 1", ds_engine_clock_set(e, TOP));
    if (refused_without_a_sample("monotonic at 2^63 - 1, advance 1", e, &s, 1)) return 1;
    EXPECT_STATUS("clock_set above the top from the top",
                  ds_engine_clock_set(e, UINT64_MAX), DS_ERR_TIME_RANGE);
    EXPECT_OK("monotonic at 2^63 - 1, advance 0", ds_engine_clock_advance(e, 0));
    EXPECT_OK("clock_now", ds_engine_clock_now(e, &now));
    if (now != TOP || s.advances != 1)
        return fail("advance 0", "not taken, or the clock moved");
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

static int live_and_halted_come_first(void)
{
    static const uint64_t deltas[] = { 1u, TOP + 1u };
    static const uint8_t junk[] = { 0x00, 0x01, 0x02, 0x03 };
    ds_engine_t *e = NULL;
    EXPECT_OK("engine", ds_engine_new(NULL, &e));
    for (size_t i = 0; i < sizeof deltas / sizeof deltas[0]; i++)
        EXPECT_STATUS("live", ds_engine_clock_advance(e, deltas[i]), DS_ERR_STATE);
    EXPECT_OK("free", ds_engine_free(e));

    /* A failed load spends the engine ([NFCT.1.1]). */
    e = NULL;
    EXPECT_OK("engine", ds_engine_new(NULL, &e));
    EXPECT_OK("mock clock", ds_engine_clock_set_mode(e, DS_CLOCK_MOCK));
    if (ds_engine_load_dsc(e, junk, sizeof junk).status == DS_OK)
        return fail("halted", "premise: junk bytes loaded");
    for (size_t i = 0; i < sizeof deltas / sizeof deltas[0]; i++)
        EXPECT_STATUS("halted", ds_engine_clock_advance(e, deltas[i]),
                      DS_ERR_ENGINE_HALTED);
    ds_engine_free(e);
    return 0;
}

int main(void)
{
    if (the_wall_clocks_top()) return 1;
    if (a_negative_wall_and_a_duration_past_any()) return 1;
    if (no_wall_limits_nothing()) return 1;
    if (the_monotonic_clocks_top()) return 1;
    if (live_and_halted_come_first()) return 1;
    printf("test_ntst_3_1__an_advance_past_a_clocks_range_is_refused: OK\n");
    return 0;
}
