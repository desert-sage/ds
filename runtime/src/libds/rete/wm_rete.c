/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/wm_rete.c — working memory operations (IRET.19).
 */
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "ds_alloc.h"
#include "internal/json.h"

#include "rete/clone.h"
#include "rete/dispatch.h"
#include "rete/engine.h"
#include "rete/fact.h"
#include "rete/pool.h"
#include "rete/schema.h"
#include "rete/terminal.h"
#include "rete/val.h"
#include "rete/wm_rete.h"
#include "telemetry.h"

/* Defined beside the ds_engine struct body, which these need; each is a no-op
   with no DS engine bound. */

/* [LSER.8.5.1]: the outgoing fact's sample survives into the end-of-pump absorb.
   Absorbing at the supersede would break [LSER.8.6.1]'s fire-then-sample. */
void ds_engine_queue_superseded_sample(struct ds_rete_engine *re,
                                        struct ds_rete_fact   *outgoing);

/* [LSER.13.14]: DS_ERR_CONTRACT_BREACH, with its BoundsError, for a sample that
   would put a step backing's identity past its `capacity`. */
ds_result_t ds_engine_series_capacity_check(struct ds_rete_engine  *re,
                                            const ds_rete_schema_t *sc,
                                            const ds_rete_val_t    *slots);

/* RFCS.6a.4: a superseded fact whose successor will not be wrapped. `old_key`
   is freed: only a table key. */
void ds_engine_finish_supersede(struct ds_rete_engine *re,
                                struct ds_rete_fact   *old_key,
                                uint32_t               old_id);

/* ---- WM hash table helpers ---------------------------------------- */

#define WM_MAX_LOAD 70u

static uint32_t hash_id(uint32_t id)
{
    id ^= id >> 16;
    id *= 0x45d9f3b;
    id ^= id >> 16;
    return id;
}

/* ---- The WM map: fact->id -> fact* --------------------------------- */

/* oa mixes the raw id; the hash moves only the probe, never iteration order
   ([IRET.28.10.3]). */
static uint64_t wm_id_oa_hash(const void *key, void *ctx)
{
    (void)ctx;
    return (uint64_t)*(const uint32_t *)key;
}

static bool wm_id_oa_eq(const void *a, const void *b, void *ctx)
{
    (void)ctx;
    return *(const uint32_t *)a == *(const uint32_t *)b;
}

void ds_rete_wm_map_init(ds_rete_engine_t *e)
{
    ds_oa_init(&e->wm_map, sizeof(uint32_t), sizeof(ds_rete_fact_t *),
            WM_MAX_LOAD, wm_id_oa_hash, wm_id_oa_eq, NULL, NULL);
}

/* ---- Json and Bytes compare by content ----------------------------- */

/* One value kind held two ways: a borrow points into another fact's tree. */
static bool val_is_json(ds_rete_val_kind_t k)
{
    return k == DS_RETE_VAL_JSON || k == DS_RETE_VAL_JSON_BORROW;
}

/* [LFAC.2.5.4]: nothing obliges a Bytes value to be interned. */
static bool bytes_equal(const ds_rete_val_t *a, const ds_rete_val_t *b)
{
    if (a->s.len != b->s.len) return false;
    if (a->s.len == 0 || a->s.ptr == b->s.ptr) return true;
    if (a->s.ptr == NULL || b->s.ptr == NULL) return false;
    return memcmp(a->s.ptr, b->s.ptr, a->s.len) == 0;
}

static uint32_t bytes_hash(const ds_rete_val_t *v)
{
    uint32_t h = 0x811c9dc5u;                    /* FNV-1a */
    const unsigned char *p = (const unsigned char *)v->s.ptr;
    for (uint32_t i = 0; p != NULL && i < v->s.len; i++)
        h = (h ^ p[i]) * 0x01000193u;
    return hash_id(h);
}

/* ---- Identity-key hash --------------------------------------------- */

/* Agrees with idkey_equal. */
static uint32_t hash_idval(const ds_rete_val_t *v)
{
    switch (v->kind) {
    case DS_RETE_VAL_BYTES:
        return bytes_hash(v);
    case DS_RETE_VAL_JSON:
    case DS_RETE_VAL_JSON_BORROW:
        return hash_id(ds_json_deep_hash(v->json));
    case DS_RETE_VAL_INT:
        return hash_id((uint32_t)(v->i ^ (v->i >> 32)));
    case DS_RETE_VAL_FLOAT: {
        /* [LFAC.2]: -0.0 == +0.0, so they hash alike. */
        double   f = (v->f == 0.0) ? 0.0 : v->f;
        uint64_t bits;
        memcpy(&bits, &f, sizeof(bits));
        return hash_id((uint32_t)(bits ^ (bits >> 32)));
    }
    case DS_RETE_VAL_STR:
        /* interned */
        return hash_id((uint32_t)((uintptr_t)v->s.ptr >> 3));
    case DS_RETE_VAL_BOOL:
        return v->b ? 0x6b8b4567u : 0x327b23c6u;
    case DS_RETE_VAL_FACT_REF:
        return hash_id(v->fact_ref_id);
    case DS_RETE_VAL_TIME:
        /* LTIM.5.2: the instant, not the offset. */
        return hash_id((uint32_t)(v->time.utc_ns ^ (v->time.utc_ns >> 32)));
    case DS_RETE_VAL_NULL:
        /* [LNUL.8.8] */
        return hash_id((uint32_t)(DS_NULL_HASH64 ^ (DS_NULL_HASH64 >> 32)));
    default:
        return 0u;
    }
}

/* The key tuple (LFAC.1.7). A key=∅ schema hashes every fact alike. */
static uint32_t hash_idkey(const ds_rete_schema_t *s,
                           const ds_rete_val_t    *slots)
{
    uint32_t h = 0x811c9dc5u;
    for (uint16_t k = 0; k < s->id_key_count; k++) {
        h = (h ^ hash_idval(&slots[s->id_key_slots[k]])) * 0x01000193u;
    }
    return h;
}

/* [LTIM.1.1.3]: a `Time` slot's value is its instant, as INT (stored, or from
   the host) or TIME (from an expression). True, with both instants, when both
   are; equal iff the instants are (LTIM.5.2). */
static bool time_slot_instants(const ds_rete_val_t *a, const ds_rete_val_t *b,
                               int64_t *ai, int64_t *bi)
{
    if (a->kind == DS_RETE_VAL_INT)       *ai = a->i;
    else if (a->kind == DS_RETE_VAL_TIME) *ai = a->time.utc_ns;
    else return false;
    if (b->kind == DS_RETE_VAL_INT)       *bi = b->i;
    else if (b->kind == DS_RETE_VAL_TIME) *bi = b->time.utc_ns;
    else return false;
    return true;
}

/* key=∅ is always equal. */
static bool idkey_equal(const ds_rete_schema_t *s,
                        const ds_rete_val_t    *a,
                        const ds_rete_val_t    *b)
{
    for (uint16_t k = 0; k < s->id_key_count; k++) {
        uint16_t i = s->id_key_slots[k];
        int64_t at, bt;
        if (s->slots[i].time && time_slot_instants(&a[i], &b[i], &at, &bt)) {
            if (at != bt) return false;
            continue;
        }
        /* [LFAC.2.5.1], [LFAC.2.5.4]: as the no-op test compares. */
        if (val_is_json(a[i].kind) && val_is_json(b[i].kind)) {
            if (!ds_json_deep_equal(a[i].json, b[i].json)) return false;
            continue;
        }
        if (a[i].kind != b[i].kind) return false;
        switch (a[i].kind) {
        case DS_RETE_VAL_BYTES:    if (!bytes_equal(&a[i], &b[i])) return false; break;
        case DS_RETE_VAL_INT:      if (a[i].i != b[i].i) return false; break;
        case DS_RETE_VAL_FLOAT:    if (a[i].f != b[i].f) return false; break;
        case DS_RETE_VAL_STR:      if (a[i].s.ptr != b[i].s.ptr) return false; break;
        case DS_RETE_VAL_BOOL:     if (a[i].b != b[i].b) return false; break;
        case DS_RETE_VAL_FACT_REF: if (a[i].fact_ref_id != b[i].fact_ref_id) return false; break;
        case DS_RETE_VAL_TIME:     if (a[i].time.utc_ns != b[i].time.utc_ns) return false; break;
        case DS_RETE_VAL_NULL:     break;
        default: return false;
        }
    }
    return true;
}

/* ---- Per-schema identity map: slot array* -> fact*; ctx the schema -- */

static uint64_t id_oa_hash(const void *key, void *ctx)
{
    const ds_rete_schema_t *s = (const ds_rete_schema_t *)ctx;
    return hash_idkey(s, *(const ds_rete_val_t *const *)key);
}

static bool id_oa_eq(const void *a, const void *b, void *ctx)
{
    const ds_rete_schema_t *s = (const ds_rete_schema_t *)ctx;
    return idkey_equal(s, *(const ds_rete_val_t *const *)a,
                          *(const ds_rete_val_t *const *)b);
}

