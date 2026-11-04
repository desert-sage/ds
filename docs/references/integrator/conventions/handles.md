<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Handles and threading

## Types

### `ds_engine_t`

**`typedef struct ds_engine ds_engine_t;`**

An engine.

Integrator-owned: [`ds_engine_new`](../engine/lifecycle.md#ds_engine_new) or [`ds_engine_clone`](../engine/lifecycle.md#ds_engine_clone) creates it and [`ds_engine_free`](../engine/lifecycle.md#ds_engine_free) releases it.

*(libds.h: Opaque types, Spec: [IDAT.3.1])*

### `ds_fact_t`

**`typedef struct ds_fact ds_fact_t;`**

A fact in working memory.

Library-owned, and invalid once its fact [leaves working memory](../facts/reading.md#fact-accessor-results).

*(libds.h: Opaque types, Spec: [IDAT.3.1], [NFCT.6.2])*

### `ds_schema_t`

**`typedef struct ds_schema ds_schema_t;`**

A schema of an engine.

Library-owned: registered at load, found with [`ds_engine_schema_find`](../facts/schemas.md#ds_engine_schema_find), and valid for the engine's lifetime.

*(libds.h: Opaque types, Spec: [IDAT.3.1])*

### `ds_stream_ev_t`

**`typedef struct ds_stream_ev ds_stream_ev_t;`**

A stream event, as the stream callback receives it.

Library-owned, and valid during the stream callback only. Its layout is public: `libds.h` defines `struct ds_stream_ev`.

*(libds.h: Stream events, Spec: [IDAT.1.2], [IDAT.3.1])*

### `ds_json_t`

**`typedef struct ds_json ds_json_t;`**

A JSON tree.

Its owner depends on where it came from. A tree from [`ds_json_parse`](../facts/json.md#ds_json_parse), [`ds_json_clone`](../facts/json.md#ds_json_clone) or [`ds_json_new_*`](../facts/json.md#builder-results) is integrator-owned and released with [`ds_json_free`](../facts/json.md#ds_json_free). A tree delivered in a callback payload as `const ds_json_t *` is a library-owned borrow, valid for the callback's duration. A tree read from a fact's `Json` slot with [`ds_fact_get_slot`](../facts/reading.md#ds_fact_get_slot) is a library-owned borrow, valid until that fact is retracted, and the caller does not free or change it.

*(libds.h: Opaque types, Spec: [IDAT.3.1], [IDAT.3.3.1], [IDAT.3.3.8], [NFCT.6.2])*

### Opaque layout

The layouts of `ds_engine_t`, `ds_fact_t`, `ds_schema_t` and `ds_json_t` are private to libds.

`libds.h` declares each as a forward typedef. Pass pointers to them, and never dereference one.

*(libds.h: Opaque types, Spec: [IARC.1.8], [IDAT.3.3.1])*

## Ownership

### Owners

A library-owned value reaches the integrator as a non-owning pointer. An integrator-owned value is one the integrator both creates and frees.

```{warning}
Calling `free` on a library-owned pointer corrupts the heap.
```

*(Spec: [IDAT.3.2])*

### Arguments

An argument passed by pointer is a borrow: the callee reads it and does not retain the pointer past the call.

When a function takes ownership of an argument, its entry states it. [`ds_json_array_append`](../facts/json.md#ds_json_array_append) and [`ds_json_object_set`](../facts/json.md#ds_json_object_set) take ownership.

*(Spec: [IDAT.10.1])*

### Returned values

The caller owns a struct returned by value.

A pointer returned through an out-parameter is a borrow from libds state, unless it is a caller-owned handle, a [`ds_engine_t`](#ds_engine_t) or a [`ds_json_t`](#ds_json_t), or a raw buffer released with [`ds_free`](#ds_free). Its entry states which, and a borrow's lifetime.

*(libds.h: ds_engine_new, ds_engine_clone, ds_json_parse, ds_json_clone, Builders, ds_json_serialize, ds_engine_get_justifiers, Spec: [IDAT.10.2], [IDAT.3.1], [IALC.4.3])*

### Callback pointers

An opaque pointer a callback receives is a borrow. The callback does not free it, and does not retain it past the callback unless that callback's entry states the pointer stays valid.

*(Spec: [IDAT.10.3])*

### Engine binding

Each fact and schema belongs to exactly one engine. A [`ds_json_t`](#ds_json_t) tree belongs to none.

```{warning}
Passing an engine a fact or schema another engine handed out is undefined behaviour, whether or not this engine holds a schema of the same name. So is passing a fact handle whose fact is not live. libds does not check for either.
```

*(libds.h: ds_engine_assert, ds_engine_retract, Spec: [IDAT.1.6])*

### NULL arguments

A public function that documents a non-NULL argument returns `DS_ERR_INVAL` when given `NULL`.

*(Spec: [IDAT.10.5])*

### `ds_free`

**`void ds_free(void *p);`**

Releases a raw buffer that libds returned with ownership transfer.

`ds_free(NULL)` is a no-op. Release these buffers with `ds_free` and never with libc `free`; the allocator in use is in [Allocator](inv:internals:std:doc#overview/allocator). They are the whole set:

| Call | Buffers to release |
|---|---|
| [`ds_json_serialize`](../facts/json.md#ds_json_serialize) | the `*out` string |
| [`ds_engine_get_justifiers`](../introspection/network.md#ds_engine_get_justifiers) | the `*out_timetags` array; each `*out_rule_names[i]` string, then the `*out_rule_names` array |

`ds_free` releases no typed handle. [`ds_engine_free`](../engine/lifecycle.md#ds_engine_free) and [`ds_json_free`](../facts/json.md#ds_json_free) release the two a caller owns, and an engine's facts and schemas go with the engine.

*(libds.h: ds_free, Spec: [IALC.4.1], [IALC.4.2], [IALC.4.3])*

## Threading

### Integrator drives

libds starts no thread or timer, holds no thread-local state and does not sleep. Rules fire only inside a pump, and the integrator decides when a pump runs and supplies any thread management.

*(Spec: [NLFC.3.1], [NLFC.3.4], [IARC.1.10])*

### Calls on one engine

Serialise all `ds_engine_*` calls on one engine. libds takes no lock.

```{warning}
Concurrent `ds_engine_*` calls on one engine from several threads are undefined behaviour.
```

*(Spec: [NLFC.3.3])*

### Several engines

A process may hold any number of engines, each fully independent, in any threads. libds has no global state. Coordination across engines is the integrator's.

A public function that acts on an engine takes its handle, or a handle the engine owns, as its first argument. [`ds_engine_new`](../engine/lifecycle.md#ds_engine_new), [`ds_build_capabilities`](../engine/loading.md#ds_build_capabilities), the [`ds_json_*`](../facts/json.md) functions and [`ds_free`](#ds_free) act on none.

*(libds.h: ds_build_capabilities, Spec: [NLFC.1.3], [NLFC.3.3], [NLFC.4.1], [NLFC.4.2], [IARC.1.11])*

### Re-entry

From inside a callback, every `ds_engine_*` call on the engine that invoked it returns `DS_ERR_STATE` and does nothing, reads and [`ds_engine_free`](../engine/lifecycle.md#ds_engine_free) included.

This holds for a callback a pump invokes and for the visitor callback of an [enumerating read](../introspection/network.md#pause-contract). A call on a different engine is unaffected.

*(Spec: [RARC.13.16], [RARC.13.17], [NLFC.3.3], Source: runtime/src/libds/engine.h, runtime/src/libds/engine.c)*
