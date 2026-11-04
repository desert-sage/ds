/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * fuzz_json_text.c -- coverage-guided fuzzing of libds's JSON parser, which
 * reads untrusted text wherever a host hands libds a Json slot as text.
 *
 * WHAT IT DRIVES, by name ([STYL.5.10.8]), all through libds.h: ds_json_parse
 * over the input; on a tree it accepts, every accessor (ds_json_get_kind, the
 * typed getters, ds_json_array_len / _at, ds_json_object_len / _at / _get),
 * ds_json_clone, ds_json_serialize, and ds_json_parse again over what
 * serialize wrote. An input holding a NUL is also cut there: the bytes before
 * it are parsed the same way and the bytes after it are a path for
 * ds_json_get_path over that tree.
 *
 * WHAT IT ASSERTS, beyond "did not crash" (ASan judges memory, and every tree
 * and buffer is freed, so the refusal paths' leaks are LSan's in REPLAY):
 *
 *   1. A REFUSAL IS A DOCUMENTED ONE. ds_json_parse answers DS_OK with a tree,
 *      or DS_ERR_PARSE, DS_ERR_JSON_LIMIT, DS_ERR_ENCODING (text that is not
 *      well-formed UTF-8, [LSTR.8.5]) or DS_ERR_OOM with *out NULL, as
 *      libds.h states; text longer than DS_JSON_MAX_TEXT_BYTES is
 *      DS_ERR_JSON_LIMIT.
 *   2. NO ACCEPTED TREE EXCEEDS A LIMIT. Its depth, its node count and its
 *      string bytes (keys and values, summed) are within DS_JSON_MAX_DEPTH,
 *      _NODES and _STRING_BYTES, as libds.h promises of every tree libds holds.
 *      And it holds no non-finite Float: a literal that rounds to an infinity
 *      is malformed ([LGRA.5.8.10]), so `1e400` is DS_ERR_PARSE.
 *   3. THE ACCESSORS AGREE WITH THE TREE. Each node's typed getter for its own
 *      kind answers DS_OK and the others DS_ERR_INVAL; an index at the length
 *      is DS_ERR_NOT_FOUND; a string's length is its strlen and its byte at
 *      that length is NUL; an object's
 *      keys are distinct, and ds_json_object_get finds each one's own value.
 *   4. THE TEXT ROUND-TRIPS. serialize(t) is DS_OK (or DS_ERR_OOM). When it is
 *      within the text limit, parse(serialize(t)) is DS_OK and
 *      equal to t (Floats bit for bit, objects key by key), and serializing it
 *      again gives the same bytes: the canonical form is a fixed point. A
 *      clone is equal to t too. Past the text limit (escapes can grow a
 *      string sixfold), the re-parse is DS_ERR_JSON_LIMIT.
 *   5. A PATH LANDS IN ITS TREE. ds_json_get_path answers DS_OK or
 *      DS_ERR_INVAL, and a node it finds is one of the tree's own.
 *
 * REPLAY's VERDICTS. With DS_FUZZ_JSON_EXPECT set to `accept`, `parse`,
 * `limit` or `encoding`, the whole input must parse to DS_OK, DS_ERR_PARSE,
 * DS_ERR_JSON_LIMIT or DS_ERR_ENCODING respectively, so each seed directory
 * pins what its inputs are. The gate replays each directory under its verdict and reads
 * the count printed at exit, so a REPLAY that judged nothing fails the lane.
 */

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"

#define FAIL(why) do {                                          \
        fprintf(stderr, "fuzz_json_text: %s\n", (why));         \
        __builtin_trap();                                       \
    } while (0)

/* What the whole input must parse to, in REPLAY: -1 is no expectation
   (SEARCH), otherwise a ds_status_t. */
static int expect = -1;

/* Counted over the inputs judged, the empty one aside: libFuzzer runs an empty
   input before the corpus, and it is no seed. Printed at exit and read by the
   gate. */
static unsigned long judged, accepted, refused, round_tripped;

static void report_judged(void)
{
    fprintf(stderr, "fuzz_json_text: judged %lu input(s): %lu accepted, "
                    "%lu refused, %lu round-tripped\n",
            judged, accepted, refused, round_tripped);
}

