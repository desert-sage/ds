/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * A step reads the live clock once, and a check that judges the step's sample
 * before it is taken judges that reading, so a call the check admits is never
 * refused after its TICK.
 *
 * A UNIT TEST, LINKED TO NO CLAUSE. Its subject is libds's: how many times a
 * step reads a LIVE source. The Mercury runtime's source is a value in its
 * engine state, so its check and its sample cannot disagree, and the
 * differential runs both on mock clocks, which do not move between reads.
 * [RFCS.6.7] and [NLFC.9.5] are ratified by their own tests on mock clocks
 * (test_nfct_2_6_1_ttl_range, test_cache_spec's NLFC.9.5 pair).
 *
 * THE INJECTED SOURCE. The link wraps clock_gettime (libds.build's row), and
 * every CLOCK_MONOTONIC read returns the scripted value and then moves it on
 * by 1 ns: a live clock as adversarial as a live clock can be. The wall clock
 * is the platform's. Nothing in libds is changed for the test.
 *
 * Cases, each at the edge of the `Time` range, INT64_MAX:
 *   - a host assert of a `ttl` schema whose deadline is exactly INT64_MAX at
 *     the reading is admitted, with that deadline, its TICK and the reading
 *     as the held sample;
 *   - one nanosecond later it is refused, records no TICK and takes no sample
 *     (the control);
 *   - a first pump fixes a held seed's deadline from the reading it judged:
 *     exactly INT64_MAX.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "libds.h"
#include "engine.h"   /* ds_engine_register_schema, the clock and the cache */
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
    g_next_mono_ns++;
    return 0;
}

#define TTL_NS   1000000000ull                      /* the schema's own TTL */
#define HOUR_NS  (3600ull * 1000000000ull)          /* the seed's */

static const ds_slot_desc_t SLOTS[1] = {
    { .name = "level", .type = DS_SLOT_TYPE_INT,
      .identity_role = DS_IDENTITY_UNSPECIFIED },
};

/* A live-clock engine (the default) with a `ttl` schema. */
static ds_engine_t *new_engine(const ds_schema_t **sc)
{
    g_next_mono_ns = 0;
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (!e) return NULL;
    CHECK(e->clock.mode == DS_CLOCK_LIVE, "the engine's clock is live");
    CHECK_OK(ds_engine_register_schema(e, "Reading", DS_SCHEMA_LIFECYCLE_TTL,
                                       TTL_NS, SLOTS, 1, sc),
             "register Reading");
    return e;
}

/* Make the engine's next read of its source `source_ns`. */
static void script_reading(const ds_engine_t *e, uint64_t source_ns)
{
    g_next_mono_ns = source_ns + e->clock.live_base_ns;
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

static ds_result_t assert_one(ds_engine_t *e, const ds_schema_t *sc,
                              ds_fact_t **f)
{
    ds_slot_value_t v[1];
    memset(v, 0, sizeof(v));
    v[0].kind = DS_SLOT_INT;
    v[0].v.i  = 1;
    return ds_engine_assert(e, sc, v, 1, f);
}

static size_t live(ds_engine_t *e)
{
    size_t n = (size_t)-1;
    CHECK_OK(ds_engine_fact_count(e, &n), "fact_count");
    return n;
}

/* The reading puts the deadline exactly at INT64_MAX: admitted, and the step
   holds that reading. */
static void test_assert_at_the_bound_is_admitted(void)
{
    const ds_schema_t *sc = NULL;
    ds_engine_t *e = new_engine(&sc);
    if (!e) return;

    static ds_rfcs_recorder_t rec;
    static uint8_t            recbuf[4096];
    g_stream_len = 0;
    CHECK_OK(ds_rfcs_record_to(e, &rec, sink, NULL, recbuf, sizeof(recbuf)),
             "record_to");

    const uint64_t reading = (uint64_t)INT64_MAX - TTL_NS;
    script_reading(e, reading);
    ds_fact_t *f = NULL;
    ds_result_t r = assert_one(e, sc, &f);
    printf("    at the bound: status=%d (expected %d)\n", r.status, DS_OK);
    CHECK_OK(r, "an assert whose deadline is INT64_MAX at the reading");
    CHECK(f != NULL && live(e) == 1, "the fact is in working memory");
    if (f != NULL) {
        uint64_t deadline = 0;
        CHECK_OK(ds_fact_get_ttl_deadline_ns(f, &deadline), "deadline");
        printf("    deadline=%llu (expected %llu)\n",
               (unsigned long long)deadline, (unsigned long long)INT64_MAX);
        CHECK(deadline == (uint64_t)INT64_MAX,
              "the deadline is the judged reading plus the TTL, INT64_MAX");
    }
    CHECK(e->clock.held_mono_ns == reading,
          "the step holds the reading the check judged");
    CHECK(count_atoms(DS_ATOM_CLOCK_ADVANCE) == 1, "the step's TICK");
    CHECK(count_atoms(DS_ATOM_FACT_ASSERT) == 1, "and its FactAssert");

    ds_engine_set_stream_callback(e, NULL, NULL);
    ds_engine_free(e);
}

/* The control: one nanosecond past the bound at the reading is refused, and
   the call records no TICK and takes no sample. */
static void test_assert_past_the_bound_records_nothing(void)
{
    const ds_schema_t *sc = NULL;
    ds_engine_t *e = new_engine(&sc);
    if (!e) return;

    static ds_rfcs_recorder_t rec;
    static uint8_t            recbuf[4096];
    g_stream_len = 0;
    CHECK_OK(ds_rfcs_record_to(e, &rec, sink, NULL, recbuf, sizeof(recbuf)),
             "record_to");

    script_reading(e, (uint64_t)INT64_MAX - TTL_NS + 1u);
    ds_fact_t *f = (ds_fact_t *)&f;   /* not NULL, so the refusal must clear it */
    ds_result_t r = assert_one(e, sc, &f);
    printf("    past the bound: status=%d (expected %d)\n", r.status,
           DS_ERR_TIME_RANGE);
    CHECK(r.status == DS_ERR_TIME_RANGE, "refused with DS_ERR_TIME_RANGE");
    CHECK(f == NULL, "a refused assert hands back no fact");
    CHECK(live(e) == 0, "working memory is unchanged");
    CHECK(!e->clock.sampled, "no sample is taken");
    CHECK(count_atoms(DS_ATOM_CLOCK_ADVANCE) == 0, "no TICK is recorded");

    ds_engine_set_stream_callback(e, NULL, NULL);
    ds_engine_free(e);
}

/* [NLFC.9.5] at the first pump: the held seed's deadline is fixed from the
   reading the check judged. */
static void test_first_pump_fixes_the_judged_deadline(void)
{
    const ds_schema_t *sc = NULL;
    ds_engine_t *e = new_engine(&sc);
    if (!e) return;

    ds_json_t *one = NULL;
    CHECK_OK(ds_json_parse("1", 1, &one), "json_parse 1");
    CHECK_OK(ds_engine_cache_seed(e, "k", one, HOUR_NS), "seed k, ttl 1 h");

    const uint64_t reading = (uint64_t)INT64_MAX - HOUR_NS;
    script_reading(e, reading);
    CHECK_OK(ds_engine_pump(e), "the first pump, at INT64_MAX - 1 h");
    CHECK(e->clock.held_mono_ns == reading,
          "the pump holds the reading the check judged");
    const ds_cache_entry_t *k = ds_cache_key_count(&e->cache) == 1
        ? ds_cache_entry_at(&e->cache, 0) : NULL;
    CHECK(k != NULL, "the cache holds k");
    if (k != NULL) {
        printf("    seed deadline=%llu (expected %llu)\n",
               (unsigned long long)k->ttl_deadline_ns,
               (unsigned long long)INT64_MAX);
        CHECK(k->held_ttl_ns == 0, "the first sample fixed k's deadline");
        CHECK(k->ttl_deadline_ns == (uint64_t)INT64_MAX,
              "k's deadline is the judged reading plus 1 h, INT64_MAX");
    }

    ds_engine_free(e);
    ds_json_free(one);
}

int main(void)
{
    printf("=== test_rfcs_6_7_one_clock_read ===\n");
    test_assert_at_the_bound_is_admitted();
    test_assert_past_the_bound_records_nothing();
    test_first_pump_fixes_the_judged_deadline();
    if (failures) {
        fprintf(stderr, "test_rfcs_6_7_one_clock_read: %d FAILURE(S)\n",
                failures);
        return 1;
    }
    printf("=== test_rfcs_6_7_one_clock_read: ALL PASSED ===\n");
    return 0;
}
