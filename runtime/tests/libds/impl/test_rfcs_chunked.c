/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * Replay consumes a stream, not a buffer: [RFCS.2.2] "Readers process atoms
 * one at a time in order"; [LFST.9.1] "a replayer opens a stream ... then
 * consumes events in seq order", at [LFST.12.4]'s sizing of 4GB-40GB per tier
 * per day.
 *
 * The property under test is that atom boundaries and chunk boundaries are
 * independent. If re-assembly is wrong, feeding the same bytes one at a time
 * diverges from feeding them at once, and the two runs stop agreeing.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "rete/engine.h"
#include "rfcs/rfcs.h"
#include "dsc/pbf_reader.h"
#include "dsc/pbf_writer.h"   /* ds_pbf_write_prefix — build a real prefix */

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
    { .name = "label", .type = DS_SLOT_TYPE_STRING, .identity_role = DS_IDENTITY_KEY },
    { .name = "n",     .type = DS_SLOT_TYPE_INT,    .identity_role = DS_IDENTITY_MUTABLE },
};

static ds_engine_t *new_engine(const ds_schema_t **out_sc)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (!e) return NULL;
    CHECK_OK(ds_engine_register_schema(e, "Rec", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       SLOTS, 2, out_sc), "register_schema");
    return e;
}

/* Build a StreamHeader + Rec's SchemaDef + `n` FactAssert stream. Returns bytes
   used, 0 on failure. The SchemaDef because a replay refuses a FactAssert no
   SchemaDef announced ([RFCS.5.4]). */
static size_t build_stream(uint8_t *out, size_t cap, int n)
{
    const ds_schema_t *sc = NULL;
    ds_engine_t *e = new_engine(&sc);
    if (!e || !sc) { if (e) ds_engine_free(e); return 0; }

    ds_session_header_t h;
    memset(&h, 0, sizeof(h));
    CHECK_OK(ds_engine_get_session_header(e, &h), "session header");

    size_t used = 0, w = 0;
    CHECK_OK(ds_rfcs_encode_header(&h, out, cap, &w), "encode StreamHeader");
    used += w;
    CHECK_OK(ds_rfcs_encode_schema_def("Rec", out + used, cap - used, &w),
             "encode Rec's SchemaDef");
    used += w;

    for (int i = 1; i <= n; i++) {
        char label[32];
        snprintf(label, sizeof(label), "row-%d", i);

        ds_slot_value_t v[2];
        memset(v, 0, sizeof(v));
        v[0].kind = DS_SLOT_STRING; v[0].v.s = label;
        v[1].kind = DS_SLOT_INT;    v[1].v.i = i;

        ds_fact_t *f = NULL;
        CHECK_OK(ds_engine_assert(e, sc, v, 2, &f), "assert source");

        uint8_t body[256];
        size_t  blen = 0;
        CHECK_OK(ds_rfcs_encode_fact_body(f, body, sizeof(body), &blen),
                 "encode body");
        CHECK_OK(ds_rfcs_encode_fcem((uint64_t)i, "Rec", body, blen, 0, 0, 0, "",
                                     out + used, cap - used, &w),
                 "encode FactAssert");
        used += w;
    }
    ds_engine_free(e);
    return used;
}

/* Replay `stream` in fixed-size chunks; report counters + resulting WM size. */
static void replay_chunked(const uint8_t *stream, size_t len, size_t chunk,
                           ds_rfcs_replay_result_t *out_res, size_t *out_facts,
                           const char *what)
{
    const ds_schema_t *sc = NULL;
    ds_engine_t *e = new_engine(&sc);
    if (!e) return;

    /* The one replay operation ([LFST.9.6]). The streams here are FactAssert-only
       over a rule-less schema, so the pumps fire nothing and there is nothing
       to compare -- the property under test is re-assembly. */
    ds_rfcs_replay_ctx_t *ctx = NULL;
    CHECK_OK(ds_rfcs_replay_begin(e, NULL, &ctx), "replay_begin");
    if (ctx) {
        for (size_t off = 0; off < len; off += chunk) {
            size_t take = len - off < chunk ? len - off : chunk;
            CHECK_OK(ds_rfcs_replay_feed(ctx, stream + off, take), what);
        }
        CHECK_OK(ds_rfcs_replay_finish(ctx, out_res), "replay_finish");
    }
    CHECK_OK(ds_engine_fact_count(e, out_facts), "fact_count");
    ds_engine_free(e);
}

/* Chunk boundaries are independent of atom boundaries. */

