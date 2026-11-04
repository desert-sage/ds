// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// @ds-lang/ds — the JavaScript binding to libds (../JS_BINDING.md), under Node.
// `open({ target })` loads libds natively or as wasm, and the API over it is
// bind.js's, the same for every target and host. A page loads it
// with browser.js instead (tools/dsdb/DSDB_WEB.md §5).
//
// NO SILENT FALLBACK BETWEEN TARGETS. The targets report different
// platform signatures ([LDET.2.3]), so quietly loading wasm when native was
// asked for would change what a recording says it was made on. Asking for a
// target that is not installed throws; `installed()` says which are, for a
// caller that chooses (dsdb does, and says which it chose). A caller that
// names no target gets the one installed here, chosen before anything loads
// and never swapped after: native where it is, else wasm where its compiler
// is beside it (the npm package carries wasm alone), else a refusal naming
// each path. `api.target` says which it got.
//
// EACH TARGET COMPILES WITH ITS OWN RUNNER. Native, the `dsc` binary
// (compile.js). Wasm, ds_dsc (dsc-wasm.js), async, as in a page: it is
// DS_JS_DSC if that names one, else the package's own
// build/ds_dsc/, and nothing else. Under Node the files a compile reads
// come off the disk: the source, and the `.ds` and `.dsrt` files under each
// `-L` directory. And the standard library the compiler ships with
// ([LIMP.3.3.1]): as the native binary finds the tarball's at
// `bin/../share/ds/stdlib`, ds_dsc finds one at
// `<its directory>/../share/ds/stdlib`, which in the DS tools package is
// build/share/ds/stdlib. The compiler looks there itself, after every
// `-L` directory; this host names it the program in its own directory and
// gives it that directory's files.

import { createRequire } from "node:module";
import { closeSync, existsSync, openSync, readFileSync, readdirSync, writeSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, join, resolve } from "node:path";

import {
    attach, Cache, Clock, CompileRefused, DsError, Engine, EngineEvent, Fact, JsonText, STREAM_EVENT_KINDS, status,
} from "./bind.js";
import { compile, compileFile } from "./compile.js";
import { compileWasm, runDsc } from "./dsc-wasm.js";

/** @import { Api, CompileOptions, FileSink, Target } from "./types.js" */
/** @import { Glue } from "./bind.js" */

export { status, DsError, Engine, EngineEvent, STREAM_EVENT_KINDS, Clock, Cache, Fact, JsonText };
// The compiler shim needs no libds, so it is not bound to a target: the
// native runner, and the wasm one (ds_dsc), which is async.
export { compile, compileFile, CompileRefused };
export { compileWasm, runDsc } from "./dsc-wasm.js";
export * from "./types.js";

const HERE = dirname(fileURLToPath(import.meta.url));

// Each target's build: DS_JS_NATIVE / DS_JS_WASM / DS_JS_DSC name
// one explicitly (the gates and the tests set them); otherwise the package's
// own build directory.
const nativePath = () => process.env.DS_JS_NATIVE ?? join(HERE, "..", "build", "ds.node");
const wasmPath = () => process.env.DS_JS_WASM ?? join(HERE, "..", "build", "ds_wasm.mjs");
const dscPath = () => process.env.DS_JS_DSC ?? join(HERE, "..", "build", "ds_dsc", "ds_dsc.mjs");

/**
 * What is installed here, each by its path, or null where it is not: the
 * native target, the wasm one, and ds_dsc, the compiler the wasm
 * target needs.
 * @returns {{ native: string | null, wasm: string | null, wasmCompiler: string | null }}
 */
export function installed() {
    /** @param {string} p */
    const there = (p) => (existsSync(p) ? p : null);
    return { native: there(nativePath()), wasm: there(wasmPath()), wasmCompiler: there(dscPath()) };
}

/** @param {string} path */
function fileSink(path) {
    const fd = openSync(path, "w");
    return { write: (/** @type {Uint8Array} */ bytes) => { writeSync(fd, bytes); }, close: () => closeSync(fd) };
}

/**
 * Node's host on the native target: `recordTo` writes a path as it goes, and
 * the native `dsc` compiles.
 * @typedef {{ file: (path: string) => FileSink, compile: typeof compile, compileFile: typeof compileFile }} NodeHost
 */

