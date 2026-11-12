<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Conversions

## The operator

### The cast

**`<expr>::T`**, **`<expr>::T?`**

`::` is a postfix conversion operator, the only conversion form.

It stands in the postfix chain with `.`, method calls and `[…]`, evaluated left to right, and binds tighter than every unary and binary operator. `R.v::Int.bit_count` is `(R.v::Int).bit_count`; `R.temp::Float > x` is `((R.temp)::Float) > x`.

`T` is one terminal resolved in the type namespace: a scalar builtin, `Time`, `Date` and [`Duration`](../time/types.md#duration) among them, `Json`, or a unit. A schema as a target is refused with `DS_VALIDATE_CAST_UNDEFINED`.

```ds expression
r.n::Float
r.level::Int
r.label::Int?
```

*(Spec: [LCST.4.1.1], [LCST.4.1.2], [LCST.4.1.4], [LCST.4.1.6], Source: compiler/mercury/src/dsc.typecheck.m)*

### Total cast

**`<expr>::T`**

`::T` must succeed, and its result type is `T`.

Total means it cannot yield `null`, not that it is lossless. A total cast traps on an input it cannot represent: the trap is no `null`, feeds no `??`, and abandons the activation as an `Int` division by zero does, unless engine state is untrustworthy, which halts the tier.

*(Spec: [LCST.4.2.1], [LCST.4.5.4])*

### Fallible cast

**`<expr>::T?`**

`::T?` yields `null` on failure, and its result type is `T?`.

The result feeds `??`, Kleene logic and narrowing as any `T?` does. After a guard that it is not null, it narrows to `T`.

*(Spec: [LCST.4.2.2], [LCST.4.3.3], [LCST.4.4.1])*

### The question mark rule

The `?` is present if and only if the result can be null: the source is nullable or the conversion fallible.

| Source | Conversion | `::T` | `::T?` |
|---|---|---|---|
| `S` | total | `T` | refused |
| `S` | fallible | refused | `T?` |
| `S?` | total | refused | `T?` |
| `S?` | fallible | refused | `T?` |

Each refusal is `DS_VALIDATE_CAST_NULLABILITY`. `null::T` is refused; `null::T?` is `null`.

```ds expression error=DS_VALIDATE_CAST_NULLABILITY
r.label::Int
```

*(Spec: [LCST.4.2.3], [LCST.4.3.1], [LCST.4.3.2])*

### Null source

A `null` source of a `::T?` gives `null`: the conversion is not attempted and nothing is raised.

*(Spec: [LCST.4.3.4], [LCST.4.5.4])*

### Binding of the question mark

The `?` binds to the target before any following operator.

`??` is one token, so `x::Int??d` is `(x::Int) ?? d`, a total cast then a coalesce. A fallible cast then a coalesce separates the two: `x::Int? ?? d`. `x::Int???d` does not spell it.

*(Spec: [LCST.4.1.3])*

### Chained casts

**`x::A::B`**

A chain applies each conversion left to right, and the result of each is the source of the next.

`x::Int?::Float`, a nullable source with a bare target, is refused with `DS_VALIDATE_CAST_NULLABILITY`. `x::Int?::Float?` is the legal form.

*(Spec: [LCST.4.1.5])*

## The conversions

### Identity

`x::T` where `x` has type `T`, the same unit included, is a legal no-op, with the warning `DS_VALIDATE_CAST_IDENTITY`.

*(Spec: [LCST.4.5.1])*

### Defined conversions

Identity and this table are the complete set of legal conversions.

| Source to target | Class | Result |
|---|---|---|
| `Int` to `Float` | total | widening |
| `Float` to `Int` | total | the truncation toward zero; a trap if that is no `Int`, as for a non-finite value or one outside `Int` |
| unit to its storage kind | total | `Float` for a `float64` dimension, `Int` for an `int64` or `int32` one; a [strip](../units/checking.md#assertion-and-strip), a runtime identity |
| storage kind to unit | total | `Float` to a `float64` unit, `Int` to an `int64` or `int32` unit; the number is in that unit, and the result is held in the base unit ([assertion](../units/checking.md#assertion-and-strip)). A negative `Int` to a `time` unit gives `0_s` |
| `Duration` to a `time` unit, and back | total | a runtime identity |
| `Int`, `Float`, `Bool` to `String` | total | see [String rendering](#string-rendering) |
| `Time`, `Date`, `Duration` to `String` | total | see [Temporal text](#temporal-text) |
| `Duration` to `Int` | total | its nanoseconds |
| `String` to `Int`, `Float`, `Bool` | fallible | see [String parsing](#string-parsing) |

*(Spec: [LCST.4.5.2])*

### Refused conversions

A pair that is no identity and no defined conversion is refused with `DS_VALIDATE_CAST_UNDEFINED`.

Among them: numeric with `Bool` in either direction, a unit with the other numeric kind, `String` to `Time`, `Date` or `Duration`, a scalar to `Json`, and a whole `Json` value to a scalar. A leaf a path reads from a `Json` value, and a value computed from one, a `??` over one included, converts as the value it holds ([Json leaf conversion](json.md#json-leaf-conversion)). `Bytes` with `String` is refused [with its own code](strings.md#bytes-and-string-conversion), an opaque source [with its own](opaque.md#elimination), and a fact to `Json` with `DS_VALIDATE_RULE_NOT_LOWERED`.

A defined conversion a compiler does not implement is refused with `DS_VALIDATE_CAST_UNSUPPORTED`.

```ds expression error=DS_VALIDATE_CAST_UNDEFINED
r.n::Json
```

*(Spec: [LCST.4.5.2], [LCST.4.5.3], [LCST.4.5.11])*

### String rendering

`Int` renders as its exact decimal, and `Bool` as `"true"` or `"false"`.

A finite `Float` renders in the canonical shortest-round-trip form, lossless through `::Float?`. `±Inf` renders `"inf"` and `"-inf"`. NaN renders `"nan"`, whatever its sign and payload.

*(Spec: [LCST.4.5.6])*

### Temporal text

`t::String`, `d::String` and `dur::String` render in the type's canonical form: `"iso8601"` for `Time` and `Date`, the compact form for `Duration`.

No cast reads one back.

*(Spec: [LCST.4.5.9])*

### String parsing

`::Bool?`, `::Int?` and `::Float?` read a `String` in its entirety, and yield `null` for every other string.

| Target | Accepts |
|---|---|
| `Bool` | exactly `"true"` and `"false"`, case-sensitive |
| `Int` | an optional `+` or `-`, then an `INT_LIT`: decimal, `0x`, `0b` or `0o`, with `_` placed as a source literal places it, the value in the 64-bit range |
| `Float` | an optional `+` or `-`, then an `INT_LIT`, a `FLOAT_LIT` or `inf`, with `_` placed as a source literal places it |

A `Float` result is the value rounded to the nearest `Float`, ties to even; a zero keeps the sign it is spelt with. `::Float?` yields `null` for a finite spelling that rounds to an infinity and for a NaN spelling. `::Int?` and `::Float?` yield `null` for surrounding whitespace and a unit suffix, and `::Int?` for a decimal point, an exponent or a value outside the 64-bit range. Every canonical rendering of a `Float` is accepted.

*(Spec: [LCST.4.5.5], [LCST.4.5.7], [LCST.4.5.8])*
