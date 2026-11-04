<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Compile

## Each target's compiler

### Compilers

Which compiler runs for each host.

| Reached through | Compiler | Returns |
|---|---|---|
| [`Api`](targets.md#api)'s `compile` and `compileFile`, native target of [`open`](targets.md#open-on-node) | the `dsc` binary | `Uint8Array` |
| `Api`'s `compile` and `compileFile`, wasm target of [`open`](targets.md#open-on-node) | the wasm compiler [`installed`](targets.md#installed) reports | `Promise<Uint8Array>` |
| `Api`'s `compile` in a page | the `compiler` given to [`open`](targets.md#open-in-a-browser) | `Promise<Uint8Array>` |
| the module's [`compile`](#compile-1), [`compileFile`](#compilefile) | the `dsc` binary, on any target | `Uint8Array` |

The binary is the path in the environment variable `DS_MERCURY_DSC`, if set and not empty, and otherwise `dsc` on `PATH`.

*(Source: bindings/js/types/index.d.ts, bindings/js/types/browser.d.ts, bindings/js/lib/index.js, bindings/js/lib/browser.js, bindings/js/lib/compile.js)*

## The `dsc` binary

### `compile`

**`export function compile(source: string, { file, searchPath }?: CompileOptions): Uint8Array;`**

Compiles DS source text to `.dsc` bytes for [`loadDsc`](engine.md#loaddsc), with `dsc compile - -o - --filename <file>` and a `-L` for each `searchPath` directory. Exported by `@ds-lang/ds`.

| Throws | Condition |
|---|---|
| [`CompileRefused`](#compilerefused) | exit status 1 |
| `Error` | any other non-zero status; no binary |
| `TypeError` | `source` is not a string |

*(Source: bindings/js/types/compile.d.ts, bindings/js/lib/compile.js)*

### `compileFile`

**`export function compileFile(path: string, { searchPath }?: Omit<CompileOptions, "file">): Uint8Array;`**

Compiles a `.ds` file with `dsc compile <path> -o -`. Exported by `@ds-lang/ds`.

The compiler reads the file, and its companion `.dstest` beside it. Diagnostics and the artefact name it as given. `searchPath` defaults to the file's directory, and `[]` searches nowhere. A file that cannot be read throws its read error, and otherwise it throws as [`compile`](#compile-1) does.

```javascript statement
const dsc = ds.compileFile("rules.ds");
engine.loadDsc(dsc);
```

*(Source: bindings/js/types/compile.d.ts, bindings/js/lib/compile.js)*

### `CompileOptions`

**`export type CompileOptions = { file?: string; searchPath?: string[]; };`**

How a compile is run.

`file` is what diagnostics and the artefact's `DsSource` atom call the source, and defaults to `"<input>"`. `searchPath` directories resolve imports, and default to none.

*(Source: bindings/js/types/types.d.ts, bindings/js/lib/compile.js, Spec: [RDSC.14.2.3])*

### `CompileRefused`

**`constructor(file: string, diagnostics: string);`**

A compile the compiler refused, and `class CompileRefused extends Error`.

`file` is what the source was called, and `diagnostics` is the compiler's report. Its `name` is `"CompileRefused"`, and its `message` is `<file>: refused by dsc`, then a newline and the diagnostics. Every host throws this class.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js)*

## Bound to a target

### `fromSource`

**`fromSource: FromSource<H["compile"]>;`**

Compiles `source` with the [`Host`](targets.md#host)'s `compile`, and returns a new [`Engine`](engine.md#engine-1) with the artefact loaded. A member of the [`Api`](targets.md#api).

`options` go to the `Host`'s `compile` as given. An engine whose load fails is closed, and the failure thrown.

*(Source: bindings/js/types/types.d.ts, bindings/js/lib/bind.js)*

### `FromSource`

**`export type FromSource<C extends Host["compile"]> = (source: string, options?: Parameters<C>[1]) => ReturnType<C> extends Promise<Uint8Array> ? Promise<Engine> : Engine;`**

`fromSource` for a [`Host`](targets.md#host)'s compiler: an [`Engine`](engine.md#engine-1) where compiling returns bytes, and a `Promise` of one where it returns a `Promise`.

*(Source: bindings/js/types/types.d.ts)*

## The wasm compiler

### `compileWasm`

**`export function compileWasm(compiler: ModuleSource, source: string, { file, searchPath, files, wasmBinary, wasmModule, program }?: WasmCompileOptions): Promise<Uint8Array>;`**

Compiles DS source text with a wasm compiler given as `compiler`, a [`ModuleSource`](targets.md#modulesource), with the argv [`compile`](#compile-1) builds. Exported by both `@ds-lang/ds` and `@ds-lang/ds/browser`.

It rejects as `compile` throws. It also rejects as [`runDsc`](#rundsc) does.

*(Source: bindings/js/types/dsc-wasm.d.ts, bindings/js/lib/dsc-wasm.js)*

### `WasmCompileOptions`

**`export type WasmCompileOptions = CompileOptions & { files?: Record<string, string | Uint8Array>; wasmBinary?: Uint8Array | ArrayBuffer; wasmModule?: WebAssembly.Module; program?: string; };`**

A compile under wasm.

| Option | Holds |
|---|---|
| `files` | what the compile reads by path: each `searchPath` directory's files, at those paths |
| `wasmBinary` | the compiler's `.wasm`; absent, the module fetches it from beside itself |
| `wasmModule` | that `.wasm` compiled already |
| `program` | the compiler's own absolute path, its `argv[0]`; absent, `/ds_dsc/bin/dsc` |

The compiler finds its standard library at `<program's directory>/../share/ds/stdlib`. A module carrying `library` writes it there, and `files` are written after it. A bare factory carries no library.

*(Source: bindings/js/types/types.d.ts, bindings/js/lib/dsc-wasm.js)*

### `runDsc`

**`export function runDsc(compiler: ModuleSource, argv: string[], { stdin, files, wasmBinary, wasmModule, program }?: { stdin?: Uint8Array<ArrayBufferLike> | undefined; files?: Record<string, string | Uint8Array<ArrayBufferLike>> | undefined; wasmBinary?: ArrayBuffer | Uint8Array<ArrayBufferLike> | undefined; wasmModule?: WebAssembly.Module | undefined; program?: string | undefined; }): Promise<{ status: number; stdout: Uint8Array; stderr: string; }>;`**

Runs the wasm compiler given as `compiler`, a [`ModuleSource`](targets.md#modulesource), once with `argv`, as the binary takes it without `argv[0]`. Exported by both `@ds-lang/ds` and `@ds-lang/ds/browser`.

Each run instantiates the module afresh. The module's exit becomes `status`, and leaves the process's exit code as it was.

An absent `compiler` rejects with `Error`. A `compiler` that is not the module, or a `program` that is not an absolute path, rejects with `TypeError`.

*(Source: bindings/js/types/dsc-wasm.d.ts, bindings/js/lib/dsc-wasm.js)*

## The wasm compiler under Node

### `compileUnderWasm`

**`export function compileUnderWasm(source: string, { file, searchPath }?: CompileOptions): Promise<Uint8Array>;`**

[`compile`](#compile-1) under the installed wasm compiler. Exported by `@ds-lang/ds`.

The files under each `searchPath` directory are read from disk: `.ds`, `.dsrt` and `.dstest`, skipping `node_modules` and hidden directories. A compiler that is not installed rejects with `Error`.

*(Source: bindings/js/types/index.d.ts, bindings/js/lib/index.js)*

### `compileFileUnderWasm`

**`export function compileFileUnderWasm(path: string, { searchPath }?: Omit<CompileOptions, "file">): Promise<Uint8Array>;`**

[`compileFile`](#compilefile) under the installed wasm compiler. Exported by `@ds-lang/ds`.

The file and its companion `.dstest` are written into the compiler's file system at the path as given. Each `searchPath` directory is read as [`compileUnderWasm`](#compileunderwasm) reads it.

*(Source: bindings/js/types/index.d.ts, bindings/js/lib/index.js)*

### `runDscUnderWasm`

**`export function runDscUnderWasm(argv: string[], { stdin, files }?: { stdin?: Uint8Array; files?: Record<string, string | Uint8Array>; }): Promise<{ status: number; stdout: Uint8Array; stderr: string; }>;`**

[`runDsc`](#rundsc) with the installed wasm compiler. Exported by `@ds-lang/ds`.

A compiler that is not installed rejects with `Error`.

*(Source: bindings/js/types/index.d.ts, bindings/js/lib/index.js)*
