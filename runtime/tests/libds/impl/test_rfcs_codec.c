/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * Atom framing, the StreamHeader, ClockAdvance, RuleFireAnnotation and
 * CallIssued atoms, and the stream reader.
 *
 * Checks: framing structure ([RFCS.19.1] two-level protobuf), encode->decode
 * round-trips, a hand-computed proto3 golden vector (byte-exactness vs the
 * wire format), a multi-atom reader
 * walk, and truncated-stream rejection. No engine required.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "test_ds_version.h"     /* [LDET.1.10] ds_test_accepted_version */
#include "rfcs/rfcs.h"
#include "rfcs_test_atom.h"

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

static void test_pack_atom(void)
{
    const uint8_t body[3] = { 0xAA, 0xBB, 0xCC };
    uint8_t out[64];
    size_t n = 0;
    /* FactAssert is field 1, so the frame is 0A <outer len> 0A 03 <3 body bytes> —
       a four-byte prefix. Taken from the function rather than written as a
       literal: the width is a function of the field number and the body
       length ([RFCS.19.1]). */
    const size_t framed = ds_rfcs_atom_framed_size(DS_ATOM_FACT_ASSERT, sizeof(body));

    CHECK_OK(ds_rfcs_pack_atom(DS_ATOM_FACT_ASSERT, body, sizeof(body), out, sizeof(out), &n),
             "pack_atom");
    CHECK(framed == 4 + 3, "a FactAssert prefix is 4 bytes over a 3-byte body");
    CHECK(n == framed, "pack_atom total length");
    {
        uint32_t       atom = 0;
        const uint8_t *bd = NULL;
        size_t         bl = 0;
        CHECK(ds_rfcs_test_atom1(out, n, &atom, &bd, &bl),
              "pack_atom output reads back as one atom");
        CHECK(atom == DS_ATOM_FACT_ASSERT, "pack_atom atom identity");
        CHECK(bl == 3 && memcmp(bd, body, 3) == 0, "pack_atom body");
    }

    /* size query: NULL out reports the needed size and does not write. */
    size_t need = 0;
    ds_result_t r = ds_rfcs_pack_atom(DS_ATOM_FACT_ASSERT, body, sizeof(body), NULL, 0, &need);
    CHECK(r.status == DS_ERR_INVAL && need == framed, "pack_atom size query");

    /* too-small buffer is rejected with the needed size. */
    r = ds_rfcs_pack_atom(DS_ATOM_FACT_ASSERT, body, sizeof(body), out, 4, &need);
    CHECK(r.status == DS_ERR_INVAL && need == framed, "pack_atom nospace");
}

/* [RFCS.19.6]: a writer must not frame at an unallocated field number, and
   must fail rather than emit one; a reader refuses such a frame
   ([RFCS.19.3]). */
static void test_rfcs_19_6__writer_refuses_unallocated_field(void)
{
    const uint8_t body[3] = { 0xAA, 0xBB, 0xCC };
    uint8_t out[64];
    size_t  n = 0;
    ds_result_t r;

    r = ds_rfcs_pack_atom(999u, body, sizeof(body), out, sizeof(out), &n);
    CHECK(r.status == DS_ERR_INVAL, "pack_atom refuses an unallocated field number");

    /* And it fails rather than emitting SOMETHING — the sizing helpers agree,
       so a caller cannot be told a frame exists and then find it does not. */
    CHECK(ds_rfcs_atom_framed_size(999u, sizeof(body)) == 0,
          "framed_size is 0 for an unallocated field number");
    CHECK(ds_rfcs_atom_prefix_size(999u, sizeof(body)) == 0,
          "prefix_size is 0 for an unallocated field number");
}

