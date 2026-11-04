/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * internal/json.h — the private layout of `struct ds_json`, opaque at the library
 * boundary ([IDAT.1.2], [IARC.1.15]).
 */
#ifndef DS_LIBDS_INTERNAL_JSON_H
#define DS_LIBDS_INTERNAL_JSON_H

#include "libds.h"

typedef struct ds_json_kv {
    const char *key;     /* owned by tree */
    ds_json_t  *value;   /* owned by tree */
} ds_json_kv_t;

/*
 * `parent`, `height`, `nodes` and `str_bytes` hold the tree limits ([LGRA.5.8.6]). Every
 * walk over a tree recurses, so the depth cap bounds the stack, and a caller keeps a
 * child's pointer after the transfer and may append to it later: an append measures
 * the real depth by walking up to the root, and raises every ancestor's counts.
 *
 * Only json.c constructs or links nodes.
 */
struct ds_json {
    ds_json_kind_t kind;
    ds_json_t     *parent;  /* the owning container; NULL for a root. Not owned. */
    uint32_t       height;  /* levels in this subtree: a scalar or an empty
                               container is 1, a container 1 + its tallest child */
    uint32_t       nodes;   /* scalars, arrays and objects in this subtree, this
                               node included */
    uint32_t       str_bytes; /* bytes of every string value in this subtree and
                                 of every key of every object in it */
    union {
        bool         b;
        int64_t      i;
        double       f;
        const char  *s;        /* owned; valid for tree lifetime */
        struct {
            ds_json_t **items; /* owned */
            uint32_t    n;
        } arr;
        struct {
            ds_json_kv_t *kvs; /* owned */
            uint32_t      n;
        } obj;
    } v;
};

/*
 * A refusal under [LGRA.5.8.6]. A parse stops at the first limit crossed, in document
 * order. A host refusal is DS_ERR_JSON_LIMIT and nothing more, so this reaches no stream
 * and no integrator.
 */
typedef enum {
    DS_JSON_LIMIT_NONE         = 0,
    DS_JSON_LIMIT_DEPTH        = 1,
    DS_JSON_LIMIT_NODES        = 2,
    DS_JSON_LIMIT_STRING_BYTES = 3,
    DS_JSON_LIMIT_TEXT_BYTES   = 4,
} ds_json_limit_t;

typedef struct ds_json_breach {
    ds_json_limit_t cap;
    uint64_t        limit;
    uint64_t        observed;
} ds_json_breach_t;

/*
 * ds_json_parse that also says WHICH limit refused the text. On
 * DS_ERR_JSON_LIMIT, *breach names it; on any other result, breach->cap is
 * DS_JSON_LIMIT_NONE. `breach` may be NULL.
 *
 * `text_limit` false skips DS_JSON_MAX_TEXT_BYTES and keeps the other three, for text
 * the engine serialized from a value it held: a control character serializes to six
 * bytes, so that text can exceed the limit.
 */
ds_result_t ds_json_parse_limited(const char *text, size_t len, ds_json_t **out,
                                  ds_json_breach_t *breach, bool text_limit);

/*
 * ds_json_parse_limited with the text limit given. SIZE_MAX applies none. A received
 * FactExternal's Json field is parsed at DS_JSON_MAX_FX_TEXT_BYTES ([LGRA.5.8.6]).
 */
ds_result_t ds_json_parse_capped(const char *text, size_t len, ds_json_t **out,
                                 ds_json_breach_t *breach, size_t max_text);

/* O(1). For the boundary checks that must not assume where a tree came from. */
bool ds_json_within_limits(const ds_json_t *tree, ds_json_breach_t *breach);

/* ds_json_get_path over `len` bytes of `path`, which need not be followed by a NUL. */
ds_result_t ds_json_get_path_n(const ds_json_t  *root,
                               const char       *path,
                               size_t            len,
                               const ds_json_t **out);

/* [LSTR.8.5]: every string value and object key. NULL is true. */
bool ds_json_utf8_well_formed(const ds_json_t *tree);

/* [LFAC.2.5.1]: an object compares by its key set, in any order. */
bool     ds_json_deep_equal(const ds_json_t *a, const ds_json_t *b);
uint32_t ds_json_deep_hash(const ds_json_t *tree);

#endif /* DS_LIBDS_INTERNAL_JSON_H */
