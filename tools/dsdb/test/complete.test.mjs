// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// `ds lsp`'s completion (lib/lsp/complete.js), over a program dumped by the
// lane's compiler for its target (compiler.mjs). Each case types something on
// one line of the program, as an editor would, and completes there with the
// program's tree.

import { test, before } from "node:test";
import assert from "node:assert/strict";

import { readModule } from "../lib/ast/read.js";
import { complete } from "../lib/lsp/complete.js";
import { lines as split } from "../lib/lsp/positions.js";
import { NO_COMPILER as NO_DSC, dumpAst } from "./compiler.mjs";

const PROGRAM = `use default

import math
from distance import cosine

const LIMIT = 90.0

schema Reading scope ttl 60_s:
    sensor: String
    temp: Float

schema Alert scope logical:
    sensor: String key

rule hot:
    Reading r where r.temp > LIMIT
->
    emit Alert logical sensor: r.sensor
`;

/** @type {import("../lib/ast/nodes.js").Module} the program's tree, dumped once */
let TREE;
before(async () => {
    if (NO_DSC) return;
    const dumped = await dumpAst(PROGRAM, "hot.ds");
    if (!("tree" in dumped)) assert.fail(dumped.refused);
    TREE = readModule(dumped.tree);
});

/** @returns {import("../lib/ast/nodes.js").Module} */
function tree() {
    return TREE;
}

/**
 * The labels completion offers once `typed` replaces line `at` (0-based) of
 * the program, with the cursor at its end.
 * @param {number} at
 * @param {string} typed
 */
function labels(at, typed) {
    const ls = split(PROGRAM);
    ls[at] = typed;
    return complete(tree(), ls, at + 1, [...typed].length).map((i) => i.label);
}

const RULE_WHERE = 15, RULE_ACTION = 17, BLANK = 4;

test("after a binding's `.`: the slots of the schema its pattern names", { skip: NO_DSC }, () => {
    assert.deepEqual(labels(RULE_WHERE, "    Reading r where r."), ["sensor", "temp"]);
    assert.deepEqual(labels(RULE_WHERE, "    Reading r where r.te"), ["sensor", "temp"], "the editor filters by the prefix");
});

test("after an imported module's `.`: its members; a module not imported reaches nothing (LIMP.3.3.4)", { skip: NO_DSC }, () => {
    const math = labels(RULE_WHERE, "    Reading r where math.");
    assert.ok(math.includes("sqrt") && math.includes("atan2") && math.includes("ln"), math.join(" "));
    assert.ok(!math.includes("math.sqrt"), "a member is offered by its own name");
    assert.deepEqual(labels(RULE_WHERE, "    Reading r where distance."), [], "the program does not `import distance`");
});

test("in an expression: the rule's bindings, the program's constants, the builtins it reaches", { skip: NO_DSC }, () => {
    const got = labels(RULE_WHERE, "    Reading r where r.temp > ");
    for (const want of ["r", "LIMIT", "abs", "now", "math", "cosine", "mean", "true", "null", "and"])
        assert.ok(got.includes(want), `${want} in ${got.length} items`);
    assert.ok(!got.includes("distance"), "not imported, so not offered as a module");
    assert.ok(!got.includes("sqrt"), "math's members are qualified unless a from-import makes them bare");
    assert.ok(!got.includes("bytes_to_utf8"), "no builtin (LEXP.17.2; LSTR.4.6 refuses it), so not offered");
});

test("after emit: the program's schemas", { skip: NO_DSC }, () => {
    assert.deepEqual(labels(RULE_ACTION, "    emit ").sort(), ["Alert", "Reading"]);
});

test("at an action line's start, the action verbs; at a pattern line's, the schemas", { skip: NO_DSC }, () => {
    const action = labels(RULE_ACTION, "    em");
    assert.ok(action.includes("emit") && action.includes("withdraw") && action.includes("let"), action.join(" "));
    assert.ok(!action.includes("Reading"), "a schema does not start an action");
    const pattern = labels(RULE_WHERE, "    Re");
    assert.ok(pattern.includes("Reading") && pattern.includes("no"), pattern.join(" "));
    assert.ok(!pattern.includes("emit"), "an action does not start a pattern");
});

test("at an action line's start, `record_event` is not offered: it is reserved and starts no action (LGRA.10.1.5, LLEX.9.8)", { skip: NO_DSC }, () => {
    const action = labels(RULE_ACTION, "    re");
    assert.ok(action.includes("publish"), action.join(" "));
    assert.ok(!action.includes("record_event"), action.join(" "));
});

test("at the top level: the declaration keywords; after `::`, the builtin types", { skip: NO_DSC }, () => {
    const top = labels(BLANK, "sc");
    assert.ok(top.includes("schema") && top.includes("rule") && top.includes("use"), top.join(" "));
    const cast = labels(RULE_WHERE, "    Reading r where r.temp::");
    assert.ok(cast.includes("Int") && cast.includes("Duration"), cast.join(" "));
});

test("with no tree yet, the declaration keywords still complete", () => {
    const got = complete(null, ["sc"], 1, 2).map((i) => i.label);
    assert.ok(got.includes("schema"));
});
