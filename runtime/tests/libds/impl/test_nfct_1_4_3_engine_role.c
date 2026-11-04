/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * DS_IDENTITY_ENGINE belongs to `ts` alone: ds_engine_register_schema's role
 * check in schema.c (nfct_1_4_3_engine_role). The entry point is internal
 * (engine.h) and [NFCT.1.4.3] is a tombstone, so the test links no clause.
 * The `.dsc` loader does not make this check; a `.dsc` is trusted input.
 *
 * Five refusals, each by the one check it names: ENGINE on `at` (name), on a
 * `ttl` schema's `ts` (lifecycle), on an Int `ts` (type), on a nullable `ts`
 * (nullable), and KEY on a logical schema's `ts` (the converse). Each is
 * DS_ERR_INVAL, which the register path's other refusals return too, so the
 * detail's `[NFCT.1.4.3]` says which check refused. The positive control
 * registers a logical schema whose non-nullable Time `ts` is ENGINE.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "engine.h"   /* ds_engine_register_schema, libds-internal */

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

#define SCHEMA_TTL_NS 1000000000ull

static ds_engine_t *new_engine(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    return e;
}

/* Register `name` and expect the NFCT.1.4.3 refusal: the code, a detail that
   names `slot` (backquoted, as the check writes it), and nothing registered. */
static void expect_refused(const char *what, const char *name,
                           ds_schema_lifecycle_t lifecycle, uint64_t ttl_ns,
                           const ds_slot_desc_t *slots, uint32_t n_slots,
                           const char *slot)
{
    ds_engine_t *e = new_engine();
    if (!e) return;

    const ds_schema_t *out = (const ds_schema_t *)(uintptr_t)1;
    ds_result_t r = ds_engine_register_schema(e, name, lifecycle, ttl_ns,
                                              slots, n_slots, &out);
    if (r.status != DS_ERR_INVAL) {
        fprintf(stderr, "FAIL: %s: want DS_ERR_INVAL (%d), "
                "got %d detail=%s\n", what, DS_ERR_INVAL,
                r.status, r.detail ? r.detail : "(null)");
        failures++;
    }
    CHECK(out == NULL, "a refused registration writes *out_schema NULL");

    char want[64];
    snprintf(want, sizeof want, "`%s`", slot);
    CHECK(r.detail != NULL && strstr(r.detail, want) != NULL,
          "the refusal's detail names the slot");
    CHECK(r.detail != NULL && strstr(r.detail, "[NFCT.1.4.3]") != NULL,
          "the refusal is the NFCT.1.4.3 check's");

    const ds_schema_t *found = (const ds_schema_t *)(uintptr_t)1;
    CHECK_OK(ds_engine_schema_find(e, name, &found), "schema_find");
    CHECK(found == NULL, "nothing of that name is registered");
    size_t n = 1;
    CHECK_OK(ds_engine_schema_count(e, &n), "schema_count");
    CHECK(n == 0, "no schema at all is registered");

    ds_engine_free(e);
}

/* ENGINE on a slot not named `ts`. */
static void test_engine_on_a_slot_named_at(void)
{
    static const ds_slot_desc_t slots[2] = {
        { .name = "id", .type = DS_SLOT_TYPE_INT,
          .identity_role = DS_IDENTITY_KEY },
        { .name = "at", .type = DS_SLOT_TYPE_TIME,
          .identity_role = DS_IDENTITY_ENGINE },
    };
    expect_refused("ENGINE on `at`", "Reading", DS_SCHEMA_LIFECYCLE_LOGICAL,
                   0, slots, 2, "at");
}

