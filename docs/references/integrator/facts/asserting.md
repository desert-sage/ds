<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Asserting and retracting

## Assert

### `ds_engine_assert`

**`ds_result_t ds_engine_assert(ds_engine_t *engine, const ds_schema_t *schema, const ds_slot_value_t *values, uint32_t n_values, ds_fact_t **out_fact);`**

Asserts a fact into working memory.

`values` holds one [`ds_slot_value_t`](values.md#ds_slot_value_t) per slot, in schema declaration order, and `n_values` equals the schema's slot count. `schema` is one this engine handed out: [`ds_engine_schema_find`](schemas.md#ds_engine_schema_find), [`ds_engine_schema_at`](schemas.md#ds_engine_schema_at), or [`ds_fact_get_schema`](reading.md#ds_fact_get_schema) on one of its facts. Any other falls under [Engine binding](../conventions/handles.md#engine-binding). `out_fact` may be NULL. On success a non-NULL `out_fact` receives the engine-owned [`ds_fact_t`](../conventions/handles.md#ds_fact_t) wrapper, and on an error it is NULL.

The call [samples the clocks](../engine/clock.md#engine-clocks), and [emits `DS_EV_FACT_ASSERT`](../callbacks/stream.md#fact_assert). It fires nothing: what the fact activates waits for a [pump](../engine/pump.md#ds_engine_pump). An answer to a call is asserted [this way](../callbacks/call.md#answers).

Where a call breaks several refusals, the first of these that applies is returned. Each of them changes nothing and records nothing:

| Order | Code | Condition |
|---|---|---|
| 1 | `DS_ERR_INVAL` | `engine` is NULL |
| 2 | `DS_ERR_STATE` | [Re-entry](../conventions/handles.md#re-entry) |
| 3 | `DS_ERR_ENGINE_HALTED` | the engine has [halted](../engine/lifecycle.md#halt-latch) |
| 4 | `DS_ERR_INVAL` | `schema` is NULL |
| 5 | `DS_ERR_INVAL` | `n_values` is not the slot count, or `values` is NULL with `n_values` above 0 |
| 6 | `DS_ERR_SLOT_TYPE_MISMATCH` | a null, a root-null `DS_SLOT_JSON` included, in a slot not declared `T?`, or a kind or fact-ref target the slot does not take ([Slot value kinds](#slot-value-kinds)) |
| 6 | `DS_ERR_INVAL` | a pointer [Slot value kinds](#slot-value-kinds) requires to be non-NULL is NULL |
| 7 | `DS_ERR_NAN_REJECTED` | a NaN `Float` |
| 8 | `DS_ERR_ENCODING` | a `String` slot's text is not well-formed UTF-8 |
| 9 | `DS_ERR_TIME_RANGE` | a `DS_SLOT_TYPE_DATE` value outside days -106751 to 106751 from 1970-01-01 |
| 10 | `DS_ERR_INVAL` | a [`TimeZoneOffset`](#timezoneoffset-facts) fact the engine refuses |
| 11 | `DS_ERR_TIME_RANGE` | the fact's TTL deadline is outside the `Time` range |
| 12 | `DS_ERR_TIME_RANGE` | this is the engine's first sample, and it would put a [seeded](../callbacks/cache.md#ds_engine_cache_seed) entry's deadline outside the `Time` range |

A step that judges slot values judges every slot, in declaration order, before the next step begins. Row 6's two codes share a step, and the first slot it refuses decides.

A call that passes those can still return:

| Code | Condition |
|---|---|
| `DS_ERR_CONTRACT_BREACH` | a declared cap refuses the fact, and a [`DS_EV_BOUNDS_ERROR`](../callbacks/stream.md#bounds_error) follows: a `String` longer than its slot's `capacity`, a sample over a series' capacity, or, on the engine's first step, the program's `initial` cache items over a [cache bound](../callbacks/cache.md#ds_engine_set_cache_cap) |
| `DS_ERR_ENGINE_HALTED` | the assert's propagation raised an `EngineError` |
| a stream callback's status | the [first](../callbacks/contract.md#stream-callback-status) the callback returned during the call |
| `DS_ERR_OOM` | an allocation failed |

*(libds.h: ds_engine_assert, DS_ERR_NAN_REJECTED, Spec: [IDAT.1.6], [NFCT.2.1], [NFCT.2.2], [NFCT.2.5], [NFCT.2.11], [NFCT.8.1], [LSTR.8.5], [LSTR.11.3], [NCBK.1.5], [NCBK.2.9], [RFCS.6.7], Source: runtime/src/libds/wm.c, runtime/src/libds/engine_rete_adapters.c)*

### Slot value kinds

Each value's `kind` matches its slot's declared [`ds_slot_type_t`](schemas.md#ds_slot_type_t), with no implicit conversion. [NFCT.2.3](inv:specs:std:label#nfct-2-3) pairs each type with its kind and union member.

A slot declared `T?` also takes `DS_SLOT_NULL`. A `DS_SLOT_JSON` value whose root is `null` is the null, and is stored as `DS_SLOT_NULL`: a slot declared `Json?` takes it, and a slot declared `Json` refuses it. `v.bytes.data` is non-NULL when `len` is above 0. A negative value in a `DS_SLOT_TYPE_DURATION` slot is stored as `0`.

A slot typed by a unit or a dimension takes the slot's stored number, in the dimension's base unit and storage type, and a read of the slot gives that number. A host holding a number in the unit the slot names converts it with [`ds_schema_slot_to_stored`](schemas.md#ds_schema_slot_to_stored) before asserting it.

The integrator supplies a slot named `ts` like any other, as a `DS_SLOT_INT` of UTC nanoseconds. The engine does not fill it.

*(libds.h: ds_slot_desc_t, ds_schema_slot_to_stored, Spec: [NFCT.2.3], [NFCT.2.10], [NFCT.1.4.6], [LUNI.7.6], [LNUL.3.4], Source: runtime/src/libds/wm.c)*

### Value copies

Everything `values` points to is borrowed for the call, and the engine retains none of it.

| Member | The engine |
|---|---|
| `v.s` | copies the content into its interned string table |
| `v.json` | deep-clones the tree; the caller keeps [ownership](json.md#tree-ownership) and frees its own tree, also when the assert errors |
| `v.bytes` | copies `len` bytes from `data` |
| `v.ref` | borrows a live fact, which outlives the assert |

*(Spec: [NFCT.2.1], [NFCT.2.4])*

### Reassertion

An assert into a `logical` schema is an upsert on the schema's `DS_IDENTITY_KEY` slots.

An assert whose key values match a live fact replaces it, and one live fact exists per key. The comparison of key values is exact. With no key slot the schema holds one live fact, and the latest wins. With every slot a key, a tuple that already exists changes nothing in working memory and `out_fact` receives the existing wrapper; the assert still emits [`DS_EV_FACT_ASSERT`](../callbacks/stream.md#fact_assert) and is recorded.

On a `DS_IDENTITY_MUTABLE` numeric slot, a declared `tolerance` widens the comparison: a change within it changes nothing, and the live fact is kept. A TTL schema does not dedup: each assert is a distinct fact with its own [deadline](../engine/clock.md#mock-clock-calls). Slot equality is in [Rete network](inv:internals:std:doc#engine/rete-network), and fact identity in [Runtime architecture](inv:internals:std:doc#overview/runtime-architecture).

*(Spec: [NFCT.4.4.1], [NFCT.4.4.2], [NFCT.4.4.3], [NFCT.4.4.4], [RFCS.6.7])*

### `TimeZoneOffset` facts

A host assert of a `TimeZoneOffset` fact is refused when its `valid_from` is not before its `valid_until`, when its `offset_s` is outside -64800 to 64800, or when its `zone` is `"UTC"`.

A fact whose period overlaps another of its zone is admitted.

*(libds.h: ds_engine_assert, Spec: [LTIM.10.9])*

## External assert

### `ds_engine_assert_external`

**`ds_result_t ds_engine_assert_external(ds_engine_t *engine, const uint8_t *bytes, size_t len);`**

Asserts a [`FactExternal`](../callbacks/stream.md#factexternal-bridging), a published fact from another tier.

`bytes` and `len` are what [`action_publish`](../callbacks/stream.md#action_publish) carried on the sending engine, or what a [fact argument](../callbacks/call.md#fact-arguments) carried to the integrator. Accept one only from a tier the integration trusts. The encoding is in [Fact stream](inv:internals:std:doc#artefacts/fact-stream).

The engine checks `schema_hash`, decodes the message and resolves each nested fact reference, innermost first:

| The reference, against the live facts of its schema | Result |
|---|---|
| a live fact equal to the inlined copy | the slot refers to it, and nothing is asserted for the copy |
| no live fact with the same identity key | the copy is asserted, and the slot refers to it |
| a live fact with that key whose values differ | the whole message is refused |

Each reference is judged once, on working memory as the call finds it, before anything is asserted.

One of the call's own asserts can remove a fact a reference resolved to, a live fact or an inlined copy the call asserted: an [answer's retraction](../callbacks/call.md#answers) removes it, or a retraction that one cascades into. That refuses nothing and stops nothing. The slot refers to that fact: [`ds_fact_get_slot`](reading.md#ds_fact_get_slot) finds it has left working memory, and [`ds_fact_get_slot_ref_id`](reading.md#ds_fact_get_slot_ref_id) reads its id.

`KIND_NULL` in a fact-reference slot is a reference with no target, whether or not the slot is declared `T?`. What it resolves and what it equals are in [Fact stream](inv:internals:std:doc#artefacts/fact-stream). In a slot declared `T?` it is null. In any other the slot refers to no fact: `ds_fact_get_slot` reads `v.ref` as NULL, and `ds_fact_get_slot_ref_id` reads `0`.

The call is one input: it samples the clocks once, and every fact it asserts takes that sample as its assertion time. Each fact gets this engine's own `event_id`, and takes its lifetime from the receiving schema.

It refuses the whole message, asserting nothing, with:

| Code | Condition |
|---|---|
| `DS_ERR_PARSE` | the bytes are not a `FactExternal`, a text field holds U+0000 or is not well-formed UTF-8, a `Json` field's text does not parse, or its references nest deeper than 16 |
| `DS_ERR_SCHEMA_UNKNOWN` | it names a schema this program does not declare |
| `DS_ERR_SCHEMA_HASH_MISMATCH` | its `schema_hash` differs from this program's schema of that name |
| `DS_ERR_FACT_REF_CONFLICT` | a nested reference meets a live fact with the same key and different values |
| `DS_ERR_SLOT_TYPE_MISMATCH` | a field's kind is not its slot's, a reference names another schema than its slot's, `KIND_NULL` is in a slot not declared `T?` that holds no fact reference, or a `Json` field's document is `null` at its root, in a slot declared `Json?` too |
| `DS_ERR_NAN_REJECTED` | a `Float` field is a NaN |
| `DS_ERR_JSON_LIMIT` | a `Json` field is over one of its limits |
| `DS_ERR_TIME_RANGE` | a `Date` field is outside the `Date` range, a fact's TTL deadline would fall outside the `Time` range, or the call's sample would give a [seeded](../callbacks/cache.md#ds_engine_cache_seed) entry a deadline outside it |
| `DS_ERR_INVAL` | a [`TimeZoneOffset`](#timezoneoffset-facts) fact it holds is malformed |
| `DS_ERR_CONTRACT_BREACH` | a field's value is longer than its slot's `capacity` |

Each holds at any depth. Every row is judged before the first assert and before the call's sample, so a refused call is not a step, and it records no event, a `DS_EV_BOUNDS_ERROR` included. `schema_hash` leaves out `capacity`, and two tiers can declare one slot with different capacities.

Between its first assert and its last, only `DS_ERR_OOM` or `DS_ERR_ENGINE_HALTED`, from a halt an assert raises, can stop a delivery. The call returns that status and asserts nothing more, and a fact already asserted is not taken back. After `DS_ERR_OOM` those facts stay live and the engine runs on. After a halt, the engine's state is as [Halt latch](../engine/lifecycle.md#halt-latch) states.

It also returns:

| Code | Condition |
|---|---|
| `DS_ERR_INVAL` | `engine` is NULL, or `bytes` is NULL with `len` above 0 |
| `DS_ERR_STATE` | [Re-entry](../conventions/handles.md#re-entry) |
| `DS_ERR_ENGINE_HALTED` | the engine has already [halted](../engine/lifecycle.md#halt-latch) |
| `DS_ERR_CONTRACT_BREACH` | this is the engine's first step, and the program's `initial` items are over a declared cap: the step records its sample alone, and nothing is asserted |
| a stream callback's status | the [first](../callbacks/contract.md#stream-callback-status) the callback returned during the call; it stops nothing |

*(libds.h: ds_engine_assert_external, Spec: [NCBK.10.4], [RFCS.23.6], [RFCS.23.7], [RFCS.23.4], [RDSC.9.9], [LGRA.5.8.6], [LSTR.8.5], [LSTR.1.5], [LSTR.11.3], [NFCT.2.3], [LNUL.3.1], [LNUL.3.4], [LEXP.4.2], [LTIM.1.2.2], [LTIM.2.8.4], [LTIM.10.9], [RFCS.6.7], [RFCS.24.1], [NLFC.9.5], [NCBK.1.5], [NCBK.2.9], [LERR.1.4.7], [LGRA.24.3], [LCRS.6.2.4], Source: runtime/src/libds/rfcs/codec.c)*

## Retract

### `ds_engine_retract`

**`ds_result_t ds_engine_retract(ds_engine_t *engine, ds_fact_t *fact);`**

Removes a live fact from working memory.

`fact` is one [this engine](../conventions/handles.md#engine-binding) handed out and still live: from `ds_engine_assert`'s `out_fact`, [`ds_engine_fact_find`](reading.md#ds_engine_fact_find), a [`ds_engine_for_each_fact`](reading.md#ds_engine_for_each_fact) visitor, a stream event's payload, or a fact-ref slot read with [`ds_fact_get_slot`](reading.md#ds_fact_get_slot). On success the pointer is invalid for any further use.

The call [samples the clocks](../engine/clock.md#engine-clocks), and [emits `DS_EV_FACT_RETRACT`](../callbacks/stream.md#fact_retract).

Errors: `DS_ERR_INVAL` for a NULL `engine` or `fact`; `DS_ERR_STATE` under [Re-entry](../conventions/handles.md#re-entry); `DS_ERR_ENGINE_HALTED` when the engine had [halted](../engine/lifecycle.md#halt-latch) or the retraction's propagation raised an `EngineError`; the [first status](../callbacks/contract.md#stream-callback-status) a stream callback returned during the call.

*(libds.h: ds_engine_retract, Spec: [NFCT.3.1], [NFCT.3.2], [NFCT.3.3], [NFCT.3.4])*
