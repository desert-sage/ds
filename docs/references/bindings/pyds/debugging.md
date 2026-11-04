<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Debugging

## `Debug`

**`class Debug`**

An engine's Rete reads, under the [pause contract](inv:integrator:std:doc#introspection/network). `Engine.debug` returns one.

Each call returns values that do not change after. A call that cannot build its whole result raises, and returns no part of it.

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/_pyds/engine.c)*

### `justifiers`

**`def justifiers(self, fact_id: FactId, /) -> list[Justifier]`**

Lists the activations that logically support a live fact, through [`ds_engine_get_justifiers`](inv:integrator:std:doc#introspection/network).

An id with no live fact raises `KeyError`, and a `bool` or a value that is not an integer raises `TypeError`.

*(Source: bindings/python/src/pyds/engine.py)*

### `network`

**`def network(self, *, rule_filter: str | None = None, include_occupancy: bool = False) -> ReteNetwork`**

Returns the Rete network, through [`ds_engine_rete_network`](inv:integrator:std:doc#introspection/network).

A `rule_filter` the program has no rule for raises `ValueError`. A `rule_filter` that is neither a `str` nor `None`, or an `include_occupancy` that is not a `bool`, raises `TypeError`.

```python statement
for node in engine.debug.network(include_occupancy=True).nodes:
    print(node.id, node.kind, node.occupancy)
```

*(Source: bindings/python/src/pyds/engine.py)*

### `match_trace`

**`def match_trace(self, fact_id: FactId, /) -> list[TraceStep]`**

Traces a live fact through the alpha nodes of its schema, through [`ds_engine_rete_match_trace`](inv:integrator:std:doc#introspection/network).

An id with no live fact raises `KeyError`, and a `bool` or a value that is not an integer raises `TypeError`.

*(Source: bindings/python/src/pyds/engine.py)*

### `refracted`

**`def refracted(self, *, rule_filter: str | None = None) -> list[RefractedActivation]`**

Lists the activations refraction blocks, through [`ds_engine_refracted_activations`](inv:integrator:std:doc#introspection/network).

A `rule_filter` the program has no rule for raises `ValueError`. One that is neither a `str` nor `None` raises `TypeError`.

*(Source: bindings/python/src/pyds/engine.py)*

## Values

### `Justifier`

**`Justifier(rule_name, timetag)`**

A frozen dataclass of one entry of [`ds_engine_get_justifiers`](inv:integrator:std:doc#introspection/network).

*(Source: bindings/python/src/pyds/engine.py)*

### `ReteNetwork`

**`ReteNetwork(nodes, edges)`**

A frozen dataclass of the network: `nodes` is a `tuple` of `ReteNode`, and `edges` a `tuple` of `ReteEdge`.

*(Source: bindings/python/src/pyds/engine.py)*

### `ReteNode`

**`ReteNode(id, kind, label, filter, occupancy, is_negative)`**

A frozen dataclass of the arguments of [`ds_rete_node_cb_t`](inv:integrator:std:doc#introspection/network).

`kind` is a `NodeKind`. `occupancy` is `None` for the `UINT32_MAX` that `include_occupancy` false gives.

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/_pyds/engine.c)*

### `ReteEdge`

**`ReteEdge(from_id, to_id)`**

A frozen dataclass of the arguments of [`ds_rete_edge_cb_t`](inv:integrator:std:doc#introspection/network).

*(Source: bindings/python/src/pyds/engine.py)*

### `NodeKind`

**`class NodeKind(StrEnum)`**

The `kind` of a Rete node, as [`ds_rete_node_cb_t`](inv:integrator:std:doc#introspection/network) gives it.

Its members and their values are `ALPHA` `"alpha"`, `BETA` `"beta"` and `TERMINAL` `"terminal"`.

*(Source: bindings/python/src/pyds/enums.py)*

### `TraceStep`

**`TraceStep(node_id, node_kind, result, detail)`**

A frozen dataclass of the arguments of [`ds_rete_trace_cb_t`](inv:integrator:std:doc#introspection/network).

`node_kind` is a `NodeKind`, and `result` a `MatchResult`.

*(Source: bindings/python/src/pyds/engine.py)*

### `MatchResult`

**`class MatchResult(StrEnum)`**

The `result` of [`ds_rete_trace_cb_t`](inv:integrator:std:doc#introspection/network).

Its members and their values are `PASSED` `"passed"` and `FILTERED` `"filtered"`.

*(Source: bindings/python/src/pyds/enums.py, runtime/src/libds/engine_rete_adapters.c)*

### `RefractedActivation`

**`RefractedActivation(rule_name, reason, detail, fact_ids)`**

A frozen dataclass of the arguments of [`ds_rete_refract_cb_t`](inv:integrator:std:doc#introspection/network).

`fact_ids` is a `tuple` of [`FactId`](facts.md#factid), each a live fact's.

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/_pyds/engine.c, runtime/src/libds/engine_rete_adapters.c, Spec: [NDBG.4.3])*
