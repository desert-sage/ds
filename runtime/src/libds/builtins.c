/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * builtins.c — DS built-in callable functions.
 *
 * Every refusal raises through `FAULT(...)`. No local wrapper: the sentinel
 * ratchet in runtime/tests/libds/source/ counts producers.
 *
 * `eval_call` has counted the operands ([RDSC.4a.9.5]), so a builtin counts none.
 * An operand's kind is the value's: DS_FAULT_TYPE_MISMATCH, whose class splits on
 * provenance. An operand the compiler inlines (the currency selector) of the
 * wrong kind is the artefact's.
 */
#include <inttypes.h>
#include <math.h>
#include <sys/types.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "internal/json.h"
#include "ds_alloc.h"
#include "ds_text.h"

#include "engine.h"
#include "rete/adapters.h"
#include "rete/engine.h"
#include "rete/eval.h"
#include "rete/action.h"
#include "rete/beta.h"
#include "rete/expr.h"
#include "rete/terminal.h"
#include "rete/intern.h"
#include "rete/schema_reg.h"
#include "rete/wm_rete.h"
#include "fn.h"
#include "rete/val.h"
#include "int_ops.h"
#include "float_fmt.h"
#include "core_math.h"

#define ARG_INT(args, i)   ((args)[(i)].kind == DS_RETE_VAL_INT   ? (args)[(i)].i : 0)
#define ARG_FLOAT(args, i) ((args)[(i)].kind == DS_RETE_VAL_FLOAT  ? (args)[(i)].f : \
                            (args)[(i)].kind == DS_RETE_VAL_INT    ? (double)(args)[(i)].i : 0.0)

/* A String operand's bytes, and their count in *len: NULL when the operand is
   no String. */
static const char *arg_str(const ds_rete_val_t *args, uint32_t i, size_t *len)
{
    if (args[i].kind != DS_RETE_VAL_STR || args[i].s.ptr == NULL) {
        *len = 0;
        return NULL;
    }
    *len = args[i].s.len;
    return args[i].s.ptr;
}

/* `expr` is NULL: a builtin is handed no expression node, and provenance comes
   from `ctx->json_tainted`, which `eval_call` stamps. */
#define FAULT(cause_) ds_rete_fault(ctx, NULL, (cause_))

/* ---- compiled regex cache ------------------------------------------ */

#define RCACHE_MAX_LOAD 70u

static uint32_t rcache_hash(const char *pat, size_t plen, unsigned flags)
{
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < plen; i++) { h ^= (uint8_t)pat[i]; h *= 16777619u; }
    h ^= (uint32_t)flags; h *= 16777619u;
    return h;
}

/* Look up only: ds_rete_regex_precompile() filled the table at load. */
static const ds_re2_t *regex_cache_get(const ds_rete_engine_t *engine,
                                       const char             *pat,
                                       size_t                  plen,
                                       unsigned                flags)
{
    if (!engine->regex_cache || engine->regex_cache_cap == 0) return NULL;
    uint32_t cap = engine->regex_cache_cap;
    uint32_t h   = rcache_hash(pat, plen, flags) & (cap - 1);
    for (uint32_t probes = 0; probes < cap; probes++) {
        const struct ds_regex_cache_entry *e = &engine->regex_cache[h];
        if (!e->pat) return NULL;                   /* empty → not present */
        if (e->pat == pat && e->flags == flags)     /* interned: ptr eq    */
            return e->compiled;
        h = (h + 1) & (cap - 1);
    }
    return NULL;                                     /* full table, absent */
}

/* Insert one (interned pat, flags), compiling it. RCACHE_OOM refuses the load
   with DS_ERR_OOM ([IALC.3.6]). */
typedef enum { RCACHE_OK, RCACHE_REJECTED, RCACHE_OOM } rcache_result_t;

static rcache_result_t rcache_insert(ds_rete_engine_t *engine,
                                     const char       *pat,
                                     unsigned          flags)
{
    uint32_t cap = engine->regex_cache_cap;
    if (cap == 0) return RCACHE_REJECTED;
    /* `pat` is an expression's literal, a C string, not a value. */
    const size_t plen = strlen(pat);
    uint32_t h = rcache_hash(pat, plen, flags) & (cap - 1);
    for (uint32_t probes = 0; probes < cap; probes++) {
        struct ds_regex_cache_entry *e = &engine->regex_cache[h];
        if (!e->pat) {
            char re_err[256];
            re_err[0] = '\0';
            ds_re2_t *re = ds_re2_compile_n(pat, plen, flags, re_err,
                                            sizeof re_err);
            if (!re)
                return strcmp(re_err, DS_RE2_ERR_OOM) == 0 ? RCACHE_OOM
                                                           : RCACHE_REJECTED;
            e->pat = pat; e->flags = flags; e->compiled = re;
            return RCACHE_OK;
        }
        if (e->pat == pat && e->flags == flags) return RCACHE_OK; /* already in */
        h = (h + 1) & (cap - 1);
    }
    return RCACHE_REJECTED;
}

/* ---- compile every pattern at load --------------------------------- */

/* The flag letters ([LREG.5.2]) to the DS_RE2_* mask. A loop, not memchr: memchr
   is on no microcontroller allow list (runtime/docker/mcu_allow). */
static unsigned rcache_flags_of(const char *flags, size_t flen)
{
    unsigned f = 0;
    for (size_t i = 0; flags != NULL && i < flen; i++) {
        if      (flags[i] == 'i') f |= DS_RE2_ICASE;
        else if (flags[i] == 'm') f |= DS_RE2_MULTILINE;
        else if (flags[i] == 's') f |= DS_RE2_DOTALL;
    }
    return f;
}

/* Visit every regex call in one expression tree. The switch has no default, so a
   new node kind is a -Wswitch warning here: a miss in the cache is only an error
   if this walk reaches every pattern. */
static void regex_walk_expr(const ds_rete_expr_t *e,
                            void (*visit)(const char *pat, const char *flags,
                                          void *user),
                            void *user)
{
    if (!e) return;
    switch (e->kind) {
    case DS_RETE_EXPR_CALL:
        /* args are (subject, pattern, flags); pattern and flags are literals. */
        if (DS_FN_IS_REGEX(e->call.op) && e->call.arg_count >= 2) {
            const ds_rete_expr_t *p = e->call.args[1];
            const ds_rete_expr_t *f = (e->call.arg_count >= 3)
                                    ? e->call.args[2] : NULL;
            if (p && p->kind == DS_RETE_EXPR_LIT_STR && p->lit_str) {
                const char *fl = (f && f->kind == DS_RETE_EXPR_LIT_STR)
                               ? f->lit_str : NULL;
                visit(p->lit_str, fl, user);
            }
        }
        for (uint32_t i = 0; i < e->call.arg_count; i++)
            regex_walk_expr(e->call.args[i], visit, user);
        return;
    case DS_RETE_EXPR_BINOP:
        regex_walk_expr(e->binop.left,  visit, user);
        regex_walk_expr(e->binop.right, visit, user);
        return;
    case DS_RETE_EXPR_UNOP:
        regex_walk_expr(e->unop.operand, visit, user);
        return;
    case DS_RETE_EXPR_INTERP:
        for (uint32_t i = 0; i < e->interp.prim_count; i++)
            regex_walk_expr(e->interp.prims[i].value, visit, user);   /* NULL for text */
        return;
    case DS_RETE_EXPR_JSON_PATH:
        regex_walk_expr(e->json_path.val,  visit, user);
        regex_walk_expr(e->json_path.path, visit, user);
        return;
    case DS_RETE_EXPR_IF:
        regex_walk_expr(e->if_.cond,  visit, user);
        regex_walk_expr(e->if_.then_, visit, user);
        regex_walk_expr(e->if_.else_, visit, user);
        return;
    case DS_RETE_EXPR_BIND:
        regex_walk_expr(e->bind.expr, visit, user);
        return;
    case DS_RETE_EXPR_COALESCE:
        regex_walk_expr(e->coalesce.left,  visit, user);
        regex_walk_expr(e->coalesce.right, visit, user);
        return;
    case DS_RETE_EXPR_IS_TEST:
        regex_walk_expr(e->is_test.operand, visit, user);
        return;
    case DS_RETE_EXPR_LIT_INT:
    case DS_RETE_EXPR_LIT_FLOAT:
    case DS_RETE_EXPR_LIT_STR:
    case DS_RETE_EXPR_LIT_BOOL:
    case DS_RETE_EXPR_LIT_NULL:
    case DS_RETE_EXPR_LIT_TIME:
    case DS_RETE_EXPR_VAR:
    case DS_RETE_EXPR_NOW:
    case DS_RETE_EXPR_BIND_REF:
    case DS_RETE_EXPR_ENTRY_STAMP:
        return;
    }
}

/* Every expression root the loaded network owns. An alpha REGEX test carries its
   pattern as a string, compiled by the loader ([RDSC.4a.6]). */