static void test_byte_at_a_time_equals_all_at_once(void)
{
    static uint8_t stream[8192];
    size_t len = build_stream(stream, sizeof(stream), 12);
    CHECK(len > 0, "stream built");
    if (!len) return;

    ds_rfcs_replay_result_t whole, single, seven;
    size_t f_whole = 0, f_single = 0, f_seven = 0;
    memset(&whole, 0, sizeof(whole));
    memset(&single, 0, sizeof(single));
    memset(&seven, 0, sizeof(seven));

    replay_chunked(stream, len, len, &whole,  &f_whole,  "feed whole");
    replay_chunked(stream, len, 1,   &single, &f_single, "feed 1 byte");
    /* 7-byte chunks split the varint prefixes as well as the bodies. */
    replay_chunked(stream, len, 7,   &seven,  &f_seven,  "feed 7 bytes");

    CHECK(whole.asserts == 12, "all 12 facts applied when fed whole");
    CHECK(single.asserts == whole.asserts, "1-byte chunks apply the same count");
    CHECK(seven.asserts  == whole.asserts, "7-byte chunks apply the same count");
    CHECK(single.header_verified == whole.header_verified,
          "StreamHeader is recognised across a split header");
    CHECK(f_single == f_whole && f_seven == f_whole,
          "working memory is identical however the stream was chunked");
}

/* The atom bound is enforced before anything is allocated. [RFCS.19.7]: a
 * reader may reject an atom whose DECLARED length exceeds an implementation
 * bound without waiting for or allocating for its body. The bound itself is
 * implementation (`max_atom_bytes`); the clause makes acting on the declared
 * length legitimate, though [RFCS.19.2] calls those same bytes EOF. */
static void test_rfcs_19_7__refused_on_declared_length(void)
{
    const ds_schema_t *sc = NULL;
    ds_engine_t *e = new_engine(&sc);
    if (!e) return;

    ds_rfcs_replay_opts_t opts;
    memset(&opts, 0, sizeof(opts));
    opts.max_atom_bytes = 64;                  /* deliberately tiny */

    ds_rfcs_replay_ctx_t *ctx = NULL;
    CHECK_OK(ds_rfcs_replay_begin(e, &opts, &ctx), "begin with a small bound");
    if (ctx) {
        /* A well-formed frame prefix declaring a 4 KiB body. Nothing follows:
           the bound must trip on the DECLARED length, without waiting for (or
           allocating for) the body.

           Written by the production framer: the prefix is a run of varints
           whose width depends on the field number and the declared length. */
        static uint8_t frame[4096 + DS_RFCS_ATOM_PREFIX_MAX];
        uint32_t field = DS_ATOM_FACT_ASSERT;
        size_t   hdr_len = 0, total = 0;

        /* The writer's capacity test covers the body too, so the buffer is
           sized for prefix + body — and then only the prefix is fed. The body
           is never written; a truncated frame is the point. */
        CHECK(ds_pbf_write_prefix(field, 4096, frame, sizeof(frame),
                                  &hdr_len, &total),
              "prefix for a 4096-byte FactAssert");
        CHECK(hdr_len == ds_rfcs_atom_prefix_size(DS_ATOM_FACT_ASSERT, 4096),
              "prefix_size agrees with write_prefix");
        CHECK(hdr_len <= DS_RFCS_ATOM_PREFIX_MAX,
              "the prefix fits DS_RFCS_ATOM_PREFIX_MAX");

        ds_result_t r = ds_rfcs_replay_feed(ctx, frame, hdr_len);
        CHECK(r.status != DS_OK, "an atom over max_atom_bytes is refused");

        /* Sticky: a failed ctx refuses further work rather than half-applying. */
        ds_result_t r2 = ds_rfcs_replay_feed(ctx, frame, hdr_len);
        CHECK(r2.status != DS_OK, "the error is sticky");

        ds_result_t rf = ds_rfcs_replay_finish(ctx, NULL);
        CHECK(rf.status != DS_OK, "finish reports the sticky error");
    }
    ds_engine_free(e);
}

/* A partial tail is end-of-stream here, and an error whole-buffer.
 * [RFCS.19.2]: for a reader consuming a stream incrementally, a partial
 * trailing atom ends the stream at the last complete atom. A reader whose
 * caller supplied the full extent may refuse it instead. [RFCS.19.8] makes
 * the incremental path the one that recovers a crash-truncated recording, so
 * the property is checked at EVERY cut, not at one convenient offset: a
 * boundary the test happens to miss is where a recovery would fail. */

#define MAX_ATOMS 16

/* Offsets just past each atom of a well-formed stream, from the strict
   reader. bounds[0] is the first atom's end. Returns the atom count. */
