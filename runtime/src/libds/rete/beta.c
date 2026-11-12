/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/beta.c — beta node lifecycle and join algorithm (IRET.7).
 */
#include <stdlib.h>
#include <string.h>
#include <assert.h>

#include "libds.h"
#include "ds_alloc.h"

#include "rete/alpha.h"
#include "rete/beta.h"
#include "rete/clone.h"
#include "rete/expr.h"
#include "rete/engine.h"
#include "rete/eval.h"
#include "rete/fact.h"
#include "rete/schema_reg.h"
#include "rete/terminal.h"
#include "rete/token.h"

/* ---- Match-time faults, once per derivation ([LERR.1.4.12]) -------- */

/* A TypeError or ComputationError a join test raised, with the pair that raised
   it: the token's fact ids (in `match_trap_ids`) and the candidate's. */
struct ds_rete_match_trap {
    const ds_rete_beta_node_t *node;
    ds_rete_held_t             held;
    uint32_t                   candidate;
    uint32_t                   ids_at;
    uint32_t                   ids_n;
    bool                       has_ordinal;
    uint32_t                   ordinal;
    uint32_t                   depth;
    uint32_t                   seq;
};
typedef struct ds_rete_match_trap ds_rete_match_trap_t;

/* Only a TypeError or a ComputationError waits for the event to end. An
   EngineError, which an untainted mismatch is, halts where it is raised
   ([LERR.1.4.12], [IRET.9.6]). */
static bool held_defers(const ds_rete_held_t *h)
{
    switch (h->cause) {
    case DS_FAULT_NULL_OPERAND:
    case DS_FAULT_DIVIDE_BY_ZERO:
    case DS_FAULT_DOMAIN:
    case DS_FAULT_NOT_REPRESENTABLE:
        return true;
    case DS_FAULT_TYPE_MISMATCH:
        return h->tainted;
    default:
        return false;
    }
}

/* [LDET.5.5]: a fact's entry rank is its id. */
static uint32_t fact_rank(const ds_rete_fact_t *f)
{
    return f ? f->id : 0u;
}

/* The terminal ordinal of the rule a node belongs to ([LDET.5.4]): the least
   over the terminals below it. False for a node no terminal is below. */
static bool node_ordinal(const ds_rete_beta_node_t *node, uint32_t *out)
{
    bool     any  = false;
    uint32_t best = 0;
    for (uint32_t i = 0; i < node->terminal_child_count; i++) {
        uint32_t o = node->terminal_children[i]->ordinal;
        if (!any || o < best) { best = o; any = true; }
    }
    for (uint32_t i = 0; i < node->beta_child_count; i++) {
        uint32_t o;
        if (node_ordinal(node->beta_children[i], &o) && (!any || o < best)) {
            best = o;
            any  = true;
        }
    }
    if (any) *out = best;
    return any;
}

static uint32_t node_depth(const ds_rete_beta_node_t *node)
{
    uint32_t d = 0;
    for (const ds_rete_beta_node_t *p = node->left_parent; p; p = p->left_parent)
        d++;
    return d;
}

/* False when nothing is holding, or the fault is not one that waits: the caller
   raises it now. A failed allocation raises its own fault ([LERR.1.4.7]) and the
   trap is lost. */
static bool hold_match_trap(struct ds_rete_engine     *engine,
                            const ds_rete_beta_node_t *node,
                            const ds_rete_token_t     *left,
                            const ds_rete_fact_t      *right,
                            const ds_rete_held_t      *held,
                            ds_rete_eval_ctx_t        *ctx)
{
    if (!engine->match_trap_hold || !held_defers(held)) return false;
    const uint32_t n = left ? left->fact_count : 0u;
    if (engine->match_trap_n == engine->match_trap_cap) {
        uint32_t nc = engine->match_trap_cap ? engine->match_trap_cap * 2u : 8u;
        ds_rete_match_trap_t *nt =
            DS_REALLOC(engine->match_traps, nc * sizeof(*nt));
        if (!nt) goto oom;
        engine->match_traps    = nt;
        engine->match_trap_cap = nc;
    }
    if (engine->match_trap_ids_cap - engine->match_trap_ids_n < n) {
        uint32_t nc = engine->match_trap_ids_cap ? engine->match_trap_ids_cap : 16u;
        while (nc - engine->match_trap_ids_n < n) nc *= 2u;
        uint32_t *ni = DS_REALLOC(engine->match_trap_ids, nc * sizeof(*ni));
        if (!ni) goto oom;
        engine->match_trap_ids     = ni;
        engine->match_trap_ids_cap = nc;
    }
    {
        ds_rete_match_trap_t *t = &engine->match_traps[engine->match_trap_n];
        t->node        = node;
        t->held        = *held;
        t->candidate   = fact_rank(right);
        t->ids_at      = engine->match_trap_ids_n;
        t->ids_n       = n;
        t->has_ordinal = node_ordinal(node, &t->ordinal);
        if (!t->has_ordinal) t->ordinal = 0;
        t->depth       = node_depth(node);
        t->seq         = engine->match_trap_n;
        for (uint32_t i = 0; i < n; i++)
            engine->match_trap_ids[engine->match_trap_ids_n++] =
                fact_rank(left->facts[i]);
        engine->match_trap_n++;
    }
    return true;
oom:
    (void)ds_rete_fault(ctx, NULL, DS_FAULT_RESOURCE);
    return true;
}

/* Rank `i` of a held pair: the token's facts, then the candidate. */
static uint32_t pair_rank(const struct ds_rete_engine *e,
                          const ds_rete_match_trap_t  *t, uint32_t i)
{
    return i < t->ids_n ? e->match_trap_ids[t->ids_at + i] : t->candidate;
}

/* [LERR.1.4.12]'s order: the terminal ordinal (a node no rule reaches first);
   the pair's facts as [LDET.5.5] ranks a match; the node's depth. Then the node
   id, and the order raised, so a pair held twice keeps its first. */
static int match_trap_cmp(const struct ds_rete_engine *e,
                          const ds_rete_match_trap_t  *a,
                          const ds_rete_match_trap_t  *b)
{
    if (a->has_ordinal != b->has_ordinal) return a->has_ordinal ? 1 : -1;
    if (a->ordinal != b->ordinal) return a->ordinal < b->ordinal ? -1 : 1;
    const uint32_t na = a->ids_n + 1u, nb = b->ids_n + 1u;
    uint32_t la = 0, lb = 0;
    for (uint32_t i = 0; i < na; i++) {
        uint32_t r = pair_rank(e, a, i);
        if (r > la) la = r;
    }
    for (uint32_t i = 0; i < nb; i++) {
        uint32_t r = pair_rank(e, b, i);
        if (r > lb) lb = r;
    }
    if (la != lb) return la < lb ? -1 : 1;
    const uint32_t n = na < nb ? na : nb;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t ra = pair_rank(e, a, i), rb = pair_rank(e, b, i);
        if (ra != rb) return ra < rb ? -1 : 1;
    }
    if (na != nb) return na < nb ? -1 : 1;
    if (a->depth != b->depth) return a->depth < b->depth ? -1 : 1;
    if (a->node->node_id != b->node->node_id)
        return a->node->node_id < b->node->node_id ? -1 : 1;
    if (a->seq != b->seq) return a->seq < b->seq ? -1 : 1;
    return 0;
}

static bool same_pair(const struct ds_rete_engine *e,
                      const ds_rete_match_trap_t  *a,
                      const ds_rete_match_trap_t  *b)
{
    if (a->node != b->node || a->ids_n != b->ids_n) return false;
    for (uint32_t i = 0; i <= a->ids_n; i++)
        if (pair_rank(e, a, i) != pair_rank(e, b, i)) return false;
    return true;
}

static ds_rete_token_t *lmem_find_ranks(const ds_rete_beta_node_t   *node,
                                        const struct ds_rete_engine *e,
                                        const ds_rete_match_trap_t  *t)
{
    for (ds_rete_token_t *k = node->left_head; k; k = k->next) {
        if (k->fact_count != t->ids_n) continue;
        uint32_t i = 0;
        while (i < t->ids_n && fact_rank(k->facts[i]) == pair_rank(e, t, i)) i++;
        if (i == t->ids_n) return k;
    }
    return NULL;
}

ds_rete_match_trap_mark_t ds_rete_beta_match_trap_mark(
    const struct ds_rete_engine *engine)
{
    ds_rete_match_trap_mark_t m = { engine->match_trap_n,
                                    engine->match_trap_ids_n };
    return m;
}

void ds_rete_beta_flush_match_traps(struct ds_rete_engine     *engine,
                                    ds_rete_match_trap_mark_t  mark)
{
    /* Before any trap is held `match_traps` is NULL, and `NULL + 0` is undefined
       (C11 6.5.6p8). */
    if (engine->match_trap_n == mark.n) {
        ds_rete_beta_discard_match_traps(engine, mark);
        return;
    }
    ds_rete_match_trap_t *v = engine->match_traps + mark.n;
    const uint32_t        n = engine->match_trap_n - mark.n;
    /* Insertion sort: stable and allocation-free. */
    for (uint32_t i = 1; i < n; i++) {
        ds_rete_match_trap_t x = v[i];
        uint32_t j = i;
        while (j > 0 && match_trap_cmp(engine, &x, &v[j - 1]) < 0) {
            v[j] = v[j - 1];
            j--;
        }
        v[j] = x;
    }
    int64_t now_ns = engine->cached_clock_ns;
    if (!engine->cached_clock_valid && engine->clock_fn)
        now_ns = engine->clock_fn(engine->clock_ctx);
    engine->match_trap_n     = mark.n;
    engine->match_trap_ids_n = mark.ids_n;
    for (uint32_t i = 0; i < n; i++) {
        /* [LERR.1.4.7] */
        if (engine->halted) break;
        const ds_rete_match_trap_t *t = &v[i];
        if (i > 0 && same_pair(engine, t, &v[i - 1])) continue;
        /* A pair the event evaluated and then ended records nothing. */
        ds_rete_fact_t **fp = (ds_rete_fact_t **)ds_oa_get(
            &t->node->right_alpha->memory.map, &t->candidate);
        if (!fp) continue;
        ds_rete_token_t *tok = lmem_find_ranks(t->node, engine, t);
        if (!tok) continue;
        ds_rete_eval_ctx_t ctx = {
            .token        = tok,
            .right_fact   = *fp,
            .engine       = engine,
            .fire_now_ns  = now_ns,
            .node_id      = t->node->node_id,
            .site_rule    = t->node->fault_rule,          /* [LERR.9.11] */
            .fault_handler_site = t->node->fault_handler, /* [LERR.9.6] */
        };
        (void)ds_rete_raise_held(&ctx, &t->held);
    }
}

