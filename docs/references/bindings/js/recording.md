<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Recording and atoms

## Recording

### `recordTo`

**`recordTo(target: string | ((bytes: Uint8Array) => void)): void;`**

Records the engine's [fact stream](inv:internals:std:doc#artefacts/fact-stream) to a path or a sink function.

A path's file is created, or truncated if it exists, and each atom is written as it is framed. A sink function receives each atom as a `Uint8Array` copy. [RFCS.3.6](inv:specs:std:label#rfcs-3-6) gives the atom each event kind records as. A running recording takes each event before listeners do.

The stream's header and schema announcements are written at the engine's first stream event, or by `recordTo` where the engine has already had one.

| Throws | Condition |
|---|---|
| `DsError`, `DS_ERR_STATE` | a recording is running; the engine is closed, and a path's file stays as it was |
| `TypeError` | `target` is neither a string nor a function; a path on a [`Host`](targets.md#host) whose `file` is `null` |
| the host `file`'s error | a path the `Host`'s `file` cannot open |
| `DsError`, `DS_ERR_IO`, with the sink's exception as its `cause` | the sink throws while `recordTo` writes |
| `DsError`, `DS_ERR_INVAL` | `recordTo` writes a `StreamHeader` above 64 KiB |
| `DsError`, `DS_ERR_OOM` | the recording's buffer cannot be allocated; `recordTo` writes a `SchemaDef` or `Slot` atom above 64 KiB |

A sink that throws afterwards stops the recording, and [`stopRecording`](#stoprecording) reports it. [`close`](engine.md#close) from a sink is refused.

```javascript statement
engine.recordTo((bytes) => console.log(bytes.length));
engine.pump();
engine.stopRecording();
```

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c)*

### `FileSink`

**`export type FileSink = { write: (bytes: Uint8Array) => void; close: () => void; };`**

What a [`Host`](targets.md#host)'s `file` returns for [`recordTo`](#recordto)'s path.

`close` runs when the recording stops, and when the engine closes.

*(Source: bindings/js/types/types.d.ts, bindings/js/lib/bind.js)*

### `stopRecording`

**`stopRecording(): void;`**

Stops the recording, and throws the recorder's first error as a `DsError`.

A sink's exception is that error's `cause`. With no recording running it does nothing. [`Engine.close`](engine.md#close) ends a recording too, and reports no failure.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c)*

## Replay

### `replayStream`

**`replayStream(source: Uint8Array | Iterable<Uint8Array>, { maxAtomBytes }?: { maxAtomBytes?: number; }): ReplayCounts;`**

Replays a [fact stream](inv:internals:std:doc#artefacts/fact-stream) into the engine, and returns what it did.

Inputs are delivered, the rules re-fire, and each re-derived compare atom is checked against the record. What the engine needs is in [Replay settings](inv:integrator:std:doc#engine/lifecycle).

`source` is one `Uint8Array`, or an iterable of chunks with any boundaries. `maxAtomBytes` is the largest atom accepted, and `0`, the default, selects libds's default.

During a replay, listeners and a running recording hear no event, and neither the call callback nor `writeThrough` is called. Listeners and a running recording hear events again once the replay ends, unless it halted the engine ([halt latch](inv:integrator:std:doc#engine/lifecycle)).

A replay that reaches the end of its recording with every compare clean returns its `ReplayCounts`, for a run that halted too. [`halted`](engine.md#halted) says whether the run halted. `DS_ERR_ENGINE_HALTED` from `replayStream` means the replay did not reproduce the run, or met an engine already halted.

While `source` is being iterated, a [`Fact`](facts.md#fact) of this engine that is not dead throws a `DsError` with `DS_ERR_STATE` from [`read`](facts.md#read), and when passed to [`assert`](facts.md#assert) or [`retract`](facts.md#retract).

| Throws | Condition |
|---|---|
| `TypeError` | `source` is neither form; a chunk is not a `Uint8Array`; `maxAtomBytes` is negative or not an integer |
| `RangeError` | `maxAtomBytes` is above 2^32-1 |
| `DsError`, `DS_ERR_STATE` | a replay is open on this engine |
| `DsError`, `DS_ERR_FS_DIVERGENCE` | a re-derived atom differs from the record, breaks a timetag's pairing with an earlier atom, or has no recorded twin; a recorded compare atom is not re-derived; a `CacheSeed` follows an event atom or is refused; an `ExternalAssert` delivery is refused, or asserts a number of facts other than the record lists |
| `DsError`, `DS_ERR_FS_VERSION` | the stream was written by another DS minor series |
| `DsError`, `DS_ERR_FS_RECORDING_INCOMPLETE` | the recording's first event has a `seq` other than `0`: it was attached after the engine's first input or sample |
| `DsError`, `DS_ERR_FS_UNKNOWN_FACT_ID` | a `FactRetract` names an unknown `fact_id` |
| `DsError`, `DS_ERR_BND_DSC_MISMATCH` or `DS_ERR_BND_DIALECT_MISMATCH` | the `StreamHeader` and the loaded artefact disagree on the dialect binding |
| `DsError`, `DS_ERR_BND_INCOMPLETE` | a `StreamHeader` holds one of a 32-byte `dsc_hash` and a 32-byte `dialect_def_sha256` without the other |
| `DsError`, `DS_ERR_SCHEMA_UNKNOWN` | a `FactAssert` names a schema no `SchemaDef` in the stream announced, or one the engine does not have |
| `DsError`, `DS_ERR_PARSE` | a malformed atom; a `FactAssert`'s `String` or `Json` field whose text is not well-formed UTF-8; a fact-reference handle that names no earlier record; an atom whose field number has no registry entry; an atom declares more than `maxAtomBytes`; the stream ends inside an atom |
| `DsError`, `DS_ERR_INVAL` | a `FactAssert`'s schema has more than 256 slots |
| `DsError`, `DS_ERR_OOM` | an allocation fails |
| `DsError`, the call's status | [`ds_engine_set_stream_callback`](inv:integrator:std:doc#callbacks/stream), [`ds_engine_schema_find`](inv:integrator:std:doc#facts/schemas), [`ds_engine_assert` or `ds_engine_retract`](inv:integrator:std:doc#facts/asserting), [`ds_engine_pump`](inv:integrator:std:doc#engine/pump), or a [clock call](inv:integrator:std:doc#engine/clock) returns a failure |

`DS_ERR_CONTRACT_BREACH` for a `FactAssert` or a `PumpBoundary` does not end the replay, nor does `DS_ERR_ENGINE_HALTED` for a halt that the atom's own assert, retract, delivery or pump raises, nor do `DS_ERR_NAN_REJECTED` and `DS_ERR_SERIES_NO_BACKING` for a `PumpBoundary`. Atoms applied before a failure stay applied.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c, runtime/src/libds/rfcs/rfcs.h, runtime/src/libds/rfcs/codec.c, Spec: [NDET.8.2], [NCBK.2.9], [RBND.5.2], [RBND.2.1], [RFCS.7.3], [LDET.1.10], [LTIM.2.8.5], [RFCS.24.2], [RFCS.26.2], [RFCS.5.3], [RFCS.5.4], [RFCS.6.3], [RFCS.6.7], [NCBK.2.11])*

### `ReplayCounts`

**`export type ReplayCounts = { asserts: bigint; retracts: bigint; clocks: bigint; ruleFires: bigint; calls: bigint; withdrawals: bigint; skipped: bigint; headerVerified: boolean; };`**

What a replay did.

| Field | Holds |
|---|---|
| `asserts` | `FactAssert` atoms delivered, a bound's repeated refusal included; `FactEmit` atoms compared; and each fact an `ExternalAssert` delivery asserted |
| `retracts` | `FactRetract` atoms read, including one whose fact has already left working memory |
| `clocks` | `ClockAdvance` atoms applied |
| `ruleFires` | `RuleFireAnnotation` atoms compared and matching the record |
| `calls` | `CallIssued` atoms compared and matching the record |
| `withdrawals` | `FactWithdraw` atoms compared and identical |
| `skipped` | `SchemaDef` and `Slot` atoms; other allocated atoms with no arm; a `BoundsError` left uncompared |
| `headerVerified` | whether a `StreamHeader` matched the engine's session header |

*(Source: bindings/js/types/types.d.ts, runtime/src/libds/rfcs/codec.c)*

## External assert

### `applyExternalAssert`

**`applyExternalAssert(body: Uint8Array): ExternalAssertApplied;`**

Applies one recorded [`ExternalAssert`](inv:internals:std:doc#artefacts/fact-stream) as the replayer does: one input, the recorded `ttl_ns` on the received fact, and no pump.

`body` is the atom's body as framed, which [`Atom`](#atom)'s `bodyOffset` and `bodyLength` locate.

| Throws | Condition |
|---|---|
| `TypeError` | `body` is not a `Uint8Array` |
| `DsError`, `DS_ERR_FS_DIVERGENCE` | the delivery refuses, or asserts a number of facts other than the record lists |
| `DsError`, `DS_ERR_PARSE` | a malformed body |
| `DsError`, `DS_ERR_STATE` or `DS_ERR_ENGINE_HALTED` | an engine that takes no input at the call |

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js, Spec: [RFCS.24.2])*

### `ExternalAssertApplied`

**`export type ExternalAssertApplied = { factIds: bigint[]; recordedIds: bigint[]; };`**

What [`applyExternalAssert`](#applyexternalassert) asserted: `factIds[i]` is the engine's id for the recorded `recordedIds[i]`.

*(Source: bindings/js/types/types.d.ts, Spec: [RFCS.24.3])*

## Atoms

### `readAtoms`

**`readAtoms: (bytes: Uint8Array, options?: { incremental?: boolean; }) => AtomsRead;`**

Reads every atom of a trace or a `.dsc`. A member of the [`Api`](targets.md#api).

With `incremental`, a partial trailing atom stops the read with `incomplete` true. Otherwise it is an `error` with `DS_ERR_PARSE`. A value that is not a `Uint8Array` throws `TypeError`. The atoms' layouts are in [The fact stream](inv:internals:std:doc#artefacts/fact-stream).

```javascript statement
const api = await ds.open();
const { atoms, error } = api.readAtoms(new Uint8Array(0));
console.log(atoms.length, error, api.messageName(1));
```

*(Source: bindings/js/types/types.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c, Spec: [RFCS.19.2])*

### `messageName`

**`messageName: (field: number) => string | null;`**

Returns the proto message an atom's field number names, or `null` for a number with no entry. A member of the [`Api`](targets.md#api).

A value that is not an integer throws `TypeError`, and one outside 0 to 2^32-1 throws `RangeError`.

*(Source: bindings/js/types/types.d.ts, bindings/js/lib/bind.js)*

### `AtomsRead`

**`export type AtomsRead = { atoms: Atom[]; end: number; incomplete: boolean; error: { offset: number; status: number; detail: string; field: number | null; message: string | null; } | null; };`**

What [`readAtoms`](#readatoms) read.

`atoms` holds those before any error. `end` is where reading stopped. `error` is `null` unless bytes stopped the read. `error.field` and `error.message` name the atom when reading stopped at its body, and both are `null` when it stopped at framing.

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c)*

### `Atom`

**`export type Atom = { offset: number; field: number; message: string | null; body: AtomBody | null; unknownFields: number[]; bodyOffset: number; bodyLength: number; };`**

One atom, named by its field number.

`message` and `body` are `null` for an atom this build has no entry for. `unknownFields` lists each field number in the body, at any depth, that its message does not name, in the order read. `bodyOffset` and `bodyLength` locate the body's bytes in what was read.

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c, Spec: [RFCS.16.1])*

### `AtomBody`

**`export type AtomBody = { [field: string]: AtomField; };`**

An atom's message, field by field: nested messages as objects, repeated fields as arrays.

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c)*

### `AtomField`

**`export type AtomField = AtomScalar | AtomEnum | AtomBody | AtomScalar[] | AtomEnum[] | AtomBody[];`**

One field of an atom's message. A repeated field is an array of one kind.

*(Source: bindings/js/types/types.d.ts)*

### `AtomEnum`

**`export type AtomEnum = { number: number; name: string | null; };`**

An enum field: its number, and its name where this build has one.

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c)*

### `AtomScalar`

**`export type AtomScalar = bigint | number | boolean | string | Uint8Array;`**

A scalar field. A 64-bit integer is a `bigint`, and bytes are a plain `Uint8Array` copy.

*(Source: bindings/js/types/types.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c)*

## Fact bodies

### `decodeFactBody`

**`decodeFactBody(schema: string, body: Uint8Array): Record<string, SlotValue>;`**

Types a `FactAssert` or `FactEmit` atom's `fact` bytes by this engine's schema `schema`, with each [`SlotValue`](facts.md#slotvalue) as a [`Fact`](facts.md#fact)'s [`read`](facts.md#read) gives it.

A name the engine has no schema by throws a `DsError` with `DS_ERR_SCHEMA_UNKNOWN`, and a schema with a fact-reference slot one with `DS_ERR_INVAL`. A malformed body, a `String` field holding U+0000 included, or a `String` or `Json` field's text that is not well-formed UTF-8, throws one with `DS_ERR_PARSE`. A `Json` field's text that does not parse throws one with `DS_ERR_PARSE`, and one over a tree limit with `DS_ERR_JSON_LIMIT`. A non-nullable `Json` slot's field that is absent, or whose document is `null` at its root, throws one with `DS_ERR_PARSE`. An allocation that fails throws one with `DS_ERR_OOM`. A `schema` that is not a string or holds U+0000, or a `body` that is not a `Uint8Array`, throws `TypeError`.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c, runtime/src/libds/rfcs/rfcs.h, runtime/src/libds/rfcs/codec.c, Spec: [LSTR.1.5], [LGRA.5.8.6], [RFCS.6.3])*

### `decodeAnnouncedFactBody`

**`decodeAnnouncedFactBody: (slots: AnnouncedSlot[], body: Uint8Array) => Record<string, SlotValue>;`**

Types a `FactAssert` or `FactEmit` atom's `fact` bytes by the stream's own `Slot` atoms, in order. A member of the [`Api`](targets.md#api).

The values are those [`decodeFactBody`](#decodefactbody) gives.

| `DsError` | Condition |
|---|---|
| `DS_ERR_INVAL` | a fact-reference slot; a `kind` no slot type has |
| `DS_ERR_PARSE` | a malformed body, a `String` field holding U+0000 included; a `String` or `Json` field's text is not well-formed UTF-8; a `Json` field's text does not parse; a non-nullable `Json` slot's field is absent, or its document is `null` at its root |
| `DS_ERR_JSON_LIMIT` | a `Json` field is over a tree limit |
| `DS_ERR_OOM` | an allocation fails |

| `TypeError` | Condition |
|---|---|
| `slots` | not an array |
| a slot | not an object; its `name` not a string, or holding a lone surrogate or U+0000; its `kind` not an integer in 0 to 2^32-1; its `nullable` not a boolean; its `schemaRef` holding a lone surrogate or U+0000 |
| `body` | not a `Uint8Array` |

*(Source: bindings/js/types/types.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c, runtime/src/libds/rfcs/codec.c, Spec: [RFCS.5.1], [RFCS.6.3], [LSTR.1.5], [LGRA.5.8.6])*

### `decodeAnnouncedFactBodyHandles`

**`decodeAnnouncedFactBodyHandles: (slots: AnnouncedSlot[], body: Uint8Array) => AnnouncedBody;`**

[`decodeAnnouncedFactBody`](#decodeannouncedfactbody), with each fact-reference slot as the stream recorded it, in an [`AnnouncedBody`](#announcedbody). A member of the [`Api`](targets.md#api).

It throws the same `TypeError`s and the same `DsError`s, but for a fact-reference slot's `DS_ERR_INVAL`. A fact-reference handle of `0`, or a slot not `nullable` with no handle, throws one with `DS_ERR_PARSE`.

*(Source: bindings/js/types/types.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c, runtime/src/libds/rfcs/codec.c, Spec: [RFCS.6.3])*

### `AnnouncedSlot`

**`export type AnnouncedSlot = { name: string; kind: number; nullable: boolean; schemaRef: string | null; };`**

One slot as a stream announces it, a `Slot` atom's fields.

`kind` is `Slot.kind`'s number. `schemaRef` is a fact-reference slot's schema, and otherwise `null` or `""`.

*(Source: bindings/js/types/types.d.ts, Spec: [RFCS.5.1])*

### `AnnouncedBody`

**`export type AnnouncedBody = { slots: Record<string, SlotValue>; refs: Record<string, bigint | null>; };`**

A fact body typed by its announced slots.

`slots` holds every slot but a fact-reference one. `refs` holds each fact-reference slot's recorded handle, or `null` where a nullable one is absent. A handle names a fact only within its stream.

*(Source: bindings/js/types/types.d.ts, Spec: [RFCS.6.3])*
