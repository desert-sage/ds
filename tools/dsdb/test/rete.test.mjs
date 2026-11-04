// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Stage 7 (DSDB.md §11): the Rete network at point, `rete`
// (DSTRACE_INTERACTIVE §4.13, §8.7). The section's example is the reference,
// and these tests hold dsdb to it.
//
// The first half needs no engine: the source's patterns, the walk from a
// network to its chains, and the text. The second runs the fixture
// dsdb_rete.ds, the section's example as a program, recorded by an engine,
// then read back in replay, live and in a hypothesis.

import { test, describe, before } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { EngineTimeline } from "../lib/core/engine-timeline.js";
import { read as readProgram } from "../lib/core/program.js";
import { Queries } from "../lib/core/query.js";
import { CONTENTS, USAGE, dot, parseArgs, patterns, reading, ruleBlock, ruleRows, schemaRows, splitPattern,
         summary } from "../lib/core/rete.js";
import { Session } from "../lib/core/session.js";
import { Timeline } from "../lib/core/timeline.js";
import { Decoder } from "../lib/core/trace.js";
import { resultLines } from "../lib/text/session.js";
import { reteLines } from "../lib/text/rete.js";

const TARGET = process.env.DS_JS_TARGET ?? "native";
const FIXTURES = process.env.DS_JS_FIXTURES;
const NO_ENGINE = FIXTURES ? false : "needs the js gate's engine and compiled fixtures (DS_JS_FIXTURES)";

// ── the source's patterns ───────────────────────────────────────────────

describe("a rule's patterns, from its source (§8.7 step 3)", () => {
    test("one per line, a docstring, comments and blank lines left out", () => {
        const block = ["rule r:", '    "A docstring."', "", "    # a comment", '    A a where a.x == "#1"   # trailing',
                       "    no B b where b.y == a.y"];
        assert.deepEqual(patterns(block), ['A a where a.x == "#1"', "no B b where b.y == a.y"]);
    });

    test("a bracket left open continues the pattern; a triple-quoted docstring is skipped", () => {
        const block = ["rule r:", '    """', "    Two lines", "    of docstring.", '    """', "    Heat h",
                       "    Thermometer t where (", "        t.entity_id == h.entity_id",
                       "        and t.temperature > 90.0    # a comment", "    )"];
        assert.deepEqual(patterns(block),
                         ["Heat h", "Thermometer t where (t.entity_id == h.entity_id and t.temperature > 90.0)"]);
    });

    test("split at the top-level `where`, not one in a string or a bracket", () => {
        assert.deepEqual(splitPattern('DoorEvent d where d.action == "opened"'), ["DoorEvent d", 'd.action == "opened"']);
        assert.deepEqual(splitPattern('A a where a.s == " where "'), ["A a", 'a.s == " where "']);
        assert.deepEqual(splitPattern("no (Ack a where a.corr == 1)"), ["no (Ack a where a.corr == 1)", ""]);
        assert.deepEqual(splitPattern("Heat"), ["Heat", ""]);
    });

    test("a rule's block: at the compiler's location where the text agrees, else by its header", () => {
        const src = [["main.ds", "schema A:\n    x: Int\n\nrule r:\n    A a\n->\n    log info \"x\"\n"]];
        assert.deepEqual(ruleBlock(src, "r", { srcFile: "main.ds", srcLine: 4 }), ["rule r:", "    A a"]);
        assert.deepEqual(ruleBlock(src, "r", { srcFile: "main.ds", srcLine: 1 }), ["rule r:", "    A a"]);
        assert.deepEqual(ruleBlock(src, "r", null), ["rule r:", "    A a"]);
        assert.equal(ruleBlock(src, "nosuch", null), null);
        assert.equal(ruleBlock([], "r", null), null);
    });
});

// ── a network, walked ───────────────────────────────────────────────────

