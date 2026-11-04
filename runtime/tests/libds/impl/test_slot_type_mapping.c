/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * A slot's declared Rete type agrees with the value kind its assert path
 * produces, on each row below. The declaration is ds_rete_val_kind_for_slot_type
 * (rete/schema_reg.c, called by engine_rete_adapters.c and dsc/loader.c); the
 * value is wm_rete_bridge.c's slot_to_rete_val. slots_equal compares kinds
 * before values, and an unassigned slot is zero-filled from its declared
 * type (rete/engine.c).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "rete/engine.h"
#include "rete/schema_reg.h"
#include "rete/val.h"

struct row {
    const char         *schema_name;
    ds_slot_type_t      ds_type;
    ds_rete_val_kind_t  want_kind;
    const char         *why;
};

/* A ds_slot_type_t, with the kind slot_to_rete_val produces for it. */
static const struct row k_rows[] = {
    { "MapInt",    DS_SLOT_TYPE_INT,    DS_RETE_VAL_INT,      "ds_rete_val_int" },
    { "MapFloat",  DS_SLOT_TYPE_FLOAT,  DS_RETE_VAL_FLOAT,    "ds_rete_val_float" },
    { "MapBool",   DS_SLOT_TYPE_BOOL,   DS_RETE_VAL_BOOL,     "ds_rete_val_bool" },
    { "MapString", DS_SLOT_TYPE_STRING, DS_RETE_VAL_STR,      "ds_rete_val_str" },
    { "MapBytes",  DS_SLOT_TYPE_BYTES,  DS_RETE_VAL_BYTES,    "ds_rete_val_bytes" },
    { "MapJson",   DS_SLOT_TYPE_JSON,   DS_RETE_VAL_JSON,     "json clone" },
    { "MapSchema", DS_SLOT_TYPE_SCHEMA, DS_RETE_VAL_FACT_REF, "fact_ref borrow" },
};

static int check_row(const struct row *r)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *engine = NULL;
    if (ds_engine_new(&cfg, &engine).status != DS_OK) {
        fprintf(stderr, "FAIL: %s: engine_new\n", r->schema_name);
        return 1;
    }

    /* A SCHEMA-typed slot must carry schema_ref, so give it something to
       point at. Registered first and on the same engine; its own slot is an
       Int so this helper does not recurse. */
    const ds_schema_t *referent = NULL;
    if (r->ds_type == DS_SLOT_TYPE_SCHEMA) {
        ds_slot_desc_t ref_sd = { .name = "n", .type = DS_SLOT_TYPE_INT,
                                  .identity_role = DS_IDENTITY_MUTABLE };
        if (ds_engine_register_schema(
                engine, "MapReferent", DS_SCHEMA_LIFECYCLE_TTL,
                3600000000000ull, &ref_sd, 1, &referent).status != DS_OK) {
            fprintf(stderr, "FAIL: %s: referent schema reg\n", r->schema_name);
            ds_engine_free(engine);
            return 1;
        }
    }

    /* A TTL schema, so the single slot needs no identity key ([LFAC.1.7]). */
    const ds_schema_t *ds_schema = NULL;
    ds_slot_desc_t sd = { .name = "v", .type = r->ds_type,
                          .schema_ref = referent,
                          .identity_role = DS_IDENTITY_MUTABLE };
    ds_result_t rr = ds_engine_register_schema(
        engine, r->schema_name, DS_SCHEMA_LIFECYCLE_TTL,
        3600000000000ull, &sd, 1, &ds_schema);
    if (rr.status != DS_OK) {
        fprintf(stderr, "FAIL: %s: register_schema status=%d\n",
                r->schema_name, rr.status);
        ds_engine_free(engine);
        return 1;
    }

    const ds_rete_schema_t *rs =
        ds_rete_schema_by_name(engine->rete_engine, r->schema_name);
    if (rs == NULL || rs->slot_count != 1) {
        fprintf(stderr, "FAIL: %s: rete schema missing or wrong arity\n",
                r->schema_name);
        ds_engine_free(engine);
        return 1;
    }

    int bad = 0;
    if (rs->slots[0].type != r->want_kind) {
        fprintf(stderr,
                "FAIL: %s: declared rete type is %d, but the assert path "
                "produces %d (%s). A slot the network types one way and "
                "populates another compares unequal in slots_equal, which "
                "tests kind before value.\n",
                r->schema_name, (int)rs->slots[0].type,
                (int)r->want_kind, r->why);
        bad = 1;
    }
    ds_engine_free(engine);
    return bad;
}