static void test_clka(void)
{
    uint8_t out[64] = {0};   /* read whole by the golden memcmp */
    size_t n = 0;
    CHECK_OK(ds_rfcs_encode_clka(5, 300, false, 0, out, sizeof(out), &n),
             "encode_clka");

    /* An UNSET wall clock writes has_wall false and no wall_ns, and proto3
       omits both, so these bytes are the single-clock encoding ([RFCS.10.1]).
       Hand-computed proto3 + framing for ClockAdvance{seq=5, clock_ns=300}:
       body = 08 05 (field1 varint 5) 10 AC 02 (field2 varint 300).
       ClockAdvance is field 3, so the inner key is (3 << 3) | 2 = 0x1A and fits one
       byte; the inner frame is key(1) + len(1) + body(5) = 7, which is what
       the outer length measures ([RFCS.19.1]). */
    static const uint8_t golden[] = {
        0x0A, 0x07,                         /* outer: field 1, len 7 */
        0x1A, 0x05,                         /* inner: ClockAdvance (field 3), len 5 */
        0x08, 0x05, 0x10, 0xAC, 0x02        /* ClockAdvance body */
    };
    CHECK(n == sizeof(golden), "clka framed length");
    CHECK(memcmp(out, golden, sizeof(golden)) == 0, "clka golden bytes");

    ds_rfcs_clka_t got;
    size_t bl_ = 0;
    const uint8_t *bd_ = ds_rfcs_test_body(out, n, &bl_);
    CHECK_OK(ds_rfcs_decode_clka(bd_, bl_, &got), "decode_clka");
    CHECK(got.seq == 5 && got.clock_ns == 300, "clka round-trip");
    CHECK(!got.has_wall, "an unset wall clock decodes as unset");

    /* Both clocks ([RFCS.10.3]): wall_ns is field 3, a varint, so
       wall_ns = 1 adds 18 01 to the body (key (3 << 3) | 0 = 0x18), and
       has_wall = 4 adds 20 01 (key (4 << 3) | 0 = 0x20) ([RFCS.10.1]). Body
       9 bytes, inner frame 11. */
    uint8_t out2[64] = {0};
    CHECK_OK(ds_rfcs_encode_clka(5, 300, true, 1, out2, sizeof(out2), &n),
             "encode_clka with wall");
    static const uint8_t golden2[] = {
        0x0A, 0x0B,                         /* outer: field 1, len 11 */
        0x1A, 0x09,                         /* inner: ClockAdvance (field 3), len 9 */
        0x08, 0x05, 0x10, 0xAC, 0x02,       /* seq, clock_ns */
        0x18, 0x01,                         /* wall_ns = 1 */
        0x20, 0x01                          /* has_wall = true */
    };
    CHECK(n == sizeof(golden2), "clka-with-wall framed length");
    CHECK(memcmp(out2, golden2, sizeof(golden2)) == 0, "clka-with-wall golden bytes");

    /* THE EPOCH IS A VALUE, NOT AN ABSENCE ([RFCS.10.1]): a wall clock set to
       0 writes has_wall and no wall_ns (proto3 omits the zero), and reads
       back as set at 0 -- which is what has_wall exists to tell apart. */
    uint8_t out4[64] = {0};
    CHECK_OK(ds_rfcs_encode_clka(5, 300, true, 0, out4, sizeof(out4), &n),
             "encode_clka at the epoch");
    bd_ = ds_rfcs_test_body(out4, n, &bl_);
    CHECK_OK(ds_rfcs_decode_clka(bd_, bl_, &got), "decode_clka at the epoch");
    CHECK(got.has_wall && got.wall_ns == 0, "a wall clock at the epoch is set");

    /* A wall clock before the epoch is legal ([LTIM.2.8.3] lets it move
       either way) and is an int64: it must survive, sign and all. */
    uint8_t out3[64] = {0};
    CHECK_OK(ds_rfcs_encode_clka(6, 400, true, -1234567890123LL, out3,
                                 sizeof(out3), &n), "encode_clka pre-epoch");
    bd_ = ds_rfcs_test_body(out3, n, &bl_);
    CHECK_OK(ds_rfcs_decode_clka(bd_, bl_, &got), "decode_clka pre-epoch");
    CHECK(got.seq == 6 && got.clock_ns == 400 && got.wall_ns == -1234567890123LL,
          "clka pre-epoch wall round-trip");
}

