<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Engine

## Lifecycle

### `Engine`

**`constructor(options?: { runId?: string | null; tierId?: string | null; });`**

One libds engine, created by [`ds_engine_new`](inv:integrator:std:doc#engine/lifecycle) from a [`ds_engine_config_t`](inv:integrator:std:doc#engine/lifecycle).

`class Engine extends EventTarget`. A realm that has not [opened](targets.md#one-target-per-realm) libds throws `Error`. `runId` or `tierId` of another type, or a string holding U+0000 or a lone surrogate, throws `TypeError`. A call that libds refuses throws a [`DsError`](errors.md#dserror). An engine collected without `close` is freed.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c)*

### `close`

**`close(): void;`**

Releases the engine through [`ds_engine_free`](inv:integrator:std:doc#engine/lifecycle), with its callbacks and a running recording.

A second `close` does nothing. After `close`, a call that reaches libds through the engine, its [`Clock`](clock.md#clock-1) or its [`Cache`](callbacks.md#cache) throws a [`DsError`](errors.md#dserror) with `DS_ERR_STATE`, and each of its [`Fact`](facts.md#fact)s is dead. A `close` inside one of the engine's callbacks or its recording sink throws a `DsError` with `DS_ERR_STATE`, and changes nothing.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c)*

### `using`

**`[Symbol.dispose](): void;`**

Calls [`close`](#close) when the scope of a `using` declaration ends.

A platform with no `Symbol.dispose` has no such method.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js)*

### `clone`

**`clone(): Engine;`**

Returns an independent copy of the engine, made by [`ds_engine_clone`](inv:integrator:std:doc#engine/lifecycle).

The copy has its own [`Clock`](clock.md#clock-1) and [`Cache`](callbacks.md#cache), and no listener or callback of the source's. A [`Fact`](facts.md#fact) of the source is refused by the copy with `DS_ERR_FACT_INVALID`, and [`factById`](facts.md#factbyid) finds the copy's fact.

```javascript statement
const copy = engine.clone();
copy.pump();
copy.close();
```

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c)*

### `runId`

**`get runId(): string | null;`**

The run id, read by [`ds_engine_get_run_id`](inv:integrator:std:doc#engine/lifecycle).

It is `null` for an id not given or given as `""`.

*(Source: bindings/js/types/bind.d.ts, bindings/js/src/ds.c)*

### `tierId`

**`get tierId(): string | null;`**

The tier id, read by [`ds_engine_get_tier_id`](inv:integrator:std:doc#engine/lifecycle).

It is `null` for an id not given or given as `""`.

*(Source: bindings/js/types/bind.d.ts, bindings/js/src/ds.c)*

## Running

### `loadDsc`

**`loadDsc(bytes: Uint8Array): void;`**

Loads a compiled artefact through [`ds_engine_load_dsc`](inv:integrator:std:doc#engine/loading).

A value that is not a `Uint8Array` throws `TypeError`. The next read of [`schemas`](program.md#schemas), [`rules`](program.md#rules) or [`lineSpans`](program.md#linespans) reads the engine again, whether the load succeeded or not.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c)*

### `pump`

**`pump(): void;`**

Runs one pump, through [`ds_engine_pump`](inv:integrator:std:doc#engine/pump).

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js)*

## Halt

### `halted`

**`get halted(): number | null;`**

The fault that halted the engine, read by [`ds_engine_halted`](inv:integrator:std:doc#engine/lifecycle), as the number of its [`ds_engine_fault_t`](inv:integrator:std:doc#callbacks/stream).

It is `null` until the [halt latch](inv:integrator:std:doc#engine/lifecycle) is set, and `0` for an engine a failed load spent.

```{note}
A halted engine can read `0`, which is falsy. Compare `halted` with `null`.
```

*(Source: bindings/js/types/bind.d.ts, bindings/js/src/ds.c)*

## Measurement

### `memory`

**`memory(): MemoryReport;`**

Measures the engine through [`ds_engine_mem`](inv:integrator:std:doc#introspection/network).

It walks the engine's structures at each call.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js)*

### `MemoryReport`

**`export type MemoryReport = { wmFactCount: number; wmFactBytes: number; wmIndexBytes: number; alphaNodeCount: number; alphaMatchCount: number; alphaIndexBytes: number; betaNodeCount: number; betaTokenCount: number; betaTokenBytes: number; betaIndexBytes: number; internCount: number; internStringBytes: number; internIndexBytes: number; poolReservedBytes: number; totalBytes: number; };`**

A plain object of [`ds_engine_mem_t`](inv:integrator:std:doc#introspection/network), each field in camelCase, as a `Number`.

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c)*

## Provenance

### `platformSignature`

**`get platformSignature(): PlatformSignature;`**

The engine's platform signature, read by [`ds_engine_get_platform_signature`](inv:integrator:std:doc#determinism/provenance).

Each read makes a new snapshot.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js)*

### `PlatformSignature`

**`export type PlatformSignature = { osFamily: string; cpuArch: string; libc: string; compiler: string; libdsVersion: string; backends: string[]; };`**

A plain object of [`ds_platform_signature_t`](inv:integrator:std:doc#determinism/provenance), each field in camelCase.

*(Source: bindings/js/types/types.d.ts, bindings/js/src/ds.c)*

### `sessionHeader`

**`get sessionHeader(): SessionHeader;`**

The engine's session header, read by [`ds_engine_get_session_header`](inv:integrator:std:doc#determinism/provenance).

Each read makes a new snapshot.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js)*

### `SessionHeader`

**`export type SessionHeader = { dsVersion: string; sessionId: string; tierId: string; dscHash: Uint8Array | null; };`**

A plain object of [`ds_session_header_t`](inv:integrator:std:doc#determinism/provenance), each field in camelCase.

`dscHash` is a copy of the loaded artefact's hash, and `null` before a load.

*(Source: bindings/js/types/types.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c)*
