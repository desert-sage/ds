/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/intern.c — string intern table with refcounted fact-slot values
 * (IRET.1.4; the entry classes are in intern.h).
 *
 * A freed counted slot becomes TOMBSTONE, which lookups probe through and inserts
 * may reuse. A rehash drops tombstones. The table never shrinks.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "ds_alloc.h"

#include "rete/intern.h"

/* ---- Slab allocator (pinned storage) ------------------------------- */

#define SLAB_CAPACITY 4096u

struct slab {
    struct slab *next;
    size_t       used;
    char         data[SLAB_CAPACITY];
};

static char *slab_alloc(struct slab **head, size_t need)
{
    /* need includes the NUL terminator the caller will write */
    struct slab *s = *head;
    if (!s || s->used + need > SLAB_CAPACITY) {
        struct slab *ns = DS_CALLOC(1, sizeof(struct slab));
        if (!ns) return NULL;
        ns->next = *head;
        *head    = ns;
        s        = ns;
    }
    char *p  = s->data + s->used;
    s->used += need;
    return p;
}

/* ---- Hash table ---------------------------------------------------- */

#define INIT_BUCKETS 64u   /* power of two */
#define MAX_LOAD_PCT 70u   /* rehash when (n+tombstones)*100/cap >= this */

/* Saturated refcount marks a PINNED (engine-lifetime) entry. */
#define PIN_REF      UINT32_MAX
/* Per-entry flag: the string is an individual allocation (counted, or an
 * oversized pinned string) and must be DS_FREE'd, not left to the slab. */
#define FLAG_HEAP    0x1u
/* Deleted-slot sentinel: lookups probe through it, inserts may reuse it. */
#define TOMBSTONE    ((const char *)0x1)

#define IS_LIVE(p)   ((p) != NULL && (p) != TOMBSTONE)

/* A counted string's block comes from an intrusive size-classed freelist and
 * returns to it on release, so a steady assert/retract cycle does not allocate.
 * Oversized strings bypass it. */
#define N_FREE_CLASS 10u          /* 8 << 0 .. 8 << 9  == 8 .. 4096 */

struct free_node { struct free_node *next; };

struct ds_rete_intern {
    const char **buckets;    /* open-addressing; NULL=empty, TOMBSTONE=deleted */
    size_t      *lens;       /* parallel — exact byte length */
    uint32_t    *refs;       /* parallel — PIN_REF=pinned, else counted refcount */
    uint8_t     *flags;      /* parallel — FLAG_HEAP etc. */
    size_t       cap;        /* always a power of two */
    size_t       n;          /* live entries (excludes tombstones) */
    size_t       n_pinned;   /* live entries whose ref is PIN_REF: maintained
                                because the pump reads it every cycle. Pinning
                                is monotone, so it is exact. */
    size_t       tombstones; /* deleted slots awaiting reuse/rehash */
    struct slab *slab_head;
    struct free_node *freelist[N_FREE_CLASS];
    size_t       counted_mallocs;
    bool         rt_locked;  /* growth returns DS_ERR_OOM */
    bool         frozen;     /* a new PINNED insert is DS_ERR_INTERNAL */
    bool         tearing_down; /* a release past zero calls no hook */
    size_t       resize_count;

    ds_rete_intern_fault_fn fault_fn;
    void        *fault_ctx;

    uint32_t     contract_cap_n;
    uint32_t     contract_cap_bytes;
    uint64_t     bytes_used;   /* running sum of live interned-string byte lengths */
};

/* FNV-1a over len bytes */
static uint32_t hash_bytes(const char *s, size_t len)
{
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < len; i++) {
        h ^= (uint8_t)s[i];
        h *= 16777619u;
    }
    return h;
}

/* Rehash into a table of new_cap buckets, dropping tombstones. Shared by
 * grow() and presz(). Caller supplies the target capacity (power of two,
 * > current live count). */
