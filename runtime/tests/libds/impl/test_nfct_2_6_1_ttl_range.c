/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * A TTL override whose deadline leaves the `Time` range is refused with
 * DS_ERR_TIME_RANGE, and nothing is asserted; the deadline is never wrapped
 * or saturated. It links no clause: [NFCT.2.6.1] is a tombstone, and
 * ds_engine_assert_with_ttl is internal (engine.h), kept because the RFCS
 * replayer restores a recorded per-fact TTL through it ([RFCS.7.4]).
 *
 * With the clock at T, UINT64_MAX and INT64_MAX - T + 1 are refused,
 * INT64_MAX - T is accepted with exactly that deadline, and an ordinary
 * override expires at T + override. A refusal is not a step, so it records
 * no TICK and no FactAssert ([RFCS.6.7], [LTIM.2.8.4]).
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "engine.h"   /* ds_engine_assert_with_ttl, libds-internal */
#include "rfcs/rfcs.h"

static int failures = 0;

#define CHECK(cond, msg)                                                      \
    do {                                                                      \
        if (!(cond)) {                                                        \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__); \
            failures++;                                                       \
        }                                                                     \
    } while (0)

#define CHECK_OK(r, msg)                                                      \
    do {                                                                      \
        ds_result_t rr_ = (r);                                                \
        if (rr_.status != DS_OK) {                                            \
            fprintf(stderr, "FAIL: %s: status=%d detail=%s (%s:%d)\n", (msg), \
                    rr_.status, rr_.detail ? rr_.detail : "(null)",           \
                    __FILE__, __LINE__);                                      \
            failures++;                                                       \
        }                                                                     \
    } while (0)

/* The schema's own TTL, which no case here reaches: every case overrides. */
#define SCHEMA_TTL_NS 1000000000ull
/* The assert clock T. Non-zero, so the boundary is INT64_MAX - T and not
   INT64_MAX: a check that ignored the clock would accept T + 1 too many. */
#define T_NS          7000000000ull
#define OVERRIDE_NS   5000000000ull

static const ds_slot_desc_t SLOTS[1] = {
    { .name = "level", .type = DS_SLOT_TYPE_INT,
      .identity_role = DS_IDENTITY_UNSPECIFIED },
};

static ds_engine_t *new_engine(const ds_schema_t **sc)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (!e) return NULL;
    CHECK_OK(ds_engine_register_schema(e, "Reading", DS_SCHEMA_LIFECYCLE_TTL,
                                       SCHEMA_TTL_NS, SLOTS, 1, sc),
             "register Reading");
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "clock_set_mode");
    CHECK_OK(ds_engine_clock_set(e, T_NS), "clock_set T");
    return e;
}

static ds_result_t assert_one(ds_engine_t *e, const ds_schema_t *sc,
                              int64_t level, uint64_t override, ds_fact_t **f)
{
    ds_slot_value_t v[1];
    memset(v, 0, sizeof(v));
    v[0].kind = DS_SLOT_INT;
    v[0].v.i  = level;
    return ds_engine_assert_with_ttl(e, sc, v, 1, override, f);
}

static size_t live(ds_engine_t *e)
{
    size_t n = (size_t)-1;
    CHECK_OK(ds_engine_fact_count(e, &n), "fact_count");
    return n;
}

static uint8_t g_stream[8192];
static size_t  g_stream_len = 0;

static ds_result_t sink(const uint8_t *bytes, size_t len, void *user)
{
    (void)user;
    if (g_stream_len + len > sizeof(g_stream))
        return (ds_result_t){ DS_ERR_INVAL, "sink overflow" };
    memcpy(g_stream + g_stream_len, bytes, len);
    g_stream_len += len;
    return (ds_result_t){ DS_OK, NULL };
}

static int count_atoms(uint32_t which)
{
    ds_rfcs_reader_t rd;
    ds_rfcs_reader_init(&rd, g_stream, g_stream_len);
    int n = 0;
    for (;;) {
        uint32_t       atom = 0;
        const uint8_t *body = NULL;
        size_t         blen = 0;
        bool           done = false;
        ds_result_t    r = ds_rfcs_next(&rd, &atom, &body, &blen, &done);
        if (r.status != DS_OK || done) break;
        if (atom == which) n++;
    }
    return n;
}