static int atom_bounds(const uint8_t *stream, size_t len, size_t *bounds)
{
    ds_rfcs_reader_t r;
    ds_rfcs_reader_init(&r, stream, len);
    int n = 0;
    for (;;) {
        uint32_t atom = 0;
        const uint8_t *body = NULL;
        size_t blen = 0;
        bool done = false;
        ds_result_t res = ds_rfcs_next(&r, &atom, &body, &blen, &done);
        CHECK_OK(res, "atom_bounds: the uncut stream reads");
        if (res.status != DS_OK || done || n == MAX_ATOMS) break;
        bounds[n++] = r.pos;
    }
    return n;
}

/* Atoms wholly inside stream[0..cut), and the offset where they end. */
static int complete_before(const size_t *bounds, int n, size_t cut,
                           size_t *last_end)
{
    int k = 0;
    *last_end = 0;
    while (k < n && bounds[k] <= cut) *last_end = bounds[k++];
    return k;
}

static void test_rfcs_19_2__chunked_tail_is_eof_at_every_cut(void)
{
    static uint8_t stream[8192];
    size_t len = build_stream(stream, sizeof(stream), 4);
    CHECK(len > 8, "stream built");
    if (len <= 8) return;

    size_t bounds[MAX_ATOMS];
    int n = atom_bounds(stream, len, bounds);
    CHECK(n == 6, "StreamHeader, Rec's SchemaDef and four FCEMs");

    for (size_t cut = 0; cut <= len; cut++) {
        size_t last_end = 0;
        int whole = complete_before(bounds, n, cut, &last_end);
        /* bounds[0] is the StreamHeader and bounds[1] Rec's SchemaDef
           (build_stream); every later atom is one FactAssert. */
        uint64_t want_asserts = whole > 2 ? (uint64_t)(whole - 2) : 0;

        for (int pass = 0; pass < 2; pass++) {   /* all at once, then bytewise */
            const ds_schema_t *sc = NULL;
            ds_engine_t *e = new_engine(&sc);
            if (!e) return;

            ds_rfcs_replay_ctx_t *ctx = NULL;
            ds_rfcs_replay_result_t res;
            memset(&res, 0, sizeof(res));
            CHECK_OK(ds_rfcs_replay_begin(e, NULL, &ctx), "begin");
            if (ctx) {
                if (pass == 0) {
                    CHECK_OK(ds_rfcs_replay_feed(ctx, stream, cut), "feed the cut");
                } else {
                    for (size_t i = 0; i < cut; i++)
                        CHECK_OK(ds_rfcs_replay_feed(ctx, stream + i, 1),
                                 "feed the cut a byte at a time");
                }
                ds_result_t r = ds_rfcs_replay_finish(ctx, &res);
                if (r.status != DS_OK) {
                    fprintf(stderr, "  cut=%zu pass=%d\n", cut, pass);
                    CHECK(0, "a cut stream finishes as end-of-stream, not an error");
                }
            }
            if (res.asserts != want_asserts || res.tail_bytes != cut - last_end) {
                fprintf(stderr, "  cut=%zu pass=%d asserts=%llu want=%llu "
                        "tail=%llu want=%zu\n", cut, pass,
                        (unsigned long long)res.asserts,
                        (unsigned long long)want_asserts,
                        (unsigned long long)res.tail_bytes, cut - last_end);
                CHECK(0, "the complete prefix applies and the tail is reported");
            }
            CHECK(!res.header_verified || whole >= 1,
                  "a partial header is never taken as verified");
            ds_engine_free(e);
        }
    }
}

static void test_rfcs_19_2__whole_buffer_refuses_a_partial_tail(void)
{
    static uint8_t stream[8192];
    static uint8_t strbuf[16384];
    size_t len = build_stream(stream, sizeof(stream), 4);
    CHECK(len > 8, "stream built");
    if (len <= 8) return;

    const ds_schema_t *sc = NULL;
    ds_engine_t *e = new_engine(&sc);
    if (!e) return;
    ds_result_t r = ds_rfcs_replay(e, stream, len - 3, strbuf, sizeof(strbuf),
                                   NULL);
    CHECK(r.status == DS_ERR_PARSE,
          "the whole-buffer form refuses a stream that ends mid-atom");
    ds_engine_free(e);
}

/* The incremental reader: INCOMPLETE, then resume. */

