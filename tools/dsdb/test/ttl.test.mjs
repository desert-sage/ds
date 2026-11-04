// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// A fact's lifetime in dsdb. No public entry point sets a per-fact TTL, so:
// - a query takes each fact's lifetime from the recording, which records every
//   TTL expiry as a FactWithdraw ([RFCS.7.4]): an answer ends at the fact's
//   recorded withdrawal, never by the query engine's own expiry, whatever TTL
//   the fact had ([LDTL.4.1]);
// - replaying a host assert reads a recorded `ttl_ns` of 0 as the schema's own
//   ([RFCS.6.2]), and refuses any other window that is not the schema's.
// The fixture dsdb_ttl.ds is compiled by the js gate.

import { test, before } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { EngineTimeline, applyInject } from "../lib/core/engine-timeline.js";
import { read as readProgram } from "../lib/core/program.js";
import { Queries } from "../lib/core/query.js";
import { NO_COMPILER, TARGET } from "./compiler.mjs";

const FIXTURES = process.env.DS_JS_FIXTURES;
const NO_ENGINE = FIXTURES ? false : "needs the js gate's engine and compiled fixtures (DS_JS_FIXTURES)";
const NO_DSC = NO_ENGINE || NO_COMPILER;
const S = 1_000_000_000n;

let ds, DSC;
before(async () => {
    if (NO_ENGINE) return;
    const jsBinding = await import(new URL("../../../bindings/js/lib/index.js", import.meta.url).href);
    ds = await jsBinding.open({ target: TARGET });
    DSC = new Uint8Array(readFileSync(join(FIXTURES, "dsdb_ttl.dsc")));
});

/** The three emits at 0 s, then a pump a second to 31 s: each Seen expires
    in its own pump, at 2 s, 10 s and 30 s. */
function record() {
    const live = EngineTimeline.live(ds, DSC);
    for (const n of [1n, 2n, 3n]) live.assertFact("Go", { n });
    for (let i = 0; i < 31; i++) live.advance(S);
    return live;
}

/** @param {import("../lib/core/timeline.js").Timeline} tl @param {bigint} n */
const seen = (tl, n) => [...tl.facts.values()].find((f) => f.schema === "Seen" && f.slots?.n === n)
    ?? assert.fail(`no Seen n=${n}`);

// The path: Queries.get -> QueryEngine.feed / #assert, over a recording whose
// three emits carry 30 s, 2 s and the schema's 10 s. A query engine that
// expired facts itself would end the first answer at 10 s, not 30 s.
test("a query's answer ends at the fact's recorded withdrawal: a retain longer than the schema's, shorter, or its own",
     { skip: NO_DSC }, async () => {
    const live = record();
    try {
        const tl = live.tl;
        const qs = new Queries(ds, readProgram(ds, DSC), tl, (src, o) => ds.compile(src, o));
        const qe = await qs.get("Seen s", tl.length);
        const [long, short, plain] = [1n, 2n, 3n].map((n) => seen(tl, n));
        for (const f of [long, short, plain]) {
            assert.equal(f.cause, "TTL_EXPIRED", `Seen n=${f.slots?.n} left by its TTL`);
            const a = qe.answers.find((x) => x.bindings[0] === f.factId) ?? assert.fail(`no answer for Seen n=${f.slots?.n}`);
            assert.equal(a.end, f.ended, `Seen n=${f.slots?.n}'s answer ends at its recorded withdrawal`);
        }
        // The recording's own order: the 2 s retain first, the schema's 10 s, then 30 s.
        assert.ok(/** @type {number} */ (short.ended) < /** @type {number} */ (plain.ended)
                  && /** @type {number} */ (plain.ended) < /** @type {number} */ (long.ended));
        assert.equal(qe.skipped, 0);
    } finally {
        live.close();
    }
});

// The path: applyInject's FactAssert arm and refuseOwnTtl, which replay and
// hypotheses use.
test("replay: a host assert recorded with ttl_ns 0 takes the schema's TTL; another window is refused with its index",
     { skip: NO_ENGINE }, () => {
    const e = new ds.Engine();
    try {
        e.loadDsc(DSC);
        /** @param {number} index @param {bigint} ttl */
        const rec = (index, ttl) => ({ index, kind: "FactAssert", cls: "inject", seq: null, clockNs: 0n, ownClock: false,
                                       offset: 0, body: { fact_id: 1n, schema_name: "Seen", slots: { n: 7n }, untyped: null,
                                                          fact_bytes: new Uint8Array(), ttl_ns: ttl, clock_ns: 0n,
                                                          rule_name: "", seq: 0n, event_id: 0n } });
        // What it asserted: [the recorded id, the engine's].
        const got = applyInject(e, /** @type {any} */ (rec(4, 0n))) ?? assert.fail("an assert returns what it asserted");
        assert.equal(got.length, 1);
        assert.equal(got[0][0], 1n, "the recorded id");
        assert.ok(e.factById(got[0][1]) !== null, "asserted");
        assert.ok(applyInject(e, /** @type {any} */ (rec(5, 10n * S))) !== null, "the schema's own window replays");
        assert.throws(() => applyInject(e, /** @type {any} */ (rec(6, 4n * S))),
                      /record 6: Seen was recorded with a 4000000000 ns TTL, not its schema's 10000000000 ns/);
    } finally {
        e.close();
    }
});
