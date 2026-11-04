/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The ds_json read and build API, black-box through libds.h: the accessors
 * (including array_len/at and object_len/get/at), the builders' ownership,
 * transfer and replace contract, and the strict-kind errors.
 *
 * Every owned tree and serialized buffer is freed, so the valgrind lane
 * checks the ownership contract (transfer on success, not consumed on error,
 * replace frees the old value) leaks nothing.
 */
#include <float.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"

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

/* ---- read accessors over a parsed tree ---- */
static int test_reads(void)
{
    const char *text =
        "{\"id\": 7, \"name\": \"hi\", \"vals\": [10, 20, 30], "
        "\"flag\": true, \"ratio\": 1.5, \"nil\": null}";
    ds_json_t *t = NULL;
    if (expect_ok("parse", ds_json_parse(text, strlen(text), &t))) return 1;

    ds_json_kind_t k;
    if (expect_ok("get_kind root", ds_json_get_kind(t, &k))) return 1;
    if (k != DS_JSON_OBJECT) { fprintf(stderr, "FAIL: root kind\n"); return 1; }

    size_t olen = 0;
    if (expect_ok("object_len", ds_json_object_len(t, &olen))) return 1;
    if (olen != 6) { fprintf(stderr, "FAIL: object_len %zu != 6\n", olen); return 1; }

    /* object_get + strict scalar getters */
    const ds_json_t *id = NULL;
    if (expect_ok("object_get id", ds_json_object_get(t, "id", &id))) return 1;
    int64_t iv = 0;
    if (expect_ok("get_int id", ds_json_get_int(id, &iv))) return 1;
    if (iv != 7) { fprintf(stderr, "FAIL: id %lld\n", (long long) iv); return 1; }

    const ds_json_t *name = NULL;
    if (expect_ok("object_get name", ds_json_object_get(t, "name", &name))) return 1;
    const char *sv = NULL; size_t slen = 0;
    if (expect_ok("get_string name", ds_json_get_string(name, &sv, &slen))) return 1;
    if (slen != 2 || strcmp(sv, "hi") != 0) {
        fprintf(stderr, "FAIL: name '%s' len %zu\n", sv, slen); return 1;
    }
    /* out_len may be NULL */
    if (expect_ok("get_string name (null len)",
                  ds_json_get_string(name, &sv, NULL))) return 1;

    const ds_json_t *flag = NULL;
    if (expect_ok("object_get flag", ds_json_object_get(t, "flag", &flag))) return 1;
    bool bv = false;
    if (expect_ok("get_bool flag", ds_json_get_bool(flag, &bv))) return 1;
    if (bv != true) { fprintf(stderr, "FAIL: flag\n"); return 1; }

    const ds_json_t *ratio = NULL;
    if (expect_ok("object_get ratio", ds_json_object_get(t, "ratio", &ratio))) return 1;
    double fv = 0;
    if (expect_ok("get_float ratio", ds_json_get_float(ratio, &fv))) return 1;
    if (fv < 1.49 || fv > 1.51) { fprintf(stderr, "FAIL: ratio %g\n", fv); return 1; }

    const ds_json_t *nil = NULL;
    if (expect_ok("object_get nil", ds_json_object_get(t, "nil", &nil))) return 1;
    if (expect_ok("get_kind nil", ds_json_get_kind(nil, &k))) return 1;
    if (k != DS_JSON_NULL) { fprintf(stderr, "FAIL: nil kind\n"); return 1; }

    /* array_len / array_at + out-of-range NOT_FOUND */
    const ds_json_t *vals = NULL;
    if (expect_ok("object_get vals", ds_json_object_get(t, "vals", &vals))) return 1;
    size_t alen = 0;
    if (expect_ok("array_len", ds_json_array_len(vals, &alen))) return 1;
    if (alen != 3) { fprintf(stderr, "FAIL: array_len %zu\n", alen); return 1; }
    const ds_json_t *el = NULL;
    if (expect_ok("array_at 1", ds_json_array_at(vals, 1, &el))) return 1;
    if (expect_ok("get_int vals[1]", ds_json_get_int(el, &iv)) || iv != 20) {
        fprintf(stderr, "FAIL: vals[1] %lld\n", (long long) iv); return 1;
    }
    if (expect_status("array_at OOR", ds_json_array_at(vals, 3, &el),
                      DS_ERR_NOT_FOUND)) return 1;

    /* object_get miss → NOT_FOUND (distinct from get_path's DS_OK+NULL) */
    const ds_json_t *absent = NULL;
    if (expect_status("object_get absent",
                      ds_json_object_get(t, "absent", &absent),
                      DS_ERR_NOT_FOUND)) return 1;
    const ds_json_t *pathmiss = NULL;
    if (expect_ok("get_path miss is soft",
                  ds_json_get_path(t, "absent", &pathmiss))) return 1;
    if (pathmiss != NULL) { fprintf(stderr, "FAIL: path miss not NULL\n"); return 1; }

    /* object_at positional iteration — collect keys, any out-ptr may be NULL */
    int seen_id = 0, seen_vals = 0;
    for (size_t i = 0; i < olen; i++) {
        const char *key = NULL; size_t klen = 0; const ds_json_t *val = NULL;
        if (expect_ok("object_at", ds_json_object_at(t, i, &key, &klen, &val)))
            return 1;
        if (key == NULL || val == NULL) {
            fprintf(stderr, "FAIL: object_at borrows null\n"); return 1;
        }
        if (klen != strlen(key)) { fprintf(stderr, "FAIL: key_len\n"); return 1; }
        if (strcmp(key, "id") == 0)   seen_id = 1;
        if (strcmp(key, "vals") == 0) seen_vals = 1;
    }
    if (!seen_id || !seen_vals) { fprintf(stderr, "FAIL: iteration coverage\n"); return 1; }
    /* all out-ptrs NULL is allowed */
    if (expect_ok("object_at all-null-out",
                  ds_json_object_at(t, 0, NULL, NULL, NULL))) return 1;
    if (expect_status("object_at OOR",
                      ds_json_object_at(t, olen, NULL, NULL, NULL),
                      DS_ERR_NOT_FOUND)) return 1;

    ds_json_free(t);
    return 0;
}

