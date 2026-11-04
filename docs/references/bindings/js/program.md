<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Program

## Schema views

### `schemas`

**`get schemas(): ReadonlyMap<string, SchemaInfo>;`**

The schemas the engine knows, by own name, read through [`ds_engine_schema_count` and `ds_engine_schema_at`](inv:integrator:std:doc#facts/schemas).

Internal schemas are included. It iterates in the engine's order. The map and its frozen values are a snapshot, the same at each read until [`loadDsc`](engine.md#loaddsc) or [`replayStream`](recording.md#replaystream) runs.

```javascript statement
const schema = engine.schemas.get("Reading");
console.log(schema?.ttlNs, engine.rules.size);
```

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js)*

### `SchemaInfo`

**`export type SchemaInfo = { name: string; lifecycle: Lifecycle; ttlNs: bigint; slots: SlotInfo[]; };`**

A plain object read by the [`ds_schema_get_*`](inv:integrator:std:doc#facts/schemas) calls.

| Field | Holds |
|---|---|
| `lifecycle` | a [`Lifecycle`](#lifecycle) |
| `slots` | an array of [`SlotInfo`](#slotinfo), in declaration order |

`name` and `ttlNs` hold what their calls read.

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c)*

### `SlotInfo`

**`export type SlotInfo = { name: string; type: string; identity: "key" | "mutable" | "engine" | null; nullable: boolean; };`**

A plain object of [`ds_slot_desc_t`](inv:integrator:std:doc#facts/schemas).

`type` is a [`SlotType`](#slottype), or the schema a fact-reference slot names. `identity` is `"key"`, `"mutable"` or `"engine"` for `DS_IDENTITY_KEY`, `DS_IDENTITY_MUTABLE` or `DS_IDENTITY_ENGINE` of [`ds_identity_role_t`](inv:integrator:std:doc#facts/schemas), and `null` for any other role.

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c)*

### `SlotType`

**`export type SlotType = "Int" | "Float" | "String" | "Bool" | "Json" | "Bytes" | "Time" | "Date" | "Duration";`**

A slot's declared type: the [`ds_slot_type_t`](inv:integrator:std:doc#facts/schemas) members other than `DS_SLOT_TYPE_SCHEMA`.

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c)*

### `Lifecycle`

**`export type Lifecycle = "logical" | "ttl" | "internal";`**

A schema's lifecycle: [`ds_schema_lifecycle_t`](inv:integrator:std:doc#facts/schemas).

`"internal"` marks a built-in fault schema, `ComputationError` or `TypeError`.

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c, Spec: [NDBG.2.2], [LSCP.2.6.2])*

## Rule metadata

### `rules`

**`get rules(): ReadonlyMap<string, RuleMeta>;`**

The loaded program's rules, by rule name, read through [`ds_engine_rule_meta_count` and `ds_engine_rule_meta_at`](inv:integrator:std:doc#introspection/metadata).

It iterates in the order the program declares them. The map and its frozen values are a snapshot, the same at each read until [`loadDsc`](engine.md#loaddsc) or [`replayStream`](recording.md#replaystream) runs.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js)*

### `RuleMeta`

**`export type RuleMeta = { ruleName: string; coolWindowNs: bigint | null; srcFile: string | null; srcLine: number | null; srcCol: number | null; debugNameTemplate: string | null; };`**

A plain object of [`ds_rule_meta_view_t`](inv:integrator:std:doc#introspection/metadata).

`coolWindowNs` is `null` when `has_cool` is false, `srcFile`, `srcLine` and `srcCol` when `has_srcr` is false, and `debugNameTemplate` when `has_dnam` is false.

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c)*

## Line spans

### `lineSpans`

**`get lineSpans(): readonly LineSpan[];`**

The loaded program's line spans, in the artefact's order, read through [`ds_engine_line_span_count` and `ds_engine_line_span_at`](inv:integrator:std:doc#introspection/metadata).

The array and its values are frozen, and the same at each read until [`loadDsc`](engine.md#loaddsc) or [`replayStream`](recording.md#replaystream) runs. It is empty before a load.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js)*

### `lineSpan`

**`lineSpan(nodeId: number): LineSpan;`**

Returns one node's frozen line span, through [`ds_engine_line_span_find`](inv:integrator:std:doc#introspection/metadata).

A `nodeId` that is not an integer in 0 to 2^32-1 throws `TypeError`. A node with no span throws a [`DsError`](errors.md#dserror) with `DS_ERR_NOT_FOUND`.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c)*

### `LineSpan`

**`export type LineSpan = { nodeId: number; moduleId: number; file: string | null; line: number; column: number; };`**

A plain object of [`ds_line_span_view_t`](inv:integrator:std:doc#introspection/metadata).

`file` is `null` when the artefact carries no source for the module. `line` and `column` hold `ds_line` and `ds_col`.

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c)*
