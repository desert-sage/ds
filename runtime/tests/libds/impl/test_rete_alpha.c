/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The alpha node, its test evaluation and its memory (IRET.6, IRET.22.1):
 * create and NULL rejection; EQ and the six comparisons on Int, and Int
 * against Float; the first failing test decides; memory insert, contains,
 * remove and for_each, under growth, removal under collision, and a reused
 * fact pointer under a new id.
 */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "libds.h"
#include "rete/alpha.h"
#include "rete/engine.h"
#include "rete/fact.h"
#include "rete/schema.h"
#include "rete/schema_reg.h"
#include "rete/val.h"

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
        fprintf(stderr, "FAIL: %s: want status %d got %d (%s)\n",
                what, want, r.status, r.detail ? r.detail : "(null)");
        return 1;
    }
    return 0;
}

/* Build a minimal engine + schema with two slots: Int "value", Str "name" */
static ds_rete_engine_t *make_engine(ds_rete_schema_t **schema_out)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);

    ds_rete_slot_desc_t slots[] = {
        { .name = "value", .type = DS_RETE_VAL_INT,  .is_key = false },
        { .name = "name",  .type = DS_RETE_VAL_STR,  .is_key = true  },
    };
    ds_rete_schema_register(e, "Sensor", DS_RETE_SCOPE_PLAIN, 0,
                             slots, 2, schema_out);
    return e;
}

/* Allocate a stack-local fact with given slot values.
 * The fact is not in working memory; just used for test evaluation. */
static ds_rete_fact_t *alloc_fact(const ds_rete_schema_t *schema,
                                   int64_t int_val,
                                   const char *str_val_interned)
{
    size_t sz = sizeof(ds_rete_fact_t) +
                schema->slot_count * sizeof(ds_rete_val_t);
    ds_rete_fact_t *f = calloc(1, sz);
    f->schema = schema;
    f->id     = 1;
    f->slots[0] = ds_rete_val_int(int_val);
    f->slots[1] = ds_rete_val_str(str_val_interned,
                                   (uint32_t)strlen(str_val_interned));
    return f;
}

static int test_node_create_destroy(void)
{
    ds_rete_alpha_node_t *n = NULL;
    if (expect_ok("create no-test node",
                  ds_rete_alpha_node_create(0, NULL, 0, &n))) return 1;
    if (!n) return fail("create: out is NULL");
    if (n->test_count != 0) return fail("test_count should be 0");
    /* The memory is an oa map with no backing until the first insert; its hash
       callback says it was initialised. */
    if (n->memory.map.hash == NULL) return fail("memory map should be initialised");
    ds_rete_alpha_node_destroy(n);
    return 0;
}

static int test_node_null_rejection(void)
{
    if (expect_status("create NULL out",
                      ds_rete_alpha_node_create(0, NULL, 0, NULL),
                      DS_ERR_INVAL)) return 1;
    return 0;
}

static int test_eq_int(void)
{
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);

    ds_rete_alpha_test_t tests[] = {{
        .kind       = DS_RETE_ALPHA_EQ,
        .slot_index = 0,
        .op         = DS_RETE_CMP_EQ,
        .literal    = ds_rete_val_int(42),
    }};
    ds_rete_alpha_node_t *n = NULL;
    ds_rete_alpha_node_create(0, tests, 1, &n);

    ds_rete_fact_t *f_match = alloc_fact(schema, 42, "sensor_1");
    ds_rete_fact_t *f_miss  = alloc_fact(schema, 99, "sensor_1");

    if (!ds_rete_alpha_test_fact(n, f_match, NULL))
        return fail("eq_int: value=42 should pass");
    if (ds_rete_alpha_test_fact(n, f_miss, NULL))
        return fail("eq_int: value=99 should fail");

    free(f_match); free(f_miss);
    ds_rete_alpha_node_destroy(n);
    ds_rete_engine_destroy(e);
    return 0;
}