/* ---- strict-kind + NULL-arg errors ---- */
static int test_strict_errors(void)
{
    ds_json_t *s = NULL, *i = NULL;
    if (expect_ok("new_string", ds_json_new_string("x", 1, &s))) return 1;
    if (expect_ok("new_int", ds_json_new_int(5, &i))) return 1;

    int64_t iv; bool bv; const char *sv; double fv;
    /* get_int on a STRING → INVAL, detail names actual (string) + requested (int) */
    ds_result_t r = ds_json_get_int(s, &iv);
    if (expect_status("get_int on string", r, DS_ERR_INVAL)) return 1;
    if (r.detail == NULL || strstr(r.detail, "string") == NULL ||
        strstr(r.detail, "int") == NULL) {
        fprintf(stderr, "FAIL: mismatch detail '%s' should name actual+requested\n",
                r.detail ? r.detail : "(null)"); return 1;
    }
    if (expect_status("get_string on int",
                      ds_json_get_string(i, &sv, NULL), DS_ERR_INVAL)) return 1;
    if (expect_status("get_bool on int",
                      ds_json_get_bool(i, &bv), DS_ERR_INVAL)) return 1;
    if (expect_status("get_float on int",
                      ds_json_get_float(i, &fv), DS_ERR_INVAL)) return 1;
    if (expect_status("array_len on int",
                      ds_json_array_len(i, (size_t *) &iv), DS_ERR_INVAL)) return 1;

    /* NULL-arg rejection */
    ds_json_kind_t k;
    if (expect_status("get_kind NULL node",
                      ds_json_get_kind(NULL, &k), DS_ERR_INVAL)) return 1;
    if (expect_status("get_int NULL out",
                      ds_json_get_int(i, NULL), DS_ERR_INVAL)) return 1;

    ds_json_free(s);
    ds_json_free(i);
    return 0;
}

