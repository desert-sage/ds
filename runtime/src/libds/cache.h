/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * cache.h — the engine-owned cache ([LSTO.4.7]): a string-keyed store of
 * JSON-text values, read engine-locally. Backed by oa_t, whose iteration order
 * the Checkpoint snapshot relies on. Not thread-safe.
 */
#ifndef LIBDS2_CACHE_H
#define LIBDS2_CACHE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "libds.h"
#include "oa.h"

/* `key` and `value_json` are owned. `ttl_deadline_ns` is the absolute expiry
   (0 = no expiry). `held_ttl_ns` is a seed's TTL held as a duration until the
   engine's first sample fixes its deadline ([NLFC.9.4]). `set_seq` is the write
   counter at the key's last set, [LDET.5.11]'s order. */
typedef struct ds_cache_entry {
    char    *key;
    char    *value_json;
    size_t   value_bytes;
    uint64_t ttl_deadline_ns;
    uint64_t held_ttl_ns;
    uint64_t set_seq;
} ds_cache_entry_t;

/* One expired entry, as the sweep collects it. `key` is the entry's own string. */
typedef struct ds_cache_sweep_slot {
    char    *key;
    uint64_t set_seq;
} ds_cache_sweep_slot_t;

typedef struct ds_cache {
    oa_t     map;                 /* key: char* (owned); value: ds_cache_entry_t */
    size_t   total_value_bytes;   /* Σ value_bytes over live entries */
    /* Capacity caps ([RTCT.6.8]); 0 = unbounded (default / no .dsrt). */
    uint32_t cap_keys;
    uint64_t cap_bytes;
    /* The breach the last set refused, for the caller to record ([NCBK.2.8]).
       breach_cap is DS_CAP_UNSPECIFIED unless that call was refused on a cap. */
    ds_cap_name_t breach_cap;
    uint64_t      breach_limit;
    uint64_t      breach_observed;
    /* The sweep's scratch is kept at least the live key count, so the sweep
       allocates nothing. */
    uint64_t               next_set_seq;
    ds_cache_sweep_slot_t *sweep_scratch;
    uint32_t               sweep_scratch_cap;
} ds_cache_t;

void        ds_cache_init(ds_cache_t *c);
void        ds_cache_free(ds_cache_t *c);

/* 0 = unbounded. */
void        ds_cache_set_caps(ds_cache_t *c, uint32_t cap_keys,
                              uint64_t cap_bytes);

/* Read `key` as of `now_ns`. On a live hit sets *out_value_json (borrowed, valid
   until the next cache mutation) and returns true. An entry past its deadline is
   evicted here too, a backstop for the pump-entry sweep ([NSTG.2.4.2]), and
   `out_expired` (nullable) reports it so the caller can fire the removal
   notification. */
bool        ds_cache_get(ds_cache_t *c, const char *key, uint64_t now_ns,
                         const char **out_value_json, bool *out_expired);

/* `ttl_ns` 0 = no expiry. A breach of a cap returns DS_ERR_CONTRACT_BREACH with
   the cache unchanged and the breach fields set. `value_json` is copied. */
ds_result_t ds_cache_set(ds_cache_t *c, const char *key,
                         const char *value_json, uint64_t ttl_ns,
                         uint64_t now_ns);

/* ds_cache_set with the absolute deadline given (0 = no expiry): a replayed seed
   carries the deadline the recorded cache held ([RFCS.26.2]). */
ds_result_t ds_cache_set_deadline(ds_cache_t *c, const char *key,
                                  const char *value_json,
                                  uint64_t deadline_ns);

/* ds_cache_set for a seed made before the engine's first sample ([NLFC.9.4]):
   `ttl_ns` is held as a duration until ds_cache_resolve_held. */
ds_result_t ds_cache_set_held(ds_cache_t *c, const char *key,
                              const char *value_json, uint64_t ttl_ns);

/* [NLFC.9.4]: at the engine's first sample, each held TTL becomes the deadline
   `now_ns` + that TTL. The caller has checked each against the `Time` range
   first ([NLFC.9.5]). */
void        ds_cache_resolve_held(ds_cache_t *c, uint64_t now_ns);

/* The largest TTL an entry holds as a duration, 0 when none does. */
uint64_t    ds_cache_held_ttl_max(const ds_cache_t *c);

/* [NLFC.2.5]: lowers `*io_best`, setting `*io_has`, to the earliest entry expiry
   later than `now_ns`. A TTL still held as a duration has no instant yet. */
void        ds_cache_next_deadline(const ds_cache_t *c, uint64_t now_ns,
                                   uint64_t *io_best, bool *io_has);

/* [LTIM.1.1.5]: whether `now_ns` + `ttl_ns` is a `Time`. A TTL of 0 is no
   deadline. */
static inline bool ds_cache_ttl_in_range(uint64_t now_ns, uint64_t ttl_ns)
{
    if (ttl_ns == 0) return true;
    return now_ns <= (uint64_t) INT64_MAX
        && ttl_ns <= (uint64_t) INT64_MAX - now_ns;
}

/* Returns true if an entry was removed. */
bool        ds_cache_delete(ds_cache_t *c, const char *key);

/* Reported once per entry the sweep removes, after it has left the map. `key` is
   borrowed for the call. */
typedef void (*ds_cache_removed_fn)(void *ctx, const char *key);

/* [NSTG.2.4.2]: remove every entry whose deadline has passed as of `now_ns`, in
   the order their keys were last set ([LDET.5.11]), calling `on_removed`
   (nullable) for each. Returns the number removed. Allocates nothing. */
uint32_t    ds_cache_sweep_expired(ds_cache_t *c, uint64_t now_ns,
                                   ds_cache_removed_fn on_removed, void *ctx);

/* Stored entries, including any past a deadline not yet swept. */
static inline uint32_t ds_cache_key_count(const ds_cache_t *c)
{
    return oa_len(&c->map);
}

/* i in [0, ds_cache_key_count). Returns the entry (borrowed). */
const ds_cache_entry_t *ds_cache_entry_at(const ds_cache_t *c, uint32_t i);

/* Deep-copy `src` into `dst` (freshly ds_cache_init'd) ([IARC.11.1]). A TTL still
   held stays held ([NLFC.9.4]). On DS_ERR_OOM, `dst` is partly built and the
   caller frees it. */
ds_result_t ds_cache_clone(ds_cache_t *dst, const ds_cache_t *src);

/* Keeps caps. */
void        ds_cache_clear(ds_cache_t *c);

#endif  /* LIBDS2_CACHE_H */