static int test_cmp_ops_int(void)
{
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);

    struct { ds_rete_cmp_op_t op; int64_t threshold; int64_t pass; int64_t fail_v; } cases[] = {
        { DS_RETE_CMP_LT,  10, 5,  15 },
        { DS_RETE_CMP_GT,  10, 15,  5  },
        { DS_RETE_CMP_LTE, 10, 10, 11  },
        { DS_RETE_CMP_GTE, 10, 10,  9  },
        { DS_RETE_CMP_NEQ, 10, 11, 10  },
    };
    for (size_t c = 0; c < sizeof(cases)/sizeof(cases[0]); c++) {
        ds_rete_alpha_test_t test = {
            .kind       = DS_RETE_ALPHA_CMP,
            .slot_index = 0,
            .op         = cases[c].op,
            .literal    = ds_rete_val_int(cases[c].threshold),
        };
        ds_rete_alpha_node_t *n = NULL;
        ds_rete_alpha_node_create(0, &test, 1, &n);

        ds_rete_fact_t *fp = alloc_fact(schema, cases[c].pass,  "x");
        ds_rete_fact_t *ff = alloc_fact(schema, cases[c].fail_v, "x");

        if (!ds_rete_alpha_test_fact(n, fp, NULL)) {
            fprintf(stderr, "FAIL: cmp op %d: pass case %" PRId64 " failed\n",
                    cases[c].op, cases[c].pass);
            free(fp); free(ff);
            ds_rete_alpha_node_destroy(n);
            ds_rete_engine_destroy(e);
            return 1;
        }
        if (ds_rete_alpha_test_fact(n, ff, NULL)) {
            fprintf(stderr, "FAIL: cmp op %d: fail case %" PRId64 " passed\n",
                    cases[c].op, cases[c].fail_v);
            free(fp); free(ff);
            ds_rete_alpha_node_destroy(n);
            ds_rete_engine_destroy(e);
            return 1;
        }
        free(fp); free(ff);
        ds_rete_alpha_node_destroy(n);
    }
    ds_rete_engine_destroy(e);
    return 0;
}

/* [LFAC.2.5.3]: a Float slot against an Int literal, and the reverse, promote
 * as the beta path does; the compiler hoists such a comparison onto the
 * alpha. */
static int test_cmp_mixed_int_float(void)
{
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);
    int rc = 0;

    ds_rete_alpha_test_t int_lit = {
        .kind = DS_RETE_ALPHA_CMP, .slot_index = 0,
        .op = DS_RETE_CMP_GT, .literal = ds_rete_val_int(75),
    };
    ds_rete_alpha_test_t float_lit = {
        .kind = DS_RETE_ALPHA_EQ, .slot_index = 0,
        .op = DS_RETE_CMP_EQ, .literal = ds_rete_val_float(42.0),
    };
    ds_rete_alpha_node_t *n_int = NULL, *n_float = NULL;
    ds_rete_alpha_node_create(0, &int_lit, 1, &n_int);
    ds_rete_alpha_node_create(1, &float_lit, 1, &n_float);

    ds_rete_fact_t *hot  = alloc_fact(schema, 0, "x");
    ds_rete_fact_t *cold = alloc_fact(schema, 0, "x");
    ds_rete_fact_t *i42  = alloc_fact(schema, 42, "x");
    hot->slots[0]  = ds_rete_val_float(99.0);
    cold->slots[0] = ds_rete_val_float(10.0);

    if (!ds_rete_alpha_test_fact(n_int, hot, NULL))
        rc = fail("mixed: Float 99.0 > Int 75 should pass");
    else if (ds_rete_alpha_test_fact(n_int, cold, NULL))
        rc = fail("mixed: Float 10.0 > Int 75 should fail");
    else if (!ds_rete_alpha_test_fact(n_float, i42, NULL))
        rc = fail("mixed: Int 42 == Float 42.0 should pass");

    free(hot); free(cold); free(i42);
    ds_rete_alpha_node_destroy(n_int);
    ds_rete_alpha_node_destroy(n_float);
    ds_rete_engine_destroy(e);
    return rc;
}

static int test_no_tests_always_passes(void)
{
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);

    ds_rete_alpha_node_t *n = NULL;
    ds_rete_alpha_node_create(0, NULL, 0, &n);

    ds_rete_fact_t *f = alloc_fact(schema, 0, "any");
    if (!ds_rete_alpha_test_fact(n, f, NULL))
        return fail("zero-test node must always pass");

    free(f);
    ds_rete_alpha_node_destroy(n);
    ds_rete_engine_destroy(e);
    return 0;
}

static int test_short_circuit(void)
{
    /* Two tests; first fails. Second would have passed. */
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);

    ds_rete_alpha_test_t tests[] = {
        { .kind = DS_RETE_ALPHA_EQ, .slot_index = 0,
          .op = DS_RETE_CMP_EQ, .literal = ds_rete_val_int(99) },
        { .kind = DS_RETE_ALPHA_EQ, .slot_index = 0,
          .op = DS_RETE_CMP_EQ, .literal = ds_rete_val_int(42) },
    };
    ds_rete_alpha_node_t *n = NULL;
    ds_rete_alpha_node_create(0, tests, 2, &n);

    ds_rete_fact_t *f = alloc_fact(schema, 42, "s");
    if (ds_rete_alpha_test_fact(n, f, NULL))
        return fail("short-circuit: should fail on first test");

    free(f);
    ds_rete_alpha_node_destroy(n);
    ds_rete_engine_destroy(e);
    return 0;
}

