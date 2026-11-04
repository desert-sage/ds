/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * A recorder that cannot record an event says so, and keeps recording. Its
 * failure changes nothing the engine does: it is the status of the public
 * call that fired the event ([NCBK.1.5]), and the stream continues past the
 * lost event, so the loss is a `seq` gap ([RFCS.21.1]).
 *
 * It includes only libds.h and rfcs/rfcs.h: this is the integrator's
 * contract, asserted through the integrator's headers.
 */
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "rfcs/rfcs.h"

/* The one libds-internal entry point this test needs, declared here rather
   than by including engine.h: it builds the schema without compiling one. */
ds_result_t ds_engine_register_schema(ds_engine_t           *engine,
                                      const char            *type_name,
                                      ds_schema_lifecycle_t  lifecycle,
                                      uint64_t               ttl_ns,
                                      const ds_slot_desc_t  *slots,
                                      uint32_t               n_slots,
                                      const ds_schema_t    **out_schema);

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

/* A capture sink that can be told to refuse its next write. */
typedef struct {
    uint8_t bytes[65536];
    size_t  len;
    int     fail_next;
} capture_t;

static ds_result_t capture_sink(const uint8_t *bytes, size_t len, void *user)
{
    capture_t *c = (capture_t *)user;
    if (c->fail_next) {
        c->fail_next = 0;
        return (ds_result_t){ DS_ERR_IO, "sink refused this write" };
    }
    if (c->len + len > sizeof(c->bytes))
        return (ds_result_t){ DS_ERR_INVAL, "capture overflow" };
    memcpy(c->bytes + c->len, bytes, len);
    c->len += len;
    return (ds_result_t){ DS_OK, NULL };
}

/* Is `needle` anywhere in the captured stream? A String slot travels as its
   bytes, so a distinctive payload is findable without decoding. */
static int captured(const capture_t *c, const char *needle)
{
    size_t n = strlen(needle);
    if (n == 0 || c->len < n)
        return 0;
    for (size_t i = 0; i + n <= c->len; i++)
        if (memcmp(c->bytes + i, needle, n) == 0)
            return 1;
    return 0;
}

/* `label` is MUTABLE, not KEY, so the 4000-byte payload of case 1 exercises the
   fact body and not the identity key's own encoding. */
static const ds_slot_desc_t SLOTS[2] = {
    { .name = "n",     .type = DS_SLOT_TYPE_INT,    .identity_role = DS_IDENTITY_KEY },
    { .name = "label", .type = DS_SLOT_TYPE_STRING, .identity_role = DS_IDENTITY_MUTABLE },
};

static ds_result_t assert_label(ds_engine_t *e, const ds_schema_t *sc,
                                int64_t n, const char *label)
{
    ds_slot_value_t v[2];
    memset(v, 0, sizeof(v));
    v[0].kind = DS_SLOT_INT;
    v[0].v.i = n;
    v[1].kind = DS_SLOT_STRING;
    v[1].v.s = label;
    ds_fact_t *f = NULL;
    return ds_engine_assert(e, sc, v, 2, &f);
}

static ds_engine_t *new_engine(const ds_schema_t **sc)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (!e)
        return NULL;
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "mock clock");
    CHECK_OK(ds_engine_clock_set(e, 1000), "clock_set");
    CHECK_OK(ds_engine_register_schema(e, "Pkt", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                       0, SLOTS, 2, sc),
             "register_schema");
    return e;
}

/* 1. A 4000-byte fact body is recorded, given a record buffer that holds
      the atom. */
static void test_large_fact_body_is_recorded(void)
{
    const ds_schema_t *sc = NULL;
    ds_engine_t *e = new_engine(&sc);
    if (!e)
        return;

    static capture_t cap;
    static ds_rfcs_recorder_t rec;
    static uint8_t buf[16384];
    CHECK_OK(ds_rfcs_record_to(e, &rec, capture_sink, &cap, buf, sizeof(buf)),
             "record_to (large body)");

    static char big[4001];
    memset(big, 'q', 4000);
    memcpy(big, "BIGBODY-", 8);
    big[4000] = '\0';
    CHECK_OK(assert_label(e, sc, 1, big), "assert a 4000-byte String slot");

    ds_engine_set_stream_callback(e, NULL, NULL);
    CHECK_OK(rec.last, "recorder had no error (large body)");
    CHECK(captured(&cap, big), "the 4000-byte slot reached the sink intact");
    ds_engine_free(e);
}

/* 2. One refused write: the assert that fired it returns the sink's status,
      and recording continues -- the next assert returns OK and its fact is in
      the stream. */
static void test_sink_failure_is_reported_and_recording_continues(void)
{
    const ds_schema_t *sc = NULL;
    ds_engine_t *e = new_engine(&sc);
    if (!e)
        return;

    static capture_t cap;
    static ds_rfcs_recorder_t rec;
    static uint8_t buf[4096];
    CHECK_OK(ds_rfcs_record_to(e, &rec, capture_sink, &cap, buf, sizeof(buf)),
             "record_to (sink failure)");

    /* The engine's first sample is recorded as a ClockAdvance ([LTIM.2.8.5]),
       so a pump takes it first; the clock does not move, and the assert's
       next write is its fact. */
    CHECK_OK(ds_engine_pump(e), "pump: the first sample, recorded");

    cap.fail_next = 1;
    ds_result_t r1 = assert_label(e, sc, 1, "FIRST-lost");
    CHECK(r1.status == DS_ERR_IO,
          "the assert whose event the sink refused returns the sink's status");

    ds_result_t r2 = assert_label(e, sc, 2, "SECOND-kept");
    CHECK_OK(r2, "the next assert returns OK: no status carries over");

    ds_engine_set_stream_callback(e, NULL, NULL);
    CHECK(rec.last.status == DS_ERR_IO, "rec.last holds the first failure");
    CHECK(!captured(&cap, "FIRST-lost"), "the refused event is not in the stream");
    CHECK(captured(&cap, "SECOND-kept"),
          "the recorder kept recording after the failure");
    ds_engine_free(e);
}

/* 3. The chained path: after a failure, the next on_event call frames its
      event and returns OK. */
static void test_on_event_after_a_failure_still_records(void)
{
    const ds_schema_t *sc = NULL;
    ds_engine_t *e = new_engine(&sc);
    if (!e)
        return;

    static capture_t cap;
    static ds_rfcs_recorder_t rec;
    static uint8_t buf[4096];
    CHECK_OK(ds_rfcs_record_begin(e, &rec, capture_sink, &cap, buf, sizeof(buf)),
             "record_begin (chained)");
    rec.last = (ds_result_t){ DS_ERR_IO, "an earlier failure" };

    size_t before = cap.len;
    ds_stream_ev_t ev;
    memset(&ev, 0, sizeof(ev));
    ev.kind = DS_EV_TICK;
    ev.seq = 7;
    ev.clock_ns = 2000;
    ds_result_t r = ds_rfcs_recorder_on_event(e, &ev, &rec);
    CHECK_OK(r, "on_event returns OK for an event it recorded");
    CHECK(cap.len > before, "on_event frames the event after an earlier failure");
    CHECK(rec.last.status == DS_ERR_IO, "the first failure is still the one kept");
    ds_engine_free(e);
}

int main(void)
{
    test_large_fact_body_is_recorded();
    test_sink_failure_is_reported_and_recording_continues();
    test_on_event_after_a_failure_still_records();

    if (failures) {
        fprintf(stderr, "test_rfcs_record_failure: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_rfcs_record_failure: OK\n");
    return 0;
}
