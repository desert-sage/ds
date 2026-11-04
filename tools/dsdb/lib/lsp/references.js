// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// References and rename, across the program: the
// document and every library it imports, transitively. An import resolves as
// the compiler resolves it ([LIMP.3.1.4]): `import a.b` is `<dir>/a/b.ds` on
// the first search-path entry that has it, the importing file's own
// directory first. A library that does not resolve, or does not parse, is
// left out; the compiler reports it.
//
// What a name refers to is decided per file, the way the file sees it: a
// schema or constant declared there, or one a `from L import X` brings in,
// or `L.X` / `L;X` through an `import L`. Two sites refer to one thing only
// when both resolve to the same declaration. A rule's binding is that rule's.
//
// The tree gives each statement a location and most names none (ds.asdl's
// `type_ref`, an identifier field), so a name's range is found in its
// statement's text (analysis.js nameRange); a `Name` or `Attribute`
// expression carries its own.

import { walk } from "../ast/read.js";
import { bindings, declName, nameRange, patternBodies, typeName, wordAt, declAt } from "./analysis.js";

/** @import { Module, Rule, Schema, Slot, decl_t, type_ref_t } from "../ast/nodes.js" */
/** @import { NameRange } from "./analysis.js" */

/**
 * One file of the program.
 * @typedef {object} Unit
 * @property {string} uri
 * @property {string | null} path
 * @property {string[]} lines
 * @property {Module} tree
 * @property {Map<string, Unit>} modules  each `import L` (or `as q`), by its qualifier
 * @property {Map<string, { unit: Unit, name: string }>} bare  each from-imported name, by its local name
 */

/**
 * The files the server reads a library from.
 * @typedef {object} Sources
 * @property {(path: string) => string | null} read  a file's text, or null if there is none
 * @property {(text: string, file: string) => Module | null} tree  its syntax tree, or null if it does not parse
 * @property {(path: string) => string} uri
 */

/** What a site refers to: a declaration, a schema's slot, or a rule's binding. */
/**
 * @typedef {{ kind: "decl", unit: Unit, decl: decl_t, name: string }
 *     | { kind: "slot", unit: Unit, schema: Schema, slot: Slot }
 *     | { kind: "binding", unit: Unit, rule: Rule, name: string }} Ref
 */

/** @typedef {{ unit: Unit, range: NameRange, declaration: boolean }} Site */

/**
 * The program rooted at a document.
 * @param {{ uri: string, path: string | null, lines: string[], tree: Module }} root
 * @param {string[]} search  library directories, after a file's own
 * @param {Sources} src
 * @returns {Unit}
 */
export function program(root, search, src) {
    /** @type {Map<string, Unit>} */
    const byPath = new Map();
    /** @param {Unit} unit */
    const link = (unit) => {
        for (const d of unit.tree.body) {
            if (d._type !== "Import" && d._type !== "ImportFrom") continue;
            const lib = library(unit, d.path);
            if (lib === null) continue;
            if (d._type === "Import") unit.modules.set(d.asname ?? d.path.join("."), lib);
            else for (const a of d.names) unit.bare.set(a.asname ?? a.name, { unit: lib, name: a.name });
        }
    };
    /**
     * @param {Unit} from
     * @param {string[]} segments
     * @returns {Unit | null}
     */
    const library = (from, segments) => {
        const dirs = from.path === null ? search : [dirOf(from.path), ...search];
        for (const dir of dirs) {
            const path = [dir, ...segments].join("/") + ".ds";
            const known = byPath.get(path);
            if (known !== undefined) return known;
            const text = src.read(path);
            if (text === null) continue;
            const tree = src.tree(text, path);
            if (tree === null) return null;
            /** @type {Unit} */
            const unit = { uri: src.uri(path), path, lines: text.split(/\r\n|\n|\r/), tree, modules: new Map(), bare: new Map() };
            byPath.set(path, unit);
            link(unit);
            return unit;
        }
        return null;
    };
    /** @type {Unit} */
    const top = { ...root, modules: new Map(), bare: new Map() };
    if (root.path !== null) byPath.set(root.path, top);
    link(top);
    return top;
}

/** @param {string} path */
const dirOf = (path) => path.slice(0, Math.max(0, path.lastIndexOf("/"))) || "/";

/**
 * Every file of the program, the root first.
 * @param {Unit} top
 * @returns {Unit[]}
 */
