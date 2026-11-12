<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Engine

## Lifecycle

### `Engine`

**`def __init__(self, *, run_id: str | None = None, tier_id: str | None = None) -> None`**

One libds engine, created by [`ds_engine_new`](inv:integrator:std:doc#engine/lifecycle) from a [`ds_engine_config_t`](inv:integrator:std:doc#engine/lifecycle).

`run_id` and `tier_id` are each a `str` or `None`. A value of another type raises `TypeError`, and one holding a NUL raises `ValueError`.

An engine collected without `close` is freed, and emits a `ResourceWarning`. A call that libds refuses raises an [`Error`](errors.md#error).

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/pyds/_pyds.pyi, bindings/python/src/_pyds/engine.c)*

### `close`

**`def close(self) -> None`**

Releases the engine through [`ds_engine_free`](inv:integrator:std:doc#engine/lifecycle), with the [callbacks](callbacks.md#callback-attributes) it holds and a running [`Recording`](recording.md#recording-1).

A second `close` does nothing. After `close`, every call but `close` and [`closed`](#closed) raises `ValueError`. A `close` that libds refuses raises and changes nothing.

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/_pyds/engine.c)*

### `closed`

**`closed: bool`**

Whether `close` has released the engine.

*(Source: bindings/python/src/pyds/_pyds.pyi, bindings/python/src/_pyds/engine.c)*

### `with`

**`with Engine() as e:`**

A block that binds the engine and calls `close` when it ends.

`__exit__` suppresses no exception.

```python statement
with pyds.Engine(run_id="r1", tier_id="t1") as e:
    e.pump()
```

*(Source: bindings/python/src/pyds/engine.py)*

### `clone`

**`def clone(self, /) -> Self`**

Returns an independent copy of the engine, made by [`ds_engine_clone`](inv:integrator:std:doc#engine/lifecycle).

The copy has the type of the engine cloned, and its `run_id` and `tier_id`.

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/pyds/_pyds.pyi, bindings/python/src/_pyds/engine.c)*

### `run_id`

**`run_id: str | None`**

The run id, read by [`ds_engine_get_run_id`](inv:integrator:std:doc#engine/lifecycle).

It is `None` for an id not given or given as `""`.

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/_pyds/engine.c)*

### `tier_id`

**`tier_id: str | None`**

The tier id, read by [`ds_engine_get_tier_id`](inv:integrator:std:doc#engine/lifecycle).

It is `None` for an id not given or given as `""`.

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/_pyds/engine.c)*

## Running

### `load_dsc`

**`def load_dsc(self, dsc: Buffer, /) -> None`**

Loads a compiled artefact through [`ds_engine_load_dsc`](inv:integrator:std:doc#engine/loading).

`dsc` is any bytes-like object, such as what [`compile`](compile.md#compile-1) returns.

*(Source: bindings/python/src/pyds/_pyds.pyi)*

### `pump`

**`def pump(self, /) -> None`**

Runs one pump, through [`ds_engine_pump`](inv:integrator:std:doc#engine/pump).

*(Source: bindings/python/src/pyds/_pyds.pyi)*

## Halt

### `halted`

**`halted: EngineFault | None`**

The fault that halted the engine, read by [`ds_engine_halted`](inv:integrator:std:doc#engine/lifecycle).

It is `None` until the [halt latch](inv:integrator:std:doc#engine/lifecycle) is set, and `EngineFault.UNSPECIFIED` for an engine a failed load spent.

```{note}
`EngineFault.UNSPECIFIED` is `0`, and false. Compare `halted` with `None`.
```

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/pyds/_faults.py)*

### `EngineFault`

**`class EngineFault(enum.IntEnum)`**

What halted the engine: [`ds_engine_fault_t`](inv:integrator:std:doc#callbacks/stream), with each member's `DS_ENGINE_FAULT_` prefix removed.

Its members are `UNSPECIFIED`, `ARTEFACT_LIED`, `PATTERN_INDEX`, `BINDING_ORDER`, `ORDER_KEY`, `ALLOCATION`, `PUMP_WCET` and `INTERNAL`.

*(Source: bindings/python/src/pyds/_faults.py)*

## Memory

### `memory_usage`

**`def memory_usage(self) -> MemoryUsage`**

Measures the engine through [`ds_engine_mem`](inv:integrator:std:doc#introspection/network).

*(Source: bindings/python/src/pyds/engine.py)*

### `MemoryUsage`

**`MemoryUsage(wm_fact_count, wm_fact_bytes, wm_index_bytes, alpha_node_count, alpha_match_count, alpha_index_bytes, beta_node_count, beta_token_count, beta_token_bytes, beta_index_bytes, intern_count, intern_string_bytes, intern_index_bytes, pool_reserved_bytes, total_bytes)`**

A frozen dataclass of [`ds_engine_mem_t`](inv:integrator:std:doc#introspection/network).

Each field is an `int`.

*(Source: bindings/python/src/pyds/engine.py)*

## Provenance

### `platform_signature`

**`platform_signature: PlatformSignature`**

The engine's platform signature, read by [`ds_engine_get_platform_signature`](inv:integrator:std:doc#determinism/provenance).

*(Source: bindings/python/src/pyds/engine.py)*

### `PlatformSignature`

**`PlatformSignature(os_family, cpu_arch, libc, compiler, libds_version, backends)`**

A frozen dataclass of [`ds_platform_signature_t`](inv:integrator:std:doc#determinism/provenance).

`backends` is a `tuple` of `str`, and every other field a `str`.

*(Source: bindings/python/src/pyds/engine.py)*

### `session_header`

**`session_header: SessionHeader`**

The engine's session header, read by [`ds_engine_get_session_header`](inv:integrator:std:doc#determinism/provenance).

*(Source: bindings/python/src/pyds/engine.py)*

### `SessionHeader`

**`SessionHeader(ds_version, session_id="", tier_id="", dsc_hash=None, capabilities=(), dialect_def_sha256=None)`**

A frozen dataclass of [`ds_session_header_t`](inv:integrator:std:doc#determinism/provenance).

Until a program is loaded, `dsc_hash` and `dialect_def_sha256` are `None`, and `capabilities` is empty. After a load, the two hashes are `bytes`. `capabilities` is a `tuple` of `Capability`.

*(Source: bindings/python/src/pyds/session.py, bindings/python/src/pyds/engine.py)*

## Capabilities

### `BUILD_CAPABILITIES`

**`BUILD_CAPABILITIES: frozenset[Capability]`**

The capabilities this build of libds has code for, read once by [`ds_build_capabilities`](inv:integrator:std:doc#engine/loading).

*(Source: bindings/python/src/pyds/__init__.py)*

### `Capability`

**`class Capability(enum.IntEnum)`**

A capability: [`ds_capability_t`](inv:integrator:std:doc#engine/loading), with each member's `DS_CAPABILITY_` prefix removed.

Its members are `REALTIME`, `CONSTSPACE`, `LINEAR_SCAN`, `LOGICAL`, `DYNAMIC_TTL`, `REGEX`, `FLOAT`, `CALL`, `PUBLISH`, `CACHE`, `CACHE_DELETE`, `NOCOOLDOWN`, `SERIES`, `SAMPLED_SLOTS`, `PERSIST_ON_SERIES`, `STORAGE_HYDRATE_FACTS` and `STORAGE_HYDRATE_SAMPLES`. The name a program writes is the member's in lower case.

*(Source: bindings/python/src/pyds/_capability.py)*

### `set_admission`

**`def set_admission(self, capability: Capability, admission: Admission, /) -> None`**

Sets the admission policy for one capability, through [`ds_engine_set_admission`](inv:integrator:std:doc#engine/loading).

A `capability` or `admission` that is not an `int`, or is a `bool`, raises `TypeError`. One that names no member raises `ValueError`.

*(Source: bindings/python/src/pyds/engine.py)*

### `Admission`

**`class Admission(enum.IntEnum)`**

Which settings of one capability an engine admits: [`ds_admission_t`](inv:integrator:std:doc#engine/loading), with each member's `DS_ADMIT_` prefix removed.

Its members are `EITHER`, `TRUE_ONLY` and `FALSE_ONLY`.

*(Source: bindings/python/src/pyds/enums.py)*
