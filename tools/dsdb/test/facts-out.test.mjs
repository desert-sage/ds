// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Writing facts (DSDB.md §9): every format writes what the loader reads back,
// value for value, including what the formats find awkward.

import { test } from "node:test";
import assert from "node:assert/strict";

import { durationLiteral, writeDoc, writeRows } from "../lib/core/facts-out.js";
import { loadFactFiles, parseJsonDoc } from "../lib/core/facts.js";

const SCHEMA = {
    name: "Alert",
    slots: [
        { name: "id", type: "String", nullable: false },
        { name: "n", type: "Int", nullable: false },
        { name: "x", type: "Float", nullable: true },
        { name: "ok", type: "Bool", nullable: false },
        { name: "doc", type: "Json", nullable: false },
        { name: "raw", type: "Bytes", nullable: true },
    ],
};
const EMPTY = { name: "Quiet", slots: [{ name: "k", type: "Int", nullable: false }] };

const ROWS = [
    { at: 0n, slots: { id: "plain", n: 2n ** 63n - 1n, x: 1.5, ok: true, doc: '{"k":12345678901234567891}', raw: new Uint8Array([0, 255]) } },
    { at: 1_500_000_000n, slots: { id: 'a "q", tab\tnl\n\\N', n: -1n, x: null, ok: false, doc: "[]", raw: null } },
    { at: 2_000_000_000n, slots: { id: "", n: 0n, x: Infinity, ok: true, doc: "null", raw: new Uint8Array([]) } },
    { at: 3n, slots: { id: "nan", n: 7n, x: NaN, ok: false, doc: '"s"', raw: null } },
];

const engine = (schemas) => ({ schemas: new Map(schemas.map((s) => [s.name, s])) });

/** What the loader makes of text, back as `{ at, slots }` per row, in file order. */
function readBack(path, text, schemas = [SCHEMA]) {
    return loadFactFiles([{ path, text }], engine(schemas))
        .sort((a, b) => a.line - b.line)
        .map((r) => ({ at: r.at, slots: r.slots }));
}

const same = (got, want) => {
    assert.equal(got.length, want.length);
    got.forEach((g, i) => {
        assert.equal(g.at, want[i].at, `row ${i} @at`);
        for (const [k, v] of Object.entries(want[i].slots)) {
            if (typeof v === "number" && Number.isNaN(v)) assert.ok(Number.isNaN(g.slots[k]), `row ${i} ${k}`);
            else assert.deepEqual(g.slots[k], v, `row ${i} ${k}`);
        }
    });
};

test("durations are exact, in the largest unit that divides", () => {
    assert.equal(durationLiteral(0n), "0_s");
    assert.equal(durationLiteral(2_000_000_000n), "2_s");
    assert.equal(durationLiteral(1_500_000_000n), "1500_ms");
    assert.equal(durationLiteral(3n), "3_ns");
    assert.equal(durationLiteral(7_200_000_000_000n), "2_h");
});

for (const format of ["csv", "tsv", "jsonl"]) {
    test(`${format}: what is written reads back, value for value`, () => {
        same(readBack(`Alert.${format}`, writeRows(SCHEMA, ROWS, format)), ROWS);
    });
}

const VISIT = {
    name: "Visit",
    slots: [
        { name: "seen", type: "Time", nullable: false },
        { name: "due", type: "Date", nullable: false },
        { name: "span", type: "Duration", nullable: true },
    ],
};
const VISITS = [
    { at: 0n, slots: { seen: 2n ** 63n - 1n, due: -1n, span: 1_500_000_000n } },
    { at: 1n, slots: { seen: 0n, due: 19_675n, span: null } },
];

for (const format of ["csv", "tsv", "jsonl"]) {
    test(`${format}: Time, Date and Duration are written as exact digits and read back`, () => {
        const text = writeRows(VISIT, VISITS, format);
        // In JSONL a number, as an Int is written, not a string of digits.
        assert.match(text, format === "jsonl" ? /"seen": 9223372036854775807, "due": -1, "span": 1500000000\}/
                                              : /^0_s[,\t]9223372036854775807[,\t]-1[,\t]1500000000\b/m);
        same(readBack(`Visit.${format}`, text, [VISIT]), VISITS);
    });
}

test("csv: null is a bare empty field, the empty string is quoted", () => {
    // The header, then ROWS[0], ROWS[1], ROWS[2]: the third row is ROWS[2].
    const [, , second, third] = writeRows(SCHEMA, ROWS, "csv").split("\r\n");
    assert.equal(second, '1500_ms,"a ""q"", tab\tnl\n\\N",-1,,false,[],');
    // Empty bytes are the empty string in base64: quoted, so not null.
    assert.equal(third, '2_s,"",0,inf,true,null,""');
});

test("the single-file document: every schema, empty ones too, and it reads back", () => {
    const doc = writeDoc([SCHEMA, EMPTY], new Map([["Alert", ROWS]]));
    assert.deepEqual([...parseJsonDoc(doc, "all.json").keys()], ["Alert", "Quiet"]);
    assert.match(doc, /"Quiet": \[\]/);
    same(readBack("all.json", doc, [SCHEMA, EMPTY]), ROWS);
    assert.equal(writeDoc([], new Map()), "{}\n");
});

test("a .json source and a per-schema file for the same schema are refused together", () => {
    const doc = writeDoc([SCHEMA], new Map([["Alert", ROWS]]));
    assert.throws(() => loadFactFiles([{ path: "all.json", text: doc }, { path: "Alert.csv", text: "id\n" }],
                                      engine([SCHEMA])), /`Alert` a second time/);
});
