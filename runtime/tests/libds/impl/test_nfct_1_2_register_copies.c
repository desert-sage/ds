/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * ds_engine_register_schema, internal (engine.h), on which libds's own tests
 * build their schemas. It links no clause: [NFCT.1.2] is a tombstone.
 *
 * 1. Registration copies its strings. The caller's buffers are overwritten,
 *    which a borrowed pointer would read on any build, and then freed.
 * 2. Registration after the first pump is DS_ERR_STATE and changes nothing.
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

static char *heap_str(const char *s)
{
    size_t n = strlen(s) + 1;
    char *p = malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

static ds_engine_t *new_engine(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    return e;
}

static void test_registration_copies_its_strings(void)
{
    ds_engine_t *e = new_engine();
    if (!e) return;

    char *type = heap_str("Reading");
    char *slot = heap_str("level");
    char *doc  = heap_str("the level, in percent");
    if (!type || !slot || !doc) {
        fprintf(stderr, "FAIL: malloc\n"); failures++;
        free(type); free(slot); free(doc); ds_engine_free(e); return;
    }
    ds_slot_desc_t sd = { .name = slot, .type = DS_SLOT_TYPE_INT,
                          .identity_role = DS_IDENTITY_KEY, .docstring = doc };
    const ds_schema_t *reg = NULL;
    CHECK_OK(ds_engine_register_schema(e, type, DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       &sd, 1, &reg),
             "register from heap buffers");

    memset(type, 'X', strlen(type));
    memset(slot, 'X', strlen(slot));
    memset(doc,  'X', strlen(doc));

    const ds_schema_t *found = NULL;
    CHECK_OK(ds_engine_schema_find(e, "Reading", &found), "schema_find");
    CHECK(found != NULL && found == reg,
          "found by its name after the caller overwrote its buffer");
    if (found) {
        const char *name = NULL;
        CHECK_OK(ds_schema_get_name(found, &name), "get_name");
        CHECK(name != NULL && strcmp(name, "Reading") == 0,
              "the type name is the engine's copy");
        ds_slot_desc_t s0;
        CHECK_OK(ds_schema_get_slot(found, 0, &s0), "get_slot 0");
        CHECK(s0.name != NULL && strcmp(s0.name, "level") == 0,
              "the slot name is the engine's copy");
        CHECK(s0.docstring != NULL &&
                  strcmp(s0.docstring, "the level, in percent") == 0,
              "the docstring is the engine's copy");
    }

    free(type); free(slot); free(doc);

    if (found) {
        ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = 42 };
        ds_fact_t *f = NULL;
        CHECK_OK(ds_engine_assert(e, found, &sv, 1, &f),
                 "assert after the caller freed its buffers");
        CHECK_OK(ds_engine_pump(e), "pump");
        size_t n = 0;
        CHECK_OK(ds_engine_fact_count(e, &n), "fact_count");
        CHECK(n == 1, "the fact is in working memory");
        const char *name = NULL;
        CHECK_OK(ds_schema_get_name(found, &name), "get_name after free");
        CHECK(name != NULL && strcmp(name, "Reading") == 0,
              "and the schema still reads its own name");
    }
    ds_engine_free(e);
}

static void test_registration_after_the_first_pump_is_refused(void)
{
    ds_engine_t *e = new_engine();
    if (!e) return;
    ds_slot_desc_t sd = { .name = "level", .type = DS_SLOT_TYPE_INT,
                          .identity_role = DS_IDENTITY_KEY };
    CHECK_OK(ds_engine_register_schema(e, "Before", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                       0, &sd, 1, NULL),
             "register before the first pump");
    CHECK_OK(ds_engine_pump(e), "the first pump");

    size_t before = 0;
    CHECK_OK(ds_engine_schema_count(e, &before), "schema_count");
    const ds_schema_t *out = (const ds_schema_t *)(uintptr_t)1;
    ds_result_t r = ds_engine_register_schema(e, "After",
                                              DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                              &sd, 1, &out);
    CHECK(r.status == DS_ERR_STATE,
          "registering after the first pump is DS_ERR_STATE");
    CHECK(out == NULL, "and writes *out_schema NULL");
    size_t after = 0;
    CHECK_OK(ds_engine_schema_count(e, &after), "schema_count after");
    CHECK(after == before, "and changes nothing: the count is unchanged");
    const ds_schema_t *found = (const ds_schema_t *)(uintptr_t)1;
    CHECK_OK(ds_engine_schema_find(e, "After", &found), "schema_find");
    CHECK(found == NULL, "nor is the refused schema found");
    ds_engine_free(e);
}

int main(void)
{
    test_registration_copies_its_strings();
    test_registration_after_the_first_pump_is_refused();

    if (failures == 0) {
        printf("OK  test_nfct_1_2_register_copies\n");
        return 0;
    }
    fprintf(stderr, "FAILED: %d check(s)\n", failures);
    return 1;
}
