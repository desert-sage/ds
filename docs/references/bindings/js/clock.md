<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Clock

## `Clock`

**`export class Clock`**

An engine's [two clocks](inv:integrator:std:doc#engine/clock). `Engine.clock` returns one, the same at every read.

It is never made directly. Each read gives the clock as it is at the read.

```javascript statement
engine.clock.mode = "mock";
engine.clock.set(1_000n);
engine.clock.advance(500);
```

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js)*

### `mode`

**`get mode(): ClockMode;`**

The clock mode, read by [`ds_engine_clock_mode`](inv:integrator:std:doc#engine/clock) and assigned through [`ds_engine_clock_set_mode`](inv:integrator:std:doc#engine/clock).

Assigning a value other than a [`ClockMode`](#clockmode), a string holding U+0000 included, throws `TypeError`.

*(Source: bindings/js/types/bind.d.ts, bindings/js/src/ds.c)*

### `now`

**`get now(): bigint;`**

The monotonic clock's value, read by [`ds_engine_clock_now`](inv:integrator:std:doc#engine/clock).

*(Source: bindings/js/types/bind.d.ts, bindings/js/src/ds.c)*

### `nextDeadline`

**`get nextDeadline(): bigint | null;`**

The earliest deadline later than the monotonic clock's value, read by [`ds_engine_next_deadline_ns`](inv:integrator:std:doc#engine/clock).

It is `null` when the engine holds no deadline.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js)*

### `set`

**`set(ns: Int64): void;`**

Sets the mock monotonic clock through [`ds_engine_clock_set`](inv:integrator:std:doc#engine/clock).

An `ns` that is negative, above 64 bits, or not an [`Int64`](facts.md#int64) throws `TypeError`.

*(Source: bindings/js/types/bind.d.ts, bindings/js/src/ds.c)*

### `advance`

**`advance(ns: Int64): void;`**

Advances the mock clocks through [`ds_engine_clock_advance`](inv:integrator:std:doc#engine/clock).

An `ns` that is negative, above 64 bits, or not an [`Int64`](facts.md#int64) throws `TypeError`.

*(Source: bindings/js/types/bind.d.ts, bindings/js/src/ds.c)*

### `setWall`

**`setWall(utcNs: Int64): void;`**

Sets the mock wall clock through [`ds_engine_wall_clock_set`](inv:integrator:std:doc#engine/clock).

A `utcNs` outside `int64`, or not an [`Int64`](facts.md#int64), throws `TypeError`.

*(Source: bindings/js/types/bind.d.ts, bindings/js/src/ds.c)*

## `ClockMode`

**`export type ClockMode = "live" | "mock";`**

Where an engine's clocks read their time: [`ds_clock_mode_t`](inv:integrator:std:doc#engine/clock).

*(Source: bindings/js/types/types.d.ts)*
