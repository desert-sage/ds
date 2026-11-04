/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NFCT.6.4]
 * ds_engine_fact_find looks a live fact up by its id, and finds nothing for
 * an id whose fact was retracted, expired or superseded, or was never
 * assigned. A no-op reassertion keeps the id, a clone answers with its own
 * facts, and NOT_FOUND writes NULL. Not covered: the clause's halted engine.
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
#define PAST_TTL_NS   2000000000ull

static const ds_slot_desc_t TTL_SLOTS[1] = {
    { .name = "level", .type = DS_SLOT_TYPE_INT,
      .identity_role = DS_IDENTITY_UNSPECIFIED },
};

static const ds_slot_desc_t KEYED_SLOTS[2] = {
    { .name = "id",    .type = DS_SLOT_TYPE_INT,
      .identity_role = DS_IDENTITY_KEY },
    { .name = "level", .type = DS_SLOT_TYPE_INT,
      .identity_role = DS_IDENTITY_MUTABLE },
};

static ds_engine_t *new_engine(const ds_schema_t **ttl, const ds_schema_t **keyed)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (!e) return NULL;
    CHECK_OK(ds_engine_register_schema(e, "Reading", DS_SCHEMA_LIFECYCLE_TTL,
                                       SCHEMA_TTL_NS, TTL_SLOTS, 1, ttl),
             "register Reading");
    CHECK_OK(ds_engine_register_schema(e, "Keyed", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                       0, KEYED_SLOTS, 2, keyed),
             "register Keyed");
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "clock_set_mode");
    CHECK_OK(ds_engine_clock_set(e, 0), "clock_set 0");
    return e;
}

static uint64_t id_of(const ds_fact_t *f)
{
    uint64_t id = 0;
    CHECK_OK(ds_fact_get_id(f, &id), "fact_get_id");
    return id;
}

/* NOT_FOUND, and *out written NULL over a non-NULL sentinel. */
static void expect_gone(ds_engine_t *e, uint64_t id, const char *what)
{
    ds_fact_t *out = (ds_fact_t *)(uintptr_t)1;
    ds_result_t r = ds_engine_fact_find(e, id, &out);
    if (r.status != DS_ERR_NOT_FOUND) {
        fprintf(stderr, "FAIL: %s: want NOT_FOUND, got %d\n", what, r.status);
        failures++;
    }
    CHECK(out == NULL, what);
}

static void expect_live(ds_engine_t *e, uint64_t id, const ds_fact_t *want,
                        const char *what)
{
    ds_fact_t *out = NULL;
    CHECK_OK(ds_engine_fact_find(e, id, &out), what);
    CHECK(out == want, what);
}

static void test_live_retract_ttl_never(void)
{
    const ds_schema_t *ttl = NULL, *keyed = NULL;
    ds_engine_t *e = new_engine(&ttl, &keyed);
    if (!e) return;

    ds_slot_value_t v[1];
    memset(v, 0, sizeof v);
    v[0].kind = DS_SLOT_INT;

    v[0].v.i = 1;
    ds_fact_t *a = NULL;
    CHECK_OK(ds_engine_assert(e, ttl, v, 1, &a), "assert a");
    v[0].v.i = 2;
    ds_fact_t *b = NULL;
    CHECK_OK(ds_engine_assert(e, ttl, v, 1, &b), "assert b");
    CHECK_OK(ds_engine_pump(e), "pump");
    const uint64_t ida = id_of(a), idb = id_of(b);

    expect_live(e, ida, a, "a found while live");
    expect_live(e, idb, b, "b found while live");

    expect_gone(e, 0, "id 0 is never assigned");
    expect_gone(e, (ida > idb ? ida : idb) + 1, "an id past the last");

    CHECK_OK(ds_engine_retract(e, a), "retract a");
    CHECK_OK(ds_engine_pump(e), "pump after retract");
    expect_gone(e, ida, "a not found after the integrator retracts it");
    expect_live(e, idb, b, "b still found after a's retract");

    CHECK_OK(ds_engine_clock_advance(e, PAST_TTL_NS), "advance past ttl");
    CHECK_OK(ds_engine_pump(e), "pump that sweeps");
    size_t n = 1;
    CHECK_OK(ds_engine_fact_count(e, &n), "fact_count");
    CHECK(n == 0, "b expired -- premise of the next check");
    expect_gone(e, idb, "b not found after its TTL expires");

    ds_engine_free(e);
}

