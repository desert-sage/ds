/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The generic atom reader, ds_rfcs_visit_atom.
 *
 *  1. Entry i's descriptor is the message registry entry i names, in package
 *     ds.v1. Both are generated from proto/atom.proto.
 *  2. Every registered atom's all-default body reads, opening and closing on
 *     its message at depth 0.
 *  3. A FactAssert from the encoder, and a PumpBoundary whose 64-bit fields
 *     come back as 64-bit integers.
 *  4. A .dsc container of SchemaLogical with `ambient`, SchemaTtl,
 *     DialectInfo, CapabilityInfo and DsSource, framed by the writer, walked
 *     by the strict reader, and each body visited.
 *  5. The refusals: an unknown field number, a body that does not unpack,
 *     and a visitor that stops the walk.
 *  6. [RDSC.9.9]: an ExternalAssert and a CallIssued nested 100 000 deep
 *     are refused as DS_ERR_PARSE, and the call returns; a body at the bound
 *     reads and one a level past it does not.
 *  7. [RTIM.14.9]: ds_rfcs_visit_atom_with_unknown reports a field the
 *     descriptor does not name, at its message's depth, and
 *     ds_rfcs_visit_atom does not.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "rfcs/rfcs.h"
#include "dsc/pbf_reader.h"
#include "dsc/pbf_writer.h"
#include "reader/atom_descriptors.h"
#include "schema_logical.pb-c.h"
#include "schema_ttl.pb-c.h"
#include "ds_source.pb-c.h"
#include "reader/dialect.pb-c.h"
#include "dsc/capabilities.pb-c.h"
#include "reader/pump_boundary.pb-c.h"

static int failures = 0;

#define CHECK(cond, msg)                                                      \
    do {                                                                      \
        if (!(cond)) {                                                        \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__); \
            failures++;                                                       \
        }                                                                     \
    } while (0)

/* ---- a recording visitor ------------------------------------------------- */

#define MAX_SEEN 64

typedef struct {
    ds_rfcs_field_t f[MAX_SEEN];
    char            s[MAX_SEEN][64];   /* string/bytes copied out: borrowed */
    int             n;
    int             stop_after;        /* 0: never stop */
} seen_t;

static bool record(void *ctx, const ds_rfcs_field_t *f)
{
    seen_t *seen = ctx;
    if (seen->n < MAX_SEEN) {
        seen->f[seen->n] = *f;
        if (f->kind == DS_RFCS_FIELD_STRING || f->kind == DS_RFCS_FIELD_BYTES) {
            size_t n = f->v.s.len < 63 ? f->v.s.len : 63;
            /* An empty field may come with p == NULL, and memcpy's source is
               declared nonnull even for zero bytes (ubsan). */
            if (n > 0)
                memcpy(seen->s[seen->n], f->v.s.p, n);
            seen->s[seen->n][n] = '\0';
        }
        seen->n++;
    }
    return !(seen->stop_after && seen->n >= seen->stop_after);
}

/* The first visited field called `name` of the atom's own message (depth 0),
   or NULL. */
static const ds_rfcs_field_t *field(const seen_t *seen, const char *name,
                                    int *at)
{
    for (int i = 0; i < seen->n; i++)
        if (seen->f[i].name && seen->f[i].depth == 0 &&
            seen->f[i].kind != DS_RFCS_FIELD_ENTER &&
            strcmp(seen->f[i].name, name) == 0) {
            if (at) *at = i;
            return &seen->f[i];
        }
    return NULL;
}

static bool opens_and_closes_on(const seen_t *seen, const char *message)
{
    if (seen->n < 2) return false;
    const ds_rfcs_field_t *a = &seen->f[0], *z = &seen->f[seen->n - 1];
    return a->kind == DS_RFCS_FIELD_ENTER && z->kind == DS_RFCS_FIELD_LEAVE &&
           a->depth == 0 && z->depth == 0 && a->name == NULL &&
           a->message && strcmp(a->message, message) == 0 &&
           z->message && strcmp(z->message, message) == 0;
}