void ds_rete_schema_id_map_init(ds_rete_schema_t *s)
{
    ds_oa_init(&s->id_map, sizeof(ds_rete_val_t *), sizeof(ds_rete_fact_t *),
            WM_MAX_LOAD, id_oa_hash, id_oa_eq, NULL, s);
}

static ds_result_t id_hash_insert(ds_rete_schema_t *s, ds_rete_fact_t *f)
{
    if (!s->id_dedup) return DS_OK_R;
    void *vp;
    bool  is_new;
    /* The key is a pointer to f->slots, a flexible array member. Any
       same-identity fact was retracted first, so the key is fresh. */
    const ds_rete_val_t *slots = f->slots;
    ds_result_t r = ds_oa_put(&s->id_map, &slots, &vp, &is_new);
    if (r.status != DS_OK) return r;
    *(ds_rete_fact_t **)vp = f;
    return DS_OK_R;
}

static void id_hash_remove(ds_rete_schema_t *s, ds_rete_fact_t *f)
{
    if (!s->id_dedup) return;
    /* Only the entry that is f. */
    const ds_rete_val_t *slots = f->slots;
    ds_rete_fact_t **vp = (ds_rete_fact_t **)ds_oa_get(&s->id_map, &slots);
    if (vp && *vp == f) ds_oa_del(&s->id_map, &slots);
}

/* Not in the deadline heap. */
#define DL_NONE UINT32_MAX

static ds_result_t dlheap_insert(ds_rete_engine_t *e, ds_rete_fact_t *f);
static void        dlheap_remove(ds_rete_engine_t *e, ds_rete_fact_t *f);
static void        wm_remove(ds_rete_engine_t *e, ds_rete_fact_t *f);

/* ---- The TimeZoneOffset index ([LTIM.10.7]) ------------------------- */

/* An oa map of zones, each an AVL tree of its live `TimeZoneOffset` facts
   ([LTIM.10.6]) by `valid_from`: O(log r) to resolve and to remove ([LNLS.4.7]
   puts removal outside its O(1) bound).

   Keyed by the designation's bytes, since [LTIM.10.6] compares byte for byte and
   an evaluated zone need not be interned. The key's pointer is the interned
   string every fact of the zone holds; wm_remove runs before a fact's strings
   are released, so it is valid while the zone has a fact.

   Kept in wm_insert and wm_remove, so every path that moves working memory keeps
   it. A removal deletes only a node naming its own fact, so an upsert's order
   cannot drop the live one. */

typedef struct ds_rete_tz_node {
    int64_t                  from;   /* valid_from: the key */
    const ds_rete_fact_t    *fact;   /* the live fact with that key */
    struct ds_rete_tz_node  *l, *r;
    int                      h;      /* AVL height */
} tz_node_t;

typedef struct {
    const char *ptr;
    uint32_t    len;
} tz_zone_key_t;

struct ds_rete_tz_index {
    oa_t zones;   /* tz_zone_key_t -> tz_node_t * (a tree's root) */
};

/* A Time slot holds its instant as TIME or, declared at runtime, as INT. */
static int64_t tz_slot_ns(const ds_rete_val_t *v)
{
    return v->kind == DS_RETE_VAL_TIME ? v->time.utc_ns : v->i;
}

static uint64_t tz_zone_hash(const void *key, void *ctx)
{
    (void)ctx;
    const tz_zone_key_t *k = key;
    uint64_t h = 1469598103934665603ULL;               /* FNV-1a */
    for (uint32_t i = 0; i < k->len; i++) {
        h ^= (uint8_t)k->ptr[i];
        h *= 1099511628211ULL;
    }
    return h;
}

static bool tz_zone_eq(const void *a, const void *b, void *ctx)
{
    (void)ctx;
    const tz_zone_key_t *x = a, *y = b;
    return x->len == y->len
        && (x->len == 0 || memcmp(x->ptr, y->ptr, x->len) == 0);
}

static void tz_tree_free(tz_node_t *n)
{
    if (n == NULL) return;
    tz_tree_free(n->l);
    tz_tree_free(n->r);
    DS_FREE(n);
}

static void tz_zone_dtor(void *val, void *ctx)
{
    (void)ctx;
    tz_tree_free(*(tz_node_t **)val);
}

static int tz_h(const tz_node_t *n) { return n ? n->h : 0; }

static void tz_fix(tz_node_t *n)
{
    int a = tz_h(n->l), b = tz_h(n->r);
    n->h = 1 + (a > b ? a : b);
}

static tz_node_t *tz_rot_r(tz_node_t *y)
{
    tz_node_t *x = y->l;
    y->l = x->r;
    x->r = y;
    tz_fix(y);
    tz_fix(x);
    return x;
}

static tz_node_t *tz_rot_l(tz_node_t *x)
{
    tz_node_t *y = x->r;
    x->r = y->l;
    y->l = x;
    tz_fix(x);
    tz_fix(y);
    return y;
}

static tz_node_t *tz_balance(tz_node_t *n)
{
    tz_fix(n);
    int bf = tz_h(n->l) - tz_h(n->r);
    if (bf > 1) {
        if (tz_h(n->l->l) < tz_h(n->l->r)) n->l = tz_rot_l(n->l);
        return tz_rot_r(n);
    }
    if (bf < -1) {
        if (tz_h(n->r->r) < tz_h(n->r->l)) n->r = tz_rot_r(n->r);
        return tz_rot_l(n);
    }
    return n;
}

/* Insert `f` under `from`, or point an existing node at it (an upsert of the
   identity (zone, valid_from)). On allocation failure *oom is set and the
   tree is returned unchanged. */
static tz_node_t *tz_put(tz_node_t *n, int64_t from, const ds_rete_fact_t *f,
                         bool *oom)
{
    if (n == NULL) {
        tz_node_t *m = DS_MALLOC(sizeof *m);
        if (m == NULL) { *oom = true; return NULL; }
        m->from = from;
        m->fact = f;
        m->l = m->r = NULL;
        m->h = 1;
        return m;
    }
    if (from < n->from) {
        tz_node_t *c = tz_put(n->l, from, f, oom);
        if (*oom) return n;
        n->l = c;
    } else if (from > n->from) {
        tz_node_t *c = tz_put(n->r, from, f, oom);
        if (*oom) return n;
        n->r = c;
    } else {
        n->fact = f;
        return n;
    }
    return tz_balance(n);
}

static tz_node_t *tz_pop_min(tz_node_t *n, tz_node_t **min)
{
    if (n->l == NULL) { *min = n; return n->r; }
    n->l = tz_pop_min(n->l, min);
    return tz_balance(n);
}

/* Delete the node under `from` if it still names `f`: an upsert has already
   pointed it at the successor otherwise, and that entry stays. */
static tz_node_t *tz_del(tz_node_t *n, int64_t from, const ds_rete_fact_t *f)
{
    if (n == NULL) return NULL;
    if (from < n->from) {
        n->l = tz_del(n->l, from, f);
    } else if (from > n->from) {
        n->r = tz_del(n->r, from, f);
    } else {
        if (n->fact != f) return n;
        tz_node_t *l = n->l, *r = n->r;
        DS_FREE(n);
        if (r == NULL) return l;
        tz_node_t *m = NULL;
        r = tz_pop_min(r, &m);
        m->l = l;
        m->r = r;
        return tz_balance(m);
    }
    return tz_balance(n);
}

/* The node with the greatest `from` not after `t`, or NULL. */
static const tz_node_t *tz_floor(const tz_node_t *n, int64_t t)
{
    const tz_node_t *best = NULL;
    while (n != NULL) {
        if (n->from <= t) { best = n; n = n->r; }
        else              { n = n->l; }
    }
    return best;
}

static ds_result_t tz_index_put(ds_rete_engine_t *e, const ds_rete_fact_t *f)
{
    const ds_rete_val_t *z = &f->slots[0];
    /* The slot checks refused a non-String zone before the fact got here. */
    if (z->kind != DS_RETE_VAL_STR || z->s.ptr == NULL) return DS_OK_R;
    if (e->tz_index == NULL) {
        e->tz_index = DS_CALLOC(1, sizeof *e->tz_index);
        if (e->tz_index == NULL)
            return DS_ERR_R(DS_ERR_OOM, "tz index: alloc");
        ds_oa_init(&e->tz_index->zones, sizeof(tz_zone_key_t),
                sizeof(tz_node_t *), WM_MAX_LOAD, tz_zone_hash, tz_zone_eq,
                tz_zone_dtor, NULL);
    }
    tz_zone_key_t k = { z->s.ptr, z->s.len };
    void *vp;
    bool  is_new;
    ds_result_t r = ds_oa_put(&e->tz_index->zones, &k, &vp, &is_new);
    if (r.status != DS_OK) return r;
    tz_node_t **root = (tz_node_t **)vp;
    bool oom = false;
    tz_node_t *nr = tz_put(*root, tz_slot_ns(&f->slots[1]), f, &oom);
    if (oom) {
        if (*root == NULL) ds_oa_del(&e->tz_index->zones, &k);
        return DS_ERR_R(DS_ERR_OOM, "tz index: node alloc");
    }
    *root = nr;
    return DS_OK_R;
}

