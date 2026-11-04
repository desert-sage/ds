/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [LGRA.5.8.8] [LSTR.1.5]
 * The JSON module on its own: parser, serializer, path lookup, builders and
 * limits.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "libds.h"
#include "internal/json.h"   /* white-box: this impl test field-walks the tree */

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

static int parse_and_check_kind(const char *text,
                                 ds_json_kind_t want_kind,
                                 ds_json_t **out)
{
    ds_json_t *t = NULL;
    ds_result_t r = ds_json_parse(text, strlen(text), &t);
    if (expect_ok("ds_json_parse", r)) return 1;
    if (t == NULL) {
        fprintf(stderr, "FAIL: parsed OK but tree is NULL\n");
        return 1;
    }
    if (t->kind != want_kind) {
        fprintf(stderr, "FAIL: parsed `%s` got kind=%d, want %d\n",
                text, (int) t->kind, (int) want_kind);
        ds_json_free(t);
        return 1;
    }
    *out = t;
    return 0;
}

static int expect_detail(const char *what, ds_result_t r, ds_status_t want,
                         const char *detail)
{
    if (expect_status(what, r, want)) return 1;
    if (r.detail == NULL || strcmp(r.detail, detail) != 0) {
        fprintf(stderr, "FAIL: %s: detail `%s`, want `%s`\n", what,
                r.detail ? r.detail : "(null)", detail);
        return 1;
    }
    return 0;
}

/* `levels` levels of nesting as text: levels-1 arrays around a `1`. */
static char *nested_text(size_t levels, size_t *len)
{
    size_t n = levels - 1;
    char *s = malloc(2 * n + 2);
    if (s == NULL) return NULL;
    memset(s, '[', n);
    s[n] = '1';
    memset(s + n + 1, ']', n);
    s[2 * n + 1] = '\0';
    *len = 2 * n + 1;
    return s;
}

/* An integer literal outside int64 is refused, not saturated. Both bounds are
   exact, and a Float literal of the same magnitude still parses. */
static int test_int_range(void)
{
    static const char *const ok[] = {
        "9223372036854775807", "-9223372036854775808", "0", "-0" };
    static const char *const refused[] = {
        "9223372036854775808", "-9223372036854775809",
        "18446744073709551615",
        "1234567890123456789012345678901234567890123456789012345678901234567890" };
    for (size_t i = 0; i < sizeof(ok) / sizeof(ok[0]); i++) {
        ds_json_t *t = NULL;
        if (parse_and_check_kind(ok[i], DS_JSON_INT, &t)) return 1;
        ds_json_free(t);
    }
    ds_json_t *t = NULL;
    if (parse_and_check_kind("9223372036854775807", DS_JSON_INT, &t)) return 1;
    if (t->v.i != INT64_MAX) {
        fprintf(stderr, "FAIL: INT64_MAX read as %lld\n", (long long) t->v.i);
        return 1;
    }
    ds_json_free(t);
    for (size_t i = 0; i < sizeof(refused) / sizeof(refused[0]); i++) {
        t = NULL;
        ds_result_t r = ds_json_parse(refused[i], strlen(refused[i]), &t);
        if (expect_detail(refused[i], r, DS_ERR_PARSE,
                          "JSON integer literal outside int64")) return 1;
        if (t != NULL) { fprintf(stderr, "FAIL: refused parse set *out\n"); return 1; }
    }
    /* Inside an array as well as at the root: the refusal is the document's. */
    ds_result_t r = ds_json_parse("[1, 18446744073709551615]", 25, &t);
    if (expect_detail("nested out-of-range int", r, DS_ERR_PARSE,
                      "JSON integer literal outside int64")) return 1;
    if (parse_and_check_kind("18446744073709551615.0", DS_JSON_FLOAT, &t)) return 1;
    ds_json_free(t);
    return 0;
}

/* A Float literal has no length limit, and `\u0000` is refused rather than
   decoded into a string it would cut short. */
static int test_parse_gaps(void)
{
    /* 0. then 100 digits: 102 bytes. */
    char lit[128];
    lit[0] = '0'; lit[1] = '.';
    for (int i = 0; i < 100; i++) lit[2 + i] = (char) ('0' + (i % 10));
    lit[102] = '\0';
    ds_json_t *t = NULL;
    if (parse_and_check_kind(lit, DS_JSON_FLOAT, &t)) return 1;
    if (!(t->v.f > 0.0123 && t->v.f < 0.0124)) {
        fprintf(stderr, "FAIL: long float literal read as %.17g\n", t->v.f);
        return 1;
    }
    ds_json_free(t);
    /* And one whose length is an exponent's: 1e-0...01, exactly 0.1. */
    char exp_lit[96] = "1e-";
    for (int i = 0; i < 80; i++) exp_lit[3 + i] = '0';
    exp_lit[83] = '1';
    exp_lit[84] = '\0';
    if (parse_and_check_kind(exp_lit, DS_JSON_FLOAT, &t)) return 1;
    if (t->v.f != 0.1) {
        fprintf(stderr, "FAIL: long exponent read as %.17g\n", t->v.f);
        return 1;
    }
    ds_json_free(t);

    static const char nul[] = "\"ab\\u0000cd\"";
    t = NULL;
    ds_result_t r = ds_json_parse(nul, sizeof(nul) - 1, &t);
    if (expect_detail("\\u0000", r, DS_ERR_PARSE,
                      "JSON string contains \\u0000; an embedded NUL "
                      "is not supported")) return 1;
    if (t != NULL) { fprintf(stderr, "FAIL: refused parse set *out\n"); return 1; }
    /* The control: `\u0001` is a character like any other. */
    static const char one[] = "\"ab\\u0001cd\"";
    if (parse_and_check_kind(one, DS_JSON_STRING, &t)) return 1;
    if (strlen(t->v.s) != 5) {
        fprintf(stderr, "FAIL: \\u0001 string is %zu bytes\n", strlen(t->v.s));
        return 1;
    }
    ds_json_free(t);
    return 0;
}

/* An object that repeats a key, compared as decoded, is refused wherever it
   sits; the same key in two objects is not a repeat. */
/* @spec [LGRA.5.8.7] */
static int test_lgra_5_8_7_duplicate_keys(void)
{
    static const char *const refused[] = {
        "{\"a\":1,\"a\":2}",
        "{\"a\":1,\"\\u0061\":2}",        /* "\u0061" is "a" */
        "{\"x\":{\"a\":1,\"a\":2}}",
        "{\"a\":1,\"b\":2,\"a\":3}",
    };
    for (size_t i = 0; i < sizeof(refused) / sizeof(refused[0]); i++) {
        ds_json_t *t = NULL;
        ds_result_t r = ds_json_parse(refused[i], strlen(refused[i]), &t);
        if (expect_detail(refused[i], r, DS_ERR_PARSE,
                          "JSON object repeats a key (LGRA.5.8.7)")) return 1;
        if (t != NULL) { fprintf(stderr, "FAIL: refused parse set *out\n"); return 1; }
    }

    ds_json_t *t = NULL;
    if (parse_and_check_kind("[{\"a\":1},{\"a\":2}]", DS_JSON_ARRAY, &t)) return 1;
    ds_json_free(t);
    if (parse_and_check_kind("{\"a\":1,\"A\":2}", DS_JSON_OBJECT, &t)) return 1;
    if (t->v.obj.n != 2) {
        fprintf(stderr, "FAIL: {a, A} holds %u members\n", (unsigned) t->v.obj.n);
        return 1;
    }
    ds_json_free(t);
    return 0;
}

/* [LSTR.1.1]: no `Json` string or key holds U+0000, by an escape, a raw byte
   or a builder. A refused object_set leaves the object and the child as they
   were. */