static void test_rfra(void)
{
    uint8_t out[128];
    size_t n = 0;
    CHECK_OK(ds_rfcs_encode_rfra(7, 999, "warm_alert", 42, true,
                                 out, sizeof(out), &n),
             "encode_rfra");
    uint32_t       atom_ = 0;
    const uint8_t *bd_ = NULL;
    size_t         bl_ = 0;
    CHECK(ds_rfcs_test_atom1(out, n, &atom_, &bd_, &bl_), "rfra reads back");
    CHECK(atom_ == DS_ATOM_RULE_FIRE_ANNOTATION, "rfra atom identity");
    /* The frame's declared length round-trips: what the writer emitted for a
       body of this size is exactly what the reader found. */
    CHECK(n == ds_rfcs_atom_framed_size(DS_ATOM_RULE_FIRE_ANNOTATION, bl_), "rfra frame length");

    ds_rfcs_rfra_t got;
    CHECK_OK(ds_rfcs_decode_rfra(bd_, bl_, &got), "decode_rfra");
    CHECK(got.seq == 7 && got.clock_ns == 999 && got.timetag == 42 &&
              got.end == true && strcmp(got.rule_name, "warm_alert") == 0,
          "rfra round-trip");
}

/* CallIssued (RFCS.15): framing, byte-determinism, fire-and-forget. */
static void test_call(void)
{
    uint8_t out[512], out2[512];
    size_t n = 0, n2 = 0;

    /* Recording view of CallIssued: seq, clock_ns, timetag, rule_name, service,
     * correlation, and the typed arguments, sorted by name ([RFCS.15],
     * `CallIssued.args`; `body_json` is reserved). */
    ds_arg_t args[1];
    memset(args, 0, sizeof(args));
    args[0].name = "k";
    args[0].value.kind = DS_ARG_INT;
    args[0].value.v.i = 1;
    CHECK_OK(ds_rfcs_encode_call(11, 12345, 777, "warm_alert", "svc.notify",
                                 "rsvp-alice", args, 1,
                                 out, sizeof(out), &n),
             "encode_call");
    {
        uint32_t       atom = 0;
        const uint8_t *bd = NULL;
        size_t         bl = 0;
        CHECK(ds_rfcs_test_atom1(out, n, &atom, &bd, &bl), "call reads back");
        CHECK(atom == DS_ATOM_CALL_ISSUED, "call atom identity");
        CHECK(n == ds_rfcs_atom_framed_size(DS_ATOM_CALL_ISSUED, bl), "call frame length");
        CHECK(bl > 0, "call non-empty body");
    }

    /* Compare-atom requirement (RFCS.15.4/.5): same inputs → byte-identical atom. */
    CHECK_OK(ds_rfcs_encode_call(11, 12345, 777, "warm_alert", "svc.notify",
                                 "rsvp-alice", args, 1,
                                 out2, sizeof(out2), &n2),
             "encode_call again");
    CHECK(n == n2 && memcmp(out, out2, n) == 0, "call encode deterministic");

    /* Fire-and-forget (RFCS.15.2): NULL correlation, and a call with no
       arguments, encode cleanly. */
    CHECK_OK(ds_rfcs_encode_call(1, 2, 0, "r", "s", NULL, NULL, 0,
                                 out, sizeof(out), &n),
             "encode_call fire-and-forget");
    {
        uint32_t       atom = 0;
        const uint8_t *bd = NULL;
        size_t         bl = 0;
        CHECK(ds_rfcs_test_atom1(out, n, &atom, &bd, &bl) &&
                  atom == DS_ATOM_CALL_ISSUED &&
                  n == ds_rfcs_atom_framed_size(DS_ATOM_CALL_ISSUED, bl),
              "f-a-f framed");
    }
}

