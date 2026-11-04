/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * A replay of a recorded TTL expiry, for the memcheck lane (libds.build's
 * `vg` column), which judges whether the replay touches freed memory. The
 * replay's pump sweeps the fact again, and the recorded FactWithdraw is
 * compared with the one it re-derives ([RFCS.7a.2]). The test's own checks
 * are only its premises; the replay's outcome is printed, not checked.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "rete/engine.h"
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

/* One second, and one nanosecond past it. */
#define TTL_NS   1000000000ull
#define PAST_TTL (TTL_NS + 1ull)

/* No identity role: `key` is legal only on a logical schema
   ([LGRA.5.10]). */
static const ds_slot_desc_t SLOTS[1] = {
    { .name = "level", .type = DS_SLOT_TYPE_INT,
      .identity_role = DS_IDENTITY_UNSPECIFIED },
};

static const ds_schema_t *register_reading(ds_engine_t *e)
{
    const ds_schema_t *sc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Reading", DS_SCHEMA_LIFECYCLE_TTL,
                                       TTL_NS, SLOTS, 1, &sc),
             "register_schema Reading (ttl)");
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

/* Print the atom inventory to the log. */
static void report_atoms(const uint8_t *stream, size_t len)
{
    ds_rfcs_reader_t rd;
    ds_rfcs_reader_init(&rd, stream, len);
    printf("    atoms:");
    for (;;) {
        uint32_t       atom = 0;
        const uint8_t *body = NULL;
        size_t         blen = 0;
        bool           done = false;
        ds_result_t    r = ds_rfcs_next(&rd, &atom, &body, &blen, &done);
        if (r.status != DS_OK) {
            printf(" <parse error: %s>", r.detail ? r.detail : "(null)");
            break;
        }
        if (done)
            break;
        printf(" %s", ds_rfcs_message_name(atom));
    }
    printf("\n");
}

/* Record the scenario: assert into a TTL schema, advance past the deadline,
   let the pump sweep it. Returns the source engine so the caller can read
   fact_count before freeing it. */
static ds_engine_t *record_a_ttl_expiry(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t       *src = NULL;
    CHECK_OK(ds_engine_new(&cfg, &src), "engine_new src");
    if (!src)
        return NULL;
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
    CHECK_OK(ds_engine_assert(src, sc, v, 1, &f), "assert Reading");
    CHECK_OK(ds_engine_pump(src), "pump after assert");

    CHECK_OK(ds_engine_clock_advance(src, PAST_TTL), "clock_advance past ttl");
    CHECK_OK(ds_engine_pump(src), "pump that sweeps");   /* frees the fact */

    CHECK(rec.last.status == DS_OK, "recorder had no error");
    ds_engine_set_stream_callback(src, NULL, NULL);
    return src;
}

int main(void)
{
    ds_engine_config_t cfg = {0};

    /* ── record ─────────────────────────────────────────────────────────── */
    ds_engine_t *src = record_a_ttl_expiry();
    if (!src)
        return 1;

    size_t n_src = (size_t)-1;
    CHECK_OK(ds_engine_fact_count(src, &n_src), "fact_count src");
    printf("test_rfcs_ttl_replay: recorded %zu bytes, facts after sweep=%zu\n",
           g_stream_len, n_src);
    report_atoms(g_stream, g_stream_len);

    /* The premise: the fact expired on the source. */
    CHECK(n_src == 0, "the ttl fact expired on the source engine");
    CHECK(g_stream_len > 0, "something was recorded");

    /* ── replay ─────────────────────────────────────────────────────────── */
    {
        ds_engine_t *dst = NULL;
        CHECK_OK(ds_engine_new(&cfg, &dst), "engine_new dst");
        if (dst) {
            (void)register_reading(dst);
            CHECK_OK(ds_engine_clock_set_mode(dst, DS_CLOCK_MOCK),
                     "clock_set_mode dst");
            CHECK_OK(ds_engine_clock_set(dst, 0), "clock_set 0 dst");

            static uint8_t          strbuf[8192];
            ds_rfcs_replay_result_t rr;
            memset(&rr, 0, sizeof(rr));
            /* Printed, not checked: the lane is the verdict. */
            ds_result_t r = ds_rfcs_replay(dst, g_stream, g_stream_len,
                                           strbuf, sizeof(strbuf), &rr);
            size_t n_dst = (size_t)-1;
            (void)ds_engine_fact_count(dst, &n_dst);
            printf("    VERIFY : status=%d detail=%s "
                   "asserts=%llu retracts=%llu clocks=%llu skipped=%llu facts=%zu\n",
                   r.status, r.detail ? r.detail : "(null)",
                   (unsigned long long)rr.asserts,
                   (unsigned long long)rr.retracts,
                   (unsigned long long)rr.clocks,
                   (unsigned long long)rr.skipped, n_dst);
            ds_engine_free(dst);
        }
    }

    ds_engine_free(src);

    if (failures) {
        fprintf(stderr, "test_rfcs_ttl_replay: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_rfcs_ttl_replay: OK (the LANE is the verdict, not this line)\n");
    return 0;
}
