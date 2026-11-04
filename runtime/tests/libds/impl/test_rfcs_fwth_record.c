/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The engine's withdrawals are recorded as FactWithdraw, with the cause its
 * site set, and the integrator's retractions as FactRetract ([RFCS.7a.2]).
 *
 * The TTL case expires an integrator-asserted fact: the atom follows who
 * withdrew the fact, not who asserted it. The identity upsert is SUPERSEDED.
 * The integrator's ds_engine_retract is the control: a FactRetract and no
 * FactWithdraw. The other origins need a live rule and are not recorded here.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "engine.h"   /* ds_engine_register_schema, libds-internal */
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

#define SCHEMA_TTL_NS 1000000000ull
#define PAST_TTL_NS   2000000000ull

static const ds_slot_desc_t SLOTS[1] = {
    { .name = "level", .type = DS_SLOT_TYPE_INT,
      .identity_role = DS_IDENTITY_UNSPECIFIED },
};

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

/* Walk the recorded stream and report what the retraction became. */
static void scan(bool *out_saw_fwth, uint32_t *out_cause, bool *out_saw_fcrt)
{
    *out_saw_fwth = false;
    *out_saw_fcrt = false;
    *out_cause    = DS_FWTH_CAUSE_UNSPECIFIED;

    ds_rfcs_reader_t rd;
    ds_rfcs_reader_init(&rd, g_stream, g_stream_len);
    for (;;) {
        uint32_t       atom = 0;
        const uint8_t *body = NULL;
        size_t         blen = 0;
        bool           done = false;
        CHECK_OK(ds_rfcs_next(&rd, &atom, &body, &blen, &done), "reader next");
        if (done)
            break;
        if (atom == DS_ATOM_FACT_RETRACT) {
            *out_saw_fcrt = true;
        } else if (atom == DS_ATOM_FACT_WITHDRAW) {
            ds_rfcs_fwth_t fw;
            CHECK_OK(ds_rfcs_decode_fwth(body, blen, &fw), "decode_fwth");
            *out_saw_fwth = true;
            *out_cause    = fw.cause;
        }
    }
}

/* Record: assert a TTL fact as the integrator, then let the sweep take it. */
static void record_ttl_expiry(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t       *e   = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (!e)
        return;
    const ds_schema_t *sc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Reading", DS_SCHEMA_LIFECYCLE_TTL,
                                       SCHEMA_TTL_NS, SLOTS, 1, &sc),
             "register_schema");
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "clock_set_mode");
    CHECK_OK(ds_engine_clock_set(e, 0), "clock_set 0");

    static ds_rfcs_recorder_t rec;
    static uint8_t            recbuf[4096];
    g_stream_len = 0;
    CHECK_OK(ds_rfcs_record_to(e, &rec, test_sink, NULL, recbuf, sizeof(recbuf)),
             "record_to");

    ds_slot_value_t v[1];
    memset(v, 0, sizeof(v));
    v[0].kind = DS_SLOT_INT;
    v[0].v.i  = 7;
    ds_fact_t *f = NULL;
    CHECK_OK(ds_engine_assert(e, sc, v, 1, &f), "assert Reading");
    CHECK_OK(ds_engine_pump(e), "pump after assert");

    CHECK_OK(ds_engine_clock_advance(e, PAST_TTL_NS), "advance past ttl");
    CHECK_OK(ds_engine_pump(e), "pump that sweeps");

    size_t n = 1;
    CHECK_OK(ds_engine_fact_count(e, &n), "fact_count");
    CHECK(n == 0, "the fact expired — premise of the rest of this file");

    CHECK(rec.last.status == DS_OK, "recorder had no error");
    ds_engine_set_stream_callback(e, NULL, NULL);
    ds_engine_free(e);
}


/* Record: assert a keyed fact twice with one key, so [LFAC.2.5.1] replaces
   the first and the engine withdraws it. */