/* An unassigned slot is zero-filled from its declared type (rete/engine.c),
   so the emit path's empty Bytes is BYTES-kinded, as the assert path's is. */
static int test_declared_type_drives_the_unassigned_zero(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *engine = NULL;
    if (ds_engine_new(&cfg, &engine).status != DS_OK) return 1;

    const ds_schema_t *ds_schema = NULL;
    ds_slot_desc_t sd = { .name = "payload", .type = DS_SLOT_TYPE_BYTES,
                          .identity_role = DS_IDENTITY_MUTABLE };
    if (ds_engine_register_schema(engine, "Blob", DS_SCHEMA_LIFECYCLE_TTL,
                                  3600000000000ull, &sd, 1,
                                  &ds_schema).status != DS_OK) {
        ds_engine_free(engine);
        return 1;
    }
    const ds_rete_schema_t *rs =
        ds_rete_schema_by_name(engine->rete_engine, "Blob");
    if (rs == NULL) { ds_engine_free(engine); return 1; }

    /* rete/engine.c reads this to choose an empty Str or an empty Bytes. */
    int bad = 0;
    if (rs->slots[0].type != DS_RETE_VAL_BYTES) {
        fprintf(stderr,
                "FAIL: an omitted Bytes slot zero-fills from the declared "
                "type; declared %d so the empty is STR-kinded, while an "
                "asserted empty Bytes is BYTES-kinded\n",
                (int)rs->slots[0].type);
        bad = 1;
    }
    ds_engine_free(engine);
    return bad;
}

/* The shared mapping itself, which both registration paths call. check_row
   drives ds_engine_register_schema; the DSC loader's path is the conformance
   corpus's, which loads .dsc artefacts. */
static int test_the_shared_mapping_itself(void)
{
    int bad = 0;
    for (size_t i = 0; i < sizeof(k_rows) / sizeof(k_rows[0]); i++) {
        ds_rete_val_kind_t got =
            ds_rete_val_kind_for_slot_type(k_rows[i].ds_type);
        if (got != k_rows[i].want_kind) {
            fprintf(stderr,
                    "FAIL: ds_rete_val_kind_for_slot_type(%d) = %d, want %d "
                    "(%s)\n",
                    (int)k_rows[i].ds_type, (int)got,
                    (int)k_rows[i].want_kind, k_rows[i].why);
            bad = 1;
        }
    }
    return bad;
}

int main(void)
{
    int fail_count = 0;
    printf("=== test_slot_type_mapping ===\n");

    if (test_the_shared_mapping_itself()) {
        fprintf(stderr, "  FAIL: test_the_shared_mapping_itself\n");
        fail_count++;
    }

    for (size_t i = 0; i < sizeof(k_rows) / sizeof(k_rows[0]); i++) {
        if (check_row(&k_rows[i])) fail_count++;
    }

    if (test_declared_type_drives_the_unassigned_zero()) {
        fprintf(stderr, "  FAIL: test_declared_type_drives_the_unassigned_zero\n");
        fail_count++;
    }

    if (fail_count == 0) {
        printf("=== test_slot_type_mapping: ALL PASSED ===\n");
        return 0;
    }
    fprintf(stderr, "=== test_slot_type_mapping: %d FAILED ===\n", fail_count);
    return 1;
}
