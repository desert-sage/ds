// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// `ds lsp`'s outline and workspace symbols (lib/lsp/symbols.js): a rule
// file and the library it imports a schema from, dumped by the lane's
// compiler for its target (compiler.mjs), the library served from memory
// through the server's `read` port.

import { test } from "node:test";
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";

import { bodies, frame } from "../lib/lsp/framing.js";
import { runLsp } from "../lib/lsp/server.js";
import { matches } from "../lib/lsp/symbols.js";
import { NO_COMPILER as NO_DSC, dumpAst } from "./compiler.mjs";

const APP = `use default

from sensors import Reading

const LIMIT = 90.0

schema Alert scope logical:
    sensor: String key
    level: Float mutable

service svc.page:
    kwarg who: String
    no response

rule hot:
    Reading r where r.temp > LIMIT
->
    emit Alert logical sensor: r.sensor level: r.temp

test "a hot reading alerts":
    inputs:
        at 0_s:
            Reading sensor: "a" temp: 95.0
    produces:
        emitted Alert sensor: "a"
`;

const LIB = `schema Reading scope ttl 60_s:
    sensor: String
    temp: Float
`;

const APP_URI = pathToFileURL("/work/app.ds").href;
const LIB_URI = pathToFileURL("/work/sensors.ds").href;

const ports = {
    dumpAst,
    compile: () => null,
    /** @param {string} path */
    read: (path) => (path === "/work/sensors.ds" ? LIB : null),
};

/** Open APP and ask; the answers by id. @param {object[]} asks */
async function session(asks) {
    const msgs = [
        { id: 1, method: "initialize", params: { capabilities: {}, rootUri: pathToFileURL("/work").href } },
        { method: "textDocument/didOpen", params: { textDocument: { uri: APP_URI, languageId: "ds", version: 1, text: APP } } },
        ...asks,
        { id: 99, method: "shutdown" }, { method: "exit" },
    ];
    async function* input() {
        for (const m of msgs) yield Buffer.from(frame({ jsonrpc: "2.0", ...m }));
    }
    let out = "";
    /** @type {string[]} */
    const logged = [];
    await runLsp({ input: input(), write: (s) => { out += s; }, log: (s) => logged.push(s), ports });
    assert.deepEqual(logged, [], "the server logged nothing");
    /** @type {Map<number, any>} */
    const byId = new Map();
    async function* one() { yield Buffer.from(out); }
    for await (const b of bodies(one())) {
        const m = JSON.parse(b);
        if (m.id !== undefined) byId.set(m.id, m);
    }
    return byId;
}

/** @param {any} r */
const span = (r) => `${r.start.line}:${r.start.character}-${r.end.line}:${r.end.character}`;

test("the server says it answers both", { skip: NO_DSC }, async () => {
    const caps = (await session([])).get(1).result.capabilities;
    assert.equal(caps.documentSymbolProvider, true);
    assert.equal(caps.workspaceSymbolProvider, true);
});

test("the outline: each declaration in source order, a schema's slots under it", { skip: NO_DSC }, async () => {
    const got = (await session([{ id: 2, method: "textDocument/documentSymbol",
                                  params: { textDocument: { uri: APP_URI } } }])).get(2).result;
    assert.deepEqual(got.map((s) => [s.name, s.kind, s.detail]), [
        ["LIMIT", 14, "const"],
        ["Alert", 23, "schema, 2 slots"],
        ["svc.page", 11, "service, no response"],
        ["hot", 12, "rule"],
        ["a hot reading alerts", 24, "test"],
    ], "the import names nothing, and is left out");
    const alert = got[1];
    assert.deepEqual(alert.children.map((s) => [s.name, s.kind, s.detail, span(s.selectionRange)]),
                     [["sensor", 8, "String", "7:4-7:10"], ["level", 8, "Float", "8:4-8:9"]]);
    // A name is selected where it is written, inside its declaration's range.
    assert.equal(span(alert.selectionRange), "6:7-6:12");
    assert.equal(span(got[2].selectionRange), "10:8-10:16");
    for (const s of got) {
        const r = s.range, sel = s.selectionRange;
        assert.ok(r.start.line <= sel.start.line && sel.end.line <= r.end.line, `${s.name} selects inside its range`);
    }
    // A rule's range runs to its last action, not into the blank line after.
    assert.equal(got[3].range.start.line, 14);
    assert.equal(got[3].range.end.line, 17);
});

test("workspace symbols reach the imported library, and a query narrows them", { skip: NO_DSC }, async () => {
    const r = await session([
        { id: 2, method: "workspace/symbol", params: { query: "" } },
        { id: 3, method: "workspace/symbol", params: { query: "lmt" } },
        { id: 4, method: "workspace/symbol", params: { query: "temp" } },
    ]);
    const where = (/** @type {any} */ s) => `${s.location.uri === LIB_URI ? "lib" : "app"}:${s.name}`;
    const all = r.get(2).result.map(where);
    for (const want of ["app:Alert", "app:sensor", "app:hot", "app:LIMIT", "lib:Reading", "lib:temp"])
        assert.ok(all.includes(want), `${want} in ${all}`);
    assert.deepEqual(r.get(3).result.map(where), ["app:LIMIT"], "the query's letters, in order, with gaps");
    const temp = r.get(4).result;
    assert.deepEqual(temp.map((s) => [where(s), s.containerName, s.kind]), [["lib:temp", "Reading", 8]]);
});

test("a query matches its letters in order, whatever their case", () => {
    assert.ok(matches("HeaterOn", "hton"));
    assert.ok(matches("HeaterOn", ""));
    assert.ok(!matches("HeaterOn", "noh"));
    assert.ok(matches("svc.page", "SVCP"));
});
