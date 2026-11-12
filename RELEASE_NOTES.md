<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->
# Release notes

## 1.1.0

**Before upgrading:** recompile every `.dsc` file. Recordings made on 1.0.x
can only be replayed on 1.0.x.

### Changes that can stop a program compiling

- A value with a unit can no longer be added to, subtracted from, compared
  with or taken `%` of a plain number, in either order and `0` included:
  `5_meter + 1` and `5_meter > 0` are now errors. Multiplying or dividing it
  by a plain number still works.
- `min`, `max`, `??`, `..` and `in` follow the same rule, and also refuse two
  values of different dimensions: `max(5_meter, 1.0)` is now an error.
- A type annotation no longer makes a product or quotient of two units
  acceptable, and no longer gives a plain number a unit:
  `let p: watt = v * i` and `let d: meter = 5.0` are now errors. Strip the
  operands with `::Float` and assert the unit on the result:
  `(v::Float * i::Float)::watt`.
- A `let` holding `integral`, `variance`, `pvariance` or `rate` of a slot with
  a unit, or of a `Duration` slot, is now an error even with an annotation.
  Strip the read: `integral(r)::Float`, or `variance(r)::Float?`.
- `math.sqrt`, `math.ln` and the other builtins that take a plain number now
  refuse a value with a unit; strip it with `::Float` first. `abs` keeps its
  unit, so `abs(r.distance) > 25` is refused, and `math.pow` refuses a unit
  as `**` does.
- A value in a time unit, such as a `millisecond` slot, is now a `Duration`:
  a unary minus or a bitwise operator on it is an error.
- A `const` can no longer hold `null`, and its right-hand side is now
  type-checked as a whole: `const x = 5_meter + 1` is now an error.
- A constant too large for the value it becomes is now an error, where 1.0.0
  compiled it to a wrong number: a duration literal past the largest
  `Duration`, such as `10000000000_s`, or a unit whose factor or offset is out
  of range.
- A `calendar` call whose arguments are all constants is now treated as a
  constant everywhere. One that names a date that doesn't exist, such as
  February 30, is a compile error rather than a fault when the rule runs.
- The `ttl:` on a cache write must now be a `Duration`, such as `30_s`.
- A `within` window longer than the TTL of the schema it reads is now an
  error.
- Converting a JSON leaf with a default to `Int`, `Float` or `Bool` now needs
  a `?`: write `(d.body.c ?? 0)::Float?`, not `(d.body.c ?? 0)::Float`.
- A `let` with a type annotation can no longer hold a JSON leaf, a value
  computed from one, or a `??` over one: `let v: Int = d.body.c ?? 0` is now
  an error. Convert the leaf and leave out the annotation:
  `let v = d.body.c::Int? ?? 0`.
- A unit whose conversion does not depend on its value, such as `= 5` or
  `= x * 0`, is now an error.
- The status `DS_ERR_FS_UNKNOWN_INJECT` is gone from `libds.h` and from every
  binding, and `pyds.atoms` no longer has `band`, `Band`, `disposition` or
  `Disposition`. Host code that names any of them must drop it.

### Added

- Integrators can ask the engine when its next deadline falls, in both
  runtimes and every binding. `ds test` and `ds -b` now move the clock to each
  deadline in turn.
- A host can convert a number between a slot's unit and the number the slot
  stores, with `ds_schema_slot_to_stored` and `ds_schema_slot_from_stored` or
  each binding's equivalent. A conversion with no result returns the new
  `DS_ERR_NOT_REPRESENTABLE`.
- A JSON leaf converts as the value it holds: `d.body.c::Float?` takes a JSON
  `31` or `31.5`, and parses a JSON string as a `String` does.
- Two values of one dimension can be divided: `/` gives a `Float` and `//` a
  whole number. A `Duration` can be multiplied or divided by a `Float`.
- Series aggregations take a `Duration` slot. `mean`, `median`, `stdev`,
  `pstdev` and percentiles over one are `Duration`s.

### Changed

- `<number>::<unit>` now takes the number as being in that unit:
  `35.0::celsius` is 35 °C, where it was 35 K. A program that asserted a unit
  other than the base unit on a number already in base units now gets a
  different value, with no diagnostic.
- `round`, `math.floor`, `math.ceil`, `math.trunc` and `math.sign` now work in
  a value's own unit: `round` of 21.5 °C is 22 °C.
- `onset_rate` counts a rising edge only when a `true` arrives while the
  signal holds `false`. A first `true` is no longer an edge, so
  `true, true, false, true` now has one edge, where it had two.
- `Duration + Duration`, `Duration * Int` and a `sum` over a `Duration` slot
  now raise `NOT_REPRESENTABLE` past about 292 years, where 1.0.0 wrapped.
- `Time` arithmetic that goes past the range a `Time` can hold now raises
  `NOT_REPRESENTABLE` and never wraps around.
- The mock clock now ends at about 292 years: setting or advancing it past
  that returns `DS_ERR_TIME_RANGE`. An `after` or `timeout` whose deadline
  would pass it raises `NOT_REPRESENTABLE`, where it wrapped and fired at once.
- An atom a runtime does not know is refused as malformed wherever it stands:
  a replay fails with `DS_ERR_PARSE`, and a load with `DS_ERR_DSC_BAD_MAGIC` or
  `DS_ERR_DSC_DECODE`. Artefacts and recordings of one release series never
  carry one.

### Fixed

- libds no longer stops the whole process when an internal check fails. It
  returns an error, or halts that engine with a new `ENGINE_FAULT_INTERNAL`
  fault. The shipped libraries no longer contain asserts.
- A series that goes quiet for a full window now keeps its signal state and
  its `nulls: hold` value instead of losing them.
- A path read on a `Json?` slot holding `null` now gives `null`, and raises
  nothing.
- A `??` over a JSON leaf no longer hides where the value came from: an
  operation the leaf's type does not fit abandons that rule's activation, where
  it halted the engine.
- Several smaller fixes: units stored as whole numbers, such as data sizes,
  convert exactly; a library's constants and unit conversions resolve in the
  library itself; and the C and Mercury runtimes agree in edge cases, mostly in
  series and replay.
