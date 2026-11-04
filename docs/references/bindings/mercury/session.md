<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Session

## Modules

### Modules a host imports

A host imports the module that defines each name it uses, `mercury_ds`'s and the runtime's alike.

| Module | Names |
|---|---|
| `mercury_ds.session` | `session`, `session_config`, `clock_choice`, `step`, `assert_step`, `assert_outcome`, `pumped`, `recording`, `read(T)` |
| `mercury_ds.value` | `storable`, `fact_view` |
| `mercury_ds.introspect` | `source_loc`, `service_info`, `rule_info`, `justifier` |
| `mercury_ds.host` | `service_answer`, `duty`, `cache_removal`, `removal_reason` |
| `mercury_ds.events` | `report`, `log_line`, `integrator_event`, `event_kind`, `activation`, `service_call`, `cache_write`, `fault_info`, `bound`, `trap_kind`, `engine_fault`, `cap_name` |
| `mercury_ds.atoms` | `atom`, `atom_listing` |
| `mercury_ds.error` | `ds_error`, `outcome` |
| `mercury_ds.status` | `status` |
| `ds.chrono` | `instant`, `duration` |
| `ds.id` | `fact_id`, `timetag`, `seq`, `node_id` |
| `ds.value` | `ds_value`, `json_term` |
| `ds.json` | `json` |
| `ds.schema` | `schema` |
| `ds.engine` | `engine`, `fire_budget`, `engine_mem`, `trace_step`, `refracted_activation` |
| `ds.dsc` | `program`, `dsc_header`, `ds_source`, `line_span`, `admission`, `admission_policy`, `svcd` |
| `ds.network` | `network` |
| `ds.service` | `service_kwarg`, `kwarg_default` |
| `ds.capability` | `capability` |
| `ds.events` | `metric`, `metric_kind`, `stream_event` |
| `ds.action` | `log_level` |
| `ds.fact_external` | `arg`, `arg_value`, `fact_external` |
| `ds.fault` | `engine_error` |
| `ds.atom` | `atom_ref`, `atom_id` |
| `ds.rfcs` | `stream_meta` |

`advance`, `set_clock`, `set_wall_clock`, `run_id`, `tier_id` and `session_header` are also `ds.engine`'s, over an `engine`. Mercury resolves each by its arguments' types, and `set_wall_clock` by its arity too: `ds.engine`'s takes no `outcome`.

*(Source: bindings/mercury/src/mercury_ds.m, runtime/mercury/src/ds.dsc.m, runtime/mercury/src/ds.engine.m, runtime/mercury/src/ds.network.m, runtime/mercury/src/ds.value.m)*

## Sessions

### `session`

**`:- type session.`**