void ds_rete_beta_discard_match_traps(struct ds_rete_engine     *engine,
                                      ds_rete_match_trap_mark_t  mark)
{
    engine->match_trap_n     = mark.n;
    engine->match_trap_ids_n = mark.ids_n;
}

void ds_rete_beta_free_match_traps(struct ds_rete_engine *engine)
{
    DS_FREE(engine->match_traps);
    DS_FREE(engine->match_trap_ids);
    engine->match_traps     = NULL;
    engine->match_trap_ids  = NULL;
    engine->match_trap_n    = engine->match_trap_cap     = 0;
    engine->match_trap_ids_n = engine->match_trap_ids_cap = 0;
}

/*
 * The tests of one join, combined as [LNUL.4.2]'s absorbing `and` ([IRET.7.6]):
 * a test answering `false` rejects the pair whatever another raises. Otherwise
 * the pair yields the one fault `ds_rete_held_select` ranks first
 * ([LERR.1.4.11]). So the tests may be evaluated in any order, and a decided EQ
 * test is a legal `+nolinscan` anchor ([IRET.7.5.1]).
 *
 * `*selected` is set when a held fault stands; `*faulted` is a fault that is not
 * a test's own, already recorded where it was raised.
 */
static void join_tests_eval(const ds_rete_join_test_t *tests,
                            uint32_t                   count,
                            ds_rete_eval_ctx_t        *proto,
                            bool                       negated,
                            bool                      *all_true,
                            bool                      *any_false,
                            ds_rete_held_t            *selected,
                            bool                      *faulted)
{
    *all_true = true;
    *any_false = false;
    *faulted = false;
    selected->held = false;
    for (uint32_t i = 0; i < count; i++) {
        if (!tests[i].expr) continue;
        ds_rete_eval_ctx_t ctx = *proto;
        ds_rete_held_t held;
        ds_rete_val_t v = ds_rete_eval_holding(&ctx, tests[i].expr, &held);
        if (ctx.faulted) {
            *faulted = true;
            *all_true = false;
            /* A negated join keeps looking for a `false` that unblocks
               ([LNUL.4.7]). */
            if (!negated) return;
            continue;
        }
        if (held.held) {
            ds_rete_held_select(selected, &held);
            *all_true = false;
            continue;
        }
        if (v.kind == DS_RETE_VAL_BOOL) {
            if (!v.b) { *any_false = true; *all_true = false; return; }
            continue;
        }
        if (v.kind == DS_RETE_VAL_NULL) { *all_true = false; continue; }
        if (negated) {
            /* A negated join keeps the block on a non-Bool value, as for null. */
            *all_true = false;
            continue;
        }
        /* The wrong kind in predicate position: held like any other fault. */
        {
            const ds_rete_held_t mismatch =
                ds_rete_held_mismatch(&ctx, tests[i].expr);
            ds_rete_held_select(selected, &mismatch);
        }
        *all_true = false;
    }
}

static bool join_tests_pass(const ds_rete_join_test_t *tests,
                             uint32_t                   count,
                             const ds_rete_token_t     *left,
                             const ds_rete_fact_t      *right,
                             struct ds_rete_engine     *engine,
                             const ds_rete_beta_node_t *node)
{
    /* One clock reading for all the tests of this invocation. */
    int64_t now_ns = engine->cached_clock_ns;
    if (!engine->cached_clock_valid && engine->clock_fn)
        now_ns = engine->clock_fn(engine->clock_ctx);

    ds_rete_eval_ctx_t proto = {
        .token        = (ds_rete_token_t *)left,
        .right_fact   = (ds_rete_fact_t  *)right,
        .bind_frame   = NULL,
        .bind_count   = 0,
        .engine       = engine,
        .fire_now_ns  = now_ns,
        .node_id      = node->node_id,
        .site_rule    = node->fault_rule,      /* [LERR.9.11] */
        .fault_handler_site = node->fault_handler,   /* [LERR.9.6] */
    };
    bool all_true, any_false, faulted;
    ds_rete_held_t selected;
    join_tests_eval(tests, count, &proto, false, &all_true, &any_false,
                    &selected, &faulted);
    if (!faulted && !any_false && selected.held) {
        ds_rete_eval_ctx_t ctx = proto;
        if (!hold_match_trap(engine, node, left, right, &selected, &ctx))
            (void)ds_rete_raise_held(&ctx, &selected);
    }
    return all_true;
}

/* [LNUL.4.7]: a right fact blocks the token iff no join test answers `false`:
 * true, null and an evaluation fault all keep the block. With no `false`, the
 * one fault [LNUL.4.2]'s order selects is recorded. */
static bool not_join_blocks(const ds_rete_join_test_t *tests,
                            uint32_t                   count,
                            const ds_rete_token_t     *left,
                            const ds_rete_fact_t      *right,
                            struct ds_rete_engine     *engine,
                            const ds_rete_beta_node_t *node)
{
    int64_t now_ns = engine->cached_clock_ns;
    if (!engine->cached_clock_valid && engine->clock_fn)
        now_ns = engine->clock_fn(engine->clock_ctx);

    ds_rete_eval_ctx_t proto = {
        .token        = (ds_rete_token_t *)left,
        .right_fact   = (ds_rete_fact_t  *)right,
        .bind_frame   = NULL,
        .bind_count   = 0,
        .engine       = engine,
        .fire_now_ns  = now_ns,
        .node_id      = node->node_id,
        .site_rule    = node->fault_rule,      /* [LERR.9.11] */
        .fault_handler_site = node->fault_handler,   /* [LERR.9.6] */
    };
    bool all_true, any_false, faulted;
    ds_rete_held_t selected;
    join_tests_eval(tests, count, &proto, true, &all_true, &any_false,
                    &selected, &faulted);
    if (any_false)
        return false;
    (void)faulted;
    if (selected.held) {
        ds_rete_eval_ctx_t ctx = proto;
        if (!hold_match_trap(engine, node, left, right, &selected, &ctx))
            (void)ds_rete_raise_held(&ctx, &selected);
    }
    return true;
}

static inline bool join_dispatch(const ds_rete_beta_node_t *node,
                                  const ds_rete_token_t     *left,
                                  const ds_rete_fact_t      *right,
                                  struct ds_rete_engine     *engine)
{
    if (node->is_negative)
        return not_join_blocks(node->join_tests, node->join_test_count,
                               left, right, engine, node);
    if (node->join_fn)
        return node->join_fn(left, right);
    return join_tests_pass(node->join_tests, node->join_test_count,
                           left, right, engine, node);
}

/* ---- Reverse join index ------------------------------------------- */
/*
 * fact_id -> oa_list<token*>: the left-memory tokens that joined with, or are
 * blocked by, that fact.
 */

#define RIDX_MAX_LOAD 70u

static uint64_t ridx_oa_hash(const void *key, void *ctx)
{
    (void)ctx;
    return *(const uint32_t *)key;
}

static bool ridx_oa_eq(const void *a, const void *b, void *ctx)
{
    (void)ctx;
    return *(const uint32_t *)a == *(const uint32_t *)b;
}

static oa_list *ridx_find(ds_rete_beta_node_t *node, uint32_t fact_id)
{
    return (oa_list *)ds_oa_get(&node->ridx_map, &fact_id);
}

/* Callers must propagate a failure: a counted-but-unindexed join is a stuck
 * activation. */
static ds_result_t ridx_add(ds_rete_beta_node_t *node, uint32_t fact_id,
                            ds_rete_token_t *t)
{
    void *vp;
    bool  is_new;
    ds_result_t r = ds_oa_put(&node->ridx_map, &fact_id, &vp, &is_new);
    if (r.status != DS_OK) return r;
    return ds_oa_list_add((oa_list *)vp, t, node->rt_locked);
}

static void ridx_remove_token(ds_rete_beta_node_t *node, uint32_t fact_id,
                               ds_rete_token_t *t)
{
    oa_list *l = ridx_find(node, fact_id);
    if (!l) return;
    if (ds_oa_list_remove(l, t) && ds_oa_list_len(l) == 0)
        ds_oa_del(&node->ridx_map, &fact_id);
}

static void ridx_drop_fact(ds_rete_beta_node_t *node, uint32_t fact_id)
{
    ds_oa_del(&node->ridx_map, &fact_id);
}

/* ---- Forward lmem join-key index ---------------------------------- */

