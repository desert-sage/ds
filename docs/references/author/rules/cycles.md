<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Cycles

## The check

### Rule graph

The compiler builds a graph at compile time, with rules as nodes. An edge from rule A to rule B exists when:

| A's right-hand side | B's left-hand side or `let` |
|---|---|
| `emit X` | an `X` pattern, positive or under `no` |
| `call` of a service `as "c"` | a pattern, positive or under `no`, over its response schema or `CallError`, whose `corr` is `"c"` or could resolve to it |
| `cache` of a key | `cached` of the same key in a `let` |
| `withdraw` of a fact of schema `X` | an `X` pattern, positive or under `no` |

*(Spec: [LCYC.3.1], [LCYC.3.2.1], [LCYC.3.2.2])*

### Refusals

| Condition | Code |
|---|---|
| a directed cycle in the graph | `DS_VALIDATE_RULE_CYCLE` |
| a cycle with an edge from an `emit` into a `no` pattern | `DS_VALIDATE_RULE_DEFEAT` |
| one rule that both `emit`s a schema and `withdraw`s a binding of it | `DS_VALIDATE_WITHDRAW_EMIT_SAME_SCHEMA` |

The message names the rules and the edge that closes the cycle. A `withdraw` into a `no` pattern does not make a cycle a defeat. The check runs at compile time only.

```ds rule error=DS_VALIDATE_RULE_CYCLE
rule loop:
    Reading r where r.ok
->
    emit Reading logical id: r.id level: r.level n: r.n label: r.label ok: r.ok
```

*(Spec: [LCYC.3.1], [LCYC.3.3.1], [LCYC.3.3.2], [LCYC.3.3.3], [LCYC.3.4.1], [LCYC.3.4.2], [LCYC.3.5.1], [LCYC.4.4], [LCYC.4.5])*

## Shapes

### Direct cycle

Rule A matches `X` and emits `Y`, rule B matches `Y` and emits `Z`, and rule C matches `Z` and emits `X`.

*(Spec: [LCYC.2.1], [LCYC.2.2.1], [LCYC.2.2.2])*

### Defeat

Each rule fires only if the other's fact is absent, and each firing makes the other's condition false: rule `x` has the pattern `no Y` and the action `emit X logical`, and rule `y` has the pattern `no X` and the action `emit Y logical`.

*(Spec: [LCYC.2.3.1])*

### Through a call

Two rules, each calling a service whose response or `CallError` the other matches by correlation, form a cycle. So does one rule that matches the outcome of its own call under the same correlation.

*(Spec: [LCYC.2.4.2])*

## What the check admits

### Withdraw-only SCC

A strongly connected component of the graph is admitted when both hold:

- no schema is both emitted and matched, positively or under `no`, by its rules;
- it consumes nothing its rules produce through a `call` or the cache, and no rule of it matches, through `latest` or `then`, a schema a rule of it emits.

Every internal edge of an admitted component is then a `withdraw` edge, and it terminates: from every working memory, every firing sequence reaches a state with no pending activation of its rules.

The component consumes a `call`'s product when a rule of it carries the `call` and a rule of it has a pattern over the response schema or `CallError`. It consumes the cache when a rule of it writes or deletes a key and a rule of it reads that key with `cached()`. A key that is not a literal is the same key as every other.

*(Spec: [LCYC.3.1.1], [LCYC.3.1.2])*

### Literal refinement

An edge is dropped when every non-negated pattern the target rule has for the schema carries a `binding.slot == X` test that the source's emit violates with a literal `slot: Y`, `Y ≠ X`.

Literals compare as `==` compares them: `kind == 1` and `kind: 1.0` do not differ, and neither do `0.0` and `-0.0`. A pair that is not two comparable literals (a slot reference, arithmetic, a function call, an interpolated string) leaves the edge in place.

| Rules | Result |
|---|---|
| A: `kind == "x"`, emits `kind: "y"`; B: `kind == "y"`, emits `kind: "x"` | the edges stay, `DS_VALIDATE_RULE_CYCLE` |
| two rules matching `val == "A"`, emitting `val: "B"` and `val: "D"` | both edges drop, no cycle |
| one rule per stage, guarded `level == k`, emitting `level: k+1` | backward edges drop, a bounded derivation |

*(Spec: [LCYC.6.1], [LCYC.6.1.1], [LCYC.6.1.2], [LCYC.6.1.3])*

## Limits

### `ttl` and `cooldown`

An edge through a `ttl` fact stays in the graph. Neither a `ttl` nor a `cooldown` breaks a cycle, and one that fires slowly is refused all the same.

*(Spec: [LCYC.2.4.2], [LCYC.6.2], [LCYC.7.2])*

### Across tiers

The check runs per tier, and a cycle that closes across a tier boundary is not detected.

*(Spec: [LCYC.6.3])*
