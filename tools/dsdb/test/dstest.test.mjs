// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// `ds test`, the `.dstest` runner on libds (core/dstest.js). The
// reading of the atoms is held first with atoms made here, so what fails a
// case is pinned whatever the compiler emits today. Then programs with tests,
// compiled by the lane's compiler for its target (compiler.mjs) and run on the
// engine, and the command line.

import { test, describe, before } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { CAP_NAMES, decodeCases, DstestError, ENGINE_FAULTS, equals, jsonOf, matchStub, runAll, runCase, sourceModules,
         TRAP_KINDS } from "../lib/core/dstest.js";
import { assertionText, caseLines, literalText } from "../lib/text/dstest.js";
import { main } from "../lib/cli/main.js";
import { NO_COMPILER, TARGET } from "./compiler.mjs";

const NO_ENGINE = process.env.DS_JS_FIXTURES ? false : "needs the js gate's engine (DS_JS_FIXTURES)";
const NO_DSC = NO_ENGINE || NO_COMPILER;

let ds;
before(async () => {
    process.env.DSDB_JS = fileURLToPath(new URL("../../../bindings/js/lib/index.js", import.meta.url));
    if (NO_ENGINE) return;
    const jsBinding = await import(new URL("../../../bindings/js/lib/index.js", import.meta.url).href);
    ds = await jsBinding.open({ target: TARGET });
});

// ── reading the atoms ───────────────────────────────────────────────────────

const POS = { number: 1, name: "TEST_POLARITY_POS" };
const NEVER = { number: 2, name: "TEST_POLARITY_NEVER" };

/** A `@ds-lang/ds` whose reader gives these atoms, as libds's reader gives them. */
function reading(...atoms) {
    return { readAtoms: () => ({ atoms: atoms.map(([message, body, unknownFields = []]) =>
        ({ offset: 0, field: 0, message, body, unknownFields, bodyOffset: 0, bodyLength: 0 })),
                                 end: 0, incomplete: false, error: null }) };
}

/** That `f` refuses the run with `code`, naming `atom`, so no case is reported. */
function refuses(f, code, atom) {
    assert.throws(f, (err) => {
        assert.ok(err instanceof DstestError, String(err));
        assert.equal(err.code, code);
        assert.match(err.message, atom);
        return true;
    });
}

// Artefacts built by hand, for what no conforming compiler writes
// ([RTIM.14.15]). An atom is framed as [RFCS.19.1] has it: 0x0a, its length, its
// field's tag and its body.
const varint = (n) => (n < 0x80 ? [n] : [(n & 0x7f) | 0x80, ...varint(n >>> 7)]);
const bytesOf = (s) => [...new TextEncoder().encode(s)];
const lenField = (field, body) => [...varint((field << 3) | 2), ...varint(body.length), ...body];
const strField = (field, s) => lenField(field, bytesOf(s));
const intField = (field, n) => [...varint(field << 3), ...varint(n)];
const atom = (field, body) => lenField(1, lenField(field, body));
const artefact = (...atoms) => Uint8Array.from(atoms.flat());
const CASE_ATOM = atom(317, [...intField(1, 1), ...strField(2, "t")]);
/** An initial Sensor fact for test 1, which the program SENSOR fires on. */
const FACT_ATOM = (testId = 1) => atom(318, [...intField(1, testId), ...intField(2, 1), ...strField(4, "Sensor"),
                                             ...lenField(5, [...strField(1, "id"), ...strField(4, "a")]),
                                             ...lenField(5, [...strField(1, "v"), ...intField(2, 42)])]);
/** `emitted Hot`, with whatever `extra` follows its known fields. */
const EMIT_ATOM = (extra = []) => atom(288, [...intField(1, 1), ...intField(2, 1), ...strField(3, "Hot"), ...extra]);
const FIELD_99 = intField(99, 7);

const CASE = ["TestCase", { test_id: 1n, name: "t", until_ns: 0n, module_id: 0n, absolute_time: false }];
const activated = (extra = {}) =>
    ["OracleActivated", { test_id: 1n, polarity: POS, rule_name: "r", occurrence: 0n, ...extra }];

// Test 2's atoms, for [RDSC.8.7]: its TestCase, an initial Sensor fact and an
// assertion that `detect` fires, which the program SENSOR below makes true.
const CASE_2 = ["TestCase", { test_id: 2n, name: "two", until_ns: 0n, module_id: 0n, absolute_time: false }];
const FACT_2 = ["TestFact", { test_id: 2n, is_initial: true, when_ns: 0n, schema_name: "Sensor",
                              slots: [{ slot_name: "id", s_val: "a" }, { slot_name: "v", i_val: 42n }],
                              source_order: 0n }];
const ORACLE_2 = activated({ test_id: 2n, rule_name: "detect" });

