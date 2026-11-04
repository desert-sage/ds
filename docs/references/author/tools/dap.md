<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# `ds dap`

## Adapter

### Command

**`ds dap [-L DIR]...`**

`ds dap` is a debug adapter on stdin and stdout, for an editor.

`-L DIR`, or `--search-path DIR`, adds a library directory to every compile, after the launch's own `libs`. Accumulates. `-h` prints the usage.

| Exit status | When |
|---|---|
| `0` | the client sent `disconnect` |
| `1` | the input ended without a `disconnect`, or held bytes that are not DAP messages |
| `2` | the command line is refused |

*(Spec: [NDBG.9.1.2], [NDBG.9.3.8], Source: tools/dsdb/lib/cli/main.js, tools/dsdb/lib/dap/server.js)*

### Protocol

The protocol is the Debug Adapter Protocol, JSON over stdio, one session per process, on an engine of the adapter's own.

DS-specific surface is custom requests and events named `ds/`. A request is answered in order, and the session is never running when one arrives.

A refused request has `success` false and its message, in `message` and `body.error.format`.

*(Spec: [NDBG.6.1], [NDBG.9.1.1], [NDBG.9.1.2], [NDBG.9.1.3], Source: tools/dsdb/lib/dap/server.js)*

### Ids

| Thing | Form | Example |
|---|---|---|
| a fact | `#` and the engine's fact id, in decimal | `#42` |
| a firing | `!` and its number in the timeline | `!17` |
| a timeline | `%0` for the real run, `%N` for the Nth fork opened | `%1` |

A request accepts the same forms.

*(Spec: [NDBG.9.3.5])*

### Capabilities

**`initialize`**

The `initialize` response declares the adapter's capabilities, and `initialized` follows it.

