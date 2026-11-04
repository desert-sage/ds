/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * Slot values on the ds_engine_assert path, black-box through libds.h:
 *   IDAT.4.6.1 — ds_slot_value_t is a tagged union. A value whose kind
 *                matches its slot round-trips through dedup: the same value
 *                is the same fact, a distinct one a new fact. Any other kind
 *                is refused, with no conversion, by wm_validate_assert_values
 *                before the Rete bridge.
 *   IDAT.4.6.2 — at a Json leaf the runtime kind is the decoded value's,
 *                checked through the ds_json_t accessors.
 */
#include "spec_common.h"

/* ============== Per-scenario fixture ============== */

static int new_engine(ds_engine_t **out)
{
    ds_engine_t *e = NULL;
    ds_result_t r = ds_engine_new(NULL, &e);
    if (r.status != DS_OK) return spec_fail("engine_new", r);
    *out = e;
    return 0;
}

/* DS-source type keyword for a one-slot schema. */
static const char *ds_type_name(ds_slot_type_t t)
{
    switch (t) {
    case DS_SLOT_TYPE_INT:    return "Int";
    case DS_SLOT_TYPE_FLOAT:  return "Float";
    case DS_SLOT_TYPE_STRING: return "String";
    case DS_SLOT_TYPE_BOOL:   return "Bool";
    case DS_SLOT_TYPE_JSON:   return "Json";
    default:                  return NULL;
    }
}

/* Load a one-slot logical schema `name` whose key slot `v` has `type`, and
   resolve it. */
static int register_one_slot(ds_engine_t       *e,
                             const char         *name,
                             ds_slot_type_t      type,
                             const ds_schema_t **out)
{
    const char *tn = ds_type_name(type);
    if (tn == NULL) {
        fprintf(stderr, "FAIL: register_one_slot: unmapped type %d\n",
                (int) type);
        return 1;
    }
    char src[160];
    int n = snprintf(src, sizeof(src),
                     "schema %s scope logical:\n    v: %s key\n", name, tn);
    if (n < 0 || (size_t) n >= sizeof(src)) {
        fprintf(stderr, "FAIL: schema src too large\n"); return 1;
    }
    ds_result_t r = spec_load_ds(e, src);
    if (r.status != DS_OK) return spec_fail("spec_load_ds one-slot", r);
    r = ds_engine_schema_find(e, name, out);
    if (r.status != DS_OK || *out == NULL) return spec_fail("schema_find", r);
    return 0;
}

/* The schema the rejection tests assert into. */
static int register_one_slot_dswm(ds_engine_t       *e,
                                  const char         *name,
                                  ds_slot_type_t      type,
                                  const ds_schema_t **out)
{
    return register_one_slot(e, name, type, out);
}

/* ============== IDAT.4.6.1 round-trip scenarios ==============
 * Each round-trip:
 *   1. Assert with matching kind → DS_OK; ptr1 captured.
 *   2. Re-assert with same value → DS_OK; ptr2 == ptr1, the no-op
 *      reassertion of IDAT.4.4.
 *   3. Assert with a different value → DS_OK; new ptr ≠ ptr1. */
static int round_trip_check(ds_engine_t       *e,
                            const ds_schema_t *schema,
                            ds_slot_value_t   *vsame,
                            uint32_t           n_same,
                            ds_slot_value_t   *vdiff,
                            uint32_t           n_diff,
                            const char        *what)
{
    ds_fact_t *p1 = NULL, *p2 = NULL, *p3 = NULL;
    ds_result_t r = ds_engine_assert(e, schema, vsame, n_same, &p1);
    if (r.status != DS_OK) return spec_fail(what, r);
    r = ds_engine_assert(e, schema, vsame, n_same, &p2);
    if (r.status != DS_OK) return spec_fail("dedupe assert", r);
    if (p1 != p2) {
        fprintf(stderr,
                "FAIL: %s — same-value reassert different ptr\n", what);
        return 1;
    }
    r = ds_engine_assert(e, schema, vdiff, n_diff, &p3);
    if (r.status != DS_OK) return spec_fail("distinct assert", r);
    if (p1 == p3) {
        fprintf(stderr,
                "FAIL: %s — distinct value did not produce new fact\n",
                what);
        return 1;
    }
    return 0;
}