describe("reading a case's atoms", () => {
    // @spec [RTIM.14.15]
    test("a refusal names the atom from the reader's error, and parses no frame: the bytes here are empty", () => {
        const stopped = (field, message) => ({ readAtoms: () => ({ atoms: [], end: 0, incomplete: false,
            error: { offset: 7, status: 1, detail: "why", field, message } }) });
        for (const read of [decodeCases, sourceModules]) {
            const none = new Uint8Array();
            refuses(() => read(stopped(288, "OracleEmit"), none), "DS_ERR_DSC_DECODE",
                    /: OracleEmit \(field 288\) at byte 7 does not decode: why$/);
            refuses(() => read(stopped(2000, null), none), "DS_ERR_DSC_DECODE",
                    /: an atom \(field 2000\) at byte 7 does not decode: why$/);
            refuses(() => read(stopped(null, null), none), "DS_ERR_DSC_DECODE",
                    /: the atom at byte 7 does not decode: why$/);
        }
    });

    test("an assertion is read with its polarity and its place among the case's assertions", () => {
        const [c] = decodeCases(reading(CASE, activated(), activated({ polarity: NEVER, rule_name: "q" })),
                                new Uint8Array());
        assert.deepEqual(c.unread, []);
        assert.deepEqual(c.oracles.map((o) => [o.head, o.rule, o.never, o.index]),
                         [["activated", "r", false, 0], ["activated", "q", true, 1]]);
    });

    test("an oracle this runner does not evaluate fails its case by name, and keeps the later ones' places "
         + "([RTIM.14.9])", () => {
        const [c] = decodeCases(reading(CASE,
            ["OracleExclusive", { test_id: 1n, polarity: POS, rule_name: ["a", "b"] }],
            activated()), new Uint8Array());
        assert.deepEqual(c.unread, ["OracleExclusive"]);
        // The second assertion is index 1: its oracle rule is named by its
        // place among all of them ([RTIM.14.13]).
        assert.equal(c.oracles[0].index, 1);
    });

    test("a polarity, severity or mode that names nothing fails the case rather than matching nothing", () => {
        const [c] = decodeCases(reading(CASE,
            activated({ polarity: { number: 0, name: "TEST_POLARITY_UNSPECIFIED" } }),
            ["OracleLog", { test_id: 1n, polarity: NEVER, severity: { number: 99, name: null }, has_msg: false,
                            msg_substr: "", occurrence: 0n }],
            ["OracleWorkingMemory", { test_id: 1n, polarity: NEVER, mode: { number: 9, name: null }, schema_name: "",
                                      count: 0n }]), new Uint8Array());
        assert.deepEqual(c.unread, ["OracleActivated with polarity 0", "OracleLog with severity 99",
                                    "OracleWorkingMemory with mode 9"]);
        assert.deepEqual(c.oracles, []);
    });

    test("`exactly N` is not read as the bare head: it fails the case ([LTSL.8.7] is deferred)", () => {
        const [c] = decodeCases(reading(CASE, activated({ occurrence: 2n })), new Uint8Array());
        assert.equal(c.unread.length, 1);
        assert.match(c.unread[0], /^OracleActivated with `exactly 2`/);
    });

    test("argument keys on `called` fail the case: argument equality is the stub's ([LTSL.8.4])", () => {
        const [c] = decodeCases(reading(CASE,
            ["OracleCall", { test_id: 1n, polarity: POS, service: "svc.foo", has_correlation: false, correlation: "",
                             arg_match: [{ slot_name: "x", i_val: 1n }], occurrence: 0n }]), new Uint8Array());
        assert.match(c.unread[0], /^OracleCall with argument keys/);
    });

    // @spec [RTIM.14.7]
    test("an emit or publish oracle with both slot_match and has_where fails its case by name, neither half "
         + "checked ([RTIM.14.7])", () => {
        // Built here: no conforming compiler writes the pair ([LGRA.21.1]).
        const emitOracle = (message, extra) =>
            [message, { test_id: 1n, polarity: POS, schema_name: "Heater", slot_match: [], has_where: false,
                        where_expr_id: 0n, occurrence: 0n, ...extra }];
        const zone = [{ slot_name: "zone", s_val: "a" }];
        for (const message of ["OracleEmit", "OraclePublish"]) {
            const [c] = decodeCases(reading(CASE, emitOracle(message, { slot_match: zone, has_where: true })),
                                    new Uint8Array());
            assert.equal(c.unread.length, 1, message);
            assert.match(c.unread[0], new RegExp(`^${message} for Heater \\(test_id 1\\) with both slot_match `
                                                 + "and a where predicate"), message);
            assert.deepEqual(c.oracles, [], message);
            // CONTROLS: each half alone is read, so the refusal is the pair's.
            const [w] = decodeCases(reading(CASE, emitOracle(message, { has_where: true })), new Uint8Array());
            assert.deepEqual([w.unread, w.oracles.map((o) => [o.schema, o.slots.length, o.where])],
                             [[], [["Heater", 0, true]]], message);
            const [s] = decodeCases(reading(CASE, emitOracle(message, { slot_match: zone })), new Uint8Array());
            assert.deepEqual([s.unread, s.oracles.map((o) => [o.schema, o.slots.length, o.where])],
                             [[], [["Heater", 1, false]]], message);
        }
    });

    // @spec [RDSC.8.7]
    test("an atom naming a test no TestCase declares refuses the run, naming the atom; with its TestCase, nothing "
         + "does", () => {
        const stub = ["TestResponse", { stub_id: 7n, test_id: 2n, service: "svc.foo" }];
        for (const [kind, a] of [["TestFact", FACT_2], ["OracleActivated", ORACLE_2], ["TestResponse", stub],
                                 ["TestCacheSeed", ["TestCacheSeed", { test_id: 2n, key: "k" }]]])
            refuses(() => decodeCases(reading(CASE, a), new Uint8Array()), "DS_ERR_DSC_DANGLING",
                    new RegExp(`a ${kind} names test_id 2`));
        const cases = decodeCases(reading(CASE, CASE_2, FACT_2, ORACLE_2), new Uint8Array());
        assert.deepEqual(cases.map((c) => [c.testId, c.name, c.unread]), [[1, "t", []], [2, "two", []]]);
    });

    // @spec [RTIM.14.15]
    test("a TestReply to a stub no TestResponse declares refuses the run; declared anywhere in the artefact, it "
         + "reads", () => {
        const reply = ["TestReply", { stub_id: 7n, schema_name: "Ack", reply_order: 0n }];
        refuses(() => decodeCases(reading(CASE, reply), new Uint8Array()), "DS_ERR_DSC_DANGLING",
                /a TestReply names stub_id 7/);
        const [c] = decodeCases(reading(reply, CASE, ["TestResponse", { stub_id: 7n, test_id: 1n, service: "svc.foo" }]),
                                new Uint8Array());
        assert.equal(c.stubs[0].replies.length, 1);
    });

    // @spec [RTIM.14.9]
    test("an oracle with a field this interpreter does not know fails its case, naming the atom and the field, "
         + "and is not read as its bare head", () => {
        const [c] = decodeCases(reading(CASE, [...activated(), [99, 8]], activated({ rule_name: "q" })),
                                new Uint8Array());
        assert.deepEqual(c.unread, ["OracleActivated with unknown fields 99, 8"]);
        assert.deepEqual(c.oracles.map((o) => [o.rule, o.index]), [["q", 1]],
                         "the later assertion keeps its place ([RTIM.14.13])");
    });

    // @spec [RTIM.14.9]
    test("a scenario atom with a field this interpreter does not know fails its case and the case is not driven", () => {
        const stub = ["TestResponse", { stub_id: 7n, test_id: 1n, service: "svc.foo" }];
        const bare = { readAtoms: () => { throw new Error("no read here"); },
                       Engine: class { constructor() { throw new Error("a case not driven needs no engine"); } } };
        for (const [name, atoms] of [
            ["TestCase", [[...CASE, [99]]]],
            ["TestFact", [CASE, [...FACT_2.slice(0, 1), { ...FACT_2[1], test_id: 1n }, [99]]]],
            ["TestCacheSeed", [CASE, ["TestCacheSeed", { test_id: 1n, key: "k" }, [99]]]],
            ["TestResponse", [CASE, [...stub, [99]]]],
            ["TestReply", [CASE, stub, ["TestReply", { stub_id: 7n, schema_name: "Ack", reply_order: 0n }, [99]]]],
        ]) {
            const [c] = decodeCases(reading(...atoms), new Uint8Array());
            assert.deepEqual(c.undriven, [`${name} with unknown field 99`], name);
            const r = runCase(bare, new Uint8Array(), c);
            assert.deepEqual([r.passed, r.verdicts, r.failures], [false, [], c.undriven], name);
        }
    });

    test("an atom libds cannot read fails every case: it may be an assertion ([RTIM.14.10])", () => {
        const cases = decodeCases(reading(CASE, [null, null],
            ["TestCase", { test_id: 2n, name: "u", until_ns: 0n, module_id: 0n, absolute_time: false }]),
                                  new Uint8Array());
        assert.equal(cases.length, 2);
        for (const c of cases) assert.match(c.unread.join("\n"), /cannot read, and which may be an assertion/);
    });

    test("replies join their stub by stub_id and run in reply order, wherever their atoms are", () => {
        const lit = (slot_name, s_val) => ({ slot_name, s_val });
        const [c] = decodeCases(reading(
            ["TestReply", { stub_id: 7n, schema_name: "Ack", slots: [lit("n", "second")], reply_order: 1n }],
            CASE,
            ["TestResponse", { stub_id: 7n, test_id: 1n, service: "svc.foo", correlation: "c1", after_ns: 0n,
                               no_response: false }],
            ["TestReply", { stub_id: 7n, schema_name: "Ack", slots: [lit("n", "first")], reply_order: 0n }]),
                                new Uint8Array());
        assert.equal(c.stubs.length, 1);
        assert.deepEqual(c.stubs[0].replies.map((r) => r.slots[0][1].value), ["first", "second"]);
        assert.deepEqual(c.stubs[0].argMatch, []);
    });

    test("a stub matches a call by service, its correlation if it names one, and its argument keys", () => {
        const stub = (id, correlation, argMatch) => ({ id, service: "svc.foo", correlation, argMatch, afterNs: 0n,
                                                        noResponse: false, replies: [] });
        const stubs = [stub(1, "c9", []), stub(2, "", [["x", { kind: "int", value: 42n }]]), stub(3, "", [])];
        const fake = { JsonText: class {} };
        assert.equal(matchStub(fake, { service: "svc.foo", correlation: "c9", args: {} }, stubs).id, 1);
        assert.equal(matchStub(fake, { service: "svc.foo", correlation: "c1", args: { x: 42n } }, stubs).id, 2);
        assert.equal(matchStub(fake, { service: "svc.foo", correlation: "c1", args: { x: 41n } }, stubs).id, 3);
        assert.equal(matchStub(fake, { service: "svc.bar", correlation: "c9", args: {} }, stubs), null);
    });

    // A call's Json argument
    // reaches the runner as its JSON text, and a `json(...)` argument key
    // must meet it by JSON value, or the stub never answers.
    test("a json() argument key matches the call's Json argument by JSON value; a string by equality", () => {
        class JsonText { constructor(text) { this.text = text; } }
        const fake = { JsonText };
        const stub = (lit) => ({ id: 1, service: "svc.x", correlation: "", argMatch: [["doc", lit]], afterNs: 0n,
                                 noResponse: true, replies: [] });
        const call = (doc) => ({ service: "svc.x", correlation: "k", args: { doc } });
        const json = stub({ kind: "json", value: '{"a": [1, null], "b": "c"}' });
        assert.equal(matchStub(fake, call(new JsonText('{"b":"c","a":[1,null]}')), [json]), json);
        const one = stub({ kind: "json", value: '{"a": 1}' });
        for (const text of ['{"a":2}', '"{\\"a\\":1}"', "not json"])
            assert.equal(matchStub(fake, call(new JsonText(text)), [one]), null, text);
        const str = stub({ kind: "string", value: "k" });
        assert.equal(matchStub(fake, call("k"), [str]), str);
        assert.equal(matchStub(fake, call("j"), [str]), null);
        // @spec [LTSL.4.3]: another kind holding the same text is unequal, either way.
        const jsonOne = stub({ kind: "json", value: "1" });
        const strOne = stub({ kind: "string", value: "1" });
        assert.equal(matchStub(fake, call("1"), [jsonOne]), null);
        assert.equal(matchStub(fake, call(new JsonText("1")), [strOne]), null);
        assert.equal(matchStub(fake, call(new JsonText("1")), [jsonOne]), jsonOne);
    });
});