/* ---- 1. the descriptor table is the registry's --------------------------- */

static void test_descriptors_are_the_registry(void)
{
    for (size_t i = 0; i < DS_ATOM_REGISTRY_COUNT; i++) {
        const ProtobufCMessageDescriptor *d = ds_atom_descriptors[i];
        const ds_atom_reg_entry_t *e = &ds_atom_registry[i];
        CHECK(d != NULL, "every registry entry has a descriptor");
        if (!d) continue;
        if (strcmp(d->short_name, e->message) != 0) {
            fprintf(stderr, "  entry %zu (field %u): descriptor %s, registry %s\n",
                    i, (unsigned) e->number, d->short_name, e->message);
            CHECK(0, "the descriptor is the message the registry names");
        }
        CHECK(strcmp(d->package_name, "ds.v1") == 0, "every body is ds.v1");
    }
}

/* ---- 2. every registered atom reads --------------------------------------- */

static void test_every_atom_reads(void)
{
    for (size_t i = 0; i < DS_ATOM_REGISTRY_COUNT; i++) {
        const ProtobufCMessageDescriptor *d = ds_atom_descriptors[i];
        const ds_atom_reg_entry_t *e = &ds_atom_registry[i];
        ProtobufCMessage *m = calloc(1, d->sizeof_message);
        CHECK(m != NULL, "alloc");
        if (!m) continue;
        protobuf_c_message_init(d, m);
        size_t n = protobuf_c_message_get_packed_size(m);
        uint8_t *buf = malloc(n ? n : 1);
        CHECK(buf != NULL, "alloc");
        if (buf) protobuf_c_message_pack(m, buf);

        seen_t seen;
        memset(&seen, 0, sizeof(seen));
        ds_result_t r = ds_rfcs_visit_atom(e->number, buf, n, record, &seen);
        if (r.status != DS_OK || !opens_and_closes_on(&seen, e->message)) {
            fprintf(stderr, "  field %u (%s): status %d, %d events\n",
                    (unsigned) e->number, e->message, r.status, seen.n);
            CHECK(0, "every registered atom's default body reads");
        }
        free(buf);
        free(m);
    }
}

/* ---- 3. trace atoms, with values ------------------------------------------- */

static void test_fcem_from_the_encoder(void)
{
    uint8_t atom[256];
    size_t  w = 0;
    const uint8_t body[3] = { 0x08, 0x2a, 0x00 };
    ds_result_t r = ds_rfcs_encode_fcem(UINT64_C(0x8000000000000001), "Reading",
                                        body, 2, 0, 0, 0, "",
                                        atom, sizeof(atom), &w);
    CHECK(r.status == DS_OK, "encode a FactAssert");
    if (r.status != DS_OK) return;

    ds_rfcs_reader_t rd;
    ds_rfcs_reader_init(&rd, atom, w);
    uint32_t atom_no = 0;
    const uint8_t *b = NULL;
    size_t blen = 0;
    bool done = false;
    CHECK(ds_rfcs_next(&rd, &atom_no, &b, &blen, &done).status == DS_OK && !done,
          "frame the FactAssert");

    seen_t seen;
    memset(&seen, 0, sizeof(seen));
    CHECK(ds_rfcs_visit_atom(atom_no, b, blen, record, &seen).status == DS_OK,
          "visit the FactAssert");
    CHECK(opens_and_closes_on(&seen, "FactAssert"), "a FactAssert is a FactAssert");

    int at = -1;
    const ds_rfcs_field_t *id = field(&seen, "fact_id", NULL);
    const ds_rfcs_field_t *sn = field(&seen, "schema_name", &at);
    const ds_rfcs_field_t *fb = field(&seen, "fact", NULL);
    CHECK(id && id->kind == DS_RFCS_FIELD_UINT &&
          id->v.u == UINT64_C(0x8000000000000001),
          "a 64-bit id with the top bit set survives as uint64");
    CHECK(sn && sn->kind == DS_RFCS_FIELD_STRING && at >= 0 &&
          strcmp(seen.s[at], "Reading") == 0, "the schema name");
    CHECK(fb && fb->kind == DS_RFCS_FIELD_BYTES && fb->v.s.len == 2,
          "the typed fact body is visited as bytes");
}

