<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Facts and values

## Asserting and retracting

### `assert`

**`assert(schema: string, slots: Record<string, SlotValue>): Fact;`**

Asserts a fact through [`ds_engine_assert`](inv:integrator:std:doc#facts/asserting), and returns its [`Fact`](#fact).

`schema` is the schema's own name, as [`ds_engine_schema_find`](inv:integrator:std:doc#facts/schemas) takes it. `slots` holds each slot by name, in any order, with a value as [Slot values](#slot-values) states. An omitted slot declared `T?` is null. The fact's TTL is its schema's.

| Throws | Condition |
|---|---|
| [`DsError`](errors.md#dserror), `DS_ERR_ENGINE_HALTED` | the engine is halted |
| `DsError`, `DS_ERR_SCHEMA_UNKNOWN` | the engine has no schema named `schema` |
| `DsError`, `DS_ERR_OOM` | an allocation for the call fails |
| `DsError`, the parse's status | [`ds_json_parse`](inv:integrator:std:doc#facts/json) refuses a `Json` slot's text |
| `DsError`, as [Slot values](#slot-values) and [`replayStream`](recording.md#replaystream) state | a `String` or fact-reference value they refuse |
| `DsError`, the call's status | [`ds_engine_assert`](inv:integrator:std:doc#facts/asserting) returns a failure |
| `TypeError` | `schema` is not a string, or holds U+0000; `slots` is not an object, or is an array; a slot not declared `T?` is omitted; a key names no slot; a value is not one its slot takes |

On a halted engine, each `Json` slot given as text is judged in declaration order, and the first refusal is thrown ahead of `DS_ERR_ENGINE_HALTED`.

```javascript statement
const fact = engine.assert("Reading", { id: "a", level: 1.5, n: 1n, label: "x", ok: true, ts: 0n });
console.log(fact.read().slots.level);
engine.retract(fact);
```

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c, Spec: [LSTR.8.5])*

### `assertExternal`

**`assertExternal(data: Uint8Array | FactArgument): void;`**

Asserts a `FactExternal` through [`ds_engine_assert_external`](inv:integrator:std:doc#facts/asserting).

`data` is the bytes, or a [`FactArgument`](#factargument), whose `external` is taken. Any other value throws `TypeError`. It returns no fact.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js)*

### `FactArgument`

**`export type FactArgument = { schema: string; assertedAt: bigint | null; external: Uint8Array; };`**

A fact passed to a call: a [`ds_encoded_fact_t`](inv:integrator:std:doc#facts/values), as a plain object.

`external` is a copy of its `FactExternal` bytes. `assertedAt` is `null` when the wall clock had no value as the fact entered working memory.

*(Source: bindings/js/types/types.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c)*

### `retract`

**`retract(fact: Fact | Int64): void;`**

Retracts a live fact through [`ds_engine_retract`](inv:integrator:std:doc#facts/asserting).

| Throws | Condition |
|---|---|
| [`DsError`](errors.md#dserror), `DS_ERR_FACT_INVALID` | a `Fact` that is dead, or of another engine |
| `DsError`, `DS_ERR_NOT_FOUND` | an id with no live fact |
| `TypeError` | an id that is negative, above 64 bits, or not an [`Int64`](#int64) |

An id is found by walking working memory through `ds_engine_for_each_fact`, and follows [Re-entry](inv:integrator:std:doc#conventions/handles) inside a callback.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c)*

## Unit conversion

### `slotToStored`

**`slotToStored(schema: string, slot: string, value: bigint | number): bigint | number;`**

Converts a number in the unit a slot names to the number the slot stores, through [`ds_schema_slot_to_stored`](inv:integrator:std:doc#facts/schemas).

`schema` is the schema's own name, as [`assert`](#assert) takes it, and `slot` the slot's name. An `Int` value is a `BigInt` or a safe-integer `Number`, and a `Float` value a `Number`. An `Int` result is a `BigInt`, and a `Float` result a `Number`. A `Boolean`, and a `Number` that is no safe integer on a slot stored as an integer, reach libds with their own kind, which it refuses by kind.

| Throws | Condition |
|---|---|
| [`DsError`](errors.md#dserror), `DS_ERR_SCHEMA_UNKNOWN` | the engine has no schema named `schema` |
| `DsError`, `DS_ERR_SLOT_UNKNOWN` | the schema has no slot named `slot` |
| `DsError`, `DS_ERR_SLOT_TYPE_MISMATCH` | a `BigInt` outside `int64` |
| `DsError`, the call's status | `ds_schema_slot_to_stored` returns a failure |
| `TypeError` | `schema` or `slot` is not a string; `value` is not a `BigInt`, a `Number` or a `Boolean` |

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c)*

### `slotFromStored`

**`slotFromStored(schema: string, slot: string, value: bigint | number): bigint | number;`**

Converts a number a slot stores to a number in the unit the slot names, through [`ds_schema_slot_from_stored`](inv:integrator:std:doc#facts/schemas).

It takes its arguments, and throws, as [`slotToStored`](#slottostored) does.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c)*

## Reading working memory

### Reads inside a callback

[`factCount`](#factcount), [`facts`](#facts) and [`factById`](#factbyid) follow [Re-entry](inv:integrator:std:doc#conventions/handles) inside a callback.

*(Source: bindings/js/src/ds.c)*

### `factCount`

**`get factCount(): number;`**

The number of facts in working memory, read by [`ds_engine_fact_count`](inv:integrator:std:doc#facts/reading).

*(Source: bindings/js/types/bind.d.ts, bindings/js/src/ds.c)*

### `facts`

**`facts({ schema }?: { schema?: string | null; }): Fact[];`**

Returns a snapshot of the live facts, or of one schema's, walked by [`ds_engine_for_each_fact`](inv:integrator:std:doc#facts/reading).

`schema` is the schema's own name, as [`ds_engine_schema_find`](inv:integrator:std:doc#facts/schemas) takes it. `schema` absent or `null` is every schema. A name the engine has no schema by throws a [`DsError`](errors.md#dserror) with `DS_ERR_SCHEMA_UNKNOWN`. A name holding U+0000, or a `schema` of another type, throws `TypeError`. The order is unspecified.

```javascript statement
for (const fact of engine.facts({ schema: "Reading" })) {
  console.log(fact.id);
}
```

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c, Spec: [NFCT.6.3])*

### `factById`

**`factById(id: Int64): Fact | null;`**

Returns the live fact with this id, or `null`, walking working memory through [`ds_engine_for_each_fact`](inv:integrator:std:doc#facts/reading).

An id that is negative, above 64 bits, or not an [`Int64`](#int64) throws `TypeError`.

*(Source: bindings/js/types/bind.d.ts, bindings/js/src/ds.c)*

## Fact handles

### `Fact`

**`export class Fact`**

A handle to one fact of one engine, read through the [`ds_fact_get_*`](inv:integrator:std:doc#facts/reading) calls.

A `Fact` comes from its engine and is never made directly. It is dead once the fact leaves working memory or its engine [closes](engine.md#close). A fact in a [`fact_retract`](callbacks.md#streameventof) event is dead once that event's listeners return. A `Fact` whose fact leaves working memory during a [`replayStream`](recording.md#replaystream) is dead once the replay ends.

After a replay that halts its engine, a `Fact` that is not dead throws a [`DsError`](errors.md#dserror) with `DS_ERR_ENGINE_HALTED` from [`read`](#read), and when passed to [`retract`](#retract). It stays not dead until the engine closes, whether or not its fact is still in working memory.

*(Source: bindings/js/types/bind.d.ts, bindings/js/src/ds.c)*

### `id`

**`get id(): bigint;`**

The fact's id, as [`ds_fact_get_id`](inv:integrator:std:doc#facts/reading) reads it. Ids increase and are never reused. A dead `Fact` answers.

*(Source: bindings/js/types/bind.d.ts, bindings/js/src/ds.c)*

### `alive`

**`get alive(): boolean;`**

Whether the `Fact` is not dead.

*(Source: bindings/js/types/bind.d.ts, bindings/js/src/ds.c)*

### `read`

**`read(): FactRecord;`**

Returns the fact as it is at the call, through the [`ds_fact_get_*`](inv:integrator:std:doc#facts/reading) calls.

A dead `Fact` throws a [`DsError`](errors.md#dserror) with `DS_ERR_FACT_INVALID`. [`Fact`](#fact) and [`replayStream`](recording.md#replaystream) state its refusals around a replay.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c)*

### `FactRecord`

**`export type FactRecord = FactRecordOf<Fact>;`**

A plain object: `schema`, the schema's own name, as [`ds_schema_get_name`](inv:integrator:std:doc#facts/schemas) reads it; `id`, a `bigint`; `slots`, each slot by name, as [Slot values](#slot-values) states.

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c)*

### `FactRecordOf`

**`export type FactRecordOf<F> = { schema: string; id: bigint; slots: Record<string, SlotValueOf<F>>; };`**

A [`FactRecord`](#factrecord) with fact references as `F`.

*(Source: bindings/js/types/types.d.ts)*

## Values

### `SlotValue`

**`export type SlotValue = SlotValueOf<Fact>;`**

A slot's value, as [Slot values](#slot-values) states.

*(Source: bindings/js/types/types.d.ts)*

### `SlotValueOf`

**`export type SlotValueOf<F> = bigint | number | string | boolean | null | Uint8Array | F;`**

A [`SlotValue`](#slotvalue) with fact references as `F`.

*(Source: bindings/js/types/types.d.ts)*

### Slot values

How each [`SlotType`](program.md#slottype) crosses [`ds_slot_value_t`](inv:integrator:std:doc#facts/values).

| `SlotType` | `assert` takes | `read` returns |
|---|---|---|
| `Int`, `Time`, `Date`, `Duration` | an [`Int64`](#int64) | `bigint` |
| `Float` | `number` | `number` |
| `String` | `string` | `string` |
| `Bool` | `boolean` | `boolean` |
| `Json` | `string` holding JSON text, parsed by [`ds_json_parse`](inv:integrator:std:doc#facts/json) | `string` holding canonical JSON text, written by [`ds_json_serialize`](inv:integrator:std:doc#facts/json) |
| `Bytes` | `Uint8Array` | a plain `Uint8Array` copy |
| a schema's name | a live [`Fact`](#fact) of this engine | `Fact`, or `null` once the target has left working memory |

`null` passes a null for a slot of any type, and `ds_engine_assert` judges it. A slot that holds null reads as `null`.

A `String` holding U+0000 throws a [`DsError`](errors.md#dserror) with `DS_ERR_INVAL`. A lone surrogate in a `String` or in JSON text is refused by libds with `DS_ERR_ENCODING`. A dead `Fact`, or one of another engine, throws a `DsError` with `DS_ERR_FACT_INVALID`.

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c, Spec: [LSTR.8.5])*

### `Int64`

**`export type Int64 = bigint | number;`**

A 64-bit integer going in: a `bigint`, or a `number` that `Number.isSafeInteger` accepts.

Another `number`, or a `bigint` out of range, throws `TypeError`. A 64-bit integer coming out is a `bigint`.

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c)*

### `JsonText`

**`export class JsonText`**

A call argument of kind `Json`, as its canonical JSON text. `instanceof JsonText` tells it from a `String` argument.

`constructor(text: string)` throws `TypeError` for a value that is not a string. `get text(): string` and `toString(): string` return the text.

```{warning}
`JSON.parse` of the text rounds an integer past 2^53.
```

```{note}
A `JsonText` given to a `Json` slot throws `TypeError`.
```

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c)*