static void test_header(void)
{
    uint8_t hash[32];
    for (int i = 0; i < 32; i++)
        hash[i] = (uint8_t)(i + 1);

    ds_session_header_t hdr;
    memset(&hdr, 0, sizeof(hdr));
    hdr.ds_version = ds_test_accepted_version();
    hdr.session_id = "";
    hdr.tier_id = "";
    hdr.dsc_hash = hash;
    hdr.dsc_hash_len = 32;

    uint8_t out[128];
    size_t n = 0;
    CHECK_OK(ds_rfcs_encode_header(&hdr, out, sizeof(out), &n), "encode_header");
    CHECK(ds_rfcs_test_is(out, n, DS_ATOM_STREAM_HEADER), "fcst atom identity");

    ds_rfcs_header_t got;
    size_t bl_ = 0;
    const uint8_t *bd_ = ds_rfcs_test_body(out, n, &bl_);
    CHECK_OK(ds_rfcs_decode_header(bd_, bl_, &got), "decode_header");
    CHECK(strcmp(got.ds_version, ds_test_accepted_version()) == 0,
          "fcst ds_version round-trip");
    CHECK(got.dsc_hash_len == 32 && memcmp(got.dsc_hash, hash, 32) == 0,
          "fcst dsc_hash round-trip");
}

/* The reader walks several atoms, then refuses a truncated stream. */
static void test_reader(void)
{
    uint8_t buf[256];
    size_t off = 0, n = 0;
    CHECK_OK(ds_rfcs_encode_clka(1, 10, false, 0, buf + off, sizeof(buf) - off, &n), "rd enc clka");
    off += n;
    CHECK_OK(ds_rfcs_encode_rfra(2, 20, "r", 0, false, buf + off, sizeof(buf) - off, &n), "rd enc rfra");
    off += n;
    CHECK_OK(ds_rfcs_encode_clka(3, 30, false, 0, buf + off, sizeof(buf) - off, &n), "rd enc clka2");
    off += n;

    ds_rfcs_reader_t rd;
    ds_rfcs_reader_init(&rd, buf, off);
    uint32_t atom;
    const uint8_t *body;
    size_t blen;
    bool done = false;
    const uint32_t expect[3] = { DS_ATOM_CLOCK_ADVANCE, DS_ATOM_RULE_FIRE_ANNOTATION, DS_ATOM_CLOCK_ADVANCE };
    int count = 0;
    for (;;) {
        CHECK_OK(ds_rfcs_next(&rd, &atom, &body, &blen, &done), "reader next");
        if (done)
            break;
        CHECK(count < 3 && atom == expect[count], "reader atom order");
        count++;
    }
    CHECK(count == 3, "reader atom count");

    /* Truncated body (drop the last byte) is a hard parse error. */
    ds_rfcs_reader_init(&rd, buf, off - 1);
    int saw_parse_err = 0;
    for (;;) {
        ds_result_t r = ds_rfcs_next(&rd, &atom, &body, &blen, &done);
        if (r.status == DS_ERR_PARSE) {
            saw_parse_err = 1;
            break;
        }
        if (r.status != DS_OK || done)
            break;
    }
    CHECK(saw_parse_err, "reader rejects truncated stream");
}

/* [RFCS.19.3]: a field number with no registry entry is no member of Atom's
   `body` oneof, so the reader refuses the frame, wherever the number lies.
   Each stream is [ClockAdvance][X][ClockAdvance], X a hand-framed atom
   ([RFCS.19.1]: 0A <len> <tag> <len> <body>) at an unallocated number. The
   body is the varint field 1 = 1. Every case is DS_ERR_PARSE with the first
   ClockAdvance read and the second not:
     - 100, 200, 322 and 3000: unallocated numbers across the field-number
       range, low and high, with 1- and 2-byte tags and one past 2047.
     - 260: reserved in atom.proto (the retired Seal).
     - 323: TextNote, deferred and held out of `Atom.oneof body`.
   PATH PINNED: rfcs_read_step's ds_pbf_lookup refusal, from ds_rfcs_next and
   from ds_rfcs_next_incremental. */
