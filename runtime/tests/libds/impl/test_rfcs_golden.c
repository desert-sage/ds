/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * Golden vectors, derived by hand from the wire format rather than taken
 * from the encoder:
 *
 *   1. the FactAssert atom's envelope;
 *   2. a hand-built stream, decoded and replayed into a cold engine;
 *   3. the header's dsc_hash bind check ([RBND.1.3]): a stream recorded
 *      under another DSC is DS_ERR_BND_DSC_MISMATCH, a matching one replays.
 *
 * Each golden array's comment derives it from the field numbers in
 * proto/{stream_header,fact_assert,fact_retract}.proto.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "engine.h"          /* ds_engine_t.rete_engine, .dsc_hash[] */
#include "rete/engine.h"
#include "rete/schema_reg.h"
#include "rete/val.h"
#include "rfcs/rfcs.h"
#include "test_ds_version.h"     /* [LDET.1.10] ds_test_accepted_version */

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

static const ds_slot_desc_t SLOTS[2] = {
    { .name = "count", .type = DS_SLOT_TYPE_INT, .identity_role = DS_IDENTITY_KEY },
    { .name = "label", .type = DS_SLOT_TYPE_STRING, .identity_role = DS_IDENTITY_KEY },
};

static const ds_schema_t *register_pkt(ds_engine_t *e)
{
    const ds_schema_t *sc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Pkt", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       SLOTS, 2, &sc),
             "register_schema");
    return sc;
}

/* ------------------------------------------------------------------ */
/* Golden vectors (proto3 wire).                                       */
/* ------------------------------------------------------------------ */

/* Pkt{count=42, label="hi"} fact body:
   f1 Int 42         -> 08 2A
   f2 String "hi"    -> 12 02 'h' 'i'                                   */
static const uint8_t BODY_GOLDEN[] = { 0x08, 0x2A, 0x12, 0x02, 'h', 'i' };

/* FactAssert{fact_id=1, schema_name="Pkt", fact=BODY_GOLDEN, clock=0, seq=0}:
   f1 fact_id 1      -> 08 01
   f2 schema "Pkt"   -> 12 03 'P' 'k' 't'
   f3 fact (6 bytes) -> 1A 06 08 2A 12 02 'h' 'i'
   (clock_ns/seq are proto3 zero -> omitted)

   Framed by [RFCS.19.1]'s two levels. FactAssert is field 1, so its inner
   key is (1 << 3) | 2 = 0x0A; the inner frame is key(1) + len(1) +
   body(15) = 17 = 0x11, which the outer length measures. */
static const uint8_t FCEM_GOLDEN[] = {
    0x0A, 0x11,                         /* outer: field 1, len 17 */
    0x0A, 0x0F,                         /* inner: FactAssert (field 1), len 15 */
    0x08, 0x01,                         /* fact_id = 1 */
    0x12, 0x03, 'P', 'k', 't',          /* schema_name = "Pkt" */
    0x1A, 0x06, 0x08, 0x2A, 0x12, 0x02, 'h', 'i' /* fact body */
};

static void test_fcem_golden(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (!e)
        return;
    const ds_schema_t *sc = register_pkt(e);

    ds_slot_value_t v[2];
    memset(v, 0, sizeof(v));
    v[0].kind = DS_SLOT_INT;
    v[0].v.i = 42;
    v[1].kind = DS_SLOT_STRING;
    v[1].v.s = "hi";
    ds_fact_t *fact = NULL;
    CHECK_OK(ds_engine_assert(e, sc, v, 2, &fact), "assert");

    uint8_t body[32];
    size_t blen = 0;
    CHECK_OK(ds_rfcs_encode_fact_body(fact, body, sizeof(body), &blen),
             "encode_fact_body");
    CHECK(blen == sizeof(BODY_GOLDEN) &&
              memcmp(body, BODY_GOLDEN, sizeof(BODY_GOLDEN)) == 0,
          "fact body matches the golden");

    uint8_t atom[64] = {0};   /* read whole by the golden memcmp */
    size_t alen = 0;
    CHECK_OK(ds_rfcs_encode_fcem(1, "Pkt", body, blen, 0, 0, 0, "", atom, sizeof(atom), &alen),
             "encode_fcem");
    CHECK(alen == sizeof(FCEM_GOLDEN) &&
              memcmp(atom, FCEM_GOLDEN, sizeof(FCEM_GOLDEN)) == 0,
          "FactAssert atom matches the golden");

    ds_engine_free(e);
}

