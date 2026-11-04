// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The outline (`textDocument/documentSymbol`) and workspace symbols
// (`workspace/symbol`) of `ds lsp`, read from the syntax tree: each
// declaration a program makes, a schema's slots under it. Positions are the
// tree's (lines 1-based, columns code points); the server converts them.
//
// A declaration's whole range runs from its start to its recorded end, or,
// where the tree records none, to the next declaration's start or the end of
// the file, as analysis.js's `declAt` reads it. Its selection range is its
// name, found in its statement's text (analysis.js `nameRange`).

import { declName, nameRange } from "./analysis.js";

/** @import { Module, Slot, decl_t } from "../ast/nodes.js" */
/** @import { NameRange } from "./analysis.js" */

/** LSP's SymbolKind numbers, the ones used here. */
export const KIND = Object.freeze({
    Field: 8, Interface: 11, Function: 12, Constant: 14, Property: 7, Struct: 23, Event: 24, TypeParameter: 26,
});

/** @typedef {{ line: number, col: number }} Pos */

/**
 * One symbol: a declaration, or a schema's slot under it.
 * @typedef {object} Outline
 * @property {string} name
 * @property {string} detail
 * @property {number} kind  an LSP SymbolKind
 * @property {{ start: Pos, end: Pos }} range  the whole declaration
 * @property {NameRange} selection  its name
 * @property {Outline[]} children
 */

/**
 * The outline of one file: its declarations in source order. Imports and the
 * `initial:` block name nothing, and are left out.
 * @param {Module} mod
 * @param {string[]} lines  the file's
 * @returns {Outline[]}
 */
export function outline(mod, lines) {
    /** @type {Outline[]} */
    const out = [];
    const body = mod.body;
    for (let i = 0; i < body.length; i++) {
        const d = body[i];
        const what = describe(d);
        if (what === null) continue;
        const { nameInText, ...shown } = what;
        out.push({
            ...shown,
            range: { start: { line: d.lineno, col: d.col_offset }, end: endOf(d, body[i + 1] ?? null, lines) },
            selection: nameRange(lines, d, nameInText ?? shown.name),
            children: d._type === "Schema" ? d.slots.map((s) => slotSymbol(s, lines)) : [],
        });
    }
    return out;
}

/**
 * Every symbol of an outline, its slots included, flat, with what contains
 * each: what `workspace/symbol` lists.
 * @param {Outline[]} tree
 * @returns {Array<Outline & { container: string | null }>}
 */
export function flat(tree) {
    return tree.flatMap((o) => [{ ...o, container: null }, ...o.children.map((c) => ({ ...c, container: o.name }))]);
}

/**
 * Whether a symbol's name answers a workspace query: the query's characters
 * in order, case-insensitively, as an editor's symbol search matches. An
 * empty query answers everything.
 * @param {string} name
 * @param {string} query
 */
export function matches(name, query) {
    const n = name.toLowerCase();
    let at = 0;
    for (const c of query.toLowerCase()) {
        at = n.indexOf(c, at);
        if (at < 0) return false;
        at += c.length;
    }
    return true;
}

/**
 * A declaration's name, kind and detail; null for one that names nothing.
 * `nameInText` is how the name is written where it differs from how it is
 * shown (a series is shown with its schema, written as its slot).
 * @param {decl_t} d
 * @returns {{ name: string, detail: string, kind: number, nameInText?: string } | null}
 */
function describe(d) {
    switch (d._type) {
    case "Schema":
        return { name: d.name, detail: `schema, ${d.slots.length} slot${d.slots.length === 1 ? "" : "s"}`,
                 kind: KIND.Struct };
    case "Rule":
        return { name: d.name, detail: "rule", kind: KIND.Function };
    case "Const":
        return { name: d.name, detail: "const", kind: KIND.Constant };
    case "Service": {
        const r = d.response;
        const detail = r === null ? "service" : r._type === "ResponseSchema" ? `service, response ${r.name}`
            : "service, no response";
        return { name: d.name.join("."), detail, kind: KIND.Interface };
    }
    case "Opaque":
        return { name: d.name, detail: `opaque ${d.representation}`, kind: KIND.TypeParameter };
    case "Series":
        return { name: d.schema === null ? d.slot : `${d.schema}.${d.slot}`, detail: "series", kind: KIND.Property,
                 nameInText: d.slot };
    case "Test": {
        const n = d.name;
        const name = n._type === "Constant" && typeof n.value === "string" ? n.value : "test";
        return { name, detail: "test", kind: KIND.Event, nameInText: "test" };
    }
    default: {
        // The unit declarations: a dimension, a scalar, a symbol, a formula,
        // an exchange pair.
        const name = declName(d);
        return name === null ? null : { name, detail: "unit", kind: KIND.Constant };
    }
    }
}

/**
 * @param {Slot} s
 * @param {string[]} lines
 * @returns {Outline}
 */
function slotSymbol(s, lines) {
    const end = s.end_lineno !== null && s.end_col_offset !== null
        ? { line: s.end_lineno, col: s.end_col_offset }
        : { line: s.lineno, col: [...(lines[s.lineno - 1] ?? "")].length };
    return {
        name: s.name, detail: s.nullable ? `${s.type}?` : s.type, kind: KIND.Field,
        range: { start: { line: s.lineno, col: s.col_offset }, end },
        selection: nameRange(lines, s, s.name), children: [],
    };
}

/**
 * Where a declaration ends: its recorded end, else the end of the last line
 * before the next declaration that is not blank or a comment, else the end
 * of the file's last such line.
 * @param {decl_t} d
 * @param {decl_t | null} next
 * @param {string[]} lines
 * @returns {Pos}
 */
function endOf(d, next, lines) {
    if (d.end_lineno !== null && d.end_col_offset !== null) return { line: d.end_lineno, col: d.end_col_offset };
    let last = (next === null ? lines.length : next.lineno - 1);
    while (last > d.lineno && /^\s*(#.*)?$/.test(lines[last - 1] ?? "")) last--;
    return { line: last, col: [...(lines[last - 1] ?? "")].length };
}
