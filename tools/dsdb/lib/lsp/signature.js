// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Signature help (`textDocument/signatureHelp`) of `ds lsp` for the builtin
// functions: each overload [LEXP.17.2]'s Signature column
// gives, its parameters as that column writes them, its summary as the
// documentation. The active overload is the first with a parameter for the
// argument the cursor is on.
//
// The call is found in the text before the cursor, split as semantic.js
// splits it, so a bracket inside a string or a comment is not one, and a call
// continued over lines inside its brackets ([LLEX.7.5]) is followed. A name
// the call reaches is resolved as builtins.js resolves it.

import { builtinNamed } from "./builtins.js";
import { dotted, scan } from "./semantic.js";

/** @import { Module } from "../ast/nodes.js" */

const OPEN = new Set(["(", "[", "{"]), CLOSE = new Set([")", "]", "}"]);

/**
 * @typedef {{ label: string, documentation: string, parameters: { label: [number, number] }[] }} Signature
 */

/**
 * The signatures of the builtin call the cursor is in, or null for none.
 * @param {Module | null} mod  the last good tree, for the imports
 * @param {string[]} lines
 * @param {number} line  1-based
 * @param {number} col  a code-point column
 * @returns {{ signatures: Signature[], activeSignature: number, activeParameter: number } | null}
 */
export function signatureHelp(mod, lines, line, col) {
    const xs = scan(lines, { line, col });
    /** @type {Array<{ open: string, callee: string | null, commas: number }>} */
    const stack = [];
    for (let k = 0; k < xs.length; k++) {
        const x = xs[k];
        if (x.kind !== "punct") continue;
        if (OPEN.has(x.text)) {
            const before = xs[k - 1];
            const callee = x.text === "(" && before?.kind === "name" && before.line === x.line ? dotted(xs, k - 1) : null;
            stack.push({ open: x.text, callee, commas: 0 });
        } else if (CLOSE.has(x.text)) {
            stack.pop();
        } else if (x.text === "," && stack.length) {
            stack[stack.length - 1].commas++;
        }
    }
    const call = stack[stack.length - 1];
    if (call === undefined || call.open !== "(" || call.callee === null) return null;
    const b = builtinNamed(mod, call.callee);
    if (b === null) return null;
    const callee = call.callee;
    const signatures = b.signatures.map((s) => signature(callee, s, b.summary));
    const fits = signatures.findIndex((s) => s.parameters.length > call.commas);
    return { signatures, activeSignature: fits < 0 ? signatures.length - 1 : fits, activeParameter: call.commas };
}

/**
 * One overload: `callee(x: Int) → Int`, each parameter the offsets of its
 * text between the parentheses, split at the commas outside any bracket.
 * @param {string} callee  as written
 * @param {string} overload  `(…) → T`, as [LEXP.17.2] writes it
 * @param {string} summary
 * @returns {Signature}
 */
function signature(callee, overload, summary) {
    const label = callee + overload;
    const open = callee.length + 1;
    const close = open + closing(overload) - 1;
    /** @type {{ label: [number, number] }[]} */
    const parameters = [];
    let depth = 0, from = open;
    for (let i = open; i <= close; i++) {
        const c = label[i];
        if (c === "(" || c === "[") depth++;
        else if (c === ")" || c === "]") depth--;
        if ((c === "," && depth === 0) || i === close) {
            let a = from, z = i;
            while (a < z && label[a] === " ") a++;
            if (a < z) parameters.push({ label: [a, z] });
            from = i + 1;
        }
    }
    return { label, documentation: summary, parameters };
}

/**
 * Where an overload's parameter list closes: the index of the `)` that
 * matches its opening one.
 * @param {string} overload
 */
function closing(overload) {
    let depth = 0;
    for (let i = 0; i < overload.length; i++) {
        if (overload[i] === "(") depth++;
        else if (overload[i] === ")" && --depth === 0) return i;
    }
    return overload.length - 1;
}
