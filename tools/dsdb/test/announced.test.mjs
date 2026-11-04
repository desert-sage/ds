// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// A trace read with no program types its facts by the stream's own Slot
// announcement ([RFCS.5.1]), which libds decodes by, and gets what the
// program would give. A fact-ref slot's value is the fact its record gave:
// the recorded handle is that record's fact_id ([RFCS.6.3]), listed
// as `Motion#2`, with the program or without it. The fixture
// dsdb_announced.ds is compiled by the js gate.

import { test, before } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { replacer } from "../lib/api/json.js";
import { EngineTimeline } from "../lib/core/engine-timeline.js";
import { read as readProgram } from "../lib/core/program.js";
import { Queries } from "../lib/core/query.js";
import { Decoder } from "../lib/core/trace.js";
import { show } from "../lib/dap/adapter.js";
import { recordLines } from "../lib/text/listing.js";
import { slotsText } from "../lib/text/render.js";
import { NO_COMPILER } from "./compiler.mjs";

const TARGET = process.env.DS_JS_TARGET ?? "native";
const FIXTURES = process.env.DS_JS_FIXTURES;
const NO_ENGINE = FIXTURES ? false : "needs the js gate's engine and compiled fixtures (DS_JS_FIXTURES)";
const NO_DSC = NO_ENGINE || NO_COMPILER;

let ds, DSC;
before(async () => {
    if (NO_ENGINE) return;
    const jsBinding = await import(new URL("../../../bindings/js/lib/index.js", import.meta.url).href);
    ds = await jsBinding.open({ target: TARGET });
    DSC = new Uint8Array(readFileSync(join(FIXTURES, "dsdb_announced.dsc")));
});

const RAW = new Uint8Array([0, 7, 255]);

/** A recording: m1 below the rule's level, m2 above it, so make_trace emits a
    Trace holding m2. The live timeline reads its own recording with the
    program, so a fact-ref body must type there too. */
function recording() {
    const live = EngineTimeline.live(ds, DSC);
    try {
        live.assertFact("Motion", { entity_id: "m1", level: 0.25, lit: false, doc: '{"a": [1, 2]}' });
        live.assertFact("Motion", { entity_id: "m2", state: 0n, level: 0.75, lit: true, doc: "[]", raw: RAW });
        return live.bytes();
    } finally {
        live.close();
    }
}

/** The bodies of `bytes`' FactAssert and FactEmit records, read with `dsc` or none. */
function bodies(bytes, dsc = null) {
    const dec = new Decoder(ds, { dsc });
    try {
        const recs = dec.feed(bytes);
        assert.equal(dec.error, null);
        return recs.filter((r) => r.kind === "FactAssert" || r.kind === "FactEmit");
    } finally {
        dec.close();
    }
}

test("with no program, each fact is typed by the announcement, as the program types it", { skip: NO_ENGINE }, () => {
    const bytes = recording();
    const motions = (dsc) => bodies(bytes, dsc).filter((r) => r.body.schema_name === "Motion").map((r) => r.body.slots);
    const bare = motions(null);
    assert.deepEqual(bare, [
        { entity_id: "m1", state: null, level: 0.25, lit: false, doc: '{"a":[1,2]}', raw: null },
        { entity_id: "m2", state: 0n, level: 0.75, lit: true, doc: "[]", raw: RAW },
    ]);
    assert.deepEqual(bare, motions(DSC), "the announcement types as the program does");
});

test("the listing, given no program, shows the slots", { skip: NO_ENGINE }, () => {
    const fa = bodies(recording()).find((r) => r.kind === "FactAssert") ?? assert.fail("no FactAssert");
    const [, lines] = recordLines(fa);
    assert.match(lines[0], /FactAssert {10}Motion#\d+ {2}entity_id='m1'  state=None  level=0\.25  lit=False/);
    assert.doesNotMatch(lines[0], /slots not typed/);
});

// The reference is the fact its record gave, by the schema the slot
// names and that record's fact_id ([RFCS.6.3]). The path: trace.js `#typed`
// over @ds-lang/ds's decodeAnnouncedFactBodyHandles, then each place a slot is
// shown: the listing, the inspector's slotsText, ds dap's show, the API's JSON.
test("a fact-ref slot is the fact its record gave, Motion#n, with the program or without", { skip: NO_ENGINE }, () => {
    const bytes = recording();
    for (const dsc of [null, DSC]) {
        const what = dsc ? "program" : "no program";
        const read = bodies(bytes, dsc);
        const m2 = read.find((r) => r.body.schema_name === "Motion" && r.body.slots?.entity_id === "m2")
            ?? assert.fail(`${what}: no Motion m2`);
        const trace = read.find((r) => r.body.schema_name === "Trace") ?? assert.fail(`${what}: make_trace emitted no Trace`);
        assert.equal(trace.kind, "FactEmit");
        assert.equal(trace.body.untyped, null, what);
        const target = trace.body.slots?.target;
        const ref = `Motion#${m2.body.fact_id}`;
        assert.equal(String(target), ref, `${what}: the reference is m2's record`);
        const [, lines] = recordLines(trace);
        assert.match(lines[0], new RegExp(`Trace#\\d+ {2}target=${ref}`), `${what}: ${lines[0]}`);
        assert.equal(slotsText(trace.body.slots), `target=${ref}`, what);
        assert.equal(show(target), ref, what);
        assert.equal(JSON.stringify(trace.body.slots, replacer), JSON.stringify({ target: ref }), what);
    }
});

// A query re-asserts each recorded fact in an engine of its own, and a
// reference there is that engine's own fact for the record it names. The path:
// Queries.get -> QueryEngine.feed / #assert. Untyped, the Trace was skipped;
// typed and passed on as recorded, the engine would refuse the reference.
test("a query takes a fact holding a reference, through its own fact for the record it names", { skip: NO_DSC }, async () => {
    const live = EngineTimeline.live(ds, DSC);
    try {
        live.assertFact("Motion", { entity_id: "m2", level: 0.75, lit: true, doc: "[]" });
        const tl = live.tl;
        const qs = new Queries(ds, readProgram(ds, DSC), tl, (src, o) => ds.compile(src, o));
        const qe = await qs.get("Trace t", tl.length);
        assert.equal(qe.skipped, 0, "every recorded fact applied");
        const trace = [...tl.facts.values()].find((f) => f.schema === "Trace") ?? assert.fail("no Trace emitted");
        assert.deepEqual(qe.answers.map((a) => a.bindings[0]), [trace.factId], "the Trace is the answer");
    } finally {
        live.close();
    }
});
