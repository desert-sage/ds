// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// What a name in a program refers to, read from its syntax tree (lib/ast/):
// a declaration, a rule's pattern binding, or a slot of the schema a binding
// or an emit names. Hover and go-to-definition are answers about that.
//
// Positions are the tree's: lines 1-based, columns 0-based in code points.
// The server converts to and from the client's.
//
// The tree records where each statement starts and ends, not where each name
// in it does (ds.asdl gives `type_ref` and identifiers no location). So the
// name under the cursor is read from the line's text, and the tree says what
// the enclosing statement makes of it.

import { walk } from "../ast/read.js";

/**
 * @import { Module, PatternBody, Rule, Schema, Slot, decl_t, expr_t, scope_t, type_ref_t, lhs_t, keyword }
 *     from "../ast/nodes.js"
 */

/**
 * What a name refers to.
 * @typedef {{ kind: "decl", decl: decl_t, name: string }
 *     | { kind: "binding", name: string, body: PatternBody, schema: Schema | null }
 *     | { kind: "slot", schema: Schema, slot: Slot }} Target
 */

/** @typedef {{ line: number, start: number, end: number }} NameRange  one line, a code-point range */

/** A name's characters: DS names are UAX #31 identifiers ([LNAM.2]), close enough for finding one. */
const NAME_CHAR = /[\p{L}\p{N}_]/u;

/**
 * The name a declaration is referred to by, or null for one that has none
 * (an import, a test, the `initial:` block).
 * @param {decl_t} d
 * @returns {string | null}
 */
export function declName(d) {
    switch (d._type) {
    case "Schema": case "Rule": case "Const": case "Opaque": case "UnitDimension": case "UnitScalar":
    case "UnitFormula": case "UnitFxPair":
        return d.name;
    case "UnitSymbol":
        return d.symbol;
    case "Service":
        return d.name.join(".");
    default:
        return null;
    }
}

/**
 * The program's declarations by name; the first of a name, if it has two
 * (the compiler refuses the second).
 * @param {Module} mod
 * @returns {Map<string, decl_t>}
 */
export function declarations(mod) {
    /** @type {Map<string, decl_t>} */
    const out = new Map();
    for (const d of mod.body) {
        const name = declName(d);
        if (name !== null && !out.has(name)) out.set(name, d);
    }
    return out;
}

/**
 * The schema a pattern or a verb names: its last name, which is the schema's
 * own whether or not a library qualifies it.
 * @param {type_ref_t} ref
 */
export function typeName(ref) {
    return ref.name;
}

/**
 * `node` spans the position. A node with no recorded end spans its first line
 * from its start.
 * @param {{ lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null }} node
 * @param {number} line
 * @param {number} col
 */
export function spans(node, line, col) {
    if (line < node.lineno || (line === node.lineno && col < node.col_offset)) return false;
    if (node.end_lineno === null || node.end_col_offset === null) return line === node.lineno;
    return line < node.end_lineno || (line === node.end_lineno && col <= node.end_col_offset);
}

/**
 * The declaration the position is in. One whose end the tree does not record
 * runs to the next declaration's start, or to the end of the file: a
 * position between two declarations is the earlier one's (its trailing
 * comments and blank lines).
 * @param {Module} mod
 * @param {number} line
 * @param {number} col
 * @returns {decl_t | null}
 */
export function declAt(mod, line, col) {
    const body = mod.body;
    for (let i = 0; i < body.length; i++) {
        const d = body[i];
        if (line < d.lineno || (line === d.lineno && col < d.col_offset)) return null;
        if (d.end_lineno !== null && d.end_col_offset !== null) {
            if (spans(d, line, col)) return d;
            continue;
        }
        const next = body[i + 1];
        if (next === undefined || line < next.lineno || (line === next.lineno && col < next.col_offset)) return d;
    }
    return null;
}

/**
 * The rule the position is in.
 * @param {Module} mod
 * @param {number} line
 * @param {number} col
 * @returns {Rule | null}
 */
export function ruleAt(mod, line, col) {
    const d = declAt(mod, line, col);
    return d?._type === "Rule" ? d : null;
}

/**
 * Every pattern body on a rule's left-hand side, in source order.
 * @param {lhs_t[]} lhs
 * @returns {PatternBody[]}
 */
export function patternBodies(lhs) {
    /** @type {PatternBody[]} */
    const out = [];
    for (const clause of lhs) {
        if (clause._type === "ThenClause") {
            out.push(clause.step.body);
            continue;
        }
        const p = clause.pattern;
        if (p._type === "Sequence") out.push(p.head, ...p.steps.map((s) => s.body));
        else out.push(p.body);
    }
    return out;
}

