/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * White-box unit test of the schema module. Host registration is not in
 * libds.h ([NFCT.1.1]); engine.h declares it for libds's own tests.
 */
#include <stdio.h>
#include <stdlib.h>

#include "libds.h"

#include "engine.h"
#include "schema.h"

static int fail(const char *msg, ds_result_t r)
{
    fprintf(stderr, "FAIL: %s: status=%d detail=%s\n",
            msg, r.status, r.detail ? r.detail : "(null)");
    return 1;
}

static int expect_ok(const char *what, ds_result_t r)
{
    if (r.status != DS_OK) return fail(what, r);
    return 0;
}

static int expect_status(const char *what, ds_result_t r, ds_status_t want)
{
    if (r.status != want) {
        fprintf(stderr, "FAIL: %s: want status %d, got %d (%s)\n",
                what, want, r.status, r.detail ? r.detail : "(null)");
        return 1;
    }
    return 0;
}

int main(void)
{
    ds_engine_t *e = NULL;
    ds_result_t r;

    r = ds_engine_new(NULL, &e);
    if (expect_ok("ds_engine_new", r)) return 1;

    /* Fresh engine: zero schemas registered. */
    size_t n = (size_t) -1;
    r = ds_engine_schema_count(e, &n);
    if (expect_ok("schema_count #1", r)) return 1;
    if (n != 0) {
        fprintf(stderr, "FAIL: fresh engine has %zu schemas, want 0\n", n);
        return 1;
    }

    /* Find on empty registry returns NULL + DS_OK. */
    const ds_schema_t *found = (void *) 0xDEADBEEF;
    r = ds_engine_schema_find(e, "Nope", &found);
    if (expect_ok("schema_find miss", r)) return 1;
    if (found != NULL) {
        fprintf(stderr, "FAIL: find miss set *out to %p, want NULL\n",
                (void *) found);
        return 1;
    }

    /* Build a real schema: `schema logical Motion` with three slots. Each
       names its role, as a logical schema's must ([LFAC.1.7]), and the
       tolerance sits on a MUTABLE one ([NFCT.4.4.3]). */
    const ds_slot_desc_t motion_slots[] = {
        { .name = "entity_id", .type = DS_SLOT_TYPE_STRING,
          .identity_role = DS_IDENTITY_KEY },
        { .name = "intensity", .type = DS_SLOT_TYPE_FLOAT,
          .has_tolerance = true, .tolerance = 0.05,
          .identity_role = DS_IDENTITY_MUTABLE },
        { .name = "ts",        .type = DS_SLOT_TYPE_FLOAT,
          .identity_role = DS_IDENTITY_MUTABLE },
    };
    ds_schema_t *motion = NULL;
    r = ds_schema_new("Motion", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                      motion_slots, 3, &motion);
    if (expect_ok("schema_new Motion", r)) return 1;
    if (motion == NULL) {
        fprintf(stderr, "FAIL: schema_new OK but out is NULL\n");
        return 1;
    }
    if (motion->n_slots != 3) {
        fprintf(stderr, "FAIL: motion->n_slots = %u, want 3\n",
                motion->n_slots);
        return 1;
    }
    /* Slot descriptors copied; array is independent of caller's. */
    if (motion->slots == motion_slots) {
        fprintf(stderr, "FAIL: schema->slots aliases caller array\n");
        return 1;
    }
    /* But slot-name pointers are shared (strings borrowed). */
    if (motion->slots[0].name != motion_slots[0].name) {
        fprintf(stderr, "FAIL: slot name pointer was copied; should be borrowed\n");
        return 1;
    }

    /* Register. */
    r = ds_schema_registry_add(&e->schemas, motion);
    if (expect_ok("registry_add Motion", r)) return 1;

    /* Count reflects addition. */
    r = ds_engine_schema_count(e, &n);
    if (expect_ok("schema_count after add", r)) return 1;
    if (n != 1) {
        fprintf(stderr, "FAIL: after add count = %zu, want 1\n", n);
        return 1;
    }

    /* Find by name returns the registered schema. */
    found = NULL;
    r = ds_engine_schema_find(e, "Motion", &found);
    if (expect_ok("schema_find Motion", r)) return 1;
    if (found != motion) {
        fprintf(stderr, "FAIL: find returned %p, want %p\n",
                (void *) found, (void *) motion);
        return 1;
    }

    /* Duplicate registration rejected; caller retains ownership. */
    ds_schema_t *motion_dup = NULL;
    r = ds_schema_new("Motion", DS_SCHEMA_LIFECYCLE_TTL, 60000000000ULL /* 60s */,
                      NULL, 0, &motion_dup);
    if (expect_ok("schema_new Motion dup", r)) return 1;
    r = ds_schema_registry_add(&e->schemas, motion_dup);
    if (expect_status("registry_add dup", r, DS_ERR_STATE)) return 1;
    /* Caller still owns motion_dup; must free. */
    r = ds_schema_free(motion_dup);
    if (expect_ok("schema_free motion_dup", r)) return 1;

    /* Validation paths. */

    /* tolerance on non-numeric slot. */
    const ds_slot_desc_t bad_tolerance_slot[] = {
        { .name = "s", .type = DS_SLOT_TYPE_STRING,
          .has_tolerance = true, .tolerance = 0.1 },
    };
    ds_schema_t *bad = NULL;
    r = ds_schema_new("Bad1", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                      bad_tolerance_slot, 1, &bad);
    if (expect_status("schema_new tol on string",
                      r, DS_ERR_INVAL)) return 1;
    if (bad != NULL) {
        fprintf(stderr, "FAIL: schema_new error path set *out to non-NULL\n");
        return 1;
    }

    /* tolerance on ttl schema. */
    const ds_slot_desc_t tol_on_ttl[] = {
        { .name = "x", .type = DS_SLOT_TYPE_FLOAT,
          .has_tolerance = true, .tolerance = 0.1 },
    };
    r = ds_schema_new("Bad2", DS_SCHEMA_LIFECYCLE_TTL, 1000000000ULL /* 1s */,
                      tol_on_ttl, 1, &bad);
    if (expect_status("schema_new tol on ttl",
                      r, DS_ERR_INVAL)) return 1;

    /* Negative tolerance. */
    const ds_slot_desc_t neg_tol[] = {
        { .name = "x", .type = DS_SLOT_TYPE_FLOAT,
          .has_tolerance = true, .tolerance = -1.0 },
    };
    r = ds_schema_new("Bad3", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                      neg_tol, 1, &bad);
    if (expect_status("schema_new negative tol",
                      r, DS_ERR_INVAL)) return 1;

    /* [NFCT.4.4.3]: a tolerance belongs to a MUTABLE slot alone. On a KEY
       slot, and on one that names no role, it is refused; the same slot as
       MUTABLE is admitted. */
    const ds_slot_desc_t key_tol[] = {
        { .name = "id", .type = DS_SLOT_TYPE_INT,
          .has_tolerance = true, .tolerance = 0.5,
          .identity_role = DS_IDENTITY_KEY },
    };
    r = ds_schema_new("KeyTol", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                      key_tol, 1, &bad);
    if (expect_status("schema_new tol on KEY (NFCT.4.4.3)",
                      r, DS_ERR_INVAL)) return 1;
    const ds_slot_desc_t unroled_tol[] = {
        { .name = "v", .type = DS_SLOT_TYPE_INT,
          .has_tolerance = true, .tolerance = 0.5 },
    };
    r = ds_schema_new("UnroledTol", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                      unroled_tol, 1, &bad);
    if (expect_status("schema_new tol on an unroled slot (NFCT.4.4.3)",
                      r, DS_ERR_INVAL)) return 1;
    const ds_slot_desc_t mutable_tol[] = {
        { .name = "id", .type = DS_SLOT_TYPE_INT,
          .has_tolerance = true, .tolerance = 0.5,
          .identity_role = DS_IDENTITY_MUTABLE },
    };
    ds_schema_t *ok_tol = NULL;
    r = ds_schema_new("MutTol", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                      mutable_tol, 1, &ok_tol);
    if (expect_ok("schema_new tol on MUTABLE (NFCT.4.4.3)", r)) return 1;
    r = ds_schema_free(ok_tol);
    if (expect_ok("schema_free MutTol", r)) return 1;

    /* Through ds_engine_register_schema too, a KEY slot's tolerance is
       refused and registers nothing. */
    const ds_slot_desc_t key_tol_reg[] = {
        { .name = "id", .type = DS_SLOT_TYPE_INT,
          .has_tolerance = true, .tolerance = 0.5,
          .identity_role = DS_IDENTITY_KEY },
    };
    const ds_schema_t *reg_out = (const ds_schema_t *) 0xDEAD;
    r = ds_engine_register_schema(e, "KeyTol", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                  key_tol_reg, 1, &reg_out);
    if (expect_status("register_schema tol on KEY (NFCT.4.4.3)",
                      r, DS_ERR_INVAL)) return 1;
    if (reg_out != NULL) {
        fprintf(stderr, "FAIL: a refused registration set *out_schema\n");
        return 1;
    }
    found = (const ds_schema_t *) 0xDEAD;
    r = ds_engine_schema_find(e, "KeyTol", &found);
    if (expect_ok("schema_find KeyTol", r)) return 1;
    if (found != NULL) {
        fprintf(stderr, "FAIL: a refused registration registered KeyTol\n");
        return 1;
    }

    /* Schema slot without schema_ref. */
    const ds_slot_desc_t schema_no_ref[] = {
        { .name = "inner", .type = DS_SLOT_TYPE_SCHEMA, .schema_ref = NULL },
    };
    r = ds_schema_new("Bad4", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                      schema_no_ref, 1, &bad);
    if (expect_status("schema_new SCHEMA slot NULL ref",
                      r, DS_ERR_INVAL)) return 1;

    /* Non-schema slot with schema_ref set. */
    const ds_slot_desc_t nonschema_with_ref[] = {
        { .name = "x", .type = DS_SLOT_TYPE_INT, .schema_ref = motion },
    };
    r = ds_schema_new("Bad5", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                      nonschema_with_ref, 1, &bad);
    if (expect_status("schema_new non-schema with ref",
                      r, DS_ERR_INVAL)) return 1;

    /* Unknown slot type. */
    const ds_slot_desc_t bad_type[] = {
        { .name = "x", .type = (ds_slot_type_t) 999 },
    };
    r = ds_schema_new("Bad6", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                      bad_type, 1, &bad);
    if (expect_status("schema_new bad slot type", r, DS_ERR_INVAL)) return 1;

    /* NULL slot name. */
    const ds_slot_desc_t null_name[] = {
        { .name = NULL, .type = DS_SLOT_TYPE_INT },
    };
    r = ds_schema_new("Bad7", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                      null_name, 1, &bad);
    if (expect_status("schema_new NULL slot name", r, DS_ERR_INVAL)) return 1;

    /* NULL type_name. */
    r = ds_schema_new(NULL, DS_SCHEMA_LIFECYCLE_LOGICAL, 0, NULL, 0, &bad);
    if (expect_status("schema_new NULL type_name", r, DS_ERR_INVAL)) return 1;

    /* TTL schema with ttl_ns=0 → DS_ERR_INVAL. */
    r = ds_schema_new("BadTtl1", DS_SCHEMA_LIFECYCLE_TTL, 0,
                      NULL, 0, &bad);
    if (expect_status("schema_new TTL with ttl_ns=0", r, DS_ERR_INVAL)) return 1;

    /* LOGICAL schema with ttl_ns>0 → DS_ERR_INVAL. */
    r = ds_schema_new("BadTtl2", DS_SCHEMA_LIFECYCLE_LOGICAL, 1000,
                      NULL, 0, &bad);
    if (expect_status("schema_new LOGICAL with ttl_ns>0", r, DS_ERR_INVAL)) return 1;

    /* NULL out. */
    r = ds_schema_new("Anything", DS_SCHEMA_LIFECYCLE_LOGICAL, 0, NULL, 0, NULL);
    if (expect_status("schema_new NULL out", r, DS_ERR_INVAL)) return 1;

    /* NULL type_name to find. */
    r = ds_engine_schema_find(e, NULL, &found);
    if (expect_status("schema_find NULL name", r, DS_ERR_INVAL)) return 1;

    /* NULL engine. */
    r = ds_engine_schema_count(NULL, &n);
    if (expect_status("schema_count NULL engine", r, DS_ERR_INVAL)) return 1;

    /* schema_free on NULL is safe. */
    r = ds_schema_free(NULL);
    if (expect_ok("schema_free NULL", r)) return 1;

    /* Clean teardown. Registry owns motion; destroy frees it. */
    r = ds_engine_free(e);
    if (expect_ok("ds_engine_free", r)) return 1;

    printf("test_schema_basic: OK\n");
    return 0;
}
