/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [LTIM.2.8.2]
 * "The runtime must hold a live reading past the top at the top": a mock clock
 * at 2^63 - 1, switched to live, reads 2^63 - 1 and does not decrease. Only a
 * live clock continuing from a mock one can reach the top, and no vector can
 * switch a clock to live.
 *
 * THE PATH: ds_engine_clock_now -> ds_clock_source_ns -> source_mono_ns's live
 * arm. Without the hold the first read is the top plus the time since the
 * switch.
 */
#include "spec_common.h"

#include <time.h>

#define TOP ((uint64_t) INT64_MAX)

static void one_millisecond(void)
{
    const struct timespec ms = { 0, 1000000 };
    nanosleep(&ms, NULL);
}

int main(void)
{
    ds_engine_t *e = NULL;
    uint64_t first = 0, second = 0;
    EXPECT_OK("engine", ds_engine_new(NULL, &e));
    EXPECT_OK("mock clock", ds_engine_clock_set_mode(e, DS_CLOCK_MOCK));
    EXPECT_OK("clock_set to the top", ds_engine_clock_set(e, TOP));
    EXPECT_OK("switch to live", ds_engine_clock_set_mode(e, DS_CLOCK_LIVE));
    one_millisecond();
    EXPECT_OK("clock_now", ds_engine_clock_now(e, &first));
    one_millisecond();
    EXPECT_OK("clock_now", ds_engine_clock_now(e, &second));
    if (first != TOP || second != TOP) {
        fprintf(stderr, "FAIL: read %llu then %llu, want the top\n",
                (unsigned long long) first, (unsigned long long) second);
        return 1;
    }
    EXPECT_OK("free", ds_engine_free(e));
    printf("test_ltim_2_8_2__a_live_reading_past_the_top_is_held: OK\n");
    return 0;
}