// §4.13's example as libds would report it: entry_detected is DoorEvent,
// Motion, no Ack; heat_warning and heat_log share their one alpha node.
const node = (id, kind, label, filter, occupancy, isNegative = false) => ({ id, kind, label, filter, occupancy, isNegative });
const EXAMPLE = {
    nodes: [node("alfa_0", "alpha", "DoorEvent", 'action == "opened"', 2),
            node("alfa_1", "alpha", "Motion", "", 5),
            node("alfa_2", "alpha", "Ack", "", 0),
            node("alfa_3", "alpha", "Thermometer", "temperature > 90", 3),
            node("beta_0", "beta", "join", "", 1),
            node("beta_1", "beta", "join", "join", 1),
            node("beta_2", "beta", "join", "join", 1, true),
            node("beta_3", "beta", "join", "", 1),
            node("beta_4", "beta", "join", "", 1),
            node("term_0", "terminal", "entry_detected", "", 1),
            node("term_1", "terminal", "heat_warning", "", 0),
            node("term_2", "terminal", "heat_log", "", 0)],
    edges: [["alfa_0", "beta_0"], ["alfa_1", "beta_1"], ["alfa_2", "beta_2"], ["alfa_3", "beta_3"], ["alfa_3", "beta_4"],
            ["beta_0", "beta_1"], ["beta_1", "beta_2"], ["beta_2", "term_0"], ["beta_3", "term_1"], ["beta_4", "term_2"]]
        .map(([fromId, toId]) => ({ fromId, toId })),
};
const occupied = (occ) => ({ ...EXAMPLE, nodes: EXAMPLE.nodes.map((n) => (n.id in occ ? { ...n, occupancy: occ[n.id] } : n)) });
const SOURCE = new Map([
    ["entry_detected", ['DoorEvent d where d.action == "opened"', "Motion m where m.entity_id == d.entity_id",
                        "no Ack a where a.corr == d.corr"]],
    ["heat_warning", ["Thermometer t where t.temperature > 90.0"]],
    ["heat_log", ["Thermometer t where t.temperature > 90.0"]],
]);
const ctx = (over = {}) => ({ name: (r) => r, source: (r) => SOURCE.get(r) ?? null,
                              fired: new Map([["entry_detected", 4], ["heat_warning", 2]]),
                              refracted: new Map([["heat_warning", 2]]), filter: null, ...over });
const fakeTl = { clockAt: (k) => (k ? 12_000_000_000n : 0n), name: () => [0x1aban, 0] };