/* ENGINE on `ts` of a schema that is not `logical`. */
static void test_engine_on_ts_of_a_ttl_schema(void)
{
    static const ds_slot_desc_t slots[2] = {
        { .name = "level", .type = DS_SLOT_TYPE_INT,
          .identity_role = DS_IDENTITY_UNSPECIFIED },
        { .name = "ts", .type = DS_SLOT_TYPE_TIME,
          .identity_role = DS_IDENTITY_ENGINE },
    };
    expect_refused("ENGINE on `ts` of a ttl schema", "Reading",
                   DS_SCHEMA_LIFECYCLE_TTL, SCHEMA_TTL_NS, slots, 2, "ts");
}

/* ENGINE on a `ts` whose type is not Time. */
static void test_engine_on_an_int_ts(void)
{
    static const ds_slot_desc_t slots[2] = {
        { .name = "id", .type = DS_SLOT_TYPE_INT,
          .identity_role = DS_IDENTITY_KEY },
        { .name = "ts", .type = DS_SLOT_TYPE_INT,
          .identity_role = DS_IDENTITY_ENGINE },
    };
    expect_refused("ENGINE on an Int `ts`", "Reading",
                   DS_SCHEMA_LIFECYCLE_LOGICAL, 0, slots, 2, "ts");
}

/* ENGINE on a nullable Time `ts`. */
static void test_engine_on_a_nullable_ts(void)
{
    static const ds_slot_desc_t slots[2] = {
        { .name = "id", .type = DS_SLOT_TYPE_INT,
          .identity_role = DS_IDENTITY_KEY },
        { .name = "ts", .type = DS_SLOT_TYPE_TIME,
          .identity_role = DS_IDENTITY_ENGINE, .nullable = true },
    };
    expect_refused("ENGINE on a nullable `ts`", "Reading",
                   DS_SCHEMA_LIFECYCLE_LOGICAL, 0, slots, 2, "ts");
}

/* The converse: a logical schema's `ts` marked KEY. */
static void test_key_on_ts_of_a_logical_schema(void)
{
    static const ds_slot_desc_t slots[2] = {
        { .name = "id", .type = DS_SLOT_TYPE_INT,
          .identity_role = DS_IDENTITY_KEY },
        { .name = "ts", .type = DS_SLOT_TYPE_TIME,
          .identity_role = DS_IDENTITY_KEY },
    };
    expect_refused("KEY on `ts` of a logical schema", "Reading",
                   DS_SCHEMA_LIFECYCLE_LOGICAL, 0, slots, 2, "ts");
}

/* The positive control: the `ts` the compiler admits registers. */
static void test_engine_on_a_logical_time_ts_registers(void)
{
    static const ds_slot_desc_t slots[3] = {
        { .name = "id", .type = DS_SLOT_TYPE_INT,
          .identity_role = DS_IDENTITY_KEY },
        { .name = "level", .type = DS_SLOT_TYPE_INT,
          .identity_role = DS_IDENTITY_MUTABLE },
        { .name = "ts", .type = DS_SLOT_TYPE_TIME,
          .identity_role = DS_IDENTITY_ENGINE },
    };
    ds_engine_t *e = new_engine();
    if (!e) return;
    const ds_schema_t *out = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Reading",
                                       DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       slots, 3, &out),
             "a logical schema's non-nullable Time `ts` takes ENGINE");
    CHECK(out != NULL, "and the schema is returned");
    const ds_schema_t *found = NULL;
    CHECK_OK(ds_engine_schema_find(e, "Reading", &found), "schema_find");
    CHECK(found != NULL && found == out, "and it is registered");
    ds_engine_free(e);
}

int main(void)
{
    test_engine_on_a_slot_named_at();
    test_engine_on_ts_of_a_ttl_schema();
    test_engine_on_an_int_ts();
    test_engine_on_a_nullable_ts();
    test_key_on_ts_of_a_logical_schema();
    test_engine_on_a_logical_time_ts_registers();

    if (failures == 0) {
        printf("OK  test_nfct_1_4_3_engine_role\n");
        return 0;
    }
    fprintf(stderr, "FAILED: %d check(s)\n", failures);
    return 1;
}