static void test_pump_int64(void)
{
    Ds__V1__PumpBoundary p = DS__V1__PUMP_BOUNDARY__INIT;
    p.seq = UINT64_C(18446744073709551615);
    p.clock_ns = INT64_C(-9223372036854775807) - 1;
    uint8_t buf[64];
    size_t n = ds__v1__pump_boundary__pack(&p, buf);

    seen_t seen;
    memset(&seen, 0, sizeof(seen));
    CHECK(ds_rfcs_visit_atom(DS_ATOM_PUMP_BOUNDARY, buf, n, record, &seen).status == DS_OK,
          "visit a PumpBoundary");
    const ds_rfcs_field_t *s = field(&seen, "seq", NULL);
    const ds_rfcs_field_t *c = field(&seen, "clock_ns", NULL);
    CHECK(s && s->kind == DS_RFCS_FIELD_UINT && s->v.u == UINT64_MAX,
          "uint64 max, exact");
    CHECK(c && c->kind == DS_RFCS_FIELD_INT && c->v.i == INT64_MIN,
          "int64 min, exact");
}

/* ---- 4. a .dsc container ------------------------------------------------ */

static size_t frame(uint32_t atom, const ProtobufCMessage *m,
                    uint8_t *out, size_t cap)
{
    size_t body = protobuf_c_message_get_packed_size(m);
    size_t hdr = 0, total = 0;
    if (!ds_pbf_write_prefix(atom, body, out, cap, &hdr, &total))
        return 0;
    protobuf_c_message_pack(m, out + hdr);
    return total;
}

