<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# `linear_scan`

## The setting

### `linear_scan` false

**`linear_scan: false`**

A strategy setting that restricts a program to the shapes [Complexity](inv:internals:std:doc#appendix/complexity) bounds.

A program has it through its dialect or a `use` block line. `linear_scan: true` permits every shape. Every violation is a compile error.

The setting is program-scoped, and a project may mix programs of either setting. A program may import schemas from any library, and [the `Json` refusal](#json) applies to an imported schema a rule uses.

A [diagnostic](../tools/diagnostics.md#diagnostic-object) gives the file and line of the violating form, a description of it, and where one exists, a suggested fix.

*(Spec: [LCAP.2.2], [LNLS.2.1], [LNLS.2.6], [LNLS.9], [LNLS.9.1])*

## Refusals

### Join anchor

In a multi-pattern rule, each pattern after the first is anchored to an earlier one: its `where` pins the full declared [`key`](../facts/schemas.md#key-and-mutable) of a `logical` schema on each side, one equality per `key` slot. Further constraints on top of the anchor are allowed. Single-pattern `where` clauses are unrestricted.

A negated pattern whose `where` references no earlier binding is exempt. A `logical` schema with an empty key is pinned by construction: between it and a keyed schema, the keyed schema's full key is pinned to slots of the singleton, each non-nullable, and between two such schemas no equality is required.

| Condition | Code |
|---|---|
| an equality that does not pin the complete key on each side | `DS_VALIDATE_NOLINSCAN_JOIN_ANCHOR_A` |
| a join against a `ttl` schema | `DS_VALIDATE_NOLINSCAN_JOIN_ANCHOR_B` |
| a pattern with no anchor to an earlier one, or an anchor on a nullable singleton slot | `DS_VALIDATE_NOLINSCAN_JOIN_ANCHOR_C` |

A capture standing in for a `key` slot is at [Capture as a join key](../expr/regex.md#capture-as-a-join-key).

*(Spec: [LNLS.3.3], [LNLS.3.3a], [LNLS.3.3b], [LNLS.3.3c], [LNLS.4.3], [LNLS.4.11])*

### `Json`

| Condition | Code |
|---|---|
| a schema with a `Json` slot, used in the program | `DS_VALIDATE_NOLINSCAN_JSON_SLOT` |
| an expression that traverses a `Json` value, a call response's included | `DS_VALIDATE_NOLINSCAN_JSON_PATH` |

```ds declaration head error=DS_VALIDATE_NOLINSCAN_JSON_SLOT
use default:
    linear_scan: false
schema Doc:
    body: Json
```

*(Spec: [LNLS.3.1], [LNLS.3.9], [LNLS.4.5], [LNLS.4.6])*

### Strings

A [`capacity`](../values/strings.md#string-capacity) on a `String` slot bounds these operations.

| Condition | Code |
|---|---|
| `~` or `!~` on a `String` slot with no `capacity` | `DS_VALIDATE_NOLINSCAN_UNBOUNDED_REGEX` |
| `<`, `>`, `<=` or `>=` in single-pattern position on a `String` slot with no `capacity` | `DS_VALIDATE_NOLINSCAN_UNBOUNDED_STRING_OP` |
| `<`, `>`, `<=` or `>=` on `String` values from different patterns, whatever their `capacity` | `DS_VALIDATE_NOLINSCAN_STRING_ORDER` |

The error names the first use of the slot in the file. Where both string codes would apply, the compiler reports `DS_VALIDATE_NOLINSCAN_UNBOUNDED_REGEX`. `==`, `!=` and `len` need no `capacity`.

*(Spec: [LNLS.3.7], [LNLS.3.8], [LNLS.3.10], [LNLS.4.2], [LNLS.4.4], [LNLS.4.9])*

### Series scans

`contains` or `count_of` over a series with no `capacity` is refused with `DS_VALIDATE_NOLINSCAN_SERIES_UNBOUNDED`, as is any series read whose cost is linear in the window's sample depth. `count`, `sum`, `mean`, `min`, `max`, `first`, `last`, `bool_and` and `bool_or` are unaffected.

*(Spec: [LNLS.3.11], [LNLS.4.8])*