static int test_lstr_1_1_no_nul(void)
{
    ds_json_t *t = NULL;
    static const char key[] = "{\"a\\u0000b\": 1}";
    ds_result_t r = ds_json_parse(key, sizeof(key) - 1, &t);
    if (expect_detail("\\u0000 in a key", r, DS_ERR_PARSE,
                      "JSON string contains \\u0000; an embedded NUL "
                      "is not supported")) return 1;
    if (t != NULL) { fprintf(stderr, "FAIL: refused key set *out\n"); return 1; }

    static const char raw[] = { '"', 'a', '\0', 'b', '"' };
    r = ds_json_parse(raw, sizeof(raw), &t);
    if (expect_status("raw NUL in a string", r, DS_ERR_PARSE)) return 1;
    if (t != NULL) { fprintf(stderr, "FAIL: raw NUL set *out\n"); return 1; }

    r = ds_json_new_string("a\0b", 3, &t);
    if (expect_status("new_string with a NUL", r, DS_ERR_INVAL)) return 1;
    if (t != NULL) { fprintf(stderr, "FAIL: new_string NUL set *out\n"); return 1; }
    /* The control: the same bytes without the NUL build. */
    if (expect_ok("new_string control", ds_json_new_string("ab", 2, &t))) return 1;
    ds_json_free(t);

    ds_json_t *obj = NULL, *child = NULL;
    if (expect_ok("new_object", ds_json_new_object(&obj))) return 1;
    if (expect_ok("new_int", ds_json_new_int(7, &child))) return 1;
    r = ds_json_object_set(obj, "k\0x", 3, child);
    if (expect_status("object_set key with a NUL", r, DS_ERR_INVAL)) return 1;
    size_t n = 99;
    if (expect_ok("object_len", ds_json_object_len(obj, &n))) return 1;
    if (n != 0) { fprintf(stderr, "FAIL: refused key changed the object\n"); return 1; }
    if (child->parent != NULL) {
        fprintf(stderr, "FAIL: refused key consumed the child\n");
        return 1;
    }
    /* The control, and the child the refusal left with the caller. */
    if (expect_ok("object_set control", ds_json_object_set(obj, "kx", 2, child)))
        return 1;
    ds_json_free(obj);
    return 0;
}

/* Parsing refuses a document nested deeper than DS_JSON_MAX_DEPTH, at exactly
   the cap, and a very deep one is refused rather than crashing. */
static int test_parse_depth(void)
{
    size_t len = 0;
    ds_json_t *t = NULL;

    char *at_cap = nested_text(DS_JSON_MAX_DEPTH, &len);
    if (at_cap == NULL) return 1;
    ds_result_t r = ds_json_parse(at_cap, len, &t);
    free(at_cap);
    if (expect_ok("parse at DS_JSON_MAX_DEPTH", r)) return 1;
    if (t->height != DS_JSON_MAX_DEPTH) {
        fprintf(stderr, "FAIL: parsed height %u, want %u\n", t->height,
                (unsigned) DS_JSON_MAX_DEPTH);
        return 1;
    }
    /* The deepest leaf's chain of owners leads back to the root. */
    const ds_json_t *leaf = t;
    while (leaf->kind == DS_JSON_ARRAY) leaf = leaf->v.arr.items[0];
    uint32_t up = 1;
    for (const ds_json_t *a = leaf; a->parent != NULL; a = a->parent) up++;
    if (up != DS_JSON_MAX_DEPTH) {
        fprintf(stderr, "FAIL: leaf has %u levels of owners\n", up);
        return 1;
    }
    /* A clone keeps the shape, and a serialize of the deepest legal tree works. */
    ds_json_t *copy = NULL;
    if (expect_ok("clone at cap", ds_json_clone(t, &copy))) return 1;
    if (copy->height != DS_JSON_MAX_DEPTH || copy->parent != NULL) {
        fprintf(stderr, "FAIL: clone height %u\n", copy->height);
        return 1;
    }
    char  *text = NULL;
    size_t tlen = 0;
    if (expect_ok("serialize at cap", ds_json_serialize(copy, &text, &tlen))) return 1;
    ds_free(text);
    ds_json_free(copy);
    ds_json_free(t);

    char *over = nested_text(DS_JSON_MAX_DEPTH + 1, &len);
    if (over == NULL) return 1;
    t = NULL;
    r = ds_json_parse(over, len, &t);
    free(over);
    if (expect_detail("parse past DS_JSON_MAX_DEPTH", r, DS_ERR_JSON_LIMIT,
                      "JSON nested deeper than DS_JSON_MAX_DEPTH")) return 1;
    if (t != NULL) { fprintf(stderr, "FAIL: deep parse set *out\n"); return 1; }

    /* The text limit ([LGRA.5.8.6]) refuses a million levels unread, so the
       depth cap is shown on text under it: 12,000 levels is 23,999 bytes. */
    char *huge = nested_text(1000000, &len);
    if (huge == NULL) return 1;
    r = ds_json_parse(huge, len, &t);
    free(huge);
    if (expect_detail("parse a million levels", r, DS_ERR_JSON_LIMIT,
                      "JSON text longer than DS_JSON_MAX_TEXT_BYTES")) return 1;
    char *deep = nested_text(12000, &len);
    if (deep == NULL) return 1;
    if (len > DS_JSON_MAX_TEXT_BYTES) { free(deep); return 1; }
    r = ds_json_parse(deep, len, &t);
    free(deep);
    if (expect_detail("parse 12000 levels", r, DS_ERR_JSON_LIMIT,
                      "JSON nested deeper than DS_JSON_MAX_DEPTH")) return 1;

    /* Objects count the same as arrays. */
    char obj[2 * DS_JSON_MAX_DEPTH * 6 + 8];
    size_t o = 0;
    for (int i = 0; i < DS_JSON_MAX_DEPTH; i++) { memcpy(obj + o, "{\"k\":", 5); o += 5; }
    obj[o++] = '1';
    for (int i = 0; i < DS_JSON_MAX_DEPTH; i++) obj[o++] = '}';
    r = ds_json_parse(obj, o, &t);
    if (expect_detail("objects past the cap", r, DS_ERR_JSON_LIMIT,
                      "JSON nested deeper than DS_JSON_MAX_DEPTH")) return 1;
    return 0;
}

/* The builders refuse to make a tree deeper than DS_JSON_MAX_DEPTH, measured
   from the root, including through a pointer the caller kept. */
static int test_build_depth(void)
{
    const char *deep = "json tree would nest deeper than DS_JSON_MAX_DEPTH";

    /* Top-down: append each new array to the deepest one, keeping only the
       pointer to the bottom. The tree's depth is invisible from that pointer
       alone, which is the case a check on the child's own height misses. */
    ds_json_t *root = NULL, *bottom = NULL;
    if (expect_ok("new root", ds_json_new_array(&root))) return 1;
    bottom = root;
    for (int level = 2; level <= DS_JSON_MAX_DEPTH; level++) {
        ds_json_t *a = NULL;
        if (expect_ok("new array", ds_json_new_array(&a))) return 1;
        if (expect_ok("append within the cap", ds_json_array_append(bottom, a)))
            return 1;
        bottom = a;
    }
    if (root->height != DS_JSON_MAX_DEPTH) {
        fprintf(stderr, "FAIL: built height %u\n", root->height);
        return 1;
    }
    ds_json_t *leaf = NULL;
    if (expect_ok("new int", ds_json_new_int(1, &leaf))) return 1;
    if (expect_detail("append past the cap, via the kept pointer",
                      ds_json_array_append(bottom, leaf), DS_ERR_JSON_LIMIT, deep))
        return 1;
    if (bottom->v.arr.n != 0 || leaf->parent != NULL) {
        fprintf(stderr, "FAIL: a refused append changed the tree\n");
        return 1;
    }
    /* object_set refuses the same way. */
    ds_json_t *obj = NULL;
    if (expect_ok("new object", ds_json_new_object(&obj))) return 1;
    if (expect_ok("append object", ds_json_array_append(root, obj))) return 1;
    ds_json_t *tall = NULL;
    size_t len = 0;
    char *text = nested_text(DS_JSON_MAX_DEPTH - 1, &len);
    if (text == NULL) return 1;
    ds_result_t r = ds_json_parse(text, len, &tall);
    free(text);
    if (expect_ok("parse a tall value", r)) return 1;
    if (expect_detail("object_set past the cap",
                      ds_json_object_set(obj, "k", 1, tall), DS_ERR_JSON_LIMIT, deep))
        return 1;
    ds_json_free(tall);
    ds_json_free(leaf);
    ds_json_free(root);

    /* Bottom-up: a tree at the cap cannot go under anything. */
    ds_json_t *top = NULL;
    text = nested_text(DS_JSON_MAX_DEPTH, &len);
    if (text == NULL) return 1;
    r = ds_json_parse(text, len, &top);
    free(text);
    if (expect_ok("parse at cap", r)) return 1;
    ds_json_t *wrap = NULL;
    if (expect_ok("new wrapper", ds_json_new_array(&wrap))) return 1;
    if (expect_detail("wrap a tree at the cap",
                      ds_json_array_append(wrap, top), DS_ERR_JSON_LIMIT, deep))
        return 1;
    ds_json_free(wrap);
    ds_json_free(top);
    return 0;
}