An engine loaded from one artefact, as a value: the capability of [`ds_engine_new`](inv:integrator:std:doc#engine/lifecycle) and [`ds_engine_load_dsc`](inv:integrator:std:doc#engine/loading) together.

A call that changes a session takes it and returns the new one, and the value it took stays valid and unchanged. A copy of the value is an independent session, and nothing is freed. A call that changes a session takes no `io`, but for [`read_clock`](clock.md#read_clock) and [`pump_serving`](reports.md#pump_serving), and only `pump_serving` runs host code.

```{note}
The halt belongs to the session value that holds it. A value taken before the call that halted the engine is not halted.
```

*(Source: bindings/mercury/src/mercury_ds.session.m)*

### `session_config`

**`:- type session_config ---> session_config(session_config_clock :: clock_choice, session_config_budget :: fire_budget, session_config_run_id :: maybe(string), session_config_tier_id :: maybe(string), session_config_admission :: admission_policy).`**

What [`load`](#load) configures: the capability of [`ds_engine_config_t`](inv:integrator:std:doc#engine/lifecycle) and [`ds_engine_set_admission`](inv:integrator:std:doc#engine/loading).

| Field | Holds |
|---|---|
| `session_config_clock` | the [`clock_choice`](clock.md#clock_choice) |
| `session_config_budget` | `fire_budget(N)`, at most `N` firings in one pump, or `no_fire_limit` |
| `session_config_run_id` | the run id, or `no`; `yes("")` is `no` |
| `session_config_tier_id` | the tier id, or `no`; `yes("")` is `no` |
| `session_config_admission` | a map from `capability` to `admission`, which is [`ds_admission_t`](inv:integrator:std:doc#engine/loading); a capability with no entry admits either setting |

*(Source: bindings/mercury/src/mercury_ds.session.m, runtime/mercury/src/ds.engine.m, runtime/mercury/src/ds.dsc.m, Spec: [NLFC.1.2], [NLFC.10.2])*

### `default_config`

**`:- func default_config = session_config.`**

The mock clock, `no_fire_limit`, no run or tier id, and an empty admission map.

*(Source: bindings/mercury/src/mercury_ds.session.m)*

### `load`

**`:- pred load(bitmap::in, session_config::in, maybe_error(session, ds_error)::out, list(report)::out) is det.`**

Makes a session from an artefact's bytes, or gives a [`ds_error`](errors.md#ds_error) saying why not.

`encoding`, then `inval`, are checked before the artefact is read. The other refusals are met as the load walks the artefact. A refused load returns no session and no reports.

| `error` with [`status`](errors.md#status) | Condition |
|---|---|
| `encoding` | the run id or tier id is not well-formed UTF-8 |
| `inval` | the firing limit is negative |
| `dsc_truncated` | the bytes are empty, or end inside a frame |
| `dsc_bad_magic` | the first atom is not a `DscHeader`, or its frame is malformed |
| `dsc_version` | the artefact is of another DS series, or holds an unknown atom numbered 128 to 255 |
| `bnd_incomplete` | the header's `dialect_def_sha256` is not 32 bytes |
| `fs_unknown_inject` | an unknown atom is numbered 1 to 127 |
| `dsc_decode` | a later frame or an atom's body does not decode, a field number is 0 or at least 2048, or an atom is empty |
| `dsc_semantic` | the artefact decodes and breaks a rule of its format, such as `dsc_sha256` not matching its bytes |
| `dsc_dangling` | an atom names what the artefact does not hold |
| `dsc_decompress` | an atom's compression is not `COMPRESSION_NONE` |
| `dsc_capability_absent` | `requires` names a capability this build has no code for, or an unknown number |
| `bnd_dialect_mismatch` | `session_config_admission` does not admit the artefact's setting of a capability |
| `retp_invalid` | a network node's id is 0, or two nodes share an id |
| `retp_index_oob` | a `node_id` names no node |
| `fn_not_found` | a `CallExpr` names a builtin this runtime has no handler for |

On success the [`report`](reports.md#report)s hold one `dsc-load` info line for each atom the load stepped over, with its field number and byte offset, in the order the load met them.

*(Source: bindings/mercury/src/mercury_ds.session.m, bindings/mercury/src/mercury_ds.from_runtime.m, runtime/mercury/src/ds.dsc.m, runtime/mercury/src/ds.engine.m, Spec: [NLFC.1.2], [RDSC.9.4], [RDSC.11.1])*

## Running

### `step`

**`:- type step ---> step(step_outcome :: outcome, step_reports :: list(report), step_duties :: list(duty)).`**

What a call that changes a session did, reported and left the host to do.

`step_outcome` is an [`outcome`](errors.md#outcome). `step_reports` is in the order the call emitted them. `step_duties` is [`duty`](reports.md#duty) values in the order the call produced them, for the host to perform.

*(Source: bindings/mercury/src/mercury_ds.session.m)*

### `pumped`

**`:- type pumped ---> pumped(pumped_outcome :: outcome, pumped_reports :: list(report), pumped_duties :: list(duty), pumped_calls :: list(service_call)).`**

What a pump did, reported and left the host to do.

`pumped_reports` is in the order the pump emitted them, `pumped_duties` in the order its firings produced them, and `pumped_calls`, each a [`service_call`](reports.md#service_call), in the order its firings issued them.

*(Source: bindings/mercury/src/mercury_ds.session.m)*

### `pump`

**`:- pred pump(pumped::out, session::in, session::out) is det.`**

Runs the agenda until it is empty or the firing limit is reached: the capability of [`ds_engine_pump`](inv:integrator:std:doc#engine/pump).

The duties and calls are returned and not performed. What the host does with them leaves the session unchanged until it [answers](reports.md#answer) a call.

At the limit with activations left, `pumped_reports` holds a [`bounds_error`](reports.md#event_kind) naming `max_fires_per_pump`, and the activations stay queued for the next pump. The limit does not change `pumped_outcome`.

| `pumped_outcome` | Condition |
|---|---|
| `error`, `engine_halted` | the session had halted, and the lists are empty; or a firing halted the engine in this pump, whatever else it raised |
| `error`, `time_range` | the pump's sample, the engine's first, would give a held cache seed a deadline outside the `Time` range; nothing is sampled, recorded or fired |
| `error`, `nan_rejected` | a `Float` call argument is NaN; the call is refused, and the firing's other actions run |
| `error`, `contract_breach` | a rule's cache write passes a bound [`set_cache_cap`](reports.md#set_cache_cap) gave; the write is refused, the firing stops there, and the pump goes on |

Of the last two, the first raised is the outcome.

```mercury declaration
:- pred pump_once(list(duty)::out, session::in, session::out) is det.
pump_once(Duties, !S) :-
    pump(Pumped, !S),
    Duties = Pumped ^ pumped_duties.
```

*(Source: bindings/mercury/src/mercury_ds.session.m, runtime/mercury/src/ds.engine.m, runtime/mercury/src/ds.events.m, bindings/mercury/src/mercury_ds.from_runtime.m, Spec: [NCBK.2.9], [NLFC.9.5], [LEXP.4.2], [LSTO.4.7.5], [LTIM.2.5.1])*

### `set_fire_budget`

**`:- pred set_fire_budget(fire_budget::in, outcome::out, session::in, session::out) is det.`**

Sets how many firings each later pump may perform.

A halted session is refused with `engine_halted`, ahead of the limit's check. A negative limit is refused with `inval`. A refused call leaves the session unchanged.

*(Source: bindings/mercury/src/mercury_ds.session.m, Spec: [NCBK.2.9])*

## Reads

### `read(T)`

**`:- type read(T) ---> ok(T) ; halted(engine_error).`**

What a read of a session answers: its value, or the error that halted the session's engine.

Once the engine has halted, every call declared with this type answers `halted`, as the [halt latch](inv:integrator:std:doc#engine/lifecycle) states.

```mercury declaration
:- func live_fact_count(session) = int.
live_fact_count(S) = N :-
    ( if fact_count(S) = ok(N0) then N = N0 else N = 0 ).
```

*(Source: bindings/mercury/src/mercury_ds.session.m, Spec: [NCBK.2.9], [LERR.1.4.7])*

### `halted`

**`:- func halted(session) = maybe(engine_error).`**

The error that halted the engine, or `no`: the capability of [`ds_engine_halted`](inv:integrator:std:doc#engine/lifecycle).

*(Source: bindings/mercury/src/mercury_ds.session.m, Spec: [NCBK.2.9])*

### `memory_usage`

**`:- func memory_usage(session) = read(engine_mem).`**

What the engine holds: the capability of [`ds_engine_mem`](inv:integrator:std:doc#introspection/network).

`engine_mem` has one field for each of `ds_engine_mem_t`'s members, in its order, each an `int`, prefixed `em_`. `em_intern_string_bytes` and `em_total_bytes` hold the interned strings' bytes, and every other byte field is 0. `em_wm_fact_count` includes the compiler's synthesised facts, which [`fact_count`](facts.md#fact_count) leaves out.

*(Source: bindings/mercury/src/mercury_ds.session.m, runtime/mercury/src/ds.engine.m, Spec: [NDBG.2.1], [NMET.4.7])*

### `run_id`

**`:- func run_id(session) = read(maybe(string)).`**

The run id the session was loaded with, or `no`: the capability of [`ds_engine_get_run_id`](inv:integrator:std:doc#engine/lifecycle).

*(Source: bindings/mercury/src/mercury_ds.session.m, runtime/mercury/src/ds.engine.m)*

### `tier_id`

**`:- func tier_id(session) = read(maybe(string)).`**

The tier id the session was loaded with, or `no`: the capability of [`ds_engine_get_tier_id`](inv:integrator:std:doc#engine/lifecycle).

*(Source: bindings/mercury/src/mercury_ds.session.m, runtime/mercury/src/ds.engine.m)*

### `session_header`

**`:- func session_header(session) = ds.rfcs.stream_meta.`**

The session header a [recording](recording.md#recording-type) of this session begins with: the capability of [`ds_engine_get_session_header`](inv:integrator:std:doc#determinism/provenance).

It holds the DS version, the artefact's `dsc_sha256`, its capabilities and dialect definition hash, and the run id and tier id, `""` for one not given. It answers on a halted session.

*(Source: bindings/mercury/src/mercury_ds.session.m, runtime/mercury/src/ds.engine.m, Spec: [NCBK.2.9], [NLFC.1.2], [RBND.1.3])*

## The runtime's values

### `session_engine`

**`:- func session_engine(session) = engine.`**

The session's engine, the runtime's own value.

```{warning}
`session_engine` refuses nothing after the halt, and a read through its value then has no defined answer.
```

*(Source: bindings/mercury/src/mercury_ds.session.m, Spec: [LERR.1.4.7])*

### `session_program`

**`:- func session_program(session) = program.`**

The program the session was loaded from, the runtime's own value.

`ds.dsc.network` reads the Rete network from it: the capability of [`ds_engine_rete_network`](inv:integrator:std:doc#introspection/network). It refuses nothing after the halt.

*(Source: bindings/mercury/src/mercury_ds.session.m, runtime/mercury/src/ds.dsc.m)*
