<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Temporal arithmetic

## Arithmetic

### Time and Duration

| Expression | Result |
|---|---|
| `Time - Time` | `Duration` |
| `Time + Duration` | `Time`, the left operand's offset preserved |
| `Time - Duration` | `Time`, the left operand's offset preserved |
| `Duration + Duration` | `Duration` |
| `Duration - Duration` | `Duration` |
| `Int * Duration`, `Duration * Int` | `Duration` |
| `Duration / Int` | `Duration`, by integer division of nanoseconds |

Arithmetic operates on `utc_ns` and the nanosecond magnitude. A `Duration`-valued row whose exact result is negative yields `0_s`: `Time - Time` with the left operand the earlier, `Duration - Duration` with the right operand the larger, and a product or quotient with a negative `Int`.

```ds expression
r.ts + 1_h
now() - r.ts
2 * 30_min
```

*(Spec: [LTIM.4.1.1], [LTIM.4.1.2])*

### Date

| Expression | Result |
|---|---|
| `Date - Date` | `Duration`, a multiple of 24 hours; `0_s` when the left operand is the earlier |
| `Date + Duration` | `Date`, the whole days after |
| `Date - Duration` | `Date`, the whole days before |

A literal sub-day duration is refused with `DS_VALIDATE_DATE_SUBDAY_ARITHMETIC`.

At run time, the first of these that applies decides:

1. A `null` operand yields `null`.
2. A `Duration` that is not a whole number of days raises a `ComputationError` of kind `DOMAIN`.
3. An operand or result outside its type's range raises a `ComputationError` of kind `NOT_REPRESENTABLE`, never a wrap.

```ds expression error=DS_VALIDATE_DATE_SUBDAY_ARITHMETIC
r.ts.date("UTC") + 1_h
```

*(Spec: [LTIM.4.2.1], [LTIM.4.2.2], [LTIM.4.2.3])*

### add_months and add_years

**`t.add_months(n: Int) → Time`**, **`d.add_months(n: Int) → Date`**, **`t.add_years(n: Int) → Time`**, **`d.add_years(n: Int) → Date`**

`add_months` and `add_years` shift a calendar date by the given months or years.

A day-of-month invalid in the target month clamps to its last valid day: one month added to 2024-03-31 is 2024-04-30. On a `Time` the shift is on the UTC calendar date, keeping the UTC time of day. A result outside its type's range raises a `ComputationError` of kind `NOT_REPRESENTABLE`.

```ds expression
r.ts.add_months(1)
r.ts.date("UTC").add_years(1)
```

*(Spec: [LTIM.4.3.1], [LTIM.4.3.2], [LTIM.4.3.3])*

## Comparison

### Comparison operators

`<`, `<=`, `>`, `>=`, `==` and `!=` are defined on `Time`, `Date` and `Duration`.

| Type | Compared on |
|---|---|
| `Time` | `utc_ns`; the offset is irrelevant |
| `Date` | `(year, month, day)`, lexicographically |
| `Duration` | the nanosecond count |

A comparison across types is refused with `DS_VALIDATE_TYPE_MISMATCH`.

```ds expression error=DS_VALIDATE_TYPE_MISMATCH
r.ts < r.ts.date("UTC")
```

*(Spec: [LTIM.5.1], [LTIM.5.2], [LTIM.5.3], [LTIM.5.4], [LTIM.5.5], Source: compiler/mercury/src/dsc.typecheck.m)*

## Extraction

### Components

**`.hour`**, **`.minute`**, **`.second`**, **`.day_of_week`**, **`.day`**, **`.month`**, **`.year`**

A component is an `Int` member of the result of `t.utc` or `t.local(tz)`, or, for `.day`, `.month`, `.year` and `.day_of_week`, of a `Date`.

| Component | Range |
|---|---|
| `.hour` | `0..23` |
| `.minute` | `0..59` |
| `.second` | `0..59` |
| `.day` | `1..31`, valid for the month and year |
| `.month` | `1..12` |
| `.year` | the full Gregorian year |
| `.day_of_week` | `0..6`, `0` Monday and `6` Sunday |

A component of a `Time` is that component of the instant in the zone: UTC for `.utc`, and consulting no fact, or the [resolved](zones.md#resolving-a-zone) zone for `.local(tz)`. A component of a `Date` is that component of its midnight in UTC.

A component read directly on a `Time` is refused with `DS_VALIDATE_TIME_NEEDS_TZ_CONTEXT`. A component its receiver does not have is refused with `DS_VALIDATE_UNKNOWN_MEMBER`.

```ds expression error=DS_VALIDATE_TIME_NEEDS_TZ_CONTEXT
r.ts.hour
```

*(Spec: [LTIM.6.1], [LTIM.6.2], [LTIM.6.3], [LTIM.6.5], [LTIM.6.6])*

## Truncation

### floor

**`t.floor(d: Duration) → Time`**

`t.floor(d)` returns the latest boundary of `d` at or before `t`, keeping `t`'s offset.

The boundaries are the multiples of `d` counted from 1970-01-01T00:00 at `t`'s offset. An instant on a boundary floors to itself. `floor` to `0_s` is a `ComputationError` of kind `DIVIDE_BY_ZERO`, and a result before the first representable instant is `NOT_REPRESENTABLE`. A non-`Duration` argument is refused with `DS_VALIDATE_BAD_OPERAND_TYPE`, and `floor` on a `Date` with `DS_VALIDATE_UNKNOWN_MEMBER`.

```ds expression error=DS_VALIDATE_UNKNOWN_MEMBER
r.ts.date("UTC").floor(1_d)
```

*(Spec: [LTIM.7.1], [LTIM.7.4], Source: compiler/mercury/src/dsc.typecheck.m)*

### floor and offsets

`floor` truncates at the offset its receiver carries and consults no timezone, so a daylight saving transition moves no boundary.

A `.local(tz)` receiver truncates at the offset `tz` gave it when resolved, and a `.utc` receiver at UTC. For a receiver in a zone with daylight saving:

- Resolved after spring-forward, it carries the new offset. America/Los_Angeles, 2026-03-08: 12:00 at −7 h floors to `1_d` as 00:00 at −7 h (07:00Z), and the zone's midnight that day is 00:00 at −8 h (08:00Z).
- The second 1:30 AM at fall-back carries the standard offset. America/Los_Angeles, 2026-11-01: 1:30 at −8 h floors to `1_h` as 1:00 at −8 h (09:00Z).

*(Spec: [LTIM.7.2], [LTIM.7.3])*