static void record_identity_upsert(void)
{
    static const ds_slot_desc_t KEYED[2] = {
        { .name = "id",    .type = DS_SLOT_TYPE_INT,
          .identity_role = DS_IDENTITY_KEY },
        { .name = "level", .type = DS_SLOT_TYPE_INT,
          .identity_role = DS_IDENTITY_MUTABLE },
    };
    ds_engine_config_t cfg = {0};
    ds_engine_t       *e   = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new upsert");
    if (!e)
        return;
    const ds_schema_t *sc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Keyed", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                       0, KEYED, 2, &sc),
             "register_schema Keyed");
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "clock_set_mode upsert");
    CHECK_OK(ds_engine_clock_set(e, 0), "clock_set 0 upsert");

    static ds_rfcs_recorder_t rec;
    static uint8_t            recbuf[4096];
    g_stream_len = 0;
    CHECK_OK(ds_rfcs_record_to(e, &rec, test_sink, NULL, recbuf, sizeof(recbuf)),
             "record_to upsert");

    ds_slot_value_t v[2];
    memset(v, 0, sizeof(v));
    v[0].kind = DS_SLOT_INT; v[0].v.i = 1;   /* the identity */
    v[1].kind = DS_SLOT_INT; v[1].v.i = 10;
    ds_fact_t *f1 = NULL;
    CHECK_OK(ds_engine_assert(e, sc, v, 2, &f1), "assert Keyed(1,10)");
    CHECK_OK(ds_engine_pump(e), "pump after first assert");

    v[1].v.i = 20;                            /* same key, new value */
    ds_fact_t *f2 = NULL;
    CHECK_OK(ds_engine_assert(e, sc, v, 2, &f2), "re-assert Keyed(1,20)");
    CHECK_OK(ds_engine_pump(e), "pump after upsert");

    size_t n = 0;
    CHECK_OK(ds_engine_fact_count(e, &n), "fact_count upsert");
    CHECK(n == 1, "the upsert replaced rather than added — premise");

    CHECK(rec.last.status == DS_OK, "recorder had no error (upsert)");
    ds_engine_set_stream_callback(e, NULL, NULL);
    ds_engine_free(e);
}
/* Control: the same fact, retracted by the INTEGRATOR before it can expire. */
static void record_integrator_retract(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t       *e   = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new control");
    if (!e)
        return;
    const ds_schema_t *sc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Reading", DS_SCHEMA_LIFECYCLE_TTL,
                                       SCHEMA_TTL_NS, SLOTS, 1, &sc),
             "register_schema control");
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "clock_set_mode control");
    CHECK_OK(ds_engine_clock_set(e, 0), "clock_set 0 control");

    static ds_rfcs_recorder_t rec;
    static uint8_t            recbuf[4096];
    g_stream_len = 0;
    CHECK_OK(ds_rfcs_record_to(e, &rec, test_sink, NULL, recbuf, sizeof(recbuf)),
             "record_to control");

    ds_slot_value_t v[1];
    memset(v, 0, sizeof(v));
    v[0].kind = DS_SLOT_INT;
    v[0].v.i  = 7;
    ds_fact_t *f = NULL;
    CHECK_OK(ds_engine_assert(e, sc, v, 1, &f), "assert control");
    CHECK_OK(ds_engine_pump(e), "pump control");
    CHECK_OK(ds_engine_retract(e, f), "integrator retract");
    CHECK_OK(ds_engine_pump(e), "pump after retract");

    CHECK(rec.last.status == DS_OK, "recorder had no error (control)");
    ds_engine_set_stream_callback(e, NULL, NULL);
    ds_engine_free(e);
}

/* One protobuf varint at `p`; returns its length. */
static size_t put_varint(uint8_t *p, uint64_t v)
{
    size_t n = 0;
    do {
        uint8_t b = (uint8_t)(v & 0x7F);
        v >>= 7;
        p[n++] = (uint8_t)(v ? (b | 0x80) : b);
    } while (v);
    return n;
}

/* A FactWithdraw body, hand-built: fact_id (1), cause (2), clock_ns (3),
   seq (4), each a varint field (proto/fact_withdraw.proto). */
static size_t fwth_body(uint8_t *p, uint64_t fact_id, uint64_t cause,
                        uint64_t clock_ns, uint64_t seq)
{
    size_t n = 0;
    p[n++] = (uint8_t)(1u << 3); n += put_varint(p + n, fact_id);
    p[n++] = (uint8_t)(2u << 3); n += put_varint(p + n, cause);
    p[n++] = (uint8_t)(3u << 3); n += put_varint(p + n, clock_ns);
    p[n++] = (uint8_t)(4u << 3); n += put_varint(p + n, seq);
    return n;
}

/* [RFCS.7a.2]: a reader carries a cause the enum does not hold, and the
   fields beside it:
     4    the reserved number;
     9    unallocated, one byte;
     258  two bytes whose low byte is 2, TTL_EXPIRED.
   The encoder carries 258 too. A negative cause is not pinned: the clause
   does not say whether one is carried. */