/* Strings are interned, so they hash by pointer. */
static uint32_t lmem_idx_val_hash(const ds_rete_val_t *v)
{
    switch (v->kind) {
    case DS_RETE_VAL_INT:  {
        uint64_t u; memcpy(&u, &v->i, 8);
        return (uint32_t)(u ^ (u >> 32)) * 2654435761u;
    }
    case DS_RETE_VAL_FLOAT: {
        /* -0.0 == +0.0 in lmem_idx_val_eq, so they hash alike. */
        double   f = (v->f == 0.0) ? 0.0 : v->f;
        uint64_t u; memcpy(&u, &f, 8);
        return (uint32_t)(u ^ (u >> 32)) * 2654435761u;
    }
    case DS_RETE_VAL_STR:
        return (uint32_t)((uintptr_t)v->s.ptr >> 3) * 2654435761u;
    case DS_RETE_VAL_BOOL:
        return v->b ? 0x6b8b4567u : 0x327b23c6u;
    case DS_RETE_VAL_FACT_REF:
        /* The target's id, so the bucket does not move when it leaves WM. */
        return v->fact_ref_id * 2654435761u;
    case DS_RETE_VAL_TIME: {
        /* LTIM.5.2: the instant. */
        uint64_t u; memcpy(&u, &v->time.utc_ns, 8);
        return (uint32_t)(u ^ (u >> 32)) * 2654435761u;
    }
    case DS_RETE_VAL_BYTES: {
        /* By content, agreeing with lmem_idx_val_eq. */
        uint32_t h = 0x811c9dc5u;
        const unsigned char *p = (const unsigned char *)v->s.ptr;
        for (uint32_t i = 0; p != NULL && i < v->s.len; i++)
            h = (h ^ p[i]) * 0x01000193u;
        return h * 2654435761u;
    }
    default:
        return 0u;
    }
}

/* Exact value equality for the lmem_idx key: strings by interned pointer, Bytes
 * by content, since nothing obliges a Bytes value to arrive interned
 * ([LFAC.2.5.4]). A `Json` key is never decided, so never reaches the index. */
static bool lmem_idx_val_eq(const ds_rete_val_t *a, const ds_rete_val_t *b)
{
    if (a->kind != b->kind) return false;
    switch (a->kind) {
    case DS_RETE_VAL_INT:      return a->i        == b->i;
    case DS_RETE_VAL_FLOAT:    return a->f        == b->f;
    case DS_RETE_VAL_STR:      return a->s.ptr    == b->s.ptr;
    case DS_RETE_VAL_BYTES:
        if (a->s.len != b->s.len) return false;
        if (a->s.len == 0 || a->s.ptr == b->s.ptr) return true;
        if (a->s.ptr == NULL || b->s.ptr == NULL) return false;
        return memcmp(a->s.ptr, b->s.ptr, a->s.len) == 0;
    case DS_RETE_VAL_BOOL:     return a->b        == b->b;
    case DS_RETE_VAL_FACT_REF: return a->fact_ref_id == b->fact_ref_id;
    case DS_RETE_VAL_TIME:     return a->time.utc_ns == b->time.utc_ns;
    default:                   return false;
    }
}

#define LMEM_IDX_MAX_LOAD 70u

/* Shared with ralpha_idx. */
static uint64_t lmem_idx_oa_hash(const void *key, void *ctx)
{
    (void)ctx;
    return lmem_idx_val_hash((const ds_rete_val_t *)key);
}
static bool lmem_idx_oa_eq(const void *a, const void *b, void *ctx)
{
    (void)ctx;
    return lmem_idx_val_eq((const ds_rete_val_t *)a, (const ds_rete_val_t *)b);
}

static oa_list *lmem_idx_find(ds_rete_beta_node_t *node, const ds_rete_val_t *key)
{
    return (oa_list *)ds_oa_get(&node->lmem_idx_map, key);
}

/* false on OOM or RT-locked list growth. The table itself grows even in RT; only
 * the per-key list heap is gated. */
static bool lmem_idx_add(ds_rete_beta_node_t *node, const ds_rete_val_t *key,
                          ds_rete_token_t *token)
{
    void *vp;
    bool  is_new;
    if (ds_oa_put(&node->lmem_idx_map, key, &vp, &is_new).status != DS_OK)
        return false;
    return ds_oa_list_add((oa_list *)vp, token, node->rt_locked).status == DS_OK;
}

static void lmem_idx_remove_token(ds_rete_beta_node_t *node,
                                   const ds_rete_val_t *key,
                                   ds_rete_token_t     *token)
{
    oa_list *l = lmem_idx_find(node, key);
    if (!l) return;
    if (ds_oa_list_remove(l, token) && ds_oa_list_len(l) == 0)
        ds_oa_del(&node->lmem_idx_map, key);
}

/* ---- Right-alpha join-key index ----------------------------------- */

#define RALPHA_IDX_MAX_LOAD 70u

static oa_list *ralpha_idx_find(ds_rete_beta_node_t *node, const ds_rete_val_t *key)
{
    return (oa_list *)ds_oa_get(&node->ralpha_idx_map, key);
}

/* false on OOM or RT-locked growth. Unlike lmem_idx, table growth is gated too. */
static bool ralpha_idx_add(ds_rete_beta_node_t *node, const ds_rete_val_t *key,
                            ds_rete_fact_t *fact)
{
    void *vp;
    bool  is_new;
    node->ralpha_idx_map.locked = node->rt_locked;
    if (ds_oa_put(&node->ralpha_idx_map, key, &vp, &is_new).status != DS_OK)
        return false;
    return ds_oa_list_add((oa_list *)vp, fact, node->rt_locked).status == DS_OK;
}

static void ralpha_idx_remove_fact(ds_rete_beta_node_t *node,
                                    const ds_rete_val_t *key,
                                    ds_rete_fact_t      *fact)
{
    oa_list *l = ralpha_idx_find(node, key);
    if (!l) return;
    if (ds_oa_list_remove(l, fact) && ds_oa_list_len(l) == 0)
        ds_oa_del(&node->ralpha_idx_map, key);
}

/* ---- Left-token join index ---------------------------------------- */
/*
 * The inverse of ridx: stored token* (by pointer identity) -> oa_list<fact*>,
 * for retracting a token without re-running join tests.
 */

#define LTOK_MAX_LOAD 70u

static uint64_t ltok_oa_hash(const void *key, void *ctx)
{
    (void)ctx;
    return (uint64_t)(uintptr_t)*(ds_rete_token_t *const *)key;
}
static bool ltok_oa_eq(const void *a, const void *b, void *ctx)
{
    (void)ctx;
    return *(ds_rete_token_t *const *)a == *(ds_rete_token_t *const *)b;
}

static oa_list *ltok_find(ds_rete_beta_node_t *node, ds_rete_token_t *token)
{
    return (oa_list *)ds_oa_get(&node->ltok_idx_map, &token);
}

static ds_result_t ltok_add(ds_rete_beta_node_t *node, ds_rete_token_t *token,
                            ds_rete_fact_t *fact)
{
    void *vp;
    bool  is_new;
    ds_result_t r = ds_oa_put(&node->ltok_idx_map, &token, &vp, &is_new);
    if (r.status != DS_OK) return r;
    r = ds_oa_list_add((oa_list *)vp, fact, node->rt_locked);
    /* On a NOT node an ltok entry is the block, so an empty new entry must not
       outlive a failed add. */
    if (r.status != DS_OK && is_new) ds_oa_del(&node->ltok_idx_map, &token);
    return r;
}

/* Record a (token, fact) join in both reverse indexes, or neither. Callers do
 * this before counting a block or propagating an extension: one without its
 * index entry is a stuck or leaked activation. */
static ds_result_t record_join(ds_rete_beta_node_t *node, uint32_t fact_id,
                               ds_rete_token_t *token, ds_rete_fact_t *fact)
{
    ds_result_t r = ridx_add(node, fact_id, token);
    if (r.status != DS_OK) return r;
    r = ltok_add(node, token, fact);
    if (r.status != DS_OK) ridx_remove_token(node, fact_id, token);
    return r;
}

static void ltok_remove_fact(ds_rete_beta_node_t *node, ds_rete_token_t *token,
                              ds_rete_fact_t *fact)
{
    oa_list *l = ltok_find(node, token);
    if (!l) return;
    if (ds_oa_list_remove(l, fact) && ds_oa_list_len(l) == 0)
        ds_oa_del(&node->ltok_idx_map, &token);
}

static void ltok_drop_token(ds_rete_beta_node_t *node, ds_rete_token_t *token)
{
    ds_oa_del(&node->ltok_idx_map, &token);
}

/* (fact_idx, left_slot, right_slot) of a join test of the form
   EQ(VAR(left,i,j), VAR(right,k)). The whole-fact marker names no slot
   (LEXP.7.20's `a == b` on two bindings): such a join is scanned. */
static bool extract_eq_join_key(const ds_rete_expr_t *expr,
                                 uint8_t *fi, uint8_t *ls, uint8_t *rs)
{
    if (!expr || expr->kind != DS_RETE_EXPR_BINOP) return false;
    if (expr->binop.op != DS_RETE_BINOP_EQ)       return false;
    const ds_rete_expr_t *L = expr->binop.left;
    const ds_rete_expr_t *R = expr->binop.right;
    if (!L || !R) return false;
    if (L->kind != DS_RETE_EXPR_VAR || R->kind != DS_RETE_EXPR_VAR) return false;
    if (L->var.slot_index == DS_RETE_VAR_WHOLE_FACT
        || R->var.slot_index == DS_RETE_VAR_WHOLE_FACT)
        return false;

    if (R->var.pattern_index == DS_RETE_VAR_RIGHT_FACT &&
        L->var.pattern_index != DS_RETE_VAR_RIGHT_FACT) {
        *fi = L->var.pattern_index;
        *ls = L->var.slot_index;
        *rs = R->var.slot_index;
        return true;
    }
    if (L->var.pattern_index == DS_RETE_VAR_RIGHT_FACT &&
        R->var.pattern_index != DS_RETE_VAR_RIGHT_FACT) {
        *fi = R->var.pattern_index;
        *ls = R->var.slot_index;
        *rs = L->var.slot_index;
        return true;
    }
    return false;
}