static void tz_index_del(ds_rete_engine_t *e, const ds_rete_fact_t *f)
{
    if (e->tz_index == NULL) return;
    const ds_rete_val_t *z = &f->slots[0];
    if (z->kind != DS_RETE_VAL_STR || z->s.ptr == NULL) return;
    tz_zone_key_t k = { z->s.ptr, z->s.len };
    tz_node_t **root = (tz_node_t **)ds_oa_get(&e->tz_index->zones, &k);
    if (root == NULL) return;
    *root = tz_del(*root, tz_slot_ns(&f->slots[1]), f);
    if (*root == NULL) ds_oa_del(&e->tz_index->zones, &k);
}

bool ds_rete_tz_resolve(const ds_rete_engine_t *engine, const char *zone,
                        uint32_t len, int64_t utc_ns, int32_t *out_offset_s)
{
    /* [LTIM.10.8]: exactly "UTC" is 0, with no fact consulted. */
    if (len == 3 && memcmp(zone, "UTC", 3) == 0) {
        *out_offset_s = 0;
        return true;
    }
    if (engine == NULL || engine->tz_index == NULL) return false;
    tz_zone_key_t k = { zone, len };
    tz_node_t *const *root =
        (tz_node_t *const *)ds_oa_get(&engine->tz_index->zones, &k);
    if (root == NULL) return false;
    const tz_node_t *n = tz_floor(*root, utc_ns);
    if (n == NULL) return false;
    /* The greatest `valid_from` not after `t` answers only while its
       `valid_until` is after `t`; otherwise the zone has no answer, whatever
       an earlier fact covers ([LTIM.10.7]). */
    if (!(tz_slot_ns(&n->fact->slots[2]) > utc_ns)) return false;
    *out_offset_s = (int32_t)n->fact->slots[3].i;
    return true;
}

uint32_t ds_rete_tz_zone_count(const ds_rete_engine_t *engine)
{
    if (engine == NULL || engine->tz_index == NULL) return 0;
    return oa_len(&engine->tz_index->zones);
}

void ds_rete_tz_index_free(ds_rete_engine_t *engine)
{
    if (engine == NULL || engine->tz_index == NULL) return;
    ds_oa_free(&engine->tz_index->zones);
    DS_FREE(engine->tz_index);
    engine->tz_index = NULL;
}

static ds_result_t wm_insert(ds_rete_engine_t *e, ds_rete_fact_t *f)
{
    void *vp;
    bool  is_new;
    ds_result_t r = ds_oa_put(&e->wm_map, &f->id, &vp, &is_new);
    if (r.status != DS_OK) return r;
    *(ds_rete_fact_t **)vp = f;
    /* [LERR.9.10]: the capacity checks leave fault facts out. */
    if (f->schema && f->schema->fault_fact) e->fault_fact_live++;

    /* A failure below undoes the insert through wm_remove, so the caller can
       free f with nothing left pointing at it. */
    if (f->deadline_ns > 0) {
        if (e->cap_dynamic_ttl) {
            /* A deadline heap, O(log N), for a per-emit TTL. */
            ds_result_t dr = dlheap_insert(e, f);
            if (dr.status != DS_OK) { wm_remove(e, f); return dr; }
        } else {
            /* A per-schema FIFO, O(1) (LDTL.1.1). */
            f->deadline_heap_idx = DL_NONE;
            f->fifo_prev = f->fifo_next = NULL;
            ds_rete_schema_t *s = (ds_rete_schema_t *)(uintptr_t)f->schema;
            if (s->ttl_fifo_tail) {
                s->ttl_fifo_tail->fifo_next = f;
                f->fifo_prev = s->ttl_fifo_tail;
            } else {
                s->ttl_fifo_head = f;
            }
            s->ttl_fifo_tail = f;
        }
    } else {
        f->deadline_heap_idx = DL_NONE;
        f->fifo_prev = f->fifo_next = NULL;
    }

    if (f->schema && f->schema->id_dedup) {
        ds_result_t r2 = id_hash_insert(
            (ds_rete_schema_t *)(uintptr_t)f->schema, f);
        if (r2.status != DS_OK) { wm_remove(e, f); return r2; }
    }

    /* [LTIM.10.7] */
    if (f->schema && f->schema->tz_offset) {
        ds_result_t r3 = tz_index_put(e, f);
        if (r3.status != DS_OK) { wm_remove(e, f); return r3; }
    }
    return DS_OK_R;
}

static void wm_remove(ds_rete_engine_t *e, ds_rete_fact_t *f)
{
    /* Only the entry that is f: a no-op if f never entered. */
    ds_rete_fact_t **vp = (ds_rete_fact_t **)ds_oa_get(&e->wm_map, &f->id);
    if (!vp || *vp != f) return;
    ds_oa_del(&e->wm_map, &f->id);
    if (f->schema && f->schema->fault_fact && e->fault_fact_live > 0)
        e->fault_fact_live--;

    if (f->deadline_ns > 0) {
        if (e->cap_dynamic_ttl) {
            if (f->deadline_heap_idx != DL_NONE)
                dlheap_remove(e, f);
        } else {
            ds_rete_schema_t *s =
                (ds_rete_schema_t *)(uintptr_t)f->schema;
            if (f->fifo_prev) f->fifo_prev->fifo_next = f->fifo_next;
            else              s->ttl_fifo_head = f->fifo_next;
            if (f->fifo_next) f->fifo_next->fifo_prev = f->fifo_prev;
            else              s->ttl_fifo_tail = f->fifo_prev;
            f->fifo_prev = f->fifo_next = NULL;
        }
    }
    if (f->schema && f->schema->id_dedup) {
        id_hash_remove((ds_rete_schema_t *)(uintptr_t)f->schema, f);
    }
    if (f->schema && f->schema->tz_offset) tz_index_del(e, f);
}

/* ---- No-op reassertion dedup -------------------------------------- */

/* [LFAC.2.5.1]: |a - b| <= tol, exactly. The difference is taken unsigned, so it
   cannot overflow, and a whole number is within `tol` iff it is within `tol`'s
   floor. A `tol` of 2^64 or more, an infinity included, holds every difference.
   The floor is taken by a conversion to int64_t, in range below 2^63; a `tol` in
   [2^63, 2^64) is 2^63 plus `tol - 2^63`, which is exact, so no double is
   converted to an unsigned type. Mercury: ds.fact.lfac_2_5_1_int_within. */
static bool int_within(int64_t a, int64_t b, double tol)
{
    uint64_t diff = a >= b ? (uint64_t)a - (uint64_t)b
                           : (uint64_t)b - (uint64_t)a;
    if (!(tol < 18446744073709551616.0)) return true;
    if (tol >= 9223372036854775808.0) {
        if (diff < UINT64_C(9223372036854775808)) return true;
        return diff - UINT64_C(9223372036854775808)
               <= (uint64_t)(int64_t)(tol - 9223372036854775808.0);
    }
    return diff <= (uint64_t)(int64_t)tol;
}

/* Under each slot's tolerance (IRET.3.4). An engine slot such as `ts` is not
   compared (LFAC.9.1, LFAC.2.5.1): the live fact keeps the `ts` it entered
   with. Mercury: ds.wm.slot_tests. */
static bool slots_equal(const ds_rete_schema_t *schema,
                        const ds_rete_val_t    *a,
                        const ds_rete_val_t    *b)
{
    for (uint16_t i = 0; i < schema->slot_count; i++) {
        const ds_rete_slot_desc_t *d = &schema->slots[i];
        if (d->is_engine) continue;
        /* [LFAC.2.5.1]: deep equality, before the kind test, since an owned
           tree and a borrowed one are one value. */
        if (val_is_json(a[i].kind) && val_is_json(b[i].kind)) {
            if (!ds_json_deep_equal(a[i].json, b[i].json)) return false;
            continue;
        }
        int64_t at, bt;
        if (d->time && time_slot_instants(&a[i], &b[i], &at, &bt)) {
            if (at != bt) return false;
            continue;
        }
        if (a[i].kind != b[i].kind) return false;
        switch (a[i].kind) {
        /* [LFAC.2.5.1]: equal iff |delta| <= tolerance, the bound included. */
        case DS_RETE_VAL_INT:
            if (d->tolerance > 0.0) {
                if (!int_within(a[i].i, b[i].i, d->tolerance)) return false;
            } else if (a[i].i != b[i].i) return false;
            break;
        case DS_RETE_VAL_FLOAT:
            /* [RLOW.3.7.4]: exact first, so two equal infinities, whose delta
               is NaN, are equal. The tolerance is never negative ([RDSC.9.11]). */
            if (a[i].f == b[i].f) break;
            if (d->tolerance > 0.0) {
                double diff = a[i].f - b[i].f;
                if (diff < 0) diff = -diff;
                if (!(diff <= d->tolerance)) return false;
            } else return false;
            break;
        case DS_RETE_VAL_STR:
            if (a[i].s.ptr != b[i].s.ptr) return false; /* interned */
            break;
        case DS_RETE_VAL_BOOL:
            if (a[i].b != b[i].b) return false;
            break;
        case DS_RETE_VAL_BYTES:
            /* [LFAC.2.5.4] */
            if (!bytes_equal(&a[i], &b[i])) return false;
            break;
        case DS_RETE_VAL_FACT_REF:
            /* By id, never by pointer: a freed target's slot is reused. */
            if (a[i].fact_ref_id != b[i].fact_ref_id) return false;
            break;
        case DS_RETE_VAL_TIME:
            /* LTIM.5.2: the instant; no tolerance. */
            if (a[i].time.utc_ns != b[i].time.utc_ns) return false;
            break;
        case DS_RETE_VAL_NULL:
            /* [LNUL.6.1] */
            break;
        default:
            return false;
        }
    }
    return true;
}