/* ---- builders + ownership/transfer/replace ---- */
static int test_build(void)
{
    char *text = NULL; size_t tlen = 0;

    /* {"n":3} */
    ds_json_t *obj = NULL, *n = NULL;
    if (expect_ok("new_object", ds_json_new_object(&obj))) return 1;
    if (expect_ok("new_int", ds_json_new_int(3, &n))) return 1;
    if (expect_ok("object_set n", ds_json_object_set(obj, "n", 1, n))) return 1;
    /* obj now owns n */
    if (expect_ok("serialize obj", ds_json_serialize(obj, &text, &tlen))) return 1;
    if (strcmp(text, "{\"n\":3}") != 0) {
        fprintf(stderr, "FAIL: built obj serialized '%s'\n", text); return 1;
    }
    ds_free(text); text = NULL;

    /* replace: object_set same key → one value per key, old value freed */
    ds_json_t *n2 = NULL;
    if (expect_ok("new_int 9", ds_json_new_int(9, &n2))) return 1;
    if (expect_ok("object_set replace", ds_json_object_set(obj, "n", 1, n2))) return 1;
    size_t olen = 0;
    if (expect_ok("object_len after replace", ds_json_object_len(obj, &olen))) return 1;
    if (olen != 1) { fprintf(stderr, "FAIL: replace grew object to %zu\n", olen); return 1; }
    if (expect_ok("serialize replaced", ds_json_serialize(obj, &text, &tlen))) return 1;
    if (strcmp(text, "{\"n\":9}") != 0) {
        fprintf(stderr, "FAIL: replace serialized '%s'\n", text); return 1;
    }
    ds_free(text); text = NULL;
    ds_json_free(obj);

    /* array append: [1,2,3] */
    ds_json_t *arr = NULL;
    if (expect_ok("new_array", ds_json_new_array(&arr))) return 1;
    for (int v = 1; v <= 3; v++) {
        ds_json_t *e = NULL;
        if (expect_ok("new_int elem", ds_json_new_int(v, &e))) return 1;
        if (expect_ok("array_append", ds_json_array_append(arr, e))) return 1;
    }
    size_t alen = 0;
    if (expect_ok("array_len built", ds_json_array_len(arr, &alen))) return 1;
    if (alen != 3) { fprintf(stderr, "FAIL: built array_len %zu\n", alen); return 1; }
    if (expect_ok("serialize arr", ds_json_serialize(arr, &text, &tlen))) return 1;
    if (strcmp(text, "[1,2,3]") != 0) {
        fprintf(stderr, "FAIL: built arr '%s'\n", text); return 1;
    }
    ds_free(text); text = NULL;
    ds_json_free(arr);

    /* transfer-on-error: wrong-kind container does NOT consume the child */
    ds_json_t *o2 = NULL, *orphan = NULL;
    if (expect_ok("new_object o2", ds_json_new_object(&o2))) return 1;
    if (expect_ok("new_int orphan", ds_json_new_int(1, &orphan))) return 1;
    if (expect_status("array_append onto object",
                      ds_json_array_append(o2, orphan), DS_ERR_INVAL)) return 1;
    /* orphan still owned by us — freeing it must be valid (no double-free) */
    ds_json_free(orphan);
    /* NULL child rejected */
    if (expect_status("object_set null child",
                      ds_json_object_set(o2, "k", 1, NULL), DS_ERR_INVAL)) return 1;
    ds_json_free(o2);

    /* build → serialize → parse → read round-trip, nested */
    ds_json_t *root = NULL, *inner = NULL, *s = NULL, *b = NULL;
    if (expect_ok("new_object root", ds_json_new_object(&root))) return 1;
    if (expect_ok("new_array inner", ds_json_new_array(&inner))) return 1;
    if (expect_ok("new_string", ds_json_new_string("deep", 4, &s))) return 1;
    if (expect_ok("append s", ds_json_array_append(inner, s))) return 1;
    if (expect_ok("set inner", ds_json_object_set(root, "items", 5, inner))) return 1;
    if (expect_ok("new_bool", ds_json_new_bool(true, &b))) return 1;
    if (expect_ok("set flag", ds_json_object_set(root, "flag", 4, b))) return 1;
    if (expect_ok("serialize root", ds_json_serialize(root, &text, &tlen))) return 1;

    ds_json_t *rp = NULL;
    if (expect_ok("reparse built", ds_json_parse(text, tlen, &rp))) return 1;
    const ds_json_t *got = NULL;
    if (expect_ok("path items[0]", ds_json_get_path(rp, "items[0]", &got))) return 1;
    const char *gs = NULL;
    if (expect_ok("get_string items[0]", ds_json_get_string(got, &gs, NULL)) ||
        strcmp(gs, "deep") != 0) {
        fprintf(stderr, "FAIL: round-trip items[0] '%s'\n", gs ? gs : "(null)");
        return 1;
    }
    ds_free(text);
    ds_json_free(rp);
    ds_json_free(root);
    return 0;
}

/* ---- the float model: a Json float is finite ---- */

/* One float, read back through the public getters: kind FLOAT, and the
   value's bits are `want`'s. A bit compare, so +0.0 and -0.0 differ. */