static ds_result_t rehash_into(ds_rete_intern_t *t, size_t new_cap)
{
    const char **nb = DS_CALLOC(new_cap, sizeof(const char *));
    size_t      *nl = DS_CALLOC(new_cap, sizeof(size_t));
    uint32_t    *nr = DS_CALLOC(new_cap, sizeof(uint32_t));
    uint8_t     *nf = DS_CALLOC(new_cap, sizeof(uint8_t));
    if (!nb || !nl || !nr || !nf) {
        DS_FREE(nb); DS_FREE(nl); DS_FREE(nr); DS_FREE(nf);
        return DS_ERR_R(DS_ERR_OOM, "intern rehash");
    }
    for (size_t i = 0; i < t->cap; i++) {
        const char *s = t->buckets[i];
        if (!IS_LIVE(s)) continue;         /* skip empty and tombstones */
        size_t   len = t->lens[i];
        uint32_t h   = hash_bytes(s, len);
        size_t   j   = h & (new_cap - 1);
        while (nb[j]) j = (j + 1) & (new_cap - 1);   /* no tombstones yet */
        nb[j] = s;
        nl[j] = len;
        nr[j] = t->refs[i];
        nf[j] = t->flags[i];
    }
    DS_FREE(t->buckets); DS_FREE(t->lens); DS_FREE(t->refs); DS_FREE(t->flags);
    t->buckets     = nb;
    t->lens        = nl;
    t->refs        = nr;
    t->flags       = nf;
    t->cap         = new_cap;
    t->tombstones  = 0;
    return DS_OK_R;
}

/* Rehash into a table twice as large. */
static ds_result_t grow(ds_rete_intern_t *t)
{
    t->resize_count++;
    return rehash_into(t, t->cap * 2);
}

/* Locate the live entry matching (str, len); return its index or SIZE_MAX.
 * Probes through tombstones; stops at an empty slot. */
static size_t lookup_idx(const ds_rete_intern_t *t,
                         const char *str, size_t len, uint32_t h)
{
    size_t i = h & (t->cap - 1);
    while (t->buckets[i]) {
        const char *s = t->buckets[i];
        if (s != TOMBSTONE && t->lens[i] == len && memcmp(s, str, len) == 0)
            return i;
        i = (i + 1) & (t->cap - 1);
    }
    return SIZE_MAX;
}

/* Locate the entry whose stored pointer IS ptr (pointer identity, for an
 * already-interned string); return its index or SIZE_MAX. */
static size_t lookup_ptr_idx(const ds_rete_intern_t *t,
                             const char *ptr, size_t len)
{
    uint32_t h = hash_bytes(ptr, len);
    size_t   i = h & (t->cap - 1);
    while (t->buckets[i]) {
        if (t->buckets[i] == ptr) return i;
        i = (i + 1) & (t->cap - 1);
    }
    return SIZE_MAX;
}

/* ---- Counted-string recycling freelist ----------------------------- */

/* Smallest size class (8 << c) that holds `need` bytes, or -1 if oversized. */
static int size_class(size_t need)
{
    size_t sz = 8;
    for (int c = 0; c < (int)N_FREE_CLASS; c++) {
        if (need <= sz) return c;
        sz <<= 1;
    }
    return -1;
}

static size_t class_size(int c) { return (size_t)8 << c; }

/* Allocate a counted-string block of at least `need` bytes: reuse a recycled
 * block of the matching size class if one is free, else allocate class-sized
 * (so it recycles on release). Oversized strings get an exact allocation and
 * do not recycle. Returns NULL on OOM. */
static char *counted_alloc(ds_rete_intern_t *t, size_t need)
{
    int c = size_class(need);
    if (c < 0) { t->counted_mallocs++; return DS_MALLOC(need); } /* oversized */
    if (t->freelist[c] != NULL) {
        struct free_node *n = t->freelist[c];
        t->freelist[c] = n->next;
        return (char *)n;                        /* recycled — no alloc */
    }
    t->counted_mallocs++;
    return DS_MALLOC(class_size(c));             /* per-class warmup alloc */
}

/* Return a counted-string block to its size-class freelist for reuse (or free
 * it outright if oversized). `len` is the string length the block was sized
 * for (len + 1 == the `need` counted_alloc rounded), so the class matches. */
static void counted_free(ds_rete_intern_t *t, char *ptr, size_t len)
{
    int c = size_class(len + 1);
    if (c < 0) { DS_FREE(ptr); return; }         /* oversized: exact free */
    struct free_node *n = (struct free_node *)ptr;
    n->next = t->freelist[c];
    t->freelist[c] = n;
}

/* Insert a not-yet-present string. Applies contract caps, grows or reuses
 * a tombstone as needed, allocates storage (slab when pinned-and-fits,
 * counted-recycling freelist for counted values, else an individual
 * allocation), and sets the entry's metadata.
 * pinned selects PIN_REF vs. a counted entry born at refcount 0. */
