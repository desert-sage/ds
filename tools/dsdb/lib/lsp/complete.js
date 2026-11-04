// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Completion: what may be written at a position, read from the line before
// the cursor and the program's tree. The lists are the spec's, generated into
// registries.js: the grammar's words by class ([LLEX.9.6]), the builtin
// functions ([LEXP.17.2]), the aggregations, the builtin types ([LGRA.22.8]).
//
// Positions are the tree's: lines 1-based, columns in code points. The tree
// may be the last good one while an edit does not parse; it answers for the
// program's names, and the line's own text says where the cursor is.

import { bindings, declAt, typeName } from "./analysis.js";
import { AGGREGATIONS, BUILTINS, GRAMMAR_WORDS, TYPES } from "./registries.js";

/** @import { Module, Rule, Schema } from "../ast/nodes.js" */
/** @import { Builtin } from "./registries.js" */

/** LSP's CompletionItemKind and InsertTextFormat numbers. */
const FUNCTION = 3, FIELD = 5, VARIABLE = 6, CLASS = 7, MODULE = 9, KEYWORD = 14, CONSTANT = 21, STRUCT = 22,
    OPERATOR = 24, SNIPPET = 2;

/** @typedef {{ label: string, kind: number, detail?: string, insertText?: string, insertTextFormat?: number }} Item */

/**
 * @param {string} label
 * @param {number} kind
 * @param {string} [detail]
 * @returns {Item}
 */
const item = (label, kind, detail) => (detail === undefined ? { label, kind } : { label, kind, detail });

/** What a call may name: every row of [LEXP.17.2]. */
const CALLABLE = BUILTINS;

/**
 * The items for a position.
 * @param {Module | null} mod  the last good tree, if the document ever parsed
 * @param {string[]} lines
 * @param {number} line
 * @param {number} col
 * @returns {Item[]}
 */
export function complete(mod, lines, line, col) {
    const before = [...(lines[line - 1] ?? "")].slice(0, col).join("");
    const dot = /([\p{L}_][\p{L}\p{N}_]*)\.[\p{L}\p{N}_]*$/u.exec(before);
    if (dot) return afterDot(mod, dot[1], line, col);
    if (/::\s*[\p{L}\p{N}_]*$/u.test(before)) return TYPES.map((t) => item(t.name, CLASS, `type (${t.clause})`));
    if (/(?:^|\s)(?:emit|publish)\s+[\p{L}\p{N}_]*$/u.test(before)) return schemas(mod);
    // Nothing on the line yet but the word being typed.
    const fresh = /^\s*[\p{L}\p{N}_]*$/u.test(before);
    if (fresh && !/^\s/u.test(before)) return GRAMMAR_WORDS.declaration.map((w) => item(w, KEYWORD));
    const d = mod === null ? null : declAt(mod, line, col);
    if (d?._type !== "Rule") return expression(mod, null);
    /** @type {Item[]} */
    const out = [];
    if (fresh) {
        if (inActions(lines, d.lineno, line)) out.push(...GRAMMAR_WORDS.action.map((w) => item(w, KEYWORD)), item("let", KEYWORD));
        else out.push(...schemas(mod), ...["no", "then", "latest"].map((w) => item(w, KEYWORD)));
    }
    out.push(...expression(mod, d));
    return out;
}

/**
 * What the program's imports reach ([LIMP.3.3.4]): each `import m` (or
 * `import m as q`) by the name it is qualified with, and each name a
 * `from m import x` (or `x as y`) makes bare, to the member it names.
 * @param {Module | null} mod
 */
export function imported(mod) {
    /** @type {Map<string, string>} the qualifier, to the module it names */
    const modules = new Map();
    /** @type {Map<string, string>} the bare name, to `module.member` */
    const bare = new Map();
    for (const d of mod?.body ?? []) {
        if (d._type === "Import") {
            const m = d.path.join(".");
            modules.set(d.asname ?? m, m);
        } else if (d._type === "ImportFrom") {
            const m = d.path.join(".");
            for (const a of d.names) bare.set(a.asname ?? a.name, `${m}.${a.name}`);
        }
    }
    return { modules, bare };
}

