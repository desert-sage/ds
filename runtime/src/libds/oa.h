/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * oa.h — the open-addressing map ([IRET.28]): dense-backed, tombstone-free,
 * backward-shift.
 *
 * Iteration order is the dense-vector order (append on insert, last-into-hole on
 * delete), a pure function of the op sequence, independent of cap, pointer values and
 * platform. Locked mode makes a would-grow put fail (DS_ERR_RT_UNSAFE). Not thread-safe.
 */
#ifndef LIBDS2_OA_H
#define LIBDS2_OA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "libds.h"

#ifdef __cplusplus
extern "C" {
#endif

/* The table applies oa_mix64, so hash need not be perfectly distributed. eq is only
 * called on a 32-bit mixed-hash match. val_dtor runs when an entry leaves the map, not
 * on grow, which relocates values by memcpy. */
typedef uint64_t (*oa_hash_fn)(const void *key, void *ctx);
typedef bool     (*oa_eq_fn)  (const void *a,   const void *b, void *ctx);
typedef void     (*oa_dtor_fn)(void *val, void *ctx);

typedef struct {
    /* probe array: 0 = empty, else (dense_index + 1). length == cap. */
    uint32_t  *slots;
    /* dense, packed [0,len): */
    uint8_t   *dkeys;   /* cap*ksize, [0,len) live */
    uint8_t   *dvals;   /* cap*vsize, [0,len) live */
    uint32_t  *dhash;   /* cap: low 32 of the MIXED hash (probe-compare, rehash) */
    uint32_t  *dslot;   /* cap: dense_index -> slot index (O(1) swap-remove) */

    uint32_t   cap;     /* slots length; 0 or a power of two (dcap == cap) */
    uint32_t   len;     /* live entries; INVARIANT len < cap when cap > 0 */

    uint16_t   ksize, vsize;
    uint8_t    load_pct;       /* grow threshold percent; 0 in ds_oa_init => 70 */
    bool       locked;         /* RT: forbid grow (put fails instead) */

    oa_hash_fn hash;
    oa_eq_fn   eq;
    oa_dtor_fn val_dtor;
    void      *ctx;            /* passed to hash/eq/val_dtor */
} oa_t;

#define OA_NONE     UINT32_MAX
#define OA_INIT_CAP 8u

/* The splitmix64 finalizer. */
static inline uint64_t oa_mix64(uint64_t h)
{
    h ^= h >> 30; h *= 0xbf58476d1ce4e5b9ULL;
    h ^= h >> 27; h *= 0x94d049bb133111ebULL;
    h ^= h >> 31; return h;
}

/* Allocates nothing. load_pct == 0 => 70. */
void        ds_oa_init(oa_t *t, uint16_t ksize, uint16_t vsize, uint8_t load_pct,
                    oa_hash_fn hash, oa_eq_fn eq, oa_dtor_fn val_dtor,
                    void *ctx);

/* So n live entries fit without a later grow. DS_ERR_OOM leaves the table unchanged. */
ds_result_t ds_oa_reserve(oa_t *t, uint32_t n);

void        ds_oa_clear(oa_t *t);   /* keeps cap */
void        ds_oa_free(oa_t *t);

/* The pointer is invalidated by the next put/del/reserve/clear/free on t. */
void       *ds_oa_get(const oa_t *t, const void *key);

/* Insert-or-find. A created value slot is zero-initialized. out_val and is_new may be
 * NULL. DS_ERR_OOM and DS_ERR_RT_UNSAFE leave the table unchanged. */
ds_result_t ds_oa_put(oa_t *t, const void *key, void **out_val, bool *is_new);

/* False if absent. */
bool        ds_oa_del(oa_t *t, const void *key);

static inline uint32_t oa_len(const oa_t *t) { return t->len; }
void       *ds_oa_val_at(const oa_t *t, uint32_t i);   /* i in [0,len) */
void       *ds_oa_key_at(const oa_t *t, uint32_t i);   /* i in [0,len) */
/* A swap-remove during iteration reorders; delete high->low to be safe. */

/* Allocated bytes; 0 when unallocated. */
size_t      ds_oa_footprint_bytes(const oa_t *t);

/* Transforms one source key's or value's bytes for the destination. Signals errors
 * through `ctx`. */
typedef void (*oa_remap_fn)(const void *src_entry, void *dst_entry, void *ctx);

/* [IARC.11.1], [IRET.28.10]: every live entry, in src's dense order. `dst` is
 * ds_oa_init'd empty with the same ksize and vsize, and its own callbacks. A NULL remap
 * copies verbatim. Every entry is re-put, so the hash is recomputed from the remapped
 * key; the value slot handed to remap_val is zero-initialized. DS_ERR_OOM leaves dst
 * partly built, for the caller to free. DS_ERR_INVAL on a size mismatch. */
ds_result_t ds_oa_clone_into(oa_t *dst, const oa_t *src,
                          oa_remap_fn remap_key, oa_remap_fn remap_val,
                          void *ctx);

#ifndef NDEBUG
/* Asserts the representation invariant, RI-1..RI-7; tests call it after every op. */
void        ds_oa_check(const oa_t *t);
#endif

/* ---- oa_list: the multimap value adapter ----------------------------- */

#define OA_LIST_INLINE 8
typedef struct {
    void    *inl[OA_LIST_INLINE];
    void   **heap;        /* NULL until overflow; owned */
    uint32_t n;           /* total element count */
    uint32_t heap_cap;
} oa_list;                /* memcpy-relocatable */

/* Under rt_locked, fails (DS_ERR_RT_UNSAFE) rather than grow. */
ds_result_t ds_oa_list_add(oa_list *l, void *elem, bool rt_locked);
/* A swap-remove. False if absent. */
bool        ds_oa_list_remove(oa_list *l, void *elem);
uint32_t    ds_oa_list_len(const oa_list *l);
void       *ds_oa_list_at(const oa_list *l, uint32_t i);
/* The val_dtor for every multimap table. */
void        ds_oa_list_free(void *val, void *ctx);

#ifdef __cplusplus
}
#endif

#endif /* LIBDS2_OA_H */
