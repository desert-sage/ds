/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [RFCS.5.1]
 * Recording beside the caller's own stream callback, through
 * ds_rfcs_record_begin and ds_rfcs_recorder_on_event.
 *
 * It includes only libds.h and rfcs/rfcs.h: a binding built against the
 * tarball's headers cannot see engine.h, and must still be able to chain the
 * recorder with a callback of its own.
 *
 * Two engines, one a clone of the other, so they share the session id, the
 * mock clock and the sequence counter, and identical input gives
 * byte-identical output ([LDET.2.2b]). One records through ds_rfcs_record_to,
 * the other through the chained path; the two recordings must be equal byte
 * for byte, and the chaining callback must see every event.
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

typedef struct {
    uint8_t bytes[8192];
    size_t  len;
} capture_t;

static ds_result_t capture_sink(const uint8_t *bytes, size_t len, void *user)
{
    capture_t *c = (capture_t *)user;
    if (c->len + len > sizeof(c->bytes))
        return (ds_result_t){ DS_ERR_INVAL, "capture overflow" };
    memcpy(c->bytes + c->len, bytes, len);
    c->len += len;
    return (ds_result_t){ DS_OK, NULL };
}

/* The caller's own callback: the recorder first, then the caller's work --
   here, counting the fact events a handle-fencing binding would act on. */
typedef struct {
    ds_rfcs_recorder_t *rec;
    int events;
    int asserts;
    int retracts;
} chain_t;

static ds_result_t chain_cb(ds_engine_t *engine, const ds_stream_ev_t *ev,
                            void *user)
{
    chain_t *c = (chain_t *)user;
    (void)ds_rfcs_recorder_on_event(engine, ev, c->rec);
    c->events++;
    if (ev->kind == DS_EV_FACT_ASSERT)  c->asserts++;
    if (ev->kind == DS_EV_FACT_RETRACT) c->retracts++;
    return (ds_result_t){ DS_OK, NULL };
}

static const ds_slot_desc_t SLOTS[2] = {
    { .name = "n",     .type = DS_SLOT_TYPE_INT,    .identity_role = DS_IDENTITY_KEY },
    { .name = "label", .type = DS_SLOT_TYPE_STRING, .identity_role = DS_IDENTITY_KEY },
};

/* The same input on either engine: two asserts, a retract, a pump. */
static void drive(ds_engine_t *e, const ds_schema_t *sc)
{
    ds_slot_value_t v[2];
    memset(v, 0, sizeof(v));
    v[0].kind = DS_SLOT_INT;
    v[0].v.i = 1;
    v[1].kind = DS_SLOT_STRING;
    v[1].v.s = "a";
    ds_fact_t *f1 = NULL;
    CHECK_OK(ds_engine_assert(e, sc, v, 2, &f1), "assert 1");
    v[0].v.i = 2;
    v[1].v.s = "b";
    ds_fact_t *f2 = NULL;
    CHECK_OK(ds_engine_assert(e, sc, v, 2, &f2), "assert 2");
    CHECK_OK(ds_engine_retract(e, f1), "retract 1");
    CHECK_OK(ds_engine_pump(e), "pump");
}

int main(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *src = NULL;
    CHECK_OK(ds_engine_new(&cfg, &src), "engine_new");
    if (!src)
        return 1;
    CHECK_OK(ds_engine_clock_set_mode(src, DS_CLOCK_MOCK), "mock clock");
    CHECK_OK(ds_engine_clock_set(src, 1000), "clock_set");

    const ds_schema_t *sc = NULL;
    CHECK_OK(ds_engine_register_schema(src, "Pkt", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                       0, SLOTS, 2, &sc),
             "register_schema");

    ds_engine_t *twin = NULL;
    CHECK_OK(ds_engine_clone(src, &twin), "clone");
    if (!twin)
        return 1;
    const ds_schema_t *twin_sc = NULL;
    CHECK_OK(ds_engine_schema_find(twin, "Pkt", &twin_sc), "twin schema");

    /* The reference: ds_rfcs_record_to on the twin. */
    static capture_t want;
    static ds_rfcs_recorder_t want_rec;
    static uint8_t want_buf[4096];
    CHECK_OK(ds_rfcs_record_to(twin, &want_rec, capture_sink, &want,
                               want_buf, sizeof(want_buf)),
             "record_to");

    /* The chained path on the source: record_begin installs no callback, so
       arm, check nothing was written, then install the chain. The header and
       the announcements wait for the first event on both paths
       ([RFCS.5.1]). */
    static capture_t got;
    static ds_rfcs_recorder_t got_rec;
    static uint8_t got_buf[4096];
    CHECK_OK(ds_rfcs_record_begin(src, &got_rec, capture_sink, &got,
                                  got_buf, sizeof(got_buf)),
             "record_begin");
    CHECK(got.len == 0,
          "record_begin before any event writes nothing yet (RFCS.5.1)");
    CHECK(got.len == want.len,
          "record_begin writes exactly what record_to writes before any event");
    size_t prefix = got.len;

    chain_t chain = { .rec = &got_rec };
    CHECK_OK(ds_engine_set_stream_callback(src, chain_cb, &chain),
             "install the caller's callback");

    drive(twin, twin_sc);
    drive(src, sc);

    ds_engine_set_stream_callback(twin, NULL, NULL);
    ds_engine_set_stream_callback(src, NULL, NULL);

    CHECK(want_rec.last.status == DS_OK, "record_to recorder had no error");
    CHECK(got_rec.last.status == DS_OK, "chained recorder had no error");
    CHECK(got.len > prefix,
          "the chained recorder framed the events, not only the prefix");
    CHECK(got.len == want.len, "chained recording has record_to's length");
    CHECK(got.len == want.len && memcmp(got.bytes, want.bytes, got.len) == 0,
          "chained recording is byte-identical to record_to's");

    CHECK(chain.asserts == 2, "the caller's callback saw both asserts");
    CHECK(chain.retracts == 1, "the caller's callback saw the retract");
    CHECK(chain.events >= 3, "the caller's callback saw every event");

    ds_engine_free(twin);
    ds_engine_free(src);

    if (failures) {
        fprintf(stderr, "test_rfcs_record_chain: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_rfcs_record_chain: OK (%zu bytes, %d events)\n", got.len,
           chain.events);
    return 0;
}
