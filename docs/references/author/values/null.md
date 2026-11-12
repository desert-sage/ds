<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Null

## The value

### null

`null` is the one canonical absent value, the same value as `Json` null.

The literal `null` alone has type `null`, the bottom of every `T?`, and is assignable to any `T?`. It is data: nullable slots, `Json` null, call-response fields and a cache miss carry it. `by: none` is a configuration marker, not `null`.

*(Spec: [LNUL.2.1], [LNUL.3.3], [LNUL.7.1], [LNUL.7.3])*

### Nullable types

**`T?`**

`T?` is the nullable form of `T`, opted into per declaration; the default is non-null.

The runtime value is a plain `null`. The compiler tracks `T?` and refuses a `T?` where a `T` is required until it is [narrowed](#narrowing).

```ds declaration
schema Sample scope logical:
    id: String key
    state: Float? mutable
```

*(Spec: [LNUL.3.1], [LNUL.3.2], [LNUL.8.4])*

### Null in a Json slot

A `Json` document whose root is `null` is the canonical `null`: a `Json` slot cannot hold it, and a `Json?` slot can.

`{"a": null}` is an object and a legal `Json` value. A path into a document follows [Path resolution](json.md#path-resolution).

*(Spec: [LNUL.3.4])*

### Nullable key

A key slot must be non-null; a nullable one is refused with `DS_VALIDATE_NULLABLE_KEY`.

```ds declaration error=DS_VALIDATE_NULLABLE_KEY
schema Sample scope logical:
    id: String? key
```

*(Spec: [LNUL.8.10])*

### Nullable Time

A `Time?` slot of any name but `ts` is admitted, and its `null` propagates as a `null` in a `Date?` or a `Duration?` does.

A slot named `ts` follows [`ts`](../facts/schemas.md#ts).

*(Spec: [LNUL.8.7], [LFAC.9.1])*

## Predicates

### Propagation

An operator other than `and`, `or`, `??` and `is` with a `null` operand, and no operand that faults, yields `null`.

This covers the arithmetic, bitwise and comparison operators, the interval relational operators and the regex match operators. With `s.state` absent, `s.state + 1`, `s.state & 1`, `s.state > 85` and `s.state == 5` are all `null`. A regex match on an absent string continues the activation for neither `~` nor `!~`.

*(Spec: [LNUL.4.1])*

### Faults and null operands

A `null` operand does not absorb a fault: for every operator but `and`, `or` and `??`, and for builtin arguments, an operand that faults makes the expression fault.

A `null` operand still prevents the operation itself: `x / z` with `x` null and `z` zero is `null`. When several operands fault, the expression yields one, chosen as under [Kleene logic](#kleene-logic). Operands evaluate in any order.

*(Spec: [LNUL.4.10])*

### Kleene logic

**`a and b`**, **`a or b`**, **`not a`**

`and`, `or` and `not` operate over `true`, `false` and `null` by the Kleene tables.

| `a` | `b` | `a and b` | `a or b` |
|---|---|---|---|
| `true` | `null` | `null` | `true` |
| `false` | `null` | `false` | `null` |
| `null` | `null` | `null` | `null` |

`not null` is `null`.

An operand faults when evaluating it raises a trap, a `TypeError` or an `EngineError`. `and` is `false` if any operand is `false`, whatever the others raise; it is a fault only if no operand is `false`, and `null` only if none is `false` and none faults. `or` is the dual, on `true`. Operands evaluate in any order, and evaluation may stop at a deciding operand. An `EngineError` from anything but evaluating the operand, such as resource exhaustion, halts the tier whatever the expression would answer.

When several operands fault and none decides, one fault is chosen by kind: `EngineError`, `TypeError`, then the trap kinds in `TrapKind` value order. Within a kind, the fields of the fault's record decide, in field-number order, without `clock_ns` and `seq`, the lower value winning at the first difference. Operand position never enters.

Commutativity, associativity, De Morgan and double negation hold. Absorption and distributivity do not hold once faults exist.

*(Spec: [LNUL.4.2])*

### Where

A `where` clause fires iff it evaluates to `true`; `false` and `null` do not fire.

| Predicate over a null `s.state` | Value | The pattern matches |
|---|---|---|
| `s.state > 85` | `null` | no |
| `not (s.state > 85)` | `null` | no |
| `(s.state ?? 0.0) > 85` | `false` | no |
| `s.state is null` | `true` | yes |

A fact whose nullable slot is `null` still matches its pattern; only `where` filters.

*(Spec: [LNUL.4.3], [LNUL.4.5], [LNUL.8.3])*

### Negated existence

**`no P where C`**

A negated-existence pattern is satisfied iff, for every fact matching `P`, `C` evaluates to `false`.

A fact for which `C` is `true` or `null` blocks satisfaction.

```ds rule
rule no_higher:
    Reading r
    no Reading o where o.level > r.level
->
    log info "{r.id}"
```

*(Spec: [LNUL.4.7], [LGRA.8.1])*

### Guards

A guard is an engine-evaluated expression that decides whether an already-matched activation is withheld; the compiler-emitted cooldown gate is the guard.

Where the guard evaluates to `null`, the activation proceeds. Only `false` suppresses. A time-dependent condition read beside the gate is not a guard: it decides whether the rule matches, as under [Where](#where).

*(Spec: [LNUL.4.8])*

### Null literal comparison

`== null` and `!= null` are refused with `DS_VALIDATE_NULL_LITERAL_COMPARISON`, with a `null` literal as either operand.

```ds expression error=DS_VALIDATE_NULL_LITERAL_COMPARISON
r.level == null
```

*(Spec: [LNUL.4.4])*

### Join equality

**`a.x == b.x`**

Cross-pattern join equality is non-matching when both values are `null`.

*(Spec: [LNUL.4.4], [LNUL.8.2])*

### Tag test

**`x is <subject>`**, **`x is not <subject>`**

`is` tests a value's tag against a closed set of subjects, and answers `true` or `false` for a value of any kind.

It yields no `null` and raises nothing. `is not` is one operator, not `not` applied to `is`. It is the only way to branch on absence inside a predicate.

| Subject | `true` exactly when |
|---|---|
| `null` | the value is `null` |
| `true`, `false` | the tag is `Bool` and the value is that boolean |
| `inf`, `-inf` | the tag is `Float` and the value is that infinity |
| `NaN` | the tag is `Float` and the value is NaN |
| `Int`, `Float`, `Bool`, `String`, `Bytes`, `Json` | the tag is that one, whatever the value |

It is `false` in every other case, a `null` value with any other subject included. A tag names a representation:

| Type | Answers `true` to |
|---|---|
| `Time`, `Date`, `Duration` | `Int` |
| a unit-typed value | `Int` or `Float`, as its declared `storage` names |
| `Ratio`, a fact reference | none of the six tag names |

The answer is a function of the value alone, and the tag is read before any value conversion.

```ds expression
r.level is NaN
r.n is Int
r.label is not null
```

*(Spec: [LNUL.4.4], [LNUL.4.9])*

## Narrowing and coalescing

### Concrete-value positions

A `T?` where a concrete `T` is required, un-narrowed, is refused with `DS_VALIDATE_NULLABLE_UNNARROWED`.

A concrete `T` is required by a consumer that does not propagate `null`: an `emit` or `publish` value into a non-nullable slot, a `call` or function argument, the receiver or an argument of a builtin that demands a value of a particular kind, a typed `let` right-hand side, or a series source. A builtin is refused on these terms inside a `where` too, in method form and function form alike.

The operators, and `math.fma`, propagate `null` and accept a `T?`. Interpolation is not a concrete-value position: [a null value renders as the empty string](../actions/actions.md#interpolation-site).

*(Spec: [LNUL.5.1], Source: compiler/mercury/src/dsc.typecheck.m)*

### Narrowing

A `T?` narrows to `T` in exactly two cases.

1. The tail of a `where` conjunction after an `x is not null and` guard, where `x` is `T` in the remaining conjuncts.
2. The result of [`x ?? d`](#coalesce).

No other construct narrows: not `or`, `not (x is null)`, a prior `let`, nor nested or cross-rule flow. Narrowing does not cross from the left-hand side into the action body, where a binding guarded on the left is still `T?`. It is a typing rule, not an evaluation order: a narrowed conjunct evaluated before its guard meets the `null`, and a `false` guard absorbs what it raises.

`s.state is null or s.state > 85` compiles, and fires on a `null` reading, as `true or null` is `true`.

*(Spec: [LNUL.5.2], [LNUL.5.4])*

### Coalesce

**`x ?? d`**

`x ?? d`, with `d : T`, has type `T`: `x` when non-null, else `d`.

`d` is evaluated only when `x` is `null`, in every mode. When evaluating `x` faults, the expression yields that fault and `d` is not evaluated.

```ds expression
r.label::Int? ?? 0
```

*(Spec: [LNUL.5.3], [LNUL.8.9])*

### Fallible cast

A [fallible cast](conversions.md#fallible-cast) yields a `T?`, which feeds `??`, Kleene logic and narrowing.

*(Spec: [LNUL.5.5])*

## Absence in series

### Series reads

A cold read of a counting, membership, `sum` or signal aggregation yields its concrete zero; every other aggregation is `T?` and yields `null` while cold.

A series sample is never `null`.

*(Spec: [LNUL.7.2])*

### Series null absorption

**`nulls: skip`**, **`nulls: hold`**, **`nulls: zero`**

A series over a `T?` source declares what it does with a sample that carries `null`.

| Policy | Effect |
|---|---|
| `skip` | drops the sample |
| `hold` | repeats the last absorbed value, kept for the series instance's life: [eviction](../series/reading.md#eviction) after a window of silence does not forget it, and a `null` after eviction absorbs it into the fresh backing. A `null` before any absorbed value absorbs nothing, and the read stays cold |
| `zero` | absorbs 0 |

- A series over a `T?` source without `nulls:` is refused with `DS_VALIDATE_SERIES_NULLS_REQUIRED`.
- `nulls:` on a non-nullable source is refused with `DS_VALIDATE_SERIES_NULLS_ON_NON_NULLABLE`.
- `nulls: zero` on a source other than `Int?` or `Float?`, unit-typed or not, is refused with `DS_VALIDATE_SERIES_NULLS_ZERO_NON_NUMERIC`.

`nulls:` is a value policy, one per series, covering every aggregation over the slot. It is not the time-axis `gap` phrase.

*(Spec: [LNUL.8.6], [LSER.9.3.2])*

## Absent arguments on the right-hand side

### Verb policies

A verb's argument may be `null`. Each verb has its own policy for a `null` argument.

| Verb | Policy |
|---|---|
| `log` | a `null` interpolated in the message renders as the empty string |
| `emit`, `publish` | a slot declared `T?` takes `null`, and any other slot raises a `TypeError` |
| `call` | the call is not made, and the firing's other actions run |
| `cache` | `null` is stored as itself; a `cached(key)` miss and a stored `null` are indistinguishable at the read |

*(Spec: [LNUL.11.1])*

### Traps in actions

A trap is not an absent value: it never reaches a slot, and it abandons the activation.

A fault raised evaluating an argument never reaches the verb, whichever verb holds the argument. A `ComputationError` or a `TypeError` abandons the activation.

Actions already performed stand, and actions after the trap do not run.

*(Spec: [LNUL.11.1])*