bool ds_rete_slots_equal(const ds_rete_schema_t *schema,
                         const ds_rete_val_t    *a,
                         const ds_rete_val_t    *b)
{
    return slots_equal(schema, a, b);
}

ds_rete_fact_t *ds_rete_wm_find_by_identity(ds_rete_engine_t       *e,
                                             const ds_rete_schema_t *schema,
                                             const ds_rete_val_t    *slot_values)
{
    (void)e;
    if (!schema->id_dedup) return NULL;
    ds_rete_fact_t **vp =
        (ds_rete_fact_t **)ds_oa_get(&schema->id_map, &slot_values);
    return vp ? *vp : NULL;
}

/* The owned Json trees; a borrow is skipped. Not on an assert's error exits:
   until it succeeds the trees are the caller's. */
static void wm_release_owned_json_slots(ds_rete_fact_t *f)
{
    if (f == NULL || f->schema == NULL) return;
    for (uint16_t i = 0; i < f->schema->slot_count; i++) {
        if (f->slots[i].kind == DS_RETE_VAL_JSON
                && f->slots[i].json != NULL) {
            ds_json_free(f->slots[i].json);
            f->slots[i].json = NULL;
        }
    }
}

/* IRET.1.4: a committed fact holds one intern reference per String or Bytes
   value, taken at commit and released at retract; a pinned value is a no-op.
   By value kind, so a null slot is skipped. */
static void wm_acquire_interned_vals(ds_rete_engine_t       *e,
                                     const ds_rete_schema_t *schema,
                                     const ds_rete_val_t    *vals)
{
    if (schema == NULL || vals == NULL) return;
    for (uint16_t i = 0; i < schema->slot_count; i++) {
        if ((vals[i].kind == DS_RETE_VAL_STR || vals[i].kind == DS_RETE_VAL_BYTES)
                && vals[i].s.ptr != NULL)
            ds_rete_intern_acquire_ptr(e->intern, vals[i].s.ptr, vals[i].s.len);
    }
}

static void wm_release_interned_vals(ds_rete_engine_t       *e,
                                     const ds_rete_schema_t *schema,
                                     const ds_rete_val_t    *vals)
{
    if (schema == NULL || vals == NULL) return;
    for (uint16_t i = 0; i < schema->slot_count; i++) {
        if ((vals[i].kind == DS_RETE_VAL_STR || vals[i].kind == DS_RETE_VAL_BYTES)
                && vals[i].s.ptr != NULL)
            ds_rete_intern_release(e->intern, vals[i].s.ptr, vals[i].s.len);
    }
}

/* ---- Deadline min-heap, under +dynamic_ttl -------------------------- */
/* Each fact carries its deadline_heap_idx, so removal is O(log N). Fixed-size
   in RT mode; grown on demand otherwise. */

static void dlheap_set(ds_rete_engine_t *e, uint32_t i, ds_rete_fact_t *f)
{
    e->deadline_heap_items[i] = f;
    f->deadline_heap_idx      = i;
}

static void dlheap_swap(ds_rete_engine_t *e, uint32_t i, uint32_t j)
{
    ds_rete_fact_t *tmp = e->deadline_heap_items[i];
    dlheap_set(e, i, e->deadline_heap_items[j]);
    dlheap_set(e, j, tmp);
}

/* Deadline, then the fact id, which is entry order (LDET.5.11): a total order,
   so equal deadlines drain in entry order. */
static bool dlheap_before(const ds_rete_fact_t *a, const ds_rete_fact_t *b)
{
    if (a->deadline_ns != b->deadline_ns) return a->deadline_ns < b->deadline_ns;
    return a->id < b->id;
}

static void dlheap_sift_up(ds_rete_engine_t *e, uint32_t i)
{
    while (i > 0) {
        uint32_t parent = (i - 1) / 2;
        if (!dlheap_before(e->deadline_heap_items[i],
                           e->deadline_heap_items[parent]))
            break;
        dlheap_swap(e, i, parent);
        i = parent;
    }
}

static void dlheap_sift_down(ds_rete_engine_t *e, uint32_t i)
{
    for (;;) {
        uint32_t best  = i;
        uint32_t left  = 2 * i + 1;
        uint32_t right = 2 * i + 2;
        if (left  < e->deadline_heap_count &&
            dlheap_before(e->deadline_heap_items[left],
                          e->deadline_heap_items[best]))
            best = left;
        if (right < e->deadline_heap_count &&
            dlheap_before(e->deadline_heap_items[right],
                          e->deadline_heap_items[best]))
            best = right;
        if (best == i) break;
        dlheap_swap(e, i, best);
        i = best;
    }
}

static ds_result_t dlheap_insert(ds_rete_engine_t *e, ds_rete_fact_t *f)
{
    if (e->deadline_heap_count >= e->deadline_heap_cap) {
        if (e->pools_ready) {
            return DS_ERR_R(DS_ERR_OOM, "dlheap_insert: heap full");
        }
        uint32_t new_cap = e->deadline_heap_cap ? e->deadline_heap_cap * 2 : 16u;
        ds_rete_fact_t **nb = DS_REALLOC(e->deadline_heap_items, new_cap * sizeof(*nb));
        if (!nb) return DS_ERR_R(DS_ERR_OOM, "dlheap_insert: OOM");
        e->deadline_heap_items = nb;
        e->deadline_heap_cap   = new_cap;
    }
    uint32_t i = e->deadline_heap_count++;
    dlheap_set(e, i, f);
    dlheap_sift_up(e, i);
    return DS_OK_R;
}

static void dlheap_remove(ds_rete_engine_t *e, ds_rete_fact_t *f)
{
    uint32_t i = f->deadline_heap_idx;
    if (i == DL_NONE || i >= e->deadline_heap_count) return;
    f->deadline_heap_idx = DL_NONE;

    e->deadline_heap_count--;
    if (i == e->deadline_heap_count) return;

    ds_rete_fact_t *moved = e->deadline_heap_items[e->deadline_heap_count];
    dlheap_set(e, i, moved);
    dlheap_sift_up(e, i);
    dlheap_sift_down(e, moved->deadline_heap_idx);
}

ds_result_t ds_rete_wm_presz(ds_rete_engine_t *engine, size_t cap)
{
    if (!engine || cap == 0) return DS_ERR_R(DS_ERR_INVAL, "wm_presz");
    return ds_oa_reserve(&engine->wm_map, (uint32_t)cap);
}

/* Presize each identity map for `cap` facts and refill it from the live facts,
   which may be there already. */
ds_result_t ds_rete_wm_rebuild_id_hashes(ds_rete_engine_t *engine, size_t cap)
{
    if (!engine) return DS_ERR_R(DS_ERR_INVAL, "rebuild_id_hashes: NULL");
    for (size_t si = 0; si < engine->schema_count; si++) {
        ds_rete_schema_t *s = engine->schemas_by_id[si];
        if (!s->id_dedup) continue;
        ds_oa_clear(&s->id_map);
        ds_result_t r = ds_oa_reserve(&s->id_map, (uint32_t)cap);
        if (r.status != DS_OK) return r;
        uint32_t wm_n = oa_len(&engine->wm_map);
        for (uint32_t j = 0; j < wm_n; j++) {
            ds_rete_fact_t *f = *(ds_rete_fact_t **)ds_oa_val_at(&engine->wm_map, j);
            if (!f || f->schema != s) continue;
            const ds_rete_val_t *slots = f->slots;
            void *vp;
            bool  is_new;
            r = ds_oa_put(&s->id_map, &slots, &vp, &is_new);
            if (r.status != DS_OK) return r;
            *(ds_rete_fact_t **)vp = f;
        }
    }
    return DS_OK_R;
}

/* ---- Public API --------------------------------------------------- */

/* [RARC.5.2.6]: exactly the declared kind, with no implicit conversion; the
 * host's door (wm_validate_assert_values) and Mercury's `ds.fact.admits_kind`
 * agree. A Time slot, declared INT, also holds a TIME, and a Json slot a
 * JSON_BORROW: each a representation of the declared type.
 *
 * UNBOUND is admitted everywhere. It lives only in a terminal's bind frame and
 * BIND_REF raises rather than yield it, so the arm is believed dead; removing it
 * wants a test that shows so.
 */
