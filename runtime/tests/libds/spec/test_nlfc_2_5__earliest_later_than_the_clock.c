/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NLFC.2.5]
 * ds_engine_next_deadline_ns "must report the earliest deadline later than the
 * monotonic clock's current value". All three kinds armed at 0 s: the cache
 * entry at 10 s, the `Lease` fact at 20 s, the timer at 30 s.
 *
 *   (a) At 0 s: 10 s, the earliest of the three.
 *   (b) The mock clock set exactly onto 10 s, with no pump: the entry is still
 *       live, since the engine does nothing at a deadline until a pump, and
 *       10 s is not later than the clock, so 20 s. A `>=` reports 10 s.
 *   (c) Set past the next, to 25 s: 30 s.
 *   (d) Set onto the last, 30 s: none.
 *   (e) A second engine, armed the same way, shows each kind's place in (a)
 *       is its own: the cache entry deleted, 20 s; the `Lease` fact retracted
 *       as well, 30 s.
 *
 * THE PATH ([STYL.5.10.8]): ds_engine_next_deadline_ns reads the clock's source
 * (ds_clock_source_ns), so a mock clock moved since the last pump counts, and
 * note_deadline (rete/wm_rete.c) and ds_cache_next_deadline (cache.c) keep only
 * an instant later than it.
 */
#include "spec_deadline.h"

int main(void)
{
    ds_engine_t *e = NULL;
    if (dl_engine(&e, dl_program())) return 1;
    if (dl_all_three(e, NULL)) return 1;
    if (dl_expect("(a) at 0 s", e, true, 10 * DL_SEC)) return 1;
    EXPECT_OK("clock_set 10 s", ds_engine_clock_set(e, 10 * DL_SEC));
    if (dl_expect("(b) at 10 s, no pump", e, true, 20 * DL_SEC)) return 1;
    EXPECT_OK("clock_set 25 s", ds_engine_clock_set(e, 25 * DL_SEC));
    if (dl_expect("(c) at 25 s, no pump", e, true, 30 * DL_SEC)) return 1;
    EXPECT_OK("clock_set 30 s", ds_engine_clock_set(e, 30 * DL_SEC));
    if (dl_expect("(d) at 30 s, no pump", e, false, 0)) return 1;
    EXPECT_OK("free", ds_engine_free(e));

    ds_fact_t *lease = NULL;
    if (dl_engine(&e, dl_program())) return 1;
    if (dl_all_three(e, &lease)) return 1;
    if (lease == NULL) return dl_fail("(e)", "premise: no Lease handle");
    if (dl_assert(e, "Drop", 1, NULL)) return 1;
    EXPECT_OK("pump", ds_engine_pump(e));
    if (dl_expect("(e) the cache entry deleted", e, true, 20 * DL_SEC)) return 1;
    EXPECT_OK("retract Lease", ds_engine_retract(e, lease));
    EXPECT_OK("pump", ds_engine_pump(e));
    if (dl_expect("(e) the Lease fact retracted", e, true, 30 * DL_SEC)) return 1;
    EXPECT_OK("free", ds_engine_free(e));

    printf("test_nlfc_2_5__earliest_later_than_the_clock: OK\n");
    return 0;
}
