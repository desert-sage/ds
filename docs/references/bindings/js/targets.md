<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Targets and entry points

## Entry points

### `@ds-lang/ds`

**`import * as ds from "@ds-lang/ds"`**

The package's main entry point, for Node.

It exports [`open`](#open-on-node), [`installed`](#installed), [`Engine`](engine.md#engine-1), [`Fact`](facts.md#fact), [`JsonText`](facts.md#jsontext), [`Clock`](clock.md#clock-1), [`EngineEvent`](callbacks.md#engineevent), [`STREAM_EVENT_KINDS`](callbacks.md#stream_event_kinds), [`Cache`](callbacks.md#cache), [`DsError`](errors.md#dserror), [`CompileRefused`](compile.md#compilerefused), [`status`](errors.md#status), [`compile`](compile.md#compile-1), [`compileFile`](compile.md#compilefile), [`compileWasm`](compile.md#compilewasm), [`runDsc`](compile.md#rundsc), [`compileUnderWasm`](compile.md#compileunderwasm), [`compileFileUnderWasm`](compile.md#compilefileunderwasm) and [`runDscUnderWasm`](compile.md#rundscunderwasm).

A resolver that applies the `browser` export condition resolves this path to `lib/browser.js`, as [`@ds-lang/ds/browser`](#ds-langdsbrowser).

*(Source: bindings/js/package.json, bindings/js/types/index.d.ts, bindings/js/lib/index.js)*

### `@ds-lang/ds/browser`

**`import * as ds from "@ds-lang/ds/browser"`**

The entry point for a page. It imports nothing from Node.

It exports [`open`](#open-in-a-browser), [`Engine`](engine.md#engine-1), [`Fact`](facts.md#fact), [`JsonText`](facts.md#jsontext), [`Clock`](clock.md#clock-1), [`EngineEvent`](callbacks.md#engineevent), [`STREAM_EVENT_KINDS`](callbacks.md#stream_event_kinds), [`Cache`](callbacks.md#cache), [`DsError`](errors.md#dserror), [`CompileRefused`](compile.md#compilerefused), [`status`](errors.md#status), [`compileWasm`](compile.md#compilewasm) and [`runDsc`](compile.md#rundsc).

*(Source: bindings/js/package.json, bindings/js/types/browser.d.ts, bindings/js/lib/browser.js)*

### `@ds-lang/ds/status`

**`import * as status from "@ds-lang/ds/status"`**

The status codes alone. It loads no libds.

*(Source: bindings/js/package.json, bindings/js/types/status.d.ts)*

## Opening a target

### `open` on Node

**`export function open(options?: { target?: Target; }): Promise<Api<NodeHost> | Api<NodeWasmHost>>;`**

Loads libds for a [`Target`](#target) and resolves to the [`Api`](#api) bound to it.

With no `target` under Node, `open` loads the native target where it is installed, and otherwise the wasm target where both it and its compiler `ds_dsc` are installed. With neither, it rejects with `Error`, naming the native, wasm and `ds_dsc` paths. Outside Node, `target` defaults to `"wasm"`. The native target compiles with the `dsc` binary. The wasm target compiles with the wasm compiler, and loads emnapi's runtime from `@emnapi/runtime`.

A target that is not installed rejects with `Error`, and no other target is tried in its place. Another value of `target` rejects with `TypeError`.

```javascript statement
const api = await ds.open({ target: "wasm" });
const e = new api.Engine({ runId: "r1" });
e.close();
```

*(Source: bindings/js/types/index.d.ts, bindings/js/lib/index.js)*

### `open` in a browser

**`export function open({ glue, runtime, wasmBinary, compiler, compilerWasm }: { glue: ModuleSource; runtime: ModuleSource; wasmBinary?: ArrayBuffer | Uint8Array<ArrayBufferLike> | undefined; compiler?: ModuleSource | undefined; compilerWasm?: ArrayBuffer | Uint8Array<ArrayBufferLike> | undefined; }): Promise<Api<BrowserHost>>;`**

Loads libds as wasm in a page and resolves to the [`Api`](#api) bound to it.

| Option | Holds |
|---|---|
| `glue` | `ds_wasm.mjs`: its factory, its module or its URL |
| `runtime` | `@emnapi/runtime`: its module or its URL |
| `wasmBinary` | the `.wasm`; absent, the glue fetches it from beside its own URL |
| `compiler` | `ds_dsc.mjs`, the wasm compiler: its factory, its module or its URL; absent, compiling throws `Error` |
| `compilerWasm` | the wasm compiler's `.wasm`; absent, the compiler fetches it from beside itself |

A `glue` or `runtime` that is absent, or that is not the module named, rejects with `TypeError`.

*(Source: bindings/js/types/browser.d.ts, bindings/js/lib/browser.js)*

### One target per realm

A realm loads libds once, for one target through one entry point.

An `open` for the same target through the same entry point resolves to the first `Api`, and does not read its arguments. Any other `open` rejects with `Error`. A load that fails leaves the realm free for another `open`.

[`Engine`](engine.md#engine-1) and [`Fact`](facts.md#fact) are module-level classes, and reach libds through the realm's one load.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js)*

### `installed`

**`export function installed(): { native: string | null; wasm: string | null; wasmCompiler: string | null; };`**

Reports what is installed: the native target, the wasm target and the wasm compiler, each by its path, or `null` where it is not. Exported by `@ds-lang/ds` only.

*(Source: bindings/js/types/index.d.ts, bindings/js/lib/index.js)*

## Bound API

### `Target`

**`export type Target = "native" | "wasm";`**

A build of libds: `"native"` through Node-API, `"wasm"` through emnapi.

*(Source: bindings/js/types/types.d.ts)*

### `Api`

**`export type Api<H extends Host> = { target: Target; Engine: typeof Engine; Fact: typeof Fact; JsonText: typeof JsonText; EngineEvent: typeof EngineEvent; STREAM_EVENT_KINDS: readonly StreamEventKind[]; DsError: typeof DsError; CompileRefused: typeof CompileRefused; status: typeof status; setUnraisableHook: (fn: UnraisableHook | null) => UnraisableHook; compile: H["compile"]; compileFile: H["compileFile"]; fromSource: FromSource<H["compile"]>; readAtoms: (bytes: Uint8Array, options?: { incremental?: boolean; }) => AtomsRead; messageName: (field: number) => string | null; decodeAnnouncedFactBody: (slots: AnnouncedSlot[], body: Uint8Array) => Record<string, SlotValue>; decodeAnnouncedFactBodyHandles: (slots: AnnouncedSlot[], body: Uint8Array) => AnnouncedBody; };`**

The frozen object `open` resolves to, for the host `H` that opened it.

`target` is the [`Target`](#target) loaded. `compile`, `compileFile` and [`fromSource`](compile.md#fromsource) are the host's, and [`setUnraisableHook`](callbacks.md#setunraisablehook), [`readAtoms`](recording.md#readatoms), [`messageName`](recording.md#messagename), [`decodeAnnouncedFactBody`](recording.md#decodeannouncedfactbody) and [`decodeAnnouncedFactBodyHandles`](recording.md#decodeannouncedfactbodyhandles) are reached only through this object.

*(Source: bindings/js/types/types.d.ts, bindings/js/lib/bind.js)*

## Hosts

### `Host`

**`export type Host = { file: ((path: string) => FileSink) | null; compile: (source: string, options?: never) => Uint8Array | Promise<Uint8Array>; compileFile: (path: string, options?: never) => Uint8Array | Promise<Uint8Array>; };`**

What a platform gives the [`Api`](#api): how [`recordTo`](recording.md#recordto) opens a path, and the compiler.

`file` is `null` where there is no file system.

*(Source: bindings/js/types/types.d.ts)*

### `NodeHost`

**`export type NodeHost = { file: (path: string) => FileSink; compile: typeof compile; compileFile: typeof compileFile; };`**

Node's [`Host`](#host) on the native target. [`compile`](compile.md#compile-1) and [`compileFile`](compile.md#compilefile) run the `dsc` binary, and return bytes.

*(Source: bindings/js/types/index.d.ts, bindings/js/lib/index.js)*

### `NodeWasmHost`

**`export type NodeWasmHost = { file: (path: string) => FileSink; compile: typeof compileUnderWasm; compileFile: typeof compileFileUnderWasm; };`**

Node's [`Host`](#host) on the wasm target. `compile` and `compileFile` run the wasm compiler, and return a `Promise`.

*(Source: bindings/js/types/index.d.ts, bindings/js/lib/index.js)*

### `BrowserHost`

**`export type BrowserHost = { file: null; compile: (source: string, options?: WasmCompileOptions) => Promise<Uint8Array>; compileFile: (path: string) => never; };`**

A page's [`Host`](#host). It has no file system, and its `compileFile` throws `Error`.

`compile` runs the compiler given to [`open`](#open-in-a-browser), and throws `Error` where none was given.

*(Source: bindings/js/types/browser.d.ts, bindings/js/lib/browser.js)*

### `GlueFactory`

**`export type GlueFactory = (options: { wasmBinary?: Uint8Array | ArrayBuffer; }) => Promise<{ emnapiInit: (options: { context: unknown; }) => Glue; }>;`**

The factory `ds_wasm.mjs` exports by default, as [`open`](#open-in-a-browser) calls it.

`open` passes `wasmBinary` when it was given one.

*(Source: bindings/js/types/browser.d.ts, bindings/js/lib/browser.js)*

### `ModuleSource`

**`export type ModuleSource = Function | object | string | URL;`**

An emscripten module a page hands to [`open`](#open-in-a-browser): its factory, the module, or a URL to import it from.

*(Source: bindings/js/types/types.d.ts, bindings/js/lib/browser.js)*