static bool rete_slot_kind_admissible(ds_rete_val_kind_t declared,
                                      ds_rete_val_kind_t got)
{
    if (got == DS_RETE_VAL_UNBOUND) return true;
    switch (declared) {
    case DS_RETE_VAL_INT:
        return got == DS_RETE_VAL_INT || got == DS_RETE_VAL_TIME;
    case DS_RETE_VAL_FLOAT:
        return got == DS_RETE_VAL_FLOAT;
    case DS_RETE_VAL_BOOL:
        return got == DS_RETE_VAL_BOOL;
    case DS_RETE_VAL_STR:
        return got == DS_RETE_VAL_STR;
    case DS_RETE_VAL_BYTES:
        return got == DS_RETE_VAL_BYTES;
    case DS_RETE_VAL_JSON:
        return got == DS_RETE_VAL_JSON || got == DS_RETE_VAL_JSON_BORROW;
    case DS_RETE_VAL_FACT_REF:
        return got == DS_RETE_VAL_FACT_REF;
    default:
        /* A declared kind the loader's mapping cannot produce. */
        return true;
    }
}

/* [LSTR.2.1]: every byte but a continuation byte starts a codepoint. A slot's
   string is valid UTF-8. */
static uint64_t utf8_codepoints(const char *p, size_t len)
{
    uint64_t n = 0;
    for (size_t i = 0; i < len; i++)
        if (((unsigned char) p[i] & 0xC0u) != 0x80u) n++;
    return n;
}

bool ds_rete_slot_over_capacity(const ds_rete_schema_t *schema, uint16_t slot,
                                const char *text, size_t len)
{
    const uint32_t capacity = schema->slots[slot].capacity;
    return capacity > 0 && utf8_codepoints(text, len) > capacity;
}

/* NMET.4.4, from the host's assert and a rule's emit alike. A rete engine with no
   DS engine counts nothing. */
static void wm_count_noop_reassert(ds_rete_engine_t       *engine,
                                   const ds_rete_schema_t *schema)
{
    if (engine == NULL || engine->ds_engine_back == NULL) return;
    ds_metric_label_t labels[1] = { { .key = "schema", .value = schema->name } };
    ds_metric_t m = {
        .name   = "ds.facts.noop_reassert_suppressed_total",
        .kind   = DS_METRIC_COUNTER, .value = 1.0,
        .labels = labels, .n_labels = 1,
    };
    (void)ds_telemetry_emit_metric((struct ds_engine *)engine->ds_engine_back,
                                   &m);
}

/* Asked before any state moves. Two passes, as the host's door and Mercury's
   `ds.fact.slot_fault` make them: kind and null over every slot, then NaN
   ([LEXP.4.2]), so a mismatch in a later slot outranks a NaN in an earlier one.
   This is the NaN check for a rule's path. */
int32_t ds_rete_slot_refused(const ds_rete_schema_t *schema,
                             const ds_rete_val_t    *slot_values)
{
    for (uint16_t i = 0; i < schema->slot_count; i++) {
        const ds_rete_slot_desc_t *d = &schema->slots[i];
        ds_rete_val_kind_t kind = slot_values[i].kind;

        /* [LNUL.3.1] */
        if (kind == DS_RETE_VAL_NULL) {
            if (!d->nullable) return (int32_t)i;
            continue;
        }
        if (!rete_slot_kind_admissible(d->type, kind)) return (int32_t)i;
    }
    for (uint16_t i = 0; i < schema->slot_count; i++)
        if (slot_values[i].kind == DS_RETE_VAL_FLOAT
            && slot_values[i].f != slot_values[i].f)
            return (int32_t)i;
    return -1;
}

/* A rule's path, as the host's door does (wm.c) and as Mercury's
   ds.wm.assert_fact does on both. No DS source reaches either arm: the door
   stores no root-null document, and the compiler saturates every Duration
   ([RLOW.6.1.6]). They hold the rule's path to the clauses whatever the
   producer. */
void ds_rete_lnul_3_4_canonical(const ds_rete_schema_t *schema,
                                ds_rete_val_t          *slot_values)
{
    for (uint16_t i = 0; i < schema->slot_count; i++) {
        ds_rete_val_t *v = &slot_values[i];
        ds_json_kind_t root_kind;
        if (schema->slots[i].type == DS_RETE_VAL_JSON
            && (v->kind == DS_RETE_VAL_JSON || v->kind == DS_RETE_VAL_JSON_BORROW)
            && v->json != NULL
            && ds_json_get_kind(v->json, &root_kind).status == DS_OK
            && root_kind == DS_JSON_NULL)
            *v = ds_rete_val_null();
        else if (schema->slots[i].duration && v->kind == DS_RETE_VAL_INT
                 && v->i < 0)
            *v = ds_rete_val_int(0);
    }
}

/* A refused slot is DS_ERR_SLOT_TYPE_MISMATCH and nothing changes (RARC.5.2.6).
   Then [LSTR.11.3]: a `String` over its slot's `capacity` is a BOUNDS refusal,
   CAP_VALUE_CAPACITY, never a truncation. Here and not in ds_rete_slot_refused,
   so over capacity is never a TypeError, on the host's door or a rule's emit. */
static ds_result_t rete_validate_slot_kinds(ds_rete_engine_t       *engine,
                                            const ds_rete_schema_t *schema,
                                            const ds_rete_val_t    *slot_values)
{
    const int32_t i = ds_rete_slot_refused(schema, slot_values);
    if (i >= 0) {
        if (slot_values[i].kind == DS_RETE_VAL_NULL)
            return DS_ERR_R(DS_ERR_SLOT_TYPE_MISMATCH,
                            "null value in a non-nullable slot (LNUL.3.1)");
        /* The host refuses its own NaN first; this is a caller with no firing
           to abandon. */
        if (slot_values[i].kind == DS_RETE_VAL_FLOAT
            && slot_values[i].f != slot_values[i].f
            && rete_slot_kind_admissible(schema->slots[i].type,
                                         DS_RETE_VAL_FLOAT))
            return DS_ERR_R(DS_ERR_NAN_REJECTED,
                            "NaN Float in a slot (LEXP.4.2)");
        return DS_ERR_R(DS_ERR_SLOT_TYPE_MISMATCH,
                        "slot-value kind does not match the declared slot "
                        "type (RARC.5.2.6)");
    }
    return ds_rete_capacity_refused(engine, schema, slot_values);
}

ds_result_t ds_rete_capacity_refused(ds_rete_engine_t       *engine,
                                     const ds_rete_schema_t *schema,
                                     const ds_rete_val_t    *slot_values)
{
    for (uint16_t s = 0; s < schema->slot_count; s++) {
        const ds_rete_slot_desc_t *d = &schema->slots[s];
        if (d->capacity > 0 && slot_values[s].kind == DS_RETE_VAL_STR) {
            uint64_t n = utf8_codepoints(slot_values[s].s.ptr,
                                         slot_values[s].s.len);
            if (n > d->capacity) {
                ds_rete_emit_breach(engine, DS_CAP_VALUE_CAPACITY,
                                    d->capacity, n, NULL, 0);
                return DS_ERR_R(DS_ERR_CONTRACT_BREACH,
                                "String longer than its slot's capacity "
                                "(LSTR.11.3)");
            }
        }
    }
    return DS_OK_R;
}

void ds_rete_wm_settle_supersede(ds_rete_engine_t *engine)
{
    if (engine == NULL || engine->supersede_old == NULL) return;
    ds_rete_fact_t *old_key = engine->supersede_old;
    const uint32_t  old_id  = engine->supersede_old_id;
    engine->supersede_old    = NULL;
    engine->supersede_new    = NULL;
    engine->supersede_old_id = 0;
    ds_engine_finish_supersede(engine, old_key, old_id);
}

/* An assert that retracted the fact it replaces and then failed: the old fact's
   withdrawal is recorded now (RFCS.6a.4). The host's door records its own from
   `out_replaced`, so only an emit is finished here. */
static void supersede_refused(ds_rete_engine_t *engine, ds_rete_fact_t *old_key,
                              uint32_t old_id, bool host)
{
    if (old_key != NULL && !host)
        ds_engine_finish_supersede(engine, old_key, old_id);
}

bool ds_rete_deadline_in_range(const ds_rete_engine_t *engine,
                               const ds_rete_schema_t *schema,
                               int64_t                 now_ns)
{
    int64_t window = 0;
    if (engine->pending_ttl_override_ns != 0)
        window = engine->pending_ttl_override_ns;
    else if (schema->scope == DS_RETE_SCOPE_TTL && schema->default_ttl_ns > 0)
        window = schema->default_ttl_ns;
    if (window <= 0) return true;
    return window <= INT64_MAX - now_ns;
}

