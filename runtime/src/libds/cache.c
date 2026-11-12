/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/* cache.c — the engine-owned cache ([LSTO.4.7]). */

#include <string.h>

#include "cache.h"
#include "ds_alloc.h"

/* The oa key is a `char *`, hashed and compared by content. */
static uint64_t cache_hash(const void *key, void *ctx)
{
    (void) ctx;
    const char *s = *(const char *const *) key;
    uint64_t h = 1469598103934665603ULL;   /* FNV-1a 64 */
    for (; *s != '\0'; s++) {
        h ^= (unsigned char) *s;
        h *= 1099511628211ULL;
    }
    return h;
}

static bool cache_eq(const void *a, const void *b, void *ctx)
{
    (void) ctx;
    return strcmp(*(const char *const *) a, *(const char *const *) b) == 0;
}

static void cache_val_dtor(void *val, void *ctx)
{
    (void) ctx;
    ds_cache_entry_t *e = (ds_cache_entry_t *) val;
    DS_FREE(e->key);
    DS_FREE(e->value_json);
}

void ds_cache_init(ds_cache_t *c)
{
    memset(c, 0, sizeof(*c));
    ds_oa_init(&c->map, (uint16_t) sizeof(char *),
            (uint16_t) sizeof(ds_cache_entry_t), 0,
            cache_hash, cache_eq, cache_val_dtor, NULL);
}

void ds_cache_free(ds_cache_t *c)
{
    if (c == NULL) return;
    ds_oa_free(&c->map);
    c->total_value_bytes = 0;
    DS_FREE(c->sweep_scratch);
    c->sweep_scratch     = NULL;
    c->sweep_scratch_cap = 0;
}

static ds_result_t cache_reserve_scratch(ds_cache_t *c, uint32_t need)
{
    if (need <= c->sweep_scratch_cap) return DS_OK_R;
    uint32_t ncap = c->sweep_scratch_cap ? c->sweep_scratch_cap : 8u;
    while (ncap < need) ncap *= 2u;
    ds_cache_sweep_slot_t *ns =
        DS_REALLOC(c->sweep_scratch, (size_t) ncap * sizeof(*ns));
    if (ns == NULL) return DS_ERR_R(DS_ERR_OOM, "cache: sweep scratch");
    c->sweep_scratch     = ns;
    c->sweep_scratch_cap = ncap;
    return DS_OK_R;
}

void ds_cache_clear(ds_cache_t *c)
{
    ds_oa_clear(&c->map);
    c->total_value_bytes = 0;
}

void ds_cache_set_caps(ds_cache_t *c, uint32_t cap_keys, uint64_t cap_bytes)
{
    c->cap_keys  = cap_keys;
    c->cap_bytes = cap_bytes;
}

bool ds_cache_get(ds_cache_t *c, const char *key, uint64_t now_ns,
                  const char **out_value_json, bool *out_expired)
{
    *out_value_json = NULL;
    if (out_expired) *out_expired = false;
    if (key == NULL) return false;
    ds_cache_entry_t *e = (ds_cache_entry_t *) ds_oa_get(&c->map, &key);
    if (e == NULL) return false;
    if (e->ttl_deadline_ns != 0 && now_ns >= e->ttl_deadline_ns) {
        c->total_value_bytes -= e->value_bytes;
        ds_oa_del(&c->map, &key);
        if (out_expired) *out_expired = true;
        return false;
    }
    *out_value_json = e->value_json;
    return true;
}

/* An entry carries a deadline or a held TTL, never both: the caller passes one
   and 0 for the other. */
