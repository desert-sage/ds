<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Series backends

## Backend vtable

### ds_series_backend_vtable_t

`ds_series_backend_vtable_t` is the whole contract between libds's engine and one of its seven series backends.

It is declared in libds's internal series header. The engine calls only the entry points it holds and knows nothing of a backend beyond its header fields. `instance_new`, `instance_free`, `update` and `query` are required. `evict_stale`, `query_with_value`, `instance_clone` and `query_at` may be NULL.

*(Spec: [ISBK.1], Source: runtime/src/libds/series/backend.h)*

### Header fields

The header identifies a backend and the aggregations it serves.

| Field | Holds |
|---|---|
| `abi_version` | `DS_SERIES_BACKEND_ABI_VERSION`; it states how much of the vtable past the required entry points is present |
| `backend_name`, `backend_version` | the backend's identity strings |
| `atom_field` | the field number of the atom of one of the seven backings, the number a `.dsc` carries the series' atom under ([Backend atoms](../artefacts/dsc-format.md#backend-atoms)); the loader keys a declaration to its backend by it, with no translation |
| `supported_aggs` | a bitmask over the `ds_series_agg_kind_t` ordinals, built with `DS_SERIES_AGG_BIT(k)` |

The checks libds makes on these fields are [Registration checks](#registration-checks).

*(Spec: [ISBK.1], [ISBK.1.1], Source: runtime/src/libds/series/backend.h)*

### ds_series_agg_kind_t

`ds_series_agg_kind_t` is the aggregation ordinal a backend serves and a query selects, `DS_SERIES_AGG_AVG` … `DS_SERIES_AGG_PERCENTILE`.

It is declared in libds's internal series header with the vtable, and mirrors `specs/registry/series_agg.ebnf` name for name and value for value.

*(Spec: [ISBK.1.1], [ISBK.3.2], Source: runtime/src/libds/series/backend.h)*

### instance_new

**`ds_result_t (*instance_new)(const ds_series_decl_t *decl, void **out_state)`**

Allocates one key's backend state from a resolved [series declaration](#ds_series_decl_t).

Required. The state goes into `*out_state` and is opaque to libds.

*(Spec: [ISBK.1.2])*

### instance_free

**`void (*instance_free)(void *state)`**

Releases one key's backend state.

Required. libds calls it at engine teardown ([Init and teardown order](../overview/libds-modules.md#init-and-teardown-order)).

*(Spec: [ISBK.1.2])*

### update

**`ds_result_t (*update)(void *state, const ds_slot_value_t *value, uint64_t ts_ns)`**

Absorbs one sample.

Required. `value->kind` matches the slot's schema type. A backend refuses a kind it does not support with `DS_ERR_INVAL`. When the engine absorbs is [Series declaration](../engine/lowering.md#series-declaration).

*(Spec: [ISBK.1.3])*

### query

**`ds_result_t (*query)(void *state, ds_series_agg_kind_t agg, uint64_t window_ns, ds_slot_value_t *out_value)`**

Answers one aggregation as of the last absorbed sample.

Required. `agg` selects the aggregation. `window_ns` is the declared series window, and a backend may ignore it. The backend sets `out_value->kind`; a count is `DS_SLOT_INT`.

*(Spec: [ISBK.1], [ISBK.1.4])*

### evict_stale

**`void (*evict_stale)(void *state, uint64_t now_ns)`**

Drops the samples that have left the window at `now_ns`.

Optional. libds calls it at the step's clock in the series sweep after each pump's absorption, and before every rule read of the backing. A backing whose window is a trimmed sequence of samples carries it: the ring buffer, the FIFO deque and the monotonic deque. One with no window, or whose `query_at` already answers at the clock, leaves it NULL.

*(Spec: [ISBK.1], [ISBK.1.5], [ISBK.3.5])*

### query_with_value

**`ds_result_t (*query_with_value)(void *state, ds_series_agg_kind_t agg, uint64_t window_ns, const ds_slot_value_t *lookup_value, uint32_t k_param, ds_slot_value_t *out_value)`**

Answers an aggregation a rule reads with a value, exact over the window: `DS_SERIES_AGG_COUNT_OF` and `DS_SERIES_AGG_CONTAINS`, whose value is the one looked up, and `DS_SERIES_AGG_PERCENTILE`, whose value is the percentile.

Optional. libds passes `k_param` as `0` on every call. A read that no declared backing with this hook can serve answers the aggregation's cold value and stashes `DS_ERR_SERIES_NO_BACKING` for the pump to return.

*(Spec: [ISBK.1.6])*

### instance_clone

**`ds_result_t (*instance_clone)(const void *state, void **out_state)`**

Deep-copies one key's backend state into `*out_state`, verbatim, every owned buffer and string included.

Optional, and every built-in backend carries it. The copy is the caller's, and `instance_free` releases it independently of the source. An allocation failure returns `DS_ERR_OOM` and leaves the source unchanged. A NULL hook means the backend's state cannot be cloned. The engine-wide copy that calls it is [Engine clone](../overview/libds-modules.md#engine-clone).

*(Spec: [ISBK.1], [ISBK.1.9], [ISBK.3.5])*

### query_at

**`ds_result_t (*query_at)(void *state, ds_series_agg_kind_t agg, uint64_t window_ns, uint64_t now_ns, ds_slot_value_t *out_value)`**

Answers one aggregation as of an explicit monotonic-clock instant, `now_ns`, and not as of the last absorbed sample.

Optional. It applies the read-only discount and the open-interval extrapolation of the signal aggregations, read after a quiet gap. Every rule read of a backing that carries it goes through it, at the step's held sample. The hook requires `now_ns` no earlier than the row's last absorb, and libds raises `now_ns` to that absorb when a sample stamped ahead of the clock is the newest. With the hook NULL, a read lands as of the last absorb, through [`query`](#query).

*(Spec: [ISBK.1], [ISBK.1.8])*

## Series declaration

### ds_series_decl_t

`ds_series_decl_t` is the resolved series declaration `instance_new` receives.

| Field | Holds |
|---|---|
| `schema_name` | the series' schema |
| `slot_name` | the series' slot |
| `identity_slot_name` | the identity slot; `""` for `by: none` |
| `window_ns` | the window; `0` for an unwindowed series |
| `persist_ns` | `0` for a live-only series |
| `atom_field` | the backing atom's field number, as in the [header](#header-fields) |
| `element_type` | a `ds_series_element_type_t`; `UNSPECIFIED` (`0`) where the backing reads none. Read by the ring buffer, the FIFO deque and the monotonic deque |
| `max_samples` | `0` for the backend's default. The ring buffer's cap, the reservoir's `k` |
| `time_model`, `gap_policy` | a `ds_series_time_model_t` and a `ds_series_gap_policy_t`. Read by the numeric integral alone, and `0` for every other backing |

The strings are borrowed for the `instance_new` call only: a backend copies a string before retaining it. The mode-specific fields are shared across backends, and a backend dispatches on its own `atom_field` and reads only the fields meaningful to it.

*(Spec: [ISBK.2.1], [ISBK.2.2], Source: runtime/src/libds/series/backend.h)*

### ds_series_element_type_t

`ds_series_element_type_t` is a declaration's element type.

It is declared in libds's internal series header with the vtable, and mirrors `SeriesElementType` in `proto/series_backend_ring_buffer.proto` member for member and value for value, `UNSPECIFIED` included.

*(Spec: [ISBK.2.1], proto: series_backend_ring_buffer.proto)*

## Registration

### Reference implementation

The ring-buffer backend is the vtable's reference implementation: every other backend's vtable has its shape.

It is `runtime/src/libds/series/ring_buffer.c` and `runtime/src/libds/series/ring_buffer_backend.c`, compiled into `libds.a`. libds registers it with the other six when it constructs an engine ([Init and teardown order](../overview/libds-modules.md#init-and-teardown-order)).

*(Spec: [ISBK.3.1])*

### Registration checks

libds validates every backend in a registration before it registers any, so a bad entry registers nothing.

Each backend is checked in this order, and the first check it fails is the answer:

| Check | Failure |
|---|---|
| the vtable is present | `DS_ERR_INVAL` |
| `abi_version` equals `DS_SERIES_BACKEND_ABI_VERSION` | `DS_ERR_BACKEND_ABI_VERSION` |
| `atom_field` names one of the seven backings | `DS_ERR_BACKEND_BAD_MAGIC` |
| `supported_aggs` is a subset of the backing's [static aggregation set](#the-seven-backends) | `DS_ERR_BACKEND_BAD_AGGS` |
| the four required entry points are present | `DS_ERR_INVAL` |

Once every entry passes, a backend for a backing already registered, or two for one backing in the same registration, is `DS_ERR_STATE`, and nothing registers: each backing has exactly one backend. A failed registration fails engine construction ([Init and teardown order](../overview/libds-modules.md#init-and-teardown-order)).

*(Spec: [ISBK.1.1], [ISBK.1.7], [ISBK.3.2], [ISBK.3.3], [ISBK.3.4])*

### The seven backends

Each backing's static aggregation set, and the optional entry points its backend carries, are [ISBK.3.5](inv:specs:std:label#isbk-3-5).

A static set bounds what a backend may serve. Which backing serves an aggregation in a program is [Series declaration](../engine/lowering.md#series-declaration).

*(Spec: [ISBK.3.2], [ISBK.3.5])*
