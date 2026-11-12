<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Temporal types

## Types

### Time

**`(utc_ns: Int64, tz_offset_ns: Int64)`**

A `Time` value is a point in time: nanoseconds since the Unix epoch in UTC, and an offset in nanoseconds east of UTC.

Ordering, equality and arithmetic operate on `utc_ns` alone. The offset is a whole number of seconds, resolved by [`local`](#local), and fixed for the value within an expression.

A `Time` in a fact slot persists `utc_ns` only: read back, it has offset 0.

The range is `utc_ns`'s `Int64` range. An operation in a rule whose result falls outside it raises a `ComputationError` of kind `NOT_REPRESENTABLE`.

*(Spec: [LTIM.1.1.1], [LTIM.1.1.2], [LTIM.1.1.3], [LTIM.1.1.5])*

### Date

**`(year, month, day)`**

A `Date` value is a Gregorian calendar date with no time of day and no timezone.

| Component | Width | Range |
|---|---|---|
| `year` | 32-bit signed integer | the full Gregorian year |
| `month` | 8-bit signed integer | `1..12` |
| `day` | 8-bit signed integer | `1..31`, valid for the month and year |

Every `Date` names a day of the proleptic Gregorian calendar. The range is `1677-09-22` through `2262-04-11`, the days whose midnight in UTC is a representable `Time`. An operation in a rule whose result falls outside it raises a `ComputationError` of kind `NOT_REPRESENTABLE`.

*(Spec: [LTIM.1.2.1], [LTIM.1.2.2], [LTIM.1.2.3], [LTIM.1.2.4], [LTIM.1.2.5])*

### Duration

A `Duration` is a magnitude in nanoseconds, stored as `int64`, and is never negative.

Wherever a `Duration` would be formed with a negative number of nanoseconds, the compiler and the runtime form `0_s`: by [arithmetic](arithmetic.md#time-and-duration), by a negative `Int` [cast to a `time` unit](../values/conversions.md#defined-conversions), and for a negative value a host asserts into a `Duration` slot. A signed difference of two instants is an `Int`: `(a - b)::Int - (b - a)::Int`.

A `Duration` is a value of the `time` dimension, and every value of that dimension is a `Duration`: a [`time`-dimensioned literal](../units/literals.md#duration-literals), a slot or service kwarg typed by a `time` unit or by `time`, a `::<time unit>` cast, and each `Duration`-valued row of [arithmetic](arithmetic.md#time-and-duration), `Date - Date` among them. The `time` unit a slot or kwarg declares sets how the value displays and is delivered, and names no other type. A unary minus on a `Duration` is refused with `DS_VALIDATE_BAD_OPERAND_TYPE`, and a bitwise operator with `DS_VALIDATE_BITWISE_TYPE`. A `Duration` carries no timezone: `Time - Time` gives the same `Duration` whatever the operands' offsets.

```ds expression
(now() - r.ts)::Int - (r.ts - now())::Int
```

*(Spec: [LTIM.1.3.1], [LTIM.1.3.2], [LTIM.1.3.3], [LTIM.1.3.4], [LTIM.1.3.5], [LUNI.3.3])*

## Construction

### utc

**`t.utc → Time`**

`t.utc` returns `t` with the offset set to 0, consulting no timezone fact.

```ds expression
r.ts.utc
```

*(Spec: [LTIM.3.1.1])*

### local

**`t.local(tz: String) → Time`**

`t.local(tz)` returns `t` with the offset `tz` [resolves to](zones.md#resolving-a-zone) at `t`.

The UTC component is unchanged. A failure to resolve is [a runtime error](zones.md#resolution-failure).

```ds expression
r.ts.local("UTC")
```

*(Spec: [LTIM.3.2.1], [LTIM.3.2.2], [LTIM.3.2.3])*

### Date of an instant

**`t.date(tz: String) → Date`**

`t.date(tz)` returns the calendar date `t` falls on in the named zone.

`t.date()` with no argument is refused with `DS_VALIDATE_DATE_NEEDS_TZ`.

```ds expression error=DS_VALIDATE_DATE_NEEDS_TZ
r.ts.date()
```

*(Spec: [LTIM.3.3.1], [LTIM.3.3.2], Source: compiler/mercury/src/dsc.typecheck.m)*

## Clocks

### Engine clocks

An engine holds a monotonic clock and a wall clock, both in integer nanoseconds.

The nanosecond unit is a storage and arithmetic contract: effective resolution is the platform clock's. The stream `seq`, not a sub-microsecond difference of time values, orders events. The host's view is [Clock](inv:integrator:std:doc#engine/clock).

*(Spec: [LTIM.2.3], [LTIM.2.8.1])*

### Monotonic clock

The monotonic clock never decreases, and only the difference between two of its readings has a meaning.

TTL expiry, [`after`](../actions/after.md#after), a call's [`timeout`](../calls/continuations.md#timeout), [`cooldown`](../rules/cooldown.md#cooldown), a single pattern's `within`, [`dwell`](../facts/logical.md#dwell) and series windows read it and no other clock, so a change to the wall clock moves none of them. A sequence's [`then … within`](../rules/temporal.md#then) compares the facts' own [`ts`](../facts/schemas.md#ts) values instead.

*(Spec: [LTIM.2.8.2])*

### Wall clock

The wall clock reads UTC nanoseconds since the Unix epoch, and may jump forward or move backward between two samples.

It drives `now()` and the `ts` the engine fills, and nothing else.

A `now()` read while the wall clock has no value, or the engine filling a `ts` from it, is a `ComputationError` of kind `DOMAIN`, and the engine continues. In an activation, a `now()` read, an `emit` or a `publish`, the activation is abandoned and the rule does not fire. An `initial` block's fact is not placed.

*(Spec: [LTIM.2.8.3])*

### Clock samples

The engine samples both clocks together when it consumes an input and when a pump begins, and at no other time.

Every read between two samples, in a `where`, a re-evaluation, a `let` or an action, returns the most recent sample.

*(Spec: [LTIM.2.8.4])*

### Entry stamp

Each fact takes the monotonic clock's current sample when it enters working memory.

A fact replaced by retract-and-replace takes a new stamp, and a suppressed no-op reassertion keeps its stamp. `dwell` and `within` measure from it. It is engine state, not a slot.

*(Spec: [LTIM.2.8.6])*

### now

**`now() → Time`**

`now()` returns the wall clock's current sample as a `Time` with offset 0, at full nanosecond width.

Two calls within one activation return the same value.

```ds expression
now() - r.ts
```

*(Spec: [LTIM.2.1.1], [LTIM.2.1.2], [LTIM.2.1.3])*

### monotonic_ns

**`monotonic_ns() → Duration`**

`monotonic_ns()` returns the [monotonic clock](#monotonic-clock)'s current sample as a `Duration`.

*(Spec: [LTIM.2.2.1], [LTIM.2.2.2])*

## Time-dependent conditions

### Time-dependent reads

A `where` condition is time-dependent when its truth can change from one pump to the next with no change to the matched facts.

Three reads make it so:

- a clock read: `now()`, `monotonic_ns()` or `dwell`;
- a series read: an aggregation over a series, as a call or a companion slot;
- a zone read: the resolution of any zone but `UTC`.

*(Spec: [LTIM.2.4.1])*

### Re-evaluation

A time-dependent condition is re-evaluated on every pump, not only when a matched fact is asserted or a left token arrives.

A rule whose only unmet gate is a time-dependent condition fires once the clock satisfies it, with no fact activity, and a `cooldown` does not exempt it. Re-evaluation reads both clocks as sampled when the pump began, and every series as it stood then. The effect on a `logical` fact is at [Time-dependent tests](../facts/logical.md#time-dependent-tests).

*(Spec: [LTIM.2.4.2], [LTIM.2.4.3])*

### Edge firing

A rule gated on a time-dependent condition fires once per false-to-true edge for a given matched fact wrapper, on the pump of the edge, and does not re-fire while the condition stays true.

- When the condition goes true to false, the match ends with its activation. Going false to true again for the same wrapper is a new edge, and fires.
- A new fact wrapper re-arms: a meaningful change or a retract and re-match. A no-op reassertion does not.
- A condition already true when its fact is asserted fires on the next pump if it holds under that pump's sample.
- A pump that ends at a firing limit leaves the activation unfired, and it fires on a later pump if its match persists.
- With a `cooldown`, the rule fires when the condition holds and the rate window permits.

*(Spec: [LTIM.2.5.1], [LTIM.2.5.2], [LTIM.2.5.3], [LTIM.2.5.4])*

### Multiple patterns

The re-evaluation guarantee is for a rule with a single positive pattern; beyond one, a time-dependent condition is [refused](../expr/operators.md#where-on-a-join).

A positive pattern's `within` counts, and a `then … within` step does not. `t.local(tz)` and `t.date(tz)` count unless `tz` folds to `"UTC"`, as a literal or a `const`.

*(Spec: [LTIM.2.6.1], [LTIM.2.6.2])*

### within

**`within <dur>`**

A positive pattern's `within <dur>` is time-dependent: the fact matches only while the monotonic clock's sample is less than `<dur>` past its [entry stamp](#entry-stamp).

A window reads working memory, so a fact counts while it is live. A duration that is not positive, on a positive or a negated pattern, written as a literal or a `time` const, is refused with `DS_VALIDATE_ZERO_WITHIN`. A duration longer than the TTL of the pattern's schema, on a positive or a negated pattern, is refused with `DS_VALIDATE_WITHIN_EXCEEDS_TTL`. A window equal to the TTL is not refused, a schema of another lifecycle bounds no window, and with `dynamic_ttl` on no window is refused this way. When a windowed pattern justifies a `logical` fact, the engine retracts that fact on the pump its match falls outside the window.

```ds rule
rule recent:
    Reading r within 5_min
->
    log info "{r.id}"
```

*(Spec: [LTIM.2.7.1], [LTIM.2.7.2], [LTIM.2.7.3], [LFAC.3.3])*

## Formatting

### to_string

**`t.to_string(format: String) → String`**, **`d.to_string(format: String) → String`**

`to_string` writes a `Time` or a `Date` in a named format.

The ISO 8601 form and the `Duration` compact form are written by [the `::String` cast](../values/conversions.md#temporal-text).

*(Spec: [LTIM.8.1.2], [LTIM.8.1.3])*

### Format identifiers

| Identifier | Written as | Types |
|---|---|---|
| `"iso8601"` | `"2024-01-15T08:00:00-08:00"`; `"2024-01-15"` | `Time`, `Date` |
| `"epoch_seconds"` | `"1705334400"` | `Time` |
| `"epoch_millis"` | `"1705334400000"` | `Time` |
| `"epoch_micros"` | `"1705334400000000"` | `Time` |
| `"epoch_nanos"` | `"1705334400000000000"`, the full `utc_ns` | `Time` |

An identifier may be written in any case. `epoch_seconds`, `epoch_millis` and `epoch_micros` are `floor(utc_ns / 10ⁿ)`, toward negative infinity: `utc_ns = -1500` is `epoch_micros` `-2`.

A literal identifier that is unknown, or that its type does not take, such as an epoch form on a `Date`, is refused with `DS_VALIDATE_UNKNOWN_TIME_FORMAT`. An unknown computed one raises a `ComputationError` of kind `NOT_REPRESENTABLE` and abandons the activation.

```ds expression error=DS_VALIDATE_UNKNOWN_TIME_FORMAT
r.ts.to_string("rfc3339")
```

*(Spec: [LTIM.8.2.1], [LTIM.8.2.1a], [LTIM.8.2.2], [LTIM.8.3.2], Source: compiler/mercury/src/dsc.typecheck.m)*

### iso8601 text

```text
time   = date , "T" , hour , ":" , minute , ":" , second ,
         [ "." , digit , { digit } ] , [ zone ] ;
date   = year , "-" , month , "-" , day ;
zone   = "Z" | ( "+" | "-" ) , 2 * digit , [ ":" ] , 2 * digit ;
year   = 4 * digit ;
month  = 2 * digit ;
day    = 2 * digit ;
hour   = 2 * digit ;
minute = 2 * digit ;
second = 2 * digit ;
digit  = "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" ;
```

The `iso8601` text of a `Time` is `time`, and of a `Date` is `date`.

`::String` of a `Time` writes the wall-clock time at the value's offset, then the zone: `Z` for a zero offset, otherwise `+hh:mm` or `-hh:mm`. It writes a fraction only when the sub-second part is not zero, as `.` and nine digits with the trailing zeros removed.

*(Spec: [LTIM.8.2.3], [LTIM.8.2.4])*

### Duration compact form

**`dur::String`**

`dur::String` writes adjacent unit-tagged components in descending order of size, omitting zero-valued ones.

The units are `h`, `m`, `s`, `ms`, `us` and `ns`, each at most once: `"1h30m"`, `"500ms"`, `"2h15s"`. The zero `Duration` is `"0s"`. It carries no sign.

*(Spec: [LTIM.8.4.1], [LTIM.8.4.2])*
