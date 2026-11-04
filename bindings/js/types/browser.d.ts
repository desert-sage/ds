// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
/**
 * Load libds as wasm in a page and return the API bound to it: the same API
 * as `open({ target: "wasm" })` under Node.
 *
 * A realm loads libds once. open() again returns the first API, and does not
 * read its arguments.
 *
 * @param {object} o
 * @param {ModuleSource} o.glue  ds_wasm.mjs: its factory (the default
 *   export), the module, or its URL
 * @param {ModuleSource} o.runtime  `@emnapi/runtime`: the module, or its URL
 * @param {Uint8Array | ArrayBuffer} [o.wasmBinary]  the `.wasm` itself, rather
 *   than the glue fetching it from beside its own URL
 * @param {ModuleSource} [o.compiler]  ds_dsc (ds_dsc.mjs: its
 *   factory, module or URL), to compile in the page
 * @param {Uint8Array | ArrayBuffer} [o.compilerWasm]  its `.wasm`, likewise
 * @returns {Promise<Api<BrowserHost>>}
 */
export function open({ glue, runtime, wasmBinary, compiler, compilerWasm }: {
    glue: ModuleSource;
    runtime: ModuleSource;
    wasmBinary?: ArrayBuffer | Uint8Array<ArrayBufferLike> | undefined;
    compiler?: ModuleSource | undefined;
    compilerWasm?: ArrayBuffer | Uint8Array<ArrayBufferLike> | undefined;
}): Promise<Api<BrowserHost>>;
export * from "./types.js";
/**
 * A page's host: no file system, and the compiler if the page gave one.
 */
export type BrowserHost = {
    file: null;
    compile: (source: string, options?: WasmCompileOptions) => Promise<Uint8Array>;
    compileFile: (path: string) => never;
};
/**
 * ds_wasm.mjs's factory, and the module it makes.
 */
export type GlueFactory = (options: {
    wasmBinary?: Uint8Array | ArrayBuffer;
}) => Promise<{
    emnapiInit: (options: {
        context: unknown;
    }) => Glue;
}>;
import type { ModuleSource } from "./types.js";
import type { Api } from "./types.js";
import { status } from "./bind.js";
import { DsError } from "./bind.js";
import { CompileRefused } from "./bind.js";
import { Engine } from "./bind.js";
import { EngineEvent } from "./bind.js";
import { STREAM_EVENT_KINDS } from "./bind.js";
import { Clock } from "./bind.js";
import { Cache } from "./bind.js";
import { Fact } from "./bind.js";
import { JsonText } from "./bind.js";
import { compileWasm } from "./dsc-wasm.js";
import { runDsc } from "./dsc-wasm.js";
import type { WasmCompileOptions } from "./types.js";
import type { Glue } from "./bind.js";
export { status, DsError, CompileRefused, Engine, EngineEvent, STREAM_EVENT_KINDS, Clock, Cache, Fact, JsonText, compileWasm, runDsc };