static ds_result_t insert_new(ds_rete_intern_t *t,
                              const char *str, size_t len, uint32_t h,
                              bool pinned, const char **out)
{
    /* Before any allocation, so the table is unmodified on breach. */
    if (t->contract_cap_n && t->n + 1 > t->contract_cap_n)
        return DS_ERR_R(DS_ERR_CONTRACT_BREACH,
                        "intern: contract intern_cap exceeded");
    if (t->contract_cap_bytes &&
        t->bytes_used + (uint64_t)len > t->contract_cap_bytes)
        return DS_ERR_R(DS_ERR_CONTRACT_BREACH,
                        "intern: contract intern_bytes_cap exceeded");

    /* [IERR.1.7]: the first-pump strings are pre-pinned before the freeze arms
     * (ds_engine, at has_pumped), so this refuses only a stray, with the table
     * as it was. */
    if (pinned && t->frozen)
        return DS_ERR_R(DS_ERR_INTERNAL,
                        "intern: pinned insert after freeze (IRET.1.4)");

    /* Grow first if the load (including tombstones) is high. */
    if ((t->n + t->tombstones) * 100u / t->cap >= MAX_LOAD_PCT) {
        if (t->rt_locked) {
            /* A tombstone may still be recyclable below. */
            if (t->tombstones == 0)
                return DS_ERR_R(DS_ERR_OOM,
                                "intern: table full (rt_locked; presz before locking)");
        } else {
            /* [LNLS.4.7]: a load that is mostly tombstones rehashes in place, so a
             * churn of distinct values does not grow the table. The next rehash
             * is then far enough off to keep an insert O(1) amortized. */
            ds_result_t r = (t->n * 100u / t->cap < MAX_LOAD_PCT / 2u)
                          ? rehash_into(t, t->cap)
                          : grow(t);
            if (r.status != DS_OK) return r;
        }
    }

    /* Find the insertion slot: first tombstone in the probe chain, else
     * the terminating empty slot. Bounded by cap to avoid looping a table
     * with no empty/tombstone slot (RT-locked full case). */
    size_t i     = h & (t->cap - 1);
    size_t reuse = SIZE_MAX;
    size_t steps = 0;
    while (t->buckets[i] && steps < t->cap) {
        if (t->buckets[i] == TOMBSTONE && reuse == SIZE_MAX) reuse = i;
        i = (i + 1) & (t->cap - 1);
        steps++;
    }
    if (t->buckets[i]) {                 /* no empty slot found */
        if (reuse != SIZE_MAX) i = reuse;
        else return DS_ERR_R(DS_ERR_OOM, "intern: table full");
    } else if (reuse != SIZE_MAX) {
        i = reuse;                       /* prefer the earlier tombstone */
    }

    /* Allocate storage for len bytes + NUL. */
    size_t need = len + 1;
    char  *p;
    uint8_t flags = 0;
    if (!pinned) {
        p = counted_alloc(t, need);
        if (!p) return DS_ERR_R(DS_ERR_OOM, "intern: string alloc");
        flags |= FLAG_HEAP;
    } else if (need > SLAB_CAPACITY) {
        /* Oversized pinned string: individual allocation, freed at destroy
         * (never released), so it is not recycled through the freelist. */
        p = DS_MALLOC(need);
        if (!p) return DS_ERR_R(DS_ERR_OOM, "intern: oversized string");
        flags |= FLAG_HEAP;
    } else {
        p = slab_alloc(&t->slab_head, need);
        if (!p) return DS_ERR_R(DS_ERR_OOM, "intern: slab");
    }
    memcpy(p, str, len);
    p[len] = '\0';

    if (t->buckets[i] == TOMBSTONE) t->tombstones--;
    t->buckets[i] = p;
    t->lens[i]    = len;
    t->refs[i]    = pinned ? PIN_REF : 0u;
    t->flags[i]   = flags;
    t->n++;
    if (pinned) t->n_pinned++;
    t->bytes_used += (uint64_t)len;
    *out = p;
    return DS_OK_R;
}

/* ---- Public API ---------------------------------------------------- */

