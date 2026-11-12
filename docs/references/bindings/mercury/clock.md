<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Clock

## Mode

### `clock_choice`

**`:- type clock_choice ---> mock_clock ; live_clock.`**

Where a session's [two clocks](inv:integrator:std:doc#engine/clock) read their time: the capability of [`ds_clock_mode_t`](inv:integrator:std:doc#engine/clock).

| Member | Clocks |
|---|---|
| `mock_clock` | moved only by [`advance`](#advance), [`set_clock`](#set_clock) and [`set_wall_clock`](#set_wall_clock) |
| `live_clock` | moved only by [`read_clock`](#read_clock) |

Under either, the monotonic clock starts at 0 and the wall clock with no value. A session keeps its choice until a replay changes it, as [`clock_mode`](#clock_mode) states.

*(Source: bindings/mercury/src/mercury_ds.session.m, runtime/mercury/src/ds.chrono.m)*

### `clock_mode`

**`:- func clock_mode(session) = read(clock_choice).`**

The session's clock choice: the capability of [`ds_engine_clock_mode`](inv:integrator:std:doc#engine/clock).

A [`replay`](recording.md#replay) that delivers a recorded clock sample puts the session on `mock_clock`, whatever it was loaded with.

*(Source: bindings/mercury/src/mercury_ds.session.m, runtime/mercury/src/ds.replay.m, Spec: [RFCS.10.5])*

## Reading

### `read_clock`

**`:- pred read_clock(session::in, session::out, io::di, io::uo) is det.`**

Under `live_clock`, reads the host's monotonic and wall clocks together into the session.

Each reading sets the wall clock to the host's value, earlier or later. The first leaves the monotonic clock where it is, and each later one moves it forward by the time elapsed, never back.

Under `mock_clock`, and on a halted session, it changes nothing.

```{note}
A `live_clock` does not move between readings. Every input and pump samples the last reading.
```

*(Source: bindings/mercury/src/mercury_ds.session.m, runtime/mercury/src/ds.chrono.m, runtime/mercury/src/ds.engine.m, Spec: [LTIM.2.8.3])*

### `now`

**`:- func now(session) = read(instant).`**

The monotonic clock's current value, as a host reads it between calls: the capability of [`ds_engine_clock_now`](inv:integrator:std:doc#engine/clock).

*(Source: bindings/mercury/src/mercury_ds.session.m, runtime/mercury/src/ds.engine.m)*

### `next_deadline`

**`:- func next_deadline(session) = read(maybe(instant)).`**

The earliest deadline later than the monotonic clock's current value, `yes(At)`, or `no` when the engine holds none: the capability of [`ds_engine_next_deadline_ns`](inv:integrator:std:doc#engine/clock).

It is a read, as [`now`](#now) is: it takes no sample, and changes nothing a later call does.

*(Source: bindings/mercury/src/mercury_ds.session.m, Spec: [NLFC.2.5])*

## Moving a mock clock

### `advance`

**`:- pred advance(duration::in, step::out, session::in, session::out) is det.`**

Moves the mock clocks forward: the capability of [`ds_engine_clock_advance`](inv:integrator:std:doc#engine/clock).

| `step_outcome` | Condition |
|---|---|
| [`error`](errors.md#outcome), [`engine_halted`](errors.md#status) | the session has halted |
| `error`, `state` | [`clock_mode`](#clock_mode) answers `live_clock` |
| `error`, `time_range` | the advance passes a clock's range, as [`ds_engine_clock_advance`](inv:integrator:std:doc#engine/clock) states; both clocks stay as they were |

On success, `step_reports` holds one `ds.clock.advance_total` [`metric`](reports.md#metric) and `step_duties` is empty.

*(Source: bindings/mercury/src/mercury_ds.session.m, runtime/mercury/src/ds.engine.m, runtime/mercury/src/ds.chrono.m, Spec: [NMET.4.1], [NTST.3.1])*

### `set_clock`

**`:- pred set_clock(instant::in, step::out, session::in, session::out) is det.`**

Sets the mock monotonic clock: the capability of [`ds_engine_clock_set`](inv:integrator:std:doc#engine/clock).

| `step_outcome` | Condition |
|---|---|
| `error`, `engine_halted` | the session has halted |
| `error`, `state` | [`clock_mode`](#clock_mode) answers `live_clock` |
| `error`, `time_range` | the instant is above 2^63 - 1, the top of the monotonic clock's range, before the engine's first sample or after it; both clocks stay as they were |
| `error`, `state` | after the engine's first sample, the instant is below the current value; both clocks stay as they were |

The first row that applies is the refusal. `step_reports` and `step_duties` are empty.

*(Source: bindings/mercury/src/mercury_ds.session.m, runtime/mercury/src/ds.engine.m, runtime/mercury/src/ds.chrono.m, Spec: [NTST.3.1])*

### `set_wall_clock`

**`:- pred set_wall_clock(int64::in, outcome::out, session::in, session::out) is det.`**

Sets the mock wall clock, in UTC nanoseconds since the Unix epoch, to any instant: the capability of [`ds_engine_wall_clock_set`](inv:integrator:std:doc#engine/clock).

`now()` faults while the wall clock has no value. The first row that applies is the refusal, and the wall clock stays as it was.

| [`outcome`](errors.md#outcome) | Condition |
|---|---|
| `error`, `engine_halted` | the session has halted |
| `error`, `state` | [`clock_mode`](#clock_mode) answers `live_clock` |

```mercury declaration
:- pred at_epoch(outcome::out, session::in, session::out) is det.
at_epoch(Outcome, !S) :-
    set_wall_clock(0i64, Outcome, !S).
```

*(Source: bindings/mercury/src/mercury_ds.session.m, runtime/mercury/src/ds.engine.m, Spec: [NTST.3.1], [LTIM.2.8.3], [NCBK.2.9])*