int LLVMFuzzerInitialize(int *argc, char ***argv)
{
    (void) argc;
    (void) argv;
    const char *e = getenv("DS_FUZZ_JSON_EXPECT");
    if (e != NULL) {
        if (strcmp(e, "accept") == 0)     expect = DS_OK;
        else if (strcmp(e, "parse") == 0) expect = DS_ERR_PARSE;
        else if (strcmp(e, "limit") == 0) expect = DS_ERR_JSON_LIMIT;
        else if (strcmp(e, "encoding") == 0) expect = DS_ERR_ENCODING;
        else {
            /* A typo read as "no expectation" would pass every seed. */
            fprintf(stderr, "fuzz_json_text: DS_FUZZ_JSON_EXPECT=%s is not "
                            "accept, parse, limit or encoding\n", e);
            abort();
        }
    }
    if (atexit(report_judged) != 0) abort();
    return 0;
}

/* The tree's nodes, as the walk meets them, for property 5. The node limit
   bounds them; a tree over it fails property 2 before this fills. */
typedef struct {
    const ds_json_t *node[DS_JSON_MAX_NODES];
    size_t           nodes;
    size_t           depth;
    uint64_t         str_bytes;
} walk_t;

static void check_wrong_kind(const ds_json_t *n, ds_json_kind_t k)
{
    bool b; int64_t i; double f; const char *s; size_t len;
    if (k != DS_JSON_BOOL && ds_json_get_bool(n, &b).status != DS_ERR_INVAL)
        FAIL("ds_json_get_bool on another kind is not DS_ERR_INVAL");
    if (k != DS_JSON_INT && ds_json_get_int(n, &i).status != DS_ERR_INVAL)
        FAIL("ds_json_get_int on another kind is not DS_ERR_INVAL");
    if (k != DS_JSON_FLOAT && ds_json_get_float(n, &f).status != DS_ERR_INVAL)
        FAIL("ds_json_get_float on another kind is not DS_ERR_INVAL");
    if (k != DS_JSON_STRING
        && ds_json_get_string(n, &s, &len).status != DS_ERR_INVAL)
        FAIL("ds_json_get_string on another kind is not DS_ERR_INVAL");
    if (k != DS_JSON_ARRAY && ds_json_array_len(n, &len).status != DS_ERR_INVAL)
        FAIL("ds_json_array_len on another kind is not DS_ERR_INVAL");
    if (k != DS_JSON_OBJECT && ds_json_object_len(n, &len).status != DS_ERR_INVAL)
        FAIL("ds_json_object_len on another kind is not DS_ERR_INVAL");
}