ds_result_t ds_rete_intern_init(ds_rete_intern_t **out)
{
    if (!out) return DS_ERR_R(DS_ERR_INVAL, "intern_init: NULL out");

    ds_rete_intern_t *t = DS_CALLOC(1, sizeof(*t));
    if (!t) return DS_ERR_R(DS_ERR_OOM, "intern_init: table");

    t->buckets = DS_CALLOC(INIT_BUCKETS, sizeof(const char *));
    t->lens    = DS_CALLOC(INIT_BUCKETS, sizeof(size_t));
    t->refs    = DS_CALLOC(INIT_BUCKETS, sizeof(uint32_t));
    t->flags   = DS_CALLOC(INIT_BUCKETS, sizeof(uint8_t));
    if (!t->buckets || !t->lens || !t->refs || !t->flags) {
        DS_FREE(t->buckets); DS_FREE(t->lens);
        DS_FREE(t->refs);    DS_FREE(t->flags);
        DS_FREE(t);
        return DS_ERR_R(DS_ERR_OOM, "intern_init: buckets");
    }
    t->cap = INIT_BUCKETS;
    *out   = t;
    return DS_OK_R;
}

void ds_rete_intern_destroy(ds_rete_intern_t *intern)
{
    if (!intern) return;
    for (size_t i = 0; i < intern->cap; i++) {
        if (IS_LIVE(intern->buckets[i]) && (intern->flags[i] & FLAG_HEAP))
            DS_FREE((void *)intern->buckets[i]);
    }
    /* A block is in a live bucket or on a freelist, never both. */
    for (unsigned c = 0; c < N_FREE_CLASS; c++) {
        struct free_node *fn = intern->freelist[c];
        while (fn) { struct free_node *nx = fn->next; DS_FREE(fn); fn = nx; }
    }
    DS_FREE(intern->buckets);
    DS_FREE(intern->lens);
    DS_FREE(intern->refs);
    DS_FREE(intern->flags);
    struct slab *s = intern->slab_head;
    while (s) {
        struct slab *next = s->next;
        DS_FREE(s);
        s = next;
    }
    DS_FREE(intern);
}

ds_result_t ds_rete_intern(ds_rete_intern_t *intern,
                            const char       *str,
                            size_t            len,
                            const char      **out)
{
    if (!intern || !str || !out)
        return DS_ERR_R(DS_ERR_INVAL, "intern: NULL arg");

    uint32_t h   = hash_bytes(str, len);
    size_t   idx = lookup_idx(intern, str, len, h);
    if (idx != SIZE_MAX) {
        /* Promote a counted entry to pinned; leave an already-pinned one. */
        if (intern->refs[idx] != PIN_REF) intern->n_pinned++;
        intern->refs[idx] = PIN_REF;
        *out = intern->buckets[idx];
        return DS_OK_R;
    }
    return insert_new(intern, str, len, h, /*pinned=*/true, out);
}

ds_result_t ds_rete_intern_cstr(ds_rete_intern_t *intern,
                                 const char       *str,
                                 const char      **out)
{
    if (!str) return DS_ERR_R(DS_ERR_INVAL, "intern_cstr: NULL str");
    return ds_rete_intern(intern, str, strlen(str), out);
}

ds_result_t ds_rete_intern_value(ds_rete_intern_t *intern,
                                  const char       *str,
                                  size_t            len,
                                  const char      **out)
{
    if (!intern || !str || !out)
        return DS_ERR_R(DS_ERR_INVAL, "intern_value: NULL arg");

    uint32_t h   = hash_bytes(str, len);
    size_t   idx = lookup_idx(intern, str, len, h);
    if (idx != SIZE_MAX) {
        *out = intern->buckets[idx];
        return DS_OK_R;
    }
    return insert_new(intern, str, len, h, /*pinned=*/false, out);
}

ds_result_t ds_rete_intern_value_cstr(ds_rete_intern_t *intern,
                                       const char       *str,
                                       const char      **out)
{
    if (!str) return DS_ERR_R(DS_ERR_INVAL, "intern_value_cstr: NULL str");
    return ds_rete_intern_value(intern, str, strlen(str), out);
}

ds_result_t ds_rete_intern_find(const ds_rete_intern_t *intern,
                                 const char             *str,
                                 size_t                  len,
                                 const char            **out)
{
    if (!intern || !str || !out)
        return DS_ERR_R(DS_ERR_INVAL, "intern_find: NULL arg");
    size_t idx = lookup_idx(intern, str, len, hash_bytes(str, len));
    *out = (idx == SIZE_MAX) ? NULL : intern->buckets[idx];
    return DS_OK_R;
}