static void test_a_dsc_reads(void)
{
    Ds__V1__SchemaLogical slog = DS__V1__SCHEMA_LOGICAL__INIT;
    slog.schema_name = "Presence";
    slog.ambient = 1;
    Ds__V1__SchemaTtl sttl = DS__V1__SCHEMA_TTL__INIT;
    sttl.schema_name = "Reading";
    sttl.ttl_ns = UINT64_C(300000000000);
    Ds__V1__DialectInfo dial = DS__V1__DIALECT_INFO__INIT;
    dial.name = "board_x";
    /* [RDSC.16.2.2] — `enabled` and `requires` are `repeated Capability`. */
    Ds__V1__Capability enabled[2] = {
        DS__V1__CAPABILITY__CAPABILITY_REALTIME,
        DS__V1__CAPABILITY__CAPABILITY_CONSTSPACE };
    Ds__V1__CapabilityInfo capb = DS__V1__CAPABILITY_INFO__INIT;
    capb.n_enabled = 2;
    capb.enabled = enabled;
    Ds__V1__DsSource dsrc = DS__V1__DS_SOURCE__INIT;
    dsrc.file = "rules.ds";

    static uint8_t dsc[1024];
    size_t used = 0, w;
    w = frame(DS_ATOM_SCHEMA_LOGICAL, &slog.base, dsc + used, sizeof(dsc) - used); used += w;
    w = frame(DS_ATOM_SCHEMA_TTL, &sttl.base, dsc + used, sizeof(dsc) - used); used += w;
    w = frame(DS_ATOM_DIALECT_INFO, &dial.base, dsc + used, sizeof(dsc) - used); used += w;
    w = frame(DS_ATOM_CAPABILITY_INFO, &capb.base, dsc + used, sizeof(dsc) - used); used += w;
    w = frame(DS_ATOM_DS_SOURCE, &dsrc.base, dsc + used, sizeof(dsc) - used); used += w;
    CHECK(w > 0 && used > 0, "the container frames");

    const char *want[5] = { "SchemaLogical", "SchemaTtl", "DialectInfo",
                            "CapabilityInfo", "DsSource" };
    ds_rfcs_reader_t rd;
    ds_rfcs_reader_init(&rd, dsc, used);
    for (int k = 0; k < 5; k++) {
        uint32_t atom_no = 0;
        const uint8_t *b = NULL;
        size_t blen = 0;
        bool done = true;
        CHECK(ds_rfcs_next(&rd, &atom_no, &b, &blen, &done).status == DS_OK && !done,
              "the next .dsc atom frames");
        seen_t seen;
        memset(&seen, 0, sizeof(seen));
        CHECK(ds_rfcs_visit_atom(atom_no, b, blen, record, &seen).status == DS_OK,
              "each .dsc atom visits");
        CHECK(opens_and_closes_on(&seen, want[k]), "each is its message");

        int at = -1;
        if (k == 0) {
            const ds_rfcs_field_t *a = field(&seen, "ambient", NULL);
            CHECK(a && a->kind == DS_RFCS_FIELD_BOOL && a->v.b,
                  "SchemaLogical says ambient, which libds.h's lifecycle cannot");
        } else if (k == 1) {
            const ds_rfcs_field_t *t = field(&seen, "ttl_ns", NULL);
            CHECK(t && t->v.u == UINT64_C(300000000000), "SchemaTtl's ttl");
        } else if (k == 2) {
            CHECK(field(&seen, "name", &at) && strcmp(seen.s[at], "board_x") == 0,
                  "DialectInfo's name");
        } else if (k == 3) {
            int n = 0;
            for (int i = 0; i < seen.n; i++)
                if (seen.f[i].name && strcmp(seen.f[i].name, "enabled") == 0 &&
                    seen.f[i].kind == DS_RFCS_FIELD_ENUM &&
                    seen.f[i].index == n &&
                    seen.f[i].v.e.number == (int) enabled[n])
                    n++;
            CHECK(n == 2, "CapabilityInfo's enabled settings, in order, each with its index");
        } else {
            CHECK(field(&seen, "file", &at) && strcmp(seen.s[at], "rules.ds") == 0,
                  "DsSource's file");
        }
    }
}

/* ---- 5. the refusals ------------------------------------------------------ */

static void test_refusals(void)
{
    seen_t seen;
    memset(&seen, 0, sizeof(seen));
    CHECK(ds_rfcs_visit_atom(999u, NULL, 0, record, &seen).status
              == DS_ERR_NOT_FOUND, "an unallocated field number is NOT_FOUND");
    const uint8_t junk[2] = { 0x0a, 0x05 };   /* a length running past the end */
    CHECK(ds_rfcs_visit_atom(DS_ATOM_DIALECT_INFO, junk, sizeof(junk), record, &seen).status
              == DS_ERR_PARSE, "a body that does not unpack is PARSE");
    CHECK(ds_rfcs_visit_atom(DS_ATOM_DIALECT_INFO, junk, 0, NULL, &seen).status
              == DS_ERR_INVAL, "NULL visitor");
    CHECK(ds_rfcs_visit_atom(DS_ATOM_DIALECT_INFO, NULL, 1, record, &seen).status
              == DS_ERR_INVAL, "NULL body with a length");

    Ds__V1__DialectInfo dial = DS__V1__DIALECT_INFO__INIT;
    dial.name = "x";
    uint8_t buf[32];
    size_t n = ds__v1__dialect_info__pack(&dial, buf);
    memset(&seen, 0, sizeof(seen));
    seen.stop_after = 1;
    CHECK(ds_rfcs_visit_atom(DS_ATOM_DIALECT_INFO, buf, n, record, &seen).status == DS_OK,
          "a visitor that stops is not an error");
    CHECK(seen.n == 1, "and nothing is visited after it stops");
}

/* ---- 6. [RDSC.9.9]: the nesting is bounded before the unpack -------------- */

/* The bytes are written by hand, innermost first, from the end of the buffer
   back, as test_assert_external.c's deep_record writes them: packing them with
   protobuf-c would recurse as deep as unpacking does. */
