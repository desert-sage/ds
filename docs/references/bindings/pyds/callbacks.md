<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Callbacks and events

## Callbacks

### Callback attributes

`on_event`, `on_log`, `on_metric`, `on_cache_set` and `on_cache_delete` are attributes of [`Engine`](engine.md#engine-1) that hold the [registered callback](inv:integrator:std:doc#callbacks/contract).

Assigning a callable registers it, assigning `None` removes it, and reading returns what was assigned. Any other value raises `TypeError`.

*(Source: bindings/python/src/pyds/engine.py)*

### `on_event`

**`on_event: Callable[[Event], object] | None`**

The stream callback, registered through [`ds_engine_set_stream_callback`](inv:integrator:std:doc#callbacks/stream).

It is called with each stream event as a [`pyds.events`](#pydsevents) value, after a running [`Recording`](recording.md#recording-1) has taken the event.

```python statement
def seen(ev: pyds.events.Event) -> None:
    print(ev.seq, ev.kind)
engine.on_event = seen
```

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/_pyds/engine.c)*

### `on_log`

**`on_log: Callable[[LogEvent], object] | None`**

The log callback, registered through [`ds_engine_set_log_callback`](inv:integrator:std:doc#callbacks/telemetry).

*(Source: bindings/python/src/pyds/engine.py)*

### `on_metric`

**`on_metric: Callable[[Metric], object] | None`**

The metric callback, registered through [`ds_engine_set_metric_callback`](inv:integrator:std:doc#callbacks/telemetry).

*(Source: bindings/python/src/pyds/engine.py)*

### `set_call_callback`

**`def set_call_callback(self, callback: Callable[[_CallRequest], object] | None, /) -> None`**

Registers the call callback through [`ds_engine_set_call_callback`](inv:integrator:std:doc#callbacks/call).

`None` removes it, and any other value that is not callable raises `TypeError`. The callback takes one `dict`, a [`ds_call_request_t`](inv:integrator:std:doc#callbacks/call):

| Key | Value |
|---|---|
| `service`, `correlation`, `rule_name` | `str` |
| `args` | a `dict` from kwarg name to value: each as `Fact.slots` [holds it](facts.md#slot-values), and a fact as an [`EncodedFact`](facts.md#encodedfact). No value is `None` |
| `timetag` | `int` |

*(libds.h: ds_call_request_t, Source: bindings/python/src/pyds/_pyds.pyi, bindings/python/src/_pyds/engine.c, Spec: [NCBK.6.10])*

### `on_cache_set`

**`on_cache_set: Callable[[str, str, int], object] | None`**

The persistence callback for a cache write, a [`ds_cache_set_cb_t`](inv:integrator:std:doc#callbacks/cache).

It is called as `fn(key, value_json, ttl_ns)`. `value_json` is a [`JsonText`](facts.md#jsontext).

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/pyds/_pyds.pyi)*

### `on_cache_delete`

**`on_cache_delete: Callable[[str, CacheRemovalReason], object] | None`**

The persistence callback for a removal, a [`ds_cache_delete_cb_t`](inv:integrator:std:doc#callbacks/cache).

It is called as `fn(key, reason)`.

*(Source: bindings/python/src/pyds/engine.py)*

### A callback's exception

The first exception a callback raises during an engine call is kept, and any later one in that call goes to `sys.unraisablehook`.

If the call fails, the [`Error`](errors.md#error) it raises carries the kept exception as `__cause__`. If it succeeds, the kept exception goes to `sys.unraisablehook`.

| Callback | What libds receives when it raises |
|---|---|
| `on_event` | `DS_OK`: the exception cannot fail the call |
| `set_call_callback`, `on_cache_set`, `on_cache_delete` | `DS_ERR_ACTION_FAILED`, which [the call reports](inv:integrator:std:doc#callbacks/contract) |
| `on_log`, `on_metric` | `DS_ERR_ACTION_FAILED`, whose status [libds drops](inv:integrator:std:doc#callbacks/contract) |

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/_pyds/engine.c)*

## Cache

### `Cache`

**`class Cache`**

The engine-owned [cache](inv:integrator:std:doc#callbacks/cache), from the integrator's side. `Engine.cache` returns one.

```python statement
engine.cache.set_cap(keys=10, bytes=4096)
engine.cache.seed("k", "1", ttl_ns=1_000)
```

*(Source: bindings/python/src/pyds/engine.py)*

### `seed`

**`def seed(self, key: str, value_json: str | bytes, *, ttl_ns: int = 0) -> None`**

Parses `value_json` through [`ds_json_parse`](inv:integrator:std:doc#facts/json), and stores it through [`ds_engine_cache_seed`](inv:integrator:std:doc#callbacks/cache).

`bytes` is the text's UTF-8, passed unchanged. A `key` holding a NUL raises `ValueError`. A `ttl_ns` that is negative or outside `uint64` raises `OverflowError`.

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/_pyds/engine.c)*

### `set_cap`

**`def set_cap(self, *, keys: int = 0, bytes: int = 0) -> None`**

Sets the cache's bounds through [`ds_engine_set_cache_cap`](inv:integrator:std:doc#callbacks/cache).

`keys` is `cap_keys` and `bytes` is `cap_bytes`. A value that is negative or wider than its parameter raises `OverflowError`.

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/_pyds/engine.c)*

### `CacheRemovalReason`

**`class CacheRemovalReason(StrEnum)`**

Why a key left the cache: [`ds_cache_removal_reason_t`](inv:integrator:std:doc#callbacks/cache).

Its members and their values are `DELETE` `"delete"` and `TTL` `"ttl"`.

*(Source: bindings/python/src/pyds/enums.py)*

## Events

### `pyds.events`

**`from pyds import events`**

The module of values an engine reports: each is a frozen, slotted dataclass, a snapshot taken when the engine reported it.

A stream event's class is its [kind](inv:integrator:std:doc#callbacks/stream) in CapWords: `fact_assert` is `FactAssert`. Each carries `seq` and `clock_ns` first, and its class attribute `kind` is the [`EventKind`](#eventkind). `events.TypeError` is the `type_error` event, and `pyds` does not re-export it.

| Class | Other fields |
|---|---|
| `FactAssert`, `FactRetract`, `FactModify`, `ActionEmit` | `fact_id`, a [`FactId`](facts.md#factid) |
| `ActionPublish` | `schema`; `slots`, a `dict` of the published fact's slot values by name; `external`, the `bytes` that [`assert_external`](facts.md#assert_external) takes. It has no `fact_id` |
| `RuleFireBegin`, `RuleFireEnd` | `rule_name`, `timetag` |
| `RuleLhsFacts` | `rule_name`, `timetag`; `lhs_facts`, a `tuple` of `FactId` |
| `TimerArmed` | `rule_name`, `timetag`, `timer_kind`, `window_ns`, `fire_at_ns` |
| `ActionLog` | `level`, a `LogLevel`; `category`, `message` |
| `ActionCall` | `service`, `correlation`, `timetag`, `rule_name`; `args`, as [`set_call_callback`](#set_call_callback) gives it |
| `ActionCacheSet` | `key`; `value_json`, a `JsonText`; `ttl_ns` |
| `ActionCacheGet` | `key`; `value_json`, a `JsonText`, or `None` for a key with none |
| `ActionCacheDelete` | `key` |
| `Tick` | `wall_ns`, or `None` when `wall_set` is false |
| `Pump` | none |
| `TypeError` | `node_id`; `rule_name`, a `str`; `schema_name`, `slot_name`, `actual`, each a `str` or `None` |
| `BoundsError` | `cap`, a `CapName`; `limit`, `observed`, `timetag`; `rule_name`, a `str` or `None` |
| `EngineError` | `engine_fault`, an [`EngineFault`](engine.md#enginefault); `node_id`; `rule_name`, a `str` |
| `ComputationError` | `trap_kind`, a `TrapKind`; `timetag`, `node_id`; `rule_name`, a `str`; `schema_name`, `slot_name`, each a `str` or `None`; `fact_id`, a `FactId` or `None` |

`ActionCall` and `ActionPublish` are not hashable.

*(Source: bindings/python/src/pyds/events.py, bindings/python/src/_pyds/engine.c, runtime/src/libds/engine_rete_adapters.c, runtime/src/libds/rete/eval.c, Spec: [LERR.9.11])*

### `Event`

**`type Event = FactAssert | FactRetract | FactModify | RuleFireBegin | RuleFireEnd | RuleLhsFacts | ActionEmit | ActionPublish | ActionLog | ActionCall | ActionCacheSet | ActionCacheGet | ActionCacheDelete | TimerArmed | Tick | Pump | TypeError | BoundsError | EngineError | ComputationError`**

The union of the stream event classes in `pyds.events`.

*(Source: bindings/python/src/pyds/events.py)*

### `EventKind`

**`class EventKind(StrEnum)`**

A stream event's kind: [`ds_stream_ev_kind_t`](inv:integrator:std:doc#callbacks/stream).

Its members and their values are `FACT_ASSERT` `"fact_assert"`, `FACT_RETRACT` `"fact_retract"`, `FACT_MODIFY` `"fact_modify"`, `RULE_FIRE_BEGIN` `"rule_fire_begin"`, `RULE_FIRE_END` `"rule_fire_end"`, `ACTION_CALL` `"action_call"`, `ACTION_EMIT` `"action_emit"`, `ACTION_PUBLISH` `"action_publish"`, `ACTION_CACHE_SET` `"action_cache_set"`, `ACTION_CACHE_GET` `"action_cache_get"`, `ACTION_LOG` `"action_log"`, `TICK` `"tick"`, `ACTION_CACHE_DELETE` `"action_cache_delete"`, `RULE_LHS_FACTS` `"rule_lhs_facts"`, `TIMER_ARMED` `"timer_armed"`, `TIMER_FIRED` `"timer_fired"`, `TYPE_ERROR` `"type_error"`, `BOUNDS_ERROR` `"bounds_error"`, `ENGINE_ERROR` `"engine_error"`, `COMPUTATION_ERROR` `"computation_error"` and `PUMP` `"pump"`. `TIMER_FIRED` names the kind [`timer_fired`](inv:integrator:std:doc#callbacks/stream) describes.

*(Source: bindings/python/src/pyds/enums.py)*

### `LogEvent`

**`LogEvent(level, category, message)`**

A frozen dataclass of [`ds_log_event_t`](inv:integrator:std:doc#callbacks/telemetry).

`level` is a `LogLevel`.

*(Source: bindings/python/src/pyds/events.py)*

### `Metric`

**`Metric(name, kind, value, labels)`**

A frozen dataclass of [`ds_metric_t`](inv:integrator:std:doc#callbacks/telemetry).

`kind` is a `MetricKind`, `value` a `float`, and `labels` a `dict` from key to value, the event's own copy. It is not hashable.

*(Source: bindings/python/src/pyds/events.py, bindings/python/src/_pyds/engine.c)*

### `LogLevel`

**`class LogLevel(StrEnum)`**

A log line's severity: [`ds_log_level_t`](inv:integrator:std:doc#callbacks/telemetry).

Its members and their values are `DEBUG` `"DEBUG"`, `INFO` `"INFO"`, `WARNING` `"WARNING"`, `ERROR` `"ERROR"` and `CRITICAL` `"CRITICAL"`.

*(Source: bindings/python/src/pyds/enums.py)*

### `MetricKind`

**`class MetricKind(StrEnum)`**

What a metric measures: [`ds_metric_kind_t`](inv:integrator:std:doc#callbacks/telemetry).

Its members and their values are `COUNTER` `"counter"`, `GAUGE` `"gauge"` and `HISTOGRAM` `"histogram"`.

*(Source: bindings/python/src/pyds/enums.py)*

### `TrapKind`

**`class TrapKind(enum.IntEnum)`**

The cause of a `computation_error`: [`ds_trap_kind_t`](inv:integrator:std:doc#callbacks/stream), with each member's `DS_TRAP_` prefix removed.

Its members are `DIVIDE_BY_ZERO`, `DOMAIN` and `NOT_REPRESENTABLE`.

*(Source: bindings/python/src/pyds/_faults.py)*

### `CapName`

**`class CapName(enum.IntEnum)`**

The cap of a `bounds_error`: [`ds_cap_name_t`](inv:integrator:std:doc#callbacks/stream), with each member's `DS_CAP_` prefix removed.

Its members are `WM_MAX`, `AGENDA`, `MAX_FIRES_PER_PUMP`, `TOKEN_POOL`, `INTERN`, `INTERN_BYTES`, `PUMP_WCET_NS`, `CACHE`, `CACHE_BYTES`, `NODE_CAPACITY`, `SERIES_CAPACITY` and `VALUE_CAPACITY`.

*(Source: bindings/python/src/pyds/_faults.py)*
