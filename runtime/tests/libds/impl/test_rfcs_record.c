/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [RFCS.12.3] [RFCS.5.1]
 * The recorder (ds_rfcs_record_to) and the FactAssert/FactRetract codec.
 *
 * Installs a recording sink, asserts then retracts a fact, and reads the
 * captured stream back atom by atom.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "rete/engine.h"
#include "rete/schema_reg.h"
#include "rete/val.h"
#include "rfcs/rfcs.h"
#include "rfcs_test_atom.h"
#include "test_ds_version.h"     /* [LDET.1.10] ds_test_accepted_version */
#include "schema_def.pb-c.h"
#include "slot.pb-c.h"

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

/* sink: append the framed atoms into a fixed buffer. */
static uint8_t g_stream[8192];
static size_t g_stream_len = 0;

static ds_result_t test_sink(const uint8_t *bytes, size_t len, void *user)
{
    (void)user;
    if (g_stream_len + len > sizeof(g_stream))
        return (ds_result_t){ DS_ERR_INVAL, "sink overflow" };
    memcpy(g_stream + g_stream_len, bytes, len);
    g_stream_len += len;
    return (ds_result_t){ DS_OK, NULL };
}

static const ds_slot_desc_t SLOTS[2] = {
    { .name = "count", .type = DS_SLOT_TYPE_INT,    .identity_role = DS_IDENTITY_KEY },
    { .name = "label", .type = DS_SLOT_TYPE_STRING, .identity_role = DS_IDENTITY_KEY },
};