#define DEEP 100000u

static size_t put_varint_before(uint8_t *buf, size_t pos, size_t v)
{
    uint8_t tmp[10];
    size_t  n = 0;
    do {
        tmp[n] = (uint8_t)(v & 0x7Fu);
        v >>= 7;
        if (v != 0u) tmp[n] |= 0x80u;
        n++;
    } while (v != 0u);
    pos -= n;
    memcpy(buf + pos, tmp, n);
    return pos;
}

static size_t put_before(uint8_t *buf, size_t pos, const uint8_t *b, size_t n)
{
    pos -= n;
    memcpy(buf + pos, b, n);
    return pos;
}

/* `tag`, then the length of buf[pos..end), in front of it: the bytes from
   `pos` become one length-delimited field. */
static size_t wrap_before(uint8_t *buf, size_t pos, size_t end, uint8_t tag)
{
    pos = put_varint_before(buf, pos, end - pos);
    return put_before(buf, pos, &tag, 1);
}

/* A FactExternal nested `wraps` deep, ending at buf[end]: each level names the
   schema `Main` and holds one field `r` whose Arg.fact is the next, the
   innermost a `Ref`. With `leaf_arg` the `Ref` holds one field, an Arg with a
   name and no value, one level below it; without, it holds none. Returns
   where it starts. */
static size_t deep_fact(uint8_t *buf, size_t end, unsigned wraps, bool leaf_arg)
{
    static const uint8_t ref_schema[]  = { 0x0A, 0x03, 'R', 'e', 'f' };
    static const uint8_t main_schema[] = { 0x0A, 0x04, 'M', 'a', 'i', 'n' };
    static const uint8_t name[]        = { 0x0A, 0x01, 'r' };  /* Arg.name */
    static const uint8_t leaf[]        = { 0x0A, 0x01, 'x' };  /* Arg.name */
    size_t pos = end;
    if (leaf_arg) {
        pos = put_before(buf, pos, leaf, sizeof leaf);
        pos = wrap_before(buf, pos, end, 0x1A);     /* FactExternal.fields, 3 */
    }
    pos = put_before(buf, pos, ref_schema, sizeof ref_schema);
    for (unsigned i = 0; i < wraps; i++) {
        pos = wrap_before(buf, pos, end, 0x4A);     /* Arg.fact, field 9 */
        pos = put_before(buf, pos, name, sizeof name);
        pos = wrap_before(buf, pos, end, 0x1A);     /* FactExternal.fields, 3 */
        pos = put_before(buf, pos, main_schema, sizeof main_schema);
    }
    return pos;
}

/* An ExternalAssert whose fact is deep_fact(wraps, leaf_arg): its own message
   at depth 0, the fact at 1, its innermost FactExternal at 1 + 2 * wraps, and
   with `leaf_arg` that FactExternal's Arg at 2 + 2 * wraps. */
static size_t deep_external_assert(uint8_t *buf, size_t end, unsigned wraps,
                                   bool leaf_arg)
{
    size_t pos = deep_fact(buf, end, wraps, leaf_arg);
    return wrap_before(buf, pos, end, 0x0A);        /* ExternalAssert.fact, 1 */
}

/* A CallIssued with one argument whose Arg.fact is deep_fact(wraps): the
   argument at depth 1, its innermost FactExternal at 2 + 2 * wraps. */
static size_t deep_call_issued(uint8_t *buf, size_t end, unsigned wraps)
{
    static const uint8_t name[] = { 0x0A, 0x01, 'a' };     /* Arg.name */
    size_t pos = deep_fact(buf, end, wraps, false);
    pos = wrap_before(buf, pos, end, 0x4A);         /* Arg.fact, field 9 */
    pos = put_before(buf, pos, name, sizeof name);
    return wrap_before(buf, pos, end, 0x4A);        /* CallIssued.args, 9 */
}

