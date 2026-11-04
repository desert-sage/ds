/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * json.c — the Json value: parser, serializer, path lookup, accessors, builders.
 *
 * Every node is its own malloc ([IARC.1.13]); keys and strings are heap copies the
 * tree owns.
 */
#include <ctype.h>
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "internal/json.h"
#include "ds_alloc.h"
#include "ds_text.h"
#include "float_fmt.h"

typedef struct {
    const char *cur;
    const char *end;
    uint32_t    depth;  /* the level of the value being parsed; the root is 1 */
    uint32_t    nodes;  /* values begun so far, in document order */
    uint64_t    str_bytes; /* bytes of every key and string value read so far */
    const char *why;    /* a refusal's detail: a literal */
    ds_json_breach_t breach; /* the first [LGRA.5.8.6] limit crossed, if any */
} json_parser_t;

static void json_breach(json_parser_t *p, ds_json_limit_t cap, uint64_t limit,
                        uint64_t observed, const char *why)
{
    if (p->breach.cap == DS_JSON_LIMIT_NONE) {
        p->breach.cap      = cap;
        p->breach.limit    = limit;
        p->breach.observed = observed;
        p->why             = why;
    }
}

typedef struct {
    char  *buf;
    size_t len;
    size_t cap;
    bool   oom;
    bool   nonfinite;
} json_buf_t;

static ds_json_t *parse_value(json_parser_t *p);
static ds_json_t *json_new_node(ds_json_kind_t kind);
static ds_json_t *json_new_float_node(double f);
static void       json_adopt(ds_json_t *container, ds_json_t *child,
                             uint32_t key_bytes);
static void       free_node(ds_json_t *node);
static bool       buf_append(json_buf_t *b, const char *s, size_t n);
static bool       serialize_node(json_buf_t *b, const ds_json_t *node);

static void skip_ws(json_parser_t *p)
{
    while (p->cur < p->end) {
        char c = *p->cur;
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            p->cur++;
        } else {
            break;
        }
    }
}

static bool peek_char(const json_parser_t *p, char c)
{
    return p->cur < p->end && *p->cur == c;
}

static bool consume_literal(json_parser_t *p, const char *lit)
{
    size_t n = strlen(lit);
    if ((size_t) (p->end - p->cur) < n) return false;
    if (memcmp(p->cur, lit, n) != 0) return false;
    p->cur += n;
    return true;
}

/* A loop: the microcontroller rows' closed world admits no memchr. */
static bool has_nul(const char *s, size_t n)
{
    for (size_t i = 0; i < n; i++)
        if (s[i] == '\0') return true;
    return false;
}

static int hex_digit(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return 10 + c - 'a';
    if (c >= 'A' && c <= 'F') return 10 + c - 'A';
    return -1;
}

/* [LSTR.7.2.3]. A fixture's `message_contains` reads this text in both runtimes. */
#define UNPAIRED_SURROGATE \
    "JSON string has a surrogate escape that is half of no pair (LSTR.7.2.3)"

/* False, unmoved, when there are not four hex digits at p->cur. */
static bool hex4(json_parser_t *p, uint32_t *out)
{
    if (p->end - p->cur < 4) return false;
    uint32_t v = 0;
    for (int i = 0; i < 4; i++) {
        int h = hex_digit(p->cur[i]);
        if (h < 0) return false;
        v = (v << 4) | (uint32_t) h;
    }
    p->cur += 4;
    *out = v;
    return true;
}

static char *parse_string_literal(json_parser_t *p)
{
    if (!peek_char(p, '"')) return NULL;
    p->cur++;

    /* Decoding never grows a string, so the source span bounds the output. It is
       capped at the string bytes the document has left, since text a runtime re-reads
       is not text-limited ([LGRA.5.8.6]); a string over the cap grows below.

       A backslash steps over its escaped byte only when there is one: one past
       `p->end` is a pointer C does not let us form (C11 6.5.6p8). */
    const char *q = p->cur;
    while (q < p->end && *q != '"')
        q += (*q == '\\' && p->end - q > 1) ? 2 : 1;
    uint64_t span   = (uint64_t) (q - p->cur);
    uint64_t budget = DS_JSON_MAX_STRING_BYTES > p->str_bytes
                    ? DS_JSON_MAX_STRING_BYTES - p->str_bytes : 0;
    size_t cap = (size_t) (span < budget ? span : budget) + 1;
    char  *out = DS_MALLOC(cap);
    if (out == NULL) return NULL;
    size_t out_n = 0;

    while (p->cur < p->end) {
        char c = *p->cur;
        if (c == '"') {
            p->cur++;
            /* [LGRA.5.8.6]: the decoded bytes. `\u0000` is refused below, so the
               stored string's strlen is this out_n. */
            p->str_bytes += out_n;
            if (p->str_bytes > DS_JSON_MAX_STRING_BYTES) {
                json_breach(p, DS_JSON_LIMIT_STRING_BYTES,
                            DS_JSON_MAX_STRING_BYTES, p->str_bytes,
                            "JSON strings exceed DS_JSON_MAX_STRING_BYTES");
                goto fail;
            }
            /* The tree keeps this buffer for the value's life. A refused shrink
               keeps the larger one. */
            if (out_n + 1 < cap) {
                char *fitted = DS_REALLOC(out, out_n + 1);
                if (fitted != NULL) out = fitted;
            }
            out[out_n] = '\0';
            return out;
        }
        if (c == '\\') {
            p->cur++;
            if (p->cur >= p->end) goto fail;
            char esc = *p->cur++;
            char emit[4];
            int  emit_n = 1;
            switch (esc) {
            case '"': emit[0] = '"'; break;
            case '\\': emit[0] = '\\'; break;
            case '/': emit[0] = '/'; break;
            case 'b': emit[0] = '\b'; break;
            case 'f': emit[0] = '\f'; break;
            case 'n': emit[0] = '\n'; break;
            case 'r': emit[0] = '\r'; break;
            case 't': emit[0] = '\t'; break;
            case 'u': {
                uint32_t cp = 0;
                if (!hex4(p, &cp)) goto fail;
                /* [LSTR.7.2.3], RFC 8259 §7: a `\u` names one UTF-16 code unit. */
                if (cp >= 0xDC00 && cp <= 0xDFFF) {
                    p->why = UNPAIRED_SURROGATE;
                    goto fail;
                }
                if (cp >= 0xD800 && cp <= 0xDBFF) {
                    uint32_t lo = 0;
                    if (p->end - p->cur < 2 || p->cur[0] != '\\'
                            || p->cur[1] != 'u') {
                        p->why = UNPAIRED_SURROGATE;
                        goto fail;
                    }
                    p->cur += 2;
                    if (!hex4(p, &lo) || lo < 0xDC00 || lo > 0xDFFF) {
                        p->why = UNPAIRED_SURROGATE;
                        goto fail;
                    }
                    cp = 0x10000u + ((cp - 0xD800u) << 10) + (lo - 0xDC00u);
                }
                /* [LSTR.1.1], in a value and in a key alike. */
                if (cp == 0) {
                    p->why = "JSON string contains \\u0000; an embedded NUL "
                             "is not supported";
                    goto fail;
                }
                if (cp < 0x80) {
                    emit[0] = (char) cp;
                    emit_n = 1;
                } else if (cp < 0x800) {
                    emit[0] = (char) (0xC0 | (cp >> 6));
                    emit[1] = (char) (0x80 | (cp & 0x3F));
                    emit_n = 2;
                } else if (cp < 0x10000) {
                    emit[0] = (char) (0xE0 | (cp >> 12));
                    emit[1] = (char) (0x80 | ((cp >> 6) & 0x3F));
                    emit[2] = (char) (0x80 | (cp & 0x3F));
                    emit_n = 3;
                } else {
                    emit[0] = (char) (0xF0 | (cp >> 18));
                    emit[1] = (char) (0x80 | ((cp >> 12) & 0x3F));
                    emit[2] = (char) (0x80 | ((cp >> 6) & 0x3F));
                    emit[3] = (char) (0x80 | (cp & 0x3F));
                    emit_n = 4;
                }
                break;
            }
            default:
                goto fail;
            }
            while (out_n + emit_n + 1 > cap) {
                size_t new_cap = cap * 2;
                char  *bigger = DS_REALLOC(out, new_cap);
                if (bigger == NULL) { DS_FREE(out); return NULL; }
                out = bigger;
                cap = new_cap;
            }
            memcpy(out + out_n, emit, emit_n);
            out_n += emit_n;
            continue;
        }
        if ((unsigned char) c < 0x20) {
            goto fail;
        }
        if (out_n + 2 > cap) {
            size_t new_cap = cap * 2;
            char  *bigger = DS_REALLOC(out, new_cap);
            if (bigger == NULL) { DS_FREE(out); return NULL; }
            out = bigger;
            cap = new_cap;
        }
        out[out_n++] = c;
        p->cur++;
    }
fail:
    DS_FREE(out);
    return NULL;
}