/* ------------------------------------------------------------------ */
/* Decode a hand-built stream and replay it.                            */
/* ------------------------------------------------------------------ */

/* StreamHeader{ds_version=<this build>}: f10 string -> 52 <len> <bytes>.
   StreamHeader is field 258, so its inner key (258 << 3) | 2 = 2066 takes two varint
   bytes — 92 10. Inner frame: key(2) + len(1) + body(2 + vlen).

   Built at run time: the stream carries this build's version
   ([LDET.1.10]). */
static size_t build_golden_fcst(uint8_t *out, size_t cap)
{
    const char  *ver  = ds_test_accepted_version();
    const size_t vlen = strlen(ver);
    size_t i = 0;
    /* The lengths are one-byte varints. */
    if (vlen > 120u || cap < 5u + vlen + 2u) return 0;
    out[i++] = 0x0A;                       /* outer tag                     */
    out[i++] = (uint8_t)(5u + vlen);       /* outer len = 2 + 1 + (2 + vlen) */
    out[i++] = 0x92; out[i++] = 0x10;      /* inner key, field 258          */
    out[i++] = (uint8_t)(2u + vlen);       /* inner len                     */
    out[i++] = 0x52;                       /* field 10, wire type 2         */
    out[i++] = (uint8_t) vlen;
    memcpy(out + i, ver, vlen); i += vlen;
    return i;
}
/* FactAssert id=2 Pkt{count=7,label="bye"}:
   body inner: 08 07 (count 7) 12 03 'b' 'y' 'e' (label)
   FactAssert: 08 02 (id) 12 03 'P' 'k' 't' 1A 07 <7-byte body>  -> 16 bytes
   Inner frame: key(1) + len(1) + body(16) = 18 = 0x12.                      */
static const uint8_t GOLDEN_FCEM2[] = {
    0x0A, 0x12, 0x0A, 0x10,
    0x08, 0x02,
    0x12, 0x03, 'P', 'k', 't',
    0x1A, 0x07, 0x08, 0x07, 0x12, 0x03, 'b', 'y', 'e'
};
/* FactRetract{fact_id=2}: f1 fact_id 2 -> 08 02. FactRetract is field 2, inner key
   (2 << 3) | 2 = 0x12. Inner frame: key(1) + len(1) + body(2) = 4. */
static const uint8_t GOLDEN_FCRT2[] = {
    0x0A, 0x04, 0x12, 0x02, 0x08, 0x02
};

typedef struct {
    int     n;
    int64_t count[8];
    char    label[8][32];
} wm_snapshot;

static ds_result_t collect_fact(const ds_fact_t *fact, void *user)
{
    wm_snapshot *s = (wm_snapshot *)user;
    if (s->n >= 8)
        return (ds_result_t){ DS_OK, NULL };
    ds_slot_value_t c, l;
    ds_fact_get_slot(fact, 0, NULL, &c);
    ds_fact_get_slot(fact, 1, NULL, &l);
    s->count[s->n] = c.v.i;
    snprintf(s->label[s->n], sizeof(s->label[s->n]), "%s", l.v.s ? l.v.s : "");
    s->n++;
    return (ds_result_t){ DS_OK, NULL };
}