/* The deepest ENTER a walk visits, and whether every ENTER had its LEAVE. */
typedef struct {
    uint32_t deepest;
    long     open;
    long     enters;
} depth_t;

static bool deepest(void *ctx, const ds_rfcs_field_t *f)
{
    depth_t *d = ctx;
    if (f->kind == DS_RFCS_FIELD_ENTER) {
        d->enters++;
        d->open++;
        if (f->depth > d->deepest) d->deepest = f->depth;
    } else if (f->kind == DS_RFCS_FIELD_LEAVE) {
        d->open--;
    }
    return true;
}

/* @spec [RDSC.9.9]: a reader loads or refuses whatever bytes it is handed.
   ExternalAssert and CallIssued are recursive through Arg.fact ->
   FactExternal.fields -> Arg, and protobuf-c's unpack has no recursion
   limit, so ds_rfcs_visit_atom's nests_too_deep bounds the nesting before
   the unpack. That the 100 000-deep calls return shows it ran first; the
   asan lane's leak subset runs this on a sanitized stack.

   The bound is DS_RFCS_VISIT_MAX_DEPTH: a deepest message at 63 or 64
   reads, one at 65 is DS_ERR_PARSE. */
static void test_rdsc_9_9__nesting_is_bounded_before_the_unpack(void)
{
    const size_t cap = 24u * DEEP + 64u;
    uint8_t *buf = malloc(cap);
    CHECK(buf != NULL, "the bodies' buffer");
    if (buf == NULL) return;
    seen_t seen;
    size_t pos;
    ds_result_t r;

    memset(&seen, 0, sizeof(seen));
    pos = deep_external_assert(buf, cap, DEEP, false);
    r = ds_rfcs_visit_atom(DS_ATOM_EXTERNAL_ASSERT, buf + pos, cap - pos,
                           record, &seen);
    CHECK(r.status == DS_ERR_PARSE,
          "an ExternalAssert 100 000 deep is refused as PARSE, and returns");
    CHECK(seen.n == 0, "nothing of it is visited");

    memset(&seen, 0, sizeof(seen));
    pos = deep_call_issued(buf, cap, DEEP);
    r = ds_rfcs_visit_atom(DS_ATOM_CALL_ISSUED, buf + pos, cap - pos,
                           record, &seen);
    CHECK(r.status == DS_ERR_PARSE,
          "a CallIssued 100 000 deep is refused as PARSE, and returns");
    CHECK(seen.n == 0, "nothing of it is visited");

    /* BELOW THE BOUND: 31 wraps put the innermost FactExternal at depth 63. */
    depth_t d = { 0, 0, 0 };
    pos = deep_external_assert(buf, cap, 31u, false);
    r = ds_rfcs_visit_atom(DS_ATOM_EXTERNAL_ASSERT, buf + pos, cap - pos,
                           deepest, &d);
    CHECK(r.status == DS_OK, "an ExternalAssert 63 deep reads");
    CHECK(d.deepest == 63u && d.open == 0 && d.enters == 64,
          "every one of its 64 messages, the deepest at 63, opened and closed");

    /* AT IT: the same 31, and an Arg in the innermost FactExternal at 64. */
    d = (depth_t){ 0, 0, 0 };
    pos = deep_external_assert(buf, cap, 31u, true);
    r = ds_rfcs_visit_atom(DS_ATOM_EXTERNAL_ASSERT, buf + pos, cap - pos,
                           deepest, &d);
    CHECK(r.status == DS_OK, "an ExternalAssert 64 deep reads");
    CHECK(d.deepest == 64u && d.open == 0 && d.enters == 65,
          "every one of its 65 messages, the deepest at 64, opened and closed");

    /* PAST IT: 32 wraps put it at 65. */
    memset(&seen, 0, sizeof(seen));
    pos = deep_external_assert(buf, cap, 32u, false);
    r = ds_rfcs_visit_atom(DS_ATOM_EXTERNAL_ASSERT, buf + pos, cap - pos,
                           record, &seen);
    CHECK(r.status == DS_ERR_PARSE, "an ExternalAssert 65 deep is refused");
    CHECK(seen.n == 0, "before anything of it is visited");

    free(buf);
}

