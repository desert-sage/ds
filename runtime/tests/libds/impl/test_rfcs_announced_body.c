/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [RFCS.5.1] [RFCS.6.3]
 * A fact body typed by the stream's own Slot announcement decodes to what the
 * program's schema decodes it to.
 *
 * A reader with no program types a recording's facts by the SchemaDef and
 * Slot atoms the stream carries ([RFCS.5.1]); ds_rfcs_decode_announced_fact_body
 * is the call. An engine registers one schema with a slot of every kind a
 * body can carry but a fact reference: a nullable Int, an Int held at zero,
 * Json, String, Float, Bool, Bytes and Time. Two facts are recorded: one with
 * the nullable Int `null` beside the zero ([RFCS.6.3]), one with the nullable
 * Int 0 and the other values flipped. The Slot atoms are read back off the
 * wire into ds_rfcs_announced_slot_t records, and each FactAssert body is
 * decoded twice, by the announcement and by the schema; the values must be
 * equal, kind and value, Json by its canonical text.
 *
 * PATH PINNED: rfcs/codec.c's ds_rfcs_decode_announced_fact_body, through
 * announced_body_slot (Slot.kind to slot type) into decode_body, the decoder
 * ds_rfcs_decode_fact_body uses.
 *
 * THE COMPARISON CAN FAIL, and the cases after it show it does: the same body
 * decoded by the announcement with the nullable Int's `nullable` cleared
 * reads 0 where the schema reads `null`. And the call refuses what it cannot
 * type: a fact-ref slot (no handle map, [RFCS.4]), SLOT_KIND_UNSPECIFIED, a
 * number SlotKind does not name, and a values array too small.
 *
 * FACT REFERENCES, `check_fact_ref_handles`: a second engine records
 * an Owner and then a Tag whose `owner` names it, whose nullable `alt` is
 * null, and which carries a String beside them. A host assert of such a fact
 * is an ExternalAssert ([RFCS.24.1]), so the body under test is the one a
 * rule's FactEmit carries, ds_rfcs_encode_fact_body's over the live Tag; the
 * Slot atoms and the Owner's record are the recording's. It is decoded with
 * ds_rfcs_decode_announced_fact_body_handles. Every slot is typed; `owner`'s
 * handle is the `fact_id` of the record that carried the Owner ([RFCS.6.3]);
 * `alt` is null with handle 0; the other slots equal what
 * ds_rfcs_decode_fact_body_resolving gives through a map to the live Owner,
 * which resolves `owner` to that Owner. A handle of 0 and an absent
 * non-nullable reference are refused, as the resolving decode refuses them.
 * PATH PINNED: the same decode_body, its fact-ref seed and varint arm taking
 * `handles` with no resolver.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "engine.h"   /* ds_engine_register_schema, libds-internal */
#include "rfcs/rfcs.h"
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

#define N_SLOTS 9

static const ds_slot_desc_t SLOTS[N_SLOTS] = {
    { .name = "id",    .type = DS_SLOT_TYPE_INT,    .identity_role = DS_IDENTITY_KEY },
    { .name = "n",     .type = DS_SLOT_TYPE_INT,    .identity_role = DS_IDENTITY_MUTABLE,
      .nullable = true },
    { .name = "z",     .type = DS_SLOT_TYPE_INT,    .identity_role = DS_IDENTITY_MUTABLE },
    { .name = "doc",   .type = DS_SLOT_TYPE_JSON,   .identity_role = DS_IDENTITY_MUTABLE },
    { .name = "label", .type = DS_SLOT_TYPE_STRING, .identity_role = DS_IDENTITY_MUTABLE },
    { .name = "ratio", .type = DS_SLOT_TYPE_FLOAT,  .identity_role = DS_IDENTITY_MUTABLE },
    { .name = "on",    .type = DS_SLOT_TYPE_BOOL,   .identity_role = DS_IDENTITY_MUTABLE },
    { .name = "blob",  .type = DS_SLOT_TYPE_BYTES,  .identity_role = DS_IDENTITY_MUTABLE },
    { .name = "seen",  .type = DS_SLOT_TYPE_TIME,   .identity_role = DS_IDENTITY_MUTABLE },
};

static uint8_t g_stream[16384];
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

/* Two decoded values are the same value: kind, then the value by kind, a
   Json tree by its canonical text. */
