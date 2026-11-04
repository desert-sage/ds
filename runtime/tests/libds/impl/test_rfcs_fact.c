/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [LSTR.1.5] [RFCS.6.3]
 * The schema-driven fact-body codec.
 *
 * Registers a schema spanning every supported scalar type (Int/Float/String/
 * Bool/Bytes), asserts a fact, encodes its slots to the FactAssert.fact proto3 body,
 * checks the bytes against a hand-computed golden vector (byte-exactness vs
 * the wire format the compiler proto + rfcs.py target), decodes the body back
 * and verifies the values, and confirms proto3 default-omission round-trips.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "engine.h"          /* ds_engine_t.rete_engine */
#include "rete/engine.h"
#include "rete/schema_reg.h" /* ds_rete_schema_register */
#include "rete/val.h"        /* DS_RETE_VAL_* */
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

static const ds_slot_desc_t SLOTS[5] = {
    { .name = "count", .type = DS_SLOT_TYPE_INT,    .identity_role = DS_IDENTITY_KEY },
    { .name = "ratio", .type = DS_SLOT_TYPE_FLOAT,  .identity_role = DS_IDENTITY_MUTABLE },
    { .name = "label", .type = DS_SLOT_TYPE_STRING, .identity_role = DS_IDENTITY_MUTABLE },
    { .name = "flag",  .type = DS_SLOT_TYPE_BOOL,   .identity_role = DS_IDENTITY_MUTABLE },
    { .name = "blob",  .type = DS_SLOT_TYPE_BYTES,  .identity_role = DS_IDENTITY_MUTABLE },
};

/* A schema with a Json slot (Json travels as the canonical proto3
   string, wire type 2 — same as String). */
static const ds_slot_desc_t JSLOTS[2] = {
    { .name = "id",  .type = DS_SLOT_TYPE_INT,  .identity_role = DS_IDENTITY_KEY },
    { .name = "doc", .type = DS_SLOT_TYPE_JSON, .identity_role = DS_IDENTITY_MUTABLE },
};

/* [RFCS.6.3]: nullable slots, whose fields are `optional` in the
   schema's proto_source and so have presence. */
static const ds_slot_desc_t NSLOTS[3] = {
    { .name = "id", .type = DS_SLOT_TYPE_INT,    .identity_role = DS_IDENTITY_KEY },
    { .name = "x",  .type = DS_SLOT_TYPE_FLOAT,  .identity_role = DS_IDENTITY_MUTABLE,
      .nullable = true },
    { .name = "s",  .type = DS_SLOT_TYPE_STRING, .identity_role = DS_IDENTITY_MUTABLE,
      .nullable = true },
};

/* A reader's handle map holding one fact, `user`: its own fact_id resolves to
   it, and any other handle -- or every handle, when `user` is NULL -- was
   given by no earlier record. */
static ds_result_t resolve_owner(void *user, uint64_t handle, ds_fact_t **out)
{
    ds_fact_t *f = (ds_fact_t *) user;
    uint64_t id = 0;
    *out = NULL;
    if (f != NULL && ds_fact_get_id(f, &id).status == DS_OK && id == handle) {
        *out = f;
        return (ds_result_t){ .status = DS_OK };
    }
    return (ds_result_t){ .status = DS_ERR_PARSE, .detail = "no such handle" };
}