static const uint8_t X_UNKNOWN_322[]  = { 0x0A, 0x05, 0x92, 0x14, 0x02, 0x08, 0x01 };
static const uint8_t X_UNKNOWN_100[]  = { 0x0A, 0x05, 0xA2, 0x06, 0x02, 0x08, 0x01 };
static const uint8_t X_UNKNOWN_200[]  = { 0x0A, 0x05, 0xC2, 0x0C, 0x02, 0x08, 0x01 };
static const uint8_t X_UNKNOWN_3000[] = { 0x0A, 0x06, 0xC2, 0xBB, 0x01, 0x02, 0x08, 0x01 };
static const uint8_t X_SEAL_260[]     = { 0x0A, 0x05, 0xA2, 0x10, 0x02, 0x08, 0x01 };
static const uint8_t X_TEXT_323[]     = { 0x0A, 0x05, 0x9A, 0x14, 0x02, 0x08, 0x01 };

/* [ClockAdvance][x][ClockAdvance] into buf; its length, or 0. */
static size_t clka_around(const uint8_t *x, size_t xlen, uint8_t *buf, size_t cap)
{
    size_t off = 0, n = 0;
    if (ds_rfcs_encode_clka(1, 10, false, 0, buf, cap, &n).status != DS_OK) return 0;
    off += n;
    if (off + xlen > cap) return 0;
    memcpy(buf + off, x, xlen);
    off += xlen;
    if (ds_rfcs_encode_clka(2, 20, false, 0, buf + off, cap - off, &n).status != DS_OK)
        return 0;
    return off + n;
}

/* Walk with ds_rfcs_next: the CLKAs read, and the status that ended it. */
static ds_status_t walk_whole(const uint8_t *buf, size_t len, int *clkas)
{
    ds_rfcs_reader_t rd;
    uint32_t atom = 0;
    const uint8_t *body;
    size_t blen;
    bool done = false;
    *clkas = 0;
    ds_rfcs_reader_init(&rd, buf, len);
    for (;;) {
        ds_result_t r = ds_rfcs_next(&rd, &atom, &body, &blen, &done);
        if (r.status != DS_OK) return r.status;
        if (done) return DS_OK;
        if (atom == DS_ATOM_CLOCK_ADVANCE) (*clkas)++;
    }
}

/* The same with ds_rfcs_next_incremental, which must agree. */
static ds_status_t walk_incremental(const uint8_t *buf, size_t len, int *clkas)
{
    ds_rfcs_reader_t rd;
    uint32_t atom = 0;
    const uint8_t *body;
    size_t blen;
    ds_rfcs_step_t step;
    *clkas = 0;
    ds_rfcs_reader_init(&rd, buf, len);
    for (;;) {
        ds_result_t r = ds_rfcs_next_incremental(&rd, &atom, &body, &blen, &step);
        if (r.status != DS_OK) return r.status;
        if (step != DS_RFCS_STEP_ATOM) return DS_OK;
        if (atom == DS_ATOM_CLOCK_ADVANCE) (*clkas)++;
    }
}

static void test_rfcs_19_3__reader_refuses_an_unknown_field_number(void)
{
    static const struct {
        const uint8_t *x;
        size_t         xlen;
        const char    *what;
    } cases[] = {
        { X_UNKNOWN_100,  sizeof X_UNKNOWN_100,  "100: DS_ERR_PARSE after one CLKA" },
        { X_UNKNOWN_200,  sizeof X_UNKNOWN_200,  "200: DS_ERR_PARSE after one CLKA" },
        { X_UNKNOWN_322,  sizeof X_UNKNOWN_322,  "322: DS_ERR_PARSE after one CLKA" },
        { X_UNKNOWN_3000, sizeof X_UNKNOWN_3000, "3000: DS_ERR_PARSE after one CLKA" },
        { X_SEAL_260,     sizeof X_SEAL_260,
          "260, the retired Seal: DS_ERR_PARSE after one CLKA" },
        { X_TEXT_323,     sizeof X_TEXT_323,
          "323, the deferred TextNote: DS_ERR_PARSE after one CLKA" },
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        uint8_t buf[128];
        size_t len = clka_around(cases[i].x, cases[i].xlen, buf, sizeof buf);
        CHECK(len > 0, "build [ClockAdvance][X][ClockAdvance]");
        if (len == 0) continue;
        int whole = -1, incr = -1;
        ds_status_t sw = walk_whole(buf, len, &whole);
        ds_status_t si = walk_incremental(buf, len, &incr);
        CHECK(sw == DS_ERR_PARSE && whole == 1, cases[i].what);
        CHECK(si == DS_ERR_PARSE && incr == 1, cases[i].what);
    }

    /* The control: the same walk over [ClockAdvance][ClockAdvance] ends
       cleanly with both read, so a refusal above is the unknown frame's. */
    {
        static const uint8_t none[1] = { 0 };   /* not NULL: memcpy's operand */
        uint8_t buf[128];
        size_t len = clka_around(none, 0, buf, sizeof buf);
        int whole = -1, incr = -1;
        CHECK(len > 0, "build [ClockAdvance][ClockAdvance]");
        CHECK(walk_whole(buf, len, &whole) == DS_OK && whole == 2,
              "control: ds_rfcs_next reads both CLKAs");
        CHECK(walk_incremental(buf, len, &incr) == DS_OK && incr == 2,
              "control: ds_rfcs_next_incremental reads both CLKAs");
    }
}

