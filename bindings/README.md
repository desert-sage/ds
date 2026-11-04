<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Bindings

A DS runtime bound into a host language, one directory each, named for the host
language — whatever language the runtime itself is written in. The
C runtime, libds, binds into any language; the Mercury runtime binds into
Mercury only.

| Directory | Host language | Runtime | Design |
|---|---|---|---|
| `js/` | JavaScript (Node, native and wasm) | libds | [`JS_BINDING.md`](JS_BINDING.md), [`js/JS_STYLE.md`](js/JS_STYLE.md) |
| `mercury/` | Mercury 22.01 | the Mercury runtime | [`MERCURY_BINDING.md`](MERCURY_BINDING.md), [`mercury/MERCURY_STYLE.md`](mercury/MERCURY_STYLE.md) |
| `python/` | Python (CPython 3.12+) | libds | [`PYTHON_BINDING.md`](PYTHON_BINDING.md), [`python/PYTHON_STYLE.md`](python/PYTHON_STYLE.md) |
| `c/` | C (C99) | libds | [`C_BINDING.md`](C_BINDING.md), [`c/C_STYLE.md`](c/C_STYLE.md); its example is `c/examples/harness.c` |

The directory names the family; a package keeps the name its host language
expects. `python/` builds the distribution `ds-lang`, imported as `pyds` —
PEP 8 asks for a short, lowercase package name. `mercury/` builds the
Mercury module `mercury_ds` and its submodules.

## Each binding is its own language's

- Each binding has a design document (`<LANGUAGE>_BINDING.md`) and a style
  canon built from its host language's authorities and no others:
  `python/PYTHON_STYLE.md` (PY.n), `js/JS_STYLE.md` (JS.n),
  `mercury/MERCURY_STYLE.md` (MER.n) and `c/C_STYLE.md` (C.n).
  A review cites the canon's rules, never another binding's code.
- Parity is measured against `libds.h`, never binding against binding. A
  capability every binding offers is stated below, and each binding's design
  says how its idiom carries it.
- Each binding's gate runs its host language's own linters and type checker,
  so an idiom borrowed from elsewhere is caught mechanically as well as in
  review.

## Across the bindings

Each binding gives libds's semantics in its own language's shape, and they
offer equivalent capability. These hold for all of them:

- **Every binding hosts services:** a function in the host language,
  registered by name, that a rule's `call` reaches. It runs after the pump,
  never inside libds; what it returns is asserted as the response, a fact of
  the service's response schema with the call's `corr`, and a failure as a
  `CallError`. Each binding does it in its own idiom: in JavaScript an
  `async` function (`JS_BINDING.md` §3.5); in Mercury the host's answer to
  each call a pump returns, given back to the session with `answer`
  (`MERCURY_BINDING.md`); in Python, `PYTHON_BINDING.md` §6.
- **A call to a service no one registered gets a `CallError` coded
  `request.unsupported`.** `[LECC.3.1.1]` names that leaf for "the adapter
  does not offer the named service", and a standard leaf is preferred to an
  adapter namespace (`[LECC.2.3]`).
- **No implicit conversion between a host's integers and floats:** an `Int`,
  `Time`, `Date` or `Duration` slot refuses a float, and a `Float` slot
  refuses an integer, as `NFCT.2.3` requires of libds. JavaScript's
  safe-integer `Number` for an `Int` slot is accepted, because it is exact by
  construction (`js/JS_STYLE.md` JS.12).
- **C has a binding, in `bindings/c`.** It wraps nothing: `libds.h` is libds's. It
  is the example program (`harness.c`), its canon (`c/C_STYLE.md`) and its
  gate. Its defects are its own, not libds's (`C_BINDING.md`). The guidance a C
  integrator reads, the integrator reference, is the docs lane's.
- **Every binding's example is a harness, as `harness.c` is:** one minimal,
  domain-agnostic program that exercises every feature of the binding, in
  stages ordered by dependency, logging each call and its outcome, built and
  run by the binding's gate. Each is written in its own language's idiom; the
  stages, not the code, are what the harnesses share.

