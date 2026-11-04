// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// A program holding library schemas, whose own names hold a `.` ([LIMP.13.1]),
// under the two things dsdb compiles from a `.dsc`'s declarations: a query and
// a typed `emit`. A declaration's `NAME` cannot hold one ([LGRA.5.1]), so
// Program.stage writes the libraries back out and the generated program imports
// them (DSDB.md §3). Two libraries declare `Reply`, and `c`'s schema refers to
// `a`'s, so the libraries have to come back as libraries and not as one list.

import { test, before } from "node:test";
import assert from "node:assert/strict";

import { compilerPort } from "../lib/cli/open.js";
import { EngineTimeline } from "../lib/core/engine-timeline.js";
import { read as readProgram } from "../lib/core/program.js";
import { Queries, evaluateEmit } from "../lib/core/query.js";
import { NO_COMPILER, TARGET } from "./compiler.mjs";

const FIXTURES = process.env.DS_JS_FIXTURES;
const NO_ENGINE = FIXTURES ? false : "needs the js gate's engine and compiled fixtures (DS_JS_FIXTURES)";
const NO_DSC = NO_ENGINE || NO_COMPILER;

const ROOT = "/libraries";
const LIBRARIES = {
    [`${ROOT}/a.ds`]: "schema Reply scope logical:\n    k: Int key\n    v: Int mutable\n",
    [`${ROOT}/b.ds`]: "schema Reply scope logical:\n    k: Int key\n    w: Int mutable\n",
    [`${ROOT}/c.ds`]: "from a import Reply\n\nschema Held scope logical:\n    k: Int key\n    r: Reply mutable\n",
};
const PROGRAM = "use default\n\nfrom a import Reply as AR\nimport b\nimport c\n\n"
    + "schema Go scope logical:\n    n: Int key\n    r: AR mutable\n";

let ds, compile, dsc;
before(async () => {
    if (NO_DSC) return;
    const jsBinding = await import(new URL("../../../bindings/js/lib/index.js", import.meta.url).href);
    ds = await jsBinding.open({ target: TARGET });
    compile = compilerPort(ds);
    dsc = await compile(PROGRAM, { file: "program.ds", searchPath: [ROOT], files: LIBRARIES });
});

// The path: compileQuery -> Program.declarations and Program.stage ->
// compilerPort, then QueryEngine's #assert, which finds the recorded own name
// in the query engine's own schemas.
test("a query names a library schema by its own name, and answers from that schema alone ([LIMP.13.1])",
     { skip: NO_DSC }, async () => {
    const live = EngineTimeline.live(ds, dsc);
    try {
        live.assertFact("a.Reply", { k: 1n, v: 10n });
        live.assertFact("b.Reply", { k: 1n, w: 20n });
        const tl = live.tl;
        const qs = new Queries(ds, readProgram(ds, dsc), tl, compile);
        const a = await qs.get("a.Reply x", tl.length);
        const b = await qs.get("b.Reply y", tl.length);
        assert.equal(a.answers.length, 1, "a.Reply's one fact");
        assert.equal(b.answers.length, 1, "b.Reply's one fact");
        assert.notEqual(a.answers[0].bindings[0], b.answers[0].bindings[0], "two facts, of two schemas");
        assert.equal(a.skipped, 0);
        assert.equal(b.skipped, 0);
    } finally {
        live.close();
    }
});

// The path: Program.declarations's `type` and #importOf: the hit schema and
// `Go` type a slot through the alias, since a type is one symbol.
test("a query over a schema with a slot of a library schema compiles", { skip: NO_DSC }, async () => {
    const live = EngineTimeline.live(ds, dsc);
    try {
        const tl = live.tl;
        const qs = new Queries(ds, readProgram(ds, dsc), tl, compile);
        assert.deepEqual((await qs.get("Go g", tl.length)).answers, []);
        assert.deepEqual((await qs.get("c.Held h", tl.length)).answers, []);
    } finally {
        live.close();
    }
});

// The path: evaluateEmit -> Program.declarations(true) and Program.stage(true).
test("an `emit` typed at the prompt names a library schema by its own name", { skip: NO_DSC }, async () => {
    const prog = readProgram(ds, dsc);
    const [schema, slots] = await evaluateEmit({ prog, line: "emit b.Reply k: 2 w: 3", n: 1, names: prog.names(), compile, ds });
    assert.equal(schema, "b.Reply");
    assert.equal(slots.w, 3n);
});

// A program with no library schema stages nothing, so what dsdb compiles for
// it, and any message from that compile, is what it was.
test("a program with no library schema stages nothing", { skip: NO_DSC }, async () => {
    const plain = await compile("use default\n\nschema T scope logical:\n    k: Int key\n", { file: "t.ds" });
    const prog = readProgram(ds, plain);
    assert.deepEqual(prog.stage(), {});
    assert.equal(prog.spelling("T"), "T");
});
