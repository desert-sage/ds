// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Fact files (DSDB.md §8): parsing, typing by schema, merging by time, and
// feeding an engine. The engine here is a stand-in that records its calls;
// the same flow against a real @ds-lang/ds engine is the CLI test's.

import { test } from "node:test";
import assert from "node:assert/strict";

import {
    FactFileError, factFileName, feed, loadFactFiles, merge, parseCsv, parseJsonl, parseTsv, typedRows,
} from "../lib/core/facts.js";

const S = 1_000_000_000n;

// A schema as @ds-lang/ds's `schemas` gives it.
const READING = {
    name: "Reading",
    slots: [
        { name: "id", type: "String", identity: "key", nullable: false },
        { name: "n", type: "Int", identity: "mutable", nullable: false },
        { name: "x", type: "Float", identity: "mutable", nullable: false },
        { name: "ok", type: "Bool", identity: "mutable", nullable: false },
        { name: "note", type: "String", identity: "mutable", nullable: true },
    ],
};
const VISIT = {
    name: "Visit",
    slots: [
        { name: "id", type: "Int", identity: "key", nullable: false },
        { name: "seen", type: "Time", identity: "mutable", nullable: false },
        { name: "due", type: "Date", identity: "mutable", nullable: false },
        { name: "span", type: "Duration", identity: "mutable", nullable: false },
    ],
};
const BLOB = {
    name: "Blob",
    slots: [
        { name: "id", type: "String", identity: "key", nullable: false },
        { name: "doc", type: "Json", identity: "mutable", nullable: false },
        { name: "raw", type: "Bytes", identity: "mutable", nullable: false },
        { name: "ref", type: "Reading", identity: "mutable", nullable: true },
    ],
};

const rows = (file, format, text, schema = READING) =>
    typedRows({ file, format, schema: schema.name, text }, schema);

function throwsAt(fn, line, re) {
    let err;
    try { fn(); } catch (e) { err = e; }
    assert.ok(err instanceof FactFileError, `expected a FactFileError, got ${err}`);
    if (line !== undefined) assert.equal(err.line, line, err.message);
    if (re) assert.match(err.message, re);
    return err;
}

test("a file's name gives its schema and format", () => {
    assert.deepEqual(factFileName("data/Reading.csv"), { format: "csv", schema: "Reading" });
    assert.deepEqual(factFileName("Alarm.TSV"), { format: "tsv", schema: "Alarm" });
    assert.deepEqual(factFileName("C:\\x\\Hot.jsonl"), { format: "jsonl", schema: "Hot" });
    assert.equal(factFileName("prog.dsc"), null);
    assert.equal(factFileName(".csv"), null);
    assert.deepEqual(factFileName("out/all.json"), { format: "json", schema: null });
});

test("CSV: quoting, doubled quotes, CRLF, newlines in a field, bare empty is null", () => {
    const p = parseCsv('id,note\r\n"a,b","say ""hi"""\r\nc,\n"multi\nline",""\n', "t.csv");
    assert.deepEqual(p.header, ["id", "note"]);
    assert.deepEqual(p.rows.map((r) => [r.line, r.cells.get("id"), r.cells.get("note")]), [
        [2, { text: "a,b" }, { text: 'say "hi"' }],
        [3, { text: "c" }, { null: true, bare: true }],
        [4, { text: "multi\nline" }, { text: "" }],
    ]);
    throwsAt(() => parseCsv('id\n"open', "t.csv"), 2, /not closed/);
    throwsAt(() => parseCsv('id,n\na\n', "t.csv"), 2, /1 fields, the header has 2/);
    throwsAt(() => parseCsv("id,id\n", "t.csv"), 1, /twice/);
});

test("TSV: tabs, escapes, \\N is null, empty is the empty string", () => {
    const p = parseTsv("id\tnote\na\\tb\t\\N\nc\t\n", "t.tsv");
    assert.deepEqual(p.rows.map((r) => [r.cells.get("id"), r.cells.get("note")]), [
        [{ text: "a\tb" }, { null: true }],
        [{ text: "c" }, { text: "" }],
    ]);
    throwsAt(() => parseTsv("id\na\\q\n", "t.tsv"), 2, /not an escape/);
});

