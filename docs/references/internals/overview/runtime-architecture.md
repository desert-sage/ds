<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Runtime architecture

## Tiers

### Tier instance

A tier instance is one engine with its own Rete network, working memory, clock source, consumption loop, stream and dispatcher.

The network runs the rule set compiled for the tier's dialect, and a rule file compiles against the settings of the tier it targets. The runtime commits to no tier count or topology: the integrator creates one engine per tier and bridges them. Tier instances share one process or run in separate processes, with integrator-supplied transport between them.

*(Spec: [RARC.1.2], [RARC.2.1], [RARC.3.1], [RARC.3.2], [RARC.3.6.4], [RARC.13.1])*

### Runtime and integrator division

The runtime provides the per-tier mechanism: an engine, its working memory, clock, dispatcher, stream and callback table.

Cross-tier transport, storage-backend wiring and debugger plumbing are the integrator's, built on the typed callbacks. The runtime ships no storage backend: the cache is engine state, and the integrator persists it through the optional cache callbacks. A debugger bridge is built on the stream callback.

*(Spec: [RARC.1.7], [RARC.2.3], [RARC.11.6], [RARC.13.15])*

### Cross-tier fact flow

Facts cross tiers upward only, through the integrator.

`emit` stays within its engine. `publish` reaches the stream as an `action_publish` event, and the integrator asserts the fact into the upper tier's engine, by a direct assert in one process or over a transport it encodes between processes. What crosses is a schema name and slot values: the receiving tier's schema decides the fact's lifecycle and TTL, and truth maintenance does not cross. Downward effects go through `call`; there is no downward fact path. The runtime does not enforce cross-tier semantics.

A tier sees the facts emitted into its own working memory, the publishes bridged from lower tiers, call responses and cache reads. It does not see facts local to sibling or higher tiers. A tier whose settings make `call` false reaches no storage service; one whose settings make `cache` or `cache_delete` false cannot write the cache; every tier reads its cache.

*(Spec: [RARC.2.2], [RARC.3.3], [RARC.3.5], [RARC.6.1.2], [RARC.6.1.3], [RARC.13.4], [RARC.13.5], [LTIE.5.2])*

### Process boundaries

The integrator places process boundaries per tier.

Tiers are co-located in one process when an upper tier consumes a lower tier's emits within the lower tier's own cycle. They are split into separate processes when the upper tier serves several lower hosts, when its horizon is much longer than the lower tier's cycle, or when independent restart is required.

*(Spec: [RARC.2.4], [RARC.13.2])*

### Pacing

The integrator chooses each tier's pump cadence.

| Pattern | Pump trigger |
|---|---|
| Input-driven | each input, after moving the clock |
| Cycle-paced | once per fixed period, after asserting the inputs accumulated in it |
| Event-driven | each input, and a timer of the integrator's |

All three use the same engine operations.

*(Spec: [RARC.3.4])*

## Engine

### Engine

An engine is the network compiled from one rule set, with its clock source, working memory, agenda, dispatcher and consumption loop.

The integrator drives it through public calls: assert, retract, the clock operations and pump. Each call is processed serially to completion before it returns. The engine has no thread, queue or loop of its own. Everything observable reaches the integrator through the stream callback and the typed callbacks for the dispatched actions.

*(Spec: [RARC.5.1], [RARC.13.7])*

### Working memory

Working memory holds every fact asserted into an engine, as fact records over the schema.

It is read and written only inside the public call being processed, including from RHS action code running inside a firing.

*(Spec: [RARC.5.2.1])*

### Fact identity

A fact's identity is its schema and its identity key.

Two facts are equal when all their slot values compare equal. The engine suppresses a no-op reassertion of a fact of a `logical` schema, and of no other. Facts of a `ttl` schema accumulate: two equal asserts are two live facts, each with its own expiry. The suppression does not reach the recorder: a no-op reassertion is still recorded as a `FactAssert`.

*(Spec: [RARC.5.2.3], [IDAT.4.3], [IARC.3.3.2])*

### TTL expiry

A `ttl` fact whose deadline is at or before the engine clock's monotonic sample is expired.

