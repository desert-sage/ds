// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The syntax tree's JavaScript side (lib/ast/): the generated table agrees
// with itself, the reader refuses every shape ds.asdl does not describe, and
// every program `dsc dump-ast` writes for the fixtures reads. The last needs
// the lane's compiler for its target (compiler.mjs).

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { NODES, TYPES } from "../lib/ast/nodes.js";
import { TreeError, readModule, readNode, walk } from "../lib/ast/read.js";
import { NO_COMPILER, dumpAst } from "./compiler.mjs";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const CORPUS = [join(HERE, "fixtures"), join(HERE, "..", "..", "..", "bindings", "js", "test", "fixtures")];

/** A located expression, as `dsc dump-ast` writes one. */
const at = { lineno: 1, col_offset: 0, end_lineno: 1, end_col_offset: 1 };
const trivia = { comments_before: [], comment_after: null, blank_lines_before: 0 };

/** The smallest program: `const C = 1`. */
function program() {
    return {
        _type: "Module", use: null, comments_end: [],
        body: [{ _type: "Const", name: "C", annotation: null, colon_form: false, ...at, ...trivia,
                 value: { _type: "Constant", value: 1, raw: "1", ...at } }],
    };
}

test("every type's constructors are nodes of that type, and every node belongs to its type", () => {
    for (const [type, ctors] of TYPES)
        for (const c of ctors) assert.equal(NODES.get(c)?.type, type, `${c} under ${type}`);
    for (const [name, shape] of NODES) assert.ok(TYPES.get(shape.type)?.includes(name), name);
});

test("every field names a builtin or a type ds.asdl defines", () => {
    const builtin = new Set(["identifier", "string", "int", "bool", "constant"]);
    for (const [name, shape] of NODES)
        for (const f of [...shape.fields, ...shape.attributes])
            assert.ok(builtin.has(f.type) || TYPES.has(f.type), `${name}.${f.name}: ${f.type}`);
});

test("a well-formed tree reads, and walk visits it in source order", () => {
    const tree = readModule(program());
    assert.deepEqual([...walk(tree)].map((n) => n._type), ["Module", "Const", "Constant"]);
});

test("the reader refuses what ds.asdl does not describe", () => {
    /** @param {(t: any) => void} spoil  @param {RegExp} why */
    const refused = (spoil, why) => {
        const t = program();
        spoil(t);
        assert.throws(() => readModule(t), (e) => e instanceof TreeError && why.test(e.message));
    };
    refused((t) => { delete t._type; }, /has no _type/);
    refused((t) => { t.body[0]._type = "Constt"; }, /`Constt` is not a node/);
    // An ASDL type is a set of nodes, never one.
    refused((t) => { t.body[0]._type = "decl"; }, /`decl` is not a node/);
    refused((t) => { t.body[0].extra = 1; }, /Const has no extra/);
    refused((t) => { delete t.body[0].colon_form; }, /Const was written without colon_form/);
    refused((t) => { t.body[0].name = null; }, /Const\.name is null, and is required/);
    refused((t) => { t.body[0].colon_form = 0; }, /Const\.colon_form should be a bool/);
    refused((t) => { t.body[0].lineno = "1"; }, /Const\.lineno should be an int/);
    refused((t) => { t.body = {}; }, /Module\.body is not a list/);
    // A node of the wrong type in a field: an expr where a decl goes.
    refused((t) => { t.body[0] = t.body[0].value; }, /Module\.body\[0\] should be decl, got Constant/);
    refused((t) => { t.body[0].value = { _type: "Module", use: null, body: [], comments_end: [] }; },
            /Const\.value should be expr, got Module/);
});

test("the root must be a Module", () => {
    assert.throws(() => readModule(program().body[0]), /the root is Const, not Module/);
    // readNode takes any node, for a tree already in hand.
    assert.equal(readNode(program().body[0], "a decl")._type, "Const");
});

test("a Constant's value may be null: `null` is a DS literal", () => {
    const t = program();
    t.body[0].value.value = null;
    t.body[0].value.raw = "null";
    assert.equal(readModule(t).body.length, 1);
});

test("every fixture `dsc dump-ast` dumps reads", { skip: NO_COMPILER }, async () => {
    const files = CORPUS.flatMap((dir) => readdirSync(dir).filter((f) => f.endsWith(".ds")).map((f) => join(dir, f)));
    // A corpus that found nothing would pass vacuously.
    assert.ok(files.length >= 10, `only ${files.length} fixtures found under ${CORPUS.join(", ")}`);
    for (const path of files) {
        const dumped = await dumpAst(readFileSync(path, "utf8"), path);
        if (!("tree" in dumped)) assert.fail(`dsc dump-ast ${path}: ${dumped.refused}`);
        const tree = readModule(dumped.tree);
        assert.ok([...walk(tree)].length > 1, `${path} read as an empty tree`);
    }
});