void ds_rete_intern_acquire_ptr(ds_rete_intern_t *intern,
                                 const char       *ptr,
                                 size_t            len)
{
    if (!intern || !ptr) return;
    size_t idx = lookup_ptr_idx(intern, ptr, len);
    if (idx == SIZE_MAX) return;
    if (intern->refs[idx] == PIN_REF) return;   /* pinned: no-op */
    intern->refs[idx]++;
}

void ds_rete_intern_release(ds_rete_intern_t *intern,
                             const char       *ptr,
                             size_t            len)
{
    if (!intern || !ptr) return;
    size_t idx = lookup_ptr_idx(intern, ptr, len);
    if (idx == SIZE_MAX) return;                /* non-interned (raw) value: no-op */
    if (intern->refs[idx] == PIN_REF) return;   /* pinned: no-op */
    /* [IERR.1.7]: past zero, with the entry left as it is. */
    if (intern->refs[idx] == 0) {
        if (!intern->tearing_down && intern->fault_fn != NULL)
            intern->fault_fn(intern->fault_ctx);
        return;
    }
    if (--intern->refs[idx] == 0) {
        if (intern->flags[idx] & FLAG_HEAP)
            counted_free(intern, (char *)intern->buckets[idx], intern->lens[idx]);
        intern->bytes_used -= (uint64_t)intern->lens[idx];
        intern->buckets[idx] = TOMBSTONE;
        intern->lens[idx]    = 0;
        intern->refs[idx]    = 0;
        intern->flags[idx]   = 0;
        intern->n--;
        intern->tombstones++;
    }
}

void ds_rete_intern_freeze(ds_rete_intern_t *intern)
{
    if (intern) intern->frozen = true;
}

void ds_rete_intern_set_fault_hook(ds_rete_intern_t *intern,
                                   ds_rete_intern_fault_fn fn, void *ctx)
{
    if (intern == NULL) return;
    intern->fault_fn  = fn;
    intern->fault_ctx = ctx;
}

void ds_rete_intern_begin_teardown(ds_rete_intern_t *intern)
{
    if (intern != NULL) intern->tearing_down = true;
}

ds_result_t ds_rete_intern_presz(ds_rete_intern_t *intern, size_t cap)
{
    if (!intern || cap == 0)
        return DS_ERR_R(DS_ERR_INVAL, "intern_presz: bad args");
    if (intern->cap >= cap) return DS_OK_R; /* already large enough */

    /* Round cap up to next power of two. */
    size_t new_cap = intern->cap ? intern->cap : INIT_BUCKETS;
    while (new_cap < cap) new_cap <<= 1;
    return rehash_into(intern, new_cap);
}

void ds_rete_intern_set_contract_caps(ds_rete_intern_t *intern,
                                       uint32_t          cap_n,
                                       uint32_t          cap_bytes)
{
    if (!intern) return;
    intern->contract_cap_n     = cap_n;
    intern->contract_cap_bytes = cap_bytes;
}

void ds_rete_intern_lock(ds_rete_intern_t *intern)
{
    if (intern) intern->rt_locked = true;
}

size_t ds_rete_intern_resize_count(const ds_rete_intern_t *intern)
{
    return intern ? intern->resize_count : 0;
}

void ds_rete_intern_mem(const ds_rete_intern_t *intern,
                        size_t                 *out_count,
                        size_t                 *out_string_bytes,
                        size_t                 *out_index_bytes)
{
    size_t count = 0, str_bytes = 0, idx_bytes = 0;
    if (intern != NULL) {
        count     = intern->n;
        str_bytes = (size_t) intern->bytes_used;
        if (intern->buckets != NULL)
            idx_bytes += intern->cap * sizeof(*intern->buckets);
        if (intern->lens != NULL)
            idx_bytes += intern->cap * sizeof(*intern->lens);
        if (intern->refs != NULL)
            idx_bytes += intern->cap * sizeof(*intern->refs);
        if (intern->flags != NULL)
            idx_bytes += intern->cap * sizeof(*intern->flags);
    }
    if (out_count)        *out_count        = count;
    if (out_string_bytes) *out_string_bytes = str_bytes;
    if (out_index_bytes)  *out_index_bytes  = idx_bytes;
}

bool ds_rete_intern_is_locked(const ds_rete_intern_t *intern)
{
    return intern && intern->rt_locked;
}

size_t ds_rete_intern_pinned_count(const ds_rete_intern_t *intern)
{
    return intern ? intern->n_pinned : 0;
}

size_t ds_rete_intern_counted_mallocs(const ds_rete_intern_t *intern)
{
    return intern ? intern->counted_mallocs : 0;
}