test("JSONL: values keep their source text; bad lines say where", () => {
    const p = parseJsonl('{"id":"a","n":18446744073709551615,"doc":{"k":[1,2.5,"x"]},"z":null}\n\n{"id":"b"}\n', "t.jsonl");
    assert.equal(p.header, null);
    const [a, b] = p.rows;
    assert.equal(a.line, 1);
    assert.deepEqual(a.cells.get("n"), { json: "18446744073709551615", kind: "number" });
    assert.deepEqual(a.cells.get("doc"), { json: '{"k":[1,2.5,"x"]}', kind: "object" });
    assert.deepEqual(a.cells.get("z"), { null: true });
    assert.equal(b.line, 3);
    throwsAt(() => parseJsonl('{"id":"a"} x\n', "t.jsonl"), 1, /more after/);
    throwsAt(() => parseJsonl("[1]\n", "t.jsonl"), 1, /one JSON object/);
    throwsAt(() => parseJsonl('{"a":1,"a":2}\n', "t.jsonl"), 1, /twice/);
});

test("typing: Int exact past 2^53 from every format, Float, Bool, null", () => {
    const big = 2n ** 63n - 1n;
    const csv = rows("r.csv", "csv", `id,n,x,ok,note\na,${big},1.5,true,\nb,-3,inf,false,"x"\n`);
    assert.deepEqual(csv.map((r) => r.slots), [
        { id: "a", n: big, x: 1.5, ok: true, note: null },
        { id: "b", n: -3n, x: Infinity, ok: false, note: "x" },
    ]);
    const tsv = rows("r.tsv", "tsv", `id\tn\tx\tok\na\t${big}\t2\ttrue\n`);
    assert.equal(tsv[0].slots.n, big);
    const jl = rows("r.jsonl", "jsonl", `{"id":"a","n":${big},"x":2,"ok":false,"note":null}\n`);
    assert.deepEqual(jl[0].slots, { id: "a", n: big, x: 2, ok: false, note: null });
    throwsAt(() => rows("r.csv", "csv", "id,n\na,1.5\n"), 2, /slot `n` \(Int\): `1.5` is not an integer/);
    // JSON producers write 64-bit integers as strings to keep them exact, so a
    // decimal string is an Int too; anything else is not.
    assert.equal(rows("r.jsonl", "jsonl", `{"id":"a","n":"${big}"}\n`)[0].slots.n, big);
    throwsAt(() => rows("r.jsonl", "jsonl", '{"id":"a","n":"7.5"}\n'), 1, /not an integer/);
    throwsAt(() => rows("r.jsonl", "jsonl", '{"id":"a","n":true}\n'), 1, /want an integer/);
    throwsAt(() => rows("r.csv", "csv", "id,ok\na,yes\n"), 2, /not true or false/);
    throwsAt(() => rows("r.csv", "csv", "id,n\na,\n"), 2, /null in a slot that is not nullable/);
    throwsAt(() => rows("r.csv", "csv", "id,colour\na,red\n"), 1, /`colour` is not a slot of Reading/);
});

test("typing: Time, Date and Duration are read as the integers they are, as Int is", () => {
    const seen = 1_700_000_000n * S + 1n;
    const want = { id: 1n, seen, due: 19_675n, span: 2n * S };
    assert.deepEqual(rows("v.csv", "csv", `id,seen,due,span\n1,${seen},19675,2000000000\n`, VISIT)[0].slots, want);
    const jsonl = `{"id":1,"seen":"${seen}","due":19675,"span":2000000000}\n`;
    assert.deepEqual(rows("v.jsonl", "jsonl", jsonl, VISIT)[0].slots, want);
    throwsAt(() => rows("v.csv", "csv", "id,seen\n1,2026-10-11\n", VISIT), 2,
             /slot `seen` \(Time\): `2026-10-11` is not an integer/);
});

test("a bare empty CSV field in a String slot that cannot be null is the empty string", () => {
    assert.equal(rows("r.csv", "csv", "id,n\n,1\n")[0].slots.id, "");
});