static ds_json_t *parse_string(json_parser_t *p)
{
    char *s = parse_string_literal(p);
    if (s == NULL) return NULL;
    ds_json_t *node = json_new_node(DS_JSON_STRING);
    if (node == NULL) { DS_FREE(s); return NULL; }
    node->v.s       = s;
    node->str_bytes = (uint32_t) strlen(s);   /* <= the string limit, checked */
    return node;
}

static ds_json_t *parse_number(json_parser_t *p)
{
    const char *start = p->cur;
    bool        is_float = false;

    if (peek_char(p, '-')) p->cur++;

    if (p->cur >= p->end) return NULL;
    if (*p->cur == '0') {
        p->cur++;
    } else if (*p->cur >= '1' && *p->cur <= '9') {
        while (p->cur < p->end && isdigit((unsigned char) *p->cur)) p->cur++;
    } else {
        return NULL;
    }

    if (peek_char(p, '.')) {
        is_float = true;
        p->cur++;
        if (p->cur >= p->end || !isdigit((unsigned char) *p->cur)) return NULL;
        while (p->cur < p->end && isdigit((unsigned char) *p->cur)) p->cur++;
    }
    if (p->cur < p->end && (*p->cur == 'e' || *p->cur == 'E')) {
        is_float = true;
        p->cur++;
        if (p->cur < p->end && (*p->cur == '+' || *p->cur == '-')) p->cur++;
        if (p->cur >= p->end || !isdigit((unsigned char) *p->cur)) return NULL;
        while (p->cur < p->end && isdigit((unsigned char) *p->cur)) p->cur++;
    }

    size_t n = (size_t) (p->cur - start);

    /* [LDET.3.2.8]: parsed in place, at any length. [LGRA.5.8.10]: a literal that
       rounds to an infinity is malformed; ds_parse_float_json answers the infinity,
       since a source float literal reads through it too. */
    if (is_float) {
        double f = 0.0;
        if (ds_parse_float_json(start, n, &f) != 0) return NULL;
        if (!isfinite(f)) {
            p->why = "JSON float literal outside the double range";
            return NULL;
        }
        return json_new_float_node(f);
    }

    char   tmp[64];
    if (n >= sizeof(tmp)) {
        p->why = "JSON integer literal outside int64";
        return NULL;
    }
    memcpy(tmp, start, n);
    tmp[n] = '\0';

    /* strtoll saturates, and says so only through errno. */
    errno = 0;
    long long v = strtoll(tmp, NULL, 10);
    if (errno == ERANGE) {
        p->why = "JSON integer literal outside int64";
        return NULL;
    }
    ds_json_t *node = json_new_node(DS_JSON_INT);
    if (node == NULL) return NULL;
    node->v.i = (int64_t) v;
    return node;
}

static ds_json_t *parse_array(json_parser_t *p)
{
    if (!peek_char(p, '[')) return NULL;
    p->cur++;

    ds_json_t *node = json_new_node(DS_JSON_ARRAY);
    if (node == NULL) return NULL;

    skip_ws(p);
    if (peek_char(p, ']')) { p->cur++; return node; }

    size_t cap = 4;
    node->v.arr.items = DS_MALLOC(cap * sizeof(*node->v.arr.items));
    if (node->v.arr.items == NULL) { DS_FREE(node); return NULL; }

    while (1) {
        skip_ws(p);
        ds_json_t *item = parse_value(p);
        if (item == NULL) goto fail;

        if (node->v.arr.n + 1 > cap) {
            size_t       new_cap = cap * 2;
            ds_json_t  **bigger  = DS_REALLOC(node->v.arr.items,
                                            new_cap * sizeof(*bigger));
            if (bigger == NULL) { free_node(item); goto fail; }
            node->v.arr.items = bigger;
            cap = new_cap;
        }
        node->v.arr.items[node->v.arr.n++] = item;
        json_adopt(node, item, 0);

        skip_ws(p);
        if (peek_char(p, ',')) { p->cur++; continue; }
        if (peek_char(p, ']')) { p->cur++; return node; }
        goto fail;
    }
fail:
    free_node(node);
    return NULL;
}

static ds_json_t *parse_object(json_parser_t *p)
{
    if (!peek_char(p, '{')) return NULL;
    p->cur++;

    ds_json_t *node = json_new_node(DS_JSON_OBJECT);
    if (node == NULL) return NULL;

    skip_ws(p);
    if (peek_char(p, '}')) { p->cur++; return node; }

    size_t cap = 4;
    node->v.obj.kvs = DS_CALLOC(cap, sizeof(*node->v.obj.kvs));
    if (node->v.obj.kvs == NULL) { DS_FREE(node); return NULL; }

    while (1) {
        skip_ws(p);
        char *key = parse_string_literal(p);
        if (key == NULL) goto fail;

        /* [LGRA.5.8.7]: compared as decoded. [LGRA.5.8.6]'s node cap bounds the scan. */
        for (uint32_t j = 0; j < node->v.obj.n; j++) {
            if (strcmp(node->v.obj.kvs[j].key, key) == 0) {
                p->why = "JSON object repeats a key (LGRA.5.8.7)";
                DS_FREE(key);
                goto fail;
            }
        }

        skip_ws(p);
        if (!peek_char(p, ':')) { DS_FREE(key); goto fail; }
        p->cur++;
        skip_ws(p);

        ds_json_t *val = parse_value(p);
        if (val == NULL) { DS_FREE(key); goto fail; }

        if (node->v.obj.n + 1 > cap) {
            size_t         new_cap = cap * 2;
            ds_json_kv_t  *bigger  = DS_REALLOC(node->v.obj.kvs,
                                              new_cap * sizeof(*bigger));
            if (bigger == NULL) { DS_FREE(key); free_node(val); goto fail; }
            memset(bigger + cap, 0, (new_cap - cap) * sizeof(*bigger));
            node->v.obj.kvs = bigger;
            cap = new_cap;
        }
        node->v.obj.kvs[node->v.obj.n].key   = key;
        node->v.obj.kvs[node->v.obj.n].value = val;
        node->v.obj.n++;
        json_adopt(node, val, (uint32_t) strlen(key));

        skip_ws(p);
        if (peek_char(p, ',')) { p->cur++; continue; }
        if (peek_char(p, '}')) { p->cur++; return node; }
        goto fail;
    }
fail:
    free_node(node);
    return NULL;
}