A pump retracts every expired `ttl` fact at its entry, before anything fires. An assert, a retract or a clock move retracts nothing: an assert made after a fact's deadline joins against that fact until the next pump retracts it. Each retraction reaches the stream with its own `seq`, and the logical retractions it causes cascade through truth maintenance.

*(Spec: [RARC.5.2.4], [RARC.5.6.3], [RARC.7.15], [IARC.3.3.3])*

### Logical facts

A `logical` fact is retracted when its last justifying activation ends.

Justifiers coalesce: a fact asserted by two activations lives while at least one of them remains. Its assertion and retraction reach the stream as `fact_assert` and `fact_retract` events.

*(Spec: [RARC.5.2.5], [IARC.3.3.4])*

### Slot typing

No fact enters working memory carrying a slot value whose kind differs from the slot's declared type.

There is no implicit conversion. The invariant binds every path into working memory: a host assertion, a rule's `emit`, a published fact, a call's response fact and a replayed inject-class atom. A violation at a host call or in a replayed atom is `DS_ERR_SLOT_TYPE_MISMATCH`.

A rule activation that would put into a slot a value of a kind its declared type does not accept, `null` into a slot not declared `T?`, or a NaN into any slot raises a `TypeError` naming the schema and the slot, and the activation is abandoned. The fact does not enter working memory, a `publish` sends nothing, and the pump returns no error: the fault is the stream event and the `TypeError` fault fact. A `Json` value whose root is `null` is stored as `null` in a `Json?` slot and refused for a `Json` slot. The compiler refuses the program wherever it proves the mismatch from the declared types.

*(Spec: [RARC.5.2.6], [RARC.5.2.7], [LTIE.4.8])*

### Rete network

The network is built from the compiled rule set and is the runtime's own code.

Its firing order is deterministic. The introspection queries expose its topology, live node occupancy and a fact's match trace in DS-level names (rule, schema and slot names); the introspection layer translates from the network's internal representation. An expression that reads a pattern position the match never bound is an unrecoverable fault, and the engine halts the tier.

*(Spec: [RARC.5.3])*

### Agenda and conflict resolver

The agenda is the list of matched activations not yet fired; the conflict resolver picks the next one to fire.

The comparator orders activations by terminal ordinal, then creation timetag:

1. The terminal ordinal is the rule's zero-based index in the artefact's terminal sequence, which is canonical source order: earlier in its source file first, and across files import-DAG topological, leaf libraries first. It is unique per rule.
2. The creation timetag is stamped when a match completes, monotone in completion order. It orders activations of one rule and never decides between two rules.

Refraction is not a key: the comparator never weighs whether an activation fired, and an activation whose (rule, token) identity has already fired is suppressed when it is selected. A rule may match a fact another rule of the same tier emits. Internal data structures for the agenda are permitted when the observable firing order is unchanged; hash-order dependence is forbidden.

The pair (ordinal, timetag) is unique in a correct runtime. A runtime that finds a duplicate halts the tier, and breaks the tie by no other means.

*(Spec: [RARC.5.4], [RARC.5.4.7], [RARC.13.6], [RARC.13.11], [IARC.3.4.1], [IRET.11.3.1])*

### Clock source

Each engine has one clock source, shared with no other engine.

In live mode it reads the host's monotonic clock and its UTC wall clock, one sample of each per step. In test and replay mode it returns what the harness or the recording sets. Every time value the engine computes with comes from it: `now()`, fact timestamps, TTL and timer deadlines, and the clock tick. A test drives the clock through the mock clock; there is no separate tick generator, and a mock mutation is recorded at the next sample, when an input or a pump takes one.

*(Spec: [RARC.5.5.1], [RARC.5.5.2], [RARC.5.5.3], [RARC.13.10], [RARC.14.4], [IARC.3.11.1])*

### Clock tick

Each pump retracts and re-asserts the synthetic fact `$ClockTick` once, after its TTL sweep and before its agenda runs.

The network's re-evaluation then re-fires time-bound tests at the pump's instant. The tick has no interval of its own: a time-bound test's resolution is the integrator's pump interval, and a condition that becomes true between two pumps is seen at the next one.