describe("JSON-value equality ([LTSL.8.2])", () => {
    test("42 and 42.0 are one number; key order and spacing do not matter", () => {
        assert.equal(jsonOf("42"), jsonOf("42.0"));
        assert.equal(jsonOf("4.2e1"), jsonOf("42"));
        assert.equal(jsonOf('{"b": [1, 2], "a": null}'), jsonOf('{"a":null,"b":[1.0,2]}'));
        assert.notEqual(jsonOf("[1, 2]"), jsonOf("[2, 1]"));
        assert.equal(jsonOf("-0"), jsonOf("0"));
    });

    test("a 64-bit integer is compared exactly, not through a double", () => {
        assert.notEqual(jsonOf("9007199254740993"), jsonOf("9007199254740992"));
    });

    test("text that is not one JSON value has no form, and equals nothing", () => {
        for (const bad of ["", "{", "[1,]", "01", "1 2", "nul", '"\\x"']) assert.equal(jsonOf(bad), null, bad);
    });
});

describe("a literal against a value read from the engine", () => {
    const int = (value) => ({ kind: "int", value });
    const float = (value) => ({ kind: "float", value });

    // @spec [LTSL.4.3]
    test("an Int literal and a Float slot, and a Float literal and an Int slot, are equal as one number", () => {
        assert.equal(equals(int(42n), 42.0), true);
        assert.equal(equals(float(42.0), 42n), true);
        assert.equal(equals(int(42n), 42.5), false);
        assert.equal(equals(float(42.5), 42n), false);
    });

    // @spec [LTSL.4.3]
    test("no promotion: an Int slot of 2^53+1 is not the Float literal 2^53", () => {
        assert.equal(equals(float(9007199254740992.0), 9007199254740993n), false);
        assert.equal(equals(float(9007199254740992.0), 9007199254740992n), true, "the same number is equal");
    });

    // @spec [LTSL.4.3]
    test("a Json literal is equal by JSON value: key order and 1 against 1.0 do not matter", () => {
        const lit = { kind: "json", value: '{"a":1,"b":[1,2]}' };
        assert.equal(equals(lit, '{"b":[1,2],"a":1.0}'), true);
        assert.equal(equals(lit, '{"b":[2,1],"a":1}'), false);
    });

    // @spec [LTSL.4.3]
    test("a literal with no value is equal to null and to nothing else", () => {
        assert.equal(equals({ kind: "none" }, null), true);
        assert.equal(equals({ kind: "none" }, 0n), false);
        assert.equal(equals({ kind: "none" }, ""), false);
    });
});

describe("writing assertions back", () => {
    test("each head in the test language's surface", () => {
        const o = (a, never = false) => ({ ...a, never, index: 0 });
        assert.equal(assertionText(o({ head: "emitted", schema: "HeaterOn", where: false,
                                       slots: [["zone", { kind: "string", value: "cellar" }]] })),
                     'emitted HeaterOn zone: "cellar"');
        assert.equal(assertionText(o({ head: "called", service: "svc.foo", correlation: "c1" }, true)),
                     'never called svc.foo as "c1"');
        assert.equal(assertionText(o({ head: "logged", level: "WARNING", text: "low" })), 'logged warning "low"');
        assert.equal(assertionText(o({ head: "wm count", schema: "Keep", count: 1 })), "wm count Keep == 1");
        assert.equal(literalText({ kind: "float", value: 42 }), "42.0");
        assert.equal(literalText({ kind: "duration", value: 5n }), "5_ns");
    });
});

// ── running cases on the engine ─────────────────────────────────────────────

/** Compile a program with its tests and run them. */
async function run(src) {
    return runAll(ds, await ds.compile(`use default\n\n${src}`, { file: "t.ds" }));
}

/** The results by case name. */
async function cases(src) {
    return new Map((await run(src)).map((r) => [r.name, r]));
}

/** What a failed case says, for an assertion's message. */
const why = (r) => caseLines(r).join("\n");

/** Every case passed. */
async function allPass(src) {
    const results = await run(src);
    assert.ok(results.length > 0, "no cases");
    for (const r of results) assert.ok(r.passed, why(r));
    return results;
}

/** A program with no test of its own, for test 2's atoms above. */
const SENSOR = `schema Sensor scope logical:
    id: String key
    v: Int mutable
schema Hot scope logical:
    id: String key

rule detect:
    Sensor s where s.v > 10
->
    emit Hot logical id: s.id
`;

const COLD = `schema TempReading scope logical:
    zone: String key
    celsius: Float mutable
schema HeaterOn scope logical:
    zone: String key
schema Shutdown scope logical:
    zone: String key

rule cold_detected:
    TempReading t where t.celsius < 5.0
->
    emit HeaterOn logical zone: "cellar"

test "cold path fires and emits":
    inputs:
        at 0_s:
            TempReading zone: "cellar" celsius: 2.0
    produces:
        activated cold_detected
        emitted HeaterOn zone: "cellar"
        never emitted Shutdown

test "warm path does not fire":
    inputs:
        at 0_s:
            TempReading zone: "cellar" celsius: 20.0
    produces:
        activated cold_detected
`;