/* event_id: deterministic cross-tier correlation. */
static void test_event_id(void)
{
    /* Deterministic derivation: same tuple -> same UUID; any input change -> different. */
    char a[DS_RFCS_EVENT_ID_LEN], b[DS_RFCS_EVENT_ID_LEN], c[DS_RFCS_EVENT_ID_LEN];
    ds_rfcs_gen_event_id("sess-1", "tierA", 7, a);
    ds_rfcs_gen_event_id("sess-1", "tierA", 7, b);
    ds_rfcs_gen_event_id("sess-1", "tierA", 8, c);
    CHECK(strcmp(a, b) == 0, "event_id is deterministic (reproduces on the same tuple)");
    CHECK(strcmp(a, c) != 0, "event_id varies with seq");
    CHECK(strlen(a) == 36 && a[8] == '-' && a[13] == '-' && a[18] == '-' && a[23] == '-',
          "event_id is UUID-shaped");

    uint8_t body[2] = { 0x08, 0x07 };
    uint8_t atom[256];
    size_t n = 0;
    ds_rfcs_fcem_t got;

    /* FactAssert round-trips a non-empty event_id; "" stays absent. */
    CHECK_OK(ds_rfcs_encode_fcem(1, "T", body, 2, 0, 0, 5, a, atom, sizeof(atom), &n),
             "encode_fcem with event_id");
    size_t bl_ = 0;
    const uint8_t *bd_ = ds_rfcs_test_body(atom, n, &bl_);
    CHECK_OK(ds_rfcs_decode_fcem(bd_, bl_, &got), "decode_fcem event_id");
    CHECK(ds_rfcs_str_eq(got.event_id, a), "event_id round-trips");
    CHECK_OK(ds_rfcs_encode_fcem(1, "T", body, 2, 0, 0, 5, "", atom, sizeof(atom), &n),
             "encode_fcem empty event_id");
    bd_ = ds_rfcs_test_body(atom, n, &bl_);
    CHECK_OK(ds_rfcs_decode_fcem(bd_, bl_, &got), "decode empty event_id");
    CHECK(got.event_id.len == 0 && got.event_id.ptr != NULL,
          "empty event_id stays absent, as \"\"");

    /* Two-tier echo (harness as integrator, [NCBK.10]): tier A derives, tier B
       ECHOES A's value into its own FactAssert -> byte-identical event_id (cross-tier
       correlation by shared value, [LFST.5.6]). Tiers share session_id
       ([RFCS.4.3]); tier B does NOT re-derive from its own (tier_id, seq). */
    char eidA[DS_RFCS_EVENT_ID_LEN];
    ds_rfcs_gen_event_id("run-uuid", "tierA", 12, eidA);   /* tier-A publish */
    uint8_t atomA[256], atomB[256];
    size_t nA = 0, nB = 0;
    CHECK_OK(ds_rfcs_encode_fcem(1, "Pub", body, 2, 0, 0, 12, eidA, atomA, sizeof(atomA), &nA),
             "tier-A publish FactAssert");
    CHECK_OK(ds_rfcs_encode_fcem(1, "Pub", body, 2, 0, 0, 3, eidA, atomB, sizeof(atomB), &nB),
             "tier-B assert FactAssert (echoed event_id)");
    ds_rfcs_fcem_t fa, fb;
    size_t blA = 0, blB = 0;
    const uint8_t *bdA = ds_rfcs_test_body(atomA, nA, &blA);
    const uint8_t *bdB = ds_rfcs_test_body(atomB, nB, &blB);
    CHECK_OK(ds_rfcs_decode_fcem(bdA, blA, &fa), "decode tier-A");
    CHECK_OK(ds_rfcs_decode_fcem(bdB, blB, &fb), "decode tier-B");
    CHECK(ds_rfcs_str_eq(fa.event_id, eidA) && ds_rfcs_str_eq(fb.event_id, eidA),
          "tier-A publish and tier-B assert share a byte-identical event_id");
}

