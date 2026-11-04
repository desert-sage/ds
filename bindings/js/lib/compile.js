// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The compiler shim: DS source to .dsc bytes through the Mercury `dsc`.
// @ds-lang/ds does not compile anything itself; it builds the SAME command line
// pyds.compile builds (bindings/python/src/pyds/__init__.py) and hands
// it to a runner:
//
//     dsc compile - -o - --filename <file> [-L <dir>]*     compile, source as text
//     dsc compile <path> -o - [-L <dir>]*                   compileFile, a file by its path
//
// The NATIVE runner is the `dsc` binary, `DS_MERCURY_DSC` if set, else `dsc`
// on PATH, source on stdin and the artefact on stdout. The wasm runner
// (dsc-wasm.js) takes the separately shipped ds_dsc module and runs the
// same argv; there is no fallback from one runner to the other.
//
// No version pre-check ([LDET.1.10]): the loader refuses an artefact from
// another series, and a second check here would be a second source for the
// same rule.

import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

// The compiler refused the source (its exit status 1): pyds's CompileRefused.
// It lives in bind.js, so every host throws the same class.
import { CompileRefused } from "./bind.js";

/** @import { CompileOptions } from "./types.js" */

export { CompileRefused };

/**
 * Compile DS source text to .dsc bytes (a Uint8Array) for Engine.loadDsc.
 *
 * `file` is what diagnostics and the artefact's DsSource atom call the source
 * ([RDSC.14.2.3]), recorded as given. `searchPath` directories resolve imports
 * (-L); source handed over as text has no directory of its own, so nothing
 * beside it is found unless searchPath says so — compileFile defaults it to
 * the file's directory.
 *
 * Throws CompileRefused on exit 1, and Error when the invocation fails (any
 * other status, or no binary).
 *
 * @param {string} source
 * @param {CompileOptions} [options]
 * @returns {Uint8Array}
 */
export function compile(source, { file = "<input>", searchPath = [] } = {}) {
    if (typeof source !== "string") throw new TypeError("compile: want DS source text");
    const argv = ["compile", "-", "-o", "-", "--filename", file];
    for (const p of searchPath) argv.push("-L", resolve(p));
    return run(argv, Buffer.from(source), file);
}

/**
 * Run the native `dsc` with `argv`, `input` on its stdin: the artefact, or
 * CompileRefused for `file` on exit 1.
 * @param {string[]} argv
 * @param {Buffer} input
 * @param {string} file
 * @returns {Uint8Array}
 */
function run(argv, input, file) {
    const dsc = process.env.DS_MERCURY_DSC || "dsc";
    const proc = spawnSync(dsc, argv, { input, maxBuffer: 1 << 30 });
    if (proc.error) {
        if (/** @type {NodeJS.ErrnoException} */ (proc.error).code === "ENOENT")
            throw new Error(`no dsc binary: ${JSON.stringify(dsc)} is not there -- ` +
                            "set DS_MERCURY_DSC or put dsc on PATH", { cause: proc.error });
        throw proc.error;
    }
    const stderr = proc.stderr.toString().trim();
    if (proc.status === 1) throw new CompileRefused(file, stderr);
    if (proc.status !== 0)
        throw new Error(`dsc exited ${proc.status ?? proc.signal} on ${file}:\n${stderr}`);
    return new Uint8Array(proc.stdout);
}

/**
 * Compile a .ds file: `dsc compile <path>`, so the compiler reads the file
 * itself, and with it the file's companion `.dstest` beside it ([LTSL.2.4]),
 * which source handed over as text has no place to be beside. Diagnostics and
 * the artefact name it as given ([RDSC.14.2.3]). `searchPath` defaults to the
 * file's own directory, so an import of a file sitting beside it resolves
 * (pyds's compile_file, IMPNOOP1). Pass [] to search nowhere.
 *
 * @param {string} path
 * @param {Omit<CompileOptions, "file">} [options]
 * @returns {Uint8Array}
 */
export function compileFile(path, { searchPath } = {}) {
    const file = String(path);
    // Read first, so a missing file is the same error it always was.
    readFileSync(file);
    const argv = ["compile", file, "-o", "-"];
    for (const p of searchPath ?? [dirname(file)]) argv.push("-L", resolve(p));
    return run(argv, Buffer.alloc(0), file);
}