test("typing: Json as text or as a JSON value, Bytes as base64, no fact references", () => {
    const csv = rows("b.csv", "csv", 'id,doc,raw\na,"{""k"": 1}",AAH/\n', BLOB);
    assert.deepEqual(csv[0].slots, { id: "a", doc: '{"k": 1}', raw: new Uint8Array([0, 1, 255]) });
    const jl = rows("b.jsonl", "jsonl", '{"id":"a","doc":{"k":12345678901234567891},"raw":""}\n', BLOB);
    assert.equal(jl[0].slots.doc, '{"k":12345678901234567891}');
    const asText = rows("b.jsonl", "jsonl", '{"id":"a","doc":"[1,2]","raw":""}\n', BLOB);
    assert.equal(asText[0].slots.doc, "[1,2]");
    throwsAt(() => rows("b.csv", "csv", "id,raw\na,!!\n", BLOB), 2, /not base64/);
    throwsAt(() => rows("b.csv", "csv", "id,ref\na,x\n", BLOB), 2, /reference to another fact/);
});

test("@at: a duration or whole nanoseconds; absent is 0", () => {
    const r = rows("r.csv", "csv", "@at,id\n1.5_s,a\n250,b\n,c\n");
    assert.deepEqual(r.map((x) => x.at), [1_500_000_000n, 250n, 0n]);
    const j = rows("r.jsonl", "jsonl", '{"@at":"2_s","id":"a"}\n{"@at":5,"id":"b"}\n');
    assert.deepEqual(j.map((x) => x.at), [2n * S, 5n]);
    throwsAt(() => rows("r.csv", "csv", "@at,id\nsoon,a\n"), 2, /not a duration/);
});

test("merge: by time, then the files' order, then row order", () => {
    const a = [{ at: 5n, tag: "a1" }, { at: 0n, tag: "a2" }, { at: 5n, tag: "a3" }];
    const b = [{ at: 5n, tag: "b1" }, { at: 1n, tag: "b2" }];
    assert.deepEqual(merge([a, b]).map((r) => r.tag), ["a2", "b2", "a1", "a3", "b1"]);
});

/** A `@ds-lang/ds` Engine's surface, recording what it is asked. */
function standIn(schemas) {
    const calls = [];
    let clock = 0n;
    return {
        calls,
        schemas: new Map(schemas.map((s) => [s.name, s])),
        clock: {
            get now() { return clock; },
            advance: (d) => { calls.push(["advance", d]); clock += d; },
        },
        assert: (s, slots) => {
            calls.push(["assert", s, slots.id]);
            if (slots.id === "boom") throw new Error("missing slot `x`");
            return {};
        },
        pump: () => calls.push(["pump"]),
    };
}

test("feed: the clock moves to each row, an assert, a pump", () => {
    const e = standIn([READING, BLOB]);
    const merged = loadFactFiles([
        { path: "in/Reading.csv", text: "@at,id,n,x,ok\n2_s,a,1,0,true\n0,b,2,0,false\n" },
        { path: "in/Blob.jsonl", text: '{"@at":"2_s","id":"z","doc":"1","raw":""}\n' },
    ], e);
    assert.equal(feed(e, merged), 3);
    assert.deepEqual(e.calls, [
        ["assert", "Reading", "b"], ["pump"],
        ["advance", 2n * S], ["assert", "Reading", "a"], ["pump"],
        ["assert", "Blob", "z"], ["pump"],
    ]);
});

// @spec [LFAC.9.2]
test("feed: a row with no `ts` takes its time, one that gives `ts` keeps it, a written null is refused", () => {
    const SEEN = { name: "Seen", slots: [
        { name: "id", type: "String", identity: "key", nullable: false },
        { name: "ts", type: "Time", identity: "engine", nullable: false },
    ] };
    const e = standIn([SEEN, READING]);
    const stamps = [];
    const put = e.assert;
    e.assert = (s, slots) => { stamps.push([s, slots.id, slots.ts]); return put(s, slots); };
    const merged = loadFactFiles([
        { path: "Seen.jsonl", text: '{"@at":"2_s","id":"a"}\n{"@at":"3_s","id":"b","ts":99}\n{"id":"c"}\n' },
        { path: "Reading.csv", text: "@at,id,n,x,ok\n1_s,r,1,0,true\n" },
    ], e);
    feed(e, merged);
    assert.deepEqual(stamps, [
        ["Seen", "c", 0n],
        ["Reading", "r", undefined],
        ["Seen", "a", 2n * S],
        ["Seen", "b", 99n],
    ]);
    throwsAt(() => loadFactFiles([{ path: "Seen.jsonl", text: '{"id":"a","ts":null}\n' }], standIn([SEEN])), 1,
             /slot `ts` \(Time\): null in a slot that is not nullable/);
});

