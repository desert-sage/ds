// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// `dsc dump-ast`'s JSON as a tree, checked against ds.asdl. The JavaScript
// side of ds_ast's `from_json` (tools/ds_ast/ds_ast/_parse.py), and as
// STRICT, in both directions: a `_type` the schema does not name, a key a node
// does not have, a field or attribute the writer left out, and a value of the
// wrong kind are each a TreeError. That strictness is what makes the Mercury
// writer's names checkable against ds.asdl from here too: a name that drifted
// is an error, not a silently missing key.
//
// No parser here, and no I/O. The compiler is the only parser ([LTSL.1.2]);
// whoever runs `dsc dump-ast` hands its output to readModule. Positions are
// as `dsc` gives them: `lineno` 1-based, `col_offset` 0-based in code points.

import { NODES, TYPES } from "./nodes.js";

/** @import { Field, Module, Node } from "./nodes.js" */

/**
 * `dsc` wrote a tree ds.asdl does not describe: a disagreement between the
 * compiler and this reader, never a problem with the program.
 */
export class TreeError extends Error {
    /** @param {string} message */
    constructor(message) {
        super(message);
        this.name = "TreeError";
    }
}

/**
 * A whole program's tree, from the JSON `dsc dump-ast` writes.
 * @param {unknown} json  the parsed JSON
 * @returns {Module}
 */
export function readModule(json) {
    const tree = readNode(json, "the root");
    if (tree._type !== "Module") throw new TreeError(`the root is ${tree._type}, not Module`);
    return tree;
}

/**
 * One node, checked with everything under it.
 * @param {unknown} value
 * @param {string} where  what holds it, for a message
 * @returns {Node}
 */
export function readNode(value, where) {
    if (value === null || typeof value !== "object" || Array.isArray(value))
        throw new TreeError(`${where} is not a node`);
    const obj = /** @type {Record<string, unknown>} */ (value);
    const type = obj._type;
    if (typeof type !== "string") throw new TreeError(`${where} has no _type`);
    // An ASDL type (`expr`, `decl`) is a set of nodes, never one.
    const shape = NODES.get(type);
    if (shape === undefined) throw new TreeError(`\`${type}\` is not a node in ds.asdl`);
    const declared = [...shape.fields, ...shape.attributes];
    const names = new Set(declared.map((f) => f.name));
    const extra = Object.keys(obj).filter((k) => k !== "_type" && !names.has(k)).sort();
    if (extra.length) throw new TreeError(`${type} has no ${extra.join(", ")}`);
    const missing = declared.filter((f) => !Object.hasOwn(obj, f.name)).map((f) => f.name).sort();
    if (missing.length) throw new TreeError(`${type} was written without ${missing.join(", ")}`);
    for (const f of declared) check(obj[f.name], f, `${type}.${f.name}`);
    return /** @type {Node} */ (value);
}

/**
 * A field's value is what its declaration says.
 * @param {unknown} value
 * @param {Field} field
 * @param {string} where
 */
function check(value, field, where) {
    if (field.kind === "*") {
        if (!Array.isArray(value)) throw new TreeError(`${where} is not a list`);
        value.forEach((item, i) => one(item, field.type, `${where}[${i}]`));
        return;
    }
    if (value === null) {
        // A Constant's value may be null: `null` is a DS literal.
        if (field.kind === "?" || field.type === "constant") return;
        throw new TreeError(`${where} is null, and is required`);
    }
    one(value, field.type, where);
}

/**
 * One value of an ASDL type or a builtin.
 * @param {unknown} value
 * @param {string} type
 * @param {string} where
 */
function one(value, type, where) {
    switch (type) {
    case "identifier":
    case "string":
        if (typeof value !== "string") throw new TreeError(`${where} should be a string`);
        return;
    case "int":
        if (!Number.isInteger(value)) throw new TreeError(`${where} should be an int`);
        return;
    case "bool":
        if (typeof value !== "boolean") throw new TreeError(`${where} should be a bool`);
        return;
    case "constant":
        if (value !== null && !["number", "string", "boolean"].includes(typeof value))
            throw new TreeError(`${where} should be a constant`);
        return;
    }
    const node = readNode(value, where);
    if (!TYPES.get(type)?.includes(node._type))
        throw new TreeError(`${where} should be ${type}, got ${node._type}`);
}

/**
 * Every node at and under `node`, parents first, children in field order:
 * Python's `ast.walk`, but depth-first, so source order is kept.
 * @param {Node} node
 * @returns {Generator<Node>}
 */
export function* walk(node) {
    yield node;
    const shape = /** @type {import("./nodes.js").Shape} */ (NODES.get(node._type));
    const obj = /** @type {Record<string, unknown>} */ (/** @type {unknown} */ (node));
    for (const f of shape.fields) {
        if (BUILTIN.has(f.type)) continue;
        const v = obj[f.name];
        if (Array.isArray(v)) for (const item of v) yield* walk(/** @type {Node} */ (item));
        else if (v !== null) yield* walk(/** @type {Node} */ (v));
    }
}

/** The builtin types: a field of one holds no node. */
const BUILTIN = new Set(["identifier", "string", "int", "bool", "constant"]);
