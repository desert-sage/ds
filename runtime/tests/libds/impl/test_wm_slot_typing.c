/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * [RARC.5.2.6]: no fact enters working memory with a slot value whose kind
 * differs from its declared slot type, by any path, and there is no implicit
 * conversion. The check is in ds_rete_wm_assert_ex, where every path to
 * working memory converges. It is driven at the Rete layer: the compiler
 * refuses a mistyped emit, and this guards the paths that do not go through
 * the compiler (integrator-registered schemas, adapters, hand-built
 * networks).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "rete/engine.h"
#include "rete/schema_reg.h"
#include "rete/val.h"
#include "rete/wm_rete.h"

/* An engine with one TTL schema of a single slot, which so needs no identity
   key ([LFAC.1.7]). */
static int make_engine(ds_engine_t **out_engine,
                       const ds_rete_schema_t **out_rs,
                       ds_slot_type_t slot_type,
                       bool nullable)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *engine = NULL;
    if (ds_engine_new(&cfg, &engine).status != DS_OK) return 1;

    const ds_schema_t *ds_schema = NULL;
    ds_slot_desc_t sd = { .name = "v", .type = slot_type,
                          .nullable = nullable,
                          .identity_role = DS_IDENTITY_MUTABLE };
    if (ds_engine_register_schema(engine, "T", DS_SCHEMA_LIFECYCLE_TTL,
                                  3600000000000ull, &sd, 1,
                                  &ds_schema).status != DS_OK) {
        ds_engine_free(engine);
        return 1;
    }
    const ds_rete_schema_t *rs =
        ds_rete_schema_by_name(engine->rete_engine, "T");
    if (rs == NULL) { ds_engine_free(engine); return 1; }
    *out_engine = engine;
    *out_rs = rs;
    return 0;
}

static int expect_assert(const char     *what,
                         ds_slot_type_t  slot_type,
                         bool            nullable,
                         ds_rete_val_t   value,
                         int             want_status)
{
    ds_engine_t *engine = NULL;
    const ds_rete_schema_t *rs = NULL;
    if (make_engine(&engine, &rs, slot_type, nullable)) {
        fprintf(stderr, "FAIL: %s: engine setup\n", what);
        return 1;
    }
    ds_rete_fact_t *fact = NULL;
    ds_result_t r = ds_rete_wm_assert_ex(engine->rete_engine, rs->id,
                                         &value, &fact, NULL);
    int bad = 0;
    if (r.status != want_status) {
        fprintf(stderr, "FAIL: %s: status=%d, want %d\n",
                what, r.status, want_status);
        bad = 1;
    }
    ds_engine_free(engine);
    return bad;
}

static int test_float_into_int_slot_is_refused(void)
{
    return expect_assert("Float into Int slot", DS_SLOT_TYPE_INT, false,
                         ds_rete_val_float(3.5),
                         DS_ERR_SLOT_TYPE_MISMATCH);
}

static int test_str_into_int_slot_is_refused(void)
{
    return expect_assert("Str into Int slot", DS_SLOT_TYPE_INT, false,
                         ds_rete_val_str("nope", 4),
                         DS_ERR_SLOT_TYPE_MISMATCH);
}

static int test_int_into_bool_slot_is_refused(void)
{
    return expect_assert("Int into Bool slot", DS_SLOT_TYPE_BOOL, false,
                         ds_rete_val_int(1),
                         DS_ERR_SLOT_TYPE_MISMATCH);
}

static int test_matching_kinds_are_admitted(void)
{
    int bad = 0;
    bad |= expect_assert("Int into Int", DS_SLOT_TYPE_INT, false,
                         ds_rete_val_int(7), DS_OK);
    bad |= expect_assert("Float into Float", DS_SLOT_TYPE_FLOAT, false,
                         ds_rete_val_float(1.5), DS_OK);
    bad |= expect_assert("Bool into Bool", DS_SLOT_TYPE_BOOL, false,
                         ds_rete_val_bool(true), DS_OK);
    return bad;
}

/* [RARC.5.2.6] "There is no implicit conversion": an Int into a Float slot is
   refused, and so is a String into a Bytes slot. */
static int test_int_into_float_slot_is_refused(void)
{
    return expect_assert("Int into Float slot", DS_SLOT_TYPE_FLOAT, false,
                         ds_rete_val_int(3), DS_ERR_SLOT_TYPE_MISMATCH);
}

static int test_str_into_bytes_slot_is_refused(void)
{
    return expect_assert("Str into Bytes slot", DS_SLOT_TYPE_BYTES, false,
                         ds_rete_val_str("aab", 3), DS_ERR_SLOT_TYPE_MISMATCH);
}

/* [LNUL.3.1] — the canonical null is admitted only where the schema said so. */
static int test_null_respects_nullable(void)
{
    int bad = 0;
    bad |= expect_assert("null into non-nullable Int",
                         DS_SLOT_TYPE_INT, false,
                         ds_rete_val_null(), DS_ERR_SLOT_TYPE_MISMATCH);
    bad |= expect_assert("null into nullable Int",
                         DS_SLOT_TYPE_INT, true,
                         ds_rete_val_null(), DS_OK);
    return bad;
}

int main(void)
{
    int fail_count = 0;
    printf("=== test_wm_slot_typing ===\n");

    struct { const char *name; int (*fn)(void); } cases[] = {
        { "float_into_int_slot_is_refused",  test_float_into_int_slot_is_refused },
        { "str_into_int_slot_is_refused",    test_str_into_int_slot_is_refused },
        { "int_into_bool_slot_is_refused",   test_int_into_bool_slot_is_refused },
        { "matching_kinds_are_admitted",     test_matching_kinds_are_admitted },
        { "int_into_float_slot_is_refused",  test_int_into_float_slot_is_refused },
        { "str_into_bytes_slot_is_refused",  test_str_into_bytes_slot_is_refused },
        { "null_respects_nullable",          test_null_respects_nullable },
    };

    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        if (cases[i].fn()) {
            fprintf(stderr, "  FAIL: %s\n", cases[i].name);
            fail_count++;
        }
    }

    if (fail_count == 0) {
        printf("=== test_wm_slot_typing: ALL PASSED ===\n");
        return 0;
    }
    fprintf(stderr, "=== test_wm_slot_typing: %d FAILED ===\n", fail_count);
    return 1;
}
