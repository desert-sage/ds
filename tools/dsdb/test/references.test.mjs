// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// `ds lsp`'s references and rename (lib/lsp/references.js), across a
// two-file program: a rule file and the library it imports a schema from.
// The library is served from memory through the server's `read` port; both
// files are dumped by the lane's compiler for its target (compiler.mjs).

import { test } from "node:test";
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";

import { bodies, frame } from "../lib/lsp/framing.js";
import { runLsp } from "../lib/lsp/server.js";
import { NO_COMPILER as NO_DSC, dumpAst } from "./compiler.mjs";

const APP = `use default

from sensors import Reading

schema Alert scope logical:
    sensor: String key

rule hot:
    Reading r where r.temp > 90.0
->
    emit Alert logical sensor: r.sensor

rule cold:
    Reading c where c.temp < 0.0
->
    emit Alert logical sensor: c.sensor
`;

const LIB = `schema Reading scope ttl 60_s:
    sensor: String
    temp: Float
`;

const APP_URI = pathToFileURL("/work/app.ds").href;
const LIB_URI = pathToFileURL("/work/sensors.ds").href;

/** The ports: the real dump, no diagnostics, the library from memory. */
const ports = {
    dumpAst,
    compile: () => null,
    /** @param {string} path */
    read: (path) => (path === "/work/sensors.ds" ? LIB : null),
};

/** Where `needle`'s `nth` occurrence starts in APP. */
function at(needle, nth = 0) {
    const ls = APP.split("\n");
    let seen = 0;
    for (let line = 0; line < ls.length; line++)
        for (let c = ls[line].indexOf(needle); c >= 0; c = ls[line].indexOf(needle, c + 1))
            if (seen++ === nth) return { line, character: c };
    throw new Error(`no ${needle} #${nth}`);
}

/**
 * Open APP in a workspace and ask; the answers by id.
 * @param {object[]} asks
 * @param {string} [root]  the workspace folder's URI
 */
async function session(asks, root = pathToFileURL("/work").href) {
    const msgs = [
        { id: 1, method: "initialize", params: { capabilities: {}, rootUri: root } },
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

/** @param {number} id @param {string} method @param {{ line: number, character: number }} position @param {object} [more] */
const ask = (id, method, position, more = {}) => ({ id, method, params: { textDocument: { uri: APP_URI }, position, ...more } });

/** A location as `file:line:start-end`, sorted. @param {any[]} locs */
const where = (locs) => locs.map((l) => `${l.uri === LIB_URI ? "lib" : l.uri === APP_URI ? "app" : l.uri}:${l.range.start.line}:${l.range.start.character}-${l.range.end.character}`).sort();

test("a schema's references span the files: its declaration in the library, the import, each pattern", { skip: NO_DSC }, async () => {
    const r = await session([
        ask(2, "textDocument/references", at("Reading", 1), { context: { includeDeclaration: true } }),
        ask(3, "textDocument/references", at("Reading", 1), { context: { includeDeclaration: false } }),
    ]);
    assert.deepEqual(where(r.get(2).result), ["app:13:4-11", "app:2:20-27", "app:8:4-11", "lib:0:7-14"]);
    assert.deepEqual(where(r.get(3).result), ["app:13:4-11", "app:2:20-27", "app:8:4-11"]);
});

test("a slot's references: read through any binding of its schema, in every rule", { skip: NO_DSC }, async () => {
    const r = await session([ask(2, "textDocument/references", at("temp"), { context: { includeDeclaration: true } })]);
    assert.deepEqual(where(r.get(2).result), ["app:13:22-26", "app:8:22-26", "lib:2:4-8"]);
});

test("a slot an emit writes by keyword is the emitted schema's, not a same-named slot read beside it", { skip: NO_DSC }, async () => {
    const r = await session([ask(2, "textDocument/references", at("sensor: r"), { context: { includeDeclaration: true } })]);
    assert.deepEqual(where(r.get(2).result), ["app:10:23-29", "app:15:23-29", "app:5:4-10"]);
});

test("a binding's references are its rule's alone", { skip: NO_DSC }, async () => {
    const r = await session([ask(2, "textDocument/references", at("r where"), { context: { includeDeclaration: true } })]);
    assert.deepEqual(where(r.get(2).result), ["app:10:31-32", "app:8:12-13", "app:8:20-21"]);
});

test("rename edits every site, in the workspace", { skip: NO_DSC }, async () => {
    const r = await session([
        ask(2, "textDocument/rename", at("Alert", 1), { newName: "Warning" }),
        ask(3, "textDocument/rename", at("temp"), { newName: "celsius" }),
    ]);
    const alert = r.get(2).result.changes;
    assert.deepEqual(Object.keys(alert), [APP_URI]);
    assert.deepEqual(alert[APP_URI].map((/** @type {any} */ e) => `${e.range.start.line}:${e.range.start.character}`).sort(), ["10:9", "15:9", "4:7"]);
    assert.ok(alert[APP_URI].every((/** @type {any} */ e) => e.newText === "Warning"));
    // The slot is declared in the library: both files change.
    assert.deepEqual(Object.keys(r.get(3).result.changes).sort(), [APP_URI, LIB_URI].sort());
});

test("rename is refused: outside the workspace, to a reserved word, to what is no name", { skip: NO_DSC }, async () => {
    const elsewhere = await session([ask(2, "textDocument/rename", at("Reading", 1), { newName: "Sample" })], pathToFileURL("/elsewhere").href);
    assert.equal(elsewhere.get(2).error.code, -32803);
    assert.match(elsewhere.get(2).error.message, /outside the workspace/);
    const r = await session([
        ask(2, "textDocument/rename", at("Alert", 1), { newName: "rule" }),
        ask(3, "textDocument/rename", at("Alert", 1), { newName: "1x" }),
        ask(4, "textDocument/rename", at("emit"), { newName: "x" }),
    ]);
    assert.match(r.get(2).error.message, /reserved word/);
    assert.match(r.get(3).error.message, /not a DS name/);
    assert.match(r.get(4).error.message, /nothing the program declares/);
});