## Capability parity

What an integrator can do, one row per capability, through each surface DS
offers. **Parity is of capability, not of shape.** Each cell is that surface's
own spelling, and the spellings are meant to differ. A dash is a gap, and the
surface that has it owes it.

**C is one of the surfaces.** An integrator in C uses `libds.h` directly, so
its column is held to the same parity as the bindings', and a gap in it is
owed by libds. The example program beside the header, and the canon it is
held to, are the C binding's, and a defect there is owed by that binding. The column is also what every binding stands on: a capability C
lacks, a binding can offer only by building it itself, once per binding. The
"a fact handle that cannot dangle" row below is the standing example.

The bindings in 1.0.0 are pyds, @ds-lang/ds, mercury_ds and the C binding (D9,
D24). mercury_ds binds the Mercury runtime rather than libds: Mercury is
DS's base language, and the binding verifies DS's Mercury types end to end.
`cpp_plusds`, `lua_plusds` and `rust_plusds` are not in 1.0.0 (D9).

This is the capability view. Which binding function reaches which `libds.h`
function is each binding's `coverage.tsv`: `python/coverage.tsv`,
`js/coverage.tsv` and `mercury/coverage.tsv`, each checked by
its binding's gate. A cell shows the surface as it is; the design documents
say what each binding is to become.

### The engine

| Capability | C (`libds.h`) | pyds | @ds-lang/ds | mercury_ds |
|---|---|---|---|---|
| Create, release | `ds_engine_new`, `ds_engine_free` | `Engine()`, `close()`, `with` | `new Engine()`, `close()`, `using` | `load`; a session is a value, with nothing to free |
| Run and tier ids | `ds_engine_config_t.run_id`, `.tier_id`; `ds_engine_get_run_id`, `_get_tier_id` | `Engine(*, run_id=, tier_id=)`; `run_id`, `tier_id` | — | `session_config`'s `session_config_run_id`, `_tier_id`; `run_id(S)`, `tier_id(S)` |
| Clone | `ds_engine_clone` | `clone()` | `clone()` | a copy of the session, which carries no host |
| Compile DS source | — (the `dsc` binary, run by the integrator) | `compile`, `compile_file`, `from_source` | `compile`, `compileFile`, `fromSource` | none in 1.0.0: the `dsc` binary, as for C |
| Load an artefact | `ds_engine_load_dsc` | `load_dsc(bytes)` | `loadDsc(Uint8Array)` | `load(bitmap, ...)` |
| What this libds build carries | `ds_build_capabilities` | `BUILD_CAPABILITIES`, a `frozenset` of `Capability` | — | the runtime's `ds.dsc.build_capabilities`, a `set(capability)` |
| Which capability settings a load admits | `ds_engine_set_admission` | `set_admission(Capability, Admission)` | — | `session_config`'s `session_config_admission`, the runtime's `admission_policy` |
| Halted, and why | `ds_engine_halted` | `halted`, an `EngineFault` or `None` | `halted` | `halted(S)`, a `maybe(engine_error)` |
| Memory used | `ds_engine_mem` | `memory_usage()`, a `MemoryUsage` | `memory()` | `memory_usage(S)`, the runtime's `engine_mem` |
| Platform signature | `ds_engine_get_platform_signature` | `platform_signature`, a `PlatformSignature` | `platformSignature` | the runtime's `ds.platform.platform_signature`, a constant of the build |
| Session header | `ds_engine_get_session_header` | `session_header`, a `SessionHeader` | `sessionHeader` | `session_header(S)`, the runtime's `stream_meta` |
| A failure, as a value | `ds_result_t`: `.status`, `.detail` | `pyds.Error`, a subclass per status family: `.status`, `.detail` | `DsError`: `.status`, `.detail` | `ds_error`: `maybe_error(T, ds_error)`'s `error`, and an `outcome`'s, `ok ; error(ds_error)` as `io.res` is |
| Status codes by name | `DS_ERR_*` | `Status.WM_FULL`, an `IntEnum` | `status.DS_ERR_*` | `mercury_ds.status`'s `status`, generated from `proto/status.proto` |
| Types for a checker | `libds.h` itself | `py.typed`, and `_pyds.pyi` for the extension, held to it by `mypy.stubtest` | — | the interface's own types, which `mmc` checks |

