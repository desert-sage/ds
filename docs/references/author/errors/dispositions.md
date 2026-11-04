<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Error dispositions

## The rungs

### Rungs

A failure has exactly one disposition, ordered by how much execution is abandoned.

| Rung | Disposition | Abandoned |
|---|---|---|
| 1 | [compile error](#compile-error) | nothing: the program never runs |
| 2 | [bounds refusal](#bounds-refusal) | nothing: the operation does not happen |
| 3 | [errors as values](#errors-as-values) | nothing: the error is ordinary data |
| 4 | [absence](#absence) | the expression; the rule does not fire |
| 5 | [`TypeError`](#typeerror) | the activation |
| 6 | [`ComputationError`](#computationerror) | the activation |
| 7 | [`EngineError`](#engineerror) | the tier |

Rungs 5 and 6 differ in why: the data was wrong, or the computation had no answer.

*(Spec: [LERR.1])*

## No fault

### Compile error

Rung 1: an author-declared static constraint the compiler can check before run time.

The compile fails with a [diagnostic](../tools/diagnostics.md), a source location and a specific message, and a refactor hint or a list of valid alternatives where available. A problem the compiler can prove from the source and the dialect is a compile error. The cases include a construct the program's settings forbid, a `use` naming an unknown dialect or capability, a lifecycle mismatch, a type mismatch on a typed slot, a [missing rate expectation](../calls/call.md#rate-expectation), and a cycle in the rule graph.

*(Spec: [LERR.1.1.1], [LERR.1.1.3], [LERR.1.1.4], [LERR.1.1.5], [LERR.1.1.6], [LERR.1.1.8], [LERR.1.1.9], [LERR.1.1.10], [LERR.1.1.11])*

### Bounds refusal

Rung 2: a declared cap would be exceeded, decided before the work happens.

The operation does not happen, state does not change, and later calls work. A `BoundsError` records the cap, its limit and what the operation would have reached. The cap is [a cache bound](../actions/cache.md#cache-bounds) the integrator set. When the refused operation is one of a firing's actions, the firing stops there: the actions before it stand, and the actions after it do not run.

*(Spec: [LERR.1.5])*

### Errors as values

Rung 3: a run-time operation has a definite outcome a rule may react to.

The outcome is a `ttl` fact, [`CallError`](../calls/call.md#callerror), with a `code`, a `message` and a `corr`. A rule matches `code`, and a rule that does not care does not match. A failing call and a response that cannot be delivered in its published shape both take this rung.

*(Spec: [LERR.1.2.1], [LERR.1.2.3], [LERR.1.2.5], [LERR.1.2.6], [LERR.1.2.7])*

### Absence

Rung 4: a value an expression needs is absent, and the operation itself is not wrong.

The expression reads as [`null`](../values/null.md#null) and propagates; the rule [fires only on `true`](../values/null.md#where), so it does not fire. No fact is asserted, the activation continues, and no sentinel is produced. An absence raises no fault. An unresolved `Json` path is absent. A path resolving to a JSON `null` reads as `null` too, as a present value, and [`has`](../values/json.md#has) tells the two apart. A failed fallible conversion, a cache miss and an interpolation of a null value are absent. A regex match against a malformed run-time string evaluates `false`.

*(Spec: [LERR.1.3.1], [LERR.1.3.3], [LERR.1.3.5], [LERR.1.3.7], [LERR.1.4.9])*

## Faults

### `TypeError`

Rung 5: an operation is invalid on a value that is present.

A type mismatch at a `Json` leaf and a format that cannot render a present value are `TypeError`s. The activation is abandoned, and the pump continues past it.

*(Spec: [LERR.1], [LERR.1.3.4], [LERR.1.4.9])*

### `ComputationError`

Rung 6: a computation has no honest answer, and no value, `null` included, would be true of it.

The source of the input does not enter into it. A `Float` operation has an answer, an infinity or a NaN included, so no `Float` arithmetic traps. A trap never feeds `T?`, `??` or Kleene logic, and the activation stays abandoned, while the pump continues past it. A rule reacts through [its fault fact](fault-facts.md#computationerror-fact), which is a record of the trap and not a value of the expression.

*(Spec: [LERR.1.4.1], [LERR.1.4.3], [LERR.1.4.7], [LERR.1.4.8])*

### Trap kinds

`ComputationError.kind` is a closed set of three.

| Kind | Raised when |
|---|---|
| `DIVIDE_BY_ZERO` | an `Int` division, floor-division or modulo has a zero divisor |
| `DOMAIN` | the operation is undefined at that input and is not an IEEE `Float` operation: a negative shift count, `now()` read while the wall clock has no value, `local()` or `date()` with no `TimeZoneOffset` fact in force, an interval whose endpoints are not `start <= end` |
| `NOT_REPRESENTABLE` | an operation has no representable result and wrapping would destroy its meaning: `Float :: Int` on a value non-finite or outside `Int`, a `Json` value a rule builds past a limit |

Integer overflow wraps, as [`Int`](../values/numbers.md#int) states, and is no trap. Float overflow yields `±Inf`.

*(Spec: [LERR.1.4.4], [LERR.1.4.9], [LERR.1.4.10])*

### `EngineError`

Rung 7: engine state cannot be trusted, and the engine halts the tier.

The cases are an artefact whose values contradict its own types, and memory exhaustion with no declared cap. The halt stops the work where it is raised: no further action of the activation runs, no further activation fires, no further fact propagates, and nothing more is recorded. After it, the engine's state is undefined except that it is halted.

*(Spec: [LERR.1.4.5], [LERR.1.4.7])*

### Fault reach

Only the fault an expression yields reaches a surface.

A fault an operand raised, and a deciding operand absorbed or [the order](../values/null.md#kleene-logic) passed over, is not recorded, asserted, delivered or counted. A fault raised while matching reaches a surface once per derivation of its pair of token and fact, while the pair is live; a pair that ends and is derived again records again.

*(Spec: [LERR.1.4.11], [LERR.1.4.12])*

## Statuses

### Status dictionary

A status is an integer from one registry, `proto/status.proto`, and the number is its identity.

A name is an implementation's label for the number. Zero is success and negatives are errors. A status's band says its category. The bands are at [Results](inv:integrator:std:doc#conventions/results), and the codes at [Error codes](inv:integrator:std:doc#conventions/errors).

*(Spec: [LERR.8], [LERR.8.1], [LERR.8.2])*
