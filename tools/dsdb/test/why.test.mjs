// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Stage 8 (DSDB.md §11): derivation trees, `why` (DSTRACE_INTERACTIVE §4.14,
// §8.8). The section's examples are the reference.
//
// Also §10.13's three checks, which the spec left to be verified by running,
// as stage 0 verified §10.10's: that a firing's matched facts come in pattern
// order, that a second activation re-deriving a logical fact is a justifier
// and no second FactEmit, and that a clone reports the justifiers its source
// does.
//
// The engine half runs the fixture dsdb_why.ds, §4.14's example as a program.

import { test, describe, before } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { EngineTimeline, cloneEngine } from "../lib/core/engine-timeline.js";
import { read as readProgram } from "../lib/core/program.js";
import { Queries } from "../lib/core/query.js";
import { Session } from "../lib/core/session.js";
import { Timeline } from "../lib/core/timeline.js";
import { Decoder } from "../lib/core/trace.js";
import { bindingOf, emitOf, lhsOf } from "../lib/core/why.js";
import { resultLines } from "../lib/text/session.js";

const TARGET = process.env.DS_JS_TARGET ?? "native";
const FIXTURES = process.env.DS_JS_FIXTURES;
const NO_ENGINE = FIXTURES ? false : "needs the js gate's engine and compiled fixtures (DS_JS_FIXTURES)";

describe("a rule's source, as `why` reads it", () => {
    test("each pattern's binding, or none", () => {
        assert.equal(bindingOf("Motion m where m.state == \"on\""), "m");
        assert.equal(bindingOf("Graph where req.root == \"/src\""), null);
        assert.equal(bindingOf("TempReading within 30_s"), null);
        assert.equal(bindingOf("Heat"), null);
        assert.equal(bindingOf("latest DoorOpen d"), "d");
    });

    test("the left-hand side: bindings in match order, `no` patterns as written, a sequence one per step", () => {
        const side = lhsOf(["Sensor s", "no Suppress x where x.room == s.room",
                            "DoorOpen d then Motion m within 30_s where m.room == d.room", "Graph"]);
        assert.deepEqual(side.names, ["s", "d", "m", null]);
        assert.deepEqual(side.negated, ["no Suppress x where x.room == s.room"]);
        assert.equal(side.sequences.length, 1);
    });

    test("the emit of a schema, and the `let` lines its values come through", () => {
        const block = ["rule manual_occupied:", "    Manual h", "->", "    let r = h.room", "    let unused = 1",
                       "    log info \"x\"", "    emit Occupied logical room: r"];
        assert.deepEqual(emitOf(block, "Occupied"), { line: "emit Occupied logical room: r", lets: ["let r = h.room"] });
        assert.equal(emitOf(block, "Occ"), null, "a schema name is matched whole");
        assert.equal(emitOf(["rule r:", "    A a"], "Occupied"), null);
    });
});

// ── on an engine ────────────────────────────────────────────────────────

let jsBinding, ds, DSC;
before(async () => {
    if (NO_ENGINE) return;
    jsBinding = await import(new URL("../../../bindings/js/lib/index.js", import.meta.url).href);
    ds = await jsBinding.open({ target: TARGET });
    DSC = new Uint8Array(readFileSync(join(FIXTURES, "dsdb_why.dsc")));
});

/** The fixture's run: a sensor fires in the kitchen, the switch is flipped
    there too, and the call about the kitchen is answered. */
function record() {
    const live = EngineTimeline.live(ds, DSC);
    live.assertFact("Sensor", { entity_id: "pir.kitchen", room: "kitchen" });
    live.assertFact("Manual", { room: "kitchen" });
    live.assertFact("CheckReply", { corr: "kitchen", ok: true });
    return live;
}

function replay(bytes) {
    const dec = new Decoder(ds, { dsc: DSC });
    const tl = new Timeline(dec.feed(bytes), dec.header);
    assert.equal(dec.error, null);
    dec.close();
    return new Session(tl, { width: 100, queries: new Queries(ds, readProgram(ds, DSC), tl, null), ds,
                             stream: () => bytes, write: () => {} });
}

const lines = async (sh, line) => (await sh.execute(line)).flatMap(resultLines);
const find = (out, re) => out.find((l) => re.test(l)) ?? assert.fail(`no line matching ${re} in\n${out.join("\n")}`);
const one = (tl, schema) => [...tl.facts.values()].find((f) => f.schema === schema)
    ?? assert.fail(`no ${schema} in the timeline`);

