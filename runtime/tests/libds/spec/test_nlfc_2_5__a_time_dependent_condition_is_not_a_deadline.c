/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NLFC.2.5]
 * "An instant at which a time-dependent condition changes ([LTIM.2.4.1]) is
 * not a deadline." `held` matches a `Ping` once it has been live 3 s
 * (`p.dwell >= 3_s`), so its condition changes at 3 s; the program holds no
 * timer, no TTL fact and no cache entry.
 *
 *   (a) The `Ping` asserted at 0 s and pumped: none.
 *   (b) At 2 s, with the change still ahead of the clock: none. An engine
 *       that counted the change reports 3 s here.
 *   (c) The control: at 3 s a pump fires `held` once, so the instant (b)
 *       leaves out is a real change of the condition.
 *
 * THE PATH ([STYL.5.10.8]): ds_engine_next_deadline_ns (engine.c), whose two
 * scans, ds_rete_wm_next_deadline and ds_cache_next_deadline, read only a
 * fact's deadline_ns, a timer fact's `fire_at` and a cache entry's expiry.
 */
#include "spec_deadline.h"

static const char *PROGRAM =
    "schema Ping scope logical:\n"
    "    id: Int key\n"
    "\n"
    "rule held:\n"
    "    Ping p where p.dwell >= 3_s\n"
    "->\n"
    "    log critical \"fired\"\n";

static ds_result_t count_logs(ds_engine_t *engine, const ds_stream_ev_t *ev,
                              void *user)
{
    (void) engine;
    if (ev->kind == DS_EV_ACTION_LOG) (*(int *) user)++;
    return DS_OK_R;
}

int main(void)
{
    int logs = 0;
    ds_engine_t *e = NULL;
    if (dl_engine(&e, PROGRAM)) return 1;
    EXPECT_OK("stream", ds_engine_set_stream_callback(e, count_logs, &logs));

    if (dl_assert(e, "Ping", 1, NULL)) return 1;
    EXPECT_OK("pump", ds_engine_pump(e));
    if (dl_expect("(a) at 0 s", e, false, 0)) return 1;

    EXPECT_OK("clock_set 2 s", ds_engine_clock_set(e, 2 * DL_SEC));
    if (dl_expect("(b) at 2 s", e, false, 0)) return 1;
    if (logs != 0) return dl_fail("(b)", "premise: `held` fired before 3 s");

    EXPECT_OK("clock_set 3 s", ds_engine_clock_set(e, 3 * DL_SEC));
    EXPECT_OK("pump", ds_engine_pump(e));
    if (logs != 1)
        return dl_fail("(c)", "premise: `held` did not fire once at 3 s, so "
                       "its condition does not change there");

    EXPECT_OK("free", ds_engine_free(e));
    printf("test_nlfc_2_5__a_time_dependent_condition_is_not_a_deadline: OK\n");
    return 0;
}
