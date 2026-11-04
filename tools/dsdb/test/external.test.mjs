// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// dsdb and a recorded ExternalAssert: a host input whose fact holds a
// fact reference, recorded as the FactExternal it is ([RFCS.24.1]). It is an
// inject-class input ([RFCS.17.5]), so every path that applies a recording's
// inputs delivers it, as libds's replayer does ([RFCS.24.2],
// @ds-lang/ds's applyExternalAssert): its facts asserted, its fact_ids bound to
// them, and a delivery that cannot be made as recorded stopping the replay at
// the record.
// The fixture dsdb_external.ds is compiled by the js gate.

import { test, before } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { EngineTimeline, applyInject, freshEngine } from "../lib/core/engine-timeline.js";
import { ProgramEngine } from "../lib/core/program-engine.js";
import { read as readProgram } from "../lib/core/program.js";
import { Queries } from "../lib/core/query.js";
import { Timeline } from "../lib/core/timeline.js";
import { INJECT, INPUT, is } from "../lib/core/trace.js";
import { W, recordLines, seqCol } from "../lib/text/listing.js";
import { NO_COMPILER, TARGET } from "./compiler.mjs";

const FIXTURES = process.env.DS_JS_FIXTURES;
const NO_ENGINE = FIXTURES ? false : "needs the js gate's engine and compiled fixtures (DS_JS_FIXTURES)";
const NO_DSC = NO_ENGINE || NO_COMPILER;

let ds, DSC;
before(async () => {
    if (NO_ENGINE) return;
    const jsBinding = await import(new URL("../../../bindings/js/lib/index.js", import.meta.url).href);
    ds = await jsBinding.open({ target: TARGET });
    DSC = new Uint8Array(readFileSync(join(FIXTURES, "dsdb_external.dsc")));
});

/** The sender's Main 1, referring to its Ref r1, as `svc.fwd`'s argument
    carries it: the FactExternal bytes, the Ref inlined ([RFCS.23.4]). */
function forwarded() {
    const tx = freshEngine(ds, DSC);
    try {
        /** @type {Uint8Array[]} */
        const out = [];
        tx.setCallCallback(() => {});
        tx.addEventListener("action_call", (ev) => {
            const m = /** @type {any} */ (ev).args.m;
            if (m?.external instanceof Uint8Array) out.push(m.external);
        });
        const ref = tx.assert("Ref", { id: "r1", note: "hello" });
        tx.assert("Main", { k: 1n, r: ref });
        tx.assert("Fwd", { k: 1n });
        tx.pump();
        assert.equal(out.length, 1, "the sender forwards one Main");
        return out[0];
    } finally {
        tx.close();
    }
}

/** A receiving tier's own recording: fed the forwarded Main, then pumped, so
    `seen` fires on it. Neither the Main nor its Ref was live there before.
    `ids` are the receiver's ids for the two, which its recording carries. */
function received() {
    const bytes = forwarded();
    const live = EngineTimeline.live(ds, DSC);
    live.eng.assertExternal(bytes);
    live.pump();
    const x = live.tl.records.find((r) => r.kind === "ExternalAssert") ?? assert.fail("no ExternalAssert recorded");
    const main = live.eng.facts({ schema: "Main" })[0] ?? assert.fail("the receiver holds the Main");
    const ref = live.eng.facts({ schema: "Ref" })[0] ?? assert.fail("the receiver holds the Ref");
    return { live, x, ids: { main: main.id, ref: ref.id } };
}

/** The record index of the receiver's `seen` emit. */
const seenAt = (/** @type {Timeline} */ tl) =>
    (tl.records.find((r) => is(r, "FactEmit") && r.body.schema_name === "Seen") ?? assert.fail("no Seen emitted")).index;

