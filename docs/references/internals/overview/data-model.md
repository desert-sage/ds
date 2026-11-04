<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Data model

## Layout locations

Every public handle's layout is private to its owning module, in an internal header.

| Type | Layout |
|---|---|
| `ds_engine_t` | `struct ds_engine`, `runtime/src/libds/engine.h` |
| `ds_fact_t` | `struct ds_fact`, `runtime/src/libds/wm.h` |
| `ds_json_t` | `struct ds_json` and `ds_json_kv`, `runtime/src/libds/internal/json.h` |

`libds.h` declares each as a forward-declared struct. `ds_stream_ev_t` is not opaque: it is a library-owned callback payload, an inline tagged union whose layout `libds.h` states.

*(Spec: [IARC.1.8], [IARC.6.1], [IDAT.1.2], [IDAT.4.1], [IDAT.9.1])*

## Struct invariants

No libds struct layout contains a thread-aware type: no `_Atomic`, no `pthread_mutex_t`, no `stdatomic.h` type.

Struct access is serial, on the pump's call stack. Every struct instance belongs to exactly one `ds_engine_t`.

```{warning}
Passing a struct to an engine other than its own is undefined behaviour. libds does not detect it.
```

*(Spec: [IDAT.1.5], [IDAT.1.6])*

## Working-memory fact record

**`struct ds_fact`**

The working-memory fact record holds DS-level metadata, a pointer to the paired Rete fact (`rete_fact`, a `ds_rete_fact_t *`) and the fact's slot values in a trailing flexible array member.

The record is allocated on assertion by `ds_wm_fact_new`, as one zeroed `DS_CALLOC` of `sizeof(ds_fact_t) + n_slots * sizeof(ds_slot_value_t)`, and freed on retraction. The slots are unpacked once, at creation, in the `wm` assertion path. Slot access is array indexing, `f->slots[i]`, with no `NULL` check, no deferred materialisation and no allocation on read. `wm` tracks the records in a hash table keyed by the `rete_fact` pointer.

A retraction frees the record: a pointer to it held outside libds dangles once the retraction event crosses the recorder.

*(Spec: [IDAT.4.1], [IDAT.4.1.1], [IDAT.4.2], [IDAT.4.5], [IDAT.12.2], Source: runtime/src/libds/wm.c)*

## Rete fact

A Rete fact carries its identity, its schema, two timestamps, its truth-maintenance count and its slot values.

| Field | Holds |
|---|---|
| `id` | a value from the engine's monotonic counter, never reused within a session |
| `schema` | the schema the fact instantiates |
| `assert_ns` | the monotonic clock's sample when the fact entered working memory |
| `deadline_ns` | the expiry instant of a TTL fact; `0` is no deadline |
| `justif_count` | the number of active justifications; non-zero only on a `logical` fact |
| `slots` | one value per declared slot, stored inline, sized from the schema's slot count |

`id` is the key the network uses in alpha memories, token arrays and the truth-maintenance dependency table. When `justif_count` reaches zero, the truth-maintenance path retracts the fact.

*(Spec: [IRET.4.3], [IRET.4.4], [IRET.4.5], [IDAT.4.5])*

## `fact_id` and reassertion

`fact_id` is a per-engine counter, numbered as [RFCS.6.9] states, used for ordering, tracing and stream correlation.

