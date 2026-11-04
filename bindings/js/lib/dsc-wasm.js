// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The compiler's wasm runner: ds_dsc, the Mercury `dsc` built for
// wasm32, run with the SAME argv the native runner gives the binary
// (compile.js), so the two are one command line with two runners. Nothing from Node: it runs in a page and under Node
// alike.
//
// ONE INSTANCE PER COMPILE: Mercury's runtime keeps global state and
// `main` exits, so each compile instantiates the module afresh. Standard input
// and output are bytes, through Emscripten's `FS.init`: the source goes in on
// stdin, the `.dsc` comes back on stdout, exactly as the binary's pipes carry
// them. Files the compile reads (`-L` directories) are
// written into the instance's in-memory file system at the paths the argv
// names. The module's own exit is caught, never allowed to end the process
// (`quit`), nor to set its exit code.
//
// THE PROGRAM'S NAME IS GIVEN, NOT TAKEN: argv[0] is where the compiler finds
// the standard library it ships with, `<its directory>/../share/ds/stdlib`
// ([LIMP.3.3.1], [RCLI.1.11]), and under Node Emscripten would otherwise take
// it from the host's own script (process.argv[1]). It is `program`, else
// DEFAULT_PROGRAM.
//
// THE LIBRARY COMES WITH THE COMPILER: the
// ds_dsc package's module exports `library`, every `.ds` file of the
// standard library by its path below the library's root, generated from the
// committed `stdlib/` when the package is made. Before `main`, this writes each
// at `<program's directory>/../share/ds/stdlib/<path>`, so a page or Node
// caller sets up nothing; a `dsc` that finds no library there refuses every
// compile, exit 2. A caller's own `files` are written after, and win.

import { CompileRefused } from "./bind.js";

/** @import { ModuleSource, WasmCompileOptions } from "./types.js" */

/**
 * The parts of an Emscripten module the runner uses.
 * @typedef {object} DscModule
 * @property {{
 *     init: (stdin: () => number | null, stdout: (c: number | null) => void, stderr: (c: number | null) => void)
 *         => void,
 *     mkdirTree: (path: string) => void,
 *     writeFile: (path: string, data: string | Uint8Array) => void,
 * }} FS
 * @property {(argv: string[]) => number | undefined} callMain
 */

/** @typedef {(options: object) => Promise<DscModule>} DscFactory */

/**
 * The directory part of a path, "." for none.
 * @param {string} p
 */
const dirOf = (p) => (p.includes("/") ? p.slice(0, p.lastIndexOf("/")) || "/" : ".");

/**
 * The directory a file's path needs made. Without `.` and `..`, which the file
 * system's mkdir refuses, and which it resolves when the file is written: a
 * caller's relative path, `cold.ds` or `../a.ds`, is a path like any other.
 * @param {string} p
 */
const dirToMake = (p) => dirOf(p).split("/").filter((s) => s !== "." && s !== "..").join("/") || "/";

/** argv[0] when the caller names none: an absolute path, so `../share` is too. */
export const DEFAULT_PROGRAM = "/ds_dsc/bin/dsc";

/**
 * The module factory and the library the package carries: given as the
 * module, a URL to import, or the bare factory. A bare factory carries no
 * library; the caller then writes one among `files`, or the compile is
 * refused ([RCLI.1.11]).
 * @param {ModuleSource | undefined | null} compiler
 * @returns {Promise<{ factory: DscFactory, library: Record<string, string> }>}
 */
async function compilerOf(compiler) {
    if (compiler === undefined || compiler === null)
        throw new Error("@ds-lang/ds: compiling under wasm needs ds_dsc, passed in as `compiler`");
    const m = typeof compiler === "string" || compiler instanceof URL ? await import(String(compiler)) : compiler;
    const f = typeof m === "function" ? m : Reflect.get(m, "default");
    if (typeof f !== "function") throw new TypeError("@ds-lang/ds: `compiler` is not ds_dsc");
    const lib = typeof m === "function" ? undefined : Reflect.get(m, "library");
    /** @type {Record<string, string>} */
    const library = {};
    if (lib !== undefined && lib !== null && typeof lib === "object") {
        for (const [rel, text] of Object.entries(lib)) {
            if (typeof text !== "string") throw new TypeError(`@ds-lang/ds: ds_dsc's library entry ${rel} is not text`);
            library[rel] = text;
        }
    }
    return { factory: f, library };
}

/**
 * Emscripten's own ExitStatus, which callMain throws when `main` exits.
 * @param {unknown} e
 * @returns {e is { name: "ExitStatus", status: number }}
 */
