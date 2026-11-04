<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Interval

## The type

### Interval values

**`Interval<T>: (start: T, end: T)`**

An `Interval` value is a half-open range `[start, end)` over one element type `T`.

`T` is `Int`, `Float`, `String`, `Time`, `Date` or [`Duration`](../time/types.md#duration). `Int` and `Float` are one numeric element type, compared as the numeric comparison compares them. Intervals of different element types are distinct types.

*(Spec: [LINT.1.1], [LINT.1.2])*

### Time endpoints

An `Interval<Time>` carries a timezone offset on each endpoint, and the offsets need not match.

*(Spec: [LINT.1.3])*

### Interval slots

An `Interval` is no slot type; a slot declared `Interval` or `Interval<T>` is refused with `DS_VALIDATE_BAD_TYPE`.

A fact carries an interval as its two endpoints.

*(Spec: [LINT.1.4])*

## Construction

### The range operator

**`a .. b`**

`a .. b` is the `Interval<T>` with `start` `a` and `end` `b`, always half-open.

`..` binds tighter than the logical operators and looser than additive arithmetic: `m.fired_at .. m.fired_at + 1_h` is `m.fired_at .. (m.fired_at + 1_h)`. An interval that includes a value has its `end` one step past it: one nanosecond for a `Time` or `Duration`, one day for a `Date`, one for an `Int`. A `Float` or `String` interval has no next value and excludes its `end`.

```ds expression
r.n .. r.n + 10
r.ts .. r.ts + 1_h
```

*(Spec: [LINT.2.1], [LINT.2.3], [LINT.2.4])*

### Operand refusals

- Operands of two element types are refused with `DS_VALIDATE_INTERVAL_MIXED_OPERANDS`.
- An operand of an unlisted type, among them a `Bool`, a `Bytes` value, a whole `Json` value, a fact reference, an opaque value and an interval, is refused with `DS_VALIDATE_UNORDERED_TYPE`.

An operand of statically unknown type, a `Json` path read, is judged by the ordinary type rules when the interval is used.

*(Spec: [LINT.2.2])*

## Relations

### in

**`t in i`**

`t in i` is `Bool`: `i.start <= t` and `t < i.end`.

The point must have the interval's element type; `Time in Interval<Date>` and `Date in Interval<Time>` are refused with `DS_VALIDATE_TYPE_MISMATCH`.

```ds expression
r.n in (0 .. 10)
```

*(Spec: [LINT.3.1.1], [LINT.3.1.3], Source: compiler/mercury/src/dsc.typecheck.m)*

### contains

**`i1 contains i2`**

`i1 contains i2` is `Bool`: `i1.start <= i2.start` and `i2.end <= i1.end`.

An empty `i2` is contained by any `i1` whose range includes `i2.start`, and `(a..a) contains (a..a)` is true. Mixed element types are refused with `DS_VALIDATE_TYPE_MISMATCH`.

*(Spec: [LINT.3.2.1], [LINT.3.2.2], [LINT.3.2.3], Source: compiler/mercury/src/dsc.typecheck.m)*

### overlaps

**`i1 overlaps i2`**

`i1 overlaps i2` is `Bool`: `max(i1.start, i2.start) < min(i1.end, i2.end)`.

Adjacent intervals, `i1.end == i2.start`, do not overlap. An empty interval overlaps none, another empty one included. Mixed element types are refused with `DS_VALIDATE_TYPE_MISMATCH`.

```ds expression
(r.n .. 10) overlaps (5 .. 15)
```

*(Spec: [LINT.4.1], [LINT.4.2], [LINT.4.3], [LINT.4.4], Source: compiler/mercury/src/dsc.typecheck.m)*

### Relation operands

A non-Interval literal operand of a relational operator, as in `5 contains 3`, is refused with `DS_VALIDATE_INTERVAL_REL_NON_INTERVAL`.

An operand of statically unknown type is not refused here, and resolves under the ordinary type rules.

*(Spec: [LINT.4.5])*

## Equality

### Interval equality

**`i1 == i2`**, **`i1 != i2`**

`i1 == i2` is `Bool`, true iff the starts are equal and the ends are equal under the element type's equality; `!=` is its negation.

`Interval<Time>` compares endpoints on `utc_ns`: `tz_offset_ns` does not affect equality. Cross-type equality is refused with `DS_VALIDATE_TYPE_MISMATCH`.

*(Spec: [LINT.5.1], [LINT.5.2], [LINT.5.3], [LINT.5.4], Source: compiler/mercury/src/dsc.typecheck.m)*

### Interval ordering

`<`, `>`, `<=` and `>=` on intervals are refused with `DS_VALIDATE_INTERVAL_NO_ORDERING`.

*(Spec: [LINT.5.3], Source: compiler/mercury/src/dsc.typecheck.m)*

## Extraction

### Components

An `Interval<T>` has these readable components; any other, or `i.duration` on another element type, is refused with `DS_VALIDATE_BAD_INTERVAL_COMPONENT`.

| Component | Type | Meaning |
|---|---|---|
| `i.start` | `T` | inclusive start endpoint |
| `i.end` | `T` | exclusive end endpoint |
| `i.duration` | `Duration` | `i.end - i.start`, for `T` `Time` or `Date` only |

For `Interval<Date>`, `i.duration` is a whole-day multiple, and for `Interval<Time>` the nanosecond difference of the endpoints. An endpoint's own extraction follows its element type: `.hour` on an `Interval<Time>`'s `i.start` requires `.utc` or `.local(tz)` as on a bare `Time`.

```ds expression
(r.ts .. r.ts + 1_h).duration
```

*(Spec: [LINT.6.1], [LINT.6.2], [LINT.6.3])*

## Empty and invalid

### Empty interval

An interval with `start == end` is empty and legal, with zero duration; no `t` is `in` it.

*(Spec: [LINT.7.1])*

### Invalid interval

An interval is valid only when `start <= end` under its element type's `<=`; one with `end < start`, or a NaN endpoint, is invalid.

A `null` endpoint does not make an interval invalid. Evaluating `start .. end` with two non-null endpoints that are not `start <= end` raises a `ComputationError` of kind `DOMAIN`.

The fault is `..`'s own: `in`, `contains`, `overlaps`, `==`, `!=` and a component read on the interval each yield it, whatever the other operand is, `null` included. A `let` bound to an interval is evaluated where it is used, and an invalid interval no operation uses raises nothing.

Two literal endpoints that are invalid are refused with `DS_VALIDATE_INTERVAL_INVERTED`.

```ds expression error=DS_VALIDATE_INTERVAL_INVERTED
(r.n .. 10) == (5 .. 3)
```

*(Spec: [LINT.7.2], [LINT.7.4], Source: compiler/mercury/src/dsc.typecheck.m)*