ds_result_t ds_rete_wm_assert_ex(ds_rete_engine_t    *engine,
                                  uint16_t             schema_id,
                                  const ds_rete_val_t *slot_values,
                                  ds_rete_fact_t     **out,
                                  ds_rete_fact_t     **out_replaced)
{
    const bool host = (out_replaced != NULL);
    if (out_replaced) *out_replaced = NULL;
    if (!engine || !out)
        return DS_ERR_R(DS_ERR_INVAL, "wm_assert: NULL arg");
    /* RFCS.6a.4: a supersede still pending is finished before this one notes
       its own. */
    ds_rete_wm_settle_supersede(engine);
    ds_rete_fact_t *replaced_key = NULL;
    uint32_t replaced_id = 0;
    if (schema_id >= engine->schema_count)
        return DS_ERR_R(DS_ERR_NOT_FOUND, "wm_assert: unknown schema_id");

    const ds_rete_schema_t *schema = engine->schemas_by_id[schema_id];

    /* [LTIM.1.1.5]: a deadline is never wrapped. Every door asks first; this
       refuses a caller that did not, before the no-op check. */
    if (!ds_rete_deadline_in_range(engine, schema,
                                   engine->clock_fn(engine->clock_ctx)))
        return DS_ERR_R(DS_ERR_TIME_RANGE,
                        "wm_assert: the fact's deadline is outside the Time range");

    /* No-op reassertion check (IRET.19.1 steps 1-3). */
    if (schema->slot_count > 0) {
        if (!slot_values)
            return DS_ERR_R(DS_ERR_INVAL, "wm_assert: NULL slot_values");
        /* [RARC.5.2.6]: every path into working memory meets it here, before
           anything moves. */
        ds_result_t vr = rete_validate_slot_kinds(engine, schema, slot_values);
        if (vr.status != DS_OK) return vr;
        ds_rete_fact_t *existing =
            ds_rete_wm_find_by_identity(engine, schema, slot_values);
        if (existing && slots_equal(schema, existing->slots, slot_values)) {
            /* A success takes the caller's owned Json trees; a no-op keeps
               none, so it frees them. A borrow is not ours. */
            for (uint16_t i = 0; i < schema->slot_count; i++)
                if (slot_values[i].kind == DS_RETE_VAL_JSON
                    && slot_values[i].json != NULL)
                    ds_json_free(slot_values[i].json);
            *out = existing;
            wm_count_noop_reassert(engine, schema);
            return DS_OK_R;
        }
        /* [LSER.13.14], [RTCT.7.2]: after the no-op probe, which adds no
           sample, and before anything is acquired or queued. */
        ds_result_t cr = ds_engine_series_capacity_check(engine, schema,
                                                         slot_values);
        if (cr.status != DS_OK) return cr;
        /* Before the supersede's retract, so a value shared with the old fact
           never drops to zero references. */
        wm_acquire_interned_vals(engine, schema, slot_values);
        if (existing) {
            replaced_key = existing;
            replaced_id  = existing->id;
            /* [LSER.8.5.1]: the absorber walks working memory, so the outgoing
               sample is queued or lost. */
            ds_engine_queue_superseded_sample(engine, existing);
            /* [LFAC.1.7.2], [LFAC.2.5.3], RFCS.6a.4: the old fact leaves here,
               and its record follows the new one's: FACT_ASSERT(new), then
               FACT_RETRACT(old) with cause SUPERSEDED, then the activation facts
               waiting on it. The host's door records it from `out_replaced`;
               every other caller through ds_rete_wm_wrap_emitted_fact, from
               the pair noted below. */
            ds_result_t r = ds_rete_wm_retract(engine, existing);
            if (r.status != DS_OK) {
                wm_release_interned_vals(engine, schema, slot_values);
                return r;
            }
            /* [LERR.1.4.7]: the old fact's retract raised the EngineError, so
               the new fact is not inserted ([NCBK.2.9]). The old fact left the
               network and is reported, so its withdrawal is recorded ahead of
               the EngineError ([RFCS.6.7]), as Mercury orders it. */
            if (engine->halted) {
                wm_release_interned_vals(engine, schema, slot_values);
                if (out_replaced) *out_replaced = existing;
                return DS_ERR_R(DS_ERR_ENGINE_HALTED,
                                "wm_assert: the halt cut the upsert");
            }
            if (out_replaced) *out_replaced = existing;
        }
    }

    /* Only an insert can breach a cap on live facts ([RTCT.7.1]): a replacement
       leaves the count where it was, and is past its retract, so refusing it
       would break [RTCT.7.2]. Mercury tests only an `inserted` candidate
       (ds.exec wm_capped). Allocation-free (RTDS.3.7). */
    const bool replacing = (replaced_key != NULL);
    /* [LERR.9.10]: a fault fact is neither counted nor refused; its bound is
       one live fault fact per site. */
    const uint32_t counted =
        oa_len(&engine->wm_map) - engine->fault_fact_live;
    if (!schema->fault_fact && !replacing
        && engine->wm_max_facts > 0 && counted >= engine->wm_max_facts) {
        wm_release_interned_vals(engine, schema, slot_values);
        /* [NCBK.2.8]: a declared cap, so a BoundsError on the stream. */
        ds_rete_emit_breach(engine, DS_CAP_WM_MAX, engine->wm_max_facts,
                            (uint64_t)counted + 1u, NULL, 0);
        return DS_ERR_R(DS_ERR_WM_FULL, "wm_assert: N_max exceeded");
    }

    /* RTCT.7.1: the contract's wm_max, beside the integrator's. */
    if (engine->has_contract && !schema->fault_fact && !replacing &&
        counted >= engine->contract_wm_max) {
        wm_release_interned_vals(engine, schema, slot_values);
        ds_rete_emit_breach(engine, DS_CAP_WM_MAX,
                            engine->contract_wm_max,
                            (uint64_t)counted + 1u,
                            NULL, 0);
        return DS_ERR_R(DS_ERR_CONTRACT_BREACH,
                        "wm_assert: contract wm_max exceeded");
    }

    /* IRET.19.1 steps 4-6 */
    size_t sz = sizeof(ds_rete_fact_t) +
                schema->slot_count * sizeof(ds_rete_val_t);
    ds_rete_fact_t *f;
    if (engine->pools_ready) {
        f = ds_rete_pool_alloc(&engine->fact_pool);
        if (!f) {
            supersede_refused(engine, replaced_key, replaced_id, host);
            return DS_ERR_R(DS_ERR_OOM, "wm_assert: fact pool exhausted");
        }
        memset(f, 0, sz);
        f->owner_pool        = &engine->fact_pool;
        f->deadline_heap_idx = DL_NONE;
    } else {
        f = DS_CALLOC(1, sz);
        if (!f) {
            supersede_refused(engine, replaced_key, replaced_id, host);
            return DS_ERR_R(DS_ERR_OOM, "wm_assert: fact alloc");
        }
        f->deadline_heap_idx = DL_NONE;
    }

    f->id        = engine->next_fact_id++;
    f->schema    = schema;
    f->assert_ns = engine->clock_fn(engine->clock_ctx);

    if (engine->pending_ttl_override_ns != 0)
        /* LFAC.1.2o: the override wins whatever the lifecycle. Neither sum
           overflows: ds_rete_deadline_in_range refused that above. */
        f->deadline_ns = f->assert_ns + engine->pending_ttl_override_ns;
    else if (schema->scope == DS_RETE_SCOPE_TTL && schema->default_ttl_ns > 0)
        f->deadline_ns = f->assert_ns + schema->default_ttl_ns;

    /* The caller owns its Json trees until this succeeds, and frees them on
       every refusal, before this copy or after it. */
    if (schema->slot_count > 0)
        memcpy(f->slots, slot_values,
               schema->slot_count * sizeof(ds_rete_val_t));

    /* [LTIM.1.1.3]: a `Time` slot stores its instant as INT, whoever wrote it,
       so the join index (which compares kinds), the identity map and every
       reader agree; the offset does not persist. Mercury: `stored_value`. */
    for (uint16_t i = 0; i < schema->slot_count; i++)
        if (schema->slots[i].time && f->slots[i].kind == DS_RETE_VAL_TIME)
            f->slots[i] = ds_rete_val_int(f->slots[i].time.utc_ns);

    ds_result_t r = wm_insert(engine, f);
    if (r.status != DS_OK) {
        wm_release_interned_vals(engine, schema, f->slots);
        if (f->owner_pool) ds_rete_pool_free(f->owner_pool, f); else DS_FREE(f);
        supersede_refused(engine, replaced_key, replaced_id, host);
        return r;
    }

    /* IRET.11.3.2: a new generation expires the refraction entries. */
    engine->cycle_generation++;

    /* IRET.19.1 step 7 */
    r = ds_rete_dispatch_assert(engine, f);
    if (r.status != DS_OK) {
        wm_remove(engine, f);
        wm_release_interned_vals(engine, schema, f->slots);
        if (f->owner_pool) ds_rete_pool_free(f->owner_pool, f); else DS_FREE(f);
        supersede_refused(engine, replaced_key, replaced_id, host);
        return r;
    }

    /* The host's door records its own supersede from `out_replaced`; only an
       emit caller leaves the pair for ds_rete_wm_wrap_emitted_fact. */
    if (replaced_key != NULL && !host) {
        engine->supersede_old    = replaced_key;
        engine->supersede_new    = f;
        engine->supersede_old_id = replaced_id;
    }
    *out = f;
    return DS_OK_R;
}