describe("the network, walked into chains (§8.7 steps 1-2, 4-5)", () => {
    test("each terminal's chain, left to right, and who shares an alpha", () => {
        const r = reading(EXAMPLE);
        assert.deepEqual(r.chains.map((c) => [c.rule, c.betas]),
                         [["entry_detected", ["beta_0", "beta_1", "beta_2"]], ["heat_warning", ["beta_3"]],
                          ["heat_log", ["beta_4"]]]);
        assert.deepEqual(r.users.get("alfa_3"), ["heat_warning", "heat_log"]);
        // A positive first pattern is its alpha; every other beta is a join.
        assert.deepEqual(summary(r), { alpha: 4, join: 2, rules: 3, facts: 10, tokens: 2 });
    });

    test("rows: a pattern's own text, counts, the right alpha, and the change since before", () => {
        const now = reading(EXAMPLE), prev = reading(occupied({ beta_1: 0, alfa_3: 4 }));
        const [entry, warn] = ruleRows(now, prev, ctx());
        assert.deepEqual(entry.rows.map((x) => [x.n, x.kind, x.head, x.text, x.count, x.delta]),
                         [[1, "alpha", "DoorEvent d", 'd.action == "opened"', 2, 0],
                          [2, "join", "Motion m", "m.entity_id == d.entity_id", 1, 1],
                          [3, "not", "no Ack a", "a.corr == d.corr", 1, 0],
                          [4, "terminal", "entry_detected", "", 1, 0]]);
        assert.deepEqual(entry.rows[1].right, { id: "alfa_1", schema: "Motion", count: 5, delta: 0 });
        assert.deepEqual([entry.fired, entry.pending, entry.refracted], [4, 1, 0]);
        assert.deepEqual(warn.rows[0].also, ["heat_log"]);
        assert.equal(warn.rows[0].delta, -1);
        assert.deepEqual([warn.fired, warn.pending, warn.refracted], [2, 0, 2]);
    });

    test("a rule whose patterns do not line up shows its alpha tests, and says so", () => {
        const [entry] = ruleRows(reading(EXAMPLE), null,
                                 ctx({ source: (r) => (r === "entry_detected" ? ["DoorEvent d"] : null) }));
        assert.deepEqual(entry.unaligned, { source: 1, network: 3 });
        assert.deepEqual(entry.rows.slice(0, 3).map((x) => [x.head, x.text, x.delta]),
                         [["DoorEvent", 'action == "opened"', null], ["Motion", "", null], ["no Ack", "", null]]);
    });

    test("a filter keeps the rules it names; row numbers run on across rules", () => {
        const rules = ruleRows(reading(EXAMPLE), null, ctx({ filter: /^heat/ }));
        assert.deepEqual(rules.map((r) => r.name), ["heat_warning", "heat_log"]);
        assert.deepEqual(rules.flatMap((r) => r.rows.map((x) => x.n)), [1, 2, 3, 4]);
    });

    test("§4.13's example, as dsdb prints it", (t) => {
        const now = reading(EXAMPLE), prev = reading(occupied({ beta_1: 0, alfa_3: 4 }));
        const lines = reteLines({ tl: fakeTl, k: 1, summary: summary(now), changed: false, noSource: false,
                                  filtered: false, rules: ruleRows(now, prev, ctx()) });
        t.diagnostic("§4.13's example:\n" + lines.join("\n"));
        assert.equal(lines[0], "  rete at @00001aba 12.0s · 4 alpha · 2 join · 3 rules · 10 facts held · 2 tokens");
        assert.deepEqual(lines.map((l, i) => [i, l]).filter(([, l]) => l === "").map(([i]) => i), [1, 7, 11]);
        const expect = [
            /^ {2}rule entry_detected +fired 4 · pending 1$/,
            /^ {5}1 {2}α DoorEvent d +d\.action == "opened" +2 facts$/,
            /^ {5}2 {2}∧ Motion m +m\.entity_id == d\.entity_id +1 token +\+1 {2}◀ α Motion {2}5 facts$/,
            /^ {5}3 {2}¬ no Ack a +a\.corr == d\.corr +1 token +◀ α Ack {5}0 facts$/,
            /^ {5}4 {2}▶ entry_detected +1 activation$/,
            /^ {2}rule heat_warning +fired 2 · refracted 2$/,
            /^ {5}5 {2}α Thermometer t +t\.temperature > 90\.0 {2}\(also heat_log\) +3 facts +-1$/,
            /^ {5}6 {2}▶ heat_warning +0 activations$/,
            /^ {2}rule heat_log +fired 0$/,
            /^ {5}7 {2}α Thermometer t +t\.temperature > 90\.0 {2}\(also heat_warning\) +3 facts +-1$/,
            /^ {5}8 {2}▶ heat_log +0 activations$/,
        ];
        assert.deepEqual(lines.filter((l) => l).slice(1).map((l, i) => expect[i].test(l) || l), expect.map(() => true));
        // One column for each: the counts, the changes, and the rule's own
        // counts ending where the rows' do.
        const rows = lines.filter((l) => /^ {4,}\d/.test(l));
        assert.equal(new Set(rows.map((l) => l.search(/\d+ (facts?|tokens?|activations?)/))).size, 1);
        assert.equal(new Set(rows.filter((l) => /[+-]1/.test(l)).map((l) => l.search(/ [+-]1/))).size, 1);
        const ends = lines.filter((l) => l.startsWith("  rule ")).map((l) => l.length);
        assert.equal(new Set(ends).size, 1);
    });

    test("schemas, alpha-first, with the rules taking each", () => {
        const now = reading(EXAMPLE);
        const sc = schemaRows(now, null, (r) => r);
        assert.deepEqual(sc.map((s) => s.schema), ["Ack", "DoorEvent", "Motion", "Thermometer"]);
        assert.deepEqual(sc[3].alphas[0].rules, ["heat_warning", "heat_log"]);
    });

    test("dot: every node and edge, the right input dashed", () => {
        const text = dot(reading(EXAMPLE), (r) => r, "@00001aba");
        assert.ok(text.startsWith("digraph rete {\n"));
        assert.match(text, /"alfa_0" \[shape=box, label="α DoorEvent\\naction == \\"opened\\"\\n2 facts"\];/);
        assert.match(text, /"beta_2" \[shape=ellipse, label="¬\\n1 token"\];/);
        assert.match(text, /"alfa_1" -> "beta_1" \[style=dashed\];/);
        assert.match(text, /"beta_2" -> "term_0";/);
        assert.equal(text.match(/ -> /g).length, EXAMPLE.edges.length);
    });

    test("the command's arguments", () => {
        assert.deepEqual(parseArgs(""), { mode: "rules", file: null, pos: null, filter: null });
        assert.deepEqual(parseArgs("@1aba-").pos, { seq: 0x1aban, minus: 1 });
        assert.equal(String(parseArgs("@1aba /heat_(warn|log)/").filter), "/heat_(warn|log)/");
        assert.equal(parseArgs("schemas @10").mode, "schemas");
        assert.deepEqual(parseArgs("dot out.dot"), { mode: "dot", file: "out.dot", pos: null, filter: null });
        assert.equal(parseArgs("dot").error, USAGE);
        assert.equal(parseArgs("schemas /x/").error, USAGE);
        assert.equal(parseArgs("nonsense").error, USAGE);
        assert.match(parseArgs("@xyz").error, /not a position/);
        assert.match(parseArgs("/(/").error, /^\/\(\/: /);
        assert.match(parseArgs("%1").error, /fg %N/);
    });
});

// ── on an engine ────────────────────────────────────────────────────────

let jsBinding, ds, DSC;
before(async () => {
    if (NO_ENGINE) return;
    jsBinding = await import(new URL("../../../bindings/js/lib/index.js", import.meta.url).href);
    ds = await jsBinding.open({ target: TARGET });
    DSC = new Uint8Array(readFileSync(join(FIXTURES, "dsdb_rete.dsc")));
});

/** The fixture's run: a hot reading, a door, motion, the reading cooling,
    and the entry acknowledged. `[recording, live timeline]`. */
function record() {
    const live = EngineTimeline.live(ds, DSC);
    live.assertFact("Thermometer", { entity_id: "kitchen", temperature: 95.0 });
    live.assertFact("DoorEvent", { entity_id: "front", action: "opened" });
    live.assertFact("Motion", { entity_id: "front" });
    live.assertFact("Thermometer", { entity_id: "kitchen", temperature: 85.0 });
    live.assertFact("Ack", { corr: "front" });
    return live;
}

function replay(bytes, written = new Map()) {
    const dec = new Decoder(ds, { dsc: DSC });
    const tl = new Timeline(dec.feed(bytes), dec.header);
    assert.equal(dec.error, null);
    dec.close();
    return new Session(tl, { width: 100, queries: new Queries(ds, readProgram(ds, DSC), tl, null), ds,
                             stream: () => bytes, write: (p, b) => written.set(p, b) });
}

const lines = async (sh, line) => (await sh.execute(line)).flatMap(resultLines);
const row = (out, re) => out.find((l) => re.test(l)) ?? assert.fail(`no line matching ${re} in\n${out.join("\n")}`);
const pointOf = (tl, k) => {
    const [n, m] = tl.name(k);
    return `@${n.toString(16)}${"-".repeat(m)}`;
};

describe(`rete on the ${TARGET} target`, () => {
    test("in replay, at the end: every rule's chain, what it holds, and the last cascade's changes", { skip: NO_ENGINE },
         async (t) => {
        const live = record();
        const sh = replay(live.image()[0]);
        try {
            const out = await lines(sh, "rete");
            t.diagnostic("rete, at the end of the fixture's run:\n" + out.join("\n"));
            assert.match(out[0], /^ {2}rete at @[0-9a-f]{8} \S+s · \d+ alpha · \d+ join · 4 rules · \d+ facts? held · \d+ tokens?$/);
            assert.match(row(out, /rule entry_detected/), /fired 1$/);
            assert.match(row(out, /α DoorEvent d/), /d\.action == "opened" +1 fact$/);
            assert.match(row(out, /∧ Motion m/), /m\.entity_id == d\.entity_id +1 token +◀ α Motion +1 fact$/);
            // The Ack arrived in the last cascade: its alpha gained a fact,
            // and the entry's activation is gone.
            assert.match(row(out, /¬ no Ack a/), /a\.corr == d\.entity_id +1 token +◀ α Ack +1 fact +\+1$/);
            assert.match(row(out, /▶ entry_detected/), /0 activations/);
            // Pattern text over several lines, and a docstring skipped.
            assert.match(row(out, /∧ Thermometer t/), /\(t\.entity_id == h\.entity_id and t\.temperature > 90\.0\)/);
            assert.ok(!out.some((l) => /patterns not lined up/.test(l)), out.join("\n"));
            // A row names a node, which cannot be opened.
            assert.deepEqual(await lines(sh, "1"), [`  ${CONTENTS}`]);
        } finally {
            sh.close();
            live.close();
        }
    });

    test("rete @N, without moving point; a filter; schemas; dot", { skip: NO_ENGINE }, async (t) => {
        const live = record();
        const written = new Map();
        const sh = replay(live.image()[0], written);
        try {
            const tl = sh.state.tl, end = sh.state.k;
            // Just after the first input's cascade: both heat rules fired once,
            // and the Thermometer alpha holds the reading, one more than before.
            const k1 = tl.settled.find((k) => tl.firingsIn(0, k).length > 0);
            const out = await lines(sh, `rete ${pointOf(tl, k1)}`);
            assert.equal(sh.state.k, end, "point does not move");
            assert.match(row(out, /rule heat_warning/), /fired 1/);
            assert.match(row(out, /rule heat_log/), /fired 1/);
            assert.match(row(out, /α Thermometer t +t\.temperature > 90\.0/), /1 fact +\+1$/);
            const heat = await lines(sh, "rete /^heat/");
            assert.match(heat[0], / · 3 shown$/);
            assert.ok(!heat.some((l) => l.includes("rule entry_detected")));
            const schemas = await lines(sh, "rete schemas");
            t.diagnostic("rete schemas:\n" + schemas.join("\n"));
            // Entry has no alpha node: no rule reads it.
            assert.match(schemas[0], /^ {2}rete schemas at @[0-9a-f]{8} \S+s · 5 schemas · /);
            assert.match(row(schemas, /α .*DoorEvent|action == "opened"/), /entry_detected$/);
            const said = await lines(sh, "rete dot net.dot");
            assert.match(said[0], /^ {2}wrote net\.dot: the network at @[0-9a-f]{8} \S+s as Graphviz, \d+ nodes and \d+ edges$/);
            const text = new TextDecoder().decode(written.get("net.dot"));
            assert.ok(text.startsWith("digraph rete {\n") && text.includes("▶ entry_detected"), text);
        } finally {
            sh.close();
            live.close();
        }
    });

    test("refused: mid-cascade, and another timeline's network", { skip: NO_ENGINE }, async () => {
        const live = record();
        const sh = replay(live.image()[0]);
        try {
            const tl = sh.state.tl;
            sh.state.k = [...Array(tl.length).keys()].find((k) => k > 0 && !tl.isSettled(k));
            assert.match((await lines(sh, "rete"))[0], /^ {2}`rete` mid-cascade is refused/);
            assert.match((await lines(sh, "rete %1"))[0], /fg %N/);
        } finally {
            sh.close();
            live.close();
        }
    });

    test("whynot: where each rule's match stops, and why (DSDB_MCP.md §10.6)", { skip: NO_ENGINE }, async (t) => {
        const live = record();
        const sh = replay(live.image()[0]);
        try {
            const tl = sh.state.tl, end = sh.state.k;
            const first = (schema) => tl.settled.find((k) => tl.liveFacts(k).some((f) => f.schema === schema));
            // After the door opened, before any motion: a token reaches the
            // Motion join, and nothing gets through it.
            sh.state.k = first("DoorEvent");
            let out = await lines(sh, "whynot entry_detected");
            t.diagnostic("whynot entry_detected, after the door:\n" + out.join("\n"));
            assert.match(out[0], /^ {2}whynot entry_detected at @[0-9a-f]{8} \S+s: no complete match; it stops at 2$/);
            assert.match(row(out, /α DoorEvent d/), /1 fact +#\d+$/);
            assert.match(row(out, /∧ Motion m/), /1 token +◀ Motion none$/);
            row(out, /^ {2}stops at 2: no Motion is live at point$/);
            // With the motion, and no Ack to block it: one complete match, fired.
            sh.state.k = first("Motion");
            out = await lines(sh, "whynot entry_detected");
            assert.match(out[0], /: 1 complete match$/);
            row(out, /^ {2}it fired 1 time up to point, the last at @[0-9a-f]{8}/);
            row(out, /refraction/);
            // At the end an Ack could block it; which it blocks needs the
            // node contents.
            sh.state.k = end;
            out = await lines(sh, "whynot entry_detected");
            t.diagnostic("whynot entry_detected, at the end:\n" + out.join("\n"));
            assert.match(out[0], /: it matches up to its last pattern, 3$/);
            row(out, /^ {2}3: 1 token arrives, and 1 Ack could block it: #\d+$/);
            row(out, /whether one blocks needs libds's node contents\)$/);
            out = await lines(sh, "whynot heat_warning");
            t.diagnostic("whynot heat_warning, at the end:\n" + out.join("\n"));
            row(out, /^ {2}stops at 1: no Thermometer passes its test: #\d+ \(alpha filter failed: /);
            row(await lines(sh, "whynot heat_seen"), /^ {2}stops at 1: no Heat is live at point$/);
            // Refusals.
            assert.match((await lines(sh, "whynot nope"))[0], /no rule `nope`/);
            assert.match((await lines(sh, "whynot"))[0], /^ {2}whynot RULE/);
            sh.state.k = [...Array(tl.length).keys()].find((k) => k > 0 && !tl.isSettled(k));
            assert.match((await lines(sh, "whynot entry_detected"))[0], /^ {2}`whynot` mid-cascade is refused/);
        } finally {
            sh.close();
            live.close();
        }
    });

    test("whynot: tokens and candidates that do not join", { skip: NO_ENGINE }, async () => {
        const live = EngineTimeline.live(ds, DSC);
        live.assertFact("DoorEvent", { entity_id: "front", action: "opened" });
        live.assertFact("Motion", { entity_id: "back" });
        const sh = replay(live.image()[0]);
        try {
            const out = await lines(sh, "whynot entry_detected");
            assert.match(row(out, /∧ Motion m/), /1 token +◀ Motion #\d+$/);
            row(out, /^ {2}stops at 2: 1 token arrives and 1 Motion passes its test, and no pair joins$/);
            row(out, /which join test rejected which pair needs libds's node contents\)$/);
        } finally {
            sh.close();
            live.close();
        }
    });

    test("live at the end, and in a hypothesis: the engine that runs there", { skip: NO_ENGINE }, async () => {
        const live = record();
        const sh = new Session(live.tl, { queries: new Queries(ds, readProgram(ds, DSC), live.tl, null), live, ds });
        try {
            assert.match(row(await lines(sh, "rete"), /¬ no Ack a/), /1 token +◀ α Ack +1 fact/);
            await sh.execute("p");
            assert.match((await lines(sh, "fork")).join("\n"), /%1: a hypothesis forked from %0/);
            // The fork is before the Ack: nothing blocks the entry.
            assert.match(row(await lines(sh, "rete"), /¬ no Ack a/), /1 token +◀ α Ack +0 facts/);
        } finally {
            sh.close();
        }
    });
});