describe(`running cases on the ${TARGET} target`, () => {
    test("a case passes when its assertions hold, and fails, naming the one that did not", { skip: NO_DSC },
         async () => {
        const by = await cases(COLD);
        const cold = by.get("cold path fires and emits");
        assert.ok(cold.passed, why(cold));
        assert.deepEqual(cold.verdicts.map((v) => [assertionText(v.oracle), v.observed]),
                         [["activated cold_detected", 1], ['emitted HeaterOn zone: "cellar"', 1],
                          ["never emitted Shutdown", 0]]);
        const warm = by.get("warm path does not fire");
        assert.ok(!warm.passed);
        assert.deepEqual(caseLines(warm), ['[FAIL] "warm path does not fire"',
                                           "    activated cold_detected: want at least one, observed 0"]);
    });

    test("an initial fact is arranged before the timeline and fires the rule ([RTIM.14.4])", { skip: NO_DSC },
         async () => {
        await allPass(`schema Sensor scope logical:
    id: String key
    v: Int mutable
schema Hot scope logical:
    id: String key

rule detect:
    Sensor s where s.v > 10
->
    emit Hot logical id: s.id

test "initial fact fires the rule":
    initial:
        Sensor id: "a" v: 42
    until 1_s
    produces:
        activated detect
        emitted Hot id: "a"
`);
    });

    // @spec [RDSC.8.7]
    test("atoms naming a test no TestCase declares run no case; declared, the same case passes", { skip: NO_DSC },
         async () => {
        // The compiler writes a TestCase for every test, so test 2's atoms
        // come through a reader of their own; the program is compiled, and
        // each case runs on a fresh engine that loads it.
        const dsc = await ds.compile(`use default\n\n${SENSOR}`, { file: "t.ds" });
        refuses(() => decodeCases(reading(FACT_2, ORACLE_2), dsc), "DS_ERR_DSC_DANGLING", /a TestFact names test_id 2/);
        const [declared] = decodeCases(reading(CASE_2, FACT_2, ORACLE_2), dsc);
        const passed = runCase(ds, dsc, declared);
        assert.ok(passed.passed, why(passed));
    });

    // @spec [RTIM.14.15]
    test("a truncated OracleEmit body refuses the run with DS_ERR_DSC_DECODE, naming the atom", { skip: NO_ENGINE },
         () => {
        // schema_name says five bytes and one follows.
        const bad = atom(288, [...intField(1, 1), ...intField(2, 1), ...varint((3 << 3) | 2), 5, 0x52]);
        refuses(() => runAll(ds, artefact(CASE_ATOM, bad)), "DS_ERR_DSC_DECODE",
                new RegExp(`OracleEmit \\(field 288\\) at byte ${CASE_ATOM.length} `));
    });

    test("a frame cut short refuses the run with DS_ERR_DSC_DECODE, naming where the atom starts", { skip: NO_ENGINE },
         () => {
        const cut = artefact(CASE_ATOM, EMIT_ATOM().slice(0, -1));
        refuses(() => runAll(ds, cut), "DS_ERR_DSC_DECODE", new RegExp(`: the atom at byte ${CASE_ATOM.length} `));
    });

    // @spec [RTIM.14.15]
    test("a TestFact with test_id 9 in a one-case artefact, and a TestReply to an undeclared stub, refuse the run "
         + "with DS_ERR_DSC_DANGLING", { skip: NO_ENGINE }, () => {
        refuses(() => runAll(ds, artefact(CASE_ATOM, FACT_ATOM(9))), "DS_ERR_DSC_DANGLING",
                /a TestFact names test_id 9/);
        const reply = atom(321, [...intField(1, 5), ...strField(2, "Ack")]);
        refuses(() => runAll(ds, artefact(CASE_ATOM, reply)), "DS_ERR_DSC_DANGLING", /a TestReply names stub_id 5/);
    });

    // @spec [RTIM.14.15]
    test("bodies are checked before names: an artefact with both defects is refused for the body",
         { skip: NO_ENGINE }, () => {
        const bad = atom(288, [...intField(1, 1), ...varint((3 << 3) | 2), 5, 0x52]);
        refuses(() => runAll(ds, artefact(CASE_ATOM, FACT_ATOM(9), bad)), "DS_ERR_DSC_DECODE", /OracleEmit/);
    });

    // @spec [RTIM.14.9]
    test("an OracleEmit carrying field 99 fails its case naming field 99, and passes when the field is removed",
         { skip: NO_DSC }, async () => {
        const dsc = await ds.compile(`use default\n\n${SENSOR}`, { file: "t.ds" });
        const runOf = (emit) => runCase(ds, dsc, decodeCases(ds, artefact(CASE_ATOM, FACT_ATOM(), emit))[0]);
        const failed = runOf(EMIT_ATOM(FIELD_99));
        assert.equal(failed.passed, false);
        assert.deepEqual(failed.failures, ["OracleEmit with unknown field 99"]);
        assert.deepEqual(failed.verdicts, [], "it is not evaluated as its bare head");
        const passed = runOf(EMIT_ATOM());
        assert.ok(passed.passed, why(passed));
        assert.deepEqual(passed.verdicts.map((v) => [assertionText(v.oracle), v.observed]), [["emitted Hot", 1]]);
    });

    /** `ds`, with each engine's cache capped at `keys` before it loads. */
    const capped = (keys) => Object.create(ds, { Engine: { value: class extends ds.Engine {
        constructor() {
            super();
            this.cache.setCap({ keys });
        }
    } } });

    const WRITES = `schema Trig scope logical:
    v: Int key
schema Later scope logical:
    v: Int key

rule writes:
    Trig
->
    cache key: "a" value: 1
    cache key: "b" value: 2

rule later:
    Later
->
    log critical "later"

test "past the cap":
    inputs:
        at 0_s:
            Trig v: 1
        at 1_s:
            Later v: 2
    produces:
        activated later
        logged critical "later"
`;

    // @spec [RTIM.14.14]
    test("a pump that writes the cache past its cap fails the case, naming the pump and its status, and no later "
         + "input is asserted", { skip: NO_DSC }, async () => {
        const dsc = await ds.compile(`use default\n\n${WRITES}`, { file: "t.ds" });
        const [r] = runAll(capped(1), dsc);
        assert.equal(r.passed, false);
        assert.match(r.failures[0], /^pump at 0 refused: DS_ERR_CONTRACT_BREACH/, why(r));
        assert.ok(r.verdicts.length > 0 && r.verdicts.every((v) => v.observed === 0), why(r));
        // CONTROL: with room for both writes the later input arrives.
        const [ok] = runAll(capped(2), dsc);
        assert.ok(ok.passed, why(ok));
    });

    // @spec [RTIM.14.14]
    test("a cache seed past the cap fails the case, naming the seed and its status, and nothing is driven",
         { skip: NO_DSC }, async () => {
        const dsc = await ds.compile(`use default\n\n${SENSOR}
test "seeded past the cap":
    initial:
        cache "a": 1
        cache "b": 2
        Sensor id: "a" v: 42
    until 1_s
    produces:
        never activated detect
`, { file: "t.ds" });
        const [r] = runAll(capped(1), dsc);
        assert.equal(r.passed, false);
        assert.match(r.failures[0], /^cache seed b refused: DS_ERR_CONTRACT_BREACH/, why(r));
        // The `never` holds because nothing was driven: the fact was not
        // arranged. CONTROL: with room for both seeds it is, and the rule fires.
        assert.deepEqual(r.verdicts.map((v) => [v.observed, v.ok]), [[0, true]], why(r));
        assert.deepEqual(runAll(capped(2), dsc)[0].verdicts.map((v) => [v.observed, v.ok]), [[1, false]]);
    });

    // @spec [LTSL.4.3]
    test("on the engine, an Int slot of 2^53+1 is not the Float literal 2^53, and keeps its 64 bits",
         { skip: NO_DSC }, async () => {
        const dsc = await ds.compile(`use default

schema Big scope logical:
    id: String key
    n: Int mutable
`, { file: "t.ds" });
        const literal = (f) => [{ slot_name: "n", ...f }];
        const wm = (polarity, slot_match) => ["OracleWorkingMemory", { test_id: 1n, polarity, schema_name: "Big",
            mode: { number: 1, name: "OracleWorkingMemory.MODE_HAS" }, slot_match, occurrence: 0n }];
        const [c] = decodeCases(reading(CASE,
            ["TestFact", { test_id: 1n, is_initial: true, when_ns: 0n, schema_name: "Big", source_order: 0n,
                           slots: [{ slot_name: "id", s_val: "a" }, { slot_name: "n", i_val: 9007199254740993n }] }],
            wm(NEVER, literal({ f_val: 9007199254740992.0 })),
            wm(NEVER, literal({ i_val: 9007199254740992n })),
            wm(POS, literal({ i_val: 9007199254740993n }))), dsc);
        const r = runCase(ds, dsc, c);
        assert.ok(r.passed, why(r));
    });

    // @spec [LTSL.4.3]
    test("on the engine, a Json literal matches a slot by JSON value, a Float slot an Int literal, and a null slot "
         + "a literal with no value", { skip: NO_DSC }, async () => {
        const dsc = await ds.compile(`use default

schema Doc scope logical:
    id: String key
    j: Json mutable
    f: Float mutable
    i: Int mutable
    gone: String? mutable
`, { file: "t.ds" });
        const [c] = decodeCases(reading(CASE,
            ["TestFact", { test_id: 1n, is_initial: true, when_ns: 0n, schema_name: "Doc", source_order: 0n,
                           slots: [{ slot_name: "id", s_val: "a" }, { slot_name: "j", j_val: '{"b":[1,2],"a":1.0}' },
                                   { slot_name: "f", f_val: 42.0 }, { slot_name: "i", i_val: 42n }] }],
            ["OracleWorkingMemory", { test_id: 1n, polarity: POS, schema_name: "Doc", occurrence: 0n,
                                      mode: { number: 1, name: "OracleWorkingMemory.MODE_HAS" },
                                      slot_match: [{ slot_name: "j", j_val: '{"a":1,"b":[1,2]}' },
                                                   { slot_name: "f", i_val: 42n }, { slot_name: "i", f_val: 42.0 },
                                                   { slot_name: "gone" }] }]), dsc);
        const r = runCase(ds, dsc, c);
        assert.ok(r.passed, why(r));
    });

    // @spec [LTSL.4.3]
    test("on the engine, a String slot and a Json slot holding the same text match only a literal of their own kind",
         { skip: NO_DSC }, async () => {
        const dsc = await ds.compile(`use default

schema Doc scope logical:
    id: String key
    s: String mutable
    j: Json mutable
`, { file: "t.ds" });
        const wm = (polarity, slot) => ["OracleWorkingMemory", { test_id: 1n, polarity, schema_name: "Doc", occurrence: 0n,
            mode: { number: 1, name: "OracleWorkingMemory.MODE_HAS" }, slot_match: [slot] }];
        const [c] = decodeCases(reading(CASE,
            ["TestFact", { test_id: 1n, is_initial: true, when_ns: 0n, schema_name: "Doc", source_order: 0n,
                           slots: [{ slot_name: "id", s_val: "a" }, { slot_name: "s", s_val: "1" },
                                   { slot_name: "j", j_val: "1" }] }],
            wm(NEVER, { slot_name: "s", j_val: "1" }),
            wm(NEVER, { slot_name: "j", s_val: "1" }),
            wm(POS, { slot_name: "s", s_val: "1" }),
            wm(POS, { slot_name: "j", j_val: "1" })), dsc);
        const r = runCase(ds, dsc, c);
        assert.ok(r.passed, why(r));
        assert.deepEqual(r.verdicts.map((v) => v.observed), [0, 0, 1, 1]);
    });

    test("a cache seed is read back through cached(), and is not itself a cache write", { skip: NO_DSC },
         async () => {
        await allPass(`schema Trig scope logical:
    tag: String key

rule readback:
    Trig
->
    let v = cached("gate")
    log critical "seen={v}"

test "seeded value is read back through cached()":
    initial:
        cache "gate": 7
    inputs:
        at 0_s:
            Trig tag: "x"
    produces:
        activated readback
        logged critical "seen=7"
        never cached "gate"

test "without the seed cached() misses":
    inputs:
        at 0_s:
            Trig tag: "y"
    produces:
        activated readback
        logged critical "seen="
        never logged critical "seen=7"
`);
    });

    // The program's own
    // `initial:` block is applied at the first step ([LGRA.24.3]), and a test's
    // `initial:` overlays it ([LTSL.5.2]): a cache key the test seeds keeps the
    // test's value. The second case is the control, so the first is not passing
    // on a block that was never applied.
    test("a test's cache seed keeps its value over the program's initial block ([LGRA.24.3])",
         { skip: NO_DSC }, async () => {
        await allPass(`schema Trig scope logical:
    tag: String key

initial:
    cache "level": 1

rule readback:
    Trig
->
    let v = cached("level")
    log critical "level={v}"

test "the test's cache entry overlays the block's":
    initial:
        cache "level": 2
    inputs:
        at 0_s:
            Trig tag: "x"
    produces:
        logged critical "level=2"
        never logged critical "level=1"

test "without one the block's value stands":
    inputs:
        at 0_s:
            Trig tag: "y"
    produces:
        logged critical "level=1"
        never logged critical "level=2"
`);
    });

    // The block's facts are in working memory before the test's first host
    // assert, so a rule joining the two fires, and once.
    test("a block fact joins a test-arranged fact exactly once ([LGRA.24.3])", { skip: NO_DSC }, async () => {
        const [r] = await allPass(`schema Cfg scope explicit:
    zone: String
    max_celsius: Int

schema Reading scope logical:
    zone: String key
    celsius: Int mutable

initial:
    Cfg zone: "cellar" max_celsius: 30

rule too_hot:
    Cfg c
    Reading r where r.zone == c.zone and r.celsius > c.max_celsius
->
    log critical "too hot {r.zone}"

test "a block fact joins a test-arranged fact":
    initial:
        Reading zone: "cellar" celsius: 35
    until 1_s
    produces:
        activated too_hot
        logged critical "too hot cellar"
`);
        assert.deepEqual(r.verdicts.filter((v) => assertionText(v.oracle) === "activated too_hot")
                                    .map((v) => v.observed), [1]);
    });

    test("absolute time pins the wall clock that now() reads ([LTSL.3.2])", { skip: NO_DSC }, async () => {
        await allPass(`import calendar

schema Ping scope logical:
    id: String key

rule stamp:
    Ping
->
    let t = now()
    log critical "t={t}"

test "absolute now() is pinned to the calendar.time coordinate":
    inputs:
        at calendar.time(2026, 6, 18, 14, 0, 0):
            Ping id: "a"
    produces:
        activated stamp
        logged critical "t=2026-06-18T14:00:00Z"
`);
    });

    // @spec [LFAC.9.2]
    test("in relative time, an input of a ts schema is stamped at its coordinate from the Unix epoch",
         { skip: NO_DSC }, async () => {
        await allPass(`schema Reading scope logical:
    id: String key
    ts: Time

rule seen:
    Reading r
->
    log critical "{r.id} ts={r.ts}"

test "ts is the coordinate's offset from 1970-01-01T00:00:00Z":
    initial:
        Reading id: "i"
    inputs:
        at 5_s:
            Reading id: "a"
    produces:
        logged critical "i ts=1970-01-01T00:00:00Z"
        logged critical "a ts=1970-01-01T00:00:05Z"
`);
    });

    // @spec [LTSL.3.1]
    test("in relative time, a rule publishes into a ts schema", { skip: NO_DSC }, async () => {
        await allPass(`schema Reading:
    id: String
    ts: Time

schema Stamped:
    id: String
    ts: Time

rule stamp:
    Reading r
->
    publish Stamped id: r.id

test "stamped":
    inputs:
        at 10_min:
            Reading id: "t"
    produces:
        published Stamped id: "t"
`);
    });

    // @spec [LTSL.3.1]
    test("in relative time, a then rule's emitted ts is its coordinate's offset from the Unix epoch",
         { skip: NO_DSC }, async () => {
        await allPass(`schema Reading scope logical:
    id: String key
    ts: Time

schema Stamped scope logical:
    id: String key
    ts: Time

rule follows:
    Reading a then Reading b within 30_s where b.id != a.id
->
    emit Stamped logical id: b.id

rule seen:
    Stamped s
->
    log critical "{s.id} ts={s.ts}"

test "the emitted ts is the coordinate's offset from 1970-01-01T00:00:00Z":
    inputs:
        at 2_s:
            Reading id: "a"
        at 5_s:
            Reading id: "b"
    produces:
        emitted Stamped id: "b"
        logged critical "b ts=1970-01-01T00:00:05Z"
`);
    });

    // @spec [LTSL.3.1]
    test("in relative time, now() reads the coordinate's offset from the Unix epoch", { skip: NO_DSC },
         async () => {
        await allPass(`schema Ping scope logical:
    id: String key

rule stamp:
    Ping p
->
    let t = now()
    log critical "{p.id} t={t}"

test "relative now() is the epoch at the start and 5_s past it at 5_s":
    inputs:
        at 0_s:
            Ping id: "a"
        at 5_s:
            Ping id: "b"
    produces:
        logged critical "a t=1970-01-01T00:00:00Z"
        logged critical "b t=1970-01-01T00:00:05Z"
`);
    });

    // A `published` head takes slot arguments and no `where` ([LTSL.8.4]): a
    // publish puts nothing in working memory for an oracle rule to match.
    test("a where predicate is the engine's oracle rule, matched on what was emitted; a published "
         + "head matches by slot", { skip: NO_DSC }, async () => {
        await allPass(`schema Trig scope logical:
    id: String key
schema Reading scope logical:
    id: String key
    v: Int mutable
schema Bell scope logical:
    zone: String key
    loud: Int mutable

rule detect:
    Trig
->
    emit Reading logical id: "r1" v: 99
    publish Bell zone: "hall" loud: 7

test "where predicate matches emitted; published by slot; near-misses do not":
    inputs:
        at 0_s:
            Trig id: "a"
    produces:
        emitted Reading r where r.v > 40
        never emitted Reading r where r.v > 200
        published Bell zone: "hall" loud: 7
        never published Bell loud: 100
`);
    });

    test("published, logged and retracted, with a ttl fact expiring between inputs", { skip: NO_DSC },
         async () => {
        await allPass(`schema Trig scope logical:
    v: Int key
schema Bell scope logical:
    zone: String key
schema Eph scope ttl 5_s:
    id: Int

rule ring:
    Trig
->
    publish Bell zone: "hall"
    log critical "ding ding"
    emit Eph id: 1

test "ring publishes, logs, and the eph expires":
    inputs:
        at 0_s:
            Trig v: 1
        at 6_s:
            Trig v: 2
    produces:
        published Bell zone: "hall"
        logged critical "ding"
        never logged critical "boom"
        emitted Eph id: 1
        retracted Eph id: 1
`);
    });

    test("a logical fact retracts when the ttl fact under it expires, and working memory empties",
         { skip: NO_DSC }, async () => {
        await allPass(`schema Source scope ttl 5_s:
    sid: String
schema Derived scope logical:
    sid: String key

rule derive:
    Source s
->
    emit Derived logical sid: s.sid

test "logical fact retracts when its ttl LHS expires":
    inputs:
        at 0_s:
            Source sid: "a"
    until 6_s
    produces:
        emitted Derived sid: "a"
        retracted Derived sid: "a"
        wm empty
`);
    });

    test("called, cached, cache_deleted and logged, each observed on the stream", { skip: NO_DSC }, async () => {
        await allPass(`schema Trig scope logical:
    v: Int key
service svc.foo:
    kwarg x: Int
    no response

rule act:
    Trig
->
    call svc.foo nocooldown as "c1"
    cache key: "lastk" value: 7
    cache_delete key: "oldk"
    log critical "boom"

test "act fires every effect":
    inputs:
        at 0_s:
            Trig v: 1
    responses:
        for call svc.foo as "c1":
            no response
    produces:
        called svc.foo as "c1"
        never called other.svc
        cached "lastk"
        never cached "wrongk"
        cache_deleted "oldk"
        logged critical "boom"
`);
    });

    test("a cached value is matched as a JSON value: 42 and 42.0 are one, 43 is not", { skip: NO_DSC },
         async () => {
        await allPass(`schema Trig scope logical:
    v: Int key

rule wr:
    Trig
->
    cache key: "k" value: 42.0

test "cached value is JSON-value equality":
    inputs:
        at 0_s:
            Trig v: 1
    produces:
        cached "k": 42.0
        cached "k": 42
        never cached "k": 43
        cached "k"
`);
    });

    test("wm has, wm count and wm empty read working memory at the end of the run", { skip: NO_DSC },
         async () => {
        await allPass(`schema Trig scope logical:
    v: Int key
schema Sensor scope logical:
    id: String key
    zone: String mutable

rule mk:
    Trig
->
    log info "hello world"
    emit Sensor logical id: "s1" zone: "cellar"

test "wm reads the end of the run":
    inputs:
        at 0_s:
            Trig v: 1
    produces:
        logged info "hello"
        never logged error
        wm has Sensor zone: "cellar"
        never wm has Sensor zone: "attic"
        wm count Sensor == 1
        wm has Trig
        never wm empty
`);
    });

    test("a logged assertion holds at the level the rule logged at, and not at another", { skip: NO_DSC },
         async () => {
        const by = await cases(`schema Trig scope logical:
    v: Int key

rule warn:
    Trig
->
    log warning "low battery"

test "logged at warning":
    inputs:
        at 0_s:
            Trig v: 1
    produces:
        logged warning "battery"

test "not logged at error":
    inputs:
        at 0_s:
            Trig v: 1
    produces:
        logged error "battery"
`);
        assert.ok(by.get("logged at warning").passed, why(by.get("logged at warning")));
        const error = by.get("not logged at error");
        assert.ok(!error.passed);
        assert.deepEqual(error.verdicts.map((v) => v.ok), [false]);
    });

    const RESP = `schema Trig scope logical:
    v: Int key
schema Ack scope ttl 1_min:
    corr: String
service svc.foo:
    kwarg x: Int
    response Ack

rule caller:
    Trig
->
    call svc.foo nocooldown as "c1"
        timeout 5_s:
            log critical "timed-out"

rule on_ack:
    Ack
->
    log critical "acked"
`;

    test("a stub's reply is asserted, and `no response` lets the timeout fire ([RTIM.14.6])", { skip: NO_DSC },
         async () => {
        await allPass(`${RESP}
test "reply arrives":
    inputs:
        at 0_s:
            Trig v: 1
    responses:
        for call svc.foo as "c1":
            Ack corr: "c1"
    produces:
        called svc.foo
        logged critical "acked"
        never logged critical "timed-out"

test "no response times out":
    inputs:
        at 0_s:
            Trig v: 1
    until 10_s
    responses:
        for call svc.foo as "c1":
            no response
    produces:
        called svc.foo
        never logged critical "acked"
        logged critical "timed-out"
`);
    });

    test("a call no stub answers fails its case, naming the call ([LTSL.7.6])", { skip: NO_DSC }, async () => {
        const [r] = await run(`${RESP}
test "nobody answers":
    inputs:
        at 0_s:
            Trig v: 1
    produces:
        called svc.foo
`);
        assert.ok(!r.passed);
        assert.deepEqual(r.failures, ['a call no stub answers: svc.foo as "c1"']);
        assert.ok(r.verdicts.every((v) => v.ok), "the assertion itself holds; the call is what fails the case");
    });

    test("a stub keyed by its arguments answers the call ([LTSL.7.2])", { skip: NO_DSC }, async () => {
        await allPass(`schema Trig scope logical:
    v: Int key
schema Ack scope ttl 1_min:
    corr: String
service svc.foo:
    kwarg x: Int
    response Ack

rule caller:
    Trig
->
    call svc.foo x: 42 nocooldown as "c1"

rule on_ack:
    Ack
->
    log critical "acked"

test "arg-matched stub replies":
    inputs:
        at 0_s:
            Trig v: 1
    responses:
        for call svc.foo x: 42:
            Ack corr: "c1"
    produces:
        called svc.foo
        logged critical "acked"
`);
    });

    test("an `after` reply arrives at its deadline, which moves both clocks ([LTSL.7.4])", { skip: NO_DSC },
         async () => {
        await allPass(`import calendar

schema Trig scope logical:
    v: Int key
schema Ack scope ttl 1_min:
    corr: String
service svc.foo:
    kwarg x: Int
    response Ack

rule caller:
    Trig
->
    call svc.foo nocooldown as "c1"

rule on_ack:
    Ack
->
    let t = now()
    log critical "acked-at={t}"

test "delayed reply arrives at the after deadline":
    inputs:
        at calendar.time(2026, 1, 1):
            Trig v: 1
    responses:
        for call svc.foo as "c1" after 3_s:
            Ack corr: "c1"
    produces:
        logged critical "acked-at=2026-01-01T00:00:03Z"
`);
    });

    const TYPED = `schema Trig scope logical:
    v: Int key
schema Reply scope ttl 1_min:
    corr: String
    ok: Bool
service svc.foo:
    kwarg x: Int
    response Reply
`;

    test("a typed reply reaches the call's continuation, which cancels its timeout", { skip: NO_DSC },
         async () => {
        await allPass(`import calendar

${TYPED}
rule outer:
    Trig
->
    call svc.foo nocooldown as "c1"
        on response.ok == true:
            log critical "got-response"
        timeout 5_s:
            log critical "timed-out"

test "a response cancels the timeout":
    inputs:
        at calendar.time(2026, 6, 18, 14, 0, 0):
            Trig v: 1
    until calendar.time(2026, 6, 18, 14, 0, 10)
    responses:
        for call svc.foo as "c1":
            Reply corr: "c1" ok: true
    produces:
        logged critical "got-response"
        never logged critical "timed-out"
`);
    });

    test("a reply that writes no corr is given the correlation the compiler generated for the call "
         + "([LTSL.7.2])", { skip: NO_DSC }, async () => {
        await allPass(`import calendar

${TYPED}
rule outer:
    Trig
->
    call svc.foo x: 7 nocooldown
        on response.ok == true:
            log critical "got-response"
        timeout 5_s:
            log critical "timed-out"

test "the runner supplies corr":
    inputs:
        at calendar.time(2026, 6, 18, 14, 0, 0):
            Trig v: 1
    until calendar.time(2026, 6, 18, 14, 0, 10)
    responses:
        for call svc.foo x: 7:
            Reply ok: true
    produces:
        logged critical "got-response"
        never logged critical "timed-out"
`);
    });
});