static void test_rfcs_19_2__incremental_reader_at_every_cut(void)
{
    static uint8_t stream[8192];
    size_t len = build_stream(stream, sizeof(stream), 4);
    CHECK(len > 8, "stream built");
    if (len <= 8) return;

    size_t bounds[MAX_ATOMS];
    int n = atom_bounds(stream, len, bounds);

    for (size_t cut = 0; cut <= len; cut++) {
        size_t last_end = 0;
        int whole = complete_before(bounds, n, cut, &last_end);

        ds_rfcs_reader_t r;
        ds_rfcs_reader_init(&r, stream, cut);
        int got = 0;
        ds_rfcs_step_t step = DS_RFCS_STEP_ATOM;
        for (;;) {
            uint32_t atom = 0;
            const uint8_t *body = NULL;
            size_t blen = 0;
            ds_result_t res = ds_rfcs_next_incremental(&r, &atom, &body, &blen,
                                                       &step);
            if (res.status != DS_OK) {
                fprintf(stderr, "  cut=%zu\n", cut);
                CHECK(0, "a cut stream is never an error to the incremental reader");
                break;
            }
            if (step != DS_RFCS_STEP_ATOM) break;
            got++;
        }
        CHECK(got == whole, "every complete atom before the cut is read");
        CHECK(r.pos == last_end, "the reader stops at the partial atom's start");
        CHECK(step == (cut == last_end ? DS_RFCS_STEP_END
                                       : DS_RFCS_STEP_INCOMPLETE),
              "END on a boundary, INCOMPLETE inside an atom");

        /* The strict reader agrees on the prefix and refuses the tail. */
        ds_rfcs_reader_t s;
        ds_rfcs_reader_init(&s, stream, cut);
        ds_result_t sres = DS_OK_R;
        for (int i = 0; i <= whole; i++) {
            uint32_t atom = 0;
            const uint8_t *body = NULL;
            size_t blen = 0;
            bool done = false;
            sres = ds_rfcs_next(&s, &atom, &body, &blen, &done);
            if (sres.status != DS_OK || done) break;
        }
        CHECK((sres.status == DS_OK) == (cut == last_end),
              "the whole-buffer reader errs exactly when the cut is inside an atom");

        /* More bytes arrive: resume and read the rest of the stream. */
        CHECK_OK(ds_rfcs_reader_extend(&r, stream, len), "extend");
        for (;;) {
            uint32_t atom = 0;
            const uint8_t *body = NULL;
            size_t blen = 0;
            ds_result_t res = ds_rfcs_next_incremental(&r, &atom, &body, &blen,
                                                       &step);
            CHECK_OK(res, "the resumed read");
            if (res.status != DS_OK || step != DS_RFCS_STEP_ATOM) break;
            got++;
        }
        CHECK(got == n && step == DS_RFCS_STEP_END,
              "resuming after the cut reads every atom exactly once");
    }

    ds_rfcs_reader_t r;
    ds_rfcs_reader_init(&r, stream, len);
    r.pos = len;
    CHECK(ds_rfcs_reader_extend(&r, stream, len - 1).status == DS_ERR_INVAL,
          "extend refuses a buffer shorter than what was read");
}

/* A frame that no append can repair is an error, and names where it is. */
static void test_rfcs_19_2__malformed_is_an_error_at_its_offset(void)
{
    static uint8_t stream[8192];
    size_t len = build_stream(stream, sizeof(stream), 4);
    CHECK(len > 8, "stream built");
    if (len <= 8) return;

    size_t bounds[MAX_ATOMS];
    int n = atom_bounds(stream, len, bounds);
    CHECK(n >= 3, "enough atoms to corrupt one in the middle");
    if (n < 3) return;

    /* Atom 2 starts at bounds[1]. Its first byte is the container's field-1
       length-delimited tag, 0x0A; 0x0B is field 1 as a start-group, a wire
       type proto3 does not have, so no number of further bytes makes it an
       atom. */
    size_t bad = bounds[1];
    CHECK(stream[bad] == 0x0Au, "an atom opens with the container tag");
    stream[bad] = 0x0Bu;

    ds_rfcs_reader_t r;
    ds_rfcs_reader_init(&r, stream, len);
    int got = 0;
    ds_result_t res = DS_OK_R;
    for (;;) {
        uint32_t atom = 0;
        const uint8_t *body = NULL;
        size_t blen = 0;
        ds_rfcs_step_t step = DS_RFCS_STEP_END;
        res = ds_rfcs_next_incremental(&r, &atom, &body, &blen, &step);
        if (res.status != DS_OK || step != DS_RFCS_STEP_ATOM) break;
        got++;
    }
    CHECK(res.status == DS_ERR_PARSE, "a malformed frame is an error");
    CHECK(got == 2, "the atoms before it are read");
    CHECK(r.pos == bad, "the reader is left at the malformed atom");

    const ds_schema_t *sc = NULL;
    ds_engine_t *e = new_engine(&sc);
    if (e) {
        ds_rfcs_replay_ctx_t *ctx = NULL;
        CHECK_OK(ds_rfcs_replay_begin(e, NULL, &ctx), "begin");
        if (ctx) {
            ds_result_t fr = ds_rfcs_replay_feed(ctx, stream, len);
            CHECK(fr.status == DS_ERR_PARSE,
                  "the chunked replay refuses it too, and is not lenient about it");
            (void)ds_rfcs_replay_finish(ctx, NULL);
        }
        ds_engine_free(e);
    }
    stream[bad] = 0x0Au;
}