/* @spec [RFCS.7a.2] */
static void check_unknown_causes_are_carried(void)
{
    static const uint32_t causes[] = { 4u, 9u, 258u };
    for (size_t i = 0; i < sizeof(causes) / sizeof(causes[0]); i++) {
        uint8_t body[64];
        size_t  blen = fwth_body(body, 42u, causes[i], 1234567890123ull, 77u);
        ds_rfcs_fwth_t fw;
        memset(&fw, 0xAB, sizeof(fw));
        ds_result_t r = ds_rfcs_decode_fwth(body, blen, &fw);
        printf("  decode cause %u: status=%d cause=%u\n",
               (unsigned)causes[i], r.status, (unsigned)fw.cause);
        CHECK_OK(r, "decode_fwth accepts a cause the enum does not hold");
        if (r.status != DS_OK)
            continue;
        CHECK(fw.cause == causes[i],
              "decode_fwth carries the cause's number unchanged ([RFCS.7a.2])");
        CHECK(fw.fact_id == 42u, "decode_fwth keeps fact_id beside the cause");
        CHECK(fw.clock_ns == 1234567890123ull,
              "decode_fwth keeps clock_ns beside the cause");
        CHECK(fw.seq == 77u, "decode_fwth keeps seq beside the cause");
    }

    uint8_t atom[64];
    size_t  alen = 0;
    CHECK_OK(ds_rfcs_encode_fwth(42u, 258u, 1234567890123ull, 77u,
                                 atom, sizeof(atom), &alen),
             "encode_fwth with cause 258");
    ds_rfcs_reader_t rd;
    ds_rfcs_reader_init(&rd, atom, alen);
    uint32_t       num  = 0;
    const uint8_t *body = NULL;
    size_t         blen = 0;
    bool           done = false;
    CHECK_OK(ds_rfcs_next(&rd, &num, &body, &blen, &done),
             "reader next over the encoded FactWithdraw");
    CHECK(!done && num == DS_ATOM_FACT_WITHDRAW,
          "encode_fwth frames one FactWithdraw");
    if (!done && num == DS_ATOM_FACT_WITHDRAW) {
        ds_rfcs_fwth_t fw;
        CHECK_OK(ds_rfcs_decode_fwth(body, blen, &fw),
                 "decode the encoded FactWithdraw");
        printf("  encode/decode cause 258: cause=%u\n", (unsigned)fw.cause);
        CHECK(fw.cause == 258u, "encode_fwth then decode_fwth carries 258");
    }
}

int main(void)
{
    check_unknown_causes_are_carried();

    bool     saw_fwth = false, saw_fcrt = false;
    uint32_t cause    = DS_FWTH_CAUSE_UNSPECIFIED;

    record_ttl_expiry();
    scan(&saw_fwth, &cause, &saw_fcrt);
    printf("  ttl expiry: FactWithdraw=%d cause=%u FactRetract=%d\n",
           (int)saw_fwth, (unsigned)cause, (int)saw_fcrt);
    CHECK(saw_fwth, "an engine TTL expiry records a FactWithdraw (RFCS.7a)");
    CHECK(cause == DS_FWTH_CAUSE_TTL_EXPIRED,
          "the FactWithdraw names TTL_EXPIRED, set at the sweep");
    CHECK(!saw_fcrt,
          "the engine's own withdrawal is NOT a FactRetract — FactRetract is the "
          "integrator's half");

    saw_fwth = saw_fcrt = false;
    cause    = DS_FWTH_CAUSE_UNSPECIFIED;
    record_identity_upsert();
    scan(&saw_fwth, &cause, &saw_fcrt);
    printf("  identity upsert: FactWithdraw=%d cause=%u FactRetract=%d\n",
           (int)saw_fwth, (unsigned)cause, (int)saw_fcrt);
    CHECK(saw_fwth, "an identity upsert records a FactWithdraw for the fact "
                    "it replaced");
    CHECK(cause == DS_FWTH_CAUSE_SUPERSEDED,
          "the FactWithdraw names SUPERSEDED, set at the upsert site");
    CHECK(!saw_fcrt, "the upsert's withdrawal is not a FactRetract");

    saw_fwth = saw_fcrt = false;
    cause    = DS_FWTH_CAUSE_UNSPECIFIED;
    record_integrator_retract();
    scan(&saw_fwth, &cause, &saw_fcrt);
    printf("  integrator retract: FactWithdraw=%d FactRetract=%d\n",
           (int)saw_fwth, (int)saw_fcrt);
    CHECK(saw_fcrt, "an integrator retract still records a FactRetract");
    CHECK(!saw_fwth,
          "an integrator retract is NOT a FactWithdraw — the control that "
          "stops FactWithdraw being emitted unconditionally");

    if (failures) {
        fprintf(stderr, "test_rfcs_fwth_record: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_rfcs_fwth_record: OK\n");
    return 0;
}