static int test_mem_insert_contains_remove(void)
{
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);

    ds_rete_alpha_node_t *n = NULL;
    ds_rete_alpha_node_create(0, NULL, 0, &n);

    ds_rete_fact_t *f = alloc_fact(schema, 1, "a");
    f->id = 7;

    if (ds_rete_alpha_mem_contains(&n->memory, f))
        return fail("contains: should be false before insert");

    if (expect_ok("insert", ds_rete_alpha_mem_insert(&n->memory, f))) return 1;
    if (!ds_rete_alpha_mem_contains(&n->memory, f))
        return fail("contains: should be true after insert");
    if ((size_t)oa_len(&n->memory.map) != 1)
        return fail("n != 1 after insert");

    if (expect_ok("remove", ds_rete_alpha_mem_remove(&n->memory, f))) return 1;
    if (ds_rete_alpha_mem_contains(&n->memory, f))
        return fail("contains: should be false after remove");
    if ((size_t)oa_len(&n->memory.map) != 0)
        return fail("n != 0 after remove");

    free(f);
    ds_rete_alpha_node_destroy(n);
    ds_rete_engine_destroy(e);
    return 0;
}

static int test_mem_duplicate_rejected(void)
{
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);
    ds_rete_alpha_node_t *n = NULL;
    ds_rete_alpha_node_create(0, NULL, 0, &n);

    ds_rete_fact_t *f = alloc_fact(schema, 1, "a");
    f->id = 3;
    ds_rete_alpha_mem_insert(&n->memory, f);
    if (expect_status("duplicate insert",
                      ds_rete_alpha_mem_insert(&n->memory, f),
                      DS_ERR_STATE)) return 1;
    if ((size_t)oa_len(&n->memory.map) != 1) return fail("n should still be 1");

    free(f);
    ds_rete_alpha_node_destroy(n);
    ds_rete_engine_destroy(e);
    return 0;
}

static int test_mem_remove_absent(void)
{
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);
    ds_rete_alpha_node_t *n = NULL;
    ds_rete_alpha_node_create(0, NULL, 0, &n);

    ds_rete_fact_t *f = alloc_fact(schema, 1, "a");
    f->id = 5;
    if (expect_status("remove absent",
                      ds_rete_alpha_mem_remove(&n->memory, f),
                      DS_ERR_NOT_FOUND)) return 1;

    free(f);
    ds_rete_alpha_node_destroy(n);
    ds_rete_engine_destroy(e);
    return 0;
}

static int for_each_count(ds_rete_fact_t *f, void *ctx)
{
    (void)f;
    (*(int *)ctx)++;
    return 0;
}

static int test_mem_for_each_api(void)
{
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);
    ds_rete_alpha_node_t *n = NULL;
    ds_rete_alpha_node_create(0, NULL, 0, &n);

    ds_rete_fact_t *facts[8];
    for (int i = 0; i < 8; i++) {
        facts[i] = alloc_fact(schema, i * 10, "y");
        facts[i]->id = (uint32_t)(i + 100);
        ds_rete_alpha_mem_insert(&n->memory, facts[i]);
    }
    ds_rete_alpha_mem_remove(&n->memory, facts[2]);
    ds_rete_alpha_mem_remove(&n->memory, facts[5]);

    int count = 0;
    ds_rete_alpha_mem_for_each(&n->memory, for_each_count, &count);
    if (count != 6) {
        fprintf(stderr, "FAIL: for_each_api: want 6, got %d\n", count);
        return 1;
    }

    for (int i = 0; i < 8; i++) free(facts[i]);
    ds_rete_alpha_node_destroy(n);
    ds_rete_engine_destroy(e);
    return 0;
}

static int test_mem_many_inserts_stability(void)
{
    /* 100 facts force several rehashes. */
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);
    ds_rete_alpha_node_t *n = NULL;
    ds_rete_alpha_node_create(0, NULL, 0, &n);

    ds_rete_fact_t *facts[100];
    for (int i = 0; i < 100; i++) {
        facts[i] = alloc_fact(schema, i, "z");
        facts[i]->id = (uint32_t)(i + 1000);
        if (expect_ok("insert many",
                      ds_rete_alpha_mem_insert(&n->memory, facts[i]))) return 1;
    }
    if ((size_t)oa_len(&n->memory.map) != 100) {
        fprintf(stderr, "FAIL: n after 100 inserts: %zu\n", (size_t)oa_len(&n->memory.map));
        return 1;
    }
    for (int i = 0; i < 100; i++) {
        if (!ds_rete_alpha_mem_contains(&n->memory, facts[i])) {
            fprintf(stderr, "FAIL: fact %d lost after rehash\n", i);
            return 1;
        }
    }
    for (int i = 0; i < 100; i++) free(facts[i]);
    ds_rete_alpha_node_destroy(n);
    ds_rete_engine_destroy(e);
    return 0;
}

