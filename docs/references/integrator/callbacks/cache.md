<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Cache

## Engine-owned cache

The engine holds the cache, and a `cached()` read answers from it with no callback.

A `cache` or `cache_delete` write mutates the engine's cache before a persistence callback mirrors it to an external store. With neither callback registered, the cache is volatile and fully working.

*(libds.h: Cache persistence callbacks, Spec: [NCBK.7.1], [NCBK.7.3], [NSTG.1.1], [NSTG.2.1.1], [NSTG.2.2.1], [IDSP.7.4], [IDSP.7.5])*

## Non-finite values

A non-finite `Float` in the value of a rule's `cache` write is a `NOT_REPRESENTABLE` [trap](stream.md#ds_trap_kind_t): the activation is abandoned at the write, the cache is not touched, and `ds.json.nonfinite_total{verb}` counts it. `ds_engine_pump` does not return `DS_ERR_JSON_NONFINITE`.

A value over a `Json` limit, and a deadline outside the `Time` range, are the same trap.

*(libds.h: DS_ERR_JSON_NONFINITE, Spec: [NCBK.7.5], [LDET.3.2.7], [NERR.6])*

## Persistence callbacks

### `ds_cache_set_cb_t`

**`typedef ds_result_t (*ds_cache_set_cb_t)(ds_engine_t *engine, const ds_cache_write_t *write, void *user);`**

The callback that mirrors a `cache` write.

