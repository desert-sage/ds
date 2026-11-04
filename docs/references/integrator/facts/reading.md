<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Reading working memory

## Working memory

### `ds_engine_fact_count`

**`ds_result_t ds_engine_fact_count(ds_engine_t *engine, size_t *out);`**

Reads the number of live facts in working memory.

It does not count a fact the lowering creates for its own use, an `after` clause's timer or capture fact, or the clock tick.

Errors: `DS_ERR_INVAL` for a NULL `engine` or `out`; `DS_ERR_STATE` under [Re-entry](../conventions/handles.md#re-entry); `DS_ERR_ENGINE_HALTED`.

*(libds.h: ds_engine_fact_count, Spec: [NFCT.6.1], [NFCT.6.3], Source: runtime/src/libds/wm.c)*

### `ds_engine_fact_find`

**`ds_result_t ds_engine_fact_find(ds_engine_t *engine, uint64_t fact_id, ds_fact_t **out);`**

Looks up the live fact whose id ([`ds_fact_get_id`](#ds_fact_get_id)) is `fact_id`.

On a hit, the status is `DS_OK` and `*out` is a pointer valid until the fact is retracted.

Errors: `DS_ERR_NOT_FOUND` when no live fact has the id, with `*out` NULL: it was retracted, expired or superseded, or was never assigned. `DS_ERR_INVAL` for a NULL `engine` or `out`; `DS_ERR_STATE` under [Re-entry](../conventions/handles.md#re-entry); `DS_ERR_ENGINE_HALTED`.

*(libds.h: ds_engine_fact_find, Spec: [NFCT.6.4], Source: runtime/src/libds/wm.c)*

### `ds_fact_visitor_fn`

**`typedef ds_result_t (*ds_fact_visitor_fn)(const ds_fact_t *fact, void *user);`**

The callback `ds_engine_for_each_fact` invokes once per fact.

`fact` is borrowed and read-only, and the visitor reads it with the `ds_fact_get_*` calls. `DS_OK_R` continues the walk, and any other result ends it. `ds_engine_*` calls from inside it follow [Re-entry](../conventions/handles.md#re-entry).

*(libds.h: ds_fact_visitor_fn, ds_engine_for_each_fact)*

### `ds_engine_for_each_fact`

**`ds_result_t ds_engine_for_each_fact(ds_engine_t *engine, const ds_schema_t *schema, ds_fact_visitor_fn visitor, void *user);`**

Visits every live fact in working memory, optionally of one schema.

With a non-NULL `schema`, only facts whose schema pointer equals it are visited. `user` passes through to every visitor call. The walk skips the facts [`ds_engine_fact_count`](#ds_engine_fact_count) does not count. The order is unspecified.

It returns `DS_OK` after a complete walk, or the visitor's result on an abort. Errors: `DS_ERR_INVAL` for a NULL `engine` or `visitor`; `DS_ERR_STATE` under [Re-entry](../conventions/handles.md#re-entry); `DS_ERR_ENGINE_HALTED`.

*(libds.h: ds_engine_for_each_fact, Spec: [NFCT.6.3], Source: runtime/src/libds/wm.c)*

## Fact accessors

### Fact accessor results

The `ds_fact_get_*` calls read a [`ds_fact_t`](../conventions/handles.md#ds_fact_t) handle.

Each returns `DS_OK` with its out-pointers set, `DS_ERR_INVAL` for a NULL `fact` or `out`, and `DS_ERR_NOT_FOUND` for an index out of range. A pointer it returns is valid until the fact is retracted, unless its entry states otherwise.

```{warning}
A `ds_fact_t *` held across pumps is left dangling when the fact is retracted: by [`ds_engine_retract`](asserting.md#ds_engine_retract), a TTL sweep or the end of a [logical justifier](../introspection/network.md#ds_engine_get_justifiers). [`DS_EV_FACT_RETRACT`](../callbacks/stream.md#fact_retract) reports the retraction.
```

*(libds.h: Per-fact accessors, Spec: [NFCT.6.2])*

### Handle reads after a halt

After an `EngineError` or a failed load sets the [halt latch](../engine/lifecycle.md#halt-latch), each `ds_fact_get_*` and [`ds_schema_get_*`](schemas.md#schema-accessors) call returns `DS_ERR_ENGINE_HALTED`, whenever the handle was taken.

Its one window is the call that raised the `EngineError`: a read is answered until that call has delivered the `EngineError` or returned, so the records it delivers ahead of the `EngineError` can be read.

*(libds.h: Per-fact accessors, Schema introspection, Spec: [NCBK.2.9], Source: runtime/src/libds/engine.h)*

### `ds_fact_get_id`

**`ds_result_t ds_fact_get_id(const ds_fact_t *fact, uint64_t *out);`**

Reads the fact's engine-assigned monotonic id.

A fact asserted again after a retract gets a new id, and an id is never reassigned.

*(libds.h: ds_fact_get_id, ds_engine_fact_find, Spec: [NFCT.6.2])*

### `ds_fact_get_schema`

**`ds_result_t ds_fact_get_schema(const ds_fact_t *fact, const ds_schema_t **out);`**

Reads the schema this fact instantiates.

`*out` is a borrow, valid for the engine's lifetime.

*(libds.h: ds_fact_get_schema)*

### `ds_fact_get_asserted_ns`

**`ds_result_t ds_fact_get_asserted_ns(const ds_fact_t *fact, uint64_t *out);`**

Reads the engine clock at the moment the fact was asserted, the [sample](../engine/clock.md#engine-clocks) on the monotonic clock.

*(libds.h: ds_fact_get_asserted_ns, Spec: [NFCT.6.2])*

### `ds_fact_get_ttl_deadline_ns`

**`ds_result_t ds_fact_get_ttl_deadline_ns(const ds_fact_t *fact, uint64_t *out);`**

Reads the fact's TTL sweep deadline, the engine clock at assert plus the fact's TTL window.

It is `0` for a fact of a `DS_SCHEMA_LIFECYCLE_LOGICAL` schema, and for a fact the engine is not tracking under TTL. When the deadline is computed is on [Mock clock calls](../engine/clock.md#mock-clock-calls), and TTL expiry in [Runtime architecture](inv:internals:std:doc#overview/runtime-architecture).

*(libds.h: ds_fact_get_ttl_deadline_ns, Spec: [NFCT.6.2])*

### `ds_fact_get_slot_count`

**`ds_result_t ds_fact_get_slot_count(const ds_fact_t *fact, uint32_t *out);`**

Reads the number of slots on the fact, its schema's slot count.

*(libds.h: ds_fact_get_slot_count)*

### `ds_fact_get_slot`

**`ds_result_t ds_fact_get_slot(const ds_fact_t *fact, uint32_t index, const char **out_name, ds_slot_value_t *out_value);`**

Reads slot `index`: its schema-declared name and its [value](values.md#ds_slot_value_t).

`*out_name` is an engine-owned borrow, valid for the engine's lifetime. Either out-pointer may be NULL, and both NULL returns `DS_ERR_INVAL`.

A `DS_SLOT_FACT_REF` slot is resolved when it is read: `v.ref` is the referenced fact while it is in working memory, and NULL once it has left. The kind stays `DS_SLOT_FACT_REF`, and a null slot is `DS_SLOT_NULL`.

*(libds.h: ds_fact_get_slot, Spec: [NFCT.6.2], Source: runtime/src/libds/wm.c)*

### `ds_fact_get_slot_ref_id`

**`ds_result_t ds_fact_get_slot_ref_id(const ds_fact_t *fact, uint32_t index, uint64_t *out);`**

Reads the id of the fact slot `index` refers to, whether or not that fact is still in working memory.

`*out` is `0` when the slot refers to no fact. It also returns `DS_ERR_INVAL` when the slot does not hold a fact reference, a null slot included.

*(libds.h: ds_fact_get_slot_ref_id)*
