// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// A nullable slot's fact-body field has presence ([RFCS.6.3]): written
// for every value, zero included, and absent for null. dsdb types a recorded
// body by its schema in the program it was recorded with, so a recorded
// null must read back, and replay, as null and not as the zero. The stream's
// own announcement says which slots are nullable too. The fixture dsdb_null.ds
// is compiled by the js gate.

import { test, before } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { EngineTimeline } from "../lib/core/engine-timeline.js";
import { Decoder } from "../lib/core/trace.js";
import { recordLines } from "../lib/text/listing.js";

const TARGET = process.env.DS_JS_TARGET ?? "native";
const FIXTURES = process.env.DS_JS_FIXTURES;
const NO_ENGINE = FIXTURES ? false : "needs the js gate's engine and compiled fixtures (DS_JS_FIXTURES)";

let ds, DSC;
before(async () => {
    if (NO_ENGINE) return;
    const jsBinding = await import(new URL("../../../bindings/js/lib/index.js", import.meta.url).href);
    ds = await jsBinding.open({ target: TARGET });
    DSC = new Uint8Array(readFileSync(join(FIXTURES, "dsdb_null.dsc")));
});

/** Record libds's two vectors, a null beside an empty string and a zero
    beside a null, and decode the recording as dsdb reads a trace. */
function recorded(fn) {
    const live = EngineTimeline.live(ds, DSC);
    const dec = new Decoder(ds, { dsc: DSC });
    try {
        live.assertFact("Maybe", { id: 3n, s: "" });        // x omitted: null
        live.assertFact("Maybe", { id: 4n, x: 0 });         // s omitted: null
        const recs = dec.feed(live.bytes());
        assert.equal(dec.error, null);
        fn(dec, recs.filter((r) => r.kind === "FactAssert").map((r) => r.body.slots));
    } finally {
        dec.close();
        live.close();
    }
}

test("the stream's slot announcement says which slots are nullable", { skip: NO_ENGINE }, () => {
    recorded((dec) => {
        assert.deepEqual(dec.slots.get("Maybe"), [["id", "INT", false], ["x", "FLOAT", true], ["s", "STRING", true]]);
    });
});

test("a recorded null reads back as null, and a recorded zero or empty string as itself", { skip: NO_ENGINE }, () => {
    recorded((_dec, facts) => {
        assert.deepEqual(facts, [{ id: 3n, x: null, s: "" }, { id: 4n, x: 0, s: null }]);
    });
});

// Read with no program, a body is typed by the stream's own
// announcement, which says which slots are nullable: a null still reads null.
test("read with no program, a recorded null reads back as null, and the listing shows it", { skip: NO_ENGINE }, () => {
    const live = EngineTimeline.live(ds, DSC);
    const dec = new Decoder(ds);
    try {
        live.assertFact("Maybe", { id: 3n, s: "" });
        live.assertFact("Maybe", { id: 4n, x: 0 });
        const fas = dec.feed(live.bytes()).filter((r) => r.kind === "FactAssert");
        assert.deepEqual(fas.map((r) => r.body.slots), [{ id: 3n, x: null, s: "" }, { id: 4n, x: 0, s: null }]);
        const [, lines] = recordLines(fas[0]);
        assert.match(lines[0], /FactAssert {10}Maybe#\d+ {2}id=3  x=None  s=''$/);
    } finally {
        dec.close();
        live.close();
    }
});
