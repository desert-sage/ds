<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# `dynamic_ttl`

## The setting

### `dynamic_ttl` true

**`dynamic_ttl: true`**

A construct setting that permits `retain:` on [`emit`](../actions/emit-publish.md#emit) for a `ttl` schema, overriding the schema's TTL for that one emission.

A program has it through its dialect or a `use` block line. `default` has `dynamic_ttl: false`.

*(Spec: [LCAP.2.4], [LDTL.1.2], [LDTL.2.1])*

### `dynamic_ttl` false

Every fact of a `ttl` schema expires its schema's TTL after it enters working memory, and one schema's facts expire in assertion order.

A `retain:` that is a compile-time constant equal to the schema's TTL has no effect. Any other `retain:` on a `ttl` schema is refused with `DS_VALIDATE_CAPABILITY_DISABLED`, naming the schema and the expression.

*(Spec: [LDTL.1.1], [LDTL.3.1], [LDTL.3.2], [LDTL.8])*

## `retain`

### Per-emit `retain`

**`retain: <expr>`**

The fact's deadline is its entry stamp plus the evaluated duration, fixed when the engine asserts the fact. A later-asserted fact may expire before an earlier one of its schema.

The engine evaluates `retain:` after every slot value of the action, so where both would fault, the fault recorded is the slot value's, and `retain:` is not evaluated. The `ts` fill comes before both.

| Condition | Code |
|---|---|
| an expression whose type is not `Duration` | `DS_VALIDATE_TYPE_MISMATCH` |
| an un-narrowed `Duration?` | `DS_VALIDATE_NULLABLE_UNNARROWED` |
| a schema that is not `ttl` | `DS_VALIDATE_RETAIN_NON_TTL` |

*(Spec: [LDTL.1.2], [LDTL.4.1], Source: compiler/mercury/src/dsc.validate.m)*