// The path: trace.js Decoder's ExternalAssert arm, and the classes INJECT and
// INPUT give a record.
test("an ExternalAssert is read: its FactExternal, its fact_ids, ttl_ns, clock, seq and body bytes, as an inject-class input",
     { skip: NO_ENGINE }, () => {
    const { live, x, ids } = received();
    try {
        assert.ok(INJECT.has("ExternalAssert") && INPUT.has("ExternalAssert"));
        assert.equal(x.cls, "inject");
        const b = /** @type {any} */ (x.body);
        assert.equal(b.fact.schema, "Main", "the received fact's FactExternal");
        // [RFCS.24.3]: the inlined Ref first, then the received Main.
        assert.deepEqual(b.fact_ids, [ids.ref, ids.main]);
        assert.equal(b.ttl_ns, 0n, "the schema's own window");
        assert.equal(typeof b.clock_ns, "bigint");
        assert.equal(x.seq, b.seq);
        assert.ok(x.seq !== null && x.seq > 0n, "it carries the first of its events' seq");
        assert.ok(b.bytes instanceof Uint8Array && b.bytes.length > 0, "the body as framed, which libds applies");
        assert.ok(seenAt(live.tl) > x.index, "seen fired on the received Main, after the input");
        // The listing (text/listing.js) names the received schema and the facts.
        const [seq, lines] = recordLines(x);
        assert.equal(seq, x.seq);
        // ttl_ns and clock_ns are shown when set, as every other body's fields
        // are; the receiver's mock clock is at 0.
        assert.equal(b.clock_ns, 0n);
        assert.deepEqual(lines, [`${seqCol(x.seq)}  ${"ExternalAssert".padEnd(W)}  Main  fact_ids=[${ids.ref}, ${ids.main}]`]);
    } finally {
        live.close();
    }
});

// The path: applyInject's ExternalAssert arm, which ProgramEngine (replay),
// hypotheses and `%0` under a new program all apply inputs through.
test("applyInject delivers an ExternalAssert: the Main and its inlined Ref, each recorded id bound to the engine's",
     { skip: NO_ENGINE }, () => {
    const { live, x, ids } = received();
    try {
        const e = freshEngine(ds, DSC);
        try {
            const got = applyInject(e, x) ?? assert.fail("an input that asserts returns what it asserted");
            assert.deepEqual(got.map(([rec]) => rec), [ids.ref, ids.main], "in [RFCS.24.3]'s order");
            const [[, ref], [, main]] = got;
            assert.equal(e.factById(main)?.read().schema, "Main");
            assert.equal(e.factById(ref)?.read().schema, "Ref");
            assert.equal(e.factCount, 2, "the two facts, and no pump: seen has not fired");
        } finally {
            e.close();
        }
    } finally {
        live.close();
    }
});

// The path: ProgramEngine.to -> applyInject's ExternalAssert arm, and the
// Timeline's ExternalAssert arm. A replay that skipped the record would hold
// no Main and emit no Seen, and the self-check would mark it unreliable there.
test("replay holds the received fact and seen's FactEmit at the recorded record indexes",
     { skip: NO_ENGINE }, () => {
    const { live, x, ids } = received();
    try {
        const tl = live.tl;
        const pe = new ProgramEngine(ds, DSC, tl);
        try {
            pe.to(tl.length);
            assert.equal(pe.unreliable, null, "every derived record replays as recorded");
            const own = pe.run.tl.records;
            assert.equal(own[x.index]?.kind, "ExternalAssert", "the input at its recorded index");
            const at = seenAt(tl);
            const emit = own[at];
            assert.ok(emit !== undefined && is(emit, "FactEmit") && emit.body.schema_name === "Seen",
                      "seen's emit at its recorded index");
            assert.equal(pe.run.eng.factById(ids.main)?.read().schema, "Main", "the received Main is live in the replay");
        } finally {
            pe.close();
        }
        // The recording's timeline knows the delivered facts: live from the
        // input on, the inlined Ref first and the received Main last.
        for (const [id, schema] of [[ids.ref, "Ref"], [ids.main, "Main"]]) {
            const f = tl.facts.get(id) ?? assert.fail(`the timeline has no fact ${id}`);
            assert.equal(f.schema, schema);
            assert.equal(f.asserted, x.index);
            assert.ok(f.liveAt(tl.length));
        }
    } finally {
        live.close();
    }
});

