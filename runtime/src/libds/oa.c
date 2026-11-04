/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * oa.c — the open-addressing map ([IRET.28]).
 */
#include "oa.h"

#include <assert.h>

#include "ds_alloc.h"

/* size_t, to avoid u32 overflow on big tables. */
#define OA_DKEY(t, d) ((t)->dkeys + (size_t)(d) * (t)->ksize)
#define OA_DVAL(t, d) ((t)->dvals + (size_t)(d) * (t)->vsize)

/* Terminates: len < cap (RI-2) guarantees an empty slot. */
static uint32_t oa_find(const oa_t *t, const void *key, uint64_t H)
{
    if (t->cap == 0) return OA_NONE;
    uint32_t mask = t->cap - 1, i = (uint32_t)H & mask, hh = (uint32_t)H;
    for (;;) {
        uint32_t s = t->slots[i];
        if (s == 0) return OA_NONE;                 /* empty => absent (RI-5) */
        uint32_t d = s - 1;
        if (t->dhash[d] == hh && t->eq(OA_DKEY(t, d), key, t->ctx)) return d;
        i = (i + 1) & mask;
    }
}

/* Rehashes via the cached dhash, with no hash or eq call. DS_ERR_OOM leaves t untouched. */
static ds_result_t oa_resize(oa_t *t, uint32_t newcap)
{
    uint32_t *ns = DS_CALLOC(newcap, sizeof(uint32_t));
    uint8_t  *nk = DS_MALLOC((size_t)newcap * t->ksize);
    uint8_t  *nv = t->vsize ? DS_MALLOC((size_t)newcap * t->vsize) : NULL;
    uint32_t *nh = DS_MALLOC((size_t)newcap * sizeof(uint32_t));
    uint32_t *nd = DS_MALLOC((size_t)newcap * sizeof(uint32_t));
    if (!ns || !nk || (t->vsize && !nv) || !nh || !nd) {
        DS_FREE(ns); DS_FREE(nk); DS_FREE(nv); DS_FREE(nh); DS_FREE(nd);
        return DS_ERR_R(DS_ERR_OOM, "oa: resize");
    }

    if (t->len) {
        memcpy(nk, t->dkeys, (size_t)t->len * t->ksize);
        if (t->vsize) memcpy(nv, t->dvals, (size_t)t->len * t->vsize);
        memcpy(nh, t->dhash, (size_t)t->len * sizeof(uint32_t));
    }

    uint32_t mask = newcap - 1;
    for (uint32_t d = 0; d < t->len; d++) {
        uint32_t i = nh[d] & mask;
        while (ns[i]) i = (i + 1) & mask;
        ns[i]  = d + 1;
        nd[d]  = i;
    }

    DS_FREE(t->slots); DS_FREE(t->dkeys); DS_FREE(t->dvals);
    DS_FREE(t->dhash); DS_FREE(t->dslot);
    t->slots = ns; t->dkeys = nk; t->dvals = nv;
    t->dhash = nh; t->dslot = nd; t->cap = newcap;
    return DS_OK_R;
}

void ds_oa_init(oa_t *t, uint16_t ksize, uint16_t vsize, uint8_t load_pct,
             oa_hash_fn hash, oa_eq_fn eq, oa_dtor_fn val_dtor, void *ctx)
{
    memset(t, 0, sizeof(*t));
    t->ksize    = ksize;
    t->vsize    = vsize;
    t->load_pct = load_pct ? load_pct : 70;
    t->hash     = hash;
    t->eq       = eq;
    t->val_dtor = val_dtor;
    t->ctx      = ctx;
}

ds_result_t ds_oa_reserve(oa_t *t, uint32_t n)
{
    if (n == 0) return DS_OK_R;
    /* The smallest power of two with n <= cap*load_pct/100. */
    uint64_t want = ((uint64_t)n * 100u + t->load_pct - 1) / t->load_pct;
    uint32_t newcap = OA_INIT_CAP;
    while (newcap < want) {
        if (newcap >= (1u << 31)) return DS_ERR_R(DS_ERR_OOM, "oa: cap overflow");
        newcap <<= 1;
    }
    if (newcap <= t->cap) return DS_OK_R;
    return oa_resize(t, newcap);
}

void ds_oa_clear(oa_t *t)
{
    if (t->val_dtor)
        for (uint32_t d = 0; d < t->len; d++)
            t->val_dtor(OA_DVAL(t, d), t->ctx);
    if (t->cap) memset(t->slots, 0, (size_t)t->cap * sizeof(uint32_t));
    t->len = 0;
}