*(Spec: [RARC.5.5.4], [RARC.13.10])*

### Consumption loop

The consumption loop is the processing an engine performs inside one public call: an assert, a retract, a clock move or a pump.

It is the engine's single writer: every change to working memory happens inside it. It runs on the caller's thread and finishes before the call returns. Across an input and the pump that follows it, the loop:

1. takes the input the call carries: a fact to assert or retract, or a new clock value;
2. samples both clocks; a pump then retracts the expired `ttl` facts;
3. applies the event to working memory;
4. hands the change to the network, which propagates it through the alpha and beta memories and updates the agenda;
5. during a pump, fires activations one at a time until the agenda is empty, each firing reaching the stream as rule-fire events;
6. runs each RHS action in the order the artefact declares: `emit` and `withdraw` change working memory directly, and every other verb goes through the dispatcher;
7. delivers the input's event and every derived event to the stream callback in the order they were processed.

Each RHS action's change is propagated through the network, truth-maintenance retractions included, before the change is recorded and before the next action runs. A cascade retraction a rule's `emit` causes is therefore recorded ahead of that action, and a firing that emits twice, where only the second emit invalidates a `no (...)`, records the retraction between its two asserts: for a rule's action, stream order is processing order, not causal order. A host input is recorded on arrival, before what its evaluation produces ([Arriving inputs](../artefacts/fact-stream.md#arriving-inputs)), and an engine withdrawal before the withdrawals it cascades into ([FactWithdraw](../artefacts/fact-stream.md#factwithdraw)). Facts an action asserts re-enter the same path. The loop is strictly serial, and `seq` is assigned as each event is produced.

A read that reaches a binding before the action establishing it has run is an unrecoverable fault, and the engine halts the tier.

*(Spec: [RARC.5.6.1]–[RARC.5.6.9], [RARC.5.6.11], [RARC.7.1], [RARC.13.9], [IARC.3.2.1])*

### Replay inputs

A deterministic consumption loop and agreeing ambient inputs give a byte-identical replay.

Ambient inputs are every input to the record that the loop does not compute, among them the clock origin and the identity assigned to an event. The engine takes no ambient input from outside the run where the run supplies it: a mock clock starts at a fixed origin, and an event's identity is derived from the run.

*(Spec: [RARC.5.6.10])*

### Dispatcher

The dispatcher routes every RHS action other than `emit` and `withdraw`, and is the engine's only outbound writer.

| Action | Destination |
|---|---|
| `call` | the integrator's call callback |
| `publish` | the stream callback, as an `action_publish` event |
| `cache`, `cache_delete` | the integrator's cache callbacks |
| `log` | the integrator's log callback |

No action calls integrator code by any other path. Every dispatched action reaches the stream before it leaves the engine, as an `action_call`, `action_publish`, `action_cache_set`, `action_cache_delete` or `action_log` event. A `cached(...)` read is not dispatched: it is a read of the engine's cache, invokes no callback, reaches no stream and is no replay input.

*(Spec: [RARC.5.7.1], [RARC.5.7.2], [RARC.5.7.9], [RARC.13.12])*

### Dispatcher components

The dispatcher has one component per routed action.

| Component | Behaviour |
|---|---|
| Call | Invokes the call callback with the service, the correlation, the arguments and the identity of the issuing firing. The correlation is the call's `as` value or the one the compiler generated. Allocates no correlation and keeps no deadline. |
| Publish | Puts nothing in working memory, and delivers an `ACTION_PUBLISH` event carrying a view of the fact and its `FactExternal` encoding. |
| Cache-op | Routes `cache` and `cache_delete` to the optional write-through persistence callbacks. A `cached(...)` read is served from the in-engine map at RHS entry. |
| Log | Delivers the interpolated string to the log callback. The stream carries the string verbatim. |

*(Spec: [RARC.5.7.3]–[RARC.5.7.8], [LTIE.4.3], [IDSP.4.4])*

### Stream delivery

Every event-producing path in the engine delivers its event to the stream callback through a hook site.