// The path: applyInject's ExternalAssert arm, refused by libds with
// DS_ERR_FS_DIVERGENCE ([RFCS.24.2]). The record is the recorded one with one
// more `fact_ids` element appended to its body (field 2, a varint).
test("an ExternalAssert whose fact_ids list one more fact than the delivery asserts stops the replay, naming the record",
     { skip: NO_ENGINE }, () => {
    const { live, x } = received();
    try {
        const b = /** @type {any} */ (x.body);
        const bytes = new Uint8Array([...b.bytes, (2 << 3) | 0, 99]);
        const bad = /** @type {typeof x} */ ({ ...x, body: { ...b, bytes, fact_ids: [...b.fact_ids, 99n] } });
        const said = new RegExp(`^record ${x.index}: the ExternalAssert does not replay as recorded \\(\\[RFCS\\.24\\.2\\]\\)`);
        const want = (/** @type {unknown} */ err) => err instanceof Error && said.test(err.message);
        const e = freshEngine(ds, DSC);
        try {
            assert.throws(() => applyInject(e, bad), want);
        } finally {
            e.close();
        }
        const records = live.tl.records.map((r) => (r.index === x.index ? bad : r));
        const pe = new ProgramEngine(ds, DSC, new Timeline(records, live.tl.header, live.tl.services));
        try {
            assert.throws(() => pe.to(records.length), want);
        } finally {
            pe.close();
        }
    } finally {
        live.close();
    }
});

// The path: ProgramEngine.to -> applyInject's FactRetract arm, through the ids
// the ExternalAssert bound; and the Timeline's end of a delivered fact.
test("a retract of the received fact by its recorded id, after the ExternalAssert, finds the fact on replay",
     { skip: NO_ENGINE }, () => {
    const { live, x, ids } = received();
    try {
        assert.ok(live.retract(ids.main), "the receiver retracts the Main it received");
        const tl = live.tl;
        const r = tl.records.find((y) => is(y, "FactRetract") && y.body.fact_id === ids.main)
            ?? assert.fail("no FactRetract of the Main recorded");
        assert.ok(r.index > x.index);
        const f = tl.facts.get(ids.main) ?? assert.fail("the timeline has no Main");
        assert.equal(f.ended, r.index, "the timeline ends the delivered Main at its retract");
        assert.ok(!tl.unmatched.includes(r.index));
        const pe = new ProgramEngine(ds, DSC, tl);
        try {
            pe.to(tl.length);
            assert.equal(pe.unreliable, null, "the retract and what it withdraws replay as recorded");
            assert.equal(pe.run.eng.factById(ids.main), null, "the retract found the Main");
            assert.equal(pe.run.eng.factById(ids.ref)?.read().schema, "Ref", "and only the Main");
        } finally {
            pe.close();
        }
    } finally {
        live.close();
    }
});

// The path: QueryEngine.feed's ExternalAssert arm. A query engine that passed
// over the record would answer `Main m` with nothing.
test("a query over a recording holding an ExternalAssert answers with the received fact",
     { skip: NO_DSC }, async () => {
    const { live, x, ids } = received();
    try {
        const tl = live.tl;
        const qs = new Queries(ds, readProgram(ds, DSC), tl, (src, o) => ds.compile(src, o));
        try {
            const qe = await qs.get("Main m", tl.length);
            assert.equal(qe.answers.length, 1, "one Main");
            const [a] = qe.answers;
            assert.deepEqual(a.bindings, [ids.main], "bound by its recorded id");
            assert.ok(a.liveAt(tl.length));
            assert.ok(a.liveAt(x.index + 1) && !a.liveAt(x.index), "from the input on");
            assert.equal(qe.skipped, 0);
        } finally {
            qs.close();
        }
    } finally {
        live.close();
    }
});