/* ---- May the EQ key be probed? ([IRET.7.5.1], RLOW.5.5) ------------ */

/* A key slot is decided when its declared type can make `==` neither raise nor
   `null`: not nullable ([LNUL.3.1]) and not `Json`. */
static bool key_slot_decided(const ds_rete_schema_t *s, uint8_t slot)
{
    if (!s || slot >= s->slot_count) return false;
    const ds_rete_slot_desc_t *d = &s->slots[slot];
    return !d->nullable && d->type != DS_RETE_VAL_JSON;
}

/*
 * Only a decided conjunct may leave the join test ([IRET.7.5.1]): probing skips
 * every pair whose keys differ, which is sound only if the EQ would have
 * answered a plain `false` for them. A nullable or `Json` key may answer `null`
 * or raise, and the probe would lose that fault.
 *
 * Decided once per node from the declared schemas, not per value: the probe and
 * the scan visit matches in different orders, and the visit order feeds
 * `next_timetag++`, so switching mid-run would change firing order. The left
 * schema is in hand only once a token exists, and until then the scan over an
 * empty memory answers what the probe would. `any_token` may be NULL.
 */
static bool eq_key_decided(ds_rete_beta_node_t   *node,
                           const ds_rete_token_t *any_token,
                           struct ds_rete_engine *engine)
{
    if (node->eq_key_decided != 0) return node->eq_key_decided > 0;
    if (!any_token || any_token->fact_count <= node->lmem_idx_fact_idx)
        return false;
    const ds_rete_fact_t *lf = any_token->facts[node->lmem_idx_fact_idx];
    if (!lf || !lf->schema) return false;
    const ds_rete_schema_t *rs =
        ds_rete_schema_by_id(engine, node->right_alpha->schema_id);
    const bool ok = key_slot_decided(lf->schema, node->lmem_idx_left_slot)
                 && key_slot_decided(rs, node->lmem_idx_right_slot);
    node->eq_key_decided = ok ? 1 : -1;
    return ok;
}

/* On a NOT node, "blocked" is "has an ltok entry": its facts are the blockers,
 * and ltok_remove_fact drops the entry when it empties. */
static bool block_is_blocked(ds_rete_beta_node_t *node, ds_rete_token_t *token)
{
    return ltok_find(node, token) != NULL;
}

static ds_result_t propagate_left_activate(ds_rete_beta_node_t  *node,
                                             ds_rete_token_t      *token,
                                             struct ds_rete_engine *engine);
static ds_result_t propagate_left_retract(ds_rete_beta_node_t  *node,
                                            ds_rete_token_t      *token,
                                            struct ds_rete_engine *engine);

static ds_result_t
do_left_activate_children(ds_rete_beta_node_t  *node,
                           ds_rete_token_t      *extended,
                           struct ds_rete_engine *engine)
{
    for (uint32_t c = 0; c < node->beta_child_count; c++) {
        ds_result_t r = propagate_left_activate(node->beta_children[c],
                                                 extended, engine);
        if (r.status != DS_OK) return r;
    }
    for (uint32_t c = 0; c < node->terminal_child_count; c++) {
        ds_result_t r = ds_rete_terminal_left_activate(
            node->terminal_children[c], extended, engine);
        if (r.status != DS_OK) return r;
    }
    return DS_OK_R;
}

/* ---- Completion order ([LDET.5.5]) ------------------------------- */

/* A match completes at the last positive join of its chain: negated nodes do not
   extend a token, so the timetag this node's token carries orders the activation
   ([LDET.5.9]). */
static bool has_positive_descendant(const ds_rete_beta_node_t *node)
{
    for (uint32_t c = 0; c < node->beta_child_count; c++) {
        const ds_rete_beta_node_t *child = node->beta_children[c];
        if (!child->is_negative || has_positive_descendant(child))
            return true;
    }
    return false;
}

static bool beta_completes(ds_rete_beta_node_t *node)
{
    if (node->completes == 0)
        node->completes = (!node->is_negative && !has_positive_descendant(node))
                          ? 1 : -1;
    return node->completes > 0;
}

/* Outside an event (the nil seeding at load) nothing is held. */
static bool holds_completion(ds_rete_beta_node_t *node,
                             const struct ds_rete_engine *engine)
{
    return engine->event_depth > 0 && beta_completes(node);
}

/* A held extension's timetag is minted at the end of the event. */
static int64_t extension_timetag(ds_rete_beta_node_t *node,
                                 struct ds_rete_engine *engine)
{
    return holds_completion(node, engine) ? 0 : engine->next_timetag++;
}

/* Takes ownership of `ext`. The held list is unordered; the flush sorts it. */
static ds_result_t forward_extension(ds_rete_beta_node_t  *node,
                                     ds_rete_token_t      *ext,
                                     struct ds_rete_engine *engine)
{
    if (holds_completion(node, engine)) {
        bool first = node->pending_head == NULL;
        ext->next = node->pending_head;
        node->pending_head = ext;
        if (first) {
            /* Ascending by node_id, so the flush's order is the artefact's. */
            ds_rete_beta_node_t **p = &engine->completion_nodes;
            while (*p && (*p)->node_id < node->node_id) p = &(*p)->pending_next;
            node->pending_next = *p;
            *p = node;
        }
        return DS_OK_R;
    }
    ds_result_t r = do_left_activate_children(node, ext, engine);
    ds_rete_token_free(ext);
    return r;
}

/* [LDET.5.5]'s key, as `formal/idris/Rete/Network.idr`'s `ldet_5_5__before`
   states it: the latest entry rank among the match's facts, then the ranks
   pattern by pattern. `fact->id` is the rank; a meaningful reassertion mints a
   new one ([IDAT.4.4]). A negated position ranks as 0. */
static uint32_t latest_rank(const ds_rete_token_t *t)
{
    uint32_t m = 0;
    for (uint32_t i = 0; i < t->fact_count; i++)
        if (t->facts[i] && t->facts[i]->id > m) m = t->facts[i]->id;
    return m;
}

static int completion_key_cmp(const ds_rete_token_t *a, const ds_rete_token_t *b)
{
    uint32_t la = latest_rank(a), lb = latest_rank(b);
    if (la != lb) return la < lb ? -1 : 1;
    uint32_t n = a->fact_count < b->fact_count ? a->fact_count : b->fact_count;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t ra = a->facts[i] ? a->facts[i]->id : 0u;
        uint32_t rb = b->facts[i] ? b->facts[i]->id : 0u;
        if (ra != rb) return ra < rb ? -1 : 1;
    }
    if (a->fact_count != b->fact_count)
        return a->fact_count < b->fact_count ? -1 : 1;
    return 0;
}

/* Merge sort on the intrusive list: stable and allocation-free. */
static ds_rete_token_t *completion_sort(ds_rete_token_t *head)
{
    if (!head || !head->next) return head;
    ds_rete_token_t *slow = head, *fast = head->next;
    while (fast && fast->next) { slow = slow->next; fast = fast->next->next; }
    ds_rete_token_t *right = slow->next;
    slow->next = NULL;
    ds_rete_token_t *a = completion_sort(head);
    ds_rete_token_t *b = completion_sort(right);
    ds_rete_token_t  out = { 0 };
    ds_rete_token_t *tail = &out;
    while (a && b) {
        if (completion_key_cmp(b, a) < 0) { tail->next = b; b = b->next; }
        else                              { tail->next = a; a = a->next; }
        tail = tail->next;
    }
    tail->next = a ? a : b;
    return out.next;
}

ds_result_t ds_rete_beta_flush_completions(struct ds_rete_engine *engine)
{
    ds_result_t first = DS_OK_R;
    while (engine->completion_nodes) {
        ds_rete_beta_node_t *node = engine->completion_nodes;
        engine->completion_nodes = node->pending_next;
        node->pending_next = NULL;
        ds_rete_token_t *t = completion_sort(node->pending_head);
        node->pending_head = NULL;
        while (t) {
            ds_rete_token_t *next = t->next;
            t->next = NULL;
            /* [LERR.1.4.7]: once halted the rest are freed unpropagated. */
            if (first.status == DS_OK && !engine->halted) {
                t->creation_timetag = engine->next_timetag++;
                ds_result_t r = do_left_activate_children(node, t, engine);
                if (r.status != DS_OK) first = r;
            }
            ds_rete_token_free(t);
            t = next;
        }
    }
    return first;
}

void ds_rete_beta_discard_completions(struct ds_rete_engine *engine)
{
    while (engine->completion_nodes) {
        ds_rete_beta_node_t *node = engine->completion_nodes;
        engine->completion_nodes = node->pending_next;
        node->pending_next = NULL;
        ds_rete_token_t *t = node->pending_head;
        node->pending_head = NULL;
        while (t) {
            ds_rete_token_t *next = t->next;
            ds_rete_token_free(t);
            t = next;
        }
    }
}

static ds_result_t
do_left_retract_children(ds_rete_beta_node_t  *node,
                          ds_rete_token_t      *extended,
                          struct ds_rete_engine *engine)
{
    for (uint32_t c = 0; c < node->beta_child_count; c++) {
        ds_result_t r = propagate_left_retract(node->beta_children[c],
                                                extended, engine);
        if (r.status != DS_OK) return r;
    }
    for (uint32_t c = 0; c < node->terminal_child_count; c++) {
        ds_result_t r = ds_rete_terminal_left_retract(
            node->terminal_children[c], extended, engine);
        if (r.status != DS_OK) return r;
    }
    return DS_OK_R;
}