static int expect_float_bits(const char *what, const ds_json_t *node,
                             double want)
{
    ds_json_kind_t k;
    double         got = 0.0;
    if (expect_ok(what, ds_json_get_kind(node, &k))) return 1;
    if (k != DS_JSON_FLOAT) { fprintf(stderr, "FAIL: %s: kind %d\n", what, k); return 1; }
    if (expect_ok(what, ds_json_get_float(node, &got))) return 1;
    if (memcmp(&got, &want, sizeof got) != 0) {
        fprintf(stderr, "FAIL: %s: %a, want %a\n", what, got, want);
        return 1;
    }
    return 0;
}

/* @spec [IDAT.3.3.9] */
static int test_idat_3_3_9__new_float_refuses_a_non_finite_value(void)
{
    const double bad[3] = { INFINITY, -INFINITY, NAN };
    const char  *name[3] = { "new_float(+Inf)", "new_float(-Inf)", "new_float(NaN)" };
    for (int i = 0; i < 3; i++) {
        ds_json_t *out = (ds_json_t *) 0x1;   /* must come back NULL */
        if (expect_status(name[i], ds_json_new_float(bad[i], &out),
                          DS_ERR_JSON_NONFINITE)) return 1;
        if (out != NULL) {
            fprintf(stderr, "FAIL: %s left *out non-NULL\n", name[i]);
            return 1;
        }
    }
    return 0;
}

/* @spec [IDAT.3.3.9] */
static int test_idat_3_3_9__new_float_admits_every_finite_value(void)
{
    ds_json_t *big = NULL, *zero = NULL;
    if (expect_ok("new_float(DBL_MAX)", ds_json_new_float(DBL_MAX, &big))) return 1;
    if (expect_float_bits("new_float(DBL_MAX) reads", big, DBL_MAX)) return 1;
    ds_json_free(big);
    /* -0.0 is finite and admitted, and held as +0.0 ([LGRA.5.8.8]). */
    if (expect_ok("new_float(-0.0)", ds_json_new_float(-0.0, &zero))) return 1;
    if (expect_float_bits("new_float(-0.0) reads", zero, 0.0)) return 1;
    ds_json_free(zero);
    return 0;
}

/* @spec [IDAT.3.3.9] */
static int test_idat_3_3_9__parse_refuses_a_literal_past_the_double_range(void)
{
    /* Each rounds to an infinity: 1.7976931348623159e308 lies above the
       rounding threshold 2^1024 - 2^970 although it is below 1e309. */
    const char *bad[3] = { "1e400", "-1e400", "1.7976931348623159e308" };
    for (int i = 0; i < 3; i++) {
        ds_json_t *out = (ds_json_t *) 0x1;
        if (expect_status(bad[i], ds_json_parse(bad[i], strlen(bad[i]), &out),
                          DS_ERR_PARSE)) return 1;
        if (out != NULL) {
            fprintf(stderr, "FAIL: parse %s left *out non-NULL\n", bad[i]);
            return 1;
        }
    }
    /* Above DBL_MAX's own decimal and below the threshold: rounds to DBL_MAX,
       not refused and not saturated past it. */
    ds_json_t *t = NULL;
    const char *edge = "1.7976931348623158e308";
    if (expect_ok("parse 1.7976931348623158e308",
                  ds_json_parse(edge, strlen(edge), &t))) return 1;
    if (expect_float_bits("1.7976931348623158e308 reads", t, DBL_MAX)) return 1;
    ds_json_free(t);
    /* Rounding to zero is a zero, either sign held as +0.0. */
    const char *tiny[2] = { "1e-400", "-1e-400" };
    for (int i = 0; i < 2; i++) {
        t = NULL;
        if (expect_ok(tiny[i], ds_json_parse(tiny[i], strlen(tiny[i]), &t))) return 1;
        if (expect_float_bits(tiny[i], t, 0.0)) return 1;
        ds_json_free(t);
    }
    return 0;
}

/* ---- paths: judged whole, then a hit or a miss ---- */

/* @spec [IDAT.3.3.10] */
static int test_idat_3_3_10__malformed_path_is_refused_on_every_tree(void)
{
    const char *trees[2] = { "{\"a\":{\"b\":1}}", "1" };
    const char *bad[] = { "", ".a", "a..b", "a.", "a[0]b", "a[ 1]", "a[-0]", "a[+1]",
                          "a[]", "a[1", "a.[0]", "absent.b[", "a.b[" };
    for (size_t t = 0; t < 2; t++) {
        ds_json_t *tree = NULL;
        if (expect_ok("parse", ds_json_parse(trees[t], strlen(trees[t]), &tree))) return 1;
        for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
            const ds_json_t *out = NULL;
            if (expect_status(bad[i], ds_json_get_path(tree, bad[i], &out), DS_ERR_INVAL))
                return 1;
        }
        ds_json_free(tree);
    }
    return 0;
}