It does not persist across engine restarts. Fact equality is stated under [Fact identity](runtime-architecture.md#fact-identity). A no-op reassertion of a `logical` fact keeps the existing `ds_fact_t`: same pointer, same `fact_id`. A reassertion that changes the fact is a retract and an assert: the old record is freed, a new one allocated, and the callbacks see the assert event before the retract event it causes. A consumer pairs a retract with the fact it removes by `fact_id`; the replacement shares the identity and is already live when the retract arrives.

*(Spec: [IDAT.4.3], [IDAT.4.4])*

## String interning

Each engine has one string-intern table.

| Entry | Holds | Lifetime |
|---|---|---|
| Pinned | schema, slot and rule names; compile-time literals | until engine destroy |
| Counted | `String` and `Bytes` slot values | reference-counted by the live committed fact slots holding the value; freed when the last holder retracts |

Every string entering working memory, from a compiled fact, an integrator-supplied slot value or a rule's `emit`, passes the intern boundary (`acquire` at commit), and the canonical pointer is stored in `ds_slot_value_t.v.s`. A fact's teardown releases its `String` and `Bytes` references (`release` at retract). Stored equality (alpha, beta and identity tests) is pointer comparison; value equality (`==`, no-op reassertion) compares content.

A holder that keeps a fact's string past the fact's life copies the bytes: a series or cache backend that samples a slot. A holder whose lifetime tracks the fact's takes an intern reference in lock step: the `ds_fact_t` record acquires when it copies the slot and releases when it is freed.

*(Spec: [IDAT.4.7], [IDAT.12.3])*

## Schema registry

Each engine has a schema registry at two layers.

| Layer | Structure |
|---|---|
| `schema` module | an engine-owned array plus a name-to-schema hash map; lookup by name is O(1) amortised, by schema pointer free |
| Rete network | populated at load from the artefact's schema atoms and its `AlphaNode` atoms; maps an interned schema name to its `ds_rete_schema_t *`, and a `uint16` schema ID to the flat array of that schema's alpha nodes |

Schema IDs are assigned consecutively from 0 while the network atoms (`AlphaNode`, `BetaNode`, `TerminalNode`) load; an engine holds at most 65535 schemas. On a fact assert or retract, the engine iterates the schema's alpha-node array and evaluates each node's tests against the fact.

*(Spec: [IDAT.5.2], [IRET.5])*

## Schema descriptor

A Rete schema descriptor holds a schema's interned name, a compact index for alpha dispatch, its slot count, its scope, its default TTL and a flat array of slot descriptors.

The default TTL is meaningful only under `ttl` scope, and zero otherwise. The scope is one of `plain`, `logical`, `ttl`, `activation` and `ambient`. `ambient` is libds's own value for a `logical` schema that carries the `ambient` modifier, `scope logical ambient`.

| Scope | Runtime semantics |
|---|---|
| `activation` | Every activation-scoped fact a firing emits is retracted when that activation ends: at the end of a synchronous RHS and on every async completion path. The sweep is keyed by (fact, activation) through the dependency table logical facts use, and is unconditional: it does not wait for a justification count to reach zero. |
| `ambient` | Working memory treats the fact as a `plain` one. The restriction of ambient emits to ambient-declared rules is checked at compile time and not at runtime. |

*(Spec: [IRET.4.2])*

## Slot descriptor

A Rete slot descriptor carries what the network needs about one slot of a schema.

| Field | Holds |
|---|---|
| name | the slot name, interned |
| index | its position in a fact's value array |
| type | the slot's value kind |
| tolerance | `0.0` for an exact match; a positive value only on a mutable slot of kind `Int` or `Float`, in the slot's base unit when it is unit-typed |
| sampled | whether absorbed samples are forwarded for the slot |
| retained | whether the slot's value is retained |
| identity_role | `KEY` or `MUTABLE` on a `logical` schema; unspecified otherwise |

Identity is a declared role per slot, never inferred from position. `identity_role` mirrors the artefact's `IdentityRole`.

*(Spec: [IRET.4.1], [LUNI.7.4])*

## Activations

An activation is a rule together with the facts that matched it: a firing owed and not yet made.

It is internal to libds. An activation holds a non-owning borrow of each fact it matched and of its rule, which a registry outliving every activation owns. The agenda module allocates an activation when the network completes a match, and frees it when the match ends: a fact it matched is retracted, or a test it passed stops admitting it. Firing does not free it. A fired activation leaves the agenda and stays on its terminal's activation list with `fired = true` until its match ends, so an activation outlives the pump that made it. The `fired` flag is the activation's [refraction](../engine/agenda-and-actions.md#refraction) state and no ordering key; the [comparator](runtime-architecture.md#agenda-and-conflict-resolver) orders it by its rule's ordinal, then its entry order.

*(Spec: [IDAT.6.2], [IDAT.6.2.1], [IRET.11])*

## Stream event layout

A stream event is held as a tagged union inline in `ds_stream_ev_t`: no `void *` payload and no flexible array member.

A consumer switches on `kind` and reads the matching member (`ev->p.fact_assert.fact`, `ev->p.rule_fire_end.dur_ns`). Each event is one allocation sized by the largest variant, and events flow through the recorder without accumulating. The layout is the in-memory shape only; what each kind means is [LFST.6]'s.

*(Spec: [IDAT.7.2], [IDAT.7.3], [IDAT.12.4])*

## Engine state

**`struct ds_engine`**

The engine struct holds its owned registries directly and its sub-module state pointers inline.

It contains no synchronisation primitive: the pump is its only writer.

*(Spec: [IDAT.9])*
