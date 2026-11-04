/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * A wire-2 length near 2^64 in a fact-stream body is a truncated body,
 * DS_ERR_PARSE, in each hand-walked decoder in rfcs/codec.c: a length of
 * 2^64 - k must not wrap `pos + len` below the body's end. Each body is
 * exactly as long as its bytes, so asan sees a read past it, and a twin
 * whose length fits decodes.
 *
 * ds_rfcs_decode_femt unpacks with protobuf-c first, which refuses the
 * length, so its case checks that no `fact` view is set.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "engine.h"          /* ds_engine_register_schema */
#include "rfcs/rfcs.h"

static int failures = 0;

#define CHECK(cond, msg)                                                      \
    do {                                                                      \
        if (!(cond)) {                                                        \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__); \
            failures++;                                                       \
        }                                                                     \
    } while (0)

static void expect_status(const char *what, ds_result_t r, int want)
{
    if (r.status != want) {
        fprintf(stderr, "FAIL: %s: status=%d (want %d) %s\n", what, r.status,
                want, r.detail ? r.detail : "");
        failures++;
    }
}

/* A length varint of 2^64 - 1: FF x9, 01. */
#define WRAP_LEN 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01
/* A walk-back body's tail. One byte back from the end of WRAP_LEN is its
   0x01, the key of a fixed64 field 0, which these eight bytes complete. */
#define SKIPPED 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08