static bool same_value(const ds_slot_value_t *a, const ds_slot_value_t *b)
{
    if (a->kind != b->kind) return false;
    switch (a->kind) {
    case DS_SLOT_NULL:   return true;
    case DS_SLOT_INT:    return a->v.i == b->v.i;
    case DS_SLOT_FLOAT:  return memcmp(&a->v.f, &b->v.f, sizeof(double)) == 0;
    case DS_SLOT_BOOL:   return a->v.b == b->v.b;
    case DS_SLOT_STRING: return strcmp(a->v.s, b->v.s) == 0;
    case DS_SLOT_BYTES:
        return a->v.bytes.len == b->v.bytes.len
            && (a->v.bytes.len == 0
                || memcmp(a->v.bytes.data, b->v.bytes.data, a->v.bytes.len) == 0);
    case DS_SLOT_JSON: {
        if (a->v.json == NULL || b->v.json == NULL)
            return a->v.json == b->v.json;
        char *ta = NULL, *tb = NULL;
        size_t la = 0, lb = 0;
        bool same = ds_json_serialize(a->v.json, &ta, &la).status == DS_OK
                 && ds_json_serialize(b->v.json, &tb, &lb).status == DS_OK
                 && la == lb && memcmp(ta, tb, la) == 0;
        ds_free(ta);
        ds_free(tb);
        return same;
    }
    default:
        return false;
    }
}

static void free_json(ds_slot_value_t *v, uint32_t n)
{
    for (uint32_t i = 0; i < n; i++)
        if (v[i].kind == DS_SLOT_JSON && v[i].v.json != NULL) {
            ds_json_free(v[i].v.json);
            v[i].v.json = NULL;
        }
}

static void assert_reading(ds_engine_t *e, const ds_schema_t *sc, int64_t id,
                           bool n_null, int64_t n, int64_t z, const char *doc,
                           const char *label, double ratio, bool on,
                           const char *blob, int64_t seen)
{
    ds_json_t *jt = NULL;
    CHECK_OK(ds_json_parse(doc, strlen(doc), &jt), "json parse");
    ds_slot_value_t v[N_SLOTS];
    memset(v, 0, sizeof(v));
    v[0].kind = DS_SLOT_INT;    v[0].v.i = id;
    if (n_null) {
        v[1].kind = DS_SLOT_NULL;
    } else {
        v[1].kind = DS_SLOT_INT; v[1].v.i = n;
    }
    v[2].kind = DS_SLOT_INT;    v[2].v.i = z;
    v[3].kind = DS_SLOT_JSON;   v[3].v.json = jt;
    v[4].kind = DS_SLOT_STRING; v[4].v.s = label;
    v[5].kind = DS_SLOT_FLOAT;  v[5].v.f = ratio;
    v[6].kind = DS_SLOT_BOOL;   v[6].v.b = on;
    v[7].kind = DS_SLOT_BYTES;
    v[7].v.bytes.data = (const uint8_t *)blob;
    v[7].v.bytes.len  = strlen(blob);
    v[8].kind = DS_SLOT_INT;    v[8].v.i = seen;
    ds_fact_t *fact = NULL;
    CHECK_OK(ds_engine_assert(e, sc, v, N_SLOTS, &fact), "assert a Reading");
    ds_json_free(jt); /* the engine deep-cloned it */
}

/* The resolving decode's map, for the comparison: the one handle this
   recording's Owner was written under, to that Owner. */
typedef struct {
    uint64_t   handle;
    ds_fact_t *fact;
} owner_map_t;

static ds_result_t resolve_owner(void *user, uint64_t handle, ds_fact_t **out)
{
    const owner_map_t *m = user;
    if (handle != m->handle)
        return (ds_result_t){ DS_ERR_PARSE, "no record gave this handle" };
    *out = m->fact;
    return (ds_result_t){ DS_OK, NULL };
}

#define N_TAG 4