static void regex_walk_network(const ds_rete_engine_t *engine,
                               void (*visit)(const char *pat, const char *flags,
                                             void *user),
                               void *user)
{
    for (uint32_t i = 0; i < engine->owned_beta_count; i++) {
        const struct ds_rete_beta_node *b = engine->owned_betas[i];
        if (!b) continue;
        for (uint32_t j = 0; j < b->join_test_count; j++)
            regex_walk_expr(b->join_tests[j].expr, visit, user);
    }
    for (uint32_t i = 0; i < engine->owned_terminal_count; i++) {
        const struct ds_rete_terminal *t = engine->owned_terminals[i];
        if (!t) continue;
        regex_walk_expr(t->fire_guard, visit, user);
        for (uint32_t j = 0; j < t->action_count; j++) {
            const ds_rete_action_t *a = &t->actions[j];
            regex_walk_expr(a->expr,         visit, user);
            regex_walk_expr(a->ttl_override, visit, user);
            for (uint32_t k = 0; k < a->assign_count; k++)
                regex_walk_expr(a->assigns[k].expr, visit, user);
        }
    }
}

static void regex_count_visit(const char *pat, const char *flags, void *user)
{
    (void)pat; (void)flags;
    (*(uint32_t *)user)++;
}

struct regex_insert_ctx {
    ds_rete_engine_t *engine;
    const char       *bad;
    rcache_result_t   why;
};

static void regex_insert_visit(const char *pat, const char *flags, void *user)
{
    struct regex_insert_ctx *cx = (struct regex_insert_ctx *)user;
    if (cx->bad) return;
    rcache_result_t r = rcache_insert(cx->engine, pat,
                            rcache_flags_of(flags, flags ? strlen(flags) : 0));
    if (r != RCACHE_OK) { cx->bad = pat; cx->why = r; }
}

ds_result_t ds_rete_regex_precompile(ds_rete_engine_t *engine)
{
    if (!engine) return DS_ERR_R(DS_ERR_INVAL, "regex_precompile: null engine");

    uint32_t n = 0;
    regex_walk_network(engine, regex_count_visit, &n);
    if (n == 0) return DS_OK_R;

    uint32_t want = (n * 100u) / RCACHE_MAX_LOAD + 1u;
    uint32_t cap  = 8u;
    while (cap < want) cap <<= 1;

    struct ds_regex_cache_entry *tab = DS_CALLOC(cap, sizeof(*tab));
    if (!tab) return DS_ERR_R(DS_ERR_OOM, "regex_precompile: cache alloc");

    if (engine->regex_cache) {
        for (uint32_t i = 0; i < engine->regex_cache_cap; i++)
            if (engine->regex_cache[i].compiled)
                ds_re2_free(engine->regex_cache[i].compiled);
        DS_FREE(engine->regex_cache);
    }
    engine->regex_cache     = tab;
    engine->regex_cache_cap = cap;

    struct regex_insert_ctx cx = { engine, NULL, RCACHE_OK };
    regex_walk_network(engine, regex_insert_visit, &cx);
    if (cx.bad && cx.why == RCACHE_OOM)
        return DS_ERR_R(DS_ERR_OOM, "regex_precompile: out of memory compiling");
    if (cx.bad) {
        return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                        "regex_precompile: pattern rejected by RE2");
    }
    return DS_OK_R;
}

/* ---- `~` / DS_FN_REGEX_MATCH (RE2) -------------------------------- */

/* DS_FN_REGEX_MATCH(<string>, <pattern>, <flags>) → Bool */
static ds_result_t builtin_regex_match(ds_rete_engine_t  *engine,
                                        ds_rete_eval_ctx_t *ctx,
                                        ds_rete_val_t      *args,
                                        uint32_t            argc,
                                        ds_rete_val_t      *out)
{
    (void)engine;
    /* [LNUL.4.1], [LREG.1.3]: a null subject propagates. */
    if (args[0].kind == DS_RETE_VAL_NULL) {
        *out = ds_rete_val_null();
        return DS_OK_R;
    }
    size_t slen, plen, flen = 0;
    const char *s     = arg_str(args, 0, &slen);
    const char *pat   = arg_str(args, 1, &plen);
    const char *flags = (argc >= 3) ? arg_str(args, 2, &flen) : NULL;
    if (!s || !pat) { *out = ds_rete_val_bool(false); return DS_OK_R; }

    const unsigned rflags = rcache_flags_of(flags, flen);

    /* [IALC.3.6]: out of memory inside RE2 is not "no match". */
    bool oom = false;
    const ds_re2_t *cached = regex_cache_get(engine, pat, plen, rflags);
    if (cached) {
        const bool hit = ds_re2_match_n(cached, s, slen, &oom);
        *out = oom ? FAULT(DS_FAULT_RESOURCE) : ds_rete_val_bool(hit);
        return DS_OK_R;
    }

    /* A miss with a cache: the cache and the expression arena disagree. With no
       cache, this is a hand-built network, which compiles per call. */
    if (engine->regex_cache != NULL) {
        *out = FAULT(DS_FAULT_ARTEFACT);
        return DS_OK_R;
    }
    char re_err[64];
    re_err[0] = '\0';
    ds_re2_t *re = ds_re2_compile_n(pat, plen, rflags, re_err, sizeof re_err);
    if (!re) {
        *out = strcmp(re_err, DS_RE2_ERR_OOM) == 0 ? FAULT(DS_FAULT_RESOURCE)
                                                   : ds_rete_val_bool(false);
        return DS_OK_R;
    }
    const bool hit = ds_re2_match_n(re, s, slen, &oom);
    ds_re2_free(re);
    *out = oom ? FAULT(DS_FAULT_RESOURCE) : ds_rete_val_bool(hit);
    return DS_OK_R;
}

/* ---- DS_FN_REGEX_CAPTURE ([LREG.4.1]) ------------------------------ */

/*
 * DS_FN_REGEX_CAPTURE(<string>, <pattern>, <flags>, <group>) → String
 *
 * `group` is 1-based. The result is interned: RE2 returns views into the subject,
 * which may be an arena value reset next pump.
 *
 * A group that did not participate (an alternation branch not taken) is the empty
 * string; no clause rules on it.
 */
static ds_result_t builtin_regex_capture(ds_rete_engine_t  *engine,
                                          ds_rete_eval_ctx_t *ctx,
                                          ds_rete_val_t      *args,
                                          uint32_t            argc,
                                          ds_rete_val_t      *out)
{
    size_t slen, plen, flen;
    const char *s     = arg_str(args, 0, &slen);
    const char *pat   = arg_str(args, 1, &plen);
    const char *flags = arg_str(args, 2, &flen);
    if (!s || !pat) { *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R; }
    if (args[3].kind != DS_RETE_VAL_INT)
        { *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R; }
    const int64_t group = args[3].i;
    /* The group index is the compiler's, so out of range is the artefact's. */
    if (group < 1 || group > 64)
        { *out = FAULT(DS_FAULT_ARTEFACT); return DS_OK_R; }

    const unsigned rflags = rcache_flags_of(flags, flen);

    /* The cache contract of builtin_regex_match. */
    const ds_re2_t *cached = regex_cache_get(engine, pat, plen, rflags);
    ds_re2_t       *owned  = NULL;
    if (!cached) {
        if (engine->regex_cache != NULL)
            { *out = FAULT(DS_FAULT_ARTEFACT); return DS_OK_R; }
        char re_err[64];
        re_err[0] = '\0';
        owned = ds_re2_compile_n(pat, plen, rflags, re_err, sizeof re_err);
        if (!owned) {
            *out = FAULT(strcmp(re_err, DS_RE2_ERR_OOM) == 0
                         ? DS_FAULT_RESOURCE : DS_FAULT_ARTEFACT);
            return DS_OK_R;
        }
        cached = owned;
    }

    /* RE2 gives a group past the count the same NULL as a non-participating one.
       The compiler holds name count to capture count ([LREG.4.2]). */
    if (group > (int64_t)ds_re2_group_count(cached)) {
        if (owned) ds_re2_free(owned);
        *out = FAULT(DS_FAULT_ARTEFACT);
        return DS_OK_R;
    }

    const char *ptr[64];
    size_t      len[64];
    bool oom = false;
    bool matched = ds_re2_capture_n(cached, s, slen, ptr, len, (int)group, &oom);
    if (owned) ds_re2_free(owned);
    if (oom) { *out = FAULT(DS_FAULT_RESOURCE); return DS_OK_R; }
    /* The lowering gates the activation on the match ([LREG.1.2]). */
    if (!matched) { *out = FAULT(DS_FAULT_ARTEFACT); return DS_OK_R; }

    const char *piece     = ptr[group - 1];
    size_t      piece_len = len[group - 1];
    if (piece == NULL) { piece = ""; piece_len = 0; }

    const char *ip = NULL;
    ds_result_t r = ds_rete_intern_value(engine->intern, piece,
                                          (uint32_t)piece_len, &ip);
    if (r.status != DS_OK) { *out = FAULT(DS_FAULT_RESOURCE); return DS_OK_R; }
    *out = ds_rete_val_str(ip, (uint32_t)piece_len);
    return DS_OK_R;
}

/* ---- DS_FN_ERROR_CODE_MATCHES ([LECC.6.2]) ------------------------- */

/* Whether <pattern>'s segments are a prefix of <code>'s ([LCCO.8.3.2]). "auth"
   matches "auth" and "auth.failed", but not "auth_failed". */
static bool error_code_matches(const char *code, size_t clen,
                               const char *pattern, size_t plen)
{
    if (!code || !pattern) return false;
    if (plen == 0) return true;
    if (clen < plen || memcmp(code, pattern, plen) != 0) return false;
    return clen == plen || code[plen] == '.';
}

