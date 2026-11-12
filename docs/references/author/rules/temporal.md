<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Temporal sequences

## The sequence

### `then`

**`sequence_pattern ::= 'latest'? pattern_body then_step+`**

**`then_step ::= 'then' 'latest'? type_ref binding? 'within' time_expr where_clause?`**

A pattern combinator that matches facts in temporal order, with a mandatory bound.

For `X then Y within T`, `Y.ts > X.ts` and `Y.ts - X.ts < T` both hold, and the activation holds both bindings. Both comparisons are on the facts' [`ts`](../facts/schemas.md#ts-source) values, so a fact delivered late orders by its `ts`, and two facts with equal `ts` do not match.

```ds rule
rule follows:
    Reading a then Reading b within 30_s where b.id == a.id
->
    log info "{b.id}"
```

*(Spec: [LGRA.8.1], [LGRA.8.5.1], [LTHE.2.1], [LTHE.2.2.2], [LTHE.2.2.3], [LTHE.5.2], [LTHE.5.3])*

### Chains

`then` is left-associative: each `within T` applies to the `then` immediately before it, and is bounded by that step's schema TTL ([Refusals](#refusals)).

*(Spec: [LGRA.8.5.8], [LTHE.2.3.1], [LTIM.2.7.3])*

### Line-leading `then`

A line of `then` steps continues the nearest positive pattern above it. The one-line and line-leading forms mean the same sequence, and mix.

*(Spec: [LGRA.8.1], [LTHE.4.1])*

### Step `where`

A `where` after a step's `within` belongs to that step, in either layout, and sees every binding before it and the step's own. A trailing `where` on a one-line sequence is the last step's.

*(Spec: [LGRA.8.5.10], [LTHE.2.4.1], [LTHE.2.4.2])*

## Cardinality

### All matches

With no prefix, a sequence has one activation per valid chain: two anchors in the window before one follower fire the rule twice.

*(Spec: [LTHE.2.5.1], [LTHE.5.1])*

### `latest`

Pins the sequence's first pattern to its most recent match before the first follower. Later steps match every fact in their windows, so the rule fires once per complete chain from that anchor.

An anchor `A` with follower `B` is excluded when another anchor `A′`, with `A.ts < A′.ts`, meets the sequence's order and windows in `A`'s place with the same `B` and later facts, and none of the anchor's `where` and the followers' `where`s answers `false` with `A′` in place. A `where` answering `null` does not stop `A′` excluding `A`. An anchor after its follower excludes nothing. The outcome depends on timestamps and slot values, not arrival order.

```ds rule
rule after_last:
    latest Reading a then Reading b within 30_s where b.id == a.id
->
    log info "{b.id}"
```

*(Spec: [LGRA.8.5.14], [LGRA.8.5.16], [LTHE.2.5.3], [LTHE.2.5.4], [LTHE.2.5.5])*

## Refusals

| Condition | Code |
|---|---|
| a participating schema with no `ts` slot | `DS_VALIDATE_WITHIN_NO_TS_SLOT` |
| a `within` of `0_s` | `DS_VALIDATE_ZERO_WITHIN` |
| a step's `within` longer than the TTL of the step before it | `DS_VALIDATE_WITHIN_EXCEEDS_TTL` |
| a `then` with no pattern above it | `DS_VALIDATE_THEN_NO_PREDECESSOR` |
| a `then` whose nearest pattern above is a `no` pattern | `DS_VALIDATE_THEN_AFTER_NEGATION` |
| a `latest` on any pattern but the first | `DS_VALIDATE_INTERIOR_LATEST` |

```ds rule error=DS_VALIDATE_ZERO_WITHIN
rule instant:
    Reading a then Reading b within 0_s where b.id == a.id
->
    log info "never"
```

*(Spec: [LTHE.4.5], [LTHE.4.7], [LTHE.4.8], [LTHE.4.9], [LTHE.5.4], [LTIM.2.7.3])*