/* ---- 7. [RTIM.14.9]: a field the descriptor does not name is reported ----- */

#define MAX_UNKNOWN 8

typedef struct {
    seen_t                  seen;
    ds_rfcs_unknown_field_t u[MAX_UNKNOWN];       /* `p` is dangling after the call */
    uint8_t                 bytes[MAX_UNKNOWN][8]; /* so its bytes are copied here */
    int                     before[MAX_UNKNOWN];  /* seen.n when it was reported */
    int                     n;
} unknowns_t;

static bool record_any(void *ctx, const ds_rfcs_field_t *f)
{
    return record(&((unknowns_t *)ctx)->seen, f);
}

static bool record_unknown(void *ctx, const ds_rfcs_unknown_field_t *u)
{
    unknowns_t *k = ctx;
    if (k->n < MAX_UNKNOWN) {
        k->u[k->n] = *u;
        /* BORROWED for the call only (rfcs.h): copied while it is valid. */
        if (u->p != NULL && u->len > 0)
            memcpy(k->bytes[k->n], u->p, u->len < 8 ? u->len : 8);
        k->before[k->n] = k->seen.n;
        k->n++;
    }
    return true;
}

static bool stop_at_unknown(void *ctx, const ds_rfcs_unknown_field_t *u)
{
    record_unknown(ctx, u);
    return false;
}

/* An OracleEmit, by hand so it can carry what no generated packer writes:
   test_id 1, polarity POS, schema_name "R", one slot_match {slot_name "a"},
   then field 99 = 7. With `nested`, the slot_match carries field 8 = 1 as
   well, a member TestSlotLiteral's `value` oneof does not have. */
static size_t oracle_emit(uint8_t *buf, bool with_99, bool nested)
{
    static const uint8_t head[]   = { 0x08, 0x01, 0x10, 0x01, 0x1A, 0x01, 'R' };
    static const uint8_t slot[]   = { 0x22, 0x03, 0x0A, 0x01, 'a' };
    static const uint8_t slot8[]  = { 0x22, 0x05, 0x0A, 0x01, 'a', 0x40, 0x01 };
    static const uint8_t f99[]    = { 0x98, 0x06, 0x07 };   /* tag 99 << 3 | 0 */
    size_t n = 0;
    memcpy(buf + n, head, sizeof head); n += sizeof head;
    if (nested) { memcpy(buf + n, slot8, sizeof slot8); n += sizeof slot8; }
    else        { memcpy(buf + n, slot, sizeof slot); n += sizeof slot; }
    if (with_99) { memcpy(buf + n, f99, sizeof f99); n += sizeof f99; }
    return n;
}

/* @spec [RTIM.14.9]: a field a test atom's descriptor does not name reaches
   the interpreter. An OracleEmit's field 99 is reported inside OracleEmit,
   after its known fields; the same bytes without it report none; and
   ds_rfcs_visit_atom, which installs no arm, visits only the known
   fields. */