The engine writes no recording of its own; a recording is what the integrator keeps of the stream. The consumption loop is the only writer to an engine's stream, in `seq` order. Each `StreamEvent` field number corresponds to exactly one hook site, and there is no generic emit API. Delivery is lossless: no sampling and no per-kind suppression. Wherever an event is encoded in the fact-stream format, the same event on the same platform encodes to the same bytes.

Every event reaches the stream callback before it becomes observable any other way: before an in-language fact it produces is asserted, and before the typed callback for it runs. All of a call's events are handed over before the call returns, and none is held past the return. The engine has no buffer to overflow: a sink slower than the engine slows the engine. Separate engines' streams share no order, clock or counter.

*(Spec: [RARC.1.8], [RARC.5.8.1]–[RARC.5.8.6], [RARC.5.8.9], [RARC.13.8], [RARC.14.2], [RARC.14.3])*

### Delivery modes

A runtime delivers a call's events in one of two ways.

| Mode | Delivery | A slow sink |
|---|---|---|
| Synchronous | Each hook site hands its event to the stream callback from inside the consumption loop, on the caller's stack. The engine holds no queue. | Blocks the consumption loop mid-pump. The block is metered under `ds.recorder`. |
| Returned effect list | The call returns its events and actions as one ordered list, and the integrator's shell hands each to its callback in order. Nothing reaches the integrator before the call returns. | Throttles the engine only between calls. |

The order the integrator sees is the same in both. Buffering, batching and onward flushing are the integrator's.

*(Spec: [RARC.5.8.7], [RARC.6.5.1])*

### Delivery points

Each class of event is delivered at a fixed point of the consumption loop.

| Class | Delivered |
|---|---|
| Inputs (`fact_assert`, `fact_retract`) | at step 1, after `seq` assignment and after the `tick` of the sample taken for the input. A call's response fact and a `CallError` arrive as `fact_assert`. |
| Engine internals | inline at the generating site: `pump` at a pump's entry; `rule_fire_begin`, `rule_lhs_facts` and `rule_fire_end` around each firing; a truth-maintenance retraction or TTL expiry as `fact_retract`; `timer_armed` where a timer is armed; `type_error`, `bounds_error`, `engine_error` and `computation_error` at the fault site |
| Actions (`action_emit`, `action_call`, `action_publish`, `action_cache_set`, `action_cache_delete`, `action_log`) | before the typed callback for the action runs. A failing or unregistered callback leaves the event delivered; a failure reaches the caller as the returned status. |

*(Spec: [RARC.5.8.10], [RARC.5.8.11], [RARC.5.8.12])*

### Event identity

A fact's `event_id` is a UUID derived from the run identifier, the tier identifier and the `seq` of the fact's `FactAssert`.

Distinct keys derive distinct `event_id`s, and all three inputs reproduce on replay. The `event_id` identifies a fact within one engine: a fact received from another tier gets the receiving engine's own.

*(Spec: [RARC.5.8.8])*

### Recording failure

A recording failure reported by the stream callback does not halt the tier.

The consumption loop continues, and the public call that fired the callback returns the status.

*(Spec: [RARC.5.8.13])*

## Threading

### Threading model

An engine runs each call on the thread that makes it and owns no thread.

Calls on one engine do not overlap: the engine takes no lock, and the integrator serialises the calls it makes on one engine. Calls on different engines run at the same time. Correlation across sibling engines flows through an upstream engine, in the order its integrator asserts the bridged facts. All I/O (ingest, cross-tier bridging, storage access, debugger and observability sinks) runs on the integrator's threads. The engine holds no queue between engines and applies no back-pressure between tiers.

Within one engine, activations fire one at a time and a firing's actions run in declared order. A runtime overlaps work only where [LDET.6.5] admits it, and produces the stream the serial order produces.

| Thread | What runs on it |
|---|---|
| The thread calling an engine | That call, start to finish, and every callback it makes. One call at a time per engine. |
| The integrator's other threads | I/O, bridging between engines, and whatever drives the clock |

```{warning}
Two concurrent calls on one engine are undefined behaviour. Nothing detects them.
```

*(Spec: [RARC.6.1], [RARC.6.2], [RARC.6.3], [RARC.6.4], [RARC.6.6], [RARC.13.13], [RARC.14.8], [IARC.3.2.2])*