### Facts

| Capability | C (`libds.h`) | pyds | @ds-lang/ds | mercury_ds |
|---|---|---|---|---|
| Assert, retract | `ds_engine_assert`, `_retract` | `assert_` (returns a `FactId`), `retract(fact_id)` | `assert(schema, slots)`, `retract(fact)`, a `Fact` or an id | `assert_fact(Schema, Values, Step, !S)`, `retract_fact(fact_id)` |
| A fact another tier published | `ds_engine_assert_external` | `assert_external(data)` | `assertExternal` | `assert_external(Bytes, Step, !S)` |
| Run the agenda | `ds_engine_pump` | `pump()` | `pump()` | `pump` |
| Integers and floats kept apart | a slot value's `kind` must match, `NFCT.2.3` | `Int` refuses a `float`, and `Float` an `int` | `Int` takes a `BigInt` or safe `Number`; `Float` refuses a `BigInt` | `storable`'s `int(int64)` and `float(float)`; each is refused in the other's slot |
| Count, enumerate | `ds_engine_fact_count`, `_for_each_fact` | `len(e.facts)`, iterating `e.facts`, `e.facts.of(schema)` | `factCount`, `facts({ schema })`, an array of `Fact` | `fact_count(S)`, `facts(S)` |
| A fact by id | `ds_engine_fact_find`, O(1) | `e.facts[fact_id]`, from pyds's own table of live facts, O(1) | `factById(id)`, a walk of working memory | `search_fact(S, Id, View)`, `semidet`, or `lookup_fact(S, Id)`, from the runtime's working memory |
| A fact's id, schema, slots | `ds_fact_get_id`, `_schema`, `_slot` | `Fact.id`, `.schema`, `.slots`, a frozen snapshot | `Fact.id`, `Fact.read()` | `fact_view`'s `fact_view_id`, `_schema`, `_slots`, a snapshot |
| A fact handle that cannot dangle | — (a `ds_fact_t *` is valid only while its fact lives; the caller tracks `FACT_RETRACT`) | `FactId`: a fact that has gone is a `KeyError`, never a dereference | `Fact`, refused with `DS_ERR_FACT_INVALID` once its fact has gone | `fact_id`, the runtime's own: `fact` fails once its fact has gone |
| Still live? | `ds_engine_fact_find` by id answers `DS_ERR_NOT_FOUND` | `fact_id in e.facts` | `Fact.alive` | `search_fact(S, Id, _)` succeeds |
| A fact-ref slot's target id | `ds_fact_get_slot_ref_id` | a fact-ref slot reads as its target's `FactId` | a fact-ref slot reads as a `Fact` | a fact-ref slot reads as `fact_ref(fact_id)` |
| When asserted, when it expires | `ds_fact_get_asserted_ns`, `_ttl_deadline_ns` | `Fact.asserted_ns`, `.ttl_deadline_ns` (`None` for none) | — | `fact_view_asserted`, `_deadline` (`no` for none) |
| `Json` values | `ds_json_*` trees | Python values in, canonical text out | JSON text in, canonical text out | the runtime's `ds.json.json` terms; `json_from_text`, `json_to_text` |

### The program