int main(void)
{
    /* --- direct FactAssert/FactRetract codec round-trip --- */
    {
        uint8_t fbody[4] = { 0x08, 0x07 }; /* a stand-in inner body (Int field=7) */
        uint8_t atom[128] = {0};   /* the decoder reads past the encoded prefix */
        size_t n = 0;
        CHECK_OK(ds_rfcs_encode_fcem(99, "Thing", fbody, 2, 0, 1234, 5, "", atom, sizeof(atom), &n),
                 "encode_fcem");
        size_t         bl = 0;
        const uint8_t *bd = NULL;
        CHECK(ds_rfcs_test_is(atom, n, DS_ATOM_FACT_ASSERT), "fact_assert atom identity");
        bd = ds_rfcs_test_body(atom, n, &bl);
        ds_rfcs_fcem_t fc;
        CHECK_OK(ds_rfcs_decode_fcem(bd, bl, &fc), "decode_fcem");
        CHECK(fc.fact_id == 99 && ds_rfcs_str_eq(fc.schema_name, "Thing") &&
                  fc.fact_len == 2 && fc.clock_ns == 1234 && fc.seq == 5 &&
                  memcmp(fc.fact, fbody, 2) == 0,
              "fact_assert round-trip");

        CHECK_OK(ds_rfcs_encode_fcrt(99, 6, 1234, atom, sizeof(atom), &n), "encode_fcrt");
        CHECK(ds_rfcs_test_is(atom, n, DS_ATOM_FACT_RETRACT), "fact_retract atom identity");
        bd = ds_rfcs_test_body(atom, n, &bl);
        ds_rfcs_fcrt_t fr;
        CHECK_OK(ds_rfcs_decode_fcrt(bd, bl, &fr), "decode_fcrt");
        CHECK(fr.fact_id == 99 && fr.seq == 6 && fr.clock_ns == 1234,
              "fact_retract round-trip (RFCS.7.5: seq and clock_ns too)");
    }

    /* --- recorder end-to-end --- */
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (!e)
        return 1;

    const ds_schema_t *sc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Pkt", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       SLOTS, 2, &sc),
             "register_schema");

    /* The mock clock fixes the clock's records: the assert's sample is the
       first and is recorded ([LTIM.2.8.5]); the retract's is unchanged and is
       not. */
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "mock clock");
    CHECK_OK(ds_engine_clock_set(e, 1000), "clock 1000");

    /* The header and prelude wait for the first event ([RFCS.5.1]). */
    ds_rfcs_recorder_t rec;
    uint8_t recbuf[4096];
    g_stream_len = 0;
    CHECK_OK(ds_rfcs_record_to(e, &rec, test_sink, NULL, recbuf, sizeof(recbuf)),
             "record_to");

    /* assert (-> FactAssert) then retract (-> FactRetract). */
    ds_slot_value_t v[2];
    memset(v, 0, sizeof(v));
    v[0].kind = DS_SLOT_INT;
    v[0].v.i = 42;
    v[1].kind = DS_SLOT_STRING;
    v[1].v.s = "hi";
    ds_fact_t *fact = NULL;
    CHECK_OK(ds_engine_assert(e, sc, v, 2, &fact), "assert");
    CHECK_OK(ds_engine_retract(e, fact), "retract");
    /* [RFCS.15]: an outbound call records a CallIssued carrying the
       (timetag, rule_name) fire identity. */
    ds_arg_t call_args[1];
    memset(call_args, 0, sizeof(call_args));
    call_args[0].name = "n";
    call_args[0].value.kind = DS_ARG_INT;
    call_args[0].value.v.i = 1;
    CHECK_OK(ds_recorder_emit_action_call(e, "svc.notify", "corr-1",
                                          call_args, 1, 777, "warm_alert"),
             "emit action_call");
    CHECK(rec.last.status == DS_OK, "recorder had no error");

    ds_engine_set_stream_callback(e, NULL, NULL); /* stop */

    /* The captured stream: StreamHeader, the announcement, ClockAdvance,
       FactAssert, FactRetract, CallIssued. */
    ds_rfcs_reader_t rd;
    ds_rfcs_reader_init(&rd, g_stream, g_stream_len);
    uint32_t atom;
    const uint8_t *body;
    size_t blen;
    bool done = false;
    int idx = 0;

    CHECK_OK(ds_rfcs_next(&rd, &atom, &body, &blen, &done), "next StreamHeader");
    CHECK(!done && atom == DS_ATOM_STREAM_HEADER, "first atom is StreamHeader");
    ds_rfcs_header_t hdr;
    CHECK_OK(ds_rfcs_decode_header(body, blen, &hdr), "decode StreamHeader");
    /* [LDET.1.10]: the recorder stamps this build's DS version. */
    CHECK(strcmp(hdr.ds_version, ds_test_accepted_version()) == 0, "StreamHeader ds_version");
    CHECK(hdr.ds_version[0] != '\0', "StreamHeader ds_version is stamped");
    idx++;

    /* [RFCS.5.1]: the schema announcement, between the StreamHeader and the
     * first FactAssert. `Pkt` was registered without a DSC, so its SchemaDef
     * carries an empty proto_source and the Slot atoms carry its structure. */
    CHECK_OK(ds_rfcs_next(&rd, &atom, &body, &blen, &done), "next SchemaDef");
    CHECK(!done && atom == DS_ATOM_SCHEMA_DEF, "second atom is SchemaDef");
    {
        Ds__V1__SchemaDef *sd =
            ds__v1__schema_def__unpack(NULL, blen, body);
        CHECK(sd != NULL, "SchemaDef body decodes");
        if (sd) {
            CHECK(sd->schema_name && strcmp(sd->schema_name, "Pkt") == 0,
                  "SchemaDef names Pkt");
            CHECK(sd->proto_source.len == 0,
                  "SchemaDef proto_source is empty for a schema with no artefact");
            ds__v1__schema_def__free_unpacked(sd, NULL);
        }
    }
    idx++;

    static const char *const WANT_SLOT[2] = { "count", "label" };
    static const Ds__V1__SlotKind WANT_KIND[2] = {
        DS__V1__SLOT_KIND__SLOT_KIND_INT,
        DS__V1__SLOT_KIND__SLOT_KIND_STRING,
    };
    for (int s = 0; s < 2; s++) {
        CHECK_OK(ds_rfcs_next(&rd, &atom, &body, &blen, &done), "next Slot");
        CHECK(!done && atom == DS_ATOM_SLOT, "announcement atom is Slot");
        Ds__V1__Slot *sl = ds__v1__slot__unpack(NULL, blen, body);
        CHECK(sl != NULL, "Slot body decodes");
        if (sl) {
            CHECK(sl->schema_name && strcmp(sl->schema_name, "Pkt") == 0,
                  "Slot names its schema");
            CHECK(sl->slot_name && strcmp(sl->slot_name, WANT_SLOT[s]) == 0,
                  "Slot slot_name in declaration order");
            CHECK(sl->kind == WANT_KIND[s], "Slot kind survives the wire");
            ds__v1__slot__free_unpacked(sl, NULL);
        }
        idx++;
    }

    /* [LTIM.2.8.5]: the assert's sample, the engine's first, is recorded
     * before the assert's own record: the monotonic 1000, and no wall value,
     * since the mock clock's wall clock is unset ([RFCS.10.1]). */
    CHECK_OK(ds_rfcs_next(&rd, &atom, &body, &blen, &done), "next ClockAdvance");
    CHECK(!done && atom == DS_ATOM_CLOCK_ADVANCE, "ClockAdvance follows the announcement");
    {
        ds_rfcs_clka_t ck;
        CHECK_OK(ds_rfcs_decode_clka(body, blen, &ck), "decode ClockAdvance");
        CHECK(ck.clock_ns == 1000, "ClockAdvance carries the monotonic sample");
        CHECK(!ck.has_wall && ck.wall_ns == 0, "and no wall value");
    }
    idx++;

    CHECK_OK(ds_rfcs_next(&rd, &atom, &body, &blen, &done), "next FactAssert");
    CHECK(!done && atom == DS_ATOM_FACT_ASSERT, "FactAssert follows its sample's ClockAdvance");
    ds_rfcs_fcem_t fact_assert;
    CHECK_OK(ds_rfcs_decode_fcem(body, blen, &fact_assert), "decode FactAssert");
    CHECK(ds_rfcs_str_eq(fact_assert.schema_name, "Pkt"), "FactAssert schema_name");
    ds_slot_value_t dv[2];
    char scratch[64];
    uint32_t dn = 0;
    CHECK_OK(ds_rfcs_decode_fact_body(sc, fact_assert.fact, fact_assert.fact_len, dv, 2,
                                      scratch, sizeof(scratch), &dn),
             "decode FactAssert fact body");
    CHECK(dn == 2 && dv[0].v.i == 42 && strcmp(dv[1].v.s, "hi") == 0,
          "FactAssert fact values");
    idx++;

    CHECK_OK(ds_rfcs_next(&rd, &atom, &body, &blen, &done), "next FactRetract");
    CHECK(!done && atom == DS_ATOM_FACT_RETRACT,
          "FactRetract follows the FactAssert -- the retract's unchanged sample is not recorded");
    ds_rfcs_fcrt_t fact_retract;
    CHECK_OK(ds_rfcs_decode_fcrt(body, blen, &fact_retract), "decode FactRetract");
    CHECK(fact_retract.fact_id == fact_assert.fact_id,
          "FactRetract fact_id matches the asserted fact");
    /* RFCS.7.5 -- the recorder writes the retract event's own seq and the
       clock at the retraction: the next seq after the assert's, and the mock
       clock's 1000, which the retract did not move. */
    CHECK(fact_retract.seq == fact_assert.seq + 1,
          "FactRetract seq is the retract event's, one after the assert's");
    CHECK(fact_retract.clock_ns == 1000,
          "FactRetract clock_ns is the engine clock at the retraction");
    idx++;

    CHECK_OK(ds_rfcs_next(&rd, &atom, &body, &blen, &done), "next CallIssued");
    CHECK(!done && atom == DS_ATOM_CALL_ISSUED, "CallIssued follows the FactRetract");
    CHECK(blen > 0, "CallIssued body is non-empty");
    idx++;

    CHECK_OK(ds_rfcs_next(&rd, &atom, &body, &blen, &done), "next end");
    CHECK(done, "stream ends after CallIssued");
    CHECK(idx == 8,
          "exactly eight atoms: StreamHeader, SchemaDef, 2x Slot, ClockAdvance, FactAssert, FactRetract, CallIssued");

    ds_engine_free(e);

    if (failures) {
        fprintf(stderr, "test_rfcs_record: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_rfcs_record: OK\n");
    return 0;
}
