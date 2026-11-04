<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Callbacks and events

## Events

### `addEventListener`

**`addEventListener<K extends keyof EngineEventMap>(type: K, listener: ((event: EngineEventMap[K]) => void) | null, options?: boolean | AddEventListenerOptions | undefined): void;`**

Adds a listener, as `EventTarget` does, for a stream event kind, `"log"` or `"metric"`.

A second overload takes `type: string` and `EventListenerOrEventListenerObject | null`.

For a stream kind, `"log"` or `"metric"` with a non-null listener:

- the first listener for a stream kind has the [`ds_engine_set_stream_callback`](inv:integrator:std:doc#callbacks/stream) callback deliver the whole stream, and the first for `"log"` or `"metric"` registers [`ds_engine_set_log_callback` or `ds_engine_set_metric_callback`](inv:integrator:std:doc#callbacks/telemetry), each until the engine closes;
- on a closed engine it throws a `DsError` with `DS_ERR_STATE`, and adds nothing.

Any other `type` adds the listener as `EventTarget` does, and registers nothing.

```javascript statement
for (const kind of ds.STREAM_EVENT_KINDS) {
  engine.addEventListener(kind, (event) => console.log(event.type, event.seq));
}
```

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js)*

### `removeEventListener`

**`removeEventListener<K extends keyof EngineEventMap>(type: K, listener: ((event: EngineEventMap[K]) => void) | null, options?: boolean | EventListenerOptions | undefined): void;`**

Removes a listener, as `EventTarget` does. A second overload takes `type: string` and `EventListenerOrEventListenerObject | null`.

It leaves the libds registration in place.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js)*

### `EngineEvent`

**`constructor(type: string, fields?: object);`**

An event an [`Engine`](engine.md#engine-1) dispatches, and `class EngineEvent extends Event`.

Each entry of `fields` is set on the event as its own property.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js)*

### `STREAM_EVENT_KINDS`

**`export const STREAM_EVENT_KINDS: readonly StreamEventKind[];`**

A frozen array of every stream event kind: the `type` of each event an [`Engine`](engine.md#engine-1) dispatches for its stream.

A listener for the whole stream is added once per kind.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js)*

### `StreamEvent`

**`export type StreamEvent = StreamEventOf<Fact>;`**