/* The refusals that keep a tree a tree: a child that already belongs to a
   container, and one that contains the container. */
static int test_build_links(void)
{
    ds_json_t *a = NULL, *b = NULL, *c = NULL;
    if (expect_ok("new a", ds_json_new_array(&a))) return 1;
    if (expect_ok("new b", ds_json_new_array(&b))) return 1;
    if (expect_ok("new c", ds_json_new_array(&c))) return 1;
    if (expect_ok("a <- b", ds_json_array_append(a, b))) return 1;
    if (expect_detail("append a node to itself", ds_json_array_append(a, a),
                      DS_ERR_INVAL, "json child contains its container")) return 1;
    if (expect_ok("b <- c", ds_json_array_append(b, c))) return 1;
    if (expect_detail("append an owned node again", ds_json_array_append(c, b),
                      DS_ERR_INVAL, "json child already belongs to a container"))
        return 1;
    if (expect_detail("append a root into its own descendant",
                      ds_json_array_append(c, a), DS_ERR_INVAL,
                      "json child contains its container")) return 1;
    if (a->height != 3 || b->height != 2 || c->height != 1) {
        fprintf(stderr, "FAIL: heights %u/%u/%u, want 3/2/1\n",
                a->height, b->height, c->height);
        return 1;
    }
    ds_json_free(a);

    /* Replacing an object's tallest value lowers the heights above it, so the
       room it freed can be used: stored heights are exact, not upper bounds. */
    ds_json_t *obj = NULL, *tall = NULL, *small = NULL;
    size_t len = 0;
    char *text = nested_text(DS_JSON_MAX_DEPTH - 1, &len);
    if (text == NULL) return 1;
    if (expect_ok("parse tall", ds_json_parse(text, len, &tall))) return 1;
    free(text);
    if (expect_ok("new object", ds_json_new_object(&obj))) return 1;
    if (expect_ok("object_set tall", ds_json_object_set(obj, "k", 1, tall))) return 1;
    if (obj->height != DS_JSON_MAX_DEPTH) {
        fprintf(stderr, "FAIL: object height %u\n", obj->height);
        return 1;
    }
    if (expect_ok("new small", ds_json_new_int(7, &small))) return 1;
    if (expect_ok("replace tall with small",
                  ds_json_object_set(obj, "k", 1, small))) return 1;
    if (obj->height != 2) {
        fprintf(stderr, "FAIL: object height after replace %u, want 2\n",
                obj->height);
        return 1;
    }
    ds_json_t *wrap = NULL;
    if (expect_ok("new wrapper", ds_json_new_array(&wrap))) return 1;
    if (expect_ok("wrap the shrunk object", ds_json_array_append(wrap, obj)))
        return 1;
    ds_json_free(wrap);
    return 0;
}

/* `n` values as text: an array of n-1 zeros, so the array is the n-th. */
static char *array_of_values(size_t n, size_t *len)
{
    size_t k = n - 1;                      /* zeros */
    char *s = malloc(2 * k + 3);
    if (s == NULL) return NULL;
    size_t o = 0;
    s[o++] = '[';
    for (size_t i = 0; i < k; i++) { if (i) s[o++] = ','; s[o++] = '0'; }
    s[o++] = ']';
    s[o] = '\0';
    *len = o;
    return s;
}

/* A string of `bytes` 'a's as JSON text: "aaa...". */
static char *string_of_bytes(size_t bytes, size_t *len)
{
    char *s = malloc(bytes + 3);
    if (s == NULL) return NULL;
    s[0] = '"';
    memset(s + 1, 'a', bytes);
    s[bytes + 1] = '"';
    s[bytes + 2] = '\0';
    *len = bytes + 2;
    return s;
}

static int expect_breach(const char *what, const ds_json_breach_t *b,
                         ds_json_limit_t cap, uint64_t limit, uint64_t observed)
{
    if (b->cap != cap || b->limit != limit || b->observed != observed) {
        fprintf(stderr, "FAIL: %s: breach cap=%d limit=%llu observed=%llu, want "
                "%d/%llu/%llu\n", what, (int) b->cap,
                (unsigned long long) b->limit, (unsigned long long) b->observed,
                (int) cap, (unsigned long long) limit,
                (unsigned long long) observed);
        return 1;
    }
    return 0;
}

/* [LGRA.5.8.6]: each of the four limits admits a document AT it and refuses one
   past it, with DS_ERR_JSON_LIMIT and a breach naming the limit and the count
   that crossed it. */