/**
 * A rule's pattern bindings, each to the pattern that makes it.
 * @param {Rule} rule
 * @returns {Map<string, PatternBody>}
 */
export function bindings(rule) {
    /** @type {Map<string, PatternBody>} */
    const out = new Map();
    for (const body of patternBodies(rule.lhs)) if (body.binding !== null && !out.has(body.binding)) out.set(body.binding, body);
    return out;
}

/**
 * The name under (or just before) a code-point column, and the name before a
 * `.` in front of it, if any: `r.value` at `value` gives `value` and `r`.
 * @param {string} text  the line
 * @param {number} col
 * @returns {{ word: string, start: number, end: number, qualifier: string | null } | null}
 */
export function wordAt(text, col) {
    const cps = [...text];
    const is = (/** @type {number} */ i) => i >= 0 && i < cps.length && NAME_CHAR.test(cps[i]);
    let at = col;
    if (!is(at) && is(at - 1)) at--;
    if (!is(at)) return null;
    let start = at, end = at;
    while (is(start - 1)) start--;
    while (is(end)) end++;
    /** @type {string | null} */
    let qualifier = null;
    if (cps[start - 1] === "." && is(start - 2)) {
        let q = start - 1;
        while (is(q - 1)) q--;
        qualifier = cps.slice(q, start - 1).join("");
    }
    return { word: cps.slice(start, end).join(""), start, end, qualifier };
}

/**
 * The schema `name` declares in this program.
 * @param {Map<string, decl_t>} decls
 * @param {string} name
 * @returns {Schema | null}
 */
function schemaNamed(decls, name) {
    const d = decls.get(name);
    return d?._type === "Schema" ? d : null;
}

/**
 * The emit, publish or record that spans the position, with the keyword
 * arguments it writes slots with.
 * @param {Rule} rule
 * @param {number} line
 * @param {number} col
 * @returns {{ schema: string, args: keyword[] } | null}
 */
function verbAt(rule, line, col) {
    /** @type {{ schema: string, args: keyword[] } | null} */
    let found = null;
    for (const n of walk(rule)) {
        if ((n._type === "Emit" || n._type === "Publish" || n._type === "RecordEvent") && spans(n, line, col))
            found = { schema: typeName(n.schema), args: [...n.args, ...n.block] };
    }
    return found;
}

/**
 * What the name at a position refers to, or null for nothing the program
 * declares: a keyword, a builtin, a literal.
 * @param {Module} mod
 * @param {string} text  the position's line
 * @param {number} line
 * @param {number} col
 * @returns {Target | null}
 */
export function resolve(mod, text, line, col) {
    const w = wordAt(text, col);
    if (w === null) return null;
    const decls = declarations(mod);
    const rule = ruleAt(mod, line, col);
    if (w.qualifier !== null) {
        // `b.slot`: a slot of the schema b's pattern names.
        const body = rule === null ? undefined : bindings(rule).get(w.qualifier);
        const schema = body === undefined ? null : schemaNamed(decls, typeName(body.type));
        const slot = schema?.slots.find((s) => s.name === w.word);
        return schema && slot ? { kind: "slot", schema, slot } : null;
    }
    if (rule !== null) {
        const body = bindings(rule).get(w.word);
        if (body !== undefined)
            return { kind: "binding", name: w.word, body, schema: schemaNamed(decls, typeName(body.type)) };
        // `emit Alert sensor: …`: `sensor` is a slot of Alert.
        const verb = verbAt(rule, line, col);
        const schema = verb === null ? null : schemaNamed(decls, verb.schema);
        if (verb !== null && schema !== null && verb.args.some((k) => k.arg === w.word && spans(k, line, w.start))) {
            const slot = schema.slots.find((s) => s.name === w.word);
            if (slot) return { kind: "slot", schema, slot };
        }
    }
    const decl = decls.get(w.word);
    if (decl !== undefined) return { kind: "decl", decl, name: w.word };
    // A slot's own declaration.
    const d = declAt(mod, line, col);
    if (d?._type === "Schema") {
        const slot = d.slots.find((s) => s.lineno === line && s.name === w.word);
        if (slot) return { kind: "slot", schema: d, slot };
    }
    return null;
}

/**
 * Where a name is written in the statement that starts on `node`'s line:
 * the first whole-word occurrence at or after its start column.
 * @param {string[]} lines  the document's
 * @param {{ lineno: number, col_offset: number }} node
 * @param {string} name
 * @returns {NameRange}
 */
export function nameRange(lines, node, name) {
    const cps = [...(lines[node.lineno - 1] ?? "")];
    const want = [...name];
    for (let i = node.col_offset; i + want.length <= cps.length; i++) {
        if (want.every((c, k) => cps[i + k] === c)
            && !NAME_CHAR.test(cps[i - 1] ?? "") && !NAME_CHAR.test(cps[i + want.length] ?? ""))
            return { line: node.lineno, start: i, end: i + want.length };
    }
    return { line: node.lineno, start: node.col_offset, end: node.col_offset };
}