static ds_json_t *parse_value_at(json_parser_t *p)
{
    skip_ws(p);
    if (p->cur >= p->end) return NULL;

    char c = *p->cur;
    if (c == '{') return parse_object(p);
    if (c == '[') return parse_array(p);
    if (c == '"') return parse_string(p);
    if (c == '-' || (c >= '0' && c <= '9')) return parse_number(p);
    if (c == 't') {
        if (!consume_literal(p, "true")) return NULL;
        ds_json_t *node = json_new_node(DS_JSON_BOOL);
        if (node == NULL) return NULL;
        node->v.b = true;
        return node;
    }
    if (c == 'f') {
        if (!consume_literal(p, "false")) return NULL;
        ds_json_t *node = json_new_node(DS_JSON_BOOL);
        if (node == NULL) return NULL;
        node->v.b = false;
        return node;
    }
    if (c == 'n') {
        if (!consume_literal(p, "null")) return NULL;
        return json_new_node(DS_JSON_NULL);
    }
    return NULL;
}

/* [LGRA.5.8.6], refused before anything is allocated: the depth cap bounds this
   recursion and every later walk over a tree. Depth first, so a value over both
   reports depth, in both runtimes. */
static ds_json_t *parse_value(json_parser_t *p)
{
    if (p->depth >= DS_JSON_MAX_DEPTH) {
        json_breach(p, DS_JSON_LIMIT_DEPTH, DS_JSON_MAX_DEPTH,
                    (uint64_t) p->depth + 1u,
                    "JSON nested deeper than DS_JSON_MAX_DEPTH");
        return NULL;
    }
    if (p->nodes >= DS_JSON_MAX_NODES) {
        json_breach(p, DS_JSON_LIMIT_NODES, DS_JSON_MAX_NODES,
                    (uint64_t) p->nodes + 1u,
                    "JSON has more than DS_JSON_MAX_NODES values");
        return NULL;
    }
    p->nodes++;
    p->depth++;
    ds_json_t *v = parse_value_at(p);
    p->depth--;
    return v;
}

ds_result_t ds_json_parse(const char *text, size_t len, ds_json_t **out)
{
    /* [LSTR.8.5], for the host's text only: the engine's own reads of text it
       serialized or was handed as trusted input ([RDSC.9.9]) call the two below. After
       the text limit, which refuses text unread ([LGRA.5.8.6]). */
    if (out != NULL && text != NULL && len <= DS_JSON_MAX_TEXT_BYTES
            && !ds_utf8_well_formed(text, len)) {
        *out = NULL;
        return DS_ERR_R(DS_ERR_ENCODING,
                        "JSON text is not well-formed UTF-8 ([LSTR.8.5])");
    }
    return ds_json_parse_limited(text, len, out, NULL, true);
}

ds_result_t ds_json_parse_limited(const char *text, size_t len, ds_json_t **out,
                                  ds_json_breach_t *breach, bool text_limit)
{
    return ds_json_parse_capped(text, len, out, breach,
                                text_limit ? (size_t) DS_JSON_MAX_TEXT_BYTES
                                           : SIZE_MAX);
}

ds_result_t ds_json_parse_capped(const char *text, size_t len, ds_json_t **out,
                                 ds_json_breach_t *breach, size_t max_text)
{
    if (breach != NULL) *breach = (ds_json_breach_t){ DS_JSON_LIMIT_NONE, 0, 0 };
    if (out == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "out must not be null");
    }
    *out = NULL;
    if (text == NULL && len > 0) {
        return DS_ERR_R(DS_ERR_INVAL, "text null with len > 0");
    }
    if (len > max_text) {
        if (breach != NULL)
            *breach = (ds_json_breach_t){ DS_JSON_LIMIT_TEXT_BYTES,
                                          (uint64_t) max_text, (uint64_t) len };
        return DS_ERR_R(DS_ERR_JSON_LIMIT,
                        max_text == DS_JSON_MAX_FX_TEXT_BYTES
                            ? "JSON text longer than DS_JSON_MAX_FX_TEXT_BYTES"
                            : "JSON text longer than DS_JSON_MAX_TEXT_BYTES");
    }

    json_parser_t p = { .cur = text, .end = text + len, .depth = 0, .nodes = 0,
                        .str_bytes = 0, .why = NULL,
                        .breach = { DS_JSON_LIMIT_NONE, 0, 0 } };
    ds_json_t *root = parse_value(&p);
    if (root == NULL) {
        if (p.breach.cap != DS_JSON_LIMIT_NONE) {
            if (breach != NULL) *breach = p.breach;
            return DS_ERR_R(DS_ERR_JSON_LIMIT, p.why);
        }
        return DS_ERR_R(DS_ERR_PARSE, p.why ? p.why : "JSON parse failed");
    }

    skip_ws(&p);
    if (p.cur != p.end) {
        free_node(root);
        return DS_ERR_R(DS_ERR_PARSE, "trailing junk after JSON value");
    }

    *out = root;
    return DS_OK_R;
}

static void free_node(ds_json_t *node)
{
    if (node == NULL) return;
    switch (node->kind) {
    case DS_JSON_STRING:
        DS_FREE((void *) node->v.s);
        break;
    case DS_JSON_ARRAY:
        for (uint32_t i = 0; i < node->v.arr.n; i++) {
            free_node(node->v.arr.items[i]);
        }
        DS_FREE(node->v.arr.items);
        break;
    case DS_JSON_OBJECT:
        for (uint32_t i = 0; i < node->v.obj.n; i++) {
            DS_FREE((void *) node->v.obj.kvs[i].key);
            free_node(node->v.obj.kvs[i].value);
        }
        DS_FREE(node->v.obj.kvs);
        break;
    case DS_JSON_NULL:
    case DS_JSON_BOOL:
    case DS_JSON_INT:
    case DS_JSON_FLOAT:
        break;
    }
    DS_FREE(node);
}

ds_result_t ds_json_free(ds_json_t *tree)
{
    free_node(tree);
    return DS_OK_R;
}

static ds_json_t *clone_node(const ds_json_t *src)
{
    if (src == NULL) return NULL;
    ds_json_t *node = DS_CALLOC(1, sizeof(*node));
    if (node == NULL) return NULL;
    node->kind   = src->kind;
    node->height    = src->height;
    node->nodes     = src->nodes;
    node->str_bytes = src->str_bytes;
    switch (src->kind) {
    case DS_JSON_NULL:
        break;
    case DS_JSON_BOOL:
        node->v.b = src->v.b;
        break;
    case DS_JSON_INT:
        node->v.i = src->v.i;
        break;
    case DS_JSON_FLOAT:
        node->v.f = src->v.f;
        break;
    case DS_JSON_STRING: {
        const char *s = src->v.s ? src->v.s : "";
        char *dup = DS_MALLOC(strlen(s) + 1);
        if (dup == NULL) { DS_FREE(node); return NULL; }
        memcpy(dup, s, strlen(s) + 1);
        node->v.s = dup;
        break;
    }
    case DS_JSON_ARRAY: {
        uint32_t n = src->v.arr.n;
        node->v.arr.n = n;
        if (n > 0) {
            node->v.arr.items = DS_CALLOC(n, sizeof(*node->v.arr.items));
            if (node->v.arr.items == NULL) { DS_FREE(node); return NULL; }
            for (uint32_t i = 0; i < n; i++) {
                ds_json_t *child = clone_node(src->v.arr.items[i]);
                if (child == NULL && src->v.arr.items[i] != NULL) {
                    free_node(node);
                    return NULL;
                }
                node->v.arr.items[i] = child;
                if (child != NULL) child->parent = node;
            }
        }
        break;
    }
    case DS_JSON_OBJECT: {
        uint32_t n = src->v.obj.n;
        node->v.obj.n = n;
        if (n > 0) {
            node->v.obj.kvs = DS_CALLOC(n, sizeof(*node->v.obj.kvs));
            if (node->v.obj.kvs == NULL) { DS_FREE(node); return NULL; }
            for (uint32_t i = 0; i < n; i++) {
                const char *k = src->v.obj.kvs[i].key
                    ? src->v.obj.kvs[i].key : "";
                char *kdup = DS_MALLOC(strlen(k) + 1);
                if (kdup == NULL) { free_node(node); return NULL; }
                memcpy(kdup, k, strlen(k) + 1);
                node->v.obj.kvs[i].key = kdup;
                ds_json_t *child = clone_node(src->v.obj.kvs[i].value);
                if (child == NULL && src->v.obj.kvs[i].value != NULL) {
                    free_node(node);
                    return NULL;
                }
                node->v.obj.kvs[i].value = child;
                if (child != NULL) child->parent = node;
            }
        }
        break;
    }
    }
    return node;
}

