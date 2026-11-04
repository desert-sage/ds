<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# libds modules

## Library

### Library artefact

**`runtime/src/libds/libds.a`**

libds builds as one static archive, the native Rete engine included.

There is no shared-object build. Every object in the archive is compiled with `-fPIC`. libds is C99: it uses no GNU extension, no C11-only feature and no compiler-specific pragma.

*(Spec: [IARC.1.2], [IARC.1.3], [IARC.7.1])*

### Source layout

libds's sources and internal headers live under `runtime/src/libds/`.

The engine's own modules sit at its top, and a subsystem with files of its own takes a subdirectory: `rete/` the matching network, `dsc/` the artefact loader, `rfcs/` the fact-stream codec, `series/` the series backings, and others beside them. The public header is `runtime/include/libds.h`; internal headers are not reachable through the public include path. Four internal headers, `sha256.h`, `rfcs/rfcs.h`, the `rfcs/atoms.h` it includes and `ds_re2.h`, also ship under `include/internal/`, with no API-stability guarantee. Module names follow the runtime specification's subsystem names one for one.

*(Spec: [IARC.1.4], [IARC.1.5], [IARC.1.7], [IARC.3.13])*

### No threads

libds never depends on threads.

It makes no `pthread_*` call, does not sleep, spawns no thread, runs no background timer, uses no thread-local state as a mechanism and holds no lock across a callback. The pump runs to agenda exhaustion and returns, and every module mutates state on the pump's call stack. All blocking I/O goes through callbacks the integrator drives. The `-lpthread` link is a libc and toolchain requirement; no libds code calls it.

*(Spec: [IARC.1.10], [IARC.7.6], [IARC.8.3])*

### Engine independence

Each `ds_engine_t` is an independent engine with its own working memory, agenda, rule set, clock, recorder and Rete network.

libds holds no global state and no singleton. All engine state hangs off the engine handle.

*(Spec: [IARC.1.11], [IARC.3.2.3])*

### Callback boundary

Every interaction across libds's boundary goes through a typed callback the integrator registers.

libds defines the shape of the data that crosses (metric name, value and labels; log event, level and message; cache key, value and TTL; call request and reply; stream events) and never its bytes, framing or transport. It opens no socket, writes no file and calls no remote API. There is no peer, wire, adapter, storage or debug module, and no protobuf wire codec: debug tooling and introspection subscribe to the stream callback.

Every callback runs on the pump's thread. An unregistered callback is a silent drop for a non-essential verb (`log`, and `cache` when storage is not required) and an error for an essential one (`call` with no target registered).

*(Spec: [IARC.1.14], [IARC.2.3], [IARC.3.5.3], [IARC.8.4], [IARC.8.6])*

### Compiled artefact

The `.dsc` artefact is a one-way compiler-to-runtime input, loaded once at engine setup.

libds owns its decoder. The compiler is a separate program, written in Mercury, under `compiler/`; libds contains no compiler code, and neither links the other. libds never invokes the compiler. The artefact carries the schemas, the rules and the Rete network (`AlphaNode`, `BetaNode`, `TerminalNode`), plus sidecar metadata of DS-level rule, schema and binding names and source locations, from which the debugger and the recorder emit DS-level names. Each schema's `.proto` ships inside the artefact; an integrator that encodes facts reads it and runs its own encoder.

*(Spec: [IARC.1.6], [IARC.1.15], [IARC.5.1], [IARC.5.3], [IARC.5.4], [IARC.5.5], [IARC.5.6], [IARC.5.8])*

### No printf family

libds links no function of the C `printf` family.

No object libds compiles defines or references `printf`, `fprintf`, `sprintf`, `snprintf`, `dprintf`, `asprintf`, their `v`-prefixed and wide-character forms, or a fortified `__*printf_chk` variant. The shipped `libprotobuf-c` archive is held to the same rule. In an archive built without RE2 the rule binds every member; in one that carries RE2, the folded-in RE2 and Abseil objects are not bound.