/* [LECC.1.2]: `[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*`. */
bool ds_error_code_valid(const char *s)
{
    if (s == NULL || s[0] == '\0') return false;
    size_t i = 0;
    while (s[i] != '\0') {
        char c = s[i];
        if (c < 'a' || c > 'z') return false;
        i++;
        while (s[i] != '\0' && s[i] != '.') {
            char ch = s[i];
            if (!((ch >= 'a' && ch <= 'z') ||
                  (ch >= '0' && ch <= '9') ||
                  ch == '_')) return false;
            i++;
        }
        if (s[i] == '.') {
            i++;
            if (s[i] == '\0') return false;
        }
    }
    return true;
}

static ds_result_t builtin_error_code_matches(ds_rete_engine_t  *engine,
                                               ds_rete_eval_ctx_t *ctx,
                                               ds_rete_val_t      *args,
                                               uint32_t            argc,
                                               ds_rete_val_t      *out)
{
    (void)engine;
    size_t clen, plen;
    const char *code    = arg_str(args, 0, &clen);
    const char *pattern = arg_str(args, 1, &plen);
    *out = ds_rete_val_bool(error_code_matches(code, clen, pattern, plen));
    return DS_OK_R;
}

/* ---- str-length ---------------------------------------------------- */

/* [LSTR.2.1]: every UTF-8 byte that is not a continuation byte starts a
   codepoint. */
static int64_t str_codepoints(const char *p, uint32_t len)
{
    int64_t n = 0;
    for (uint32_t i = 0; i < len; i++)
        if (((unsigned char) p[i] & 0xC0u) != 0x80u) n++;
    return n;
}

static ds_result_t builtin_str_length(ds_rete_engine_t  *engine,
                                       ds_rete_eval_ctx_t *ctx,
                                       ds_rete_val_t      *args,
                                       uint32_t            argc,
                                       ds_rete_val_t      *out)
{
    (void)engine;
    /* [LSTR.4.2]: `Bytes`, the byte count. */
    if (args[0].kind == DS_RETE_VAL_BYTES)
        { *out = ds_rete_val_int((int64_t) args[0].s.len); return DS_OK_R; }
    /* [LEXP.6.1]: a whole `Json` slot; the compiler folds only a path into
       DS_FN_JSON_LEN. */
    if ((args[0].kind == DS_RETE_VAL_JSON
         || args[0].kind == DS_RETE_VAL_JSON_BORROW)
        && args[0].json != NULL && args[0].json->kind == DS_JSON_ARRAY) {
        *out = ds_rete_val_int((int64_t) args[0].json->v.arr.n);
        return DS_OK_R;
    }
    if (args[0].kind != DS_RETE_VAL_STR)
        { *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R; }
    *out = ds_rete_val_int(str_codepoints(args[0].s.ptr, args[0].s.len));
    return DS_OK_R;
}

/* ---- math builtins ------------------------------------------------- */

#define NUM_REQUIRE1() \
    do { if (args[0].kind != DS_RETE_VAL_INT && \
             args[0].kind != DS_RETE_VAL_FLOAT) \
             { *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R; } \
    } while (0)

#define NUM_REQUIRE2() \
    do { for (uint32_t _i = 0; _i < 2u; _i++) \
             if (args[_i].kind != DS_RETE_VAL_INT && \
                 args[_i].kind != DS_RETE_VAL_FLOAT) \
                 { *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R; } \
    } while (0)

static double to_double(const ds_rete_val_t *v)
{
    return (v->kind == DS_RETE_VAL_INT) ? (double)v->i : v->f;
}

/* floor / ceil / trunc / round of an Int are that Int ([LEXP.3.2]), never through
   a double. */
#define INT_IS_ITS_OWN_ROUNDING()                                              \
    do { if (argc >= 1 && args[0].kind == DS_RETE_VAL_INT)                     \
             { *out = args[0]; return DS_OK_R; } } while (0)

/* An integral double into an Int, or [LEXP.3.2.1]'s NOT_REPRESENTABLE. One range
   test covers NaN and the infinities, so no isfinite, a libm symbol the
   microcontroller allowlists refuse (runtime/docker/mcu_allow/). */
static ds_result_t rounded_to_int(ds_rete_eval_ctx_t *ctx, double r,
                                  ds_rete_val_t *out)
{
    if (!(r >= -9223372036854775808.0 && r < 9223372036854775808.0)) {
        *out = FAULT(DS_FAULT_NOT_REPRESENTABLE);
        return DS_OK_R;
    }
    *out = ds_rete_val_int((int64_t)r);
    return DS_OK_R;
}

static ds_result_t builtin_floor(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                  ds_rete_val_t *args, uint32_t argc,
                                  ds_rete_val_t *out)
{
    (void)e; NUM_REQUIRE1();
    INT_IS_ITS_OWN_ROUNDING();
    return rounded_to_int(ctx, floor(args[0].f), out);
}
static ds_result_t builtin_ceil(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                 ds_rete_val_t *args, uint32_t argc,
                                 ds_rete_val_t *out)
{
    (void)e; NUM_REQUIRE1();
    INT_IS_ITS_OWN_ROUNDING();
    return rounded_to_int(ctx, ceil(args[0].f), out);
}
static ds_result_t builtin_trunc(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                  ds_rete_val_t *args, uint32_t argc,
                                  ds_rete_val_t *out)
{
    (void)e; NUM_REQUIRE1();
    INT_IS_ITS_OWN_ROUNDING();
    return rounded_to_int(ctx, trunc(args[0].f), out);
}
static ds_result_t builtin_sign(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                 ds_rete_val_t *args, uint32_t argc,
                                 ds_rete_val_t *out)
{
    (void)e; NUM_REQUIRE1();
    double x = to_double(&args[0]);
    *out = ds_rete_val_int((x > 0.0) - (x < 0.0));
    return DS_OK_R;
}

static ds_result_t builtin_abs(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                               ds_rete_val_t *args, uint32_t argc,
                               ds_rete_val_t *out)
{
    (void)e;
    if (args[0].kind == DS_RETE_VAL_INT) {
        *out = ds_rete_val_int(ds_i64_abs(args[0].i));
    } else if (args[0].kind == DS_RETE_VAL_FLOAT) {
        *out = ds_rete_val_float(fabs(args[0].f));
    } else {
        *out = FAULT(ds_rete_mismatch_cause(args, argc));
    }
    return DS_OK_R;
}

/* rint() ties to even under the default rounding mode, which DS never changes. */
static ds_result_t builtin_round(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                 ds_rete_val_t *args, uint32_t argc,
                                 ds_rete_val_t *out)
{
    (void)e; NUM_REQUIRE1();
    INT_IS_ITS_OWN_ROUNDING();
    return rounded_to_int(ctx, rint(args[0].f), out);
}

/* A negative argument gives NaN ([LDET.3.6.2]). */
static ds_result_t builtin_sqrt(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                 ds_rete_val_t *args, uint32_t argc,
                                 ds_rete_val_t *out)
{
    (void)e; NUM_REQUIRE1();
    *out = ds_rete_val_float(sqrt(to_double(&args[0])));
    return DS_OK_R;
}

/* The transcendentals ([LEXP.3.9.1]), correctly rounded through CORE-MATH, never
 * the platform's libm ([LDET.3.4.1]). None traps ([LEXP.3.9.3]). */
#define CM_UNARY(name, fn)                                                    \
    static ds_result_t builtin_##name(ds_rete_engine_t *e,                    \
                                      ds_rete_eval_ctx_t *ctx,                \
                                      ds_rete_val_t *args, uint32_t argc,     \
                                      ds_rete_val_t *out)                     \
    {                                                                         \
        (void)e; NUM_REQUIRE1();                                              \
        *out = ds_rete_val_float(fn(to_double(&args[0])));                    \
        return DS_OK_R;                                                       \
    }

CM_UNARY(exp,   ds_cm_exp)
CM_UNARY(ln,    ds_cm_log)
CM_UNARY(log2,  ds_cm_log2)
CM_UNARY(log10, ds_cm_log10)
CM_UNARY(sin,   ds_cm_sin)
CM_UNARY(cos,   ds_cm_cos)
CM_UNARY(tan,   ds_cm_tan)
CM_UNARY(asin,  ds_cm_asin)
CM_UNARY(acos,  ds_cm_acos)
CM_UNARY(atan,  ds_cm_atan)
CM_UNARY(sinh,  ds_cm_sinh)
CM_UNARY(cosh,  ds_cm_cosh)
CM_UNARY(tanh,  ds_cm_tanh)

#undef CM_UNARY

static ds_result_t builtin_atan2(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                 ds_rete_val_t *args, uint32_t argc,
                                 ds_rete_val_t *out)
{
    (void)e; NUM_REQUIRE2();
    *out = ds_rete_val_float(ds_cm_atan2(to_double(&args[0]), to_double(&args[1])));
    return DS_OK_R;
}

/* [LEXP.3.2.2]: `ds_libm_fma`, libds's own on every row ([IARC.7.14]), so the
 * compiler cannot lower it to an instruction on one row and a libc call on
 * another. A null operand is null, before the kind test ([LNUL.4.1]). */