/* No object repeats a key ([LGRA.5.8.7], [IDAT.3.3.4]), so an object compares and
   hashes member by member. */
static const ds_json_t *member_lookup(const ds_json_t *obj, const char *k,
                                      bool *found)
{
    for (uint32_t j = 0; j < obj->v.obj.n; j++) {
        const char *kj = obj->v.obj.kvs[j].key ? obj->v.obj.kvs[j].key : "";
        if (strcmp(kj, k) == 0) { *found = true; return obj->v.obj.kvs[j].value; }
    }
    *found = false;
    return NULL;
}

/* [LFAC.2.5.1]. Int and Float are different kinds ([LEXP.7.12.1]), so 1 and 1.0 are
   unequal. An object's members compare in any order. */
bool ds_json_deep_equal(const ds_json_t *a, const ds_json_t *b)
{
    if (a == b) return true;
    if (a == NULL || b == NULL) return false;
    if (a->kind != b->kind) return false;
    switch (a->kind) {
    case DS_JSON_NULL:   return true;
    case DS_JSON_BOOL:   return a->v.b == b->v.b;
    case DS_JSON_INT:    return a->v.i == b->v.i;
    case DS_JSON_FLOAT:  return a->v.f == b->v.f;
    case DS_JSON_STRING:
        return strcmp(a->v.s ? a->v.s : "", b->v.s ? b->v.s : "") == 0;
    case DS_JSON_ARRAY:
        if (a->v.arr.n != b->v.arr.n) return false;
        for (uint32_t i = 0; i < a->v.arr.n; i++)
            if (!ds_json_deep_equal(a->v.arr.items[i], b->v.arr.items[i]))
                return false;
        return true;
    case DS_JSON_OBJECT:
        if (a->v.obj.n != b->v.obj.n) return false;
        for (uint32_t i = 0; i < a->v.obj.n; i++) {
            const char *k = a->v.obj.kvs[i].key ? a->v.obj.kvs[i].key : "";
            bool found = false;
            const ds_json_t *bv = member_lookup(b, k, &found);
            if (!found) return false;
            if (!ds_json_deep_equal(a->v.obj.kvs[i].value, bv)) return false;
        }
        return true;
    }
    return false;
}

static uint32_t hash_mix32(uint32_t h)
{
    h ^= h >> 16;
    h *= 0x45d9f3bu;
    h ^= h >> 16;
    return h;
}

static uint32_t hash_cstr(const char *s)
{
    uint32_t h = 0x811c9dc5u;                    /* FNV-1a */
    for (const unsigned char *p = (const unsigned char *)(s ? s : ""); *p; p++)
        h = (h ^ *p) * 0x01000193u;
    return h;
}

/* Equal trees under ds_json_deep_equal hash equal: -0.0 hashes as +0.0, and an
   object's members combine by a sum, which does not depend on their order. */
uint32_t ds_json_deep_hash(const ds_json_t *n)
{
    if (n == NULL) return 0x9e3779b9u;
    uint32_t h = 0x2545f491u * (uint32_t)(n->kind + 1);
    switch (n->kind) {
    case DS_JSON_NULL:
        return hash_mix32(h);
    case DS_JSON_BOOL:
        return hash_mix32(h ^ (n->v.b ? 0x6b8b4567u : 0x327b23c6u));
    case DS_JSON_INT:
        return hash_mix32(h ^ (uint32_t)(n->v.i ^ (n->v.i >> 32)));
    case DS_JSON_FLOAT: {
        double   f = (n->v.f == 0.0) ? 0.0 : n->v.f;
        uint64_t bits;
        memcpy(&bits, &f, sizeof(bits));
        return hash_mix32(h ^ (uint32_t)(bits ^ (bits >> 32)));
    }
    case DS_JSON_STRING:
        return hash_mix32(h ^ hash_cstr(n->v.s));
    case DS_JSON_ARRAY:
        for (uint32_t i = 0; i < n->v.arr.n; i++)
            h = (h ^ ds_json_deep_hash(n->v.arr.items[i])) * 0x01000193u;
        return hash_mix32(h);
    case DS_JSON_OBJECT: {
        uint32_t sum = 0;
        for (uint32_t i = 0; i < n->v.obj.n; i++) {
            uint32_t kh = hash_cstr(n->v.obj.kvs[i].key);
            uint32_t vh = ds_json_deep_hash(n->v.obj.kvs[i].value);
            sum += hash_mix32(kh * 31u + vh);
        }
        return hash_mix32(h ^ sum);
    }
    }
    return h;
}