static ds_result_t cache_put(ds_cache_t *c, const char *key,
                             const char *value_json, uint64_t deadline,
                             uint64_t held_ttl_ns)
{
    c->breach_cap = DS_CAP_UNSPECIFIED;
    if (key == NULL) return DS_ERR_R(DS_ERR_INVAL, "cache: NULL key");
    const char *v = value_json ? value_json : "";
    size_t vbytes = strlen(v);

    ds_cache_entry_t *existing = (ds_cache_entry_t *) ds_oa_get(&c->map, &key);

    if (c->cap_keys != 0 && existing == NULL
        && (uint64_t) oa_len(&c->map) + 1u > c->cap_keys) {
        c->breach_cap      = DS_CAP_CACHE;
        c->breach_limit    = c->cap_keys;
        c->breach_observed = (uint64_t) oa_len(&c->map) + 1u;
        return DS_ERR_R(DS_ERR_CONTRACT_BREACH,
                        "cache: contract cache_cap (live keys) exceeded");
    }
    if (c->cap_bytes != 0) {
        uint64_t new_total = (uint64_t) c->total_value_bytes + vbytes
                           - (existing ? existing->value_bytes : 0);
        if (new_total > c->cap_bytes) {
            c->breach_cap      = DS_CAP_CACHE_BYTES;
            c->breach_limit    = c->cap_bytes;
            c->breach_observed = new_total;
            return DS_ERR_R(DS_ERR_CONTRACT_BREACH,
                            "cache: contract cache_bytes_cap exceeded");
        }
    }

    if (existing != NULL) {
        char *vcopy = DS_STRDUP(v);
        if (vcopy == NULL) return DS_ERR_R(DS_ERR_OOM, "cache: value dup");
        c->total_value_bytes -= existing->value_bytes;
        DS_FREE(existing->value_json);
        existing->value_json     = vcopy;
        existing->value_bytes    = vbytes;
        existing->ttl_deadline_ns = deadline;
        existing->held_ttl_ns    = held_ttl_ns;
        existing->set_seq        = c->next_set_seq++;
        c->total_value_bytes += vbytes;
        return DS_OK_R;
    }

    ds_result_t sr = cache_reserve_scratch(c, oa_len(&c->map) + 1u);
    if (sr.status != DS_OK) return sr;

    char *kcopy = DS_STRDUP(key);
    char *vcopy = DS_STRDUP(v);
    if (kcopy == NULL || vcopy == NULL) {
        DS_FREE(kcopy); DS_FREE(vcopy);
        return DS_ERR_R(DS_ERR_OOM, "cache: key/value dup");
    }
    ds_cache_entry_t *slot = NULL;
    bool is_new = false;
    ds_result_t r = ds_oa_put(&c->map, &kcopy, (void **) &slot, &is_new);
    if (r.status != DS_OK) { DS_FREE(kcopy); DS_FREE(vcopy); return r; }
    slot->key             = kcopy;
    slot->value_json      = vcopy;
    slot->value_bytes     = vbytes;
    slot->ttl_deadline_ns = deadline;
    slot->held_ttl_ns     = held_ttl_ns;
    slot->set_seq         = c->next_set_seq++;
    c->total_value_bytes += vbytes;
    return DS_OK_R;
}

ds_result_t ds_cache_set(ds_cache_t *c, const char *key,
                         const char *value_json, uint64_t ttl_ns,
                         uint64_t now_ns)
{
    /* [LTIM.1.1.5]: a deadline is never wrapped. */
    if (!ds_cache_ttl_in_range(now_ns, ttl_ns)) {
        c->breach_cap = DS_CAP_UNSPECIFIED;
        return DS_ERR_R(DS_ERR_TIME_RANGE,
                        "cache: the entry's deadline is outside the Time range");
    }
    uint64_t deadline = (ttl_ns != DS_CACHE_TTL_NONE) ? now_ns + ttl_ns : 0;
    return cache_put(c, key, value_json, deadline, 0);
}

ds_result_t ds_cache_set_deadline(ds_cache_t *c, const char *key,
                                  const char *value_json,
                                  uint64_t deadline_ns)
{
    return cache_put(c, key, value_json, deadline_ns, 0);
}

ds_result_t ds_cache_set_held(ds_cache_t *c, const char *key,
                              const char *value_json, uint64_t ttl_ns)
{
    return cache_put(c, key, value_json, 0, ttl_ns);
}

uint64_t ds_cache_held_ttl_max(const ds_cache_t *c)
{
    uint64_t max = 0;
    uint32_t n = oa_len(&c->map);
    for (uint32_t i = 0; i < n; i++) {
        const ds_cache_entry_t *e =
            (const ds_cache_entry_t *) ds_oa_val_at(&c->map, i);
        if (e != NULL && e->held_ttl_ns > max) max = e->held_ttl_ns;
    }
    return max;
}

void ds_cache_next_deadline(const ds_cache_t *c, uint64_t now_ns,
                            uint64_t *io_best, bool *io_has)
{
    uint32_t n = oa_len(&c->map);
    for (uint32_t i = 0; i < n; i++) {
        const ds_cache_entry_t *e =
            (const ds_cache_entry_t *) ds_oa_val_at(&c->map, i);
        if (e == NULL || e->ttl_deadline_ns <= now_ns) continue;
        if (!*io_has || e->ttl_deadline_ns < *io_best) {
            *io_best = e->ttl_deadline_ns;
            *io_has  = true;
        }
    }
}

void ds_cache_resolve_held(ds_cache_t *c, uint64_t now_ns)
{
    uint32_t n = oa_len(&c->map);
    for (uint32_t i = 0; i < n; i++) {
        ds_cache_entry_t *e = (ds_cache_entry_t *) ds_oa_val_at(&c->map, i);
        if (e == NULL || e->held_ttl_ns == 0) continue;
        e->ttl_deadline_ns = now_ns + e->held_ttl_ns;
        e->held_ttl_ns     = 0;
    }
}