static int test_parse_limits(void)
{
    size_t len = 0;
    ds_json_t *t = NULL;
    ds_json_breach_t b;
    ds_result_t r;

    /* NODES: 256 values parse, and the tree counts them. */
    char *s = array_of_values(DS_JSON_MAX_NODES, &len);
    if (s == NULL) return 1;
    r = ds_json_parse_limited(s, len, &t, &b, true);
    free(s);
    if (expect_ok("parse 256 values", r)) return 1;
    if (t->nodes != DS_JSON_MAX_NODES || b.cap != DS_JSON_LIMIT_NONE) {
        fprintf(stderr, "FAIL: 256 values counted %u\n", t->nodes);
        return 1;
    }
    ds_json_free(t);
    s = array_of_values(DS_JSON_MAX_NODES + 1, &len);
    if (s == NULL) return 1;
    t = NULL;
    r = ds_json_parse_limited(s, len, &t, &b, true);
    free(s);
    if (expect_detail("parse 257 values", r, DS_ERR_JSON_LIMIT,
                      "JSON has more than DS_JSON_MAX_NODES values")) return 1;
    if (expect_breach("257 values", &b, DS_JSON_LIMIT_NODES, DS_JSON_MAX_NODES,
                      DS_JSON_MAX_NODES + 1)) return 1;
    if (t != NULL) { fprintf(stderr, "FAIL: refused parse set *out\n"); return 1; }

    /* STRING BYTES: one string at the limit parses; one byte more is refused.
       Keys count too: {"k": <16383 bytes>} is at the limit, and a two-byte key
       crosses it. */
    s = string_of_bytes(DS_JSON_MAX_STRING_BYTES, &len);
    if (s == NULL) return 1;
    r = ds_json_parse_limited(s, len, &t, &b, true);
    free(s);
    if (expect_ok("parse a 16384-byte string", r)) return 1;
    if (t->str_bytes != DS_JSON_MAX_STRING_BYTES) {
        fprintf(stderr, "FAIL: string counted %u bytes\n", t->str_bytes);
        return 1;
    }
    ds_json_free(t);
    s = string_of_bytes(DS_JSON_MAX_STRING_BYTES + 1, &len);
    if (s == NULL) return 1;
    t = NULL;
    r = ds_json_parse_limited(s, len, &t, &b, true);
    free(s);
    if (expect_detail("parse a 16385-byte string", r, DS_ERR_JSON_LIMIT,
                      "JSON strings exceed DS_JSON_MAX_STRING_BYTES")) return 1;
    if (expect_breach("16385 bytes", &b, DS_JSON_LIMIT_STRING_BYTES,
                      DS_JSON_MAX_STRING_BYTES, DS_JSON_MAX_STRING_BYTES + 1))
        return 1;
    for (int keylen = 1; keylen <= 2; keylen++) {
        size_t vlen = 0;
        char *v = string_of_bytes(DS_JSON_MAX_STRING_BYTES - 1, &vlen);
        if (v == NULL) return 1;
        char *o = malloc(vlen + 16);
        if (o == NULL) { free(v); return 1; }
        size_t n = (size_t) sprintf(o, "{\"%s\":", keylen == 1 ? "k" : "kk");
        memcpy(o + n, v, vlen); n += vlen;
        o[n++] = '}';
        free(v);
        t = NULL;
        r = ds_json_parse_limited(o, n, &t, &b, true);
        free(o);
        if (keylen == 1) {
            if (expect_ok("a key at the string limit", r)) return 1;
            if (t->str_bytes != DS_JSON_MAX_STRING_BYTES) {
                fprintf(stderr, "FAIL: key + value counted %u\n", t->str_bytes);
                return 1;
            }
            ds_json_free(t);
        } else {
            if (expect_status("a key past the string limit", r, DS_ERR_JSON_LIMIT))
                return 1;
            /* The key is read first (2 bytes), then the value crosses. */
            if (expect_breach("key past", &b, DS_JSON_LIMIT_STRING_BYTES,
                              DS_JSON_MAX_STRING_BYTES,
                              DS_JSON_MAX_STRING_BYTES + 1)) return 1;
        }
    }

    /* TEXT: a document of exactly 24576 bytes is read (padding is whitespace),
       and one byte more is refused unread -- the breach says the whole length,
       and with the text limit off the same text parses. */
    char *pad = malloc(DS_JSON_MAX_TEXT_BYTES + 2);
    if (pad == NULL) return 1;
    memset(pad, ' ', DS_JSON_MAX_TEXT_BYTES + 1);
    pad[0] = '1';
    r = ds_json_parse_limited(pad, DS_JSON_MAX_TEXT_BYTES, &t, &b, true);
    if (expect_ok("parse 24576 bytes of text", r)) { free(pad); return 1; }
    ds_json_free(t);
    t = NULL;
    r = ds_json_parse_limited(pad, DS_JSON_MAX_TEXT_BYTES + 1, &t, &b, true);
    if (expect_detail("parse 24577 bytes of text", r, DS_ERR_JSON_LIMIT,
                      "JSON text longer than DS_JSON_MAX_TEXT_BYTES")) {
        free(pad); return 1;
    }
    if (expect_breach("24577 bytes", &b, DS_JSON_LIMIT_TEXT_BYTES,
                      DS_JSON_MAX_TEXT_BYTES, DS_JSON_MAX_TEXT_BYTES + 1)) {
        free(pad); return 1;
    }
    r = ds_json_parse_limited(pad, DS_JSON_MAX_TEXT_BYTES + 1, &t, &b, false);
    free(pad);
    if (expect_ok("the engine's own text skips the text limit", r)) return 1;
    ds_json_free(t);
    t = NULL;

    /* A received FactExternal's Json field: the same at its own cap,
       DS_JSON_MAX_FX_TEXT_BYTES, and the breach names that cap. */
    pad = malloc(DS_JSON_MAX_FX_TEXT_BYTES + 2);
    if (pad == NULL) return 1;
    memset(pad, ' ', DS_JSON_MAX_FX_TEXT_BYTES + 1);
    pad[0] = '1';
    r = ds_json_parse_capped(pad, DS_JSON_MAX_FX_TEXT_BYTES, &t, &b,
                             DS_JSON_MAX_FX_TEXT_BYTES);
    if (expect_ok("parse 106496 bytes at the field's cap", r)) { free(pad); return 1; }
    ds_json_free(t);
    t = NULL;
    r = ds_json_parse_capped(pad, DS_JSON_MAX_FX_TEXT_BYTES + 1, &t, &b,
                             DS_JSON_MAX_FX_TEXT_BYTES);
    free(pad);
    if (expect_detail("parse 106497 bytes at the field's cap", r, DS_ERR_JSON_LIMIT,
                      "JSON text longer than DS_JSON_MAX_FX_TEXT_BYTES"))
        return 1;
    if (expect_breach("106497 bytes", &b, DS_JSON_LIMIT_TEXT_BYTES,
                      DS_JSON_MAX_FX_TEXT_BYTES, DS_JSON_MAX_FX_TEXT_BYTES + 1))
        return 1;

    /* The public entry point applies all four. */
    s = array_of_values(DS_JSON_MAX_NODES + 1, &len);
    if (s == NULL) return 1;
    r = ds_json_parse(s, len, &t);
    free(s);
    if (expect_status("ds_json_parse, 257 values", r, DS_ERR_JSON_LIMIT)) return 1;
    return 0;
}

/* [LGRA.5.8.6] through the builders: a tree reaches each limit and stops there,
   the refused call changes nothing, and replacing a value recounts. */
static int test_build_limits(void)
{
    ds_json_t *arr = NULL, *x = NULL;
    if (expect_ok("new array", ds_json_new_array(&arr))) return 1;
    for (int i = 1; i < DS_JSON_MAX_NODES; i++) {        /* the array is the 1st */
        if (expect_ok("new int", ds_json_new_int(i, &x))) return 1;
        if (expect_ok("append within the node limit", ds_json_array_append(arr, x)))
            return 1;
    }
    if (arr->nodes != DS_JSON_MAX_NODES) {
        fprintf(stderr, "FAIL: built %u nodes\n", arr->nodes);
        return 1;
    }
    if (expect_ok("one more int", ds_json_new_int(0, &x))) return 1;
    if (expect_detail("append the 257th value", ds_json_array_append(arr, x),
                      DS_ERR_JSON_LIMIT,
                      "json tree would hold more than DS_JSON_MAX_NODES values"))
        return 1;
    if (arr->v.arr.n != DS_JSON_MAX_NODES - 1 || x->parent != NULL
        || arr->nodes != DS_JSON_MAX_NODES) {
        fprintf(stderr, "FAIL: a refused append changed the tree\n");
        return 1;
    }
    ds_json_free(x);
    /* A clone carries the counters. */
    ds_json_t *copy = NULL;
    if (expect_ok("clone at the node limit", ds_json_clone(arr, &copy))) return 1;
    if (copy->nodes != DS_JSON_MAX_NODES) {
        fprintf(stderr, "FAIL: clone counted %u nodes\n", copy->nodes);
        return 1;
    }
    ds_json_free(copy);
    ds_json_free(arr);

    /* new_string at and past the string limit. */
    char *bytes = malloc(DS_JSON_MAX_STRING_BYTES + 1);
    if (bytes == NULL) return 1;
    memset(bytes, 'a', DS_JSON_MAX_STRING_BYTES + 1);
    ds_json_t *s = NULL;
    if (expect_ok("new_string at the limit",
                  ds_json_new_string(bytes, DS_JSON_MAX_STRING_BYTES, &s))) {
        free(bytes); return 1;
    }
    ds_json_free(s);
    s = NULL;
    if (expect_detail("new_string past the limit",
                      ds_json_new_string(bytes, DS_JSON_MAX_STRING_BYTES + 1, &s),
                      DS_ERR_JSON_LIMIT,
                      "ds_json_new_string: longer than DS_JSON_MAX_STRING_BYTES")) {
        free(bytes); return 1;
    }

    /* object_set counts the key: {"k": <16383 bytes>} is at the limit, a second
       key of one byte with an empty string crosses it, and REPLACING the big
       value frees its bytes so the same key then fits. */
    ds_json_t *obj = NULL, *big = NULL, *empty = NULL, *small = NULL;
    if (expect_ok("new object", ds_json_new_object(&obj))) { free(bytes); return 1; }
    if (expect_ok("big value",
                  ds_json_new_string(bytes, DS_JSON_MAX_STRING_BYTES - 1, &big))) {
        free(bytes); return 1;
    }
    free(bytes);
    if (expect_ok("set k at the limit", ds_json_object_set(obj, "k", 1, big)))
        return 1;
    if (obj->str_bytes != DS_JSON_MAX_STRING_BYTES) {
        fprintf(stderr, "FAIL: object counted %u string bytes\n", obj->str_bytes);
        return 1;
    }
    if (expect_ok("empty string", ds_json_new_string("", 0, &empty))) return 1;
    if (expect_detail("a second key crosses", ds_json_object_set(obj, "j", 1, empty),
                      DS_ERR_JSON_LIMIT,
                      "json tree's strings would exceed DS_JSON_MAX_STRING_BYTES"))
        return 1;
    if (expect_ok("small value", ds_json_new_string("ab", 2, &small))) return 1;
    if (expect_ok("replace k's value", ds_json_object_set(obj, "k", 1, small)))
        return 1;
    if (obj->str_bytes != 3 || obj->nodes != 2) {
        fprintf(stderr, "FAIL: after replace %u bytes, %u nodes; want 3, 2\n",
                obj->str_bytes, obj->nodes);
        return 1;
    }
    if (expect_ok("now the second key fits", ds_json_object_set(obj, "j", 1, empty)))
        return 1;
    if (obj->str_bytes != 4 || obj->nodes != 3) {
        fprintf(stderr, "FAIL: after insert %u bytes, %u nodes; want 4, 3\n",
                obj->str_bytes, obj->nodes);
        return 1;
    }
    ds_json_free(obj);
    return 0;
}