#define LMEM_MAP_MAX_LOAD  70u

static uint64_t lmem_map_oa_hash(const void *key, void *ctx)
{
    (void)ctx;
    return (*(ds_rete_token_t *const *)key)->hash;
}
static bool lmem_map_oa_eq(const void *a, const void *b, void *ctx)
{
    (void)ctx;
    return ds_rete_tokens_equal(*(ds_rete_token_t *const *)a,
                                *(ds_rete_token_t *const *)b);
}

static ds_result_t lmem_map_insert(ds_rete_beta_node_t *node, ds_rete_token_t *stored)
{
    void *vp;
    bool  is_new;
    ds_result_t r = ds_oa_put(&node->lmem_map, &stored, &vp, &is_new);
    if (r.status != DS_OK) return r;
    *(ds_rete_token_t **)vp = stored;
    return DS_OK_R;
}

/* Unlinks and returns the stored token content-equal to `token`, or NULL. The
 * list scan drains a content-equal duplicate the oa map collapsed. */
static ds_rete_token_t *lmem_map_extract(ds_rete_beta_node_t *node,
                                         ds_rete_token_t     *token)
{
    ds_rete_token_t **vp = (ds_rete_token_t **)ds_oa_get(&node->lmem_map, &token);
    ds_rete_token_t  *e  = vp ? *vp : NULL;
    if (e) {
        ds_oa_del(&node->lmem_map, &token);
    } else {
        for (ds_rete_token_t *t = node->left_head; t; t = t->next)
            if (ds_rete_tokens_equal(t, token)) { e = t; break; }
        if (!e) return NULL;
    }
    if (e->prev) e->prev->next = e->next;
    else         node->left_head = e->next;
    if (e->next) e->next->prev = e->prev;
    node->left_count--;
    return e;
}

static ds_result_t lmem_add(ds_rete_beta_node_t *node, ds_rete_token_t *token)
{
    if (node->contract_capacity > 0 &&
        node->left_count >= node->contract_capacity)
        return DS_ERR_R(DS_ERR_CONTRACT_BREACH,
                        "beta: contract per-node token capacity exceeded");
    token->next = node->left_head;
    token->prev = NULL;
    if (node->left_head) node->left_head->prev = token;
    node->left_head = token;
    node->left_count++;
    /* On a failed insert the token leaves the list again: both callers free it
       on any error. */
    ds_result_t r = lmem_map_insert(node, token);
    if (r.status != DS_OK) {
        node->left_head = token->next;
        if (token->next) token->next->prev = NULL;
        token->next = NULL;
        node->left_count--;
        return r;
    }
    if (node->lmem_idx_enabled && token->fact_count > node->lmem_idx_fact_idx) {
        ds_rete_fact_t *kf = token->facts[node->lmem_idx_fact_idx];
        if (kf && node->lmem_idx_left_slot < kf->schema->slot_count) {
            const ds_rete_val_t *key = &kf->slots[node->lmem_idx_left_slot];
            lmem_idx_add(node, key, token);
        }
    }
    return DS_OK_R;
}

/* Returns the stored copy of `token` (the parent's original), which the caller
   uses for ltok/ridx cleanup and frees. NULL if not found. */
static ds_rete_token_t *lmem_extract(ds_rete_beta_node_t *node,
                                      ds_rete_token_t     *token)
{
    ds_rete_token_t *e = lmem_map_extract(node, token);
    if (!e) return NULL;
    if (node->lmem_idx_enabled && e->fact_count > node->lmem_idx_fact_idx) {
        ds_rete_fact_t *kf = e->facts[node->lmem_idx_fact_idx];
        if (kf && node->lmem_idx_left_slot < kf->schema->slot_count)
            lmem_idx_remove_token(node, &kf->slots[node->lmem_idx_left_slot], e);
    }
    return e;
}

ds_result_t ds_rete_beta_node_create(ds_rete_beta_node_t  *left_parent,
                                      ds_rete_alpha_node_t *right_alpha,
                                      ds_rete_join_test_t  *join_tests,
                                      uint32_t              join_test_count,
                                      bool                  is_negative,
                                      ds_rete_beta_node_t **out)
{
    if (!out || !right_alpha)
        return DS_ERR_R(DS_ERR_INVAL, "beta_node_create: NULL arg");

    ds_rete_beta_node_t *n = DS_CALLOC(1, sizeof(*n));
    if (!n) return DS_ERR_R(DS_ERR_OOM, "beta_node alloc");

    if (join_test_count > 0) {
        n->join_tests = DS_CALLOC(join_test_count, sizeof(*n->join_tests));
        if (!n->join_tests) { DS_FREE(n); return DS_ERR_R(DS_ERR_OOM, "join tests"); }
        memcpy(n->join_tests, join_tests,
               join_test_count * sizeof(*join_tests));
    }

    n->left_parent      = left_parent;
    n->right_alpha      = right_alpha;
    n->join_test_count  = join_test_count;
    n->is_negative      = is_negative;

    ds_oa_init(&n->ridx_map, sizeof(uint32_t), sizeof(oa_list), RIDX_MAX_LOAD,
            ridx_oa_hash, ridx_oa_eq, ds_oa_list_free, NULL);

    ds_oa_init(&n->lmem_idx_map, sizeof(ds_rete_val_t), sizeof(oa_list),
            LMEM_IDX_MAX_LOAD, lmem_idx_oa_hash, lmem_idx_oa_eq, ds_oa_list_free, NULL);
    ds_oa_init(&n->ralpha_idx_map, sizeof(ds_rete_val_t), sizeof(oa_list),
            RALPHA_IDX_MAX_LOAD, lmem_idx_oa_hash, lmem_idx_oa_eq, ds_oa_list_free, NULL);

    ds_oa_init(&n->ltok_idx_map, sizeof(ds_rete_token_t *), sizeof(oa_list),
            LTOK_MAX_LOAD, ltok_oa_hash, ltok_oa_eq, ds_oa_list_free, NULL);

    ds_oa_init(&n->lmem_map, sizeof(ds_rete_token_t *), sizeof(ds_rete_token_t *),
            LMEM_MAP_MAX_LOAD, lmem_map_oa_hash, lmem_map_oa_eq, NULL, NULL);

    /* The EQ join key, on positive joins only. */
    n->lmem_idx_enabled = false;
    if (!is_negative) {
        for (uint32_t i = 0; i < join_test_count; i++) {
            uint8_t fi, ls, rs;
            if (n->join_tests[i].expr &&
                extract_eq_join_key(n->join_tests[i].expr, &fi, &ls, &rs)) {
                n->lmem_idx_enabled    = true;
                n->lmem_idx_fact_idx   = fi;
                n->lmem_idx_left_slot  = ls;
                n->lmem_idx_right_slot = rs;
                break;
            }
        }
    }

    n->ralpha_idx_enabled    = n->lmem_idx_enabled;
    n->ralpha_idx_right_slot = n->lmem_idx_right_slot;
    n->ralpha_idx_left_fact  = n->lmem_idx_fact_idx;
    n->ralpha_idx_left_slot  = n->lmem_idx_left_slot;

    *out = n;
    return DS_OK_R;
}

void ds_rete_beta_node_destroy(ds_rete_beta_node_t *node)
{
    if (!node) return;
    ds_rete_token_t *t = node->left_head;
    while (t) {
        ds_rete_token_t *next = t->next;
        ds_rete_token_free(t);
        t = next;
    }
    if (node->join_tests) {
        for (uint32_t i = 0; i < node->join_test_count; i++)
            ds_rete_expr_free_tree(node->join_tests[i].expr);
        DS_FREE(node->join_tests);
    }
    ds_oa_free(&node->lmem_map);
    ds_oa_free(&node->ridx_map);
    ds_oa_free(&node->lmem_idx_map);
    ds_oa_free(&node->ralpha_idx_map);
    ds_oa_free(&node->ltok_idx_map);
    DS_FREE(node->beta_children);     /* ptrs only */
    DS_FREE(node->terminal_children); /* ptrs only */
    DS_FREE(node);
}

ds_result_t ds_rete_beta_add_child(ds_rete_beta_node_t *node,
                                    ds_rete_beta_node_t *child)
{
    if (!node || !child)
        return DS_ERR_R(DS_ERR_INVAL, "beta_add_child: NULL arg");
    /* A node has one left input: a second edge would leave the first parent
       propagating into a child whose left_retract walks back to the second. */
    if (child->left_parent != NULL && child->left_parent != node)
        return DS_ERR_R(DS_ERR_INVAL,
                        "beta_add_child: child already has another left parent");
    if (node->beta_child_count >= node->beta_child_cap) {
        uint32_t nc = node->beta_child_cap ? node->beta_child_cap * 2 : 4u;
        ds_rete_beta_node_t **nb =
            DS_REALLOC(node->beta_children, nc * sizeof(*nb));
        if (!nb) return DS_ERR_R(DS_ERR_OOM, "beta children grow");
        node->beta_children    = nb;
        node->beta_child_cap   = nc;
    }
    node->beta_children[node->beta_child_count++] = child;
    child->left_parent = node;
    return DS_OK_R;
}

ds_result_t ds_rete_beta_add_terminal(ds_rete_beta_node_t     *node,
                                       struct ds_rete_terminal *terminal)
{
    if (!node || !terminal)
        return DS_ERR_R(DS_ERR_INVAL, "beta_add_terminal: NULL arg");
    if (node->terminal_child_count >= node->terminal_child_cap) {
        uint32_t nc = node->terminal_child_cap ? node->terminal_child_cap * 2 : 4u;
        struct ds_rete_terminal **nb =
            DS_REALLOC(node->terminal_children, nc * sizeof(*nb));
        if (!nb) return DS_ERR_R(DS_ERR_OOM, "terminal children grow");
        node->terminal_children   = nb;
        node->terminal_child_cap  = nc;
    }
    node->terminal_children[node->terminal_child_count++] = terminal;
    return DS_OK_R;
}

