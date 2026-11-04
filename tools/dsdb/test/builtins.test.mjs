// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// A builtin's hover in `ds lsp` (lib/lsp/builtins.js): [LEXP.17.2]'s
// signature, summary and defining clauses, and nothing else. The rendering
// is pinned against the clause's own row, read here from the spec, so the
// test and the table cannot part.

import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { builtinAt, builtinHover, builtinNamed, docsBase } from "../lib/lsp/builtins.js";

const SPECS = fileURLToPath(new URL("../../../specs/", import.meta.url));

/** LEXP.17.2's row for a name, by its column names. @param {string} name */
function row(name) {
    const { columns, rows } = JSON.parse(readFileSync(`${SPECS}language/EXPRESSIONS/LEXP.17.2.json`, "utf8")).data;
    const r = rows.find((/** @type {string[]} */ x) => x[0] === name);
    return Object.fromEntries(columns.map((/** @type {string} */ c, /** @type {number} */ i) => [c, r[i]]));
}

/** A tree holding only these imports. @param {object[]} body */
const mod = (...body) => /** @type {any} */ ({ _type: "Module", body });

test("a hover is the row's signature, summary and defining clauses ([LEXP.17.2])", () => {
    // `len`: three overloads, three defining clauses.
    const r = row("len");
    const b = builtinNamed(null, "len");
    assert.ok(b !== null);
    const want = [
        "```ds\n" + r.Signature.split(";").map((/** @type {string} */ s) => `len${s.trim()}`).join("\n") + "\n```",
        r.Summary,
        r["Defined by"].split(",").map((/** @type {string} */ c) => `[${c.trim()}]`).join(", "),
    ].join("\n\n");
    assert.equal(builtinHover(b, null), want);
    assert.equal(builtinHover(b, null).split("\n").filter((l) => l.startsWith("len(")).length, 3);
});

test("with the documentation's place, each defining clause links to its page in the specification book", () => {
    const b = builtinNamed(null, "len");
    assert.ok(b !== null);
    const hover = builtinHover(b, "https://ds.example/docs/");
    assert.match(hover, /\[\[LEXP\.6\.1\]\]\(https:\/\/ds\.example\/docs\/specs\/language\/EXPRESSIONS\.html#lexp-6-1\)/);
    // Every page is a clause file's: `<tree>/<DOC>.html#<id dashed>`.
    for (const c of b.defined) {
        const m = /^(\w+)\/(\w+)\.html#([a-z0-9-]+)$/.exec(c.page);
        assert.ok(m, c.page);
        assert.equal(m[3], c.id.replaceAll(".", "-").toLowerCase());
        assert.ok(existsSync(`${SPECS}${m[1]}/${m[2]}/${c.id}.json`), `${c.id} is a clause of ${m[1]}/${m[2]}`);
    }
});

test("the documentation's place: a URL as given, a path as a file: URL", () => {
    assert.equal(docsBase("https://ds.example/docs"), "https://ds.example/docs/");
    assert.equal(docsBase("/opt/ds/docs"), "file:///opt/ds/docs/");
    assert.equal(docsBase(""), null);
    assert.equal(docsBase(undefined), null);
});

test("the builtin a name calls: bare, through an import's qualifier, through a from-import", () => {
    const text = "    let x = math.sqrt(y) + abs(z) + sqrt(w)";
    const col = (/** @type {string} */ w) => text.indexOf(w) + 1;
    assert.equal(builtinAt(null, text, col("abs"))?.name, "abs");
    assert.equal(builtinAt(null, text, col("sqrt(y")), null, "math is not imported");
    assert.equal(builtinAt(mod({ _type: "Import", path: ["math"], asname: null }), text, col("sqrt(y"))?.name, "math.sqrt");
    const from = mod({ _type: "ImportFrom", path: ["math"], names: [{ name: "sqrt", asname: null }] });
    assert.equal(builtinAt(from, text, col("sqrt(w"))?.name, "math.sqrt");
    assert.equal(builtinAt(null, "    count 3", 5), null, "`count` not called is the clause word");
});