static void check_fact_ref_handles(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "refs: engine_new");
    if (!e) return;

    static const ds_slot_desc_t OSLOTS[1] = {
        { .name = "id", .type = DS_SLOT_TYPE_INT, .identity_role = DS_IDENTITY_KEY },
    };
    const ds_schema_t *osc = NULL, *tsc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Owner", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                       0, OSLOTS, 1, &osc),
             "refs: register Owner");
    ds_slot_desc_t TSLOTS[N_TAG] = {
        { .name = "n",     .type = DS_SLOT_TYPE_INT,    .identity_role = DS_IDENTITY_KEY },
        { .name = "owner", .type = DS_SLOT_TYPE_SCHEMA, .schema_ref = osc,
          .identity_role = DS_IDENTITY_MUTABLE },
        { .name = "alt",   .type = DS_SLOT_TYPE_SCHEMA, .schema_ref = osc,
          .identity_role = DS_IDENTITY_MUTABLE, .nullable = true },
        { .name = "label", .type = DS_SLOT_TYPE_STRING, .identity_role = DS_IDENTITY_MUTABLE },
    };
    CHECK_OK(ds_engine_register_schema(e, "Tag", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                       0, TSLOTS, N_TAG, &tsc),
             "refs: register Tag");

    ds_rfcs_recorder_t rec;
    uint8_t recbuf[8192];
    g_stream_len = 0;
    CHECK_OK(ds_rfcs_record_to(e, &rec, test_sink, NULL, recbuf, sizeof(recbuf)),
             "refs: record_to");

    ds_slot_value_t ov[1] = { { .kind = DS_SLOT_INT, .v.i = 7 } };
    ds_fact_t *owner = NULL;
    CHECK_OK(ds_engine_assert(e, osc, ov, 1, &owner), "refs: assert Owner");
    ds_slot_value_t tv[N_TAG];
    memset(tv, 0, sizeof(tv));
    tv[0].kind = DS_SLOT_INT;      tv[0].v.i = 1;
    tv[1].kind = DS_SLOT_FACT_REF; tv[1].v.ref = owner;
    tv[2].kind = DS_SLOT_NULL;
    tv[3].kind = DS_SLOT_STRING;   tv[3].v.s = "linked";
    ds_fact_t *tag = NULL;
    CHECK_OK(ds_engine_assert(e, tsc, tv, N_TAG, &tag), "refs: assert Tag");
    CHECK(rec.last.status == DS_OK, "refs: recorder had no error");
    ds_engine_set_stream_callback(e, NULL, NULL);

    Ds__V1__Slot *msgs[N_TAG] = {0};
    ds_rfcs_announced_slot_t ann[N_TAG];
    memset(ann, 0, sizeof(ann));
    uint32_t n_ann = 0;
    uint64_t owner_record = 0;   /* the fact_id the Owner's record carries */
    int tag_as_fact_assert = 0;

    ds_rfcs_reader_t rd;
    ds_rfcs_reader_init(&rd, g_stream, g_stream_len);
    for (;;) {
        uint32_t atom;
        const uint8_t *body;
        size_t blen;
        bool done = false;
        ds_result_t r = ds_rfcs_next(&rd, &atom, &body, &blen, &done);
        CHECK_OK(r, "refs: next atom");
        if (r.status != DS_OK || done) break;

        if (atom == DS_ATOM_SLOT) {
            Ds__V1__Slot *sl = ds__v1__slot__unpack(NULL, blen, body);
            CHECK(sl != NULL, "refs: Slot body decodes");
            if (sl == NULL) continue;
            if (sl->schema_name && strcmp(sl->schema_name, "Tag") == 0
                    && n_ann < N_TAG) {
                msgs[n_ann] = sl;
                ann[n_ann].name       = sl->slot_name;
                ann[n_ann].kind       = (uint32_t)sl->kind;
                ann[n_ann].nullable   = sl->nullable;
                ann[n_ann].schema_ref = sl->schema_ref;
                n_ann++;
            } else {
                ds__v1__slot__free_unpacked(sl, NULL);
            }
        } else if (atom == DS_ATOM_FACT_ASSERT) {
            ds_rfcs_fcem_t fc;
            CHECK_OK(ds_rfcs_decode_fcem(body, blen, &fc), "refs: decode FactAssert");
            if (ds_rfcs_str_eq(fc.schema_name, "Owner"))
                owner_record = fc.fact_id;
            else
                tag_as_fact_assert++;
        }
    }
    CHECK(n_ann == N_TAG, "refs: the stream announces Tag's four slots");
    CHECK(owner_record != 0, "refs: the Owner is recorded as a FactAssert");
    /* [RFCS.24.1]: a HOST assert of a fact holding a reference is an
       ExternalAssert, not a FactAssert, so the stream carries no fact body for
       the Tag. A rule's FactEmit does carry one, and the recorder writes it
       with emit_fact_fields, the encoder ds_rfcs_encode_fact_body is. So the
       body under test is that encoder's, over the live Tag. */
    CHECK(tag_as_fact_assert == 0,
          "refs: the Tag is not a FactAssert (RFCS.24.1)");

    uint8_t tbody[64];
    size_t tlen = 0;
    CHECK_OK(ds_rfcs_encode_fact_body(tag, tbody, sizeof(tbody), &tlen),
             "refs: the Tag's body, as a FactEmit carries it");

    if (n_ann == N_TAG && owner_record != 0) {
        /* The plain announced decode still refuses the body. */
        ds_slot_value_t plain[N_TAG];
        char p_scratch[64];
        uint32_t pn = 0;
        CHECK(ds_rfcs_decode_announced_fact_body(ann, n_ann, tbody, tlen,
                                                 plain, N_TAG, p_scratch,
                                                 sizeof(p_scratch), &pn)
                  .status == DS_ERR_INVAL,
              "refs: the decode without handles refuses a fact-ref body");

        ds_slot_value_t by_ann[N_TAG], by_map[N_TAG];
        uint64_t handles[N_TAG];
        char a_scratch[64], m_scratch[64];
        uint32_t an = 0, mn = 0;
        memset(handles, 0xA5, sizeof(handles));  /* every entry must be set */
        CHECK_OK(ds_rfcs_decode_announced_fact_body_handles(
                     ann, n_ann, tbody, tlen, by_ann, handles, N_TAG,
                     a_scratch, sizeof(a_scratch), &an),
                 "refs: decode by the announcement, handles as recorded");
        owner_map_t map = { owner_record, owner };
        CHECK_OK(ds_rfcs_decode_fact_body_resolving(
                     tsc, tbody, tlen, by_map, N_TAG, m_scratch,
                     sizeof(m_scratch), resolve_owner, &map, &mn),
                 "refs: decode by the schema through the handle map");
        CHECK(an == N_TAG && mn == N_TAG, "refs: every slot of the Tag is typed");

        /* `owner`: a reference with the Owner record's fact_id. */
        CHECK(by_ann[1].kind == DS_SLOT_FACT_REF && by_ann[1].v.ref == NULL,
              "refs: a present reference is FACT_REF with no fact resolved");
        CHECK(handles[1] == owner_record,
              "refs: the handle is the fact_id of the Owner's record (RFCS.6.3)");
        uint64_t owner_id = 0;
        CHECK_OK(ds_fact_get_id(owner, &owner_id), "refs: Owner's fact_id");
        CHECK(handles[1] == owner_id, "refs: and that is the Owner's own fact_id");
        CHECK(by_map[1].kind == DS_SLOT_FACT_REF && by_map[1].v.ref == owner,
              "refs: the map resolves the same handle to the Owner");

        /* `alt`: an absent nullable reference. */
        CHECK(by_ann[2].kind == DS_SLOT_NULL && handles[2] == 0,
              "refs: an absent nullable reference is null, handle 0");
        CHECK(by_map[2].kind == DS_SLOT_NULL, "refs: and null by the map");

        /* The other slots: as the resolving decode gives them. */
        CHECK(handles[0] == 0 && handles[3] == 0,
              "refs: a slot that is no reference has handle 0");
        CHECK(same_value(&by_ann[0], &by_map[0]) && by_ann[0].v.i == 1,
              "refs: n is typed as the schema types it");
        CHECK(same_value(&by_ann[3], &by_map[3])
                  && strcmp(by_ann[3].v.s, "linked") == 0,
              "refs: label is typed as the schema types it");
    }

    /* The refusals are the resolving decode's. Hand-made bodies, typed by the
       announcement read off the wire above. */
    if (n_ann == N_TAG) {
        ds_slot_value_t v[N_TAG];
        uint64_t h[N_TAG];
        char scratch[16];
        uint32_t n = 0;
        static const uint8_t zero_handle[] = { 0x08, 0x01, 0x10, 0x00 };
        CHECK(ds_rfcs_decode_announced_fact_body_handles(
                  ann, n_ann, zero_handle, sizeof(zero_handle), v, h, N_TAG,
                  scratch, sizeof(scratch), &n).status == DS_ERR_PARSE,
              "refs: a handle of 0 names no record");
        static const uint8_t no_owner[] = { 0x08, 0x01 };
        CHECK(ds_rfcs_decode_announced_fact_body_handles(
                  ann, n_ann, no_owner, sizeof(no_owner), v, h, N_TAG,
                  scratch, sizeof(scratch), &n).status == DS_ERR_PARSE,
              "refs: an absent non-nullable reference names nothing");
        CHECK(ds_rfcs_decode_announced_fact_body_handles(
                  ann, n_ann, no_owner, sizeof(no_owner), v, NULL, N_TAG,
                  scratch, sizeof(scratch), &n).status == DS_ERR_INVAL,
              "refs: the handles array is required");
    }

    for (uint32_t i = 0; i < n_ann; i++)
        ds__v1__slot__free_unpacked(msgs[i], NULL);
    ds_engine_free(e);
}