### Re-entrancy

The engine is not re-entrant.

Inside a callback an engine invoked, every `ds_engine_*` call on that engine returns `DS_ERR_STATE`, reads included. The same holds inside the visitor callback of an enumerating read (of working memory, of the network's nodes and edges, of a match trace, of refracted activations). A call on a different engine is unaffected.

The engine core is a pure function of its inputs over four observables: the return value, the effect list, the event stream delivered to callbacks and any `ds_engine_*` read. Its mutation is unobservable through those four. Timing is excluded. With every mid-pump call refused, a pump's cycle, with callbacks run between its steps, reaches the working memory and event sequence of a single step computed from the engine state and the queued inputs, in every interleaving. Two premises are the integrator's and the host's: single-writer exclusion, and weak fairness in the scheduler for a call's eventual return.

*(Spec: [RARC.13.16], [RARC.13.17])*

## Compilation and rule sets

### Compilation model

The compiler is a separate tool that turns rule source files and the libraries they import into a compiled `.dsc` artefact before the engine runs.

The integrator runs it and loads its output into an engine, which builds its network from it. The engine never invokes the compiler, and nothing at runtime changes the compiled rule set. The artefact carries the schema metadata (definitions, lifecycle category, TTL defaults), the service set with argument and response shapes, and sidecar metadata (rule names, source locations, schema information).

*(Spec: [RARC.2.5], [RARC.9.1], [RARC.11.3], [RARC.13.3])*

### Compile-time inputs

The compiler requires three inputs when it runs.

| Input | Requirement |
|---|---|
| Dialect | The dialect a rule file declares with `use` is registered at compiler startup, from the built-in dialects and the integrator's definitions. |
| Schemas | `schema` blocks in rule files are parsed as part of the compilation unit. |
| Services | Service declarations are reached by `import`. The compiler resolves each `call <service>` against the declared set and builds the dispatch table. A `call` to a service not in scope fails with `DS_VALIDATE_UNKNOWN_SERVICE`. |

There is no second service manifest. The service set is fixed at compile time and travels in the `.dsc`; at runtime the engine binds it to the per-service callbacks the integrator registers. There is no handshake: an unregistered callback fails the call and does not change the set.

*(Spec: [RARC.9.2], [RARC.9.3], [RARC.9.4.1], [RARC.9.4.2])*

### Failure detection

Each configuration failure is detected at a fixed stage.

| Failure | Detected | Behaviour |
|---|---|---|
| Undeclared dialect in a rule file | compile | compile error listing the dialects |
| Form unknown to the dialect | compile | compile error |
| Call to an undeclared service | compile | compile error |
| Call to a declared service with no registered callback | runtime | fails at dispatch; there is no startup check |
| Persistence callback failure | runtime | the non-OK result reaches the integrator verbatim; the write stays in the cache |

*(Spec: [RARC.9.5.3], [RARC.9.6])*

### Changing the rule set

An engine runs the artefact it was created with for its whole life.

To change the rule set, the integrator frees the engine and creates a new one from the new `.dsc`. The new engine's stream is a new session with the new `ruleset_hash`, and the new engine inherits nothing from the old one. Nothing preserves activations. A call pending when its engine is freed is cancelled by nothing: the engine tracks no pending call and synthesises no `CallError`.

*(Spec: [RARC.10.1], [RARC.10.8], [RARC.13.14])*

### Synthetic identifiers

A synthetic identifier is `$` followed by a name, such as `$ClockTick`.

Synthetic names belong to the compiler and the engine: compiler-generated facts, rules and series, and engine-internal facts. `$` is not a `NAME` character, so no source text writes one and no author name collides with one. The compiler passes synthetic names through lowering unchanged. A synthetic schema carries no `.proto` text.

*(Spec: [RARC.12])*

### Test harness

The test harness drives an engine through the same public surface as any integrator.

It asserts a synthetic event trace directly, mocks the integrator callbacks to inspect what the engine emits, and controls the clock through the mock-clock surface.

*(Spec: [RARC.11.5])*
