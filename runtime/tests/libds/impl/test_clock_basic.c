/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * test_clock_basic — exercise ds_engine_clock_* APIs in both modes.
 *
 * Intentionally no real sleeps / timing assumptions. Tests assert on
 * monotonic-non-decreasing for live mode and exact equality for mock.
 */
#include <stdio.h>
#include <stdlib.h>

#include "libds.h"

static int fail(const char *msg, ds_result_t r)
{
    fprintf(stderr, "FAIL: %s: status=%d detail=%s\n",
            msg, r.status, r.detail ? r.detail : "(null)");
    return 1;
}

static int expect_ok(const char *what, ds_result_t r)
{
    if (r.status != DS_OK) {
        return fail(what, r);
    }
    return 0;
}

static int expect_status(const char *what, ds_result_t r, ds_status_t want)
{
    if (r.status != want) {
        fprintf(stderr, "FAIL: %s: want status %d, got %d (%s)\n",
                what, want, r.status, r.detail ? r.detail : "(null)");
        return 1;
    }
    return 0;
}

int main(void)
{
    ds_engine_t *e = NULL;
    ds_result_t r;

    r = ds_engine_new(NULL, &e);
    if (expect_ok("ds_engine_new", r)) return 1;

    /* Default mode is LIVE. */
    ds_clock_mode_t mode = (ds_clock_mode_t) -1;
    r = ds_engine_clock_mode(e, &mode);
    if (expect_ok("ds_engine_clock_mode", r)) return 1;
    if (mode != DS_CLOCK_LIVE) {
        fprintf(stderr, "FAIL: default mode: want LIVE (%d), got %d\n",
                (int) DS_CLOCK_LIVE, (int) mode);
        return 1;
    }

    /* Live clock reads are non-decreasing. */
    uint64_t t1 = 0, t2 = 0;
    r = ds_engine_clock_now(e, &t1);
    if (expect_ok("clock_now #1", r)) return 1;
    r = ds_engine_clock_now(e, &t2);
    if (expect_ok("clock_now #2", r)) return 1;
    if (t2 < t1) {
        fprintf(stderr, "FAIL: live clock went backwards: t1=%lu t2=%lu\n",
                (unsigned long) t1, (unsigned long) t2);
        return 1;
    }

    /* clock_set / advance are errors in live mode. */
    r = ds_engine_clock_set(e, 42);
    if (expect_status("clock_set in live", r, DS_ERR_STATE)) return 1;
    r = ds_engine_clock_advance(e, 100);
    if (expect_status("clock_advance in live", r, DS_ERR_STATE)) return 1;

    /* Switch to mock. The mock clock starts at a fixed 0, whatever the live
       clock read ([NLFC.5.4]). */
    r = ds_engine_clock_set_mode(e, DS_CLOCK_MOCK);
    if (expect_ok("set_mode MOCK", r)) return 1;
    r = ds_engine_clock_mode(e, &mode);
    if (expect_ok("clock_mode after switch", r)) return 1;
    if (mode != DS_CLOCK_MOCK) {
        fprintf(stderr, "FAIL: mode after switch: want MOCK, got %d\n", (int) mode);
        return 1;
    }
    uint64_t t3 = 0;
    r = ds_engine_clock_now(e, &t3);
    if (expect_ok("clock_now after MOCK switch", r)) return 1;
    if (t3 != 0) {
        fprintf(stderr, "FAIL: mock clock starts at %lu, want 0 (the live "
                "reading was %lu)\n", (unsigned long) t3, (unsigned long) t2);
        return 1;
    }

    /* Set and read. */
    r = ds_engine_clock_set(e, 1000000);
    if (expect_ok("clock_set 1e6", r)) return 1;
    uint64_t t4 = 0;
    r = ds_engine_clock_now(e, &t4);
    if (expect_ok("clock_now after set", r)) return 1;
    if (t4 != 1000000) {
        fprintf(stderr, "FAIL: clock_set then read: want 1000000, got %lu\n",
                (unsigned long) t4);
        return 1;
    }

    /* Advance. */
    r = ds_engine_clock_advance(e, 250);
    if (expect_ok("clock_advance 250", r)) return 1;
    uint64_t t5 = 0;
    r = ds_engine_clock_now(e, &t5);
    if (expect_ok("clock_now after advance", r)) return 1;
    if (t5 != 1000250) {
        fprintf(stderr, "FAIL: set+advance: want 1000250, got %lu\n",
                (unsigned long) t5);
        return 1;
    }

    /* Advance by 0 is OK. */
    r = ds_engine_clock_advance(e, 0);
    if (expect_ok("clock_advance 0", r)) return 1;

    /* Switch back to live; time continues >= last mock value. */
    r = ds_engine_clock_set_mode(e, DS_CLOCK_LIVE);
    if (expect_ok("set_mode LIVE", r)) return 1;
    uint64_t t6 = 0;
    r = ds_engine_clock_now(e, &t6);
    if (expect_ok("clock_now after LIVE switch", r)) return 1;
    if (t6 < t5) {
        fprintf(stderr, "FAIL: live time after return: want >= %lu, got %lu\n",
                (unsigned long) t5, (unsigned long) t6);
        return 1;
    }

    /* Redundant mode switch is a no-op. */
    r = ds_engine_clock_set_mode(e, DS_CLOCK_LIVE);
    if (expect_ok("redundant set_mode LIVE", r)) return 1;

    /* A second entry into mock starts at 0 again: the origin is fixed, not
       "where the mock clock last was" and not the live reading (t6 > 0). */
    r = ds_engine_clock_set_mode(e, DS_CLOCK_MOCK);
    if (expect_ok("set_mode MOCK again", r)) return 1;
    uint64_t t7 = 1;
    r = ds_engine_clock_now(e, &t7);
    if (expect_ok("clock_now after second MOCK switch", r)) return 1;
    if (t7 != 0) {
        fprintf(stderr, "FAIL: second mock entry starts at %lu, want 0\n",
                (unsigned long) t7);
        return 1;
    }
    r = ds_engine_clock_set_mode(e, DS_CLOCK_LIVE);
    if (expect_ok("set_mode LIVE again", r)) return 1;

    /* NULL-arg rejection. */
    r = ds_engine_clock_now(NULL, &t1);
    if (expect_status("clock_now NULL engine", r, DS_ERR_INVAL)) return 1;
    r = ds_engine_clock_now(e, NULL);
    if (expect_status("clock_now NULL out_ns", r, DS_ERR_INVAL)) return 1;
    r = ds_engine_clock_mode(NULL, &mode);
    if (expect_status("clock_mode NULL engine", r, DS_ERR_INVAL)) return 1;

    /* Unknown mode value. */
    r = ds_engine_clock_set_mode(e, (ds_clock_mode_t) 999);
    if (expect_status("set_mode bogus", r, DS_ERR_INVAL)) return 1;

    r = ds_engine_free(e);
    if (expect_ok("ds_engine_free", r)) return 1;

    printf("test_clock_basic: OK\n");
    return 0;
}