| Capability | Value |
|---|---|
| `supportsConfigurationDoneRequest` | `true` |
| `supportsStepBack` | `true` |
| `supportsRestartRequest` | `true` |
| `supportsGotoTargetsRequest` | `true` |
| `supportsStepInTargetsRequest` | `true` |
| `exceptionBreakpointFilters` | [the three filters](#exception-breakpoints) |
| `supportsFunctionBreakpoints` | `true` |
| `supportsDataBreakpoints` | `false` |
| `supportsConditionalBreakpoints` | `true` |
| `supportsHitConditionalBreakpoints` | `true` |
| `supportsLogPoints` | `true` |
| `supportsRestartFrame` | `false` |
| `supportsSetVariable` | `false` |
| `supportsCompletionsRequest` | `false` |
| `supportsEvaluateForHovers` | `true` |
| `additionalModuleColumns` | `[]` |

`supportsStepBack` and `supportsGotoTargetsRequest` hold in replay and in a live session: a live run is recorded as it goes.

*(Spec: [NDBG.9.2.1], [NDBG.9.2.2], Source: tools/dsdb/lib/dap/server.js)*

## Session

### `launch`

**`launch`**

`launch` opens the session the arguments name.

| Argument | Meaning |
|---|---|
| `program` | the program, as a `.dsc` or as `.ds` source the adapter compiles; optional when `trace` embeds it |
| `libs` | library directories for a `.ds` program's imports |
| `trace` | a recorded fact stream; present, the session replays it, and absent, the session is live |
| `facts` | live only: [fact files](dsdb.md#fact-files) fed as inputs |
| `source` | the `.ds` source of a `.dsc` that carries no source spans |
| `events` | the [custom events](#custom-events) to send; absent, none |

Replay starts at the trace's start. `facts` with `trace`, and neither `program` nor `trace`, are refused.

A trace is put to the shell's [binding check](dsdb.md#binding-check) against the program. A mismatch refuses the launch with an error response whose body carries the `DS_ERR_BND_*` code.

*(Spec: [NDBG.9.3.1], [NDBG.14r.1.1], [NDBG.14r.6.5], Source: tools/dsdb/lib/dap/server.js, tools/dsdb/lib/dap/adapter.js)*

### `configurationDone`

**`configurationDone`**

After a `launch`, `configurationDone` is answered, then `stopped` goes out at the session's position, with `reason` `entry` when the session has not moved. Before a `launch`, it is refused.

*(Spec: [NDBG.9.3.7], Source: tools/dsdb/lib/dap/server.js)*

### `attach`

**`attach`**

`attach` is refused, and the message says to use `launch`.

*(Spec: [NDBG.9.1.3])*

### `restart`

**`restart`**

`restart` re-reads the program, the trace and the fact files, compiles a `.ds` program again, and starts the session over.

Breakpoints are kept and verified again, each reported by a `breakpoint` event. Every fork is dropped.

*(Spec: [NDBG.9.3.2], Source: tools/dsdb/lib/dap/server.js)*

### `disconnect`

**`disconnect`**

`disconnect` frees the engine and every timeline, and the adapter exits.

*(Spec: [NDBG.9.3.2])*

### Engine trap

If the engine traps, the adapter sends an `output` event of category `important` naming the fault, then `terminated`, and does not restart the session.

Variable references, thread ids and breakpoint ids are then invalid.

*(Spec: [NDBG.9.3.3])*

### Pause state

While paused, the adapter feeds the engine nothing and runs no pump, and the clock moves only by [`ds/advanceClock`](#dsadvanceclock).

A breakpoint set then takes effect from the following step. Variable references hold until the following move.

*(Spec: [NDBG.9.3.4])*

### Program output

Each time the session crosses a firing's `log` action moving forward, live or in replay, the line goes out as an `output` event of category `stdout`.

The line opens with the firing, the instant and the action's level. None goes out moving back. The `events` argument and `ds/streamEvents` do not choose these events. A firing's lines go out once the move has crossed its every action.

*(Spec: [NDBG.9.3.6], Source: tools/dsdb/lib/dap/adapter.js)*

## Threads and frames

### `threads`

**`threads`**

`threads` lists the firings at the stop. A thread is a rule firing.

- In replay: the firing at the current position, focused, and the later firings of the same pump, each labelled as still to fire in this pump.
- In a live session: the firings of the pump that has run, with the firing a breakpoint stopped on focused. They exit at the following step.

Where no firing qualifies, one thread stands for the engine, named `engine at T=` and the position's clock in seconds to three places and `s`. It has one frame with no source, and `scopes` on it omits `Bindings`.

An activation cancelled before it fires is not a thread.

*(Spec: [NDBG.10.1.1], Source: tools/dsdb/lib/dap/adapter.js)*

### Thread ids and names

A firing keeps one thread id for the whole session, and a fork's firings get their own. A `thread` event with `reason` `started` or `exited` reports each change.

A thread's name fills the rule's `RuleDebugName` template with the firing's bound values, else is `{rule_name} !{N}`.

Every thread is stopped while the session is paused. The focused thread is the one `stopped` names.

*(Spec: [NDBG.10.1.2], [NDBG.10.1.3], [NDBG.10.1.4])*

### `stackTrace`

**`stackTrace`**

`stackTrace` gives a thread's frames, by `startFrame` and `levels`.

The focused thread has two frames, each `presentationHint` `normal`. Frame 0 is the action at the position, its `name` saying which (`emit Reading`). Frame 1 is the rule, at its `rule` line. In a `.dsc`, frame 0's source is the rule's.

Any other thread has one frame, `subtle`: the rule declaration, named by its display name.

*(Spec: [NDBG.10.2.1], [NDBG.10.2.2], Source: tools/dsdb/lib/dap/adapter.js)*

## Execution control

### Steps

| Request | Meaning |
|---|---|
| `next` | forward one step at the current granularity |
| `stepBack` | back one step at the current granularity |
| `stepIn` | in replay, to the first later firing whose match includes a fact the current action asserted, passing the firings between; `targetId` names another |
| `stepInTargets` | every firing the action caused, the earliest first |
| `stepOut` | in replay, until every firing the current firing caused within the pump, directly or transitively, has fired, then stops at the following firing |
| `continue` | forward to the nearest breakpoint |
| `reverseContinue` | back to the most recent breakpoint |
| `pause` | answered, then a `stopped` event with `reason` `pause` at the position, which does not move |

Behind the end of a live run, a forward step moves through the recorded run, and at its end the session carries on live.

In a live session, `stepIn` and `stepOut` behave as `next`. In replay, so does `stepIn` at an action that caused no firing. A breakpoint `stepIn` or `stepOut` reaches first stops it there.

DAP's `granularity` field is ignored.

*(Spec: [NDBG.11.1.1], [NDBG.11.1.2], [NDBG.11.1.3], [NDBG.11.1.4], [NDBG.11.2.1], [NDBG.14r.3.1], [NDBG.14r.4.1], Source: tools/dsdb/lib/dap/server.js)*

### `gotoTargets`

**`gotoTargets`**

`gotoTargets` gives the recorded instants of a line, at most the 1,000 nearest the position.

- A `rule` declaration: each firing of that rule.
- An `after` or `on response` line: each firing of that body.
- A `schema` declaration: each assert of a fact of that schema.

A target's label is `!N at T=X.XXXs`, or for an assert `#N at T=X.XXXs`.

*(Spec: [NDBG.14r.5.1])*

### `goto`

**`goto`**

`goto` moves the session to a target's instant, with `reason` `goto`.

*(Spec: [NDBG.14r.5.2], Source: tools/dsdb/lib/dap/server.js)*

### `ds/stepGranularity`

**`{ "granularity": "action" | "rule" | "pump" | "input" }`**

`ds/stepGranularity` sets the step granularity for the session.

| Value | Step | Mode |
|---|---|---|
| `action` | one action | replay only |
| `rule` | one whole firing | replay only |
| `pump` | one pump, to its settled point | both |
| `input` | to the following input the trace or the fact files feed | both |

`action` and `rule` are refused in a live session. The default is `action` in replay and `pump` live. On a change of mode, the granularity becomes the new mode's default unless the client set one the new mode admits.

A live step with no input left to feed leaves the session paused, and an `output` event says so.

*(Spec: [NDBG.14.1.1])*

### `ds/advanceClock`

**`{ "by": "5_s" }`**

At the end of a live run, `ds/advanceClock` moves the clock forward and pumps once, then stops with `reason` `step`.

`by` is a duration or a whole number of nanoseconds. In replay, and behind a live run's end, it is refused.

*(Spec: [NDBG.14.18.1])*

### `ds/loadRecording`

**`{ "path": "session.trace" }`**

`ds/loadRecording` loads a recorded fact stream mid-session, and the session replays it from its start.

The response carries `duration_ns`, `event_count`, `rule_count` and `schema_count`. The trace is put to the [binding check](#launch) as at `launch`. The session must have been launched with `program`. The granularity follows [`ds/stepGranularity`](#dsstepgranularity)'s rule for a change of mode.

*(Spec: [NDBG.14.2.1], [NDBG.14.2.2], Source: tools/dsdb/lib/dap/server.js)*

## Breakpoints

### `setBreakpoints`

**`setBreakpoints`**

`setBreakpoints` on a `.ds` file takes a breakpoint on a `rule` declaration, an `after` line or an `on response` line, stopping only in that rule's or that body's firings.

- In replay, it stops at the firing's record, before its first action.
- In a live session, it stops at the settled point after the pump, focused on the matching firing.

| Field | Meaning |
|---|---|
| `condition` | a DS expression over the firing's bound variables, as a `where` clause writes one, compiled at once |
| `hitCondition` | `5` is the 5th hit, `>= 3` from the 3rd on; hits count from the timeline's start |
| `logMessage` | a DS interpolation string (`level={r.level}`); an `output` event of category `important` in place of a stop, each time the session crosses the hit moving forward |

A logpoint's line opens with the firing and the instant.

| `verified: false` when | `message` |
|---|---|
| another line | `DS breakpoints must be on rule, after or on response lines, or use ds/setFactBreakpoints for fact-event breakpoints` |
| no source lines | `no source lines: give the program's .ds` |
| a condition or logpoint with no source | `needs the program's source` |
| a condition that does not compile | the compiler's detail |

*(Spec: [NDBG.12.1.1], [NDBG.12.1.2], [NDBG.12.1.3], [NDBG.12.1.4])*

### `setFunctionBreakpoints`

**`setFunctionBreakpoints`**

`setFunctionBreakpoints` treats a function name as a rule name, and stops as a breakpoint on its `rule` line does.

It needs no source lines. `condition`, `hitCondition` and `logMessage` hold as for [`setBreakpoints`](#setbreakpoints). An unknown name is `verified: false` with `no rule named 'X' in the loaded rule set`.

*(Spec: [NDBG.12.2.1], [NDBG.12.2.2], [NDBG.12.2.3])*

### `ds/setFactBreakpoints`

**`{ "breakpoints": [ { "schema", "on", "where", "hitCondition" } ] }`**

`ds/setFactBreakpoints` sets breakpoints on fact lifecycle events.

`schema` is required, and may name a built-in schema other than the clock tick. `on` is a non-empty list of `assert` and `retract`; `retract` covers every way a fact leaves working memory. `where` is a DS expression naming the fact by its schema name lowercased, compiled at once. `hitCondition` is as for [`setBreakpoints`](#setbreakpoints).

Each breakpoint is answered with `id` and `verified`, or `verified: false` and `message`: `no schema 'X'`, `on must be ...`, or the compiler's code and text.

A stop has `reason` `data breakpoint` and a `description` of the fact, what happened and its slots: `Reading #42 asserted: id=a, level=95.2`, or `Reading #42 retracted (ttl_expiry): …`. The word in the parentheses is a [retractor kind](#dsgetfactlineage).

*(Spec: [NDBG.12.3.1], [NDBG.12.3.2], [NDBG.12.3.3], [NDBG.12.3.4], [NDBG.12.3.5])*

### `ds/setCacheBreakpoints`

**`{ "breakpoints": [ { "key", "on" } ] }`**

`ds/setCacheBreakpoints` sets breakpoints on cache operations.

`key` is the cache key, a string, and the empty string matches any. `on` is a non-empty list of `get`, `set` and `delete`; `delete` covers a TTL expiry too.

Each is answered with `id` and `verified`. An entry is `verified: false`, with a message saying why, when its `key` is not a string, when its `on` is not a non-empty list of `get`, `set` and `delete`, or when it is a `get` in replay, with `a trace does not record cache reads`. A replay entry's `set` and `delete` stand. A stop has `reason` `data breakpoint` and a `description` of the key, the operation, the value for `set`, and for a removal its reason, `delete` or `ttl`.

*(Spec: [NDBG.12.5.1], [NDBG.12.5.2], [NDBG.12.5.3], [NDBG.12.5.4])*

### Exception breakpoints

**`setExceptionBreakpoints`**

`setExceptionBreakpoints` chooses among three filters.

| `filter` | `label` | Stops when | `default` |
|---|---|---|---|
| `unanswered_call` | Unanswered call | a pump ends with a call still waiting for its answer | `false` |
| `fault` | Fault | a firing raises a fault | `false` |
| `engine_error` | Engine error | a pump returns an error status, or the engine halts | `true` |

A stop has `reason` `exception` and a `description`. With `unanswered_call` off, an unanswered call is listed in the [Calls scope](#scopes) and reported by [`ds/callMade`](#dscallmade).

*(Spec: [NDBG.12.6.1])*

## Inspection

### `scopes`

**`scopes`**

`scopes` on the focused thread's top frame gives five scopes, and on any other frame only `Bindings`.

| Scope | Contents |
|---|---|
| `Bindings` | the firing's bound variables, by source name |
| `Working Memory` | the facts at the position, by schema, paged 100 to a schema |
| `Agenda` | in replay, the firings still to come in this pump, in order, each with rule, bindings and terminal ordinal; empty in a live session |
| `Cache` | each cache key at the position, with its value and TTL |
| `Calls` | the calls waiting for an answer, then those answered in this pump |

*(Spec: [NDBG.13.1.1], [NDBG.13.1.2], [NDBG.13.6.1])*

### `variables`

**`variables`**

`variables` gives a reference's children on demand, by `start` and `count`.

- A binding is named for its binding, valued by its schema, with one child per slot.
- A `Working Memory` child is a schema with a count, `Reading (3 facts)`, and its children are the facts.
- A fact has a read-only `_id`, and a logical fact has `_justifiers`, one child per active [justifier](../facts/logical.md#justifiers): `(2 active)`.
- A `Json` slot is a tree with no depth cap: an object's keys and an array's indices are children.

*(Spec: [NDBG.13.1.3], [NDBG.13.2.1], [NDBG.13.2.2], [NDBG.13.3.1], [NDBG.13.3.2], [NDBG.13.3.3], [NDBG.13.4.1], [NDBG.13.4.2], [NDBG.13.5.1], [NDBG.13.5.2])*

### `evaluate`

**`evaluate`**

`evaluate` reads a DS expression at the position, with the syntax of a `where` clause, against the bound variables of the firing `frameId` names.

`context` is `watch`, `hover` or `repl`, each answered alike, and any other is refused. Without a `frameId`, or on the engine's thread, the expression has no bindings. It reads the clocks and the series as a firing at that position reads them, and changes nothing in the engine.

`result` is the value as `variables` writes it, and a `Json` value carries a `variablesReference`. A failure to compile, a program with no source, and a fault, named by class, are error responses.

*(Spec: [NDBG.13.7.1], [NDBG.13.7.2], [LDEB.7.4.1])*

### `ds/getWorkingMemory`

**`{ "schema", "where", "limit", "offset" }`**

`ds/getWorkingMemory` gives the facts at the position.

Omitting `schema` gives every schema. `where` names the fact by its schema name lowercased, and needs `schema`.

The response is `facts` and `total`. A fact carries `fact_id`, `schema`, `slots`, `logical` and `ttl_remaining_ns`, non-null for a TTL fact. A logical fact also carries `_justifiers`, a count.

*(Spec: [NDBG.14w.1], [NDBG.14w.1a], [NDBG.14w.2])*

### `ds/diffWorkingMemory`

**`{ "from": { "timeline", "at_ns" }, "to": { "timeline", "at_ns" } }`**

`ds/diffWorkingMemory` gives the working-memory delta between two positions, as `asserted` and `retracted`, each entry with `schema`, `fact_id` and `slots`.

Within one timeline, these are the facts that entered and left in `[from, to)`, and a fact that did both is in both. Across two timelines, `asserted` holds the facts at `to` and not at `from`, and `retracted` the reverse.

Each list is in clock order. Within one timeline, `from` not before `to` is refused with `from must be strictly before to`. A position outside what its timeline recorded is refused, naming it.

*(Spec: [NDBG.20.1], [NDBG.20.2], [NDBG.20.3], [NDBG.20.4], [NDBG.20.5])*

### `ds/getFactLineage`

**`{ "fact_id": "#42" }`**

`ds/getFactLineage` gives what asserted a fact and what retracted it, as `asserter` and `retractor`.

| `asserter.kind` | Meaning |
|---|---|
| `rule` | a firing asserted it; carries `rule_name` and `firing` |
| `input` | the trace, a fact file or an inject fed it |
| `response` | it is a call's answer |
| `engine` | the engine asserted it, as it does a fault fact |

| `retractor.kind` | Meaning |
|---|---|
| `rule` | a firing retracted it; carries `rule_name` and `firing` |
| `ttl_expiry` | its TTL ended |
| `support_lost` | a logical fact whose last support ended |
| `input` | the trace, a fact file or an inject withdrew it |

Each carries `clock_ns`. `retractor` is null for a live fact.

*(Spec: [NDBG.14.4.1], [NDBG.14.4.2])*

### `ds/getActivationPath`

**`{ "firing": "!47" }`, `{ "threadId": 9 }`**

`ds/getActivationPath` gives the facts that matched each pattern of a firing of the current timeline, in declaration order.

The response is `rule_name`, `display_name` and `steps`. A step carries `pattern_index`, `schema`, `binding`, `fact_id`, `slots`, `join_result`, `passed` throughout, and `join_detail`. A firing the timeline does not hold is refused.

*(Spec: [NDBG.14.11.1], [NDBG.14.11.2], [NDBG.14.11.3])*

### `ds/getJustifiers`

**`{ "fact_id": "#42" }`**

`ds/getJustifiers` gives a logical fact's active [justifiers](../facts/logical.md#justifiers), each with `rule_name`, `firing`, `display_name` and `clock_ns`.

The libds call is in [Rete network](inv:integrator:std:doc#introspection/network).

*(Spec: [NDBG.6.1], [NDBG.14.3.1])*

### `ds/getReteNetwork`

**`{ "rule_name": "hot", "include_occupancy": true }`**

`ds/getReteNetwork` gives the Rete network, or one rule's part of it, as `nodes` and `edges`.

A node carries `id`, `kind` (`alpha`, `beta` or `terminal`), `label`, `filter` and `source`, and with `include_occupancy` its `occupancy`, or for a terminal `pending_activations`. Labels use DS source terms. Past 1,000 nodes, the response carries `truncated` and `node_count`.

*(Spec: [NDBG.6.1], [NDBG.14.6.1], [NDBG.14.6.2], [NDBG.14.6.4])*

### `ds/getMatchTrace`

**`{ "fact_id": "#39" }`**

`ds/getMatchTrace` traces a fact through the network's alpha nodes.

The response is `fact`, `path` and `joins_traced`, `false`. A step carries `node_id`, `node_kind`, `result`, `passed` or `filtered`, and `detail`, which for `filtered` names the test and the values. A fact that passes every alpha test and matches no rule was stopped at a join.

*(Spec: [NDBG.14.7.1], [NDBG.14.7.2])*

### `ds/getRefractedActivations`

**`{ "rule_name": "" }`**

`ds/getRefractedActivations` gives the activations refraction prevented from firing, with bindings by source name.

The empty string gives every rule. An entry carries `rule_name`, `display_name`, the rule's name, `reason`, `refraction`, `detail` and `bindings`. `suppressed` is empty, and `supersedure_reported` is `false`.

*(Spec: [NDBG.14.12.1], [NDBG.14.12.2], [NDBG.13.6.3])*

### `ds/getTimerAgenda`

**`ds/getTimerAgenda`**

`ds/getTimerAgenda` gives, in clock order, each armed cooldown window and each live fact's TTL deadline.

An entry carries `kind`, `cooldown` or `ttl`, `rule_name` or `fact_id`, `ends_at_ns` and `remaining_ns`. `after_listed` is `false`.

*(Spec: [NDBG.14.8.1])*

## Injection

### `ds/assertFact`

**`{ "schema", "slots" }`**

`ds/assertFact` injects a fact while paused.

At the end of a live run, it lands in the run as an input. Anywhere else, the adapter opens a fork at the position with the fact asserted, and the session follows the fork.

`slots` is one row, each value read as the slot's type. The fact takes its schema's lifetime, and a request with a `ttl` is refused. The response is `fact_id`, `timeline` and `message`, which also goes out as an `output` event.

An unknown schema is refused with `no schema 'X'`, a slot value that does not read names the slot, and an assert the engine refuses carries its code.

*(Spec: [NDBG.14.13.1], [NDBG.14.13.2], [NDBG.14.13.3])*

### `ds/retractFact`

**`{ "fact_id": "#42" }`**

`ds/retractFact` retracts a fact while paused, landing as [`ds/assertFact`](#dsassertfact) does.

The response is `timeline` and `message`, which also goes out as an `output` event. An unknown or retracted fact is refused with `fact 'X' not in working memory`. A retract the engine refuses carries its code.

*(Spec: [NDBG.14.14.1], [NDBG.14.14.2], [NDBG.14.14.3])*

### `ds/answerCall`

**`{ "corr", "response" }`, `{ "corr", "error" }`**

`ds/answerCall` answers one waiting call, once, landing as [`ds/assertFact`](#dsassertfact) does.

`response` and `error` are as for [`ds/installMock`](#dsinstallmock). A `corr` that names no waiting call is refused.

*(Spec: [NDBG.14.19.1])*

### `ds/installMock`

**`{ "corr" | "service", "response" | "error", "times" }`**

`ds/installMock` installs a standing answer for calls, and responds with `mock_id`.

A request carries exactly one of `corr` and `service`, and exactly one of `response` and `error`. `response` is one row of the service's response schema, read as `slots` is. `error`, `{ "code", "message" }`, reaches the continuation as a [`CallError`](../calls/call.md#callerror).

`times: N` answers `N` calls, then removes the mock. `0` matches until removed, and absent is `1`.

When the engine issues a matching call, the mock answers it. In replay, a mock that would answer a recorded call differently from the trace opens a fork at the first such call after the position.

*(Spec: [NDBG.14.15.1], [NDBG.14.15.2], [NDBG.14.15.3])*

### `ds/removeMock`

**`{ "mock_id": "mock-0001" }`**

`ds/removeMock` removes an installed mock.

*(Spec: [NDBG.14.16.1], [NDBG.14.16.2])*

## Timelines

### `ds/timelines`

**`ds/timelines`**

`ds/timelines` lists the real run and each fork, as `timelines`.

An entry carries `timeline` and `current`, and a fork also `from`, `at_ns` and `change`. A fork starts at a position in another timeline with one change there, and opening one switches the session to it.

*(Spec: [NDBG.14.17.1], [NDBG.14.17.2])*

### `ds/switchTimeline`

**`{ "timeline": "%0" }`**

`ds/switchTimeline` makes the session follow another timeline, at the position it held there, and `stopped` follows with `reason` `goto`.

*(Spec: [NDBG.14.17.2])*

### `ds/dropTimeline`

**`{ "timeline": "%1" }`**

`ds/dropTimeline` drops a fork and every fork opened from it, and responds with `dropped`.

Dropping `%0`, or the timeline the session follows, is refused.

*(Spec: [NDBG.14.17.2], Source: tools/dsdb/lib/dap/server.js)*

## Custom events

### `ds/streamEvents`

**`{ "kinds": ["factAsserted", "callMade"] }`**

`ds/streamEvents` chooses which custom events go out from then on, replacing the `events` launch argument's choice.

Each kind is the event's name without `ds/`. An empty list sends none, and an unknown name is refused, naming it. Events are off by default, and go out only while the session moves forward.

*(Spec: [NDBG.14.20.1], [NDBG.15.9])*

### `ds/factAsserted`

**`{ "schema", "fact_id", "slots", "asserter", "clock_ns", "logical" }`**

`ds/factAsserted` reports a fact entering working memory. `asserter` is as in [`ds/getFactLineage`](#dsgetfactlineage).

*(Spec: [NDBG.15.1])*

### `ds/factRetracted`

**`{ "schema", "fact_id", "retractor", "clock_ns" }`**

`ds/factRetracted` reports a fact leaving working memory. `retractor` is as in [`ds/getFactLineage`](#dsgetfactlineage).

*(Spec: [NDBG.15.2])*

### `ds/logicalFactFlipped`

**`{ "schema", "fact_id", "direction", "justifier_count", "clock_ns" }`**

`ds/logicalFactFlipped` reports a logical fact coming into existence, `direction` `assert`, or leaving when its last justifier withdrew, `retract`.

*(Spec: [NDBG.15.3])*

### `ds/callMade`

**`{ "corr", "service", "kwargs", "firing", "clock_ns" }`**

`ds/callMade` reports the engine issuing a call.

*(Spec: [NDBG.15.4])*

### `ds/callAnswered`

**`{ "corr", "service", "response" | "error", "clock_ns" }`**

`ds/callAnswered` reports a call's answer reaching the engine: a `response` row, or an `error` delivered as a [`CallError`](../calls/call.md#callerror).

*(Spec: [NDBG.15.5])*