export function units(top) {
    /** @type {Unit[]} */
    const out = [];
    /** @type {Set<Unit>} */
    const seen = new Set();
    /** @param {Unit} u */
    const visit = (u) => {
        if (seen.has(u)) return;
        seen.add(u);
        out.push(u);
        for (const m of u.modules.values()) visit(m);
        for (const b of u.bare.values()) visit(b.unit);
    };
    visit(top);
    return out;
}

/**
 * The declaration `name` names in a file: its own, or one an import brings.
 * @param {Unit} unit
 * @param {string} name
 * @returns {{ unit: Unit, decl: decl_t } | null}
 */
function lookup(unit, name) {
    for (const d of unit.tree.body) if (declName(d) === name) return { unit, decl: d };
    const b = unit.bare.get(name);
    if (b === undefined) return null;
    for (const d of b.unit.tree.body) if (declName(d) === b.name) return { unit: b.unit, decl: d };
    return null;
}

/**
 * The declaration a schema reference names, written plain or qualified.
 * @param {Unit} unit
 * @param {type_ref_t} ref
 */
function lookupType(unit, ref) {
    if (ref._type === "TypeName") return lookup(unit, ref.name);
    const lib = unit.modules.get(ref.library.join("."));
    if (lib === undefined) return null;
    for (const d of lib.tree.body) if (declName(d) === ref.name) return { unit: lib, decl: d };
    return null;
}

/**
 * What the name at a position refers to, in the program.
 * @param {Unit} unit  the position's file
 * @param {number} line
 * @param {number} col
 * @returns {Ref | null}
 */
export function refAt(unit, line, col) {
    const w = wordAt(unit.lines[line - 1] ?? "", col);
    if (w === null) return null;
    const d = declAt(unit.tree, line, col);
    if (d?._type === "Rule") {
        const bs = bindings(d);
        if (w.qualifier !== null) {
            const body = bs.get(w.qualifier);
            if (body !== undefined) {
                const s = lookupType(unit, body.type);
                const slot = s?.decl._type === "Schema" ? s.decl.slots.find((x) => x.name === w.word) : undefined;
                return s && slot && s.decl._type === "Schema" ? { kind: "slot", unit: s.unit, schema: s.decl, slot } : null;
            }
            const lib = unit.modules.get(w.qualifier);
            if (lib === undefined) return null;
            for (const x of lib.tree.body) if (declName(x) === w.word) return { kind: "decl", unit: lib, decl: x, name: w.word };
            return null;
        }
        if (bs.has(w.word)) return { kind: "binding", unit, rule: d, name: w.word };
        for (const n of walk(d)) {
            if ((n._type === "Emit" || n._type === "Publish" || n._type === "RecordEvent") && n.lineno === line
                && [...n.args, ...n.block].some((k) => k.arg === w.word && k.lineno === line)) {
                const s = lookupType(unit, n.schema);
                const slot = s?.decl._type === "Schema" ? s.decl.slots.find((x) => x.name === w.word) : undefined;
                if (s && slot && s.decl._type === "Schema") return { kind: "slot", unit: s.unit, schema: s.decl, slot };
            }
        }
    }
    if (d?._type === "Schema") {
        const slot = d.slots.find((s) => s.lineno === line && s.name === w.word);
        if (slot) return { kind: "slot", unit, schema: d, slot };
    }
    const found = lookup(unit, w.word);
    return found === null ? null : { kind: "decl", unit: found.unit, decl: found.decl, name: declName(found.decl) ?? w.word };
}

/**
 * Every site of what `ref` refers to, across the program, its declaration
 * marked.
 * @param {Unit} top
 * @param {Ref} ref
 * @returns {Site[]}
 */
export function sites(top, ref) {
    /** @type {Site[]} */
    const out = [];
    /** @param {Unit} unit @param {NameRange} range @param {boolean} [declaration] */
    const add = (unit, range, declaration = false) => out.push({ unit, range, declaration });
    if (ref.kind === "binding") {
        bindingSites(ref, add);
        return out;
    }
    if (ref.kind === "decl") add(ref.unit, nameRange(ref.unit.lines, ref.decl, ref.name), true);
    else add(ref.unit, nameRange(ref.unit.lines, ref.slot, ref.slot.name), true);
    for (const unit of units(top)) {
        if (ref.kind === "decl") declSites(unit, ref, add);
        else slotSites(unit, ref, add);
    }
    return out;
}

/**
 * @param {Extract<Ref, { kind: "binding" }>} ref
 * @param {(unit: Unit, range: NameRange, declaration?: boolean) => void} add
 */