static ds_result_t builtin_fma(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                               ds_rete_val_t *args, uint32_t argc,
                               ds_rete_val_t *out)
{
    (void)e;
    for (uint32_t i = 0; i < 3u; i++)
        if (args[i].kind == DS_RETE_VAL_NULL) {
            *out = ds_rete_val_null();
            return DS_OK_R;
        }
    for (uint32_t i = 0; i < 3u; i++)
        if (args[i].kind != DS_RETE_VAL_INT &&
            args[i].kind != DS_RETE_VAL_FLOAT)
            { *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R; }
    *out = ds_rete_val_float(ds_libm_fma(to_double(&args[0]), to_double(&args[1]),
                                         to_double(&args[2])));
    return DS_OK_R;
}

/* `**`: Int ** non-negative Int is an Int ([LEXP.7.3a]); every other form is
 * CORE-MATH's `pow` ([LEXP.3.9.2]). */
static ds_result_t builtin_pow(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                               ds_rete_val_t *args, uint32_t argc,
                               ds_rete_val_t *out)
{
    (void)e; NUM_REQUIRE2();
    if (args[0].kind == DS_RETE_VAL_INT &&
        args[1].kind == DS_RETE_VAL_INT &&
        args[1].i >= 0) {
        *out = ds_rete_val_int(ds_i64_pow(args[0].i, args[1].i));
        return DS_OK_R;
    }
    *out = ds_rete_val_float(ds_cm_pow(to_double(&args[0]), to_double(&args[1])));
    return DS_OK_R;
}

/* [LEXP.3.8]: the winning operand verbatim, keeping its kind. Two Ints compare
 * exactly ([LDET.3.2.2]); a mixed pair through double. */
static bool first_wins(const ds_rete_val_t *a, const ds_rete_val_t *b, bool want_max)
{
    if (a->kind == DS_RETE_VAL_INT && b->kind == DS_RETE_VAL_INT)
        return want_max ? a->i >= b->i : a->i <= b->i;
    return want_max ? to_double(a) >= to_double(b) : to_double(a) <= to_double(b);
}

static ds_result_t builtin_max(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                               ds_rete_val_t *args, uint32_t argc,
                               ds_rete_val_t *out)
{
    (void)e; NUM_REQUIRE2();
    *out = first_wins(&args[0], &args[1], true) ? args[0] : args[1];
    return DS_OK_R;
}

static ds_result_t builtin_min(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                               ds_rete_val_t *args, uint32_t argc,
                               ds_rete_val_t *out)
{
    (void)e; NUM_REQUIRE2();
    *out = first_wins(&args[0], &args[1], false) ? args[0] : args[1];
    return DS_OK_R;
}

/* [LEXP.3.6.1]: one correctly rounded multiply. M_PI is not guaranteed under
   strict POSIX. */
static const double DS_RAD_TO_DEG = 180.0 / 3.14159265358979323846;
static const double DS_DEG_TO_RAD = 3.14159265358979323846 / 180.0;

static ds_result_t builtin_rad_deg(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                   ds_rete_val_t *args, uint32_t argc,
                                   ds_rete_val_t *out)
{
    (void)e; NUM_REQUIRE1();
    *out = ds_rete_val_float(to_double(&args[0]) * DS_RAD_TO_DEG);
    return DS_OK_R;
}

static ds_result_t builtin_deg_rad(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                   ds_rete_val_t *args, uint32_t argc,
                                   ds_rete_val_t *out)
{
    (void)e; NUM_REQUIRE1();
    *out = ds_rete_val_float(to_double(&args[0]) * DS_DEG_TO_RAD);
    return DS_OK_R;
}

/* Geometric distance ([LEXP.5.3], [LEXP.5.5]): 2D takes (ax ay bx by), or (x y)
 * for hypot; 3D takes 6, or 3. */
#define GEO_REQUIRE(n) \
    do { for (uint32_t _i = 0; _i < (n); _i++) \
             if (args[_i].kind != DS_RETE_VAL_INT && \
                 args[_i].kind != DS_RETE_VAL_FLOAT) \
                 { *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R; } \
    } while (0)

static ds_result_t builtin_euclidean_2d(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                         ds_rete_val_t *args, uint32_t argc,
                                         ds_rete_val_t *out)
{
    (void)e; GEO_REQUIRE(4);
    double dx = to_double(&args[0]) - to_double(&args[2]);
    double dy = to_double(&args[1]) - to_double(&args[3]);
    *out = ds_rete_val_float(sqrt(dx * dx + dy * dy));
    return DS_OK_R;
}

static ds_result_t builtin_euclidean_3d(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                         ds_rete_val_t *args, uint32_t argc,
                                         ds_rete_val_t *out)
{
    (void)e; GEO_REQUIRE(6);
    double dx = to_double(&args[0]) - to_double(&args[3]);
    double dy = to_double(&args[1]) - to_double(&args[4]);
    double dz = to_double(&args[2]) - to_double(&args[5]);
    *out = ds_rete_val_float(sqrt(dx * dx + dy * dy + dz * dz));
    return DS_OK_R;
}

static ds_result_t builtin_manhattan_2d(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                         ds_rete_val_t *args, uint32_t argc,
                                         ds_rete_val_t *out)
{
    (void)e; GEO_REQUIRE(4);
    *out = ds_rete_val_float(
        fabs(to_double(&args[0]) - to_double(&args[2])) +
        fabs(to_double(&args[1]) - to_double(&args[3])));
    return DS_OK_R;
}

static ds_result_t builtin_manhattan_3d(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                         ds_rete_val_t *args, uint32_t argc,
                                         ds_rete_val_t *out)
{
    (void)e; GEO_REQUIRE(6);
    *out = ds_rete_val_float(
        fabs(to_double(&args[0]) - to_double(&args[3])) +
        fabs(to_double(&args[1]) - to_double(&args[4])) +
        fabs(to_double(&args[2]) - to_double(&args[5])));
    return DS_OK_R;
}

static double _max2(double a, double b) { return a > b ? a : b; }

static ds_result_t builtin_chebyshev_2d(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                         ds_rete_val_t *args, uint32_t argc,
                                         ds_rete_val_t *out)
{
    (void)e; GEO_REQUIRE(4);
    *out = ds_rete_val_float(_max2(
        fabs(to_double(&args[0]) - to_double(&args[2])),
        fabs(to_double(&args[1]) - to_double(&args[3]))));
    return DS_OK_R;
}

static ds_result_t builtin_chebyshev_3d(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                         ds_rete_val_t *args, uint32_t argc,
                                         ds_rete_val_t *out)
{
    (void)e; GEO_REQUIRE(6);
    double m = _max2(
        fabs(to_double(&args[0]) - to_double(&args[3])),
        fabs(to_double(&args[1]) - to_double(&args[4])));
    m = _max2(m, fabs(to_double(&args[2]) - to_double(&args[5])));
    *out = ds_rete_val_float(m);
    return DS_OK_R;
}

static ds_result_t builtin_hypot_2d(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                     ds_rete_val_t *args, uint32_t argc,
                                     ds_rete_val_t *out)
{
    (void)e; GEO_REQUIRE(2);
    double x = to_double(&args[0]), y = to_double(&args[1]);
    *out = ds_rete_val_float(sqrt(x * x + y * y));
    return DS_OK_R;
}

static ds_result_t builtin_hypot_3d(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                     ds_rete_val_t *args, uint32_t argc,
                                     ds_rete_val_t *out)
{
    (void)e; GEO_REQUIRE(3);
    double x = to_double(&args[0]), y = to_double(&args[1]), z = to_double(&args[2]);
    *out = ds_rete_val_float(sqrt(x * x + y * y + z * z));
    return DS_OK_R;
}

/* [LEXP.5.7.3]'s composition. A zero vector gives NaN ([LDET.3.6.2]). */
static double _cos_dist(double dot, double na2, double nb2)
{
    return 1.0 - dot / (sqrt(na2) * sqrt(nb2));
}

static ds_result_t builtin_cosine_2d(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                      ds_rete_val_t *args, uint32_t argc,
                                      ds_rete_val_t *out)
{
    (void)e; GEO_REQUIRE(4);
    double ax = to_double(&args[0]), ay = to_double(&args[1]);
    double bx = to_double(&args[2]), by = to_double(&args[3]);
    *out = ds_rete_val_float(_cos_dist(ax * bx + ay * by,
                                       ax * ax + ay * ay,
                                       bx * bx + by * by));
    return DS_OK_R;
}

static ds_result_t builtin_cosine_3d(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                      ds_rete_val_t *args, uint32_t argc,
                                      ds_rete_val_t *out)
{
    (void)e; GEO_REQUIRE(6);
    double ax = to_double(&args[0]), ay = to_double(&args[1]), az = to_double(&args[2]);
    double bx = to_double(&args[3]), by = to_double(&args[4]), bz = to_double(&args[5]);
    *out = ds_rete_val_float(_cos_dist(ax * bx + ay * by + az * bz,
                                       ax * ax + ay * ay + az * az,
                                       bx * bx + by * by + bz * bz));
    return DS_OK_R;
}

/* [LEXP.5.11.2]'s composition; Mercury: `ds.eval.lexp_5_11_2_great_circle`.
 * [LEXP.5.11.3]: one range test per argument covers NaN and the infinities. */