static ds_result_t propagate_left_activate(ds_rete_beta_node_t  *node,
                                             ds_rete_token_t      *token,
                                             struct ds_rete_engine *engine)
{
    return ds_rete_beta_left_activate(node, token, engine);
}

static ds_result_t propagate_left_retract(ds_rete_beta_node_t  *node,
                                            ds_rete_token_t      *token,
                                            struct ds_rete_engine *engine)
{
    return ds_rete_beta_left_retract(node, token, engine);
}

/* ---- NOT node helpers --------------------------------------------- */
/*
 * The NOT node's left memory is the sole owner of its tokens: a copy goes
 * downstream. Block entries key on in-list pointers, so not_left_retract extracts
 * the list pointer before removal.
 */

static ds_result_t not_right_activate(ds_rete_beta_node_t  *node,
                                       ds_rete_fact_t       *fact,
                                       struct ds_rete_engine *engine)
{
    /* A new right fact has no ridx entry yet: that index is populated from the
       joins, so the left memory is scanned. */
    ds_rete_token_t *t = node->left_head;
    while (t) {
        ds_rete_token_t *next = t->next;
        if (join_dispatch(node, t, fact, engine)) {
            /* Read before record_join adds this fact to ltok[t]. */
            bool was_blocked = block_is_blocked(node, t);
            ds_result_t r = record_join(node, fact->id, t, fact);
            if (r.status != DS_OK) return r;
            if (!was_blocked) {
                ds_rete_token_t *copy =
                    ds_rete_token_copy(t, engine->next_timetag++, (engine->pools_ready ? &engine->token_pool : NULL), (engine->pools_ready ? &engine->token_budget : NULL), &r);
                if (!copy) return r;
                r = do_left_retract_children(node, copy, engine);
                ds_rete_token_free(copy);
                if (r.status != DS_OK) return r;
            }
        }
        t = next;
    }
    return DS_OK_R;
}

static ds_result_t not_right_retract(ds_rete_beta_node_t  *node,
                                      ds_rete_fact_t       *fact,
                                      struct ds_rete_engine *engine)
{
    if (node->ridx_map.cap != 0) {
        oa_list *l = ridx_find(node, fact->id);
        if (!l) return DS_OK_R;
        uint32_t n = ds_oa_list_len(l);
        /* First, or the ltok lists keep a pointer to `fact` once it is freed. */
        for (uint32_t i = 0; i < n; i++)
            ltok_remove_fact(node, (ds_rete_token_t *)ds_oa_list_at(l, i), fact);
        for (uint32_t i = 0; i < n; i++) {
            ds_rete_token_t *t = (ds_rete_token_t *)ds_oa_list_at(l, i);
            if (!block_is_blocked(node, t)) {
                ds_result_t r;
                /* [LDET.5.9]: unblocking does not mint a timetag. */
                ds_rete_token_t *copy =
                    ds_rete_token_copy(t, t->creation_timetag, (engine->pools_ready ? &engine->token_pool : NULL), (engine->pools_ready ? &engine->token_budget : NULL), &r);
                if (!copy) { ridx_drop_fact(node, fact->id); return r; }
                r = do_left_activate_children(node, copy, engine);
                ds_rete_token_free(copy);
                if (r.status != DS_OK) { ridx_drop_fact(node, fact->id); return r; }
            }
        }
        ridx_drop_fact(node, fact->id);
        return DS_OK_R;
    }

    /* ridx never allocated: no join was recorded, so no token is blocked. */
    return DS_OK_R;
}

static ds_result_t not_left_activate(ds_rete_beta_node_t  *node,
                                      ds_rete_token_t      *token,
                                      struct ds_rete_engine *engine)
{
    ds_result_t rc;
    ds_rete_token_t *stored = ds_rete_token_copy(token, token->creation_timetag, (engine->pools_ready ? &engine->token_pool : NULL), (engine->pools_ready ? &engine->token_budget : NULL), &rc);
    if (!stored) return rc;
    rc = lmem_add(node, stored);
    if (rc.status != DS_OK) { ds_rete_token_free(stored); return rc; }

    uint32_t cnt = 0;
    {
        const ds_rete_alpha_mem_t *bmem = &node->right_alpha->memory;
        ds_rete_fact_t **bocc = (ds_rete_fact_t **)bmem->map.dvals;
        uint32_t bn = bmem->map.len;
        for (uint32_t j = 0; j < bn; j++) {
            ds_rete_fact_t *f = bocc[j];
            if (join_dispatch(node, stored, f, engine)) {
                ds_result_t jr = record_join(node, f->id, stored, f);
                if (jr.status != DS_OK) return jr;
                cnt++;
            }
        }
    }
    if (cnt > 0) return DS_OK_R;
    ds_result_t r;
    ds_rete_token_t *copy = ds_rete_token_copy(stored, engine->next_timetag++, (engine->pools_ready ? &engine->token_pool : NULL), (engine->pools_ready ? &engine->token_budget : NULL), &r);
    if (!copy) return r;
    r = do_left_activate_children(node, copy, engine);
    ds_rete_token_free(copy);
    return r;
}

static ds_result_t not_left_retract(ds_rete_beta_node_t  *node,
                                     ds_rete_token_t      *token,
                                     struct ds_rete_engine *engine)
{
    ds_rete_token_t *found = lmem_map_extract(node, token);
    if (!found) return DS_OK_R;

    /* Read before the cleanup below drops ltok[found]. */
    bool was_blocked = block_is_blocked(node, found);

    {
        oa_list *le = ltok_find(node, found);
        if (le) {
            uint32_t ln = ds_oa_list_len(le);
            for (uint32_t j = 0; j < ln; j++) {
                ds_rete_fact_t *f = (ds_rete_fact_t *)ds_oa_list_at(le, j);
                ridx_remove_token(node, f->id, found);
            }
            ltok_drop_token(node, found);
        }
    }

    if (!was_blocked) {
        ds_result_t r;
        ds_rete_token_t *tmp = ds_rete_token_copy(found, 0, (engine->pools_ready ? &engine->token_pool : NULL), (engine->pools_ready ? &engine->token_budget : NULL), &r);
        if (!tmp) { ds_rete_token_free(found); return r; }
        r = do_left_retract_children(node, tmp, engine);
        ds_rete_token_free(tmp);
        ds_rete_token_free(found);
        return r;
    }
    ds_rete_token_free(found);
    return DS_OK_R;
}

/* ---- Normal (positive) join paths --------------------------------- */

/*
 * left_activate receives a borrowed token and stores its own copy; an extended
 * token is freed by its creator after propagation.
 */

ds_result_t ds_rete_beta_right_activate(ds_rete_beta_node_t  *node,
                                         ds_rete_fact_t       *fact,
                                         struct ds_rete_engine *engine)
{
    if (!node || !fact) return DS_ERR_R(DS_ERR_INVAL, "right_activate: NULL");
    /* [LERR.1.4.7]: nothing propagates past an EngineError. Checked at the entry
       of each of the four node-to-node steps, before it has touched anything. */
    if (engine && engine->halted) return DS_OK_R;

    if (node->is_negative)
        return not_right_activate(node, fact, engine);

    if (node->ralpha_idx_enabled &&
        node->ralpha_idx_right_slot < fact->schema->slot_count) {
        ralpha_idx_add(node, &fact->slots[node->ralpha_idx_right_slot], fact);
    }

    if (node->lmem_idx_enabled &&
        node->lmem_idx_right_slot < fact->schema->slot_count &&
        eq_key_decided(node, node->left_head, engine)) {
        const ds_rete_val_t *rkey = &fact->slots[node->lmem_idx_right_slot];
        oa_list *ie = lmem_idx_find(node, rkey);
        if (ie) {
            uint32_t n = ds_oa_list_len(ie);
            for (uint32_t j = 0; j < n; j++) {
                ds_rete_token_t *t = (ds_rete_token_t *)ds_oa_list_at(ie, j);
                if (!join_dispatch(node, t, fact, engine)) continue;
                { ds_result_t jr = record_join(node, fact->id, t, fact);
                  if (jr.status != DS_OK) return jr; }
                ds_result_t r;
                ds_rete_token_t *ext =
                    ds_rete_token_create(t, fact, extension_timetag(node, engine),
                                         (engine->pools_ready ? &engine->token_pool : NULL),
                                         (engine->pools_ready ? &engine->token_budget : NULL), &r);
                if (!ext) return r;
                r = forward_extension(node, ext, engine);
                if (r.status != DS_OK) return r;
            }
        }
        return DS_OK_R;
    }

    ds_rete_token_t *t = node->left_head;
    while (t) {
        ds_rete_token_t *next = t->next;
        if (join_dispatch(node, t, fact, engine)) {
            ds_result_t r = record_join(node, fact->id, t, fact);
            if (r.status != DS_OK) return r;
            ds_rete_token_t *ext =
                ds_rete_token_create(t, fact, extension_timetag(node, engine), (engine->pools_ready ? &engine->token_pool : NULL), (engine->pools_ready ? &engine->token_budget : NULL), &r);
            if (!ext) return r;
            r = forward_extension(node, ext, engine);
            if (r.status != DS_OK) return r;
        }
        t = next;
    }
    return DS_OK_R;
}

ds_result_t ds_rete_beta_left_activate(ds_rete_beta_node_t  *node,
                                        ds_rete_token_t      *token,
                                        struct ds_rete_engine *engine)
{
    if (!node || !token) return DS_ERR_R(DS_ERR_INVAL, "left_activate: NULL");
    if (engine && engine->halted) return DS_OK_R;   /* [LERR.1.4.7] */

