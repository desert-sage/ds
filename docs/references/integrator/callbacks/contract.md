<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Callback contract

## Arguments

A registered callback takes the engine handle first and its `void *user` last, and returns [`ds_result_t`](../conventions/results.md#ds_result_t).

Between them it takes its payload as one `const` pointer: a callback reads a payload and does not change it. `user` is the pointer given at registration, and libds does not read it.

*(libds.h: ds_stream_cb_t, ds_metric_cb_t, ds_log_cb_t, ds_call_cb_t, ds_cache_set_cb_t, ds_cache_delete_cb_t, Spec: [NCBK.1.1], [NCBK.1.2], [NCBK.1.3], [NCBK.1.4])*

## Execution

A callback runs synchronously, on the caller's thread and on the stack of the `ds_engine_*` call that caused it.

Do not block in a callback: a blocking callback blocks that call. Threads are the integrator's ([Integrator drives](../conventions/handles.md#integrator-drives)).

*(Spec: [NCBK.1.7], [NLFC.3.3], [NMET.6.2], [IARC.1.14])*

## Calls from a callback

A `ds_engine_*` call from a callback follows [Re-entry](../conventions/handles.md#re-entry).

A callback reads the fact and schema handles in its payload with [`ds_fact_get_*`](../facts/reading.md#fact-accessor-results) and [`ds_schema_get_*`](../facts/schemas.md#schema-accessors).

*(Spec: [NCBK.1.6], [NCBK.2.9], Source: runtime/src/libds/wm.c, runtime/src/libds/schema.c)*

## Payload pointers

Every pointer reachable from a payload, strings included, follows [Callback pointers](../conventions/handles.md#callback-pointers). Copy what is needed past the callback.

*(Spec: [NCBK.1.6])*

## Return value

A status other than `DS_OK` from a stream, call or cache callback is returned by the public call that fired the callback. libds drops the status of a metric or log callback.

Inside work an outer public call started, such as a pump's firings, the outer call reports the status.

*(libds.h: Telemetry callbacks, Spec: [NCBK.1.5], [NERR.14.1], [NMET.6.5])*

## Stream callback status

The engine does not act on the stream callback's status: the call that fired it runs to completion, delivers every remaining event, and retracts every expired fact.

The first status other than `DS_OK` in a public call is that call's return value, unless the call fails for its own reason, whose status takes precedence. A later one in that call is not reported, and none carries into the next call. The same holds for a fault event's delivery.

*(Spec: [NCBK.1.5])*

## Errors through a callback

A pump reports the first status other than `DS_OK` from the callbacks it fires. libds passes a callback's status and detail through unchanged.

A detail string a callback returns stays valid until the outermost public call reporting that status returns.

*(Spec: [NERR.14.1], [NERR.14.2], [NSTG.7.2], [NSTG.7.3])*

## Unregistered callbacks

An engine starts with no callback registered.

An event, metric or log line with no callback is dropped, and a cache write with no callback is not persisted. A `call` with no callback is an [error](call.md#no-callback).

*(Spec: [NCBK.1.8], [NLFC.1.4])*

## Replacement

A second setter call replaces the registration, and the previous `user` pointer returns to the integrator. A NULL callback unregisters.

Cache persistence registers both callbacks in one call, [`ds_engine_cache_callbacks`](cache.md#ds_engine_cache_callbacks). Every other area has one setter.

*(Spec: [NCBK.1.9], [NCBK.12.3])*

## Registration order

Register callbacks after [`ds_engine_new`](../engine/lifecycle.md#ds_engine_new) and before [`ds_engine_load_dsc`](../engine/loading.md#ds_engine_load_dsc). A callback registered after work starts misses the events before it.

*(Spec: [NCBK.12.1], [NCBK.12.2])*