static ds_result_t builtin_great_circle(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                         ds_rete_val_t *args, uint32_t argc,
                                         ds_rete_val_t *out)
{
    (void)e; GEO_REQUIRE(4);
    double lat1 = to_double(&args[0]), lon1 = to_double(&args[1]);
    double lat2 = to_double(&args[2]), lon2 = to_double(&args[3]);
    if (!(lat1 >= -90.0 && lat1 <= 90.0) || !(lat2 >= -90.0 && lat2 <= 90.0) ||
        !(lon1 >= -180.0 && lon1 <= 180.0) || !(lon2 >= -180.0 && lon2 <= 180.0)) {
        *out = ds_rete_val_float(NAN);
        return DS_OK_R;
    }
    double phi1 = lat1 * DS_DEG_TO_RAD;
    double phi2 = lat2 * DS_DEG_TO_RAD;
    double dphi = (lat2 - lat1) * DS_DEG_TO_RAD;
    double dlam = (lon2 - lon1) * DS_DEG_TO_RAD;
    double s = ds_cm_sin(dphi / 2.0);
    double t = ds_cm_sin(dlam / 2.0);
    double a = s * s + (ds_cm_cos(phi1) * ds_cm_cos(phi2)) * (t * t);
    double ac = a < 0.0 ? 0.0 : (a > 1.0 ? 1.0 : a);
    *out = ds_rete_val_float(
        6371008.8 * (2.0 * ds_cm_atan2(sqrt(ac), sqrt(1.0 - ac))));
    return DS_OK_R;
}

/* `t.floor(d)` ([LTIM.7.1]): `utc_ns - floor_mod(utc_ns + offset_ns, d)`. An
 * untagged Int is a Time slot read: it floors at offset 0 and stays an Int. The
 * offset is fixed and no zone is consulted, so [LTIM.7.3]'s DST cases are not
 * met. */
static int64_t floor_mod_i64(int64_t a, int64_t d)   /* d > 0; in [0, d) */
{
    int64_t r = a % d;
    return r < 0 ? r + d : r;
}

static ds_result_t builtin_floor_time(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                       ds_rete_val_t *args, uint32_t argc,
                                       ds_rete_val_t *out)
{
    (void)e;
    if ((args[0].kind != DS_RETE_VAL_INT && args[0].kind != DS_RETE_VAL_TIME) ||
        args[1].kind != DS_RETE_VAL_INT)
        { *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R; }
    int64_t d = args[1].i;
    if (d <= 0)
        { *out = FAULT(DS_FAULT_DIVIDE_BY_ZERO); return DS_OK_R; }
    bool zoned = args[0].kind == DS_RETE_VAL_TIME;
    int64_t t = zoned ? args[0].time.utc_ns : args[0].i;
    int64_t off = zoned ? (int64_t)args[0].time.tz_offset_s * 1000000000LL : 0;
    /* (t + off) mod d without forming t + off, which may overflow. */
    uint64_t sum = (uint64_t)floor_mod_i64(t, d) + (uint64_t)floor_mod_i64(off, d);
    int64_t r = (int64_t)(sum >= (uint64_t)d ? sum - (uint64_t)d : sum);
    int64_t floored;
    if (__builtin_sub_overflow(t, r, &floored))
        { *out = FAULT(DS_FAULT_NOT_REPRESENTABLE); return DS_OK_R; }
    *out = zoned ? ds_rete_val_time(floored, args[0].time.tz_offset_s)
                 : ds_rete_val_int(floored);
    return DS_OK_R;
}

/* [RLOW.7.3.9]: `n / d` when `d` divides `n`. C's `/` and `%` trap on
 * INT64_MIN / -1, so it is answered before dividing. */
static ds_result_t builtin_int_div_exact(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                         ds_rete_val_t *args, uint32_t argc,
                                         ds_rete_val_t *out)
{
    (void)e;
    if (args[0].kind == DS_RETE_VAL_NULL || args[1].kind == DS_RETE_VAL_NULL)
        { *out = ds_rete_val_null(); return DS_OK_R; }
    if (args[0].kind != DS_RETE_VAL_INT || args[1].kind != DS_RETE_VAL_INT)
        { *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R; }
    int64_t n = args[0].i;
    int64_t d = args[1].i;
    if (d == 0)
        { *out = FAULT(DS_FAULT_DIVIDE_BY_ZERO); return DS_OK_R; }
    if ((n == INT64_MIN && d == -1) || n % d != 0)
        { *out = FAULT(DS_FAULT_NOT_REPRESENTABLE); return DS_OK_R; }
    *out = ds_rete_val_int(n / d);
    return DS_OK_R;
}

/* ---- bitwise builtins -------------------------------------------------- */

#define INT_REQUIRE1() \
    do { if (args[0].kind != DS_RETE_VAL_INT) \
             { *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R; } \
    } while (0)

#define INT_REQUIRE2() \
    do { if (args[0].kind != DS_RETE_VAL_INT || \
             args[1].kind != DS_RETE_VAL_INT) \
             { *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R; } \
    } while (0)

#define BITWISE2(name_, op_) \
static ds_result_t builtin_##name_(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx, \
                                    ds_rete_val_t *args, uint32_t argc,           \
                                    ds_rete_val_t *out) { \
    (void)e; INT_REQUIRE2(); \
    *out = ds_rete_val_int(args[0].i op_ args[1].i); return DS_OK_R; }

BITWISE2(bit_and, &)
BITWISE2(bit_or,  |)
BITWISE2(bit_xor, ^)

/* [LEXP.7.14.1]: a negative count is DOMAIN, before the int_ops helpers, whose
   precondition is count >= 0. */
static ds_result_t builtin_bit_shl(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                    ds_rete_val_t *args, uint32_t argc,
                                    ds_rete_val_t *out)
{
    (void)e; INT_REQUIRE2();
    if (args[1].i < 0) { *out = FAULT(DS_FAULT_DOMAIN); return DS_OK_R; }
    *out = ds_rete_val_int(ds_i64_shl(args[0].i, args[1].i));
    return DS_OK_R;
}

static ds_result_t builtin_bit_shr(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                    ds_rete_val_t *args, uint32_t argc,
                                    ds_rete_val_t *out)
{
    (void)e; INT_REQUIRE2();
    if (args[1].i < 0) { *out = FAULT(DS_FAULT_DOMAIN); return DS_OK_R; }
    *out = ds_rete_val_int(ds_i64_shr(args[0].i, args[1].i));
    return DS_OK_R;
}

static ds_result_t builtin_bit_not(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                    ds_rete_val_t *args, uint32_t argc,
                                    ds_rete_val_t *out)
{
    (void)e; INT_REQUIRE1();
    *out = ds_rete_val_int(~args[0].i);
    return DS_OK_R;
}

static ds_result_t builtin_bit_count(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                      ds_rete_val_t *args, uint32_t argc,
                                      ds_rete_val_t *out)
{
    (void)e; INT_REQUIRE1();
#if defined(__GNUC__) || defined(__clang__)
    *out = ds_rete_val_int((int64_t)__builtin_popcountll((unsigned long long)args[0].i));
#else
    uint64_t x = (uint64_t)args[0].i;
    int64_t n = 0;
    while (x) { n += (int64_t)(x & 1u); x >>= 1; }
    *out = ds_rete_val_int(n);
#endif
    return DS_OK_R;
}

static ds_result_t builtin_bit_length(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                       ds_rete_val_t *args, uint32_t argc,
                                       ds_rete_val_t *out)
{
    (void)e; INT_REQUIRE1();
    *out = ds_rete_val_int(ds_i64_bit_length(args[0].i));
    return DS_OK_R;
}

/* ---- the Int members bits .. trailing_zeros ([LEXP.3.7.3]) --------- */

/* A null receiver or argument is null, before the kind test. */
#define BIT_MEMBER_REQUIRE(n_) \
    do { for (uint32_t _i = 0; _i < (n_); _i++) \
             if (args[_i].kind == DS_RETE_VAL_NULL) \
                 { *out = ds_rete_val_null(); return DS_OK_R; } \
         for (uint32_t _i = 0; _i < (n_); _i++) \
             if (args[_i].kind != DS_RETE_VAL_INT) \
                 { *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R; } \
    } while (0)

/* [LEXP.3.7.4]: a width or position out of domain, before the int_ops.h helper
   whose precondition it is. */
static ds_result_t builtin_bits(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                ds_rete_val_t *args, uint32_t argc,
                                ds_rete_val_t *out)
{
    (void)e; BIT_MEMBER_REQUIRE(3u);
    int64_t lo = args[1].i, w = args[2].i;
    if (lo < 0 || w < 1 || w > 64 || lo > 64 - w)
        { *out = FAULT(DS_FAULT_DOMAIN); return DS_OK_R; }
    *out = ds_rete_val_int(ds_i64_bits(args[0].i, lo, w));
    return DS_OK_R;
}

static ds_result_t builtin_sign_extend(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                       ds_rete_val_t *args, uint32_t argc,
                                       ds_rete_val_t *out)
{
    (void)e; BIT_MEMBER_REQUIRE(2u);
    int64_t w = args[1].i;
    if (w < 1 || w > 64) { *out = FAULT(DS_FAULT_DOMAIN); return DS_OK_R; }
    *out = ds_rete_val_int(ds_i64_sign_extend(args[0].i, w));
    return DS_OK_R;
}