static void test_upsert_and_noop(void)
{
    const ds_schema_t *ttl = NULL, *keyed = NULL;
    ds_engine_t *e = new_engine(&ttl, &keyed);
    if (!e) return;

    ds_slot_value_t v[2];
    memset(v, 0, sizeof v);
    v[0].kind = DS_SLOT_INT; v[0].v.i = 7;     /* the identity */
    v[1].kind = DS_SLOT_INT; v[1].v.i = 10;
    ds_fact_t *f1 = NULL;
    CHECK_OK(ds_engine_assert(e, keyed, v, 2, &f1), "assert Keyed(7,10)");
    CHECK_OK(ds_engine_pump(e), "pump");
    const uint64_t id1 = id_of(f1);

    /* A no-op reassertion returns the live fact: same wrapper, same id. */
    ds_fact_t *same = NULL;
    CHECK_OK(ds_engine_assert(e, keyed, v, 2, &same), "no-op reassert");
    CHECK_OK(ds_engine_pump(e), "pump after no-op");
    CHECK(same == f1, "the no-op reassert returned the live fact -- premise");
    expect_live(e, id1, f1, "found after a no-op reassertion");

    /* An upsert supersedes it ([LFAC.2.5.1]): a new fact with a new id. */
    v[1].v.i = 20;
    ds_fact_t *f2 = NULL;
    CHECK_OK(ds_engine_assert(e, keyed, v, 2, &f2), "upsert Keyed(7,20)");
    CHECK_OK(ds_engine_pump(e), "pump after upsert");
    const uint64_t id2 = id_of(f2);
    CHECK(id2 != id1, "the upsert minted a new id -- premise");
    expect_gone(e, id1, "the superseded fact is not found");
    expect_live(e, id2, f2, "the superseding fact is found");

    ds_engine_free(e);
}

static void test_clone_answers_for_its_own(void)
{
    const ds_schema_t *ttl = NULL, *keyed = NULL;
    ds_engine_t *e = new_engine(&ttl, &keyed);
    if (!e) return;

    ds_slot_value_t v[1];
    memset(v, 0, sizeof v);
    v[0].kind = DS_SLOT_INT; v[0].v.i = 3;
    ds_fact_t *f = NULL;
    CHECK_OK(ds_engine_assert(e, ttl, v, 1, &f), "assert");
    CHECK_OK(ds_engine_pump(e), "pump");
    const uint64_t id = id_of(f);

    ds_engine_t *c = NULL;
    CHECK_OK(ds_engine_clone(e, &c), "clone");
    if (c) {
        ds_fact_t *cf = NULL;
        CHECK_OK(ds_engine_fact_find(c, id, &cf), "the clone finds the id");
        CHECK(cf != NULL && cf != f, "the clone's fact is its own, not the source's");
        CHECK(cf != NULL && id_of(cf) == id, "and carries the same id");

        /* Retracting in the clone leaves the source's answer alone. */
        if (cf) CHECK_OK(ds_engine_retract(c, cf), "retract in the clone");
        CHECK_OK(ds_engine_pump(c), "pump the clone");
        expect_gone(c, id, "gone from the clone after its retract");
        expect_live(e, id, f, "still found in the source");
        ds_engine_free(c);
    }
    ds_engine_free(e);
}

static void test_arguments(void)
{
    const ds_schema_t *ttl = NULL, *keyed = NULL;
    ds_engine_t *e = new_engine(&ttl, &keyed);
    if (!e) return;
    CHECK(ds_engine_fact_find(e, 1, NULL).status == DS_ERR_INVAL,
          "NULL out is refused");
    ds_fact_t *out = (ds_fact_t *)(uintptr_t)1;
    CHECK(ds_engine_fact_find(NULL, 1, &out).status == DS_ERR_INVAL,
          "NULL engine is refused");
    CHECK(out == NULL, "and *out is written NULL");
    ds_engine_free(e);
}

int main(void)
{
    test_live_retract_ttl_never();
    test_upsert_and_noop();
    test_clone_answers_for_its_own();
    test_arguments();

    if (failures == 0) {
        printf("OK  test_nfct_6_4_fact_find\n");
        return 0;
    }
    fprintf(stderr, "FAILED: %d check(s)\n", failures);
    return 1;
}
