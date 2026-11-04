/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The fact model, black-box through libds.h:
 *   LFAC.1.1   — a schema declares its lifecycle (logical and ttl).
 *   LFAC.1.2.2 — logical: distinct key values are distinct facts.
 *   LFAC.1.3.3 — ttl: a pump past the deadline retracts the fact.
 *   LFAC.2.5.1 — a no-op reassertion is de-duplicated, by exact equality
 *                on an Int, Float, String or Bool key slot.
 */
#include "spec_common.h"

/* ============== Stream probe ============== */

typedef struct {
    int n_fact_assert;
    int n_fact_retract;
} stream_probe_t;

static ds_result_t stream_cb(ds_engine_t          *engine,
                             const ds_stream_ev_t *event,
                             void                 *user)
{
    (void) engine;
    stream_probe_t *s = (stream_probe_t *) user;
    if (event->kind == DS_EV_FACT_ASSERT)  s->n_fact_assert++;
    if (event->kind == DS_EV_FACT_RETRACT) s->n_fact_retract++;
    return DS_OK_R;
}

/* ============== Per-scenario fixture ============== */

static int new_engine(ds_engine_t **out_e)
{
    ds_engine_t *e = NULL;
    ds_result_t r = ds_engine_new(NULL, &e);
    if (r.status != DS_OK) return spec_fail("engine_new", r);
    *out_e = e;
    return 0;
}

/* Load the one-slot schema `ds_decl` declares and resolve `name`. Set the
   stream callback after this returns: the loader emits its own load-time
   events, and a probe installed earlier would count them. */
static int load_one_slot(ds_engine_t        *e,
                         const char          *name,
                         const char          *ds_decl,
                         const ds_schema_t  **out_schema)
{
    ds_result_t r = spec_load_ds(e, ds_decl);
    if (r.status != DS_OK) return spec_fail("spec_load_ds one-slot", r);
    r = ds_engine_schema_find(e, name, out_schema);
    if (r.status != DS_OK || *out_schema == NULL)
        return spec_fail("schema_find one-slot", r);
    return 0;
}

/* ============== Scenarios ============== */

