<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Fault facts

## Schemas

### Fault fact

A fault fact describes a [`TypeError` or a `ComputationError`](dispositions.md#faults) after it has abandoned its activation, and rules match it.

Both schemas are [built in](../facts/builtin-schemas.md#the-built-in-schemas) and [`internal`](../facts/lifecycles.md#internal). A fact is a record of the fault, never a value of the expression that raised it. An `EngineError` is recorded and not asserted.

```ds rule
rule on_fault:
    ComputationError c where c.kind == "DOMAIN"
->
    log error "{c.rule} {c.slot}"
    withdraw c
```

*(Spec: [LERR.9], [LERR.9.1], [LERR.9.4])*

### `ComputationError` fact

**`ComputationError`**

`ComputationError` holds one trap, with identity `(node, rule)`.

| Slot | Type | Marker | Meaning |
|---|---|---|---|
| `kind` | `String` | | [a trap kind](dispositions.md#trap-kinds): `"DIVIDE_BY_ZERO"`, `"DOMAIN"` or `"NOT_REPRESENTABLE"` |
| `rule` | `String` | key | the [fault's rule name](#rule-name) |
| `schema` | `String` | | the schema of the value with no answer, or `""` |
| `slot` | `String` | | the slot of that value, or `""` |
| `node` | `Int` | key | the expression node that faulted |

A comparison of `kind` against a string literal outside the set is refused with `DS_VALIDATE_CLOSED_SET_LITERAL`.

```ds rule error=DS_VALIDATE_CLOSED_SET_LITERAL
rule on_other:
    ComputationError c where c.kind == "OTHER"
->
    log error "{c.rule}"
```

*(Spec: [LERR.9.2])*

### `TypeError` fact

**`TypeError`**

`TypeError` holds one invalid operation, with identity `(node, rule)`.

| Slot | Type | Marker | Meaning |
|---|---|---|---|
| `actual` | `String` | | the type tag the value had |
| `rule` | `String` | key | the [fault's rule name](#rule-name) |
| `schema` | `String` | | the schema of the value, or `""` |
| `slot` | `String` | | the slot of that value, or `""` |
| `node` | `Int` | key | the expression node that faulted |

*(Spec: [LERR.9.3])*

### Rule name

Every fault names a rule.

| Fault raised | Name |
|---|---|
| in an activation | that activation's rule |
| at a network node during matching | `$alpha_<id>` or `$beta_<id>` |
| with no node site | `$engine` |

*(Spec: [LERR.9.11])*

### Slot context

`schema`, `slot` and `actual` describe the node's offending operand: the first operand whose value is known and `null`, else at a division or remainder the divisor, else the first operand.

A value is known when it is a literal or a slot read. `schema` and `slot` are filled when the offending operand is a slot read, and `""` otherwise. `actual` is filled when the operand's value is known.

*(Spec: [LERR.9.12])*

## Behaviour

### Latching

Working memory holds at most one fault fact per schema per `(node, rule)`.

A fault at a site with a live fact and equal slots is a no-op, and nothing matching it fires again. Any slot that differs replaces the fact. A rule acknowledges a fault by [`withdraw`](../facts/lifecycles.md#withdrawal-scope); the next fault at the site is then asserted afresh. The event trace still records every occurrence.

*(Spec: [LERR.9.5])*

### Fault handlers

A rule with any pattern, positive or negated, on `ComputationError` or `TypeError` is a fault handler.

A fault raised in a handler's activation, or at a node any handler's patterns use, is recorded and not asserted. Asserting fault facts forms no cycle.

*(Spec: [LERR.9.6])*

### Assertion timing

Fault facts are asserted when the current propagation has completed or the abandoned activation has unwound, before the next agenda selection.

They queue in the order the faults are recorded. A later fault at a site whose fault is still pending replaces it in place. A handler's activation is ordered as any is, as [Total order](../rules/firing-order.md#total-order) states.

*(Spec: [LERR.9.7])*

### Only what reaches a surface

A fault that [does not reach a surface](dispositions.md#fault-reach) becomes no fact.

*(Spec: [LERR.9.9])*
