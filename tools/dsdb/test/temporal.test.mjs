// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Time, Date and Duration slots: an artefact declares each as its own
// type and stores it as an Int (RDSC.5.5.8). dsdb writes the declaration back
// with the type, and types a recorded fact's body by it. The fixture
// dsdb_temporal.ds is compiled by the js gate.

import { test, before } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { EngineTimeline } from "../lib/core/engine-timeline.js";
import { declaration, read as readProgram } from "../lib/core/program.js";
import { Decoder } from "../lib/core/trace.js";

const TARGET = process.env.DS_JS_TARGET ?? "native";
const FIXTURES = process.env.DS_JS_FIXTURES;
const NO_ENGINE = FIXTURES ? false : "needs the js gate's engine and compiled fixtures (DS_JS_FIXTURES)";
const S = 1_000_000_000n;

let ds, DSC;
before(async () => {
    if (NO_ENGINE) return;
    const jsBinding = await import(new URL("../../../bindings/js/lib/index.js", import.meta.url).href);
    ds = await jsBinding.open({ target: TARGET });
    DSC = new Uint8Array(readFileSync(join(FIXTURES, "dsdb_temporal.dsc")));
});

test("a .dsc's Time, Date and Duration slots are declared with their own types", { skip: NO_ENGINE }, () => {
    const visit = readProgram(ds, DSC).schemas.get("Visit");
    assert.deepEqual(declaration(visit), [
        "schema Visit scope logical:",
        "    id: Int key",
        "    seen: Time mutable",
        "    due: Date mutable",
        "    span: Duration mutable",
    ]);
});

test("a recorded fact's Time, Date and Duration slots are typed, as their integers", { skip: NO_ENGINE }, () => {
    const live = EngineTimeline.live(ds, DSC);
    const dec = new Decoder(ds, { dsc: DSC });
    try {
        const seen = 1_700_000_000n * S + 1n;
        live.assertFact("Visit", { id: 1n, seen, due: 19_675n, span: 2n * S });
        const recs = dec.feed(live.bytes());
        assert.equal(dec.error, null);
        // The stream's Slot atoms carry the declared kinds ([RFCS.5.1]), none nullable.
        assert.deepEqual(dec.slots.get("Visit"),
                         [["id", "INT", false], ["seen", "TIME", false], ["due", "DATE", false],
                          ["span", "DURATION", false]]);
        const visit = recs.find((r) => r.kind === "FactAssert" && r.body.schema_name === "Visit");
        assert.ok(visit, "the assert was recorded");
        assert.deepEqual(visit.body.slots, { id: 1n, seen, due: 19_675n, span: 2n * S });
    } finally {
        dec.close();
        live.close();
    }
});