// No public entry point sets a per-fact TTL, so there is no `@ttl` column: a
// file carrying one is refused as it loads,
// naming the file and the column, before anything is fed. `@at` is the only
// column that is not a slot.
test("load: an @ttl column is refused, naming the file and the column, with no assert made", () => {
    const e = standIn([READING]);
    throwsAt(() => loadFactFiles([{ path: "Reading.csv", text: "@ttl,id,n,x,ok\n10_s,b,2,0,false\n" }], e), 1,
             /Reading\.csv:1: `@ttl` is not a fact-file column: `@at` is the only one that is not a slot; a fact takes its schema's TTL/);
    throwsAt(() => loadFactFiles([{ path: "Reading.jsonl", text: '{"@ttl":"10_s","id":"b","n":2,"x":0,"ok":false}\n' }], e), 1,
             /Reading\.jsonl:1: `@ttl` is not a fact-file column/);
    throwsAt(() => loadFactFiles([{ path: "Reading.csv", text: "@when,id,n,x,ok\n1,b,2,0,false\n" }], e), 1,
             /`@when` is not a fact-file column: `@at` is the only one that is not a slot$/);
    assert.deepEqual(e.calls, []);
});

test("feed: an engine's refusal names the file and line", () => {
    const e = standIn([READING]);
    const merged = loadFactFiles([{ path: "Reading.csv", text: "id,n,x,ok\nboom,1,0,true\n" }], e);
    throwsAt(() => feed(e, merged), 2, /Reading\.csv:2: missing slot/);
});

// [NTST.3.1]: a clock's advance has a range, and a row's @at is what moves it.
test("feed: an advance the engine refuses for a row's @at names the file and line, and the row is not asserted", () => {
    const e = standIn([READING]);
    e.clock.advance = () => { throw new Error("clock_advance past the wall clock's Time range"); };
    const merged = loadFactFiles([{ path: "Reading.csv", text: "@at,id,n,x,ok\n1_s,a,1,0,true\n" }], e);
    throwsAt(() => feed(e, merged), 2, /Reading\.csv:2: clock_advance past the wall clock's Time range/);
    assert.deepEqual(e.calls, []);
});

// [LTIM.1.3.1]: no Duration is longer than 2^63 - 1 nanoseconds. Past 2^64 the
// binding's own argument check would refuse it, with no DsError for a caller to
// name the row from, so it never gets that far.
test("load: an @at longer than any Duration is refused, naming the file and line; the longest is taken", () => {
    const e = standIn([READING]);
    const load = (at) => loadFactFiles([{ path: "Reading.csv", text: `@at,id,n,x,ok\n${at},a,1,0,true\n` }], e);
    assert.equal(load("9223372036854775807")[0].at, (1n << 63n) - 1n);
    for (const at of ["9223372036854775808", "18446744073709551616", "106752_d"])
        throwsAt(() => load(at), 2, new RegExp(`Reading\\.csv:2: \`@at\` \`${at}\` is longer than any Duration`));
    throwsAt(() => load(`${"9".repeat(400)}_d`), 2, /is not a duration such as `12_s`/);
    assert.deepEqual(e.calls, [], "nothing is fed");
});

test("loading refuses a schema the program lacks, a second file for one, a non-fact file", () => {
    const e = standIn([READING]);
    throwsAt(() => loadFactFiles([{ path: "Nope.csv", text: "id\na\n" }], e), 0, /no schema `Nope`/);
    throwsAt(() => loadFactFiles([{ path: "Reading.csv", text: "id\n" }, { path: "x/Reading.tsv", text: "id\n" }], e),
             0, /`Reading` a second time/);
    throwsAt(() => loadFactFiles([{ path: "prog.dsc", text: "" }], e), 0, /not a fact file/);
});
