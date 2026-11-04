<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Pump

## `ds_engine_pump`

**`ds_result_t ds_engine_pump(ds_engine_t *engine);`**

Takes one clock sample, sweeps what has expired, and runs the agenda to exhaustion.

Rules fire only in a pump: until one runs, asserted facts wait in working memory and matched activations on the agenda. No argument bounds one pump's work, and nothing outside the call can stop it part-way. The sample, its [`DS_EV_TICK`](../callbacks/stream.md#tick) and [`DS_EV_PUMP`](../callbacks/stream.md#ds_ev_pump) come first, then the fact sweep and the [cache sweep](../callbacks/cache.md#expiry). Calls are [serialised](../conventions/handles.md#calls-on-one-engine) by the integrator. The consumption loop is in [Runtime architecture](inv:internals:std:doc#overview/runtime-architecture).

A firing's failure does not stop the pump: the agenda still runs to exhaustion, and the first non-OK result is the pump's status. The pump's own failure takes precedence, and an `EngineError`'s [halt](lifecycle.md#halt-latch) over everything. Errors:

| Code | Condition |
|---|---|
| `DS_ERR_INVAL` | `engine` is NULL |
| `DS_ERR_STATE` | called from inside a callback on this engine ([Re-entry](../conventions/handles.md#re-entry)) |
| `DS_ERR_ENGINE_HALTED` | a firing raised an `EngineError` during this pump, or the engine had halted before it |
| `DS_ERR_TIME_RANGE` | this is the engine's first sample, and it would put a [seeded](../callbacks/cache.md#ds_engine_cache_seed) entry's deadline outside the `Time` range; nothing is sampled or recorded |
| `DS_ERR_CONTRACT_BREACH` | a cache write in a firing would exceed a [cache bound](../callbacks/cache.md#ds_engine_set_cache_cap); or, on the engine's first step, the program's `initial` cache items would, and the pump is refused before firing anything |
| `DS_ERR_STORAGE_UNAVAILABLE` | a firing's `call` met [no call callback](../callbacks/call.md#no-callback) |
| `DS_ERR_NAN_REJECTED` | a firing's `call` had a NaN `Float` [argument](../callbacks/call.md#refused-arguments) |
| `DS_ERR_SERIES_NO_BACKING` | a series read no declared backing could answer |
| a callback's status | the call callback's, or a cache persistence callback's, with the meaning its verb gives it; or the first the [stream callback](../callbacks/contract.md#stream-callback-status) returned |
| `DS_ERR_OOM` | an allocation failed |

An error leaves working memory as the partial pump left it, with no rollback. A later pump continues from there, unless the engine has halted.

*(libds.h: ds_engine_pump, Spec: [NLFC.2.1], [NLFC.2.2], [NLFC.2.4], [NERR.15.1], [NERR.15.2], [NTST.3.4])*
