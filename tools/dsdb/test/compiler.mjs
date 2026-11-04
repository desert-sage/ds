// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The compiler this lane's target has, for the tests that need one.
// Natively it is the branch's Mercury `dsc` (DS_MERCURY_DSC, as the @ds-lang/ds
// gate sets it); under wasm it is ds_dsc (DS_JS_DSC, as the
// js-wasm lane sets it). A test reaches it as dsdb does, through
// @ds-lang/ds on the lane's target and the language server's ports, and so
// runs in both lanes. It is skipped, naming what is missing, only in a lane
// that gives no compiler for its target.

import { lspPorts } from "../lib/lsp/ports.js";

/** @import { LspPorts } from "../lib/lsp/server.js" */

export const TARGET = process.env.DS_JS_TARGET ?? "native";

/** False where this lane's target has its compiler; else why the test is skipped. */
export const NO_COMPILER = TARGET === "wasm"
    ? (process.env.DS_JS_DSC ? false : "needs ds_dsc (DS_JS_DSC), as the js-wasm lane sets it")
    : (process.env.DS_MERCURY_DSC ? false : "needs the Mercury dsc (DS_MERCURY_DSC), as the js gate sets it");

/** @type {Promise<LspPorts> | null} */
let ports = null;

/**
 * The language server's ports on this lane's target: `dumpAst` and `compile`
 * as `ds lsp` runs them.
 * @returns {Promise<LspPorts>}
 */
export function targetPorts() {
    ports ??= (async () => {
        const binding = await import(new URL("../../../bindings/js/lib/index.js", import.meta.url).href);
        return lspPorts(binding, await binding.open({ target: TARGET }));
    })();
    return ports;
}

/**
 * `dsc dump-ast` of `text`, named `file`, on this lane's target: the tree,
 * or what the compiler said refusing it.
 * @param {string} text
 * @param {string} file
 */
export async function dumpAst(text, file) {
    return (await targetPorts()).dumpAst(text, file);
}