static void test_rtim_14_9__unknown_fields_are_reported(void)
{
    uint8_t buf[64];
    unknowns_t k;
    size_t n;
    ds_result_t r;

    /* Field 99 on the atom's own message. */
    memset(&k, 0, sizeof k);
    n = oracle_emit(buf, true, false);
    r = ds_rfcs_visit_atom_with_unknown(DS_ATOM_ORACLE_EMIT, buf, n,
                                        record_any, record_unknown, &k);
    CHECK(r.status == DS_OK, "an OracleEmit with a field 99 visits");
    CHECK(opens_and_closes_on(&k.seen, "OracleEmit"), "as an OracleEmit");
    CHECK(k.n == 1, "one field is reported unknown");
    CHECK(k.n >= 1 && k.u[0].number == 99u && k.u[0].wire == 0u &&
          k.u[0].depth == 0u && k.u[0].message &&
          strcmp(k.u[0].message, "OracleEmit") == 0,
          "field 99, a varint, of OracleEmit itself");
    CHECK(k.n >= 1 && k.u[0].len == 1u && k.bytes[0][0] == 0x07,
          "with its value's bytes");
    CHECK(k.n >= 1 && k.before[0] == k.seen.n - 1,
          "after the last known field, before OracleEmit's LEAVE");
    const ds_rfcs_field_t *sn = field(&k.seen, "schema_name", NULL);
    CHECK(sn && sn->kind == DS_RFCS_FIELD_STRING, "the known fields still visit");

    /* The same bytes without it. */
    memset(&k, 0, sizeof k);
    n = oracle_emit(buf, false, false);
    r = ds_rfcs_visit_atom_with_unknown(DS_ATOM_ORACLE_EMIT, buf, n,
                                        record_any, record_unknown, &k);
    CHECK(r.status == DS_OK && k.n == 0, "without field 99, none is reported");

    /* A nested message's: field 8 in the slot_match, at depth 1. */
    memset(&k, 0, sizeof k);
    n = oracle_emit(buf, true, true);
    r = ds_rfcs_visit_atom_with_unknown(DS_ATOM_ORACLE_EMIT, buf, n,
                                        record_any, record_unknown, &k);
    CHECK(r.status == DS_OK && k.n == 2, "a nested unknown field is reported too");
    CHECK(k.n == 2 && k.u[0].number == 8u && k.u[0].depth == 1u &&
          k.u[0].message && strcmp(k.u[0].message, "TestSlotLiteral") == 0,
          "field 8 first, in the TestSlotLiteral it was read in");
    CHECK(k.n == 2 && k.before[0] >= 1 &&
          k.seen.f[k.before[0] - 1].kind != DS_RFCS_FIELD_LEAVE &&
          k.seen.f[k.before[0]].kind == DS_RFCS_FIELD_LEAVE &&
          k.seen.f[k.before[0]].depth == 1u,
          "inside the slot_match, before its LEAVE");
    CHECK(k.n == 2 && k.u[1].number == 99u && k.u[1].depth == 0u,
          "then field 99, of OracleEmit");

    /* Without the arm, the same visit whether or not the body carries field
       99. */
    seen_t plain, bare;
    memset(&plain, 0, sizeof plain);
    memset(&bare, 0, sizeof bare);
    n = oracle_emit(buf, true, false);
    CHECK(ds_rfcs_visit_atom(DS_ATOM_ORACLE_EMIT, buf, n, record, &plain).status == DS_OK,
          "ds_rfcs_visit_atom reads it");
    n = oracle_emit(buf, false, false);
    CHECK(ds_rfcs_visit_atom(DS_ATOM_ORACLE_EMIT, buf, n, record, &bare).status == DS_OK,
          "and the bytes without field 99");
    CHECK(plain.n == bare.n, "the two visits are the same length: field 99 is not visited");

    /* An arm that stops the walk stops it. */
    memset(&k, 0, sizeof k);
    n = oracle_emit(buf, true, true);
    r = ds_rfcs_visit_atom_with_unknown(DS_ATOM_ORACLE_EMIT, buf, n,
                                        record_any, stop_at_unknown, &k);
    CHECK(r.status == DS_OK, "an arm that stops is not an error");
    CHECK(k.n == 1 && k.seen.n == k.before[0],
          "and nothing is visited or reported after it stops");
}

int main(void)
{
    test_descriptors_are_the_registry();
    test_every_atom_reads();
    test_fcem_from_the_encoder();
    test_pump_int64();
    test_a_dsc_reads();
    test_refusals();
    test_rdsc_9_9__nesting_is_bounded_before_the_unpack();
    test_rtim_14_9__unknown_fields_are_reported();

    if (failures) {
        fprintf(stderr, "test_rfcs_reader: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_rfcs_reader: OK\n");
    return 0;
}