/* The int `path` resolves to in `tree`. */
static int expect_path_int(const ds_json_t *tree, const char *path, int64_t want)
{
    const ds_json_t *node = NULL;
    int64_t got = 0;
    if (expect_ok(path, ds_json_get_path(tree, path, &node))) return 1;
    if (node == NULL) { fprintf(stderr, "FAIL: %s missed\n", path); return 1; }
    if (expect_ok(path, ds_json_get_int(node, &got))) return 1;
    if (got != want) {
        fprintf(stderr, "FAIL: %s: %lld, want %lld\n", path, (long long) got, (long long) want);
        return 1;
    }
    return 0;
}

/* A well-formed path that resolves nothing: DS_OK with *out written NULL. */
static int expect_path_miss(const ds_json_t *tree, const char *path)
{
    const ds_json_t *node = tree;
    if (expect_ok(path, ds_json_get_path(tree, path, &node))) return 1;
    if (node != NULL) { fprintf(stderr, "FAIL: %s did not miss\n", path); return 1; }
    return 0;
}

/* @spec [IDAT.3.3.10] */
static int test_idat_3_3_10__a_path_resolves_or_misses(void)
{
    const char *obj_text = "{\"a\":{\"b\":1},\"\":2,\"a.b\":3}";
    const char *arr_text = "{\"a\":[[10,20],5]}";
    const char *top_text = "[{\"a\":7}]";
    ds_json_t *obj = NULL, *arr = NULL, *top = NULL;
    if (expect_ok("parse", ds_json_parse(obj_text, strlen(obj_text), &obj))) return 1;
    if (expect_ok("parse", ds_json_parse(arr_text, strlen(arr_text), &arr))) return 1;
    if (expect_ok("parse", ds_json_parse(top_text, strlen(top_text), &top))) return 1;

    const ds_json_t *node = NULL;
    ds_json_kind_t kind = DS_JSON_NULL;
    if (expect_ok("a", ds_json_get_path(obj, "a", &node))) return 1;
    if (node == NULL || expect_ok("kind", ds_json_get_kind(node, &kind)) ||
        kind != DS_JSON_OBJECT) { fprintf(stderr, "FAIL: a is the object\n"); return 1; }
    if (expect_path_int(obj, "a.b", 1)) return 1;   /* a then b, not the member "a.b" */
    if (expect_ok("a[0]", ds_json_get_path(arr, "a[0]", &node))) return 1;
    if (node == NULL || expect_ok("kind", ds_json_get_kind(node, &kind)) ||
        kind != DS_JSON_ARRAY) { fprintf(stderr, "FAIL: a[0] is the array\n"); return 1; }
    if (expect_path_int(top, "[0].a", 7)) return 1;
    if (expect_path_int(arr, "a[0][1]", 20)) return 1;
    if (expect_path_int(arr, "a[01]", 5)) return 1;

    if (expect_path_miss(obj, "absent")) return 1;
    if (expect_path_miss(obj, "a.b.c")) return 1;     /* a key step on an int */
    if (expect_path_miss(obj, "a[0]")) return 1;      /* an index step on an object */
    if (expect_path_miss(arr, "a[2]")) return 1;
    if (expect_path_miss(arr, "a[99999999999999999999999]")) return 1;

    /* A member keyed "" or "a.b" has no path; object_get reads it. */
    int64_t v = 0;
    if (expect_ok("object_get \"\"", ds_json_object_get(obj, "", &node))) return 1;
    if (expect_ok("its int", ds_json_get_int(node, &v)) || v != 2) {
        fprintf(stderr, "FAIL: member \"\" is 2\n"); return 1;
    }
    if (expect_ok("object_get a.b", ds_json_object_get(obj, "a.b", &node))) return 1;
    if (expect_ok("its int", ds_json_get_int(node, &v)) || v != 3) {
        fprintf(stderr, "FAIL: member \"a.b\" is 3\n"); return 1;
    }

    ds_json_free(top);
    ds_json_free(arr);
    ds_json_free(obj);
    return 0;
}