    if (node->is_negative)
        return not_left_activate(node, token, engine);

    ds_result_t rc;
    ds_rete_token_t *stored = ds_rete_token_copy(token, token->creation_timetag, (engine->pools_ready ? &engine->token_pool : NULL), (engine->pools_ready ? &engine->token_budget : NULL), &rc);
    if (!stored) return rc;
    rc = lmem_add(node, stored);
    if (rc.status != DS_OK) { ds_rete_token_free(stored); return rc; }

    if (node->ralpha_idx_enabled &&
        stored->fact_count > node->ralpha_idx_left_fact &&
        eq_key_decided(node, stored, engine)) {
        ds_rete_fact_t *kf = stored->facts[node->ralpha_idx_left_fact];
        if (kf && node->ralpha_idx_left_slot < kf->schema->slot_count) {
            const ds_rete_val_t *lkey = &kf->slots[node->ralpha_idx_left_slot];
            oa_list *ie = ralpha_idx_find(node, lkey);
            if (ie) {
                uint32_t rn = ds_oa_list_len(ie);
                for (uint32_t j = 0; j < rn; j++) {
                    ds_rete_fact_t *f = (ds_rete_fact_t *)ds_oa_list_at(ie, j);
                    if (!join_dispatch(node, token, f, engine)) continue;
                    { ds_result_t jr = record_join(node, f->id, stored, f);
                      if (jr.status != DS_OK) return jr; }
                    ds_rete_token_t *ext =
                        ds_rete_token_create(token, f, extension_timetag(node, engine),
                                              (engine->pools_ready ? &engine->token_pool : NULL),
                                              (engine->pools_ready ? &engine->token_budget : NULL), &rc);
                    if (!ext) return rc;
                    ds_result_t r = forward_extension(node, ext, engine);
                    if (r.status != DS_OK) return r;
                }
            }
            return DS_OK_R;
        }
    }

    const ds_rete_alpha_mem_t *amem = &node->right_alpha->memory;
    ds_rete_fact_t **aocc = (ds_rete_fact_t **)amem->map.dvals;
    uint32_t an = amem->map.len;
    for (uint32_t j = 0; j < an; j++) {
        ds_rete_fact_t *f = aocc[j];
        if (!join_dispatch(node, token, f, engine))
            continue;
        { ds_result_t jr = record_join(node, f->id, stored, f);
          if (jr.status != DS_OK) return jr; }
        ds_rete_token_t *ext =
            ds_rete_token_create(token, f, extension_timetag(node, engine), (engine->pools_ready ? &engine->token_pool : NULL), (engine->pools_ready ? &engine->token_budget : NULL), &rc);
        if (!ext) return rc;
        ds_result_t r = forward_extension(node, ext, engine);
        if (r.status != DS_OK) return r;
    }
    return DS_OK_R;
}

ds_result_t ds_rete_beta_right_retract(ds_rete_beta_node_t  *node,
                                        ds_rete_fact_t       *fact,
                                        struct ds_rete_engine *engine)
{
    if (!node || !fact) return DS_ERR_R(DS_ERR_INVAL, "right_retract: NULL");
    /* [LERR.1.4.7]. A retract cut here leaves this node's tokens pointing at
       `fact`, so ds_rete_wm_retract keeps the fact in working memory when the
       engine has halted, and ds_engine_free releases both. */
    if (engine && engine->halted) return DS_OK_R;

    if (node->is_negative)
        return not_right_retract(node, fact, engine);

    if (node->ralpha_idx_enabled &&
        node->ralpha_idx_right_slot < fact->schema->slot_count)
        ralpha_idx_remove_fact(node, &fact->slots[node->ralpha_idx_right_slot], fact);

    if (node->ridx_map.cap != 0) {
        oa_list *l = ridx_find(node, fact->id);
        if (l) {
            uint32_t n = ds_oa_list_len(l);
            /* First, so an OOM below cannot leave an ltok pointing at `fact`. */
            for (uint32_t i = 0; i < n; i++)
                ltok_remove_fact(node, (ds_rete_token_t *)ds_oa_list_at(l, i), fact);
            for (uint32_t i = 0; i < n; i++) {
                ds_rete_token_t *t = (ds_rete_token_t *)ds_oa_list_at(l, i);
                ds_result_t r;
                ds_rete_token_t *ext =
                    ds_rete_token_create(t, fact, 0, (engine->pools_ready ? &engine->token_pool : NULL), (engine->pools_ready ? &engine->token_budget : NULL), &r);
                if (!ext) { ridx_drop_fact(node, fact->id); return r; }
                r = do_left_retract_children(node, ext, engine);
                ds_rete_token_free(ext);
                if (r.status != DS_OK) { ridx_drop_fact(node, fact->id); return r; }
            }
            ridx_drop_fact(node, fact->id);
        }
        return DS_OK_R;
    }

    /* ridx never allocated: no join was recorded, so nothing is downstream. A
       retraction evaluates no join test ([IRET.7.7], [LERR.1.4.12]). */
    return DS_OK_R;
}

ds_result_t ds_rete_beta_left_retract(ds_rete_beta_node_t  *node,
                                       ds_rete_token_t      *token,
                                       struct ds_rete_engine *engine)
{
    if (!node || !token) return DS_ERR_R(DS_ERR_INVAL, "left_retract: NULL");
    /* [LERR.1.4.7]. The stored copy stays in this node's memory, which
       ds_engine_free releases. */
    if (engine && engine->halted) return DS_OK_R;

    if (node->is_negative)
        return not_left_retract(node, token, engine);

    ds_rete_token_t *stored_lmem = lmem_extract(node, token);
    if (!stored_lmem) return DS_OK_R;

    {
        oa_list *le = ltok_find(node, stored_lmem);
        if (le) {
            uint32_t n = ds_oa_list_len(le);
            /* First, so an OOM below cannot free the token with a ridx list
               still pointing at it. */
            for (uint32_t j = 0; j < n; j++)
                ridx_remove_token(node,
                    ((ds_rete_fact_t *)ds_oa_list_at(le, j))->id, stored_lmem);
            for (uint32_t j = 0; j < n; j++) {
                ds_rete_fact_t *f = (ds_rete_fact_t *)ds_oa_list_at(le, j);
                ds_result_t r;
                ds_rete_token_t *ext =
                    ds_rete_token_create(token, f, 0,
                                          (engine->pools_ready ? &engine->token_pool : NULL),
                                          (engine->pools_ready ? &engine->token_budget : NULL), &r);
                if (!ext) { ltok_drop_token(node, stored_lmem); ds_rete_token_free(stored_lmem); return r; }
                r = do_left_retract_children(node, ext, engine);
                ds_rete_token_free(ext);
                if (r.status != DS_OK) { ltok_drop_token(node, stored_lmem); ds_rete_token_free(stored_lmem); return r; }
            }
            ltok_drop_token(node, stored_lmem);
        }
    }
    ds_rete_token_free(stored_lmem);
    return DS_OK_R;
}

ds_result_t ds_rete_beta_presz_ridx(ds_rete_beta_node_t *node, uint32_t cap)
{
    if (!node) return DS_ERR_R(DS_ERR_INVAL, "presz_ridx: NULL node");
    return ds_oa_reserve(&node->ridx_map, cap);
}

ds_result_t ds_rete_beta_presz_ralpha(ds_rete_beta_node_t *node, uint32_t cap)
{
    if (!node || !node->ralpha_idx_enabled) return DS_OK_R;
    return ds_oa_reserve(&node->ralpha_idx_map, cap);
}

ds_result_t ds_rete_beta_presz_lmem_idx(ds_rete_beta_node_t *node, uint32_t cap)
{
    if (!node || !node->lmem_idx_enabled) return DS_OK_R;
    return ds_oa_reserve(&node->lmem_idx_map, cap);
}

ds_result_t ds_rete_beta_presz_ltok(ds_rete_beta_node_t *node, uint32_t cap)
{
    if (!node) return DS_ERR_R(DS_ERR_INVAL, "presz_ltok: NULL node");
    return ds_oa_reserve(&node->ltok_idx_map, cap);
}

#ifdef DS_DEBUG
/* Asserted at pump quiescence in a DS_DEBUG build, so an index and a counter
 * that drift apart fail at their source node. */
