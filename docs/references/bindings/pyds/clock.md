<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Clock

## `Clock`

**`class Clock`**

An engine's [two clocks](inv:integrator:std:doc#engine/clock). `Engine.clock` returns one.

```python statement
engine.clock.mode = pyds.ClockMode.MOCK
engine.clock.set(1_000)
engine.clock.advance(500)
```

*(Source: bindings/python/src/pyds/engine.py)*

### `mode`

**`mode: ClockMode`**

The clock mode, read by [`ds_engine_clock_mode`](inv:integrator:std:doc#engine/clock) and assigned through [`ds_engine_clock_set_mode`](inv:integrator:std:doc#engine/clock).

An assignment takes a `ClockMode`, or a `str` naming a member. A `str` that names none raises `ValueError`, and another type raises `TypeError`.

*(Source: bindings/python/src/pyds/engine.py)*

### `now_ns`

**`now_ns: int`**

The monotonic clock's value, read by [`ds_engine_clock_now`](inv:integrator:std:doc#engine/clock).

*(Source: bindings/python/src/pyds/engine.py)*

### `next_deadline_ns`

**`next_deadline_ns: int | None`**

The earliest deadline later than the monotonic clock's value, read by [`ds_engine_next_deadline_ns`](inv:integrator:std:doc#engine/clock).

It is `None` when the engine holds no deadline.

*(Source: bindings/python/src/pyds/engine.py)*

### `set`

**`def set(self, now_ns: int, /) -> None`**

Sets the mock monotonic clock through [`ds_engine_clock_set`](inv:integrator:std:doc#engine/clock).

`now_ns` is an `int`, or an object with `__index__`. A value that is negative or outside `uint64` raises `OverflowError`, and another type raises `TypeError`.

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/_pyds/engine.c)*

### `advance`

**`def advance(self, delta_ns: int, /) -> None`**

Advances the mock clocks through [`ds_engine_clock_advance`](inv:integrator:std:doc#engine/clock).

`delta_ns` is an `int`, or an object with `__index__`. A value that is negative or outside `uint64` raises `OverflowError`, and another type raises `TypeError`.

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/_pyds/engine.c)*

### `set_wall`

**`def set_wall(self, utc_ns: int, /) -> None`**

Sets the mock wall clock through [`ds_engine_wall_clock_set`](inv:integrator:std:doc#engine/clock).

`utc_ns` is an `int`, or an object with `__index__`. A value outside `int64` raises `OverflowError`, and another type raises `TypeError`.

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/_pyds/engine.c)*

## `ClockMode`

**`class ClockMode(StrEnum)`**

Where an engine's clocks read their time: [`ds_clock_mode_t`](inv:integrator:std:doc#engine/clock).

Its members and their values are `LIVE` `"live"` and `MOCK` `"mock"`.

*(Source: bindings/python/src/pyds/enums.py)*
