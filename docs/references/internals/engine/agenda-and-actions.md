<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Agenda and actions

## Agenda

### Activation

An activation is a matched rule waiting to fire.

| Field | Holds |
|---|---|
| `terminal` | the terminal whose LHS matched |
| `token` | the match |
| `creation_timetag` | the second ordering key, within one rule |
| `heap_index` | the activation's position in the agenda heap |
| `fired`, `refracts` | whether it has been fired or dismissed, and whether its firing put its identity in the terminal's refraction table |

An activation's ownership and lifetime are [Activations](../overview/data-model.md#activations).

*(Spec: [IRET.11], Source: runtime/src/libds/rete/agenda.h)*

### Ordering

The agenda is a binary min-heap ordered by `(terminal ordinal, creation_timetag)`, implementing the [comparator](../overview/runtime-architecture.md#agenda-and-conflict-resolver).

Both keys are read off the activation and its terminal, with no lookup. Two activations never share both keys: the ordinal is unique per rule, and a timetag is assigned per token, which reaches exactly one terminal. No level of the agenda orders by hash. Each activation's `heap_index` gives O(log n) removal when its token is retracted before it fires.

*(Spec: [IRET.1.9], [IRET.11.1], [IRET.11.2], Source: runtime/src/libds/rete/agenda.h)*

### Refraction

Refraction is the activation's `fired` flag: a fired activation leaves the agenda, stays on its terminal's list with the flag set, and is not selected again while its match lasts.

Two per-terminal structures back the flag where a match is formed again without having ended.

| Structure | Holds | Emptied |
|---|---|---|
| refraction table | the token identities that fired in the engine's current cycle generation | by the generation's turnover, at every working-memory assert and retract and once per pump |
| edge-once set | the fact IDs whose clock-driven match has fired | per fact, when its time-dependent test goes false or the fact leaves working memory; not by the generation's turnover |

A token identity is the activation's tuple of participating fact IDs. The 32-bit [token hash](rete-network.md#token) is a pre-filter: an entry matches only when both its hash and its fact-ID tuple match (`refract_identity_match`). An activation selected whose identity has an entry in the current generation's table is discarded unfired. A firing enters its token identity in the table at the current generation. A clock-driven match, a token joining `$ClockTick` for a time-dependent test, is formed again with a new token on every tick; a re-formed activation for a fact in the edge-once set is suppressed. An upserted fact takes a new ID, which the set does not hold.

A fired match stays refracted until its activation is re-created: its token re-asserted under a new wrapper, retracted, released by a negated condition of its rule, or ended by a time-dependent test that went false and made again when the test goes true. Nothing else releases it: not an unrelated assert or retract, not a pump boundary, and not a clock tick under which its match persists. A generation's turnover leaves every table entry stale and releases no match. A match blocked and released within one pump is re-created and may fire again.

The table is an open-addressing array of (token hash, generation, fact-ID tuple) entries, probed linearly; an entry stamped with an earlier generation counts as empty, so a turnover empties the table in O(1) without visiting it. The edge-once set is an [`oa`](rete-network.md#oa) set keyed by fact ID.

*(Spec: [IRET.11], [IRET.11.3], [IRET.11.3.1], [IRET.11.3.2], [IRET.11.3.3], [IRET.11.3.5], [IRET.23.4])*

### Firing loop

`ds_rete_run(engine, max_fires, fires_out)` fires activations until the agenda drains or `max_fires` is reached.

1. Pop the next activation; discard it if refracted.
2. Call the `before_fire` hook.
3. Evaluate the activation's RHS actions in order.
4. Call the `after_fire` hook.
5. Enter the token identity in the terminal's refraction table.
6. Increment `fires_out`.

It returns `DS_OK` when the agenda drains and `DS_ERR_BUDGET_EXCEEDED` when `max_fires` stops it. A `max_fires` of 0 is unlimited, and `ds_engine_pump` runs `ds_rete_run(engine, 0, NULL)`. `ds_rete_run` does not [tick](rete-network.md#ttl-sweep-and-tick).

*(Spec: [IRET.11.4], [IRET.11.5], Source: runtime/src/libds/rete/engine.c)*

### Rule-fire events

Before and after each activation fires, the engine emits `DS_EV_RULE_FIRE_BEGIN` and `DS_EV_RULE_FIRE_END` carrying the rule name.

`ds_recorder_emit_rule_fire_begin` and `ds_recorder_emit_rule_fire_end` emit them, and the recorder's before and after machinery consumes them. There is no separate firing-token hook.

*(Spec: [IRET.1.13])*

## Actions

### Action list

A terminal's RHS actions are evaluated in order when its activation fires; each is an expression whose builtin calls carry its side effects.

| Action | At fire time |
|---|---|
| `ACTION_ASSERT` | builds a `ds_rete_fact_t` from the schema ID and its `(slot_index, expr)` pairs and calls `ds_rete_wm_assert` |
| `ACTION_LOGICAL_ASSERT` | the same, and records a [justification](truth-maintenance.md#justification) under the current activation |
| a `CallExpr` action | dispatches to its builtin |
| `ACTION_WITHDRAW` | retracts the fact at `withdraw_pattern_index` in the token |
| `ACTION_WITHDRAW_BY_ID` | retracts the live fact a reference in the capture fact names, by `withdraw_fact_id` |

A withdrawal is an engine retraction: the fact leaves working memory, the retraction propagates as any other does, and the stream records it as a `FactWithdraw` with cause `AUTHOR_WITHDRAWN`. A withdrawal whose fact has left working memory does nothing, and the firing continues with its next action. `ACTION_WITHDRAW_BY_ID` serves a `withdraw` in a nested body, whose synthetic sibling rule's token does not hold the fact: the compiler adds one fact-reference slot to the capture fact per withdrawn binding. A fact ID is never reused, so a reference to a fact that has left working memory names nothing.

The loader checks each `Action.kind` against the kinds the engine executes and refuses an artefact carrying any other with `DS_ERR_DSC_SEMANTIC`.

*(Spec: [IRET.10], [IRET.10.1], [IRET.10.2], [IRET.10.3], [IRET.10.5], [IRET.10.6], [IRET.10.7], Source: runtime/src/libds/rete/action.h)*

### Fire guard

A terminal's optional `fire_guard` is evaluated before its action loop; `false` skips every action.

A rule's cooldown is its fire guard's rate gate, a call to `DS_FN_RATE_ALLOW` with a tracker name, the activation key's components and the window in nanoseconds, always last. The builtin keeps per-engine state keyed by `(name, activation_key)`: the last firing's time. It allows when `now_ns - last_fire_ns >= cooldown_ns`, and on allowing sets `last_fire_ns = now_ns`. A `call`'s own cooldown is an inline `FN_RATE_ALLOW` gate inside its `ACTION_CALL` expression, tracked per call site and key; when the window has not elapsed, the gate suppresses the call.

*(Spec: [IRET.10.4], [IRET.16.6], [IDSP.6.8], Source: runtime/src/libds/rete/terminal.h, runtime/src/libds/builtin_fn.h)*

### Action-verb dispatch

Each RHS verb invokes its dispatcher operation directly, with no interpretation step.

| Verb | Reaches the terminal as | Dispatcher operation | Operands |
|---|---|---|---|
| `emit` | `ACTION_ASSERT`, `ACTION_LOGICAL_ASSERT` | assert into working memory | schema, slots, logical flag, token |
| `publish` | `FN_PUBLISH` | publish | schema, slots |
| `call` | `FN_CALL` | issue a call | service, correlation, typed arguments, `cooldown_ns` |
| `cache` | `FN_CACHE_SET` | cache set | key, `value_json`, `ttl_ns` |
| `cache_delete` | `FN_CACHE_DELETE` | cache delete | key |
| `log` | `FN_LOG` | log | level, rule name, message |

A logical `emit` passes the firing activation's token as the justifier.

*(Spec: [IRET.27.5])*

### Builtin dispatch

A CALL node carries a numeric `BuiltinFn` op, and dispatch is an O(1) index into the global `ds_builtin_dispatch[]` by that op, through `ds_lookup_fn`.

The table is shared by every engine, zero-initialised, and filled once, idempotently, at engine init by the module register functions; a duplicate registration of one op is first-registrant-wins. An artefact holding an op with no handler is refused at load ([Builtin calls](../artefacts/dsc-format.md#builtin-calls)). Every builtin is libds's own. The op registry is `enum BuiltinFn` (`proto/builtin_fn.proto`, mirrored as `DS_FN_*` in `builtin_fn.h`): an op is assigned once and never reused, and a reserved op has no handler and is never emitted.

| Op group | Registered in |
|---|---|
| action verbs and the rate gate | `rete/adapters.c` |
| math, rounding, bitwise, distances, regex, `Json` path, string length, `now` | `builtins.c` |
| series reads | `engine_rete_adapters.c` |
| string, time and `Json` adapters | `rete/adapters.c` |

The builtin signature is `ds_fn_t`.

*(Spec: [IRET.13], [IRET.13.1], [IRET.13.2], Source: runtime/src/libds/fn.h)*

## Dispatcher

### Verb adapters

Each action verb is routed by one adapter, `bridge_<verb>`.

`ds_engine_wire_rete_adapters` installs the bridges into the engine's `ds_rete_adapter_config_t` through `ds_rete_register_adapters`. The integrator's callbacks live in the per-engine `ds_dispatcher_state_t`, and each bridge reads its own. The Rete evaluator hands a bridge its arguments as typed values in a request struct, such as `ds_rete_call_request_t { service, correlation, args, arg_count }`, which the bridge forwards as typed parameters. There is no trampoline and no decode by index: the `Action` the compiler emits fixes the arity and types, and dispatch does not re-validate them.

*(Spec: [IDSP.1.1], [IDSP.1.2])*

### Action events

A verb's `DS_EV_ACTION_*` event is emitted once the engine's own part of the verb has succeeded (its arguments evaluated, its write applied) and before any integrator callback the verb invokes.

A verb that fails in the engine emits no action event. A callback's failure, or its absence, never decides whether the event is emitted. Stream order is the [delivery points](../overview/runtime-architecture.md#delivery-points).

*(Spec: [IDSP.1.4], [IDSP.10.1])*

### Verb errors

A verb's failure is stashed on the engine's pending slot, not returned up the evaluation stack.

The evaluator discards an action's result value. A failing essential verb, or an essential verb with no callback registered, stashes its error with `ds_engine_set_pending`; `ds_engine_pump` drains it with `ds_engine_take_pending` after `ds_rete_run` and returns the first error. `log` stashes nothing. A verb's missing callback is a silent drop unless the verb is essential. A verb that calls back into libds, as `emit` calls `ds_engine_assert`, saves and restores the pending slot around the call, so the first error among sibling actions is the one kept.

*(Spec: [IDSP.1.3], [IDSP.1.5], [IDSP.1.6])*

### log

`ds_dispatcher_log(engine, level, rule_name, message)` emits `ACTION_LOG`, then passes the `ds_log_event_t` to `ds_telemetry_emit_log`.

The level is one of DEBUG, INFO, WARNING, ERROR and CRITICAL; any other value is `DS_ERR_INVAL` and emits no event. The category and message pass verbatim. A missing log callback is a silent drop, and a failing one leaves the pump `DS_OK`.

*(Spec: [IDSP.2.2], [IDSP.2.3], [IDSP.2.4])*

### emit

`emit` looks the schema up in the engine's schema registry, checks the slot arguments against it and calls `ds_engine_assert`.

| Failure | Status |
|---|---|
| unknown schema | `DS_ERR_SCHEMA_UNKNOWN` |
| slot-argument count differs from the schema's | `DS_ERR_INVAL` |
| wrong slot-argument type | `DS_ERR_SLOT_TYPE_MISMATCH` |
| `Json` parse failure | `DS_ERR_PARSE` |
| schema-reference slot | `DS_ERR_UNSUPPORTED` |

`Json` trees parsed for the arguments are freed after the assert, which copies them. Within the firing, the assert's `FACT_ASSERT` precedes an `ACTION_EMIT` carrying the same fact wrapper, from `ds_recorder_emit_action_emit`:

```text
RULE_FIRE_BEGIN
FACT_ASSERT
ACTION_EMIT
RULE_FIRE_END
```

*(Spec: [IDSP.3.2], [IDSP.3.3], [IDSP.3.4], [IDSP.3.5])*

### publish

`publish` takes `emit`'s arguments and puts nothing in working memory. Once the values are judged, it records `ACTION_PUBLISH` through `ds_recorder_emit_action_publish`, carrying a view of the published fact and its `FactExternal` encoding.

A publish emits no `FACT_ASSERT` and no `ACTION_EMIT`. Cross-tier subscribers forward on `ACTION_PUBLISH`.

```text
RULE_FIRE_BEGIN
ACTION_PUBLISH
RULE_FIRE_END
```

*(Spec: [IDSP.4.2], [IDSP.4.4], [IDSP.4.5], [IDSP.4.6], [LTIE.4.3], [LTIE.4.8])*

### call

`ds_dispatcher_call(engine, service, correlation, args, arg_count, cooldown_ns)` issues a call.

| Argument | Holds |
|---|---|
| `service` | the `domain.method` of the lowered `call` |
| `correlation` | the call's `as` value, or the value generated for a call with none; never `null` or empty; it flows verbatim to the answer's `corr` slot |
| `args` | one typed argument per supplied kwarg, sorted by name; a fact argument is encoded as `FactExternal` |

1. A NaN `Float` argument refuses the call with `DS_ERR_NAN_REJECTED`.
2. The call supersedes its earlier answers.
3. Emit `ACTION_CALL` with the request payload.
4. In a replay, stop: no callback is invoked, and a missing one raises no error.
5. Look up the call callback; none is `DS_ERR_STORAGE_UNAVAILABLE`.
6. Invoke it with a `ds_call_request_t { service, correlation, args, arg_count }`.
7. Propagate a callback error verbatim.

An argument that fails to evaluate, or is refused, emits no event. The dispatcher allocates no correlation, keeps no per-call deadline and no in-flight table, and synthesises no response fact or `CallError`: the integrator asserts those.

*(Spec: [IDSP.6.1], [IDSP.6.2], [IDSP.6.3], [IDSP.6.4], [IDSP.6.5], [IDSP.6.6], [IDSP.6.7])*

### cache

The engine owns the cache: a `cached(key)` read is answered from its own map, and `cache` and `cache_delete` mutate the map and then call the optional write-through persistence callbacks.

| Verb | Arguments | Effect |
|---|---|---|
| read | key (`String`) | the stored JSON text on a hit; `null` on a miss |
| `cache` | key (`String`), value (`String`, JSON text), `ttl_ns` (`Int` ≥ 0; 0 is no expiry) | stores, emits `ACTION_CACHE_SET { key, value, ttl_ns }`, then calls the set callback |
| `cache_delete` | key (`String`) | removes, emits `ACTION_CACHE_DELETE { key }`, then calls the delete callback |

A read invokes no callback and emits no event. A missing persistence callback is not an error: the write lands in the cache unpersisted. A persistence callback's error propagates verbatim, and the cache keeps the write. A TTL expiry calls the delete callback and emits no stream event. A wrong argument count or type, or a negative `ttl_ns`, is `DS_ERR_INVAL`; bad JSON in a value is `DS_ERR_PARSE`. The set callback borrows the value for its duration.

*(Spec: [IDSP.7.2], [IDSP.7.3], [IDSP.7.4], [IDSP.7.5], [IDSP.7.6], [IDSP.7.7], [IDSP.7.8], [IDSP.7.9], [IDSP.11.2], [IDSP.11.4])*

### FN_JSON_VALUE

`FN_JSON_VALUE(value)` returns a `String` holding its argument's JSON text; the compiler wraps every `cache` value in it.

| DS value | JSON text |
|---|---|
| `null` | `null` |
| `Int` | a JSON number, decimal |
| finite `Float` | a JSON number, in the canonical `Float` form |
| `Bool` | `true` or `false` |
| `String` | a JSON string: `"` and `\` escaped, `\n` `\r` `\t` for those three, `\u00XX` for any other character below U+0020, every other character as itself |
| `Time` | a JSON number, UTC nanoseconds since the Unix epoch |
| `Date` | a JSON number, days since 1970-01-01 |
| `Duration` | a JSON number, nanoseconds |
| `Json` | the document's JSON text |

A non-finite `Float`, a `Bytes` value, a fact reference and a `Ratio` have no JSON form: each raises a `ComputationError` of kind `NOT_REPRESENTABLE` and abandons the activation, so the write does not happen. A call with no argument is `ENGINE_FAULT_ARTEFACT_LIED`, and an allocation failure while building the text is `ENGINE_FAULT_ALLOCATION`; both halt the tier.

*(Spec: [IDSP.13.2], [IDSP.13.3], [IDSP.13.4], [IDSP.13.5], [IDSP.13.6])*