ds_result_t ds_json_clone(const ds_json_t *src, ds_json_t **out)
{
    if (out == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_clone: out must not be null");
    if (src == NULL) { *out = NULL; return DS_OK_R; }
    ds_json_t *copy = clone_node(src);
    if (copy == NULL) {
        *out = NULL;
        return DS_ERR_R(DS_ERR_OOM, "ds_json_clone: alloc");
    }
    *out = copy;
    return DS_OK_R;
}

static bool buf_reserve(json_buf_t *b, size_t need)
{
    if (b->oom) return false;
    if (b->len + need + 1 <= b->cap) return true;
    size_t new_cap = b->cap == 0 ? 64 : b->cap;
    while (new_cap < b->len + need + 1) new_cap *= 2;
    char *bigger = DS_REALLOC(b->buf, new_cap);
    if (bigger == NULL) { b->oom = true; return false; }
    b->buf = bigger;
    b->cap = new_cap;
    return true;
}

static bool buf_append(json_buf_t *b, const char *s, size_t n)
{
    if (!buf_reserve(b, n)) return false;
    memcpy(b->buf + b->len, s, n);
    b->len += n;
    return true;
}

static bool buf_putc(json_buf_t *b, char c)
{
    if (!buf_reserve(b, 1)) return false;
    b->buf[b->len++] = c;
    return true;
}

static bool serialize_string(json_buf_t *b, const char *s)
{
    if (!buf_putc(b, '"')) return false;
    while (*s) {
        unsigned char c = (unsigned char) *s++;
        if (c == '"' || c == '\\') {
            if (!buf_putc(b, '\\') || !buf_putc(b, (char) c)) return false;
        } else if (c == '\b') {
            if (!buf_append(b, "\\b", 2)) return false;
        } else if (c == '\f') {
            if (!buf_append(b, "\\f", 2)) return false;
        } else if (c == '\n') {
            if (!buf_append(b, "\\n", 2)) return false;
        } else if (c == '\r') {
            if (!buf_append(b, "\\r", 2)) return false;
        } else if (c == '\t') {
            if (!buf_append(b, "\\t", 2)) return false;
        } else if (c < 0x20) {
            char buf[8];
            ds_text_t t = ds_text(buf, sizeof(buf));
            ds_text_str(&t, "\\u");
            ds_text_hex(&t, c, 4);
            if (!buf_append(b, buf, (size_t) ds_text_len(&t))) return false;
        } else {
            if (!buf_putc(b, (char) c)) return false;
        }
    }
    return buf_putc(b, '"');
}

static bool serialize_node(json_buf_t *b, const ds_json_t *node)
{
    char num[64];
    int  n;

    switch (node->kind) {
    case DS_JSON_NULL:
        return buf_append(b, "null", 4);
    case DS_JSON_BOOL:
        return buf_append(b, node->v.b ? "true" : "false",
                          node->v.b ? 4 : 5);
    case DS_JSON_INT: {
        ds_text_t t = ds_text(num, sizeof(num));
        ds_text_i64(&t, (int64_t) node->v.i);
        return buf_append(b, num, (size_t) ds_text_len(&t));
    }
    case DS_JSON_FLOAT:
        /* No public call makes such a tree ([LGRA.5.8.10]); libds's own writers rely
           on this refusal. */
        if (!isfinite(node->v.f)) {
            b->nonfinite = true;
            return false;
        }
        n = ds_fmt_float(num, sizeof(num), node->v.f);
        if (n < 0) return false;
        return buf_append(b, num, (size_t) n);
    case DS_JSON_STRING:
        return serialize_string(b, node->v.s);
    case DS_JSON_ARRAY:
        if (!buf_putc(b, '[')) return false;
        for (uint32_t i = 0; i < node->v.arr.n; i++) {
            if (i > 0 && !buf_putc(b, ',')) return false;
            if (!serialize_node(b, node->v.arr.items[i])) return false;
        }
        return buf_putc(b, ']');
    case DS_JSON_OBJECT: {
        if (!buf_putc(b, '{')) return false;
        uint32_t n = node->v.obj.n;
        if (n > 0) {
            /* Keys in byte-wise order, so the text agrees with ds_json_deep_equal
               ([LFAC.2.5.1]). */
            uint32_t stack_idx[16];
            uint32_t *idx = stack_idx;
            uint32_t *heap_idx = NULL;
            if (n > 16) {
                heap_idx = DS_MALLOC(n * sizeof(*heap_idx));
                if (heap_idx == NULL) return false;
                idx = heap_idx;
            }
            for (uint32_t i = 0; i < n; i++) idx[i] = i;
            for (uint32_t i = 1; i < n; i++) {
                uint32_t cur = idx[i];
                const char *k = node->v.obj.kvs[cur].key;
                uint32_t j = i;
                while (j > 0 &&
                       strcmp(node->v.obj.kvs[idx[j-1]].key, k) > 0) {
                    idx[j] = idx[j-1];
                    j--;
                }
                idx[j] = cur;
            }
            for (uint32_t i = 0; i < n; i++) {
                if (i > 0 && !buf_putc(b, ',')) {
                    DS_FREE(heap_idx);
                    return false;
                }
                const ds_json_kv_t *kv = &node->v.obj.kvs[idx[i]];
                if (!serialize_string(b, kv->key) ||
                    !buf_putc(b, ':') ||
                    !serialize_node(b, kv->value)) {
                    DS_FREE(heap_idx);
                    return false;
                }
            }
            DS_FREE(heap_idx);
        }
        return buf_putc(b, '}');
    }
    }
    return false;
}

ds_result_t ds_json_serialize(const ds_json_t *tree,
                              char           **out,
                              size_t          *out_len)
{
    if (tree == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "tree must not be null");
    }
    if (out == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "out must not be null");
    }
    *out = NULL;

    json_buf_t b = {0};
    if (!serialize_node(&b, tree)) {
        bool nonfinite = b.nonfinite;
        DS_FREE(b.buf);
        if (nonfinite) {
            return DS_ERR_R(DS_ERR_JSON_NONFINITE,
                "non-finite Float in a JSON tree; serialize refused");
        }
        return DS_ERR_R(DS_ERR_OOM, "JSON serialize allocation failed");
    }
    if (!buf_putc(&b, '\0')) {
        DS_FREE(b.buf);
        return DS_ERR_R(DS_ERR_OOM, "JSON serialize NUL allocation failed");
    }
    *out = b.buf;
    if (out_len != NULL) *out_len = b.len - 1;
    return DS_OK_R;
}

/* json_path.ebnf, [IDAT.3.3.10]. Nothing past `len` is read. */
static bool path_well_formed(const char *path, size_t len)
{
    const char *p   = path;
    const char *lim = path + len;
    if (p == lim) return false;
    for (bool first = true; p < lim; first = false) {
        if (*p == '[') {
            const char *digits = ++p;
            while (p < lim && *p >= '0' && *p <= '9') p++;
            if (p == digits || p == lim || *p != ']') return false;
            p++;
        } else {
            if (!first && *p != '.') return false;
            if (!first) p++;
            const char *key = p;
            while (p < lim && *p != '.' && *p != '[') p++;
            if (p == key) return false;
        }
    }
    return true;
}

/* One step of an admitted path: the next node, with the cursor advanced, or NULL on
   a miss. */
static const ds_json_t *path_step(const ds_json_t *cur,
                                  const char     **path_cur,
                                  const char      *lim)
{
    const char *p = *path_cur;

    if (*p == '[') {
        if (cur->kind != DS_JSON_ARRAY) return NULL;
        /* A number past UINT64_MAX saturates: past every array's end, a miss. */
        uint64_t idx = 0;
        for (p++; *p != ']'; p++) {
            unsigned d = (unsigned) (*p - '0');
            idx = (idx > (UINT64_MAX - d) / 10u) ? UINT64_MAX : idx * 10u + d;
        }
        if (idx >= cur->v.arr.n) return NULL;
        *path_cur = p + 1;
        return cur->v.arr.items[idx];
    }

    if (*p == '.') p++;

    if (cur->kind != DS_JSON_OBJECT) return NULL;
    const char *key_start = p;
    while (p < lim && *p != '.' && *p != '[') p++;
    size_t key_len = (size_t) (p - key_start);

    for (uint32_t i = 0; i < cur->v.obj.n; i++) {
        const char *k = cur->v.obj.kvs[i].key;
        if (strlen(k) == key_len &&
            memcmp(k, key_start, key_len) == 0) {
            *path_cur = p;
            return cur->v.obj.kvs[i].value;
        }
    }
    return NULL;
}

ds_result_t ds_json_get_path(const ds_json_t  *root,
                             const char       *path,
                             const ds_json_t **out)
{
    if (root == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "root must not be null");
    }
    if (path == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "path must not be null");
    }
    return ds_json_get_path_n(root, path, strlen(path), out);
}

ds_result_t ds_json_get_path_n(const ds_json_t  *root,
                               const char       *path,
                               size_t            len,
                               const ds_json_t **out)
{
    if (root == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "root must not be null");
    }
    if (path == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "path must not be null");
    }
    if (out == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "out must not be null");
    }

    /* Before the tree is read, so a malformed tail after a miss is still malformed. */
    if (!path_well_formed(path, len)) {
        return DS_ERR_R(DS_ERR_INVAL, "malformed JSON path");
    }

    const ds_json_t *cur  = root;
    const char      *p    = path;
    const char      *lim  = path + len;
    while (p != lim) {
        cur = path_step(cur, &p, lim);
        if (cur == NULL) break;  /* a miss: DS_OK with *out NULL */
    }
    *out = cur;
    return DS_OK_R;
}