/* [LGRA.5.8.6]: ds_json_object_set judges a key's length as a size_t, before
   anything reads the key. Where size_t is wider than 32 bits, key_len 2^32
   and 2^32 + 1 would count as 0 and 1 bytes if cut to 32 bits; the key passed
   for them is a one-byte buffer, which only a check made before any read
   leaves unread. Each refusal leaves the object empty and the child
   unconsumed. */
/* @spec [LGRA.5.8.6] */
static int test_object_set_key_length(void)
{
    static const char want[] =
        "ds_json_object_set: key longer than DS_JSON_MAX_STRING_BYTES";
    ds_json_t *obj = NULL, *child = NULL;
    if (expect_ok("new object", ds_json_new_object(&obj))) return 1;
    if (expect_ok("new int", ds_json_new_int(1, &child))) return 1;
    char *bytes = malloc(DS_JSON_MAX_STRING_BYTES + 1);
    if (bytes == NULL) return 1;
    memset(bytes, 'a', DS_JSON_MAX_STRING_BYTES + 1);

    /* The one-byte key is on the heap, so memcheck's valgrind reports a read
       past it; a literal's bytes sit among others it would not flag. */
    char *one = malloc(1);
    if (one == NULL) { free(bytes); return 1; }
    one[0] = 'k';
    struct key_case { const char *label; const char *key; size_t len; };
    struct key_case refused[3];
    size_t n_refused = 0;
    refused[n_refused++] = (struct key_case) {
        "a key one byte over the limit", bytes, DS_JSON_MAX_STRING_BYTES + 1 };
#if SIZE_MAX > UINT32_MAX
    refused[n_refused++] = (struct key_case) {
        "key_len 2^32, which 32 bits count as 0", one, (size_t) 1 << 32 };
    refused[n_refused++] = (struct key_case) {
        "key_len 2^32 + 1, which 32 bits count as 1", one, ((size_t) 1 << 32) + 1 };
#endif
    for (size_t i = 0; i < n_refused; i++) {
        if (expect_detail(refused[i].label,
                          ds_json_object_set(obj, refused[i].key, refused[i].len,
                                             child),
                          DS_ERR_JSON_LIMIT, want)) {
            free(one); free(bytes); return 1;
        }
        if (obj->v.obj.n != 0 || obj->str_bytes != 0 || child->parent != NULL) {
            fprintf(stderr, "FAIL: [LGRA.5.8.6] %s: the refused set changed the "
                    "object or consumed the child\n", refused[i].label);
            free(one); free(bytes); return 1;
        }
    }
    free(one);

    if (expect_ok("a key of exactly DS_JSON_MAX_STRING_BYTES",
                  ds_json_object_set(obj, bytes, DS_JSON_MAX_STRING_BYTES, child))) {
        free(bytes); return 1;
    }
    free(bytes);
    if (obj->v.obj.n != 1 || obj->str_bytes != DS_JSON_MAX_STRING_BYTES) {
        fprintf(stderr, "FAIL: [LGRA.5.8.6] the control holds %u keys and %u "
                "string bytes\n", obj->v.obj.n, obj->str_bytes);
        return 1;
    }
    ds_json_free(obj);
    return 0;
}

/* The boundary check the engine runs at assert and cache seed. A tree libds
   built can never fail it, so its refusal is shown by setting a counter past a
   limit directly (white-box), then restoring it so the free is honest. */
static int test_within_limits(void)
{
    ds_json_t *t = NULL;
    ds_json_breach_t b;
    if (expect_ok("parse", ds_json_parse("[1,2]", 5, &t))) return 1;
    if (!ds_json_within_limits(t, &b) || b.cap != DS_JSON_LIMIT_NONE) {
        fprintf(stderr, "FAIL: a small tree is over a limit\n");
        return 1;
    }
    uint32_t saved = t->nodes;
    t->nodes = DS_JSON_MAX_NODES + 1;
    if (ds_json_within_limits(t, &b)
        || expect_breach("nodes past", &b, DS_JSON_LIMIT_NODES, DS_JSON_MAX_NODES,
                         DS_JSON_MAX_NODES + 1)) {
        fprintf(stderr, "FAIL: within_limits missed the node count\n");
        return 1;
    }
    t->nodes = saved;
    saved = t->height;
    t->height = DS_JSON_MAX_DEPTH + 1;
    if (ds_json_within_limits(t, &b) || b.cap != DS_JSON_LIMIT_DEPTH) {
        fprintf(stderr, "FAIL: within_limits missed the depth\n");
        return 1;
    }
    t->height = saved;
    saved = t->str_bytes;
    t->str_bytes = DS_JSON_MAX_STRING_BYTES + 1;
    if (ds_json_within_limits(t, &b) || b.cap != DS_JSON_LIMIT_STRING_BYTES) {
        fprintf(stderr, "FAIL: within_limits missed the string bytes\n");
        return 1;
    }
    t->str_bytes = saved;
    ds_json_free(t);
    return 0;
}

/* [LSTR.8.5]: JSON text, a string and an object key a host hands the engine
   are well-formed UTF-8, or the call is refused with DS_ERR_ENCODING and makes
   nothing. Each of RFC 3629's malformed classes, through ds_json_parse and
   both builders. The text limit still comes first, and the engine's own parse
   of trusted text (ds_json_parse_limited) does not ask. */
