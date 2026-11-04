/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The schema registry (IRET.5, IRET.22.1):
 *   - Registration and lookup by id and by name
 *   - Slot descriptor intern and indexing
 *   - Duplicate name rejection (DS_ERR_STATE)
 *   - Multiple schemas, correct id assignment
 *   - Scope and TTL fields preserved
 *   - A zero-slot schema, NULL arguments, and the activation and ambient
 *     scopes
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "libds.h"
#include "rete/engine.h"
#include "rete/schema.h"
#include "rete/schema_reg.h"

static int fail(const char *msg)
{
    fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

static int expect_ok(const char *what, ds_result_t r)
{
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: %s: status=%d (%s)\n",
                what, r.status, r.detail ? r.detail : "(null)");
        return 1;
    }
    return 0;
}

static int expect_status(const char *what, ds_result_t r, int want)
{
    if (r.status != want) {
        fprintf(stderr, "FAIL: %s: want status %d, got %d (%s)\n",
                what, want, r.status, r.detail ? r.detail : "(null)");
        return 1;
    }
    return 0;
}

static int test_register_and_lookup_by_id(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);

    ds_rete_slot_desc_t slots[] = {
        { .name = "entity_id", .type = DS_RETE_VAL_STR,   .is_key = true },
        { .name = "state",     .type = DS_RETE_VAL_FLOAT,  .tolerance   = 0.01 },
    };
    ds_rete_schema_t *s = NULL;
    if (expect_ok("register Sensor",
                  ds_rete_schema_register(e, "Sensor",
                                          DS_RETE_SCOPE_PLAIN, 0,
                                          slots, 2, &s))) return 1;
    if (!s) return fail("register: out pointer is NULL");
    if (s->id != 0)
        return fail("first schema must have id 0");
    if (s->slot_count != 2)
        return fail("slot_count wrong");

    /* by_id lookup */
    const ds_rete_schema_t *found = ds_rete_schema_by_id(e, 0);
    if (!found) return fail("by_id(0) returned NULL");
    if (found != s) return fail("by_id(0) wrong pointer");

    /* out-of-range */
    if (ds_rete_schema_by_id(e, 1) != NULL)
        return fail("by_id(1) should be NULL for single schema");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_lookup_by_name(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);

    ds_rete_schema_register(e, "Motion", DS_RETE_SCOPE_PLAIN, 0, NULL, 0, NULL);

    const ds_rete_schema_t *found = ds_rete_schema_by_name(e, "Motion");
    if (!found) return fail("by_name('Motion') returned NULL");
    if (strcmp(found->name, "Motion") != 0)
        return fail("by_name: wrong name on returned schema");

    if (ds_rete_schema_by_name(e, "Missing") != NULL)
        return fail("by_name('Missing') should return NULL");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_slot_names_interned(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);

    ds_rete_slot_desc_t slots[] = {
        { .name = "entity_id", .type = DS_RETE_VAL_STR },
        { .name = "value",     .type = DS_RETE_VAL_INT  },
    };
    ds_rete_schema_t *s = NULL;
    ds_rete_schema_register(e, "Counter", DS_RETE_SCOPE_PLAIN, 0,
                             slots, 2, &s);

    /* Slot names must be interned pointers (stable across two lookups). */
    const char *n1 = s->slots[0].name;
    const char *n2;
    ds_rete_intern_cstr(e->intern, "entity_id", &n2);
    if (n1 != n2) return fail("slot name not interned");

    /* Slot indices must be canonical (0, 1). */
    if (s->slots[0].index != 0) return fail("slot[0].index != 0");
    if (s->slots[1].index != 1) return fail("slot[1].index != 1");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_slot_fields_preserved(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);

    ds_rete_slot_desc_t slots[] = {
        { .name        = "temp",
          .type        = DS_RETE_VAL_FLOAT,
          .tolerance   = 0.5,
          .sampled     = true,
          .retained    = false,
          .is_key = false },
    };
    ds_rete_schema_t *s = NULL;
    ds_rete_schema_register(e, "Thermo", DS_RETE_SCOPE_TTL, 30000000000LL,
                             slots, 1, &s);

    if (s->scope != DS_RETE_SCOPE_TTL)
        return fail("scope not preserved");
    if (s->default_ttl_ns != 30000000000LL)
        return fail("default_ttl_ns not preserved");
    if (s->slots[0].type != DS_RETE_VAL_FLOAT)
        return fail("slot type not preserved");
    if (s->slots[0].tolerance != 0.5)
        return fail("tolerance not preserved");
    if (!s->slots[0].sampled)
        return fail("sampled flag not preserved");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_duplicate_rejected(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);

    ds_rete_schema_register(e, "Door", DS_RETE_SCOPE_PLAIN, 0, NULL, 0, NULL);
    if (expect_status("duplicate register",
                      ds_rete_schema_register(e, "Door",
                                              DS_RETE_SCOPE_PLAIN, 0,
                                              NULL, 0, NULL),
                      DS_ERR_STATE)) return 1;

    /* Engine must be unmodified: still exactly 1 schema. */
    if (e->schema_count != 1)
        return fail("duplicate: schema_count changed after rejection");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_multiple_schemas(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);

    const char *names[] = { "Alpha", "Beta", "Gamma", "Delta" };
    ds_rete_schema_t *schemas[4];
    for (int i = 0; i < 4; i++) {
        if (expect_ok("register multi",
                      ds_rete_schema_register(e, names[i],
                                              DS_RETE_SCOPE_PLAIN, 0,
                                              NULL, 0, &schemas[i]))) return 1;
        if (schemas[i]->id != (uint16_t)i) {
            fprintf(stderr, "FAIL: schema %s: expected id %d got %d\n",
                    names[i], i, schemas[i]->id);
            return 1;
        }
    }

    /* Both lookup directions work for all schemas. */
    for (int i = 0; i < 4; i++) {
        if (ds_rete_schema_by_id(e, (uint16_t)i) != schemas[i])
            return fail("by_id wrong after multiple registrations");
        if (ds_rete_schema_by_name(e, names[i]) != schemas[i])
            return fail("by_name wrong after multiple registrations");
    }
    if (e->schema_count != 4) return fail("schema_count wrong");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_zero_slot_schema(void)
{
    /* $ClockTick is a zero-slot schema (IRET.19.5). */
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);

    ds_rete_schema_t *s = NULL;
    if (expect_ok("register zero-slot",
                  ds_rete_schema_register(e, "$ClockTick",
                                          DS_RETE_SCOPE_PLAIN, 0,
                                          NULL, 0, &s))) return 1;
    if (s->slot_count != 0)
        return fail("zero-slot schema has non-zero slot_count");
    if (s->slots != NULL)
        return fail("zero-slot schema has non-NULL slots pointer");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_null_rejection(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);

    if (expect_status("NULL engine",
                      ds_rete_schema_register(NULL, "X",
                                              DS_RETE_SCOPE_PLAIN, 0,
                                              NULL, 0, NULL),
                      DS_ERR_INVAL)) return 1;
    if (expect_status("NULL name",
                      ds_rete_schema_register(e, NULL,
                                              DS_RETE_SCOPE_PLAIN, 0,
                                              NULL, 0, NULL),
                      DS_ERR_INVAL)) return 1;

    ds_rete_slot_desc_t s = { .name = "x", .type = DS_RETE_VAL_INT };
    if (expect_status("non-zero count NULL slots",
                      ds_rete_schema_register(e, "Y",
                                              DS_RETE_SCOPE_PLAIN, 0,
                                              NULL, 1, NULL),
                      DS_ERR_INVAL)) return 1;
    (void)s;

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_activation_and_ambient_scopes(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);

    ds_rete_schema_t *sa = NULL, *sb = NULL;
    if (expect_ok("register activation-scope",
                  ds_rete_schema_register(e, "LockFact",
                                          DS_RETE_SCOPE_ACTIVATION, 0,
                                          NULL, 0, &sa))) return 1;
    if (expect_ok("register ambient-scope",
                  ds_rete_schema_register(e, "SharedState",
                                          DS_RETE_SCOPE_AMBIENT, 0,
                                          NULL, 0, &sb))) return 1;

    if (sa->scope != DS_RETE_SCOPE_ACTIVATION)
        return fail("activation scope not preserved");
    if (sb->scope != DS_RETE_SCOPE_AMBIENT)
        return fail("ambient scope not preserved");

    ds_rete_engine_destroy(e);
    return 0;
}

int main(void)
{
    int fail_count = 0;

#define RUN(t) do { \
    int _r = (t)(); \
    if (_r) { fprintf(stderr, "  FAIL: " #t "\n"); fail_count++; } \
    else    { printf("  pass: " #t "\n"); } \
} while (0)

    printf("=== test_rete_schema_reg ===\n");
    RUN(test_register_and_lookup_by_id);
    RUN(test_lookup_by_name);
    RUN(test_slot_names_interned);
    RUN(test_slot_fields_preserved);
    RUN(test_duplicate_rejected);
    RUN(test_multiple_schemas);
    RUN(test_zero_slot_schema);
    RUN(test_null_rejection);
    RUN(test_activation_and_ambient_scopes);
#undef RUN

    if (fail_count == 0) {
        printf("=== test_rete_schema_reg: ALL PASSED ===\n");
        return 0;
    }
    fprintf(stderr, "=== test_rete_schema_reg: %d FAILED ===\n", fail_count);
    return 1;
}