| Capability | C (`libds.h`) | pyds | @ds-lang/ds | mercury_ds |
|---|---|---|---|---|
| Schemas | `ds_engine_schema_*`, `ds_schema_get_*` | `Engine.schemas`, a `Mapping` of `Schema` | `Engine.schemas`, a `ReadonlyMap` of `SchemaInfo` | `schema_names(S)`, `search_schema(S, Name, Schema)`, `lookup_schema(S, Name)`; `slot_names(S, Schema)` |
| A schema's source position and `.proto` text | `ds_schema_get_source`, `_proto_source` | `Schema.source`, `.proto_source` | — | `search_schema_source(S, Name, Loc)`, `lookup_schema_source(S, Name)`, a `source_loc` whose file is `no` where libds's is NULL; `proto_text(Schema)` |
| Rule metadata | `ds_engine_rule_meta_*` | `Engine.rules`, a `Mapping` of `Rule` | `Engine.rules`, a `ReadonlyMap` of `RuleMeta` | `rules(S)`, `search_rule(S, Name, Info)`, `lookup_rule(S, Name)` |
| Program sources and line spans | `ds_engine_ds_source_*`, `_line_span_*` | `sources`, a `Mapping` of `ProgramSource` by module id; `line_spans`, a `Mapping` of `LineSpan` by node id | — | `sources(S)`, `line_spans(S)`, `search_line_span`, `search_source_file`, and their `lookup_` forms |
| The program's services: response schema, `no response`, kwargs | `ds_engine_service_count`, `_at`, `_find` | — | — | `services(S)`: each name, its response schema (`no` for `no response`) and its kwargs, the runtime's `service_kwarg`s |

### Time

| Capability | C (`libds.h`) | pyds | @ds-lang/ds | mercury_ds |
|---|---|---|---|---|
| Clock mode, read, set, advance | `ds_engine_clock_mode`, `_set_mode`, `_now`, `_set`, `_advance` | `Engine.clock`: `.mode` (a `ClockMode`), `.now_ns`, `.set`, `.advance`, `.set_wall` | `Engine.clock`: `.mode` (settable), `.now`, `.set`, `.advance` | `session_config_clock` at load; `clock_mode(S)`, `now(S)`, `set_clock`, `advance` |
| Mock wall clock | `ds_engine_wall_clock_set` | `Engine.clock.set_wall` | `Engine.clock.setWall` | `set_wall_clock(UtcNs, Outcome, !S)` |

### Callbacks and the integrator's verbs

| Capability | C (`libds.h`) | pyds | @ds-lang/ds | mercury_ds |
|---|---|---|---|---|
| Every event | `ds_engine_set_stream_callback` | `on_event = fn`, events as `pyds.events` dataclasses, facts as `FactId` | `addEventListener(kind, fn)` for each of `STREAM_EVENT_KINDS`, an `EngineEvent` per event, facts as `Fact` | each call's `streamed(integrator_event)` reports, in order |
| Log, metric | `ds_engine_set_log_callback`, `_metric_callback` | `on_log`, `on_metric` | `"log"` and `"metric"` events, `onlog`, `onmetric` | `logged(log_line)` and `measured(metric)` reports |
| A callback's failure | its returned status, where the callback type has one | `sys.unraisablehook` | a listener's: the platform's, as any listener's; a handler's: the `cause` of the `DsError` its call throws, or the platform's where no call fails; a callback's: `setUnraisableHook(fn)` | none: no host code runs inside a call; a duty is performed after the pump returns, by the host |
| A rule's `call` | `ds_engine_set_call_callback` | `set_call_callback(fn)` | `setCallCallback(fn)` | a pump's `pumped_calls`, and the `action_call(service_call)` event |
| Services | the call callback, and the integrator asserts the response | — (`PYTHON_BINDING.md` §6) | — (`JS_BINDING.md` §3.5) | `answer(Call, service_answer, Step, !S)`; `pump_serving` for the loop |
| Cache write-through, and seeding | `ds_engine_cache_callbacks`, `_cache_seed` | `on_cache_set`, `on_cache_delete`, `cache.seed` | `cache.writeThrough = { set, delete }`, `cache.seed` | every call's `write_cache` and `remove_cache` duties; `cache_seed` |
| Cache caps | `ds_engine_set_cache_cap` | `cache.set_cap(keys=, bytes=)` | `cache.setCap({ keys, bytes })` | `set_cache_cap(Keys, Bytes, Outcome, !S)`, each an `int` |