/**
 * Node's host on the wasm target: `recordTo` as on native, and ds_dsc
 * compiles, async, as in a page.
 * @typedef {{ file: (path: string) => FileSink, compile: typeof compileUnderWasm,
 *     compileFile: typeof compileFileUnderWasm }} NodeWasmHost
 */

/** @type {NodeHost} */
const NATIVE_HOST = { file: fileSink, compile, compileFile };

/** @type {NodeWasmHost} */
const WASM_HOST = { file: fileSink, compile: compileUnderWasm, compileFile: compileFileUnderWasm };

/** What a compile reads by path, by suffix (sourcesUnder). */
const SOURCE_SUFFIXES = [".ds", ".dsrt", ".dstest"];

/**
 * Every `.ds` file under `dir`, every `.dsrt` (a source's contract beside it,
 * [RTCT.4.1]) and every `.dstest` (a module's companion tests, [LTSL.2.4]), by
 * absolute path, for the wasm compiler's file system: what a compile with
 * `-L dir` can read. A directory that is not there gives nothing, as `-L` of
 * one gives the native compiler nothing.
 * @param {string} dir
 * @param {Record<string, Uint8Array>} into
 */
function sourcesUnder(dir, into) {
    /** @type {import("node:fs").Dirent[]} */
    let entries;
    try {
        entries = readdirSync(dir, { withFileTypes: true });
    } catch {
        return;
    }
    for (const e of entries) {
        const p = join(dir, e.name);
        if (e.isDirectory() && !e.name.startsWith(".") && e.name !== "node_modules") sourcesUnder(p, into);
        else if (e.isFile() && SOURCE_SUFFIXES.some((s) => e.name.endsWith(s))) into[p] = readFileSync(p);
    }
}

/**
 * Compile DS source text to .dsc bytes with ds_dsc: compile.js's
 * `compile` under wasm, the same argv and the same errors, and async.
 * @param {string} source
 * @param {CompileOptions} [options]
 * @returns {Promise<Uint8Array>}
 */
export async function compileUnderWasm(source, { file = "<input>", searchPath = [] } = {}) {
    const mjs = installedDsc();
    const dirs = searchPath.map((p) => resolve(p));
    /** @type {Record<string, Uint8Array>} */
    const files = {};
    for (const d of dirs) sourcesUnder(d, files);
    const program = bundled(mjs, files);
    return compileWasm(pathToFileURL(mjs).href, source,
                       { file, searchPath: dirs, files, wasmModule: await compiledDsc(mjs), program });
}

/**
 * The program ds_dsc runs as, `<its directory>/dsc`, with the standard
 * library beside it, `<its directory>/../share/ds/stdlib`, added to `files`
 * ([LIMP.3.3.1]). No library there adds nothing, and the compiler finds none,
 * as a `dsc` built in a tree finds none.
 * @param {string} mjs  ds_dsc.mjs
 * @param {Record<string, string | Uint8Array>} files
 * @returns {string}
 */
function bundled(mjs, files) {
    const dir = dirname(resolve(mjs));
    /** @type {Record<string, Uint8Array>} */
    const library = {};
    sourcesUnder(join(dir, "..", "share", "ds", "stdlib"), library);
    Object.assign(files, library);
    return join(dir, "dsc");
}

/**
 * Run ds_dsc once with `argv`, as the binary takes it: dsc-wasm.js's
 * `runDsc` with the compiler this package finds, for a subcommand `@ds-lang/ds`
 * has no call for (`dump-ast`).
 * @param {string[]} argv
 * @param {{ stdin?: Uint8Array, files?: Record<string, string | Uint8Array> }} [io]
 * @returns {Promise<{ status: number, stdout: Uint8Array, stderr: string }>}
 */
export async function runDscUnderWasm(argv, { stdin, files = {} } = {}) {
    const mjs = installedDsc();
    const all = { ...files };
    const program = bundled(mjs, all);
    return runDsc(pathToFileURL(mjs).href, argv, { stdin, files: all, wasmModule: await compiledDsc(mjs), program });
}

/**
 * ds_dsc.mjs, where it is installed, with its `.wasm` beside it;
 * refused, saying how to install it, where not.
 * @returns {string}
 */
