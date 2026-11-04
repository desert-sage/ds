<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Rete network

## Reads

### Pause contract

The reads on this page change no engine state, and are answered between pumps. From inside a callback they follow [Re-entry](../conventions/handles.md#re-entry), which also holds inside their own callbacks.

Each returns `DS_ERR_STATE` under Re-entry and `DS_ERR_ENGINE_HALTED` under the [halt latch](../engine/lifecycle.md#halt-latch).

A string or array a callback on this page receives is valid only for the callback's duration.

*(libds.h: ds_engine_rete_network, Spec: [NDBG.1.1], [NDBG.1.2], [NDBG.1.3], [RARC.13.16], [RARC.13.17], Source: runtime/src/libds/engine_rete_adapters.c)*

## Justifiers

### `ds_engine_get_justifiers`

**`ds_result_t ds_engine_get_justifiers(ds_engine_t *engine, uint64_t fact_id, int64_t **out_timetags, char ***out_rule_names, uint32_t *out_count);`**

Lists the activations that logically support a fact.

`fact_id` is a fact's [id](../facts/reading.md#ds_fact_get_id). `*out_timetags` and `*out_rule_names` are caller-owned arrays of `*out_count` elements, each entry a [`timetag`](../callbacks/stream.md#firing-identity) and a copy of its rule's name. They are released with [`ds_free`](../conventions/handles.md#ds_free). A non-logical fact or an unknown `fact_id` returns `DS_OK` with a count of 0 and both arrays NULL.

It also returns `DS_ERR_INVAL` for a NULL `engine` or out-pointer, and `DS_ERR_OOM`. On every error, each out-pointer given holds NULL or 0. Truth maintenance is in [Truth maintenance](inv:internals:std:doc#engine/truth-maintenance).

*(libds.h: ds_engine_get_justifiers, Spec: [NDBG.5.1], [NDBG.5.2], [NDBG.7.1], Source: runtime/src/libds/engine_rete_adapters.c)*

## Network

### `ds_rete_node_cb_t`

**`typedef void (*ds_rete_node_cb_t)(const char *id, const char *kind, const char *label, const char *filter, uint32_t occupancy, bool is_negative, void *user);`**

The callback that receives one Rete node.

| Argument | Holds |
|---|---|
| `id` | the decimal text of the node's `node_id` in the artefact |
| `kind` | `"alpha"`, `"beta"` or `"terminal"` |
| `label` | an alpha's schema name, a terminal's rule name, or a beta's `"join"` |
| `filter` | an alpha's formatted test; a beta's `"join"` where it carries join tests; `""` if none |
| `occupancy` | the node's live fact or token count, and for a terminal its activations not yet fired; `UINT32_MAX` without `include_occupancy` |
| `is_negative` | whether the node is a NOT-beta |
| `user` | the call's `node_user` |

*(libds.h: ds_engine_rete_network, Spec: [NDBG.4.1])*

### `ds_rete_edge_cb_t`

**`typedef void (*ds_rete_edge_cb_t)(const char *from_id, const char *to_id, void *user);`**

The callback that receives one directed edge.

`from_id` and `to_id` are node `id`s. `user` is the call's `edge_user`.

*(libds.h: ds_engine_rete_network, Spec: [NDBG.4.1])*

### `ds_engine_rete_network`

**`ds_result_t ds_engine_rete_network(ds_engine_t *engine, const char *rule_filter, bool include_occupancy, ds_rete_node_cb_t node_cb, void *node_user, ds_rete_edge_cb_t edge_cb, void *edge_user);`**

Enumerates the Rete network: `node_cb` once per node, and `edge_cb` once per directed edge.

Every node comes before any edge: the alphas, then the betas, then the terminals. The order within each kind and among the edges is unspecified. A NULL `edge_cb` enumerates the nodes alone.

A non-NULL `rule_filter` names a rule, and restricts the enumeration to its terminal or terminals and every alpha and join upstream of them, with only the edges between two of those. A name no rule has enumerates nothing. `include_occupancy` populates `occupancy`.

It also returns `DS_ERR_INVAL` for a NULL `engine` or `node_cb`, with `edge_cb` set or not, and `DS_ERR_OOM` for `rule_filter`'s working set. The network is in [Rete network](inv:internals:std:doc#engine/rete-network).

*(libds.h: ds_engine_rete_network, Spec: [NDBG.4.1], [NDBG.7.1], Source: runtime/src/libds/engine_rete_adapters.c)*

## Match trace

### `ds_rete_trace_cb_t`

**`typedef void (*ds_rete_trace_cb_t)(const char *node_id, const char *node_kind, const char *result, const char *detail, void *user);`**

The callback that receives one alpha node's verdict on a fact.

`node_id` is the node's `id`, as [`ds_rete_node_cb_t`](#ds_rete_node_cb_t) gives it, and `node_kind` is its kind. `result` is the string `"passed"` or `"filtered"`. `detail` is a human-readable explanation, in DS-level names.

*(libds.h: ds_engine_rete_match_trace, Spec: [NDBG.4.2])*

### `ds_engine_rete_match_trace`

**`ds_result_t ds_engine_rete_match_trace(ds_engine_t *engine, uint64_t fact_id, ds_rete_trace_cb_t cb, void *user);`**

Traces a fact through the alpha nodes of its schema's dispatch: `cb` once per node.

An unknown `fact_id` returns `DS_OK` with no callbacks. It also returns `DS_ERR_INVAL` for a NULL `engine` or `cb`.

*(libds.h: ds_engine_rete_match_trace, Spec: [NDBG.4.2], [NDBG.7.1])*

## Refracted activations

### `ds_rete_refract_cb_t`

**`typedef void (*ds_rete_refract_cb_t)(const char *rule_name, const char *reason, const char *detail, const uint64_t *fact_ids, uint32_t fact_count, void *user);`**

The callback that receives one activation refraction blocks.

| Argument | Holds |
|---|---|
| `rule_name` | the rule's name |
| `reason` | `"refraction"` |
| `detail` | `"fired, and not re-created since"` |
| `fact_ids`, `fact_count` | the [ids](../facts/reading.md#ds_fact_get_id) of the facts the author's patterns bound, in pattern order |
| `user` | the call's `user` |

A fact the compiler synthesised, such as the clock tick or an `after` timer, is not listed, and an entry whose match holds only such facts has a `fact_count` of 0.

*(libds.h: ds_engine_refracted_activations, Spec: [NDBG.4.3])*

### `ds_engine_refracted_activations`

**`ds_result_t ds_engine_refracted_activations(ds_engine_t *engine, const char *rule_filter, ds_rete_refract_cb_t cb, void *user);`**

Lists every activation refraction blocks: `cb` once per entry of the terminals' refraction sets.

An entry stays listed until its activation is re-created. An unrelated assert or retract, or a pump boundary, removes nothing, and every fact an entry names is live. Entries come terminal by terminal in ordinal order, and within one terminal by their fact ids compared as a tuple, ascending. A non-NULL `rule_filter` restricts them to that rule's terminals.

It also returns `DS_ERR_INVAL` for a NULL `engine` or `cb`, and `DS_ERR_OOM`.

*(libds.h: ds_engine_refracted_activations, Spec: [NDBG.4.3], [NDBG.7.1], Source: runtime/src/libds/engine_rete_adapters.c)*

## Memory

### `ds_engine_mem_t`

**`typedef struct ds_engine_mem_s { size_t wm_fact_count; size_t wm_fact_bytes; size_t wm_index_bytes; size_t alpha_node_count; size_t alpha_match_count; size_t alpha_index_bytes; size_t beta_node_count; size_t beta_token_count; size_t beta_token_bytes; size_t beta_index_bytes; size_t intern_count; size_t intern_string_bytes; size_t intern_index_bytes; size_t pool_reserved_bytes; size_t total_bytes; } ds_engine_mem_t;`**

A byte-level breakdown of the engine's Rete structures.

| Member | Holds |
|---|---|
| `wm_fact_count` | live facts in working memory |
| `wm_fact_bytes` | fact headers and inline slot arrays |
| `wm_index_bytes` | working memory's hash buckets and occupancy arrays |
| `alpha_node_count` | alpha nodes |
| `alpha_match_count` | fact entries across alpha memories |
| `alpha_index_bytes` | alpha-memory hash tables |
| `beta_node_count` | beta nodes |
| `beta_token_count` | tokens across all left memories |
| `beta_token_bytes` | token headers and their fact-pointer arrays |
| `beta_index_bytes` | join index tables and child arrays |
| `intern_count` | live interned strings |
| `intern_string_bytes` | summed byte length of interned content |
| `intern_index_bytes` | the intern hash table |
| `pool_reserved_bytes` | `0` |
| `total_bytes` | the sum of the live `*_bytes` members above |

Each `*_bytes` member is the size of objects in use. `wm_fact_bytes` counts no interned content and no Json tree, and the alpha and beta `*_index_bytes` members cover the owning hash tables and never the facts they point to.

The counts of facts, nodes, alpha matches and beta tokens describe the program's logical state. The byte sizes and the intern members describe a runtime's own storage and are implementation-defined.

*(libds.h: ds_engine_mem_t, Spec: [NDBG.2.1])*

### `ds_engine_mem`

**`ds_result_t ds_engine_mem(ds_engine_t *engine, ds_engine_mem_t *out);`**

Fills `*out` with the engine's memory breakdown.

It also returns `DS_ERR_INVAL` for a NULL `engine` or `out`.

*(libds.h: ds_engine_mem, Source: runtime/src/libds/engine_rete_adapters.c)*
