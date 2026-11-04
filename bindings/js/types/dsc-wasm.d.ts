// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
/**
 * Run the compiler once: `{ status, stdout, stderr }`.
 * @param {ModuleSource} compiler  ds_dsc: its factory, module, or URL
 * @param {string[]} argv  as the binary takes it, without argv[0]
 * @param {object} [io]
 * @param {Uint8Array} [io.stdin]
 * @param {Record<string, string | Uint8Array>} [io.files]  path -> contents, written before main
 * @param {Uint8Array | ArrayBuffer} [io.wasmBinary]  the `.wasm`, rather than the module fetching it
 * @param {WebAssembly.Module} [io.wasmModule]  the `.wasm` already compiled, so this run only instantiates
 *   it: a caller that compiles often keeps one
 * @param {string} [io.program]  argv[0], an absolute path, DEFAULT_PROGRAM if none: the compiler finds
 *   the standard library at `<its directory>/../share/ds/stdlib` ([LIMP.3.3.1]), where the package's
 *   own `library` is written
 * @returns {Promise<{ status: number, stdout: Uint8Array, stderr: string }>}
 */
export function runDsc(compiler: ModuleSource, argv: string[], { stdin, files, wasmBinary, wasmModule, program }?: {
    stdin?: Uint8Array<ArrayBufferLike> | undefined;
    files?: Record<string, string | Uint8Array<ArrayBufferLike>> | undefined;
    wasmBinary?: ArrayBuffer | Uint8Array<ArrayBufferLike> | undefined;
    wasmModule?: WebAssembly.Module | undefined;
    program?: string | undefined;
}): Promise<{
    status: number;
    stdout: Uint8Array;
    stderr: string;
}>;
/**
 * Compile DS source text to `.dsc` bytes with ds_dsc: compile.js's
 * `compile` under wasm, the same argv and the same errors, and async.
 *
 * `files` holds what the compile reads by path: each `searchPath` directory's
 * files, at those paths, and with a `program`, the standard library beside it.
 *
 * @param {ModuleSource} compiler
 * @param {string} source
 * @param {WasmCompileOptions} [options]
 * @returns {Promise<Uint8Array>}
 */
export function compileWasm(compiler: ModuleSource, source: string, { file, searchPath, files, wasmBinary, wasmModule, program }?: WasmCompileOptions): Promise<Uint8Array>;
/** argv[0] when the caller names none: an absolute path, so `../share` is too. */
export const DEFAULT_PROGRAM: "/ds_dsc/bin/dsc";
/**
 * The parts of an Emscripten module the runner uses.
 */
export type DscModule = {
    FS: {
        init: (stdin: () => number | null, stdout: (c: number | null) => void, stderr: (c: number | null) => void) => void;
        mkdirTree: (path: string) => void;
        writeFile: (path: string, data: string | Uint8Array) => void;
    };
    callMain: (argv: string[]) => number | undefined;
};
export type DscFactory = (options: object) => Promise<DscModule>;
import type { ModuleSource } from "./types.js";
import type { WasmCompileOptions } from "./types.js";