function bindingSites(ref, add) {
    const { unit, rule, name } = ref;
    for (const body of patternBodies(rule.lhs))
        if (body.binding === name) add(unit, nameAfter(unit.lines, body, typeName(body.type), name), true);
    for (const n of walk(rule)) if (n._type === "Name" && n.id === name) add(unit, exprRange(n, name));
}

/**
 * Sites in one file of a declaration, written under its own name.
 * @param {Unit} unit
 * @param {Extract<Ref, { kind: "decl" }>} ref
 * @param {(unit: Unit, range: NameRange) => void} add
 */
function declSites(unit, ref, add) {
    const same = (/** @type {{ decl: decl_t } | null} */ r) => r !== null && r.decl === ref.decl;
    for (const d of unit.tree.body) {
        if (d._type === "ImportFrom")
            for (const a of d.names)
                if (a.name === ref.name && unit.bare.get(a.asname ?? a.name)?.unit === ref.unit) add(unit, nameRange(unit.lines, a, a.name));
        if (d._type !== "Rule") continue;
        const bs = bindings(d);
        for (const body of patternBodies(d.lhs))
            if (body.type.name === ref.name && same(lookupType(unit, body.type))) add(unit, nameRange(unit.lines, body, ref.name));
        for (const n of walk(d)) {
            if ((n._type === "Emit" || n._type === "Publish" || n._type === "RecordEvent")
                && n.schema.name === ref.name && same(lookupType(unit, n.schema)))
                add(unit, nameRange(unit.lines, n, ref.name));
            else if (n._type === "Name" && n.id === ref.name && !bs.has(n.id) && same(lookup(unit, n.id)))
                add(unit, exprRange(n, n.id));
            else if (n._type === "Attribute" && n.attr === ref.name && n.value._type === "Name"
                     && unit.modules.get(n.value.id) === ref.unit && !bs.has(n.value.id))
                add(unit, attrRange(unit.lines, n));
        }
    }
}

/**
 * Sites in one file of a slot: read through a binding of its schema, or
 * written by an emit, publish or record of it.
 * @param {Unit} unit
 * @param {Extract<Ref, { kind: "slot" }>} ref
 * @param {(unit: Unit, range: NameRange) => void} add
 */
function slotSites(unit, ref, add) {
    const isSchema = (/** @type {type_ref_t} */ t) => lookupType(unit, t)?.decl === ref.schema;
    for (const d of unit.tree.body) {
        if (d._type !== "Rule") continue;
        /** @type {Set<string>} */
        const of = new Set();
        for (const [b, body] of bindings(d)) if (isSchema(body.type)) of.add(b);
        for (const n of walk(d)) {
            if (n._type === "Attribute" && n.attr === ref.slot.name && n.value._type === "Name" && of.has(n.value.id))
                add(unit, attrRange(unit.lines, n));
            else if ((n._type === "Emit" || n._type === "Publish" || n._type === "RecordEvent") && isSchema(n.schema))
                for (const k of [...n.args, ...n.block]) if (k.arg === ref.slot.name) add(unit, nameRange(unit.lines, k, k.arg));
        }
    }
}

/**
 * A `Name`'s range: it starts where the node does.
 * @param {{ lineno: number, col_offset: number }} n
 * @param {string} name
 * @returns {NameRange}
 */
function exprRange(n, name) {
    return { line: n.lineno, start: n.col_offset, end: n.col_offset + [...name].length };
}

/**
 * An `Attribute`'s name: the first whole-word occurrence after its value,
 * read from the line. `dsc dump-ast` writes an Attribute's end just past its
 * name, but inside an interpolation site the end is null, so the line
 * is what serves every Attribute.
 * @param {string[]} lines
 * @param {import("../ast/nodes.js").Attribute} n
 * @returns {NameRange}
 */
function attrRange(lines, n) {
    const v = n.value;
    const from = v._type === "Name" && v.lineno === n.lineno ? v.col_offset + [...v.id].length : n.col_offset;
    return nameRange(lines, { lineno: n.lineno, col_offset: from }, n.attr);
}

/**
 * A pattern's binding: the first whole-word occurrence after its type.
 * @param {string[]} lines
 * @param {{ lineno: number, col_offset: number }} body
 * @param {string} type
 * @param {string} name
 */
function nameAfter(lines, body, type, name) {
    const t = nameRange(lines, body, type);
    return nameRange(lines, { lineno: body.lineno, col_offset: t.end }, name);
}