static void walk(const ds_json_t *n, size_t level, walk_t *w)
{
    if (n == NULL) FAIL("a tree holds a NULL node");
    if (level > DS_JSON_MAX_DEPTH) FAIL("an accepted tree is over DS_JSON_MAX_DEPTH");
    if (w->nodes >= DS_JSON_MAX_NODES) FAIL("an accepted tree is over DS_JSON_MAX_NODES");
    w->node[w->nodes++] = n;
    if (level > w->depth) w->depth = level;

    ds_json_kind_t k;
    if (ds_json_get_kind(n, &k).status != DS_OK) FAIL("ds_json_get_kind refused a node");
    check_wrong_kind(n, k);
    switch (k) {
    case DS_JSON_NULL:
        return;
    case DS_JSON_BOOL: {
        bool b;
        if (ds_json_get_bool(n, &b).status != DS_OK) FAIL("ds_json_get_bool refused a Bool");
        return;
    }
    case DS_JSON_INT: {
        int64_t i;
        if (ds_json_get_int(n, &i).status != DS_OK) FAIL("ds_json_get_int refused an Int");
        return;
    }
    case DS_JSON_FLOAT: {
        double f;
        if (ds_json_get_float(n, &f).status != DS_OK) FAIL("ds_json_get_float refused a Float");
        if (!isfinite(f)) FAIL("an accepted tree holds a non-finite Float (LGRA.5.8.10)");
        return;
    }
    case DS_JSON_STRING: {
        const char *s = NULL;
        size_t      len = 0;
        if (ds_json_get_string(n, &s, &len).status != DS_OK || s == NULL)
            FAIL("ds_json_get_string refused a String");
        if (s[len] != '\0') FAIL("a String's byte at its length is not NUL");
        if (strlen(s) != len) FAIL("a String's length is not its strlen");
        w->str_bytes += len;
        break;
    }
    case DS_JSON_ARRAY: {
        size_t len = 0;
        if (ds_json_array_len(n, &len).status != DS_OK) FAIL("ds_json_array_len refused an Array");
        for (size_t i = 0; i < len; i++) {
            const ds_json_t *c = NULL;
            if (ds_json_array_at(n, i, &c).status != DS_OK) FAIL("ds_json_array_at refused an index below the length");
            walk(c, level + 1, w);
        }
        const ds_json_t *c = NULL;
        if (ds_json_array_at(n, len, &c).status != DS_ERR_NOT_FOUND)
            FAIL("ds_json_array_at at the length is not DS_ERR_NOT_FOUND");
        break;
    }
    case DS_JSON_OBJECT: {
        size_t len = 0;
        if (ds_json_object_len(n, &len).status != DS_OK) FAIL("ds_json_object_len refused an Object");
        for (size_t i = 0; i < len; i++) {
            const char      *key = NULL;
            size_t           key_len = 0;
            const ds_json_t *v = NULL;
            if (ds_json_object_at(n, i, &key, &key_len, &v).status != DS_OK || key == NULL)
                FAIL("ds_json_object_at refused an index below the length");
            if (key[key_len] != '\0' || strlen(key) != key_len)
                FAIL("an object key's length is not its strlen");
            for (size_t j = 0; j < i; j++) {
                const char *other = NULL;
                if (ds_json_object_at(n, j, &other, NULL, NULL).status != DS_OK)
                    FAIL("ds_json_object_at refused an index it answered before");
                if (strcmp(other, key) == 0) FAIL("an accepted object repeats a key");
            }
            const ds_json_t *found = NULL;
            if (ds_json_object_get(n, key, &found).status != DS_OK || found != v)
                FAIL("ds_json_object_get does not find a key's own value");
            w->str_bytes += key_len;
            walk(v, level + 1, w);
        }
        if (ds_json_object_at(n, len, NULL, NULL, NULL).status != DS_ERR_NOT_FOUND)
            FAIL("ds_json_object_at at the length is not DS_ERR_NOT_FOUND");
        break;
    }
    default:
        FAIL("ds_json_get_kind answered a kind libds.h does not name");
    }
    if (w->str_bytes > DS_JSON_MAX_STRING_BYTES)
        FAIL("an accepted tree is over DS_JSON_MAX_STRING_BYTES");
}

/* Structural equality, as [LFAC.2.5.1] reads Json: Floats bit for bit, so
   -0.0 and 0.0 differ, and objects key by key, since serialize reorders them.
   Both trees have passed walk(), so every accessor here is known to answer. */
static bool equal(const ds_json_t *a, const ds_json_t *b)
{
    ds_json_kind_t ka, kb;
    ds_json_get_kind(a, &ka);
    ds_json_get_kind(b, &kb);
    if (ka != kb) return false;
    switch (ka) {
    case DS_JSON_NULL:
        return true;
    case DS_JSON_BOOL: {
        bool x, y;
        ds_json_get_bool(a, &x);
        ds_json_get_bool(b, &y);
        return x == y;
    }
    case DS_JSON_INT: {
        int64_t x, y;
        ds_json_get_int(a, &x);
        ds_json_get_int(b, &y);
        return x == y;
    }
    case DS_JSON_FLOAT: {
        double x, y;
        ds_json_get_float(a, &x);
        ds_json_get_float(b, &y);
        return memcmp(&x, &y, sizeof x) == 0;
    }
    case DS_JSON_STRING: {
        const char *x, *y;
        size_t      nx, ny;
        ds_json_get_string(a, &x, &nx);
        ds_json_get_string(b, &y, &ny);
        return nx == ny && memcmp(x, y, nx) == 0;
    }
    case DS_JSON_ARRAY: {
        size_t nx, ny;
        ds_json_array_len(a, &nx);
        ds_json_array_len(b, &ny);
        if (nx != ny) return false;
        for (size_t i = 0; i < nx; i++) {
            const ds_json_t *x, *y;
            ds_json_array_at(a, i, &x);
            ds_json_array_at(b, i, &y);
            if (!equal(x, y)) return false;
        }
        return true;
    }
    case DS_JSON_OBJECT: {
        size_t nx, ny;
        ds_json_object_len(a, &nx);
        ds_json_object_len(b, &ny);
        if (nx != ny) return false;
        for (size_t i = 0; i < nx; i++) {
            const char      *key;
            const ds_json_t *x, *y = NULL;
            ds_json_object_at(a, i, &key, NULL, &x);
            if (ds_json_object_get(b, key, &y).status != DS_OK) return false;
            if (!equal(x, y)) return false;
        }
        return true;
    }
    }
    return false;
}

