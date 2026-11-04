<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Time zones

## Zone data

### TimeZoneOffset

`TimeZoneOffset` is a [built-in schema](../facts/builtin-schemas.md#the-built-in-schemas), `scope logical ambient`, each fact one zone's offset over one period.

The integrator asserts its facts, as in [Asserting](inv:integrator:std:doc#facts/asserting), which states what it refuses. What a rule may do with one is at [`ambient`](../facts/lifecycles.md#ambient). Its identity is `(zone, valid_from)`.

| Slot | Type | Marker | Meaning |
|---|---|---|---|
| `zone` | `String` | key | the designation the fact resolves, compared byte for byte: no normalisation, and case is significant |
| `valid_from` | `Time` | key | the first instant of the period, inclusive |
| `valid_until` | `Time` | mutable | the end of the period, exclusive |
| `offset_s` | `Int` | mutable | the offset over the period, in seconds east of UTC |

*(Spec: [LTIM.10.1], [LTIM.10.6], [LTIM.10.9])*

## Resolution

### Resolution sites

A zone is resolved at `t.local(tz)` and `t.date(tz)`, and nowhere else.

The `::String` cast and `to_string` write the value's own offset, the `epoch_*` forms are UTC integers, and `calendar.time` builds a UTC instant.

*(Spec: [LTIM.10.3])*

### Resolving a zone

To resolve a designation `Z` other than `"UTC"` at instant `t`, the engine takes the live `TimeZoneOffset` fact of `Z` with the greatest `valid_from` not after `t`.

If its `valid_until` is after `t`, its `offset_s` is the answer. Otherwise, and when there is no such fact, `Z` has no answer at `t`. A fact whose period overlaps another of its zone is admitted, and this rule decides which answers. A period is half-open, so no zone but `"UTC"` has an answer at the last instant of the `Time` range.

A resolution sees every fact the host asserted, replaced or retracted before it, and no host assert or retract runs during a pump. A change to a zone's facts re-evaluates a `where` that resolves the zone, and does not re-run an action that has fired.

*(Spec: [LTIM.10.7], [LTIM.10.9], [LTIM.10.10])*

### UTC

The designation exactly `"UTC"` is offset 0 at every instant, consulting no fact.

Every other designation, `"UTC+8"`, `"utc"` and `"PST"` included, resolves only through facts under that exact string.

*(Spec: [LTIM.10.8])*

### Resolution failure

When no fact answers for the zone at the instant, `.local(tz)` or `.date(tz)` raises a `ComputationError` of kind `DOMAIN`.

The activation is abandoned, the rule does not fire, the fault is a stream event, and the engine continues. This holds for a zone from a literal or from data. A zone operand that is not a `String`, or is `null`, is a type mismatch.

*(Spec: [LTIM.10.5.1], [LTIM.10.5.3], [LTIM.10.5.4])*

## Daylight saving time

### Offsets across transitions

Every resolution goes from an instant to an offset, and no wall-clock time is resolved to an instant, so a local time skipped or repeated at a transition is never read.

The offset is as correct as the facts the host supplies. A value that carries an offset across a transition is at [floor and offsets](arithmetic.md#floor-and-offsets).

*(Spec: [LTIM.3.2.2], [LTIM.12.11])*