/* Removal under collision leaves no hole mid probe chain: after every removal
 * the removed fact is gone and every surviving fact is still found. */
static int test_mem_delete_under_collision(void)
{
    enum { N = 200 };
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);
    ds_rete_alpha_node_t *n = NULL;
    ds_rete_alpha_node_create(0, NULL, 0, &n);

    ds_rete_fact_t *facts[N];
    for (int i = 0; i < N; i++) {
        facts[i] = alloc_fact(schema, i, "z");
        facts[i]->id = (uint32_t)(i + 1000);
        if (expect_ok("insert", ds_rete_alpha_mem_insert(&n->memory, facts[i]))) return 1;
    }
    for (int i = 0; i < N; i++) {
        if (expect_ok("remove", ds_rete_alpha_mem_remove(&n->memory, facts[i]))) return 1;
        if (ds_rete_alpha_mem_contains(&n->memory, facts[i])) {
            fprintf(stderr, "FAIL: removed fact %d still present\n", i);
            return 1;
        }
        if ((size_t)oa_len(&n->memory.map) != (size_t)(N - 1 - i)) {
            fprintf(stderr, "FAIL: n=%zu after removing %d, want %d\n",
                    (size_t)oa_len(&n->memory.map), i, N - 1 - i);
            return 1;
        }
        for (int j = i + 1; j < N; j++) {
            if (!ds_rete_alpha_mem_contains(&n->memory, facts[j])) {
                fprintf(stderr, "FAIL: surviving fact %d unreachable after "
                        "removing %d (probe chain broken)\n", j, i);
                return 1;
            }
        }
    }
    for (int i = 0; i < N; i++) free(facts[i]);
    ds_rete_alpha_node_destroy(n);
    ds_rete_engine_destroy(e);
    return 0;
}


/* The memory matches by stored id, not by pointer: the LIFO fact pool can hand
 * a freed fact's pointer to a new fact while a stale entry still holds it, and
 * the new fact, under its own id, must insert. One allocation models it. */
static int test_mem_slab_reuse_id_aliasing(void)
{
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine(&schema);
    ds_rete_alpha_node_t *n = NULL;
    ds_rete_alpha_node_create(0, NULL, 0, &n);

    /* Any two distinct ids serve: oa matches by key. */
    uint32_t id1 = 1, id2 = 2;

    ds_rete_fact_t *slab = alloc_fact(schema, 0, "z");
    slab->id = id1;
    if (expect_ok("insert orphan", ds_rete_alpha_mem_insert(&n->memory, slab))) return 1;

    /* The same pointer as a new fact; the id1 entry is left stale. */
    slab->id = id2;
    ds_result_t r = ds_rete_alpha_mem_insert(&n->memory, slab);
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: reused-slab insert rejected (status %d) — "
                "pointer-dedup false DUPLICATE; the rule would go dark\n", r.status);
        free(slab); ds_rete_alpha_node_destroy(n); ds_rete_engine_destroy(e);
        return 1;
    }
    free(slab);
    ds_rete_alpha_node_destroy(n);
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

    printf("=== test_rete_alpha ===\n");
    RUN(test_node_create_destroy);
    RUN(test_node_null_rejection);
    RUN(test_eq_int);
    RUN(test_cmp_ops_int);
    RUN(test_cmp_mixed_int_float);
    RUN(test_no_tests_always_passes);
    RUN(test_short_circuit);
    RUN(test_mem_insert_contains_remove);
    RUN(test_mem_duplicate_rejected);
    RUN(test_mem_remove_absent);
    RUN(test_mem_for_each_api);
    RUN(test_mem_many_inserts_stability);
    RUN(test_mem_delete_under_collision);
    RUN(test_mem_slab_reuse_id_aliasing);
#undef RUN

    if (fail_count == 0) {
        printf("=== test_rete_alpha: ALL PASSED ===\n");
        return 0;
    }
    fprintf(stderr, "=== test_rete_alpha: %d FAILED ===\n", fail_count);
    return 1;
}