int main(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (!e)
        return 1;

    const ds_schema_t *sc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Pkt", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       SLOTS, 5, &sc),
             "register_schema");

    /* [NFCT.1.1]: every schema is registered before the engine's first
       stream event, the first assert below, so the later sections' schemas
       are registered here. */
    const ds_schema_t *jsc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Doc", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       JSLOTS, 2, &jsc),
             "register json schema");
    const ds_schema_t *nsc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Maybe", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                       0, NSLOTS, 3, &nsc),
             "register nullable schema");
    const ds_schema_t *osc = NULL, *tsc = NULL;
    static const ds_slot_desc_t OSLOTS[1] = {
        { .name = "id", .type = DS_SLOT_TYPE_INT, .identity_role = DS_IDENTITY_KEY },
    };
    CHECK_OK(ds_engine_register_schema(e, "Owner", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                       0, OSLOTS, 1, &osc),
             "register Owner");
    ds_slot_desc_t TSLOTS[3] = {
        { .name = "n",     .type = DS_SLOT_TYPE_INT,    .identity_role = DS_IDENTITY_KEY },
        { .name = "owner", .type = DS_SLOT_TYPE_SCHEMA, .schema_ref = osc,
          .identity_role = DS_IDENTITY_MUTABLE },
        { .name = "alt",   .type = DS_SLOT_TYPE_SCHEMA, .schema_ref = osc,
          .identity_role = DS_IDENTITY_MUTABLE, .nullable = true },
    };
    CHECK_OK(ds_engine_register_schema(e, "Tag", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                       0, TSLOTS, 3, &tsc),
             "register Tag");

    /* Assert a fact with one value of each type. */
    uint8_t blob[2] = { 0xDE, 0xAD };
    ds_slot_value_t v[5];
    memset(v, 0, sizeof(v));
    v[0].kind = DS_SLOT_INT;
    v[0].v.i = 42;
    v[1].kind = DS_SLOT_FLOAT;
    v[1].v.f = 1.5;
    v[2].kind = DS_SLOT_STRING;
    v[2].v.s = "hi";
    v[3].kind = DS_SLOT_BOOL;
    v[3].v.b = true;
    v[4].kind = DS_SLOT_BYTES;
    v[4].v.bytes.data = blob;
    v[4].v.bytes.len = 2;

    ds_fact_t *fact = NULL;
    CHECK_OK(ds_engine_assert(e, sc, v, 5, &fact), "assert");

    /* Encode the fact body and check it byte-for-byte. */
    uint8_t body[64];
    size_t blen = 0;
    CHECK_OK(ds_rfcs_encode_fact_body(fact, body, sizeof(body), &blen),
             "encode_fact_body");

    static const uint8_t golden[] = {
        0x08, 0x2A,                                           /* f1 Int 42 */
        0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x3F, /* f2 Float 1.5 */
        0x1A, 0x02, 'h', 'i',                                 /* f3 String "hi" */
        0x20, 0x01,                                           /* f4 Bool true */
        0x2A, 0x02, 0xDE, 0xAD                                /* f5 Bytes DE AD */
    };
    CHECK(blen == sizeof(golden), "fact body golden length");
    CHECK(memcmp(body, golden, blen < sizeof(golden) ? blen : sizeof(golden)) == 0,
          "fact body golden bytes");

    /* Decode back and verify. */
    ds_slot_value_t dv[5];
    char scratch[128];
    uint32_t dn = 0;
    CHECK_OK(ds_rfcs_decode_fact_body(sc, body, blen, dv, 5, scratch, sizeof(scratch), &dn),
             "decode_fact_body");
    CHECK(dn == 5, "decoded slot count");
    CHECK(dv[0].kind == DS_SLOT_INT && dv[0].v.i == 42, "decode count");
    CHECK(dv[1].kind == DS_SLOT_FLOAT && dv[1].v.f == 1.5, "decode ratio");
    CHECK(dv[2].kind == DS_SLOT_STRING && strcmp(dv[2].v.s, "hi") == 0, "decode label");
    CHECK(dv[3].kind == DS_SLOT_BOOL && dv[3].v.b == true, "decode flag");
    CHECK(dv[4].kind == DS_SLOT_BYTES && dv[4].v.bytes.len == 2 &&
              memcmp(dv[4].v.bytes.data, blob, 2) == 0,
          "decode blob");

    /* proto3 default omission: a fact whose Int/Bool/String are defaults
       encodes only the non-default fields, and decode restores the defaults. */
    ds_slot_value_t v0[5];
    memset(v0, 0, sizeof(v0));
    v0[0].kind = DS_SLOT_INT;
    v0[0].v.i = 0; /* default -> omitted */
    v0[1].kind = DS_SLOT_FLOAT;
    v0[1].v.f = 2.0; /* non-default -> present */
    v0[2].kind = DS_SLOT_STRING;
    v0[2].v.s = ""; /* default -> omitted */
    v0[3].kind = DS_SLOT_BOOL;
    v0[3].v.b = false; /* default -> omitted */
    v0[4].kind = DS_SLOT_BYTES;
    v0[4].v.bytes.data = (const uint8_t *)"";
    v0[4].v.bytes.len = 0; /* default -> omitted */

    ds_fact_t *fact0 = NULL;
    CHECK_OK(ds_engine_assert(e, sc, v0, 5, &fact0), "assert defaults");
    size_t blen0 = 0;
    CHECK_OK(ds_rfcs_encode_fact_body(fact0, body, sizeof(body), &blen0),
             "encode defaults");
    /* Only field 2 (Float 2.0) survives: tag 0x11 + 8 fixed64 bytes = 9. */
    CHECK(blen0 == 9 && body[0] == 0x11, "default omission encodes one field");

    CHECK_OK(ds_rfcs_decode_fact_body(sc, body, blen0, dv, 5, scratch, sizeof(scratch), &dn),
             "decode defaults");
    CHECK(dv[0].v.i == 0 && dv[1].v.f == 2.0 && dv[2].v.s[0] == '\0' &&
              dv[3].v.b == false && dv[4].v.bytes.len == 0,
          "default round-trip");

    /* -0.0 is not the default: the default is the all-zero bit pattern, and
       only +0.0 has it, so a replay keeps the sign ([LDET.1.5]). Lockstep
       pair 109_pow_negzero / 78_pow_negzero. */
    ds_slot_value_t vz[5];
    memcpy(vz, v0, sizeof(vz));
    vz[0].v.i = 7;
    vz[1].v.f = -0.0;
    ds_fact_t *factz = NULL;
    CHECK_OK(ds_engine_assert(e, sc, vz, 5, &factz), "assert negative zero");
    size_t blenz = 0;
    CHECK_OK(ds_rfcs_encode_fact_body(factz, body, sizeof(body), &blenz),
             "encode negative zero");
    static const uint8_t negzero[] = {
        0x08, 0x07,                                           /* f1 Int 7 */
        0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80  /* f2 -0.0 */
    };
    CHECK(blenz == sizeof(negzero) &&
              memcmp(body, negzero, sizeof(negzero)) == 0,
          "negative zero is written, sign bit and all");
    CHECK_OK(ds_rfcs_decode_fact_body(sc, body, blenz, dv, 5, scratch,
                                      sizeof(scratch), &dn),
             "decode negative zero");
    uint64_t zbits = 0;
    memcpy(&zbits, &dv[1].v.f, sizeof(zbits));
    CHECK(dv[1].kind == DS_SLOT_FLOAT && zbits == 0x8000000000000000ull,
          "negative zero decodes with its sign");

    /* And +0.0 is still the omitted default. */
    vz[0].v.i = 8;
    vz[1].v.f = 0.0;
    CHECK_OK(ds_engine_assert(e, sc, vz, 5, &factz), "assert positive zero");
    CHECK_OK(ds_rfcs_encode_fact_body(factz, body, sizeof(body), &blenz),
             "encode positive zero");
    CHECK(blenz == 2 && body[0] == 0x08 && body[1] == 0x08,
          "positive zero is omitted");

    /* A Json slot round-trips as its canonical serialization, keys in
       lexicographic order. */
    ds_json_t *jt = NULL;
    CHECK_OK(ds_json_parse("{\"b\":2,\"a\":1}", 13, &jt), "json parse");
    char *canon = NULL;
    size_t canonlen = 0;
    CHECK_OK(ds_json_serialize(jt, &canon, &canonlen), "json canon");
    CHECK(canon && strstr(canon, "\"a\"") < strstr(canon, "\"b\""),
          "serialize canonicalises key order (a before b)");

    ds_slot_value_t jv[2];
    memset(jv, 0, sizeof(jv));
    jv[0].kind = DS_SLOT_INT;  jv[0].v.i = 7;
    jv[1].kind = DS_SLOT_JSON; jv[1].v.json = jt;
    ds_fact_t *jfact = NULL;
    CHECK_OK(ds_engine_assert(e, jsc, jv, 2, &jfact), "assert json");
    ds_json_free(jt); /* engine deep-cloned it */

    uint8_t jbody[128];
    size_t jblen = 0;
    CHECK_OK(ds_rfcs_encode_fact_body(jfact, jbody, sizeof(jbody), &jblen),
             "encode json body");
    /* field 1 (Int 7): 0x08 0x07; field 2 (Json): 0x12 <len> <canon bytes>. */
    CHECK(jblen == 2 + 2 + canonlen && jbody[0] == 0x08 && jbody[2] == 0x12,
          "json body shape (Int + len-delim Json string)");
    CHECK(canonlen < 128 && memcmp(jbody + 4, canon, canonlen) == 0,
          "json body carries the canonical text");

    ds_slot_value_t jdv[2];
    char jscratch[128];
    uint32_t jdn = 0;
    CHECK_OK(ds_rfcs_decode_fact_body(jsc, jbody, jblen, jdv, 2,
                                      jscratch, sizeof(jscratch), &jdn),
             "decode json body");
    CHECK(jdn == 2 && jdv[0].v.i == 7, "decode json id");
    CHECK(jdv[1].kind == DS_SLOT_JSON && jdv[1].v.json != NULL, "decode json present");
    char *rt = NULL;
    size_t rtlen = 0;
    CHECK_OK(ds_json_serialize(jdv[1].v.json, &rt, &rtlen), "reserialize decoded");
    CHECK(rt && strcmp(rt, canon) == 0, "json survives encode/decode canonically");
    ds_free(rt);
    ds_json_free(jdv[1].v.json); /* caller owns the decoded tree (rfcs.h) */
    ds_free(canon);

    /* [LSTR.1.5]: a String holds no U+0000, so a body carrying one is
       malformed, never cut short at the NUL. Hand-built: no conforming
       writer can produce one. */
    static const uint8_t nul_string[] = {
        0x08, 0x01,                     /* f1 Int 1 */
        0x1A, 0x03, 'a', 0x00, 'b'      /* f3 String "a\0b" */
    };
    ds_result_t rn = ds_rfcs_decode_fact_body(sc, nul_string,
                                              sizeof(nul_string), dv, 5,
                                              scratch, sizeof(scratch), &dn);
    CHECK(rn.status == DS_ERR_PARSE,
          "a String slot holding U+0000 is a malformed body (LSTR.1.5)");

    /* The Json arm parses the text whole, and the parser refuses U+0000
       spelled as an escape and as a raw byte alike. */
    static const uint8_t nul_json_escape[] = {
        0x08, 0x01,                                         /* f1 Int 1 */
        0x12, 0x0A, '"', 'a', '\\', 'u', '0', '0', '0', '0', 'b', '"'
    };
    ds_result_t rj = ds_rfcs_decode_fact_body(jsc, nul_json_escape,
                                              sizeof(nul_json_escape), jdv, 2,
                                              jscratch, sizeof(jscratch), &jdn);
    CHECK(rj.status != DS_OK,
          "a Json leaf spelling \\u0000 is a malformed body (LSTR.1.5)");
    static const uint8_t nul_json_raw[] = {
        0x08, 0x01,                                         /* f1 Int 1 */
        0x12, 0x05, '"', 'a', 0x00, 'b', '"'
    };
    rj = ds_rfcs_decode_fact_body(jsc, nul_json_raw, sizeof(nul_json_raw),
                                  jdv, 2, jscratch, sizeof(jscratch), &jdn);
    CHECK(rj.status != DS_OK,
          "a Json leaf holding a raw U+0000 is a malformed body (LSTR.1.5)");

    /* Text that is not well-formed UTF-8 is a malformed body, in the String
       and the Json arm alike. */
    static const uint8_t ill_string[] = {
        0x08, 0x01,                     /* f1 Int 1 */
        0x1A, 0x02, 'a', 0xFF           /* f3 String */
    };
    rn = ds_rfcs_decode_fact_body(sc, ill_string, sizeof(ill_string), dv, 5,
                                  scratch, sizeof(scratch), &dn);
    CHECK(rn.status == DS_ERR_PARSE,
          "a String slot that is not well-formed UTF-8 is a malformed body");
    static const uint8_t ill_json[] = {
        0x08, 0x01,                     /* f1 Int 1 */
        0x12, 0x04, '"', 'a', 0xFF, '"' /* f2 Json */
    };
    rj = ds_rfcs_decode_fact_body(jsc, ill_json, sizeof(ill_json), jdv, 2,
                                  jscratch, sizeof(jscratch), &jdn);
    CHECK(rj.status == DS_ERR_PARSE,
          "a Json slot's text that is not well-formed UTF-8 is a malformed body");

    /* [LGRA.5.8.7]: a recorded Json object that repeats a key is a malformed
       body. Hand-built: the canonical serializer cannot write one. */
    static const uint8_t dup_json[] = {
        0x08, 0x01,                                         /* f1 Int 1 */
        0x12, 0x0D, '{', '"', 'a', '"', ':', '1', ',',
                    '"', 'a', '"', ':', '2', '}'            /* f2 {"a":1,"a":2} */
    };
    rj = ds_rfcs_decode_fact_body(jsc, dup_json, sizeof(dup_json),
                                  jdv, 2, jscratch, sizeof(jscratch), &jdn);
    CHECK(rj.status == DS_ERR_PARSE,
          /* @spec [LGRA.5.8.7] */
          "test_lgra_5_8_7_recorded_duplicate_refused: a recorded Json object "
          "that repeats a key is a malformed body (LGRA.5.8.7)");

    /* [RFCS.6.3]: a nullable slot has presence.
         A: x = null, s = ""    -> x absent, s present and empty
         B: x = 0.0,  s = null  -> x present (+0.0), s absent */
    {
        ds_slot_value_t na[3], nb[3];
        memset(na, 0, sizeof(na));
        memset(nb, 0, sizeof(nb));
        na[0].kind = DS_SLOT_INT;    na[0].v.i = 3;
        na[1].kind = DS_SLOT_NULL;
        na[2].kind = DS_SLOT_STRING; na[2].v.s = "";
        nb[0].kind = DS_SLOT_INT;    nb[0].v.i = 4;
        nb[1].kind = DS_SLOT_FLOAT;  nb[1].v.f = 0.0;
        nb[2].kind = DS_SLOT_NULL;

        ds_fact_t *fa = NULL, *fb = NULL;
        CHECK_OK(ds_engine_assert(e, nsc, na, 3, &fa), "assert A (null, \"\")");
        CHECK_OK(ds_engine_assert(e, nsc, nb, 3, &fb), "assert B (0.0, null)");

        uint8_t nbody[64];
        size_t nlen = 0;
        CHECK_OK(ds_rfcs_encode_fact_body(fa, nbody, sizeof(nbody), &nlen),
                 "encode A");
        static const uint8_t golden_a[] = {
            0x08, 0x03,      /* f1 Int 3 */
            0x1A, 0x00       /* f3 String "" -- present, empty */
        };
        CHECK(nlen == sizeof(golden_a) && memcmp(nbody, golden_a, nlen) == 0,
              "A: null x is absent, \"\" s is a present empty field");

        ds_slot_value_t nd[3];
        char nscratch[64];
        uint32_t nn = 0;
        CHECK_OK(ds_rfcs_decode_fact_body(nsc, nbody, nlen, nd, 3, nscratch,
                                          sizeof(nscratch), &nn),
                 "decode A");
        CHECK(nn == 3 && nd[0].kind == DS_SLOT_INT && nd[0].v.i == 3,
              "A: id decodes");
        CHECK(nd[1].kind == DS_SLOT_NULL, "A: an absent nullable field decodes as null");
        CHECK(nd[2].kind == DS_SLOT_STRING && nd[2].v.s && nd[2].v.s[0] == '\0',
              "A: a present empty string decodes as \"\", not null");

        CHECK_OK(ds_rfcs_encode_fact_body(fb, nbody, sizeof(nbody), &nlen),
                 "encode B");
        static const uint8_t golden_b[] = {
            0x08, 0x04,                                           /* f1 Int 4 */
            0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00  /* f2 +0.0, present */
        };
        CHECK(nlen == sizeof(golden_b) && memcmp(nbody, golden_b, nlen) == 0,
              "B: a nullable +0.0 is written, a null s is absent");
        CHECK_OK(ds_rfcs_decode_fact_body(nsc, nbody, nlen, nd, 3, nscratch,
                                          sizeof(nscratch), &nn),
                 "decode B");
        uint64_t xbits = 1;
        memcpy(&xbits, &nd[1].v.f, sizeof(xbits));
        CHECK(nd[1].kind == DS_SLOT_FLOAT && xbits == 0,
              "B: a present +0.0 decodes as 0.0, not null");
        CHECK(nd[2].kind == DS_SLOT_NULL, "B: an absent nullable string decodes as null");
    }

    /* [RFCS.6.3], [RDSC.5.8.3]: a fact-reference slot's field is a `uint64`
       holding the referenced fact's `fact_id`. A reader resolves it through
       its map and refuses one no earlier record gave (DS_ERR_PARSE).
       `Tag.alt` is nullable and left null, so its field is absent. */
    {
        ds_slot_value_t ov[1] = { { .kind = DS_SLOT_INT, .v.i = 1 } };
        ds_fact_t *owner = NULL;
        CHECK_OK(ds_engine_assert(e, osc, ov, 1, &owner), "assert Owner");
        uint64_t owner_id = 0;
        CHECK_OK(ds_fact_get_id(owner, &owner_id), "Owner's fact_id");
        CHECK(owner_id > 0 && owner_id < 128, "Owner's fact_id is a one-byte varint");

        ds_slot_value_t tv[3];
        memset(tv, 0, sizeof(tv));
        tv[0].kind = DS_SLOT_INT;      tv[0].v.i = 1;
        tv[1].kind = DS_SLOT_FACT_REF; tv[1].v.ref = owner;
        tv[2].kind = DS_SLOT_NULL;
        ds_fact_t *tag = NULL;
        CHECK_OK(ds_engine_assert(e, tsc, tv, 3, &tag), "assert Tag");

        uint8_t rbody[16];
        size_t rlen = 0;
        CHECK_OK(ds_rfcs_encode_fact_body(tag, rbody, sizeof(rbody), &rlen),
                 "encode a body with a reference");
        const uint8_t golden_r[] = {
            0x08, 0x01,                   /* f1 Int 1 */
            0x10, (uint8_t) owner_id      /* f2 uint64: Owner's handle */
                                          /* f3 absent: alt is null */
        };
        CHECK(rlen == sizeof(golden_r) && memcmp(rbody, golden_r, rlen) == 0,
              "a reference is its target's fact_id; a null one is absent");

        ds_slot_value_t rd[3];
        char rscratch[32];
        uint32_t rn = 0;
        ds_result_t rr = ds_rfcs_decode_fact_body(tsc, rbody, rlen, rd, 3,
                                                  rscratch, sizeof(rscratch), &rn);
        CHECK(rr.status == DS_ERR_INVAL,
              "with no handle map a reference cannot be decoded (RFCS.4)");

        CHECK_OK(ds_rfcs_decode_fact_body_resolving(tsc, rbody, rlen, rd, 3,
                                                    rscratch, sizeof(rscratch),
                                                    resolve_owner, owner, &rn),
                 "decode through the handle map");
        CHECK(rn == 3 && rd[0].kind == DS_SLOT_INT && rd[0].v.i == 1, "n decodes");
        CHECK(rd[1].kind == DS_SLOT_FACT_REF && rd[1].v.ref == owner,
              "the handle resolves to the fact its record carries");
        CHECK(rd[2].kind == DS_SLOT_NULL, "an absent nullable reference is null");

        rr = ds_rfcs_decode_fact_body_resolving(tsc, rbody, rlen, rd, 3,
                                                rscratch, sizeof(rscratch),
                                                resolve_owner, NULL, &rn);
        CHECK(rr.status == DS_ERR_PARSE,
              "a handle no earlier record gave is refused (DS_ERR_PARSE)");

        static const uint8_t zero_handle[] = { 0x08, 0x01, 0x10, 0x00 };
        rr = ds_rfcs_decode_fact_body_resolving(tsc, zero_handle,
                                                sizeof(zero_handle), rd, 3,
                                                rscratch, sizeof(rscratch),
                                                resolve_owner, owner, &rn);
        CHECK(rr.status == DS_ERR_PARSE, "a handle of 0 names no record");

        static const uint8_t no_owner[] = { 0x08, 0x01 };
        rr = ds_rfcs_decode_fact_body_resolving(tsc, no_owner, sizeof(no_owner),
                                                rd, 3, rscratch, sizeof(rscratch),
                                                resolve_owner, owner, &rn);
        CHECK(rr.status == DS_ERR_PARSE,
              "an absent non-nullable reference names nothing");
    }

    ds_engine_free(e);

    if (failures) {
        fprintf(stderr, "test_rfcs_fact: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_rfcs_fact: OK\n");
    return 0;
}
