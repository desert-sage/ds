<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# The fact stream

## Stream

### Event trace

An event trace is one serialisation of an engine session's stream: every recordable event, in emission order, with the schema information to decode every fact.

It records every input the engine consumed, every observable it produced, and the structural atoms that frame them. It is read two ways. Replay re-executes it against an engine and compares what the engine produces with what the trace holds; it alone needs the compiled program. Inspection decodes it without an engine: every schema is announced before its first use. Writing a trace is the integrator's; the engine performs no I/O. The delivery it serialises is [Stream delivery](../overview/runtime-architecture.md#stream-delivery).

*(Spec: [RFCS.1.1], [RFCS.1.2], [RFCS.1.3])*

### Framing

A stream is a `Stream` container, `repeated Atom atoms = 1`; each atom is identified by its `oneof` field number.

The outer tag is one byte for every atom. A stream is read forward and in one pass. The `.dsc` container (`Dsc`) shares the framing.

```ebnf
container   = { frame } ;
frame       = outer_tag , varint_len , atom ;
outer_tag   = %x0A ;
atom        = oneof_tag , varint_len , body ;
oneof_tag   = ?varint of (field_number << 3 | 2)? ;
```

*(Spec: [RFCS.2], [RFCS.2.2], [RFCS.19.1], proto: atom.proto)*

### Lean and self-contained streams