describe(`§10.13's three checks, on the ${TARGET} target`, () => {
    test("1: a firing's matched facts come in the rule's positive-pattern order", { skip: NO_ENGINE }, () => {
        const live = record();
        try {
            const tl = live.tl;
            const seen = tl.firings.find((f) => f.rule === "manual_seen");
            // The Sensor was asserted first; `manual_seen` names the Manual first.
            assert.deepEqual(seen.matched.map(BigInt), [one(tl, "Manual").factId, one(tl, "Sensor").factId]);
            const motion = tl.firings.find((f) => f.rule === "motion_in");
            assert.deepEqual(motion.matched.map(BigInt), [one(tl, "Sensor").factId], "a `no` pattern matches no fact");
        } finally {
            live.close();
        }
    });

    // §10.13 expected no second FactEmit. There is one, carrying the live
    // fact's id: the recorder writes the emit though it coalesced. So the
    // timeline takes it as a second emitter of one fact, not a second fact.
    test("2: a second activation deriving the same logical fact is a justifier, and a FactEmit of the same fact",
         { skip: NO_ENGINE }, () => {
        const live = record();
        try {
            const tl = live.tl, occ = one(tl, "Occupied");
            const emits = tl.records.filter((r) => r.kind === "FactEmit" && r.body.schema_name === "Occupied");
            assert.deepEqual(emits.map((r) => r.body.fact_id), [occ.factId, occ.factId]);
            assert.equal(occ.asserted, emits[0].index, "the fact begins at the first");
            assert.deepEqual(occ.reemits, [emits[1].index]);
            assert.equal(tl.population(tl.length).get("Occupied"), 1);
            assert.equal(tl.firings.find((f) => f.rule === "manual_occupied").effects.includes(emits[1].index), true);
            const just = live.eng.justifiers(occ.factId);
            assert.deepEqual(just.map((j) => j.ruleName).sort(), ["manual_occupied", "mark_occupied"]);
            // Both are firings the timeline recorded.
            for (const j of just) assert.ok(tl.firings.some((f) => f.rule === j.ruleName && f.timetag === BigInt(j.timetag)));
        } finally {
            live.close();
        }
    });

    test("3: a clone reports the justifiers its source does", { skip: NO_ENGINE }, () => {
        const live = record();
        const twin = cloneEngine(live.eng);
        try {
            for (const f of live.tl.facts.values())
                assert.deepEqual(twin.justifiers(f.factId), live.eng.justifiers(f.factId), `#${f.factId}`);
        } finally {
            twin.close();
            live.close();
        }
    });
});