static void test_decode_golden_stream(void)
{
    /* Stream: header, Pkt's SchemaDef, assert id=1 (survives), assert id=2,
       retract id=2. A replay refuses a FactAssert no SchemaDef announced
       ([RFCS.5.4]); the facts are typed from the engine's Pkt, so no Slot
       atoms are needed. */
    uint8_t stream[256];
    size_t off = 0;
    size_t fcst_len = build_golden_fcst(stream + off, sizeof(stream) - off);
    CHECK(fcst_len > 0, "build golden StreamHeader");
    off += fcst_len;
    size_t sdef_len = 0;
    CHECK_OK(ds_rfcs_encode_schema_def("Pkt", stream + off, sizeof(stream) - off,
                                       &sdef_len), "encode Pkt's SchemaDef");
    off += sdef_len;
    memcpy(stream + off, FCEM_GOLDEN, sizeof(FCEM_GOLDEN));   off += sizeof(FCEM_GOLDEN);
    memcpy(stream + off, GOLDEN_FCEM2, sizeof(GOLDEN_FCEM2)); off += sizeof(GOLDEN_FCEM2);
    memcpy(stream + off, GOLDEN_FCRT2, sizeof(GOLDEN_FCRT2)); off += sizeof(GOLDEN_FCRT2);

    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (!e)
        return;
    const ds_schema_t *sc = register_pkt(e);

    static uint8_t strbuf[4096];
    ds_rfcs_replay_result_t rr;
    CHECK_OK(ds_rfcs_replay(e, stream, off, strbuf, sizeof(strbuf), &rr),
             "replay golden stream");
    CHECK(rr.asserts == 2 && rr.retracts == 1, "golden stream applied (2 asserts, 1 retract)");
    CHECK(!rr.header_verified, "no dsc_hash carried -> not positively verified");

    wm_snapshot snap;
    memset(&snap, 0, sizeof(snap));
    CHECK_OK(ds_engine_for_each_fact(e, sc, collect_fact, &snap), "for_each_fact");
    CHECK(snap.n == 1, "exactly the un-retracted fact survives");
    if (snap.n == 1)
        CHECK(snap.count[0] == 42 && strcmp(snap.label[0], "hi") == 0,
              "surviving golden-decoded fact is {42,\"hi\"}");

    ds_engine_free(e);
}

/* ------------------------------------------------------------------ */
/* Header binding: dsc_hash mismatch is refused, match is accepted.   */
/* ------------------------------------------------------------------ */

static void test_header_binding(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (!e)
        return;
    (void)register_pkt(e);

    /* Stamp the tuple ds_engine_load_dsc would set from a DSC's header.
       test_dsc_basic's test_rbnd_5_1__replay_binds_the_whole_tuple goes
       through the loader. */
    for (int i = 0; i < 32; i++) {
        e->dsc_hash[i] = (uint8_t)(0x10 + i);
        e->dsc_def_sha256[i] = (uint8_t)(0x60 + i);
    }
    e->n_dsc_capabilities = 0;
    e->dsc_hash_valid = true;

    static uint8_t strbuf[256];

    /* A stream recorded under another DSC is refused. Its other tuple
       fields are the engine's: a hash with no `dialect_def_sha256` is
       DS_ERR_BND_INCOMPLETE before the hash is compared ([RBND.2.1]). */
    {
        uint8_t other[32];
        for (int i = 0; i < 32; i++)
            other[i] = (uint8_t)(0xA0 + i);
        ds_session_header_t h;
        CHECK_OK(ds_engine_get_session_header(e, &h), "get session header");
        h.dsc_hash = other;
        h.dsc_hash_len = 32;
        uint8_t fcst[128];
        size_t flen = 0;
        CHECK_OK(ds_rfcs_encode_header(&h, fcst, sizeof(fcst), &flen), "encode mismatch StreamHeader");

        ds_rfcs_replay_result_t rr;
        ds_result_t r = ds_rfcs_replay(e, fcst, flen, strbuf, sizeof(strbuf), &rr);
        CHECK(r.status == DS_ERR_BND_DSC_MISMATCH,
              "mismatched dsc_hash is refused with DS_ERR_BND_DSC_MISMATCH");
    }

    /* The matching DSC -> accepted, header positively verified. */
    {
        ds_session_header_t h;
        CHECK_OK(ds_engine_get_session_header(e, &h), "get session header");
        uint8_t fcst[128];
        size_t flen = 0;
        CHECK_OK(ds_rfcs_encode_header(&h, fcst, sizeof(fcst), &flen), "encode matching StreamHeader");

        ds_rfcs_replay_result_t rr;
        CHECK_OK(ds_rfcs_replay(e, fcst, flen, strbuf, sizeof(strbuf), &rr),
                 "matching dsc_hash replays");
        CHECK(rr.header_verified, "matching dsc_hash is positively verified");
    }

    ds_engine_free(e);
}

int main(void)
{
    test_fcem_golden();
    test_decode_golden_stream();
    test_header_binding();

    if (failures) {
        fprintf(stderr, "test_rfcs_golden: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_rfcs_golden: OK\n");
    return 0;
}