/* A string of `n` bytes, none of them NUL, for the length tests below. */
static void long_name(char *buf, size_t n)
{
    for (size_t i = 0; i < n; i++)
        buf[i] = (char)('a' + (int)(i % 26u));
    buf[n] = '\0';
}

/* A run id and a tier id of any length decode whole. [RFCS.4.3] records the
   run id so a replay can be given it and reproduce every `event_id`, and no
   clause bounds its length. Lengths 63, 64 and 100. */
/* @spec [RFCS.4.3] [RFCS.4.4] */
static void test_header_ids_decode_whole(void)
{
    static const size_t lens[] = { 63, 64, 100 };
    for (size_t k = 0; k < sizeof lens / sizeof lens[0]; k++) {
        char run[128], tier[128];
        long_name(run, lens[k]);
        long_name(tier, lens[k]);
        tier[0] = 'T';

        ds_session_header_t hdr;
        memset(&hdr, 0, sizeof(hdr));
        hdr.ds_version = ds_test_accepted_version();
        hdr.session_id = run;
        hdr.tier_id = tier;

        uint8_t out[512];
        size_t n = 0;
        CHECK_OK(ds_rfcs_encode_header(&hdr, out, sizeof(out), &n),
                 "encode_header with long ids");
        ds_rfcs_header_t got;
        size_t bl = 0;
        const uint8_t *bd = ds_rfcs_test_body(out, n, &bl);
        CHECK_OK(ds_rfcs_decode_header(bd, bl, &got), "decode_header long ids");
        CHECK(ds_rfcs_str_eq(got.session_id, run),
              "a run id decodes whole, whatever its length");
        CHECK(ds_rfcs_str_eq(got.tier_id, tier),
              "a tier id decodes whole, whatever its length");
    }
}

/* A FactAssert's and a FactEmit's schema name of any length decode whole,
   and an event_id longer than the 36 bytes this engine derives decodes as
   written. */
/* @spec [RFCS.5.4] [RFCS.6a] */
static void test_fact_strings_decode_whole(void)
{
    static const size_t lens[] = { 63, 64, 100 };
    uint8_t body[2] = { 0x08, 0x07 };
    char eid[48];
    long_name(eid, 40);
    for (size_t k = 0; k < sizeof lens / sizeof lens[0]; k++) {
        char name[128];
        long_name(name, lens[k]);
        name[0] = 'S';

        uint8_t atom[512];
        size_t n = 0, bl = 0;
        ds_rfcs_fcem_t got;
        CHECK_OK(ds_rfcs_encode_fcem(1, name, body, 2, 0, 0, 5, eid,
                                     atom, sizeof(atom), &n),
                 "encode_fcem with a long schema name");
        const uint8_t *bd = ds_rfcs_test_body(atom, n, &bl);
        CHECK_OK(ds_rfcs_decode_fcem(bd, bl, &got), "decode_fcem long name");
        CHECK(ds_rfcs_str_eq(got.schema_name, name),
              "a FactAssert's schema name decodes whole");
        CHECK(ds_rfcs_str_eq(got.event_id, eid),
              "a FactAssert's event_id decodes as written");
        CHECK(got.fact_len == 2 && got.fact[0] == 0x08 && got.fact[1] == 0x07,
              "and the fact body beside them is unchanged");

        CHECK_OK(ds_rfcs_encode_femt(1, name, body, 2, 0, "r", 0, 5, eid,
                                     atom, sizeof(atom), &n),
                 "encode_femt with a long schema name");
        bd = ds_rfcs_test_body(atom, n, &bl);
        CHECK_OK(ds_rfcs_decode_femt(bd, bl, &got), "decode_femt long name");
        CHECK(ds_rfcs_str_eq(got.schema_name, name),
              "a FactEmit's schema name decodes whole");
        CHECK(ds_rfcs_str_eq(got.event_id, eid),
              "a FactEmit's event_id decodes as written");
    }
}