/* `obj`'s keys by position are `first`, then `second`, and there are two. */
static int expect_positions(const char *what, const ds_json_t *obj,
                            const char *first, const char *second)
{
    const char *k0 = NULL, *k1 = NULL;
    size_t n = 0;
    if (expect_ok(what, ds_json_object_len(obj, &n))) return 1;
    if (n != 2) { fprintf(stderr, "FAIL: %s: %zu members\n", what, n); return 1; }
    if (expect_ok(what, ds_json_object_at(obj, 0, &k0, NULL, NULL))) return 1;
    if (expect_ok(what, ds_json_object_at(obj, 1, &k1, NULL, NULL))) return 1;
    if (strcmp(k0, first) != 0 || strcmp(k1, second) != 0) {
        fprintf(stderr, "FAIL: %s: %s then %s, want %s then %s\n",
                what, k0, k1, first, second);
        return 1;
    }
    return 0;
}

/* @spec [IDAT.3.3.11] */
static int test_idat_3_3_11__object_positions_are_entry_order(void)
{
    const char *text = "{\"b\":1,\"a\":2}";
    ds_json_t *parsed = NULL;
    if (expect_ok("parse", ds_json_parse(text, strlen(text), &parsed))) return 1;
    if (expect_positions("parsed", parsed, "b", "a")) return 1;
    ds_json_free(parsed);

    ds_json_t *built = NULL, *v1 = NULL, *v2 = NULL, *v3 = NULL, *copy = NULL;
    if (expect_ok("new_object", ds_json_new_object(&built))) return 1;
    if (expect_ok("new_int", ds_json_new_int(1, &v1))) return 1;
    if (expect_ok("new_int", ds_json_new_int(2, &v2))) return 1;
    if (expect_ok("new_int", ds_json_new_int(3, &v3))) return 1;
    if (expect_ok("set b", ds_json_object_set(built, "b", 1, v1))) return 1;
    if (expect_ok("set a", ds_json_object_set(built, "a", 1, v2))) return 1;
    if (expect_positions("built", built, "b", "a")) return 1;
    if (expect_ok("set b again", ds_json_object_set(built, "b", 1, v3))) return 1;
    if (expect_positions("a present key keeps its position", built, "b", "a")) return 1;
    if (expect_ok("clone", ds_json_clone(built, &copy))) return 1;
    if (expect_positions("clone", copy, "b", "a")) return 1;

    /* The positions are not serialize's order, which sorts by key. */
    char *out = NULL;
    if (expect_ok("serialize", ds_json_serialize(built, &out, NULL))) return 1;
    const char *a = strstr(out, "\"a\""), *b = strstr(out, "\"b\"");
    if (a == NULL || b == NULL || a > b) {
        fprintf(stderr, "FAIL: serialize does not sort: %s\n", out);
        return 1;
    }
    ds_free(out);
    ds_json_free(copy);
    ds_json_free(built);
    return 0;
}

/* @spec [IDAT.3.3.6] */
static int test_idat_3_3_6__a_miss_writes_null(void)
{
    const char *text = "{\"a\":[1]}";
    ds_json_t *tree = NULL;
    if (expect_ok("parse", ds_json_parse(text, strlen(text), &tree))) return 1;

    const ds_json_t *out = tree;
    if (expect_status("object_get absent", ds_json_object_get(tree, "absent", &out),
                      DS_ERR_NOT_FOUND)) return 1;
    if (out != NULL) { fprintf(stderr, "FAIL: object_get left *out\n"); return 1; }

    const ds_json_t *array = NULL;
    if (expect_ok("object_get a", ds_json_object_get(tree, "a", &array))) return 1;
    out = tree;
    if (expect_status("array_at past the end", ds_json_array_at(array, 1, &out),
                      DS_ERR_NOT_FOUND)) return 1;
    if (out != NULL) { fprintf(stderr, "FAIL: array_at left *out\n"); return 1; }

    ds_json_free(tree);
    return 0;
}

int main(void)
{
    if (test_reads())         return 1;
    if (test_strict_errors()) return 1;
    if (test_build())         return 1;
    if (test_idat_3_3_9__new_float_refuses_a_non_finite_value())          return 1;
    if (test_idat_3_3_9__new_float_admits_every_finite_value())           return 1;
    if (test_idat_3_3_9__parse_refuses_a_literal_past_the_double_range()) return 1;
    if (test_idat_3_3_10__malformed_path_is_refused_on_every_tree())      return 1;
    if (test_idat_3_3_10__a_path_resolves_or_misses())                    return 1;
    if (test_idat_3_3_11__object_positions_are_entry_order())             return 1;
    if (test_idat_3_3_6__a_miss_writes_null())                            return 1;
    printf("test_json_api_spec: OK\n");
    return 0;
}