A lean stream begins with a `StreamHeader` atom; a self-contained stream begins with its embedded [`.dsc`](dsc-format.md#layout), a `DscHeader` atom first, followed by the stream.

A reader dispatches on the first atom's field number: `StreamHeader` (258) opens a stream, `DscHeader` (263) opens a `.dsc`, and any other first atom is refused. It never classifies by a leading byte or a four-byte prefix. In a self-contained stream, the reader processes the leading `.dsc` atoms as the embedded program and finds the stream by walking atom lengths until a `StreamHeader` appears; it never scans the bytes for the header's tag.

| Operation | Effect |
|---|---|
| embed | concatenation: `.dsc` bytes, then the stream |
| strip | walk the `.dsc` atoms by length to the `StreamHeader`; the remainder is the lean stream, and its `dsc_hash` still binds it |
| extract | the bytes strip removes are the `.dsc` |

A self-contained stream replays bit-identically to the lean stream with its `.dsc`.

*(Spec: [RFCS.4.1], [RFCS.13], [RFCS.13.1], [RFCS.13.2], [RFCS.13.3], [RFCS.13.4], [RFCS.19.4])*

### Truncation

A partial trailing atom ends a stream read incrementally, as EOF: the reader stops at the last complete atom.

A reader given the whole buffer may treat a partial trailing atom as an error. A stream that ends at its last complete atom is in progress or crash-truncated, not corrupt, and a conforming implementation has an incremental path that recovers it. A reader may reject an atom whose declared length exceeds an implementation bound without waiting for its body. A truncated `.dsc` is a loader error.

*(Spec: [RFCS.19.2], [RFCS.19.7], [RFCS.19.8])*

### Parsing departures from protobuf

DS hand-parses the containers and differs from protobuf in two cases.

| Case | protobuf | DS |
|---|---|---|
| truncated trailing atom | refuses the message | reads on, keeping the complete atoms |
| `Atom` with no `oneof` member set | accepts it | refuses the container |

*(Spec: [RFCS.19.2], [RFCS.19.3])*

### Writer rules

A writer emits every message's fields in ascending field-number order, each atom body and every nested message included.

It writes a non-repeated field at most once, and a repeated field's elements in the order its defining clause states, or otherwise in an order that depends on its input alone. A writer's bytes for one input are then the same on every conforming platform. A writer never frames an atom at a field number the registry does not allocate; it fails instead.

*(Spec: [RFCS.19.5], [RFCS.19.6])*

## Atoms

### Atom registry

The `.dsc` and the stream share one [atom registry](../atoms/index.md#census): one `oneof body` over one field-number space.

An atom's field number is its wire identity in both containers, and each container carries a legal subset. Each atom has its own number; atoms are never told apart by a discriminator inside a body. No atom is renumbered. `SchemaDef` and `Slot` share their bodies with the `.dsc`.

A field inside an atom's body that the reader does not know is skipped. Within one `<major>.<minor>.` series, such a field is one the series has struck and reserved.

*(Spec: [RFCS.3.2], [RFCS.3.5], [RFCS.16.1], [RFCS.16.3], [RFCS.16.5], [RFCS.16.6])*

### Container legality and stream class

Each atom has a container legality, `DSC`, `stream` or `both`, and a stream class, `inject`, `compare` or `structural`.

| Class | On replay |
|---|---|
| inject | a recorded input, delivered to the engine as recorded |
| compare | an engine output, re-derived and byte-compared with the record; never delivered |
| structural | framing, schema and seek, with no input role |

A known reader rejects a container carrying an atom its legality does not admit. A replayer's inject path refuses every atom outside the inject class: a `call` is never a replay input.

*(Spec: [RFCS.3.4], [RFCS.17.1], [RFCS.17.3], [RFCS.17.5], [RFCS.17.6])*

### Event kinds and atoms

Each stream event kind with an atom records as that atom.

| Kind | Atom |
|---|---|
| `fact_assert` | `FactAssert` for a host assert; an `ExternalAssert` lists a fact an external delivery or a reference-holding host assert asserted; a rule-emitted fact has none |
| `fact_retract` | `FactRetract` when the integrator retracted; `FactWithdraw` when the engine withdrew |
| `rule_fire_begin`, `rule_fire_end` | `RuleFireAnnotation`, one each |
| `action_emit` | `FactEmit` |
| `action_publish` | `FactPublish` |
| `action_call` | `CallIssued` |
| `tick` | `ClockAdvance` |
| `pump` | `PumpBoundary` |
| `type_error`, `bounds_error`, `engine_error`, `computation_error` | `TypeError`, `BoundsError`, `EngineError`, `ComputationError` |

A kind with no row reaches the stream callback only; a replay re-derives what it reports. When each kind is delivered is [Delivery points](../overview/runtime-architecture.md#delivery-points).

*(Spec: [RFCS.3.6], Source: runtime/src/libds/rfcs/codec.c)*

## Header and prelude

### StreamHeader

The `StreamHeader` atom opens the trace body.

| Field | Holds |
|---|---|
| `ds_version` (10) | the DS version that wrote the stream; a reader accepts its own `<major>.<minor>.` series and rejects every other |
| `session_id` | the run identifier the engine was given, or empty |
| `tier_id` | the tier identifier the engine was given, or empty; opaque to the format |
| `dsc_hash` | the 32-byte binding to the program |
| `capabilities`, `dialect_def_sha256` | the rest of the program binding |
| `wall_start_iso8601` | the host wall-clock time the stream opened, UTC, ISO 8601; provenance, never a replay input; optional |

A replay given the same `session_id` and `tier_id` reproduces every `event_id`.

*(Spec: [RFCS.4.2], [RFCS.4.3], [RFCS.4.4], [RFCS.4.8], proto: stream_header.proto)*

### Header binding check

A reader holding the `.dsc`, embedded or supplied, verifies it against its own `dsc_sha256` and checks the header's binding tuple.

The tuple's fields, what a header lacking them does, and the mismatch errors are [Containers](dialect-binding.md#containers) and [Binding check](dialect-binding.md#binding-check). A `ds_version` outside the reader's series is a fatal stream-open error, `DS_ERR_FS_VERSION`, with no warn-and-continue mode.

*(Spec: [RFCS.4.5], [RFCS.4.7])*

### Schema announcement

The `StreamHeader` is followed, before any event atom, by one `SchemaDef` atom per registered schema, each followed by one `Slot` atom per slot in declaration order.

Schemas are announced in registration order, which is the order the artefact's `SchemaDef` atoms appear. Schemas with synthetic names are not announced. Declaration order fixes the fact body's field numbers. A `Slot` atom carries the declared kind, the temporal kinds included, and `schema_ref`, `sampled`, `retained`, `tolerance`, `identity_role`, `nullable` and `capacity`. The encoder writes the header and the announcements when it encodes the engine's first event, after which the engine registers no schema; nothing is announced later, and nothing is repeated in the body.

An encoder forwards the `.dsc`'s `SchemaDef` and `Slot` atoms or constructs them from the schema registry; a constructed `SchemaDef` may carry an empty `proto_source`. A reader adds each schema to its descriptor pool as it arrives. An embedded `.dsc`'s atoms count as announcements for the reader, and the body still announces every schema. A `FactAssert` naming a schema neither announced nor held by a replaying engine is fatal: `DS_ERR_SCHEMA_UNKNOWN`.

*(Spec: [RFCS.5.1], [RFCS.5.2], [RFCS.5.3], [RFCS.5.4], [RFCS.12.3])*

### CacheSeed

A `CacheSeed` atom records one host cache seed, in the prelude after the schema announcement and before any event atom.

| Field | Holds |
|---|---|
| `key` | the key |
| `value_json` | the value as the cache holds it, its canonical JSON text |
| `deadline_ns` | the entry's deadline in engine-clock nanoseconds, or `0` for no expiry |

There is one atom per seeded key the cache holds when the header is written, in ascending order of the key's UTF-8 bytes; a key seeded twice carries the second seed's entry. A refused seed, an `initial` block's cache items and the cache of a recorder attached after the first event have no atom. A `CacheSeed` carries no `seq`. A replayer applies each before the first event, as a host seed, with no cache event and no write-through; an engine that refuses one, or a `CacheSeed` after an event atom, is `DS_ERR_FS_DIVERGENCE`. Stream class inject, field 6.

*(Spec: [RFCS.26.1], [RFCS.26.2], proto: cache_seed.proto)*

## Fact atoms

### FactAssert

A `FactAssert` atom records a host assert arriving.

| Field | Holds |
|---|---|
| `fact_id` | the engine's ID for the fact; unique within the file; echoed by `FactRetract` |
| `schema_name` | the schema's [own name](inv:author:std:doc#lang/imports), in NFC, matching an announced `SchemaDef` |
| `fact` | the fact body, encoded as the schema's message |
| `ttl_ns` | the fact's TTL window; `0` is the schema default |
| `clock_ns` | the engine's monotonic clock at the assertion |
| `rule_name` | empty |
| `seq` | the event's sequence number |
| `event_id` | the derived UUID |

A `fact_id` is scoped to its file.

*(Spec: [RFCS.3.3], [RFCS.6.1], [RFCS.6.2], [RFCS.6.4], [RFCS.6.5], [RFCS.6.6], [RFCS.7.5], proto: fact_assert.proto)*

### Fact body encoding

A fact body is the protobuf message the schema's `SchemaDef` defines, and a reader decodes it with the descriptor from that atom.

A `null` in a nullable slot, whose field is `optional`, is the omitted field; any other value is written, its type's zero included, and a reader never substitutes a zero for an absent field. A non-nullable slot's field has no presence, and an absent one is the type's zero. A non-nullable `Json` or fact-reference slot has no such zero: a writer writes the field, and a reader refuses a body without it with `DS_ERR_PARSE`. A `Json` field whose document is `null` at its root is written by no writer; a reader decodes it as `null` in a nullable slot and refuses the body with `DS_ERR_PARSE` in a non-nullable one. A fact-reference slot is a `uint64` holding the `fact_id` of the referenced fact, which always precedes it in the stream: a record's fact or a fact an `ExternalAssert` listed. A handle identifies a fact within one stream only. A `Json` slot carries its canonical JSON text.

*(Spec: [RFCS.4], [RFCS.6.3])*

### Arriving inputs

A host input is recorded on arrival, before everything its evaluation produces.

| Input | Recorded |
|---|---|
| no-op reassertion | a `FactAssert` carrying the live fact's ID |
| identity update | the `FactAssert`, then a `FactWithdraw` of the superseded fact with cause `SUPERSEDED` |
| host retract | the `FactRetract`, then its faults and cascaded withdrawals |
| assert a bound refuses | the `FactAssert`, then the `BoundsError` |
| assert whose TTL deadline falls outside the `Time` range | nothing; refused with `DS_ERR_TIME_RANGE`, the engine unchanged |
| host call that is not a well-formed input | nothing |

A bounds refusal of a rule's action is a `BoundsError` in the firing that attempted it: the firing stops at the refused action and the pump continues, returning `DS_ERR_CONTRACT_BREACH`. An input during which the engine halts returns `DS_ERR_ENGINE_HALTED`. A replayer treats both statuses as outcomes and compares the re-derived `BoundsError` or `EngineError` with the recorded one.

A pump that returns `DS_ERR_NAN_REJECTED`, for a refused call, or `DS_ERR_SERIES_NO_BACKING`, for a read no backing can answer, is an outcome as well. No atom records either status, and a call the recording holds and the replay refuses, or the reverse, is a divergence at that `CallIssued`.

Any other failing status from a replayed pump, or an input refused by an already halted engine, ends the replay.

*(Spec: [RFCS.6.7])*

### Fact numbering

The engine numbers facts from one counter per engine, starting at 1 and increasing by 1.

It takes an ID for each fact entering working memory (a host assert, a rule's `emit`, an `ExternalAssert` delivery, a hydrated row, a fault fact, an identity update's replacement) and for each host assert a bound refuses. It takes none for a no-op reassertion, a malformed host call, or a fact the lowering or the engine creates for its own use. No fact has ID 0. A clone continues the counter. Every compared body carries IDs, so a replay matches only if it numbers as the recorded run did.

*(Spec: [RFCS.6.9])*

### event_id derivation

Each `FactAssert`'s `event_id` is a version-8 UUID derived from the run identifier `r`, the tier identifier `t` and the event's `seq` `s`.

`r` and `t` are UTF-8, empty when absent; `be64(s)` is `s` as eight bytes, most significant first. The `event_id` is `u_0 … u_15` as 32 lower-case hex digits in groups of 8, 4, 4, 4 and 12, joined by `-`: 36 characters. The architecture is [Event identity](../overview/runtime-architecture.md#event-identity).

```text
h   = SHA-256("ds.rfcs.event_id.v1" ‖ 0x1F ‖ r ‖ 0x1F ‖ t ‖ 0x1F ‖ be64(s))
u_i = h_i for 0 ≤ i < 16, i ≠ 6, 8;  u_6 = (h_6 & 0x0F) | 0x80;  u_8 = (h_8 & 0x3F) | 0x80
```

*(Spec: [RFCS.6.8])*

### FactEmit

A `FactEmit` atom records a fact the engine produced by firing an author's rule.

It carries `FactAssert`'s fact-bearing fields and a never-empty `rule_name`. `ttl_ns` carries a per-emit TTL override. It is compare class: re-derived and byte-compared, reference slots and `fact_id`s included, and never delivered. An emit that supersedes a live fact under one identity records the `FactEmit`, then the `FactWithdraw` with cause `SUPERSEDED`. A correlation sweep's withdrawal is recorded where its action runs, ahead of the emit. A fault fact's replacement records the `FactWithdraw` with cause `SUPERSEDED`, then the `FactEmit`. A compiler-owned fact, an `after`-clause timer fact or a capture-corr fact, has no `FactEmit` and no `FactWithdraw`. A truth-maintenance retraction the emit causes is ordered by [Consumption loop](../overview/runtime-architecture.md#consumption-loop).

*(Spec: [RFCS.6a.1], [RFCS.6a.2], [RFCS.6a.3], [RFCS.6a.4], [RFCS.6a.5], proto: fact_emit.proto)*

### FactPublish

A `FactPublish` atom records that a rule's `publish` ran.

| Field | Holds |
|---|---|
| `schema_name` | the schema the `publish` named |
| `rule_name` | the publishing rule; never empty |
| `clock_ns` | the engine clock at the `publish` |
| `seq` | the event's sequence number |
| `timetag` | the firing's timetag |

It holds no slot value and no fact handle. A `publish` the engine refuses records none. It is compare class: a replayer re-derives it by firing the same rule and compares it with the record, and never delivers it. A replay that matches shows the same rule published the same schema at the same point, and nothing of the values. What crosses a tier is the event's [`FactExternal`](#factexternal), which no atom records.

*(Spec: [RFCS.27.1], [RFCS.27.2], proto: fact_publish.proto)*

### FactRetract

A `FactRetract` atom records the integrator retracting a fact.

It carries the event's `seq` and the monotonic `clock_ns` at which the engine applied the retraction. Its `fact_id` names a fact a `FactAssert`, `FactEmit` or `ExternalAssert` carried earlier in the file, still live, and named by no earlier `FactRetract`; any other is fatal, and a replay stops with `DS_ERR_FS_UNKNOWN_FACT_ID`. A TTL expiry is not a `FactRetract`.

*(Spec: [RFCS.7.1], [RFCS.7.2], [RFCS.7.3], [RFCS.7.4], [RFCS.7.5], proto: fact_retract.proto)*

### FactWithdraw

A `FactWithdraw` atom records the engine taking back a fact, with its cause.

| Cause | Raised by |
|---|---|
| `JUSTIFIER_ENDED` | truth maintenance: the last justifier stopped matching |
| `TTL_EXPIRED` | the pump's TTL sweep |
| `SUPERSEDED` | a successor under the same identity: an identity upsert, or an `as`-keyed re-fire |
| `SYNTHETIC_DISCHARGED` | a lowering-created fact whose deferred action has run; never recorded |
| `AUTHOR_WITHDRAWN` | a rule's `withdraw` |
| `ACTIVATION_COMPLETED` | an activation-scoped fact whose activation completed |

The engine sets the cause where the withdrawal originates and never records `CAUSE_UNSPECIFIED`. A reader accepts a cause the enum lacks and carries its number. The atom is compare class. Its `fact_id` names a `FactEmit` or `FactAssert` in the file; any other is fatal. A withdrawal is recorded before everything its evaluation produces, each cascaded withdrawal before its own consequences.

*(Spec: [RFCS.7a.1], [RFCS.7a.2], [RFCS.7a.3], [RFCS.7a.4])*

## Event atoms

### ClockAdvance

A `ClockAdvance` atom records a new sample of the engine's two clocks: `clock_ns`, the monotonic clock, and `wall_ns`, the wall clock.

Every `ClockAdvance` carries both and writes `has_wall`, false when the wall clock has no value. The engine emits one for every value a sample observes, of either clock, live or mock, with no coalescing or decimation. A replayer advances the replay engine's monotonic clock to `clock_ns` and sets its wall clock to `wall_ns`, or to no value, before the next atom. A stream's start and end are its first and last atoms' `clock_ns`; events are ordered by `seq`, never by `clock_ns`. Stream class inject, field 3.

*(Spec: [RFCS.6.6], [RFCS.10.1], [RFCS.10.2], [RFCS.10.3], [RFCS.10.5], proto: stream_header.proto)*

### RuleFireAnnotation

A `RuleFireAnnotation` atom with `end=false` precedes every atom a rule's firing produces, and one with `end=true` follows them.

Every atom between a matching pair is attributed to that activation. `timetag` (field 6) is the firing activation's creation timetag; with `rule_name` it is the join key `CallIssued` carries byte-identically. A timetag identifies a firing within one stream and is never compared with another engine's. The atom is compare class: a replayer never skips it, and an inspecting reader that does not use it skips it. The emitting mechanism is [Rule-fire events](../engine/agenda-and-actions.md#rule-fire-events).

*(Spec: [RFCS.11.2], [RFCS.11.3], [RFCS.11.4], [RFCS.11.6], proto: stream_header.proto)*

### CallIssued

A `CallIssued` atom records an outbound call the engine issued, one per `action_call` event.

| Field | Holds |
|---|---|
| `call_id` (1) | absent |
| `args` | one `Arg` per supplied kwarg, sorted by name; a schema-typed kwarg is `KIND_ENCODED_FACT` carrying a `FactExternal` |
| `correlation` | the `as` value or the compiler-generated one; never empty |
| `rule_name`, `timetag` | the firing activation's identity |

`(timetag, rule_name)` joins it to its `RuleFireAnnotation`; `correlation` joins it to its answers, which arrive as `FactAssert`s. It is compare class. Its body is canonical by construction. The event is emitted once the call's arguments evaluate, before the call callback, whatever the callback does or whether one is registered; a call with an argument that fails to evaluate or is refused emits none. `call` is the only verb recorded this way. The emitting mechanism is [Action events](../engine/agenda-and-actions.md#action-events).

*(Spec: [RFCS.15.1], [RFCS.15.2], [RFCS.15.3], [RFCS.15.4], [RFCS.15.5], [RFCS.15.6], [RFCS.15.7], [IDSP.1.4], [IDSP.6.5], proto: call_issued.proto)*

### ComputationError

A `ComputationError` atom records a trap, before the fault fact it asserts, which is recorded as a `FactEmit`.

Its identity is `rule_name` and `timetag`, the pair `CallIssued` and `RuleFireAnnotation` carry. A trap raised while matching has `timetag` 0, which names no activation, and is told apart by its `rule_name` (`$beta_<id>`), `node_id` and `fact_id`. The slot-context fields name the offending operand when it is a slot read. `recoverable` is carried, not derived from `kind`. Container `stream`, class compare, field 325.

*(Spec: [RFCS.21.1], proto: engine_error.proto)*

### PumpBoundary

A `PumpBoundary` atom marks one pump to quiescence, including a pump that fired nothing.

It is inject class, field 4: a replayer performs a pump on meeting one. Its body carries no fire count.

*(Spec: [RFCS.22], proto: pump_boundary.proto)*

### ExternalAssert

An `ExternalAssert` atom records a host input whose fact holds a fact reference, as a `FactExternal` with each referenced fact inlined.

It records both an external delivery holding a reference, as the host passed it, and a direct host assert with a non-null fact-reference slot. Every other host assert is a `FactAssert`. It is written on arrival and is one step: its `clock_ns` is the input's one clock sample. `fact_ids` lists the facts the delivery asserted, innermost inlined copy first and the received fact last; a copy that resolved to a live fact contributes none. The engine emits one `fact_assert` event per listed fact, each with its own `seq`; the atom carries the first's. A delivery refused whole is not recorded. A replayer asserts the `fact` by the receiving rules and binds `fact_ids` in order; a refusal or a different fact count is `DS_ERR_FS_DIVERGENCE`. Inject class, field 5.

*(Spec: [RFCS.24.1], [RFCS.24.2], [RFCS.24.3], proto: external_assert.proto, Source: runtime/src/libds/rfcs/codec.c)*

## Portable facts

### FactExternal

A `FactExternal` is a fact leaving the engine, published to another tier or passed as a call argument: a portable value, not a stream atom.

It decodes without `SchemaDef` or `Slot` atoms and without the program that wrote it. It carries one field per slot, in the writing schema's declaration order, each named for its slot; a `null` slot is `KIND_NULL`. A fact-reference slot carries the referenced fact inlined as a nested `FactExternal` of kind `KIND_FACT_REF`, at most 16 deep; a deeper one is refused whole with `DS_ERR_PARSE`. A reference whose target has left working memory is `KIND_NULL`, whether or not the slot is nullable. It carries no `event_id` and no TTL. `asserted_at` is the UTC instant, in nanoseconds since the Unix epoch, the fact entered working memory, or, for a fact a rule publishes, the instant of the `publish`. It is absent (`has_asserted_at` false) when the wall clock had none.

*(Spec: [RFCS.23.1], [RFCS.23.4], [RFCS.23.5], [RFCS.23.6], proto: fact_external.proto)*

### Arg and Kind

Every value in a `FactExternal` or a call's arguments is an `Arg`: a name, a `Kind` and the one value member that kind names.

`Kind` is one number space with two subtypes: a slot value admits the common kinds and `KIND_FACT_REF`, and a call argument the common kinds and `KIND_ENCODED_FACT`; each subtype's numbers are reserved in the other. A call argument never carries `KIND_NULL`. A `Time`, `Date` or `Duration` value is `KIND_INT`. A `Json` value is its JSON text. The engine's slot-kind and argument-kind enumerations are generated from `Kind`.

*(Spec: [RFCS.23.2], proto: fact_external.proto)*

### schema_hash

`schema_hash` is the SHA-256 of the schema's `SchemaShape`: its name and, per slot in byte order of slot name, the slot's name, `Kind`, nullability, referenced schema for a fact-reference slot, and declared `SlotKind` for a `Time`, `Date` or `Duration` slot.

The shape is encoded in field-number order with defaults omitted. Lifecycle, identity keys, slot order and units are outside it. A program refuses a `FactExternal` whose `schema_hash` differs from its own schema of that name, or that names a schema it does not declare.

*(Spec: [RFCS.23.3], proto: fact_external.proto, proto: slot.proto)*

### Receiving a FactExternal

An engine receiving a `FactExternal` checks its `schema_hash`, decodes it, asserts it, and resolves each nested reference innermost first.

1. A live fact of the schema equal to the inlined copy is the same fact: nothing is asserted, and the slot refers to it.
2. Otherwise, with no live fact of the same identity key, the copy is asserted and the slot refers to it.
3. Otherwise the whole `FactExternal` is refused: nothing is asserted or replaced.

`KIND_NULL` in a fact-reference slot is a reference with no target, whether or not the slot is nullable: nothing is resolved or asserted for it. In a nullable slot it is `null`, and in any other the slot refers to no fact.

Equality is the no-op reassertion's, slot by slot. A reference slot is equal when it resolves to the same fact, and a reference with no target equals a live slot that is `null` or whose target has left working memory. Every fact asserted gets this engine's own `event_id`. One `FactExternal` is one input: the engine samples its clocks once, and every fact it asserts takes that sample.

*(Spec: [RFCS.23.7], [RFCS.23.4], Source: runtime/src/libds/rfcs/codec.c)*