// ── the faults a case met ([RTIM.14.16]) ────────────────────────────────────
//
// The path: Run's stream observer (dstest.js `#observe`, through `faultOf`)
// collects every fault event the engine raised into the case result, and
// caseLines prints them under a failing case, after its assertions.

describe("the faults a case met ([RTIM.14.16])", { skip: NO_DSC }, () => {
    // `divide` divides by an Int slot that is 0 (`/` gives a Float): a ComputationError
    // DIVIDE_BY_ZERO abandons its activation, so its emit never happens.
    const DIVIDE = `schema Trig scope logical:
    x: Int key
    y: Int mutable
schema Out scope logical:
    q: Float key

rule divide:
    Trig t
->
    let q = t.x / t.y
    emit Out logical q: q

rule seen:
    Trig t
->
    log info "seen {t.x}"
`;

    // @spec [RTIM.14.16]
    test("a failing case names the fault that abandoned its rule: the kind, the instant, the rule", async () => {
        const [r] = await run(`${DIVIDE}
test "the division":
    inputs:
        at 5_s:
            Trig x: 1 y: 0
    produces:
        emitted Out q: 0.0
`);
        assert.equal(r.passed, false, why(r));
        assert.equal(r.faults.length, 1, why(r));
        const [f] = r.faults;
        assert.deepEqual([f.kind, f.atNs, f.rule], ["ComputationError", 5_000_000_000n, "divide"]);
        assert.match(f.cause, /^DIVIDE_BY_ZERO\b/);
        const lines = caseLines(r);
        assert.equal(lines.at(-1), `    ComputationError at T=5.000s in rule divide: ${f.cause}`, why(r));
        const short = lines.indexOf("    emitted Out q: 0.0: want at least one, observed 0");
        assert.ok(short >= 1 && short < lines.length - 1, `the fault follows the assertion that came up short:\n${why(r)}`);
    });

    // @spec [RTIM.14.16]
    test("a fault alone fails nothing: a case asserting only another rule's output passes", async () => {
        const [r] = await run(`${DIVIDE}
test "only what seen does":
    inputs:
        at 0_s:
            Trig x: 1 y: 0
    produces:
        logged info "seen 1"
`);
        assert.equal(r.passed, true, why(r));
        assert.equal(r.faults.length, 1, "the fault was met, and it failed nothing");
        assert.deepEqual(caseLines(r), ['[PASS] "only what seen does"'], "a passing case shows no fault");
    });

    // @spec [RTIM.14.16]
    test("two faults in one failing case are named in stream order: a TypeError, then a ComputationError",
         async () => {
        // `nan` computes inf - inf into a Float slot, a TypeError naming
        // Nan.v ([RARC.5.2.7]); `divide` at 2 s, a ComputationError.
        const [r] = await run(`${DIVIDE}
schema Reading scope logical:
    id: Int key
    a: Float mutable
schema Nan scope logical:
    id: Int key
    v: Float mutable

rule nanned:
    Reading r
->
    emit Nan logical id: r.id v: (r.a * r.a - r.a * r.a)

test "two faults":
    inputs:
        at 1_s:
            Reading id: 1 a: 1.0e200
        at 2_s:
            Trig x: 1 y: 0
    produces:
        emitted Out q: 0.0
`);
        assert.equal(r.passed, false, why(r));
        assert.deepEqual(r.faults.map((f) => [f.kind, f.atNs, f.rule]),
                         [["TypeError", 1_000_000_000n, "nanned"], ["ComputationError", 2_000_000_000n, "divide"]],
                         why(r));
        assert.match(r.faults[0].cause, /^Nan\.v\b/);
        const lines = caseLines(r);
        assert.deepEqual(lines.slice(-2).map((l) => l.trim().split(" ")[0]), ["TypeError", "ComputationError"]);
    });
});

