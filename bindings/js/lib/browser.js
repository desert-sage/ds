// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// @ds-lang/ds in a page (tools/dsdb/DSDB_WEB.md §5): libds as wasm, the API
// bind.js's, the same as under Node. Nothing here imports from Node. The page
// gives what Node finds on disk: the emscripten glue (ds_wasm.mjs) and
// emnapi's runtime, each as a module or a URL to import, and, if it wants,
// the `.wasm`'s bytes instead of the glue fetching them beside itself.
//
// What a page has not got: a file system, so `recordTo` takes a sink function
// only and `compileFile` refuses. Compiling is ds_dsc's, which
// the page passes as `compiler` when it wants one: `compile` and `fromSource`
// are then async, and without one they refuse, saying why.

import {
    attach, Cache, Clock, CompileRefused, DsError, Engine, EngineEvent, Fact, JsonText, STREAM_EVENT_KINDS, status,
} from "./bind.js";
import { compileWasm, runDsc } from "./dsc-wasm.js";

/** @import { Api, ModuleSource, WasmCompileOptions } from "./types.js" */
/** @import { Glue } from "./bind.js" */

export {
    status, DsError, CompileRefused, Engine, EngineEvent, STREAM_EVENT_KINDS, Clock, Cache, Fact, JsonText,
    compileWasm, runDsc,
};
export * from "./types.js";

const NO_COMPILER = "@ds-lang/ds: compiling in a page needs ds_dsc, the wasm compiler: "
    + "pass it to open() as `compiler`";

/**
 * A page's host: no file system, and the compiler if the page gave one.
 * @typedef {object} BrowserHost
 * @property {null} file
 * @property {(source: string, options?: WasmCompileOptions) => Promise<Uint8Array>} compile
 * @property {(path: string) => never} compileFile
 */

/**
 * ds_wasm.mjs's factory, and the module it makes.
 * @typedef {(options: { wasmBinary?: Uint8Array | ArrayBuffer }) =>
 *     Promise<{ emnapiInit: (options: { context: unknown }) => Glue }>} GlueFactory
 */

/**
 * @param {ModuleSource | undefined} compiler
 * @param {Uint8Array | ArrayBuffer | undefined} compilerWasm
 * @returns {BrowserHost}
 */
function host(compiler, compilerWasm) {
    return {
        file: null,
        compile: compiler === undefined
            ? () => { throw new Error(NO_COMPILER); }
            : (source, options = {}) => compileWasm(compiler, source, { wasmBinary: compilerWasm, ...options }),
        compileFile: () => {
            throw new Error("@ds-lang/ds: compileFile needs a file system; in a page, `compile` the source text");
        },
    };
}

/**
 * `what` if it is already the module, else the module imported from it (a URL).
 * @param {unknown} what
 * @param {string} name
 * @returns {Promise<unknown>}
 */
async function moduleOf(what, name) {
    if (what === undefined || what === null) throw new TypeError(`@ds-lang/ds: open() needs \`${name}\``);
    if (typeof what === "string" || what instanceof URL) return import(String(what));
    return what;
}

/**
 * A module's member `key`, or undefined.
 * @param {unknown} m
 * @param {string} key
 * @returns {unknown}
 */
function member(m, key) {
    return m !== null && (typeof m === "object" || typeof m === "function") ? Reflect.get(m, key) : undefined;
}

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
export async function open({ glue, runtime, wasmBinary, compiler, compilerWasm }) {
    return attach("browser", "wasm", async () => {
        const g = await moduleOf(glue, "glue");
        const factory = typeof g === "function" ? g : member(g, "default");
        if (typeof factory !== "function") throw new TypeError("@ds-lang/ds: `glue` is not ds_wasm.mjs");
        const rt = await moduleOf(runtime, "runtime");
        const getDefaultContext = member(rt, "getDefaultContext") ?? member(member(rt, "default"), "getDefaultContext");
        if (typeof getDefaultContext !== "function")
            throw new TypeError("@ds-lang/ds: `runtime` is not @emnapi/runtime");
        // The glue's factory, checked as far as JavaScript can check one.
        const create = /** @type {GlueFactory} */ (factory);
        const Module = await create(wasmBinary === undefined ? {} : { wasmBinary });
        return Module.emnapiInit({ context: getDefaultContext() });
    }, host(compiler, compilerWasm));
}