/**
 * `q.` and what follows it: a slot of the schema binding `q` names, or a
 * member of the builtin module `q` names, if the program imports it. A
 * module's members are reached only through an import ([LIMP.3.3.4]).
 * @param {Module | null} mod
 * @param {string} q
 * @param {number} line
 * @param {number} col
 * @returns {Item[]}
 */
function afterDot(mod, q, line, col) {
    const d = mod === null ? null : declAt(mod, line, col);
    if (mod !== null && d?._type === "Rule") {
        const body = bindings(d).get(q);
        const schema = body === undefined ? null : schemaNamed(mod, typeName(body.type));
        if (schema !== null) return schema.slots.map((s) => item(s.name, FIELD, s.nullable ? `${s.type}?` : s.type));
    }
    const m = imported(mod).modules.get(q);
    if (m === undefined) return [];
    const prefix = m + ".";
    return CALLABLE.filter((b) => b.name.startsWith(prefix)).map((b) => builtin(b, b.name.slice(prefix.length)));
}

/**
 * What an expression in a rule (or anywhere, with no rule) can name: the
 * rule's bindings, the program's constants, the builtins it reaches (the
 * unqualified ones, an imported module's under its qualifier, a from-import's
 * bare), the aggregations, the grammar's constants and operators.
 * @param {Module | null} mod
 * @param {Rule | null} rule
 * @returns {Item[]}
 */
function expression(mod, rule) {
    /** @type {Item[]} */
    const out = [];
    if (rule !== null && mod !== null)
        for (const [name, body] of bindings(rule)) out.push(item(name, VARIABLE, typeName(body.type)));
    for (const d of mod?.body ?? []) if (d._type === "Const") out.push(item(d.name, CONSTANT, "const"));
    for (const b of CALLABLE) if (!b.name.includes(".")) out.push(builtin(b, b.name));
    const { modules, bare } = imported(mod);
    for (const [q, m] of modules)
        if (CALLABLE.some((b) => b.name.startsWith(m + "."))) out.push(item(q, MODULE, `builtin module ${m}`));
    for (const [name, full] of bare) {
        const b = CALLABLE.find((x) => x.name === full);
        if (b !== undefined) out.push(builtin(b, name));
    }
    const named = new Set(CALLABLE.map((b) => b.name));
    for (const a of AGGREGATIONS) if (!named.has(a)) out.push(item(a, FUNCTION, "aggregation"));
    out.push(...GRAMMAR_WORDS.constant.map((w) => item(w, CONSTANT)), ...GRAMMAR_WORDS.operator.map((w) => item(w, OPERATOR)));
    return out;
}

/**
 * A builtin as an item: its arities, its tier, and a call to fill in.
 * @param {Builtin} b
 * @param {string} label
 * @returns {Item}
 */
function builtin(b, label) {
    const arity = `${b.arities.length > 1 ? "arities" : "arity"} ${b.arities.join(", ")}`;
    const tier = b.tier === "sync-impure" ? ", bound once per firing" : "";
    const takes = Math.max(...b.arities) > 0;
    return { label, kind: FUNCTION, detail: `${arity}${tier}`,
             insertText: takes ? `${label}($1)` : `${label}()`, insertTextFormat: SNIPPET };
}

/**
 * The program's schemas, for a pattern or an emit.
 * @param {Module | null} mod
 * @returns {Item[]}
 */
function schemas(mod) {
    /** @type {Item[]} */
    const out = [];
    for (const d of mod?.body ?? []) if (d._type === "Schema") out.push(item(d.name, STRUCT, `schema, ${d.slots.length} slots`));
    return out;
}

/**
 * The schema `name` declares.
 * @param {Module} mod
 * @param {string} name
 * @returns {Schema | null}
 */
function schemaNamed(mod, name) {
    for (const d of mod.body) if (d._type === "Schema" && d.name === name) return d;
    return null;
}

/**
 * The rule's `->` comes before `line`: the line is one of its actions.
 * @param {string[]} lines
 * @param {number} start  the rule's first line
 * @param {number} line
 */
function inActions(lines, start, line) {
    for (let l = start; l < line; l++) if ((lines[l - 1] ?? "").trim().startsWith("->")) return true;
    return false;
}