/**
 * Where a target is declared.
 * @param {string[]} lines
 * @param {Target} t
 * @returns {NameRange}
 */
export function definition(lines, t) {
    switch (t.kind) {
    case "decl": return nameRange(lines, t.decl, t.name);
    case "binding": return nameRange(lines, t.body, t.name);
    case "slot": return nameRange(lines, t.slot, t.slot.name);
    }
}

/**
 * A schema's lifecycle as declared: the keyword, and a ttl scope's duration
 * as written. No `scope` clause is `explicit` ([LSCP.6.2]);
 * `Unprefixed` is the same scope with the keyword left out.
 * @param {scope_t | null} scope
 * @returns {string}
 */
function scopeName(scope) {
    if (scope === null) return "explicit";
    switch (scope._type) {
    case "Unprefixed": return scopeName(scope.scope);
    case "Explicit": return "explicit";
    case "Activation": return "activation";
    case "BareAmbient": return "ambient";
    case "Logical": return scope.ambient ? "logical ambient" : "logical";
    case "Ttl": return `ttl ${exprText(scope.duration)}` + (scope.ambient ? " ambient" : "");
    }
}

/**
 * A literal as written: what a declaration holds where it takes a value (a
 * ttl, a tolerance, a capacity). Anything else is not a literal there, and
 * the compiler refuses it; `…` stands for it.
 * @param {expr_t} e
 * @returns {string}
 */
function exprText(e) {
    switch (e._type) {
    case "Quantity": return e.raw ?? `${e.magnitude}_${e.unit}`;
    case "Constant": return e.raw ?? String(e.value);
    case "Name": return e.id;
    default: return "…";
    }
}

/** @param {Slot} s */
const slotType = (s) => (s.nullable ? `${s.type}?` : s.type);

/** Each marker's keyword ([LGRA]'s slot line). */
const MARKER = /** @type {const} */ ({ Key: "key", Mutable: "mutable", Sampled: "sampled", Retained: "retained" });

/**
 * A slot's line as declared, after its name: its type and nullability, its
 * capacity, its markers in the order written, and its tolerance.
 * @param {Slot} s
 */
function slotDecl(s) {
    const parts = [slotType(s)];
    if (s.capacity !== null) parts[0] += ` capacity ${exprText(s.capacity)}`;
    for (const m of s.markers) parts.push(MARKER[m._type]);
    if (s.tolerance !== null) parts.push(`tolerance ${exprText(s.tolerance)}`);
    return parts.join(" ");
}

/**
 * The hover text for a target: its declaration, in DS, then its docstring.
 * @param {Target} t
 * @returns {string}
 */
export function hoverText(t) {
    switch (t.kind) {
    case "slot":
        return block(`${t.slot.name}: ${slotDecl(t.slot)}  # in ${t.schema.name}`, t.slot.docstring);
    case "binding":
        return block(`${t.name}: ${t.schema?.name ?? typeName(t.body.type)}  # a pattern binding`,
                     null, t.schema === null ? "" : schemaText(t.schema));
    case "decl": {
        const d = t.decl;
        if (d._type === "Schema") return block(schemaText(d), d.docstring);
        if (d._type === "Rule") {
            const pats = patternBodies(d.lhs).map((b) => `    ${typeName(b.type)}${b.binding === null ? "" : " " + b.binding}`);
            return block([`rule ${d.name}:`, ...pats].join("\n"), d.docstring);
        }
        if (d._type === "Const") {
            const v = d.value;
            const raw = v._type === "Constant" || v._type === "Quantity" ? v.raw : null;
            return block(`const ${d.name}${raw === null ? "" : " = " + raw}`, null);
        }
        if (d._type === "Service") return block(`service ${t.name}`, d.docstring);
        return block(`${t.name}  # ${d._type}`, null);
    }
    }
}

/**
 * A schema as declared: its header and its slots.
 * @param {Schema} s
 */
function schemaText(s) {
    return [`schema ${s.name} scope ${scopeName(s.scope)}:`, ...s.slots.map((x) => `    ${x.name}: ${slotDecl(x)}`)].join("\n");
}

/**
 * Markdown: a `ds` code block, then any prose.
 * @param {string} code
 * @param {string | null} doc
 * @param {string} [more]  a second code block
 */
function block(code, doc, more = "") {
    const parts = ["```ds\n" + code + "\n```"];
    if (more) parts.push("```ds\n" + more + "\n```");
    if (doc) parts.push(doc);
    return parts.join("\n\n");
}