describe(`why on the ${TARGET} target`, () => {
    test("a logical fact in replay: every firing supporting it at point, down to the inputs", { skip: NO_ENGINE },
         async (t) => {
        const live = record();
        const sh = replay(live.image()[0]);
        try {
            const tl = sh.state.tl;
            const out = await lines(sh, `why #${one(tl, "Occupied").factId}`);
            t.diagnostic("why Occupied:\n" + out.join("\n"));
            assert.match(out[0], /^ {2}Occupied#\d+ {2}room="kitchen" {3}logical, live at @[0-9a-f]{8} /);
            assert.match(out[1], /^ {2}│ {2}emitted by: emit Occupied logical room: m\.room$/);
            // Both justifiers, in whatever order libds gives them.
            find(out, /^ {2}[├└]─ +\d+ {2}supported by mark_occupied {2}tt 0x[0-9a-f]+ {2}fired @/);
            find(out, /^ {2}[├└]─ +\d+ {2}supported by manual_occupied {2}tt 0x/);
            find(out, /m = Motion#\d+ {2}room="kitchen" {2}state="on" {3}ttl, @/);
            find(out, /emitted by: emit Motion room: s\.room state: "on"/);
            find(out, /s = Sensor#\d+ {2}entity_id="pir\.kitchen" {2}room="kitchen"/);
            find(out, / {3}input @[0-9a-f]{8} /);
            find(out, /no \(Suppress x where x\.room == s\.room\) {3}held at \S+s$/);
            find(out, /h = Manual#\d+ {2}room="kitchen"/);
        } finally {
            sh.close();
            live.close();
        }
    });

    test("a reply leads to its call's firing; a fact reached twice is printed once", { skip: NO_ENGINE }, async (t) => {
        const live = record();
        const sh = replay(live.image()[0]);
        try {
            const tl = sh.state.tl;
            const conf = await lines(sh, `why #${one(tl, "Confirmed").factId}`);
            t.diagnostic("why Confirmed:\n" + conf.join("\n"));
            find(conf, /c = CheckReply#\d+ {2}corr="kitchen"/);
            find(conf, /reply to call 1: svc\.check as "kitchen"/);
            find(conf, /\d+ {2}ask {2}tt 0x/);
            find(conf, /o = Occupied#\d+/);
            const busy = await lines(sh, `why #${one(tl, "Busy").factId}`);
            t.diagnostic("why Busy:\n" + busy.join("\n"));
            const motion = one(tl, "Motion").factId;
            assert.equal(busy.filter((l) => new RegExp(`m = Motion#${motion} `).test(l)).length, 2);
            find(busy, new RegExp(`m = Motion#${motion} {3}\\(see 2\\)$`));
            // depth 1: the firing and its bindings, their causes cut.
            const cut = await lines(sh, `why #${one(tl, "Busy").factId} depth 1`);
            assert.ok(cut.some((l) => l.endsWith("…")), cut.join("\n"));
            assert.ok(!cut.some((l) => /Sensor#/.test(l)), cut.join("\n"));
            // A row expands its node into its own tree.
            const two = await lines(sh, "2");
            assert.match(two[0], new RegExp(`^ {2}Motion#${motion} `));
        } finally {
            sh.close();
            live.close();
        }
    });

    test("an activation: what triggered it, and whether it is the first firing for its facts", { skip: NO_ENGINE },
         async (t) => {
        const live = record();
        const sh = replay(live.image()[0]);
        try {
            await lines(sh, "!:");
            const i = sh.state.firingRows.findIndex((f) => f.rule === "mark_occupied");
            const out = await lines(sh, `why !${i + 1}`);
            t.diagnostic("why !mark_occupied:\n" + out.join("\n"));
            assert.match(out[0], /^ {2}mark_occupied {2}tt 0x[0-9a-f]+ {2}fired @\S+ \S+s {3}\(1st firing for these facts\)$/);
            find(out, /triggered by: input Sensor#\d+ @/);
            find(out, /→ Motion#\d+, emitted by motion_in in this cascade/);
            const seen = sh.state.tl.firings.find((f) => f.rule === "manual_seen");
            const byName = await lines(sh, `why manual_seen ${seen.timetag.toString(16)}`);
            find(byName, /h = Manual#\d+/);
            find(byName, /s = Sensor#\d+/);
            assert.match((await lines(sh, "why manual_seen ffffff"))[0], /no firing of `manual_seen`/);
        } finally {
            sh.close();
            live.close();
        }
    });

    test("live, and in a hypothesis forked from replay", { skip: NO_ENGINE }, async () => {
        const live = record();
        const bytes = live.image()[0];
        const lsh = new Session(live.tl, { queries: new Queries(ds, readProgram(ds, DSC), live.tl, null), live, ds });
        try {
            find(await lines(lsh, `why #${one(live.tl, "Occupied").factId}`), /supported by manual_occupied/);
        } finally {
            lsh.close();
        }
        const sh = replay(bytes);
        try {
            await sh.execute("p");
            assert.match((await lines(sh, "fork")).join("\n"), /%1: a hypothesis forked from %0/);
            // Its firings before the fork are %0's: their matched facts come
            // from %0's provenance pass.
            const out = await lines(sh, `why #${one(sh.state.tl, "Occupied").factId}`);
            find(out, /m = Motion#\d+/);
            assert.ok(!out.some((l) => /not recorded/.test(l)), out.join("\n"));
        } finally {
            sh.close();
        }
    });

    test("a fact that has ended: what ended it, and what ended that, back to the input or the clock",
         { skip: NO_ENGINE }, async (t) => {
        // The switch alone makes the hall occupied, and is turned off. Motion
        // makes the kitchen occupied, and times out with its sensor.
        const live = EngineTimeline.live(ds, DSC);
        const manual = live.assertFact("Manual", { room: "hall" });
        live.retract(manual);
        live.assertFact("Sensor", { entity_id: "pir.kitchen", room: "kitchen" });
        live.advance(61_000_000_000n);
        const sh = replay(live.image()[0]);
        try {
            const tl = sh.state.tl;
            /** @param {string} room */
            const occupied = (room) => [...tl.facts.values()].find((f) => f.schema === "Occupied" && f.slots?.room === room)
                ?? assert.fail(`no Occupied in the ${room}`);
            const motion = one(tl, "Motion");
            const hall = await lines(sh, `why #${occupied("hall").factId}`);
            t.diagnostic("why the hall's Occupied:\n" + hall.join("\n"));
            assert.match(hall[0], /ended @[0-9a-f]{8} \S+s JUSTIFIER_ENDED, not live at point$/);
            find(hall, new RegExp(`^ {2}│ {2}ended: its support manual_occupied {2}tt 0x[0-9a-f]+ lost h = Manual#${manual}$`));
            find(hall, new RegExp(`^ {2}│ {9}→ Manual#${manual} ended @[0-9a-f]{8} \\S+s: retracted by the integrator$`));
            const kitchen = await lines(sh, `why #${occupied("kitchen").factId}`);
            t.diagnostic("why the kitchen's Occupied:\n" + kitchen.join("\n"));
            find(kitchen, new RegExp(`ended: its support mark_occupied {2}tt 0x[0-9a-f]+ lost m = Motion#${motion.factId}$`));
            find(kitchen, new RegExp(`→ Motion#${motion.factId} ended @[0-9a-f]{8} \\S+s TTL_EXPIRED: its ttl ran out$`));
            // Before the end, the same fact is live and says nothing of one.
            sh.state.k = motion.ended;
            assert.ok(!(await lines(sh, `why #${occupied("kitchen").factId}`)).some((l) => /ended:/.test(l)));
        } finally {
            sh.close();
            live.close();
        }
    });

    test("a fact whose support ended when its absence stopped holding: the pattern, and the fact that began it",
         { skip: NO_ENGINE }, async (t) => {
        const dsc = new Uint8Array(readFileSync(join(FIXTURES, "dsdb_why_ended.dsc")));
        const live = EngineTimeline.live(ds, dsc);
        live.assertFact("Occupied", { room: "hall" });
        // Motion elsewhere, a step of its own: the hall stays quiet.
        live.assertFact("Motion", { room: "kitchen" });
        const moved = live.assertFact("Motion", { room: "hall" });
        const bytes = live.image()[0];
        const dec = new Decoder(ds, { dsc });
        const tl = new Timeline(dec.feed(bytes), dec.header);
        dec.close();
        const sh = new Session(tl, { width: 100, queries: new Queries(ds, readProgram(ds, dsc), tl, null), ds,
                                     stream: () => bytes, write: () => {} });
        try {
            const quiet = one(tl, "Quiet");
            const out = await lines(sh, `why #${quiet.factId}`);
            t.diagnostic("why Quiet:\n" + out.join("\n"));
            assert.match(out[0], /ended @[0-9a-f]{8} \S+s JUSTIFIER_ENDED, not live at point$/);
            find(out, new RegExp(`ended: its support quiet {2}tt 0x[0-9a-f]+ lost its absence: `
                                 + `no \\(Motion m where m\\.room == o\\.room\\) began to match Motion#${moved}$`));
            assert.ok(!out.some((l) => /→/.test(l)), "an absence ends the chain");
        } finally {
            sh.close();
            live.close();
        }
    });

    test("refused, and said: no target, a later fact, mid-cascade", { skip: NO_ENGINE }, async () => {
        const live = record();
        const sh = replay(live.image()[0]);
        try {
            const tl = sh.state.tl;
            assert.match((await lines(sh, "why"))[0], /needs a fact or a firing/);
            assert.match((await lines(sh, "why #99999"))[0], /no fact #99999/);
            assert.match((await lines(sh, "why #1 depth 0"))[0], /from 1/);
            const conf = one(tl, "Confirmed");
            sh.state.k = conf.asserted;
            assert.match((await lines(sh, `why #${conf.factId}`))[0], /not asserted until after point/);
            // Mid-cascade, just after the switch's rule re-derived Occupied:
            // no engine to ask, so every firing that derived it up to point.
            const occ = one(tl, "Occupied");
            sh.state.k = occ.reemits[0] + 1;
            assert.equal(tl.isSettled(sh.state.k), false);
            const out = await lines(sh, `why #${occ.factId}`);
            find(out, /^ {2}[├└]─ +\d+ {2}mark_occupied {2}tt 0x/);
            find(out, /^ {2}[├└]─ +\d+ {2}manual_occupied {2}tt 0x/);
            find(out, /mid-cascade, no engine exists to ask for support at point/);
            // Before the re-emit, only the first derivation.
            sh.state.k = occ.reemits[0];
            assert.ok(!(await lines(sh, `why #${occ.factId}`)).some((l) => /manual_occupied/.test(l)));
        } finally {
            sh.close();
            live.close();
        }
    });
});
