/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NLFC.2.5]
 * "The call is a read ... It must not take a clock sample ([NTST.3.3]), must
 * record nothing, and must not change what any later call or pump does."
 *
 * Two runs of one script on the mock clock: set 5 s, set 7 s, assert `Write`,
 * pump. The queried run calls ds_engine_next_deadline_ns after each clock
 * move; the other does not. Each records every stream event's kind, seq and
 * clock_ns. A call that sampled the clock records a DS_EV_TICK at 5 s that
 * the other run has not, and moves every later seq. The two traces must be
 * equal, and the call after the pump must answer the same in both: the
 * entry's 17 s.
 *
 * Premise: the plain run records exactly one TICK, at 7 s, so a TICK is what
 * a sample would add.
 *
 * THE PATH ([STYL.5.10.8]): ds_engine_next_deadline_ns (engine.c) reads the
 * clock with ds_clock_source_ns, not with a sampling read.
 */
#include "spec_deadline.h"

#define MAX_EVENTS 64

typedef struct {
    int                 n;
    int                 overflow;
    ds_stream_ev_kind_t kind[MAX_EVENTS];
    uint64_t            seq[MAX_EVENTS];
    uint64_t            clock_ns[MAX_EVENTS];
} trace_t;

static ds_result_t record(ds_engine_t *engine, const ds_stream_ev_t *ev,
                          void *user)
{
    (void) engine;
    trace_t *t = user;
    if (t->n >= MAX_EVENTS) { t->overflow = 1; return DS_OK_R; }
    t->kind[t->n]     = ev->kind;
    t->seq[t->n]      = ev->seq;
    t->clock_ns[t->n] = ev->clock_ns;
    t->n++;
    return DS_OK_R;
}

static int query(ds_engine_t *e)
{
    uint64_t ns = 0;
    bool has = false;
    EXPECT_OK("next_deadline", ds_engine_next_deadline_ns(e, &ns, &has));
    return 0;
}

static int run(bool queried, trace_t *t)
{
    memset(t, 0, sizeof *t);
    ds_engine_t *e = NULL;
    if (dl_engine(&e, dl_program())) return 1;
    EXPECT_OK("stream", ds_engine_set_stream_callback(e, record, t));
    EXPECT_OK("clock_set 5 s", ds_engine_clock_set(e, 5 * DL_SEC));
    if (queried && query(e)) return 1;
    EXPECT_OK("clock_set 7 s", ds_engine_clock_set(e, 7 * DL_SEC));
    if (queried && query(e)) return 1;
    if (dl_assert(e, "Write", 1, NULL)) return 1;
    EXPECT_OK("pump", ds_engine_pump(e));
    if (t->overflow) return dl_fail("run", "more events than MAX_EVENTS");
    if (dl_expect(queried ? "after the pump, queried" : "after the pump, plain",
                  e, true, 17 * DL_SEC))
        return 1;
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

int main(void)
{
    static trace_t plain, queried;
    if (run(false, &plain) || run(true, &queried)) return 1;

    int ticks = 0;
    for (int i = 0; i < plain.n; i++)
        if (plain.kind[i] == DS_EV_TICK) {
            ticks++;
            if (plain.clock_ns[i] != 7 * DL_SEC)
                return dl_fail("premise", "the plain run's TICK is not at 7 s");
        }
    if (ticks != 1) return dl_fail("premise", "the plain run has not one TICK");

    if (queried.n != plain.n)
        return dl_fail("the traces", "the queried run recorded another number "
                       "of events");
    for (int i = 0; i < plain.n; i++)
        if (queried.kind[i] != plain.kind[i] || queried.seq[i] != plain.seq[i]
                || queried.clock_ns[i] != plain.clock_ns[i]) {
            fprintf(stderr, "FAIL: event %d: queried kind=%d seq=%llu clock=%llu, "
                    "plain kind=%d seq=%llu clock=%llu\n", i,
                    (int) queried.kind[i], (unsigned long long) queried.seq[i],
                    (unsigned long long) queried.clock_ns[i],
                    (int) plain.kind[i], (unsigned long long) plain.seq[i],
                    (unsigned long long) plain.clock_ns[i]);
            return 1;
        }

    printf("test_nlfc_2_5__takes_no_sample: OK\n");
    return 0;
}
