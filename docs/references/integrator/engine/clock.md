<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Clock

## Engine clocks

An engine holds two clocks: a monotonic clock, which never decreases and drives every relative-time mechanism, and a wall clock, in UTC nanoseconds since the Unix epoch, which drives `now()`.

The engine samples both together when it consumes an input ([`ds_engine_assert`](../facts/asserting.md#ds_engine_assert), [`ds_engine_retract`](../facts/asserting.md#ds_engine_retract)) and when a [pump](pump.md#ds_engine_pump) begins, and every read in between returns that sample. A sample that changes either clock is recorded as a [`DS_EV_TICK`](../callbacks/stream.md#tick). The clock source is in [Runtime architecture](inv:internals:std:doc#overview/runtime-architecture).

*(libds.h: Clock source, Spec: [NLFC.5.1], [NTST.3.3])*

## Mode

### `ds_clock_mode_t`

**`typedef enum { DS_CLOCK_LIVE = 0, DS_CLOCK_MOCK = 1 } ds_clock_mode_t;`**

The source of an engine's clocks.

| Member | Clocks |
|---|---|
| `DS_CLOCK_LIVE` | the host's monotonic and UTC clocks; an engine starts here |
| `DS_CLOCK_MOCK` | the values the integrator sets with the calls below |

*(libds.h: ds_clock_mode_t, Spec: [NLFC.1.4], [NLFC.5.4])*

### `ds_engine_clock_mode`

**`ds_result_t ds_engine_clock_mode(ds_engine_t *engine, ds_clock_mode_t *out_mode);`**

Reads the current clock mode.

Errors: `DS_ERR_INVAL`, `DS_ERR_STATE`, `DS_ERR_ENGINE_HALTED`.

*(libds.h: ds_engine_clock_mode, Source: runtime/src/libds/clock.c)*

### `ds_engine_clock_set_mode`

**`ds_result_t ds_engine_clock_set_mode(ds_engine_t *engine, ds_clock_mode_t mode);`**

Switches the clock mode.

A switch to the current mode does nothing. A switch to `DS_CLOCK_MOCK` starts the mock monotonic clock at `0` and leaves the mock wall clock unset, so neither depends on when the run started. A switch to `DS_CLOCK_LIVE` continues the monotonic clock from the current mock time, advancing with the host's from there, and returns the wall clock to the host's.

Errors: `DS_ERR_STATE` for a switch to `DS_CLOCK_MOCK` once the engine has sampled its clock, for an input or a pump, and under [Re-entry](../conventions/handles.md#re-entry); `DS_ERR_INVAL` for a NULL `engine` or an unknown `mode`; `DS_ERR_ENGINE_HALTED`.

*(libds.h: ds_engine_clock_set_mode, Clock source, Spec: [NLFC.5.2], [NLFC.5.4], Source: runtime/src/libds/clock.c)*

## Reading

### `ds_engine_clock_now`

**`ds_result_t ds_engine_clock_now(ds_engine_t *engine, uint64_t *out_ns);`**

Reads the monotonic clock's current value, in nanoseconds, in either mode.

It is not a sample: it records nothing, and does not change what the engine's next read returns. Errors: `DS_ERR_INVAL`, `DS_ERR_STATE`, `DS_ERR_ENGINE_HALTED`.

*(libds.h: ds_engine_clock_now, Source: runtime/src/libds/clock.c)*

### `ds_engine_next_deadline_ns`

**`ds_result_t ds_engine_next_deadline_ns(ds_engine_t *engine, uint64_t *out_ns, bool *out_has);`**

Reports the earliest deadline later than the monotonic clock's current value.

A deadline is the `fire_at` of a live timer fact, the expiry of a live fact with a TTL, or the expiry of a cache entry. `*out_has` is false when the engine holds none, and `*out_ns` is then `0`. An instant at which a time-dependent condition changes is not a deadline, and neither is the end of a cooldown.

It is a read, in either mode: it is not a sample, records nothing, and changes nothing a later call or pump does. The engine does nothing at a deadline until a [pump](pump.md#ds_engine_pump). Its cost is linear in the live facts and cache entries.

Errors: `DS_ERR_INVAL` for a NULL `engine`, `out_ns` or `out_has`; `DS_ERR_STATE` under [Re-entry](../conventions/handles.md#re-entry); `DS_ERR_ENGINE_HALTED`.

*(libds.h: ds_engine_next_deadline_ns, Spec: [NLFC.2.5], Source: runtime/src/libds/engine.c)*

## Mock clock

### Mock clock calls

`ds_engine_clock_set`, `ds_engine_clock_advance` and `ds_engine_wall_clock_set` move the mock clocks.

Each returns `DS_ERR_STATE` in `DS_CLOCK_LIVE`. Each also returns `DS_ERR_INVAL` for a NULL `engine`, `DS_ERR_ENGINE_HALTED`, and `DS_ERR_STATE` under [Re-entry](../conventions/handles.md#re-entry).

None is a sample: each emits no event and records nothing, and the next input or pump observes the value it left. Two calls between samples leave one record. A fact's TTL deadline is computed at assert: moving the clock later changes whether the next [pump](pump.md#ds_engine_pump) retracts the fact, and not the deadline.

*(libds.h: Clock source, Spec: [NLFC.5.3], [NTST.3.2], [NTST.3.3], [NTST.3.5], Source: runtime/src/libds/clock.c)*

### `ds_engine_clock_set`

**`ds_result_t ds_engine_clock_set(ds_engine_t *engine, uint64_t now_ns);`**

Sets the mock monotonic clock to an absolute value.

Before the engine's first sample it takes any value up to 2^63 - 1. After it, a value below the current one returns `DS_ERR_STATE` and leaves both clocks as they were. A value above 2^63 - 1, the top of the monotonic clock's range, returns `DS_ERR_TIME_RANGE` and leaves both clocks as they were, before the first sample and after it. A value equal to the top is taken.

*(libds.h: ds_engine_clock_set, Spec: [NTST.3.1], [LTIM.2.8.2], Source: runtime/src/libds/clock.c)*

### `ds_engine_clock_advance`

**`ds_result_t ds_engine_clock_advance(ds_engine_t *engine, uint64_t delta_ns);`**

Advances the mock monotonic clock by `delta_ns`, and the mock wall clock by the same amount when it is set.

An unset wall clock stays unset, and limits nothing.

It returns `DS_ERR_TIME_RANGE`, and leaves both clocks as they were, for a monotonic clock or a set wall clock that would pass 2^63 - 1. An advance that lands on the top of a range is taken.

*(libds.h: ds_engine_clock_advance, Spec: [NTST.3.1], [LTIM.2.8.2], Source: runtime/src/libds/clock.c)*

### `ds_engine_wall_clock_set`

**`ds_result_t ds_engine_wall_clock_set(ds_engine_t *engine, int64_t utc_ns);`**

Sets the mock wall clock alone to `utc_ns`, nanoseconds since the Unix epoch.

It takes any instant, earlier or later.

*(libds.h: ds_engine_wall_clock_set, Spec: [NLFC.5.3], [NTST.3.1])*
