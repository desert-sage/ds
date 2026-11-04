// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
/**
 * What is installed here, each by its path, or null where it is not: the
 * native target, the wasm one, and ds_dsc, the compiler the wasm
 * target needs.
 * @returns {{ native: string | null, wasm: string | null, wasmCompiler: string | null }}
 */
export function installed(): {
    native: string | null;
    wasm: string | null;
    wasmCompiler: string | null;
};
/**
 * Compile DS source text to .dsc bytes with ds_dsc: compile.js's
 * `compile` under wasm, the same argv and the same errors, and async.
 * @param {string} source
 * @param {CompileOptions} [options]
 * @returns {Promise<Uint8Array>}
 */
export function compileUnderWasm(source: string, { file, searchPath }?: CompileOptions): Promise<Uint8Array>;
/**
 * Run ds_dsc once with `argv`, as the binary takes it: dsc-wasm.js's
 * `runDsc` with the compiler this package finds, for a subcommand `@ds-lang/ds`
 * has no call for (`dump-ast`).
 * @param {string[]} argv
 * @param {{ stdin?: Uint8Array, files?: Record<string, string | Uint8Array> }} [io]
 * @returns {Promise<{ status: number, stdout: Uint8Array, stderr: string }>}
 */
export function runDscUnderWasm(argv: string[], { stdin, files }?: {
    stdin?: Uint8Array;
    files?: Record<string, string | Uint8Array>;
}): Promise<{
    status: number;
    stdout: Uint8Array;
    stderr: string;
}>;
/**
 * Compile a .ds file with ds_dsc: compile.js's `compileFile` under
 * wasm, the same argv, `dsc compile <path>`, and the same errors. The file and
 * its companion `.dstest` ([LTSL.2.4]) are written into the compiler's file
 * system at the path as given, where the argv names them, so the artefact
 * names the file as the native compiler's does. `searchPath` defaults to the
 * file's directory.
 * @param {string} path
 * @param {Omit<CompileOptions, "file">} [options]
 * @returns {Promise<Uint8Array>}
 */
export function compileFileUnderWasm(path: string, { searchPath }?: Omit<CompileOptions, "file">): Promise<Uint8Array>;
/**
 * Load libds for a target and return the API bound to it: on native, `dsc`
 * compiles; on wasm, ds_dsc, and `compile` and `compileFile` are async.
 *
 * With no `target`, the one installed here: native where it is, else wasm
 * where its compiler is too, else refused. A named target that is not
 * installed is refused, never swapped for the other.
 *
 * A realm loads one target. open() again for the same target returns the same
 * API; for the other one it is refused.
 *
 * @param {{ target?: Target }} [options]
 * @returns {Promise<Api<NodeHost> | Api<NodeWasmHost>>}
 */
export function open(options?: {
    target?: Target;
}): Promise<Api<NodeHost> | Api<NodeWasmHost>>;
export * from "./types.js";
/**
 * Node's host on the native target: `recordTo` writes a path as it goes, and
 * the native `dsc` compiles.
 */
export type NodeHost = {
    file: (path: string) => FileSink;
    compile: typeof compile;
    compileFile: typeof compileFile;
};
/**
 * Node's host on the wasm target: `recordTo` as on native, and ds_dsc
 * compiles, async, as in a page.
 */
export type NodeWasmHost = {
    file: (path: string) => FileSink;
    compile: typeof compileUnderWasm;
    compileFile: typeof compileFileUnderWasm;
};
import type { CompileOptions } from "./types.js";
import type { Target } from "./types.js";
import type { Api } from "./types.js";
import { status } from "./bind.js";
import { DsError } from "./bind.js";
import { Engine } from "./bind.js";
import { EngineEvent } from "./bind.js";
import { STREAM_EVENT_KINDS } from "./bind.js";
import { Clock } from "./bind.js";
import { Cache } from "./bind.js";
import { Fact } from "./bind.js";
import { JsonText } from "./bind.js";
import { compile } from "./compile.js";
import { compileFile } from "./compile.js";
import { CompileRefused } from "./bind.js";
import type { FileSink } from "./types.js";
export { status, DsError, Engine, EngineEvent, STREAM_EVENT_KINDS, Clock, Cache, Fact, JsonText, compile, compileFile, CompileRefused };
export { compileWasm, runDsc } from "./dsc-wasm.js";