ds_result_t ds_rete_wm_assert(ds_rete_engine_t    *engine,
                                uint16_t             schema_id,
                                const ds_rete_val_t *slot_values,
                                ds_rete_fact_t     **out)
{
    return ds_rete_wm_assert_ex(engine, schema_id, slot_values, out, NULL);
}

ds_result_t ds_rete_wm_retract(ds_rete_engine_t *engine,
                                 ds_rete_fact_t   *fact)
{
    if (!engine || !fact)
        return DS_ERR_R(DS_ERR_INVAL, "wm_retract: NULL arg");

    /* A fact with no schema is left alone. */
    if (!fact->schema)
        return DS_OK_R;

    /* IRET.11.3.2: a new generation expires the refraction entries. */
    engine->cycle_generation++;

    /* [LERR.1.4.7]: nothing leaves working memory once halted. */
    if (engine->halted) return DS_OK_R;

    /* IRET.19.2 step 1 */
    ds_result_t r = ds_rete_dispatch_retract(engine, fact);
    if (r.status != DS_OK) return r;

    /* [LERR.1.4.7]: a retract the halt cut keeps its fact, since tokens may
       still point at it; ds_engine_free releases it. */
    if (engine->halted) return DS_OK_R;

    wm_remove(engine, fact);

    /* [LTIM.2.5.1]: a fact id never recurs, so its edge-once marks go with it;
       this bounds the sets and changes no firing. The tick and timer facts are
       never marked, and are skipped to keep the per-pump path off the terminal
       scan. */
    if (engine->clock_tick_schema != NULL
            && fact->schema != engine->clock_tick_schema
            && !(fact->schema->name != NULL
                 && strncmp(fact->schema->name, DS_RETE_TIMER_PREFIX,
                            DS_RETE_TIMER_PREFIX_LEN) == 0)) {
        for (uint32_t i = 0; i < engine->owned_terminal_count; i++)
            ds_rete_terminal_oneshot_clear(engine->owned_terminals[i], fact->id);
    }

    /* After the network let go, so no token still borrows a string. */
    wm_release_interned_vals(engine, fact->schema, fact->slots);
    wm_release_owned_json_slots(fact);

    if (fact->owner_pool) ds_rete_pool_free(fact->owner_pool, fact);
    else                  DS_FREE(fact);
    return DS_OK_R;
}

size_t ds_rete_wm_count(const ds_rete_engine_t *engine)
{
    return engine ? oa_len(&engine->wm_map) : 0;
}

/* `at`, when it is later than `now_ns` and earlier than the best so far. */
static void note_deadline(uint64_t at, uint64_t now_ns,
                          uint64_t *io_best, bool *io_has)
{
    if (at <= now_ns) return;
    if (!*io_has || at < *io_best) {
        *io_best = at;
        *io_has  = true;
    }
}

/* [NLFC.2.5]. A scan: nothing holds a timer's `fire_at`, and a facts' queue head
   may be at or before `now_ns` with a later deadline behind it. */
void ds_rete_wm_next_deadline(const ds_rete_engine_t *engine, uint64_t now_ns,
                              uint64_t *io_best, bool *io_has)
{
    if (engine == NULL) return;
    uint32_t n = oa_len(&engine->wm_map);
    for (uint32_t i = 0; i < n; i++) {
        ds_rete_fact_t *const *vp =
            (ds_rete_fact_t *const *) ds_oa_val_at(&engine->wm_map, i);
        if (vp == NULL || *vp == NULL) continue;
        const ds_rete_fact_t *f = *vp;
        if (f->deadline_ns > 0)
            note_deadline((uint64_t) f->deadline_ns, now_ns, io_best, io_has);
        /* [LTAC.3.2]: `fire_at` is a timer schema's first slot. */
        if (f->schema != NULL && f->schema->name != NULL
                && f->schema->slot_count > 0
                && strncmp(f->schema->name, DS_RETE_TIMER_PREFIX,
                           DS_RETE_TIMER_PREFIX_LEN) == 0
                && f->slots[0].kind == DS_RETE_VAL_INT
                && f->slots[0].i > 0) {
            note_deadline((uint64_t) f->slots[0].i, now_ns, io_best, io_has);
        }
    }
}

ds_rete_fact_t *ds_rete_wm_find_by_id(const ds_rete_engine_t *engine,
                                        uint32_t                id)
{
    if (!engine) return NULL;
    ds_rete_fact_t **vp = (ds_rete_fact_t **)ds_oa_get(&engine->wm_map, &id);
    return vp ? *vp : NULL;
}

int ds_rete_wm_for_each(const ds_rete_engine_t *engine,
                          int (*visitor)(ds_rete_fact_t *, void *),
                          void *ctx)
{
    if (!engine || !visitor) return 0;
    /* oa's dense order ([IRET.28.10]), which feeds timetag assignment. */
    uint32_t wm_n = oa_len(&engine->wm_map);
    for (uint32_t i = 0; i < wm_n; i++) {
        int rv = visitor(*(ds_rete_fact_t **)ds_oa_val_at(&engine->wm_map, i), ctx);
        if (rv) return rv;
    }
    return 0;
}

/* LDET.5.11, [LDTL.6.1]: one tick's default-mode expiries leave by deadline,
   then by fact id (entry order), across schemas: a merge of the per-schema FIFO
   heads. Every schema with a queue takes part, whatever its scope
   ([RARC.5.2.4]): a capture fact's schema is explicit-scoped, its facts carry
   [LCCO.5.3]'s lifetime, and no wrapper sweep reaches them. A capture's queue
   is in deadline order, since the compiler fixes its window per call.

   A front is a snapshot of one schema's head, never a fact pointer, since a
   cascade can free another schema's head: each is checked against the live
   head before use, and re-keyed if it moved. */
typedef struct {
    int64_t  deadline;
    uint32_t id;
    uint32_t schema;          /* index into schemas_by_id */
} ttl_front_t;

/* More queued schemas than this allocate the heap, off RT only. In RT mode, or
   if the allocation fails, a linear scan gives the same order at
   O(expired x n_ttl_schemas) rather than [LDTL.6.1]'s O(expired x log
   n_ttl_schemas). */
#define TTL_FRONT_STACK 32u

static bool ttl_front_after(const ttl_front_t *a, const ttl_front_t *b)
{
    if (a->deadline != b->deadline) return a->deadline > b->deadline;
    return a->id > b->id;
}

/* Schema `idx`'s FIFO head as a front, if it is due at `now`. */
static bool ttl_front_due(const ds_rete_schema_t *s, uint32_t idx,
                          int64_t now, ttl_front_t *out)
{
    const ds_rete_fact_t *f = s->ttl_fifo_head;
    if (!f || f->deadline_ns == 0 || f->deadline_ns > now) return false;
    out->deadline = f->deadline_ns;
    out->id       = f->id;
    out->schema   = idx;
    return true;
}

static void ttl_front_sift_down(ttl_front_t *h, size_t i, size_t n)
{
    for (;;) {
        size_t m = i, l = 2u * i + 1u, r = 2u * i + 2u;
        if (l < n && ttl_front_after(&h[m], &h[l])) m = l;
        if (r < n && ttl_front_after(&h[m], &h[r])) m = r;
        if (m == i) return;
        ttl_front_t t = h[i]; h[i] = h[m]; h[m] = t;
        i = m;
    }
}

/* The merge through a heap of fronts: O(n_ttl_schemas) to build it, then
   O(log n_ttl_schemas) per expiry. Stops at the first refused retraction,
   leaving the rest for the next tick. */
static ds_result_t ttl_tick_merge_heap(ds_rete_engine_t *engine, int64_t now,
                                       ttl_front_t *heap, size_t *n_out)
{
    size_t hn = 0;
    for (size_t i = 0; i < engine->schema_count; i++) {
        const ds_rete_schema_t *s = engine->schemas_by_id[i];
        if (s && ttl_front_due(s, (uint32_t) i, now, &heap[hn]))
            hn++;
    }
    for (size_t i = hn / 2u; i-- > 0; ) ttl_front_sift_down(heap, i, hn);

    while (hn > 0) {
        /* [LERR.1.4.7]: a halted retract removes nothing, so the head would
           stay due. */
        if (engine->halted) return DS_OK_R;
        const ttl_front_t top = heap[0];
        ds_rete_schema_t *s = engine->schemas_by_id[top.schema];
        ttl_front_t cur;
        if (!ttl_front_due(s, top.schema, now, &cur)) {
            heap[0] = heap[--hn];          /* emptied, or no longer due */
            ttl_front_sift_down(heap, 0, hn);
            continue;
        }
        if (cur.deadline != top.deadline || cur.id != top.id) {
            heap[0] = cur;                 /* a cascade moved this head */
            ttl_front_sift_down(heap, 0, hn);
            continue;
        }
        ds_result_t rr = ds_rete_wm_retract(engine, s->ttl_fifo_head);
        if (rr.status != DS_OK) return rr;
        (*n_out)++;
        if (ttl_front_due(s, top.schema, now, &cur)) heap[0] = cur;
        else                                         heap[0] = heap[--hn];
        ttl_front_sift_down(heap, 0, hn);
    }
    return DS_OK_R;
}