void ds_oa_free(oa_t *t)
{
    ds_oa_clear(t);
    DS_FREE(t->slots); DS_FREE(t->dkeys); DS_FREE(t->dvals);
    DS_FREE(t->dhash); DS_FREE(t->dslot);
    memset(t, 0, sizeof(*t));
}

void *ds_oa_get(const oa_t *t, const void *key)
{
    uint64_t H = oa_mix64(t->hash(key, t->ctx));
    uint32_t d = oa_find(t, key, H);
    return (d == OA_NONE) ? NULL : OA_DVAL(t, d);
}

ds_result_t ds_oa_put(oa_t *t, const void *key, void **out_val, bool *is_new)
{
    uint64_t H = oa_mix64(t->hash(key, t->ctx));
    uint32_t d = oa_find(t, key, H);
    if (d != OA_NONE) {
        if (out_val) *out_val = OA_DVAL(t, d);
        if (is_new)  *is_new  = false;
        return DS_OK_R;
    }

    if (t->cap == 0 ||
        (uint64_t)(t->len + 1) * 100u > (uint64_t)t->cap * t->load_pct) {
        if (t->locked) return DS_ERR_R(DS_ERR_RT_UNSAFE, "oa: grow while locked");
        uint32_t newcap;
        if (t->cap == 0) {
            newcap = OA_INIT_CAP;
        } else {
            if (t->cap >= (1u << 31)) return DS_ERR_R(DS_ERR_OOM, "oa: cap overflow");
            newcap = t->cap * 2u;
        }
        ds_result_t gr = oa_resize(t, newcap);
        if (gr.status != DS_OK) return gr;
    }

    uint32_t mask = t->cap - 1;
    d = t->len++;
    memcpy(OA_DKEY(t, d), key, t->ksize);
    if (t->vsize) memset(OA_DVAL(t, d), 0, t->vsize);
    t->dhash[d] = (uint32_t)H;
    uint32_t i = (uint32_t)H & mask;
    while (t->slots[i]) i = (i + 1) & mask;
    t->slots[i] = d + 1;
    t->dslot[d] = i;

    if (out_val) *out_val = OA_DVAL(t, d);
    if (is_new)  *is_new  = true;
    return DS_OK_R;
}

static void oa_del_at(oa_t *t, uint32_t d)
{
    uint32_t s = t->dslot[d], mask = t->cap - 1;
    if (t->val_dtor) t->val_dtor(OA_DVAL(t, d), t->ctx);

    /* The dense swap-remove. */
    uint32_t last = --t->len;
    if (d != last) {
        memcpy(OA_DKEY(t, d), OA_DKEY(t, last), t->ksize);
        if (t->vsize) memcpy(OA_DVAL(t, d), OA_DVAL(t, last), t->vsize);
        t->dhash[d]            = t->dhash[last];
        t->dslot[d]            = t->dslot[last];
        t->slots[t->dslot[d]]  = d + 1;
    }

    /* The backward-shift. slots[s] = 0 first, so the scan terminates when it wraps back
       to s, even at maximal load. */
    t->slots[s] = 0;
    uint32_t gap = s, scan = (s + 1) & mask;
    while (t->slots[scan] != 0) {
        uint32_t nat = t->dhash[t->slots[scan] - 1] & mask;
        bool on_path = (nat <= scan) ? (nat <= gap && gap < scan)
                                     : (gap >= nat || gap < scan);
        if (on_path) {
            t->slots[gap] = t->slots[scan];
            t->dslot[t->slots[gap] - 1] = gap;
            t->slots[scan] = 0;
            gap = scan;
        }
        scan = (scan + 1) & mask;
    }
}

bool ds_oa_del(oa_t *t, const void *key)
{
    uint64_t H = oa_mix64(t->hash(key, t->ctx));
    uint32_t d = oa_find(t, key, H);
    if (d == OA_NONE) return false;
    oa_del_at(t, d);
    return true;
}

void *ds_oa_val_at(const oa_t *t, uint32_t i) { return OA_DVAL(t, i); }
void *ds_oa_key_at(const oa_t *t, uint32_t i) { return OA_DKEY(t, i); }

size_t ds_oa_footprint_bytes(const oa_t *t)
{
    if (t->cap == 0) return 0;
    return (size_t)t->cap *
           (3u * sizeof(uint32_t) + (size_t)t->ksize + (size_t)t->vsize);
}

/* The largest key any map uses is a ds_rete_val_t or a pointer. */
#define OA_CLONE_KMAX 64u

