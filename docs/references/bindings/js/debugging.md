<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Debugging

## Justifiers

### `justifiers`

**`justifiers(fact: Fact | Int64): Justifier[];`**

Lists the activations that logically support a fact, through [`ds_engine_get_justifiers`](inv:integrator:std:doc#introspection/network), under its [pause contract](inv:integrator:std:doc#introspection/network).

A [`Fact`](facts.md#fact) is taken by its id. An id that is negative, above 64 bits or not an [`Int64`](facts.md#int64) throws `TypeError`.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c)*

### `Justifier`

**`export type Justifier = { timetag: bigint; ruleName: string; };`**

A plain object of one entry of [`ds_engine_get_justifiers`](inv:integrator:std:doc#introspection/network).

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c)*

## Network

### `reteNetwork`

**`reteNetwork({ ruleFilter, includeOccupancy }?: { ruleFilter?: string | null; includeOccupancy?: boolean; }): ReteNetwork;`**

Returns the Rete network, through [`ds_engine_rete_network`](inv:integrator:std:doc#introspection/network), under its [pause contract](inv:integrator:std:doc#introspection/network).

`ruleFilter` defaults to `null`, and `includeOccupancy` to `false`. A `ruleFilter` that is neither a string nor `null`, or that holds U+0000, throws `TypeError`.

```javascript statement
const { nodes, edges } = engine.reteNetwork({ includeOccupancy: true });
console.log(nodes.length, edges.length);
```

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c)*

### `ReteNetwork`

**`export type ReteNetwork = { nodes: ReteNode[]; edges: ReteEdge[]; };`**

The nodes and edges the walk reported.

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c)*

### `ReteNode`

**`export type ReteNode = { id: string; kind: string; label: string; filter: string; occupancy: number | null; isNegative: boolean; };`**

A plain object of the arguments of [`ds_rete_node_cb_t`](inv:integrator:std:doc#introspection/network).

`occupancy` is `null` for the `UINT32_MAX` libds gives for not populated.

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c)*

### `ReteEdge`

**`export type ReteEdge = { fromId: string; toId: string; };`**

A plain object of the arguments of [`ds_rete_edge_cb_t`](inv:integrator:std:doc#introspection/network).

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c)*

## Match trace

### `reteMatchTrace`

**`reteMatchTrace(fact: Fact | Int64): MatchStep[];`**

Traces a fact through the alpha nodes, through [`ds_engine_rete_match_trace`](inv:integrator:std:doc#introspection/network), under its [pause contract](inv:integrator:std:doc#introspection/network).

A [`Fact`](facts.md#fact) is taken by its id. An id that is negative, above 64 bits or not an [`Int64`](facts.md#int64) throws `TypeError`.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c)*

### `MatchStep`

**`export type MatchStep = { nodeId: string; nodeKind: string; result: string; detail: string; };`**

A plain object of the arguments of [`ds_rete_trace_cb_t`](inv:integrator:std:doc#introspection/network).

`result` is `"passed"` or `"filtered"`.

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c, runtime/src/libds/engine_rete_adapters.c, Spec: [NDBG.4.2])*

## Refracted activations

### `refractedActivations`

**`refractedActivations(ruleFilter?: string | null): Refraction[];`**

Lists the activations refraction blocks, through [`ds_engine_refracted_activations`](inv:integrator:std:doc#introspection/network), under its [pause contract](inv:integrator:std:doc#introspection/network).

`ruleFilter` defaults to `null`. A value that is neither a string nor `null`, or a string holding U+0000, throws `TypeError`.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c)*

### `Refraction`

**`export type Refraction = { ruleName: string; reason: string; detail: string; factIds: bigint[]; };`**

A plain object of the arguments of [`ds_rete_refract_cb_t`](inv:integrator:std:doc#introspection/network).

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c)*