/* IDAT.4.6.1 — INT slot accepts DS_SLOT_INT values. */
static int test_idat_4_6_1__int_slot_round_trip(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    const ds_schema_t *s = NULL;
    if (register_one_slot(e, "I", DS_SLOT_TYPE_INT, &s)) return 1;
    ds_slot_value_t same[] = { { .kind = DS_SLOT_INT, .v.i = 42 } };
    ds_slot_value_t diff[] = { { .kind = DS_SLOT_INT, .v.i = 43 } };
    if (round_trip_check(e, s, same, 1, diff, 1, "int round-trip")) return 1;
    ds_engine_free(e);
    return 0;
}

/* IDAT.4.6.1 — FLOAT slot accepts DS_SLOT_FLOAT values. */
static int test_idat_4_6_1__float_slot_round_trip(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    const ds_schema_t *s = NULL;
    if (register_one_slot(e, "F", DS_SLOT_TYPE_FLOAT, &s)) return 1;
    ds_slot_value_t same[] = { { .kind = DS_SLOT_FLOAT, .v.f = 3.14 } };
    ds_slot_value_t diff[] = { { .kind = DS_SLOT_FLOAT, .v.f = 2.71 } };
    if (round_trip_check(e, s, same, 1, diff, 1, "float round-trip")) return 1;
    ds_engine_free(e);
    return 0;
}

/* IDAT.4.6.1 — STRING slot accepts DS_SLOT_STRING values. */
static int test_idat_4_6_1__string_slot_round_trip(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    const ds_schema_t *s = NULL;
    if (register_one_slot(e, "S", DS_SLOT_TYPE_STRING, &s)) return 1;
    ds_slot_value_t same[] = { { .kind = DS_SLOT_STRING, .v.s = "alpha" } };
    ds_slot_value_t diff[] = { { .kind = DS_SLOT_STRING, .v.s = "beta"  } };
    if (round_trip_check(e, s, same, 1, diff, 1, "string round-trip")) return 1;
    ds_engine_free(e);
    return 0;
}

/* IDAT.4.6.1 — BOOL slot accepts DS_SLOT_BOOL values; both true and
   false round-trip. */
static int test_idat_4_6_1__bool_slot_round_trip(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    const ds_schema_t *s = NULL;
    if (register_one_slot(e, "B", DS_SLOT_TYPE_BOOL, &s)) return 1;
    ds_slot_value_t same[] = { { .kind = DS_SLOT_BOOL, .v.b = true  } };
    ds_slot_value_t diff[] = { { .kind = DS_SLOT_BOOL, .v.b = false } };
    if (round_trip_check(e, s, same, 1, diff, 1, "bool round-trip")) return 1;
    ds_engine_free(e);
    return 0;
}

/* IDAT.4.6.2 — at a Json leaf the runtime kind is the decoded value's: one
   parsed document carries a leaf of every kind, and ds_json_get_path reports
   each. No engine. */
static int test_idat_4_6_2__json_leaf_runtime_kinds(void)
{
    const char *text =
        "{\"i\":42,"
        " \"f\":3.5,"
        " \"s\":\"hi\","
        " \"b\":true,"
        " \"n\":null,"
        " \"a\":[1,2,3],"
        " \"o\":{\"k\":1}}";
    ds_json_t *tree = NULL;
    ds_result_t r = ds_json_parse(text, strlen(text), &tree);
    EXPECT_OK("parse", r);
    ds_json_kind_t rootk = DS_JSON_NULL;
    if (tree == NULL || ds_json_get_kind(tree, &rootk).status != DS_OK ||
        rootk != DS_JSON_OBJECT) {
        fprintf(stderr, "FAIL: root not OBJECT\n"); return 1;
    }
    struct { const char *path; ds_json_kind_t want; } cases[] = {
        { "i", DS_JSON_INT    },
        { "f", DS_JSON_FLOAT  },
        { "s", DS_JSON_STRING },
        { "b", DS_JSON_BOOL   },
        { "n", DS_JSON_NULL   },
        { "a", DS_JSON_ARRAY  },
        { "o", DS_JSON_OBJECT },
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        const ds_json_t *leaf = NULL;
        r = ds_json_get_path(tree, cases[i].path, &leaf);
        EXPECT_OK("get_path", r);
        if (leaf == NULL) {
            fprintf(stderr, "FAIL: path \"%s\" missing\n", cases[i].path);
            return 1;
        }
        ds_json_kind_t lk = DS_JSON_NULL;
        if (ds_json_get_kind(leaf, &lk).status != DS_OK || lk != cases[i].want) {
            fprintf(stderr,
                    "FAIL: path \"%s\" kind=%d, want %d\n",
                    cases[i].path, (int) lk, (int) cases[i].want);
            return 1;
        }
    }
    /* Specific deeper traversal: a[0] is INT; o.k is INT. */
    const ds_json_t *a0 = NULL, *ok = NULL;
    r = ds_json_get_path(tree, "a[0]", &a0); EXPECT_OK("a[0]", r);
    r = ds_json_get_path(tree, "o.k",  &ok); EXPECT_OK("o.k",  r);
    ds_json_kind_t ak = DS_JSON_NULL, okk = DS_JSON_NULL;
    if (!a0 || ds_json_get_kind(a0, &ak).status != DS_OK || ak != DS_JSON_INT) {
        fprintf(stderr, "FAIL: a[0] kind\n"); return 1;
    }
    if (!ok || ds_json_get_kind(ok, &okk).status != DS_OK || okk != DS_JSON_INT) {
        fprintf(stderr, "FAIL: o.k kind\n"); return 1;
    }
    ds_json_free(tree);
    return 0;
}