/* LFAC.1.1 — a `scope logical` schema is LOGICAL, with no TTL. */
static int test_lfac_1_1__schema_declares_logical(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *s = NULL;
    if (new_engine(&e)) return 1;
    if (load_one_slot(e, "L", "schema L scope logical:\n    v: Int key\n", &s))
        return 1;
    ds_schema_lifecycle_t lc;
    ds_result_t r = ds_schema_get_lifecycle(s, &lc);
    EXPECT_OK("get_lifecycle", r);
    if (lc != DS_SCHEMA_LIFECYCLE_LOGICAL) {
        fprintf(stderr, "FAIL: lifecycle %d, want LOGICAL\n", (int) lc);
        return 1;
    }
    uint64_t ttl = 1;
    r = ds_schema_get_ttl_ns(s, &ttl);
    EXPECT_OK("get_ttl_ns", r);
    if (ttl != 0) {
        fprintf(stderr, "FAIL: logical schema ttl_ns=%llu, want 0\n",
                (unsigned long long) ttl);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* LFAC.1.1 — a `scope ttl 1_s` schema is TTL, with its declared lifetime. */
static int test_lfac_1_1__schema_declares_ttl(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *s = NULL;
    if (new_engine(&e)) return 1;
    if (load_one_slot(e, "T", "schema T scope ttl 1_s:\n    v: Int\n", &s))
        return 1;
    ds_schema_lifecycle_t lc;
    ds_result_t r = ds_schema_get_lifecycle(s, &lc);
    EXPECT_OK("get_lifecycle", r);
    if (lc != DS_SCHEMA_LIFECYCLE_TTL) {
        fprintf(stderr, "FAIL: lifecycle %d, want TTL\n", (int) lc);
        return 1;
    }
    uint64_t ttl = 0;
    r = ds_schema_get_ttl_ns(s, &ttl);
    EXPECT_OK("get_ttl_ns", r);
    if (ttl != 1000000000ull) {
        fprintf(stderr, "FAIL: ttl_ns=%llu, want 1000000000\n",
                (unsigned long long) ttl);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* LFAC.1.2.2 — two distinct key values are two distinct facts. */
static int test_lfac_1_2_2__logical_distinct_values_distinct_facts(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *s = NULL;
    if (new_engine(&e)) return 1;
    if (load_one_slot(e, "S", "schema S scope logical:\n    v: Int key\n", &s))
        return 1;
    ds_slot_value_t v1[] = { { .kind = DS_SLOT_INT, .v.i = 1 } };
    ds_slot_value_t v2[] = { { .kind = DS_SLOT_INT, .v.i = 2 } };
    ds_fact_t *p1 = NULL, *p2 = NULL;
    ds_result_t r = ds_engine_assert(e, s, v1, 1, &p1);
    EXPECT_OK("assert 1", r);
    r = ds_engine_assert(e, s, v2, 1, &p2);
    EXPECT_OK("assert 2", r);
    if (p1 == p2) {
        fprintf(stderr, "FAIL: distinct values gave same fact ptr\n");
        return 1;
    }
    size_t fc = 0;
    r = ds_engine_fact_count(e, &fc);
    EXPECT_OK("fact_count", r);
    if (fc != 2) {
        fprintf(stderr, "FAIL: fc=%zu, want 2\n", fc); return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* LFAC.1.3.3 — a pump past a per-schema TTL's deadline retracts the fact. */
static int test_lfac_1_3_3__ttl_expires_at_deadline(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL;
    const ds_schema_t *s = NULL;
    if (new_engine(&e)) return 1;
    ds_result_t r = ds_engine_clock_set_mode(e, DS_CLOCK_MOCK);
    EXPECT_OK("mock_mode", r);
    r = ds_engine_clock_set(e, 1000000);  /* t = 1ms */
    EXPECT_OK("clock 1ms", r);
    if (load_one_slot(e, "S", "schema S scope ttl 1_ms:\n    v: Int\n", &s))
        return 1;
    r = ds_engine_set_stream_callback(e, stream_cb, &sp);
    EXPECT_OK("set_stream_cb", r);
    ds_slot_value_t v[] = { { .kind = DS_SLOT_INT, .v.i = 1 } };
    r = ds_engine_assert(e, s, v, 1, NULL);
    EXPECT_OK("assert ttl", r);
    /* The deadline is 2ms. */
    r = ds_engine_clock_set(e, 3000000);  /* t = 3ms */
    EXPECT_OK("clock 3ms", r);
    r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_fact_retract != 1) {
        fprintf(stderr, "FAIL: ttl did not retract (count=%d)\n",
                sp.n_fact_retract);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* LFAC.2.5.1 — a reassertion equal on the Int key slot is a no-op: the same
   fact, and fact_count unchanged. */
static int test_lfac_2_5_1__int_exact_equality_dedup(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL;
    const ds_schema_t *s = NULL;
    if (new_engine(&e)) return 1;
    if (load_one_slot(e, "S", "schema S scope logical:\n    v: Int key\n", &s))
        return 1;
    ds_result_t r = ds_engine_set_stream_callback(e, stream_cb, &sp);
    EXPECT_OK("set_stream_cb", r);
    ds_slot_value_t v[] = { { .kind = DS_SLOT_INT, .v.i = 7 } };
    ds_fact_t *p1 = NULL, *p2 = NULL;
    r = ds_engine_assert(e, s, v, 1, &p1);
    EXPECT_OK("assert 1", r);
    r = ds_engine_assert(e, s, v, 1, &p2);
    EXPECT_OK("assert 2 (dedup)", r);
    if (p1 != p2) {
        fprintf(stderr, "FAIL: int dedup gave different ptr\n"); return 1;
    }
    /* Two FACT_ASSERTs: a FactAssert records an assert arriving, and both
       arrived ([RFCS.6.7]). */
    r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_fact_assert != 2) {
        fprintf(stderr, "FAIL: dedup emitted %d FACT_ASSERT, want 2 "
                        "(the no-op re-assert is recorded)\n",
                sp.n_fact_assert);
        return 1;
    }
    size_t fc = 0;
    r = ds_engine_fact_count(e, &fc);
    EXPECT_OK("fact_count", r);
    if (fc != 1) {
        fprintf(stderr, "FAIL: fc=%zu, want 1\n", fc); return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* LFAC.2.5.1 — exact equality dedup on a String key slot. */
static int test_lfac_2_5_1__string_exact_equality_dedup(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *s = NULL;
    if (new_engine(&e)) return 1;
    if (load_one_slot(e, "S", "schema S scope logical:\n    v: String key\n", &s))
        return 1;
    ds_slot_value_t v[] = { { .kind = DS_SLOT_STRING, .v.s = "alpha" } };
    ds_fact_t *p1 = NULL, *p2 = NULL;
    ds_result_t r = ds_engine_assert(e, s, v, 1, &p1);
    EXPECT_OK("assert 1", r);
    r = ds_engine_assert(e, s, v, 1, &p2);
    EXPECT_OK("assert 2 (dedup)", r);
    if (p1 != p2) {
        fprintf(stderr, "FAIL: string dedup gave different ptr\n");
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* LFAC.2.5.1 — exact equality dedup on a Bool key slot. */
static int test_lfac_2_5_1__bool_exact_equality_dedup(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *s = NULL;
    if (new_engine(&e)) return 1;
    if (load_one_slot(e, "S", "schema S scope logical:\n    v: Bool key\n", &s))
        return 1;
    ds_slot_value_t v[] = { { .kind = DS_SLOT_BOOL, .v.b = true } };
    ds_fact_t *p1 = NULL, *p2 = NULL;
    ds_result_t r = ds_engine_assert(e, s, v, 1, &p1);
    EXPECT_OK("assert 1", r);
    r = ds_engine_assert(e, s, v, 1, &p2);
    EXPECT_OK("assert 2 (dedup)", r);
    if (p1 != p2) {
        fprintf(stderr, "FAIL: bool dedup gave different ptr\n"); return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* LFAC.2.5.1 — with no tolerance, a Float key slot compares by exact
   equality, so a distinct float is a distinct fact. */
static int test_lfac_2_5_1__float_exact_equality_dedup_default(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *s = NULL;
    if (new_engine(&e)) return 1;
    if (load_one_slot(e, "S", "schema S scope logical:\n    v: Float key\n", &s))
        return 1;
    ds_slot_value_t v[] = { { .kind = DS_SLOT_FLOAT, .v.f = 3.14 } };
    ds_fact_t *p1 = NULL, *p2 = NULL;
    ds_result_t r = ds_engine_assert(e, s, v, 1, &p1);
    EXPECT_OK("assert 1", r);
    r = ds_engine_assert(e, s, v, 1, &p2);
    EXPECT_OK("assert 2 (dedup)", r);
    if (p1 != p2) {
        fprintf(stderr, "FAIL: float dedup gave different ptr\n"); return 1;
    }
    /* Distinct floats are distinct facts. */
    ds_slot_value_t v2[] = { { .kind = DS_SLOT_FLOAT, .v.f = 3.15 } };
    ds_fact_t *p3 = NULL;
    r = ds_engine_assert(e, s, v2, 1, &p3);
    EXPECT_OK("assert distinct float", r);
    if (p1 == p3) {
        fprintf(stderr, "FAIL: distinct float gave same ptr\n"); return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* ============== Driver ============== */

int main(void)
{
    int failed = 0;
    failed |= test_lfac_1_1__schema_declares_logical();
    failed |= test_lfac_1_1__schema_declares_ttl();
    failed |= test_lfac_1_2_2__logical_distinct_values_distinct_facts();
    failed |= test_lfac_1_3_3__ttl_expires_at_deadline();
    failed |= test_lfac_2_5_1__int_exact_equality_dedup();
    failed |= test_lfac_2_5_1__string_exact_equality_dedup();
    failed |= test_lfac_2_5_1__bool_exact_equality_dedup();
    failed |= test_lfac_2_5_1__float_exact_equality_dedup_default();
    if (!failed) printf("test_lfac_spec: OK\n");
    return failed;
}