libds renders all its text with its own formatting operations: integers, the canonical `Float` form and its parse, and interpolation. An interpolated string arrives as primitives, and the loader refuses one whose alignment, type or time field is not a member of its enumeration in `proto/rete_expr.proto` with `DS_ERR_DSC_SEMANTIC`. The loader does not check a format spec against the type it formats. A build whose archive violates the rule is invalid; a symbol census of every shipped archive enforces it.

*(Spec: [IARC.1.16])*

### Link dependencies

libds links `libprotobuf-c` and the standard C library (`-lpthread`, `-lm`).

`libprotobuf-c` decodes atom bodies on the artefact-load path and no module uses it for anything else. Atom bodies are uncompressed, and libds carries no decompressor. libds links no test framework and no wire, transport or RPC library. In a build that carries RE2, the RE2 and Abseil objects are folded into `libds.a` at pinned versions, and an integrator links nothing further for them; a build without RE2 carries neither.

*(Spec: [IARC.7.2], [IARC.7.4], [IARC.7.6], [IARC.7.7], [IARC.7.8], [IARC.7.9], [IARC.7.15])*

### Vendored numerics

libds compiles its numeric primitives from vendored, pinned, unmodified sources.

| Source | Use | Build |
|---|---|---|
| CORE-MATH, binary64 | the correctly rounded functions | one pinned upstream commit, through the RE2 pinned-fetch path; `-O2 -ffp-contract=off -std=gnu11`, on a toolchain whose `FLT_EVAL_METHOD` is 0 |
| Dragonbox `to_chars`, compact cache | shortest `Float` text | pinned release, every file's digest recorded |
| fast_float | `Float` parse | pinned release, every file's digest recorded |
| musl `fma` | the fused multiply-add | pinned source, compiled with the flags its pin records, renamed to a name private to libds |

A pin and its flags are recorded together, and a change to either re-admits each release row before it ships. A fixed precision is rounded from the binary value by exact integer arithmetic, with no table and no allocation. The compiler and the Mercury runtime call the same vendored float-text code and the same compiled `fma`. A fused multiply-add in CORE-MATH is the private `fma` or, on a row whose baseline ISA has one, the instruction; libds's objects do not reference the C library's `fma`.

*(Spec: [IARC.7.10], [IARC.7.13], [IARC.7.14])*

### Undefined symbols

Each release row carries an allowlist of the symbols its `libds.a` may leave undefined.

The build fails on any other undefined symbol.

*(Spec: [IARC.7.12])*

## Modules

### Module graph

The `engine` module composes every other module, and calls run only downward.

| Header | Depends on |
|---|---|
| `clock.h` | no module |
| `wm.h`, `schema.h`, `dispatcher.h`, `recorder.h`, `telemetry.h` | `libds.h`, `clock.h` |
| `engine.h` | every other module's internal header |
| `libds.h` | the standard library only |

The subsystem modules do not depend on each other: a horizontal call (`wm` to `dispatcher`) goes through `engine`. Header hygiene enforces the graph; no tool does.

*(Spec: [IARC.2.1], [IARC.2.2], [IARC.2.4]–[IARC.2.8])*

### Subsystem mapping

Each runtime subsystem is one libds module.

| Runtime subsystem | Module |
|---|---|
| Consumption loop | `engine` |
| Working memory | `wm` |
| Schema registry | `schema` |
| Rete network | `rete` |
| Agenda and conflict resolver | `agenda` |
| Clock source | `clock` |
| Recorder | `recorder` |
| Dispatcher | `dispatcher` |
| Telemetry | `telemetry` |

`schema` and `telemetry` correspond to no runtime-spec subsystem. Cross-process and cross-machine I/O is the integrator's and no module's.

*(Spec: [IARC.4.1], [IARC.4.2])*

### engine

