<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Engine lifecycle

## Creation

### `ds_engine_config_t`

**`typedef struct ds_engine_config { const char *run_id; const char *tier_id; } ds_engine_config_t;`**

The configuration `ds_engine_new` takes.

Initialise it to zero, as `{0}` or with `memset`, and set the fields needed. A zeroed configuration, or NULL, is the default engine.

`run_id` and `tier_id` are the integrator's. Either may be NULL, and an empty string is the same as NULL. Each given must be well-formed UTF-8. `ds_engine_new` copies them. The engine derives every fact's `event_id` from them and `seq`, and with neither given `seq` alone distinguishes facts. The fact-stream [session header](../determinism/provenance.md#ds_session_header_t) records them as `session_id` and `tier_id`.

*(libds.h: ds_engine_config_t, Spec: [NLFC.1.2])*

### `ds_engine_new`

**`ds_result_t ds_engine_new(const ds_engine_config_t *config, ds_engine_t **out);`**

Creates an engine and stores its handle in `*out`.

A NULL `config` takes the defaults. The new engine is on the live [clock](clock.md#ds_clock_mode_t), and holds no schemas, no rules and no callbacks. The caller owns it until `ds_engine_free`. Each engine is [independent](../conventions/handles.md#several-engines).

Errors: `DS_ERR_INVAL` for a NULL `out`; `DS_ERR_ENCODING` for a `run_id` or `tier_id` that is not well-formed UTF-8, which creates no engine; `DS_ERR_OOM`. On failure `*out` is NULL.

*(libds.h: ds_engine_new, Spec: [NLFC.1.1], [NLFC.1.2], [NLFC.1.4])*

### `ds_engine_get_run_id`

**`ds_result_t ds_engine_get_run_id(const ds_engine_t *engine, const char **out);`**

Reads the run id given at `ds_engine_new`.

`*out` is NULL when it was absent or `""`. The pointer is the engine's, and valid for the engine's lifetime. Errors: `DS_ERR_INVAL`, `DS_ERR_STATE`, `DS_ERR_ENGINE_HALTED`.

*(libds.h: ds_engine_get_run_id, Spec: [NLFC.1.2], Source: runtime/src/libds/engine.c)*

### `ds_engine_get_tier_id`

**`ds_result_t ds_engine_get_tier_id(const ds_engine_t *engine, const char **out);`**

Reads the tier id given at `ds_engine_new`.

`*out` is NULL when it was absent or `""`. The pointer is the engine's, and valid for the engine's lifetime. Errors: `DS_ERR_INVAL`, `DS_ERR_STATE`, `DS_ERR_ENGINE_HALTED`.

*(libds.h: ds_engine_get_tier_id, Spec: [NLFC.1.2], Source: runtime/src/libds/engine.c)*

## Clone

### `ds_engine_clone`

**`ds_result_t ds_engine_clone(const ds_engine_t *src, ds_engine_t **out_dst);`**

Produces an independent engine identical to `src` at call time.

The two share no mutable state, and either may be freed first. `*out_dst` is caller-owned. Equivalence is over working memory, the agenda, the clocks, series and the cache. Every monotonic counter (`fact_id`, `seq`, activation timetags) continues from the source's value, and each engine then continues its own copy. Under identical input the two produce byte-identical observable output, once the clone's callbacks behave as the source's do. A discarded clone's events never enter the source's stream. How the copy is made is in [libds modules](inv:internals:std:doc#overview/libds-modules).

The clone starts with no callback and no `user` pointer of the source's. It reports a `call` with no callback as a new engine [does](../callbacks/call.md#no-callback).

Errors: `DS_ERR_INVAL` for a NULL `src` or `out_dst`; `DS_ERR_STATE` under [Re-entry](../conventions/handles.md#re-entry) or mid-pump; `DS_ERR_ENGINE_HALTED`; `DS_ERR_OOM`, which leaves the source unchanged. On failure `*out_dst` is NULL.

*(libds.h: ds_engine_clone, Spec: [NLFC.8.1], [NLFC.8.2], [NLFC.8.3], [IARC.11.2], [IARC.11.3], [NCBK.2.9], Source: runtime/src/libds/engine_clone.c)*

## Teardown

### `ds_engine_free`

**`ds_result_t ds_engine_free(ds_engine_t *engine);`**

Destroys an engine and releases everything it holds, whatever state a [halt](#halt-latch) left it in.

After it returns, the engine pointer and every fact and schema handle from that engine are invalid. It fires no callback: no stream event, metric or log, and nothing to the cache persistence callbacks. Free what a callback's `user` owns after it returns. Teardown is in [libds modules](inv:internals:std:doc#overview/libds-modules).

Errors: `DS_ERR_INVAL` for a NULL `engine`; `DS_ERR_STATE` under [Re-entry](../conventions/handles.md#re-entry).

```{warning}
Calling `ds_engine_free` twice on one engine is undefined behaviour.
```

*(libds.h: ds_engine_free, Spec: [NLFC.6.2], [NLFC.6.3], [NLFC.6.4], [NCBK.2.9], Source: runtime/src/libds/engine.c)*

## Halt

### Halt latch

The engine state that refuses further service: set when the engine raises an `EngineError`, or when a load fails, and never cleared.

The engine sets it on the [`engine_error`](../callbacks/stream.md#engine_error) event, or on a [failed load](loading.md#failed-load). The engine's state is then undefined.

Every `ds_engine_*` call but four then returns `DS_ERR_ENGINE_HALTED` and does nothing: a pump, an [assert](../facts/asserting.md#ds_engine_assert) or [retract](../facts/asserting.md#ds_engine_retract), a load, a setter, `ds_engine_clone`, and every read of [working memory](../facts/reading.md), a [schema](../facts/schemas.md#schema-accessors) or the introspection surface ([metadata](../introspection/metadata.md#metadata-views), [network](../introspection/network.md#pause-contract)). These four remain valid:

- [`ds_engine_halted`](#ds_engine_halted)
- [`ds_engine_get_platform_signature`](../determinism/provenance.md#ds_engine_get_platform_signature)
- [`ds_engine_get_session_header`](../determinism/provenance.md#ds_engine_get_session_header)
- [`ds_engine_free`](#ds_engine_free), which remains the integrator's to call

The call during which the engine raises an `EngineError` returns `DS_ERR_ENGINE_HALTED` ahead of any other status. It fires, propagates and records nothing after the `EngineError`, which is the last stream event from that engine.

A callback may finish its own work and return. Inside it, every call on that engine is [refused](../conventions/handles.md#re-entry), the four included, and they are valid once the callback has returned.

*(libds.h: DS_ERR_ENGINE_HALTED, ds_stream_ev_kind_t, ds_engine_load_dsc, Spec: [NCBK.2.9], [RDSC.9.8])*

### `ds_engine_halted`

**`ds_result_t ds_engine_halted(const ds_engine_t *engine, bool *out_halted, ds_engine_fault_t *out_fault);`**

Reads the [halt latch](#halt-latch) and its cause.

| Engine | `*out_halted` | `*out_fault` |
|---|---|---|
| not halted | false | `DS_ENGINE_FAULT_UNSPECIFIED` |
| halted by an `EngineError` | true | the [`ds_engine_fault_t`](../callbacks/stream.md#ds_engine_fault_t) its `DS_EV_ENGINE_ERROR` carried |
| spent by a failed load | true | `DS_ENGINE_FAULT_UNSPECIFIED` |

Either out-pointer may be NULL. Errors: `DS_ERR_INVAL` for a NULL `engine`; `DS_ERR_STATE` under [Re-entry](../conventions/handles.md#re-entry).

*(libds.h: ds_engine_halted, Spec: [NCBK.2.11], Source: runtime/src/libds/engine.c)*

## Failed calls

### A call that fails

A failed call leaves the engine usable, unless its entry states otherwise. The result is [`ds_result_t`](../conventions/results.md#ds_result_t), and a code's meaning is in the [catalogue](../conventions/errors.md).

*(Spec: [NLFC.7.3])*

## Replay

### Replay settings

Give a replaying engine the recording engine's `run_id` and `tier_id`, which the stream [header](../determinism/provenance.md#ds_session_header_t) records, and its [cache bounds](../callbacks/cache.md#ds_engine_set_cache_cap).

The admission policy, the clocks and the reporting callbacks change no observable. The replayer drives both clocks from the trace. The integrator does not seed an engine it replays into: the recording carries each seed.

A replay invokes no effect callback. It hands no call to the call callback and no write, delete or expiry to the cache persistence callbacks. The engine still applies each cache write to its own cache.

An integrator driving an engine from its own record of inputs, not replaying a recording, drives the clocks itself: the [mock clock](clock.md#ds_clock_mode_t) before the first sample.

*(Spec: [NDET.4.1], [NDET.8.1], [NDET.8.2])*