/* Every atom has a message name, and it is the oneof's type. */

static void test_every_atom_names_its_message(void)
{
    for (size_t i = 0; i < DS_ATOM_REGISTRY_COUNT; i++) {
        const ds_atom_reg_entry_t *e = &ds_atom_registry[i];
        CHECK(e->message != NULL && e->message[0] >= 'A' && e->message[0] <= 'Z',
              "every registry entry names a message");
        const char *n = ds_rfcs_message_name(e->number);
        CHECK(n == e->message, "ds_rfcs_message_name reads the registry entry");
    }
    /* Three named from atom.proto's type column, not from the field number's
       old name or the file: ComputationError's body is ComputationError (declared in
       engine_error.proto) and EngineError's is EngineError (engine_fault.proto). */
    const char *fcem = ds_rfcs_message_name(DS_ATOM_FACT_ASSERT);
    const char *eerr = ds_rfcs_message_name(DS_ATOM_COMPUTATION_ERROR);
    const char *engf = ds_rfcs_message_name(DS_ATOM_ENGINE_ERROR);
    CHECK(fcem && strcmp(fcem, "FactAssert") == 0, "FactAssert is FactAssert");
    CHECK(eerr && strcmp(eerr, "ComputationError") == 0, "ComputationError is ComputationError");
    CHECK(engf && strcmp(engf, "EngineError") == 0, "EngineError is EngineError");
    CHECK(ds_rfcs_message_name(999u) == NULL,
          "an unallocated field number has no name");
    CHECK(ds_rfcs_message_name(0u) == NULL, "field number 0 has no name");
}

/* A stream far larger than the atom bound still replays. */

static void test_stream_may_exceed_the_resident_bound(void)
{
    /* The invariant is that the resident set tracks the largest ATOM, not the
       stream. Feeding a stream many times the bound, with the bound set well
       below the total, exercises exactly that: it can only succeed if nothing
       is accumulating the whole stream. */
    static uint8_t stream[16384];
    size_t len = build_stream(stream, sizeof(stream), 200);
    CHECK(len > 4096, "stream is comfortably larger than the bound");
    if (!len) return;

    const ds_schema_t *sc = NULL;
    ds_engine_t *e = new_engine(&sc);
    if (!e) return;

    ds_rfcs_replay_opts_t opts;
    memset(&opts, 0, sizeof(opts));
    opts.max_atom_bytes = 512;          /* >= any single atom, << the stream */

    ds_rfcs_replay_ctx_t *ctx = NULL;
    ds_rfcs_replay_result_t res;
    memset(&res, 0, sizeof(res));
    CHECK_OK(ds_rfcs_replay_begin(e, &opts, &ctx), "begin");
    if (ctx) {
        for (size_t off = 0; off < len; off += 64)
            CHECK_OK(ds_rfcs_replay_feed(ctx, stream + off,
                                         len - off < 64 ? len - off : 64),
                     "feed 64B chunks");
        CHECK_OK(ds_rfcs_replay_finish(ctx, &res), "finish");
        CHECK(res.asserts == 200, "every fact applied");
    }
    ds_engine_free(e);
}

int main(void)
{
    test_byte_at_a_time_equals_all_at_once();
    test_rfcs_19_7__refused_on_declared_length();
    test_rfcs_19_2__chunked_tail_is_eof_at_every_cut();
    test_rfcs_19_2__whole_buffer_refuses_a_partial_tail();
    test_rfcs_19_2__incremental_reader_at_every_cut();
    test_rfcs_19_2__malformed_is_an_error_at_its_offset();
    test_every_atom_names_its_message();
    test_stream_may_exceed_the_resident_bound();

    if (failures) {
        fprintf(stderr, "test_rfcs_chunked: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_rfcs_chunked: OK\n");
    return 0;
}