static int test_lstr_8_5__json_text_and_builders(void)
{
    static const struct { const char *label; const char *bytes; } ill[] = {
        { "an overlong form",           "\xC0\xAF" },
        { "a surrogate",                "\xED\xA0\x80" },
        { "a code point past U+10FFFF", "\xF4\x90\x80\x80" },
        { "a sequence cut short",       "\xE2\x82" },
        { "a stray continuation byte",  "\x80" },
    };
    static const char *const ok[] = {
        "\xC3\xA9", "\xE2\x82\xAC", "\xF0\x9F\x98\x80", "\xF4\x8F\xBF\xBF",
    };
    char text[64], label[96];
    ds_json_t *t = NULL;
    ds_result_t r;

    for (size_t c = 0; c < sizeof ill / sizeof ill[0]; c++) {
        const char *b = ill[c].bytes;
        const size_t bl = strlen(b);
        /* As a string value, as a key, and between two values. */
        for (int k = 0; k < 3; k++) {
            int n = k == 0 ? snprintf(text, sizeof text, "\"%s\"", b)
                  : k == 1 ? snprintf(text, sizeof text, "{\"%s\":1}", b)
                  :          snprintf(text, sizeof text, "[1,%s2]", b);
            t = (ds_json_t *) 1;
            r = ds_json_parse(text, (size_t) n, &t);
            snprintf(label, sizeof label, "parse %s in shape %d", ill[c].label, k);
            if (expect_status(label, r, DS_ERR_ENCODING)) return 1;
            if (t != NULL) {
                fprintf(stderr, "FAIL: %s: a tree was handed back\n", label);
                return 1;
            }
        }
        /* The builders: a string, and a key whose child is not consumed. */
        ds_json_t *s = (ds_json_t *) 1;
        r = ds_json_new_string(b, bl, &s);
        snprintf(label, sizeof label, "new_string of %s", ill[c].label);
        if (expect_status(label, r, DS_ERR_ENCODING)) return 1;
        if (s != NULL) {
            fprintf(stderr, "FAIL: %s: a node was handed back\n", label);
            return 1;
        }
        ds_json_t *obj = NULL, *child = NULL;
        if (expect_ok("new object", ds_json_new_object(&obj))) return 1;
        if (expect_ok("new int", ds_json_new_int(7, &child))) return 1;
        r = ds_json_object_set(obj, b, bl, child);
        snprintf(label, sizeof label, "object_set with a key of %s", ill[c].label);
        if (expect_status(label, r, DS_ERR_ENCODING)) return 1;
        if (obj->v.obj.n != 0 || child->parent != NULL) {
            fprintf(stderr, "FAIL: %s: the refused set changed the object\n",
                    label);
            return 1;
        }
        ds_json_free(child);
        ds_json_free(obj);
        /* The engine's own read of text it trusts does not ask. */
        int n = snprintf(text, sizeof text, "\"%s\"", b);
        snprintf(label, sizeof label, "parse_limited of %s", ill[c].label);
        if (expect_ok(label, ds_json_parse_limited(text, (size_t) n, &t, NULL,
                                                   true))) return 1;
        ds_json_free(t);
    }

    /* Valid multibyte text, in a string and a key and through both builders. */
    for (size_t c = 0; c < sizeof ok / sizeof ok[0]; c++) {
        int n = snprintf(text, sizeof text, "{\"%s\":\"%s\"}", ok[c], ok[c]);
        snprintf(label, sizeof label, "parse well-formed text %zu", c);
        if (expect_ok(label, ds_json_parse(text, (size_t) n, &t))) return 1;
        ds_json_free(t);
        ds_json_t *s = NULL, *obj = NULL;
        if (expect_ok("new_string, well-formed",
                      ds_json_new_string(ok[c], strlen(ok[c]), &s))) return 1;
        if (expect_ok("new object", ds_json_new_object(&obj))) return 1;
        if (expect_ok("object_set, a well-formed key",
                      ds_json_object_set(obj, ok[c], strlen(ok[c]), s))) return 1;
        ds_json_free(obj);
    }

    /* Text both over the text limit and ill-formed: the limit, read first. */
    size_t big = (size_t) DS_JSON_MAX_TEXT_BYTES + 1;
    char *over = malloc(big);
    if (over == NULL) return 1;
    memset(over, ' ', big);
    over[0] = '\x80';
    r = ds_json_parse(over, big, &t);
    free(over);
    if (expect_status("ill-formed text over the text limit", r,
                      DS_ERR_JSON_LIMIT)) return 1;
    return 0;
}

/* [LSTR.7.2.3]: a high-surrogate escape followed at once by a low one is the
   codepoint the pair encodes, in a value and in a key. A surrogate that is
   half of no pair is DS_ERR_PARSE, as Mercury's `jr_unpaired_surrogate` is;
   the bytes are test_ds.m's `[LSTR.7.2.3]` json_text checks. PATH:
   parse_string_literal's `u` arm and hex4, under ds_json_parse. */
/* @spec [LSTR.7.2.3] */
static int test_lstr_7_2_3__surrogate_pairs(void)
{
    static const struct { const char *text; const char *utf8; } pairs[] = {
        { "\"\\ud800\\udf48\"", "\xF0\x90\x8D\x88" },     /* U+10348 */
        { "\"\\udbff\\udfff\"", "\xF4\x8F\xBF\xBF" },     /* U+10FFFF */
    };
    ds_json_t *t = NULL;
    for (size_t i = 0; i < sizeof pairs / sizeof pairs[0]; i++) {
        if (parse_and_check_kind(pairs[i].text, DS_JSON_STRING, &t)) return 1;
        if (strcmp(t->v.s, pairs[i].utf8) != 0) {
            fprintf(stderr, "FAIL: [LSTR.7.2.3] %s did not read back as its "
                    "codepoint's four UTF-8 bytes\n", pairs[i].text);
            ds_json_free(t);
            return 1;
        }
        ds_json_free(t);
    }
    /* Upper-case hex, between other characters, and as an object key. */
    static const char mixed[] = "{\"a\\uD800\\uDF48b\": \"x\\ud800\\udf48\"}";
    if (parse_and_check_kind(mixed, DS_JSON_OBJECT, &t)) return 1;
    ds_json_free(t);

    static const struct { const char *label; const char *text; } refused[] = {
        { "a lone high surrogate",               "\"\\ud800\"" },
        { "a lone low surrogate",                "\"\\udf48\"" },
        { "a low surrogate before a high",       "\"\\udf48\\ud800\"" },
        { "a high surrogate, then a non-escape", "\"\\ud800x\"" },
        { "a high surrogate, then a BMP escape", "\"\\ud800\\u0041\"" },
        { "a high surrogate, then a cut escape", "\"\\ud800\\udf4\"" },
        { "a lone high surrogate in a key",      "{\"\\ud800\": 1}" },
    };
    for (size_t i = 0; i < sizeof refused / sizeof refused[0]; i++) {
        t = NULL;
        ds_result_t r = ds_json_parse(refused[i].text, strlen(refused[i].text),
                                      &t);
        if (expect_detail(refused[i].label, r, DS_ERR_PARSE,
                          "JSON string has a surrogate escape that is half "
                          "of no pair (LSTR.7.2.3)")) return 1;
        if (t != NULL) {
            fprintf(stderr, "FAIL: [LSTR.7.2.3] %s: a refused parse set *out\n",
                    refused[i].label);
            return 1;
        }
    }
    return 0;
}