/* The same merge by a linear scan (TTL_FRONT_STACK). */
static ds_result_t ttl_tick_merge_scan(ds_rete_engine_t *engine, int64_t now,
                                       size_t *n_out)
{
    for (;;) {
        if (engine->halted) return DS_OK_R;   /* [LERR.1.4.7], as above */
        ds_rete_schema_t *best_s = NULL;
        ttl_front_t best = { 0, 0, 0 }, cur;
        for (size_t i = 0; i < engine->schema_count; i++) {
            ds_rete_schema_t *s = engine->schemas_by_id[i];
            if (!s || !ttl_front_due(s, (uint32_t) i, now, &cur)) continue;
            if (!best_s || ttl_front_after(&best, &cur)) { best = cur; best_s = s; }
        }
        if (!best_s) return DS_OK_R;
        ds_result_t rr = ds_rete_wm_retract(engine, best_s->ttl_fifo_head);
        if (rr.status != DS_OK) return rr;
        (*n_out)++;
    }
}

ds_result_t ds_rete_wm_tick_ttl(ds_rete_engine_t *engine,
                                  int64_t            now_ns,
                                  size_t            *out_retracted)
{
    if (out_retracted) *out_retracted = 0;
    if (!engine) return DS_ERR_R(DS_ERR_INVAL, "wm_tick_ttl: NULL engine");

    ds_result_t r = DS_OK_R;
    size_t      n = 0;

    if (engine->cap_dynamic_ttl) {
        if (!engine->deadline_heap_items) {
            if (out_retracted) *out_retracted = 0;
            return DS_OK_R;
        }
        while (engine->deadline_heap_count > 0) {
            if (engine->halted) break;   /* [LERR.1.4.7], as in the merge */
            ds_rete_fact_t *f = engine->deadline_heap_items[0];
            if (f->deadline_ns == 0 || f->deadline_ns > now_ns) break;
            ds_result_t rr = ds_rete_wm_retract(engine, f);
            if (rr.status == DS_OK) n++;
            else if (r.status == DS_OK) r = rr;
        }
    } else {
        /* [LDTL.6.1]: each schema's queue is in deadline order, so the tick
           merges the heads. In a DS engine the wrapper sweep has already
           expired every wrapped fact, and what is left is the unwrapped ones,
           a capture's among them; the merge does not rest on that. The heap
           holds one front per queue the tick starts with, and a cascade adds
           none to it. */
        size_t n_ttl = 0;
        for (size_t i = 0; i < engine->schema_count; i++) {
            const ds_rete_schema_t *s = engine->schemas_by_id[i];
            if (s && s->ttl_fifo_head) n_ttl++;
        }
        ttl_front_t  stack_heap[TTL_FRONT_STACK];
        ttl_front_t *heap  = NULL;
        bool         owned = false;
        if (n_ttl <= TTL_FRONT_STACK) {
            heap = stack_heap;
        } else if (!engine->rt_mode) {
            heap  = DS_MALLOC(n_ttl * sizeof(*heap));
            owned = heap != NULL;
        }
        r = heap ? ttl_tick_merge_heap(engine, now_ns, heap, &n)
                 : ttl_tick_merge_scan(engine, now_ns, &n);
        if (owned) DS_FREE(heap);
    }

    if (out_retracted) *out_retracted = n;
    return r;
}

/* ---- Working-memory clone ------------------------------------------- */

/* NULL-safe. */
static ds_rete_fact_t *clone_fact_ptr(ds_rete_clone_ctx_t *cx,
                                      const ds_rete_fact_t *f)
{
    return f ? ds_rete_clone_fact_lookup(cx, f->id) : NULL;
}

ds_result_t ds_rete_wm_clone(ds_rete_clone_ctx_t *cx,
                             const ds_rete_engine_t *src,
                             ds_rete_engine_t *dst)
{
    const uint32_t n = oa_len(&src->wm_map);

    /* Pass 1: each fact, in src's dense order, which timetag assignment reads.
       The links are pass 2, so dense and FIFO order are each reproduced. */
    for (uint32_t i = 0; i < n; i++) {
        const ds_rete_fact_t *sf =
            *(ds_rete_fact_t *const *) ds_oa_val_at(&src->wm_map, i);
        ds_rete_schema_t *dsch = dst->schemas_by_id[sf->schema->id];

        size_t sz = sizeof(ds_rete_fact_t) +
                    (size_t) dsch->slot_count * sizeof(ds_rete_val_t);
        ds_rete_fact_t *nf = DS_CALLOC(1, sz);
        if (!nf) return DS_ERR_R(DS_ERR_OOM, "wm_clone: fact alloc");

        nf->id                = sf->id;
        nf->schema            = dsch;
        nf->assert_ns         = sf->assert_ns;
        nf->deadline_ns       = sf->deadline_ns;
        nf->justif_count      = sf->justif_count;
        nf->series_absorbed   = sf->series_absorbed;
        nf->deadline_heap_idx = sf->deadline_heap_idx;
        nf->owner_pool        = NULL;
        nf->fifo_next = nf->fifo_prev = NULL;
        for (uint16_t s = 0; s < dsch->slot_count; s++)
            nf->slots[s] = ds_rete_clone_val(cx, &sf->slots[s]);
        /* IRET.1.4: one reference per value, as wm_acquire_interned_vals. */
        for (uint16_t s = 0; s < dsch->slot_count; s++) {
            if ((nf->slots[s].kind == DS_RETE_VAL_STR ||
                 nf->slots[s].kind == DS_RETE_VAL_BYTES) &&
                nf->slots[s].s.ptr != NULL)
                ds_rete_intern_acquire_ptr(dst->intern,
                                           nf->slots[s].s.ptr, nf->slots[s].s.len);
        }

        void *vp; bool is_new;
        ds_result_t r = ds_oa_put(&dst->wm_map, &nf->id, &vp, &is_new);
        if (r.status != DS_OK) { DS_FREE(nf); return r; }
        *(ds_rete_fact_t **) vp = nf;

        void *ip;
        r = ds_oa_put(&cx->id2fact, &sf->id, &ip, &is_new);
        if (r.status != DS_OK) return r;
        *(ds_rete_fact_t **) ip = nf;

        if (cx->oom) return DS_ERR_R(DS_ERR_OOM, "wm_clone: slot value clone");
    }

    /* Pass 2: FIFO links and identity maps. A FACT_REF holds an id, which the
       clone keeps. */
    for (uint32_t i = 0; i < n; i++) {
        const ds_rete_fact_t *sf =
            *(ds_rete_fact_t *const *) ds_oa_val_at(&src->wm_map, i);
        ds_rete_fact_t *nf = ds_rete_clone_fact_lookup(cx, sf->id);
        nf->fifo_next = clone_fact_ptr(cx, sf->fifo_next);
        nf->fifo_prev = clone_fact_ptr(cx, sf->fifo_prev);
        ds_result_t r = id_hash_insert(
            (ds_rete_schema_t *) (uintptr_t) nf->schema, nf);
        if (r.status != DS_OK) return r;
        /* [LTIM.10.7]: pass 1 bypassed wm_insert. */
        if (nf->schema->tz_offset) {
            r = tz_index_put(dst, nf);
            if (r.status != DS_OK) return r;
        }
    }

    for (size_t si = 0; si < src->schema_count; si++) {
        const ds_rete_schema_t *ss = src->schemas_by_id[si];
        ds_rete_schema_t       *ds = dst->schemas_by_id[si];
        ds->ttl_fifo_head = clone_fact_ptr(cx, ss->ttl_fifo_head);
        ds->ttl_fifo_tail = clone_fact_ptr(cx, ss->ttl_fifo_tail);
    }

    /* The deadline heap, position for position: each fact's index was copied. */
    if (src->deadline_heap_count > 0 && src->deadline_heap_items) {
        uint32_t cap = src->deadline_heap_cap ? src->deadline_heap_cap
                                              : src->deadline_heap_count;
        dst->deadline_heap_items = DS_CALLOC(cap, sizeof(*dst->deadline_heap_items));
        if (!dst->deadline_heap_items)
            return DS_ERR_R(DS_ERR_OOM, "wm_clone: deadline heap");
        dst->deadline_heap_cap   = cap;
        dst->deadline_heap_count = src->deadline_heap_count;
        for (uint32_t i = 0; i < src->deadline_heap_count; i++)
            dst->deadline_heap_items[i] =
                clone_fact_ptr(cx, src->deadline_heap_items[i]);
    }

    return DS_OK_R;
}
