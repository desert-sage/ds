/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * White-box unit test of the wm module: schemas are built and
 * ds_wm_fact_new / _free called directly, through the internal headers.
 *
 * The fact-tracking table is keyed by rete_fact pointer. This test makes
 * unique non-NULL fake pointers as keys; the table never dereferences them.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "libds.h"

/* Internal headers — available via -I../../src/libds. */
#include "engine.h"
#include "schema.h"
#include "wm.h"

/* A fake Rete-fact pointer: a key, never dereferenced. */
static void *fake_rete_fact(uintptr_t i)
{
    return (void *) (uintptr_t) (0x10000ull + i * 0x100ull);
}

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

/* Build and register a trivial schema for testing. Returns borrowed
   pointer to the registered schema via *out. */
static int make_and_register_schema(ds_engine_t       *e,
                                     const char         *name,
                                     uint32_t            n_slots,
                                     const ds_schema_t **out)
{
    /* Build a simple slot list: all INT slots with generated names. */
    static const char *const slot_names[] = {
        "a", "b", "c", "d", "e", "f", "g", "h"
    };
    if (n_slots > sizeof(slot_names) / sizeof(slot_names[0])) {
        fprintf(stderr, "FAIL: test helper n_slots too large\n");
        return 1;
    }

    ds_slot_desc_t descs[8] = {0};
    for (uint32_t i = 0; i < n_slots; i++) {
        descs[i].name = slot_names[i];
        descs[i].type = DS_SLOT_TYPE_INT;
    }

    ds_schema_t *s = NULL;
    ds_result_t r = ds_schema_new(name, DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                  descs, n_slots, &s);
    if (expect_ok("ds_schema_new", r)) return 1;

    r = ds_schema_registry_add(&e->schemas, s);
    if (expect_ok("registry_add", r)) return 1;

    *out = s;
    return 0;
}