/* Properties 4 and 5 over an accepted tree. */
static void check_tree(const ds_json_t *t, const char *path)
{
    walk_t w;
    memset(&w, 0, sizeof w);
    walk(t, 1, &w);

    ds_json_t *copy = NULL;
    ds_result_t r = ds_json_clone(t, &copy);
    if (r.status == DS_OK) {
        if (copy == NULL || !equal(t, copy)) FAIL("a clone is not equal to its tree");
        ds_json_free(copy);
    } else if (r.status != DS_ERR_OOM) {
        FAIL("ds_json_clone answered a status libds.h does not document");
    }

    char  *text = NULL;
    size_t len = 0;
    r = ds_json_serialize(t, &text, &len);
    if (r.status == DS_OK) {
        if (text == NULL || text[len] != '\0' || strlen(text) != len)
            FAIL("serialize's length is not its text's strlen");
        ds_json_t *again = NULL;
        r = ds_json_parse(text, len, &again);
        if (len > DS_JSON_MAX_TEXT_BYTES) {
            if (r.status != DS_ERR_JSON_LIMIT)
                FAIL("a re-parse past DS_JSON_MAX_TEXT_BYTES is not DS_ERR_JSON_LIMIT");
        } else if (r.status == DS_OK) {
            if (!equal(t, again)) FAIL("parse(serialize(t)) is not t");
            char  *text2 = NULL;
            size_t len2 = 0;
            r = ds_json_serialize(again, &text2, &len2);
            if (r.status == DS_OK) {
                if (len2 != len || memcmp(text, text2, len) != 0)
                    FAIL("the canonical text is not a fixed point");
                round_tripped++;
            } else if (r.status != DS_ERR_OOM) {
                FAIL("a re-parsed tree did not serialize");
            }
            ds_free(text2);
        } else if (r.status != DS_ERR_OOM) {
            FAIL("libds refused the text it serialized");
        }
        ds_json_free(again);
    } else if (r.status != DS_ERR_OOM) {
        FAIL("ds_json_serialize answered a status libds.h does not document");
    }
    ds_free(text);

    if (path != NULL) {
        const ds_json_t *found = NULL;
        r = ds_json_get_path(t, path, &found);
        if (r.status == DS_OK) {
            if (found != NULL) {
                bool own = false;
                for (size_t i = 0; i < w.nodes && !own; i++) own = w.node[i] == found;
                if (!own) FAIL("ds_json_get_path found a node outside its tree");
            }
        } else if (r.status != DS_ERR_INVAL) {
            FAIL("ds_json_get_path answered a status libds.h does not document");
        }
    }
}

/* Property 1, then the rest over what it accepts. Returns the status. */
static int check_text(const char *text, size_t len, const char *path)
{
    ds_json_t  *t = NULL;
    ds_result_t r = ds_json_parse(text, len, &t);
    if (r.status == DS_OK) {
        if (t == NULL) FAIL("ds_json_parse answered DS_OK with no tree");
        if (len > DS_JSON_MAX_TEXT_BYTES) FAIL("text over DS_JSON_MAX_TEXT_BYTES parsed");
        check_tree(t, path);
        ds_json_free(t);
    } else {
        if (t != NULL) FAIL("a refused parse left a tree in *out");
        if (r.status != DS_ERR_PARSE && r.status != DS_ERR_JSON_LIMIT
            && r.status != DS_ERR_ENCODING && r.status != DS_ERR_OOM)
            FAIL("ds_json_parse answered a status libds.h does not document");
        if (len > DS_JSON_MAX_TEXT_BYTES && r.status != DS_ERR_JSON_LIMIT)
            FAIL("text over DS_JSON_MAX_TEXT_BYTES is not DS_ERR_JSON_LIMIT");
    }
    return r.status;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    int status = check_text((const char *) data, size, NULL);
    if (size > 0) {
        judged++;
        if (status == DS_OK) accepted++;
        else refused++;
        if (expect != -1 && status != expect) FAIL("the input's verdict is not the one its seed directory names");
    }

    const uint8_t *nul = memchr(data, '\0', size);
    if (nul != NULL) {
        size_t cut = (size_t) (nul - data);
        size_t tail = size - cut - 1u;
        char  *path = malloc(tail + 1u);
        if (path == NULL) return 0;
        memcpy(path, nul + 1, tail);
        path[tail] = '\0';
        check_text((const char *) data, cut, path);
        free(path);
    }
    return 0;
}