ds_result_t ds_oa_clone_into(oa_t *dst, const oa_t *src,
                          oa_remap_fn remap_key, oa_remap_fn remap_val,
                          void *ctx)
{
    if (dst->ksize != src->ksize || dst->vsize != src->vsize)
        return DS_ERR_R(DS_ERR_INVAL, "ds_oa_clone_into: key/value size mismatch");
    if (src->ksize > OA_CLONE_KMAX)
        return DS_ERR_R(DS_ERR_INVAL, "ds_oa_clone_into: key exceeds OA_CLONE_KMAX");

    uint32_t n = oa_len(src);
    if (n == 0) return DS_OK_R;

    ds_result_t r = ds_oa_reserve(dst, n);
    if (r.status != DS_OK) return r;

    uint8_t kbuf[OA_CLONE_KMAX];
    for (uint32_t i = 0; i < n; i++) {
        const void *sk = ds_oa_key_at(src, i);
        const void *sv = ds_oa_val_at(src, i);
        if (remap_key) remap_key(sk, kbuf, ctx);
        else           memcpy(kbuf, sk, src->ksize);

        void *dv = NULL;
        r = ds_oa_put(dst, kbuf, &dv, NULL);
        if (r.status != DS_OK) return r;
        if (remap_val) remap_val(sv, dv, ctx);
        else           memcpy(dv, sv, src->vsize);
    }
    return DS_OK_R;
}

/* ---- ds_oa_check (RI-1..RI-7) ------------------------------------------- */

#ifndef NDEBUG
void ds_oa_check(const oa_t *t)
{
    /* RI-1: cap is 0 or a power of two. */
    assert(t->cap == 0 || (t->cap & (t->cap - 1)) == 0);
    if (t->cap == 0) { assert(t->len == 0); return; }
    /* RI-2: len < cap. */
    assert(t->len < t->cap);

    /* count non-empty slots == len; RI-3 + RI-4 (slot -> dense). */
    uint32_t occ = 0;
    for (uint32_t i = 0; i < t->cap; i++) {
        uint32_t s = t->slots[i];
        if (s == 0) continue;
        occ++;
        assert(s - 1 < t->len);             /* RI-3 */
        assert(t->dslot[s - 1] == i);       /* RI-4 */
    }
    assert(occ == t->len);

    /* RI-4 (dense -> slot), RI-5 findability, RI-6 no-dup, RI-7 cached hash. */
    for (uint32_t d = 0; d < t->len; d++) {
        assert(t->slots[t->dslot[d]] == d + 1);
        uint64_t H = oa_mix64(t->hash(OA_DKEY(t, d), t->ctx));
        assert(t->dhash[d] == (uint32_t)H);              /* RI-7 */
        assert(oa_find(t, OA_DKEY(t, d), H) == d);       /* RI-5 + RI-6 */
    }
}
#endif

/* ---- oa_list multimap adapter ---------------------------------------- */

ds_result_t ds_oa_list_add(oa_list *l, void *elem, bool rt_locked)
{
    if (l->n < OA_LIST_INLINE) {
        l->inl[l->n++] = elem;
        return DS_OK_R;
    }
    uint32_t hi = l->n - OA_LIST_INLINE;
    if (hi >= l->heap_cap) {
        if (rt_locked) return DS_ERR_R(DS_ERR_RT_UNSAFE, "oa_list: grow while locked");
        uint32_t ncap = l->heap_cap ? l->heap_cap * 2u : 4u;
        void **nh = DS_REALLOC(l->heap, (size_t)ncap * sizeof(void *));
        if (!nh) return DS_ERR_R(DS_ERR_OOM, "oa_list: heap");
        l->heap = nh;
        l->heap_cap = ncap;
    }
    l->heap[hi] = elem;
    l->n++;
    return DS_OK_R;
}

bool ds_oa_list_remove(oa_list *l, void *elem)
{
    for (uint32_t i = 0; i < l->n; i++) {
        void **slot = (i < OA_LIST_INLINE) ? &l->inl[i]
                                           : &l->heap[i - OA_LIST_INLINE];
        if (*slot == elem) {
            uint32_t last = l->n - 1;
            void *lastv = (last < OA_LIST_INLINE) ? l->inl[last]
                                                  : l->heap[last - OA_LIST_INLINE];
            *slot = lastv;
            l->n--;
            return true;
        }
    }
    return false;
}

uint32_t ds_oa_list_len(const oa_list *l) { return l->n; }

void *ds_oa_list_at(const oa_list *l, uint32_t i)
{
    return (i < OA_LIST_INLINE) ? l->inl[i] : l->heap[i - OA_LIST_INLINE];
}

void ds_oa_list_free(void *val, void *ctx)
{
    (void)ctx;
    oa_list *l = (oa_list *)val;
    DS_FREE(l->heap);
    l->heap = NULL;
    l->heap_cap = 0;
    l->n = 0;
}