/* ============== IDAT.4.6.1 — kind-mismatch rejection ==============
 * The value's `kind` must match the slot's declared type exactly; there is
 * no implicit conversion, Int to Float included. */

static int test_idat_4_6_1__int_slot_rejects_other_kinds(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    const ds_schema_t *s = NULL;
    if (register_one_slot_dswm(e, "I", DS_SLOT_TYPE_INT, &s)) return 1;
    /* No implicit numeric promotion: FLOAT kind is rejected. */
    ds_slot_value_t bad[] = { { .kind = DS_SLOT_FLOAT, .v.f = 0.5 } };
    ds_result_t r = ds_engine_assert(e, s, bad, 1, NULL);
    EXPECT_STATUS("int slot vs float kind", r, DS_ERR_SLOT_TYPE_MISMATCH);
    ds_engine_free(e);
    return 0;
}

static int test_idat_4_6_1__float_slot_rejects_other_kinds(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    const ds_schema_t *s = NULL;
    if (register_one_slot_dswm(e, "F", DS_SLOT_TYPE_FLOAT, &s)) return 1;
    /* INT kind for FLOAT slot — no implicit widening. */
    ds_slot_value_t bad[] = { { .kind = DS_SLOT_INT, .v.i = 7 } };
    ds_result_t r = ds_engine_assert(e, s, bad, 1, NULL);
    EXPECT_STATUS("float slot vs int kind", r, DS_ERR_SLOT_TYPE_MISMATCH);
    ds_engine_free(e);
    return 0;
}

static int test_idat_4_6_1__string_slot_rejects_other_kinds(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    const ds_schema_t *s = NULL;
    if (register_one_slot_dswm(e, "S", DS_SLOT_TYPE_STRING, &s)) return 1;
    ds_slot_value_t bad[] = { { .kind = DS_SLOT_INT, .v.i = 42 } };
    ds_result_t r = ds_engine_assert(e, s, bad, 1, NULL);
    EXPECT_STATUS("string slot vs int kind", r, DS_ERR_SLOT_TYPE_MISMATCH);
    ds_engine_free(e);
    return 0;
}

static int test_idat_4_6_1__bool_slot_rejects_other_kinds(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    const ds_schema_t *s = NULL;
    if (register_one_slot_dswm(e, "B", DS_SLOT_TYPE_BOOL, &s)) return 1;
    /* INT kind (e.g., 0/1) does not coerce to BOOL. */
    ds_slot_value_t bad[] = { { .kind = DS_SLOT_INT, .v.i = 1 } };
    ds_result_t r = ds_engine_assert(e, s, bad, 1, NULL);
    EXPECT_STATUS("bool slot vs int kind", r, DS_ERR_SLOT_TYPE_MISMATCH);
    ds_engine_free(e);
    return 0;
}