/* Typed getters are strict: exact kind, no Int or Float coercion. Reads return borrows
   valid for the source tree's lifetime. */

/* Literals, so safe from any thread ([IARC.1.11]). Indexed (actual, requested) by
   ds_json_kind_t. The diagonal is never read. */
#define JSON_KIND_COUNT 7
static const char *const json_kind_mismatch[JSON_KIND_COUNT][JSON_KIND_COUNT] = {
    [DS_JSON_NULL] = {
        "", "node is null, not bool", "node is null, not int",
        "node is null, not float", "node is null, not string",
        "node is null, not array", "node is null, not object" },
    [DS_JSON_BOOL] = {
        "node is bool, not null", "", "node is bool, not int",
        "node is bool, not float", "node is bool, not string",
        "node is bool, not array", "node is bool, not object" },
    [DS_JSON_INT] = {
        "node is int, not null", "node is int, not bool", "",
        "node is int, not float", "node is int, not string",
        "node is int, not array", "node is int, not object" },
    [DS_JSON_FLOAT] = {
        "node is float, not null", "node is float, not bool",
        "node is float, not int", "", "node is float, not string",
        "node is float, not array", "node is float, not object" },
    [DS_JSON_STRING] = {
        "node is string, not null", "node is string, not bool",
        "node is string, not int", "node is string, not float", "",
        "node is string, not array", "node is string, not object" },
    [DS_JSON_ARRAY] = {
        "node is array, not null", "node is array, not bool",
        "node is array, not int", "node is array, not float",
        "node is array, not string", "", "node is array, not object" },
    [DS_JSON_OBJECT] = {
        "node is object, not null", "node is object, not bool",
        "node is object, not int", "node is object, not float",
        "node is object, not string", "node is object, not array", "" },
};
#define JSON_KIND_MISMATCH_OTHER "node is not of the requested kind"

static ds_result_t json_check_kind(const ds_json_t *node, ds_json_kind_t want,
                                   const char *null_detail)
{
    if (node == NULL)
        return DS_ERR_R(DS_ERR_INVAL, null_detail);
    if (node->kind != want) {
        const unsigned a = (unsigned) node->kind, w = (unsigned) want;
        return DS_ERR_R(DS_ERR_INVAL,
                        (a < JSON_KIND_COUNT && w < JSON_KIND_COUNT)
                            ? json_kind_mismatch[a][w]
                            : JSON_KIND_MISMATCH_OTHER);
    }
    return DS_OK_R;
}