### Debugging

| Capability | C (`libds.h`) | pyds | @ds-lang/ds | mercury_ds |
|---|---|---|---|---|
| Justifiers | `ds_engine_get_justifiers` | `debug.justifiers(fact_id)`, a list of `Justifier` | `justifiers(fact)` | `justifiers(S, Id)` |
| The Rete network | `ds_engine_rete_network` | `debug.network()`, a `ReteNetwork` | `reteNetwork` | `session_program(S)`, the runtime's `program` |
| A fact's alpha path | `ds_engine_rete_match_trace` | `debug.match_trace(fact_id)`, a list of `TraceStep` | `reteMatchTrace(fact)` | `match_trace(S, Id)`, the runtime's `trace_step`s |
| Refracted activations | `ds_engine_refracted_activations` | `debug.refracted()`, a list of `RefractedActivation` | `refractedActivations` | `refracted_activations(S, Rule)`, the runtime's `refracted_activation`s |

### Recording and replay

C's column here is `include/internal/rfcs/rfcs.h`, not `libds.h`. It ships in
every tarball, but as an internal header, with no stability promise. So a C
integrator who records or replays depends on a surface that may change
between versions, while a binding wraps it and gives its own callers a stable
one.

| Capability | C (`internal/rfcs/rfcs.h`) | pyds | @ds-lang/ds | mercury_ds |
|---|---|---|---|---|
| Record the fact stream | `ds_rfcs_record_*` | `record(path)`, a `Recording` closed by `close()` or `with` | `recordTo(path or sink)`, `stopRecording()` | `start_recording(!S)`, `stop_recording(!S)`; `recording(S)`, the bytes, which the host writes |
| Replay a stream | `ds_rfcs_replay_*` | `replay(stream)`, a `ReplayResult` | `replayStream` | `replay(Bytes, Step, !S)`, running no host method |
| Read a trace's or `.dsc`'s atoms | `ds_rfcs_next_incremental`, `ds_rfcs_visit_atom` | `pyds.atoms` | `readAtoms`, `messageName` | `mercury_ds.atoms.atoms(Bytes)`, each named by the runtime's `atom_id` |
| Type a recorded fact body | `ds_rfcs_decode_fact_body` | `Engine.decode_fact_body(schema, body)` | `decodeFactBody` | the runtime's `ds.rfcs.decode_stream`, whose events carry each body's values typed |
| A text-note atom (deferred, RFCS.25) | `ds_rfcs_encode_text` | none: TextNote is deferred | `encodeText` | none: TextNote is deferred |

**Beyond libds.** @ds-lang/ds has dsdb beside it (`dsdb`), whose `ds test` is
the `.dstest` runner. That is not a libds capability, so it has no row. pyds
carries no codec of its own.

### Gaps, by surface

- **C:**
  - no compile entry point: a C integrator runs `dsc`, where pyds and
    @ds-lang/ds wrap it;
  - no fact handle that is safe to hold, so each libds binding builds its
    own table of live facts from the stream. mercury_ds needs none: the
    Mercury runtime's `fact_id` is safe to hold;
  - recording and replay only in an internal header.
- **pyds:** services, and the program's services view they read.
- **@ds-lang/ds:** run and tier ids; build capabilities and admission; asserted
  and expiry times; a schema's source position and `.proto` text; program
  sources and line spans; types; services, and the program's services view;
  a fact by id walks working memory where `ds_engine_fact_find` answers in
  O(1).
- **mercury_ds:** a service by name, `ds_engine_service_find`: the runtime
  has `search_service`, and the binding does not export it
  (`mercury/coverage.tsv`). It offers no in-process compile.
- **mercury_ds, by design:** the clock's mode is chosen at load, where
  libds can switch it with `ds_engine_clock_set_mode`; a host wanting live
  time loads live.