static int test_idat_4_6_1__json_slot_rejects_other_kinds(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    const ds_schema_t *s = NULL;
    if (register_one_slot_dswm(e, "J", DS_SLOT_TYPE_JSON, &s)) return 1;
    /* STRING kind (JSON-text) is not enough — the runtime kind must be
       DS_SLOT_JSON with a parsed tree. */
    ds_slot_value_t bad[] = { { .kind = DS_SLOT_STRING, .v.s = "{}" } };
    ds_result_t r = ds_engine_assert(e, s, bad, 1, NULL);
    EXPECT_STATUS("json slot vs string kind", r, DS_ERR_SLOT_TYPE_MISMATCH);
    ds_engine_free(e);
    return 0;
}

/* IDAT.4.6.1 — SCHEMA slot rejects non-FACT_REF kinds. */
static int test_idat_4_6_1__schema_slot_rejects_other_kinds(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    /* `ref` is a schema-typed slot ([LGRA.5.7a.2]). The key slot `id` takes
       its Int; the Int handed to `ref` is the refusal. */
    ds_result_t r = spec_load_ds(e,
        "schema Inner scope logical:\n    v: Int key\n\n"
        "schema Outer scope logical:\n    id: Int key\n    ref: Inner mutable\n");
    EXPECT_OK("load schema-ref slot", r);
    const ds_schema_t *outer = NULL;
    r = ds_engine_schema_find(e, "Outer", &outer);
    EXPECT_OK("find Outer", r);
    ds_slot_value_t int_in_schema_slot[] = {
        { .kind = DS_SLOT_INT, .v.i = 1 },
        { .kind = DS_SLOT_INT, .v.i = 7 },
    };
    r = ds_engine_assert(e, outer, int_in_schema_slot, 2, NULL);
    EXPECT_STATUS("int rejected for schema slot", r, DS_ERR_SLOT_TYPE_MISMATCH);
    ds_engine_free(e);
    return 0;
}

/* IDAT.4.6.1 — STRING slot value pointer must not be NULL even though the
   kind matches. Caught at assert time as DS_ERR_INVAL. */
static int test_idat_4_6_1__string_slot_null_pointer_rejected(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    const ds_schema_t *s = NULL;
    if (register_one_slot_dswm(e, "S", DS_SLOT_TYPE_STRING, &s)) return 1;
    ds_slot_value_t bad[] = { { .kind = DS_SLOT_STRING, .v.s = NULL } };
    ds_result_t r = ds_engine_assert(e, s, bad, 1, NULL);
    EXPECT_STATUS("null string pointer", r, DS_ERR_INVAL);
    ds_engine_free(e);
    return 0;
}

/* IDAT.4.6.1 — JSON slot value pointer must not be NULL. */
static int test_idat_4_6_1__json_slot_null_tree_rejected(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    const ds_schema_t *s = NULL;
    if (register_one_slot_dswm(e, "J", DS_SLOT_TYPE_JSON, &s)) return 1;
    ds_slot_value_t bad[] = { { .kind = DS_SLOT_JSON, .v.json = NULL } };
    ds_result_t r = ds_engine_assert(e, s, bad, 1, NULL);
    EXPECT_STATUS("null json tree", r, DS_ERR_INVAL);
    ds_engine_free(e);
    return 0;
}

/* ============== Driver ============== */

int main(void)
{
    int failed = 0;
    failed |= test_idat_4_6_1__int_slot_round_trip();
    failed |= test_idat_4_6_1__float_slot_round_trip();
    failed |= test_idat_4_6_1__string_slot_round_trip();
    failed |= test_idat_4_6_1__bool_slot_round_trip();
    failed |= test_idat_4_6_2__json_leaf_runtime_kinds();
    failed |= test_idat_4_6_1__int_slot_rejects_other_kinds();
    failed |= test_idat_4_6_1__float_slot_rejects_other_kinds();
    failed |= test_idat_4_6_1__string_slot_rejects_other_kinds();
    failed |= test_idat_4_6_1__bool_slot_rejects_other_kinds();
    failed |= test_idat_4_6_1__json_slot_rejects_other_kinds();
    failed |= test_idat_4_6_1__schema_slot_rejects_other_kinds();
    failed |= test_idat_4_6_1__string_slot_null_pointer_rejected();
    failed |= test_idat_4_6_1__json_slot_null_tree_rejected();
    if (!failed) printf("test_slot_kinds_spec: OK\n");
    return failed;
}
