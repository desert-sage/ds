<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Debugging

## Justifiers

### `justifier`

**`:- type justifier ---> justifier(justifier_rule :: string, justifier_timetag :: maybe(timetag)).`**

One live activation that supports a logical fact.

`justifier_rule` is the rule's name. `justifier_timetag` is always `no`: the runtime keeps the rule and not the firing.

*(Source: bindings/mercury/src/mercury_ds.introspect.m)*

### `justifiers`

**`:- func justifiers(session, fact_id) = read(list(justifier)).`**

The live justifications of a fact, one for each activation that supports it: the capability of [`ds_engine_get_justifiers`](inv:integrator:std:doc#introspection/network).

The list is empty for a fact not asserted `logical` and for an id no live fact has. After the halt it answers as [`read(T)`](session.md#readt) states.

*(Source: bindings/mercury/src/mercury_ds.introspect.m, Spec: [NDBG.5.1])*

## Match trace

### `match_trace`

**`:- func match_trace(session, fact_id) = read(list(trace_step)).`**

A live fact's path through the alpha nodes that test its schema, each step passed or filtered: the capability of [`ds_engine_rete_match_trace`](inv:integrator:std:doc#introspection/network).

The list is in the order the nodes test the fact. It is empty for an id with no live fact a host can see. `trace_step` is `ds.engine`'s, and its members hold the arguments of [`ds_rete_trace_cb_t`](inv:integrator:std:doc#introspection/network):

| Member | Holds |
|---|---|
| `ts_node` | the decimal text of the node's id |
| `ts_kind` | `"alpha"` |
| `ts_result` | `"passed"` or `"filtered"` |
| `ts_detail` | the explanation |

*(Source: bindings/mercury/src/mercury_ds.introspect.m, runtime/mercury/src/ds.engine.m, Spec: [NDBG.4.2])*

## Refracted activations

### `refracted_activations`

**`:- func refracted_activations(session, maybe(string)) = read(list(refracted_activation)).`**

The matches that have fired and are held back from firing again, for every rule (`no`) or for the one named: the capability of [`ds_engine_refracted_activations`](inv:integrator:std:doc#introspection/network).

The list is by terminal ordinal, and within one terminal by fact ids, compared as a tuple. A name no rule has gives an empty list. `refracted_activation` is `ds.engine`'s, and its members hold the arguments of [`ds_rete_refract_cb_t`](inv:integrator:std:doc#introspection/network):

| Member | Holds |
|---|---|
| `ra_rule` | the rule's name |
| `ra_reason` | `"refraction"` |
| `ra_detail` | the detail text |
| `ra_facts` | the facts the author's patterns bound |

```mercury declaration
:- pred any_refracted(session::in) is semidet.
any_refracted(S) :-
    refracted_activations(S, no) = ok([_ | _]).
```

*(Source: bindings/mercury/src/mercury_ds.introspect.m, runtime/mercury/src/ds.engine.m, Spec: [NDBG.4.3])*
