/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * A per-fact TTL survives a record/replay round trip: the FactAssert carries
 * `ttl_ns`, and the replay honours it ([RFCS.7.4]). The fact is asserted
 * through ds_engine_assert_with_ttl with an override longer than the
 * schema's TTL.
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

#define SCHEMA_TTL_NS   1000000000ull
#define OVERRIDE_TTL_NS 5000000000ull
/* Past the schema's TTL, short of the override. */
#define BETWEEN_NS      2000000000ull

static const ds_slot_desc_t SLOTS[1] = {
    { .name = "level", .type = DS_SLOT_TYPE_INT,
      .identity_role = DS_IDENTITY_UNSPECIFIED },
};

static const ds_schema_t *register_reading(ds_engine_t *e)
{
    const ds_schema_t *sc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Reading", DS_SCHEMA_LIFECYCLE_TTL,
                                       SCHEMA_TTL_NS, SLOTS, 1, &sc),
             "register_schema Reading");
    return sc;
}

static uint8_t g_stream[8192];
static size_t  g_stream_len = 0;

static ds_result_t test_sink(const uint8_t *bytes, size_t len, void *user)
{
    (void)user;
    if (g_stream_len + len > sizeof(g_stream))
        return (ds_result_t){ DS_ERR_INVAL, "sink overflow" };
    memcpy(g_stream + g_stream_len, bytes, len);
    g_stream_len += len;
    return (ds_result_t){ DS_OK, NULL };
}

/* Record one fact asserted with a per-emit override, and nothing else. The
   clock does not advance, so the recording carries no expiry — the deadline
   is the only thing under test. */
static void record_an_override(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t       *src = NULL;
    CHECK_OK(ds_engine_new(&cfg, &src), "engine_new src");
    if (!src)
        return;
    const ds_schema_t *sc = register_reading(src);

    CHECK_OK(ds_engine_clock_set_mode(src, DS_CLOCK_MOCK), "clock_set_mode src");
    CHECK_OK(ds_engine_clock_set(src, 0), "clock_set 0 src");

    static ds_rfcs_recorder_t rec;
    static uint8_t            recbuf[4096];
    g_stream_len = 0;
    CHECK_OK(ds_rfcs_record_to(src, &rec, test_sink, NULL, recbuf, sizeof(recbuf)),
             "record_to");

    ds_slot_value_t v[1];
    memset(v, 0, sizeof(v));
    v[0].kind = DS_SLOT_INT;
    v[0].v.i  = 7;
    ds_fact_t *f = NULL;
    CHECK_OK(ds_engine_assert_with_ttl(src, sc, v, 1, OVERRIDE_TTL_NS, &f),
             "assert_with_ttl override");
    CHECK_OK(ds_engine_pump(src), "pump after assert");

    uint64_t deadline = 0;
    CHECK_OK(ds_fact_get_ttl_deadline_ns(f, &deadline), "src deadline");
    CHECK(deadline == OVERRIDE_TTL_NS,
          "source fact carries the OVERRIDE deadline, not the schema default");

    CHECK(rec.last.status == DS_OK, "recorder had no error");
    ds_engine_set_stream_callback(src, NULL, NULL);
    ds_engine_free(src);
}

/* The FactAssert carries the TTL window. */
static void check_wire_carries_the_window(void)
{
    ds_rfcs_reader_t rd;
    ds_rfcs_reader_init(&rd, g_stream, g_stream_len);
    bool saw_fcem = false;
    for (;;) {
        uint32_t       atom = 0;
        const uint8_t *body = NULL;
        size_t         blen = 0;
        bool           done = false;
        CHECK_OK(ds_rfcs_next(&rd, &atom, &body, &blen, &done), "reader next");
        if (done)
            break;
        if (atom != DS_ATOM_FACT_ASSERT)
            continue;
        saw_fcem = true;
        ds_rfcs_fcem_t fc;
        CHECK_OK(ds_rfcs_decode_fcem(body, blen, &fc), "decode_fcem");
        printf("    FactAssert ttl_ns=%llu (expected %llu)\n",
               (unsigned long long)fc.ttl_ns,
               (unsigned long long)OVERRIDE_TTL_NS);
        CHECK(fc.ttl_ns == OVERRIDE_TTL_NS,
              "FactAssert carries the TTL WINDOW (RFCS.7.4)");
    }
    CHECK(saw_fcem, "the stream contains a FactAssert");
}

/* After the replay, the fact is live past the schema's TTL and gone past the
   override. */
static void check_replay_honours_the_window(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t       *dst = NULL;
    CHECK_OK(ds_engine_new(&cfg, &dst), "engine_new dst");
    if (!dst)
        return;
    (void)register_reading(dst);
    CHECK_OK(ds_engine_clock_set_mode(dst, DS_CLOCK_MOCK), "clock_set_mode dst");
    CHECK_OK(ds_engine_clock_set(dst, 0), "clock_set 0 dst");

    static uint8_t          strbuf[8192];
    ds_rfcs_replay_result_t rr;
    memset(&rr, 0, sizeof(rr));
    /* The program has no rules, so only the TTL sweep can take the fact
       out. */
    CHECK_OK(ds_rfcs_replay(dst, g_stream, g_stream_len, strbuf, sizeof(strbuf), &rr),
             "replay");

    size_t n = (size_t)-1;
    CHECK_OK(ds_engine_fact_count(dst, &n), "fact_count after replay");
    CHECK(n == 1, "the fact replayed in");

    CHECK_OK(ds_engine_clock_advance(dst, BETWEEN_NS), "advance past schema default");
    CHECK_OK(ds_engine_pump(dst), "pump that sweeps");

    CHECK_OK(ds_engine_fact_count(dst, &n), "fact_count after sweep");
    printf("    after advancing to %llu ns: facts=%zu (expected 1)\n",
           (unsigned long long)BETWEEN_NS, n);
    CHECK(n == 1,
          "replayed fact outlives the SCHEMA default — the override survived");

    CHECK_OK(ds_engine_clock_advance(dst, OVERRIDE_TTL_NS), "advance past override");
    CHECK_OK(ds_engine_pump(dst), "pump that sweeps again");
    CHECK_OK(ds_engine_fact_count(dst, &n), "fact_count after second sweep");
    CHECK(n == 0, "replayed fact expires at the OVERRIDE deadline");

    ds_engine_free(dst);
}

int main(void)
{
    record_an_override();
    if (g_stream_len == 0) {
        fprintf(stderr, "test_rfcs_ttl_record: nothing recorded\n");
        return 1;
    }
    printf("test_rfcs_ttl_record: recorded %zu bytes\n", g_stream_len);

    check_wire_carries_the_window();
    check_replay_honours_the_window();

    if (failures) {
        fprintf(stderr, "test_rfcs_ttl_record: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_rfcs_ttl_record: OK\n");
    return 0;
}