static ds_result_t builtin_swap_bytes(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                      ds_rete_val_t *args, uint32_t argc,
                                      ds_rete_val_t *out)
{
    (void)e; BIT_MEMBER_REQUIRE(2u);
    int64_t w = args[1].i;
    if (w != 16 && w != 32 && w != 64)
        { *out = FAULT(DS_FAULT_DOMAIN); return DS_OK_R; }
    *out = ds_rete_val_int(ds_i64_swap_bytes(args[0].i, w));
    return DS_OK_R;
}

static ds_result_t builtin_leading_zeros(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                         ds_rete_val_t *args, uint32_t argc,
                                         ds_rete_val_t *out)
{
    (void)e; BIT_MEMBER_REQUIRE(1u);
    *out = ds_rete_val_int(ds_i64_leading_zeros(args[0].i));
    return DS_OK_R;
}

static ds_result_t builtin_trailing_zeros(ds_rete_engine_t *e, ds_rete_eval_ctx_t *ctx,
                                          ds_rete_val_t *args, uint32_t argc,
                                          ds_rete_val_t *out)
{
    (void)e; BIT_MEMBER_REQUIRE(1u);
    *out = ds_rete_val_int(ds_i64_trailing_zeros(args[0].i));
    return DS_OK_R;
}

#undef BIT_MEMBER_REQUIRE

/* ---- now ----------------------------------------------------------- */

static ds_result_t builtin_now(ds_rete_engine_t  *engine,
                                ds_rete_eval_ctx_t *ctx,
                                ds_rete_val_t      *args,
                                uint32_t            argc,
                                ds_rete_val_t      *out)
{
    /* The same read as the NOW expression node (rete/eval.c). */
    (void)args; (void)argc;
    int64_t wall = 0;
    if (!engine->wall_fn(engine->clock_ctx, &wall)) {
        *out = FAULT(DS_FAULT_DOMAIN);
        return DS_OK_R;
    }
    *out = ds_rete_val_time(wall, 0);
    return DS_OK_R;
}

/* JSON text as a Json builtin's root, parsed. Text that is not JSON is the
   mismatch; text over a limit of [LGRA.5.8.6] is NOT_REPRESENTABLE. False with
   *out the fault; true with *owned the tree. */
static bool json_root_of_text(ds_rete_eval_ctx_t *ctx, ds_rete_val_t *args,
                              uint32_t argc, const ds_rete_val_t *text,
                              ds_json_t **owned, ds_rete_val_t *out)
{
    ds_result_t r = ds_json_parse(text->s.ptr, text->s.len, owned);
    if (r.status == DS_OK) return true;
    *out = FAULT(r.status == DS_ERR_JSON_LIMIT
                     ? DS_FAULT_NOT_REPRESENTABLE
                     : ds_rete_mismatch_cause(args, argc));
    return false;
}

/* ---- DS_FN_JSON_PATH ----------------------------------------------- */

static ds_result_t builtin_json_path(ds_rete_engine_t  *engine,
                                      ds_rete_eval_ctx_t *ctx,
                                      ds_rete_val_t      *args,
                                      uint32_t            argc,
                                      ds_rete_val_t      *out)
{
    if (args[1].kind != DS_RETE_VAL_STR)
        { *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R; }
    const char  *path = args[1].s.ptr;
    const size_t plen = args[1].s.len;

    /* [LNUL.8.4]: a `null` root, a `Json?` slot holding none, has no document
       to resolve against, and the read is `null`, a leaf. */
    if (args[0].kind == DS_RETE_VAL_NULL) {
        if (ctx) ctx->json_composite = false;
        *out = ds_rete_val_null();
        return DS_OK_R;
    }

    ds_json_t       *owned = NULL;
    const ds_json_t *root  = NULL;

    if (args[0].kind == DS_RETE_VAL_JSON || args[0].kind == DS_RETE_VAL_JSON_BORROW) {
        root = args[0].json;
    } else if (args[0].kind == DS_RETE_VAL_STR) {
        if (!json_root_of_text(ctx, args, argc, &args[0], &owned, out))
            return DS_OK_R;
        root = owned;
    } else {
        *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R;
    }

    const ds_json_t *found = NULL;
    ds_json_get_path_n(root, path, plen, &found);
    /* Read by eval_interp (LGRA.2.9.6.11): only a leaf renders. */
    if (ctx)
        ctx->json_composite = found != NULL
            && (found->kind == DS_JSON_ARRAY || found->kind == DS_JSON_OBJECT);
    *out = ds_rete_json_path_result(ctx, engine, found, owned);
    return DS_OK_R;
}

/* ---- DS_FN_JSON_HAS ------------------------------------------------ */

/* [LEXP.6]: presence, read off the node: the projection maps a present null and
   an unresolved path to one value ([LNUL.8.4]). */
static ds_result_t builtin_json_has(ds_rete_engine_t  *engine,
                                     ds_rete_eval_ctx_t *ctx,
                                     ds_rete_val_t      *args,
                                     uint32_t            argc,
                                     ds_rete_val_t      *out)
{
    (void)engine;
    if (args[1].kind != DS_RETE_VAL_STR)
        { *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R; }
    const char  *path = args[1].s.ptr;
    const size_t plen = args[1].s.len;

    ds_json_t       *owned = NULL;
    const ds_json_t *root  = NULL;

    if (args[0].kind == DS_RETE_VAL_JSON || args[0].kind == DS_RETE_VAL_JSON_BORROW) {
        root = args[0].json;
    } else if (args[0].kind == DS_RETE_VAL_STR) {
        if (!json_root_of_text(ctx, args, argc, &args[0], &owned, out))
            return DS_OK_R;
        root = owned;
    } else {
        *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R;
    }

    const ds_json_t *found = NULL;
    ds_json_get_path_n(root, path, plen, &found);
    *out = ds_rete_val_bool(found != NULL);
    if (owned) ds_json_free(owned);
    return DS_OK_R;
}

/* ---- DS_FN_JSON_LEN ([LEXP.6.1]) ----------------------------------- */

/* Takes the root and the path, not a projected value: projection serialises an
   array to its text before any builtin runs. */
static ds_result_t builtin_json_len(ds_rete_engine_t  *engine,
                                     ds_rete_eval_ctx_t *ctx,
                                     ds_rete_val_t      *args,
                                     uint32_t            argc,
                                     ds_rete_val_t      *out)
{
    (void)engine;
    if (args[1].kind != DS_RETE_VAL_STR)
        { *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R; }
    const char  *path = args[1].s.ptr;
    const size_t plen = args[1].s.len;

    ds_json_t       *owned = NULL;
    const ds_json_t *root  = NULL;

    if (args[0].kind == DS_RETE_VAL_JSON || args[0].kind == DS_RETE_VAL_JSON_BORROW) {
        root = args[0].json;
    } else if (args[0].kind == DS_RETE_VAL_STR) {
        if (!json_root_of_text(ctx, args, argc, &args[0], &owned, out))
            return DS_OK_R;
        root = owned;
    } else {
        *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R;
    }

    const ds_json_t *found = NULL;
    ds_json_get_path_n(root, path, plen, &found);
    /* [LEXP.6.2]: an unresolved path is `null`, not an array. */
    if (found == NULL || found->kind != DS_JSON_ARRAY)
        *out = FAULT(ds_rete_mismatch_cause(args, argc));
    else
        *out = ds_rete_val_int((int64_t)found->v.arr.n);
    if (owned) ds_json_free(owned);
    return DS_OK_R;
}

/* ---- Currency methods ([LUNI.13]) ---------------------------------- */

/* Checked int64 multiply: wrapped money is the worst outcome. No __int128: the
 * 32-bit embedded targets have none. */
static bool i64_mul_ok(int64_t a, int64_t b, int64_t *out)
{
    if (a == 0 || b == 0) { *out = 0; return true; }
    if (a > 0) {
        if (b > 0) { if (a > INT64_MAX / b) return false; }
        else       { if (b < INT64_MIN / a) return false; }
    } else {
        if (b > 0) { if (a < INT64_MIN / b) return false; }
        else       { if (a < INT64_MAX / b) return false; }
    }
    *out = a * b;
    return true;
}

/* [RLOW.7.3.9]'s FN_INT_MUL_ADD_CHECKED(x, m, a): `m*x + a`, an integer-stored
 * unit's conversion. The product, and then the sum, are each held to the Int
 * range, and either outside it is NOT_REPRESENTABLE: a sum that would come back
 * into range after the product left it raises too, and nothing wraps. A null
 * operand is null; the compiler writes `m` and `a` as literals. */
static ds_result_t builtin_int_mul_add_checked(ds_rete_engine_t *e,
                                               ds_rete_eval_ctx_t *ctx,
                                               ds_rete_val_t *args, uint32_t argc,
                                               ds_rete_val_t *out)
{
    (void)e;
    if (args[0].kind == DS_RETE_VAL_NULL || args[1].kind == DS_RETE_VAL_NULL ||
        args[2].kind == DS_RETE_VAL_NULL)
        { *out = ds_rete_val_null(); return DS_OK_R; }
    if (args[0].kind != DS_RETE_VAL_INT || args[1].kind != DS_RETE_VAL_INT ||
        args[2].kind != DS_RETE_VAL_INT)
        { *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R; }
    int64_t product, sum;
    if (!i64_mul_ok(args[1].i, args[0].i, &product) ||
        __builtin_add_overflow(product, args[2].i, &sum))
        { *out = FAULT(DS_FAULT_NOT_REPRESENTABLE); return DS_OK_R; }
    *out = ds_rete_val_int(sum);
    return DS_OK_R;
}