int main(void)
{
    ds_engine_t *e = NULL;
    ds_result_t r;

    r = ds_engine_new(NULL, &e);
    if (expect_ok("ds_engine_new", r)) return 1;

    /* Fresh engine has zero facts. */
    size_t count = (size_t) -1;
    r = ds_engine_fact_count(e, &count);
    if (expect_ok("fact_count #1", r)) return 1;
    if (count != 0) {
        fprintf(stderr, "FAIL: fresh engine has %zu facts, want 0\n", count);
        return 1;
    }

    /* Register two schemas. */
    const ds_schema_t *schema_a = NULL;
    const ds_schema_t *schema_b = NULL;
    if (make_and_register_schema(e, "SchemaA", 3, &schema_a)) return 1;
    if (make_and_register_schema(e, "SchemaB", 0, &schema_b)) return 1;

    /* Create facts of each schema. */
    ds_fact_t *f1 = NULL;
    r = ds_wm_fact_new(&e->wm, schema_a, fake_rete_fact(1), &f1);
    if (expect_ok("wm_fact_new f1", r)) return 1;
    if (f1->schema != schema_a) {
        fprintf(stderr, "FAIL: f1->schema != schema_a\n");
        return 1;
    }
    if (f1->n_slots != 3) {
        fprintf(stderr, "FAIL: f1->n_slots = %u, want 3\n", f1->n_slots);
        return 1;
    }
    /* Ids start at 1: 0 is the "not set" sentinel for stream fields, so no real
     * fact may carry it. */
    if (f1->fact_id != 1) {
        fprintf(stderr, "FAIL: first fact_id = %lu, want 1\n",
                (unsigned long) f1->fact_id);
        return 1;
    }
    for (uint32_t i = 0; i < f1->n_slots; i++) {
        if (f1->slots[i].kind != DS_SLOT_INT || f1->slots[i].v.i != 0) {
            fprintf(stderr, "FAIL: slot %u not zero-initialised\n", i);
            return 1;
        }
    }

    ds_fact_t *f2 = NULL;
    r = ds_wm_fact_new(&e->wm, schema_b, fake_rete_fact(2), &f2);
    if (expect_ok("wm_fact_new f2", r)) return 1;
    if (f2->schema != schema_b) {
        fprintf(stderr, "FAIL: f2->schema != schema_b\n");
        return 1;
    }
    if (f2->fact_id != 2) {
        fprintf(stderr, "FAIL: second fact_id = %lu, want 2\n",
                (unsigned long) f2->fact_id);
        return 1;
    }
    if (f2->n_slots != 0) {
        fprintf(stderr, "FAIL: f2->n_slots = %u, want 0\n", f2->n_slots);
        return 1;
    }

    r = ds_engine_fact_count(e, &count);
    if (expect_ok("fact_count after f1+f2", r)) return 1;
    if (count != 2) {
        fprintf(stderr, "FAIL: after f1+f2 count = %zu, want 2\n", count);
        return 1;
    }

    /* Free f1. */
    r = ds_wm_fact_free(&e->wm, f1);
    if (expect_ok("wm_fact_free f1", r)) return 1;
    r = ds_engine_fact_count(e, &count);
    if (expect_ok("fact_count after free(f1)", r)) return 1;
    if (count != 1) {
        fprintf(stderr, "FAIL: after free(f1) count = %zu, want 1\n", count);
        return 1;
    }

    /* NOT_FOUND for a live wrapper whose rete_fact the table never saw.
     * Freeing a wrapper twice is not tested: the second call reads freed
     * memory, and wm.h states the precondition. */
    ds_fact_t untracked;
    memset(&untracked, 0, sizeof(untracked));
    untracked.rete_fact = fake_rete_fact(9999);
    r = ds_wm_fact_free(&e->wm, &untracked);
    if (expect_status("free of a live but untracked wrapper", r,
                      DS_ERR_NOT_FOUND)) return 1;

    /* A live wrapper whose rete_fact names a different tracked fact is
     * refused, and f2 stays. The Rete pool is LIFO and reuses freed slots,
     * so a stale key can alias a live one. */
    ds_fact_t aliased;
    memset(&aliased, 0, sizeof(aliased));
    aliased.rete_fact = f2->rete_fact;
    r = ds_wm_fact_free(&e->wm, &aliased);
    if (expect_status("free of a wrapper aliasing another fact's key", r,
                      DS_ERR_NOT_FOUND)) return 1;
    r = ds_engine_fact_count(e, &count);
    if (expect_ok("fact_count after refused alias free", r)) return 1;
    if (count != 1) {
        fprintf(stderr, "FAIL: alias free released f2; count = %zu, want 1\n",
                count);
        return 1;
    }

    /* Burst of facts to grow the tracking table past initial cap. */
    #define BURST 20
    ds_fact_t *burst[BURST];
    for (int i = 0; i < BURST; i++) {
        r = ds_wm_fact_new(&e->wm, schema_a,
                           fake_rete_fact(100 + (uintptr_t) i),
                           &burst[i]);
        if (expect_ok("burst fact_new", r)) return 1;
    }
    r = ds_engine_fact_count(e, &count);
    if (expect_ok("fact_count after burst", r)) return 1;
    if (count != 21) {
        fprintf(stderr, "FAIL: after burst count = %zu, want 21\n", count);
        return 1;
    }

    /* NULL-arg rejection. */
    r = ds_wm_fact_new(NULL, schema_a, fake_rete_fact(999), &f1);
    if (expect_status("wm_fact_new NULL wm", r, DS_ERR_INVAL)) return 1;
    r = ds_wm_fact_new(&e->wm, NULL, fake_rete_fact(999), &f1);
    if (expect_status("wm_fact_new NULL schema", r, DS_ERR_INVAL)) return 1;
    r = ds_wm_fact_new(&e->wm, schema_a, NULL, &f1);
    if (expect_status("wm_fact_new NULL rete_fact", r, DS_ERR_INVAL)) return 1;
    r = ds_wm_fact_new(&e->wm, schema_a, fake_rete_fact(999), NULL);
    if (expect_status("wm_fact_new NULL out", r, DS_ERR_INVAL)) return 1;
    r = ds_wm_fact_free(&e->wm, NULL);
    if (expect_status("wm_fact_free NULL fact", r, DS_ERR_INVAL)) return 1;
    r = ds_engine_fact_count(NULL, &count);
    if (expect_status("fact_count NULL engine", r, DS_ERR_INVAL)) return 1;

    /* Clean teardown; wm_destroy frees remaining 21 facts; registry
       destroy frees the two schemas. */
    r = ds_engine_free(e);
    if (expect_ok("ds_engine_free", r)) return 1;

    /* [NFCT.2.2]: n_values equals the schema's slot count. A short array
       (on both entry points) or a long one is refused and touches nothing;
       a full row asserts. */
    {
        ds_engine_t *ea = NULL;
        r = ds_engine_new(NULL, &ea);
        if (expect_ok("arity: engine_new", r)) return 1;
        static const ds_slot_desc_t two[2] = {
            { .name = "a", .type = DS_SLOT_TYPE_INT,
              .identity_role = DS_IDENTITY_KEY },
            { .name = "b", .type = DS_SLOT_TYPE_INT,
              .identity_role = DS_IDENTITY_MUTABLE },
        };
        const ds_schema_t *sc = NULL;
        r = ds_engine_register_schema(ea, "Pair", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                      0, two, 2, &sc);
        if (expect_ok("arity: register Pair", r)) return 1;

        ds_slot_value_t v3[3] = {
            { .kind = DS_SLOT_INT, .v.i = 1 },
            { .kind = DS_SLOT_INT, .v.i = 2 },
            { .kind = DS_SLOT_INT, .v.i = 3 },
        };
        ds_fact_t *got = (ds_fact_t *) 1;   /* must come back NULL */
        r = ds_engine_assert(ea, sc, v3, 1, &got);
        if (expect_status("arity: one value for two slots", r, DS_ERR_INVAL))
            return 1;
        if (got != NULL) {
            fprintf(stderr, "FAIL: a refused assert left *out_fact set\n");
            return 1;
        }
        r = ds_engine_assert(ea, sc, v3, 3, NULL);
        if (expect_status("arity: three values for two slots", r,
                          DS_ERR_INVAL))
            return 1;
        r = ds_engine_assert_with_ttl(ea, sc, v3, 1, 1000000000ull, NULL);
        if (expect_status("arity: with_ttl, one value for two slots", r,
                          DS_ERR_INVAL))
            return 1;
        size_t n_after = 99;
        r = ds_engine_fact_count(ea, &n_after);
        if (expect_ok("arity: fact_count", r)) return 1;
        if (n_after != 0) {
            fprintf(stderr, "FAIL: refused asserts left %zu fact(s)\n",
                    n_after);
            return 1;
        }

        r = ds_engine_assert(ea, sc, v3, 2, NULL);
        if (expect_ok("arity: two values for two slots", r)) return 1;
        r = ds_engine_fact_count(ea, &n_after);
        if (expect_ok("arity: fact_count after a full row", r)) return 1;
        if (n_after != 1) {
            fprintf(stderr, "FAIL: a full row asserted %zu fact(s)\n",
                    n_after);
            return 1;
        }
        r = ds_engine_free(ea);
        if (expect_ok("arity: engine_free", r)) return 1;
    }

    printf("test_wm_basic: OK\n");
    return 0;
}