function installedDsc() {
    const mjs = dscPath();
    if (!existsSync(mjs))
        throw new Error(`@ds-lang/ds: the wasm compiler is not installed (${mjs}); `
                        + "install the DS tools package, or set DS_JS_DSC to its ds_dsc.mjs");
    if (!existsSync(join(dirname(mjs), "dsc_cli.wasm")))
        throw new Error(`@ds-lang/ds: ds_dsc's dsc_cli.wasm is not beside it (${dirname(mjs)})`);
    return mjs;
}

/** @type {Map<string, Promise<WebAssembly.Module>>} ds_dsc.mjs -> its `.wasm`, compiled */
const COMPILED = new Map();

/**
 * ds_dsc's `.wasm`, beside its module, compiled once per process:
 * each compile then instantiates it, and does not compile the compiler again.
 * @param {string} mjs
 * @returns {Promise<WebAssembly.Module>}
 */
function compiledDsc(mjs) {
    let m = COMPILED.get(mjs);
    if (m === undefined) {
        m = WebAssembly.compile(readFileSync(join(dirname(mjs), "dsc_cli.wasm")));
        COMPILED.set(mjs, m);
        m.catch(() => COMPILED.delete(mjs));
    }
    return m;
}

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
export async function compileFileUnderWasm(path, { searchPath } = {}) {
    const file = String(path);
    const mjs = installedDsc();
    const dirs = (searchPath ?? [dirname(file)]).map((p) => resolve(p));
    /** @type {Record<string, Uint8Array>} */
    const files = {};
    for (const d of dirs) sourcesUnder(d, files);
    const program = bundled(mjs, files);
    files[file] = readFileSync(file);
    const companion = file.replace(/\.ds$/, ".dstest");
    if (companion !== file && existsSync(companion)) files[companion] = readFileSync(companion);
    const argv = ["compile", file, "-o", "-"];
    for (const d of dirs) argv.push("-L", d);
    const r = await runDsc(pathToFileURL(mjs).href, argv, { files, wasmModule: await compiledDsc(mjs), program });
    const stderr = r.stderr.trim();
    if (r.status === 1) throw new CompileRefused(file, stderr);
    if (r.status !== 0) throw new Error(`dsc exited ${r.status} on ${file}:\n${stderr}`);
    return r.stdout;
}

/**
 * The target open() loads when none is named. Outside Node, wasm. Under
 * Node, the one installed here: native where it is; else wasm where it and
 * ds_dsc both are, since a wasm target with no compiler cannot compile; else
 * refused, naming each path looked at.
 * @returns {Target}
 */
function defaultTarget() {
    if (typeof process === "undefined" || !process.versions?.node) return "wasm";
    const here = installed();
    if (here.native !== null) return "native";
    if (here.wasm !== null && here.wasmCompiler !== null) return "wasm";
    throw new Error(`@ds-lang/ds: no target is installed: neither the native target (${nativePath()}) `
                    + `nor the wasm target (${wasmPath()}) with its compiler (${dscPath()})`);
}

/** @returns {Glue} */
function loadNative() {
    const path = nativePath();
    if (!existsSync(path))
        throw new Error(`@ds-lang/ds: the native target is not installed (${path})`);
    return createRequire(import.meta.url)(path);
}

/** @returns {Promise<Glue>} */
async function loadWasm() {
    // The same glue, compiled by emcc against emnapi (Node-API for Emscripten).
    // DS_JS_EMNAPI_RUNTIME names emnapi's runtime explicitly (the gate sets
    // it); otherwise an installed `@emnapi/runtime`. A page loads it with
    // browser.js.
    const require = createRequire(import.meta.url);
    const glue = wasmPath();
    if (!existsSync(glue))
        throw new Error(`@ds-lang/ds: the wasm target is not installed (${glue})`);
    const { getDefaultContext } = require(process.env.DS_JS_EMNAPI_RUNTIME ?? "@emnapi/runtime");
    const { default: createDsWasm } = await import(pathToFileURL(glue).href);
    const Module = await createDsWasm();
    return Module.emnapiInit({ context: getDefaultContext() });
}

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
export async function open(options = {}) {
    const target = options.target ?? defaultTarget();
    if (target === "native") return attach("node", target, loadNative, NATIVE_HOST);
    if (target === "wasm") return attach("node", target, loadWasm, WASM_HOST);
    throw new TypeError(`@ds-lang/ds: unknown target ${JSON.stringify(target)}`);
}