/* [LUNI.13.5], [LUNI.13.6]: round num/den (den > 0) in integers. The tie test is
 * `|r|` against `den - |r|`, since `2*|r|` could overflow. False on an int64
 * boundary. */
static bool currency_round_ratio(int64_t num, int64_t den, int64_t mode,
                                 int64_t *out)
{
    if (den <= 0) return false;
    int64_t q = num / den;
    int64_t r = num % den;
    if (r == 0) { *out = q; return true; }

    const bool neg = (num < 0);
    const int64_t ar   = neg ? -r : r;
    const int64_t rest = den - ar;

    bool away;  /* step the magnitude away from zero? */
    switch (mode) {
    case DS_ROUND_TRUNCATE:  away = false;          break;
    case DS_ROUND_CEILING:   away = !neg;           break;
    case DS_ROUND_FLOOR:     away = neg;            break;
    case DS_ROUND_HALF_UP:   away = (ar >= rest);   break;
    case DS_ROUND_HALF_DOWN: away = (ar >  rest);   break;
    case DS_ROUND_HALF_EVEN:
        away = (ar != rest) ? (ar > rest) : (q % 2 != 0);
        break;
    default: return false;
    }
    if (!away) { *out = q; return true; }
    if (neg) { if (q == INT64_MIN) return false; *out = q - 1; }
    else     { if (q == INT64_MAX) return false; *out = q + 1; }
    return true;
}

/* A finite double as an exact num/den, den a power of two. False if it will not
 * fit int64 after scaling. */
static bool double_to_ratio(double d, int64_t *num, int64_t *den)
{
    if (!isfinite(d)) return false;
    double  scaled = d;
    int64_t den_   = 1;
    for (int i = 0; i < 62 && scaled != floor(scaled); i++) {
        if (den_ > INT64_MAX / 2) return false;
        scaled *= 2.0;
        den_   *= 2;
    }
    if (scaled != floor(scaled)) return false;
    if (!(scaled >= -9223372036854775808.0 && scaled < 9223372036854775808.0))
        return false;
    *num = (int64_t)scaled;
    *den = den_;
    return true;
}

/* The receiver of a round: a Ratio from CURRENCY_CONVERT, an Int, or a Float
 * intermediate ([LUNI.13.5.2]), decomposed exactly. */
static bool currency_receiver(const ds_rete_val_t *v,
                              int64_t *num, int64_t *den)
{
    switch (v->kind) {
    case DS_RETE_VAL_RATIO:
        *num = v->ratio.num; *den = v->ratio.den; return true;
    case DS_RETE_VAL_INT:
        *num = v->i; *den = 1; return true;
    case DS_RETE_VAL_FLOAT:
        return double_to_ratio(v->f, num, den);
    default:
        return false;
    }
}

/* [LUNI.13.5] */
static ds_result_t builtin_currency_round(ds_rete_engine_t *e,
                                          ds_rete_eval_ctx_t *ctx,
                                          ds_rete_val_t *args, uint32_t argc,
                                          ds_rete_val_t *out)
{
    (void)e;
    int64_t num, den, res;
    if (args[1].kind != DS_RETE_VAL_INT)
        { *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R; }
    if (!currency_receiver(&args[0], &num, &den))
        { *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R; }
    if (!currency_round_ratio(num, den, args[1].i, &res))
        { *out = FAULT(DS_FAULT_NOT_REPRESENTABLE); return DS_OK_R; }
    *out = ds_rete_val_int(res);
    return DS_OK_R;
}

/* [LUNI.13.5]: `scale` is the coarser unit's size in minor units, and the result
 * stays in minor units: round(num / (den*scale)) * scale. */
static ds_result_t builtin_currency_round_to(ds_rete_engine_t *e,
                                             ds_rete_eval_ctx_t *ctx,
                                             ds_rete_val_t *args, uint32_t argc,
                                             ds_rete_val_t *out)
{
    (void)e;
    int64_t num, den, scaled_den, k, res;
    if (args[1].kind != DS_RETE_VAL_INT || args[2].kind != DS_RETE_VAL_INT)
        { *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R; }
    /* `scale` is the compiler's. */
    if (args[1].i <= 0) { *out = FAULT(DS_FAULT_ARTEFACT); return DS_OK_R; }
    if (!currency_receiver(&args[0], &num, &den))
        { *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R; }
    if (!i64_mul_ok(den, args[1].i, &scaled_den)
        || !currency_round_ratio(num, scaled_den, args[2].i, &k)
        || !i64_mul_ok(k, args[1].i, &res))
        { *out = FAULT(DS_FAULT_NOT_REPRESENTABLE); return DS_OK_R; }
    *out = ds_rete_val_int(res);
    return DS_OK_R;
}

/* The exact intermediate, not rounded: the mode is the author's at the call site
 * ([LUNI.13.4], [LUNI.13.5]). */
static ds_result_t currency_apply_rate(ds_rete_eval_ctx_t *ctx,
                                       int64_t amount, int64_t rate_num,
                                       int64_t rate_den, ds_rete_val_t *out)
{
    if (rate_den == 0)
        { *out = FAULT(DS_FAULT_DIVIDE_BY_ZERO); return DS_OK_R; }
    int64_t num, den = rate_den;
    if (!i64_mul_ok(amount, rate_num, &num)) {
        *out = FAULT(DS_FAULT_NOT_REPRESENTABLE); return DS_OK_R;
    }
    /* currency_round_ratio relies on den > 0. */
    if (den < 0) {
        if (den == INT64_MIN || num == INT64_MIN) {
            *out = FAULT(DS_FAULT_NOT_REPRESENTABLE); return DS_OK_R;
        }
        den = -den; num = -num;
    }
    *out = ds_rete_val_ratio(num, den);
    return DS_OK_R;
}

/* In engine_rete_adapters.c, which can see the full ds_engine_t. */
extern void ds_engine_fx_note_fallback(struct ds_rete_engine *re, const char *pair);
extern void ds_engine_fx_note_ambiguous(struct ds_rete_engine *re, const char *pair);

/* The greatest-`asof` search over one `unit fx_pair`'s selector ([LUNI.4.6.2]).
 * The selector arrives inlined as literal arguments. */
struct fx_probe {
    const ds_rete_schema_t *schema_ref; /* NULL: the name names no schema */
    const ds_rete_val_t *num_field;   /* the rate slots' names, String values */
    const ds_rete_val_t *den_field;
    ds_rete_val_t *sel;         /* [slot, value] pairs, interleaved       */
    uint32_t       n_sel;       /* number of pairs, not values            */
    bool     found;
    bool     asof_tie;          /* two matches share the greatest asof    */
    bool     asof_missing;      /* the schema has no `asof` slot          */
    double   best_asof;
    int64_t  num, den;
};

static bool fx_name_is(const char *slot_name, const char *name, size_t len)
{
    return slot_name != NULL && name != NULL && strlen(slot_name) == len
        && memcmp(slot_name, name, len) == 0;
}

static const ds_rete_val_t *fx_slot(const ds_rete_fact_t *f, const char *name,
                                    size_t len)
{
    const ds_rete_schema_t *sc = f->schema;
    if (!sc) return NULL;
    for (uint16_t i = 0; i < sc->slot_count; i++) {
        if (fx_name_is(sc->slots[i].name, name, len))
            return &f->slots[i];
    }
    return NULL;
}

static const ds_rete_val_t *fx_slot_v(const ds_rete_fact_t *f,
                                      const ds_rete_val_t *name)
{
    return fx_slot(f, name->s.ptr, name->s.len);
}

/* Answer the selector from the identity map when the via-schema's key is the
 * selector: at most one live fact per key ([LFAC.1.7]), so the scan would find
 * the same fact. Every uncertainty returns false and lets the scan run. */
#define FX_ID_QUERY_MAX 32u

static bool fx_try_identity(ds_rete_engine_t *e, struct fx_probe *p)
{
    const ds_rete_schema_t *s = p->schema_ref;

    if (!s->id_dedup) return false;
    if (s->id_key_count != p->n_sel) return false;
    if (s->slot_count > FX_ID_QUERY_MAX) return false;

    /* Shaped like a fact's slots. Only the id_key_slots positions are read. */
    ds_rete_val_t q[FX_ID_QUERY_MAX];
    memset(q, 0, sizeof(q[0]) * s->slot_count);

    for (uint16_t k = 0; k < s->id_key_count; k++) {
        uint16_t    idx   = s->id_key_slots[k];
        const char *kname = (idx < s->slot_count) ? s->slots[idx].name : NULL;
        bool        bound = false;
        if (!kname) return false;

        for (uint32_t i = 0; i < p->n_sel && !bound; i++) {
            const ds_rete_val_t *sname = &p->sel[i * 2];
            const ds_rete_val_t *sval  = &p->sel[i * 2 + 1];
            if (!fx_name_is(kname, sname->s.ptr, sname->s.len)) continue;
            if (sval->kind != DS_RETE_VAL_STR) return false;
            q[idx] = *sval;
            bound  = true;
        }
        if (!bound) return false;
    }

    ds_rete_fact_t *f = ds_rete_wm_find_by_identity(e, s, q);
    if (!f) return false;

    const ds_rete_val_t *n = fx_slot_v(f, p->num_field);
    const ds_rete_val_t *d = fx_slot_v(f, p->den_field);
    if (!n || !d || n->kind != DS_RETE_VAL_INT || d->kind != DS_RETE_VAL_INT)
        return false;

    if (!fx_slot(f, "asof", 4)) p->asof_missing = true;
    p->found = true;
    p->num   = n->i;
    p->den   = d->i;
    return true;
}