int main(void)
{
    ds_result_t r;
    ds_json_t  *t = NULL;

    if (parse_and_check_kind("null", DS_JSON_NULL, &t)) return 1;
    ds_json_free(t);

    if (parse_and_check_kind("true", DS_JSON_BOOL, &t)) return 1;
    if (t->v.b != true) { fprintf(stderr, "FAIL: true→%d\n", t->v.b); return 1; }
    ds_json_free(t);

    if (parse_and_check_kind("false", DS_JSON_BOOL, &t)) return 1;
    if (t->v.b != false) { fprintf(stderr, "FAIL: false→%d\n", t->v.b); return 1; }
    ds_json_free(t);

    if (parse_and_check_kind("42", DS_JSON_INT, &t)) return 1;
    if (t->v.i != 42) { fprintf(stderr, "FAIL: 42→%lld\n", (long long) t->v.i); return 1; }
    ds_json_free(t);

    if (parse_and_check_kind("-7", DS_JSON_INT, &t)) return 1;
    if (t->v.i != -7) { fprintf(stderr, "FAIL: -7→%lld\n", (long long) t->v.i); return 1; }
    ds_json_free(t);

    if (parse_and_check_kind("3.14", DS_JSON_FLOAT, &t)) return 1;
    if (t->v.f < 3.139 || t->v.f > 3.141) {
        fprintf(stderr, "FAIL: 3.14→%g\n", t->v.f);
        return 1;
    }
    ds_json_free(t);

    if (parse_and_check_kind("1e3", DS_JSON_FLOAT, &t)) return 1;
    if (t->v.f != 1000.0) { fprintf(stderr, "FAIL: 1e3→%g\n", t->v.f); return 1; }
    ds_json_free(t);

    /* [LDET.3.2.7]: a whole float keeps its Float kind on decode. With the
       serializer's ".0" (test_float_fmt), 42.0 round-trips as a Float. */
    if (parse_and_check_kind("42.0", DS_JSON_FLOAT, &t)) return 1;
    if (t->v.f != 42.0) { fprintf(stderr, "FAIL: 42.0→%g\n", t->v.f); return 1; }
    ds_json_free(t);

    /* [LGRA.5.8.8]: -0.0 keeps its Float kind and loses its sign. A float
       zero in a Json value is +0.0, folded where the value comes into being. */
    if (parse_and_check_kind("-0.0", DS_JSON_FLOAT, &t)) return 1;
    if (t->v.f != 0.0 || signbit(t->v.f)) {
        fprintf(stderr, "FAIL: -0.0→%g (signbit=%d), want +0.0\n",
                t->v.f, signbit(t->v.f));
        return 1;
    }
    ds_json_free(t);

    /* The public builder folds the same way. */
    {
        ds_json_t *z = NULL;
        if (expect_ok("new_float(-0.0)", ds_json_new_float(-0.0, &z))) return 1;
        if (z->kind != DS_JSON_FLOAT || z->v.f != 0.0 || signbit(z->v.f)) {
            fprintf(stderr, "FAIL: ds_json_new_float(-0.0) kept its sign\n");
            ds_json_free(z);
            return 1;
        }
        ds_json_free(z);
    }

    /* And a nonzero negative is untouched: the fold is for zero only. */
    if (parse_and_check_kind("-1.5", DS_JSON_FLOAT, &t)) return 1;
    if (t->v.f != -1.5) { fprintf(stderr, "FAIL: -1.5→%g\n", t->v.f); return 1; }
    ds_json_free(t);

    /* A large whole float at the fixed/scientific boundary (ds_fmt_float emits
       "1000000000000000.0" for 1e15, kept fixed with ".0") also round-trips as
       Float, not Int. */
    if (parse_and_check_kind("1000000000000000.0", DS_JSON_FLOAT, &t)) return 1;
    if (t->v.f != 1e15) { fprintf(stderr, "FAIL: 1e15→%g\n", t->v.f); return 1; }
    ds_json_free(t);

    if (parse_and_check_kind("\"hello\"", DS_JSON_STRING, &t)) return 1;
    if (strcmp(t->v.s, "hello") != 0) {
        fprintf(stderr, "FAIL: hello→%s\n", t->v.s);
        return 1;
    }
    ds_json_free(t);

    if (parse_and_check_kind("\"a\\n\\tb\\\"c\"", DS_JSON_STRING, &t)) return 1;
    if (strcmp(t->v.s, "a\n\tb\"c") != 0) {
        fprintf(stderr, "FAIL: escaped string mismatch: got `%s`\n", t->v.s);
        return 1;
    }
    ds_json_free(t);

    if (parse_and_check_kind("\"\\u0041\\u00e9\"", DS_JSON_STRING, &t)) return 1;
    /* "Aé" — 'A' (0x41) + 'é' (0xC3 0xA9) = 3 bytes */
    if (t->v.s[0] != 'A' ||
        (unsigned char) t->v.s[1] != 0xC3 ||
        (unsigned char) t->v.s[2] != 0xA9 ||
        t->v.s[3] != '\0') {
        fprintf(stderr, "FAIL: \\u escape decode wrong\n");
        return 1;
    }
    ds_json_free(t);

    if (parse_and_check_kind("[]", DS_JSON_ARRAY, &t)) return 1;
    if (t->v.arr.n != 0) { fprintf(stderr, "FAIL: empty array n=%u\n", t->v.arr.n); return 1; }
    ds_json_free(t);

    if (parse_and_check_kind("[1, 2, 3]", DS_JSON_ARRAY, &t)) return 1;
    if (t->v.arr.n != 3) { fprintf(stderr, "FAIL: array n=%u, want 3\n", t->v.arr.n); return 1; }
    if (t->v.arr.items[0]->kind != DS_JSON_INT || t->v.arr.items[0]->v.i != 1 ||
        t->v.arr.items[1]->v.i != 2 || t->v.arr.items[2]->v.i != 3) {
        fprintf(stderr, "FAIL: array element values\n"); return 1;
    }
    ds_json_free(t);

    if (parse_and_check_kind("{}", DS_JSON_OBJECT, &t)) return 1;
    if (t->v.obj.n != 0) { fprintf(stderr, "FAIL: empty object n=%u\n", t->v.obj.n); return 1; }
    ds_json_free(t);

    if (parse_and_check_kind("{\"x\": 5, \"y\": \"z\"}",
                              DS_JSON_OBJECT, &t)) return 1;
    if (t->v.obj.n != 2) { fprintf(stderr, "FAIL: object n=%u, want 2\n", t->v.obj.n); return 1; }
    if (strcmp(t->v.obj.kvs[0].key, "x") != 0 ||
        t->v.obj.kvs[0].value->kind != DS_JSON_INT ||
        t->v.obj.kvs[0].value->v.i != 5) {
        fprintf(stderr, "FAIL: object[0] mismatch\n"); return 1;
    }
    if (strcmp(t->v.obj.kvs[1].key, "y") != 0 ||
        t->v.obj.kvs[1].value->kind != DS_JSON_STRING ||
        strcmp(t->v.obj.kvs[1].value->v.s, "z") != 0) {
        fprintf(stderr, "FAIL: object[1] mismatch\n"); return 1;
    }
    ds_json_free(t);

    const char *complex_text =
        "{"
        "\"body\": {"
        "  \"temperature\": 22.5,"
        "  \"forecast\": ["
        "    {\"max\": 30, \"min\": 15},"
        "    {\"max\": 28, \"min\": 14}"
        "  ]"
        "},"
        "\"alerts\": null"
        "}";
    r = ds_json_parse(complex_text, strlen(complex_text), &t);
    if (expect_ok("parse complex", r)) return 1;

    const ds_json_t *node = NULL;
    r = ds_json_get_path(t, "body.temperature", &node);
    if (expect_ok("get_path body.temperature", r)) return 1;
    if (node == NULL || node->kind != DS_JSON_FLOAT ||
        node->v.f < 22.49 || node->v.f > 22.51) {
        fprintf(stderr, "FAIL: body.temperature lookup\n");
        return 1;
    }

    r = ds_json_get_path(t, "body.forecast[0].max", &node);
    if (expect_ok("get_path body.forecast[0].max", r)) return 1;
    if (node == NULL || node->kind != DS_JSON_INT || node->v.i != 30) {
        fprintf(stderr, "FAIL: body.forecast[0].max lookup\n");
        return 1;
    }

    r = ds_json_get_path(t, "body.forecast[1].min", &node);
    if (expect_ok("get_path body.forecast[1].min", r)) return 1;
    if (node == NULL || node->kind != DS_JSON_INT || node->v.i != 14) {
        fprintf(stderr, "FAIL: body.forecast[1].min lookup\n");
        return 1;
    }

    r = ds_json_get_path(t, "alerts", &node);
    if (expect_ok("get_path alerts", r)) return 1;
    if (node == NULL || node->kind != DS_JSON_NULL) {
        fprintf(stderr, "FAIL: alerts lookup\n");
        return 1;
    }

    /* Soft fails: missing key, out-of-range index, wrong-kind step. */
    r = ds_json_get_path(t, "body.nonexistent", &node);
    if (expect_ok("get_path miss", r)) return 1;
    if (node != NULL) {
        fprintf(stderr, "FAIL: missing key returned non-NULL\n");
        return 1;
    }
    r = ds_json_get_path(t, "body.forecast[99].max", &node);
    if (expect_ok("get_path index miss", r)) return 1;
    if (node != NULL) {
        fprintf(stderr, "FAIL: out-of-range index returned non-NULL\n");
        return 1;
    }
    r = ds_json_get_path(t, "body.temperature.deeper", &node);
    if (expect_ok("get_path on float", r)) return 1;
    if (node != NULL) {
        fprintf(stderr, "FAIL: descending into float returned non-NULL\n");
        return 1;
    }

    char  *text  = NULL;
    size_t tlen  = 0;
    r = ds_json_serialize(t, &text, &tlen);
    if (expect_ok("serialize", r)) return 1;
    if (text == NULL || tlen == 0) {
        fprintf(stderr, "FAIL: serialize returned empty\n"); return 1;
    }

    ds_json_t *t2 = NULL;
    r = ds_json_parse(text, tlen, &t2);
    if (expect_ok("re-parse serialized", r)) return 1;

    r = ds_json_get_path(t2, "body.forecast[0].max", &node);
    if (expect_ok("get_path on re-parsed", r)) return 1;
    if (node == NULL || node->v.i != 30) {
        fprintf(stderr, "FAIL: round-trip lost data\n");
        return 1;
    }

    free(text);
    ds_json_free(t2);
    ds_json_free(t);

    r = ds_json_parse("{ unterminated", 15, &t);
    if (expect_status("parse error: bad object",
                      r, DS_ERR_PARSE)) return 1;

    r = ds_json_parse("{\"x\": 5} extra", 14, &t);
    if (expect_status("parse error: trailing junk",
                      r, DS_ERR_PARSE)) return 1;

    r = ds_json_parse("[1, 2,]", 7, &t);
    if (expect_status("parse error: trailing comma",
                      r, DS_ERR_PARSE)) return 1;

    r = ds_json_parse("true", 4, NULL);
    if (expect_status("parse NULL out", r, DS_ERR_INVAL)) return 1;
    r = ds_json_parse(NULL, 4, &t);
    if (expect_status("parse NULL text with len > 0",
                      r, DS_ERR_INVAL)) return 1;

    r = ds_json_serialize(NULL, &text, NULL);
    if (expect_status("serialize NULL tree", r, DS_ERR_INVAL)) return 1;

    /* [LGRA.5.8.10]: a Float literal that rounds to an infinity is
       malformed text, refused with its own detail, and makes no tree. */
    t = (ds_json_t *) 0x1;
    r = ds_json_parse("1e400", 5, &t);
    if (expect_status("parse 1e400", r, DS_ERR_PARSE)) return 1;
    if (t != NULL) { fprintf(stderr, "FAIL: parse 1e400 left a tree\n"); return 1; }
    if (r.detail == NULL
            || strcmp(r.detail, "JSON float literal outside the double range") != 0) {
        fprintf(stderr, "FAIL: parse 1e400 detail `%s`\n",
                r.detail ? r.detail : "(null)");
        return 1;
    }
    r = ds_json_parse("{\"x\": -1e400}", 13, &t);
    if (expect_status("parse nested -1e400", r, DS_ERR_PARSE)) return 1;

    /* ds_json_serialize refuses a non-finite Float with DS_ERR_JSON_NONFINITE.
       No public call makes one ([LGRA.5.8.10]) and rete/adapters.c leans on
       the refusal, so the infinity is written into a parsed leaf. */
    r = ds_json_parse("1.5", 3, &t);
    if (expect_ok("parse 1.5", r)) return 1;
    if (t == NULL || t->kind != DS_JSON_FLOAT) {
        fprintf(stderr, "FAIL: 1.5 did not parse to a FLOAT\n");
        return 1;
    }
    t->v.f = INFINITY;
    text = NULL;
    r = ds_json_serialize(t, &text, &tlen);
    if (expect_status("serialize +Inf scalar", r, DS_ERR_JSON_NONFINITE))
        return 1;
    if (text != NULL) {
        fprintf(stderr, "FAIL: serialize of Inf emitted `%s`, want no output\n",
                text);
        return 1;
    }
    ds_json_free(t);

    /* And nested in an object. */
    r = ds_json_parse("{\"x\": 1.5, \"y\": 2}", 18, &t);
    if (expect_ok("parse {x:1.5,y:2}", r)) return 1;
    {
        const ds_json_t *x = NULL;
        if (expect_ok("get_path x", ds_json_get_path(t, "x", &x))) return 1;
        ((ds_json_t *) x)->v.f = INFINITY;
    }
    text = NULL;
    r = ds_json_serialize(t, &text, &tlen);
    if (expect_status("serialize nested Inf", r, DS_ERR_JSON_NONFINITE))
        return 1;
    if (text != NULL) {
        fprintf(stderr, "FAIL: nested-Inf serialize emitted `%s`\n", text);
        return 1;
    }
    ds_json_free(t);

    r = ds_json_get_path(NULL, "x", &node);
    if (expect_status("get_path NULL root", r, DS_ERR_INVAL)) return 1;

    /* A typed getter's mismatch detail is a literal: the first still reads
       right after a second mismatch. */
    {
        ds_json_t *str_node = NULL, *arr_node = NULL;
        if (parse_and_check_kind("\"s\"", DS_JSON_STRING, &str_node)) return 1;
        if (parse_and_check_kind("[1]", DS_JSON_ARRAY, &arr_node)) return 1;
        int64_t     iv = 0;
        bool        bv = false;
        ds_result_t r1 = ds_json_get_int(str_node, &iv);
        ds_result_t r2 = ds_json_get_bool(arr_node, &bv);
        if (expect_status("get_int on a string", r1, DS_ERR_INVAL)) return 1;
        if (expect_status("get_bool on an array", r2, DS_ERR_INVAL)) return 1;
        if (r1.detail == NULL
                || strcmp(r1.detail, "node is string, not int") != 0) {
            fprintf(stderr, "FAIL: get_int mismatch detail `%s`\n",
                    r1.detail ? r1.detail : "(null)");
            return 1;
        }
        if (r2.detail == NULL
                || strcmp(r2.detail, "node is array, not bool") != 0) {
            fprintf(stderr, "FAIL: get_bool mismatch detail `%s`\n",
                    r2.detail ? r2.detail : "(null)");
            return 1;
        }
        ds_result_t rn = ds_json_get_int(NULL, &iv);
        if (expect_status("get_int on NULL", rn, DS_ERR_INVAL)) return 1;
        if (rn.detail == NULL || strcmp(rn.detail,
                "ds_json_get_int: node must not be null") != 0) {
            fprintf(stderr, "FAIL: get_int NULL detail `%s`\n",
                    rn.detail ? rn.detail : "(null)");
            return 1;
        }
        ds_json_free(str_node);
        ds_json_free(arr_node);
    }

    r = ds_json_free(NULL);
    if (expect_ok("free(NULL)", r)) return 1;

    if (test_int_range()) return 1;
    if (test_parse_gaps()) return 1;
    if (test_lstr_7_2_3__surrogate_pairs()) return 1;
    if (test_lstr_1_1_no_nul()) return 1;
    if (test_lgra_5_8_7_duplicate_keys()) return 1;
    if (test_parse_depth()) return 1;
    if (test_build_depth()) return 1;
    if (test_build_links()) return 1;
    if (test_parse_limits()) return 1;
    if (test_build_limits()) return 1;
    if (test_object_set_key_length()) return 1;
    if (test_within_limits()) return 1;
    if (test_lstr_8_5__json_text_and_builders()) return 1;

    printf("test_json_basic: OK\n");
    return 0;
}