One [stream event](inv:integrator:std:doc#callbacks/stream), with each fact as a [`Fact`](facts.md#fact).

*(Source: bindings/js/types/types.d.ts)*

### `StreamEventOf`

**`export type StreamEventOf<F> = { seq: bigint; clockNs: bigint; } & ({ kind: "fact_assert" | "fact_retract" | "fact_modify" | "action_emit"; fact: F; } | { kind: "action_publish"; schema: string; slots: Record<string, SlotValueOf<F>>; external: Uint8Array; } | { kind: "rule_fire_begin" | "rule_fire_end"; ruleName: string; timetag: bigint; } | { kind: "rule_lhs_facts"; ruleName: string; lhsFacts: F[]; timetag: bigint; } | ({ kind: "action_log"; } & LogRecord) | { kind: "action_cache_set"; key: string; valueJson: string | null; ttlNs: bigint; } | { kind: "action_cache_get"; key: string; valueJson: string | null; } | { kind: "action_cache_delete"; key: string; } | ({ kind: "action_call"; } & CallRequest) | { kind: "timer_armed"; ruleName: string; timerKind: string; windowNs: bigint; fireAtNs: bigint; timetag: bigint; } | { kind: "timer_fired"; ruleName: string; timerKind: string; } | { kind: "type_error"; nodeId: number; schemaName: string | null; slotName: string | null; actual: string | null; ruleName: string; } | { kind: "bounds_error"; cap: number; limit: bigint; observed: bigint; ruleName: string | null; timetag: bigint; } | { kind: "engine_error"; engineFault: number; nodeId: number; ruleName: string; } | { kind: "computation_error"; trapKind: number; ruleName: string; timetag: bigint; schemaName: string | null; slotName: string | null; factId: bigint; nodeId: number; } | { kind: "tick"; wallNs: bigint | null; } | { kind: "pump" | "unknown"; });`**

A stream event with facts as `F`. Each kind means what [Stream events](inv:integrator:std:doc#callbacks/stream) states.

| Field | Holds |
|---|---|
| `kind` | the kind's name; `"unknown"` for a kind that has none |
| `valueJson` | canonical JSON text, or `null` where there is no value |
| `schema`, `slots` | on an `action_publish`, the published fact's schema and its slot values by name, each a [`SlotValueOf`](facts.md#slotvalueof). The fact is in no working memory, so the event carries no `F` |
| `external` | a copy of the `FactExternal` bytes |
| `cap` | the number of its [`ds_cap_name_t`](inv:integrator:std:doc#callbacks/stream) |
| `engineFault` | the number of its [`ds_engine_fault_t`](inv:integrator:std:doc#callbacks/stream) |
| `trapKind` | the number of its [`ds_trap_kind_t`](inv:integrator:std:doc#callbacks/stream) |
| `wallNs` | `null` while the wall clock has no value |
| `ruleName` | on a `bounds_error`, `null` with no activation |

A `fact_retract` event's fact is dead as [`Fact`](facts.md#fact) states.

*(Source: bindings/js/types/types.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c, Spec: [LERR.9.11])*

### `StreamEventKind`

**`export type StreamEventKind = StreamEvent["kind"];`**

The name of a stream event's kind.

*(Source: bindings/js/types/types.d.ts)*

### `StreamEngineEvent`

**`export type StreamEngineEvent = AsEngineEvent<StreamEvent>;`**

The event an [`Engine`](engine.md#engine-1) dispatches for one stream event, of any kind.

*(Source: bindings/js/types/types.d.ts)*

### `AsEngineEvent`

**`export type AsEngineEvent<R> = R extends { kind: infer K; } ? EngineEvent & Omit<R, "kind"> & { readonly type: K; } : never;`**

A stream record as the event dispatched for it: its `kind` is the event's `type`, and its other fields are the event's own.

*(Source: bindings/js/types/types.d.ts, bindings/js/lib/bind.js)*

### `EngineEventMap`

**`export type EngineEventMap = { [K in StreamEventKind]: StreamEngineEvent & { readonly type: K; }; } & { log: LogEngineEvent; metric: MetricEngineEvent; };`**

The events an [`Engine`](engine.md#engine-1) dispatches, by `type`.

*(Source: bindings/js/types/types.d.ts)*

## Telemetry

### `onlog`

**`get onlog(): ((event: LogEngineEvent) => void) | null;`**

The `"log"` events' handler property, or `null`.

Assigning a function replaces the listener it added. Assigning any other value clears it. The function is called with the engine as `this`.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js)*

### `onmetric`

**`get onmetric(): ((event: MetricEngineEvent) => void) | null;`**

The `"metric"` events' handler property, or `null`.

It behaves as [`onlog`](#onlog) does.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js)*

### `LogEngineEvent`

**`export type LogEngineEvent = EngineEvent & LogRecord & { readonly type: "log"; };`**

The event dispatched for one log record.

*(Source: bindings/js/types/types.d.ts)*

### `MetricEngineEvent`

**`export type MetricEngineEvent = EngineEvent & Metric & { readonly type: "metric"; };`**

The event dispatched for one metric.

*(Source: bindings/js/types/types.d.ts)*

### `LogRecord`

**`export type LogRecord = { level: LogLevel; category: string; message: string; };`**

A plain object of [`ds_log_event_t`](inv:integrator:std:doc#callbacks/telemetry).

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c)*

### `LogLevel`

**`export type LogLevel = "DEBUG" | "INFO" | "WARNING" | "ERROR" | "CRITICAL" | "UNKNOWN";`**

A log line's severity: [`ds_log_level_t`](inv:integrator:std:doc#callbacks/telemetry), and `"UNKNOWN"` for a level with no name.

*(Source: bindings/js/types/types.d.ts, runtime/src/bindings/ds_names.h)*

### `Metric`

**`export type Metric = { name: string; kind: "counter" | "gauge" | "histogram" | "unknown"; value: number; labels: Record<string, string>; };`**

A plain object of [`ds_metric_t`](inv:integrator:std:doc#callbacks/telemetry), with its labels by key.

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c)*

## Calls

### `setCallCallback`

**`setCallCallback(fn: ((request: CallRequest) => void) | null): void;`**

Registers the call callback through [`ds_engine_set_call_callback`](inv:integrator:std:doc#callbacks/call).

`null` or `undefined` removes it, and any other value that is not a function throws `TypeError`. The return value of `fn` is ignored.

```javascript statement
engine.setCallCallback((request) => {
  console.log(request.service, request.correlation);
});
```

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c)*

### `CallRequest`

**`export type CallRequest = { service: string; correlation: string; args: Record<string, CallArgument>; timetag: bigint; ruleName: string; };`**

A plain object of [`ds_call_request_t`](inv:integrator:std:doc#callbacks/call), with its arguments by name.

*(libds.h: ds_call_request_t, Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c)*

### `CallArgument`

**`export type CallArgument = bigint | number | string | boolean | null | Uint8Array | JsonText | FactArgument;`**

One value of [`ds_arg_value_t`](inv:integrator:std:doc#facts/values).

| `ds_arg_kind_t` | Value |
|---|---|
| `DS_ARG_INT` | `bigint` |
| `DS_ARG_FLOAT` | `number` |
| `DS_ARG_STRING` | `string` |
| `DS_ARG_BOOL` | `boolean` |
| `DS_ARG_BYTES` | a plain `Uint8Array` copy |
| `DS_ARG_JSON` | [`JsonText`](facts.md#jsontext) |
| `DS_ARG_ENCODED_FACT` | [`FactArgument`](facts.md#factargument) |

*(Source: bindings/js/types/types.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c)*

## Cache access

### `Cache`

**`export class Cache`**

An engine's [cache](inv:integrator:std:doc#callbacks/cache), from the host's side. `Engine.cache` returns one, the same at every read.

It is never made directly, and the host does not read the cache through it.

```javascript statement
engine.cache.seed("k", "1");
engine.cache.setCap({ keys: 10 });
engine.cache.writeThrough = { set: (write) => console.log(write.key) };
```

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js)*

### `seed`

**`seed(key: string, json: string, { ttlNs }?: { ttlNs?: Int64; }): void;`**

Parses `json` through [`ds_json_parse`](inv:integrator:std:doc#facts/json), and stores it through [`ds_engine_cache_seed`](inv:integrator:std:doc#callbacks/cache).

`ttlNs` defaults to `0n`. A `key` or `json` that is not a string, a `key` holding U+0000, or a `ttlNs` that is negative, above 64 bits or not an [`Int64`](facts.md#int64), throws `TypeError`.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c)*

### `setCap`

**`setCap({ keys, bytes }?: { keys?: Int64; bytes?: Int64; }): void;`**

Sets the cache's bounds through [`ds_engine_set_cache_cap`](inv:integrator:std:doc#callbacks/cache).

`keys` is `cap_keys` and `bytes` is `cap_bytes`, and each defaults to `0n`. A value that is negative or not an [`Int64`](facts.md#int64) throws `TypeError`, and a `keys` above 2^32-1 throws `RangeError`.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c)*

### `writeThrough`

**`get writeThrough(): Readonly<WriteThrough> | null;`**

The persistence callbacks registered through [`ds_engine_cache_callbacks`](inv:integrator:std:doc#callbacks/cache), or `null`.

Assigning a [`WriteThrough`](#writethrough-1) registers its `set` and `delete` as one, each called with the object as `this`. Assigning `null` clears them. Another value, or a member that is neither a function nor `null`, throws `TypeError`. The value read back is a frozen copy of the handlers as they were assigned.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js)*

### `WriteThrough`

**`export type WriteThrough = { set?: ((write: CacheWrite) => void) | null | undefined; delete?: ((removal: CacheRemoval) => void) | null | undefined; };`**

The handlers of [`writeThrough`](#writethrough). A member left out, or `null`, is not called.

*(Source: bindings/js/types/types.d.ts, bindings/js/lib/bind.js)*

### `CacheWrite`

**`export type CacheWrite = { key: string; value: string | null; ttlNs: bigint; };`**

A plain object of [`ds_cache_write_t`](inv:integrator:std:doc#callbacks/cache), with `value` as canonical JSON text.

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c)*

### `CacheRemoval`

**`export type CacheRemoval = { key: string; reason: "delete" | "ttl"; };`**

A [`ds_cache_removal_t`](inv:integrator:std:doc#callbacks/cache), with `reason` as its name.

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c)*

## Failures

### `setUnraisableHook`

**`setUnraisableHook: (fn: UnraisableHook | null) => UnraisableHook;`**

Replaces where a throwing callback's exception is reported, and returns the previous hook.

A member of the [`Api`](targets.md#api). `null` restores the default, which prints to stderr. Any other value that is not a function throws `TypeError`.

*(Source: bindings/js/types/types.d.ts, bindings/js/lib/bind.js)*

### `UnraisableHook`

**`export type UnraisableHook = (error: unknown, where: string) => void;`**

Takes the exception and the callback's name: `"call"` for a call callback's exception, or `"stream"`, `"log"`, `"metric"`, `"cacheSet"` or `"cacheDelete"` for a callback whose argument could not be built.

An exception the hook throws is dropped.

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c)*

### Failure routes

Where a host function's exception goes.

| Function | Its exception | libds receives |
|---|---|---|
| a listener, `onlog`, `onmetric` | reported by the platform as any listener's; the listeners after it run | `DS_OK` |
| `writeThrough`'s `set` or `delete` | during `pump` or `loadDsc`, the first is the `cause` of the `DsError` that call throws; any other is reported as an uncaught exception | `DS_ERR_ACTION_FAILED` |
| `setCallCallback`'s `fn` | the [`UnraisableHook`](#unraisablehook) | `DS_ERR_ACTION_FAILED` |

[Callback contract](inv:integrator:std:doc#callbacks/contract) and [Persistence failure](inv:integrator:std:doc#callbacks/cache) state what libds does with the status.

*(Source: bindings/js/lib/bind.js, bindings/js/src/ds.c)*