bool ds_cache_delete(ds_cache_t *c, const char *key)
{
    if (key == NULL) return false;
    ds_cache_entry_t *e = (ds_cache_entry_t *) ds_oa_get(&c->map, &key);
    if (e == NULL) return false;
    c->total_value_bytes -= e->value_bytes;
    return ds_oa_del(&c->map, &key);
}

/* In-place heapsort by set_seq, which is unique, so the order is total. */
static void sweep_sift_down(ds_cache_sweep_slot_t *a, uint32_t i, uint32_t n)
{
    for (;;) {
        uint32_t big = i, l = 2u * i + 1u, r = 2u * i + 2u;
        if (l < n && a[l].set_seq > a[big].set_seq) big = l;
        if (r < n && a[r].set_seq > a[big].set_seq) big = r;
        if (big == i) return;
        ds_cache_sweep_slot_t t = a[i]; a[i] = a[big]; a[big] = t;
        i = big;
    }
}

static void sweep_sort_by_set_seq(ds_cache_sweep_slot_t *a, uint32_t n)
{
    if (n < 2) return;
    for (uint32_t i = n / 2u; i-- > 0; ) sweep_sift_down(a, i, n);
    for (uint32_t end = n - 1u; end > 0; end--) {
        ds_cache_sweep_slot_t t = a[0]; a[0] = a[end]; a[end] = t;
        sweep_sift_down(a, 0, end);
    }
}

uint32_t ds_cache_sweep_expired(ds_cache_t *c, uint64_t now_ns,
                                ds_cache_removed_fn on_removed, void *ctx)
{
    if (c == NULL) return 0;

    uint32_t k = 0;
    uint32_t n = oa_len(&c->map);
    for (uint32_t i = 0; i < n; i++) {
        ds_cache_entry_t *e = (ds_cache_entry_t *) ds_oa_val_at(&c->map, i);
        if (e == NULL || e->ttl_deadline_ns == 0 || now_ns < e->ttl_deadline_ns)
            continue;
        if (k >= c->sweep_scratch_cap) break;
        c->sweep_scratch[k].key     = e->key;
        c->sweep_scratch[k].set_seq = e->set_seq;
        k++;
    }

    /* [LDET.5.11]: the map's dense order is reshuffled by every swap-remove. */
    sweep_sort_by_set_seq(c->sweep_scratch, k);

    uint32_t removed = 0;
    for (uint32_t j = 0; j < k; j++) {
        char *kp = c->sweep_scratch[j].key;
        ds_cache_entry_t *e = (ds_cache_entry_t *) ds_oa_get(&c->map, &kp);
        if (e == NULL) continue;
        /* Taken from the val_dtor, so the key outlives its own removal. */
        char *key = e->key;
        char *val = e->value_json;
        e->key        = NULL;
        e->value_json = NULL;
        c->total_value_bytes -= e->value_bytes;
        ds_oa_del(&c->map, &key);
        removed++;
        if (on_removed) on_removed(ctx, key);
        DS_FREE(key);
        DS_FREE(val);
    }
    return removed;
}

const ds_cache_entry_t *ds_cache_entry_at(const ds_cache_t *c, uint32_t i)
{
    return (const ds_cache_entry_t *) ds_oa_val_at(&c->map, i);
}

ds_result_t ds_cache_clone(ds_cache_t *dst, const ds_cache_t *src)
{
    dst->cap_keys     = src->cap_keys;
    dst->cap_bytes    = src->cap_bytes;
    dst->next_set_seq = src->next_set_seq;
    uint32_t n = oa_len(&src->map);
    ds_result_t sr = cache_reserve_scratch(dst, n);
    if (sr.status != DS_OK) return sr;
    for (uint32_t i = 0; i < n; i++) {
        const ds_cache_entry_t *e =
            (const ds_cache_entry_t *) ds_oa_val_at(&src->map, i);
        char *kcopy = DS_STRDUP(e->key);
        char *vcopy = DS_STRDUP(e->value_json);
        if (kcopy == NULL || vcopy == NULL) {
            DS_FREE(kcopy); DS_FREE(vcopy);
            return DS_ERR_R(DS_ERR_OOM, "cache: clone dup");
        }
        ds_cache_entry_t *slot = NULL;
        bool is_new = false;
        ds_result_t r = ds_oa_put(&dst->map, &kcopy, (void **) &slot, &is_new);
        if (r.status != DS_OK) { DS_FREE(kcopy); DS_FREE(vcopy); return r; }
        slot->key             = kcopy;
        slot->value_json      = vcopy;
        slot->value_bytes     = e->value_bytes;
        slot->ttl_deadline_ns = e->ttl_deadline_ns;
        slot->held_ttl_ns     = e->held_ttl_ns;
        slot->set_seq         = e->set_seq;
        dst->total_value_bytes += e->value_bytes;
    }
    return DS_OK_R;
}