/* UINT64_MAX: refused, nothing in working memory, no FactAssert recorded. */
static void test_uint64_max_is_refused(void)
{
    const ds_schema_t *sc = NULL;
    ds_engine_t *e = new_engine(&sc);
    if (!e) return;

    static ds_rfcs_recorder_t rec;
    static uint8_t            recbuf[4096];
    g_stream_len = 0;
    CHECK_OK(ds_rfcs_record_to(e, &rec, sink, NULL, recbuf, sizeof(recbuf)),
             "record_to");

    ds_fact_t *f = (ds_fact_t *)&f;   /* not NULL, so the refusal must clear it */
    ds_result_t r = assert_one(e, sc, 1, UINT64_MAX, &f);
    printf("    UINT64_MAX: status=%d (expected %d)\n", r.status, DS_ERR_TIME_RANGE);
    CHECK(r.status == DS_ERR_TIME_RANGE, "UINT64_MAX is DS_ERR_TIME_RANGE");
    CHECK(f == NULL, "a refused assert hands back no fact");
    CHECK(live(e) == 0, "working memory is unchanged");
    /* Read before the pump below, which takes a sample of its own. */
    CHECK(count_atoms(DS_ATOM_CLOCK_ADVANCE) == 0,
          "the refused call records no TICK: it is not a step ([RFCS.6.7])");
    CHECK_OK(ds_engine_pump(e), "pump after the refusal");
    CHECK(live(e) == 0, "still nothing after a pump");
    CHECK(count_atoms(DS_ATOM_FACT_ASSERT) == 0, "no FactAssert is recorded");

    ds_engine_set_stream_callback(e, NULL, NULL);
    ds_engine_free(e);
}

/* INT64_MAX - T + 1 refused; INT64_MAX - T accepted with that deadline. */
static void test_the_boundary_is_int64_max_minus_t(void)
{
    const ds_schema_t *sc = NULL;
    ds_engine_t *e = new_engine(&sc);
    if (!e) return;

    const uint64_t at_bound = (uint64_t)INT64_MAX - T_NS;
    ds_fact_t *f = NULL;

    ds_result_t r = assert_one(e, sc, 1, at_bound + 1u, &f);
    CHECK(r.status == DS_ERR_TIME_RANGE, "INT64_MAX - T + 1 is refused");
    CHECK(live(e) == 0, "and asserts nothing");

    f = NULL;
    CHECK_OK(assert_one(e, sc, 2, at_bound, &f), "INT64_MAX - T is accepted");
    CHECK(live(e) == 1, "and asserts the fact");
    if (f != NULL) {
        uint64_t deadline = 0;
        CHECK_OK(ds_fact_get_ttl_deadline_ns(f, &deadline), "deadline");
        printf("    at the bound: deadline=%llu (expected %llu)\n",
               (unsigned long long)deadline, (unsigned long long)INT64_MAX);
        CHECK(deadline == (uint64_t)INT64_MAX,
              "the deadline is exactly T + override = INT64_MAX");
    }
    ds_engine_free(e);
}

/* An ordinary override still expires the fact at T + override. */
static void test_an_ordinary_override_expires(void)
{
    const ds_schema_t *sc = NULL;
    ds_engine_t *e = new_engine(&sc);
    if (!e) return;

    ds_fact_t *f = NULL;
    CHECK_OK(assert_one(e, sc, 3, OVERRIDE_NS, &f), "ordinary override");
    CHECK_OK(ds_engine_pump(e), "pump at T");
    CHECK(live(e) == 1, "live at T");

    CHECK_OK(ds_engine_clock_advance(e, OVERRIDE_NS - 1u), "advance to T + override - 1");
    CHECK_OK(ds_engine_pump(e), "pump");
    CHECK(live(e) == 1, "live at T + override - 1 ns");

    CHECK_OK(ds_engine_clock_advance(e, 1u), "advance to T + override");
    CHECK_OK(ds_engine_pump(e), "pump that sweeps");
    CHECK(live(e) == 0, "gone at T + override");
    ds_engine_free(e);
}

int main(void)
{
    printf("=== test_nfct_2_6_1_ttl_range ===\n");
    test_uint64_max_is_refused();
    test_the_boundary_is_int64_max_minus_t();
    test_an_ordinary_override_expires();
    if (failures) {
        fprintf(stderr, "test_nfct_2_6_1_ttl_range: %d FAILURE(S)\n", failures);
        return 1;
    }
    printf("=== test_nfct_2_6_1_ttl_range: ALL PASSED ===\n");
    return 0;
}
