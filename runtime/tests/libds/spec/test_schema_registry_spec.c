/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The schema registry's read surface (IDAT.5, and IDAT.10.5's NULL checks),
 * black-box through libds.h. Every schema here is declared in DS source and
 * loaded with spec_load_ds, the integrator's path ([ISTS.2.3]).
 *   - Find by name returns the loaded schema's borrow; a miss is DS_OK with
 *     a NULL out (IDAT.5.2).
 *   - schema_count counts the declared schemas; find does not change it.
 *   - schema_at reaches each schema below the count, and the count itself
 *     is DS_ERR_NOT_FOUND (IDAT.5.5).
 *   - Per-engine registries are independent.
 *   - An engine holds one artefact: a second load after a successful one is
 *     refused, and the engine is unchanged ([NFCT.1.1]); a load after a
 *     failed one is refused, since the failed one spent the engine
 *     ([RDSC.9.8]).
 *   - NULL engine and NULL type_name are refused.
 */
#include "spec_common.h"

/* ============== Per-scenario fixtures ============== */

static int new_engine(ds_engine_t **out)
{
    ds_engine_t *e = NULL;
    ds_result_t r = ds_engine_new(NULL, &e);
    if (r.status != DS_OK) return spec_fail("engine_new", r);
    *out = e;
    return 0;
}

/* An engine loaded with an artefact declaring `src`'s schemas. */
static int load_engine(ds_engine_t **out, const char *src)
{
    if (new_engine(out)) return 1;
    ds_result_t r = spec_load_ds(*out, src);
    if (r.status != DS_OK) return spec_fail("spec_load_ds", r);
    return 0;
}

static const char ONE_SCHEMA[] =
    "schema A scope logical:\n    v: Int key\n";

static const char THREE_SCHEMAS[] =
    "schema A scope logical:\n    v: Int key\n\n"
    "schema B scope logical:\n    v: Int key\n\n"
    "schema C scope logical:\n    v: Int key\n";

/* ============== Scenarios ============== */

/* IDAT.5.2 — find by type_name returns the declared schema's borrow, and
   the same borrow on every lookup. */