void ds_rete_beta_check(const ds_rete_beta_node_t *node)
{
    if (!node) return;

    uint32_t list_len = 0;
    for (const ds_rete_token_t *t = node->left_head; t; t = t->next) list_len++;
    assert(list_len == node->left_count);
    /* lmem_map collapses content-equal tokens the list keeps both of. */
    assert(oa_len(&node->lmem_map) <= node->left_count);

    /* ridx and ltok are mutual inverses. */
    for (uint32_t i = 0; i < oa_len(&node->ridx_map); i++) {
        uint32_t fid = *(const uint32_t *)ds_oa_key_at(&node->ridx_map, i);
        const oa_list *toks = (const oa_list *)ds_oa_val_at(&node->ridx_map, i);
        for (uint32_t j = 0; j < ds_oa_list_len(toks); j++) {
            ds_rete_token_t *t = (ds_rete_token_t *)ds_oa_list_at(toks, j);
            const oa_list *facts = (const oa_list *)ds_oa_get(&node->ltok_idx_map, &t);
            bool inverse = false;
            for (uint32_t k = 0; facts && k < ds_oa_list_len(facts); k++)
                if (((ds_rete_fact_t *)ds_oa_list_at(facts, k))->id == fid) {
                    inverse = true; break;
                }
            assert(inverse); /* ridx entry with no matching ltok entry */
        }
    }
    for (uint32_t i = 0; i < oa_len(&node->ltok_idx_map); i++) {
        ds_rete_token_t *t =
            *(ds_rete_token_t *const *)ds_oa_key_at(&node->ltok_idx_map, i);
        const oa_list *facts = (const oa_list *)ds_oa_val_at(&node->ltok_idx_map, i);
        for (uint32_t j = 0; j < ds_oa_list_len(facts); j++) {
            ds_rete_fact_t *f = (ds_rete_fact_t *)ds_oa_list_at(facts, j);
            const oa_list *toks = (const oa_list *)ds_oa_get(&node->ridx_map, &f->id);
            bool inverse = false;
            for (uint32_t k = 0; toks && k < ds_oa_list_len(toks); k++)
                if ((ds_rete_token_t *)ds_oa_list_at(toks, k) == t) {
                    inverse = true; break;
                }
            assert(inverse); /* ltok entry with no matching ridx entry */
        }
    }

    /* "Blocked" is "has an entry", so an empty one would block for nothing. */
    for (uint32_t i = 0; i < oa_len(&node->ltok_idx_map); i++) {
        const oa_list *facts = (const oa_list *)ds_oa_val_at(&node->ltok_idx_map, i);
        assert(ds_oa_list_len(facts) > 0);
    }
}
#endif /* DS_DEBUG */

/* ---- Beta node deep-copy --------------------------------------------- */

static uint64_t btokptr_hash(const void *k, void *c)
{ (void) c; return (uint64_t) (uintptr_t) *(void *const *) k; }
static bool btokptr_eq(const void *a, const void *b, void *c)
{ (void) c; return *(void *const *) a == *(void *const *) b; }

typedef struct {
    ds_rete_clone_ctx_t *cx;
    oa_t                *tokmap;   /* src token* -> clone token* */
} beta_cc_t;

static ds_rete_token_t *bcc_tok(beta_cc_t *b, const ds_rete_token_t *st)
{
    if (!st) return NULL;
    void *v = ds_oa_get(b->tokmap, &st);
    return v ? *(ds_rete_token_t **) v : NULL;
}

/* key or value = token* */
static void b_remap_tok(const void *sv, void *dv, void *ctx)
{
    beta_cc_t *b = (beta_cc_t *) ctx;
    *(ds_rete_token_t **) dv = bcc_tok(b, *(ds_rete_token_t *const *) sv);
}
/* key = ds_rete_val_t (STR/BYTES re-interned; FACT_REF is an id, kept) */
static void b_remap_val(const void *sv, void *dv, void *ctx)
{
    beta_cc_t *b = (beta_cc_t *) ctx;
    const ds_rete_val_t *s = (const ds_rete_val_t *) sv;
    *(ds_rete_val_t *) dv = ds_rete_clone_val(b->cx, s);
}
/* value = oa_list<token*> (zero-init dst list; rebuild with remapped elems) */
static void b_remap_list_tok(const void *sv, void *dv, void *ctx)
{
    beta_cc_t *b = (beta_cc_t *) ctx;
    const oa_list *sl = (const oa_list *) sv;
    oa_list       *dl = (oa_list *) dv;
    for (uint32_t i = 0; i < ds_oa_list_len(sl); i++) {
        ds_rete_token_t *ct = bcc_tok(b, (ds_rete_token_t *) ds_oa_list_at(sl, i));
        if (ds_oa_list_add(dl, ct, false).status != DS_OK) { b->cx->oom = true; return; }
    }
}
/* value = oa_list<fact*> */
static void b_remap_list_fact(const void *sv, void *dv, void *ctx)
{
    beta_cc_t *b = (beta_cc_t *) ctx;
    const oa_list *sl = (const oa_list *) sv;
    oa_list       *dl = (oa_list *) dv;
    for (uint32_t i = 0; i < ds_oa_list_len(sl); i++) {
        ds_rete_fact_t *sf = (ds_rete_fact_t *) ds_oa_list_at(sl, i);
        ds_rete_fact_t *cf = sf ? ds_rete_clone_fact_lookup(b->cx, sf->id) : NULL;
        if (ds_oa_list_add(dl, cf, false).status != DS_OK) { b->cx->oom = true; return; }
    }
}

ds_result_t ds_rete_beta_node_clone(ds_rete_clone_ctx_t       *cx,
                                    const ds_rete_beta_node_t *src,
                                    ds_rete_beta_node_t      **out)
{
    ds_rete_beta_node_t *n = DS_CALLOC(1, sizeof(*n));
    if (!n) return DS_ERR_R(DS_ERR_OOM, "beta_clone: node alloc");

    /* Wiring is filled by the orchestration node-map pass. */
    n->is_negative           = src->is_negative;
    n->node_id               = src->node_id;
    memcpy(n->fault_rule, src->fault_rule, sizeof n->fault_rule);
    n->fault_handler         = src->fault_handler;
    n->contract_capacity     = src->contract_capacity;
    n->join_fn               = src->join_fn;
    n->rt_locked             = src->rt_locked;
    n->join_test_count       = src->join_test_count;
    n->left_count            = src->left_count;
    n->lmem_idx_enabled      = src->lmem_idx_enabled;
    n->lmem_idx_fact_idx     = src->lmem_idx_fact_idx;
    n->lmem_idx_left_slot    = src->lmem_idx_left_slot;
    n->lmem_idx_right_slot   = src->lmem_idx_right_slot;
    n->ralpha_idx_enabled    = src->ralpha_idx_enabled;
    n->ralpha_idx_right_slot = src->ralpha_idx_right_slot;
    n->ralpha_idx_left_fact  = src->ralpha_idx_left_fact;
    n->ralpha_idx_left_slot  = src->ralpha_idx_left_slot;

    if (src->join_test_count > 0) {
        n->join_tests = DS_CALLOC(src->join_test_count, sizeof(*n->join_tests));
        if (!n->join_tests) { DS_FREE(n); return DS_ERR_R(DS_ERR_OOM, "beta_clone: join_tests"); }
        for (uint32_t i = 0; i < src->join_test_count; i++)
            n->join_tests[i].expr = ds_rete_clone_expr(cx, src->join_tests[i].expr);
    }

    ds_oa_init(&n->ridx_map, sizeof(uint32_t), sizeof(oa_list), RIDX_MAX_LOAD,
            ridx_oa_hash, ridx_oa_eq, ds_oa_list_free, NULL);
    ds_oa_init(&n->lmem_idx_map, sizeof(ds_rete_val_t), sizeof(oa_list),
            LMEM_IDX_MAX_LOAD, lmem_idx_oa_hash, lmem_idx_oa_eq, ds_oa_list_free, NULL);
    ds_oa_init(&n->ralpha_idx_map, sizeof(ds_rete_val_t), sizeof(oa_list),
            RALPHA_IDX_MAX_LOAD, lmem_idx_oa_hash, lmem_idx_oa_eq, ds_oa_list_free, NULL);
    ds_oa_init(&n->ltok_idx_map, sizeof(ds_rete_token_t *), sizeof(oa_list),
            LTOK_MAX_LOAD, ltok_oa_hash, ltok_oa_eq, ds_oa_list_free, NULL);
    ds_oa_init(&n->lmem_map, sizeof(ds_rete_token_t *), sizeof(ds_rete_token_t *),
            LMEM_MAP_MAX_LOAD, lmem_map_oa_hash, lmem_map_oa_eq, NULL, NULL);

    oa_t tokmap;
    ds_oa_init(&tokmap, sizeof(ds_rete_token_t *), sizeof(ds_rete_token_t *), 70,
            btokptr_hash, btokptr_eq, NULL, NULL);
    beta_cc_t b = { cx, &tokmap };

    ds_result_t r = DS_OK_R;
    ds_rete_token_t *prev = NULL;
    for (const ds_rete_token_t *st = src->left_head; st; st = st->next) {
        ds_rete_token_t *ct = ds_rete_token_clone(cx, st);
        if (!ct) { r = DS_ERR_R(DS_ERR_OOM, "beta_clone: token"); goto fail; }
        ct->prev = prev;
        ct->next = NULL;
        if (prev) prev->next = ct; else n->left_head = ct;
        prev = ct;
        void *vp;
        r = ds_oa_put(&tokmap, &st, &vp, NULL);
        if (r.status != DS_OK) { ds_rete_token_free(ct); goto fail; }
        *(ds_rete_token_t **) vp = ct;
    }

    if ((r = ds_oa_clone_into(&n->lmem_map,   &src->lmem_map,   b_remap_tok, b_remap_tok,       &b)).status != DS_OK) goto fail;
    if ((r = ds_oa_clone_into(&n->ridx_map,   &src->ridx_map,   NULL,        b_remap_list_tok,  &b)).status != DS_OK) goto fail;
    if ((r = ds_oa_clone_into(&n->lmem_idx_map,   &src->lmem_idx_map,   b_remap_val, b_remap_list_tok,  &b)).status != DS_OK) goto fail;
    if ((r = ds_oa_clone_into(&n->ralpha_idx_map, &src->ralpha_idx_map, b_remap_val, b_remap_list_fact, &b)).status != DS_OK) goto fail;
    if ((r = ds_oa_clone_into(&n->ltok_idx_map,   &src->ltok_idx_map,   b_remap_tok, b_remap_list_fact, &b)).status != DS_OK) goto fail;
    if (cx->oom) { r = DS_ERR_R(DS_ERR_OOM, "beta_clone: index remap"); goto fail; }

    ds_oa_free(&tokmap);
    *out = n;
    return DS_OK_R;

fail:
    ds_oa_free(&tokmap);
    ds_rete_beta_node_destroy(n);
    return r;
}
