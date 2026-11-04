<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# The .dsc format

## File

### Layout

A `.dsc` is a `Dsc` container of atoms, framed as [Framing](fact-stream.md#framing) states: a `DscHeader` atom first, then atoms to the end of the stream.

An atom's identity is its `oneof` field number, and its body is the serialized protobuf message that number determines; no name appears on the wire. A runtime rejects a file whose first atom, tested by its field number and not by the file's first bytes, is not a `DscHeader`. An atom repeats where its [multiplicity](../atoms/index.md#multiplicity) permits. A reader steps over a body it cannot decode by its length alone.

*(Spec: [RDSC.1.1], [RDSC.1.2], [RDSC.1.3], [RDSC.1.4], [RDSC.1.6], [RDSC.2], [RDSC.2.5])*

### Canonical order

The canonical atom order is a grammar whose terminals are framed atoms, each named by its body message.

```ebnf
dsc            ::= header module_group* rete_network?
header         ::= DscHeader DialectInfo? CapabilityInfo
module_group   ::= DsSource schema_group* series_atom* rule_group*
                   ServiceDef* DocString* initial_atom* test_group*
initial_atom   ::= InitialFact | InitialCacheSeed
schema_group   ::= lifecycle_atom Slot* SchemaSource SchemaDef
lifecycle_atom ::= SchemaTtl | SchemaLogical
series_atom    ::= SeriesBackendWelfordEwma | SeriesBackendRingBuffer
                 | SeriesBackendMonotonicDeque | SeriesBackendFifoDeque
                 | SeriesBackendReservoir | SeriesBackendIntervalPulse
                 | SeriesBackendNumericIntegral
rule_group     ::= RuleCooldown? RuleSource RuleDebugName?
test_group     ::= TestCase TestFact* TestCacheSeed* response_stub* oracle_atom*
response_stub  ::= TestResponse TestReply*
oracle_atom    ::= OracleActivated | OracleEmit | OraclePublish | OracleCall
                 | OracleCacheSet | OracleCacheDelete
                 | OracleLog | OracleRetract | OracleWorkingMemory
                 | OracleExclusive
rete_network   ::= AlphaNode* BetaNode* TerminalNode* LineSpan*
```

`rete_network` is bundle-global: it occurs at most once, after every `module_group`. A schema takes exactly one lifecycle atom. The conditions no production states:

| Condition | Rule |
|---|---|
| order of module groups | ascending `module_id`, which is import-DAG topological order, leaf libraries first; a library's schemas and nodes load before any reference to them |
| order within a group | source order: the order of the declarations in the module's `.ds` file, and the order of its parts within one declaration |
| series backend atoms | a declaration's backend atoms follow its lines; a backing several lines share takes the place of the first line that selects it; backings one line selects first follow the `series_atom` alternation, then ascending window |
| `TerminalNode` atoms | the terminal-ordinal order of [Terminal order](../engine/lowering.md#terminal-order); the runtime numbers terminals from this sequence and from nothing else, the order of the `rule_group`s included |
| sorted lists | a call's and a service's kwargs in name order; the header's capability lists in number order |
| `DialectInfo` | present when the program's dialect is known |
| alphabet | only the `.dsc` atoms of the census; the event trace's atoms other than `SchemaDef` and `Slot` never appear |

*(Spec: [RDSC.8.1], [RDSC.8.1.1], [RDSC.8.4], [RDSC.8.5], [RDSC.8.6], [RDSC.8.8])*

### Section order

Every schema is registered before any network node is assembled, and rule metadata is attached by name once the network is assembled.

Every `module_group` precedes the bundle-global `rete_network`, so the schemas of the whole artefact precede the alpha nodes that name them. A `rule_group` precedes the `TerminalNode` that realizes its rule; its atoms accumulate and resolve against the known rules in one pass at the end. Network atoms reference each other by `node_id`, so a reference resolves wherever its target stands.

*(Spec: [RDSC.8.2], [RDSC.8.3], [RDSC.9.3])*

### References

A loader refuses, with `DS_ERR_DSC_DANGLING`, an artefact in which an atom it reads names something no atom in it defines.

| Atom | Names |
|---|---|
| a `rule_group`'s atoms | a rule a `TerminalNode` realizes |
| `AlphaNode` | a schema a `schema_group` registers |
| an `oracle_atom`, and every test atom but `TestCase` and `TestReply` | its `TestCase` |
| `TestReply` | the `TestResponse` stub it answers |

A reference is by name, resolved once the whole artefact is read. The loader decodes every body in full before it checks a name, so an artefact with a body defect and a dangling name is refused for the body. A runtime skips the test and oracle atoms and does not check what they name: the `.dstest` interpreter refuses the run, running no case, over a test atom that names a test or a stub no atom declares.

*(Spec: [RDSC.8.7], [RTIM.14.15])*

### Reproducibility

A compiler writes byte-identical `.dsc` output given the same sources under the same names, the same library inputs, the same compiler version and the same options.

A source's name is the one its `DsSource` atom records, and it is the only path an artefact carries. Nothing in an artefact depends on the time, the host or a file path, so `dsc_sha256` is a content address. Two conforming compilers need not agree byte for byte.

*(Spec: [RDSC.3.11])*

## Header

### DscHeader

The `DscHeader` atom carries the artefact's file-level metadata, and the runtime reads it before any other atom.

| Field | Holds |
|---|---|
| `compiler_version` (3) | the DS version that wrote the artefact |
| `dsc_sha256` (7) | the artefact's hash ([dsc_sha256](#dsc_sha256)) |
| `capabilities` (13), `dialect_def_sha256` (10) | the rest of the [binding tuple](dialect-binding.md#binding-tuple) |
| `fault_fact_sites` (14) | the program's fault-fact site count |

The loader checks `compiler_version` against the runtime's own `<major>.<minor>.` series before it processes any further atom, and refuses another series with `DS_ERR_DSC_VERSION`. The compiler writes `capabilities` with every capability the program's resolved settings set `true`, the empty list when none is. A `dialect_def_sha256` that is not 32 bytes is `DS_ERR_BND_INCOMPLETE`. The compiler computes `fault_fact_sites` from the rule network and writes it in every artefact, `0` where the network has no site. A runtime that pre-sizes its working memory sizes its fault-fact pool from it; any other runtime may ignore it.

*(Spec: [RDSC.3.1], [RDSC.3.2], [RDSC.3.5], [RDSC.3.7], [RDSC.3.10], [RDSC.9.2], proto: header.proto, Source: runtime/src/libds/dsc/loader.c)*

### dsc_sha256

`dsc_sha256` is the SHA-256 of the artefact's bytes with the `dsc_sha256` field present as 32 zero bytes.

The compiler computes it so and patches the real hash in. The field holds the raw 32 bytes. At load, the runtime recomputes the hash with the field zeroed and refuses an artefact whose `dsc_sha256` does not match with `DS_ERR_DSC_SEMANTIC`.

*(Spec: [RDSC.3.6])*

## Module identity

### module_id

Every per-module atom carries a `module_id`, a `uint32` naming the source module the atom belongs to.

The compiler assigns it from 1 in import-DAG topological order, leaves first and importer last; `0` is unset and never emitted. The runtime joins `DsSource`, `LineSpan`, `SchemaSource`, `RuleSource`, `SchemaTtl`, `SchemaLogical`, `Slot`, `Hydration`, `SchemaDef`, `RuleCooldown`, `DocString` and `TestCase` atoms across the bundle by `module_id`. `AlphaNode`, `BetaNode` and `TerminalNode` carry none and are joined by `node_id`. No per-module atom carries a display path: a tool resolves one through `DsSource[module_id].file`.

*(Spec: [RDSC.4.7])*

## Compression

### Compression

`DsSource` and `SchemaDef` bodies carry a `Compression` selector, and `COMPRESSION_NONE` is the only codec.

The compiler writes `COMPRESSION_NONE`, and the runtime, which carries no decompressor and links no compression library, refuses a body declaring any other codec with `DS_ERR_DSC_DECOMPRESS`. Body bytes are the same on every platform and toolchain. The refusal concerns the codec and not the version.

*(Spec: [RDSC.4.3], [RDSC.4.4], [RDSC.4.5], [RDSC.4.5.1], proto: common.proto)*

## Schema atoms

### Schema metadata

Schema atoms carry a schema's metadata, each keyed by the schema's [own name](inv:author:std:doc#lang/imports), and the runtime builds its schema descriptor from them.

The runtime registers each schema by name, and the alpha nodes that match on it reference it by that name. What the compiler writes into a schema group is [Schema group](../engine/lowering.md#schema-group).

*(Spec: [RDSC.5.1], [RDSC.5.2], [LIMP.13.2])*

### SchemaTtl

`SchemaTtl` declares a schema's default fact TTL, `ttl_ns`, in nanoseconds.

The compiler omits the atom for a schema with no TTL and never writes it with `ttl_ns = 0`.

*(Spec: [RDSC.5.3.1], [RDSC.5.3.2], [RDSC.5.3.3], proto: schema_ttl.proto)*

### SchemaLogical

`SchemaLogical` carries a schema's declared lifecycle in `lifecycle`: `EXPLICIT`, `LOGICAL` or `ACTIVATION`.

A schema without it is `ttl` and carries a `SchemaTtl` instead. The runtime refuses `UNSPECIFIED` with `DS_ERR_DSC_SEMANTIC`. It drives each lifecycle's retraction from the field: no engine retraction for `EXPLICIT`, justification withdrawal for `LOGICAL`, and every completion path of the asserting activation for `ACTIVATION`. The slots' identity roles do not carry the lifecycle.

*(Spec: [RDSC.5.4.1], [RDSC.5.4.2], [RDSC.5.4.3], [RDSC.5.4.5], proto: schema_logical.proto)*

### Slot

`Slot` carries one slot: `schema_name`, `slot_name`, `kind` and, for `SLOT_KIND_SCHEMA`, `schema_ref`, the referenced schema.

For every other kind the compiler leaves `schema_ref` empty and a runtime ignores it, in an artefact and in a recording alike. The runtime applies type-checked conversion by `kind` at assert and retract. `kind` is the declared type. A `Time`, `Date` or `Duration` slot is `SLOT_KIND_TIME`, `SLOT_KIND_DATE` or `SLOT_KIND_DURATION`, never `SLOT_KIND_INT`. Each is a signed 64-bit integer on the wire: a `Time` as UTC nanoseconds since the epoch with no zone offset, a `Date` as days since the epoch, a `Duration` as nanoseconds. A runtime stores and compares the three as it does `INT`, and reports the declared type where it reports a slot's type.

| `identity_role` | Slot |
|---|---|
| `IDENTITY_ROLE_KEY` | part of a `logical` schema's identity key |
| `IDENTITY_ROLE_MUTABLE` | a `logical` schema's payload |
| `IDENTITY_ROLE_ENGINE` | `ts`, outside the key and the no-op comparison |
| `IDENTITY_ROLE_UNSPECIFIED` | every slot of a non-`logical` schema |

The runtime reads a `logical` schema's identity key from its `KEY` slots alone, and compares its `KEY` and `MUTABLE` slots for the no-op test.

*(Spec: [RDSC.5.5.1], [RDSC.5.5.2], [RDSC.5.5.3], [RDSC.5.5.4], [RDSC.5.5.5], [RDSC.5.5.7], [RDSC.5.5.8], proto: slot.proto)*

### SchemaSource

`SchemaSource` records where a schema was declared: `file`, the `.ds` source path, and `line` and `col`, 1-indexed.

*(Spec: [RDSC.5.7.1], [RDSC.5.7.2], [RDSC.5.7.3], proto: schema_source.proto)*

### SchemaDef

`SchemaDef` carries `proto_source`, the `.proto` text the compiler generates from the schema's declaration: the cross-boundary shape of the schema's facts.

The message is the schema's `NAME`, and the package is `ds.dsc.user.v1`, followed for a library's schema by the library's path: `plant.sensors.Reading` is the message `Reading` in `package ds.dsc.user.v1.plant.sensors`. The schema's [own name](inv:author:std:doc#lang/imports) is that path and `NAME`.

Every nullable slot's field is a proto3 `optional` field, and no other field is. A field's type is its slot kind's:

| Slot kind | proto3 type |
|---|---|
| `SLOT_KIND_INT`, `_TIME`, `_DATE`, `_DURATION` | `int64` |
| `SLOT_KIND_FLOAT` | `double` |
| `SLOT_KIND_STRING`, `_JSON` | `string` |
| `SLOT_KIND_BOOL` | `bool` |
| `SLOT_KIND_SCHEMA` | `uint64` |
| `SLOT_KIND_BYTES` | `bytes` |

A synthetic schema's `proto_source` is as [Synthetic identifiers](../overview/runtime-architecture.md#synthetic-identifiers) states. The runtime stores the text verbatim. The `.proto` and the schema's `Slot` atoms describe the same slots, and the `.proto` describes no lifecycle.

*(Spec: [RDSC.5.8.1], [RDSC.5.8.2], [RDSC.5.8.3], [RDSC.5.8.5], [RDSC.5.8.7], proto: schema_def.proto)*

## Series backend atoms

### Backend selection

A series backend atom declares the runtime state for one backing of a series declaration's observation lines, keyed by `(schema_name, slot_name, identity_slot_name)`.

Which backings the compiler emits is [Series declaration](../engine/lowering.md#series-declaration). An empty `identity_slot_name` is `by: none`, one allocation per (schema, slot, module); a non-empty one names the bound schema's slot that is the per-key dimension.

*(Spec: [RDSC.5a.1], [RDSC.5a.2], [RDSC.5a.3])*

### Backend keying

Each backend atom is unique per `(schema_name, slot_name, identity_slot_name, atom, window_ns)` per module, and the runtime keys the state it allocates on the same tuple.

One declaration may observe one slot through several backings, or through one backing at several windows; each is a parallel backend keyed by the full tuple. Different modules may emit backend atoms for the same slot, and each module's atoms apply only within that module's load.

*(Spec: [RDSC.5a.8.1], [RDSC.5a.8.2], [RDSC.5a.8.3])*

### Backend reads

A backend's aggregation read computes its value from stored state as of the step's clock, over the window at the firing, and is idempotent.

A read may evict: drop the samples that have left the window at the step's clock. Every read at that clock or later excludes those samples, so whether a read evicts first changes no answer. A read makes no other change to the state: no lazy decay, sketch-buffer flush or compaction. Where libds evicts is [evict_stale](../values/series-backends.md#evict_stale).

*(Spec: [RDSC.5a.1a])*

### Backend atoms

Each backend atom's body is its `.proto`.

| Atom | Serves | `window_ns` | `max_samples` |
|---|---|---|---|
| `SeriesBackendWelfordEwma` | every `all_time` aggregation the series selection matrix backs with it, cumulative from boot | `0` | none |
| `SeriesBackendRingBuffer` | exact samples on `sliding <dur>` | `> 0` | the series' `capacity`; `0` leaves the window the only bound |
| `SeriesBackendMonotonicDeque` | exact `min` and `max` on `sliding` | `> 0` | the series' `capacity`; `0` leaves the window the only bound |
| `SeriesBackendFifoDeque` | `first`, `bool_or` and `bool_and` on `sliding` | `> 0` | caps the deque |
| `SeriesBackendReservoir` | the bag aggregations on `sample <n>` | `0` | `n` |
| `SeriesBackendIntervalPulse` | `active_fraction` on `sliding` | `> 0` | the series' `capacity`, `0` for none; a full backing refuses |
| `SeriesBackendNumericIntegral` | `integral` on `sliding` or `all_time` | `> 0` on `sliding`, `0` on `all_time` | the series' `capacity`, `0` for none; a full backing refuses |

| Atom | Behaviour |
|---|---|
| `SeriesBackendWelfordEwma` | `persist_ns = 0` is live-only; a non-zero value forwards each absorbed sample to the integrator's sample callback |
| `SeriesBackendRingBuffer` | `element_type` is the slot's inferred element type, converted with type checks at absorption; a non-zero `max_samples` caps the samples each identity retains within the window; an identity's state is evicted when no sample for it has been absorbed for `window_ns` |
| `SeriesBackendMonotonicDeque` | holds the monotonic subsequence of in-window candidates: the query reads the front in O(1), insert and evict are amortised O(1), state is O(window·rate); updates and eviction are value comparisons and integer timestamp tests, bit-exact on every platform given event-trace order |
| `SeriesBackendFifoDeque` | preserves arrival order; `bool_*` are an in-window true-count, O(1) to query; `first` reads the front; `element_type` (tag 4) types `first` and limits `bool_*` to `Bool` slots, and puts `window_ns`, `persist_ns` and `max_samples` at tags 5, 6 and 7; bit-exact on every platform given event-trace order |
| `SeriesBackendReservoir` | a uniform-random reservoir of `n` over all-time history, O(`n`) state, no time-based eviction; retention uses a fixed-seed `xorshift64` PRNG (seed `0x9e3779b97f4a7c15`) advanced once per absorbed sample in event-trace order; quantiles sort a scratch copy; bit-exact on every platform |
| `SeriesBackendIntervalPulse` | the slot is `Bool`, so the body carries no element type; `null_policy` is the series' `nulls:` policy |
| `SeriesBackendNumericIntegral` | `element_type` is the slot's, `Float` or `Int`; `time_model` is `SERIES_TIME_MODEL_SLIDING` or `SERIES_TIME_MODEL_ALL_TIME`; `gap_policy` is the series' gap policy and `null_policy` its `nulls:` policy, and neither stands for the other |

*(Spec: [RDSC.5a.2], [RDSC.5a.4.1], [RDSC.5a.4.2], [RDSC.5a.4.3], [RDSC.5a.4.4], [RDSC.5a.5.1], [RDSC.5a.5.2], [RDSC.5a.5.3], [RDSC.5a.5.4], [RDSC.5a.5.5], [RDSC.5a.7d.1], [RDSC.5a.7d.2], [RDSC.5a.7d.3], [RDSC.5a.7d.4], [RDSC.5a.7e.1], [RDSC.5a.7e.2], [RDSC.5a.7e.3], [RDSC.5a.7e.4], [RDSC.5a.7g.1], [RDSC.5a.7g.2], [RDSC.5a.7g.3], [RDSC.5a.7g.4], [RDSC.5a.9.1], [RDSC.5a.9.2], [RDSC.5a.10.1], [RDSC.5a.10.2])*

## Rule atoms

### Rule metadata

Rule atoms carry the rule metadata the node graph does not encode, each keyed by the rule's name.

The runtime correlates them with the rules the `TerminalNode` atoms realize by exact name match.

*(Spec: [RDSC.6.1], [RDSC.6.2])*

### RuleCooldown

`RuleCooldown` declares a rule's cooldown window, `window_ns`, in nanoseconds.

A rule with no `RuleCooldown` has no cooldown. The gate that applies the window is the terminal's [fire guard](#fire-guard), and each activation key has its own window.

*(Spec: [RDSC.6.5.1], [RDSC.6.5.2], [RDSC.6.5.3], [RDSC.6.5.4], proto: rule_cooldown.proto)*

### RuleSource

`RuleSource` records where a rule was declared: `line` and `col`, 1-indexed.

It carries no source path: `module_id` names the rule's module, and the path is that module's `DsSource` `file`.

*(Spec: [RDSC.6.7.1], [RDSC.6.7.2], [RDSC.6.7.3], proto: rule_source.proto)*

### RuleDebugName

`RuleDebugName` carries `name_template`, the display-name template the debug adapter labels a rule's activation threads with.

A `{binding.slot}` placeholder is replaced with the activation's bound value for that slot when the activation is created, and literal text outside `{…}` passes through. The compiler generates the template from the rule's patterns: the rule name, `(`, one entry per contributing pattern in source order separated by `, `, and `)`. An entry is `<binding>={<binding>.<slot>}`, where `<slot>` is the first `key` slot the schema declares, or its first slot when it declares no `key` slot. A pattern with no binding written contributes its synthetic name; a pattern whose schema declares no slots, and a negated pattern, contribute nothing. With no entry the template is empty, and the compiler omits the atom. The runtime treats an absent atom as an empty template and displays `{rule_name} #{sequence}`.

*(Spec: [RDSC.6.8.1], [RDSC.6.8.2], [RDSC.6.8.3], [RDSC.6.8.4], [RDSC.6.8.5], [RDSC.6.8.6], [RDSC.6.8.7], [RDSC.6.8.9], proto: rule_debug_name.proto)*

## Service atoms

### ServiceDef

`ServiceDef` carries one service declaration: its dotted `name`, its kwarg list and its response schema, when it has one.

How the runtime binds the integrator's callbacks to them is [Compile-time inputs](../overview/runtime-architecture.md#compile-time-inputs). `name` is the fully qualified dotted path, such as `light.turn_on`; its first segment is the service domain, and a flat-named service has one segment. A service is identified by its name alone: an artefact carries one `ServiceDef` per service, and the compiler never writes one with an empty name or two with the same name. `module_id` attributes a service to the module that declared it and is not part of its identity.

A kwarg's `default_value` is the canonical text of the value the service receives when a call omits the kwarg, in the storage type of the kwarg's declared type. It is empty when `has_default` is false.

| Declared type | `default_value` |
|---|---|
| `Int` | the integer in decimal, `-` first when negative |
| `Float` | the Float's canonical text, from an `Int` literal too |
| `String` | the value in double quotes, each `"` written `\"` and each `\` written `\\` |
| `Bool` | `true` or `false` |
| a unit symbol | the quantity in that unit: decimal where the unit's dimension declares `storage int64`, otherwise the Float's canonical text |
| a dimension or scalar-group name | the quantity in the dimension's base unit, written as for a unit symbol |

*(Spec: [RDSC.6a.1], [RDSC.6a.2.1], [RDSC.6a.2.2], [RDSC.6a.2.3], [RDSC.6a.2.4], [RDSC.6a.2.6], proto: service_def.proto)*

## Initial-block atoms

### InitialFact and InitialCacheSeed

An `InitialFact` atom carries one fact item of a program's `initial:` block, and an `InitialCacheSeed` atom one cache item.

`module_id` names the module whose block holds the item, and `source_order` the item's place in that block, counted over its fact and cache items together. A runtime applies the items in ascending `module_id`, then ascending `source_order`. A fact item's slot values and a cache item's value are `TestSlotLiteral`s, as a `TestFact` carries them; a cache item's `slot_name` is unused.

*(Spec: [RDSC.17.1], [RDSC.17.2], proto: initial.proto)*

## Network atoms

### Rule network

The rule network is the `AlphaNode`, `BetaNode` and `TerminalNode` atoms, one per node, whose content is [Network atoms](../engine/rete-network.md#network-atoms).

No atom carries rule-network source text. The node graph carries the order in which nodes are linked, so a reader does not order atom bodies, and a file may split its network across atoms freely. The network is optional: a program that declares no rule compiles to an artefact with no network atom, and the runtime loads it, registers its schemas and fires no rule.

*(Spec: [RDSC.4.1], [RDSC.4.6], [RDSC.4a.1], [RDSC.4a.2])*

### node_id

Every network atom carries `node_id`, a `uint32` unique across all three atom types within a bundle; `0` is null.

`BetaNode.right_alpha_id`, `BetaNode.left_parent_id` and `TerminalNode.parent_beta_id` reference nodes by `node_id`, and the loader builds one map keyed by it over all three types. `AlphaNode` references its schema by `schema_name`, and `TerminalNode` its rule by `rule_name`, each resolved against the atoms already registered. Neither repeats the schema's structure or the rule's metadata.

*(Spec: [RDSC.4a.3], [RDSC.4a.4])*

### Network load order

The loader processes the network atoms in one forward pass, and the compiler emits every `AlphaNode` before any `BetaNode`.

`BetaNode`-to-`BetaNode` parent references and `BetaNode`-to-`TerminalNode` wiring accumulate as pending references, resolved in one sweep after the stream ends. The loader then seeds every root beta, one with `left_parent_id == 0`, with a nil token, so a right activation produces a single-fact token at pattern index 0. The steps are [Load](../engine/rete-network.md#load).

*(Spec: [RDSC.4a.5])*

### AlphaNode

An `AlphaNode` admits the facts of its `schema_name` that pass every one of its tests; with no test it admits every fact of the schema.

`schema_name` is never empty: a loader refuses an empty one with `DS_ERR_DSC_SEMANTIC` while decoding the body, before it looks any name up. Regex flags travel inside the pattern as an RE2 flag group; `AlphaTest` has no flags field. The loader compiles each regex pattern at load. A loader refuses, with `DS_ERR_DSC_SEMANTIC`, an `AlphaTest`:
- whose `kind` is no member of `AlphaTestKind`;
- of kind `ALPHA_TEST_EQ` or `ALPHA_TEST_CMP` with no `literal`, or a `literal` that sets no member of its `value`;
- of kind `ALPHA_TEST_CMP` whose `op` is no member of `AlphaCmpOp`;
- of kind `ALPHA_TEST_REGEX` whose `pattern` is empty or does not compile;
- whose `slot_index` is above 254.

Each of these but a pattern that does not compile is refused as the body is decoded. How the engine evaluates the tests, and when a test faults, is [Alpha tests](../engine/rete-network.md#alpha-tests).

*(Spec: [RDSC.4a.6], [RDSC.4a.6.1], [RDSC.4a.6.2], [RDSC.4a.6.3], proto: alfa.proto)*

### BetaNode

A `BetaNode` is one join node; `left_parent_id == 0` marks a root beta, the first or only pattern of a rule.

`join_tests` are `Expr` trees evaluated against the left token and the right candidate fact. `is_negative` makes the node a [NOT node](../engine/rete-network.md#not-node).

*(Spec: [RDSC.4a.7], proto: beta.proto)*

### TerminalNode

A `TerminalNode` is the leaf of a rule's network, carrying its `rule_name` and its RHS actions.

`rule_name` resolves the rule's cooldown through `RuleCooldown`, and the terminal repeats none of it. Rule order is the [terminal order](../engine/lowering.md#terminal-order), and a logical assert's justifier is [Justification](../engine/truth-maintenance.md#justification). What each action does when the terminal fires is [Action list](../engine/agenda-and-actions.md#action-list).

*(Spec: [RDSC.4a.8], proto: term.proto)*

### Fire guard

A `TerminalNode`'s `fire_guard` carries at most two parts: a condition and a rate gate.

| Part | Holds |
|---|---|
| condition | a `where` that reads a clock or a series, an `after` follow-up's included, or a positive pattern's `within` window, moved off the pattern and read under each pump's sample |
| rate gate | a `CallExpr` whose `op` is `FN_RATE_ALLOW` |

The guard is the condition alone, the rate gate alone, or a `BinopExpr` of `BINOP_AND` whose `left` is the condition and `right` the rate gate. The condition holds no `FN_RATE_ALLOW` call. A runtime tells the parts apart by these shapes and by the callee: a top-level call is the rate gate only when its `op` is `FN_RATE_ALLOW`.

The runtime evaluates the condition when it selects the activation, under the pump's clock sample and series snapshot, and lets the activation fire only when it is `true`. `false` and `null` both withhold it. A withheld activation is not a firing: it emits no event, is not counted, and its rate gate is not evaluated. The runtime evaluates the rate gate after `RULE_FIRE_BEGIN` and before the first action, exactly once per firing, and only when the condition, where there is one, was `true`. The gate records the firing it admits. `null` admits, and `false` suppresses the actions while the firing stands. A firing whose actions the gate suppressed is still the match's firing, and the match does not fire again on a later tick while it persists. The gate's state is [Fire guard](../engine/agenda-and-actions.md#fire-guard).

*(Spec: [RDSC.4a.8.2.1], [RDSC.4a.8.2.2], [RDSC.4a.8.2.3])*

### Indexes

A slot or pattern index is a byte on the wire, held in a `uint32` field: 0 to 254 name a slot or pattern, and 255 is a marker or nothing.

| Field | 255 |
|---|---|
| `VarExpr.pattern_index`, `Expr.entry_stamp` | the beta's right-side candidate fact |
| `VarExpr.slot_index` | the fact itself, as a fact-reference value |
| `AlphaTest.slot_index`, `SlotAssign.slot_index`, `Action.withdraw_pattern_index` | no marker |

`VarExpr(pattern_index = 255, slot_index = 255)` is the candidate right fact as a reference. A loader refuses, with `DS_ERR_DSC_SEMANTIC`, an atom holding an index above 255 in a field with a marker, or above 254 in a field without one. An index within its field's range that names no slot of the fact's schema, or no pattern of the rule, is not refused at load. Where the engine uses it, the engine raises an `EngineError` naming the node or rule and halts the tier: `ENGINE_FAULT_PATTERN_INDEX` for a pattern index, read or named by a `withdraw`, and `ENGINE_FAULT_ARTEFACT_LIED` for a slot index read by an `AlphaTest` or a `VarExpr`, or written by a `SlotAssign`. A faulting `AlphaTest` is evaluated as [Alpha tests](../engine/rete-network.md#alpha-tests) states.

*(Spec: [RDSC.4a.9.1], proto: rete_expr.proto)*

### Builtin calls

A `CallExpr` names a member of `BuiltinFn` in `op` and carries its operands in `args`.

The compiler emits an op only at a site where a clause has it emit that op, and with an operand count the op admits. A runtime does not check at load how many operands a call carries. A call that reaches evaluation with fewer operands than its op takes, more than an op of fixed count takes, or in a shape its op does not admit, raises an `EngineError` of `ENGINE_FAULT_ARTEFACT_LIED` and halts the tier. A `CallExpr` stands as an action's `expr` or inside an expression, a fire guard's included. At load, a runtime refuses with `DS_ERR_FN_NOT_FOUND` an artefact holding a `CallExpr` whose op it has no handler for at the site where it stands. Each op's operand count is [RDSC.4a.9.5](inv:specs:std:label#rdsc-4a-9-5), and every runtime's view of the counts is generated from it, never written by hand.

A `CallExpr` of `FN_CALL` carries 2 + 2n operands: the service name as a string literal; the correlation; then one pair per supplied argument, its name as a string literal and its value expression. The pairs are in strictly ascending order of name, compared by UTF-8 bytes, with no name twice, and the runtime reads each argument's name from its pair.

*(Spec: [RDSC.4a.9.3], [RDSC.4a.9.4], proto: rete_expr.proto, proto: builtin_fn.proto)*

### Operator enums

`BinopOp` and `UnopOp` in `proto/rete_expr.proto` are the operator enums, and no other enum encodes a DS operator.

Join tests and action expressions share the `Expr` message. `proto/alfa.proto` does not import it: an alpha test is an `AlphaTest`, not an expression tree.

*(Spec: [RDSC.4a.9], proto: rete_expr.proto, proto: alfa.proto)*

## Source atoms

### Source preservation

The source-preservation atoms keep canonical source forms in the artefact for debuggers, inspectors and replayers.

The runtime does not need them to operate, and a loader may skip them in a fast-load configuration. The compiler emits them in production builds.

*(Spec: [RDSC.14.1])*

### DsSource

`DsSource` carries the original DS source text of one source module, verbatim, comments included.

`file` is the module's name: for the file the compiler was asked to compile, the name the command line gives it; for a library read from the search path, the path it was read from, as the search-path entry spells it; for a module handed to the compiler with no path, a synthetic name in angle brackets, such as `<in-memory:lib.ds>`. The importing file and each transitively loaded library each have a `DsSource`. `file` may repeat across modules; the runtime indexes by `module_id`.

*(Spec: [RDSC.14.2.1], [RDSC.14.2.2], [RDSC.14.2.3], [RDSC.14.2.4], [RDSC.14.2.5], proto: ds_source.proto)*

### LineSpan

`LineSpan` maps a network node, by `node_id`, to the DS source range of the construct that made it.

`ds_line` and `ds_col` are 1-based; `module_id` names the owning module. The compiler emits one `LineSpan` per beta and terminal node it attributes to a source construct, and none for an alpha node, which belongs to no single rule. A node the compiler makes for itself carries none: a capture view, a continuation's response pattern, a timer's beta, and the terminal of an `after` follow-up or of a call's sibling rule. A predicate on a shared alpha is attributed by its pattern's beta `LineSpan`, and the schema by `SchemaSource`. A `LineSpan` whose `node_id` names no emitted network node makes the file malformed. The runtime uses the mapping to report a node's runtime diagnostic at its DS source line and column.

*(Spec: [RDSC.14.3], [RDSC.14.3.1], [RDSC.14.3.2], [RDSC.14.3.3], [RDSC.14.3.4], [RDSC.14.3.5], [RDSC.14.3.6], proto: line_span.proto)*

### DocString

`DocString` records the docstring of one schema, slot or rule as metadata keyed to its declaration.

`target` names the documented declaration's kind, `schema_name`, `slot_name` and `rule_name` carry its identity, and `text` is the UTF-8 docstring. Its source location is inline, `ds_line` and `ds_col`. `DocString` is the only wire home of docstrings; `Slot` has no docstring field. The engine never decodes it: a runtime that does not consume docs skips it, and its presence is never a load error. It belongs to the source-metadata tier with `DsSource` and `LineSpan`, and an artefact may carry `DocString` with `DsSource` stripped. The compiler emits `DocString` atoms by `module_id`, then declaration order.

*(Spec: [RDSC.14.4.1], [RDSC.14.4.2], [RDSC.14.4.3], [RDSC.14.4.4], [RDSC.14.4.5], [RDSC.14.4.6], [RDSC.14.4.7], [RDSC.14.4.8], proto: doc_string.proto)*

## Settings atoms

### DialectInfo

`DialectInfo` records `name`, the dialect the program's `use` directive named; it is informational.

The runtime executes under the settings `CapabilityInfo` records, and the binding compares those, never the name. `DialectInfo` is file-level, with no `module_id`: only the program has a dialect. An artefact without it loads, with the dialect unknown.

*(Spec: [RDSC.15.1], [RDSC.15.2], [RDSC.15.3], [RDSC.15.4], [RDSC.15.5], proto: dialect.proto)*

### CapabilityInfo

`CapabilityInfo` records the program's resolved settings, `enabled`, and the capabilities its content requires, `requires`; the runtime executes under the recorded settings.

They, and nothing an integrator configures, select the engine's strategy. `enabled` lists every capability whose setting is `true`; every capability absent from it is `false`. The compiler lists in `requires` exactly the capabilities whose code the content needs, and every strategy that is `true`. Each list is ascending in `Capability` order, without repetition and without `CAPABILITY_UNSPECIFIED`, and `requires` is a subset of `enabled`. A runtime rejects a body that breaks any of these with `DS_ERR_DSC_SEMANTIC`. Every artefact carries one: a runtime rejects an artefact without it with `DS_ERR_DSC_SEMANTIC`. It is file-level, with no `module_id`.

Before decoding any body but the header's and `CapabilityInfo`'s, the runtime compares `requires` with the capabilities it was built with. A member it lacks, a `Capability` value it does not know included, fails the load with `DS_ERR_DSC_CAPABILITY_ABSENT`, naming the lowest lacking capability as a value of `Capability`. The code means only that the runtime was built without the code. A runtime trusts `requires` and does not check it against the content.

*(Spec: [RDSC.16.1], [RDSC.16.2.1], [RDSC.16.2.2], [RDSC.16.2.3], [RDSC.16.2.4], [RDSC.16.2.6], [RDSC.16.2.7], [RDSC.16.2.8], proto: capabilities.proto)*

## Loading

### Atom dispatch

The loader reads atoms in stream order: for each, the outer frame, then the inner `Atom`'s `oneof` tag, and dispatches the body bytes to the handler registered for that field number.

Reading in stream order does not mean acting in stream order. Bodies are decoded by the protobuf library [Link dependencies](../overview/libds-modules.md#link-dependencies) names. Dispatch over the atoms is O(N) in their count, and each atom's decode O(M) in its body's size.

*(Spec: [RDSC.9.1], [RDSC.12.1], [RDSC.12.4])*

### Unknown atoms

An atom whose field number the loader has no entry for is disposed of by its [band](fact-stream.md#bands).

| Band | Loader |
|---|---|
| 256–2047 | skips the frame and logs at info level, category `dsc-load`, with the field number and the byte offset |
| 128–255 | rejects with `DS_ERR_DSC_VERSION` |
| 1–127 | rejects with `DS_ERR_DSC_VERSION`; no `.dsc` atom occupies the inject band |

A loader that knows the atom rejects it on its container legality instead ([Container legality and stream class](fact-stream.md#container-legality-and-stream-class)). Every additive atom is allocated in the skip band. Renaming an atom's body message, with its field number and fields kept, is no format change.

*(Spec: [RDSC.9.4], [RDSC.16.3.7b], Source: runtime/src/libds/dsc/loader.c)*

### Load errors

The loader errors on an atom whose body fails protobuf decode, on a decoded atom that breaks a per-atom rule, and on a truncated stream.

A body is decoded before any other rule judges it. A body that fails decode is `DS_ERR_DSC_DECODE` whatever other defect it carries; a body that decodes and breaks another rule is refused with the code that rule names. A decode error names the atom, the byte offset and the decoder's reason. A per-atom rule error names the atom, the offending field and the violated rule's ID. The loader reads an `Expr` nested deeper than 48 as its tag and length in its parent and no further, and refuses the body with `DS_ERR_DSC_SEMANTIC` whatever the bytes inside that `Expr` hold.

*(Spec: [RDSC.9.5], [RDSC.9.6], [RDSC.9.7], [RDSC.11.3], [RDSC.11.4])*

### Decoded values

The loader holds each body as protobuf decodes it, and refuses some values a decode admits.

| Body | Loader |
|---|---|
| a singular message field, or a message member of a oneof, occurring more than once at any depth | refuses with `DS_ERR_DSC_DECODE` |
| `DscHeader`'s `dsc_sha256` occurring more than once | refuses with `DS_ERR_DSC_DECODE` |
| a scalar field occurring more than once | holds the last occurrence |
| a repeated field | holds every occurrence, in order |
| a oneof with more than one member present | holds the member that occurs last |
| a `string` field, at any depth read, that is not well-formed UTF-8 or holds U+0000 | refuses with `DS_ERR_DSC_DECODE`, judging every occurrence; it neither repairs nor truncates the string |
| `DsSource`'s `data` or `SchemaDef`'s `proto_source`, under `COMPRESSION_NONE`, that is not well-formed UTF-8 or holds U+0000 | refuses with `DS_ERR_DSC_DECODE`, judging the field's value |
| a NaN of any payload in `AlphaLiteral`'s `float_val`, `Expr`'s `lit_float`, `Slot`'s `tolerance`, or a `TestSlotLiteral`'s `f_val` | refuses with `DS_ERR_DSC_SEMANTIC`; an infinity is not refused |
| a `Slot` `tolerance` less than zero, `-inf` included | refuses with `DS_ERR_DSC_SEMANTIC`; `-0.0` is not less than zero |

A value is judged as the decoded atom holds it: a NaN that a later occurrence, or a later member of its oneof, replaces is not refused.

*(Spec: [RDSC.9.5], [RDSC.9.10], [RDSC.9.11], [RDSC.9.12])*

### Failed load

A load that fails once it has begun reading the artefact spends the engine.

It returns the error that stopped it and sets the engine's halt latch. It raises no `EngineError` and records no stream event, and the loader undoes nothing it applied: the engine's state is undefined. A load refused before it reads the artefact changes nothing: one on an engine that already holds an artefact or has emitted a stream event, and one on an engine already halted.

An allocation that fails during a load fails it with `DS_ERR_OOM`, which spends the engine. A runtime absorbs such a failure only where the allocation reserves capacity the engine also grows on demand, and the loaded program and every value and event are then what they would have been without it. A load never absorbs a failure by dropping anything the artefact carries, or by leaving the engine on a slower path for its life.

*(Spec: [RDSC.9.8], [IRET.18.2])*

### Check order

A load checks, in this order, the capabilities the build lacks, then the integration's admission policy, then, where the load pairs artefacts, the [binding](dialect-binding.md#binding-check).

The first failure is the one reported.

*(Spec: [RDSC.16.2.9])*

### Trusted input

A `.dsc` is trusted input: its provenance is the integration's, and a runtime spends no load time or memory analysing it for malicious construction.

A loader may refuse an artefact for compatibility, the version series or an unknown atom's band, or for a cheap structural need of its own, and never on the ground that it may be hostile. Heavier verification belongs to a separate tool, never to a load. A program a trace embeds is trusted the same way, as are a recorded fact stream and a `FactExternal`, which the integration accepts only from a source it trusts. Whatever bytes it is handed, a loader loads or refuses them, and an engine running what it loaded faults rather than reading or writing outside what it allocated.

*(Spec: [RDSC.9.9])*

## Version discipline

### Version series

A DS persistent format is read only by a binary of the `<major>.<minor>.` series that wrote it; an artefact of any other series is a fatal error, not a translation event.

The policy governs every artefact that persists across a process or a release boundary, a `.dsc` and a fact-stream recording among them, each of which records the DS version that wrote it. Its refusal has no opt-out. Live IPC between sibling tiers is the integrator's transport, carrying whatever the integrator encodes, and has no version to refuse. The behaviour an artefact describes is checked by its [binding tuple](dialect-binding.md#binding-tuple).

*(Spec: [RARC.4.1], [RARC.4.5], [RARC.4.6], [RARC.4.7])*