// Each name table in dstest.js is its proto enum with the prefix dropped and
// the unspecified 0 left out, so a member the proto gains fails here first.
describe("the fault cause names against their protos", () => {
    /**
     * An enum's members, number to name without `prefix`, from a proto file.
     * @param {string} file @param {string} name @param {string} prefix
     */
    const members = (file, name, prefix) => {
        const text = readFileSync(fileURLToPath(new URL(`../../../proto/${file}`, import.meta.url)), "utf8");
        const body = text.slice(text.indexOf(`enum ${name} {`));
        const block = body.slice(0, body.indexOf("}"));
        const out = new Map();
        for (const m of block.matchAll(new RegExp(`^\\s*${prefix}([A-Z0-9_]+)\\s*=\\s*(\\d+)\\s*;`, "gm")))
            if (m[1] !== "UNSPECIFIED") out.set(Number(m[2]), m[1]);
        assert.ok(out.size > 0, `${name} read from ${file}`);
        return out;
    };
    test("TrapKind, CapName and EngineFault", () => {
        assert.deepEqual(TRAP_KINDS, members("engine_error.proto", "TrapKind", "TRAP_"));
        assert.deepEqual(CAP_NAMES, members("bounds_error.proto", "CapName", "CAP_"));
        assert.deepEqual(ENGINE_FAULTS, members("engine_fault.proto", "EngineFault", "ENGINE_FAULT_"));
    });
});

