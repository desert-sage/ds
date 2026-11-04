/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * test_dsc_basic — impl-side coverage for the DSC loader ([RDSC]).
 *
 * Builds .dsc byte streams by hand with protobuf-c and loads them: framing,
 * the version gate, atom multiplicity, missing-mandatory refusals, the
 * skip-unknown policy, and what a load leaves registered.
 */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"

/* Internal: tests reach into ds_schema_t to verify per-slot
   hydration_eligible, per-schema src_file and the like. */
#include "schema.h"
#include "dsc/loader.h"
#include "test_ds_version.h"  /* [LDET.1.10] ds_test_accepted_version */
/* ds_version_series_len — the LOADER's own splitter, so the same-series test
   below and the check it exercises cannot disagree about where a series ends.
   The DS_LIBDS_VERSION this header also defines is deliberately NOT used; see
   test_ds_version.h. */
#include "version_series.h"

#include "header.pb-c.h"
#include "capabilities.pb-c.h"
#include "common.pb-c.h"
#include "schema_ttl.pb-c.h"
#include "schema_logical.pb-c.h"
#include "slot.pb-c.h"
#include "hydration.pb-c.h"
#include "schema_source.pb-c.h"
#include "schema_def.pb-c.h"
#include "rule_cooldown.pb-c.h"
#include "rule_debug_name.pb-c.h"
#include "rule_source.pb-c.h"
#include "ds_source.pb-c.h"
#include "line_span.pb-c.h"
#include "alfa.pb-c.h"
#include "beta.pb-c.h"
#include "term.pb-c.h"
#include "rete_expr.pb-c.h"

#include "engine.h"  /* for ds_engine internal — read rule_metas in tests */
#include "cache.h"   /* [LSTR.8.5]: a refused seed leaves the cache's key count */
#include "internal/json.h"  /* [LSTR.8.5]: a string no builder would make */
#include "ds_re2.h"  /* ds_re2_available: which build this is, RE2 or the stub */
#include "rete/engine.h"  /* RDSC.3.10 — fault_fact_sites, kept from the header */
/* [RDSC.4c.3] — each node's compiled-code hook, which no load may set */
#include "rete/alpha.h"
#include "rete/beta.h"
#include "rete/terminal.h"
#include "dsc/pbf_writer.h"   /* fixtures frame through the production writer */
#include "dsc/pbf_reader.h"   /* [RDSC.3.6] — seal_dsc finds the header's dsc_sha256 */
#include "rfcs/rfcs.h"        /* the stream header and replay's binding check */
#include "sha256.h"

#define MAGIC_LEN 4

/* ============== Tiny byte-buffer + atom-framing helpers ============== */

typedef struct {
    uint8_t *data;
    size_t   len;
    size_t   cap;
} buf_t;

static void buf_init(buf_t *b) { b->data = NULL; b->len = 0; b->cap = 0; }
static void buf_free(buf_t *b) { free(b->data); b->data = NULL; b->len = 0; b->cap = 0; }

static int buf_append(buf_t *b, const void *src, size_t n)
{
    if (b->len + n > b->cap) {
        size_t newcap = b->cap == 0 ? 64 : b->cap * 2;
        while (newcap < b->len + n) newcap *= 2;
        uint8_t *nb = realloc(b->data, newcap);
        if (nb == NULL) return -1;
        b->data = nb;
        b->cap = newcap;
    }
    memcpy(b->data + b->len, src, n);
    b->len += n;
    return 0;
}

/* Every fixture frames here, naming an atom by its field number
   ([RFCS.16.1]) through the generated DS_ATOM_*. It uses the PRODUCTION
   writer, so a fixture that stops matching the reader is a real
   disagreement; the writer itself is held to PBF_FRAMING_VECTORS.json. */
static int buf_append_frame(buf_t *b, uint32_t field,
                            const uint8_t *body, size_t body_len)
{
    size_t   total = 0;
    uint8_t *frame;
    int      rc;

    if (!ds_pbf_lookup(field)) return -1;   /* not an allocated atom */
    total = ds_pbf_framed_size(field, body_len);
    if (total == 0) return -1;
    frame = malloc(total);
    if (frame == NULL) return -1;
    if (!ds_pbf_frame_atom(field, body, body_len, frame, total, &total)) {
        free(frame);
        return -1;
    }
    rc = buf_append(b, frame, total);
    free(frame);
    return rc;
}

/* `buf_append_frame`, and after a DscHeader an EMPTY CapabilityInfo: nothing enabled, nothing
   required. [RDSC.16.2.4] makes CapabilityInfo required, so every artefact these tests
   build carries one; an empty body is well-formed ([RDSC.16.2.3]) and turns
   on no strategy. A test about CapabilityInfo itself frames with
   `buf_append_frame`. */
static int buf_append_atom(buf_t *b, uint32_t field,
                           const uint8_t *body, size_t body_len)
{
    static const uint8_t empty[1] = { 0 };
    if (buf_append_frame(b, field, body, body_len) != 0) return -1;
    if (field != DS_ATOM_DSC_HEADER) return 0;
    return buf_append_frame(b, DS_ATOM_CAPABILITY_INFO, empty, 0);
}

/*
 * Frame an atom for a field number the registry does NOT know — an atom a
 * LATER runtime would write, with an empty body.
 *
 * The production writer refuses this and should: emitting an atom you cannot
 * name is not something a runtime ought to be able to do. But skip-unknown
 * ([RDSC.9.4] / [RFCS.16.3]) is precisely about reading one, so the bytes are
 * laid out here from [RFCS.19.1]'s grammar — the only place in this file that
 * frames without the registry.
 *
 * Empty body keeps the varints single-byte and the arithmetic visible:
 * outer 0x0A, outer len 3, inner key (field << 3 | 2) in two bytes for any
 * field in 16..2047, inner len 0.
 */
static int buf_append_unknown_atom(buf_t *b, uint32_t field)
{
    uint32_t key = (field << 3) | 2u;
    uint8_t  frame[5];

    if (field < 16u || field > 2047u) return -1;   /* two-byte key range */
    /* Guard the fixture, not the runtime: if this number ever gets allocated
       the test would quietly start exercising a KNOWN atom. */
    if (ds_pbf_lookup(field)) return -1;
    frame[0] = 0x0Au;
    frame[1] = 0x03u;
    frame[2] = (uint8_t)((key & 0x7Fu) | 0x80u);
    frame[3] = (uint8_t)(key >> 7);
    frame[4] = 0x00u;
    return buf_append(b, frame, sizeof frame);
}

/* [RDSC.3.6] — every header this file builds carries `dsc_sha256` as 32 zero
   bytes: PRESENT, because a zeroed field and an absent one hash differently,
   and zero, because that is what the compiler hashes before it seals. */
static uint8_t g_unsealed_sha256[32];

/* Locate the 32 `dsc_sha256` bytes of the artefact's DscHeader: the first
   atom's body, field 7. Returns the offset into `data`, or -1 when there is no
   such field (the malformed inputs the framing tests feed the loader). */
static long dsc_sha256_offset(const uint8_t *data, size_t len)
{
    ds_pbf_atom_t a;
    if (ds_pbf_next_atom(data, len, 0, &a) != DS_PBF_OK) return -1;
    if (a.field != DS_ATOM_DSC_HEADER) return -1;
    size_t pos = 0;
    while (pos < a.body_len) {
        ds_pbf_field_t fld;
        if (ds_pbf_next_field(a.body, a.body_len, pos, &fld) != DS_PBF_OK)
            return -1;
        if (fld.field == 7u && fld.wire == 2u && fld.val_len == 32u)
            return (long)(fld.val - data);
        pos = fld.next;
    }
    return -1;
}

/* SEAL a fixture as the compiler does ([RDSC.3.6]): zero the header's
   `dsc_sha256`, hash the whole artefact, write the digest in. The loader
   refuses an artefact whose hash does not match, so a fixture built by hand
   must be sealed to reach what it tests. A buffer with
   no header field to seal is left as it is. */
static void seal_dsc(buf_t *f)
{
    long off = dsc_sha256_offset(f->data, f->len);
    if (off < 0) return;
    memset(f->data + off, 0, 32);
    uint8_t digest[32];
    ds_sha256(f->data, f->len, digest);
    memcpy(f->data + off, digest, 32);
}

/* Seal, then load: every load in this file goes through here, except the
   [RDSC.3.6] tests below, which load unsealed or tampered bytes on purpose. */
static ds_result_t load_sealed(ds_engine_t *e, buf_t *f)
{
    seal_dsc(f);
    return ds_engine_load_dsc(e, f->data, f->len);
}

/* Forward decls for cross-referenced helpers (the test_srcs_round_trip
   and test_rule_metadata_round_trip scenarios reach into helpers
   defined further down for stage-D atom encoding). */
static int build_dsrc_body(buf_t *out, const char *file,
                           Ds__V1__Compression compression,
                           const uint8_t *data, size_t data_len);

/* The version this runtime accepts — asked of the library, never compiled in.
   See test_ds_version.h for why the macro cannot be used here. */
#define TEST_ACCEPTED_VERSION ds_test_accepted_version()

/* [RDSC.3.7] -- every header carries a `dialect_def_sha256` of 32 bytes, or
   the loader refuses it with DS_ERR_BND_INCOMPLETE before any other atom. So
   every header these tests build carries one; `test_rdsc_3_7__*` is about the
   rule itself. The bytes are arbitrary: only the length is checked at load. */
static uint8_t test_def_sha[33] = {
    0xD5, 0xD5, 0xD5, 0xD5, 0xD5, 0xD5, 0xD5, 0xD5, 0xD5, 0xD5, 0xD5,
    0xD5, 0xD5, 0xD5, 0xD5, 0xD5, 0xD5, 0xD5, 0xD5, 0xD5, 0xD5, 0xD5,
    0xD5, 0xD5, 0xD5, 0xD5, 0xD5, 0xD5, 0xD5, 0xD5, 0xD5, 0xD5, 0xD5,
};

static void set_def_sha(Ds__V1__DscHeader *h, size_t len)
{
    h->dialect_def_sha256.len = len;
    h->dialect_def_sha256.data = len ? test_def_sha : NULL;
}

/* Build a serialized DscHeader stamping a chosen compiler_version. */
static int build_dsco_body_ver(buf_t *out, const char *compiler_version)
{
    Ds__V1__DscHeader h = DS__V1__DSC_HEADER__INIT;
    h.compiler_version = (char *) compiler_version;
    set_def_sha(&h, 32);
    h.dsc_sha256.data = g_unsealed_sha256;
    h.dsc_sha256.len  = sizeof g_unsealed_sha256;
    size_t pl = ds__v1__dsc_header__get_packed_size(&h);
    uint8_t *buf = malloc(pl);
    if (buf == NULL) return -1;
    ds__v1__dsc_header__pack(&h, buf);
    buf_init(out);
    if (buf_append(out, buf, pl) != 0) { free(buf); return -1; }
    free(buf);
    return 0;
}

static int build_dsco_body(buf_t *out)
{
    return build_dsco_body_ver(out, TEST_ACCEPTED_VERSION);
}

/* A DscHeader body with the reserved field 12 (`unicode_version`) appended
   as raw bytes carrying `retired`. Tag 12<<3|2 = 0x62; `retired` is under 128
   bytes, so its length is one byte. */
static int build_dsco_body_retired12(buf_t *out, const char *retired)
{
    if (build_dsco_body_ver(out, TEST_ACCEPTED_VERSION) != 0) return -1;
    size_t n = strlen(retired);
    uint8_t tag[2] = { 0x62, (uint8_t) n };
    if (buf_append(out, tag, sizeof tag) != 0) return -1;
    if (n > 0 && buf_append(out, retired, n) != 0) return -1;
    return 0;
}


/* ============== Scenario helpers ============== */

static int new_engine(ds_engine_t **out)
{
    ds_engine_t *e = NULL;
    ds_result_t r = ds_engine_new(NULL, &e);
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: engine_new: %d %s\n", r.status,
                r.detail ? r.detail : "");
        return 1;
    }
    *out = e;
    return 0;
}

#define EXPECT_LOAD_STATUS(label, r, want)                                   \
    do {                                                                     \
        if ((r).status != (want)) {                                          \
            fprintf(stderr, "FAIL: %s: status=%d (want %d) detail=%s\n",     \
                    (label), (r).status, (want),                             \
                    (r).detail ? (r).detail : "(null)");                     \
            return 1;                                                        \
        }                                                                    \
    } while (0)

/* [RDSC.9.8]: a failed load spends the engine. The latch reads set with no
   fault ([NCBK.2.11]), and a read of engine state, a schema lookup among
   them, is refused ([NCBK.2.9]). Returns the number of failures. */
static int expect_spent(const char *label, ds_engine_t *e)
{
    int fails = 0;
    bool halted = false;
    ds_engine_fault_t fault = DS_ENGINE_FAULT_ARTEFACT_LIED;   /* not 0 */
    ds_result_t hr = ds_engine_halted(e, &halted, &fault);
    if (hr.status != DS_OK || !halted || fault != DS_ENGINE_FAULT_UNSPECIFIED) {
        fprintf(stderr, "FAIL: %s: the failed load did not spend the engine "
                "(status=%d halted=%d fault=%d)\n", label, hr.status,
                (int) halted, (int) fault);
        fails++;
    }
    const ds_schema_t *s = NULL;
    ds_result_t fr = ds_engine_schema_find(e, "S", &s);
    if (fr.status != DS_ERR_ENGINE_HALTED) {
        fprintf(stderr, "FAIL: %s: a schema read on the spent engine is "
                "status %d, not DS_ERR_ENGINE_HALTED\n", label, fr.status);
        fails++;
    }
    return fails;
}

/* ============== Scenarios ============== */

/* RDSC.1.4 — file too short to contain DscHeader atom. */
static int test_truncated_empty(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    ds_result_t r = ds_engine_load_dsc(e, NULL, 0);
    EXPECT_LOAD_STATUS("empty", r, DS_ERR_DSC_TRUNCATED);
    ds_engine_free(e);
    return 0;
}

/* [RFCS.19.1] / [RDSC.1.4] — bytes that are not a valid container.
 *
 * There is ONE answer for everything that is not a major-3 DSC: `D` is a
 * legal first byte of a protobuf stream, so the first byte cannot tell an old
 * artefact from garbage, and no converter exists for one.
 */
static int test_rfcs_19_1__not_a_container_is_refused(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;

    /* What a major-2 artefact looks like: ASCII magic + u32-BE length. Not
       special-cased — 'D' is field 8 / wire type 4, which proto3 does not
       have, so it is refused as "not a container" like anything else. */
    uint8_t legacy[] = { 'D','S','C','O', 0, 0, 0, 0 };
    ds_result_t r = ds_engine_load_dsc(e, legacy, sizeof legacy);
    EXPECT_LOAD_STATUS("major-2 artefact", r, DS_ERR_DSC_BAD_MAGIC);

    /* And arbitrary bytes. Same answer, same reason. On an engine of their
       own: the refusal above spent this one ([RDSC.9.8]). */
    ds_engine_free(e);
    if (new_engine(&e)) return 1;
    uint8_t foreign[] = { 0xFF, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07 };
    r = ds_engine_load_dsc(e, foreign, sizeof foreign);
    EXPECT_LOAD_STATUS("foreign bytes", r, DS_ERR_DSC_BAD_MAGIC);

    ds_engine_free(e);
    return 0;
}

/* [RDSC.11.1]'s Framing and No padding: one row per case the
 * clause codes, each loaded twice, as the artefact's first frame and as a frame
 * after a valid header. The second load is sealed ([RDSC.3.6]) with the bad
 * bytes in place, so the header passes and the walk reaches them.
 *
 *   - a malformed frame is BAD_MAGIC first (not an atom container) and DECODE
 *     later;
 *   - the bytes running out inside a frame are TRUNCATED wherever they do;
 *   - a body that ends early inside a complete frame is DECODE wherever.
 *
 * A trailing 0x00 or 0xFF is a malformed frame, so an artefact padded with
 * either is refused, never loaded up to the padding. The Mercury runtime is
 * held to the same rows (test_ds.m, rdsc_11_1_framing_rows).
 */
/* @spec [RDSC.11.1] */
static int test_rdsc_11_1__framing_table(void)
{
    static const uint8_t outer_tag[]  = { 0x12, 0x00 };
    static const uint8_t zero_pad[]   = { 0x00 };
    static const uint8_t erased_pad[] = { 0xFF };
    static const uint8_t erased_run[] = { 0xFF, 0xFF, 0xFF, 0xFF };
    static const uint8_t inner_wire[] = { 0x0A, 0x02, 0x08, 0x01 };
    static const uint8_t inner_fixed[] = { 0x0A, 0x02, 0x09, 0x00 };
    static const uint8_t eleven[]     = { 0x0A, 0x80, 0x80, 0x80, 0x80, 0x80,
                                          0x80, 0x80, 0x80, 0x80, 0x80 };
    static const uint8_t tenth_high[] = { 0x0A, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                                          0xFF, 0xFF, 0xFF, 0xFF, 0x02 };
    static const uint8_t empty_atom[] = { 0x0A, 0x00 };
    static const uint8_t wide_field[] = { 0x0A, 0x06, 0x82, 0x80, 0x80, 0x80,
                                          0x80, 0x01 };
    /* An inner field number in no band ([RFCS.16.3]): 2048, key 16386
       = 82 80 01, with an empty body; and 0, key 0x02. */
    static const uint8_t field_2048[] = { 0x0A, 0x04, 0x82, 0x80, 0x01, 0x00 };
    static const uint8_t field_0[]    = { 0x0A, 0x02, 0x02, 0x00 };
    static const uint8_t mid_length[] = { 0x0A, 0x80 };
    static const uint8_t long_frame[] = { 0x0A, 0x05, 0xBA, 0x10 };
    static const uint8_t past_bound[] = { 0x0A, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F,
                                          0xBA };
    static const uint8_t short_body[] = { 0x0A, 0x03, 0xBA, 0x10, 0x05 };
    static const uint8_t short_tag[]  = { 0x0A, 0x01, 0xBA };
    static const struct {
        const char    *what;
        const uint8_t *bytes;
        size_t         len;
        int            first;
        int            later;
    } rows[] = {
        { "an outer tag that is not 0x0A", outer_tag, sizeof outer_tag,
          DS_ERR_DSC_BAD_MAGIC, DS_ERR_DSC_DECODE },
        { "a 0x00 (zero padding)", zero_pad, sizeof zero_pad,
          DS_ERR_DSC_BAD_MAGIC, DS_ERR_DSC_DECODE },
        { "a 0xFF (erased padding)", erased_pad, sizeof erased_pad,
          DS_ERR_DSC_BAD_MAGIC, DS_ERR_DSC_DECODE },
        { "a run of 0xFF (erased padding)", erased_run, sizeof erased_run,
          DS_ERR_DSC_BAD_MAGIC, DS_ERR_DSC_DECODE },
        { "an inner tag that is not length-delimited", inner_wire,
          sizeof inner_wire, DS_ERR_DSC_BAD_MAGIC, DS_ERR_DSC_DECODE },
        { "an inner fixed64 tag, its value cut short", inner_fixed,
          sizeof inner_fixed, DS_ERR_DSC_BAD_MAGIC, DS_ERR_DSC_DECODE },
        { "a varint past ten bytes", eleven, sizeof eleven,
          DS_ERR_DSC_BAD_MAGIC, DS_ERR_DSC_DECODE },
        { "a tenth varint byte past bit 63", tenth_high, sizeof tenth_high,
          DS_ERR_DSC_BAD_MAGIC, DS_ERR_DSC_DECODE },
        { "an Atom with no oneof member", empty_atom, sizeof empty_atom,
          DS_ERR_DSC_BAD_MAGIC, DS_ERR_DSC_DECODE },
        { "a field number past 2^32", wide_field, sizeof wide_field,
          DS_ERR_DSC_BAD_MAGIC, DS_ERR_DSC_DECODE },
        { "an inner field number past every band (2048)", field_2048,
          sizeof field_2048, DS_ERR_DSC_BAD_MAGIC, DS_ERR_DSC_DECODE },
        { "an inner field number of 0", field_0, sizeof field_0,
          DS_ERR_DSC_BAD_MAGIC, DS_ERR_DSC_DECODE },
        { "bytes that run out inside a length", mid_length, sizeof mid_length,
          DS_ERR_DSC_TRUNCATED, DS_ERR_DSC_TRUNCATED },
        { "a length longer than the bytes that remain", long_frame,
          sizeof long_frame, DS_ERR_DSC_TRUNCATED, DS_ERR_DSC_TRUNCATED },
        { "a length past 2^31", past_bound, sizeof past_bound,
          DS_ERR_DSC_TRUNCATED, DS_ERR_DSC_TRUNCATED },
        { "a body that ends early inside its frame", short_body,
          sizeof short_body, DS_ERR_DSC_DECODE, DS_ERR_DSC_DECODE },
        { "an Atom's tag cut short inside its frame", short_tag,
          sizeof short_tag, DS_ERR_DSC_DECODE, DS_ERR_DSC_DECODE },
    };
    int fails = 0;
    for (size_t i = 0; i < sizeof rows / sizeof rows[0]; i++) {
        ds_engine_t *e = NULL;
        if (new_engine(&e)) return 1;
        ds_result_t r = ds_engine_load_dsc(e, rows[i].bytes, rows[i].len);
        if (r.status != rows[i].first) {
            fprintf(stderr, "FAIL: [RDSC.11.1] first frame, %s: status=%d "
                    "(want %d) detail=%s\n", rows[i].what, r.status,
                    rows[i].first, r.detail ? r.detail : "(null)");
            fails++;
        }
        ds_engine_free(e);

        if (new_engine(&e)) return 1;
        buf_t hb, f;
        if (build_dsco_body(&hb) != 0) return 1;
        buf_init(&f);
        if (buf_append_atom(&f, DS_ATOM_DSC_HEADER, hb.data, hb.len) != 0
            || buf_append(&f, rows[i].bytes, rows[i].len) != 0) return 1;
        r = load_sealed(e, &f);
        if (r.status != rows[i].later) {
            fprintf(stderr, "FAIL: [RDSC.11.1] after a header, %s: status=%d "
                    "(want %d) detail=%s\n", rows[i].what, r.status,
                    rows[i].later, r.detail ? r.detail : "(null)");
            fails++;
        }
        buf_free(&hb);
        buf_free(&f);
        ds_engine_free(e);
    }
    return fails ? 1 : 0;
}

/* [LDET.1.10] — an artefact from another DS minor series is refused.
 *
 * THE PROBE DERIVES FROM THE RUNTIME'S OWN VERSION, never a literal: "9"
 * prefixed onto this build's version is in no series this runtime can be,
 * whatever the release.
 */
static int test_ldet_1_10__other_series_rejected(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t hb;
    char other[80];
    snprintf(other, sizeof other, "9%s", TEST_ACCEPTED_VERSION);
    if (build_dsco_body_ver(&hb, other) != 0) return 1;
    buf_t f; buf_init(&f);
    if (buf_append_atom(&f, DS_ATOM_DSC_HEADER,hb.data, hb.len) != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("other minor series", r, DS_ERR_DSC_VERSION);
    buf_free(&hb); buf_free(&f);
    ds_engine_free(e);
    return 0;
}

/* An UNSTAMPED artefact is refused, not waved through. proto3 has no presence
   for a scalar string, so an absent `compiler_version` and an empty one are
   the same bytes — and an artefact recording no version sits in no series.
   The accept-all reading is the dangerous one, which is why it is pinned. */
static int test_ldet_1_10__empty_version_rejected(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t hb;
    if (build_dsco_body_ver(&hb, "") != 0) return 1;
    buf_t f; buf_init(&f);
    if (buf_append_atom(&f, DS_ATOM_DSC_HEADER,hb.data, hb.len) != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("empty compiler_version", r, DS_ERR_DSC_VERSION);
    buf_free(&hb); buf_free(&f);
    ds_engine_free(e);
    return 0;
}


/* Header field 12 (`unicode_version`) is reserved: the compiler version
   implies the Unicode pin ([LNAM.2.2.5]), and the version gate holds it
   ([LDET.1.10]). An artefact carrying it loads whatever it says, the field
   skipped as unknown. The Mercury runtime's test_ds.m pins the same three
   ("a reserved field 12 loads whatever it holds"). */
static int test_reserved_field_12_loads_whatever_it_holds(void)
{
    static const char *const held[] = { "16.0.0", "17.0.0", "" };
    for (size_t i = 0; i < sizeof held / sizeof held[0]; i++) {
        ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
        buf_t hb; if (build_dsco_body_retired12(&hb, held[i]) != 0) return 1;
        buf_t f; buf_init(&f);
        if (buf_append_atom(&f, DS_ATOM_DSC_HEADER, hb.data, hb.len) != 0) return 1;
        ds_result_t r = load_sealed(e, &f);
        EXPECT_LOAD_STATUS(held[i][0] ? held[i] : "empty field 12", r, DS_OK);
        buf_free(&hb); buf_free(&f); ds_engine_free(e);
    }
    return 0;
}


/* RDSC.3.10 — `DscHeader.fault_fact_sites` (field 14) reaches the engine. The
   pool it sizes is allocated later, once the capabilities are known
   ([LERR.9.10]); this pins only that the count is read and kept. A non-zero
   value, so a loader that never reads the field fails rather than agreeing on
   the default; and an absent field, which must read as 0. */
static int test_rdsc_3_10__fault_fact_sites_kept(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    Ds__V1__DscHeader h = DS__V1__DSC_HEADER__INIT;
    h.compiler_version = (char *) TEST_ACCEPTED_VERSION;
    set_def_sha(&h, 32);
    h.fault_fact_sites = 7u;
    h.dsc_sha256.data = g_unsealed_sha256;
    h.dsc_sha256.len  = sizeof g_unsealed_sha256;
    size_t pl = ds__v1__dsc_header__get_packed_size(&h);
    uint8_t *hb = malloc(pl);
    if (hb == NULL) return 1;
    ds__v1__dsc_header__pack(&h, hb);
    buf_t f; buf_init(&f);
    if (buf_append_atom(&f, DS_ATOM_DSC_HEADER,hb, pl) != 0) return 1;
    free(hb);
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("fault_fact_sites=7", r, DS_OK);
    if (e->rete_engine == NULL || e->rete_engine->fault_fact_sites != 7u) {
        fprintf(stderr, "FAIL: fault_fact_sites=7 did not reach the engine\n");
        return 1;
    }
    buf_free(&f); ds_engine_free(e);

    ds_engine_t *e2 = NULL; if (new_engine(&e2)) return 1;
    buf_t hb2; if (build_dsco_body(&hb2) != 0) return 1;
    buf_t f2; buf_init(&f2);
    if (buf_append_atom(&f2, DS_ATOM_DSC_HEADER,hb2.data, hb2.len) != 0) return 1;
    ds_result_t r2 = load_sealed(e2, &f2);
    EXPECT_LOAD_STATUS("fault_fact_sites absent", r2, DS_OK);
    if (e2->rete_engine == NULL || e2->rete_engine->fault_fact_sites != 0u) {
        fprintf(stderr, "FAIL: an absent fault_fact_sites did not read as 0\n");
        return 1;
    }
    buf_free(&hb2); buf_free(&f2); ds_engine_free(e2);
    return 0;
}

/* Load a header whose `dialect_def_sha256` is `def_len` bytes (0: absent),
   stamped `version`, plus the empty CapabilityInfo every artefact carries. */
static ds_status_t load_def_sha_header(const char *version, size_t def_len)
{
    ds_engine_t *e = NULL;
    if (new_engine(&e)) return DS_ERR_OOM;
    Ds__V1__DscHeader h = DS__V1__DSC_HEADER__INIT;
    h.compiler_version = (char *) version;
    set_def_sha(&h, def_len);
    /* [RDSC.3.6]: the field the seal below writes. The 32-byte case has to
       load, so it has to be sealed; the -703 cases are refused before the
       self-hash is checked, so sealing them too changes nothing they test. */
    h.dsc_sha256.data = g_unsealed_sha256;
    h.dsc_sha256.len  = sizeof g_unsealed_sha256;
    size_t pl = ds__v1__dsc_header__get_packed_size(&h);
    uint8_t *hb = malloc(pl);
    if (hb == NULL) { ds_engine_free(e); return DS_ERR_OOM; }
    ds__v1__dsc_header__pack(&h, hb);
    buf_t f; buf_init(&f);
    ds_status_t st = DS_ERR_OOM;
    if (buf_append_atom(&f, DS_ATOM_DSC_HEADER,hb, pl) == 0)
        st = load_sealed(e, &f).status;
    free(hb); buf_free(&f); ds_engine_free(e);
    return st;
}

/* [RDSC.3.7] -- "A file whose `dialect_def_sha256` is not 32 bytes is rejected
   with `DS_ERR_BND_INCOMPLETE`." 32 loads; 31, 33 and absent are -703. The
   Mercury runtime pins the same cases in test_ds.m, so both answer alike. */
static int test_rdsc_3_7__def_sha_must_be_32_bytes(void)
{
    static const struct { size_t len; ds_status_t want; const char *what; }
    cases[] = {
        { 32, DS_OK,                 "32 bytes loads" },
        { 31, DS_ERR_BND_INCOMPLETE, "31 bytes is -703" },
        { 33, DS_ERR_BND_INCOMPLETE, "33 bytes is -703" },
        {  0, DS_ERR_BND_INCOMPLETE, "absent is -703" },
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        ds_status_t st = load_def_sha_header(TEST_ACCEPTED_VERSION, cases[i].len);
        if (st != cases[i].want) {
            fprintf(stderr, "FAIL: RDSC.3.7 %s: status=%d (want %d)\n",
                    cases[i].what, (int) st, (int) cases[i].want);
            return 1;
        }
    }
    /* The version is verified first ([RDSC.9.2]): a header wrong in both
       ways cites the version. */
    ds_status_t st = load_def_sha_header("9.9.9", 31);
    if (st != DS_ERR_DSC_VERSION) {
        fprintf(stderr, "FAIL: RDSC.3.7 bad version + 31 bytes: status=%d "
                "(want %d)\n", (int) st, (int) DS_ERR_DSC_VERSION);
        return 1;
    }
    return 0;
}

/* [LDET.1.10] — THE SAME SERIES, A DIFFERENT PATCH, ACCEPTED. Without this
   case the two refusals above pass against a loader that refuses
   everything. */
static int test_ldet_1_10__same_series_other_patch_ok(void)
{
    /* Rebuild this build's version with the patch component replaced, by
       taking the accepted series prefix and appending a component no release
       would carry. `ds_version_series_len` is the loader's own splitter, so
       the two cannot disagree about where the series ends. */
    const size_t n = ds_version_series_len(TEST_ACCEPTED_VERSION);
    if (n == 0u) {
        fprintf(stderr, "FAIL: TEST_ACCEPTED_VERSION %s carries no "
                "<major>.<minor>. prefix\n", TEST_ACCEPTED_VERSION);
        return 1;
    }
    char probe[128];
    if (n + 8u >= sizeof(probe)) return 1;
    memcpy(probe, TEST_ACCEPTED_VERSION, n);
    memcpy(probe + n, "99999", 6);

    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t hb;
    if (build_dsco_body_ver(&hb, probe) != 0) return 1;
    buf_t f; buf_init(&f);
    if (buf_append_atom(&f, DS_ATOM_DSC_HEADER,hb.data, hb.len) != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("same series, other patch", r, DS_OK);
    buf_free(&hb); buf_free(&f);
    ds_engine_free(e);
    return 0;
}

/* ============== CapabilityInfo — [RDSC.16.2] ============== */

/* Load DscHeader, then a CapabilityInfo carrying `enabled` / `requires` as given (or no CapabilityInfo
   when `with_capb` is 0), then `extra_capb` more empty CapabilityInfo atoms. */
static ds_result_t load_with_capb(int with_capb,
                                  const int *enabled, size_t n_enabled,
                                  const int *requires_, size_t n_requires,
                                  int extra_capb)
{
    static const uint8_t empty[1] = { 0 };
    Ds__V1__Capability en[8], rq[8];
    ds_result_t r = { DS_ERR_INVAL, "test fixture failed to build" };
    ds_engine_t *e = NULL;
    buf_t hb, f, cb;

    if (n_enabled > 8 || n_requires > 8) return r;
    if (new_engine(&e)) return r;
    if (build_dsco_body(&hb) != 0) { ds_engine_free(e); return r; }
    buf_init(&f); buf_init(&cb);
    if (buf_append_frame(&f, DS_ATOM_DSC_HEADER,hb.data, hb.len) != 0) goto out;
    if (with_capb) {
        Ds__V1__CapabilityInfo m = DS__V1__CAPABILITY_INFO__INIT;
        for (size_t i = 0; i < n_enabled; i++) en[i] = (Ds__V1__Capability) enabled[i];
        for (size_t i = 0; i < n_requires; i++) rq[i] = (Ds__V1__Capability) requires_[i];
        m.n_enabled = n_enabled;   m.enabled = en;
        m.n_requires = n_requires; m.requires = rq;
        size_t pl = ds__v1__capability_info__get_packed_size(&m);
        uint8_t *body = malloc(pl == 0 ? 1 : pl);
        if (body == NULL) goto out;
        ds__v1__capability_info__pack(&m, body);
        int rc = buf_append_frame(&f, DS_ATOM_CAPABILITY_INFO,body, pl);
        free(body);
        if (rc != 0) goto out;
    }
    for (int i = 0; i < extra_capb; i++)
        if (buf_append_frame(&f, DS_ATOM_CAPABILITY_INFO,empty, 0) != 0) goto out;
    r = load_sealed(e, &f);
    /* The detail lives in the engine's buffer, which dies with the engine
       below, so the caller gets a copy. */
    {
        static char detail[256];
        snprintf(detail, sizeof detail, "%s", r.detail ? r.detail : "");
        r.detail = detail;
    }
out:
    buf_free(&hb); buf_free(&f); buf_free(&cb);
    ds_engine_free(e);
    return r;
}

static int test_rdsc_16_2__capb(void)
{
    static const int logical_call[] = { 4, 8 };
    static const int call_logical[] = { 8, 4 };
    static const int repeated[]     = { 4, 4 };
    static const int unspecified[]  = { 0, 4 };
    /* dynamic_ttl, which every build has. A capability that is
       requires-but-not-enabled is a shape refusal (-504) only in a build that
       has the capability: the build's capabilities are checked first, so a
       build without it answers -514 (the case below). */
    static const int dynamic_ttl[]  = { 5 };
    static const int unknown[]      = { 4, 99 };
    static const int unknown_rq[]   = { 99 };
    static const int two_unknown[]  = { 98, 99 };

    EXPECT_LOAD_STATUS("[RDSC.16.2.4] no CapabilityInfo",
        load_with_capb(0, NULL, 0, NULL, 0, 0), DS_ERR_DSC_SEMANTIC);
    /* A second CapabilityInfo is not checked for ([RDSC.16.2.5],
       [RDSC.7.2]): it is read as the first was. */
    EXPECT_LOAD_STATUS("[RDSC.16.2.5] a second CapabilityInfo is not checked",
        load_with_capb(1, NULL, 0, NULL, 0, 1), DS_OK);
    EXPECT_LOAD_STATUS("[RDSC.16.2.2] settings load",
        load_with_capb(1, logical_call, 2, logical_call, 1, 0), DS_OK);
    EXPECT_LOAD_STATUS("[RDSC.16.2.3] out of order",
        load_with_capb(1, call_logical, 2, NULL, 0, 0), DS_ERR_DSC_SEMANTIC);
    EXPECT_LOAD_STATUS("[RDSC.16.2.3] repeated",
        load_with_capb(1, repeated, 2, NULL, 0, 0), DS_ERR_DSC_SEMANTIC);
    EXPECT_LOAD_STATUS("[RDSC.16.2.3] unspecified",
        load_with_capb(1, unspecified, 2, NULL, 0, 0), DS_ERR_DSC_SEMANTIC);
    EXPECT_LOAD_STATUS("[RDSC.16.2.3] requires outside enabled",
        load_with_capb(1, logical_call, 2, dynamic_ttl, 1, 0),
        DS_ERR_DSC_SEMANTIC);
    /* A number this build does not know is a capability it lacks, and the
       build's capabilities are checked before the shape (the Mercury runtime
       agrees): 99 required and not enabled still answers -514. */
    EXPECT_LOAD_STATUS("[RDSC.16.2.7] unknown required capability",
        load_with_capb(1, unknown, 2, unknown_rq, 1, 0),
        DS_ERR_DSC_CAPABILITY_ABSENT);
    /* 12 is reserved in proto/capabilities.proto, so it is a number this
       build does not know: inside the range, and still absent. */
    static const int reserved_12[] = { 12 };
    ds_result_t r12 = load_with_capb(1, reserved_12, 1, reserved_12, 1, 0);
    EXPECT_LOAD_STATUS("[RDSC.16.2.7] the reserved 12 required", r12,
                       DS_ERR_DSC_CAPABILITY_ABSENT);
    if (r12.detail == NULL || strstr(r12.detail, "capability 12 ") == NULL) {
        fprintf(stderr, "FAIL: [RDSC.16.2.7] names 12: %s\n",
                r12.detail ? r12.detail : "(null)");
        return 1;
    }
    /* 17 to 19 are reserved too: inside the range, absent, and the lowest of
       the three is the one named. */
    static const int reserved_17_19[] = { 17, 18, 19 };
    ds_result_t r17 = load_with_capb(1, reserved_17_19, 3, reserved_17_19, 3, 0);
    EXPECT_LOAD_STATUS("[RDSC.16.2.7] the reserved 17 to 19 required", r17,
                       DS_ERR_DSC_CAPABILITY_ABSENT);
    if (r17.detail == NULL || strstr(r17.detail, "capability 17 ") == NULL) {
        fprintf(stderr, "FAIL: [RDSC.16.2.7] names 17: %s\n",
                r17.detail ? r17.detail : "(null)");
        return 1;
    }
    /* 20 is `storage_hydrate_facts`, a member, so an artefact naming it
       loads. */
    static const int hydrate_facts[] = { 8, DS_CAPABILITY_STORAGE_HYDRATE_FACTS };
    EXPECT_LOAD_STATUS("[LCAP.1] 20 is storage_hydrate_facts, still a member",
        load_with_capb(1, hydrate_facts, 2, NULL, 0, 0), DS_OK);
    ds_result_t two = load_with_capb(1, two_unknown, 2, two_unknown, 2, 0);
    EXPECT_LOAD_STATUS("[RDSC.16.2.7] two lacking", two,
                       DS_ERR_DSC_CAPABILITY_ABSENT);
    if (two.detail == NULL || strstr(two.detail, "capability 98 ") == NULL) {
        fprintf(stderr, "FAIL: [RDSC.16.2.7] the lowest is named: %s\n",
                two.detail ? two.detail : "(null)");
        return 1;
    }
    return 0;
}

/* Load DscHeader + a CapabilityInfo enabling `enabled` and requiring `requires_` into an
   engine whose policy for `cap` is `admit`. */
static ds_result_t load_admitted(ds_capability_t cap, ds_admission_t admit,
                                 const int *enabled, size_t n_enabled,
                                 const int *requires_, size_t n_requires)
{
    Ds__V1__Capability en[8], rq[8];
    ds_result_t r = { DS_ERR_INVAL, "test fixture failed to build" };
    ds_engine_t *e = NULL;
    buf_t hb, f;

    if (n_enabled > 8 || n_requires > 8) return r;
    if (new_engine(&e)) return r;
    r = ds_engine_set_admission(e, cap, admit);
    if (r.status != DS_OK) { ds_engine_free(e); return r; }
    r = (ds_result_t){ DS_ERR_INVAL, "test fixture failed to build" };
    if (build_dsco_body(&hb) != 0) { ds_engine_free(e); return r; }
    buf_init(&f);
    Ds__V1__CapabilityInfo m = DS__V1__CAPABILITY_INFO__INIT;
    for (size_t i = 0; i < n_enabled; i++) en[i] = (Ds__V1__Capability) enabled[i];
    for (size_t i = 0; i < n_requires; i++) rq[i] = (Ds__V1__Capability) requires_[i];
    m.n_enabled = n_enabled;   m.enabled = en;
    m.n_requires = n_requires; m.requires = rq;
    size_t pl = ds__v1__capability_info__get_packed_size(&m);
    uint8_t *body = malloc(pl == 0 ? 1 : pl);
    if (body != NULL
        && (ds__v1__capability_info__pack(&m, body), 1)
        && buf_append_frame(&f, DS_ATOM_DSC_HEADER,hb.data, hb.len) == 0
        && buf_append_frame(&f, DS_ATOM_CAPABILITY_INFO,body, pl) == 0) {
        r = load_sealed(e, &f);
        static char detail[256];
        snprintf(detail, sizeof detail, "%s", r.detail ? r.detail : "");
        r.detail = detail;
    }
    free(body);
    buf_free(&hb); buf_free(&f);
    ds_engine_free(e);
    return r;
}

/* [NLFC.10.2] — the admission policy, and its place in [RDSC.16.2.9]'s order. */
static int test_nlfc_10_2__admission(void)
{
    static const int logical_call[] = { 4, 8 };
    static const int logical[]      = { 4 };
    static const int unknown[]      = { 4, 99 };
    static const int unknown_rq[]   = { 99 };

    EXPECT_LOAD_STATUS("[NLFC.10.2] call true, admitted either way",
        load_admitted(DS_CAPABILITY_CALL, DS_ADMIT_EITHER,
                      logical_call, 2, NULL, 0), DS_OK);
    EXPECT_LOAD_STATUS("[NLFC.10.2] call true, admitted true only",
        load_admitted(DS_CAPABILITY_CALL, DS_ADMIT_TRUE_ONLY,
                      logical_call, 2, NULL, 0), DS_OK);
    ds_result_t r = load_admitted(DS_CAPABILITY_CALL, DS_ADMIT_FALSE_ONLY,
                                  logical_call, 2, NULL, 0);
    EXPECT_LOAD_STATUS("[NLFC.10.2] call true, admitted false only", r,
                       DS_ERR_BND_DIALECT_MISMATCH);
    if (strstr(r.detail, "capability 8 set true") == NULL) {
        fprintf(stderr, "FAIL: [NLFC.10.2] the refusal names the capability: %s\n",
                r.detail);
        return 1;
    }
    EXPECT_LOAD_STATUS("[NLFC.10.2] call false, admitted true only",
        load_admitted(DS_CAPABILITY_CALL, DS_ADMIT_TRUE_ONLY,
                      logical, 1, NULL, 0), DS_ERR_BND_DIALECT_MISMATCH);
    /* [RDSC.16.2.9] — the build's capabilities come first: a policy the
       artefact also breaks does not hide the physical refusal. */
    EXPECT_LOAD_STATUS("[RDSC.16.2.9] absent before policy",
        load_admitted(DS_CAPABILITY_LOGICAL, DS_ADMIT_FALSE_ONLY,
                      unknown, 2, unknown_rq, 1), DS_ERR_DSC_CAPABILITY_ABSENT);
    EXPECT_LOAD_STATUS("[NLFC.10.2] not a capability",
        load_admitted((ds_capability_t) 0, DS_ADMIT_TRUE_ONLY, NULL, 0, NULL, 0),
        DS_ERR_INVAL);
    EXPECT_LOAD_STATUS("[NLFC.10.2] not an admission",
        load_admitted(DS_CAPABILITY_CALL, (ds_admission_t) 7, NULL, 0, NULL, 0),
        DS_ERR_INVAL);
    return 0;
}

/* Defined with the stage-B scenarios below. */
static int build_slog_body(buf_t *out, const char *schema);
static int build_slot_body(buf_t *out, const char *schema, const char *slot,
                           Ds__V1__SlotKind kind, const char *schema_ref);
static int frame_into(buf_t *out, uint32_t field, const buf_t *body);

/* Load DscHeader, a CapabilityInfo enabling `cache_delete` (11) and requiring it iff
   `requires_it`, and a one-rule network whose terminal does `cache_delete`. */
static ds_result_t load_cache_delete_rule(int requires_it)
{
    ds_result_t fail = DS_ERR_R(DS_ERR_INVAL, "test fixture did not build");
    ds_engine_t *e = NULL;
    if (new_engine(&e)) return fail;

    buf_t hb, f, capb_b, slog_b, slot_b, alfa_b, beta_b, term_b;
    buf_t atoms[6];
    if (build_dsco_body(&hb) != 0) return fail;
    if (build_slog_body(&slog_b, "S") != 0) return fail;
    if (build_slot_body(&slot_b, "S", "v",
                        DS__V1__SLOT_KIND__SLOT_KIND_INT, NULL) != 0) return fail;

    Ds__V1__Capability en[1] = { DS__V1__CAPABILITY__CAPABILITY_CACHE_DELETE };
    Ds__V1__CapabilityInfo c = DS__V1__CAPABILITY_INFO__INIT;
    c.n_enabled = 1;  c.enabled = en;
    if (requires_it) { c.n_requires = 1; c.requires = en; }

    Ds__V1__Expr key = DS__V1__EXPR__INIT;
    key.kind_case = DS__V1__EXPR__KIND_LIT_STR;
    key.lit_str = (char *) "k";
    Ds__V1__Expr *args[1] = { &key };
    Ds__V1__CallExpr call = DS__V1__CALL_EXPR__INIT;
    call.op = DS__V1__BUILTIN_FN__FN_CACHE_DELETE;
    call.n_args = 1;  call.args = args;
    Ds__V1__Expr ce = DS__V1__EXPR__INIT;
    ce.kind_case = DS__V1__EXPR__KIND_CALL;
    ce.call = &call;
    Ds__V1__Action act = DS__V1__ACTION__INIT;
    act.kind = DS__V1__ACTION_KIND__ACTION_CALL;
    act.expr = &ce;
    Ds__V1__Action *acts[1] = { &act };

    Ds__V1__AlphaNode a = DS__V1__ALPHA_NODE__INIT;
    a.node_id = 1;
    a.schema_name = (char *) "S";
    Ds__V1__BetaNode b = DS__V1__BETA_NODE__INIT;
    b.node_id = 2;
    b.right_alpha_id = 1;
    b.left_parent_id = 0;
    Ds__V1__TerminalNode t = DS__V1__TERMINAL_NODE__INIT;
    t.node_id = 3;
    t.parent_beta_id = 2;
    t.rule_name = (char *) "r";
    t.n_actions = 1;  t.actions = acts;

    uint8_t pk[512];
    if (ds__v1__terminal_node__get_packed_size(&t) > sizeof pk
        || ds__v1__capability_info__get_packed_size(&c) > sizeof pk)
        return fail;
    buf_init(&capb_b);
    buf_append(&capb_b, pk, ds__v1__capability_info__pack(&c, pk));
    buf_init(&alfa_b);
    buf_append(&alfa_b, pk, ds__v1__alpha_node__pack(&a, pk));
    buf_init(&beta_b);
    buf_append(&beta_b, pk, ds__v1__beta_node__pack(&b, pk));
    buf_init(&term_b);
    buf_append(&term_b, pk, ds__v1__terminal_node__pack(&t, pk));

    /* DscHeader and CapabilityInfo through buf_append_frame: buf_append_atom would add an
       empty CapabilityInfo of its own after the header. */
    buf_init(&f);
    if (buf_append_frame(&f, DS_ATOM_DSC_HEADER,hb.data, hb.len) != 0) return fail;
    if (buf_append_frame(&f, DS_ATOM_CAPABILITY_INFO,capb_b.data, capb_b.len) != 0) return fail;
    if (frame_into(&atoms[0], DS_ATOM_SCHEMA_LOGICAL,&slog_b) != 0) return fail;
    if (frame_into(&atoms[1], DS_ATOM_SLOT,&slot_b) != 0) return fail;
    if (frame_into(&atoms[2], DS_ATOM_ALPHA_NODE,&alfa_b) != 0) return fail;
    if (frame_into(&atoms[3], DS_ATOM_BETA_NODE,&beta_b) != 0) return fail;
    if (frame_into(&atoms[4], DS_ATOM_TERMINAL_NODE,&term_b) != 0) return fail;
    for (int i = 0; i < 5; i++)
        if (buf_append(&f, atoms[i].data, atoms[i].len) != 0) return fail;

    ds_result_t r = load_sealed(e, &f);
    static char detail[256];
    snprintf(detail, sizeof detail, "%s", r.detail ? r.detail : "");
    r.detail = detail;

    for (int i = 0; i < 5; i++) buf_free(&atoms[i]);
    buf_free(&hb); buf_free(&f); buf_free(&capb_b); buf_free(&slog_b);
    buf_free(&slot_b); buf_free(&alfa_b); buf_free(&beta_b); buf_free(&term_b);
    ds_engine_free(e);
    return r;
}

/* [RDSC.16.2.8] — `requires` is TRUSTED: the loader compares it only
   against its build ([RDSC.16.2.7]), never against what the content uses. A network using `cache_delete` loads whether or not
   `requires` names it. */
static int test_rdsc_16_2_8__requires_is_trusted(void)
{
    EXPECT_LOAD_STATUS("[RDSC.16.2.8] cache_delete required, and used",
        load_cache_delete_rule(1), DS_OK);
    EXPECT_LOAD_STATUS("[RDSC.16.2.8] cache_delete used, not required: loads",
        load_cache_delete_rule(0), DS_OK);
    return 0;
}

/* [NLFC.10.1] — the build's capabilities: ascending, the size query agrees
   with the fill, and every capability present but `regex` on a build that
   links the RE2 stub instead of RE2.

   ONE TEST FOR BOTH BUILDS. The default lanes link RE2; the MSan lane builds
   `-D re2=stub` and runs this file too, and there the second half is
   [RDSC.16.2.7]'s case for a real missing capability: an artefact requiring
   `regex` fails its load with DS_ERR_DSC_CAPABILITY_ABSENT, naming 6. */
static int test_nlfc_10_1__build_capabilities(void)
{
    static const int regex_[] = { 6 };
    const bool have_re2 = ds_re2_available();
    /* 1..21 less the reserved 12 and 17 to 19, and less `regex` on the
       stub. */
    const size_t want = have_re2 ? 17 : 16;
    ds_capability_t caps[32];
    size_t n = ds_build_capabilities(NULL, 0);
    if (n != want) {
        fprintf(stderr, "FAIL: [NLFC.10.1] %zu capabilities, want %zu\n", n, want);
        return 1;
    }
    if (ds_build_capabilities(caps, 32) != n) {
        fprintf(stderr, "FAIL: [NLFC.10.1] the size query and the fill differ\n");
        return 1;
    }
    for (size_t i = 0, c = 1; i < n; i++, c++) {
        if (!have_re2 && c == DS_CAPABILITY_REGEX) c++;
        if (c == 12) c++;
        if (c == 17) c = 20;
        if (caps[i] != (ds_capability_t) c) {
            fprintf(stderr, "FAIL: [NLFC.10.1] caps[%zu] = %d, want %zu\n",
                    i, (int) caps[i], c);
            return 1;
        }
    }
    /* A short array is filled as far as it goes, and the total still told. */
    if (ds_build_capabilities(caps, 2) != n || caps[1] != DS_CAPABILITY_CONSTSPACE) {
        fprintf(stderr, "FAIL: [NLFC.10.1] a short array\n");
        return 1;
    }
    ds_result_t r = load_with_capb(1, regex_, 1, regex_, 1, 0);
    if (have_re2) {
        EXPECT_LOAD_STATUS("[RDSC.16.2.7] regex required, RE2 linked", r, DS_OK);
    } else {
        EXPECT_LOAD_STATUS("[RDSC.16.2.7] regex required, the stub linked", r,
                           DS_ERR_DSC_CAPABILITY_ABSENT);
        if (strstr(r.detail, "capability 6 ") == NULL) {
            fprintf(stderr, "FAIL: [RDSC.16.2.7] names regex: %s\n", r.detail);
            return 1;
        }
    }
    return 0;
}

/* [RDSC.9.7] — a truncated .dsc ERRORS.
 *
 * `ds_pbf_next_atom` reports a partial trailing atom as EOF, as a STREAM
 * needs ([RFCS.19.2]): a recording is appended to while it is read. A .dsc is
 * a finished artefact, so the same EOF is a truncated bundle and the loader
 * refuses it. A tolerated truncation would be what the session header's
 * `dsc_hash` names, and every stream bound to it ([RFCS.4.7]) would verify
 * against a ruleset nobody wrote. The refusal comes before the self-hash
 * check ([RDSC.3.6]) and names the truncation.
 *
 * Hand-built: the production writer cannot produce a truncation.
 */
static int test_rdsc_9_7__truncated_body_errors(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    /* A major-3 DscHeader frame whose outer length claims 103 bytes of Atom and
       supplies 7:  0A 67 | BA 10 64 | 'X' 'X' 'X' 'X'
                    ^outer  ^DscHeader=263, inner len 100
       The outer length is satisfied by nothing, so the parser reaches EOF with
       bytes remaining — which for a DSC is truncation, not end-of-container. */
    uint8_t f[] = { 0x0A, 0x67, 0xBA, 0x10, 0x64, 'X','X','X','X' };
    ds_result_t r = ds_engine_load_dsc(e, f, sizeof f);
    EXPECT_LOAD_STATUS("body trunc", r, DS_ERR_DSC_TRUNCATED);
    ds_engine_free(e);
    return 0;
}

/* RDSC.9.4 — an unknown atom after a valid DscHeader is skipped: the load
   succeeds rather than erroring as DSC_BAD_MAGIC / DSC_DECODE. */
static int test_unknown_magic_is_skipped(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t hb; if (build_dsco_body(&hb) != 0) return 1;
    buf_t f; buf_init(&f);
    if (buf_append_atom(&f, DS_ATOM_DSC_HEADER,hb.data, hb.len) != 0) return 1;
    /* An atom from a LATER runtime, in the SKIP band ([RFCS.16.2],
       256..2047), so skipping is the right answer. */
    if (buf_append_unknown_atom(&f, 2000u) != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("skip unknown", r, DS_OK);
    buf_free(&hb); buf_free(&f);
    ds_engine_free(e);
    return 0;
}

/* ============== Stage B helpers — schema-atom encoders ============== */

static int build_sttl_body(buf_t *out, const char *schema, uint64_t ttl_ns)
{
    Ds__V1__SchemaTtl m = DS__V1__SCHEMA_TTL__INIT;
    m.schema_name = (char *) schema;
    m.ttl_ns = ttl_ns;
    size_t pl = ds__v1__schema_ttl__get_packed_size(&m);
    uint8_t *b = malloc(pl); if (!b) return -1;
    ds__v1__schema_ttl__pack(&m, b);
    buf_init(out);
    if (buf_append(out, b, pl) != 0) { free(b); return -1; }
    free(b);
    return 0;
}

/* RDSC.5.4.5 -- the SchemaLogical atom carries the declared lifecycle, and
   UNSPECIFIED is refused, so every fixture here says which. */
static int build_slog_body_lc(buf_t *out, const char *schema,
                              Ds__V1__SchemaLifecycle lifecycle)
{
    Ds__V1__SchemaLogical m = DS__V1__SCHEMA_LOGICAL__INIT;
    m.schema_name = (char *) schema;
    m.lifecycle   = lifecycle;
    size_t pl = ds__v1__schema_logical__get_packed_size(&m);
    uint8_t *b = malloc(pl); if (!b) return -1;
    ds__v1__schema_logical__pack(&m, b);
    buf_init(out);
    if (buf_append(out, b, pl) != 0) { free(b); return -1; }
    free(b);
    return 0;
}

/* The common case: a bare `schema Foo:`, EXPLICIT ([LSCP.1.4]), whose slots
   carry no identity role -- which is what build_slot_body writes. */
static int build_slog_body(buf_t *out, const char *schema)
{
    return build_slog_body_lc(out, schema,
                              DS__V1__SCHEMA_LIFECYCLE__SCHEMA_LIFECYCLE_EXPLICIT);
}

static int build_slot_body_role(buf_t *out, const char *schema, const char *slot,
                                Ds__V1__SlotKind kind, const char *schema_ref,
                                Ds__V1__IdentityRole role)
{
    Ds__V1__Slot m = DS__V1__SLOT__INIT;
    m.schema_name = (char *) schema;
    m.slot_name = (char *) slot;
    m.kind = kind;
    m.identity_role = role;
    m.schema_ref = (char *) (schema_ref != NULL ? schema_ref : "");
    size_t pl = ds__v1__slot__get_packed_size(&m);
    uint8_t *b = malloc(pl); if (!b) return -1;
    ds__v1__slot__pack(&m, b);
    buf_init(out);
    if (buf_append(out, b, pl) != 0) { free(b); return -1; }
    free(b);
    return 0;
}

/* An unmarked slot: the shape every non-logical schema's slots take
   ([RDSC.5.5.7]). */
static int build_slot_body(buf_t *out, const char *schema, const char *slot,
                           Ds__V1__SlotKind kind, const char *schema_ref)
{
    return build_slot_body_role(out, schema, slot, kind, schema_ref,
                                DS__V1__IDENTITY_ROLE__IDENTITY_ROLE_UNSPECIFIED);
}

static int build_hydr_body(buf_t *out, const char *schema, const char *slot)
{
    Ds__V1__Hydration m = DS__V1__HYDRATION__INIT;
    m.schema_name = (char *) schema;
    m.slot_name = (char *) slot;
    size_t pl = ds__v1__hydration__get_packed_size(&m);
    uint8_t *b = malloc(pl); if (!b) return -1;
    ds__v1__hydration__pack(&m, b);
    buf_init(out);
    if (buf_append(out, b, pl) != 0) { free(b); return -1; }
    free(b);
    return 0;
}

static int build_srcs_body(buf_t *out, const char *schema, const char *file,
                           uint32_t line, uint32_t col)
{
    /* `file` is unused: SchemaSource carries no path, and the runtime
       resolves the display path via DsSource[module_id].file. */
    (void) file;
    Ds__V1__SchemaSource m = DS__V1__SCHEMA_SOURCE__INIT;
    m.schema_name = (char *) schema;
    m.line = line;
    m.col  = col;
    size_t pl = ds__v1__schema_source__get_packed_size(&m);
    uint8_t *b = malloc(pl); if (!b) return -1;
    ds__v1__schema_source__pack(&m, b);
    buf_init(out);
    if (buf_append(out, b, pl) != 0) { free(b); return -1; }
    free(b);
    return 0;
}

static int build_sdef_body(buf_t *out, const char *schema,
                           Ds__V1__Compression compression,
                           const uint8_t *proto, size_t proto_len)
{
    Ds__V1__SchemaDef m = DS__V1__SCHEMA_DEF__INIT;
    m.schema_name = (char *) schema;
    m.compression = compression;
    m.proto_source.data = (uint8_t *) proto;
    m.proto_source.len  = proto_len;
    size_t pl = ds__v1__schema_def__get_packed_size(&m);
    uint8_t *b = malloc(pl); if (!b) return -1;
    ds__v1__schema_def__pack(&m, b);
    buf_init(out);
    if (buf_append(out, b, pl) != 0) { free(b); return -1; }
    free(b);
    return 0;
}

/* Build a complete file: DscHeader + extra_framed[], each a framed atom.
   `clips_text` is unused. */
static int build_file_with_atoms(buf_t *f,
                                  const buf_t *extra_framed,
                                  size_t n_extra,
                                  const char *clips_text)
{
    (void) clips_text;
    buf_init(f);
    buf_t hb;
    if (build_dsco_body(&hb) != 0) return -1;
    if (buf_append_atom(f, DS_ATOM_DSC_HEADER,hb.data, hb.len) != 0) { buf_free(&hb); return -1; }
    buf_free(&hb);
    for (size_t i = 0; i < n_extra; i++) {
        if (buf_append(f, extra_framed[i].data, extra_framed[i].len) != 0) return -1;
    }
    return 0;
}

/* Wraps a body buffer as a framed atom. Reuses buf_append_atom. */
static int frame_into(buf_t *out, uint32_t field, const buf_t *body)
{
    buf_init(out);
    return buf_append_atom(out, field, body->data, body->len);
}

/* ============== Stage B scenarios ============== */

/* RDSC.5 — DscHeader + SchemaTtl + Slot registers a TTL schema queryable via
 * ds_engine_schema_find. */
static int test_schema_load_ttl(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t sttl_b, slot_b;
    if (build_sttl_body(&sttl_b, "MySchema", 5000) != 0) return 1;
    if (build_slot_body(&slot_b, "MySchema", "v",
                        DS__V1__SLOT_KIND__SLOT_KIND_INT, NULL) != 0) return 1;
    buf_t atoms[2];
    if (frame_into(&atoms[0], DS_ATOM_SCHEMA_TTL,&sttl_b) != 0) return 1;
    if (frame_into(&atoms[1], DS_ATOM_SLOT,&slot_b) != 0) return 1;
    buf_t f;
    if (build_file_with_atoms(&f, atoms, 2, "(deftemplate MySchema (slot v))") != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("ttl schema", r, DS_OK);
    const ds_schema_t *s = NULL;
    r = ds_engine_schema_find(e, "MySchema", &s);
    EXPECT_LOAD_STATUS("schema_find", r, DS_OK);
    if (s == NULL) {
        fprintf(stderr, "FAIL: schema not registered\n"); return 1;
    }
    buf_free(&sttl_b); buf_free(&slot_b);
    buf_free(&atoms[0]); buf_free(&atoms[1]); buf_free(&f);
    ds_engine_free(e);
    return 0;
}

/* DscHeader + SchemaLogical(LOGICAL) + a role-marked Slot registers a LOGICAL
   schema. The slot carries MUTABLE because a logical schema marks every slot
   ([LFAC.1.7.4]) and the loader holds the atom's lifecycle to the roles
   (RDSC.5.4.5). */
static int test_schema_load_logical(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t slog_b, slot_b;
    if (build_slog_body_lc(&slog_b, "Lg",
            DS__V1__SCHEMA_LIFECYCLE__SCHEMA_LIFECYCLE_LOGICAL) != 0) return 1;
    if (build_slot_body_role(&slot_b, "Lg", "v",
            DS__V1__SLOT_KIND__SLOT_KIND_STRING, NULL,
            DS__V1__IDENTITY_ROLE__IDENTITY_ROLE_MUTABLE) != 0) return 1;
    buf_t atoms[2];
    if (frame_into(&atoms[0], DS_ATOM_SCHEMA_LOGICAL,&slog_b) != 0) return 1;
    if (frame_into(&atoms[1], DS_ATOM_SLOT,&slot_b) != 0) return 1;
    buf_t f;
    if (build_file_with_atoms(&f, atoms, 2, "(deftemplate Lg (slot v))") != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("logical schema", r, DS_OK);
    buf_free(&slog_b); buf_free(&slot_b);
    buf_free(&atoms[0]); buf_free(&atoms[1]); buf_free(&f);
    ds_engine_free(e);
    return 0;
}

/* One SchemaLogical + one Slot, loaded; the status is the test. Shared by the
   RDSC.5.4.5 cases below, which differ only in the lifecycle the atom says
   and the role the slot carries. */
static int load_slog_slot(const char *label,
                          Ds__V1__SchemaLifecycle lifecycle, bool with_field,
                          Ds__V1__IdentityRole role, int want)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t slog_b, slot_b;
    if (with_field) {
        if (build_slog_body_lc(&slog_b, "A", lifecycle) != 0) return 1;
    } else {
        /* UNSPECIFIED is proto3's zero: the field is omitted. */
        if (build_slog_body_lc(&slog_b, "A",
                DS__V1__SCHEMA_LIFECYCLE__SCHEMA_LIFECYCLE_UNSPECIFIED) != 0)
            return 1;
    }
    if (build_slot_body_role(&slot_b, "A", "v",
            DS__V1__SLOT_KIND__SLOT_KIND_INT, NULL, role) != 0) return 1;
    buf_t atoms[2];
    if (frame_into(&atoms[0], DS_ATOM_SCHEMA_LOGICAL,&slog_b) != 0) return 1;
    if (frame_into(&atoms[1], DS_ATOM_SLOT,&slot_b) != 0) return 1;
    buf_t f;
    if (build_file_with_atoms(&f, atoms, 2, "(deftemplate A (slot v))") != 0) return 1;
    /* SEALED, so the refusal under test is RDSC.5.4.5's: an unsealed file is
       refused by the self-hash check ([RDSC.3.6]) with the same -504, which
       would let the two refusal cases pass without reaching the lifecycle. */
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS(label, r, want);
    buf_free(&slog_b); buf_free(&slot_b);
    buf_free(&atoms[0]); buf_free(&atoms[1]); buf_free(&f);
    ds_engine_free(e);
    return 0;
}

/* RDSC.5.4.5 -- a SchemaLogical whose lifecycle is UNSPECIFIED, the zero
   proto3 omits, is refused. */
static int test_rdsc_5_4_5__slog_without_lifecycle_refused(void)
{
    return load_slog_slot("SchemaLogical without lifecycle",
        DS__V1__SCHEMA_LIFECYCLE__SCHEMA_LIFECYCLE_UNSPECIFIED, false,
        DS__V1__IDENTITY_ROLE__IDENTITY_ROLE_UNSPECIFIED, DS_ERR_DSC_SEMANTIC);
}

/* RDSC.5.4.5 -- ACTIVATION over an unmarked slot agrees and loads, as its
   own scope. */
static int test_rdsc_5_4_5__activation_loads(void)
{
    return load_slog_slot("ACTIVATION over an unmarked slot",
        DS__V1__SCHEMA_LIFECYCLE__SCHEMA_LIFECYCLE_ACTIVATION, true,
        DS__V1__IDENTITY_ROLE__IDENTITY_ROLE_UNSPECIFIED, DS_OK);
}

/* NDBG.2.2 / LSCP.2.6.2 — a built-in fault schema enumerates with the
 * lifecycle INTERNAL; an author schema beside it keeps LOGICAL; and an
 * integrator cannot register an INTERNAL schema. The artefact carries the
 * built-in as a plain explicit schema (a SchemaLogical with no identity role), so
 * the name is what the loader marks it by. */
static int test_ndbg_2_2__builtin_schema_is_internal(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t te_slog, te_slot, lg_slog, lg_slot;
    if (build_slog_body(&te_slog, "TypeError") != 0) return 1;
    if (build_slot_body(&te_slot, "TypeError", "actual",
                        DS__V1__SLOT_KIND__SLOT_KIND_STRING, NULL) != 0) return 1;
    if (build_slog_body(&lg_slog, "Lg") != 0) return 1;
    if (build_slot_body(&lg_slot, "Lg", "v",
                        DS__V1__SLOT_KIND__SLOT_KIND_STRING, NULL) != 0) return 1;
    buf_t atoms[4];
    if (frame_into(&atoms[0], DS_ATOM_SCHEMA_LOGICAL,&te_slog) != 0) return 1;
    if (frame_into(&atoms[1], DS_ATOM_SLOT,&te_slot) != 0) return 1;
    if (frame_into(&atoms[2], DS_ATOM_SCHEMA_LOGICAL,&lg_slog) != 0) return 1;
    if (frame_into(&atoms[3], DS_ATOM_SLOT,&lg_slot) != 0) return 1;
    buf_t f;
    if (build_file_with_atoms(&f, atoms, 4,
            "(deftemplate TypeError (slot actual)) (deftemplate Lg (slot v))") != 0)
        return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("builtin + author schema", r, DS_OK);

    const ds_schema_t *te = NULL, *lg = NULL;
    ds_schema_lifecycle_t lc = DS_SCHEMA_LIFECYCLE_TTL;
    r = ds_engine_schema_find(e, "TypeError", &te);
    EXPECT_LOAD_STATUS("find TypeError", r, DS_OK);
    r = ds_schema_get_lifecycle(te, &lc);
    EXPECT_LOAD_STATUS("lifecycle TypeError", r, DS_OK);
    if (lc != DS_SCHEMA_LIFECYCLE_INTERNAL) {
        fprintf(stderr, "FAIL: TypeError reported lifecycle %d, want INTERNAL\n",
                (int) lc);
        return 1;
    }
    r = ds_engine_schema_find(e, "Lg", &lg);
    EXPECT_LOAD_STATUS("find Lg", r, DS_OK);
    r = ds_schema_get_lifecycle(lg, &lc);
    EXPECT_LOAD_STATUS("lifecycle Lg", r, DS_OK);
    if (lc != DS_SCHEMA_LIFECYCLE_LOGICAL) {
        fprintf(stderr, "FAIL: Lg reported lifecycle %d, want LOGICAL\n", (int) lc);
        return 1;
    }

    ds_engine_t *e2 = NULL; if (new_engine(&e2)) return 1;
    ds_slot_desc_t slot = { .name = "v", .type = DS_SLOT_TYPE_STRING };
    r = ds_engine_register_schema(e2, "Mine", DS_SCHEMA_LIFECYCLE_INTERNAL, 0,
                                  &slot, 1, NULL);
    if (r.status != DS_ERR_INVAL) {
        fprintf(stderr, "FAIL: registering an INTERNAL schema gave %d, want %d\n",
                (int) r.status, (int) DS_ERR_INVAL);
        return 1;
    }

    buf_free(&te_slog); buf_free(&te_slot); buf_free(&lg_slog); buf_free(&lg_slot);
    for (int i = 0; i < 4; i++) buf_free(&atoms[i]);
    buf_free(&f);
    ds_engine_free(e);
    ds_engine_free(e2);
    return 0;
}

/* ============== [LSTR.8.5] host text is well-formed UTF-8 ============== */

/* RFC 3629's five ways for bytes to be no UTF-8, and four well-formed strings
   at the 2-, 3- and 4-byte lengths and the last code point. */
static const struct { const char *label; const char *bytes; } lstr_8_5_ill[] = {
    { "an overlong form",          "\xC0\xAF" },
    { "a surrogate",               "\xED\xA0\x80" },
    { "a code point past U+10FFFF", "\xF4\x90\x80\x80" },
    { "a sequence cut short",      "\xE2\x82" },
    { "a stray continuation byte", "\x80" },
};
static const char *const lstr_8_5_ok[] = {
    "\xC3\xA9", "\xE2\x82\xAC", "\xF0\x9F\x98\x80", "\xF4\x8F\xBF\xBF",
};
#define LSTR_8_5_N_ILL (sizeof lstr_8_5_ill / sizeof lstr_8_5_ill[0])
#define LSTR_8_5_N_OK  (sizeof lstr_8_5_ok / sizeof lstr_8_5_ok[0])

/* A Json string the builders could not make: "ab" made, then its two bytes
   overwritten with an overlong form (white-box, as test_json_basic.c's
   within_limits test sets a counter). The assert and the seed do not assume
   where a tree came from, and this is the tree that shows they do not. */
static ds_json_t *lstr_8_5_poked_tree(void)
{
    ds_json_t *s = NULL;
    if (ds_json_new_string("ab", 2, &s).status != DS_OK) return NULL;
    char *p = (char *) s->v.s;
    p[0] = '\xC0';
    p[1] = '\xAF';
    return s;
}

/* [LSTR.8.5] — text a host hands the engine is
   well-formed UTF-8, or the call is refused with DS_ERR_ENCODING and changes
   nothing. ds_engine_assert: a String slot of each malformed class, and a Json
   slot holding one; ds_engine_cache_seed: a key of each class, and a value
   holding one. Each refusal leaves working memory and the cache as they were;
   valid multibyte text, U+10FFFF included, is admitted at both. The Mercury
   runtime is held to the same cases (test_ds.m, test_lstr_8_5_host_text). */
static int test_lstr_8_5__assert_and_seed_refuse_ill_formed_utf8(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t slog, slot_v, slot_j;
    if (build_slog_body(&slog, "Lg") != 0) return 1;
    if (build_slot_body(&slot_v, "Lg", "v",
                        DS__V1__SLOT_KIND__SLOT_KIND_STRING, NULL) != 0) return 1;
    if (build_slot_body(&slot_j, "Lg", "j",
                        DS__V1__SLOT_KIND__SLOT_KIND_JSON, NULL) != 0) return 1;
    buf_t atoms[3];
    if (frame_into(&atoms[0], DS_ATOM_SCHEMA_LOGICAL, &slog) != 0) return 1;
    if (frame_into(&atoms[1], DS_ATOM_SLOT, &slot_v) != 0) return 1;
    if (frame_into(&atoms[2], DS_ATOM_SLOT, &slot_j) != 0) return 1;
    buf_t f;
    if (build_file_with_atoms(&f, atoms, 3,
                              "(deftemplate Lg (slot v) (slot j))") != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("[LSTR.8.5] load Lg", r, DS_OK);
    const ds_schema_t *lg = NULL;
    r = ds_engine_schema_find(e, "Lg", &lg);
    EXPECT_LOAD_STATUS("[LSTR.8.5] find Lg", r, DS_OK);

    ds_json_t *one = NULL;
    if (ds_json_new_int(1, &one).status != DS_OK) return 1;
    size_t n = 0;
    char label[96];

    /* A String slot of each malformed class: refused, nothing asserted. */
    for (size_t c = 0; c < LSTR_8_5_N_ILL; c++) {
        ds_slot_value_t vals[2] = {
            { .kind = DS_SLOT_STRING, .v.s = lstr_8_5_ill[c].bytes },
            { .kind = DS_SLOT_JSON,   .v.json = one },
        };
        ds_fact_t *fact = (ds_fact_t *) 1;
        r = ds_engine_assert(e, lg, vals, 2, &fact);
        snprintf(label, sizeof label, "[LSTR.8.5] a String slot holding %s",
                 lstr_8_5_ill[c].label);
        EXPECT_LOAD_STATUS(label, r, DS_ERR_ENCODING);
        if (fact != NULL || ds_engine_fact_count(e, &n).status != DS_OK || n != 0) {
            fprintf(stderr, "FAIL: %s: the refused assert changed working "
                    "memory\n", label);
            return 1;
        }
    }

    /* A Json slot holding a string no builder would make: refused too. */
    ds_json_t *poked = lstr_8_5_poked_tree();
    if (poked == NULL) return 1;
    {
        ds_slot_value_t vals[2] = {
            { .kind = DS_SLOT_STRING, .v.s = "x" },
            { .kind = DS_SLOT_JSON,   .v.json = poked },
        };
        ds_fact_t *fact = NULL;
        r = ds_engine_assert(e, lg, vals, 2, &fact);
        EXPECT_LOAD_STATUS("[LSTR.8.5] a Json slot holding an overlong form", r,
                           DS_ERR_ENCODING);
        if (ds_engine_fact_count(e, &n).status != DS_OK || n != 0) {
            fprintf(stderr, "FAIL: [LSTR.8.5] the refused Json assert changed "
                    "working memory\n");
            return 1;
        }
    }

    /* The cache seed: a key of each class, then a value holding one. */
    for (size_t c = 0; c < LSTR_8_5_N_ILL; c++) {
        r = ds_engine_cache_seed(e, lstr_8_5_ill[c].bytes, one,
                                 DS_CACHE_TTL_NONE);
        snprintf(label, sizeof label, "[LSTR.8.5] a cache seed key holding %s",
                 lstr_8_5_ill[c].label);
        EXPECT_LOAD_STATUS(label, r, DS_ERR_ENCODING);
    }
    r = ds_engine_cache_seed(e, "k", poked, DS_CACHE_TTL_NONE);
    EXPECT_LOAD_STATUS("[LSTR.8.5] a cache seed value holding an overlong form",
                       r, DS_ERR_ENCODING);
    if (ds_cache_key_count(&e->cache) != 0) {
        fprintf(stderr, "FAIL: [LSTR.8.5] a refused seed changed the cache\n");
        return 1;
    }

    /* Valid multibyte text is admitted at both doors: the seeds first, since a
       seed after the engine's first stream event is refused ([NLFC.9.1]), and
       that every refusal above emitted none is why these are still in the
       window. */
    for (size_t c = 0; c < LSTR_8_5_N_OK; c++) {
        r = ds_engine_cache_seed(e, lstr_8_5_ok[c], one, DS_CACHE_TTL_NONE);
        EXPECT_LOAD_STATUS("[LSTR.8.5] a well-formed seed key", r, DS_OK);
    }
    if (ds_cache_key_count(&e->cache) != LSTR_8_5_N_OK) {
        fprintf(stderr, "FAIL: [LSTR.8.5] the well-formed seeds are not all "
                "held\n");
        return 1;
    }
    for (size_t c = 0; c < LSTR_8_5_N_OK; c++) {
        ds_slot_value_t vals[2] = {
            { .kind = DS_SLOT_STRING, .v.s = lstr_8_5_ok[c] },
            { .kind = DS_SLOT_JSON,   .v.json = one },
        };
        ds_fact_t *fact = NULL;
        r = ds_engine_assert(e, lg, vals, 2, &fact);
        EXPECT_LOAD_STATUS("[LSTR.8.5] a well-formed String slot", r, DS_OK);
    }
    if (ds_engine_fact_count(e, &n).status != DS_OK || n != LSTR_8_5_N_OK) {
        fprintf(stderr, "FAIL: [LSTR.8.5] %zu facts after the well-formed "
                "asserts, want %zu\n", n, (size_t) LSTR_8_5_N_OK);
        return 1;
    }

    ds_json_free(poked);
    ds_json_free(one);
    buf_free(&slog); buf_free(&slot_v); buf_free(&slot_j);
    for (int i = 0; i < 3; i++) buf_free(&atoms[i]);
    buf_free(&f);
    ds_engine_free(e);
    return 0;
}

/* ============== [NDBG.2.4] services ============== */

/* A ServiceDef body, written field by field from proto/service_def.proto: the
   loader walks it with its own PBF reader and the generated decoder for it is
   not on this test's include path, so the bytes are laid out here. */
static int pb_varint(buf_t *b, uint64_t v)
{
    uint8_t tmp[10];
    size_t  n = 0;
    do {
        uint8_t byte = (uint8_t)(v & 0x7Fu);
        v >>= 7;
        tmp[n++] = (uint8_t)(byte | (v ? 0x80u : 0u));
    } while (v);
    return buf_append(b, tmp, n);
}

static int pb_bytes(buf_t *b, uint32_t field, const void *p, size_t n)
{
    if (pb_varint(b, ((uint64_t) field << 3) | 2u) != 0) return -1;
    if (pb_varint(b, n) != 0) return -1;
    return n ? buf_append(b, p, n) : 0;
}

static int pb_str(buf_t *b, uint32_t field, const char *s)
{
    return pb_bytes(b, field, s, strlen(s));
}

static int pb_bool(buf_t *b, uint32_t field, bool v)
{
    if (!v) return 0;                 /* proto3 omits a false bool */
    if (pb_varint(b, (uint64_t) field << 3) != 0) return -1;
    return pb_varint(b, 1u);
}

/* One ServiceKwarg (ds_type 1, name 2, required 3, is_literal 4,
   has_default 5, default_value 6), appended to `svc` as field 2. */
static int svcd_kwarg(buf_t *svc, const char *name, const char *ds_type,
                      bool required, bool literal, const char *dflt)
{
    buf_t k; buf_init(&k);
    int rc = pb_str(&k, 1, ds_type) || pb_str(&k, 2, name)
          || pb_bool(&k, 3, required) || pb_bool(&k, 4, literal)
          || pb_bool(&k, 5, dflt != NULL)
          || (dflt != NULL && pb_str(&k, 6, dflt))
          || pb_bytes(svc, 2, k.data, k.len);
    buf_free(&k);
    return rc ? -1 : 0;
}

static int str_eq(const char *a, const char *b)
{
    return a != NULL && b != NULL && strcmp(a, b) == 0;
}

/* [NDBG.2.4] — the services the loaded program declares, one view per
 * ServiceDef, read back field for field: name, response (empty for `no
 * response`), the `no response` flag exactly when declared, and the kwargs in
 * the artefact's order (by name, [LGRA.23.2]) with type, `required`,
 * `literal` and the default's text ([RDSC.6a.2.4]: `3` for an Int, `"ops"`
 * for a String). `_at` past the count is DS_ERR_NOT_FOUND; `_find` hits by
 * name and reports a miss with DS_OK; a clone gives the same view. PATH
 * PINNED: dsc/loader.c `handle_svcd` keeps the fields, and engine.c
 * `ds_engine_service_*` read them. */
static int test_ndbg_2_4__services_read_back(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;

    /* alert.page: `response Ack`, three kwargs in name order. */
    buf_t a; buf_init(&a);
    if (pb_str(&a, 1, "alert.page") != 0) return 1;
    if (svcd_kwarg(&a, "level", "Int", false, false, "3") != 0) return 1;
    if (svcd_kwarg(&a, "msg", "String", true, false, NULL) != 0) return 1;
    if (svcd_kwarg(&a, "target", "String", false, true, "\"ops\"") != 0) return 1;
    if (pb_str(&a, 3, "Ack") != 0) return 1;

    /* log.write: `no response`, one required kwarg. */
    buf_t w; buf_init(&w);
    if (pb_str(&w, 1, "log.write") != 0) return 1;
    if (svcd_kwarg(&w, "line", "String", true, false, NULL) != 0) return 1;
    if (pb_bool(&w, 5, true) != 0) return 1;

    buf_t atoms[2];
    if (frame_into(&atoms[0], DS_ATOM_SERVICE_DEF, &a) != 0) return 1;
    if (frame_into(&atoms[1], DS_ATOM_SERVICE_DEF, &w) != 0) return 1;
    buf_t f;
    if (build_file_with_atoms(&f, atoms, 2, "") != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("two services", r, DS_OK);

    int fails = 0;
#define NDBG_CHECK(cond, what)                                                \
    do { if (!(cond)) { fprintf(stderr, "FAIL: [NDBG.2.4] %s\n", (what));    \
                        fails++; } } while (0)

    size_t n = 0;
    r = ds_engine_service_count(e, &n);
    NDBG_CHECK(r.status == DS_OK && n == 2, "two services counted");

    ds_service_view_t v;
    memset(&v, 0, sizeof v);
    r = ds_engine_service_at(e, 0, &v);
    NDBG_CHECK(r.status == DS_OK, "_at(0)");
    NDBG_CHECK(str_eq(v.name, "alert.page"), "_at(0) is the first ServiceDef");
    NDBG_CHECK(str_eq(v.response, "Ack"), "alert.page answers with Ack");
    NDBG_CHECK(!v.no_response, "alert.page does not declare `no response`");
    NDBG_CHECK(v.kwarg_count == 3 && v.kwargs != NULL, "alert.page has three kwargs");
    if (v.kwarg_count == 3 && v.kwargs != NULL) {
        const ds_service_kwarg_view_t *k = v.kwargs;
        NDBG_CHECK(str_eq(k[0].name, "level") && str_eq(k[1].name, "msg")
                   && str_eq(k[2].name, "target"), "kwargs in the artefact's order");
        NDBG_CHECK(str_eq(k[0].ds_type, "Int") && str_eq(k[1].ds_type, "String")
                   && str_eq(k[2].ds_type, "String"), "each kwarg's declared type");
        NDBG_CHECK(!k[0].required && k[1].required && !k[2].required, "`required`");
        NDBG_CHECK(!k[0].is_literal && !k[1].is_literal && k[2].is_literal, "`literal`");
        NDBG_CHECK(k[0].has_default && str_eq(k[0].default_text, "3"),
                   "an Int default's text");
        NDBG_CHECK(!k[1].has_default && str_eq(k[1].default_text, ""),
                   "no default: empty text");
        NDBG_CHECK(k[2].has_default && str_eq(k[2].default_text, "\"ops\""),
                   "a String default's text");
    }

    memset(&v, 0, sizeof v);
    r = ds_engine_service_at(e, 1, &v);
    NDBG_CHECK(r.status == DS_OK && str_eq(v.name, "log.write"), "_at(1)");
    NDBG_CHECK(str_eq(v.response, ""), "a `no response` service has no response schema");
    NDBG_CHECK(v.no_response, "log.write declares `no response`");
    NDBG_CHECK(v.kwarg_count == 1 && v.kwargs != NULL
               && str_eq(v.kwargs[0].name, "line") && v.kwargs[0].required,
               "log.write's one required kwarg");

    r = ds_engine_service_at(e, 2, &v);
    NDBG_CHECK(r.status == DS_ERR_NOT_FOUND, "_at(count) is DS_ERR_NOT_FOUND");

    bool found = false;
    memset(&v, 0, sizeof v);
    r = ds_engine_service_find(e, "log.write", &v, &found);
    NDBG_CHECK(r.status == DS_OK && found && v.no_response, "_find hits by name");
    found = true;
    r = ds_engine_service_find(e, "nope", &v, &found);
    NDBG_CHECK(r.status == DS_OK && !found, "_find(\"nope\"): DS_OK, not found");

    /* A clone owns its own copy of the table and gives the same view. */
    ds_engine_t *c = NULL;
    r = ds_engine_clone(e, &c);
    NDBG_CHECK(r.status == DS_OK && c != NULL, "clone");
    if (c != NULL) {
        memset(&v, 0, sizeof v);
        r = ds_engine_service_at(c, 0, &v);
        NDBG_CHECK(r.status == DS_OK && str_eq(v.name, "alert.page")
                   && v.kwarg_count == 3 && v.kwargs != NULL
                   && str_eq(v.kwargs[2].default_text, "\"ops\"")
                   && v.kwargs[2].is_literal,
                   "a clone's view is the source's");
        ds_engine_free(c);
    }
#undef NDBG_CHECK

    buf_free(&a); buf_free(&w);
    for (int i = 0; i < 2; i++) buf_free(&atoms[i]);
    buf_free(&f);
    ds_engine_free(e);
    return fails;
}

/* Load DscHeader + one ServiceDef with body `svc`; the load's status. */
static ds_status_t load_one_svcd(buf_t *svc, ds_engine_t **out_e)
{
    ds_engine_t *e = NULL;
    if (new_engine(&e)) return DS_ERR_OOM;
    buf_t atom, f;
    if (frame_into(&atom, DS_ATOM_SERVICE_DEF, svc) != 0) return DS_ERR_OOM;
    if (build_file_with_atoms(&f, &atom, 1, "") != 0) return DS_ERR_OOM;
    ds_result_t r = load_sealed(e, &f);
    buf_free(&atom); buf_free(&f);
    *out_e = e;
    return r.status;
}

/* [NDBG.2.4] / [RDSC.11.1] — the cases no compiler writes, held as the Mercury
 * runtime's test_svcd_kwargs holds them, so the two runtimes load the same
 * artefacts and read them the same way:
 *   - a `default_value` beside a false `has_default` is no default, its text
 *     ignored ([RDSC.6a.2.4]: "empty when `has_default` is false");
 *   - `has_default` with no text is a default the artefact does not state:
 *     has_default set, the text empty;
 *   - a kwarg body that does not decode, and a kwargs field that is not a
 *     message, fail the atom's protobuf decode: DS_ERR_DSC_DECODE. */
static int test_ndbg_2_4__kwargs_edge_cases(void)
{
    int fails = 0;
    ds_engine_t *e = NULL;
    ds_service_view_t v;

    buf_t stray; buf_init(&stray);
    if (pb_str(&stray, 1, "probe.stray") != 0) return 1;
    {   /* has_default left false, default_value "7" */
        buf_t k; buf_init(&k);
        if (pb_str(&k, 1, "Int") || pb_str(&k, 2, "x") || pb_str(&k, 6, "7")
            || pb_bytes(&stray, 2, k.data, k.len)) return 1;
        buf_free(&k);
    }
    if (load_one_svcd(&stray, &e) != DS_OK) {
        fprintf(stderr, "FAIL: [NDBG.2.4] a stray default_value does not load\n");
        fails++;
    } else if (ds_engine_service_at(e, 0, &v).status != DS_OK || v.kwarg_count != 1
               || v.kwargs[0].has_default || !str_eq(v.kwargs[0].default_text, "")) {
        fprintf(stderr, "FAIL: [NDBG.2.4] a default_value without has_default "
                        "is no default\n");
        fails++;
    }
    ds_engine_free(e); e = NULL;
    buf_free(&stray);

    buf_t unstated; buf_init(&unstated);
    if (pb_str(&unstated, 1, "probe.unstated") != 0) return 1;
    {   /* has_default true, no default_value */
        buf_t k; buf_init(&k);
        if (pb_str(&k, 1, "celsius") || pb_str(&k, 2, "t") || pb_bool(&k, 5, true)
            || pb_bytes(&unstated, 2, k.data, k.len)) return 1;
        buf_free(&k);
    }
    if (load_one_svcd(&unstated, &e) != DS_OK
        || ds_engine_service_at(e, 0, &v).status != DS_OK || v.kwarg_count != 1
        || !v.kwargs[0].has_default || !str_eq(v.kwargs[0].default_text, "")) {
        fprintf(stderr, "FAIL: [NDBG.2.4] has_default with no text: set, text empty\n");
        fails++;
    }
    ds_engine_free(e); e = NULL;
    buf_free(&unstated);

    buf_t garbled; buf_init(&garbled);
    static const uint8_t junk[] = { 0xFF };
    if (pb_str(&garbled, 1, "probe.garbled") || pb_bytes(&garbled, 2, junk, 1))
        return 1;
    if (load_one_svcd(&garbled, &e) != DS_ERR_DSC_DECODE) {
        fprintf(stderr, "FAIL: [RDSC.11.1] a kwarg that does not decode is not "
                        "DS_ERR_DSC_DECODE\n");
        fails++;
    }
    ds_engine_free(e); e = NULL;
    buf_free(&garbled);

    buf_t varint; buf_init(&varint);
    if (pb_str(&varint, 1, "probe.varint") || pb_varint(&varint, 2u << 3)
        || pb_varint(&varint, 1u)) return 1;
    if (load_one_svcd(&varint, &e) != DS_ERR_DSC_DECODE) {
        fprintf(stderr, "FAIL: [RDSC.11.1] a kwargs field that is not a message is "
                        "not DS_ERR_DSC_DECODE\n");
        fails++;
    }
    ds_engine_free(e);
    buf_free(&varint);
    return fails;
}

/* LFAC.1.1 — a schema with both SchemaTtl and SchemaLogical is not
   refused: the artefact is trusted ([RDSC.9.9]), and the schema is built TTL,
   the choice the scope already makes. The Mercury runtime chooses the same
   (ds.dsc_schema.lfac_1_1_one_lifecycle). */
static int test_schema_sttl_slog_conflict(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t sttl_b, slog_b, slot_b;
    if (build_sttl_body(&sttl_b, "X", 1000) != 0) return 1;
    if (build_slog_body(&slog_b, "X") != 0) return 1;
    if (build_slot_body(&slot_b, "X", "v",
                        DS__V1__SLOT_KIND__SLOT_KIND_INT, NULL) != 0) return 1;
    buf_t atoms[3];
    if (frame_into(&atoms[0], DS_ATOM_SCHEMA_TTL,&sttl_b) != 0) return 1;
    if (frame_into(&atoms[1], DS_ATOM_SCHEMA_LOGICAL,&slog_b) != 0) return 1;
    if (frame_into(&atoms[2], DS_ATOM_SLOT,&slot_b) != 0) return 1;
    buf_t f;
    if (build_file_with_atoms(&f, atoms, 3, "(deftemplate X (slot v))") != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("SchemaTtl+SchemaLogical", r, DS_OK);
    const ds_schema_t *x = NULL;
    r = ds_engine_schema_find(e, "X", &x); EXPECT_LOAD_STATUS("find X", r, DS_OK);
    ds_schema_lifecycle_t lc = DS_SCHEMA_LIFECYCLE_LOGICAL;
    r = ds_schema_get_lifecycle(x, &lc); EXPECT_LOAD_STATUS("lc", r, DS_OK);
    if (lc != DS_SCHEMA_LIFECYCLE_TTL) {
        fprintf(stderr, "FAIL: SchemaTtl+SchemaLogical built lifecycle %d, want TTL\n",
                (int) lc);
        return 1;
    }
    uint64_t ttl = 0;
    r = ds_schema_get_ttl_ns(x, &ttl); EXPECT_LOAD_STATUS("ttl", r, DS_OK);
    if (ttl != 1000) {
        fprintf(stderr, "FAIL: SchemaTtl+SchemaLogical ttl=%llu, want 1000\n",
                (unsigned long long) ttl);
        return 1;
    }
    buf_free(&sttl_b); buf_free(&slog_b); buf_free(&slot_b);
    buf_free(&atoms[0]); buf_free(&atoms[1]); buf_free(&atoms[2]); buf_free(&f);
    ds_engine_free(e);
    return 0;
}

/* LFAC.1.1 — schema with neither SchemaTtl nor SchemaLogical is rejected. */
static int test_schema_no_lifecycle(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t slot_b;
    if (build_slot_body(&slot_b, "X", "v",
                        DS__V1__SLOT_KIND__SLOT_KIND_INT, NULL) != 0) return 1;
    buf_t atoms[1];
    if (frame_into(&atoms[0], DS_ATOM_SLOT,&slot_b) != 0) return 1;
    buf_t f;
    if (build_file_with_atoms(&f, atoms, 1, "(deftemplate X (slot v))") != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("no lifecycle", r, DS_ERR_DSC_SEMANTIC);
    buf_free(&slot_b);
    buf_free(&atoms[0]); buf_free(&f);
    ds_engine_free(e);
    return 0;
}

/* LFAC.1.1, RDSC.8.1 — the same for each other schema atom: a
   SchemaDef or a SchemaSource naming a schema no SchemaTtl or SchemaLogical
   declares is DS_ERR_DSC_SEMANTIC, and so is a Slot beside another schema's
   lifecycle. A Hydration alone names a
   slot no Slot declared, so it is DS_ERR_DSC_DANGLING first (RDSC.5.6.4).
   The Mercury runtime is held to all four (test_ds.m, test_orphan_schema_atoms). */
static int load_one_atom(uint32_t field, const buf_t *body, ds_result_t *out)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t atom, f;
    if (frame_into(&atom, field, body) != 0) return 1;
    if (build_file_with_atoms(&f, &atom, 1, "") != 0) return 1;
    *out = load_sealed(e, &f);
    buf_free(&atom); buf_free(&f);
    ds_engine_free(e);
    return 0;
}

static int test_lfac_1_1__orphan_schema_atoms_refused(void)
{
    ds_result_t r;
    buf_t sdef_b, srcs_b, hydr_b;
    if (build_sdef_body(&sdef_b, "X", DS__V1__COMPRESSION__COMPRESSION_NONE,
                        NULL, 0) != 0) return 1;
    if (build_srcs_body(&srcs_b, "X", NULL, 3, 1) != 0) return 1;
    if (build_hydr_body(&hydr_b, "X", "v") != 0) return 1;

    if (load_one_atom(DS_ATOM_SCHEMA_DEF, &sdef_b, &r) != 0) return 1;
    EXPECT_LOAD_STATUS("orphan sdef", r, DS_ERR_DSC_SEMANTIC);
    if (load_one_atom(DS_ATOM_SCHEMA_SOURCE, &srcs_b, &r) != 0) return 1;
    EXPECT_LOAD_STATUS("orphan srcs", r, DS_ERR_DSC_SEMANTIC);
    if (load_one_atom(DS_ATOM_HYDRATION, &hydr_b, &r) != 0) return 1;
    EXPECT_LOAD_STATUS("orphan hydr", r, DS_ERR_DSC_DANGLING);

    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t slog_b, slot_b;
    if (build_slog_body(&slog_b, "Q") != 0) return 1;
    if (build_slot_body(&slot_b, "X", "v",
                        DS__V1__SLOT_KIND__SLOT_KIND_INT, NULL) != 0) return 1;
    buf_t atoms[2], f;
    if (frame_into(&atoms[0], DS_ATOM_SCHEMA_LOGICAL,&slog_b) != 0) return 1;
    if (frame_into(&atoms[1], DS_ATOM_SLOT,&slot_b) != 0) return 1;
    if (build_file_with_atoms(&f, atoms, 2, "") != 0) return 1;
    r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("slot beside another schema", r, DS_ERR_DSC_SEMANTIC);
    for (int i = 0; i < 2; i++) buf_free(&atoms[i]);
    buf_free(&f); buf_free(&slog_b); buf_free(&slot_b);
    ds_engine_free(e);

    buf_free(&sdef_b); buf_free(&srcs_b); buf_free(&hydr_b);
    return 0;
}

/* RDSC.5.6.4 — Hydration for unknown slot rejected. */
static int test_hydr_dangling(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t slog_b, slot_b, hydr_b;
    if (build_slog_body(&slog_b, "Z") != 0) return 1;
    if (build_slot_body(&slot_b, "Z", "v",
                        DS__V1__SLOT_KIND__SLOT_KIND_INT, NULL) != 0) return 1;
    if (build_hydr_body(&hydr_b, "Z", "no_such_slot") != 0) return 1;
    buf_t atoms[3];
    if (frame_into(&atoms[0], DS_ATOM_SCHEMA_LOGICAL,&slog_b) != 0) return 1;
    if (frame_into(&atoms[1], DS_ATOM_SLOT,&slot_b) != 0) return 1;
    if (frame_into(&atoms[2], DS_ATOM_HYDRATION,&hydr_b) != 0) return 1;
    buf_t f;
    if (build_file_with_atoms(&f, atoms, 3, "(deftemplate Z (slot v))") != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("hydr dangling", r, DS_ERR_DSC_DANGLING);
    buf_free(&slog_b); buf_free(&slot_b); buf_free(&hydr_b);
    buf_free(&atoms[0]); buf_free(&atoms[1]); buf_free(&atoms[2]); buf_free(&f);
    ds_engine_free(e);
    return 0;
}

/* SCHEMA-ref slot resolves to in-artefact target. Two schemas Inner +
 * Outer where Outer.r ↦ Inner. After load both registered; Outer's
 * slots[0].schema_ref points at Inner. */
static int test_schema_ref_resolves(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t inner_log, inner_slot, outer_log, outer_slot;
    if (build_slog_body(&inner_log, "Inner") != 0) return 1;
    if (build_slot_body(&inner_slot, "Inner", "v",
                        DS__V1__SLOT_KIND__SLOT_KIND_INT, NULL) != 0) return 1;
    if (build_slog_body(&outer_log, "Outer") != 0) return 1;
    if (build_slot_body(&outer_slot, "Outer", "r",
                        DS__V1__SLOT_KIND__SLOT_KIND_SCHEMA, "Inner") != 0) return 1;
    buf_t atoms[4];
    if (frame_into(&atoms[0], DS_ATOM_SCHEMA_LOGICAL,&inner_log) != 0) return 1;
    if (frame_into(&atoms[1], DS_ATOM_SLOT,&inner_slot) != 0) return 1;
    if (frame_into(&atoms[2], DS_ATOM_SCHEMA_LOGICAL,&outer_log) != 0) return 1;
    if (frame_into(&atoms[3], DS_ATOM_SLOT,&outer_slot) != 0) return 1;
    buf_t f;
    if (build_file_with_atoms(&f, atoms, 4,
            "(deftemplate Inner (slot v))"
            "(deftemplate Outer (slot r))") != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("schema-ref load", r, DS_OK);
    const ds_schema_t *outer = NULL, *inner = NULL;
    r = ds_engine_schema_find(e, "Outer", &outer); EXPECT_LOAD_STATUS("find Outer", r, DS_OK);
    r = ds_engine_schema_find(e, "Inner", &inner); EXPECT_LOAD_STATUS("find Inner", r, DS_OK);
    if (outer == NULL || inner == NULL) {
        fprintf(stderr, "FAIL: missing schema\n"); return 1;
    }
    if (outer->n_slots != 1 || outer->slots[0].schema_ref != inner) {
        fprintf(stderr, "FAIL: schema_ref did not resolve to Inner\n"); return 1;
    }
    buf_free(&inner_log); buf_free(&inner_slot); buf_free(&outer_log); buf_free(&outer_slot);
    for (int i = 0; i < 4; i++) buf_free(&atoms[i]);
    buf_free(&f);
    ds_engine_free(e);
    return 0;
}

/* SCHEMA-ref naming an unknown target → DSC_DANGLING. */
static int test_schema_ref_dangling(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t slog_b, slot_b;
    if (build_slog_body(&slog_b, "S") != 0) return 1;
    if (build_slot_body(&slot_b, "S", "r",
                        DS__V1__SLOT_KIND__SLOT_KIND_SCHEMA, "Missing") != 0) return 1;
    buf_t atoms[2];
    if (frame_into(&atoms[0], DS_ATOM_SCHEMA_LOGICAL,&slog_b) != 0) return 1;
    if (frame_into(&atoms[1], DS_ATOM_SLOT,&slot_b) != 0) return 1;
    buf_t f;
    if (build_file_with_atoms(&f, atoms, 2, "(deftemplate S (slot r))") != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("dangling ref", r, DS_ERR_DSC_DANGLING);
    buf_free(&slog_b); buf_free(&slot_b);
    buf_free(&atoms[0]); buf_free(&atoms[1]); buf_free(&f);
    ds_engine_free(e);
    return 0;
}

/* A one-rule network for [RDSC.8.7] and [RDSC.11.1]: AlphaNode 1
   naming `alpha_schema`, BetaNode 2 over AlphaNode `right` with left parent
   `parent`, TerminalNode 3 under BetaNode `term_parent`. The artefact carries
   one schema group, for `group`, or none when it is NULL. `prereg` registers
   a schema named `alpha_schema` on the engine first, through the integrator
   API. The engine is returned through `out_e` for the caller to read and
   free. */
static ds_result_t load_rdsc_8_7_net(const char *group, const char *alpha_schema,
                                     int prereg, uint32_t right, uint32_t parent,
                                     uint32_t term_parent, ds_engine_t **out_e)
{
    ds_result_t fail = DS_ERR_R(DS_ERR_INVAL, "test fixture did not build");
    ds_engine_t *e = NULL;
    *out_e = NULL;
    if (new_engine(&e)) return fail;
    *out_e = e;
    if (prereg) {
        ds_slot_desc_t slot = { .name = "v", .type = DS_SLOT_TYPE_INT };
        ds_result_t pr = ds_engine_register_schema(
            e, alpha_schema, DS_SCHEMA_LIFECYCLE_TTL, 1000000000u, &slot, 1, NULL);
        if (pr.status != DS_OK) return fail;
    }

    Ds__V1__AlphaNode a = DS__V1__ALPHA_NODE__INIT;
    a.node_id = 1;
    a.schema_name = (char *) alpha_schema;
    Ds__V1__BetaNode b = DS__V1__BETA_NODE__INIT;
    b.node_id = 2;
    b.right_alpha_id = right;
    b.left_parent_id = parent;
    Ds__V1__TerminalNode t = DS__V1__TERMINAL_NODE__INIT;
    t.node_id = 3;
    t.parent_beta_id = term_parent;
    t.rule_name = (char *) "r";

    uint8_t pk[256];
    buf_t slog_b, slot_b, alfa_b, beta_b, term_b, f;
    buf_t atoms[5];
    size_t n = 0;
    buf_init(&slog_b); buf_init(&slot_b);
    if (group != NULL) {
        if (build_slog_body(&slog_b, group) != 0) return fail;
        if (build_slot_body(&slot_b, group, "v",
                            DS__V1__SLOT_KIND__SLOT_KIND_INT, NULL) != 0) return fail;
        if (frame_into(&atoms[n++], DS_ATOM_SCHEMA_LOGICAL, &slog_b) != 0) return fail;
        if (frame_into(&atoms[n++], DS_ATOM_SLOT, &slot_b) != 0) return fail;
    }
    buf_init(&alfa_b);
    buf_append(&alfa_b, pk, ds__v1__alpha_node__pack(&a, pk));
    buf_init(&beta_b);
    buf_append(&beta_b, pk, ds__v1__beta_node__pack(&b, pk));
    buf_init(&term_b);
    buf_append(&term_b, pk, ds__v1__terminal_node__pack(&t, pk));
    if (frame_into(&atoms[n++], DS_ATOM_ALPHA_NODE, &alfa_b) != 0) return fail;
    if (frame_into(&atoms[n++], DS_ATOM_BETA_NODE, &beta_b) != 0) return fail;
    if (frame_into(&atoms[n++], DS_ATOM_TERMINAL_NODE, &term_b) != 0) return fail;
    if (build_file_with_atoms(&f, atoms, n, NULL) != 0) return fail;

    ds_result_t r = load_sealed(e, &f);
    static char detail[256];
    snprintf(detail, sizeof detail, "%s", r.detail ? r.detail : "");
    r.detail = detail;

    buf_free(&slog_b); buf_free(&slot_b);
    buf_free(&alfa_b); buf_free(&beta_b); buf_free(&term_b);
    for (size_t i = 0; i < n; i++) buf_free(&atoms[i]);
    buf_free(&f);
    return r;
}

/* The atoms that realize `rule` ([RDSC.8.3]): a logical schema group for
   `schema` (SchemaLogical, Slot `v`), AlphaNode 1 over it, BetaNode 2 joining
   the root to AlphaNode 1, and TerminalNode 3 named `rule`. Framed into
   out[0..RULE_NETWORK_ATOMS-1], which the caller frees. A rule_group atom names
   a rule some TerminalNode in the artefact realizes, or the load is refused
   ([RDSC.8.7]), so a test of rule metadata carries these beside it. */
#define RULE_NETWORK_ATOMS 5

/* Defined with the stage-C scenarios and the RuleDebugName round trip below. */
static int build_cool_body(buf_t *out, const char *rule, uint64_t window_ns);
static int build_srcr_body(buf_t *out, const char *rule, const char *file,
                           uint32_t line, uint32_t col);
static int build_dnam_body(buf_t *out, const char *rule, const char *tmpl);

/* The network's three nodes, as frame_rule_network writes them: AlphaNode 1
   over `schema`, BetaNode 2 joining the root to it, TerminalNode 3 under
   BetaNode 2 named `rule`. A caller edits one before framing it. */
static void rule_network_nodes(const char *schema, const char *rule,
                               Ds__V1__AlphaNode *a, Ds__V1__BetaNode *b,
                               Ds__V1__TerminalNode *t)
{
    ds__v1__alpha_node__init(a);
    a->node_id = 1;
    a->schema_name = (char *) schema;
    ds__v1__beta_node__init(b);
    b->node_id = 2;
    b->right_alpha_id = 1;
    b->left_parent_id = 0;
    ds__v1__terminal_node__init(t);
    t->node_id = 3;
    t->parent_beta_id = 2;
    t->rule_name = (char *) rule;
}

/* frame_rule_network's atoms, a logical schema group for `schema` and the
   three nodes given. */
static int frame_rule_network_nodes(buf_t out[RULE_NETWORK_ATOMS],
                                    const char *schema,
                                    const Ds__V1__AlphaNode *a,
                                    const Ds__V1__BetaNode *b,
                                    const Ds__V1__TerminalNode *t)
{
    uint8_t pk[256];
    buf_t slog_b, slot_b, alfa_b, beta_b, term_b;
    if (build_slog_body(&slog_b, schema) != 0) return 1;
    if (build_slot_body(&slot_b, schema, "v",
                        DS__V1__SLOT_KIND__SLOT_KIND_INT, NULL) != 0) return 1;
    buf_init(&alfa_b);
    buf_append(&alfa_b, pk, ds__v1__alpha_node__pack(a, pk));
    buf_init(&beta_b);
    buf_append(&beta_b, pk, ds__v1__beta_node__pack(b, pk));
    buf_init(&term_b);
    buf_append(&term_b, pk, ds__v1__terminal_node__pack(t, pk));
    int bad = frame_into(&out[0], DS_ATOM_SCHEMA_LOGICAL, &slog_b)
           || frame_into(&out[1], DS_ATOM_SLOT, &slot_b)
           || frame_into(&out[2], DS_ATOM_ALPHA_NODE, &alfa_b)
           || frame_into(&out[3], DS_ATOM_BETA_NODE, &beta_b)
           || frame_into(&out[4], DS_ATOM_TERMINAL_NODE, &term_b);
    buf_free(&slog_b); buf_free(&slot_b);
    buf_free(&alfa_b); buf_free(&beta_b); buf_free(&term_b);
    return bad;
}

static int frame_rule_network(buf_t out[RULE_NETWORK_ATOMS],
                              const char *schema, const char *rule)
{
    Ds__V1__AlphaNode    a;
    Ds__V1__BetaNode     b;
    Ds__V1__TerminalNode t;
    rule_network_nodes(schema, rule, &a, &b, &t);
    return frame_rule_network_nodes(out, schema, &a, &b, &t);
}

/* [RDSC.8.7] — a rule_group's atoms name a rule a TerminalNode in the
   artefact realizes, or the load is refused with DS_ERR_DSC_DANGLING, which
   spends the engine ([RDSC.9.8]). Each of the three atoms is held to it on
   its own, and a RuleDebugName with an empty template is no exception: it
   sets nothing, but it still names a rule. The Mercury runtime is held to the
   same cases (test_ds.m, test_network_integrity's check_rule_group_case). */
static int test_rdsc_8_7__rule_group_names_a_terminal(void)
{
    struct { const char *label; uint32_t atom; int which; } cases[] = {
        { "RuleCooldown",                 DS_ATOM_RULE_COOLDOWN,   0 },
        { "RuleSource",                   DS_ATOM_RULE_SOURCE,     1 },
        { "RuleDebugName",                DS_ATOM_RULE_DEBUG_NAME, 2 },
        { "RuleDebugName, empty template", DS_ATOM_RULE_DEBUG_NAME, 3 },
    };
    for (size_t c = 0; c < sizeof cases / sizeof cases[0]; c++) {
        for (int realized = 1; realized >= 0; realized--) {
            /* The network realizes `r`; the atom names `r` (the control,
               which loads) or `ghost` (which no TerminalNode realizes). */
            const char *named = realized ? "r" : "ghost";
            buf_t body;
            int bad = 0;
            switch (cases[c].which) {
            case 0:  bad = build_cool_body(&body, named, 5000); break;
            case 1:  bad = build_srcr_body(&body, named, NULL, 1, 1); break;
            case 2:  bad = build_dnam_body(&body, named, "r(x={x.v})"); break;
            default: bad = build_dnam_body(&body, named, ""); break;
            }
            if (bad) return 1;
            buf_t atoms[1 + RULE_NETWORK_ATOMS];
            if (frame_into(&atoms[0], cases[c].atom, &body) != 0) return 1;
            if (frame_rule_network(&atoms[1], "S", "r") != 0) return 1;
            buf_t f;
            if (build_file_with_atoms(&f, atoms, 1 + RULE_NETWORK_ATOMS,
                                      NULL) != 0) return 1;
            ds_engine_t *e = NULL;
            if (new_engine(&e)) return 1;
            ds_result_t r = load_sealed(e, &f);
            char label[96];
            snprintf(label, sizeof label, "[RDSC.8.7] %s naming %s",
                     cases[c].label, realized ? "a terminal's rule (control)"
                                              : "no terminal's rule");
            if (realized) {
                EXPECT_LOAD_STATUS(label, r, DS_OK);
            } else {
                EXPECT_LOAD_STATUS(label, r, DS_ERR_DSC_DANGLING);
                /* NERR.8.1: the detail names the rule. */
                if (r.detail == NULL || strstr(r.detail, "'ghost'") == NULL) {
                    fprintf(stderr, "FAIL: %s: the detail does not name the "
                            "rule: %s\n", label, r.detail ? r.detail : "(null)");
                    ds_engine_free(e); return 1;
                }
                /* [RDSC.9.8]: the refused load spent the engine. */
                if (expect_spent(label, e)) {
                    ds_engine_free(e); return 1;
                }
            }
            ds_engine_free(e);
            buf_free(&body);
            for (size_t i = 0; i < 1 + RULE_NETWORK_ATOMS; i++)
                buf_free(&atoms[i]);
            buf_free(&f);
        }
    }
    return 0;
}

/* [RDSC.9.9] — a TerminalNode with an empty `rule_name` loads: no clause
   requires the name. protobuf-c leaves an empty proto3 string unwritten, so
   this is the field omitted; the Mercury runtime is held to that case and to
   the field written empty (test_ds.m, test_network). */
static int test_rdsc_9_9__terminal_with_empty_rule_name_loads(void)
{
    buf_t atoms[RULE_NETWORK_ATOMS];
    if (frame_rule_network(atoms, "S", "") != 0) return 1;
    buf_t f;
    if (build_file_with_atoms(&f, atoms, RULE_NETWORK_ATOMS, NULL) != 0)
        return 1;
    ds_engine_t *e = NULL;
    if (new_engine(&e)) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("[RDSC.9.9] a TerminalNode with no rule_name", r, DS_OK);
    ds_engine_free(e);
    for (size_t i = 0; i < RULE_NETWORK_ATOMS; i++) buf_free(&atoms[i]);
    buf_free(&f);
    return 0;
}

/* [RDSC.9.5] before [RDSC.8.7] — [RDSC.8.7] is a condition over the
   PARSED stream, so an artefact one of whose network bodies does not decode is
   refused for that body, with its offset, although it also carries a name no
   atom defines. Each node body in turn is replaced by one that cannot decode
   (field 1 with wire type 7, which no protobuf field has), beside a
   RuleCooldown naming `ghost`, which no TerminalNode realizes. The control,
   every body intact, is refused as dangling, so the name the other cases carry
   is a real one. The Mercury runtime is held to the same cases (test_ds.m,
   test_network_integrity). */
static int test_rdsc_9_5__undecodable_body_before_dangling_name(void)
{
    static const uint8_t undecodable[1] = { 0x0F };
    struct { const char *label; uint32_t atom; size_t at; const char *detail; } cases[] = {
        /* frame_rule_network's order, after the RuleCooldown at 0. */
        { "AlphaNode",    DS_ATOM_ALPHA_NODE,    1 + 2, "alfa body" },
        { "BetaNode",     DS_ATOM_BETA_NODE,     1 + 3, "beta body" },
        { "TerminalNode", DS_ATOM_TERMINAL_NODE, 1 + 4, "term body" },
    };
    const size_t n_cases = sizeof cases / sizeof cases[0];
    for (size_t c = 0; c <= n_cases; c++) {
        int control = c == n_cases;
        buf_t cool, f;
        buf_t atoms[1 + RULE_NETWORK_ATOMS];
        if (build_cool_body(&cool, "ghost", 5000) != 0) return 1;
        if (frame_into(&atoms[0], DS_ATOM_RULE_COOLDOWN, &cool) != 0) return 1;
        if (frame_rule_network(&atoms[1], "S", "r") != 0) return 1;
        if (!control) {
            buf_t bad;
            buf_init(&bad);
            if (buf_append(&bad, undecodable, sizeof undecodable) != 0) return 1;
            buf_free(&atoms[cases[c].at]);
            if (frame_into(&atoms[cases[c].at], cases[c].atom, &bad) != 0) return 1;
            buf_free(&bad);
        }
        if (build_file_with_atoms(&f, atoms, 1 + RULE_NETWORK_ATOMS,
                                  NULL) != 0) return 1;
        ds_engine_t *e = NULL;
        if (new_engine(&e)) return 1;
        ds_result_t r = load_sealed(e, &f);
        char label[96];
        if (control) {
            snprintf(label, sizeof label,
                     "[RDSC.8.7] every body intact (control)");
            EXPECT_LOAD_STATUS(label, r, DS_ERR_DSC_DANGLING);
            if (r.detail == NULL || strstr(r.detail, "'ghost'") == NULL) {
                fprintf(stderr, "FAIL: %s: the detail does not name the "
                        "rule: %s\n", label, r.detail ? r.detail : "(null)");
                ds_engine_free(e); return 1;
            }
        } else {
            snprintf(label, sizeof label,
                     "[RDSC.9.5] an undecodable %s body beside a dangling name",
                     cases[c].label);
            EXPECT_LOAD_STATUS(label, r, DS_ERR_DSC_DECODE);
            /* The body's own refusal, with the offset [RDSC.9.5] asks for. */
            if (r.detail == NULL || strstr(r.detail, cases[c].detail) == NULL
                || strstr(r.detail, " at offset ") == NULL) {
                fprintf(stderr, "FAIL: %s: the detail is not the body's "
                        "refusal: %s\n", label, r.detail ? r.detail : "(null)");
                ds_engine_free(e); return 1;
            }
        }
        ds_engine_free(e);
        buf_free(&cool);
        for (size_t i = 0; i < 1 + RULE_NETWORK_ATOMS; i++)
            buf_free(&atoms[i]);
        buf_free(&f);
    }
    return 0;
}

/* [RDSC.9.5] — "The error names the atom, the byte offset, and
   the protobuf decoder's reason." protobuf-c's `unpack` gives no reason, so the
   walk's ds_dsc_decode_at_offset reads the body's top-level fields again and
   names the first wire error, in the Mercury runtime's words
   (`ds.dsc.wire_reason`). An AlphaNode body carrying each of the four, in
   turn, after the RuleCooldown: the refusal names the body, its offset and
   that reason. PATH: the walk, as for every atom. The Mercury runtime is held
   to the same bodies and the same words (test_ds.m,
   test_rdsc_9_5_decoder_reason). */
/* @spec [RDSC.9.5] */
static int test_rdsc_9_5__the_refusal_names_the_decoders_reason(void)
{
    static const uint8_t wt7[]       = { 0x0F };        /* field 1, wire type 7 */
    static const uint8_t truncated[] = { 0x08 };        /* field 1 varint, no value */
    static const uint8_t overlong[]  = { 0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                                         0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 };
                                                        /* an eleven-byte varint */
    static const uint8_t too_long[]  = { 0x12, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F };
                                                        /* field 2, length 2^32 - 1 */
    struct { const uint8_t *body; size_t len; const char *reason; } cases[] = {
        { wt7,       sizeof wt7,       ": wire type 7 is not one DS writes" },
        { truncated, sizeof truncated, ": the body ends mid-value" },
        { overlong,  sizeof overlong,
          ": a varint is longer than ten bytes or carries bits above 64" },
        { too_long,  sizeof too_long,  ": a declared length does not fit" },
    };
    for (size_t c = 0; c < sizeof cases / sizeof cases[0]; c++) {
        buf_t cool, bad, f;
        buf_t atoms[1 + RULE_NETWORK_ATOMS];
        if (build_cool_body(&cool, "r", 5000) != 0) return 1;
        if (frame_into(&atoms[0], DS_ATOM_RULE_COOLDOWN, &cool) != 0) return 1;
        if (frame_rule_network(&atoms[1], "S", "r") != 0) return 1;
        buf_init(&bad);
        if (buf_append(&bad, cases[c].body, cases[c].len) != 0) return 1;
        buf_free(&atoms[1 + 2]);
        if (frame_into(&atoms[1 + 2], DS_ATOM_ALPHA_NODE, &bad) != 0) return 1;
        buf_free(&bad);
        if (build_file_with_atoms(&f, atoms, 1 + RULE_NETWORK_ATOMS,
                                  NULL) != 0) return 1;
        ds_engine_t *e = NULL;
        if (new_engine(&e)) return 1;
        ds_result_t r = load_sealed(e, &f);
        char label[128];
        snprintf(label, sizeof label, "[RDSC.9.5] an AlphaNode body refused%s",
                 cases[c].reason);
        EXPECT_LOAD_STATUS(label, r, DS_ERR_DSC_DECODE);
        if (r.detail == NULL || strstr(r.detail, "alfa body") == NULL
            || strstr(r.detail, " at offset ") == NULL
            || strstr(r.detail, cases[c].reason) == NULL) {
            fprintf(stderr, "FAIL: %s: the detail does not name the atom, the "
                    "offset and the reason: %s\n", label,
                    r.detail ? r.detail : "(null)");
            ds_engine_free(e); return 1;
        }
        ds_engine_free(e);
        buf_free(&cool);
        for (size_t i = 0; i < 1 + RULE_NETWORK_ATOMS; i++)
            buf_free(&atoms[i]);
        buf_free(&f);
    }
    return 0;
}

/* [RDSC.8.7] — the stream is parsed when every body is decoded in
   full, a network node's shape included, so a node body its own clause
   refuses is refused for that, not as dangling, beside a RuleCooldown naming
   `ghost`, which no TerminalNode realizes. One case per shape the clause
   names: a node id of 0 on each node atom ([RDSC.4a.3], DS_ERR_RETP_INVALID),
   an AlphaNode naming no schema ([RDSC.4a.6]) and a BetaNode join test that
   is an `Expr` of no kind ([RDSC.11.3]), each DS_ERR_DSC_SEMANTIC. With every
   body intact the artefact is refused as dangling
   (test_rdsc_9_5__undecodable_body_before_dangling_name's control), so the
   name is a real one. PATH: the walk's ds_dsc_rete_body_decodes, which runs
   the apply phase's decoder with no engine. The Mercury runtime is held to the same cases
   (test_ds.m, test_network_integrity). */
static int test_rdsc_8_7__body_shape_before_dangling_name(void)
{
    enum { ALPHA_ID_0, BETA_ID_0, TERM_ID_0, ALPHA_NO_SCHEMA, KINDLESS_JOIN_TEST };
    struct { const char *label; int edit; int want; const char *clause; } cases[] = {
        { "an AlphaNode with node_id 0",      ALPHA_ID_0,         DS_ERR_RETP_INVALID, "RDSC.4a.3" },
        { "a BetaNode with node_id 0",        BETA_ID_0,          DS_ERR_RETP_INVALID, "RDSC.4a.3" },
        { "a TerminalNode with node_id 0",    TERM_ID_0,          DS_ERR_RETP_INVALID, "RDSC.4a.3" },
        { "an AlphaNode naming no schema",    ALPHA_NO_SCHEMA,    DS_ERR_DSC_SEMANTIC, "RDSC.4a.6" },
        { "a BetaNode join test of no kind",  KINDLESS_JOIN_TEST, DS_ERR_DSC_SEMANTIC, NULL },
    };
    for (size_t c = 0; c < sizeof cases / sizeof cases[0]; c++) {
        Ds__V1__AlphaNode    a;
        Ds__V1__BetaNode     b;
        Ds__V1__TerminalNode t;
        Ds__V1__Expr         kindless = DS__V1__EXPR__INIT;
        Ds__V1__Expr        *join_tests[1] = { &kindless };
        rule_network_nodes("S", "r", &a, &b, &t);
        switch (cases[c].edit) {
        case ALPHA_ID_0:      a.node_id = 0;   break;
        case BETA_ID_0:       b.node_id = 0;   break;
        case TERM_ID_0:       t.node_id = 0;   break;
        case ALPHA_NO_SCHEMA: a.schema_name = (char *) ""; break;
        default:
            b.n_join_tests = 1;
            b.join_tests = join_tests;
            break;
        }
        buf_t cool, f;
        buf_t atoms[1 + RULE_NETWORK_ATOMS];
        if (build_cool_body(&cool, "ghost", 5000) != 0) return 1;
        if (frame_into(&atoms[0], DS_ATOM_RULE_COOLDOWN, &cool) != 0) return 1;
        if (frame_rule_network_nodes(&atoms[1], "S", &a, &b, &t) != 0) return 1;
        if (build_file_with_atoms(&f, atoms, 1 + RULE_NETWORK_ATOMS,
                                  NULL) != 0) return 1;
        ds_engine_t *e = NULL;
        if (new_engine(&e)) return 1;
        ds_result_t r = load_sealed(e, &f);
        char label[96];
        snprintf(label, sizeof label, "[RDSC.8.7] %s beside a dangling name",
                 cases[c].label);
        EXPECT_LOAD_STATUS(label, r, cases[c].want);
        /* The body's own refusal: its clause where the detail names one, and
           never the name's. */
        if (r.detail == NULL || strstr(r.detail, "'ghost'") != NULL
            || (cases[c].clause != NULL
                && strstr(r.detail, cases[c].clause) == NULL)) {
            fprintf(stderr, "FAIL: %s: the detail is not the body's "
                    "refusal: %s\n", label, r.detail ? r.detail : "(null)");
            ds_engine_free(e); return 1;
        }
        ds_engine_free(e);
        buf_free(&cool);
        for (size_t i = 0; i < 1 + RULE_NETWORK_ATOMS; i++)
            buf_free(&atoms[i]);
        buf_free(&f);
    }
    return 0;
}

/* [RDSC.4a.6.1] — a malformed AlphaTest is refused with DS_ERR_DSC_SEMANTIC
   as the AlphaNode's body is decoded, and so for the body beside a
   RuleCooldown naming `ghost`, which no TerminalNode realizes. One case per
   shape the clause names but a pattern that does not compile
   (test_rete_loader.c, test_alpha_regex_bad_pattern_refuses_load). The slot
   bound is 254: the field has no marker, so 255 is refused and 254 loads
   ([RDSC.4a.9.1]). The same test at slot 0 loads too, so each refusal is the
   edit's. PATH: the walk's ds_dsc_rete_body_decodes, which
   runs decode_alfa. The Mercury runtime is held to the same cases (test_ds.m,
   test_network_integrity). */
/* @spec [RDSC.4a.6.1] */
static int test_rdsc_4a_6_1__malformed_alpha_test(void)
{
    enum { NO_KIND, EQ_NO_LITERAL, EQ_EMPTY_LITERAL, CMP_NO_LITERAL,
           CMP_NO_OP, REGEX_NO_PATTERN, SLOT_255, SLOT_254, SLOT_0 };
    struct { const char *label; int edit; int want; } cases[] = {
        { "an AlphaTest of no AlphaTestKind",            NO_KIND,          DS_ERR_DSC_SEMANTIC },
        { "an EQ AlphaTest with no literal",             EQ_NO_LITERAL,    DS_ERR_DSC_SEMANTIC },
        { "an EQ AlphaTest whose literal sets no member", EQ_EMPTY_LITERAL, DS_ERR_DSC_SEMANTIC },
        { "a CMP AlphaTest with no literal",             CMP_NO_LITERAL,   DS_ERR_DSC_SEMANTIC },
        { "a CMP AlphaTest whose op is no AlphaCmpOp",   CMP_NO_OP,        DS_ERR_DSC_SEMANTIC },
        { "a REGEX AlphaTest with no pattern",           REGEX_NO_PATTERN, DS_ERR_DSC_SEMANTIC },
        { "an AlphaTest slot_index of 255",              SLOT_255,         DS_ERR_DSC_SEMANTIC },
        { "an AlphaTest slot_index of 254",              SLOT_254,         DS_OK },
        { "the same AlphaTest at slot 0 (control)",      SLOT_0,           DS_OK },
    };
    for (size_t c = 0; c < sizeof cases / sizeof cases[0]; c++) {
        Ds__V1__AlphaNode    a;
        Ds__V1__BetaNode     b;
        Ds__V1__TerminalNode t;
        Ds__V1__AlphaTest    test;
        Ds__V1__AlphaTest   *tests[1] = { &test };
        Ds__V1__AlphaLiteral lit;
        rule_network_nodes("S", "r", &a, &b, &t);
        /* slot 0 > int 42, as test_ds.m's "an AlphaNode test decodes". */
        ds__v1__alpha_test__init(&test);
        ds__v1__alpha_literal__init(&lit);
        lit.value_case = DS__V1__ALPHA_LITERAL__VALUE_INT_VAL;
        lit.int_val = 42;
        test.kind = DS__V1__ALPHA_TEST_KIND__ALPHA_TEST_CMP;
        test.slot_index = 0;
        test.op = DS__V1__ALPHA_CMP_OP__ALPHA_CMP_GT;
        test.literal = &lit;
        switch (cases[c].edit) {
        case NO_KIND:
            test.kind = (Ds__V1__AlphaTestKind) 3;
            test.op = DS__V1__ALPHA_CMP_OP__ALPHA_CMP_EQ;
            break;
        case EQ_NO_LITERAL:
            test.kind = DS__V1__ALPHA_TEST_KIND__ALPHA_TEST_EQ;
            test.op = DS__V1__ALPHA_CMP_OP__ALPHA_CMP_EQ;
            test.literal = NULL;
            break;
        case EQ_EMPTY_LITERAL:
            test.kind = DS__V1__ALPHA_TEST_KIND__ALPHA_TEST_EQ;
            test.op = DS__V1__ALPHA_CMP_OP__ALPHA_CMP_EQ;
            lit.value_case = DS__V1__ALPHA_LITERAL__VALUE__NOT_SET;
            break;
        case CMP_NO_LITERAL:   test.literal = NULL; break;
        case CMP_NO_OP:        test.op = (Ds__V1__AlphaCmpOp) 6; break;
        case REGEX_NO_PATTERN:
            test.kind = DS__V1__ALPHA_TEST_KIND__ALPHA_TEST_REGEX;
            test.op = DS__V1__ALPHA_CMP_OP__ALPHA_CMP_EQ;
            test.literal = NULL;
            test.pattern = (char *) "";
            break;
        case SLOT_255:         test.slot_index = 255; break;
        case SLOT_254:         test.slot_index = 254; break;
        default:               break;
        }
        a.n_tests = 1;
        a.tests = tests;
        /* The refusals sit beside the dangling name; the loads cannot. */
        int ghost = cases[c].want != DS_OK;
        buf_t cool, f;
        buf_t atoms[1 + RULE_NETWORK_ATOMS];
        if (ghost) {
            if (build_cool_body(&cool, "ghost", 5000) != 0) return 1;
            if (frame_into(&atoms[0], DS_ATOM_RULE_COOLDOWN, &cool) != 0) return 1;
            buf_free(&cool);
        }
        if (frame_rule_network_nodes(&atoms[ghost], "S", &a, &b, &t) != 0)
            return 1;
        if (build_file_with_atoms(&f, atoms, (size_t) ghost + RULE_NETWORK_ATOMS,
                                  NULL) != 0) return 1;
        ds_engine_t *e = NULL;
        if (new_engine(&e)) return 1;
        ds_result_t r = load_sealed(e, &f);
        char label[112];
        snprintf(label, sizeof label, "[RDSC.4a.6.1] %s", cases[c].label);
        EXPECT_LOAD_STATUS(label, r, cases[c].want);
        /* The body's own refusal, never the name's. */
        if (ghost && (r.detail == NULL || strstr(r.detail, "'ghost'") != NULL
                      || strstr(r.detail, "RDSC.4a.6.1") == NULL)) {
            fprintf(stderr, "FAIL: %s: the detail is not the AlphaTest's "
                    "refusal: %s\n", label, r.detail ? r.detail : "(null)");
            ds_engine_free(e); return 1;
        }
        ds_engine_free(e);
        for (size_t i = 0; i < (size_t) ghost + RULE_NETWORK_ATOMS; i++)
            buf_free(&atoms[i]);
        buf_free(&f);
    }

    /* An enum is its varint's low 32 bits, as protobuf-c reads it: a kind of
       2^32 is EQ and an op of 2^32 + 3 is GT, so both load. Hand-built, since
       a packer writes no varint past 32 bits for an enum. The Mercury runtime
       is held to the same bytes. */
    static const uint8_t wide_kind[] = {
        0x08, 0x01, 0x12, 0x01, 0x53, 0x1A, 0x0C,
        0x08, 0x80, 0x80, 0x80, 0x80, 0x10, 0x10, 0x00,
        0x22, 0x02, 0x08, 0x2A };
    static const uint8_t wide_op[] = {
        0x08, 0x01, 0x12, 0x01, 0x53, 0x1A, 0x0E,
        0x08, 0x01, 0x10, 0x00, 0x18, 0x83, 0x80, 0x80, 0x80, 0x10,
        0x22, 0x02, 0x08, 0x2A };
    struct { const char *label; const uint8_t *body; size_t len; } wide[] = {
        { "an AlphaTest kind of 2^32 is EQ",    wide_kind, sizeof wide_kind },
        { "an AlphaTest op of 2^32 + 3 is GT",  wide_op,   sizeof wide_op },
    };
    for (size_t c = 0; c < sizeof wide / sizeof wide[0]; c++) {
        buf_t alfa, f;
        buf_t atoms[RULE_NETWORK_ATOMS];
        if (frame_rule_network(atoms, "S", "r") != 0) return 1;
        buf_init(&alfa);
        if (buf_append(&alfa, wide[c].body, wide[c].len) != 0) return 1;
        buf_free(&atoms[2]);
        if (frame_into(&atoms[2], DS_ATOM_ALPHA_NODE, &alfa) != 0) return 1;
        buf_free(&alfa);
        if (build_file_with_atoms(&f, atoms, RULE_NETWORK_ATOMS, NULL) != 0)
            return 1;
        ds_engine_t *e = NULL;
        if (new_engine(&e)) return 1;
        ds_result_t r = load_sealed(e, &f);
        char label[112];
        snprintf(label, sizeof label, "[RDSC.4a.6.1] %s", wide[c].label);
        EXPECT_LOAD_STATUS(label, r, DS_OK);
        ds_engine_free(e);
        for (size_t i = 0; i < RULE_NETWORK_ATOMS; i++) buf_free(&atoms[i]);
        buf_free(&f);
    }
    return 0;
}

/* [RDSC.8.7] — an AlphaNode names a schema some schema group in the ARTEFACT
   registers, or the load is refused with DS_ERR_DSC_DANGLING. The artefact
   alone decides: a schema registered through ds_engine_register_schema
   (libds-internal) does not satisfy it. The refusal spends the engine
   ([RDSC.9.8]).
   [RDSC.11.1] — a node_id naming no node is DS_ERR_RETP_INDEX_OOB. The
   Mercury runtime is held to the same cases (test_ds.m,
   test_network_integrity). */
static int test_rdsc_8_7__alpha_schema_from_the_artefact(void)
{
    ds_engine_t *e = NULL;
    ds_result_t r;

    /* CONTROL: the same network with its schema group loads, so every refusal
       below is the defect its case names and not the fixture. */
    r = load_rdsc_8_7_net("S", "S", 0, 1, 0, 2, &e);
    ds_engine_free(e);
    EXPECT_LOAD_STATUS("[RDSC.8.7] control", r, DS_OK);

    r = load_rdsc_8_7_net(NULL, "S", 0, 1, 0, 2, &e);
    ds_engine_free(e);
    EXPECT_LOAD_STATUS("[RDSC.8.7] no schema group", r, DS_ERR_DSC_DANGLING);
    /* NERR.8.1: the detail names the AlphaNode and the schema. */
    if (strstr(r.detail, "AlphaNode 1") == NULL || strstr(r.detail, "'S'") == NULL) {
        fprintf(stderr, "FAIL: [RDSC.8.7] detail names neither node nor schema: %s\n",
                r.detail);
        return 1;
    }

    /* Another schema's group is not the one the AlphaNode names, and the
       refusal spends the engine. */
    r = load_rdsc_8_7_net("T", "S", 0, 1, 0, 2, &e);
    EXPECT_LOAD_STATUS("[RDSC.8.7] another schema's group", r, DS_ERR_DSC_DANGLING);
    int spent = expect_spent("[RDSC.9.8] another schema's group", e);
    ds_engine_free(e);
    if (spent) return 1;

    r = load_rdsc_8_7_net(NULL, "S", 1, 1, 0, 2, &e);
    ds_engine_free(e);
    EXPECT_LOAD_STATUS("[RDSC.8.7] registered programmatically, absent from the "
                       "artefact", r, DS_ERR_DSC_DANGLING);

    r = load_rdsc_8_7_net("S", "S", 0, 9, 0, 2, &e);
    ds_engine_free(e);
    EXPECT_LOAD_STATUS("[RDSC.11.1] right_alpha_id names no node", r,
                       DS_ERR_RETP_INDEX_OOB);
    r = load_rdsc_8_7_net("S", "S", 0, 1, 9, 2, &e);
    ds_engine_free(e);
    EXPECT_LOAD_STATUS("[RDSC.11.1] left_parent_id names no node", r,
                       DS_ERR_RETP_INDEX_OOB);
    r = load_rdsc_8_7_net("S", "S", 0, 1, 0, 9, &e);
    ds_engine_free(e);
    EXPECT_LOAD_STATUS("[RDSC.11.1] parent_beta_id names no node", r,
                       DS_ERR_RETP_INDEX_OOB);
    return 0;
}

/* Hydration set on a slot makes hydration_eligible true on the registered
 * schema. SchemaDef stores the .proto text on the schema. */
static int test_hydr_and_sdef_metadata(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t slog_b, slot_b, hydr_b, sdef_b;
    if (build_slog_body(&slog_b, "M") != 0) return 1;
    if (build_slot_body(&slot_b, "M", "ts",
                        DS__V1__SLOT_KIND__SLOT_KIND_INT, NULL) != 0) return 1;
    if (build_hydr_body(&hydr_b, "M", "ts") != 0) return 1;
    const char *proto = "syntax = \"proto3\"; package m;";
    if (build_sdef_body(&sdef_b, "M",
                        DS__V1__COMPRESSION__COMPRESSION_NONE,
                        (const uint8_t *) proto, strlen(proto)) != 0) return 1;
    buf_t atoms[4];
    if (frame_into(&atoms[0], DS_ATOM_SCHEMA_LOGICAL,&slog_b) != 0) return 1;
    if (frame_into(&atoms[1], DS_ATOM_SLOT,&slot_b) != 0) return 1;
    if (frame_into(&atoms[2], DS_ATOM_HYDRATION,&hydr_b) != 0) return 1;
    if (frame_into(&atoms[3], DS_ATOM_SCHEMA_DEF,&sdef_b) != 0) return 1;
    buf_t f;
    if (build_file_with_atoms(&f, atoms, 4, "(deftemplate M (slot ts))") != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("hydr+sdef", r, DS_OK);
    const ds_schema_t *m = NULL;
    r = ds_engine_schema_find(e, "M", &m); EXPECT_LOAD_STATUS("find M", r, DS_OK);
    if (m == NULL || m->n_slots != 1) {
        fprintf(stderr, "FAIL: schema not registered\n"); return 1;
    }
    if (!m->slots[0].hydration_eligible) {
        fprintf(stderr, "FAIL: Hydration did not set hydration_eligible\n"); return 1;
    }
    buf_free(&slog_b); buf_free(&slot_b); buf_free(&hydr_b); buf_free(&sdef_b);
    for (int i = 0; i < 4; i++) buf_free(&atoms[i]);
    buf_free(&f);
    ds_engine_free(e);
    return 0;
}

/* RDSC.5.7 — SchemaSource preserves source location on the registered schema.
   The display path is resolved via the matching
   DsSource for the same module_id; the test provides one. */
static int test_srcs_round_trip(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t slog_b, slot_b, srcs_b, dsrc_b;
    if (build_slog_body(&slog_b, "Q") != 0) return 1;
    if (build_slot_body(&slot_b, "Q", "v",
                        DS__V1__SLOT_KIND__SLOT_KIND_INT, NULL) != 0) return 1;
    if (build_srcs_body(&srcs_b, "Q", "test.ds", 17, 4) != 0) return 1;
    if (build_dsrc_body(&dsrc_b, "test.ds",
                        DS__V1__COMPRESSION__COMPRESSION_NONE,
                        (const uint8_t *) "schema Q", 8) != 0) return 1;
    buf_t atoms[4];
    if (frame_into(&atoms[0], DS_ATOM_DS_SOURCE,&dsrc_b) != 0) return 1;
    if (frame_into(&atoms[1], DS_ATOM_SCHEMA_LOGICAL,&slog_b) != 0) return 1;
    if (frame_into(&atoms[2], DS_ATOM_SLOT,&slot_b) != 0) return 1;
    if (frame_into(&atoms[3], DS_ATOM_SCHEMA_SOURCE,&srcs_b) != 0) return 1;
    buf_t f;
    if (build_file_with_atoms(&f, atoms, 4, "(deftemplate Q (slot v))") != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("srcs", r, DS_OK);
    const ds_schema_t *q = NULL;
    r = ds_engine_schema_find(e, "Q", &q);
    EXPECT_LOAD_STATUS("find Q", r, DS_OK);
    if (q == NULL || q->src_file == NULL ||
        strcmp(q->src_file, "test.ds") != 0 ||
        q->src_line != 17 || q->src_col != 4) {
        fprintf(stderr, "FAIL: SchemaSource metadata mismatch\n"); return 1;
    }
    buf_free(&slog_b); buf_free(&slot_b); buf_free(&srcs_b); buf_free(&dsrc_b);
    for (int i = 0; i < 4; i++) buf_free(&atoms[i]);
    buf_free(&f);
    ds_engine_free(e);
    return 0;
}

/* RDSC.5.7, RDSC.4.7 — with no DsSource for the schema's clip there
   is no display path, and the position stays: ds_schema_get_source answers a
   NULL file with SchemaSource's line and column. The Mercury runtime's
   `schema_source_for` is held to this. */
static int test_rdsc_5_7__srcs_without_dsrc_keeps_position(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t slog_b, slot_b, srcs_b;
    if (build_slog_body(&slog_b, "Q") != 0) return 1;
    if (build_slot_body(&slot_b, "Q", "v",
                        DS__V1__SLOT_KIND__SLOT_KIND_INT, NULL) != 0) return 1;
    if (build_srcs_body(&srcs_b, "Q", NULL, 17, 4) != 0) return 1;
    buf_t atoms[3];
    if (frame_into(&atoms[0], DS_ATOM_SCHEMA_LOGICAL,&slog_b) != 0) return 1;
    if (frame_into(&atoms[1], DS_ATOM_SLOT,&slot_b) != 0) return 1;
    if (frame_into(&atoms[2], DS_ATOM_SCHEMA_SOURCE,&srcs_b) != 0) return 1;
    buf_t f;
    if (build_file_with_atoms(&f, atoms, 3, "(deftemplate Q (slot v))") != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("srcs, no dsrc", r, DS_OK);
    const ds_schema_t *q = NULL;
    r = ds_engine_schema_find(e, "Q", &q);
    EXPECT_LOAD_STATUS("find Q", r, DS_OK);
    const char *file = "unset";
    uint32_t line = 0, col = 0;
    r = ds_schema_get_source(q, &file, &line, &col);
    EXPECT_LOAD_STATUS("get_source", r, DS_OK);
    if (file != NULL || line != 17 || col != 4) {
        fprintf(stderr, "FAIL: no DsSource: want (NULL, 17, 4), got (%s, %u, %u)\n",
                file ? file : "NULL", (unsigned) line, (unsigned) col);
        return 1;
    }
    buf_free(&slog_b); buf_free(&slot_b); buf_free(&srcs_b);
    for (int i = 0; i < 3; i++) buf_free(&atoms[i]);
    buf_free(&f);
    ds_engine_free(e);
    return 0;
}

/* ============== Stage C helpers — rule-atom encoders ============== */

static int build_cool_body(buf_t *out, const char *rule, uint64_t window_ns)
{
    Ds__V1__RuleCooldown m = DS__V1__RULE_COOLDOWN__INIT;
    m.rule_name = (char *) rule; m.window_ns = window_ns;
    size_t pl = ds__v1__rule_cooldown__get_packed_size(&m);
    uint8_t *b = malloc(pl); if (!b) return -1;
    ds__v1__rule_cooldown__pack(&m, b);
    buf_init(out);
    if (buf_append(out, b, pl) != 0) { free(b); return -1; }
    free(b); return 0;
}

static int build_srcr_body(buf_t *out, const char *rule, const char *file,
                           uint32_t line, uint32_t col)
{
    (void) file;  /* not on RuleSource */
    Ds__V1__RuleSource m = DS__V1__RULE_SOURCE__INIT;
    m.rule_name = (char *) rule;
    m.line = line; m.col = col;
    size_t pl = ds__v1__rule_source__get_packed_size(&m);
    uint8_t *b = malloc(pl); if (!b) return -1;
    ds__v1__rule_source__pack(&m, b);
    buf_init(out);
    if (buf_append(out, b, pl) != 0) { free(b); return -1; }
    free(b); return 0;
}

/* Find a rule's metadata on the engine, NULL if not present. */
static const struct ds_rule_meta *find_rule_meta(ds_engine_t *e, const char *name)
{
    for (size_t i = 0; i < e->n_rule_metas; i++) {
        if (strcmp(e->rule_metas[i].rule_name, name) == 0) {
            return &e->rule_metas[i];
        }
    }
    return NULL;
}

/* ============== Stage C scenarios ============== */

/* RDSC.6 — RuleCooldown/RuleSource for an existing defrule round-trip.
   The RuleSource display path is resolved via DsSource for
   the same module_id; the test provides a matching DsSource. */
static int test_rule_metadata_round_trip(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t cool, srcr, dsrc_b;
    if (build_cool_body(&cool, "myrule", 30000000000ULL) != 0) return 1;
    if (build_srcr_body(&srcr, "myrule", "x.ds", 12, 5) != 0) return 1;
    if (build_dsrc_body(&dsrc_b, "x.ds",
                        DS__V1__COMPRESSION__COMPRESSION_NONE,
                        (const uint8_t *) "rule myrule:", 12) != 0) return 1;
    buf_t atoms[3 + RULE_NETWORK_ATOMS];
    if (frame_into(&atoms[0], DS_ATOM_DS_SOURCE,&dsrc_b) != 0) return 1;
    if (frame_into(&atoms[1], DS_ATOM_RULE_COOLDOWN,&cool) != 0) return 1;
    if (frame_into(&atoms[2], DS_ATOM_RULE_SOURCE,&srcr) != 0) return 1;
    /* The rule atoms name `myrule`, so a TerminalNode must realize it
       ([RDSC.8.7]). */
    if (frame_rule_network(&atoms[3], "Trig", "myrule") != 0) return 1;
    buf_t f;
    if (build_file_with_atoms(&f, atoms, 3 + RULE_NETWORK_ATOMS,
            "(deftemplate Trig (slot v))"
            "(defrule myrule (Trig (v 1)) => )") != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("rule meta load", r, DS_OK);

    const struct ds_rule_meta *m = find_rule_meta(e, "myrule");
    if (m == NULL) {
        fprintf(stderr, "FAIL: myrule meta not found\n"); return 1;
    }
    if (!m->has_cool || m->cool_window_ns != 30000000000ULL ||
        !m->has_srcr || strcmp(m->src_file, "x.ds") != 0 ||
        m->src_line != 12 || m->src_col != 5) {
        fprintf(stderr, "FAIL: rule meta fields mismatch\n");
        return 1;
    }

    buf_free(&cool);
    buf_free(&srcr); buf_free(&dsrc_b);
    for (int i = 0; i < 3 + RULE_NETWORK_ATOMS; i++) buf_free(&atoms[i]);
    buf_free(&f);
    ds_engine_free(e);
    return 0;
}

/* ============== Stage D helpers — source-preservation encoders ============== */

static int build_dsrc_body(buf_t *out, const char *file,
                           Ds__V1__Compression compression,
                           const uint8_t *data, size_t data_len)
{
    Ds__V1__DsSource m = DS__V1__DS_SOURCE__INIT;
    m.file = (char *) file;
    m.compression = compression;
    m.data.data = (uint8_t *) data;
    m.data.len = data_len;
    size_t pl = ds__v1__ds_source__get_packed_size(&m);
    uint8_t *b = malloc(pl); if (!b) return -1;
    ds__v1__ds_source__pack(&m, b);
    buf_init(out);
    if (buf_append(out, b, pl) != 0) { free(b); return -1; }
    free(b); return 0;
}

static int build_line_body(buf_t *out, uint32_t node_id, uint32_t ds_line,
                           uint32_t ds_col)
{
    Ds__V1__LineSpan m = DS__V1__LINE_SPAN__INIT;
    m.node_id = node_id;
    m.ds_line = ds_line;
    m.ds_col  = ds_col;
    size_t pl = ds__v1__line_span__get_packed_size(&m);
    uint8_t *b = malloc(pl); if (!b) return -1;
    ds__v1__line_span__pack(&m, b);
    buf_init(out);
    if (buf_append(out, b, pl) != 0) { free(b); return -1; }
    free(b); return 0;
}

/* ============== Stage D scenarios ============== */

/* RDSC.14.2 — DsSource stores DS source on the engine. */
static int test_dsrc_round_trip(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    const char *src = "schema Foo { v Int }";
    buf_t dsrc_b;
    if (build_dsrc_body(&dsrc_b, "main.ds",
                        DS__V1__COMPRESSION__COMPRESSION_NONE,
                        (const uint8_t *) src, strlen(src)) != 0) return 1;
    buf_t atoms[1];
    if (frame_into(&atoms[0], DS_ATOM_DS_SOURCE,&dsrc_b) != 0) return 1;
    buf_t f;
    if (build_file_with_atoms(&f, atoms, 1, "(deftemplate Foo (slot v))") != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("dsrc load", r, DS_OK);
    if (e->n_ds_sources != 1 ||
        strcmp(e->ds_sources[0].file, "main.ds") != 0 ||
        strcmp(e->ds_sources[0].text, src) != 0) {
        fprintf(stderr, "FAIL: DsSource round-trip mismatch\n"); return 1;
    }
    buf_free(&dsrc_b); buf_free(&atoms[0]); buf_free(&f);
    ds_engine_free(e);
    return 0;
}

/* RDSC.4.5.1 — COMPRESSION_ZLIB is retired; a DsSource body declaring a non-NONE
   codec (a legacy zlib .dsc) is rejected with DS_ERR_DSC_DECOMPRESS — the
   runtime carries no decompressor and never attempts to decode. The enum
   value 2 is tombstoned (reserved) in the proto, so it is synthesised raw. */
static int test_dsrc_zlib_body_rejected(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t dsrc_b;
    /* A plausible zlib header (0x78 0x9c) as the body — the runtime must reject
       on the codec, not attempt to inflate it. */
    if (build_dsrc_body(&dsrc_b, "legacy.ds",
                        (Ds__V1__Compression) 2,
                        (const uint8_t *) "\x78\x9c\x00", 3) != 0) return 1;
    buf_t atoms[1];
    if (frame_into(&atoms[0], DS_ATOM_DS_SOURCE,&dsrc_b) != 0) return 1;
    buf_t f;
    if (build_file_with_atoms(&f, atoms, 1, "(deftemplate Foo (slot v))") != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("zlib body rejected", r, DS_ERR_DSC_DECOMPRESS);
    buf_free(&dsrc_b); buf_free(&atoms[0]); buf_free(&f);
    ds_engine_free(e);
    return 0;
}

/* RDSC.14.3 — LineSpan atoms map Rete node_ids to DS spans; load + store,
   then look up by node_id (the diagnostic path). */
static int test_span_node_round_trip(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t s1, s2;
    /* node 7 -> line 21 col 3; node 8 -> line 22 col 9. */
    if (build_line_body(&s1, 7, 21, 3) != 0) return 1;
    if (build_line_body(&s2, 8, 22, 9) != 0) return 1;
    buf_t atoms[2];
    if (frame_into(&atoms[0], DS_ATOM_LINE_SPAN,&s1) != 0) return 1;
    if (frame_into(&atoms[1], DS_ATOM_LINE_SPAN,&s2) != 0) return 1;
    buf_t f;
    if (build_file_with_atoms(&f, atoms, 2, "") != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("span load", r, DS_OK);
    if (e->n_line_spans != 2) {
        fprintf(stderr, "FAIL: expected 2 spans, got %zu\n",
                e->n_line_spans); return 1;
    }
    ds_line_span_view_t lv;
    r = ds_engine_line_span_find(e, 7, &lv);
    EXPECT_LOAD_STATUS("find span node 7", r, DS_OK);
    if (lv.node_id != 7 || lv.ds_line != 21 || lv.ds_col != 3) {
        fprintf(stderr, "FAIL: span node 7 fields wrong\n"); return 1;
    }
    buf_free(&s1); buf_free(&s2); buf_free(&atoms[0]); buf_free(&atoms[1]); buf_free(&f);
    ds_engine_free(e);
    return 0;
}

/* DocString is tooling metadata the engine never reads. The loader
   recognizes the atom and skips it (skip-don't-reject, RDSC.9.4):
   the bundle loads cleanly and the atom contributes no engine state. The
   body is opaque to the runtime (it never decodes DocString), so any
   bytes are accepted. */
static int test_docs_atom_skipped(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t hb; if (build_dsco_body(&hb) != 0) return 1;
    buf_t f; buf_init(&f);
    if (buf_append_atom(&f, DS_ATOM_DSC_HEADER,hb.data, hb.len) != 0) return 1;
    /* Opaque DocString-shaped bytes — never decoded by the runtime. */
    uint8_t docs_body[] = { 0x08, 0x02, 0x10, 0x01 };
    if (buf_append_atom(&f, DS_ATOM_DOC_STRING,docs_body, sizeof docs_body) != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("docs skipped", r, DS_OK);
    if (e->n_line_spans != 0) {
        fprintf(stderr, "FAIL: DocString contributed engine state\n"); return 1;
    }
    buf_free(&hb); buf_free(&f);
    ds_engine_free(e);
    return 0;
}

/* The loader's `dsc-load` log, counted. */
typedef struct {
    int  n;
    char last[192];
} dsc_load_log_t;

static ds_result_t dsc_load_log_cb(ds_engine_t *engine, const ds_log_event_t *ev,
                                   void *user)
{
    (void) engine;
    dsc_load_log_t *p = (dsc_load_log_t *) user;
    if (ev->category != NULL && strcmp(ev->category, "dsc-load") == 0) {
        p->n++;
        p->last[0] = '\0';
        if (ev->message) strncpy(p->last, ev->message, sizeof(p->last) - 1);
    }
    return (ds_result_t){ .status = DS_OK };
}

/* [RDSC.15.1] — DialectInfo is informational and KNOWN, so a load of an
   artefact carrying one writes no `dsc-load` log, as the Mercury runtime
   writes none. */
static int test_dialect_info_loads_without_a_log(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    dsc_load_log_t p = {0};
    if (ds_engine_set_log_callback(e, dsc_load_log_cb, &p).status != DS_OK) {
        fprintf(stderr, "FAIL: set_log_callback\n"); return 1;
    }
    buf_t hb; if (build_dsco_body(&hb) != 0) return 1;
    buf_t f; buf_init(&f);
    if (buf_append_atom(&f, DS_ATOM_DSC_HEADER, hb.data, hb.len) != 0) return 1;
    /* Opaque bytes: the runtime never decodes DialectInfo. */
    uint8_t dial_body[] = { 0x0A, 0x07, 'd','e','f','a','u','l','t' };
    if (buf_append_frame(&f, DS_ATOM_DIALECT_INFO, dial_body, sizeof dial_body) != 0)
        return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("dialect info", r, DS_OK);
    if (p.n != 0) {
        fprintf(stderr, "FAIL: DialectInfo wrote %d dsc-load log(s), the last: %s\n",
                p.n, p.last);
        return 1;
    }
    buf_free(&hb); buf_free(&f);
    ds_engine_free(e);
    return 0;
}

/* [RDSC.15.6] — "At most one `DialectInfo` atom per file. The compiler must
   write no second, and the runtime does not check for one ([RDSC.7.2])".
   One loads, and so do two, as a second
   CapabilityInfo does ([RDSC.16.2.5]). The Mercury runtime's `test_ds.m`
   checks the same two loads. */
static int test_rdsc_15_6__two_dialect_infos_load(void)
{
    uint8_t dial_body[] = { 0x0A, 0x07, 'd','e','f','a','u','l','t' };
    for (int copies = 1; copies <= 2; copies++) {
        ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
        buf_t hb; if (build_dsco_body(&hb) != 0) return 1;
        buf_t f; buf_init(&f);
        if (buf_append_atom(&f, DS_ATOM_DSC_HEADER, hb.data, hb.len) != 0) return 1;
        for (int i = 0; i < copies; i++) {
            if (buf_append_frame(&f, DS_ATOM_DIALECT_INFO, dial_body,
                                 sizeof dial_body) != 0)
                return 1;
        }
        ds_result_t r = load_sealed(e, &f);
        if (copies == 1) {
            EXPECT_LOAD_STATUS("[RDSC.15.6] one DialectInfo", r, DS_OK);
        } else {
            EXPECT_LOAD_STATUS("[RDSC.15.6] two DialectInfo", r, DS_OK);
        }
        buf_free(&hb); buf_free(&f);
        ds_engine_free(e);
    }
    return 0;
}

/* [RDSC.9.4] — an UNRECOGNISED skip-band atom is skipped AND logged at
   info, category `dsc-load`, naming the field number and the byte offset its
   frame starts at. The Mercury runtime's `test_ds.m` checks the same line. */
static int test_rdsc_9_4__unrecognised_skip_is_logged(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    dsc_load_log_t p = {0};
    if (ds_engine_set_log_callback(e, dsc_load_log_cb, &p).status != DS_OK) {
        fprintf(stderr, "FAIL: set_log_callback\n"); return 1;
    }
    buf_t hb; if (build_dsco_body(&hb) != 0) return 1;
    buf_t f; buf_init(&f);
    if (buf_append_atom(&f, DS_ATOM_DSC_HEADER, hb.data, hb.len) != 0) return 1;
    size_t at = f.len;
    if (buf_append_unknown_atom(&f, 2000u) != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("[RDSC.9.4] unrecognised skip", r, DS_OK);
    char want[64];
    snprintf(want, sizeof want, "byte offset %zu", at);
    if (p.n != 1 || strstr(p.last, "2000") == NULL
            || strstr(p.last, want) == NULL) {
        fprintf(stderr, "FAIL: %d dsc-load log(s), want 1 naming 2000 and %s; "
                "the last: %s\n", p.n, want, p.last);
        return 1;
    }
    buf_free(&hb); buf_free(&f);
    ds_engine_free(e);
    return 0;
}

/* A KNOWN atom the loader has no handler for is skipped with a
   log that names it: the field number, the registry's message name and the
   byte offset ([RDSC.9.4]). TestCase is one: compiled `.dstest` carries it and
   the engine does not run tests. */
static int test_unread_known_atom_log_names_it(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    dsc_load_log_t p = {0};
    if (ds_engine_set_log_callback(e, dsc_load_log_cb, &p).status != DS_OK) {
        fprintf(stderr, "FAIL: set_log_callback\n"); return 1;
    }
    buf_t hb; if (build_dsco_body(&hb) != 0) return 1;
    buf_t f; buf_init(&f);
    if (buf_append_atom(&f, DS_ATOM_DSC_HEADER, hb.data, hb.len) != 0) return 1;
    uint8_t tcas_body[] = { 0x0A, 0x01, 't' };
    if (buf_append_frame(&f, DS_ATOM_TEST_CASE, tcas_body, sizeof tcas_body) != 0)
        return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("unread known atom", r, DS_OK);
    if (p.n != 1) {
        fprintf(stderr, "FAIL: %d dsc-load log(s) for one unread atom, want 1\n", p.n);
        return 1;
    }
    if (strstr(p.last, "317") == NULL || strstr(p.last, "TestCase") == NULL
            || strstr(p.last, "byte offset") == NULL
            || strstr(p.last, "unknown magic") != NULL) {
        fprintf(stderr, "FAIL: the log does not name the atom: %s\n", p.last);
        return 1;
    }
    buf_free(&hb); buf_free(&f);
    ds_engine_free(e);
    return 0;
}

/* ============== RDSC.4c.3: a CompiledCode atom is skipped ============== */

/* The `arch` this build's own CompiledCode would carry ([RAOT.5.2]), so the
   atom below is one a runtime that ran compiled code would take for its own,
   map and wire. */
#if defined(__x86_64__) || defined(_M_X64)
#  define RDSC_4C_3_ARCH "amd64"
#elif defined(__aarch64__) || defined(_M_ARM64)
#  define RDSC_4C_3_ARCH "arm64"
#elif defined(__riscv) && (__riscv_xlen == 64)
#  define RDSC_4C_3_ARCH "rv64g"
#else
#  define RDSC_4C_3_ARCH "unknown"
#endif

/* One run of the artefact: logical S(v), ttl Out(v), AlphaNode 1 over S,
   BetaNode 2 joining the root to it, and TerminalNode 3 (rule `r`) asserting
   Out(v = 1). With `with_code`, a CompiledCode atom follows them, carrying an
   RHS for TerminalNode 3, and *out_at is its frame's byte offset.

   Loads the artefact, refuses a node with a compiled-code hook set BEFORE any
   pump, so the bytes are never run, then asserts S(v = 1), pumps, and leaves
   the fact count in *out_facts. The dsc-load lines go to `log`. Nonzero when
   a check fails. */
static int rdsc_4c_3_run(bool with_code, size_t *out_facts,
                         dsc_load_log_t *log, size_t *out_at)
{
    ds_engine_t *e = NULL;
    if (new_engine(&e)) return 1;
    if (ds_engine_set_log_callback(e, dsc_load_log_cb, log).status != DS_OK) {
        fprintf(stderr, "FAIL: [RDSC.4c.3] set_log_callback\n");
        return 1;
    }

    buf_t slog_b, slot_s, sttl_b, slot_o, alfa_b, beta_b, term_b, f;
    buf_t atoms[7];
    if (build_slog_body(&slog_b, "S") != 0) return 1;
    if (build_slot_body(&slot_s, "S", "v",
                        DS__V1__SLOT_KIND__SLOT_KIND_INT, NULL) != 0) return 1;
    if (build_sttl_body(&sttl_b, "Out", UINT64_C(60000000000)) != 0) return 1;
    if (build_slot_body(&slot_o, "Out", "v",
                        DS__V1__SLOT_KIND__SLOT_KIND_INT, NULL) != 0) return 1;

    Ds__V1__AlphaNode a = DS__V1__ALPHA_NODE__INIT;
    a.node_id = 1;
    a.schema_name = (char *) "S";
    Ds__V1__BetaNode b = DS__V1__BETA_NODE__INIT;
    b.node_id = 2;
    b.right_alpha_id = 1;
    b.left_parent_id = 0;
    Ds__V1__Expr one = DS__V1__EXPR__INIT;
    one.kind_case = DS__V1__EXPR__KIND_LIT_INT;
    one.lit_int = 1;
    Ds__V1__SlotAssign sa = DS__V1__SLOT_ASSIGN__INIT;
    sa.slot_index = 0;
    sa.expr = &one;
    Ds__V1__SlotAssign *sas[1] = { &sa };
    Ds__V1__Action act = DS__V1__ACTION__INIT;
    act.kind = DS__V1__ACTION_KIND__ACTION_ASSERT;
    act.schema_name = (char *) "Out";
    act.n_assigns = 1;
    act.assigns = sas;
    Ds__V1__Action *actions[1] = { &act };
    Ds__V1__TerminalNode t = DS__V1__TERMINAL_NODE__INIT;
    t.node_id = 3;
    t.parent_beta_id = 2;
    t.rule_name = (char *) "r";
    t.n_actions = 1;
    t.actions = actions;

    uint8_t pk[512];
    buf_init(&alfa_b);
    buf_append(&alfa_b, pk, ds__v1__alpha_node__pack(&a, pk));
    buf_init(&beta_b);
    buf_append(&beta_b, pk, ds__v1__beta_node__pack(&b, pk));
    if (ds__v1__terminal_node__get_packed_size(&t) > sizeof pk) return 1;
    buf_init(&term_b);
    buf_append(&term_b, pk, ds__v1__terminal_node__pack(&t, pk));

    if (frame_into(&atoms[0], DS_ATOM_SCHEMA_LOGICAL, &slog_b) != 0) return 1;
    if (frame_into(&atoms[1], DS_ATOM_SLOT, &slot_s) != 0) return 1;
    if (frame_into(&atoms[2], DS_ATOM_SCHEMA_TTL, &sttl_b) != 0) return 1;
    if (frame_into(&atoms[3], DS_ATOM_SLOT, &slot_o) != 0) return 1;
    if (frame_into(&atoms[4], DS_ATOM_ALPHA_NODE, &alfa_b) != 0) return 1;
    if (frame_into(&atoms[5], DS_ATOM_BETA_NODE, &beta_b) != 0) return 1;
    if (frame_into(&atoms[6], DS_ATOM_TERMINAL_NODE, &term_b) != 0) return 1;
    if (build_file_with_atoms(&f, atoms, 7, NULL) != 0) return 1;

    if (with_code) {
        /* CompiledCode (`proto/dsc/aot.proto`): arch = 1, node_id = 2,
           kind = 3 (3 is RHS), body = 4. The body is a zeroed 64-byte slot
           table and 16 bytes after it, the shape a runtime that maps RHS
           code takes. */
        static const uint8_t code_body[80];
        size_t arch_len = strlen(RDSC_4C_3_ARCH);
        uint8_t arch_hdr[2] = { 0x0A, (uint8_t) arch_len };
        static const uint8_t ids[6] = { 0x10, 3, 0x18, 3, 0x22, 80 };
        buf_t cc;
        buf_init(&cc);
        if (buf_append(&cc, arch_hdr, sizeof arch_hdr) != 0
            || buf_append(&cc, RDSC_4C_3_ARCH, arch_len) != 0
            || buf_append(&cc, ids, sizeof ids) != 0
            || buf_append(&cc, code_body, sizeof code_body) != 0)
            return 1;
        *out_at = f.len;
        if (buf_append_frame(&f, DS_ATOM_COMPILED_CODE, cc.data, cc.len) != 0)
            return 1;
        buf_free(&cc);
    }

    ds_result_t r = load_sealed(e, &f);
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: [RDSC.4c.3] load (%s): status=%d %s\n",
                with_code ? "with CompiledCode" : "control", r.status,
                r.detail ? r.detail : "");
        return 1;
    }

    /* No node runs compiled code: every hook is still NULL. Checked before
       the pump, so a loader that wired the atom fails here and never jumps
       into its bytes. */
    const ds_rete_engine_t *re = e->rete_engine;
    for (uint32_t i = 0; i < re->owned_alpha_count; i++) {
        if (re->owned_alphas[i]->alpha_fn != NULL) {
            fprintf(stderr, "FAIL: [RDSC.4c.3] an AlphaNode carries compiled "
                    "code\n");
            return 1;
        }
    }
    for (uint32_t i = 0; i < re->owned_beta_count; i++) {
        if (re->owned_betas[i]->join_fn != NULL) {
            fprintf(stderr, "FAIL: [RDSC.4c.3] a BetaNode carries compiled "
                    "code\n");
            return 1;
        }
    }
    for (uint32_t i = 0; i < re->owned_terminal_count; i++) {
        if (re->owned_terminals[i]->rhs_fn != NULL) {
            fprintf(stderr, "FAIL: [RDSC.4c.3] TerminalNode %u carries "
                    "compiled code\n",
                    (unsigned) re->owned_terminals[i]->node_id);
            return 1;
        }
    }

    const ds_schema_t *s = NULL;
    if (ds_engine_schema_find(e, "S", &s).status != DS_OK || s == NULL) {
        fprintf(stderr, "FAIL: [RDSC.4c.3] no schema S\n");
        return 1;
    }
    ds_slot_value_t v[1] = { { .kind = DS_SLOT_INT, .v.i = 1 } };
    ds_fact_t *fact = NULL;
    if (ds_engine_assert(e, s, v, 1, &fact).status != DS_OK
        || ds_engine_pump(e).status != DS_OK
        || ds_engine_fact_count(e, out_facts).status != DS_OK) {
        fprintf(stderr, "FAIL: [RDSC.4c.3] assert, pump or fact_count\n");
        return 1;
    }

    buf_free(&slog_b); buf_free(&slot_s); buf_free(&sttl_b); buf_free(&slot_o);
    buf_free(&alfa_b); buf_free(&beta_b); buf_free(&term_b);
    for (int i = 0; i < 7; i++) buf_free(&atoms[i]);
    buf_free(&f);
    ds_engine_free(e);
    return 0;
}

/* [RDSC.4c.3] — in this edition a runtime skips every CompiledCode atom: it
   logs it as [RDSC.9.4] logs an unrecognised skip-band atom, maps and wires
   nothing, and interprets every node, so the artefact behaves as it does
   without the atom. The atom is a well-formed RHS for this build's arch on
   the network's one terminal. The control is the same artefact without it.
   The Mercury runtime's test_ds.m (test_no_aot) checks the same line. */
/* @spec [RDSC.4c.3] */
static int test_rdsc_4c_3__compiled_code_atom_is_skipped(void)
{
    dsc_load_log_t plain = {0};
    dsc_load_log_t coded = {0};
    size_t plain_facts = 0;
    size_t coded_facts = 0;
    size_t at = 0;

    if (rdsc_4c_3_run(false, &plain_facts, &plain, &at) != 0) return 1;
    if (plain_facts != 2 || plain.n != 0) {
        fprintf(stderr, "FAIL: [RDSC.4c.3] control: %zu facts (want S and Out),"
                " %d dsc-load line(s)\n", plain_facts, plain.n);
        return 1;
    }

    if (rdsc_4c_3_run(true, &coded_facts, &coded, &at) != 0) return 1;
    if (coded_facts != plain_facts) {
        fprintf(stderr, "FAIL: [RDSC.4c.3] %zu facts with the atom, %zu "
                "without: the interpreted rule did not fire as it does "
                "without it\n", coded_facts, plain_facts);
        return 1;
    }
    char want[160];
    snprintf(want, sizeof want, "skipping atom 298 (CompiledCode) at byte "
             "offset %zu: this edition runs no compiled code (RDSC.4c.3)", at);
    if (coded.n != 1 || strcmp(coded.last, want) != 0) {
        fprintf(stderr, "FAIL: [RDSC.4c.3] %d dsc-load line(s), want 1:\n"
                "  want: %s\n  last: %s\n", coded.n, want, coded.last);
        return 1;
    }
    return 0;
}

/* RDSC.5/6/14 — public introspection round-trip. Build a .dsc with
 * one schema (TTL+Slot+SchemaSource+SchemaDef+Hydration), one rule (RuleCooldown), one
 * DsSource, one LineSpan; load and verify every public accessor returns the
 * spec'd value through the opaque schema/engine. */
static int test_introspection_round_trip(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t sttl, slot, srcs, sdef, hydr, cool, dsrc, line;
    if (build_sttl_body(&sttl, "Q", 1000) != 0) return 1;
    if (build_slot_body(&slot, "Q", "v",
                        DS__V1__SLOT_KIND__SLOT_KIND_INT, NULL) != 0) return 1;
    if (build_srcs_body(&srcs, "Q", "main.ds", 7, 3) != 0) return 1;
    const char *proto = "syntax = \"proto3\"; message Q { int64 v = 1; }";
    if (build_sdef_body(&sdef, "Q",
                        DS__V1__COMPRESSION__COMPRESSION_NONE,
                        (const uint8_t *) proto, strlen(proto)) != 0) return 1;
    if (build_hydr_body(&hydr, "Q", "v") != 0) return 1;
    if (build_cool_body(&cool, "rA", 5000) != 0) return 1;
    if (build_dsrc_body(&dsrc, "main.ds",
                        DS__V1__COMPRESSION__COMPRESSION_NONE,
                        (const uint8_t *) "schema Q { v Int }", 18) != 0) return 1;
    if (build_line_body(&line, 3, 5, 1) != 0) return 1;

    buf_t atoms[8 + RULE_NETWORK_ATOMS];
    if (frame_into(&atoms[0], DS_ATOM_SCHEMA_TTL,&sttl) != 0) return 1;
    if (frame_into(&atoms[1], DS_ATOM_SLOT,&slot) != 0) return 1;
    if (frame_into(&atoms[2], DS_ATOM_SCHEMA_SOURCE,&srcs) != 0) return 1;
    if (frame_into(&atoms[3], DS_ATOM_SCHEMA_DEF,&sdef) != 0) return 1;
    if (frame_into(&atoms[4], DS_ATOM_HYDRATION,&hydr) != 0) return 1;
    if (frame_into(&atoms[5], DS_ATOM_RULE_COOLDOWN,&cool) != 0) return 1;
    if (frame_into(&atoms[6], DS_ATOM_DS_SOURCE,&dsrc) != 0) return 1;
    if (frame_into(&atoms[7], DS_ATOM_LINE_SPAN,&line) != 0) return 1;
    /* The RuleCooldown names `rA`, so a TerminalNode must realize it
       ([RDSC.8.7]), over a schema of its own. */
    if (frame_rule_network(&atoms[8], "RuleHost", "rA") != 0) return 1;

    buf_t f;
    if (build_file_with_atoms(&f, atoms, 8 + RULE_NETWORK_ATOMS,
            "(deftemplate Q (slot v))\n(defrule rA (Q (v 1)) => )") != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("load", r, DS_OK);

    /* Schema introspection. */
    const ds_schema_t *q = NULL;
    r = ds_engine_schema_find(e, "Q", &q); EXPECT_LOAD_STATUS("find Q", r, DS_OK);
    if (q == NULL) { fprintf(stderr, "FAIL: Q missing\n"); return 1; }

    const char *name = NULL;
    r = ds_schema_get_name(q, &name); EXPECT_LOAD_STATUS("name", r, DS_OK);
    if (strcmp(name, "Q") != 0) { fprintf(stderr, "FAIL: name=%s\n", name); return 1; }

    ds_schema_lifecycle_t lc;
    r = ds_schema_get_lifecycle(q, &lc); EXPECT_LOAD_STATUS("lc", r, DS_OK);
    if (lc != DS_SCHEMA_LIFECYCLE_TTL) { fprintf(stderr, "FAIL: lc=%d\n", lc); return 1; }

    uint64_t ttl;
    r = ds_schema_get_ttl_ns(q, &ttl); EXPECT_LOAD_STATUS("ttl", r, DS_OK);
    if (ttl != 1000) { fprintf(stderr, "FAIL: ttl=%llu\n", (unsigned long long) ttl); return 1; }

    uint32_t n_slots;
    r = ds_schema_get_slot_count(q, &n_slots); EXPECT_LOAD_STATUS("nslots", r, DS_OK);
    if (n_slots != 1) { fprintf(stderr, "FAIL: nslots=%u\n", n_slots); return 1; }

    ds_slot_desc_t s0;
    r = ds_schema_get_slot(q, 0, &s0); EXPECT_LOAD_STATUS("slot 0", r, DS_OK);
    if (strcmp(s0.name, "v") != 0 || s0.type != DS_SLOT_TYPE_INT ||
        !s0.hydration_eligible) {
        fprintf(stderr, "FAIL: slot 0 fields wrong\n"); return 1;
    }

    const char *src_file = NULL; uint32_t s_line = 0, s_col = 0;
    r = ds_schema_get_source(q, &src_file, &s_line, &s_col);
    EXPECT_LOAD_STATUS("source", r, DS_OK);
    if (src_file == NULL || strcmp(src_file, "main.ds") != 0 ||
        s_line != 7 || s_col != 3) {
        fprintf(stderr, "FAIL: source mismatch\n"); return 1;
    }

    const char *proto_text = NULL; size_t proto_len = 0;
    r = ds_schema_get_proto_source(q, &proto_text, &proto_len);
    EXPECT_LOAD_STATUS("proto", r, DS_OK);
    if (proto_text == NULL || strcmp(proto_text, proto) != 0) {
        fprintf(stderr, "FAIL: proto mismatch\n"); return 1;
    }

    /* Rule meta. */
    ds_rule_meta_view_t v; bool found = false;
    r = ds_engine_rule_meta_find(e, "rA", &v, &found);
    EXPECT_LOAD_STATUS("rule_meta_find", r, DS_OK);
    if (!found || !v.has_cool || v.cool_window_ns != 5000) {
        fprintf(stderr, "FAIL: rule meta fields wrong\n"); return 1;
    }

    /* DS source + line span. */
    size_t n;
    r = ds_engine_ds_source_count(e, &n); EXPECT_LOAD_STATUS("dsrc count", r, DS_OK);
    if (n != 1) { fprintf(stderr, "FAIL: dsrc count=%zu\n", n); return 1; }
    ds_ds_source_view_t dv;
    r = ds_engine_ds_source_at(e, 0, &dv); EXPECT_LOAD_STATUS("dsrc 0", r, DS_OK);
    if (strcmp(dv.file, "main.ds") != 0 ||
        strncmp(dv.text, "schema Q", 8) != 0) {
        fprintf(stderr, "FAIL: dsrc fields wrong\n"); return 1;
    }
    r = ds_engine_line_span_count(e, &n); EXPECT_LOAD_STATUS("line count", r, DS_OK);
    if (n != 1) { fprintf(stderr, "FAIL: line count=%zu\n", n); return 1; }
    ds_line_span_view_t lv;
    r = ds_engine_line_span_at(e, 0, &lv); EXPECT_LOAD_STATUS("line 0", r, DS_OK);
    if (lv.node_id != 3 || lv.ds_line != 5 || lv.ds_col != 1 ||
        strcmp(lv.ds_file, "main.ds") != 0) {
        fprintf(stderr, "FAIL: line span fields wrong\n"); return 1;
    }

    buf_free(&sttl); buf_free(&slot); buf_free(&srcs); buf_free(&sdef);
    buf_free(&hydr); buf_free(&cool);
    buf_free(&dsrc); buf_free(&line);
    for (int i = 0; i < 8 + RULE_NETWORK_ATOMS; i++) buf_free(&atoms[i]);
    buf_free(&f);
    ds_engine_free(e);
    return 0;
}

/* ---- RuleDebugName builder + round-trip test -------------------------------- */

static int build_dnam_body(buf_t *out, const char *rule, const char *tmpl)
{
    Ds__V1__RuleDebugName m = DS__V1__RULE_DEBUG_NAME__INIT;
    m.rule_name = (char *) rule;
    m.name_template = (char *) tmpl;
    size_t pl = ds__v1__rule_debug_name__get_packed_size(&m);
    uint8_t *b = malloc(pl); if (!b) return -1;
    ds__v1__rule_debug_name__pack(&m, b);
    buf_init(out);
    if (buf_append(out, b, pl) != 0) { free(b); return -1; }
    free(b); return 0;
}

static int test_dnam_round_trip(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t dnam;
    if (build_dnam_body(&dnam, "myrule",
                        "myrule(s={s.entity_id})") != 0) return 1;
    buf_t atoms[1 + RULE_NETWORK_ATOMS];
    if (frame_into(&atoms[0], DS_ATOM_RULE_DEBUG_NAME,&dnam) != 0) return 1;
    if (frame_rule_network(&atoms[1], "Trig", "myrule") != 0) return 1;
    buf_t f;
    if (build_file_with_atoms(&f, atoms, 1 + RULE_NETWORK_ATOMS,
            "(deftemplate Trig (slot v))"
            "(defrule myrule (Trig (v 1)) => )") != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("dnam round trip", r, DS_OK);
    const struct ds_rule_meta *m = find_rule_meta(e, "myrule");
    if (m == NULL) {
        fprintf(stderr, "FAIL: dnam round trip: myrule not found\n"); return 1;
    }
    if (!m->has_dnam ||
        m->debug_name_template == NULL ||
        strcmp(m->debug_name_template, "myrule(s={s.entity_id})") != 0) {
        fprintf(stderr, "FAIL: dnam round trip: template mismatch: has_dnam=%d tmpl=%s\n",
                (int)m->has_dnam, m->debug_name_template ? m->debug_name_template : "(null)");
        return 1;
    }
    buf_free(&dnam);
    for (int i = 0; i < 1 + RULE_NETWORK_ATOMS; i++) buf_free(&atoms[i]);
    buf_free(&f);
    ds_engine_free(e);
    printf("  pass: test_dnam_round_trip\n");
    return 0;
}

/* RDSC.7.2.1 -- a second RuleDebugName for one rule is not checked
   for: the artefact loads, and the rule keeps one of the two templates.
   Which one is unstated, so it is not pinned; what is pinned is that the
   replaced template is neither leaked nor read after it is freed (asan and
   memcheck run this suite). */
static int test_dnam_duplicate_loads(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t dnam1, dnam2;
    if (build_dnam_body(&dnam1, "myrule", "first") != 0) return 1;
    if (build_dnam_body(&dnam2, "myrule", "second") != 0) return 1;
    buf_t atoms[2 + RULE_NETWORK_ATOMS];
    if (frame_into(&atoms[0], DS_ATOM_RULE_DEBUG_NAME, &dnam1) != 0) return 1;
    if (frame_into(&atoms[1], DS_ATOM_RULE_DEBUG_NAME, &dnam2) != 0) return 1;
    if (frame_rule_network(&atoms[2], "Trig", "myrule") != 0) return 1;
    buf_t f;
    if (build_file_with_atoms(&f, atoms, 2 + RULE_NETWORK_ATOMS,
            "(deftemplate Trig (slot v))"
            "(defrule myrule (Trig (v 1)) => )") != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("dnam duplicate", r, DS_OK);
    const struct ds_rule_meta *m = find_rule_meta(e, "myrule");
    if (m == NULL || !m->has_dnam || m->debug_name_template == NULL ||
        (strcmp(m->debug_name_template, "first") != 0 &&
         strcmp(m->debug_name_template, "second") != 0)) {
        fprintf(stderr, "FAIL: dnam duplicate: template %s, want first or second\n",
                m && m->debug_name_template ? m->debug_name_template : "(null)");
        ds_engine_free(e); return 1;
    }
    buf_free(&dnam1); buf_free(&dnam2);
    for (int i = 0; i < 2 + RULE_NETWORK_ATOMS; i++) buf_free(&atoms[i]);
    buf_free(&f);
    ds_engine_free(e);
    printf("  pass: test_dnam_duplicate_loads\n");
    return 0;
}

/* ============== A malformed Expr is refused at load ============== */

/* The smallest network that reaches the Expr decoder: one logical schema S(v),
   AlphaNode 1 over it, BetaNode 2 joining the root to AlphaNode 1, and
   TerminalNode 3 under BetaNode 2 whose `fire_guard` is the Expr under test. The guard is the decoder's one
   entry with nothing around it — no action kind, no schema lookup — so what a
   case measures is the Expr and nothing else.

   `raw_guard`, when given, is appended to the packed TerminalNode as field 7
   verbatim: the one way to put bytes on the wire that protobuf-c's own structs cannot
   express, such as an Expr carrying only a field this tree has `reserved`. */
static ds_result_t load_term(const Ds__V1__Expr *guard,
                             const uint8_t *raw_guard, size_t raw_len,
                             Ds__V1__Action *action);

static ds_result_t load_with_guard(const Ds__V1__Expr *guard,
                                   const uint8_t *raw_guard, size_t raw_len)
{
    return load_term(guard, raw_guard, raw_len, NULL);
}

/* `load_with_guard`'s network, with `action`, when given, as TerminalNode 3's
   one action, and `beta_test`, when given, as BetaNode 2's one join test. */
static ds_result_t load_net(const Ds__V1__Expr *guard,
                            const uint8_t *raw_guard, size_t raw_len,
                            Ds__V1__Action *action, Ds__V1__Expr *beta_test);

static ds_result_t load_term(const Ds__V1__Expr *guard,
                             const uint8_t *raw_guard, size_t raw_len,
                             Ds__V1__Action *action)
{
    return load_net(guard, raw_guard, raw_len, action, NULL);
}

static ds_result_t load_net(const Ds__V1__Expr *guard,
                            const uint8_t *raw_guard, size_t raw_len,
                            Ds__V1__Action *action, Ds__V1__Expr *beta_test)
{
    ds_result_t fail = DS_ERR_R(DS_ERR_INVAL, "test fixture did not build");
    ds_engine_t *e = NULL;
    if (new_engine(&e)) return fail;

    buf_t slog_b, slot_b, alfa_b, beta_b, term_b, f;
    buf_t atoms[5];
    if (build_slog_body(&slog_b, "S") != 0) return fail;
    if (build_slot_body(&slot_b, "S", "v",
                        DS__V1__SLOT_KIND__SLOT_KIND_INT, NULL) != 0) return fail;

    Ds__V1__AlphaNode a = DS__V1__ALPHA_NODE__INIT;
    a.node_id = 1;
    a.schema_name = (char *) "S";
    Ds__V1__BetaNode b = DS__V1__BETA_NODE__INIT;
    b.node_id = 2;
    b.right_alpha_id = 1;
    b.left_parent_id = 0;
    Ds__V1__Expr *tests[1] = { beta_test };
    if (beta_test != NULL) {
        b.n_join_tests = 1;
        b.join_tests = tests;
    }
    Ds__V1__TerminalNode t = DS__V1__TERMINAL_NODE__INIT;
    t.node_id = 3;
    t.parent_beta_id = 2;
    t.rule_name = (char *) "r";
    t.fire_guard = (Ds__V1__Expr *) guard;
    Ds__V1__Action *actions[1] = { action };
    if (action != NULL) {
        t.n_actions = 1;
        t.actions = actions;
    }

    uint8_t pk[512];
    buf_init(&alfa_b);
    buf_append(&alfa_b, pk, ds__v1__alpha_node__pack(&a, pk));
    buf_init(&beta_b);
    buf_append(&beta_b, pk, ds__v1__beta_node__pack(&b, pk));
    if (ds__v1__terminal_node__get_packed_size(&t) > sizeof pk) return fail;
    buf_init(&term_b);
    buf_append(&term_b, pk, ds__v1__terminal_node__pack(&t, pk));
    if (raw_guard != NULL) {
        uint8_t hdr[2] = { (7u << 3) | 2u, (uint8_t) raw_len };
        if (raw_len > 127) return fail;
        buf_append(&term_b, hdr, sizeof hdr);
        buf_append(&term_b, raw_guard, raw_len);
    }

    if (frame_into(&atoms[0], DS_ATOM_SCHEMA_LOGICAL,&slog_b) != 0) return fail;
    if (frame_into(&atoms[1], DS_ATOM_SLOT,&slot_b) != 0) return fail;
    if (frame_into(&atoms[2], DS_ATOM_ALPHA_NODE,&alfa_b) != 0) return fail;
    if (frame_into(&atoms[3], DS_ATOM_BETA_NODE,&beta_b) != 0) return fail;
    if (frame_into(&atoms[4], DS_ATOM_TERMINAL_NODE,&term_b) != 0) return fail;
    if (build_file_with_atoms(&f, atoms, 5, NULL) != 0) return fail;

    ds_result_t r = load_sealed(e, &f);

    buf_free(&slog_b); buf_free(&slot_b);
    buf_free(&alfa_b); buf_free(&beta_b); buf_free(&term_b);
    for (int i = 0; i < 5; i++) buf_free(&atoms[i]);
    buf_free(&f);
    ds_engine_free(e);
    return r;
}

/* Every case is a pair with a loading control, so a refusal is the defect the
   case names and not a fixture that never built — load_with_guard's own
   failure answers DS_ERR_INVAL, which no case below expects. */
static int test_rdsc_11_1__malformed_expr_refused_at_load(void)
{
    int fails = 0;

    /* CONTROL: a well-formed guard loads. */
    Ds__V1__Expr ok = DS__V1__EXPR__INIT;
    ok.kind_case = DS__V1__EXPR__KIND_LIT_BOOL;
    ok.lit_bool = 1;
    ds_result_t r = load_with_guard(&ok, NULL, 0);
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: control guard: status=%d %s\n", r.status,
                r.detail ? r.detail : "");
        return 1;   /* nothing below means anything */
    }

    /* An Expr with no oneof member set. */
    Ds__V1__Expr empty = DS__V1__EXPR__INIT;
    r = load_with_guard(&empty, NULL, 0);
    if (r.status != DS_ERR_DSC_SEMANTIC) {
        fprintf(stderr, "FAIL: empty Expr: status=%d (want %d) %s\n",
                r.status, DS_ERR_DSC_SEMANTIC, r.detail ? r.detail : "");
        fails++;
    }

    /* The shape an artefact from another series has: an Expr whose only field
       is `str_cat` = 9, reserved here. protobuf-c keeps it as an unknown field
       and reports no member set. */
    static const uint8_t str_cat[] = { (9u << 3) | 2u, 0x00 };
    r = load_with_guard(NULL, str_cat, sizeof str_cat);
    if (r.status != DS_ERR_DSC_SEMANTIC) {
        fprintf(stderr, "FAIL: reserved str_cat Expr: status=%d (want %d) %s\n",
                r.status, DS_ERR_DSC_SEMANTIC, r.detail ? r.detail : "");
        fails++;
    }

    /* A binop with its right operand absent. CONTROL first: both present. */
    Ds__V1__Expr one = DS__V1__EXPR__INIT;
    one.kind_case = DS__V1__EXPR__KIND_LIT_INT;
    one.lit_int = 1;
    Ds__V1__BinopExpr bo = DS__V1__BINOP_EXPR__INIT;
    bo.op = DS__V1__BINOP_OP__BINOP_GT;
    bo.left = &one;
    bo.right = &one;
    Ds__V1__Expr bx = DS__V1__EXPR__INIT;
    bx.kind_case = DS__V1__EXPR__KIND_BINOP;
    bx.binop = &bo;
    r = load_with_guard(&bx, NULL, 0);
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: binop control: status=%d %s\n", r.status,
                r.detail ? r.detail : "");
        fails++;
    }
    bo.right = NULL;
    r = load_with_guard(&bx, NULL, 0);
    if (r.status != DS_ERR_DSC_SEMANTIC) {
        fprintf(stderr, "FAIL: binop missing right: status=%d (want %d) %s\n",
                r.status, DS_ERR_DSC_SEMANTIC, r.detail ? r.detail : "");
        fails++;
    }

    /* `is` with the proto3-zero subject: the body decoded, so it is a rule
       violation (SEMANTIC), not a decode failure (RETP_INVALID). CONTROL: the
       same test with a real subject loads. */
    Ds__V1__Expr nul = DS__V1__EXPR__INIT;
    nul.kind_case = DS__V1__EXPR__KIND_LIT_NULL;
    nul.lit_null = 1;
    Ds__V1__IsTestExpr it = DS__V1__IS_TEST_EXPR__INIT;
    it.operand = &nul;
    it.subject = DS__V1__IS_SUBJECT__IS_SUBJECT_NULL;
    Ds__V1__Expr ix = DS__V1__EXPR__INIT;
    ix.kind_case = DS__V1__EXPR__KIND_IS_TEST;
    ix.is_test = &it;
    r = load_with_guard(&ix, NULL, 0);
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: is_test control: status=%d %s\n", r.status,
                r.detail ? r.detail : "");
        fails++;
    }
    it.subject = DS__V1__IS_SUBJECT__IS_SUBJECT_UNSPECIFIED;
    r = load_with_guard(&ix, NULL, 0);
    if (r.status != DS_ERR_DSC_SEMANTIC) {
        fprintf(stderr, "FAIL: is_test unspecified subject: status=%d (want %d) %s\n",
                r.status, DS_ERR_DSC_SEMANTIC, r.detail ? r.detail : "");
        fails++;
    }

    /* An interpolation whose ValuePrim has no value. CONTROL: with one. */
    Ds__V1__ValuePrim vp = DS__V1__VALUE_PRIM__INIT;
    vp.value = &one;
    Ds__V1__FormatPrim fp = DS__V1__FORMAT_PRIM__INIT;
    fp.prim_case = DS__V1__FORMAT_PRIM__PRIM_VALUE;
    fp.value = &vp;
    Ds__V1__FormatPrim *fps[1] = { &fp };
    Ds__V1__InterpExpr ie = DS__V1__INTERP_EXPR__INIT;
    ie.n_prims = 1;
    ie.prims = fps;
    Ds__V1__Expr ip = DS__V1__EXPR__INIT;
    ip.kind_case = DS__V1__EXPR__KIND_INTERP;
    ip.interp = &ie;
    r = load_with_guard(&ip, NULL, 0);
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: ValuePrim control: status=%d %s\n", r.status,
                r.detail ? r.detail : "");
        fails++;
    }
    vp.value = NULL;
    r = load_with_guard(&ip, NULL, 0);
    if (r.status != DS_ERR_DSC_SEMANTIC) {
        fprintf(stderr, "FAIL: ValuePrim with no value: status=%d (want %d) %s\n",
                r.status, DS_ERR_DSC_SEMANTIC, r.detail ? r.detail : "");
        fails++;
    }

    return fails;
}

/* ============== RDSC.11.3: an Expr the artefact does not state ============== */

/* A guard that is `n` nested `not`s over `true`: the outermost Expr is at
   depth 0, so the literal sits at depth `n`. */
#define DEPTH_CHAIN_MAX 49
typedef struct {
    Ds__V1__Expr     expr[DEPTH_CHAIN_MAX + 1];
    Ds__V1__UnopExpr unop[DEPTH_CHAIN_MAX];
} depth_chain_t;

static Ds__V1__Expr *depth_chain(depth_chain_t *c, int n)
{
    Ds__V1__Expr init = DS__V1__EXPR__INIT;
    Ds__V1__UnopExpr uinit = DS__V1__UNOP_EXPR__INIT;
    c->expr[n] = init;
    c->expr[n].kind_case = DS__V1__EXPR__KIND_LIT_BOOL;
    c->expr[n].lit_bool = 1;
    for (int i = n - 1; i >= 0; i--) {
        c->unop[i] = uinit;
        c->unop[i].op = DS__V1__UNOP_OP__UNOP_NOT;
        c->unop[i].operand = &c->expr[i + 1];
        c->expr[i] = init;
        c->expr[i].kind_case = DS__V1__EXPR__KIND_UNOP;
        c->expr[i].unop = &c->unop[i];
    }
    return &c->expr[0];
}

/* [RDSC.11.3]: an Expr nested deeper than 48 and a SlotAssign with no `expr`
   are refused with DS_ERR_DSC_SEMANTIC; depth 48 loads. The empty Expr is
   test_rdsc_11_1__malformed_expr_refused_at_load's first case. The Mercury
   runtime is held to the same (test_ds.m, `[RDSC.11.3]` checks). */
static int test_rdsc_11_3__expr_shape_refused_at_load(void)
{
    int fails = 0;
    depth_chain_t chain;

    ds_result_t r = load_with_guard(depth_chain(&chain, 48), NULL, 0);
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: a guard 48 deep: status=%d (want OK) %s\n",
                r.status, r.detail ? r.detail : "");
        fails++;
    }
    r = load_with_guard(depth_chain(&chain, 49), NULL, 0);
    if (r.status != DS_ERR_DSC_SEMANTIC) {
        fprintf(stderr, "FAIL: a guard 49 deep: status=%d (want %d) %s\n",
                r.status, DS_ERR_DSC_SEMANTIC, r.detail ? r.detail : "");
        fails++;
    }

    /* An ASSERT whose one SlotAssign carries an expr loads; the same with the
       expr absent is refused. */
    Ds__V1__Expr one = DS__V1__EXPR__INIT;
    one.kind_case = DS__V1__EXPR__KIND_LIT_INT;
    one.lit_int = 1;
    Ds__V1__SlotAssign sa = DS__V1__SLOT_ASSIGN__INIT;
    sa.slot_index = 0;
    sa.expr = &one;
    Ds__V1__SlotAssign *sas[1] = { &sa };
    Ds__V1__Action emit = DS__V1__ACTION__INIT;
    emit.kind = DS__V1__ACTION_KIND__ACTION_ASSERT;
    emit.schema_name = (char *) "S";
    emit.n_assigns = 1;
    emit.assigns = sas;
    r = load_term(NULL, NULL, 0, &emit);
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: a SlotAssign with an expr: status=%d (want OK) %s\n",
                r.status, r.detail ? r.detail : "");
        fails++;
    }
    sa.expr = NULL;
    r = load_term(NULL, NULL, 0, &emit);
    if (r.status != DS_ERR_DSC_SEMANTIC) {
        fprintf(stderr, "FAIL: a SlotAssign with no expr: status=%d (want %d) %s\n",
                r.status, DS_ERR_DSC_SEMANTIC, r.detail ? r.detail : "");
        fails++;
    }

    /* An ACTION_CALL whose expr is a `log` loads; the same with the expr
       absent is refused at load. An Action with nothing set is one:
       ACTION_CALL is the kind's zero. */
    Ds__V1__Expr level = DS__V1__EXPR__INIT;
    level.kind_case = DS__V1__EXPR__KIND_LIT_INT;
    level.lit_int = 1;
    Ds__V1__Expr cat = DS__V1__EXPR__INIT;
    cat.kind_case = DS__V1__EXPR__KIND_LIT_STR;
    cat.lit_str = (char *) "r";
    Ds__V1__Expr msg = DS__V1__EXPR__INIT;
    msg.kind_case = DS__V1__EXPR__KIND_LIT_STR;
    msg.lit_str = (char *) "m";
    Ds__V1__Expr *log_args[3] = { &level, &cat, &msg };
    Ds__V1__CallExpr log_call = DS__V1__CALL_EXPR__INIT;
    log_call.op = DS__V1__BUILTIN_FN__FN_LOG;
    log_call.n_args = 3;
    log_call.args = log_args;
    Ds__V1__Expr log_expr = DS__V1__EXPR__INIT;
    log_expr.kind_case = DS__V1__EXPR__KIND_CALL;
    log_expr.call = &log_call;
    Ds__V1__Action call = DS__V1__ACTION__INIT;
    call.kind = DS__V1__ACTION_KIND__ACTION_CALL;
    call.expr = &log_expr;
    r = load_term(NULL, NULL, 0, &call);
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: an ACTION_CALL with an expr: status=%d (want OK) %s\n",
                r.status, r.detail ? r.detail : "");
        fails++;
    }
    call.expr = NULL;
    r = load_term(NULL, NULL, 0, &call);
    if (r.status != DS_ERR_DSC_SEMANTIC) {
        fprintf(stderr, "FAIL: an ACTION_CALL with no expr: status=%d (want %d) %s\n",
                r.status, DS_ERR_DSC_SEMANTIC, r.detail ? r.detail : "");
        fails++;
    }
    return fails;
}

/* ============== RDSC.4a.9.1: an index is a byte ============== */

/* [RDSC.4a.9.1]: a slot or pattern index is a byte. 255
   is the marker in VarExpr.pattern_index, Expr.entry_stamp and
   VarExpr.slot_index, so each takes 255 and refuses 256; SlotAssign.slot_index
   and Action.withdraw_pattern_index have none, so each takes 254 and refuses
   255, with DS_ERR_DSC_SEMANTIC. AlphaTest.slot_index is
   test_rdsc_4a_6_1__malformed_alpha_test's. An index in range that names no
   slot of `S` (one slot, `v`) is not refused at load: it faults when it is
   read. VarExpr and entry_stamp sit as BetaNode 2's join test, the others in
   TerminalNode 3's one action. The Mercury runtime is held to the same
   (test_ds.m, test_rdsc_4a_9_1_index_bounds). */
/* @spec [RDSC.4a.9.1] */
static int test_rdsc_4a_9_1__index_bounds(void)
{
    int fails = 0;
    struct { const char *label; int field; uint32_t value; int want; } cases[] = {
        { "VarExpr.pattern_index 255, the candidate", 0, 255, DS_OK },
        { "VarExpr.pattern_index 256",                0, 256, DS_ERR_DSC_SEMANTIC },
        { "VarExpr.slot_index 255, the fact itself",  1, 255, DS_OK },
        { "VarExpr.slot_index 256",                   1, 256, DS_ERR_DSC_SEMANTIC },
        { "Expr.entry_stamp 255, the candidate",      2, 255, DS_OK },
        { "Expr.entry_stamp 256",                     2, 256, DS_ERR_DSC_SEMANTIC },
        { "SlotAssign.slot_index 254",                3, 254, DS_OK },
        { "SlotAssign.slot_index 255",                3, 255, DS_ERR_DSC_SEMANTIC },
        { "Action.withdraw_pattern_index 254",        4, 254, DS_OK },
        { "Action.withdraw_pattern_index 255",        4, 255, DS_ERR_DSC_SEMANTIC },
    };
    for (size_t c = 0; c < sizeof cases / sizeof cases[0]; c++) {
        Ds__V1__VarExpr var = DS__V1__VAR_EXPR__INIT;
        Ds__V1__Expr test = DS__V1__EXPR__INIT;
        Ds__V1__Expr one = DS__V1__EXPR__INIT;
        one.kind_case = DS__V1__EXPR__KIND_LIT_INT;
        one.lit_int = 1;
        Ds__V1__SlotAssign sa = DS__V1__SLOT_ASSIGN__INIT;
        Ds__V1__SlotAssign *sas[1] = { &sa };
        Ds__V1__Action act = DS__V1__ACTION__INIT;
        Ds__V1__Expr *beta_test = NULL;
        Ds__V1__Action *action = NULL;
        switch (cases[c].field) {
        case 0:
        case 1:
            var.pattern_index = cases[c].field == 0 ? cases[c].value : 0;
            var.slot_index    = cases[c].field == 1 ? cases[c].value : 0;
            test.kind_case = DS__V1__EXPR__KIND_VAR;
            test.var = &var;
            beta_test = &test;
            break;
        case 2:
            test.kind_case = DS__V1__EXPR__KIND_ENTRY_STAMP;
            test.entry_stamp = cases[c].value;
            beta_test = &test;
            break;
        case 3:
            sa.slot_index = cases[c].value;
            sa.expr = &one;
            act.kind = DS__V1__ACTION_KIND__ACTION_ASSERT;
            act.schema_name = (char *) "S";
            act.n_assigns = 1;
            act.assigns = sas;
            action = &act;
            break;
        default:
            act.kind = DS__V1__ACTION_KIND__ACTION_WITHDRAW;
            act.withdraw_pattern_index = cases[c].value;
            action = &act;
            break;
        }
        ds_result_t r = load_net(NULL, NULL, 0, action, beta_test);
        if (r.status != cases[c].want
            || (cases[c].want != DS_OK
                && (r.detail == NULL
                    || strstr(r.detail, "RDSC.4a.9.1") == NULL))) {
            fprintf(stderr, "FAIL: [RDSC.4a.9.1] %s: status=%d (want %d) %s\n",
                    cases[c].label, r.status, cases[c].want,
                    r.detail ? r.detail : "");
            fails++;
        }
    }
    return fails;
}

/* ============== RDSC.9.10: no NaN in an artefact's doubles ============== */

/* The artefacts below, by shape. The first five put `v`'s bits in one of the
   four `double` fields; the rest are the edges the clause's reading turns on. */
enum {
    RDSC_9_10_EXPR,             /* Expr.lit_float, BetaNode 2's join test */
    RDSC_9_10_ALPHA,            /* an EQ AlphaTest's AlphaLiteral.float_val */
    RDSC_9_10_TOL,              /* Slot "S"."t"'s tolerance, a logical "S" */
    RDSC_9_10_IFCT,             /* an InitialFact's TestSlotLiteral.f_val */
    RDSC_9_10_ICAC,             /* an InitialCacheSeed's TestSlotLiteral.f_val */
    RDSC_9_10_EXPR_REPLACED,    /* lit_float `v`, then lit_bool true */
    RDSC_9_10_ALPHA_REPLACED,   /* float_val `v`, then int_val 42 */
    RDSC_9_10_TOL_REPLACED,     /* tolerance `v`, then tolerance 1.5 */
    RDSC_9_10_ALPHA_BAD_OP,     /* a CMP test whose op is 6, literal `v` */
    RDSC_9_10_IFCT_TRUNCATED,   /* f_val `v`, then a slot_name past the body */
    RDSC_9_10_IFCT_REPLACED,    /* an InitialFact slot: f_val `v`, then i_val 1 */
    RDSC_9_10_ICAC_REPLACED     /* a seed: value f_val `v`, then value f_val 1.5 */
};

static void rdsc_9_10_put(uint8_t *b, size_t *n, const void *p, size_t len)
{
    memcpy(b + *n, p, len);
    *n += len;
}

/* Load the artefact of `shape` into a new engine, *out_e, the caller's to
   free. Hand-built rather than packed: a packer that took the double as a
   `double` could quiet a signalling NaN on its way through a register. The
   bytes are test_ds.m's (test_rdsc_9_10_nan_doubles), byte for byte, but for
   the TerminalNode the network atoms carry here. */
static ds_result_t rdsc_9_10_load(int shape, uint64_t v, ds_engine_t **out_e)
{
    static const uint8_t slog_x[] = { 0x0A, 0x01, 0x53, 0x18, 0x01 };
    static const uint8_t slog_l[] = { 0x0A, 0x01, 0x53, 0x18, 0x02 };
    static const uint8_t slot[] = { 0x0A, 0x01, 0x53, 0x12, 0x01, 0x74,
                                    0x18, 0x02 };              /* FLOAT */
    static const uint8_t alfa[] = { 0x08, 0x01, 0x12, 0x01, 0x53 };
    static const uint8_t beta[] = { 0x08, 0x02, 0x10, 0x01 };
    static const uint8_t term[] = { 0x08, 0x03, 0x10, 0x02, 0x1A, 0x01, 0x52 };
    static const uint8_t lit_float = 0x11;    /* field 2, fixed64 */
    static const uint8_t lit_bool_true[] = { 0x20, 0x01 };
    static const uint8_t int_val_42[] = { 0x08, 0x2A };
    static const uint8_t one_point_five[8] = { 0, 0, 0, 0, 0, 0, 0xF8, 0x3F };
    ds_result_t fail = DS_ERR_R(DS_ERR_INVAL, "test fixture did not build");
    uint8_t d[8], t[32], b[64];
    size_t  tn = 0, bn = 0;
    for (int i = 0; i < 8; i++) d[i] = (uint8_t) (v >> (8 * i));
    struct { uint32_t field; const uint8_t *body; size_t len; } atoms[5];
    size_t na = 0;
#define RDSC_9_10_ATOM(f, p, l) \
    (atoms[na].field = (f), atoms[na].body = (p), atoms[na].len = (l), na++)
    *out_e = NULL;

    switch (shape) {
    case RDSC_9_10_EXPR:
    case RDSC_9_10_EXPR_REPLACED: {
        static const uint8_t pre[] = { 0x08, 0x02, 0x10, 0x01, 0x22 };
        rdsc_9_10_put(t, &tn, &lit_float, 1);
        rdsc_9_10_put(t, &tn, d, 8);
        if (shape == RDSC_9_10_EXPR_REPLACED)
            rdsc_9_10_put(t, &tn, lit_bool_true, sizeof lit_bool_true);
        rdsc_9_10_put(b, &bn, pre, sizeof pre);
        b[bn++] = (uint8_t) tn;
        rdsc_9_10_put(b, &bn, t, tn);
        RDSC_9_10_ATOM(DS_ATOM_SCHEMA_LOGICAL, slog_x, sizeof slog_x);
        RDSC_9_10_ATOM(DS_ATOM_SLOT, slot, sizeof slot);
        RDSC_9_10_ATOM(DS_ATOM_ALPHA_NODE, alfa, sizeof alfa);
        RDSC_9_10_ATOM(DS_ATOM_BETA_NODE, b, bn);
        RDSC_9_10_ATOM(DS_ATOM_TERMINAL_NODE, term, sizeof term);
        break;
    }
    case RDSC_9_10_ALPHA:
    case RDSC_9_10_ALPHA_REPLACED:
    case RDSC_9_10_ALPHA_BAD_OP: {
        static const uint8_t pre[] = { 0x08, 0x01, 0x12, 0x01, 0x53, 0x1A };
        static const uint8_t eq_slot_0[] = { 0x10, 0x00 };
        static const uint8_t cmp_slot_0_op_6[] = { 0x08, 0x01, 0x10, 0x00,
                                                   0x18, 0x06 };
        uint8_t lit_len = shape == RDSC_9_10_ALPHA_REPLACED ? 0x0B : 0x09;
        if (shape == RDSC_9_10_ALPHA_BAD_OP)
            rdsc_9_10_put(t, &tn, cmp_slot_0_op_6, sizeof cmp_slot_0_op_6);
        else
            rdsc_9_10_put(t, &tn, eq_slot_0, sizeof eq_slot_0);
        t[tn++] = 0x22;                       /* literal, field 4 */
        t[tn++] = lit_len;
        rdsc_9_10_put(t, &tn, &lit_float, 1);
        rdsc_9_10_put(t, &tn, d, 8);
        if (shape == RDSC_9_10_ALPHA_REPLACED)
            rdsc_9_10_put(t, &tn, int_val_42, sizeof int_val_42);
        rdsc_9_10_put(b, &bn, pre, sizeof pre);
        b[bn++] = (uint8_t) tn;
        rdsc_9_10_put(b, &bn, t, tn);
        RDSC_9_10_ATOM(DS_ATOM_SCHEMA_LOGICAL, slog_x, sizeof slog_x);
        RDSC_9_10_ATOM(DS_ATOM_SLOT, slot, sizeof slot);
        RDSC_9_10_ATOM(DS_ATOM_ALPHA_NODE, b, bn);
        RDSC_9_10_ATOM(DS_ATOM_BETA_NODE, beta, sizeof beta);
        RDSC_9_10_ATOM(DS_ATOM_TERMINAL_NODE, term, sizeof term);
        break;
    }
    case RDSC_9_10_TOL:
    case RDSC_9_10_TOL_REPLACED: {
        static const uint8_t tolerance = 0x39;    /* field 7, fixed64 */
        static const uint8_t mutable_role[] = { 0x48, 0x02 };
        rdsc_9_10_put(b, &bn, slot, sizeof slot);
        rdsc_9_10_put(b, &bn, &tolerance, 1);
        rdsc_9_10_put(b, &bn, d, 8);
        if (shape == RDSC_9_10_TOL_REPLACED) {
            rdsc_9_10_put(b, &bn, &tolerance, 1);
            rdsc_9_10_put(b, &bn, one_point_five, 8);
        }
        rdsc_9_10_put(b, &bn, mutable_role, sizeof mutable_role);
        RDSC_9_10_ATOM(DS_ATOM_SCHEMA_LOGICAL, slog_l, sizeof slog_l);
        RDSC_9_10_ATOM(DS_ATOM_SLOT, b, bn);
        break;
    }
    case RDSC_9_10_IFCT:
    case RDSC_9_10_IFCT_TRUNCATED:
    case RDSC_9_10_IFCT_REPLACED:
    case RDSC_9_10_ICAC:
    case RDSC_9_10_ICAC_REPLACED: {
        static const uint8_t ifct_pre[] = { 0x08, 0x01, 0x12, 0x01, 0x53, 0x1A };
        static const uint8_t icac_pre[] = { 0x08, 0x01, 0x12, 0x01, 0x6B, 0x1A };
        static const uint8_t slot_name_t[] = { 0x0A, 0x01, 0x74 };
        static const uint8_t f_val = 0x19;        /* field 3, fixed64 */
        static const uint8_t truncated[] = { 0x0A, 0x05 };
        static const uint8_t i_val_1[] = { 0x10, 0x01 };    /* field 2 */
        static const uint8_t value_f_val[] = { 0x1A, 0x09, 0x19 };
        const bool seed = shape == RDSC_9_10_ICAC
                       || shape == RDSC_9_10_ICAC_REPLACED;
        if (!seed)
            rdsc_9_10_put(t, &tn, slot_name_t, sizeof slot_name_t);
        rdsc_9_10_put(t, &tn, &f_val, 1);
        rdsc_9_10_put(t, &tn, d, 8);
        if (shape == RDSC_9_10_IFCT_TRUNCATED)
            rdsc_9_10_put(t, &tn, truncated, sizeof truncated);
        if (shape == RDSC_9_10_IFCT_REPLACED)
            rdsc_9_10_put(t, &tn, i_val_1, sizeof i_val_1);
        if (seed)
            rdsc_9_10_put(b, &bn, icac_pre, sizeof icac_pre);
        else
            rdsc_9_10_put(b, &bn, ifct_pre, sizeof ifct_pre);
        b[bn++] = (uint8_t) tn;
        rdsc_9_10_put(b, &bn, t, tn);
        if (shape == RDSC_9_10_ICAC_REPLACED) {   /* a second `value`, 1.5 */
            rdsc_9_10_put(b, &bn, value_f_val, sizeof value_f_val);
            rdsc_9_10_put(b, &bn, one_point_five, 8);
        }
        RDSC_9_10_ATOM(DS_ATOM_SCHEMA_LOGICAL, slog_x, sizeof slog_x);
        RDSC_9_10_ATOM(DS_ATOM_SLOT, slot, sizeof slot);
        RDSC_9_10_ATOM(seed ? DS_ATOM_INITIAL_CACHE_SEED : DS_ATOM_INITIAL_FACT,
                       b, bn);
        break;
    }
    default:
        return fail;
    }
#undef RDSC_9_10_ATOM

    buf_t f, hb;
    buf_init(&f);
    if (build_dsco_body(&hb) != 0) return fail;
    int bad = buf_append_atom(&f, DS_ATOM_DSC_HEADER, hb.data, hb.len) != 0;
    buf_free(&hb);
    for (size_t i = 0; i < na && !bad; i++)
        bad = buf_append_atom(&f, atoms[i].field, atoms[i].body, atoms[i].len)
              != 0;
    if (bad || new_engine(out_e)) {
        buf_free(&f);
        return fail;
    }
    ds_result_t r = load_sealed(*out_e, &f);
    buf_free(&f);
    return r;
}

/* The status `want`, and for a refusal with a `clause` a detail naming it. A
   DECODE refusal names no clause: initial_literal's detail is the atom's. */
static int rdsc_9_10_expect(const char *label, ds_result_t r, int want,
                            const char *clause)
{
    if (r.status == want
        && (want == DS_OK || clause == NULL
            || (r.detail != NULL && strstr(r.detail, clause) != NULL)))
        return 0;
    fprintf(stderr, "FAIL: %s: status=%d (want %d) %s\n", label, r.status,
            want, r.detail ? r.detail : "");
    return 1;
}

/* [RDSC.9.10]: a loader refuses with DS_ERR_DSC_SEMANTIC an artefact holding
   a NaN, quiet or signalling, in Expr.lit_float, AlphaLiteral.float_val,
   Slot.tolerance or TestSlotLiteral.f_val, and the refusal spends the engine
   ([RDSC.9.8]); the same field holding +inf loads. A NaN is judged on what
   the decoded atom holds: one a later member or field replaced is not held
   -- an Expr, an AlphaLiteral, a Slot and an InitialFact's literal alike --
   and a body that fails to decode is DS_ERR_DSC_DECODE ([RDSC.11.1])
   whatever NaN it carries, as is a seed with a second `value` ([RDSC.9.5];
   test_rdsc_9_5__repeated_message_field_refused). A malformed
   AlphaTest is refused for
   its shape before its NaN literal. PATH: the walk's handle_slot, and
   handle_initial with initial_literal (rdsc_9_10_held_nan), and
   ds_dsc_rete_body_decodes's decode_alfa and decode_expr_msg. The Mercury
   runtime is held to the same bytes (test_ds.m, test_rdsc_9_10_nan_doubles:
   ds.dsc's literal_field, test_slot_literal, lgra_24_3_decode_ifct / _icac). */
/* @spec [RDSC.9.10] */
static int test_rdsc_9_10__nan_doubles_refused(void)
{
    static const uint64_t qnan = 0x7FF8000000000000ull;
    static const struct { const char *label; uint64_t bits; int want; } values[] = {
        { "a quiet NaN",      0x7FF8000000000000ull, DS_ERR_DSC_SEMANTIC },
        { "a signalling NaN", 0x7FF0000000000001ull, DS_ERR_DSC_SEMANTIC },
        { "+inf",             0x7FF0000000000000ull, DS_OK },
    };
    static const struct { const char *label; int shape; } fields[] = {
        { "an Expr.lit_float",                           RDSC_9_10_EXPR },
        { "an AlphaLiteral.float_val",                   RDSC_9_10_ALPHA },
        { "a Slot.tolerance",                            RDSC_9_10_TOL },
        { "an InitialFact's TestSlotLiteral.f_val",      RDSC_9_10_IFCT },
        { "an InitialCacheSeed's TestSlotLiteral.f_val", RDSC_9_10_ICAC },
    };
    static const struct {
        const char *label; int shape; int want; const char *clause;
    } edges[] = {
        { "an Expr whose NaN lit_float a later lit_bool replaces",
          RDSC_9_10_EXPR_REPLACED, DS_OK, NULL },
        { "an AlphaLiteral whose NaN float_val a later int_val replaces",
          RDSC_9_10_ALPHA_REPLACED, DS_OK, NULL },
        { "a Slot whose NaN tolerance a later 1.5 replaces",
          RDSC_9_10_TOL_REPLACED, DS_OK, NULL },
        { "a CMP AlphaTest whose op is no AlphaCmpOp, before its NaN literal",
          RDSC_9_10_ALPHA_BAD_OP, DS_ERR_DSC_SEMANTIC, "RDSC.4a.6.1" },
        { "a TestSlotLiteral whose NaN f_val a field that does not parse "
          "follows, as DECODE",
          RDSC_9_10_IFCT_TRUNCATED, DS_ERR_DSC_DECODE, NULL },
        { "an InitialFact literal whose NaN f_val a later i_val replaces",
          RDSC_9_10_IFCT_REPLACED, DS_OK, NULL },
        /* [RDSC.9.5]: a second `value` is no replacement. */
        { "a seed whose NaN value a second value of 1.5 follows, as DECODE",
          RDSC_9_10_ICAC_REPLACED, DS_ERR_DSC_DECODE, NULL },
    };
    int fails = 0;
    char label[160];

    for (size_t vi = 0; vi < sizeof values / sizeof values[0]; vi++) {
        for (size_t fi = 0; fi < sizeof fields / sizeof fields[0]; fi++) {
            ds_engine_t *e = NULL;
            snprintf(label, sizeof label, "[RDSC.9.10] %s holding %s",
                     fields[fi].label, values[vi].label);
            ds_result_t r = rdsc_9_10_load(fields[fi].shape, values[vi].bits, &e);
            fails += rdsc_9_10_expect(label, r, values[vi].want, "RDSC.9.10");
            /* [RDSC.9.8]: the refused load spent the engine. */
            if (values[vi].want != DS_OK && e != NULL)
                fails += expect_spent(label, e);
            if (e != NULL) ds_engine_free(e);
        }
    }

    for (size_t c = 0; c < sizeof edges / sizeof edges[0]; c++) {
        ds_engine_t *e = NULL;
        snprintf(label, sizeof label, "[RDSC.9.10] %s", edges[c].label);
        ds_result_t r = rdsc_9_10_load(edges[c].shape, qnan, &e);
        fails += rdsc_9_10_expect(label, r, edges[c].want, edges[c].clause);
        /* The tolerance the later field gave is the one kept. */
        if (edges[c].shape == RDSC_9_10_TOL_REPLACED && r.status == DS_OK) {
            const ds_schema_t *s = NULL;
            if (ds_engine_schema_find(e, "S", &s).status != DS_OK || s == NULL
                || s->n_slots != 1 || s->slots[0].tolerance != 1.5) {
                fprintf(stderr, "FAIL: %s: the slot's tolerance is not 1.5\n",
                        label);
                fails++;
            }
        }
        if (e != NULL) ds_engine_free(e);
    }
    return fails;
}

/* ===== RDSC.9.5: a message field that is not repeated, more than once ===== */

/* The network artefacts below, by shape. Each refused shape has a twin that
   holds the field once and loads, so the refusal is the repeat's. */
enum {
    RDSC_9_5_ALPHA_ONCE,      /* an EQ AlphaTest: literal { float_val 1.5 } */
    RDSC_9_5_ALPHA_TWICE,     /* ... then literal {} */
    RDSC_9_5_BINOP_ONCE,      /* a join test: binop { EQ, left 1, right 1 } */
    RDSC_9_5_BINOP_TWICE,     /* ... then the same binop again */
    RDSC_9_5_NESTED_LEFT,     /* binop { EQ, left 1, left 2, right 1 } */
    RDSC_9_5_GUARD_TWICE,     /* a TerminalNode: fire_guard { true } twice */
    RDSC_9_5_SHA_TWICE,       /* a DscHeader: a second dsc_sha256, 32 zeros */
    /* Each its own join test, once and twice. */
    RDSC_9_5_IF_ONCE,         /* if_ { true, true, true } */
    RDSC_9_5_IF_TWICE,
    RDSC_9_5_COALESCE_ONCE,   /* coalesce { left true, right true } */
    RDSC_9_5_COALESCE_RIGHT_TWICE,
    RDSC_9_5_VALUE_PRIM_ONCE, /* interp { FormatPrim { value { 1 } } } */
    RDSC_9_5_VALUE_PRIM_TWICE,
    RDSC_9_5_TIME_PRIM_ONCE,  /* interp { FormatPrim { time { value 1 } } } */
    RDSC_9_5_TIME_PRIM_TWICE,
    /* Each TerminalNode 3's one action, once and twice. */
    RDSC_9_5_LET_ONCE,        /* ACTION_CALL, expr { bind { 0 := 1 } } */
    RDSC_9_5_LET_TWICE,
    RDSC_9_5_TTL_ONCE,        /* ACTION_ASSERT "S", slot 0 := 1, ttl 1 */
    RDSC_9_5_TTL_TWICE,
    RDSC_9_5_BY_ID_ONCE,      /* ACTION_WITHDRAW_BY_ID, the fact at 0 */
    RDSC_9_5_BY_ID_TWICE,
    RDSC_9_5_ASSIGN_ONCE,     /* ACTION_ASSERT "S", slot 0 := 1 */
    RDSC_9_5_ASSIGN_TWICE     /* ... the SlotAssign's expr twice */
};

/* Load the network artefact of `shape` into a new engine, *out_e, the
   caller's to free. The bytes are test_ds.m's (test_rdsc_9_5_repeated), but
   for the TerminalNode the network atoms carry here. */
static ds_result_t rdsc_9_5_load(int shape, ds_engine_t **out_e)
{
    static const uint8_t slog_x[] = { 0x0A, 0x01, 0x53, 0x18, 0x01 };
    static const uint8_t slot[] = { 0x0A, 0x01, 0x53, 0x12, 0x01, 0x74,
                                    0x18, 0x02 };              /* FLOAT */
    static const uint8_t alfa[] = { 0x08, 0x01, 0x12, 0x01, 0x53 };
    static const uint8_t beta[] = { 0x08, 0x02, 0x10, 0x01 };
    static const uint8_t term[] = { 0x08, 0x03, 0x10, 0x02, 0x1A, 0x01, 0x52 };
    /* AlphaNode 1 over "S", one EQ test on slot 0 whose literal's
       float_val (field 2, fixed64) is 1.5; a second, empty literal. */
    static const uint8_t alfa_pre[] = { 0x08, 0x01, 0x12, 0x01, 0x53, 0x1A };
    static const uint8_t lit_once[] = { 0x10, 0x00, 0x22, 0x09, 0x11,
                                        0, 0, 0, 0, 0, 0, 0xF8, 0x3F };
    static const uint8_t lit_empty[] = { 0x22, 0x00 };
    /* BetaNode 2 over AlphaNode 1, one join test (field 4): `1 == 1`. An
       Expr's binop is field 6; a BinopExpr's op 1 (EQ is 6), left 2,
       right 3; an Expr's lit_int 1. */
    static const uint8_t beta_pre[] = { 0x08, 0x02, 0x10, 0x01, 0x22 };
    static const uint8_t binop[] = { 0x32, 0x0A, 0x08, 0x06,
                                     0x12, 0x02, 0x08, 0x01,
                                     0x1A, 0x02, 0x08, 0x01 };
    static const uint8_t nested[] = { 0x32, 0x0E, 0x08, 0x06,
                                      0x12, 0x02, 0x08, 0x01,
                                      0x12, 0x02, 0x08, 0x02,
                                      0x1A, 0x02, 0x08, 0x01 };
    /* fire_guard (field 7): an Expr whose lit_bool (field 4) is true. */
    static const uint8_t guard[] = { 0x3A, 0x02, 0x20, 0x01 };
    /* Join tests, each Expr body whole. Expr.if_ (field 12): an
       IfExpr whose cond, then_ and else_ are each lit_bool true. */
    static const uint8_t if_once[] = { 0x62, 0x0C, 0x0A, 0x02, 0x20, 0x01,
                                       0x12, 0x02, 0x20, 0x01,
                                       0x1A, 0x02, 0x20, 0x01 };
    static const uint8_t if_twice[] = { 0x62, 0x0C, 0x0A, 0x02, 0x20, 0x01,
                                        0x12, 0x02, 0x20, 0x01,
                                        0x1A, 0x02, 0x20, 0x01,
                                        0x62, 0x0C, 0x0A, 0x02, 0x20, 0x01,
                                        0x12, 0x02, 0x20, 0x01,
                                        0x1A, 0x02, 0x20, 0x01 };
    /* Expr.coalesce (field 17): left true, right true; then right twice. */
    static const uint8_t coal_once[] = { 0x8A, 0x01, 0x08, 0x0A, 0x02, 0x20,
                                         0x01, 0x12, 0x02, 0x20, 0x01 };
    static const uint8_t coal_right2[] = { 0x8A, 0x01, 0x0C, 0x0A, 0x02, 0x20,
                                           0x01, 0x12, 0x02, 0x20, 0x01,
                                           0x12, 0x02, 0x20, 0x01 };
    /* Expr.interp (field 20) of one FormatPrim whose `value` member (field
       2) is a ValuePrim of lit_int 1; then that member twice. */
    static const uint8_t vprim_once[] = { 0xA2, 0x01, 0x08, 0x0A, 0x06,
                                          0x12, 0x04, 0x0A, 0x02, 0x08, 0x01 };
    static const uint8_t vprim_twice[] = { 0xA2, 0x01, 0x0E, 0x0A, 0x0C,
                                           0x12, 0x04, 0x0A, 0x02, 0x08, 0x01,
                                           0x12, 0x04, 0x0A, 0x02, 0x08, 0x01 };
    /* The same, the FormatPrim's `time` member (field 3) a TimePrim whose
       `value` is lit_int 1, with no items; then that `value` twice. */
    static const uint8_t tprim_once[] = { 0xA2, 0x01, 0x08, 0x0A, 0x06,
                                          0x1A, 0x04, 0x0A, 0x02, 0x08, 0x01 };
    static const uint8_t tprim_twice[] = { 0xA2, 0x01, 0x0C, 0x0A, 0x0A,
                                           0x1A, 0x08, 0x0A, 0x02, 0x08, 0x01,
                                           0x0A, 0x02, 0x08, 0x01 };
    /* TerminalNode 3's one action. A runtime `let`: ACTION_CALL (kind 0,
       absent) whose expr (field 2) is Expr.bind (field 13), bind_index 0 :=
       lit_int 1, under a bind_count (field 4) of 1 after the action. */
    static const uint8_t let_once[] = { 0x12, 0x06, 0x6A, 0x04,
                                        0x12, 0x02, 0x08, 0x01 };
    static const uint8_t let_twice[] = { 0x12, 0x06, 0x6A, 0x04,
                                         0x12, 0x02, 0x08, 0x01,
                                         0x12, 0x06, 0x6A, 0x04,
                                         0x12, 0x02, 0x08, 0x01 };
    static const uint8_t bind_count[] = { 0x20, 0x01 };
    /* ACTION_ASSERT "S" whose one SlotAssign sets slot 0 := lit_int 1
       (test_rdsc_4a_9_1__index_bounds's); with a ttl_override (field 5) of
       lit_int 1, once and twice; and with the SlotAssign's expr twice. */
    static const uint8_t assign_once[] = { 0x08, 0x01, 0x1A, 0x01, 0x53,
                                           0x22, 0x04, 0x12, 0x02, 0x08, 0x01 };
    static const uint8_t ttl_once[] = { 0x08, 0x01, 0x1A, 0x01, 0x53,
                                        0x22, 0x04, 0x12, 0x02, 0x08, 0x01,
                                        0x2A, 0x02, 0x08, 0x01 };
    static const uint8_t ttl_twice[] = { 0x08, 0x01, 0x1A, 0x01, 0x53,
                                         0x22, 0x04, 0x12, 0x02, 0x08, 0x01,
                                         0x2A, 0x02, 0x08, 0x01,
                                         0x2A, 0x02, 0x08, 0x01 };
    static const uint8_t assign_twice[] = { 0x08, 0x01, 0x1A, 0x01, 0x53,
                                            0x22, 0x08, 0x12, 0x02, 0x08, 0x01,
                                            0x12, 0x02, 0x08, 0x01 };
    /* ACTION_WITHDRAW_BY_ID whose withdraw_fact_id (field 7) is the fact at
       pattern 0 itself (VarExpr slot 255); then that field twice. */
    static const uint8_t by_id_once[] = { 0x08, 0x04,
                                          0x3A, 0x05, 0x2A, 0x03, 0x10, 0xFF,
                                          0x01 };
    static const uint8_t by_id_twice[] = { 0x08, 0x04,
                                           0x3A, 0x05, 0x2A, 0x03, 0x10, 0xFF,
                                           0x01,
                                           0x3A, 0x05, 0x2A, 0x03, 0x10, 0xFF,
                                           0x01 };
    static const struct {
        int shape; bool action; const uint8_t *p; size_t n;
    } more[] = {
        { RDSC_9_5_IF_ONCE,              false, if_once,      sizeof if_once },
        { RDSC_9_5_IF_TWICE,             false, if_twice,     sizeof if_twice },
        { RDSC_9_5_COALESCE_ONCE,        false, coal_once,    sizeof coal_once },
        { RDSC_9_5_COALESCE_RIGHT_TWICE, false, coal_right2,  sizeof coal_right2 },
        { RDSC_9_5_VALUE_PRIM_ONCE,      false, vprim_once,   sizeof vprim_once },
        { RDSC_9_5_VALUE_PRIM_TWICE,     false, vprim_twice,  sizeof vprim_twice },
        { RDSC_9_5_TIME_PRIM_ONCE,       false, tprim_once,   sizeof tprim_once },
        { RDSC_9_5_TIME_PRIM_TWICE,      false, tprim_twice,  sizeof tprim_twice },
        { RDSC_9_5_LET_ONCE,             true,  let_once,     sizeof let_once },
        { RDSC_9_5_LET_TWICE,            true,  let_twice,    sizeof let_twice },
        { RDSC_9_5_TTL_ONCE,             true,  ttl_once,     sizeof ttl_once },
        { RDSC_9_5_TTL_TWICE,            true,  ttl_twice,    sizeof ttl_twice },
        { RDSC_9_5_BY_ID_ONCE,           true,  by_id_once,   sizeof by_id_once },
        { RDSC_9_5_BY_ID_TWICE,          true,  by_id_twice,  sizeof by_id_twice },
        { RDSC_9_5_ASSIGN_ONCE,          true,  assign_once,  sizeof assign_once },
        { RDSC_9_5_ASSIGN_TWICE,         true,  assign_twice, sizeof assign_twice },
    };
    ds_result_t fail = DS_ERR_R(DS_ERR_INVAL, "test fixture did not build");
    uint8_t t[32], b[64];
    size_t  tn = 0, bn = 0;
    struct { uint32_t field; const uint8_t *body; size_t len; } atoms[5];
    size_t na = 0;
#define RDSC_9_5_ATOM(f, p, l) \
    (atoms[na].field = (f), atoms[na].body = (p), atoms[na].len = (l), na++)
    *out_e = NULL;

    RDSC_9_5_ATOM(DS_ATOM_SCHEMA_LOGICAL, slog_x, sizeof slog_x);
    RDSC_9_5_ATOM(DS_ATOM_SLOT, slot, sizeof slot);
    switch (shape) {
    case RDSC_9_5_ALPHA_ONCE:
    case RDSC_9_5_ALPHA_TWICE:
        rdsc_9_10_put(t, &tn, lit_once, sizeof lit_once);
        if (shape == RDSC_9_5_ALPHA_TWICE)
            rdsc_9_10_put(t, &tn, lit_empty, sizeof lit_empty);
        rdsc_9_10_put(b, &bn, alfa_pre, sizeof alfa_pre);
        b[bn++] = (uint8_t) tn;
        rdsc_9_10_put(b, &bn, t, tn);
        RDSC_9_5_ATOM(DS_ATOM_ALPHA_NODE, b, bn);
        RDSC_9_5_ATOM(DS_ATOM_BETA_NODE, beta, sizeof beta);
        RDSC_9_5_ATOM(DS_ATOM_TERMINAL_NODE, term, sizeof term);
        break;
    case RDSC_9_5_BINOP_ONCE:
    case RDSC_9_5_BINOP_TWICE:
    case RDSC_9_5_NESTED_LEFT:
        if (shape == RDSC_9_5_NESTED_LEFT) {
            rdsc_9_10_put(t, &tn, nested, sizeof nested);
        } else {
            rdsc_9_10_put(t, &tn, binop, sizeof binop);
            if (shape == RDSC_9_5_BINOP_TWICE)
                rdsc_9_10_put(t, &tn, binop, sizeof binop);
        }
        rdsc_9_10_put(b, &bn, beta_pre, sizeof beta_pre);
        b[bn++] = (uint8_t) tn;
        rdsc_9_10_put(b, &bn, t, tn);
        RDSC_9_5_ATOM(DS_ATOM_ALPHA_NODE, alfa, sizeof alfa);
        RDSC_9_5_ATOM(DS_ATOM_BETA_NODE, b, bn);
        RDSC_9_5_ATOM(DS_ATOM_TERMINAL_NODE, term, sizeof term);
        break;
    case RDSC_9_5_GUARD_TWICE:
        rdsc_9_10_put(b, &bn, term, sizeof term);
        rdsc_9_10_put(b, &bn, guard, sizeof guard);
        rdsc_9_10_put(b, &bn, guard, sizeof guard);
        RDSC_9_5_ATOM(DS_ATOM_ALPHA_NODE, alfa, sizeof alfa);
        RDSC_9_5_ATOM(DS_ATOM_BETA_NODE, beta, sizeof beta);
        RDSC_9_5_ATOM(DS_ATOM_TERMINAL_NODE, b, bn);
        break;
    case RDSC_9_5_SHA_TWICE:
        break;
    default: {
        size_t m = 0;
        while (m < sizeof more / sizeof more[0] && more[m].shape != shape) m++;
        if (m == sizeof more / sizeof more[0]) return fail;
        RDSC_9_5_ATOM(DS_ATOM_ALPHA_NODE, alfa, sizeof alfa);
        if (more[m].action) {
            /* TerminalNode 3's one action (field 6), then a let's
               bind_count. */
            rdsc_9_10_put(b, &bn, term, sizeof term);
            b[bn++] = 0x32;
            b[bn++] = (uint8_t) more[m].n;
            rdsc_9_10_put(b, &bn, more[m].p, more[m].n);
            if (shape == RDSC_9_5_LET_ONCE || shape == RDSC_9_5_LET_TWICE)
                rdsc_9_10_put(b, &bn, bind_count, sizeof bind_count);
            RDSC_9_5_ATOM(DS_ATOM_BETA_NODE, beta, sizeof beta);
            RDSC_9_5_ATOM(DS_ATOM_TERMINAL_NODE, b, bn);
        } else {
            /* BetaNode 2's one join test. */
            rdsc_9_10_put(b, &bn, beta_pre, sizeof beta_pre);
            b[bn++] = (uint8_t) more[m].n;
            rdsc_9_10_put(b, &bn, more[m].p, more[m].n);
            RDSC_9_5_ATOM(DS_ATOM_BETA_NODE, b, bn);
            RDSC_9_5_ATOM(DS_ATOM_TERMINAL_NODE, term, sizeof term);
        }
        break;
    }
    }
#undef RDSC_9_5_ATOM

    buf_t f, hb;
    buf_init(&f);
    if (build_dsco_body(&hb) != 0) return fail;
    if (shape == RDSC_9_5_SHA_TWICE) {
        /* Field 7, length 32: tag 0x3A, 0x20. The seal fills the first. */
        static const uint8_t sha_tag[] = { 0x3A, 0x20 };
        if (buf_append(&hb, sha_tag, sizeof sha_tag) != 0
            || buf_append(&hb, g_unsealed_sha256, sizeof g_unsealed_sha256)
               != 0) {
            buf_free(&hb);
            return fail;
        }
    }
    int bad = buf_append_atom(&f, DS_ATOM_DSC_HEADER, hb.data, hb.len) != 0;
    buf_free(&hb);
    for (size_t i = 0; i < na && !bad; i++)
        bad = buf_append_atom(&f, atoms[i].field, atoms[i].body, atoms[i].len)
              != 0;
    if (bad || new_engine(out_e)) {
        buf_free(&f);
        return fail;
    }
    ds_result_t r = load_sealed(*out_e, &f);
    buf_free(&f);
    return r;
}

/* [RDSC.9.5]: a loader refuses with DS_ERR_DSC_DECODE a body
   in which a singular message field, or a message-typed member of a oneof,
   occurs more than once, at any depth, and names the atom in the refusal;
   the same body holding the field once loads. A scalar twice is held as its
   last, as a control. PATH: rdsc_11_4_gate's judge, asked by decode_alfa,
   decode_beta and decode_term before protobuf-c unpacks the node, and
   handle_initial's and handle_svcd's own counts of a seed's `value` and a
   service's `hydration`. The Mercury runtime is held to the same bytes
   (test_ds.m, test_rdsc_9_5_repeated: `ds.dsc_judge`'s tables, field for
   field, and `ds.dsc`'s `decode_svcd` and `lgra_24_3_decode_icac`), so each
   network case pins a row of those tables against protobuf-c's
   descriptors. */
/* @spec [RDSC.9.5] */
static int test_rdsc_9_5__repeated_message_field_refused(void)
{
    static const struct {
        const char *label; int shape; int want; const char *atom;
    } cases[] = {
        { "an AlphaTest holding its literal once", RDSC_9_5_ALPHA_ONCE,
          DS_OK, NULL },
        { "an AlphaTest holding its literal twice", RDSC_9_5_ALPHA_TWICE,
          DS_ERR_DSC_DECODE, "AlphaNode body" },
        { "an Expr holding its binop member once", RDSC_9_5_BINOP_ONCE,
          DS_OK, NULL },
        { "an Expr holding its binop member twice", RDSC_9_5_BINOP_TWICE,
          DS_ERR_DSC_DECODE, "BetaNode body" },
        { "a binop holding its left operand twice", RDSC_9_5_NESTED_LEFT,
          DS_ERR_DSC_DECODE, "BetaNode body" },
        { "a TerminalNode holding its fire_guard twice", RDSC_9_5_GUARD_TWICE,
          DS_ERR_DSC_DECODE, "TerminalNode body" },
        { "a DscHeader holding its dsc_sha256 twice", RDSC_9_5_SHA_TWICE,
          DS_ERR_DSC_DECODE, "DscHeader body" },
        { "an Action holding its expr once", RDSC_9_5_LET_ONCE, DS_OK, NULL },
        { "an Action holding its expr twice", RDSC_9_5_LET_TWICE,
          DS_ERR_DSC_DECODE, "TerminalNode body" },
        { "an Action holding its ttl_override once", RDSC_9_5_TTL_ONCE,
          DS_OK, NULL },
        { "an Action holding its ttl_override twice", RDSC_9_5_TTL_TWICE,
          DS_ERR_DSC_DECODE, "TerminalNode body" },
        { "an Action holding its withdraw_fact_id once", RDSC_9_5_BY_ID_ONCE,
          DS_OK, NULL },
        { "an Action holding its withdraw_fact_id twice", RDSC_9_5_BY_ID_TWICE,
          DS_ERR_DSC_DECODE, "TerminalNode body" },
        { "a SlotAssign holding its expr once", RDSC_9_5_ASSIGN_ONCE,
          DS_OK, NULL },
        { "a SlotAssign holding its expr twice", RDSC_9_5_ASSIGN_TWICE,
          DS_ERR_DSC_DECODE, "TerminalNode body" },
        { "an Expr holding its if_ member once", RDSC_9_5_IF_ONCE, DS_OK, NULL },
        { "an Expr holding its if_ member twice", RDSC_9_5_IF_TWICE,
          DS_ERR_DSC_DECODE, "BetaNode body" },
        { "a CoalesceExpr holding its right operand once",
          RDSC_9_5_COALESCE_ONCE, DS_OK, NULL },
        { "a CoalesceExpr holding its right operand twice",
          RDSC_9_5_COALESCE_RIGHT_TWICE, DS_ERR_DSC_DECODE, "BetaNode body" },
        { "a FormatPrim holding its value member once",
          RDSC_9_5_VALUE_PRIM_ONCE, DS_OK, NULL },
        { "a FormatPrim holding its value member twice",
          RDSC_9_5_VALUE_PRIM_TWICE, DS_ERR_DSC_DECODE, "BetaNode body" },
        { "a TimePrim holding its value once", RDSC_9_5_TIME_PRIM_ONCE,
          DS_OK, NULL },
        { "a TimePrim holding its value twice", RDSC_9_5_TIME_PRIM_TWICE,
          DS_ERR_DSC_DECODE, "BetaNode body" },
    };
    static const uint64_t one = 0x3FF0000000000000ull;    /* 1.0 */
    int  fails = 0;
    char label[160];

    for (size_t c = 0; c < sizeof cases / sizeof cases[0]; c++) {
        ds_engine_t *e = NULL;
        snprintf(label, sizeof label, "[RDSC.9.5] %s", cases[c].label);
        ds_result_t r = rdsc_9_5_load(cases[c].shape, &e);
        fails += rdsc_9_10_expect(label, r, cases[c].want, NULL);
        if (cases[c].want != DS_OK
            && (r.detail == NULL || strstr(r.detail, cases[c].atom) == NULL
                || strstr(r.detail, "more than once") == NULL
                || strstr(r.detail, "(RDSC.9.5)") == NULL)) {
            fprintf(stderr, "FAIL: %s: the refusal does not name the atom "
                    "and the repeat: %s\n", label, r.detail ? r.detail : "");
            fails++;
        }
        if (e != NULL) ds_engine_free(e);
    }

    /* A seed's `value` twice, 1.0 then 1.5: DECODE, naming the seed. Once,
       it loads (test_rdsc_9_10__nan_doubles_refused's +inf case). */
    {
        ds_engine_t *e = NULL;
        ds_result_t r = rdsc_9_10_load(RDSC_9_10_ICAC_REPLACED, one, &e);
        fails += rdsc_9_10_expect("[RDSC.9.5] a seed holding its value twice",
                                  r, DS_ERR_DSC_DECODE, NULL);
        if (r.detail == NULL || strstr(r.detail, "InitialCacheSeed body") == NULL
            || strstr(r.detail, "more than once") == NULL) {
            fprintf(stderr, "FAIL: [RDSC.9.5] a seed holding its value twice: "
                    "the refusal does not name the seed and the repeat: %s\n",
                    r.detail ? r.detail : "");
            fails++;
        }
        if (e != NULL) ds_engine_free(e);
    }

    /* A ServiceDef "s", `no response`, whose hydration (field 4) is an empty
       ServiceHydration: once it loads, twice it is DECODE, naming the
       ServiceDef. PATH: handle_svcd's own count of field 4. */
    for (int reps = 1; reps <= 2; reps++) {
        static const uint8_t hydration[] = { 0x22, 0x00 };
        ds_engine_t *e = NULL;
        buf_t s, atom, f;
        buf_init(&s);
        snprintf(label, sizeof label, "[RDSC.9.5] a ServiceDef holding its "
                 "hydration %s", reps == 1 ? "once" : "twice");
        if (pb_str(&s, 1, "s") != 0 || pb_bool(&s, 5, true) != 0
            || buf_append(&s, hydration, sizeof hydration) != 0
            || (reps == 2 && buf_append(&s, hydration, sizeof hydration) != 0)
            || frame_into(&atom, DS_ATOM_SERVICE_DEF, &s) != 0) {
            buf_free(&s);
            fprintf(stderr, "FAIL: %s: test fixture did not build\n", label);
            fails++;
            continue;
        }
        buf_free(&s);
        if (build_file_with_atoms(&f, &atom, 1, "") != 0 || new_engine(&e)) {
            buf_free(&atom);
            fprintf(stderr, "FAIL: %s: test fixture did not build\n", label);
            fails++;
            continue;
        }
        buf_free(&atom);
        ds_result_t r = load_sealed(e, &f);
        buf_free(&f);
        fails += rdsc_9_10_expect(label, r,
                                  reps == 1 ? DS_OK : DS_ERR_DSC_DECODE, NULL);
        if (reps == 2
            && (r.detail == NULL || strstr(r.detail, "ServiceDef body") == NULL
                || strstr(r.detail, "more than once") == NULL)) {
            fprintf(stderr, "FAIL: %s: the refusal does not name the "
                    "ServiceDef and the repeat: %s\n", label,
                    r.detail ? r.detail : "");
            fails++;
        }
        if (e != NULL) ds_engine_free(e);
    }

    /* The control: a Slot's tolerance, a scalar, twice, 1.0 then 1.5, loads
       holding the last. */
    {
        ds_engine_t *e = NULL;
        const ds_schema_t *s = NULL;
        ds_result_t r = rdsc_9_10_load(RDSC_9_10_TOL_REPLACED, one, &e);
        fails += rdsc_9_10_expect("[RDSC.9.5] a Slot holding its tolerance "
                                  "twice", r, DS_OK, NULL);
        if (r.status == DS_OK
            && (ds_engine_schema_find(e, "S", &s).status != DS_OK || s == NULL
                || s->n_slots != 1 || s->slots[0].tolerance != 1.5)) {
            fprintf(stderr, "FAIL: [RDSC.9.5] the slot's tolerance is not the "
                    "last one, 1.5\n");
            fails++;
        }
        if (e != NULL) ds_engine_free(e);
    }
    return fails;
}

/* ===== RDSC.11.4: a body is decoded before it is judged ===== */

/* How many bytes `v` takes as a varint. */
static size_t rdsc_11_4_vlen(uint64_t v)
{
    size_t n = 1;
    while (v >>= 7) n++;
    return n;
}

/* An Expr: `levels` nested NOTs over the Expr body `inner` (Expr.unop is field
   7; UnopExpr.operand field 2, its `op` left out because NOT is UnopOp's zero).
   The outermost Expr's body is appended to `out`, so with `levels` 0 it is
   `inner`. Written from the inside out by length, so a chain 100 000 deep
   costs one pass. */
static int rdsc_11_4_not_chain(buf_t *out, size_t levels,
                               const uint8_t *inner, size_t inner_len)
{
    size_t *len = malloc((levels + 1) * sizeof *len);   /* len[i]: Expr i's body */
    if (len == NULL) return -1;
    len[levels] = inner_len;
    for (size_t i = levels; i-- > 0;) {
        const size_t unop = 1 + rdsc_11_4_vlen(len[i + 1]) + len[i + 1];
        len[i] = 1 + rdsc_11_4_vlen(unop) + unop;
    }
    static const uint8_t expr_unop = 0x3A, unop_operand = 0x12;
    int rc = 0;
    for (size_t i = 0; i < levels && rc == 0; i++) {
        const size_t unop = 1 + rdsc_11_4_vlen(len[i + 1]) + len[i + 1];
        rc = buf_append(out, &expr_unop, 1) || pb_varint(out, unop)
             || buf_append(out, &unop_operand, 1) || pb_varint(out, len[i + 1]);
    }
    if (rc == 0 && inner_len > 0) rc = buf_append(out, inner, inner_len);
    free(len);
    return rc;
}

/* A BetaNode 2 over AlphaNode 1 whose one join test (field 4) is the Expr
   body `test`, and after it `tail`, appended to `out`. */
static int rdsc_11_4_beta(buf_t *out, const buf_t *test,
                          const uint8_t *tail, size_t tail_len)
{
    static const uint8_t pre[] = { 0x08, 0x02, 0x10, 0x01, 0x22 };
    if (buf_append(out, pre, sizeof pre) != 0
        || pb_varint(out, test->len) != 0
        || (test->len > 0 && buf_append(out, test->data, test->len) != 0))
        return -1;
    return tail_len > 0 ? buf_append(out, tail, tail_len) : 0;
}

/* Load the network artefact with the BetaNode body `beta` and the TerminalNode
   body `term`, each the plain node of test_rdsc_9_5's artefact when NULL, into
   a new engine, *out_e, the caller's to free. */
static ds_result_t rdsc_11_4_load(const buf_t *beta, const buf_t *term,
                                  ds_engine_t **out_e)
{
    static const uint8_t slog_x[] = { 0x0A, 0x01, 0x53, 0x18, 0x01 };
    static const uint8_t slot[] = { 0x0A, 0x01, 0x53, 0x12, 0x01, 0x74,
                                    0x18, 0x02 };              /* FLOAT */
    static const uint8_t alfa[] = { 0x08, 0x01, 0x12, 0x01, 0x53 };
    static const uint8_t beta0[] = { 0x08, 0x02, 0x10, 0x01 };
    static const uint8_t term0[] = { 0x08, 0x03, 0x10, 0x02, 0x1A, 0x01, 0x52 };
    ds_result_t fail = DS_ERR_R(DS_ERR_INVAL, "test fixture did not build");
    buf_t f, hb;
    *out_e = NULL;
    buf_init(&f);
    if (build_dsco_body(&hb) != 0) return fail;
    int bad = buf_append_atom(&f, DS_ATOM_DSC_HEADER, hb.data, hb.len) != 0
        || buf_append_atom(&f, DS_ATOM_SCHEMA_LOGICAL, slog_x, sizeof slog_x) != 0
        || buf_append_atom(&f, DS_ATOM_SLOT, slot, sizeof slot) != 0
        || buf_append_atom(&f, DS_ATOM_ALPHA_NODE, alfa, sizeof alfa) != 0
        || buf_append_atom(&f, DS_ATOM_BETA_NODE,
                           beta ? beta->data : beta0,
                           beta ? beta->len : sizeof beta0) != 0
        || buf_append_atom(&f, DS_ATOM_TERMINAL_NODE,
                           term ? term->data : term0,
                           term ? term->len : sizeof term0) != 0;
    buf_free(&hb);
    if (bad || new_engine(out_e)) {
        buf_free(&f);
        return fail;
    }
    ds_result_t r = load_sealed(*out_e, &f);
    buf_free(&f);
    return r;
}

/* The status `want`, and for a refusal the words `words` in its detail. */
static int rdsc_11_4_expect(const char *label, ds_result_t r, int want,
                            const char *words)
{
    char full[160];
    snprintf(full, sizeof full, "[RDSC.11.4] %s", label);
    if (rdsc_9_10_expect(full, r, want, NULL) != 0) return 1;
    if (want == DS_OK || (r.detail != NULL && strstr(r.detail, words) != NULL))
        return 0;
    fprintf(stderr, "FAIL: %s: the refusal does not say \"%s\": %s\n", full,
            words, r.detail ? r.detail : "");
    return 1;
}

/* Load `beta` and `term` (NULL for the plain node), check the status and the
   words, and free the engine. A fixture that did not build fails. */
static int rdsc_11_4_case(const char *label, int unbuilt, const buf_t *beta,
                          const buf_t *term, int want, const char *words)
{
    ds_engine_t *e = NULL;
    ds_result_t  r = unbuilt != 0 ? DS_ERR_R(DS_ERR_INVAL, "fixture did not build")
                                  : rdsc_11_4_load(beta, term, &e);
    int fails = rdsc_11_4_expect(label, r, want, words);
    if (e != NULL) ds_engine_free(e);
    return fails;
}

/* [RDSC.11.4]: a loader refuses with DS_ERR_DSC_DECODE a body
   that fails protobuf decode, or holds a field more than once as [RDSC.9.5]
   refuses, whatever other defect it carries; and reads nothing inside an Expr
   nested past [RDSC.11.3]'s 48, so a body that decodes down to that limit and
   nests deeper is DS_ERR_DSC_SEMANTIC whatever the unread bytes hold, and the
   load returns however deep they nest ([RDSC.9.9]). PATH: rete_loader.c's
   rdsc_11_4_gate (ds_pb_rdsc_11_4_judge), asked by decode_beta and decode_term
   from the walk's ds_dsc_rete_body_decodes before protobuf-c unpacks the body,
   and decode_expr_msg on a body the gate passes. The Mercury runtime is held to
   the same bytes (test_ds.m, test_rdsc_11_4_decoded_before_judged:
   `ds.dsc_judge`, then `ds.dsc_network`'s decoders). */
/* @spec [RDSC.11.4] */
static int test_rdsc_11_4__decoded_before_judged(void)
{
    static const uint8_t lit_true[] = { 0x20, 0x01 };     /* Expr.lit_bool */
    int   fails = 0;
    int   bad;
    buf_t test, beta, beta2, term, left, tail, binop;
    buf_init(&test); buf_init(&beta); buf_init(&beta2); buf_init(&term);
    buf_init(&left); buf_init(&tail); buf_init(&binop);

    /* 1. A join test `binop { EQ, left: <an Expr whose
          innermost is 49 deep>, right: 1, right: 1 }`. The left operand is at
          depth 1, so 48 NOTs put its literal at 49. The second `right` is a
          repeat ([RDSC.9.5]): DECODE, the left operand's depth unread. */
    {
        static const uint8_t op_eq[] = { 0x08, 0x06 };
        static const uint8_t right[] = { 0x1A, 0x02, 0x08, 0x01 };
        bad = rdsc_11_4_not_chain(&left, 48, lit_true, sizeof lit_true)
            || buf_append(&binop, op_eq, sizeof op_eq)
            || pb_bytes(&binop, 2u, left.data, left.len)
            || buf_append(&binop, right, sizeof right)
            || buf_append(&binop, right, sizeof right)
            || pb_bytes(&test, 6u, binop.data, binop.len)
            || rdsc_11_4_beta(&beta, &test, NULL, 0);
        fails += rdsc_11_4_case("a binop whose left nests 49 deep and whose "
                                "right occurs twice", bad, &beta, NULL,
                                DS_ERR_DSC_DECODE, "BetaNode body");
    }
    buf_free(&test); buf_free(&beta); buf_free(&left); buf_free(&binop);

    /* 2. A join test that is an Expr with no member set ([RDSC.11.3]'s
          SEMANTIC), then, later in the same body, `is_negative` (field 5) as
          a varint of eleven bytes: DECODE. 6b, its control: without the wire
          error the same body is SEMANTIC. */
    {
        static const uint8_t overlong[] = { 0x28, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                                            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 };
        bad = rdsc_11_4_beta(&beta, &test, overlong, sizeof overlong);
        fails += rdsc_11_4_case("an empty join test, then an eleven-byte "
                                "varint", bad, &beta, NULL,
                                DS_ERR_DSC_DECODE, "longer than ten bytes");
        bad = rdsc_11_4_beta(&beta2, &test, NULL, 0);
        fails += rdsc_11_4_case("an empty join test, and no wire error", bad,
                                &beta2, NULL, DS_ERR_DSC_SEMANTIC,
                                "no kind set");
    }
    buf_free(&beta); buf_free(&beta2);

    /* 3. A TerminalNode whose first action is an ACTION_CALL with no `expr`
          (an Action with nothing set: CALL is the kind's zero), and whose
          `fire_guard` occurs twice: DECODE, before the action is judged. */
    {
        static const uint8_t body[] = { 0x08, 0x03, 0x10, 0x02, 0x1A, 0x01, 0x52,
                                        0x32, 0x00,               /* actions */
                                        0x3A, 0x02, 0x20, 0x01,   /* fire_guard */
                                        0x3A, 0x02, 0x20, 0x01 };
        bad = buf_append(&term, body, sizeof body);
        fails += rdsc_11_4_case("a CALL action with no expr, then fire_guard "
                                "twice", bad, NULL, &term,
                                DS_ERR_DSC_DECODE, "TerminalNode body");
    }
    buf_free(&term);

    /* 4. A join test 100 000 NOTs deep, otherwise well formed: SEMANTIC, and
          the load returns ([RDSC.9.9]). */
    bad = rdsc_11_4_not_chain(&test, 100000, lit_true, sizeof lit_true)
        || rdsc_11_4_beta(&beta, &test, NULL, 0);
    fails += rdsc_11_4_case("a join test 100000 deep", bad, &beta, NULL,
                            DS_ERR_DSC_SEMANTIC, "deeper than 48");
    buf_free(&test); buf_free(&beta);

    /* 5. A join test 60 deep whose Expr at depth 55 opens with a tag of wire
          type 7, which no decoder reads: SEMANTIC, because those bytes are
          not read. */
    {
        static const uint8_t bad_tag = 0x0F;          /* field 1, wire type 7 */
        bad = buf_append(&tail, &bad_tag, 1)
            || rdsc_11_4_not_chain(&tail, 5, lit_true, sizeof lit_true)
            || rdsc_11_4_not_chain(&test, 55, tail.data, tail.len)
            || rdsc_11_4_beta(&beta, &test, NULL, 0);
        fails += rdsc_11_4_case("a join test 60 deep, malformed at depth 55",
                                bad, &beta, NULL, DS_ERR_DSC_SEMANTIC,
                                "deeper than 48");
    }
    buf_free(&test); buf_free(&beta); buf_free(&tail);

    /* 6a. The control: a join test whose literal sits at depth 48 loads. */
    bad = rdsc_11_4_not_chain(&test, 48, lit_true, sizeof lit_true)
        || rdsc_11_4_beta(&beta, &test, NULL, 0);
    fails += rdsc_11_4_case("a join test 48 deep", bad, &beta, NULL, DS_OK,
                            NULL);
    buf_free(&test); buf_free(&beta);
    return fails;
}

/* ===== RDSC.9.12: a string field is well-formed UTF-8, with no U+0000 ===== */

/* One body of rdsc_9_12_load's artefact: NULL keeps the plain one. */
typedef struct { const uint8_t *p; size_t n; } rdsc_9_12_body_t;

/* rdsc_11_4_load's artefact -- a schema group "S", AlphaNode 1, BetaNode 2,
   TerminalNode 3 naming rule "R" -- with any of the Slot, AlphaNode, BetaNode
   and TerminalNode bodies replaced, loaded into a new engine, *out_e, the
   caller's to free. */
static ds_result_t rdsc_9_12_load(rdsc_9_12_body_t slot, rdsc_9_12_body_t alfa,
                                  rdsc_9_12_body_t beta, rdsc_9_12_body_t term,
                                  ds_engine_t **out_e)
{
    static const uint8_t slog_x[] = { 0x0A, 0x01, 0x53, 0x18, 0x01 };
    static const uint8_t slot0[] = { 0x0A, 0x01, 0x53, 0x12, 0x01, 0x74,
                                     0x18, 0x02 };             /* FLOAT */
    static const uint8_t alfa0[] = { 0x08, 0x01, 0x12, 0x01, 0x53 };
    static const uint8_t beta0[] = { 0x08, 0x02, 0x10, 0x01 };
    static const uint8_t term0[] = { 0x08, 0x03, 0x10, 0x02, 0x1A, 0x01, 0x52 };
    const rdsc_9_12_body_t atoms[4] = {
        slot.p ? slot : (rdsc_9_12_body_t){ slot0, sizeof slot0 },
        alfa.p ? alfa : (rdsc_9_12_body_t){ alfa0, sizeof alfa0 },
        beta.p ? beta : (rdsc_9_12_body_t){ beta0, sizeof beta0 },
        term.p ? term : (rdsc_9_12_body_t){ term0, sizeof term0 },
    };
    static const uint32_t fields[4] = { DS_ATOM_SLOT, DS_ATOM_ALPHA_NODE,
                                        DS_ATOM_BETA_NODE, DS_ATOM_TERMINAL_NODE };
    ds_result_t fail = DS_ERR_R(DS_ERR_INVAL, "test fixture did not build");
    buf_t f, hb;
    *out_e = NULL;
    buf_init(&f);
    if (build_dsco_body(&hb) != 0) return fail;
    int bad = buf_append_atom(&f, DS_ATOM_DSC_HEADER, hb.data, hb.len) != 0
        || buf_append_atom(&f, DS_ATOM_SCHEMA_LOGICAL, slog_x, sizeof slog_x) != 0;
    for (size_t i = 0; i < 4 && !bad; i++)
        bad = buf_append_atom(&f, fields[i], atoms[i].p, atoms[i].n) != 0;
    buf_free(&hb);
    if (bad || new_engine(out_e)) {
        buf_free(&f);
        return fail;
    }
    ds_result_t r = load_sealed(*out_e, &f);
    buf_free(&f);
    return r;
}

/* A BetaNode 2 over AlphaNode 1 whose one join test is `binop { EQ, left:
   lit_str <s>, right: lit_str "x" }`, into `out`. */
static int rdsc_9_12_beta(buf_t *out, const uint8_t *s, size_t n)
{
    static const uint8_t op_eq[] = { 0x08, 0x06 };
    static const uint8_t right[] = { 0x1A, 0x03, 0x1A, 0x01, 0x78 };
    buf_t left, binop, test;
    buf_init(&left); buf_init(&binop); buf_init(&test);
    int bad = pb_bytes(&left, 3u, s, n)                    /* Expr.lit_str */
        || buf_append(&binop, op_eq, sizeof op_eq)
        || pb_bytes(&binop, 2u, left.data, left.len)
        || buf_append(&binop, right, sizeof right)
        || pb_bytes(&test, 6u, binop.data, binop.len)      /* Expr.binop */
        || rdsc_11_4_beta(out, &test, NULL, 0);
    buf_free(&left); buf_free(&binop); buf_free(&test);
    return bad;
}

/* Load a header and the one atom `field` with body `p`/`n` into a new engine,
   *out_e, the caller's to free. */
static ds_result_t rdsc_9_12_load_one(uint32_t field, const uint8_t *p,
                                      size_t n, ds_engine_t **out_e)
{
    ds_result_t fail = DS_ERR_R(DS_ERR_INVAL, "test fixture did not build");
    buf_t f, hb;
    *out_e = NULL;
    buf_init(&f);
    if (build_dsco_body(&hb) != 0) return fail;
    int bad = buf_append_atom(&f, DS_ATOM_DSC_HEADER, hb.data, hb.len) != 0
        || buf_append_atom(&f, field, p, n) != 0;
    buf_free(&hb);
    if (bad || new_engine(out_e)) {
        buf_free(&f);
        return fail;
    }
    ds_result_t r = load_sealed(*out_e, &f);
    buf_free(&f);
    return r;
}

/* The status `want`, and for a refusal the words `words` in its detail. */
static int rdsc_9_12_expect(const char *label, ds_result_t r, int want,
                            const char *words)
{
    char full[160];
    snprintf(full, sizeof full, "[RDSC.9.12] %s", label);
    if (rdsc_9_10_expect(full, r, want, NULL) != 0) return 1;
    if (want == DS_OK || (r.detail != NULL && strstr(r.detail, words) != NULL))
        return 0;
    fprintf(stderr, "FAIL: %s: the refusal does not say \"%s\": %s\n", full,
            words, r.detail ? r.detail : "");
    return 1;
}

/* [RDSC.9.12]: a loader refuses with DS_ERR_DSC_DECODE an atom
   body in which a field of protobuf type `string`, at any depth it reads,
   holds bytes that are not well-formed UTF-8, or that hold U+0000; it neither
   repairs the string nor cuts it at the NUL. Network bodies and every other
   atom libds unpacks with protobuf-c alike. A string inside an Expr past
   [RDSC.11.3]'s 48 is not read ([RDSC.11.4]), so that body is SEMANTIC.
   PATH: ds_pb_rdsc_11_4_judge's string check, asked by rete_loader.c's
   rdsc_11_4_gate for a network body, and by loader.c's rdsc_9_5_pre_unpack
   for the Slot. The Mercury runtime is held to the same bytes (test_ds.m,
   test_rdsc_9_12_string_fields: `ds.dsc_judge`, and `ds.dsc_schema`'s
   `reader_string`). */
/* @spec [RDSC.9.12] */
static int test_rdsc_9_12__string_fields_refused(void)
{
    static const uint8_t nul[]     = { 0x61, 0x00, 0x62 };       /* a\0b */
    static const uint8_t e_acute[] = { 0xC3, 0xA9 };             /* é */
    static const rdsc_9_12_body_t plain = { NULL, 0 };
    int   fails = 0;
    int   bad;
    buf_t beta, test;
    ds_engine_t *e = NULL;
    ds_result_t  r;

    /* 1. TerminalNode.rule_name the single byte 0xFF. */
    {
        static const uint8_t term[] = { 0x08, 0x03, 0x10, 0x02, 0x1A, 0x01, 0xFF };
        r = rdsc_9_12_load(plain, plain, plain,
                           (rdsc_9_12_body_t){ term, sizeof term }, &e);
        fails += rdsc_9_12_expect("a rule_name of 0xFF", r, DS_ERR_DSC_DECODE,
                                  "TerminalNode body holds a string field");
        if (e != NULL) { ds_engine_free(e); e = NULL; }
    }

    /* 2. Expr.lit_str holding a\0b, in a BetaNode join test. */
    buf_init(&beta);
    bad = rdsc_9_12_beta(&beta, nul, sizeof nul);
    r = bad ? DS_ERR_R(DS_ERR_INVAL, "fixture did not build")
            : rdsc_9_12_load(plain, plain,
                             (rdsc_9_12_body_t){ beta.data, beta.len }, plain, &e);
    fails += rdsc_9_12_expect("a lit_str holding U+0000", r, DS_ERR_DSC_DECODE,
                              "BetaNode body holds a string field");
    if (e != NULL) { ds_engine_free(e); e = NULL; }
    buf_free(&beta);

    /* 3. AlphaNode.schema_name an overlong form, 0xC0 0xAF. */
    {
        static const uint8_t alfa[] = { 0x08, 0x01, 0x12, 0x02, 0xC0, 0xAF };
        r = rdsc_9_12_load(plain, (rdsc_9_12_body_t){ alfa, sizeof alfa },
                           plain, plain, &e);
        fails += rdsc_9_12_expect("a schema_name in an overlong form", r,
                                  DS_ERR_DSC_DECODE,
                                  "AlphaNode body holds a string field");
        if (e != NULL) { ds_engine_free(e); e = NULL; }
    }

    /* 4. A Slot atom's name a lone surrogate's encoding, 0xED 0xA0 0x80: an
          atom outside the network, so every atom is covered. */
    {
        static const uint8_t slot[] = { 0x0A, 0x01, 0x53, 0x12, 0x03,
                                        0xED, 0xA0, 0x80, 0x18, 0x02 };
        r = rdsc_9_12_load((rdsc_9_12_body_t){ slot, sizeof slot }, plain,
                           plain, plain, &e);
        fails += rdsc_9_12_expect("a Slot name holding a surrogate", r,
                                  DS_ERR_DSC_DECODE,
                                  "Slot body holds a string field");
        if (e != NULL) { ds_engine_free(e); e = NULL; }
    }

    /* 5a. The control: case 2 with a well-formed two-byte string loads, and
           the literal holds the two bytes. */
    buf_init(&beta);
    bad = rdsc_9_12_beta(&beta, e_acute, sizeof e_acute);
    r = bad ? DS_ERR_R(DS_ERR_INVAL, "fixture did not build")
            : rdsc_9_12_load(plain, plain,
                             (rdsc_9_12_body_t){ beta.data, beta.len }, plain, &e);
    fails += rdsc_9_12_expect("a lit_str of U+00E9", r, DS_OK, NULL);
    if (r.status == DS_OK) {
        const ds_rete_engine_t *re = e->rete_engine;
        const ds_rete_expr_t *t = re->owned_beta_count == 1
            && re->owned_betas[0]->join_test_count == 1
            ? re->owned_betas[0]->join_tests[0].expr : NULL;
        if (t == NULL || t->kind != DS_RETE_EXPR_BINOP
            || t->binop.left->kind != DS_RETE_EXPR_LIT_STR
            || strcmp(t->binop.left->lit_str, "\xC3\xA9") != 0) {
            fprintf(stderr, "FAIL: [RDSC.9.12] the literal is not the two "
                    "bytes C3 A9\n");
            fails++;
        }
    }
    if (e != NULL) { ds_engine_free(e); e = NULL; }
    buf_free(&beta);

    /* 5b. A join test whose deepest lit_str, at depth 49, is 0xFF: that Expr
           is not read, so the body is SEMANTIC ([RDSC.11.4]). */
    {
        static const uint8_t lit_ff[] = { 0x1A, 0x01, 0xFF };   /* Expr.lit_str */
        buf_init(&test); buf_init(&beta);
        bad = rdsc_11_4_not_chain(&test, 49, lit_ff, sizeof lit_ff)
            || rdsc_11_4_beta(&beta, &test, NULL, 0);
        r = bad ? DS_ERR_R(DS_ERR_INVAL, "fixture did not build")
                : rdsc_9_12_load(plain, plain,
                                 (rdsc_9_12_body_t){ beta.data, beta.len },
                                 plain, &e);
        fails += rdsc_9_12_expect("a 0xFF lit_str past depth 48", r,
                                  DS_ERR_DSC_SEMANTIC, "deeper than 48");
        if (e != NULL) { ds_engine_free(e); e = NULL; }
        buf_free(&test); buf_free(&beta);
    }

    /* The two `bytes` fields that carry text: DsSource `data` and
       SchemaDef `proto_source`, judged as strings under COMPRESSION_NONE, the
       one compression a loader reads them as text in. PATH: loader.c
       rdsc_9_12_text_bytes_ok, asked by rdsc_9_5_pre_unpack. */
    /* 6. A DsSource "m.ds", NONE, whose `data` is the single byte 0xFF. */
    {
        static const uint8_t dsrc[] = { 0x0A, 0x04, 'm', '.', 'd', 's',
                                        0x10, 0x01, 0x1A, 0x01, 0xFF };
        r = rdsc_9_12_load_one(DS_ATOM_DS_SOURCE, dsrc, sizeof dsrc, &e);
        fails += rdsc_9_12_expect("a DsSource data of 0xFF", r,
                                  DS_ERR_DSC_DECODE, "DsSource body");
        if (e != NULL) { ds_engine_free(e); e = NULL; }
    }
    /* 7. A SchemaDef "S", NONE, whose `proto_source` is a\0b. */
    {
        static const uint8_t sdef[] = { 0x0A, 0x01, 'S', 0x10, 0x01,
                                        0x1A, 0x03, 0x61, 0x00, 0x62 };
        r = rdsc_9_12_load_one(DS_ATOM_SCHEMA_DEF, sdef, sizeof sdef, &e);
        fails += rdsc_9_12_expect("a SchemaDef proto_source holding U+0000", r,
                                  DS_ERR_DSC_DECODE, "SchemaDef body");
        if (e != NULL) { ds_engine_free(e); e = NULL; }
    }
    /* 8. The control: case 6 with `data` C3 A9 loads, and the source view
          reads back those two bytes. */
    {
        static const uint8_t dsrc[] = { 0x0A, 0x04, 'm', '.', 'd', 's',
                                        0x10, 0x01, 0x1A, 0x02, 0xC3, 0xA9 };
        ds_ds_source_view_t dv;
        r = rdsc_9_12_load_one(DS_ATOM_DS_SOURCE, dsrc, sizeof dsrc, &e);
        fails += rdsc_9_12_expect("a DsSource data of U+00E9", r, DS_OK, NULL);
        if (r.status == DS_OK
            && (ds_engine_ds_source_at(e, 0, &dv).status != DS_OK
                || dv.text_len != 2u
                || memcmp(dv.text, "\xC3\xA9", 2) != 0)) {
            fprintf(stderr, "FAIL: [RDSC.9.12] the source view is not the two "
                    "bytes C3 A9\n");
            fails++;
        }
        if (e != NULL) { ds_engine_free(e); e = NULL; }
    }
    /* 9. Case 6 with compression 2, the retired ZLIB's number: refused for
          its compression ([RDSC.4.5.1]), its bytes never read as text. */
    {
        static const uint8_t dsrc[] = { 0x0A, 0x04, 'm', '.', 'd', 's',
                                        0x10, 0x02, 0x1A, 0x01, 0xFF };
        r = rdsc_9_12_load_one(DS_ATOM_DS_SOURCE, dsrc, sizeof dsrc, &e);
        fails += rdsc_9_12_expect("a ZLIB DsSource is refused for its "
                                  "compression, not its bytes", r,
                                  DS_ERR_DSC_DECOMPRESS, "RDSC.4.5.1");
        if (e != NULL) { ds_engine_free(e); e = NULL; }
    }
    return fails;
}

/* [RDSC.9.11]: a loader refuses with DS_ERR_DSC_SEMANTIC an
   artefact whose Slot.tolerance is less than zero, -inf included, and the
   refusal spends the engine ([RDSC.9.8]). -0.0 is not less than
   zero: it loads, and is exact equality, as 0 is. The artefact is
   rdsc_9_10_load's tolerance shape, so the bytes are test_ds.m's
   (test_rdsc_9_11_negative_tolerance). PATH: the walk's handle_slot. */
/* @spec [RDSC.9.11] */
static int test_rdsc_9_11__negative_tolerance_refused(void)
{
    static const struct { const char *label; uint64_t bits; int want; } cases[] = {
        { "-1.0", 0xBFF0000000000000ull, DS_ERR_DSC_SEMANTIC },
        { "-inf", 0xFFF0000000000000ull, DS_ERR_DSC_SEMANTIC },
        { "-0.0", 0x8000000000000000ull, DS_OK },
    };
    int fails = 0;
    char label[96];

    for (size_t c = 0; c < sizeof cases / sizeof cases[0]; c++) {
        ds_engine_t *e = NULL;
        snprintf(label, sizeof label, "[RDSC.9.11] a Slot.tolerance of %s",
                 cases[c].label);
        ds_result_t r = rdsc_9_10_load(RDSC_9_10_TOL, cases[c].bits, &e);
        fails += rdsc_9_10_expect(label, r, cases[c].want, "RDSC.9.11");
        if (cases[c].want != DS_OK) {
            /* [RDSC.9.8]: the refused load spent the engine, so the schema
               read is refused rather than answered. */
            if (e != NULL) fails += expect_spent(label, e);
        } else {
            const ds_schema_t *s = NULL;
            bool found = e != NULL
                && ds_engine_schema_find(e, "S", &s).status == DS_OK
                && s != NULL;
            if (!found || s->n_slots != 1 || s->slots[0].has_tolerance) {
                /* -0.0 is exact: no tolerance armed. */
                fprintf(stderr, "FAIL: %s: the slot is not exact\n", label);
                fails++;
            }
        }
        if (e != NULL) ds_engine_free(e);
    }
    return fails;
}

/* The one-rule artefact the [RDSC.9.8] test loads, sealed: a logical schema
   `S` and the network realizing rule `r` ([RDSC.8.3]). With `cut` > 0 the
   last `cut` bytes are dropped BEFORE the seal, so the hash matches and the
   walk reaches the partial atom: DS_ERR_DSC_TRUNCATED ([RDSC.9.7]), not the
   seal's refusal. */
static int rdsc_9_8_artefact(buf_t *f, size_t cut)
{
    buf_t atoms[RULE_NETWORK_ATOMS];
    if (frame_rule_network(atoms, "S", "r") != 0) return 1;
    int bad = build_file_with_atoms(f, atoms, RULE_NETWORK_ATOMS, NULL) != 0;
    for (size_t i = 0; i < RULE_NETWORK_ATOMS; i++) buf_free(&atoms[i]);
    if (bad || f->len <= cut) return 1;
    f->len -= cut;
    seal_dsc(f);
    return 0;
}

/* [RDSC.9.8]: A FAILED LOAD SPENDS THE ENGINE. A load that fails once it has begun reading returns the
   error that stopped it and sets the halt latch, with no fault
   ([NCBK.2.11]); every later call but [NCBK.2.9]'s four is refused with
   DS_ERR_ENGINE_HALTED; ds_engine_free releases it. A load refused before it
   reads changes nothing.

   Three failures, each on a fresh engine:
     - (a) the walk: the artefact truncated, DS_ERR_DSC_TRUNCATED;
     - (a') the apply phase: an AlphaNode naming a schema no group in the
       artefact declares, DS_ERR_DSC_DANGLING ([RDSC.8.7]), refused once the
       walk is clean;
     - (c) before the read: NULL data with len > 0, DS_ERR_INVAL, after which
       the same engine takes the good artefact.
   The allocation failure inside the apply phase, DS_ERR_OOM, is the
   alloc-conformance harness's (conformance_main.c, rdsc-9-8-oom), which has
   the allocator hooks. CONTROL: the good artefact loads on a fresh engine, so
   no refusal below is the fixture's. The assert on a spent engine takes a
   schema handle from the control's engine, an unknown schema to the spent
   one: halted is [NFCT.2.11]'s first step, so it answers.

   The Mercury runtime has no engine until a load succeeds, so it is held to
   (a) as what it can represent (test_ds.m, test_rdsc_9_8_failed_load_spends).
   PATH: ds_engine_load_dsc -> engine_load_dsc_body -> ds_dsc_load. */
/* @spec [RDSC.9.8] */
static int test_rdsc_9_8__failed_load_spends_the_engine(void)
{
    int fails = 0;
    buf_t good, cut;
    if (rdsc_9_8_artefact(&good, 0) != 0) return 1;
    if (rdsc_9_8_artefact(&cut, 1) != 0) { buf_free(&good); return 1; }

    /* CONTROL. */
    ds_engine_t *ctl = NULL;
    if (new_engine(&ctl)) return 1;
    ds_result_t r = ds_engine_load_dsc(ctl, good.data, good.len);
    EXPECT_LOAD_STATUS("[RDSC.9.8] control", r, DS_OK);
    const ds_schema_t *s = NULL;
    if (ds_engine_schema_find(ctl, "S", &s).status != DS_OK || s == NULL) {
        fprintf(stderr, "FAIL: [RDSC.9.8] control: no schema S\n");
        return 1;
    }
    ds_slot_value_t v = { .kind = DS_SLOT_INT, .v.i = 1 };

    struct { const char *label; int net; int want; } spend[] = {
        { "(a) a truncated artefact, refused by the walk", 0,
          DS_ERR_DSC_TRUNCATED },
        { "(a') a dangling AlphaNode, refused by the apply phase", 1,
          DS_ERR_DSC_DANGLING },
    };
    for (size_t c = 0; c < sizeof spend / sizeof spend[0]; c++) {
        char label[128];
        snprintf(label, sizeof label, "[RDSC.9.8] %s", spend[c].label);
        ds_engine_t *e = NULL;
        if (spend[c].net) {
            r = load_rdsc_8_7_net(NULL, "S", 0, 1, 0, 2, &e);
            if (e == NULL) return 1;
        } else {
            if (new_engine(&e)) return 1;
            r = ds_engine_load_dsc(e, cut.data, cut.len);
        }
        if (r.status != spend[c].want) {
            fprintf(stderr, "FAIL: %s: status=%d (want %d) detail=%s\n", label,
                    r.status, spend[c].want, r.detail ? r.detail : "(null)");
            fails++;
        }
        fails += expect_spent(label, e);
        r = ds_engine_load_dsc(e, good.data, good.len);
        if (r.status != DS_ERR_ENGINE_HALTED) {
            fprintf(stderr, "FAIL: %s: a second load is status %d, not "
                    "DS_ERR_ENGINE_HALTED\n", label, r.status);
            fails++;
        }
        r = ds_engine_assert(e, s, &v, 1, NULL);
        if (r.status != DS_ERR_ENGINE_HALTED) {
            fprintf(stderr, "FAIL: %s: an assert is status %d, not "
                    "DS_ERR_ENGINE_HALTED\n", label, r.status);
            fails++;
        }
        r = ds_engine_free(e);
        if (r.status != DS_OK) {
            fprintf(stderr, "FAIL: %s: ds_engine_free is status %d\n", label,
                    r.status);
            fails++;
        }
    }

    /* (c) Refused before the read: nothing changes. */
    {
        ds_engine_t *e = NULL;
        if (new_engine(&e)) return 1;
        r = ds_engine_load_dsc(e, NULL, good.len);
        if (r.status != DS_ERR_INVAL) {
            fprintf(stderr, "FAIL: [RDSC.9.8] (c) NULL data is status %d, not "
                    "DS_ERR_INVAL\n", r.status);
            fails++;
        }
        bool halted = true;
        if (ds_engine_halted(e, &halted, NULL).status != DS_OK || halted) {
            fprintf(stderr, "FAIL: [RDSC.9.8] (c) a load refused before the "
                    "read set the latch\n");
            fails++;
        }
        r = ds_engine_load_dsc(e, good.data, good.len);
        const ds_schema_t *found = NULL;
        if (r.status != DS_OK
            || ds_engine_schema_find(e, "S", &found).status != DS_OK
            || found == NULL) {
            fprintf(stderr, "FAIL: [RDSC.9.8] (c) the good load after it is "
                    "status %d\n", r.status);
            fails++;
        }
        ds_engine_free(e);
    }

    ds_engine_free(ctl);
    buf_free(&good);
    buf_free(&cut);
    return fails;
}

/* ============== IRET.10.6: an unknown action kind is refused ============== */

/* An action kind the loader does not know is refused. CONTROLS first: an
   ASSERT and a WITHDRAW (kind 3, IRET.10.5) load; then kind 7 is refused with
   DS_ERR_DSC_SEMANTIC. */
static int test_iret_10_6__unknown_action_kind_refused(void)
{
    int fails = 0;

    Ds__V1__Action emit = DS__V1__ACTION__INIT;
    emit.kind = DS__V1__ACTION_KIND__ACTION_ASSERT;
    emit.schema_name = (char *) "S";
    ds_result_t r = load_term(NULL, NULL, 0, &emit);
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: ASSERT control: status=%d %s\n", r.status,
                r.detail ? r.detail : "");
        return 1;   /* nothing below means anything */
    }

    Ds__V1__Action wd = DS__V1__ACTION__INIT;
    wd.kind = DS__V1__ACTION_KIND__ACTION_WITHDRAW;
    wd.withdraw_pattern_index = 0;
    r = load_term(NULL, NULL, 0, &wd);
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: WITHDRAW loads: status=%d %s\n", r.status,
                r.detail ? r.detail : "");
        fails++;
    }

    Ds__V1__Action bad = DS__V1__ACTION__INIT;
    bad.kind = (Ds__V1__ActionKind) 7;
    r = load_term(NULL, NULL, 0, &bad);
    if (r.status != DS_ERR_DSC_SEMANTIC) {
        fprintf(stderr, "FAIL: kind 7: status=%d (want %d) %s\n",
                r.status, DS_ERR_DSC_SEMANTIC, r.detail ? r.detail : "");
        fails++;
    }
    return fails;
}

/* ============== RDSC.4a.9.3: an op with no handler ============== */

/* A CallExpr expression naming `op` with `n` operands, each the literal 1. */
typedef struct {
    Ds__V1__Expr     expr;
    Ds__V1__CallExpr call;
    Ds__V1__Expr     arg[3];
    Ds__V1__Expr    *args[3];
} call_fixture_t;

static Ds__V1__Expr *call_of(call_fixture_t *c, uint32_t op, size_t n)
{
    Ds__V1__Expr e = DS__V1__EXPR__INIT;
    Ds__V1__CallExpr ce = DS__V1__CALL_EXPR__INIT;
    c->expr = e;
    c->call = ce;
    for (size_t i = 0; i < n; i++) {
        Ds__V1__Expr a = DS__V1__EXPR__INIT;
        a.kind_case = DS__V1__EXPR__KIND_LIT_INT;
        a.lit_int = 1;
        c->arg[i] = a;
        c->args[i] = &c->arg[i];
    }
    c->call.op = (Ds__V1__BuiltinFn) op;
    c->call.n_args = n;
    c->call.args = n ? c->args : NULL;
    c->expr.kind_case = DS__V1__EXPR__KIND_CALL;
    c->expr.call = &c->call;
    return &c->expr;
}

static int expect_load(const char *label, ds_result_t r, ds_status_t want)
{
    if (r.status == want) return 0;
    fprintf(stderr, "FAIL: %s: status=%d (want %d) %s\n", label, r.status, want,
            r.detail ? r.detail : "");
    return 1;
}

/* [RDSC.4a.9.3]: the one op check the loader makes
 * is whether libds has a handler for the op. A CallExpr naming an op it has no
 * handler for is DS_ERR_FN_NOT_FOUND at load, wherever it stands, a fire guard's
 * included. Where an op stands and how many operands it carries are the
 * compiler's guarantees, and the loader checks neither ([RDSC.9.9]). Every
 * artefact here is built by hand, so none is a program a DS source reaches.
 *
 * PATH PINNED: ds_engine_load_dsc -> ds_dsc_apply_rete_network -> decode_expr_msg's
 * ds_lookup_fn. A runtime holds a handler for an op at a site ([RDSC.4a.9.3]),
 * and the Mercury runtime's are positional, so its counterpart, test_ds.m's
 * `op_rewritten`, refuses more of these. */
static int test_rdsc_4a_9_3__only_an_op_with_no_handler_is_refused(void)
{
    int fails = 0;
    call_fixture_t c;
    Ds__V1__Action act = DS__V1__ACTION__INIT;
    act.kind = DS__V1__ACTION_KIND__ACTION_CALL;

    /* THE CONTROLS: expression builtins in a `where` test load. */
    fails += expect_load("FN_ABS in a where test",
        load_net(NULL, NULL, 0, NULL, call_of(&c, DS__V1__BUILTIN_FN__FN_ABS, 1)),
        DS_OK);
    fails += expect_load("FN_FMA in a where test",
        load_net(NULL, NULL, 0, NULL, call_of(&c, DS__V1__BUILTIN_FN__FN_FMA, 3)),
        DS_OK);

    /* No handler: refused at every site. */
    static const struct { const char *label; uint32_t op; } unhandled[] = {
        { "FN_UPPER (66), a tombstone", DS__V1__BUILTIN_FN__FN_UPPER },
        /* 4000 is far past any allocation BuiltinFn will make, so the row stays
           an unallocated number. */
        { "an unallocated number (4000)", 4000u },
        /* `none` rows of [RDSC.4a.9.5], which "admit no count": no clause in
           force has the compiler emit either as a call. test_ds.m's
           `op_rewritten` refuses the same two at the same three sites. */
        { "FN_EMIT (45), a none row", DS__V1__BUILTIN_FN__FN_EMIT },
        { "FN_HYDRATION_CALL (52), a none row",
          DS__V1__BUILTIN_FN__FN_HYDRATION_CALL },
    };
    for (size_t i = 0; i < sizeof unhandled / sizeof unhandled[0]; i++) {
        char label[96];
        snprintf(label, sizeof label, "%s in a where test", unhandled[i].label);
        fails += expect_load(label,
            load_net(NULL, NULL, 0, NULL, call_of(&c, unhandled[i].op, 1)),
            DS_ERR_FN_NOT_FOUND);
        snprintf(label, sizeof label, "%s as an action", unhandled[i].label);
        act.expr = call_of(&c, unhandled[i].op, 1);
        fails += expect_load(label, load_term(NULL, NULL, 0, &act),
                             DS_ERR_FN_NOT_FOUND);
        snprintf(label, sizeof label, "%s as a fire guard", unhandled[i].label);
        fails += expect_load(label,
            load_with_guard(call_of(&c, unhandled[i].op, 1), NULL, 0),
            DS_ERR_FN_NOT_FOUND);
    }

    /* A handler: loads wherever it stands, at any operand count. No compiler
       writes one of these. */
    fails += expect_load("FN_LOG, a verb, in a where test",
        load_net(NULL, NULL, 0, NULL, call_of(&c, DS__V1__BUILTIN_FN__FN_LOG, 3)),
        DS_OK);
    fails += expect_load("FN_GENSYM, a bind's op, as a fire guard",
        load_with_guard(call_of(&c, DS__V1__BUILTIN_FN__FN_GENSYM, 0), NULL, 0),
        DS_OK);
    act.expr = call_of(&c, DS__V1__BUILTIN_FN__FN_ABS, 1);
    fails += expect_load("FN_ABS, an expression builtin, as an action",
                         load_term(NULL, NULL, 0, &act), DS_OK);
    act.expr = call_of(&c, DS__V1__BUILTIN_FN__FN_LOG, 1);
    fails += expect_load("FN_LOG with one operand of three, as an action",
                         load_term(NULL, NULL, 0, &act), DS_OK);
    fails += expect_load("FN_ABS with three operands of one, in a where test",
        load_net(NULL, NULL, 0, NULL, call_of(&c, DS__V1__BUILTIN_FN__FN_ABS, 3)),
        DS_OK);

    return fails;
}

/* [RDSC.3.6] — the loader verifies `dsc_sha256` and refuses a mismatch with
 * DS_ERR_DSC_SEMANTIC. Every other case in
 * this file loads through load_sealed; these load unsealed or tampered bytes on
 * purpose.
 *
 * A DscHeader plus a skip-band atom, so the tampered byte can sit in a later atom
 * whose content the loader otherwise ignores: a refusal there is the hash's
 * alone. */
static int build_hash_fixture(buf_t *f)
{
    buf_t hb; if (build_dsco_body(&hb) != 0) return -1;
    buf_init(f);
    if (buf_append_atom(f, DS_ATOM_DSC_HEADER,hb.data, hb.len) != 0) return -1;
    buf_free(&hb);
    return buf_append_unknown_atom(f, 2000u);
}

static int test_rdsc_3_6__self_hash_verified_at_load(void)
{
    int fails = 0;

    /* THE CONTROL: sealed, it loads. Without it every refusal below passes
       against a loader that refuses everything. */
    {
        ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
        buf_t f; if (build_hash_fixture(&f) != 0) return 1;
        ds_result_t r = load_sealed(e, &f);
        if (r.status != DS_OK) {
            fprintf(stderr, "FAIL: sealed: status=%d %s\n", r.status,
                    r.detail ? r.detail : "");
            fails++;
        }
        buf_free(&f); ds_engine_free(e);
    }

    /* Unsealed: the stored hash is 32 zero bytes. */
    {
        ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
        buf_t f; if (build_hash_fixture(&f) != 0) return 1;
        ds_result_t r = ds_engine_load_dsc(e, f.data, f.len);
        if (r.status != DS_ERR_DSC_SEMANTIC) {
            fprintf(stderr, "FAIL: unsealed: status=%d (want %d)\n",
                    r.status, DS_ERR_DSC_SEMANTIC);
            fails++;
        }
        /* [RDSC.9.8] — the refused load spent the engine, and recorded no
           binding: the session header, which a spent engine still answers
           ([NCBK.2.9]), carries no dsc_hash. */
        fails += expect_spent("unsealed", e);
        ds_session_header_t sh;
        if (ds_engine_get_session_header(e, &sh).status != DS_OK ||
            sh.dsc_hash != NULL) {
            fprintf(stderr, "FAIL: unsealed: a refused load recorded a dsc_hash\n");
            fails++;
        }
        buf_free(&f); ds_engine_free(e);
    }

    /* Sealed, then one byte of the stored hash flipped. */
    {
        ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
        buf_t f; if (build_hash_fixture(&f) != 0) return 1;
        seal_dsc(&f);
        long off = dsc_sha256_offset(f.data, f.len);
        if (off < 0) { fprintf(stderr, "FAIL: no dsc_sha256 to flip\n"); return 1; }
        f.data[off] ^= 0x01u;
        ds_result_t r = ds_engine_load_dsc(e, f.data, f.len);
        if (r.status != DS_ERR_DSC_SEMANTIC) {
            fprintf(stderr, "FAIL: hash byte flipped: status=%d (want %d)\n",
                    r.status, DS_ERR_DSC_SEMANTIC);
            fails++;
        }
        buf_free(&f); ds_engine_free(e);
    }

    /* Sealed, then the LAST byte flipped: the skip atom's body, which the
       loader ignores once the hash matches. The hash covers the body. */
    {
        ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
        buf_t f; if (build_hash_fixture(&f) != 0) return 1;
        seal_dsc(&f);
        f.data[f.len - 1] ^= 0x01u;
        ds_result_t r = ds_engine_load_dsc(e, f.data, f.len);
        if (r.status != DS_ERR_DSC_SEMANTIC) {
            fprintf(stderr, "FAIL: body byte flipped: status=%d (want %d)\n",
                    r.status, DS_ERR_DSC_SEMANTIC);
            fails++;
        }
        buf_free(&f); ds_engine_free(e);
    }

    /* THE ORDER: another series is a version refusal even unsealed. Its
       layout is not one this runtime reads ([LDET.1.10]), so the version gate
       answers before the hash is looked at. */
    {
        ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
        char other[80];
        snprintf(other, sizeof other, "9%s", TEST_ACCEPTED_VERSION);
        buf_t hb; if (build_dsco_body_ver(&hb, other) != 0) return 1;
        buf_t f; buf_init(&f);
        if (buf_append_atom(&f, DS_ATOM_DSC_HEADER,hb.data, hb.len) != 0) return 1;
        ds_result_t r = ds_engine_load_dsc(e, f.data, f.len);
        if (r.status != DS_ERR_DSC_VERSION) {
            fprintf(stderr, "FAIL: other series unsealed: status=%d (want %d)\n",
                    r.status, DS_ERR_DSC_VERSION);
            fails++;
        }
        buf_free(&hb); buf_free(&f); ds_engine_free(e);
    }
    return fails;
}

/* [RBND.3.1] — the session header's `dsc_hash` is the artefact's own header
 * `dsc_sha256`, copied, and not a hash of the file as written. Both
 * runtimes record that value. */
static int test_rbnd_3_1__session_dsc_hash_is_the_header_value(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t f; if (build_hash_fixture(&f) != 0) return 1;
    ds_result_t r = load_sealed(e, &f);
    EXPECT_LOAD_STATUS("sealed", r, DS_OK);
    uint8_t as_written[32];
    ds_sha256(f.data, f.len, as_written);
    long off = dsc_sha256_offset(f.data, f.len);
    ds_session_header_t sh;
    if (off < 0 || ds_engine_get_session_header(e, &sh).status != DS_OK ||
        sh.dsc_hash == NULL || sh.dsc_hash_len != 32u) {
        fprintf(stderr, "FAIL: no session dsc_hash after a load\n");
        return 1;
    }
    if (memcmp(sh.dsc_hash, f.data + off, 32) != 0) {
        fprintf(stderr, "FAIL: session dsc_hash is not the header's dsc_sha256\n");
        return 1;
    }
    /* And the two forms really differ, or the check above pins nothing: an
       engine recording the as-written hash must fail here. */
    if (memcmp(sh.dsc_hash, as_written, 32) == 0) {
        fprintf(stderr, "FAIL: as-written and header hashes coincide\n");
        return 1;
    }
    buf_free(&f); ds_engine_free(e);
    return 0;
}

/* ============== RBND.1.3: the whole dialect-binding tuple ============== */

/* A header carrying the whole tuple ([RBND.1.3]): `caps` as its `capabilities`
   (field 13), a `dialect_def_sha256` of 32 bytes of `def_byte`, and
   `fault_fact_sites` (field 14, RDSC.3.10). Two of these that differ only in
   `fault_fact_sites` differ in `dsc_sha256` and in nothing else the tuple
   names, and both load: the count sizes a pool only under `realtime` or
   `constspace`. */
static uint8_t g_tuple_def[32];

static int build_dsc_tuple(buf_t *f, const Ds__V1__Capability *caps,
                           size_t n_caps, uint8_t def_byte,
                           uint32_t fault_fact_sites)
{
    memset(g_tuple_def, def_byte, sizeof g_tuple_def);
    Ds__V1__DscHeader h = DS__V1__DSC_HEADER__INIT;
    h.compiler_version = (char *) TEST_ACCEPTED_VERSION;
    h.dialect_def_sha256.data = g_tuple_def;
    h.dialect_def_sha256.len  = sizeof g_tuple_def;
    h.fault_fact_sites = fault_fact_sites;
    h.dsc_sha256.data = g_unsealed_sha256;
    h.dsc_sha256.len  = sizeof g_unsealed_sha256;
    h.capabilities   = (Ds__V1__Capability *) caps;
    h.n_capabilities = n_caps;
    size_t pl = ds__v1__dsc_header__get_packed_size(&h);
    uint8_t *body = malloc(pl);
    if (body == NULL) return -1;
    ds__v1__dsc_header__pack(&h, body);
    buf_init(f);
    int rc = buf_append_atom(f, DS_ATOM_DSC_HEADER, body, pl);
    free(body);
    if (rc != 0) return -1;
    seal_dsc(f);
    return 0;
}

/* `logical` (4) and `regex` (6), ascending as [RBND.1.3] writes them. The
   header's list is not the CapabilityInfo atom's, so neither is checked
   against this build's capabilities: only the tuple is under test. */
static const Ds__V1__Capability TUPLE_CAPS[2] = {
    DS__V1__CAPABILITY__CAPABILITY_LOGICAL,
    DS__V1__CAPABILITY__CAPABILITY_REGEX,
};

/* [RBND.1.3], [RBND.2], [RBND.3.1] — the session header carries the loaded
 * DSC header's `capabilities` and `dialect_def_sha256`, copied, beside its
 * `dsc_hash`; and the stream header encoded from it carries all three, which
 * is what the recorder writes ([RBND.2]: an event trace holds the tuple). */
static int test_rbnd_1_3__session_header_carries_the_tuple(void)
{
    int fails = 0;
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    buf_t f; if (build_dsc_tuple(&f, TUPLE_CAPS, 2, 0xA1, 0u) != 0) return 1;
    ds_result_t r = ds_engine_load_dsc(e, f.data, f.len);
    EXPECT_LOAD_STATUS("tuple fixture", r, DS_OK);

    ds_session_header_t sh;
    if (ds_engine_get_session_header(e, &sh).status != DS_OK) return 1;
    if (sh.capabilities == NULL || sh.n_capabilities != 2 ||
        sh.capabilities[0] != 4u || sh.capabilities[1] != 6u) {
        fprintf(stderr, "FAIL: session capabilities are not the header's "
                        "[logical, regex] (n=%zu)\n", sh.n_capabilities);
        fails++;
    }
    if (sh.dialect_def_sha256 == NULL || sh.dialect_def_sha256_len != 32 ||
        memcmp(sh.dialect_def_sha256, g_tuple_def, 32) != 0) {
        fprintf(stderr, "FAIL: session dialect_def_sha256 is not the header's\n");
        fails++;
    }

    /* The stream header, as the recorder encodes it, read back. */
    uint8_t fcst[512];
    size_t  flen = 0;
    ds_pbf_atom_t a;
    ds_rfcs_header_t dh;
    if (ds_rfcs_encode_header(&sh, fcst, sizeof fcst, &flen).status != DS_OK ||
        ds_pbf_next_atom(fcst, flen, 0, &a) != DS_PBF_OK ||
        ds_rfcs_decode_header(a.body, a.body_len, &dh).status != DS_OK) {
        fprintf(stderr, "FAIL: the stream header does not encode and decode\n");
        return fails + 1;
    }
    if (dh.n_capabilities != 2 || dh.capabilities[0] != 4u ||
        dh.capabilities[1] != 6u) {
        fprintf(stderr, "FAIL: the stream header's capabilities (field 16) "
                        "are not the DSC's (n=%zu)\n", dh.n_capabilities);
        fails++;
    }
    if (dh.dialect_def_sha256_len != 32 ||
        memcmp(dh.dialect_def_sha256, g_tuple_def, 32) != 0) {
        fprintf(stderr, "FAIL: the stream header's dialect_def_sha256 "
                        "(field 9) is not the DSC's\n");
        fails++;
    }
    if (dh.dsc_hash_len != 32 || memcmp(dh.dsc_hash, sh.dsc_hash, 32) != 0) {
        fprintf(stderr, "FAIL: the stream header's dsc_hash is not the DSC's\n");
        fails++;
    }
    buf_free(&f); ds_engine_free(e);
    return fails;
}

/* [RBND.1.3] — a DSC header whose `capabilities` list is malformed is
 * refused at load with DS_ERR_DSC_SEMANTIC: not strictly ascending (a
 * capability twice, two out of order), or an entry that is not a live member of
 * proto/capabilities.proto#Capability (a reserved number, an unallocated one,
 * CAPABILITY_UNSPECIFIED). Each fixture is SEALED, so the self-hash is right
 * and the list is the only thing wrong with it: a loader without the check
 * loads every one. CONTROL: TUPLE_CAPS, ascending live members, loads. */
static int test_rbnd_1_3__malformed_capability_list_refused_at_load(void)
{
    int fails = 0;
    static const Ds__V1__Capability twice[2] = {
        DS__V1__CAPABILITY__CAPABILITY_LOGICAL,
        DS__V1__CAPABILITY__CAPABILITY_LOGICAL };
    static const Ds__V1__Capability reversed[2] = {
        DS__V1__CAPABILITY__CAPABILITY_REGEX,
        DS__V1__CAPABILITY__CAPABILITY_LOGICAL };
    static const Ds__V1__Capability reserved[2] = {
        DS__V1__CAPABILITY__CAPABILITY_LOGICAL, (Ds__V1__Capability) 12 };
    static const Ds__V1__Capability unknown[2] = {
        DS__V1__CAPABILITY__CAPABILITY_LOGICAL, (Ds__V1__Capability) 99 };
    static const Ds__V1__Capability zero[1] = {
        DS__V1__CAPABILITY__CAPABILITY_UNSPECIFIED };
    const struct {
        const char *label; const Ds__V1__Capability *caps; size_t n; ds_status_t want;
    } cases[] = {
        { "control: ascending live members", TUPLE_CAPS, 2, DS_OK },
        { "a capability twice",              twice,      2, DS_ERR_DSC_SEMANTIC },
        { "two out of order",                reversed,   2, DS_ERR_DSC_SEMANTIC },
        { "a reserved number (12)",          reserved,   2, DS_ERR_DSC_SEMANTIC },
        { "an unallocated number (99)",      unknown,    2, DS_ERR_DSC_SEMANTIC },
        { "CAPABILITY_UNSPECIFIED (0)",      zero,       1, DS_ERR_DSC_SEMANTIC },
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
        buf_t f;
        if (build_dsc_tuple(&f, cases[i].caps, cases[i].n, 0xA1, 0u) != 0)
            return 1;
        ds_result_t r = ds_engine_load_dsc(e, f.data, f.len);
        if (r.status != cases[i].want) {
            fprintf(stderr, "FAIL: %s: status=%d (want %d) %s\n", cases[i].label,
                    r.status, cases[i].want, r.detail ? r.detail : "");
            fails++;
        } else if (cases[i].want != DS_OK &&
                   (r.detail == NULL || strstr(r.detail, "RBND.1.3") == NULL)) {
            fprintf(stderr, "FAIL: %s: refused, but not for RBND.1.3: %s\n",
                    cases[i].label, r.detail ? r.detail : "");
            fails++;
        }
        buf_free(&f); ds_engine_free(e);
    }
    return fails;
}

/* Replay a stream holding only the StreamHeader encoded from `h` into a fresh
   engine that has loaded `dsc`, or none when `dsc` is NULL. The status, whether
   the header verified, and the detail, copied before the engine that owns it
   is freed. */
static ds_status_t replay_fcst_into(const buf_t *dsc, const ds_session_header_t *h,
                                    bool *verified, char *detail, size_t dcap)
{
    ds_engine_t *e = NULL;
    *verified = false;
    detail[0] = '\0';
    if (new_engine(&e)) return DS_ERR_INVAL;
    ds_status_t st = dsc ? ds_engine_load_dsc(e, dsc->data, dsc->len).status : DS_OK;
    if (st != DS_OK) { ds_engine_free(e); return st; }
    uint8_t fcst[512];
    size_t  flen = 0;
    st = ds_rfcs_encode_header(h, fcst, sizeof fcst, &flen).status;
    if (st == DS_OK) {
        static uint8_t strbuf[256];
        ds_rfcs_replay_result_t rr;
        memset(&rr, 0, sizeof rr);
        ds_result_t r = ds_rfcs_replay(e, fcst, flen, strbuf, sizeof strbuf, &rr);
        st = r.status;
        *verified = rr.header_verified;
        snprintf(detail, dcap, "%s", r.detail ? r.detail : "");
    }
    ds_engine_free(e);
    return st;
}

static void hex16(const uint8_t *b, char out[17])
{
    static const char digits[] = "0123456789abcdef";
    for (int i = 0; i < 8; i++) {
        out[2 * i]     = digits[b[i] >> 4];
        out[2 * i + 1] = digits[b[i] & 0x0Fu];
    }
    out[16] = '\0';
}

#define EXPECT_REPLAY(label, got, want)                                       \
    do {                                                                      \
        if ((got) != (want)) {                                                \
            fprintf(stderr, "FAIL: %s: status=%d (want %d) detail=%s\n",      \
                    (label), (got), (want), detail);                         \
            fails++;                                                          \
        }                                                                     \
    } while (0)

/* [RBND.5.1], [RBND.5.2], [RBND.8.1] — replay compares a stream header's
 * dialect-binding tuple with the loaded DSC's, all three fields, through the
 * one comparison ([RBND.6.1]), and refuses a mismatch before it applies
 * anything.
 *
 * Every stream here is the StreamHeader alone, encoded from a session header:
 * the recording engine's own, or that one with a single field changed. A real
 * recording of another DSC differs in `dsc_sha256` whatever else it differs
 * in, because the hash covers the header that carries the other two
 * ([RDSC.3.6]); so the `capabilities` and `dialect_def_sha256` cases are
 * re-written headers. RBND.8.1's fourth case, two dialect names that resolve
 * alike, has no form here: neither tuple carries a name.
 *
 * PATH PINNED: ds_rfcs_replay -> replay_verify_header -> ds_binding_compare_dialect.
 * The Mercury runtime's counterpart is test_ds.m's `check_replay_dsc_binding`
 * (ds.replay -> ds.binding.compare_dialect). */
static int test_rbnd_5_1__replay_binds_the_whole_tuple(void)
{
    int  fails = 0;
    bool verified = false;
    char detail[512];
    char want_a[17], want_b[17];

    buf_t fa; if (build_dsc_tuple(&fa, TUPLE_CAPS, 2, 0xA1, 0u) != 0) return 1;
    buf_t fb; if (build_dsc_tuple(&fb, TUPLE_CAPS, 2, 0xA1, 1u) != 0) return 1;

    ds_engine_t *ea = NULL; if (new_engine(&ea)) return 1;
    ds_engine_t *eb = NULL; if (new_engine(&eb)) return 1;
    if (ds_engine_load_dsc(ea, fa.data, fa.len).status != DS_OK ||
        ds_engine_load_dsc(eb, fb.data, fb.len).status != DS_OK) {
        fprintf(stderr, "FAIL: the two tuple fixtures load\n");
        return 1;
    }
    ds_session_header_t ha, hb;
    if (ds_engine_get_session_header(ea, &ha).status != DS_OK ||
        ds_engine_get_session_header(eb, &hb).status != DS_OK) return 1;
    if (ha.dsc_hash == NULL || hb.dsc_hash == NULL) {
        fprintf(stderr, "FAIL: a loaded engine has no dsc_hash\n");
        return 1;
    }
    hex16(ha.dsc_hash, want_a);
    hex16(hb.dsc_hash, want_b);

    /* 1. Identical tuples: DS_OK, and positively verified. */
    EXPECT_REPLAY("identical tuples",
                  replay_fcst_into(&fa, &ha, &verified, detail, sizeof detail), DS_OK);
    if (!verified) {
        fprintf(stderr, "FAIL: identical tuples: header not verified\n");
        fails++;
    }

    /* 2. Another DSC's recording: -700, naming the field and both values,
          recorded first, each to 16 hex characters. */
    EXPECT_REPLAY("another DSC's recording",
                  replay_fcst_into(&fa, &hb, &verified, detail, sizeof detail),
                  DS_ERR_BND_DSC_MISMATCH);
    if (strstr(detail, "dsc_sha256") == NULL || strstr(detail, want_b) == NULL ||
        strstr(detail, want_a) == NULL) {
        fprintf(stderr, "FAIL: -700's detail names neither the field nor both "
                        "hashes: %s\n", detail);
        fails++;
    }

    /* 3. One capability fewer, the DSC hash unchanged: -701, naming it. */
    {
        static const uint32_t one[1] = { 4u };
        ds_session_header_t h = ha;
        h.capabilities = one;
        h.n_capabilities = 1;
        EXPECT_REPLAY("a one-capability delta",
                      replay_fcst_into(&fa, &h, &verified, detail, sizeof detail),
                      DS_ERR_BND_DIALECT_MISMATCH);
        if (strstr(detail, "capabilities") == NULL || strstr(detail, "regex") == NULL) {
            fprintf(stderr, "FAIL: -701's detail does not name the capability "
                            "in one tuple only: %s\n", detail);
            fails++;
        }
    }

    /* 4. The same capabilities in another order: a list that is not strictly
          ascending is malformed ([RBND.1.3]), so the stream header's decode
          refuses it, DS_ERR_PARSE, before any comparison. */
    {
        static const uint32_t swapped[2] = { 6u, 4u };
        ds_session_header_t h = ha;
        h.capabilities = swapped;
        h.n_capabilities = 2;
        EXPECT_REPLAY("capabilities reordered",
                      replay_fcst_into(&fa, &h, &verified, detail, sizeof detail),
                      DS_ERR_PARSE);
    }

    /* 4b. [RBND.1.3]: a capability twice, a number no live member
           names (12 is reserved, 99 unallocated), and 0, which is
           CAPABILITY_UNSPECIFIED: each a malformed list, refused at the stream
           header's decode with DS_ERR_PARSE. Neither cut, sorted nor
           de-duplicated: a list repaired so would compare as another tuple. */
    {
        static const uint32_t twice[2]    = { 4u, 4u };
        static const uint32_t reserved[2] = { 4u, 12u };
        static const uint32_t unknown[2]  = { 4u, 99u };
        static const uint32_t zero[2]     = { 0u, 4u };
        const struct { const char *label; const uint32_t *caps; } bad[] = {
            { "a capability twice",          twice },
            { "a reserved number (12)",      reserved },
            { "an unallocated number (99)",  unknown },
            { "CAPABILITY_UNSPECIFIED (0)",  zero },
        };
        for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
            ds_session_header_t h = ha;
            h.capabilities = bad[i].caps;
            h.n_capabilities = 2;
            EXPECT_REPLAY(bad[i].label,
                          replay_fcst_into(&fa, &h, &verified, detail, sizeof detail),
                          DS_ERR_PARSE);
            if (strstr(detail, "RBND.1.3") == NULL) {
                fprintf(stderr, "FAIL: %s: the refusal does not cite RBND.1.3: "
                                "%s\n", bad[i].label, detail);
                fails++;
            }
        }
    }

    /* 5. Another dialect_def_sha256: -701, naming that field. */
    {
        uint8_t other[32];
        memset(other, 0xB2, sizeof other);
        ds_session_header_t h = ha;
        h.dialect_def_sha256 = other;
        h.dialect_def_sha256_len = 32;
        EXPECT_REPLAY("another dialect_def_sha256",
                      replay_fcst_into(&fa, &h, &verified, detail, sizeof detail),
                      DS_ERR_BND_DIALECT_MISMATCH);
        if (strstr(detail, "dialect_def_sha256") == NULL) {
            fprintf(stderr, "FAIL: -701's detail does not name "
                            "dialect_def_sha256: %s\n", detail);
            fails++;
        }
    }

    /* 6. A DSC hash and no dialect_def_sha256: -703 ([RBND.2.1]). */
    {
        ds_session_header_t h = ha;
        h.dialect_def_sha256 = NULL;
        h.dialect_def_sha256_len = 0;
        EXPECT_REPLAY("no dialect_def_sha256",
                      replay_fcst_into(&fa, &h, &verified, detail, sizeof detail),
                      DS_ERR_BND_INCOMPLETE);
    }

    /* 7. No tuple at all: replayed without a binding check, into an engine
          with a DSC or without one ([RBND.2.1]). */
    {
        ds_session_header_t h = ha;
        h.dsc_hash = NULL; h.dsc_hash_len = 0;
        h.capabilities = NULL; h.n_capabilities = 0;
        h.dialect_def_sha256 = NULL; h.dialect_def_sha256_len = 0;
        EXPECT_REPLAY("no tuple",
                      replay_fcst_into(&fa, &h, &verified, detail, sizeof detail), DS_OK);
        if (verified) {
            fprintf(stderr, "FAIL: no tuple: reported verified\n");
            fails++;
        }
        EXPECT_REPLAY("no tuple, into an engine with no DSC",
                      replay_fcst_into(NULL, &h, &verified, detail, sizeof detail), DS_OK);
    }

    /* 8. A dialect_def_sha256 and no DSC hash: -703. A trace holding one of
          the two and not the other is incomplete ([RBND.2.1]), whichever one
          it holds. */
    {
        ds_session_header_t h = ha;
        h.dsc_hash = NULL; h.dsc_hash_len = 0;
        EXPECT_REPLAY("a dialect_def_sha256 and no dsc_hash",
                      replay_fcst_into(&fa, &h, &verified, detail, sizeof detail),
                      DS_ERR_BND_INCOMPLETE);
    }

    /* 9. A partial tuple into an engine with no DSC: -703 still. The
          incompleteness is the container's own, found before any comparison,
          so it does not wait for a DSC to compare against ([RBND.2.1]). The
          whole tuple into the same engine replays unverified: there is nothing
          to compare it with ([RBND.5.4]). */
    {
        ds_session_header_t h = ha;
        h.dialect_def_sha256 = NULL; h.dialect_def_sha256_len = 0;
        EXPECT_REPLAY("a dsc_hash alone, into an engine with no DSC",
                      replay_fcst_into(NULL, &h, &verified, detail, sizeof detail),
                      DS_ERR_BND_INCOMPLETE);
        ds_session_header_t g = ha;
        g.dsc_hash = NULL; g.dsc_hash_len = 0;
        EXPECT_REPLAY("a dialect_def_sha256 alone, into an engine with no DSC",
                      replay_fcst_into(NULL, &g, &verified, detail, sizeof detail),
                      DS_ERR_BND_INCOMPLETE);
        EXPECT_REPLAY("the whole tuple, into an engine with no DSC",
                      replay_fcst_into(NULL, &ha, &verified, detail, sizeof detail),
                      DS_OK);
        if (verified) {
            fprintf(stderr, "FAIL: the whole tuple, no DSC: reported verified\n");
            fails++;
        }
    }

    ds_engine_free(ea); ds_engine_free(eb);
    buf_free(&fa); buf_free(&fb);
    return fails;
}

/* Run one case and name it if it fails: the `return 1` guards (engine_new,
 * the buf builders) print nothing of their own. */
#define RUN(fn)                                                               \
    do {                                                                      \
        if ((fn)() != 0) {                                                    \
            fprintf(stderr, "FAILED CASE: %s\n", #fn);                        \
            failed = 1;                                                       \
        }                                                                     \
    } while (0)

int main(void)
{
    int failed = 0;
    RUN(test_truncated_empty);
    RUN(test_rfcs_19_1__not_a_container_is_refused);
    RUN(test_rdsc_11_1__framing_table);
    RUN(test_ldet_1_10__other_series_rejected);
    RUN(test_ldet_1_10__empty_version_rejected);
    RUN(test_ldet_1_10__same_series_other_patch_ok);
    RUN(test_reserved_field_12_loads_whatever_it_holds);
    RUN(test_rdsc_16_2__capb);
    RUN(test_nlfc_10_1__build_capabilities);
    RUN(test_nlfc_10_2__admission);
    RUN(test_rdsc_16_2_8__requires_is_trusted);
    RUN(test_rdsc_9_7__truncated_body_errors);
    RUN(test_unknown_magic_is_skipped);
    RUN(test_schema_load_ttl);
    RUN(test_schema_load_logical);
    RUN(test_rdsc_5_4_5__slog_without_lifecycle_refused);
    RUN(test_rdsc_5_4_5__activation_loads);
    RUN(test_ndbg_2_2__builtin_schema_is_internal);
    RUN(test_lstr_8_5__assert_and_seed_refuse_ill_formed_utf8);
    RUN(test_ndbg_2_4__services_read_back);
    RUN(test_ndbg_2_4__kwargs_edge_cases);
    RUN(test_schema_sttl_slog_conflict);
    RUN(test_schema_no_lifecycle);
    RUN(test_lfac_1_1__orphan_schema_atoms_refused);
    RUN(test_hydr_dangling);
    RUN(test_schema_ref_resolves);
    RUN(test_schema_ref_dangling);
    RUN(test_rdsc_8_7__alpha_schema_from_the_artefact);
    RUN(test_rdsc_8_7__rule_group_names_a_terminal);
    RUN(test_rdsc_9_9__terminal_with_empty_rule_name_loads);
    RUN(test_rdsc_9_5__undecodable_body_before_dangling_name);
    RUN(test_rdsc_9_5__the_refusal_names_the_decoders_reason);
    RUN(test_rdsc_8_7__body_shape_before_dangling_name);
    RUN(test_rdsc_4a_6_1__malformed_alpha_test);
    RUN(test_hydr_and_sdef_metadata);
    RUN(test_srcs_round_trip);
    RUN(test_rdsc_5_7__srcs_without_dsrc_keeps_position);
    RUN(test_rule_metadata_round_trip);
    RUN(test_dnam_round_trip);
    RUN(test_dnam_duplicate_loads);
    RUN(test_dsrc_round_trip);
    RUN(test_dsrc_zlib_body_rejected);
    RUN(test_span_node_round_trip);
    RUN(test_docs_atom_skipped);
    RUN(test_dialect_info_loads_without_a_log);
    RUN(test_rdsc_15_6__two_dialect_infos_load);
    RUN(test_rdsc_9_4__unrecognised_skip_is_logged);
    RUN(test_unread_known_atom_log_names_it);
    RUN(test_rdsc_4c_3__compiled_code_atom_is_skipped);
    RUN(test_introspection_round_trip);
    RUN(test_rdsc_11_1__malformed_expr_refused_at_load);
    RUN(test_rdsc_11_3__expr_shape_refused_at_load);
    RUN(test_rdsc_4a_9_1__index_bounds);
    RUN(test_rdsc_9_10__nan_doubles_refused);
    RUN(test_rdsc_9_5__repeated_message_field_refused);
    RUN(test_rdsc_11_4__decoded_before_judged);
    RUN(test_rdsc_9_12__string_fields_refused);
    RUN(test_rdsc_9_11__negative_tolerance_refused);
    RUN(test_rdsc_9_8__failed_load_spends_the_engine);
    RUN(test_rdsc_3_10__fault_fact_sites_kept);
    RUN(test_rdsc_3_7__def_sha_must_be_32_bytes);
    RUN(test_iret_10_6__unknown_action_kind_refused);
    RUN(test_rdsc_4a_9_3__only_an_op_with_no_handler_is_refused);
    RUN(test_rdsc_3_6__self_hash_verified_at_load);
    RUN(test_rbnd_3_1__session_dsc_hash_is_the_header_value);
    RUN(test_rbnd_1_3__session_header_carries_the_tuple);
    RUN(test_rbnd_1_3__malformed_capability_list_refused_at_load);
    RUN(test_rbnd_5_1__replay_binds_the_whole_tuple);
    if (!failed) printf("test_dsc_basic: OK\n");
    return failed;
}