`engine` hosts the Rete network and runs the [consumption loop](runtime-architecture.md#consumption-loop).

It owns no intake: its input is what the integrator asserts, through the assert API or by event-trace replay. Its public entry points create and destroy an engine, load compiled rules, feed inbound facts, pump and install callbacks; there is no start or stop.

*(Spec: [IARC.3.2.1], [IARC.3.2.4])*

### Init and teardown order

`ds_engine_new` initialises every subsystem, and `ds_engine_free` destroys every subsystem.

A subsystem is initialised after, and destroyed before, every subsystem it borrows from. Teardown is not the reverse of initialisation. When an initialisation fails, `ds_engine_new` destroys the subsystems already initialised.

Initialisation order:

1. clock, `ds_clock_init`, which reads the `CLOCK_MONOTONIC` baseline;
2. telemetry, `ds_telemetry_init`;
3. recorder, `ds_recorder_init`;
4. schema registry, `ds_schema_registry_init`;
5. working memory, `ds_wm_init`;
6. dispatcher, `ds_dispatcher_init`;
7. rete engine, `ds_rete_engine_create`, which owns the matching network and the string-intern table;
8. cache, `ds_cache_init`;
9. series-state registry, `ds_series_state_registry_init`;
10. series-backend registry, `ds_engine_series_registry_init`, filled with the built-in backends.

Destruction order:

1. dispatcher;
2. working memory, with its facts;
3. schema registry;
4. recorder;
5. telemetry;
6. series-state registry, after each row's backend state is released through its backend's `instance_free`;
7. cache;
8. series-backend registry;
9. rete engine.

The clock holds nothing to destroy.

*(Spec: [IARC.3.2.5])*

### wm

`wm` is working memory.

It owns fact-identity hashing for no-op-reassertion suppression, the bookkeeping of [TTL expiry](runtime-architecture.md#ttl-expiry), the truth maintenance of [logical facts](runtime-architecture.md#logical-facts), and the translation between DS-typed values and the network's slot-value encodings.

*(Spec: [IARC.3.3])*

### agenda

`agenda` holds the conflict-resolution strategy that enforces the [firing order](runtime-architecture.md#agenda-and-conflict-resolver).

It exposes the unfired activation list for introspection.

*(Spec: [IARC.3.4])*

### dispatcher

`dispatcher` executes the RHS of a fired rule.

It routes each action verb (`log`, `call`, `emit`, `publish`, `cache_*`) to a registered callback, an inline `wm` mutation or a recorder entry, synchronously and with no outbound queue. Each verb is registered as a native Rete builtin. The dispatcher holds the typed callback table for `call`, `cache` and `cache_delete`: a verb's handler decodes the RHS arguments, invokes the registered callback and surfaces an error through the engine's pending-error slot. It also keeps the refraction bookkeeping the agenda reads.

*(Spec: [IARC.3.5.1], [IARC.3.5.2], [IARC.4.2])*

### recorder

`recorder` dispatches stream events inside libds.

Other modules hand it events through its per-kind emit helpers. It assigns each event's `seq`, timestamps it with the engine clock and hands it to the integrator's stream callback; with no callback registered, it drops the event. It writes no trace and keeps no event after delivering it.

*(Spec: [IARC.3.6.1], [IDAT.7.1], [RARC.5.8.1])*

### clock

`clock` is the only module that reads wall time.

It implements the [clock source](runtime-architecture.md#clock-source).

*(Spec: [IARC.3.11.1])*

### telemetry

`telemetry` is the per-engine dispatch table for the metric and operational-log callbacks.

It holds two `{cb, user}` pairs and routes each emit to the registered callback, or drops it when none is registered. It owns no other state; teardown zeroes it.

*(Spec: [IARC.3.12])*

### schema

`schema` owns `ds_schema_t` and the per-engine schema registry.

It validates and registers fact-type declarations, and resolves slot names, types and unit dimensions. `wm` and `dispatcher` consult it to type-check asserted facts and decoded RHS arguments.

*(Spec: [IARC.3.14])*

### json

`json` owns `ds_json_t`.

It parses, builds, queries and serialises the JSON payloads carried by `emit`, `publish` and `cache_*`, and `Json` call arguments.

*(Spec: [IARC.3.15])*

### rete

`rete` is libds's own C Rete matching network.

There is no abstraction layer over a swappable engine.

*(Spec: [IARC.1.9])*

### Handle ownership

Each public handle, and the stream event, belongs to one module.

| Type | Owning module |
|---|---|
| `ds_engine_t` | `engine` |
| `ds_fact_t` | `wm` |
| `ds_schema_t` | `schema` |
| `ds_stream_ev_t` | `recorder` |
| `ds_json_t` | `json` |

A consumer holds only the pointer; a read or a mutation goes through the owning module's exported functions.

*(Spec: [IARC.6.1], [IARC.6.2], [IARC.6.3])*

## Errors and memory

### Result convention

Every libds function that can fail, internal and static ones included, returns `ds_result_t`.

No failure is reported any other way: no status as an `int`, no thread-local `errno` and no call-again-for-detail step. Within one firing the engine's pending-error slot keeps the first error: the trampoline overwrites it only on a non-OK result, and `wm.c` saves and restores it around a nested `ds_engine_assert`.

*(Spec: [IARC.1.12], [IARC.8.1], [IDAT.1.3])*

### Error propagation

A function checks each result, returns a failure unchanged, and returns `DS_OK_R` on completion.

A public-API function replaces a generic inner error with a fresh, more specific outer one only when the outer name is more specific or the inner detail would mislead at that boundary; it never concatenates detail strings or mutates the inner result. Checking a status and discarding the error is a defect. A function that cannot fail returns no result. libds does not log errors: they reach the caller as the result. An error that is semantically observable, such as a rule-fire failure, is also recorded as a stream event.

```c declaration
static ds_result_t step(ds_engine_t *engine) {
    ds_result_t r = ds_engine_pump(engine);
    if (r.status != DS_OK) return r;
    return DS_OK_R;
}
```

*(Spec: [IERR.7])*

### Allocation discipline

Each libds struct has a `ds_<type>_new(engine, ...)` that allocates it and a `ds_<type>_free(obj)` that frees it.

There is no bulk arena or copy-on-write, and each allocation has one owner. Reference counting is used in two places and no others: the intern table's counted entries ([String interning](data-model.md#string-interning)) and the immutable structures a clone shares with its source ([Engine clone](#engine-clone)). Working-memory facts, alpha- and beta-node state and tokens belong to the `rete` and `wm` modules under the same discipline. All allocation goes through the [allocation layer](allocator.md#routing-scope). An allocation failure returns `DS_ERR_OOM` through the result; libds never aborts on it, cleans up what it partially constructed and uses no `longjmp`.

*(Spec: [IARC.1.13], [IARC.8.2])*

## Engine operations

### Engine clone

`ds_engine_clone` copies an engine's mutable state and continues every counter from the source's value.

The per-session immutable structures (the network topology, the schema registry, the loaded artefact) are either shared read-only behind a reference count or copied; a shared owner is reference-counted so the two engines free in either order. The mutable state is deep-copied: the fact set; the alpha memories and beta tokens; the truth-maintenance justifier table; series backings; the TTL structure; the agenda and refraction sets; the clock value; the cache map, verbatim; and the string-intern table, re-created with its content re-interned. The deep copy is a graph clone that maps each old fact pointer to its new one and repoints every fact reference, and every interned-string reference by the old-to-new string map.

`fact_id`, `seq`, activation timetags, the gensym, the cycle generation and every other monotonic counter continue from the source's values. Series backings copy verbatim, the reservoir's `xorshift64` state included. From the clone point each engine advances its own copy: two engines driven with identical input produce byte-identical streams, in parallel or serially.

*(Spec: [IARC.11])*

### Cache seed

`ds_engine_cache_seed` writes a key and value directly into the engine-owned cache store.

It bypasses the dispatcher: it emits no `action_cache_set` event and invokes no write-through callback. The value is serialised by `ds_json_serialize`, the serialiser a rule `cache` write uses, so a seeded and a rule-written value with the same logical JSON store byte-identically. An existing key is overwritten. A `ttl_ns` of 0 is no expiry; any other value is a lifetime counted from the engine's first sample. A recording carries the seed as a `CacheSeed` in the stream's prelude, and a replay applies it before the first input; the integrator does not seed a replaying engine. The artefact's `initial` cache items are placed at the first step.

The seed has two users: an integrator restoring the cache from write-through persistence, and the `.dstest` interpreter applying an `initial: cache` arrange.

*(Spec: [IARC.12], [RARC.5.7.10])*