// ── the command line ────────────────────────────────────────────────────────

describe("ds test", () => {
    /**
     * Run `ds test` over files written into a scratch directory. A name may
     * have directories in it. `given` names the files handed to `ds test`
     * (every file, by default), and `DIR` in an `extra` argument is the
     * scratch directory.
     */
    async function dsTest(files, extra = [], given = null) {
        const base = process.env.DS_MERCURY_SCRATCH || tmpdir();
        mkdirSync(base, { recursive: true });
        const dir = mkdtempSync(join(base, "ds-test-"));
        try {
            const paths = Object.entries(files).map(([name, text]) => {
                const p = join(dir, name);
                mkdirSync(dirname(p), { recursive: true });
                writeFileSync(p, text);
                return [name, p];
            }).filter(([name]) => given === null || given.includes(name)).map(([, p]) => p);
            const args = extra.map((a) => a.replaceAll("DIR", dir));
            let out = "", err = "";
            const status = await main(["test", ...args, ...paths],
                                      { stdout: (s) => { out += s; }, stderr: (s) => { err += s; } });
            return { status, out: out.replaceAll(dir, "DIR"), err: err.replaceAll(dir, "DIR") };
        } finally {
            rmSync(dir, { recursive: true, force: true });
        }
    }

    test("every case passing is 0, and each case is a line", { skip: NO_DSC }, async () => {
        const src = `use default\n\n${COLD.replace(/\ntest "warm path[^]*$/, "\n")}`;
        const r = await dsTest({ "cold.ds": src });
        assert.equal(r.status, 0, r.err);
        assert.equal(r.out, '[PASS] "cold path fires and emits"\nds test: 1/1 case passed\n');
    });

    test("a failing case is 1, with what it wanted and saw", { skip: NO_DSC }, async () => {
        const r = await dsTest({ "cold.ds": `use default\n\n${COLD}` });
        assert.equal(r.status, 1, r.err);
        assert.equal(r.out, '[PASS] "cold path fires and emits"\n[FAIL] "warm path does not fire"\n'
                            + "    activated cold_detected: want at least one, observed 0\nds test: 1/2 cases passed\n");
    });

    test("a file with no test case is 1: a run that tested nothing does not pass", { skip: NO_DSC }, async () => {
        const r = await dsTest({ "empty.ds": "use default\n\nschema A scope logical:\n    id: Int key\n" });
        assert.equal(r.status, 1);
        assert.match(r.err, /empty\.ds: no test cases/);
    });

    test("a file that does not compile is 1, and the compiler's report goes to stderr", { skip: NO_DSC },
         async () => {
        const r = await dsTest({ "bad.ds": "use default\n\nrule broken\n" });
        assert.equal(r.status, 1);
        assert.match(r.err, /^ds test: .*bad\.ds: refused by dsc/m);
    });

    // A compiled artefact runs as it is, and an import resolves from `-L` or from the file's own directory.
    test("a .dsc runs as it is, with no compile", { skip: NO_DSC }, async () => {
        const dsc = await ds.compile(`use default\n\n${COLD.replace(/\ntest "warm path[^]*$/, "\n")}`,
                                     { file: "cold.ds" });
        const r = await dsTest({ "cold.dsc": dsc });
        assert.equal(r.status, 0, r.err);
        assert.equal(r.out, '[PASS] "cold path fires and emits"\nds test: 1/1 case passed\n');
    });

    const IMPORTER = `use default

from util.shapes import Helper

rule seen:
    Helper h
->
    log critical "seen {h.id}"

test "an imported schema":
    inputs:
        at 0_s:
            Helper id: "a"
    produces:
        logged critical "seen a"
`;
    const SHAPES = "schema Helper scope logical:\n    id: String key\n";

    test("-L resolves an import from another directory, and without it the import is refused",
         { skip: NO_DSC }, async () => {
        const files = { "lib/util/shapes.ds": SHAPES, "prog/main.ds": IMPORTER };
        const withL = await dsTest(files, ["-L", "DIR/lib"], ["prog/main.ds"]);
        assert.equal(withL.status, 0, withL.err);
        const without = await dsTest(files, [], ["prog/main.ds"]);
        assert.equal(without.status, 1);
        assert.match(without.err, /main\.ds: refused by dsc/);
    });

    // Every dsdb tool that takes a .ds file compiles it with the file's
    // own directory on the search path, then each -L (cli/open.js
    // `compileFile`); `dsc compile` searches its -L directories only
    // ([RCLI.1.4]). DSDB.md §13 says why they differ. Both are searched, so a
    // library in each is two candidates, which the compiler refuses
    // ([LIMP.3.1.3]): the file's own copy shadows nothing. And -L naming the
    // file's own directory again is one file reached twice, so it compiles.
    test("the file's own directory is searched with -L: a library in both is ambiguous; -L naming it again "
         + "is not", { skip: NO_DSC }, async () => {
        const files = { "prog/util/shapes.ds": SHAPES, "prog/main.ds": IMPORTER, "lib/util/shapes.ds": SHAPES };
        const both = await dsTest(files, ["-L", "DIR/lib"], ["prog/main.ds"]);
        assert.equal(both.status, 1, both.err);
        assert.match(both.err, new RegExp("DS_VALIDATE_AMBIGUOUS_LIBRARY: library `util\\.shapes`.*"
                                          + "DIR/prog/util/shapes\\.ds.*DIR/lib/util/shapes\\.ds"), both.err);
        const twice = await dsTest({ "prog/util/shapes.ds": SHAPES, "prog/main.ds": IMPORTER }, ["-L", "DIR/prog"],
                                   ["prog/main.ds"]);
        assert.equal(twice.status, 0, `one directory on the path twice is one candidate: ${twice.err}`);
    });

    test("the file's own directory is searched for an import", { skip: NO_DSC }, async () => {
        const r = await dsTest({ "prog/util/shapes.ds": SHAPES, "prog/main.ds": IMPORTER }, [], ["prog/main.ds"]);
        assert.equal(r.status, 0, r.err);
    });

    test("a missing file is 4, and no file at all a usage error", async () => {
        let err = "";
        const io = { stdout: () => {}, stderr: (s) => { err += s; } };
        assert.equal(await main(["test", "/no/such/file.ds"], io), 4);
        assert.match(err, /\/no\/such\/file\.ds/);
        assert.equal(await main(["test"], io), 2);
        assert.equal(await main(["test", "--frob", "x.ds"], io), 2);
        assert.equal(await main(["test", "x.dstest", "--program"], io), 2);
    });

    // ── a module's tests, and its companion's ───────────────────────────────
    //
    // A project in one directory: `main.ds` imports libraries `alpha`
    // and `beta`, and each module has a companion `.dstest` with one test. A
    // compile of `main.ds` carries all three, numbered alpha, beta, main
    // ([LTSL.2.4], [RLOW.17.1]); each case carries its module's id.

    const twoSchemas = (i, o) => `schema ${i} scope logical:\n    id: Int key\n\nschema ${o} scope logical:\n    id: Int key\n\n`;
    const answering = (rule, i, o) => `rule ${rule}:\n    ${i} p\n->\n    emit ${o} logical id: p.id\n`;
    const answers = (name, i, o, id) => `test "${name}":\n    inputs:\n        at 0_s:\n            ${i} id: ${id}\n`
        + `    produces:\n        emitted ${o} o where o.id == ${id}\n`;
    const PROJECT = {
        "alpha.ds": twoSchemas("Ping", "Pong") + answering("answer", "Ping", "Pong"),
        "alpha.dstest": answers("alpha answers", "Ping", "Pong", 1),
        "beta.ds": twoSchemas("Ding", "Dong") + answering("ring", "Ding", "Dong"),
        "beta.dstest": answers("beta answers", "Ding", "Dong", 2),
        "main.ds": `use default\n\nimport alpha\nimport beta\n\n${twoSchemas("Tick", "Tock")}${answering("tock", "Tick", "Tock")}`,
        "main.dstest": answers("main answers", "Tick", "Tock", 3),
    };
    const only = (header, name) => `${header}\n[PASS] "${name}"\nds test: 1/1 case passed\n`;

    test("a library's .dstest runs that module's cases alone, under the program in its directory that imports it "
         + "([LTSL.2.4], [LTSL.2.2])", { skip: NO_DSC }, async () => {
        const r = await dsTest(PROJECT, [], ["alpha.dstest"]);
        assert.equal(r.status, 0, r.err);
        assert.equal(r.out, only("DIR/alpha.dstest, under DIR/main.ds", "alpha answers"));
        const lib = await dsTest(PROJECT, [], ["beta.ds"]);
        assert.equal(lib.status, 0, lib.err);
        assert.equal(lib.out, only("DIR/beta.ds, under DIR/main.ds", "beta answers"), "a library .ds is its module too");
    });

    test("a program runs every module's cases in test_id order, and its own .dstest only its own",
         { skip: NO_DSC }, async () => {
        const all = await dsTest(PROJECT, [], ["main.ds"]);
        assert.equal(all.status, 0, all.err);
        assert.equal(all.out, '[PASS] "alpha answers"\n[PASS] "beta answers"\n[PASS] "main answers"\n'
                              + "ds test: 3/3 cases passed\n");
        const own = await dsTest(PROJECT, [], ["main.dstest"]);
        assert.equal(own.status, 0, own.err);
        assert.equal(own.out, only("DIR/main.dstest, under DIR/main.ds", "main answers"));
    });

    test("files that name one program compile it once and run each case once", { skip: NO_DSC }, async () => {
        const r = await dsTest(PROJECT, [], ["alpha.dstest", "main.ds"]);
        assert.equal(r.status, 0, r.err);
        assert.equal(r.out, 'DIR/alpha.dstest, DIR/main.ds\n[PASS] "alpha answers"\n[PASS] "beta answers"\n'
                            + '[PASS] "main answers"\nds test: 3/3 cases passed\n');
    });

    test("a .dstest with no module of its name beside it is refused, and runs nothing", { skip: NO_DSC },
         async () => {
        const r = await dsTest({ ...PROJECT, "stray.dstest": "bogus Thing\n" }, [], ["stray.dstest"]);
        assert.equal(r.status, 1);
        assert.match(r.err, /DIR\/stray\.dstest: a \.dstest is the tests of the module of its name beside it \(\[LTSL\.2\.4\]\), and there is no stray\.ds/);
        assert.equal(r.out, "ds test: no case ran\n");
    });

    test("a library two programs import is refused, naming both, and --program names the one",
         { skip: NO_DSC }, async () => {
        const files = { ...PROJECT, "other.ds": "use default\n\nimport alpha\n" };
        const both = await dsTest(files, [], ["alpha.dstest"]);
        assert.equal(both.status, 1);
        assert.match(both.err, /DIR\/alpha\.ds: a library runs under the program that imports it \(\[LTSL\.2\.2\]\), and 2 programs import it: main\.ds, other\.ds; name one with --program/);
        const picked = await dsTest(files, ["--program", "DIR/other.ds"], ["alpha.dstest"]);
        assert.equal(picked.status, 0, picked.err);
        assert.equal(picked.out, only("DIR/alpha.dstest, under DIR/other.ds", "alpha answers"));
    });

    test("a library no program imports is refused, and so is a --program that does not import it",
         { skip: NO_DSC }, async () => {
        const lone = await dsTest({ "lone.ds": twoSchemas("A", "B") + answering("r", "A", "B"),
                                    "lone.dstest": answers("lone answers", "A", "B", 1) }, [], ["lone.dstest"]);
        assert.equal(lone.status, 1);
        assert.match(lone.err, /DIR\/lone\.ds: .*no program in DIR imports it; name one with --program/);
        const wrong = await dsTest({ ...PROJECT, "other.ds": "use default\n" }, ["--program", "DIR/other.ds"],
                                   ["alpha.dstest"]);
        assert.equal(wrong.status, 1);
        assert.match(wrong.err, /DIR\/alpha\.ds: DIR\/other\.ds does not import it/);
    });
});