static int test_idat_5_2__find_returns_declared_borrow(void)
{
    ds_engine_t *e = NULL; if (load_engine(&e, ONE_SCHEMA)) return 1;
    const ds_schema_t *first = NULL, *again = NULL;
    ds_result_t r = ds_engine_schema_find(e, "A", &first);
    EXPECT_OK("find", r);
    if (first == NULL) {
        fprintf(stderr, "FAIL: declared schema A not found\n"); return 1;
    }
    r = ds_engine_schema_find(e, "A", &again);
    EXPECT_OK("find again", r);
    if (again != first) {
        fprintf(stderr, "FAIL: find returned different pointers\n"); return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* IDAT.5.2 — lookup miss returns DS_OK with NULL out. Miss is not
   an error; the caller distinguishes hit vs miss by *out. */
static int test_idat_5_2__find_unknown_returns_null_with_ok(void)
{
    ds_engine_t *e = NULL; if (load_engine(&e, ONE_SCHEMA)) return 1;
    const ds_schema_t *found = (const ds_schema_t *) 0xDEADBEEF;
    ds_result_t r = ds_engine_schema_find(e, "Nope", &found);
    EXPECT_OK("find unknown", r);
    if (found != NULL) {
        fprintf(stderr, "FAIL: miss left out=%p\n", (const void *) found);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* IDAT.5.2 — schema_count counts the declared schemas: an artefact
   declaring three holds two more than one declaring one, whatever schemas
   every artefact carries besides. Find does not change the count. */
static int test_idat_5_2__count_reflects_declared(void)
{
    ds_engine_t *one = NULL, *three = NULL;
    if (load_engine(&one, ONE_SCHEMA)) return 1;
    if (load_engine(&three, THREE_SCHEMAS)) return 1;
    size_t c1 = 0, c3 = 0;
    ds_result_t r = ds_engine_schema_count(one, &c1);
    EXPECT_OK("count one", r);
    r = ds_engine_schema_count(three, &c3);
    EXPECT_OK("count three", r);
    if (c3 != c1 + 2) {
        fprintf(stderr, "FAIL: count=%zu with three schemas, %zu with one\n",
                c3, c1);
        return 1;
    }
    /* Find — both hit and miss — must not change count. */
    const ds_schema_t *out = NULL;
    r = ds_engine_schema_find(three, "B", &out);  EXPECT_OK("hit", r);
    r = ds_engine_schema_find(three, "Z", &out);  EXPECT_OK("miss", r);
    size_t after = 0;
    r = ds_engine_schema_count(three, &after);
    EXPECT_OK("count after finds", r);
    if (after != c3) {
        fprintf(stderr, "FAIL: count after finds=%zu, before %zu\n",
                after, c3);
        return 1;
    }
    ds_engine_free(one);
    ds_engine_free(three);
    return 0;
}

/* IDAT.5 / IARC — registries are per-engine. A schema loaded into engine A
   is invisible to engine B, and B's do not affect A: no global schema
   state. */
static int test_idat_5__multiple_engines_independent_registries(void)
{
    ds_engine_t *a = NULL, *b = NULL;
    if (load_engine(&a, "schema OnlyInA scope logical:\n    v: Int key\n"))
        return 1;
    if (load_engine(&b, "schema OnlyInB scope logical:\n    v: Int key\n"))
        return 1;
    const ds_schema_t *out = NULL;
    ds_result_t r = ds_engine_schema_find(a, "OnlyInB", &out);
    EXPECT_OK("a find b", r);
    if (out != NULL) {
        fprintf(stderr, "FAIL: engine A saw engine B's schema\n"); return 1;
    }
    r = ds_engine_schema_find(b, "OnlyInA", &out);
    EXPECT_OK("b find a", r);
    if (out != NULL) {
        fprintf(stderr, "FAIL: engine B saw engine A's schema\n"); return 1;
    }
    r = ds_engine_schema_find(a, "OnlyInA", &out);
    EXPECT_OK("a find a", r);
    if (out == NULL) {
        fprintf(stderr, "FAIL: engine A lost its own schema\n"); return 1;
    }
    ds_engine_free(a);
    ds_engine_free(b);
    return 0;
}

/* The most schemas the schema_at scenarios hold: the three declared, and
   whatever schemas every artefact carries besides. */
#define MAX_SCHEMAS 256

/* IDAT.5.5 — each index below schema_count reaches a schema through
   ds_engine_schema_at: DS_OK and a schema at every index, no schema at two
   indices, and the three the artefact declares among them. */
static int test_idat_5_5__schema_at_below_count_reaches_each_schema(void)
{
    ds_engine_t *e = NULL; if (load_engine(&e, THREE_SCHEMAS)) return 1;
    size_t n = 0;
    ds_result_t r = ds_engine_schema_count(e, &n);
    EXPECT_OK("count", r);
    if (n < 3 || n > MAX_SCHEMAS) {
        fprintf(stderr, "FAIL: count=%zu with three schemas declared\n", n);
        return 1;
    }
    const ds_schema_t *at[MAX_SCHEMAS];
    for (size_t i = 0; i < n; i++) {
        at[i] = NULL;
        r = ds_engine_schema_at(e, i, &at[i]);
        EXPECT_OK("schema_at below count", r);
        if (at[i] == NULL) {
            fprintf(stderr, "FAIL: schema_at(%zu) gave no schema\n", i);
            return 1;
        }
        for (size_t j = 0; j < i; j++) {
            if (at[j] == at[i]) {
                fprintf(stderr, "FAIL: schema_at(%zu) and (%zu) are one schema\n",
                        j, i);
                return 1;
            }
        }
    }
    static const char *const declared[] = { "A", "B", "C" };
    for (size_t k = 0; k < 3; k++) {
        const ds_schema_t *found = NULL;
        r = ds_engine_schema_find(e, declared[k], &found);
        EXPECT_OK("find declared", r);
        size_t i = 0;
        while (i < n && at[i] != found) i++;
        if (found == NULL || i == n) {
            fprintf(stderr, "FAIL: schema %s is at no index below %zu\n",
                    declared[k], n);
            return 1;
        }
    }
    ds_engine_free(e);
    return 0;
}

/* IDAT.5.5 — the index equal to schema_count, and any past it, is
   DS_ERR_NOT_FOUND. */
static int test_idat_5_5__schema_at_count_is_not_found(void)
{
    ds_engine_t *e = NULL; if (load_engine(&e, THREE_SCHEMAS)) return 1;
    size_t n = 0;
    ds_result_t r = ds_engine_schema_count(e, &n);
    EXPECT_OK("count", r);
    const ds_schema_t *out = NULL;
    r = ds_engine_schema_at(e, n, &out);
    EXPECT_STATUS("schema_at(count)", r, DS_ERR_NOT_FOUND);
    r = ds_engine_schema_at(e, n + 1, &out);
    EXPECT_STATUS("schema_at(count + 1)", r, DS_ERR_NOT_FOUND);
    r = ds_engine_schema_at(e, SIZE_MAX, &out);
    EXPECT_STATUS("schema_at(SIZE_MAX)", r, DS_ERR_NOT_FOUND);
    ds_engine_free(e);
    return 0;
}

/* NFCT.1.1 — an engine holds one artefact. A second ds_engine_load_dsc after
   a successful one is DS_ERR_STATE, and the engine is as the first load left
   it: the second artefact's schema is not there, the first's is the same
   borrow, the count has not moved. Twice: an artefact declaring a schema the
   engine does not hold, so the refusal cannot be a duplicate check's, and the
   same artefact again. */
/* @spec [NFCT.1.1] */
static int test_nfct_1_1__second_load_refused(void)
{
    ds_engine_t *e = NULL; if (load_engine(&e, ONE_SCHEMA)) return 1;
    const ds_schema_t *a = NULL;
    ds_result_t r = ds_engine_schema_find(e, "A", &a);
    EXPECT_OK("find A", r);
    size_t before = 0;
    r = ds_engine_schema_count(e, &before);
    EXPECT_OK("count before", r);

    r = spec_load_ds(e, "schema B scope logical:\n    v: Int key\n");
    EXPECT_STATUS("second load, another schema", r, DS_ERR_STATE);
    r = spec_load_ds(e, ONE_SCHEMA);
    EXPECT_STATUS("second load, the same artefact", r, DS_ERR_STATE);

    const ds_schema_t *out = NULL;
    r = ds_engine_schema_find(e, "B", &out);
    EXPECT_OK("find B", r);
    if (out != NULL) {
        fprintf(stderr, "FAIL: a refused load registered B\n"); return 1;
    }
    r = ds_engine_schema_find(e, "A", &out);
    EXPECT_OK("find A after", r);
    if (out != a) {
        fprintf(stderr, "FAIL: A's borrow changed across a refused load\n");
        return 1;
    }
    size_t after = 0;
    r = ds_engine_schema_count(e, &after);
    EXPECT_OK("count after", r);
    if (after != before) {
        fprintf(stderr, "FAIL: count %zu after refused loads, %zu before\n",
                after, before);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* NFCT.1.1 / RDSC.9.8 — a failed load spends the engine, so that engine
   takes no other load: a good load after it is refused with
   DS_ERR_ENGINE_HALTED, and so is the schema read that would show what it
   registered. The bad bytes are no artefact at all (no DscHeader), so the
   loader refuses them whatever else it checks. CONTROL: the good artefact
   loads on an engine of its own, so the refusal is the spent engine's. */
/* @spec [NFCT.1.1] */
static int test_nfct_1_1__load_after_failed_load_refused(void)
{
    ds_engine_t *ctl = NULL; if (load_engine(&ctl, ONE_SCHEMA)) return 1;
    ds_engine_free(ctl);

    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    static const uint8_t junk[] = { 0x00, 0x01, 0x02, 0x03 };
    ds_result_t r = ds_engine_load_dsc(e, junk, sizeof junk);
    if (r.status == DS_OK) {
        fprintf(stderr, "FAIL: junk bytes loaded\n"); return 1;
    }
    r = spec_load_ds(e, ONE_SCHEMA);
    EXPECT_STATUS("load after a failed load", r, DS_ERR_ENGINE_HALTED);
    const ds_schema_t *a = NULL;
    r = ds_engine_schema_find(e, "A", &a);
    EXPECT_STATUS("find A on the spent engine", r, DS_ERR_ENGINE_HALTED);
    ds_engine_free(e);
    return 0;
}

/* IDAT.10.5 — NULL engine rejected on every public schema read. */
static int test_idat_10_5__null_engine_rejected(void)
{
    const ds_schema_t *out = NULL;
    ds_result_t r = ds_engine_schema_find(NULL, "X", &out);
    EXPECT_STATUS("find null engine", r, DS_ERR_INVAL);
    size_t c = 0;
    r = ds_engine_schema_count(NULL, &c);
    EXPECT_STATUS("count null engine", r, DS_ERR_INVAL);
    r = ds_engine_schema_at(NULL, 0, &out);
    EXPECT_STATUS("schema_at null engine", r, DS_ERR_INVAL);
    return 0;
}

/* IDAT.10.5 — NULL type_name rejected on find. */
static int test_idat_10_5__null_type_name_rejected(void)
{
    ds_engine_t *e = NULL; if (load_engine(&e, ONE_SCHEMA)) return 1;
    const ds_schema_t *out = NULL;
    ds_result_t r = ds_engine_schema_find(e, NULL, &out);
    EXPECT_STATUS("find null name", r, DS_ERR_INVAL);
    ds_engine_free(e);
    return 0;
}

/* ============== Driver ============== */

int main(void)
{
    int failed = 0;
    failed |= test_idat_5_2__find_returns_declared_borrow();
    failed |= test_idat_5_2__find_unknown_returns_null_with_ok();
    failed |= test_idat_5_2__count_reflects_declared();
    failed |= test_idat_5__multiple_engines_independent_registries();
    failed |= test_idat_5_5__schema_at_below_count_reaches_each_schema();
    failed |= test_idat_5_5__schema_at_count_is_not_found();
    failed |= test_nfct_1_1__second_load_refused();
    failed |= test_nfct_1_1__load_after_failed_load_refused();
    failed |= test_idat_10_5__null_engine_rejected();
    failed |= test_idat_10_5__null_type_name_rejected();
    if (!failed) printf("test_schema_registry_spec: OK\n");
    return failed;
}