int main(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (!e) return 1;

    const ds_schema_t *sc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Reading", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                       0, SLOTS, N_SLOTS, &sc),
             "register_schema with a slot of every body kind");
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "mock clock");
    CHECK_OK(ds_engine_clock_set(e, 1000), "clock 1000");

    ds_rfcs_recorder_t rec;
    uint8_t recbuf[8192];
    g_stream_len = 0;
    CHECK_OK(ds_rfcs_record_to(e, &rec, test_sink, NULL, recbuf, sizeof(recbuf)),
             "record_to");

    /* The nullable Int null beside a zero ([RFCS.6.3]); then 0 present, the
       other values flipped. */
    assert_reading(e, sc, 1, true, 0, 0, "{\"b\":2,\"a\":1}", "x", 1.5, true,
                   "ab", INT64_C(1791676800000000000));
    assert_reading(e, sc, 2, false, 0, 7, "[]", "", 0.0, false, "", 0);
    CHECK(rec.last.status == DS_OK, "recorder had no error");
    ds_engine_set_stream_callback(e, NULL, NULL);

    /* The announcement, off the wire. The unpacked Slot messages are kept
       until the end, since the records borrow their strings. */
    Ds__V1__Slot *msgs[N_SLOTS] = {0};
    ds_rfcs_announced_slot_t ann[N_SLOTS];
    memset(ann, 0, sizeof(ann));
    uint32_t n_ann = 0;
    int bodies = 0;

    ds_rfcs_reader_t rd;
    ds_rfcs_reader_init(&rd, g_stream, g_stream_len);
    for (;;) {
        uint32_t atom;
        const uint8_t *body;
        size_t blen;
        bool done = false;
        ds_result_t r = ds_rfcs_next(&rd, &atom, &body, &blen, &done);
        CHECK_OK(r, "next atom");
        if (r.status != DS_OK || done) break;

        if (atom == DS_ATOM_SLOT) {
            Ds__V1__Slot *sl = ds__v1__slot__unpack(NULL, blen, body);
            CHECK(sl != NULL, "Slot body decodes");
            if (sl == NULL) continue;
            if (sl->schema_name && strcmp(sl->schema_name, "Reading") == 0
                    && n_ann < N_SLOTS) {
                msgs[n_ann] = sl;
                ann[n_ann].name       = sl->slot_name;
                ann[n_ann].kind       = (uint32_t)sl->kind;
                ann[n_ann].nullable   = sl->nullable;
                ann[n_ann].schema_ref = sl->schema_ref;
                n_ann++;
            } else {
                ds__v1__slot__free_unpacked(sl, NULL);
            }
        } else if (atom == DS_ATOM_FACT_ASSERT) {
            CHECK(n_ann == N_SLOTS, "the schema is announced before its facts");
            ds_rfcs_fcem_t fc;
            CHECK_OK(ds_rfcs_decode_fcem(body, blen, &fc), "decode FactAssert");

            ds_slot_value_t by_schema[N_SLOTS], by_ann[N_SLOTS];
            char s_scratch[256], a_scratch[256];
            uint32_t sn = 0, an = 0;
            CHECK_OK(ds_rfcs_decode_fact_body(sc, fc.fact, fc.fact_len,
                                              by_schema, N_SLOTS, s_scratch,
                                              sizeof(s_scratch), &sn),
                     "decode by the program's schema");
            CHECK_OK(ds_rfcs_decode_announced_fact_body(ann, n_ann, fc.fact,
                                                        fc.fact_len, by_ann,
                                                        N_SLOTS, a_scratch,
                                                        sizeof(a_scratch), &an),
                     "decode by the stream's own announcement");
            CHECK(sn == N_SLOTS && an == N_SLOTS, "every slot decoded");
            for (uint32_t i = 0; i < sn && i < an; i++) {
                if (!same_value(&by_schema[i], &by_ann[i]))
                    fprintf(stderr, "  slot %s differs (kind %d vs %d)\n",
                            SLOTS[i].name, (int)by_schema[i].kind,
                            (int)by_ann[i].kind);
                CHECK(same_value(&by_schema[i], &by_ann[i]),
                      "the announcement types the body as the schema does");
            }
            /* The first fact's nullable Int is null and its zero is 0. */
            if (bodies == 0) {
                CHECK(by_ann[1].kind == DS_SLOT_NULL,
                      "an absent nullable field is null by the announcement");
                CHECK(by_ann[2].kind == DS_SLOT_INT && by_ann[2].v.i == 0,
                      "an absent non-nullable Int is 0 by the announcement");

                /* THE COMPARISON CAN FAIL: clear the announced `nullable` and
                   the same body reads 0 where the schema reads null. */
                ds_rfcs_announced_slot_t flipped[N_SLOTS];
                memcpy(flipped, ann, sizeof(flipped));
                flipped[1].nullable = false;
                ds_slot_value_t by_flip[N_SLOTS];
                char f_scratch[256];
                uint32_t fn = 0;
                CHECK_OK(ds_rfcs_decode_announced_fact_body(flipped, n_ann,
                                                            fc.fact, fc.fact_len,
                                                            by_flip, N_SLOTS,
                                                            f_scratch,
                                                            sizeof(f_scratch),
                                                            &fn),
                         "decode by an announcement with `nullable` cleared");
                CHECK(fn == N_SLOTS && !same_value(&by_schema[1], &by_flip[1]),
                      "a different announcement types the body differently");
                free_json(by_flip, fn);
            }
            free_json(by_schema, sn);
            free_json(by_ann, an);
            bodies++;
        }
    }
    CHECK(bodies == 2, "both asserts are recorded");

    /* What the call refuses. */
    {
        static const uint8_t empty_body[1] = { 0 };
        ds_slot_value_t v[2];
        char scratch[16];
        uint32_t n = 0;
        ds_rfcs_announced_slot_t ref[1] = {
            { .name = "who", .kind = DS__V1__SLOT_KIND__SLOT_KIND_SCHEMA,
              .schema_ref = "Person" },
        };
        CHECK(ds_rfcs_decode_announced_fact_body(ref, 1, empty_body, 0, v, 2,
                                                 scratch, sizeof(scratch), &n)
                  .status == DS_ERR_INVAL,
              "a fact-ref slot is refused: its handle needs the stream's map");
        ds_rfcs_announced_slot_t unspecified[1] = {
            { .name = "x", .kind = DS__V1__SLOT_KIND__SLOT_KIND_UNSPECIFIED },
        };
        CHECK(ds_rfcs_decode_announced_fact_body(unspecified, 1, empty_body, 0,
                                                 v, 2, scratch, sizeof(scratch),
                                                 &n).status == DS_ERR_INVAL,
              "SLOT_KIND_UNSPECIFIED types nothing");
        ds_rfcs_announced_slot_t unknown[1] = { { .name = "x", .kind = 99 } };
        CHECK(ds_rfcs_decode_announced_fact_body(unknown, 1, empty_body, 0, v,
                                                 2, scratch, sizeof(scratch), &n)
                  .status == DS_ERR_INVAL,
              "a kind SlotKind does not name types nothing");
        CHECK(ds_rfcs_decode_announced_fact_body(ann, n_ann, empty_body, 0, v,
                                                 2, scratch, sizeof(scratch), &n)
                  .status == DS_ERR_INVAL,
              "a values array smaller than the announcement is refused");
    }

    for (uint32_t i = 0; i < n_ann; i++)
        ds__v1__slot__free_unpacked(msgs[i], NULL);
    ds_engine_free(e);

    check_fact_ref_handles();

    if (failures) {
        fprintf(stderr, "test_rfcs_announced_body: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_rfcs_announced_body: OK\n");
    return 0;
}