static int fx_visit(ds_rete_fact_t *f, void *ctx)
{
    struct fx_probe *p = (struct fx_probe *)ctx;
    if (!f->schema || !f->schema->name) return 0;
    if (f->schema != p->schema_ref) return 0;

    for (uint32_t i = 0; i < p->n_sel; i++) {
        const ds_rete_val_t *want = &p->sel[i * 2 + 1];
        const ds_rete_val_t *got  = fx_slot_v(f, &p->sel[i * 2]);
        if (!got) return 0;
        if (got->kind != DS_RETE_VAL_STR && got->kind != DS_RETE_VAL_BYTES)
            return 0;
        if (!got->s.ptr || !want->s.ptr) return 0;
        if (got->s.len != want->s.len
            || memcmp(got->s.ptr, want->s.ptr, got->s.len) != 0) return 0;
    }

    const ds_rete_val_t *n = fx_slot_v(f, p->num_field);
    const ds_rete_val_t *d = fx_slot_v(f, p->den_field);
    if (!n || !d || n->kind != DS_RETE_VAL_INT || d->kind != DS_RETE_VAL_INT)
        return 0;

    /* `asof` is named by [LUNI.13.3], not by the pair declaration. */
    const ds_rete_val_t *a = fx_slot(f, "asof", 4);
    double asof = 0.0;
    if (!a) {
        p->asof_missing = true;
    } else if (a->kind == DS_RETE_VAL_FLOAT) {
        asof = a->f;
    } else if (a->kind == DS_RETE_VAL_INT) {
        asof = (double)a->i;
    } else {
        p->asof_missing = true;
    }

    if (!p->found || asof > p->best_asof) {
        if (p->found && asof == p->best_asof) p->asof_tie = true;
        p->found = true; p->best_asof = asof;
        p->num = n->i; p->den = d->i;
    } else if (asof == p->best_asof) {
        p->asof_tie = true;
    }
    return 0;
}

/* DS_FN_CURRENCY_CONVERT(<amount:Int>, <pair:Str>, <schema:Str>,
 *                        <num_field:Str>, <den_field:Str>,
 *                        [<slot:Str>, <value:Str>]...)
 * -> Ratio [LUNI.13.4]
 *
 * No match converts 1:1 ([LUNI.4.6.1]), and is counted. */
static ds_result_t builtin_currency_convert(ds_rete_engine_t *e,
                                            ds_rete_eval_ctx_t *ctx,
                                            ds_rete_val_t *args, uint32_t argc,
                                            ds_rete_val_t *out)
{
    if (args[0].kind != DS_RETE_VAL_INT)
        { *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R; }
    /* Inlined by the compiler, so a non-String is the artefact's. */
    for (uint32_t i = 1; i < argc; i++) {
        if (args[i].kind != DS_RETE_VAL_STR)
            { *out = FAULT(DS_FAULT_ARTEFACT); return DS_OK_R; }
    }

    struct fx_probe p;
    memset(&p, 0, sizeof(p));
    p.num_field = &args[3];
    p.den_field = &args[4];
    p.sel       = &args[5];
    p.n_sel     = (argc - 5) / 2;

    /* A metric label, which reaches the host as a C string (rete/val.h). */
    const char *pair = args[1].s.ptr ? args[1].s.ptr : "";

    if (e && args[2].s.ptr)
        p.schema_ref = ds_rete_schema_by_name_n(e, args[2].s.ptr, args[2].s.len);

    if (e && p.schema_ref && !fx_try_identity(e, &p))
        ds_rete_wm_for_each(e, fx_visit, &p);

    if (!p.found) {
        ds_engine_fx_note_fallback(e, pair);
        return currency_apply_rate(ctx, args[0].i, 1, 1, out);
    }
    if (p.asof_tie || p.asof_missing) ds_engine_fx_note_ambiguous(e, pair);
    return currency_apply_rate(ctx, args[0].i, p.num, p.den, out);
}

/* ---- Registration -------------------------------------------------- */

#define REG(op, fn) do { \
    ds_result_t _r = ds_register_fn((op), (fn)); \
    if (_r.status != DS_OK) return _r; \
} while (0)

/* Idempotent: called per engine init, and the table is shared. */
ds_result_t ds_register_builtins(ds_rete_engine_t *engine)
{
    if (!engine) return DS_ERR_R(DS_ERR_INVAL, "register_builtins: NULL engine");

    REG(DS_FN_REGEX_MATCH,        builtin_regex_match);
    REG(DS_FN_REGEX_CAPTURE,      builtin_regex_capture);
    REG(DS_FN_ERROR_CODE_MATCHES, builtin_error_code_matches);
    REG(DS_FN_STR_LENGTH,         builtin_str_length);

    REG(DS_FN_FLOOR,      builtin_floor);
    REG(DS_FN_FLOOR_TIME, builtin_floor_time);
    REG(DS_FN_CEIL,       builtin_ceil);
    REG(DS_FN_TRUNC,      builtin_trunc);
    REG(DS_FN_SIGN,       builtin_sign);
    REG(DS_FN_ABS,        builtin_abs);
    REG(DS_FN_ROUND,      builtin_round);
    REG(DS_FN_SQRT,       builtin_sqrt);
    REG(DS_FN_DEGREES,    builtin_rad_deg);
    REG(DS_FN_RADIANS,    builtin_deg_rad);
    REG(DS_FN_POW,        builtin_pow);
    REG(DS_FN_MAX,        builtin_max);
    REG(DS_FN_MIN,        builtin_min);
    REG(DS_FN_INT_DIV_EXACT, builtin_int_div_exact);
    REG(DS_FN_INT_MUL_ADD_CHECKED, builtin_int_mul_add_checked);

    REG(DS_FN_EXP,   builtin_exp);
    REG(DS_FN_LN,    builtin_ln);
    REG(DS_FN_LOG2,  builtin_log2);
    REG(DS_FN_LOG10, builtin_log10);
    REG(DS_FN_SIN,   builtin_sin);
    REG(DS_FN_COS,   builtin_cos);
    REG(DS_FN_TAN,   builtin_tan);
    REG(DS_FN_ASIN,  builtin_asin);
    REG(DS_FN_ACOS,  builtin_acos);
    REG(DS_FN_ATAN,  builtin_atan);
    REG(DS_FN_ATAN2, builtin_atan2);
    REG(DS_FN_FMA,   builtin_fma);
    REG(DS_FN_SINH,  builtin_sinh);
    REG(DS_FN_COSH,  builtin_cosh);
    REG(DS_FN_TANH,  builtin_tanh);

    REG(DS_FN_EUCLIDEAN_2D,  builtin_euclidean_2d);
    REG(DS_FN_EUCLIDEAN_3D,  builtin_euclidean_3d);
    REG(DS_FN_MANHATTAN_2D,  builtin_manhattan_2d);
    REG(DS_FN_MANHATTAN_3D,  builtin_manhattan_3d);
    REG(DS_FN_CHEBYSHEV_2D,  builtin_chebyshev_2d);
    REG(DS_FN_CHEBYSHEV_3D,  builtin_chebyshev_3d);
    REG(DS_FN_HYPOTENUSE_2D, builtin_hypot_2d);
    REG(DS_FN_HYPOTENUSE_3D, builtin_hypot_3d);
    REG(DS_FN_COSINE_2D,     builtin_cosine_2d);
    REG(DS_FN_COSINE_3D,     builtin_cosine_3d);
    REG(DS_FN_GREAT_CIRCLE,  builtin_great_circle);

    REG(DS_FN_BIT_COUNT,  builtin_bit_count);
    REG(DS_FN_BIT_LENGTH, builtin_bit_length);
    REG(DS_FN_BITS,           builtin_bits);
    REG(DS_FN_SIGN_EXTEND,    builtin_sign_extend);
    REG(DS_FN_SWAP_BYTES,     builtin_swap_bytes);
    REG(DS_FN_LEADING_ZEROS,  builtin_leading_zeros);
    REG(DS_FN_TRAILING_ZEROS, builtin_trailing_zeros);
    REG(DS_FN_BIT_AND,    builtin_bit_and);
    REG(DS_FN_BIT_OR,     builtin_bit_or);
    REG(DS_FN_BIT_XOR,    builtin_bit_xor);
    REG(DS_FN_BIT_NOT,    builtin_bit_not);
    REG(DS_FN_BIT_SHL,    builtin_bit_shl);
    REG(DS_FN_BIT_SHR,    builtin_bit_shr);

    REG(DS_FN_NOW,      builtin_now);

    REG(DS_FN_JSON_PATH,   builtin_json_path);
    REG(DS_FN_JSON_HAS,    builtin_json_has);
    REG(DS_FN_JSON_LEN,    builtin_json_len);

    REG(DS_FN_CURRENCY_ROUND,    builtin_currency_round);
    REG(DS_FN_CURRENCY_ROUND_TO, builtin_currency_round_to);
    REG(DS_FN_CURRENCY_CONVERT,  builtin_currency_convert);

    return DS_OK_R;
}
