<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Reports and duties

## Reports

### `report`

**`:- type report ---> streamed(integrator_event) ; logged(log_line) ; measured(metric) ; cache_expired(string).`**

One thing a call reports: a value the call returns, in place of a libds callback.

| Member | Capability of |
|---|---|
| `streamed(E)` | [`ds_stream_cb_t`](inv:integrator:std:doc#callbacks/stream) |
| `logged(L)` | [`ds_log_cb_t`](inv:integrator:std:doc#callbacks/telemetry): a rule's `log`, after its `action_log`, or a line the engine writes |
| `measured(M)` | [`ds_metric_cb_t`](inv:integrator:std:doc#callbacks/telemetry), with a [`metric`](#metric) |
| `cache_expired(Key)` | [`ds_cache_delete_cb_t`](inv:integrator:std:doc#callbacks/cache) with `DS_CACHE_REMOVED_TTL`: where the expiry happened among the call's reports |

A call's reports are in the order it emitted them, as [Stream and telemetry order](inv:integrator:std:doc#callbacks/stream) states.

*(Source: bindings/mercury/src/mercury_ds.events.m, bindings/mercury/src/mercury_ds.from_runtime.m, Spec: [NCBK.1.5], [NSTG.2.4.2])*

### `log_line`

**`:- type log_line ---> log_line(log_line_level :: log_level, log_line_category :: string, log_line_message :: string).`**

A log line: the capability of [`ds_log_event_t`](inv:integrator:std:doc#callbacks/telemetry).

`log_line_category` is the rule's name for a rule's `log`, and the engine's subsystem for a line it writes.

*(Source: bindings/mercury/src/mercury_ds.events.m)*

### `log_level`

**`:- type log_level ---> log_debug ; log_info ; log_warning ; log_error ; log_critical.`**

A log line's severity, `ds.action`'s: [`ds_log_level_t`](inv:integrator:std:doc#callbacks/telemetry), with `log_` for `DS_LOG_` and in lower case.

*(Source: runtime/mercury/src/ds.action.m)*

### `metric`

**`:- type metric ---> metric(m_name :: string, m_kind :: metric_kind, m_value :: float, m_labels :: list({string, string})).`**

One metric emission, `ds.events`': the capability of [`ds_metric_t`](inv:integrator:std:doc#callbacks/telemetry).

`m_kind` is `mk_counter` or `mk_gauge`, as [`ds_metric_kind_t`](inv:integrator:std:doc#callbacks/telemetry) has them. `m_labels` is each label's key and value, in the order libds builds them.

*(Source: runtime/mercury/src/ds.events.m)*

## Stream events

### `integrator_event`

**`:- type integrator_event ---> integrator_event(integrator_event_seq :: seq, integrator_event_clock :: instant, integrator_event_kind :: event_kind).`**

One stream event: the capability of [`struct ds_stream_ev`](inv:integrator:std:doc#callbacks/stream).

`integrator_event_seq` is the engine's number for the event. The engine numbers events it does not report as well, so the numbers reported can have gaps. `integrator_event_clock` is the monotonic sample the emitting step took.

*(Source: bindings/mercury/src/mercury_ds.events.m, bindings/mercury/src/mercury_ds.from_runtime.m)*

### `event_kind`

**`:- type event_kind ---> fact_assert(fact_id, string, list(storable)) ; fact_retract(fact_id) ; rule_lhs_facts(activation, list(fact_id)) ; rule_fire_begin(activation) ; rule_fire_end(activation) ; action_call(service_call) ; action_emit(fact_id, string) ; action_publish(string, list(storable), maybe(fact_external)) ; action_cache_set(cache_write) ; action_cache_delete(string) ; action_log(log_line) ; tick(maybe(int64)) ; timer_armed(activation, duration, instant) ; type_error(fault_info) ; computation_error(trap_kind, fault_info) ; bounds_error(cap_name, fault_info) ; engine_error(engine_fault, fault_info) ; pump.`**

A stream event's kind and payload. Each constructor is the kind of its name in the integrator's [stream payloads](inv:integrator:std:doc#callbacks/stream); strings are strings, and a schema is its name.

| Constructor | Arguments |
|---|---|
| `fact_assert` | the fact, its schema's name, its slot values as [`storable`](facts.md#storable)s |
| `fact_retract` | the fact, whoever removed it: the host, an expiry, a supersedure or truth maintenance |
| `rule_lhs_facts` | the firing, and the facts it matched, at most one per pattern |
| `action_emit` | the fact, its schema's name |
| `action_publish` | the schema's name, the published slot values as `storable`s, and the fact as it crosses to another engine, or `no` where it does not encode; `fact_external` is `ds.fact_external`'s. No `fact_id`: the fact is in no working memory of this session |
| `tick` | the wall sample in UTC nanoseconds, or `no` while the wall clock has no value |
| `timer_armed` | the firing, the cooldown window's length, and when it ends |
| `computation_error` | the [`trap_kind`](#trap_kind), `domain` for a slot value the schema refused |
| `bounds_error` | the [`cap_name`](#cap_name) |
| `engine_error` | the [`engine_fault`](#engine_fault); it is a halted session's last event |

*(Source: bindings/mercury/src/mercury_ds.events.m, bindings/mercury/src/mercury_ds.from_runtime.m, Spec: [NCBK.2.9], [NCBK.2.6])*

### `activation`

**`:- type activation ---> activation(activation_rule :: string, activation_timetag :: timetag).`**

The firing an event belongs to, as [Firing identity](inv:integrator:std:doc#callbacks/stream) states.

*(Source: bindings/mercury/src/mercury_ds.events.m, Spec: [NCBK.2.12])*

### `service_call`

**`:- type service_call ---> service_call(service_call_service :: string, service_call_correlation :: string, service_call_args :: list(arg), service_call_activation :: activation).`**

A rule's `call`: the capability of [`ds_call_request_t`](inv:integrator:std:doc#callbacks/call).

`service_call_args` is sorted by name.

*(Source: bindings/mercury/src/mercury_ds.events.m, Spec: [NCBK.6.10], [LCRS.3.1])*

### `arg`

**`:- type arg ---> arg(arg_name :: string, arg_value :: arg_value).`**

One typed call argument, `ds.fact_external`'s: the capability of [`ds_arg_t`](inv:integrator:std:doc#facts/values).

| `arg_value` | `ds_arg_kind_t` | Holds |
|---|---|---|
| `av_int(int64)` | [`DS_ARG_INT`](inv:integrator:std:doc#facts/values) | the integer |
| `av_float(float)` | `DS_ARG_FLOAT` | the float |
| `av_string(string)` | `DS_ARG_STRING` | the text |
| `av_bool(bool)` | `DS_ARG_BOOL` | the value |
| `av_json(string)` | `DS_ARG_JSON` | the canonical JSON text |
| `av_bytes(list(uint8))` | `DS_ARG_BYTES` | the bytes |
| `av_encoded_fact(fact_external)` | `DS_ARG_ENCODED_FACT` | the fact |

*(Source: runtime/mercury/src/ds.fact_external.m, runtime/mercury/src/ds.exec.m, Spec: [NCBK.6.10])*

### `cache_write`

**`:- type cache_write ---> cache_write(cache_write_key :: string, cache_write_value_json :: string, cache_write_ttl :: maybe(duration)).`**

A rule's `cache` write: the capability of [`ds_cache_write_t`](inv:integrator:std:doc#callbacks/cache).

`cache_write_value_json` is the JSON text the cache holds. `cache_write_ttl` is `no` for no expiry.

*(Source: bindings/mercury/src/mercury_ds.events.m)*

## Fault payloads

### `fault_info`

**`:- type fault_info ---> fault_info(fault_info_rule :: string, fault_info_activation :: maybe(activation), fault_info_node :: maybe(node_id), fault_info_schema :: maybe(string), fault_info_slot :: maybe(string), fault_info_bound :: maybe(bound), fault_info_fact :: maybe(fact_id), fault_info_actual :: maybe(string)).`**

Where a fault was raised: the capability of the integrator's [fault payloads](inv:integrator:std:doc#callbacks/stream).

`fault_info_rule` is never empty: a rule, `$alpha_<id>`, `$beta_<id>` or `$engine`. `fault_info_actual` is the tag the offending value had. Each `maybe` is `no` where the raise site does not know it.

*(Source: bindings/mercury/src/mercury_ds.events.m, Spec: [NCBK.2.10], [LERR.9.11])*

### `bound`

**`:- type bound ---> bound(bound_limit :: int, bound_observed :: int).`**

A cap's limit, and the usage the refused operation would have reached.

*(Source: bindings/mercury/src/mercury_ds.events.m)*

### `trap_kind`

**`:- type trap_kind ---> divide_by_zero ; domain ; not_representable.`**

The cause of a `computation_error`: [`ds_trap_kind_t`](inv:integrator:std:doc#callbacks/stream).

*(Source: bindings/mercury/src/mercury_ds.events.m)*

### `engine_fault`

**`:- type engine_fault ---> artefact_lied ; pattern_index ; binding_order ; order_key ; allocation ; pump_wcet ; internal ; unspecified_fault.`**

The cause of an `engine_error`: [`ds_engine_fault_t`](inv:integrator:std:doc#callbacks/stream).

`unspecified_fault` is a fault with no `EngineFault` of its own.

*(Source: bindings/mercury/src/mercury_ds.events.m, bindings/mercury/src/mercury_ds.from_runtime.m)*

### `cap_name`

**`:- type cap_name ---> wm_max ; agenda ; max_fires_per_pump ; token_pool ; intern ; intern_bytes ; pump_wcet_ns ; cache ; cache_bytes ; node_capacity ; series_capacity ; value_capacity.`**

The cap of a `bounds_error`: [`ds_cap_name_t`](inv:integrator:std:doc#callbacks/stream).

*(Source: bindings/mercury/src/mercury_ds.events.m)*

## Duties

### `duty`

**`:- type duty ---> write_cache(cache_write) ; remove_cache(cache_removal).`**

Something a call asks of the host, which a session does not do itself: the capability of the [persistence callbacks](inv:integrator:std:doc#callbacks/cache), returned as data.

`write_cache` writes a rule's write through to the host's store, and `remove_cache` removes a key from it. Perform them in the order given. What the host does leaves the session unchanged.

```mercury declaration
:- func duty_key(duty) = string.
duty_key(write_cache(W)) = W ^ cache_write_key.
duty_key(remove_cache(R)) = R ^ cache_removal_key.
```

*(Source: bindings/mercury/src/mercury_ds.host.m, bindings/mercury/src/mercury_ds.session.m, Spec: [NSTG.2.4.2])*

### `cache_removal`

**`:- type cache_removal ---> cache_removal(cache_removal_key :: string, cache_removal_reason :: removal_reason).`**

A key leaving the engine's cache: the capability of [`ds_cache_removal_t`](inv:integrator:std:doc#callbacks/cache).

*(Source: bindings/mercury/src/mercury_ds.host.m)*

### `removal_reason`

**`:- type removal_reason ---> removed_by_rule ; expired.`**

Why a key left the cache: [`ds_cache_removal_reason_t`](inv:integrator:std:doc#callbacks/cache).

`removed_by_rule` is a rule's `cache_delete`, and `expired` is the entry's TTL running out.

*(Source: bindings/mercury/src/mercury_ds.host.m)*

## Services

### `service_answer`

**`:- type service_answer ---> answered(list(storable)) ; no_response ; call_error(string, string) ; not_offered.`**

What a service did with a call.

| Member | Meaning |
|---|---|
| `answered(Slots)` | the response: every slot of the service's response schema but `corr`, in declaration order |
| `no_response` | done, for a service declared `no response` |
| `call_error(Code, Message)` | it could not be done: the `CallError`'s code and message |
| `not_offered` | the host offers no service of this name |

*(Source: bindings/mercury/src/mercury_ds.host.m)*

### `answer`

**`:- pred answer(service_call::in, service_answer::in, step::out, session::in, session::out) is det.`**

Answers a call a pump issued, as [Answers](inv:integrator:std:doc#callbacks/call) states, setting `corr` to the call's correlation.

What the [`step`](session.md#step) holds depends on the answer:

| Answer | Asserted |
|---|---|
| `answered`, fitting the response schema | the response |
| `answered`, to a service with no response schema | a `CallError`, `internal.bug` |
| `answered`, not one value per slot, or an assert refuses it for anything but `encoding` | a `CallError`, `internal.bug` |
| `no_response`, to a service declared `no response` | nothing |
| `no_response`, to a service with a response schema | a `CallError`, `internal.bug` |
| `call_error(Code, Message)` | a `CallError` with them |
| `not_offered` | a `CallError`, `request.unsupported` |

`step_outcome` is `error` with `engine_halted` for a session that had halted or a call that halts the engine, `error` with `encoding` for a refusal of ill-formed text, and otherwise `ok`.

An assert of the response or the `CallError` refused with [`encoding`](facts.md#assert_fact) changes nothing: no `CallError` is asserted, and `step_reports` and `step_duties` are empty.

A `CallError`'s `ts` is the wall clock's value. With no wall value, nothing is asserted, and `step_reports` holds a `log_warning` line in the category `services`. A `CallError` the engine refuses for anything but `encoding` is not asserted, and `step_outcome` is `ok`.

*(Source: bindings/mercury/src/mercury_ds.session.m, Spec: [LCRS.3.1], [LCRS.4.2.1], [NCBK.2.9], [LSTR.8.5])*

### `pump_serving`

**`:- pred pump_serving(pred(service_call, service_answer, H, H, io, io)::in(pred(in, out, in, out, di, uo) is det), pumped::out, session::in, session::out, H::in, H::out, io::di, io::uo) is det.`**

Pumps, and answers every call through `Serve`, pumping again after each answer that asserted something, until no call waits.

Calls are answered in the order issued, and the calls an answer causes wait behind those already waiting. It runs [`read_clock`](clock.md#read_clock) before the first pump and after each service. Once the session has halted, no further call is served.

The [`pumped`](session.md#pumped) is every pump's: the first failure, an answer's `encoding` refusal among them, and each list in order. `pumped_calls` holds every call issued, each answered unless the session halted first or the answer was refused. Nothing `Serve` throws is caught.

*(Source: bindings/mercury/src/mercury_ds.session.m, Spec: [LSTR.8.5], [NCBK.1.5])*

## Cache

### `cache_seed`

**`:- pred cache_seed(string::in, json::in, maybe(duration)::in, outcome::out, session::in, session::out) is det.`**

Restores one cache entry: the capability of [`ds_engine_cache_seed`](inv:integrator:std:doc#callbacks/cache).

`no` is no expiry. The first row that applies is the refusal, and the session is unchanged.

| `error` with | Condition |
|---|---|
| `engine_halted` | the session has halted |
| `inval` | the TTL is zero |
| `state` | the engine has emitted a stream event |
| `time_range` | the TTL is longer than `2^63 - 1` nanoseconds |
| `json_limit` | the value passes a [`DS_JSON_MAX_*` limit](inv:integrator:std:doc#facts/json) |
| `encoding` | the key, or a string or key in the value, is not well-formed UTF-8 |
| `json_nonfinite` | the value holds an infinite or NaN float |
| `contract_breach` | storing it passes a bound [`set_cache_cap`](#set_cache_cap) set |

*(Source: bindings/mercury/src/mercury_ds.session.m, runtime/mercury/src/ds.engine.m, Spec: [NLFC.9.1], [NLFC.9.5], [NLFC.9.6], [LGRA.5.8.10], [LSTO.4.7.5])*

### `set_cache_cap`

**`:- pred set_cache_cap(int::in, int::in, outcome::out, session::in, session::out) is det.`**

Bounds the cache by live keys, then value bytes, zero for unbounded: the capability of [`ds_engine_set_cache_cap`](inv:integrator:std:doc#callbacks/cache).

A halted session is refused with `engine_halted`, ahead of the bounds' checks. A negative bound, or a key bound above 4294967295, is refused with `inval`. A refused call leaves the session unchanged.

*(Source: bindings/mercury/src/mercury_ds.session.m, runtime/mercury/src/ds.engine.m, Spec: [LSTO.4.7.5], [NCBK.2.9])*
