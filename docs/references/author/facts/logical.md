<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Logical facts

## Truth maintenance

### `emit X logical`

**`emit X logical <kwargs>`**

`emit X logical` ties the fact's lifetime to the matching left-hand side: the fact lives while the left-hand side matches and is retracted when it stops.

`X` is declared [`scope logical`](lifecycles.md#scope-logical), and every assertion against such a schema carries the flag. The flag restates the schema's lifecycle and selects nothing. A mismatch either way is [`DS_VALIDATE_BAD_LIFECYCLE_FLAG`](lifecycles.md#categories-and-verbs). The rule's actions do not run on the retraction.

```ds rule
schema Busy scope logical:
    id: String key

rule mark_busy:
    Reading r where r.ok
->
    emit Busy logical id: r.id
```

*(Spec: [LFAC.1.2.5], [LLOG.1.1], [LLOG.1.2], [LLOG.1.3], [LLOG.11.1], [LLOG.15.1])*

### Justifiers

Each activation that emits a `logical` fact is one justification of it.

The fact is asserted by the first, kept alive by any, and retracted when the last goes away. A match ends by any means: a pattern's `within` lapsing, a `no` pattern being broken, a test turning false.

*(Spec: [LLOG.2.1], [LLOG.2.2], [LLOG.2.3], [LLOG.2.4], [LLOG.2.5], [LLOG.5.1], [LLOG.5.2], [LLOG.5.3], [LLOG.5.4], [LLOG.5.5], [LLOG.15.1])*

### Identical and distinct facts

Rules emitting one schema with identical slot values produce one fact with several justifiers; distinct values under distinct keys produce separate facts with independent lifetimes.

With every slot `key`, each tuple is its own fact, matched individually.

*(Spec: [LLOG.2.7.1], [LLOG.2.7.2], [LLOG.2.7.4], [LLOG.11.4], [LFAC.1.7.2])*

### Superseded justifications

An emit with a live key and different other slots supersedes the live fact, whose justifications leave with it.

They do not transfer to the new fact, which lives on its own justifications alone. When the new fact's last justification goes, the key holds no fact, even if the activation that derived the superseded value still matches: that activation has fired, and does not fire again while its match holds.

*(Spec: [LLOG.2.7.5])*

### What truth maintenance covers

A fact asserted with the `logical` flag is linked to its justifiers at the asserting tier; every other fact is not.

A `ttl`, `explicit` or `activation` fact, and an `after` timer's fact, lives by its own lifecycle, and the engine does not retract it when whatever asserted it withdraws. An `after` timer is cancelled only by `as`-keyed supersedure. The mechanism is [Truth maintenance](inv:internals:std:doc#engine/truth-maintenance).

*(Spec: [LLOG.15.1], [LLOG.15.2])*

### Across tiers

A `logical` fact's justification does not cross a tier.

The fact arrives as its schema name and slot values, and the receiving tier asserts it under its own declaration. That tier holds one fact per identity, justified by nothing in the publishing tier.

*(Spec: [LLOG.11.7])*

## Re-evaluation

### Time-dependent tests

A time-dependent test (`now()`, `dwell`, a `within` window, a series read) can go false while no fact changes; the engine re-evaluates it at each pump, under that pump's clock sample.

A match the new sample refuses ends, and the `logical` facts it justified are retracted. Resolution is one pump, and the integrator's pump cadence decides it.

*(Spec: [LLOG.3.1], [LLOG.11.2])*

### `dwell`

**`t.dwell`**

`t.dwell` is the `Duration` a `logical` fact has been in working memory: the monotonic clock's sample less the fact's entry stamp.

A no-op reassertion leaves it running, and a [meaningful change](lifecycles.md#meaningful-change) resets it. It reads no slot, `ts` included. A condition reading it is time-dependent. On a `ttl` binding it is refused with `DS_VALIDATE_DWELL_TTL_SCHEMA`.

```ds expression
r.dwell
```

*(Spec: [LFAC.1.2.4], [LFAC.2.2], [LFAC.2.7.5], [LFAC.3.5], [LFAC.4.5], [LEXP.9.5.1], [LEXP.9.5.3], [LTIM.2.8.6], Source: compiler/mercury/src/dsc.typecheck.m)*

## Negation

### Absence as a justification

A `logical` fact whose rule has a `no` pattern is justified in part by that absence.

The fact lives while the absence persists. When a fact the negated pattern matches is asserted, the pattern fails, the activation ends and the `logical` fact is retracted.

```ds rule
schema Quiet scope logical:
    id: String key

rule mark_quiet:
    no Reading r where r.ok
->
    emit Quiet logical id: "all"
```

*(Spec: [LLOG.4.1], [LLOG.4.2], [LLOG.11.5])*

## Ending a match from inside

### Self-ending emits

A `logical` emit whose activation ends inside its own firing is refused with `DS_VALIDATE_LOGICAL_EMIT_SELF_ENDING`. [`withdraw`](lifecycles.md#withdrawal-scope) does not reach a `logical` binding.

The refusal covers:

- a `logical` emit in the body of an `after` clause;
- a `logical` emit that follows a `withdraw` of one of the rule's bindings in the same actions;
- an emit of `X`, when `logical`, that replaces a fact the rule's positive `X` pattern matched, and a `logical` emit after it. It replaces the fact when every key slot of the emit is that binding's same slot, and another slot is a literal differing from the literal the pattern requires of that slot.

An emit before the `withdraw` compiles. A body nested in a later action runs in its own rule, and these rules do not reach it.

```ds rule error=DS_VALIDATE_LOGICAL_EMIT_SELF_ENDING
schema Task:
    id: String

schema Done scope logical:
    id: String key

rule finish:
    Task t
->
    withdraw t
    emit Done logical id: "all"
```

*(Spec: [LLOG.11.9])*

### Emits that end a match at run time

From the action of a firing that ends the activation's own match, the activation justifies nothing.

A `logical` fact the firing emitted before that action loses this justification there, and is retracted if no other holds it. A `logical` fact emitted after it gains none, and is retracted as it is made unless another justification already holds it.

*(Spec: [LLOG.15.1])*

### Cycles through a justification

A rule that reads a `logical` fact and ends its justifier's match compiles only when its emit is one the literal break refutes.

Such an emit drops the edge back to the justifier, unless it replaces a fact the rule matched, which is a [self-ending emit](#self-ending-emits). A `withdraw` of the fact the justifier matches, or an emit whose value the break cannot compare, keeps the edge. Both rules are then one strongly connected component with the `logical` fact emitted and matched inside it, and the program is refused with `DS_VALIDATE_RULE_CYCLE`.

*(Spec: [LLOG.15.3])*

## Introspection

### Logical fact state

The runtime exposes which `logical` facts are active, which activations justify each, and each fact's assert and retract history with each retraction's cause.

*(Spec: [LLOG.9.1], [LLOG.9.2], [LLOG.9.3], [LLOG.9.4])*