`write` is its [payload](#ds_cache_write_t).

*(libds.h: ds_cache_set_cb_t, Spec: [NCBK.1.1], [NCBK.7.4], [NSTG.2.3])*

### `DS_CACHE_TTL_NONE`

**`#define DS_CACHE_TTL_NONE UINT64_C(0)`**

The cache `ttl_ns` that sets no expiry.

An entry with it lives until a `cache_delete`. It applies to cache TTLs only.

*(libds.h: DS_CACHE_TTL_NONE, Spec: [NSTG.2.3.2])*

### `ds_cache_delete_cb_t`

**`typedef ds_result_t (*ds_cache_delete_cb_t)(ds_engine_t *engine, const ds_cache_removal_t *removal, void *user);`**

The callback that mirrors a removal: the key has left the engine's cache.

Both reasons call it. Make it idempotent: a removal can name a key the store does not hold, and that returns `DS_OK`, not `DS_ERR_STORAGE_NOT_FOUND`.

*(libds.h: ds_cache_delete_cb_t, Spec: [NCBK.7.4], [NSTG.2.4], [NSTG.2.4.1])*

### `ds_cache_write_t`

**`typedef struct ds_cache_write { const char *key; const ds_json_t *value; uint64_t ttl_ns; } ds_cache_write_t;`**

The payload of the set callback.

| Member | Meaning |
|---|---|
| `key` | the cache key written |
| `value` | the value, as a parsed JSON tree |
| `ttl_ns` | the entry's lifetime in nanoseconds, or [`DS_CACHE_TTL_NONE`](#ds_cache_ttl_none); the callback mirrors it into the store |

The struct, `key` and the tree are borrowed for the callback, and libds frees the tree after it returns.

*(libds.h: ds_cache_write_t, Spec: [NCBK.7.4], [NSTG.2.3], [NSTG.2.3.1], [NSTG.2.3.2], [NSTG.6.1], [IDSP.7.8])*

### `ds_cache_removal_t`

**`typedef struct ds_cache_removal { const char *key; ds_cache_removal_reason_t reason; } ds_cache_removal_t;`**

The payload of the delete callback.

`key` is borrowed for the callback.

*(libds.h: ds_cache_removal_t, Spec: [NCBK.7.4], [NSTG.6.1])*

### `ds_cache_removal_reason_t`

**`typedef enum ds_cache_removal_reason { DS_CACHE_REMOVED_DELETE = 0, DS_CACHE_REMOVED_TTL = 1 } ds_cache_removal_reason_t;`**

Why an entry left the cache.

| Member | Meaning |
|---|---|
| `DS_CACHE_REMOVED_DELETE` | an explicit `cache_delete` |
| `DS_CACHE_REMOVED_TTL` | the entry's TTL deadline passed |

A store drops the row for either.

*(libds.h: ds_cache_removal_reason_t, Spec: [NSTG.2.4], [NSTG.2.4.3], [NSTG.9.1])*

### `DS_CACHE_CB_ABI_VERSION`

**`#define DS_CACHE_CB_ABI_VERSION 3u`**

The cache callback ABI this header declares.

Pass it to `ds_engine_cache_callbacks`.

*(libds.h: DS_CACHE_CB_ABI_VERSION, Spec: [NCBK.7.2])*

### `ds_engine_cache_callbacks`

**`ds_result_t ds_engine_cache_callbacks(ds_engine_t *engine, uint32_t abi_version, ds_cache_set_cb_t set_cb, ds_cache_delete_cb_t delete_cb, void *user);`**

Registers both persistence callbacks, with one shared `user`.

Either callback may be NULL, and that write is not persisted. Pass both NULL to detach persistence. A second call replaces the registration.

Errors: `DS_ERR_BACKEND_ABI_VERSION` for an `abi_version` other than `DS_CACHE_CB_ABI_VERSION`, which registers nothing; `DS_ERR_INVAL`; `DS_ERR_STATE`; `DS_ERR_ENGINE_HALTED`.

*(libds.h: ds_engine_cache_callbacks, Spec: [NCBK.7.2], [NCBK.7.3], [NSTG.2.1.2], [NCBK.2.9], [RARC.13.16])*

### Persistence failure

A status other than `DS_OK` from a persistence callback propagates unchanged through [`ds_engine_pump`](../engine/pump.md#ds_engine_pump).

The engine's cache keeps the write or removal.

*(libds.h: Cache persistence callbacks, Spec: [NCBK.7.5], [NSTG.2.3.3], [NSTG.2.4.1], [NSTG.7.3], [IDSP.7.9])*

## Expiry

The engine removes an expired entry in a sweep at pump entry, and fires the delete callback for each with `DS_CACHE_REMOVED_TTL`. A TTL expiry emits no stream event.

The order at pump entry is the fact sweep, the cache sweep, the run. Both sweeps read one clock value. A `cached()` read that finds an expired entry removes it and fires the delete callback too.

*(Spec: [NSTG.2.4.2], [IDSP.7.6])*

## Bounds

### `ds_engine_set_cache_cap`

**`ds_result_t ds_engine_set_cache_cap(ds_engine_t *engine, uint32_t cap_keys, uint64_t cap_bytes);`**

Sets the cache's bounds: `cap_keys` on its live keys and `cap_bytes` on its total value bytes.

`0` leaves a bound unset. Call it before the artefact is [loaded](../engine/loading.md#ds_engine_load_dsc), and before any seed the bound is to count. A later call binds the writes and seeds that follow and removes nothing. A cache past a new bound keeps its entries, and refuses each write of a new key until it is back under the bound.

A rule's write past a bound changes nothing, records a `DS_EV_BOUNDS_ERROR` and stops the firing at the write, and the pump returns `DS_ERR_CONTRACT_BREACH`. A replaying engine is given the bounds the recording one had, a later change included, between the same two inputs.

Errors: `DS_ERR_INVAL`, `DS_ERR_STATE`, `DS_ERR_ENGINE_HALTED`.

*(libds.h: ds_engine_set_cache_cap, Spec: [NSTG.2.6.1], [LSTO.4.7.5], [NCBK.2.9])*

## Restore

### `ds_engine_cache_seed`

**`ds_result_t ds_engine_cache_seed(ds_engine_t *engine, const char *key, const ds_json_t *value, uint64_t ttl_ns);`**

Stores `key` and `value` directly in the engine's cache before the run.

Call it before the engine's first stream event, once per entry, to restore what the persistence callbacks saved. It overwrites an existing key. It emits no stream event and fires no persistence callback, and a recording carries the entry in its prelude. The caller keeps ownership of `value`, and the engine stores its canonical serialization: byte-identical to the same value written by a rule. A seeded key keeps its value over the ruleset's `initial` block.

A non-zero `ttl_ns` counts from the engine's first [sample](../engine/clock.md#engine-clocks), which sets the deadline to that sample plus `ttl_ns`.

`DS_ERR_INVAL` is returned for a NULL `engine`, `key` or `value`. After that, the first of these that applies is returned, and the cache is unchanged:

1. `DS_ERR_ENGINE_HALTED`: the engine is [halted](../engine/lifecycle.md#halt-latch).
2. `DS_ERR_STATE`: the engine has emitted a stream event.
3. `DS_ERR_TIME_RANGE`: `ttl_ns` is greater than `INT64_MAX`.
4. `DS_ERR_ENCODING`: `key` is not well-formed UTF-8.
5. `DS_ERR_CONTRACT_BREACH`: storing the seed would breach a bound [`ds_engine_set_cache_cap`](#ds_engine_set_cache_cap) sets.

`DS_ERR_OOM` is returned at whichever step needs the allocation, and leaves the cache unchanged.

Where the first sample would put a seed's deadline outside the `Time` range, the call that would take that sample returns `DS_ERR_TIME_RANGE` and changes nothing, and the seeding window stays open.

*(libds.h: ds_engine_cache_seed, Spec: [NLFC.9.1], [NLFC.9.2], [NLFC.9.3], [NLFC.9.4], [NLFC.9.5], [NLFC.9.6], [NSTG.9.1], [NSTG.9.2], [NSTG.2.6.1])*
