/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NLFC.2.5]
 * Each of the clause's three kinds is a deadline, "whether or not a rule acts
 * on it": the `fire_at` of a live timer fact ([LTAC.3.2]), the expiry of a live
 * fact that has a TTL ([LDTL.1.1]), and the expiry of a cache entry
 * ([NSTG.2.4.2]). Each alone on a fresh engine, armed at an instant of its
 * own, so the answer is the arming instant plus the TTL and not the TTL:
 *
 *   timer   `Arm` asserted at 100 s and pumped; `after 30_s`    130 s
 *   ttl     `Lease` asserted at 5 s, no pump; `scope ttl 20_s`   25 s
 *   cache   `Write` asserted at 7 s and pumped; `ttl: 10_s`      17 s
 *
 * Before each is armed the engine holds none, so the answer is that kind's.
 * No rule matches `Lease`.
 *
 * THE PATH ([STYL.5.10.8]): ds_engine_next_deadline_ns (engine.c);
 * ds_rete_wm_next_deadline (rete/wm_rete.c) for the timer fact's first slot
 * and the fact's deadline_ns, ds_cache_next_deadline (cache.c) for the entry's
 * ttl_deadline_ns.
 */
#include "spec_deadline.h"

static int one_kind(const char *what, uint64_t at_s, const char *schema,
                    bool pump, uint64_t want_s)
{
    ds_engine_t *e = NULL;
    if (dl_engine(&e, dl_program())) return 1;
    EXPECT_OK("clock_set", ds_engine_clock_set(e, at_s * DL_SEC));
    if (dl_expect(what, e, false, 0)) return 1;
    if (dl_assert(e, schema, 1, NULL)) return 1;
    if (pump) EXPECT_OK("pump", ds_engine_pump(e));
    if (dl_expect(what, e, true, want_s * DL_SEC)) return 1;
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

int main(void)
{
    if (one_kind("a timer's fire_at", 100, "Arm", true, 130)) return 1;
    if (one_kind("a ttl fact's expiry", 5, "Lease", false, 25)) return 1;
    if (one_kind("a cache entry's expiry", 7, "Write", true, 17)) return 1;
    printf("test_nlfc_2_5__each_of_the_three_kinds: OK\n");
    return 0;
}