int main(void)
{
    /* ---- FactRetract: a length-delimited field 4 (0x22). ---- */
    {
        static const uint8_t walk_back[] = { 0x22, WRAP_LEN, SKIPPED };
        static const uint8_t fits[] = { 0x08, 0x07, 0x22, 0x00 };
        ds_rfcs_fcrt_t fr;
        expect_status("ds_rfcs_decode_fcrt: a length that wraps, then eight "
                      "bytes, is refused",
                      ds_rfcs_decode_fcrt(walk_back, sizeof walk_back, &fr),
                      DS_ERR_PARSE);
        expect_status("ds_rfcs_decode_fcrt: an empty field 4 decodes",
                      ds_rfcs_decode_fcrt(fits, sizeof fits, &fr), DS_OK);
        CHECK(fr.fact_id == 7u, "ds_rfcs_decode_fcrt: the twin's fact_id");
    }

    /* ---- FactAssert: `schema_name` (field 2, 0x12) of length
       2^64 - 1. ---- */
    {
        static const uint8_t walk_back[] = { 0x12, WRAP_LEN, SKIPPED };
        static const uint8_t ends[] = { 0x12, WRAP_LEN };
        static const uint8_t fits[] = { 0x12, 0x01, 'S' };
        ds_rfcs_fcem_t fc;
        expect_status("ds_rfcs_decode_fcem: a length that wraps, then eight "
                      "bytes, is refused",
                      ds_rfcs_decode_fcem(walk_back, sizeof walk_back, &fc),
                      DS_ERR_PARSE);
        expect_status("ds_rfcs_decode_fcem: a length that wraps is refused",
                      ds_rfcs_decode_fcem(ends, sizeof ends, &fc),
                      DS_ERR_PARSE);
        expect_status("ds_rfcs_decode_fcem: a one-byte schema_name decodes",
                      ds_rfcs_decode_fcem(fits, sizeof fits, &fc), DS_OK);
        CHECK(fc.schema_name.len == 1u && fc.schema_name.ptr[0] == 'S',
              "ds_rfcs_decode_fcem: the twin's schema_name");
    }

    /* ---- FactEmit: `fact` (field 3, 0x1A) of length 2^64 - 1. ---- */
    {
        static const uint8_t wrap[] = { 0x1A, WRAP_LEN };
        ds_rfcs_fcem_t fe;
        memset(&fe, 0xA5, sizeof fe);
        expect_status("ds_rfcs_decode_femt: a length that wraps is refused",
                      ds_rfcs_decode_femt(wrap, sizeof wrap, &fe),
                      DS_ERR_PARSE);
        CHECK(fe.fact == NULL && fe.fact_len == 0u,
              "ds_rfcs_decode_femt: no fact view after the refusal");
    }

    /* ---- A fact body: a Bytes slot (field 2, 0x12) and a String slot
       (field 1, 0x0A), each of length 2^64 - 1. ---- */
    {
        ds_engine_config_t cfg = {0};
        ds_engine_t *e = NULL;
        expect_status("engine_new", ds_engine_new(&cfg, &e), DS_OK);
        if (e == NULL)
            return 1;
        static const ds_slot_desc_t bslots[2] = {
            { .name = "k", .type = DS_SLOT_TYPE_INT,
              .identity_role = DS_IDENTITY_KEY },
            { .name = "b", .type = DS_SLOT_TYPE_BYTES,
              .identity_role = DS_IDENTITY_MUTABLE },
        };
        const ds_schema_t *bsc = NULL;
        expect_status("register_schema B",
                      ds_engine_register_schema(e, "B",
                          DS_SCHEMA_LIFECYCLE_LOGICAL, 0, bslots, 2, &bsc),
                      DS_OK);
        if (bsc != NULL) {
            static const uint8_t walk_back[] = { 0x12, WRAP_LEN, SKIPPED };
            static const uint8_t fits[] = { 0x08, 0x05, 0x12, 0x02, 0xAB, 0xCD };
            ds_slot_value_t v[2];
            char scratch[32];
            uint32_t n = 0;
            expect_status("ds_rfcs_decode_fact_body: a Bytes length that "
                          "wraps, then eight bytes, is refused",
                          ds_rfcs_decode_fact_body(bsc, walk_back,
                              sizeof walk_back, v, 2, scratch, sizeof scratch,
                              &n),
                          DS_ERR_PARSE);
            expect_status("ds_rfcs_decode_fact_body: a two-byte Bytes decodes",
                          ds_rfcs_decode_fact_body(bsc, fits, sizeof fits, v, 2,
                              scratch, sizeof scratch, &n),
                          DS_OK);
            CHECK(n == 2u && v[1].kind == DS_SLOT_BYTES
                      && v[1].v.bytes.len == 2u
                      && v[1].v.bytes.data[0] == 0xAB,
                  "ds_rfcs_decode_fact_body: the twin's Bytes");
        }
        static const ds_slot_desc_t slots[1] = {
            { .name = "s", .type = DS_SLOT_TYPE_STRING,
              .identity_role = DS_IDENTITY_KEY },
        };
        const ds_schema_t *sc = NULL;
        expect_status("register_schema",
                      ds_engine_register_schema(e, "W",
                          DS_SCHEMA_LIFECYCLE_LOGICAL, 0, slots, 1, &sc),
                      DS_OK);
        if (sc != NULL) {
            static const uint8_t wrap[] = { 0x0A, WRAP_LEN };
            static const uint8_t fits[] = { 0x0A, 0x02, 'h', 'i' };
            ds_slot_value_t v[1];
            char scratch[32];
            uint32_t n = 0;
            expect_status("ds_rfcs_decode_fact_body: a length that wraps is "
                          "refused",
                          ds_rfcs_decode_fact_body(sc, wrap, sizeof wrap, v, 1,
                              scratch, sizeof scratch, &n),
                          DS_ERR_PARSE);
            expect_status("ds_rfcs_decode_fact_body: a two-byte String decodes",
                          ds_rfcs_decode_fact_body(sc, fits, sizeof fits, v, 1,
                              scratch, sizeof scratch, &n),
                          DS_OK);
            CHECK(n == 1u && v[0].kind == DS_SLOT_STRING
                      && strcmp(v[0].v.s, "hi") == 0,
                  "ds_rfcs_decode_fact_body: the twin's String");
        }
        ds_engine_free(e);
    }

    /* ---- FactRetract: field 4 (0x22) of length 2^64 - 11, which wraps
       `pos + len` to the body's start. A decoder that wraps loops on it, so
       it runs only when nothing above has failed. ---- */
    if (failures == 0) {
        static const uint8_t wrap[] = { 0x22, 0xF5, 0xFF, 0xFF, 0xFF, 0xFF,
                                        0xFF, 0xFF, 0xFF, 0xFF, 0x01 };
        ds_rfcs_fcrt_t fr;
        expect_status("ds_rfcs_decode_fcrt: a length wrapping to 0 is refused",
                      ds_rfcs_decode_fcrt(wrap, sizeof wrap, &fr),
                      DS_ERR_PARSE);
    }

    if (failures) {
        fprintf(stderr, "test_rfcs_len_wrap: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_rfcs_len_wrap: OK\n");
    return 0;
}