/* [RFCS.7.5]: a FactRetract carries the stream event's seq and
   clock_ns. The vector: an integrator retraction's atom encoded from the
   values the recorder passes (ds_rfcs_recorder_on_event's DS_EV_FACT_RETRACT
   arm, the one site that writes a FactRetract), decoded, and re-encoded byte for
   byte, with seq and clock_ns NON-ZERO -- proto3 omits a zero, so a zero
   would pass an encoder that drops both fields. */
static void test_rfcs_7_5__fcrt_round_trip(void)
{
    uint8_t atom[64], again[64];
    size_t n = 0, m = 0;

    CHECK_OK(ds_rfcs_encode_fcrt(99, 7, 123456, atom, sizeof(atom), &n),
             "encode_fcrt with seq and clock_ns");
    CHECK(ds_rfcs_test_is(atom, n, DS_ATOM_FACT_RETRACT), "the atom is a FactRetract");

    size_t bl = 0;
    const uint8_t *bd = ds_rfcs_test_body(atom, n, &bl);
    ds_rfcs_fcrt_t fr;
    CHECK_OK(ds_rfcs_decode_fcrt(bd, bl, &fr), "decode_fcrt");
    CHECK(fr.fact_id == 99, "fact_id round-trips");
    CHECK(fr.seq == 7, "seq round-trips (RFCS.7.5)");
    CHECK(fr.clock_ns == 123456, "clock_ns round-trips (RFCS.7.5)");

    CHECK_OK(ds_rfcs_encode_fcrt(fr.fact_id, fr.seq, fr.clock_ns,
                                 again, sizeof(again), &m),
             "re-encode from the decoded values");
    CHECK(m == n && memcmp(atom, again, n) == 0,
          "decode then encode reproduces the bytes");

    /* The body is the proto's three varints in field order, which is also
       what Mercury's `encode_event` and pyds's `encode_fcrt` write; the
       differential compares the two runtimes' streams on it. */
    static const uint8_t want[] = { 0x08, 99, 0x10, 7, 0x18, 0xC0, 0xC4, 0x07 };
    CHECK(bl == sizeof want && memcmp(bd, want, bl) == 0,
          "the body is fact_id=1, seq=2, clock_ns=3 as varints, in order");

    /* A body of fact_id alone decodes, with seq and clock_ns reading 0:
       additive in proto3. */
    static const uint8_t old[] = { 0x08, 99 };
    CHECK_OK(ds_rfcs_decode_fcrt(old, sizeof old, &fr), "decode a one-field body");
    CHECK(fr.fact_id == 99 && fr.seq == 0 && fr.clock_ns == 0,
          "a body without seq and clock_ns reads them as 0");
}

int main(void)
{
    test_pack_atom();
    test_rfcs_19_6__writer_refuses_unallocated_field();
    test_rfcs_7_5__fcrt_round_trip();
    test_clka();
    test_rfra();
    test_call();
    test_header();
    test_reader();
    test_rfcs_19_3__reader_refuses_an_unknown_field_number();
    test_event_id();
    test_header_ids_decode_whole();
    test_fact_strings_decode_whole();

    if (failures) {
        fprintf(stderr, "test_rfcs_codec: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_rfcs_codec: OK\n");
    return 0;
}