function isExitStatus(e) {
    return e !== null && typeof e === "object" && Reflect.get(e, "name") === "ExitStatus"
        && typeof Reflect.get(e, "status") === "number";
}

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
export async function runDsc(compiler, argv,
                             { stdin = new Uint8Array(0), files = {}, wasmBinary, wasmModule,
                               program = DEFAULT_PROGRAM } = {}) {
    if (!program.startsWith("/")) throw new TypeError(`@ds-lang/ds: \`program\` is ${program}, not an absolute path`);
    const { factory, library } = await compilerOf(compiler);
    const root = `${dirOf(dirOf(program))}/share/ds/stdlib`.replace(/^\/\//, "/");
    /** @type {number[]} */
    const out = [];
    /** @type {number[]} */
    const err = [];
    let at = 0;
    class Quit extends Error {
        /** @param {number} status */
        constructor(status) {
            super(`exit ${status}`);
            this.status = status;
        }
    }
    const M = await factory({
        ...(wasmBinary === undefined ? {} : { wasmBinary }),
        // Emscripten's own hook for a module compiled already: instantiate it
        // with the imports the factory gives, and hand the instance back.
        ...(wasmModule === undefined ? {} : {
            instantiateWasm: (/** @type {WebAssembly.Imports} */ imports,
                              /** @type {(i: WebAssembly.Instance, m: WebAssembly.Module) => void} */ receive) => {
                WebAssembly.instantiate(wasmModule, imports).then((inst) => receive(inst, wasmModule));
                return {};
            },
        }),
        noInitialRun: true,
        thisProgram: program,
        print: () => {},
        printErr: () => {},
        // Emscripten's default quit ends a Node process. Rethrowing its own
        // ExitStatus lets callMain return the status, as it does in a page.
        quit: (/** @type {number} */ status, /** @type {unknown} */ toThrow) => { throw toThrow ?? new Quit(status); },
        preRun: [(/** @type {DscModule} */ m) => {
            m.FS.init(() => (at < stdin.length ? stdin[at++] : null),
                      (c) => { if (c !== null) out.push(c & 0xff); },
                      (c) => { if (c !== null) err.push(c & 0xff); });
            // The program is there, as a binary's would be: the compiler
            // follows its own path through any link before it looks beside it
            // ([RCLI.1.11]), and a path that names nothing ends nowhere. Then
            // `<dir>/../share/ds/stdlib` resolves, and holds the package's
            // library.
            m.FS.mkdirTree(dirOf(program));
            m.FS.writeFile(program, new Uint8Array(0));
            for (const [rel, text] of Object.entries(library)) {
                const path = `${root}/${rel}`;
                m.FS.mkdirTree(dirOf(path));
                m.FS.writeFile(path, text);
            }
            for (const [path, data] of Object.entries(files)) {
                m.FS.mkdirTree(dirToMake(path));
                m.FS.writeFile(path, data);
            }
        }],
    });
    // Emscripten's quit for Node sets process.exitCode before it throws, and
    // a build that does not take the `quit` above runs it: the
    // compiler's status would become the process's. It is the run's, so the
    // process's own is put back. Only under Node is there one to keep.
    const proc = /** @type {{ exitCode?: number | string | null } | undefined} */ (Reflect.get(globalThis, "process"));
    const exitCode = proc?.exitCode;
    /** @type {number | undefined} */
    let status;
    try {
        status = M.callMain(argv);
    } catch (e) {
        if (e instanceof Quit) status = e.status;
        else if (isExitStatus(e)) status = e.status;
        else throw e;
    } finally {
        if (proc !== undefined) proc.exitCode = exitCode;
    }
    return {
        status: status ?? 0,
        stdout: Uint8Array.from(out),
        stderr: new TextDecoder().decode(Uint8Array.from(err)),
    };
}

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
export async function compileWasm(compiler, source, { file = "<input>", searchPath = [], files = {}, wasmBinary,
                                                      wasmModule, program } = {}) {
    if (typeof source !== "string") throw new TypeError("compile: want DS source text");
    const argv = ["compile", "-", "-o", "-", "--filename", file];
    for (const p of searchPath) argv.push("-L", p);
    const r = await runDsc(compiler, argv,
                           { stdin: new TextEncoder().encode(source), files, wasmBinary, wasmModule, program });
    const stderr = r.stderr.trim();
    if (r.status === 1) throw new CompileRefused(file, stderr);
    if (r.status !== 0) throw new Error(`dsc exited ${r.status} on ${file}:\n${stderr}`);
    return r.stdout;
}
