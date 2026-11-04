// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
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
export function compile(source: string, { file, searchPath }?: CompileOptions): Uint8Array;
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
export function compileFile(path: string, { searchPath }?: Omit<CompileOptions, "file">): Uint8Array;
export { CompileRefused };
import type { CompileOptions } from "./types.js";
import { CompileRefused } from "./bind.js";
