/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * [RFCS.6.3]: a non-nullable Json slot has no zero, so a body with its field
 * absent is DS_ERR_PARSE.
 *
 * A file of its own, not test_rfcs_fact.c: that binary is outside the leak lanes,
 * and the case that fails after an earlier Json field parsed is a leak if the
 * failure path misses that tree. Bodies are hand-built, as no conforming writer
 * omits the field.
 *
 * PATH PINNED: rfcs/codec.c's decode_body, its last loop, through
 * ds_rfcs_decode_fact_body.
 */
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

static const ds_slot_desc_t REQUIRED[2] = {
    { .name = "id", .type = DS_SLOT_TYPE_INT,  .identity_role = DS_IDENTITY_KEY },
    { .name = "j",  .type = DS_SLOT_TYPE_JSON, .identity_role = DS_IDENTITY_MUTABLE },
};
static const ds_slot_desc_t NULLABLE[2] = {
    { .name = "id", .type = DS_SLOT_TYPE_INT,  .identity_role = DS_IDENTITY_KEY },
    { .name = "j",  .type = DS_SLOT_TYPE_JSON, .identity_role = DS_IDENTITY_MUTABLE,
      .nullable = true },
};
static const ds_slot_desc_t TWO[3] = {
    { .name = "id", .type = DS_SLOT_TYPE_INT,  .identity_role = DS_IDENTITY_KEY },
    { .name = "a",  .type = DS_SLOT_TYPE_JSON, .identity_role = DS_IDENTITY_MUTABLE },
    { .name = "b",  .type = DS_SLOT_TYPE_JSON, .identity_role = DS_IDENTITY_MUTABLE },
};

/* @spec [RFCS.6.3] */
static void test_rfcs_6_3__an_absent_json_field_is_malformed(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *req = NULL, *nul = NULL, *two = NULL;
    CHECK(ds_engine_new(NULL, &e).status == DS_OK, "engine_new");
    if (e == NULL) return;
    CHECK(ds_engine_register_schema(e, "Req", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                    REQUIRED, 2, &req).status == DS_OK
              && ds_engine_register_schema(e, "Nul", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                           NULLABLE, 2, &nul).status == DS_OK
              && ds_engine_register_schema(e, "Two", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                           TWO, 3, &two).status == DS_OK,
          "register the schemas");

    ds_slot_value_t v[3];
    char scratch[32];
    uint32_t n = 0;

    static const uint8_t absent[] = { 0x08, 0x01 };  /* f1 Int 1, and no f2 */
    CHECK(ds_rfcs_decode_fact_body(req, absent, sizeof absent, v, 3, scratch,
                                   sizeof scratch, &n).status == DS_ERR_PARSE,
          "a non-nullable Json slot's absent field is a malformed body");

    /* The control: the same body. */
    CHECK(ds_rfcs_decode_fact_body(nul, absent, sizeof absent, v, 3, scratch,
                                   sizeof scratch, &n).status == DS_OK
              && n == 2 && v[1].kind == DS_SLOT_NULL,
          "a nullable slot's absent field is null");

    static const uint8_t empty[] = { 0x08, 0x01, 0x12, 0x00 };  /* f2 "" */
    CHECK(ds_rfcs_decode_fact_body(req, empty, sizeof empty, v, 3, scratch,
                                   sizeof scratch, &n).status == DS_ERR_PARSE,
          "a present empty field is refused by the parser");

    /* The asan and memcheck-leak lanes judge what becomes of `a`'s tree. */
    static const uint8_t first_only[] = { 0x08, 0x01, 0x12, 0x01, '1' };
    CHECK(ds_rfcs_decode_fact_body(two, first_only, sizeof first_only, v, 3,
                                   scratch, sizeof scratch, &n).status
              == DS_ERR_PARSE,
          "a body that fails on this slot after an earlier Json field parsed");

    /* A Json field of another wire type never parsed, so it holds no tree. */
    static const uint8_t varint[] = { 0x08, 0x01, 0x10, 0x01 };
    CHECK(ds_rfcs_decode_fact_body(req, varint, sizeof varint, v, 3, scratch,
                                   sizeof scratch, &n).status == DS_ERR_PARSE,
          "a Json field that is a varint is a malformed body");

    ds_engine_free(e);
}

/* @spec [RFCS.6.3]
   A Json field whose document is `null` at its root is the canonical null.
   No conforming writer writes one, so the bodies are hand-built. The leak lanes
   judge that the nullable slot's tree is freed, and `a`'s in the body that fails.
   THE PATH: decode_body's last loop. */
static void test_rfcs_6_3__a_root_null_json_field(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *req = NULL, *nul = NULL, *two = NULL;
    CHECK(ds_engine_new(NULL, &e).status == DS_OK, "engine_new");
    if (e == NULL) return;
    CHECK(ds_engine_register_schema(e, "Req", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                    REQUIRED, 2, &req).status == DS_OK
              && ds_engine_register_schema(e, "Nul", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                           NULLABLE, 2, &nul).status == DS_OK
              && ds_engine_register_schema(e, "Two", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                           TWO, 3, &two).status == DS_OK,
          "register the schemas");

    ds_slot_value_t v[3];
    char scratch[32];
    uint32_t n = 0;

    static const uint8_t root_null[] = {
        0x08, 0x01, 0x12, 0x04, 'n', 'u', 'l', 'l'
    };
    CHECK(ds_rfcs_decode_fact_body(req, root_null, sizeof root_null, v, 3, scratch,
                                   sizeof scratch, &n).status == DS_ERR_PARSE,
          "a root-null document in a non-nullable slot is a malformed body");

    CHECK(ds_rfcs_decode_fact_body(nul, root_null, sizeof root_null, v, 3, scratch,
                                   sizeof scratch, &n).status == DS_OK
              && n == 2 && v[1].kind == DS_SLOT_NULL,
          "and in a nullable slot it is null");

    static const uint8_t second_null[] = {
        0x08, 0x01, 0x12, 0x01, '1', 0x1A, 0x04, 'n', 'u', 'l', 'l'
    };
    CHECK(ds_rfcs_decode_fact_body(two, second_null, sizeof second_null, v, 3,
                                   scratch, sizeof scratch, &n).status
              == DS_ERR_PARSE,
          "a body that fails on this slot after an earlier Json field parsed");

    /* The control: [LNUL.3.4]'s second paragraph. A null inside a document is no
       null at its root. */
    static const uint8_t holds_null[] = {
        0x08, 0x01, 0x12, 0x0A, '{', '"', 'a', '"', ':', 'n', 'u', 'l', 'l', '}'
    };
    CHECK(ds_rfcs_decode_fact_body(req, holds_null, sizeof holds_null, v, 3, scratch,
                                   sizeof scratch, &n).status == DS_OK
              && v[1].kind == DS_SLOT_JSON,
          "a document holding a null decodes as a document");
    if (v[1].kind == DS_SLOT_JSON) {
        ds_json_kind_t root = DS_JSON_NULL;
        CHECK(ds_json_get_kind(v[1].v.json, &root).status == DS_OK
                  && root == DS_JSON_OBJECT,
              "whose root is the object");
        ds_json_free(v[1].v.json);
    }

    ds_engine_free(e);
}

int main(void)
{
    test_rfcs_6_3__an_absent_json_field_is_malformed();
    test_rfcs_6_3__a_root_null_json_field();
    if (failures) {
        fprintf(stderr, "test_rfcs_6_3_absent_json: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_rfcs_6_3_absent_json: OK\n");
    return 0;
}
