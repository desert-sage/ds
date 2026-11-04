<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Stream events

## Registration

### `ds_stream_cb_t`

**`typedef ds_result_t (*ds_stream_cb_t)(ds_engine_t *engine, const ds_stream_ev_t *event, void *user);`**

The stream callback.

It receives every observable event of the engine, in `seq` order. The [contract](contract.md#stream-callback-status) states what its status does. How each event is delivered is in [Runtime architecture](inv:internals:std:doc#overview/runtime-architecture), and how it is recorded in [Fact stream](inv:internals:std:doc#artefacts/fact-stream).

*(libds.h: ds_stream_cb_t, Spec: [NCBK.2.1])*

### `ds_engine_set_stream_callback`

**`ds_result_t ds_engine_set_stream_callback(ds_engine_t *engine, ds_stream_cb_t cb, void *user);`**

Registers the stream callback.

A NULL `cb` removes it. Errors: `DS_ERR_INVAL`, `DS_ERR_STATE`, `DS_ERR_ENGINE_HALTED`.

*(libds.h: ds_engine_set_stream_callback, Spec: [NCBK.2.1], [NCBK.2.9], [RARC.13.16])*

## Event

### `struct ds_stream_ev`

**`struct ds_stream_ev { uint64_t seq; uint64_t clock_ns; ds_stream_ev_kind_t kind; union { … } p; };`**

The layout of a [`ds_stream_ev_t`](../conventions/handles.md#ds_stream_ev_t).

`seq` strictly increases per engine. `clock_ns` is the engine clock at emit. Switch on `kind` and read only the matching member of `p`.

*(libds.h: struct ds_stream_ev, Spec: [NCBK.2.2], [NFCT.5.2], [IDAT.7.2])*

### `ds_stream_ev_kind_t`

**`typedef enum { … } ds_stream_ev_kind_t;`**

The kind of a stream event, and the discriminant of `p`.

A `switch` over it handles `default`. Each kind is named on its payload entry below.

```{include} ../_generated/event_kinds.md
```

*(libds.h: ds_stream_ev_kind_t, proto: stream_event_kind.proto, Spec: [NCBK.2.13])*

### Action event timing

A `DS_EV_ACTION_*` event is emitted once the engine's own part of the verb has succeeded, and before any integrator callback the verb invokes.

A verb that fails in the engine emits no action event. A callback's failure or absence does not decide the event. How each verb dispatches is in [Agenda and actions](inv:internals:std:doc#engine/agenda-and-actions).

*(Spec: [IDSP.1.4], [NCBK.2.7])*

### Stream and telemetry order

For one logical event, the stream event precedes its metric and log emissions.

*(Spec: [NCBK.2.7])*

### Firing order

Within one rule firing, the `seq` order is:

1. `DS_EV_RULE_LHS_FACTS`, when the firing matched at least one live fact.
2. `DS_EV_RULE_FIRE_BEGIN`, with no event between it and `DS_EV_RULE_LHS_FACTS`.
3. For each right-hand-side action in turn: `DS_EV_FACT_ASSERT` if it asserts, `DS_EV_ACTION_*`, and `DS_EV_FACT_RETRACT` if it retracts.
4. `DS_EV_RULE_FIRE_END`.
5. `DS_EV_TIMER_ARMED`, immediately after, when the rate gate admitted a `cooldown` rule's firing.

A firing that matched no live fact emits no `DS_EV_RULE_LHS_FACTS`, and neither does the firing of an `after` body. An activation withheld by a fire guard emits neither `DS_EV_RULE_LHS_FACTS` nor `DS_EV_RULE_FIRE_BEGIN`.

*(Spec: [NCBK.2.6])*

## Fact payloads

### `fact_assert`

**`struct { ds_fact_t *fact; } fact_assert;`**

The payload of `DS_EV_FACT_ASSERT`: an assert arrived, before anything its evaluation produces.

The event fires when a new fact entered working memory, when an upsert's replacement did (the old fact's `DS_EV_FACT_RETRACT` follows), when a no-op reassertion left the live fact in place, and when the engine refused the assert (its `DS_EV_BOUNDS_ERROR` follows). `fact` is valid until that fact is retracted. After a refused assert, `fact` is valid only for the callback and is not a working-memory handle.

*(libds.h: struct ds_stream_ev, Spec: [NCBK.2.3], [NFCT.5.1], [NFCT.5.3], [NFCT.5.4])*

### `fact_retract`

**`struct { ds_fact_t *fact; } fact_retract;`**

The payload of `DS_EV_FACT_RETRACT`: a fact left working memory, by retract, TTL sweep or upsert replacement.

`fact` is valid only for the callback. Each successful retract emits one event, and the TTL sweep one per expired fact.

*(libds.h: struct ds_stream_ev, Spec: [NCBK.2.3], [NFCT.5.1], [NFCT.5.3], [NFCT.5.4])*

### `fact_modify`

**`struct { ds_fact_t *fact; } fact_modify;`**

The payload arm of `DS_EV_FACT_MODIFY`.

libds never emits `DS_EV_FACT_MODIFY`. An upsert surfaces as a `DS_EV_FACT_ASSERT` followed by a `DS_EV_FACT_RETRACT`.

*(libds.h: struct ds_stream_ev, Spec: [NCBK.2.4], [NFCT.5.1])*

## Rule firing payloads

### `rule_fire_begin`

**`struct { const char *rule_name; int64_t timetag; } rule_fire_begin;`**

The payload of `DS_EV_RULE_FIRE_BEGIN`: a rule's right-hand side is about to run.

`timetag` is the [firing's identity](#firing-identity).

*(libds.h: struct ds_stream_ev, Spec: [NCBK.2.3])*

### `rule_fire_end`

**`struct { const char *rule_name; int64_t timetag; } rule_fire_end;`**

The payload of `DS_EV_RULE_FIRE_END`: a rule's right-hand side returned.

*(libds.h: struct ds_stream_ev, Spec: [NCBK.2.3])*

### `rule_lhs_facts`

**`struct { const char *rule_name; ds_fact_t **facts; uint32_t fact_count; int64_t timetag; } rule_lhs_facts;`**

The payload of `DS_EV_RULE_LHS_FACTS`: the facts the firing matched.

`facts` holds at most one fact per left-hand-side pattern, in declaration order, and the array is valid only for the callback.

*(libds.h: struct ds_stream_ev, Spec: [NCBK.2.3], [NCBK.2.5], [NCBK.2.6])*

### `timer_armed`

**`struct { const char *rule_name; const char *kind; uint64_t window_ns; uint64_t fire_at_ns; int64_t timetag; } timer_armed;`**

The payload of `DS_EV_TIMER_ARMED`: a `cooldown` rule fired and armed its suppression window.

`kind` is `"cooldown"`. `window_ns` is the configured window. `fire_at_ns` is `clock_ns` plus `window_ns`, the earliest `clock_ns` at which the rule may fire again. A firing the gate suppresses arms nothing.

*(libds.h: struct ds_stream_ev, ds_stream_ev_kind_t, Spec: [NCBK.2.3], [NCBK.2.6])*

### `timer_fired`

**`struct { const char *rule_name; const char *kind; } timer_fired;`**

The payload arm of `DS_EV_TIMER_FIRED`.

libds never emits `DS_EV_TIMER_FIRED`. A `cooldown` rule's later firing is seen through its ordinary firing events, and joined to its `DS_EV_TIMER_ARMED` by `timetag`.

*(libds.h: struct ds_stream_ev, Spec: [NCBK.2.4])*

### Firing identity

`timetag` identifies a firing within this engine's stream.

It has one value on every event one firing produces: `DS_EV_RULE_LHS_FACTS`, `DS_EV_RULE_FIRE_BEGIN`, `DS_EV_RULE_FIRE_END`, `DS_EV_ACTION_CALL` and `DS_EV_TIMER_ARMED`. Join these events by `timetag`, not by stream position or `rule_name`, and do not compare it with a `timetag` from another engine. `0` is not a valid timetag.

*(libds.h: struct ds_stream_ev, Spec: [NCBK.2.12])*

## Action payloads

### `action_emit`

**`struct { ds_fact_t *fact; } action_emit;`**

The payload of `DS_EV_ACTION_EMIT`: an `emit` asserted a fact, local to this engine.

`fact` is a working-memory handle, valid until its `DS_EV_FACT_RETRACT`.

*(libds.h: struct ds_stream_ev, Spec: [NCBK.2.3], [NCBK.2.5])*

### `action_publish`

**`struct { ds_fact_t *fact; const uint8_t *external; size_t external_len; } action_publish;`**

The payload of `DS_EV_ACTION_PUBLISH`: a `publish` sent a fact to the tiers upstream, and asserted nothing in this engine.

`fact` is a view of the published fact, valid for the callback only. It is in no working memory, so it has no id and no lookup finds it. `external` and `external_len` are the fact's [`FactExternal` encoding](#factexternal-bridging). `external` is `NULL` and `external_len` `0` when an allocation failed to build them.

The event arrives between the firing's `DS_EV_RULE_FIRE_BEGIN` and `DS_EV_RULE_FIRE_END`. No `DS_EV_FACT_ASSERT` or `DS_EV_ACTION_EMIT` is delivered for a `publish`.

*(libds.h: struct ds_stream_ev, Spec: [NCBK.2.3], [NCBK.2.5], [NCBK.10.1], [IDSP.4.6])*

### `action_log`

**`struct { ds_log_level_t level; const char *category; const char *message; } action_log;`**

The payload of `DS_EV_ACTION_LOG`: a `log` action ran.

The event precedes the [log callback](telemetry.md#ds_log_cb_t).

*(libds.h: struct ds_stream_ev, Spec: [NCBK.2.3])*

### `action_call`

**`struct { const char *service; const char *correlation; const ds_arg_t *args; uint32_t arg_count; int64_t timetag; const char *rule_name; } action_call;`**

The payload of `DS_EV_ACTION_CALL`: a `call` action's arguments evaluated.

The members are [`ds_call_request_t`](call.md#ds_call_request_t)'s. The event precedes the call callback, and fires whatever the callback returns and whether or not one is registered. An argument that fails to evaluate or is refused emits no event.

*(libds.h: struct ds_stream_ev, Spec: [NCBK.2.3], [NCBK.6.9], [IDSP.1.4], [IDSP.6.5])*

### `action_cache_set`

**`struct { const char *key; const ds_json_t *value; uint64_t ttl_ns; } action_cache_set;`**

The payload of `DS_EV_ACTION_CACHE_SET`: the engine applied a `cache` write.

The event precedes the [persistence callback](cache.md#ds_cache_set_cb_t), and fires whether or not one is registered. `value` is borrowed for the callback.

*(libds.h: struct ds_stream_ev, Spec: [NCBK.2.3], [NCBK.7.6], [IDSP.7.6])*

### `action_cache_delete`

**`struct { const char *key; } action_cache_delete;`**

The payload of `DS_EV_ACTION_CACHE_DELETE`: the engine applied a `cache_delete`.

A [TTL expiry](cache.md#expiry) emits no event.

*(libds.h: struct ds_stream_ev, Spec: [NCBK.2.3], [NCBK.7.6], [IDSP.7.6])*

### `action_cache_get`

**`struct { const char *key; const ds_json_t *value; } action_cache_get;`**

The payload arm of `DS_EV_ACTION_CACHE_GET`.

libds never emits `DS_EV_ACTION_CACHE_GET`. A `cached()` read is an internal engine read.

*(libds.h: struct ds_stream_ev, Spec: [NCBK.2.4], [NCBK.7.6], [IDSP.7.6])*

## Clock payloads

### `tick`

**`struct { bool wall_set; int64_t wall_ns; } tick;`**

The payload of `DS_EV_TICK`: an input or a pump took a clock sample.

`clock_ns` is the monotonic sample. `wall_ns` is the wall sample, in UTC nanoseconds since the Unix epoch. `wall_set` is false while the wall clock has no value, and `wall_ns` is then `0`.

*(libds.h: struct ds_stream_ev, Spec: [NCBK.2.3])*

### `DS_EV_PUMP`

**`DS_EV_PUMP`**

The kind of the event that begins a host pump.

It follows the pump's clock sample and `DS_EV_TICK`, and fires whether or not the pump fires anything. It has no payload. `clock_ns` is the pump's sample.

*(libds.h: ds_stream_ev_kind_t, Spec: [NCBK.2.3])*

## Fault payloads

### Fault events

Every fault is a stream event on the stream callback, in `seq` order.

Each of the four kinds has one disposition, and no payload carries one.

| Kind | Raised when | Disposition |
|---|---|---|
| `DS_EV_TYPE_ERROR` | a value is present and the operation is invalid at that site | the activation is abandoned |
| `DS_EV_BOUNDS_ERROR` | a declared cap was reached | the operation is rejected and the engine is intact |
| `DS_EV_ENGINE_ERROR` | engine state is not trustworthy | the tier halts |
| `DS_EV_COMPUTATION_ERROR` | a well-typed operation has no answer | the activation is abandoned |

A fault's `rule_name`, where the payload's entry does not say otherwise, is the activation's rule, `$alpha_<id>` or `$beta_<id>` for a fault raised at a node during matching, or `$engine` with no node site. It is never NULL or empty.

```{note}
A fault reaching the callback has not thereby reached durable storage. Persistence is the integrator's sink.
```

*(libds.h: ds_stream_ev_kind_t, struct ds_stream_ev, Spec: [NCBK.2.8], [LERR.9.11])*

### `type_error`

**`struct { uint32_t node_id; const char *schema_name; const char *slot_name; const char *actual; const char *rule_name; } type_error;`**

The payload of `DS_EV_TYPE_ERROR`.

`node_id` is the node, from which a consumer holding the artefact derives the expected type. `actual` is the tag the value had.

*(libds.h: struct ds_stream_ev, proto: type_error.proto, Spec: [NCBK.2.10])*

### `bounds_error`

**`struct { ds_cap_name_t cap; uint64_t limit; uint64_t observed; const char *rule_name; int64_t timetag; } bounds_error;`**

The payload of `DS_EV_BOUNDS_ERROR`.

`cap` names the cap, `limit` is its declared value, and `observed` is what the operation would have reached. `rule_name` and `timetag` are the activation's identity. With no activation, `rule_name` is NULL and `timetag` is `0`.

*(libds.h: struct ds_stream_ev, proto: bounds_error.proto, Spec: [NCBK.2.10])*

### `engine_error`

**`struct { ds_engine_fault_t fault; uint32_t node_id; const char *rule_name; } engine_error;`**

The payload of `DS_EV_ENGINE_ERROR`.

`fault` is the cause. `node_id` is `0` for a fault with no node site. This event is the last from that engine, and sets the [halt latch](../engine/lifecycle.md#halt-latch).

*(libds.h: struct ds_stream_ev, Spec: [NCBK.2.9], [NCBK.2.10])*

### `computation_error`

**`struct { ds_trap_kind_t kind; const char *rule_name; int64_t timetag; const char *schema_name; const char *slot_name; uint64_t fact_id; uint32_t node_id; } computation_error;`**

The payload of `DS_EV_COMPUTATION_ERROR`.

`kind` is the cause. `rule_name` and `timetag` are the activation's identity, and `timetag` is `0` for a trap raised while matching. `node_id` is the node, which the artefact's `LineSpan` [maps to a line](../introspection/metadata.md#ds_engine_line_span_find).

*(libds.h: struct ds_stream_ev, proto: engine_error.proto, Spec: [NCBK.2.10])*

## Fault enums

### `ds_trap_kind_t`

**`typedef enum { … } ds_trap_kind_t;`**

The cause of a `computation_error`, the C mirror of `proto/engine_error.proto`'s `TrapKind`.

| Member | Meaning |
|---|---|
| `DS_TRAP_UNSPECIFIED` | refused at load |
| `DS_TRAP_DIVIDE_BY_ZERO` | division by zero |
| `DS_TRAP_DOMAIN` | mathematically undefined at that input |
| `DS_TRAP_NOT_REPRESENTABLE` | a total `Float :: Int` that is not representable |

*(libds.h: ds_trap_kind_t, Spec: [NCBK.2.10])*

### `ds_engine_fault_t`

**`typedef enum { … } ds_engine_fault_t;`**

The cause of an `engine_error`, the C mirror of `proto/engine_fault.proto`'s `EngineFault`.

| Member | Meaning |
|---|---|
| `DS_ENGINE_FAULT_UNSPECIFIED` | refused at load |
| `DS_ENGINE_FAULT_ARTEFACT_LIED` | an ill-typed operation on a value not sourced from `Json`; a call whose operand count or shape its op does not admit; or a slot index, read by an `AlphaTest` or a `VarExpr` or written by a `SlotAssign`, that names no slot of the fact's schema |
| `DS_ENGINE_FAULT_PATTERN_INDEX` | an expression read a pattern position the match never bound |
| `DS_ENGINE_FAULT_BINDING_ORDER` | a read reached a binding before the action establishing it ran |
| `DS_ENGINE_FAULT_ORDER_KEY` | two activations held one agenda order key |
| `DS_ENGINE_FAULT_ALLOCATION` | an allocation failed, with no declared cap as the limit |
| `DS_ENGINE_FAULT_PUMP_WCET` | a pump overran its time bound |

*(libds.h: ds_engine_fault_t, proto: engine_fault.proto, Spec: [NCBK.2.10], [RARC.5.3.3], [RARC.5.6.11], [RARC.5.4.9], [RDSC.4a.9.1])*

### `ds_cap_name_t`

**`typedef enum { … } ds_cap_name_t;`**

The cap of a `bounds_error`, the C mirror of `proto/bounds_error.proto`'s `CapName`.

| Member | Scope |
|---|---|
| `DS_CAP_UNSPECIFIED` | refused at load |
| `DS_CAP_WM_MAX` | per engine |
| `DS_CAP_AGENDA` | per engine |
| `DS_CAP_MAX_FIRES_PER_PUMP` | per engine |
| `DS_CAP_TOKEN_POOL` | per engine |
| `DS_CAP_INTERN` | per engine |
| `DS_CAP_INTERN_BYTES` | per engine |
| `DS_CAP_PUMP_WCET_NS` | per engine |
| `DS_CAP_CACHE` | per engine |
| `DS_CAP_CACHE_BYTES` | per engine |
| `DS_CAP_NODE_CAPACITY` | per instance: `nodes[i].capacity` |
| `DS_CAP_SERIES_CAPACITY` | per instance: `series[i].capacity` |
| `DS_CAP_VALUE_CAPACITY` | per instance: a slot's declared `capacity` |

*(libds.h: ds_cap_name_t, Spec: [NCBK.2.10])*

## Cross-tier bridging

### `FactExternal` bridging

A published fact crosses tiers as its `FactExternal` encoding, self-describing bytes that the integrator does not decode.

`DS_EV_ACTION_PUBLISH` alone carries the encoding, in `external` and `external_len`, valid only for the callback. `emit` asserts locally and carries no encoding. [`ds_engine_assert_external`](../facts/asserting.md#ds_engine_assert_external) on another engine asserts the bytes, and that engine gives each fact its own `event_id`. The encoding is in [Fact stream](inv:internals:std:doc#artefacts/fact-stream).

*(libds.h: struct ds_stream_ev, Spec: [NCBK.10.1], [NCBK.10.2], [NCBK.10.3])*