ds_result_t ds_json_get_kind(const ds_json_t *node, ds_json_kind_t *out)
{
    if (node == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_get_kind: node must not be null");
    if (out == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_get_kind: out must not be null");
    *out = node->kind;
    return DS_OK_R;
}

ds_result_t ds_json_get_bool(const ds_json_t *node, bool *out)
{
    if (out == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_get_bool: out must not be null");
    ds_result_t rk = json_check_kind(node, DS_JSON_BOOL,
                                     "ds_json_get_bool: node must not be null");
    if (rk.status != DS_OK) return rk;
    *out = node->v.b;
    return DS_OK_R;
}

ds_result_t ds_json_get_int(const ds_json_t *node, int64_t *out)
{
    if (out == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_get_int: out must not be null");
    ds_result_t rk = json_check_kind(node, DS_JSON_INT,
                                     "ds_json_get_int: node must not be null");
    if (rk.status != DS_OK) return rk;
    *out = node->v.i;
    return DS_OK_R;
}

ds_result_t ds_json_get_float(const ds_json_t *node, double *out)
{
    if (out == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_get_float: out must not be null");
    ds_result_t rk = json_check_kind(node, DS_JSON_FLOAT,
                                     "ds_json_get_float: node must not be null");
    if (rk.status != DS_OK) return rk;
    *out = node->v.f;
    return DS_OK_R;
}

ds_result_t ds_json_get_string(const ds_json_t *node, const char **out_s,
                               size_t *out_len)
{
    if (out_s == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_get_string: out_s must not be null");
    ds_result_t rk = json_check_kind(node, DS_JSON_STRING,
                                     "ds_json_get_string: node must not be null");
    if (rk.status != DS_OK) return rk;
    const char *s = node->v.s ? node->v.s : "";
    *out_s = s;
    /* A String holds no U+0000 ([LSTR.1.1]). */
    if (out_len != NULL) *out_len = strlen(s);
    return DS_OK_R;
}

ds_result_t ds_json_array_len(const ds_json_t *node, size_t *out)
{
    if (out == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_array_len: out must not be null");
    ds_result_t rk = json_check_kind(node, DS_JSON_ARRAY,
                                     "ds_json_array_len: node must not be null");
    if (rk.status != DS_OK) return rk;
    *out = node->v.arr.n;
    return DS_OK_R;
}

ds_result_t ds_json_array_at(const ds_json_t *node, size_t index,
                             const ds_json_t **out)
{
    if (out == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_array_at: out must not be null");
    ds_result_t rk = json_check_kind(node, DS_JSON_ARRAY,
                                     "ds_json_array_at: node must not be null");
    if (rk.status != DS_OK) return rk;
    if (index >= node->v.arr.n) {
        *out = NULL;
        return DS_ERR_R(DS_ERR_NOT_FOUND, "ds_json_array_at: index out of range");
    }
    *out = node->v.arr.items[index];
    return DS_OK_R;
}

ds_result_t ds_json_object_len(const ds_json_t *node, size_t *out)
{
    if (out == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_object_len: out must not be null");
    ds_result_t rk = json_check_kind(node, DS_JSON_OBJECT,
                                     "ds_json_object_len: node must not be null");
    if (rk.status != DS_OK) return rk;
    *out = node->v.obj.n;
    return DS_OK_R;
}

ds_result_t ds_json_object_get(const ds_json_t *node, const char *key,
                               const ds_json_t **out)
{
    if (key == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_object_get: key must not be null");
    if (out == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_object_get: out must not be null");
    ds_result_t rk = json_check_kind(node, DS_JSON_OBJECT,
                                     "ds_json_object_get: node must not be null");
    if (rk.status != DS_OK) return rk;
    size_t klen = strlen(key);
    for (uint32_t i = 0; i < node->v.obj.n; i++) {
        const char *k = node->v.obj.kvs[i].key;
        if (k != NULL && strlen(k) == klen &&
            (klen == 0 || memcmp(k, key, klen) == 0)) {
            *out = node->v.obj.kvs[i].value;
            return DS_OK_R;
        }
    }
    *out = NULL;
    return DS_ERR_R(DS_ERR_NOT_FOUND, "ds_json_object_get: key absent");
}

ds_result_t ds_json_object_at(const ds_json_t *node, size_t index,
                              const char **out_key, size_t *out_key_len,
                              const ds_json_t **out_value)
{
    ds_result_t rk = json_check_kind(node, DS_JSON_OBJECT,
                                     "ds_json_object_at: node must not be null");
    if (rk.status != DS_OK) return rk;
    if (index >= node->v.obj.n)
        return DS_ERR_R(DS_ERR_NOT_FOUND, "ds_json_object_at: index out of range");
    const ds_json_kv_t *kv = &node->v.obj.kvs[index];
    const char *k = kv->key ? kv->key : "";
    if (out_key != NULL)     *out_key = k;
    if (out_key_len != NULL) *out_key_len = strlen(k);
    if (out_value != NULL)   *out_value = kv->value;
    return DS_OK_R;
}

static ds_json_t *json_new_node(ds_json_kind_t kind)
{
    ds_json_t *node = DS_CALLOC(1, sizeof(*node));
    if (node != NULL) {
        node->kind   = kind;
        node->height = 1;   /* a leaf, or a container with no children yet */
        node->nodes  = 1;   /* itself; str_bytes is 0 until a string sets it */
    }
    return node;
}

/* [LGRA.5.8.8]: a float zero in a Json value has no sign. Every float node is made
   here. A `Float` outside a Json value keeps its sign ([LDET.3.2.7]). */
static ds_json_t *json_new_float_node(double f)
{
    ds_json_t *node = json_new_node(DS_JSON_FLOAT);
    if (node != NULL) node->v.f = (f == 0.0) ? 0.0 : f;
    return node;
}

/* The totals are per subtree, so a change moves every one above it. */
static void json_account(ds_json_t *a, int64_t dnodes, int64_t dbytes)
{
    for (; a != NULL; a = a->parent) {
        a->nodes     = (uint32_t) ((int64_t) a->nodes + dnodes);
        a->str_bytes = (uint32_t) ((int64_t) a->str_bytes + dbytes);
    }
}

/* `container` has already stored `child`, under a key of `key_bytes` bytes (0 for an
   array). */
static void json_adopt(ds_json_t *container, ds_json_t *child,
                       uint32_t key_bytes)
{
    child->parent = container;
    uint32_t h = child->height + 1;
    for (ds_json_t *a = container; a != NULL && a->height < h; a = a->parent) {
        a->height = h;
        h++;
    }
    json_account(container, (int64_t) child->nodes,
                 (int64_t) child->str_bytes + (int64_t) key_bytes);
}

/* Heights stay exact: an upper bound would refuse appends the cap allows. */
static void json_refresh_heights(ds_json_t *node)
{
    for (ds_json_t *a = node; a != NULL; a = a->parent) {
        uint32_t h = 1;
        if (a->kind == DS_JSON_ARRAY) {
            for (uint32_t i = 0; i < a->v.arr.n; i++)
                if (a->v.arr.items[i]->height + 1 > h)
                    h = a->v.arr.items[i]->height + 1;
        } else if (a->kind == DS_JSON_OBJECT) {
            for (uint32_t i = 0; i < a->v.obj.n; i++)
                if (a->v.obj.kvs[i].value->height + 1 > h)
                    h = a->v.obj.kvs[i].value->height + 1;
        }
        if (h == a->height) return;
        a->height = h;
    }
}

/* `replaced` is NULL unless an object key is being reused. DS_ERR_INVAL when `child`
 * already has an owner, or is the container or an ancestor of it. DS_ERR_JSON_LIMIT
 * when the result would pass [LGRA.5.8.6], measured on the whole tree: the container
 * may sit deep inside one the caller still holds a pointer into. */
static ds_result_t json_check_link(const ds_json_t *container,
                                   const ds_json_t *child,
                                   uint32_t key_bytes,
                                   const ds_json_t *replaced)
{
    if (child->parent != NULL)
        return DS_ERR_R(DS_ERR_INVAL, "json child already belongs to a container");
    uint32_t level = 0;
    const ds_json_t *root = container;
    for (const ds_json_t *a = container; a != NULL; a = a->parent) {
        if (a == child)
            return DS_ERR_R(DS_ERR_INVAL, "json child contains its container");
        level++;
        root = a;
    }
    if (level + child->height > DS_JSON_MAX_DEPTH)
        return DS_ERR_R(DS_ERR_JSON_LIMIT,
                        "json tree would nest deeper than DS_JSON_MAX_DEPTH");
    uint64_t nodes = (uint64_t) root->nodes + child->nodes;
    uint64_t bytes = (uint64_t) root->str_bytes + child->str_bytes;
    if (replaced != NULL) {
        nodes -= replaced->nodes;
        bytes -= replaced->str_bytes;
    } else {
        bytes += key_bytes;
    }
    if (nodes > DS_JSON_MAX_NODES)
        return DS_ERR_R(DS_ERR_JSON_LIMIT,
                        "json tree would hold more than DS_JSON_MAX_NODES values");
    if (bytes > DS_JSON_MAX_STRING_BYTES)
        return DS_ERR_R(DS_ERR_JSON_LIMIT,
                        "json tree's strings would exceed DS_JSON_MAX_STRING_BYTES");
    return DS_OK_R;
}

bool ds_json_within_limits(const ds_json_t *tree, ds_json_breach_t *breach)
{
    ds_json_breach_t b = { DS_JSON_LIMIT_NONE, 0, 0 };
    if (tree != NULL) {
        if (tree->height > DS_JSON_MAX_DEPTH)
            b = (ds_json_breach_t){ DS_JSON_LIMIT_DEPTH, DS_JSON_MAX_DEPTH,
                                    tree->height };
        else if (tree->nodes > DS_JSON_MAX_NODES)
            b = (ds_json_breach_t){ DS_JSON_LIMIT_NODES, DS_JSON_MAX_NODES,
                                    tree->nodes };
        else if (tree->str_bytes > DS_JSON_MAX_STRING_BYTES)
            b = (ds_json_breach_t){ DS_JSON_LIMIT_STRING_BYTES,
                                    DS_JSON_MAX_STRING_BYTES, tree->str_bytes };
    }
    if (breach != NULL) *breach = b;
    return b.cap == DS_JSON_LIMIT_NONE;
}

bool ds_json_utf8_well_formed(const ds_json_t *tree)
{
    if (tree == NULL) return true;
    switch (tree->kind) {
    case DS_JSON_STRING:
        return tree->v.s == NULL
            || ds_utf8_well_formed(tree->v.s, strlen(tree->v.s));
    case DS_JSON_ARRAY:
        for (uint32_t i = 0; i < tree->v.arr.n; i++)
            if (!ds_json_utf8_well_formed(tree->v.arr.items[i])) return false;
        return true;
    case DS_JSON_OBJECT:
        for (uint32_t i = 0; i < tree->v.obj.n; i++) {
            const char *k = tree->v.obj.kvs[i].key;
            if (k != NULL && !ds_utf8_well_formed(k, strlen(k))) return false;
            if (!ds_json_utf8_well_formed(tree->v.obj.kvs[i].value))
                return false;
        }
        return true;
    case DS_JSON_NULL:
    case DS_JSON_BOOL:
    case DS_JSON_INT:
    case DS_JSON_FLOAT:
        return true;
    }
    return true;
}

ds_result_t ds_json_new_null(ds_json_t **out)
{
    if (out == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_new_null: out must not be null");
    *out = NULL;
    ds_json_t *node = json_new_node(DS_JSON_NULL);
    if (node == NULL) return DS_ERR_R(DS_ERR_OOM, "ds_json_new_null: alloc");
    *out = node;
    return DS_OK_R;
}

ds_result_t ds_json_new_bool(bool v, ds_json_t **out)
{
    if (out == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_new_bool: out must not be null");
    *out = NULL;
    ds_json_t *node = json_new_node(DS_JSON_BOOL);
    if (node == NULL) return DS_ERR_R(DS_ERR_OOM, "ds_json_new_bool: alloc");
    node->v.b = v;
    *out = node;
    return DS_OK_R;
}

ds_result_t ds_json_new_int(int64_t v, ds_json_t **out)
{
    if (out == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_new_int: out must not be null");
    *out = NULL;
    ds_json_t *node = json_new_node(DS_JSON_INT);
    if (node == NULL) return DS_ERR_R(DS_ERR_OOM, "ds_json_new_int: alloc");
    node->v.i = v;
    *out = node;
    return DS_OK_R;
}

ds_result_t ds_json_new_float(double v, ds_json_t **out)
{
    if (out == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_new_float: out must not be null");
    *out = NULL;
    /* [LGRA.5.8.10], [IDAT.3.3.9]. */
    if (!isfinite(v))
        return DS_ERR_R(DS_ERR_JSON_NONFINITE,
                        "ds_json_new_float: a non-finite float, which a Json "
                        "value does not hold (LGRA.5.8.10)");
    ds_json_t *node = json_new_float_node(v);
    if (node == NULL) return DS_ERR_R(DS_ERR_OOM, "ds_json_new_float: alloc");
    *out = node;
    return DS_OK_R;
}

ds_result_t ds_json_new_string(const char *s, size_t len, ds_json_t **out)
{
    if (out == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_new_string: out must not be null");
    *out = NULL;
    if (s == NULL && len > 0)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_new_string: s null with len > 0");
    /* The length first, so a host buffer over the limit is refused unscanned. */
    if (len > DS_JSON_MAX_STRING_BYTES)
        return DS_ERR_R(DS_ERR_JSON_LIMIT,
                        "ds_json_new_string: longer than DS_JSON_MAX_STRING_BYTES");
    /* [LSTR.1.1]. */
    if (len > 0 && has_nul(s, len))
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_new_string: s contains a NUL");
    /* [LSTR.8.5]. */
    if (len > 0 && !ds_utf8_well_formed(s, len))
        return DS_ERR_R(DS_ERR_ENCODING,
                        "ds_json_new_string: s is not well-formed UTF-8");
    char *dup = DS_MALLOC(len + 1);
    if (dup == NULL) return DS_ERR_R(DS_ERR_OOM, "ds_json_new_string: alloc");
    if (len > 0) memcpy(dup, s, len);
    dup[len] = '\0';
    ds_json_t *node = json_new_node(DS_JSON_STRING);
    if (node == NULL) {
        DS_FREE(dup);
        return DS_ERR_R(DS_ERR_OOM, "ds_json_new_string: alloc");
    }
    node->v.s       = dup;
    node->str_bytes = (uint32_t) len;
    *out = node;
    return DS_OK_R;
}

ds_result_t ds_json_new_array(ds_json_t **out)
{
    if (out == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_new_array: out must not be null");
    *out = NULL;
    ds_json_t *node = json_new_node(DS_JSON_ARRAY);
    if (node == NULL) return DS_ERR_R(DS_ERR_OOM, "ds_json_new_array: alloc");
    *out = node;
    return DS_OK_R;
}

ds_result_t ds_json_new_object(ds_json_t **out)
{
    if (out == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_new_object: out must not be null");
    *out = NULL;
    ds_json_t *node = json_new_node(DS_JSON_OBJECT);
    if (node == NULL) return DS_ERR_R(DS_ERR_OOM, "ds_json_new_object: alloc");
    *out = node;
    return DS_OK_R;
}

ds_result_t ds_json_array_append(ds_json_t *array, ds_json_t *child)
{
    if (array == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_array_append: array must not be null");
    if (child == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_array_append: child must not be null");
    if (array->kind != DS_JSON_ARRAY)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_array_append: node is not an array");
    if (array->v.arr.n == UINT32_MAX)
        return DS_ERR_R(DS_ERR_OOM, "ds_json_array_append: array full");
    ds_result_t rl = json_check_link(array, child, 0, NULL);
    if (rl.status != DS_OK) return rl;
    /* On OOM the array is unchanged and `child` is not consumed. */
    uint32_t n = array->v.arr.n;
    ds_json_t **bigger = DS_REALLOC(array->v.arr.items,
                                    (size_t) (n + 1) * sizeof(*bigger));
    if (bigger == NULL)
        return DS_ERR_R(DS_ERR_OOM, "ds_json_array_append: grow");
    array->v.arr.items    = bigger;
    array->v.arr.items[n] = child;
    array->v.arr.n        = n + 1;
    json_adopt(array, child, 0);
    return DS_OK_R;
}

ds_result_t ds_json_object_set(ds_json_t *object, const char *key,
                               size_t key_len, ds_json_t *child)
{
    if (object == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_object_set: object must not be null");
    if (key == NULL && key_len > 0)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_object_set: key null with key_len > 0");
    /* [LGRA.5.8.6]: first, so a host buffer over the limit is refused unscanned. It
       also keeps the (uint32_t) key counts below lossless. No refusal here consumes
       `child`. */
    if (key_len > DS_JSON_MAX_STRING_BYTES)
        return DS_ERR_R(DS_ERR_JSON_LIMIT,
                        "ds_json_object_set: key longer than DS_JSON_MAX_STRING_BYTES");
    /* [LSTR.1.1]. */
    if (key_len > 0 && has_nul(key, key_len))
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_object_set: key contains a NUL");
    /* [LSTR.8.5]. */
    if (key_len > 0 && !ds_utf8_well_formed(key, key_len))
        return DS_ERR_R(DS_ERR_ENCODING,
                        "ds_json_object_set: key is not well-formed UTF-8");
    if (child == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_object_set: child must not be null");
    if (object->kind != DS_JSON_OBJECT)
        return DS_ERR_R(DS_ERR_INVAL, "ds_json_object_set: node is not an object");
    if (object->v.obj.n == UINT32_MAX)
        return DS_ERR_R(DS_ERR_OOM, "ds_json_object_set: object full");

    /* Before the check: a replacement's totals are the tree's less the old value's. */
    uint32_t hit = UINT32_MAX;
    for (uint32_t i = 0; i < object->v.obj.n; i++) {
        const char *k = object->v.obj.kvs[i].key;
        if (k != NULL && strlen(k) == key_len &&
            (key_len == 0 || memcmp(k, key, key_len) == 0)) {
            hit = i;
            break;
        }
    }
    ds_result_t rl = json_check_link(object, child, (uint32_t) key_len,
                                     hit != UINT32_MAX
                                         ? object->v.obj.kvs[hit].value : NULL);
    if (rl.status != DS_OK) return rl;

    /* [IDAT.3.3.4]. The old value may have been the tallest child, so the heights are
       recomputed rather than only raised. */
    if (hit != UINT32_MAX) {
        ds_json_t *old = object->v.obj.kvs[hit].value;
        json_account(object, -(int64_t) old->nodes, -(int64_t) old->str_bytes);
        free_node(old);
        object->v.obj.kvs[hit].value = child;
        child->parent = object;
        json_account(object, (int64_t) child->nodes, (int64_t) child->str_bytes);
        json_refresh_heights(object);
        return DS_OK_R;
    }

    /* On OOM the object is unchanged and `child` is not consumed. */
    char *kdup = DS_MALLOC(key_len + 1);
    if (kdup == NULL)
        return DS_ERR_R(DS_ERR_OOM, "ds_json_object_set: key alloc");
    if (key_len > 0) memcpy(kdup, key, key_len);
    kdup[key_len] = '\0';

    uint32_t n = object->v.obj.n;
    ds_json_kv_t *bigger = DS_REALLOC(object->v.obj.kvs,
                                      (size_t) (n + 1) * sizeof(*bigger));
    if (bigger == NULL) {
        DS_FREE(kdup);
        return DS_ERR_R(DS_ERR_OOM, "ds_json_object_set: grow");
    }
    object->v.obj.kvs        = bigger;
    object->v.obj.kvs[n].key = kdup;
    object->v.obj.kvs[n].value = child;
    object->v.obj.n          = n + 1;
    json_adopt(object, child, (uint32_t) key_len);
    return DS_OK_R;
}
