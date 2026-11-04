// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// `ds lsp` (lib/lsp/): the base protocol's framing, columns three ways, dsc's
// rendered diagnostics read back, and the server driven as an editor drives
// it, over a program compiled and dumped by the lane's compiler for its target
// (compiler.mjs).

import { test } from "node:test";
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";

import { parseDiagnostics } from "../lib/lsp/diagnostics.js";
import { FrameError, MAX_BODY, bodies, frame } from "../lib/lsp/framing.js";
import { fromClient, lines, negotiate, toClient } from "../lib/lsp/positions.js";
import { lspPorts } from "../lib/lsp/ports.js";
import { runLsp } from "../lib/lsp/server.js";
import { main } from "../lib/cli/main.js";
import { NO_COMPILER } from "./compiler.mjs";
import { SCHEMAS, lspChecker, pinnedLspChecker } from "./lsp_schema.mjs";

// Every message the server sends, in every session of this file, is checked
// against LSP's published metaModel (lsp_schema.mjs). What breaks it
// is collected here and judged by the file's last test.
const CHECK = pinnedLspChecker();
/** @type {string[]} */
const VIOLATIONS = [];
/** @param {any[]} fromClient @param {any[]} fromServer */
const record = (fromClient, fromServer) => {
    if (CHECK) VIOLATIONS.push(...CHECK(fromClient, fromServer));
};

const NO_DSC = NO_COMPILER;

/** @param {...(string | Uint8Array)} parts */
async function* chunks(...parts) {
    for (const p of parts) yield typeof p === "string" ? Buffer.from(p, "utf8") : p;
}

/** @param {AsyncIterable<string>} it */
async function all(it) {
    const out = [];
    for await (const x of it) out.push(x);
    return out;
}

test("a message split across chunks waits for the rest; two in one chunk come out apart", async () => {
    const a = frame({ id: 1, x: "é" }), b = frame({ id: 2 });
    assert.match(a, /^Content-Length: 17\r\n\r\n/, "the length is in bytes: é is two");
    const got = await all(bodies(chunks(a.slice(0, 5), a.slice(5, 22), a.slice(22) + b)));
    assert.deepEqual(got.map((s) => JSON.parse(s).id), [1, 2]);
});

test("a Content-Type header is passed over; a header with no Content-Length is refused", async () => {
    const body = '{"id":3}';
    const got = await all(bodies(chunks(`Content-Type: application/vscode-jsonrpc; charset=utf-8\r\ncontent-length: ${body.length}\r\n\r\n${body}`)));
    assert.deepEqual(got, [body]);
    await assert.rejects(all(bodies(chunks("Content-Type: x\r\n\r\n{}"))), FrameError);
});

test("a Content-Length past the limit is refused before its body is read; so is a header that never ends", async () => {
    const big = `Content-Length: ${MAX_BODY + 1}\r\n\r\n`;
    await assert.rejects(all(bodies(chunks(big))), (err) => err instanceof FrameError && /past the/.test(err.message));
    // At the limit, a body is read as any other.
    const body = '{"id":9}';
    assert.deepEqual(await all(bodies(chunks(`Content-Length: ${body.length}\r\n\r\n${body}`), { maxBody: body.length })), [body]);
    await assert.rejects(all(bodies(chunks(`Content-Length: ${body.length + 1}\r\n\r\n${body} `), { maxBody: body.length })),
                         FrameError);
    await assert.rejects(all(bodies(chunks("X-Junk: " + "a".repeat(9000)))), (err) => err instanceof FrameError
                         && /header longer than/.test(err.message));
});

test("the server ends, with status 1 and a line on stderr, on bytes it cannot read as a message", async () => {
    const logged = [];
    const code = await runLsp({ input: chunks(`Content-Length: ${MAX_BODY + 1}\r\n\r\n`), write: () => {},
                                log: (s) => logged.push(s), ports: { dumpAst: () => ({ refused: "" }), compile: () => null } });
    assert.equal(code, 1);
    assert.match(logged.join("\n"), /^ds lsp: a Content-Length of \d+ bytes, past the/m);
});

test("columns: code points where the client takes utf-32, UTF-16 units otherwise", () => {
    const line = "a😀b";  // 😀 is one code point and two UTF-16 units
    assert.equal(negotiate(["utf-16", "utf-32"]), "utf-32");
    assert.equal(negotiate(["utf-8"]), "utf-16");
    assert.equal(negotiate(undefined), "utf-16");
    assert.equal(toClient(line, 2, "utf-16"), 3);
    assert.equal(toClient(line, 2, "utf-32"), 2);
    assert.equal(fromClient(line, 3, "utf-16"), 2);
    // Inside the surrogate pair: the code point it is part of.
    assert.equal(fromClient(line, 2, "utf-16"), 1);
    assert.equal(toClient(line, 5, "utf-16"), 6, "past the end, one unit per missing code point");
    assert.deepEqual(lines("a\r\nb\nc\rd"), ["a", "b", "c", "d"]);
});

test("dsc's rendered diagnostics read back: span, code, hint, related, a span that continues", () => {
    const text = [
        'File "p.ds", line 3, column 5',
        "    emit Nope x: 1",
        "        ^^^^",
        "DS_VALIDATE_UNKNOWN_SCHEMA: no schema `Nope`",
        "  hint: did you mean `Note`?",
        'related: File "p.ds", line 1, column 8',
        "    schema Note:",
        "           ^",
        "  `Note` is declared here",
        "",
        'File "p.ds", line 9, column 1',
        '    """a docstring',
        "    ^^^^^^^^^^^^^^ (continues to line 11, column 4)",
        "DS_VALIDATE_X: something",
        "",
        'File "p.ds", line 40, column 2',
        "DS_VALIDATE_EOF: past the end",
    ].join("\n");
    const [a, b, c] = parseDiagnostics(text);
    assert.deepEqual(a.span, { start: { line: 3, col: 4 }, end: { line: 3, col: 8 } });
    assert.equal(a.code, "DS_VALIDATE_UNKNOWN_SCHEMA");
    assert.equal(a.message, "no schema `Nope`");
    assert.equal(a.hint, "did you mean `Note`?");
    assert.deepEqual(a.related, [{ span: { start: { line: 1, col: 7 }, end: { line: 1, col: 8 } }, message: "`Note` is declared here" }]);
    assert.deepEqual(b.span, { start: { line: 9, col: 0 }, end: { line: 11, col: 3 } });
    assert.equal(b.hint, null);
    // No source line (out of range): one code point at the column.
    assert.deepEqual(c.span, { start: { line: 40, col: 1 }, end: { line: 40, col: 2 } });
    assert.equal(parseDiagnostics("dsc: a note\n").length, 0);
});

const PROGRAM = `use default

schema Reading scope ttl 60_s:
    sensor: String
    temp: Float

schema Alert scope logical:
    sensor: String key

rule hot:
    Reading r where r.temp > 90.0
->
    emit Alert logical sensor: r.sensor
`;

/**
 * An editor's session: the messages it sends, framed, and what the server
 * sent back, parsed.
 * @param {object[]} msgs
 * @param {import("../lib/lsp/server.js").LspPorts} ports
 */
async function session(msgs, ports) {
    let out = "";
    /** @type {string[]} */
    const logged = [];
    const code = await runLsp({ input: chunks(...msgs.map((m) => frame({ jsonrpc: "2.0", ...m }))),
                                write: (s) => { out += s; }, log: (s) => logged.push(s), ports });
    const sent = (await all(bodies(chunks(out)))).map((s) => JSON.parse(s));
    record(msgs.map((m) => ({ jsonrpc: "2.0", ...m })), sent);
    return { code, sent, logged };
}

/** @param {any[]} sent @param {number} id */
const reply = (sent, id) => sent.find((m) => m.id === id);

const URI = pathToFileURL("/work/hot.ds").href;
/** Line and character of `needle`'s first character, its `nth` occurrence. */
function at(needle, nth = 0) {
    const ls = PROGRAM.split("\n");
    let seen = 0;
    for (let line = 0; line < ls.length; line++) {
        let from = 0;
        for (;;) {
            const c = ls[line].indexOf(needle, from);
            if (c < 0) break;
            if (seen++ === nth) return { line, character: c };
            from = c + 1;
        }
    }
    throw new Error(`no ${needle} #${nth}`);
}

test("before initialize a request is refused; exit without shutdown is status 1", async () => {
    const ports = { dumpAst: () => ({ refused: "" }), compile: () => null };
    const { code, sent } = await session([{ id: 1, method: "textDocument/hover", params: {} }, { method: "exit" }], ports);
    assert.equal(reply(sent, 1).error.code, -32002);
    assert.equal(code, 1);
});

test("an unknown request is -32601; an unknown notification is ignored; shutdown then exit is 0", async () => {
    const ports = { dumpAst: () => ({ refused: "" }), compile: () => null };
    const { code, sent } = await session([
        { id: 1, method: "initialize", params: { capabilities: {} } },
        { method: "initialized", params: {} },
        { method: "workspace/didChangeConfiguration", params: {} },
        { id: 2, method: "textDocument/nothing", params: {} },
        { id: 3, method: "shutdown" }, { method: "exit" },
    ], ports);
    assert.equal(reply(sent, 1).result.capabilities.positionEncoding, "utf-16");
    assert.equal(reply(sent, 2).error.code, -32601);
    assert.equal(reply(sent, 3).result, null);
    assert.equal(code, 0);
});

test("a refused compile is published as diagnostics on the document; a clean one clears them", async () => {
    let refuse = true;
    const ports = {
        dumpAst: () => ({ refused: "" }),
        compile: () => (refuse ? 'File "/work/hot.ds", line 3, column 8\n    schema Reading scope ttl 60_s:\n           ^^^^^^^\nDS_VALIDATE_X: no\n  hint: try' : null),
    };
    const open = { method: "textDocument/didOpen", params: { textDocument: { uri: URI, languageId: "ds", version: 1, text: PROGRAM } } };
    const change = { method: "textDocument/didChange", params: { textDocument: { uri: URI, version: 2 }, contentChanges: [{ text: PROGRAM }] } };
    const msgs = [{ id: 1, method: "initialize", params: { capabilities: {} } }, open];
    const first = await session([...msgs, { id: 9, method: "shutdown" }, { method: "exit" }], ports);
    const [pub] = first.sent.filter((m) => m.method === "textDocument/publishDiagnostics");
    assert.equal(pub.params.uri, URI);
    assert.deepEqual(pub.params.diagnostics[0].range, { start: { line: 2, character: 7 }, end: { line: 2, character: 14 } });
    assert.equal(pub.params.diagnostics[0].code, "DS_VALIDATE_X");
    assert.equal(pub.params.diagnostics[0].message, "no\n\nhint: try");
    refuse = false;
    const second = await session([...msgs, change, { id: 9, method: "shutdown" }, { method: "exit" }], ports);
    const pubs = second.sent.filter((m) => m.method === "textDocument/publishDiagnostics");
    assert.deepEqual(pubs.map((p) => p.params.diagnostics.length), [0, 0]);
});

// An edit is analysed when typing settles, not per keystroke; a
// request other than completion or signature help first catches up.
test("a burst of changes is analysed once: when a request needs it, or when typing settles", async () => {
    let compiles = 0;
    const ports = { dumpAst: () => ({ refused: "" }), compile: () => { compiles++; return null; } };
    const open = { method: "textDocument/didOpen", params: { textDocument: { uri: URI, languageId: "ds", version: 1, text: PROGRAM } } };
    const change = (/** @type {number} */ v) => ({ method: "textDocument/didChange",
        params: { textDocument: { uri: URI, version: v }, contentChanges: [{ text: PROGRAM + "#".repeat(v) }] } });
    const position = { textDocument: { uri: URI }, position: { line: 0, character: 0 } };
    /**
     * The server's replies, its publications and the analyses, to messages
     * sent with a pause where `null` stands.
     * @param {Array<object | null>} msgs
     */
    const drive = async (msgs) => {
        compiles = 0;
        async function* input() {
            for (const m of msgs) {
                if (m === null) await new Promise((r) => setTimeout(r, 60));
                else yield Buffer.from(frame({ jsonrpc: "2.0", ...m }));
            }
        }
        let out = "";
        const code = await runLsp({ input: input(), write: (s) => { out += s; }, log: () => {}, ports, settleMs: 20 });
        const sent = (await all(bodies(chunks(out)))).map((s) => JSON.parse(s));
        record(msgs.filter((m) => m !== null), sent);
        return { code, sent, compiles };
    };
    const init = { id: 1, method: "initialize", params: { capabilities: {} } };
    const end = [{ id: 9, method: "shutdown" }, { method: "exit" }];
    const pubs = (/** @type {any[]} */ sent) => sent.filter((m) => m.method === "textDocument/publishDiagnostics").length;

    // Typing, and completion asked for while it goes on: nothing analysed
    // until the hover, which asks about the text as it is.
    const a = await drive([init, open, change(2), change(3),
                           { id: 2, method: "textDocument/completion", params: position }, change(4),
                           { id: 3, method: "textDocument/hover", params: position }, ...end]);
    assert.equal(a.code, 0);
    assert.equal(a.compiles, 2, "the open, then the three changes once");
    assert.equal(pubs(a.sent), 2);
    const order = a.sent.map((m) => m.id ?? m.method);
    assert.ok(order.indexOf(2) < order.lastIndexOf("textDocument/publishDiagnostics"), "completion did not wait");
    assert.ok(order.lastIndexOf("textDocument/publishDiagnostics") < order.indexOf(3), "the hover did");

    // Typing that stops: analysed when it settles, before anything asks.
    const b = await drive([init, open, change(2), change(3), null, ...end]);
    assert.equal(b.compiles, 2);
    const ord = b.sent.map((m) => m.id ?? m.method);
    assert.ok(ord.lastIndexOf("textDocument/publishDiagnostics") < ord.indexOf(9), "published before the shutdown");

    // A library changed on disk: every open document again, once settled.
    const c = await drive([init, open, { method: "workspace/didChangeWatchedFiles", params: { changes: [] } }, null, ...end]);
    assert.equal(c.compiles, 2);
});

test("hover and definition over the branch's dsc: schemas, bindings and slots", { skip: NO_DSC }, async () => {
    const jsBinding = await import(new URL("../../../bindings/js/lib/index.js", import.meta.url).href);
    const ports = lspPorts(jsBinding, await jsBinding.open({ target: process.env.DS_JS_TARGET ?? "native" }));
    const ask =(/** @type {number} */ id, /** @type {string} */ method, /** @type {{ line: number, character: number }} */ position) =>
        ({ id, method, params: { textDocument: { uri: URI }, position } });
    const { code, sent, logged } = await session([
        { id: 1, method: "initialize", params: { capabilities: { general: { positionEncodings: ["utf-32"] } } } },
        { method: "textDocument/didOpen", params: { textDocument: { uri: URI, languageId: "ds", version: 1, text: PROGRAM } } },
        ask(2, "textDocument/hover", at("Reading", 1)),       // in the pattern
        ask(3, "textDocument/definition", at("Reading", 1)),
        ask(4, "textDocument/hover", at("temp", 1)),          // r.temp
        ask(5, "textDocument/definition", at("temp", 1)),
        ask(6, "textDocument/definition", at("r.sensor")),    // the binding r
        ask(7, "textDocument/definition", at("sensor: r")),   // emit Alert sensor: …
        ask(8, "textDocument/hover", at("emit")),             // a keyword: nothing
        { id: 9, method: "shutdown" }, { method: "exit" },
    ], ports);
    assert.deepEqual(logged, [], "the server logged nothing");
    assert.equal(code, 0);
    const pub = sent.find((m) => m.method === "textDocument/publishDiagnostics");
    assert.ok(pub, "diagnostics were published");
    assert.deepEqual(pub.params.diagnostics, [], "the program compiles");
    for (const [id, what] of [[2, "hover, Reading"], [3, "definition, Reading"], [4, "hover, r.temp"], [5, "definition, r.temp"],
                              [6, "definition, r"], [7, "definition, sensor: in the emit"]])
        assert.ok(reply(sent, id)?.result, `${what}: got ${JSON.stringify(reply(sent, id))}`);
    assert.match(reply(sent, 2).result.contents.value, /schema Reading scope ttl 60_s:\n {4}sensor: String\n {4}temp: Float/);
    assert.deepEqual(reply(sent, 3).result.range, { start: { line: 2, character: 7 }, end: { line: 2, character: 14 } });
    assert.match(reply(sent, 4).result.contents.value, /temp: Float {2}# in Reading/);
    assert.deepEqual(reply(sent, 5).result.range.start, { line: 4, character: 4 });
    assert.deepEqual(reply(sent, 6).result.range, { start: { line: 10, character: 12 }, end: { line: 10, character: 13 } });
    assert.deepEqual(reply(sent, 7).result.range.start, { line: 7, character: 4 }, "Alert's slot");
    assert.equal(reply(sent, 8).result, null);
});

// A schema's hover is its declaration as written: the ttl scope with
// its duration, and each slot with its markers and its nullability. The path:
// lsp/analysis.js `hoverText` and `schemaText`, over dsc's tree. Before the
// fix the ttl scope read `scope ttl:`, which is not DS, and every marker was
// dropped.
test("a schema's hover is its declaration: the ttl duration, and each slot's markers", { skip: NO_DSC }, async () => {
    const jsBinding = await import(new URL("../../../bindings/js/lib/index.js", import.meta.url).href);
    const ports = lspPorts(jsBinding, await jsBinding.open({ target: process.env.DS_JS_TARGET ?? "native" }));
    const text =`use default

schema Reading scope ttl 90_s:
    sensor: String
    note: String?

schema Level scope logical:
    sensor: String key
    value: Int mutable

schema Seen scope logical:
    sensor: String key

rule hot:
    Reading r
    Level l where l.sensor == r.sensor
->
    emit Seen logical sensor: r.sensor
`;
    const ls = text.split("\n");
    /** @param {string} needle @param {number} nth */
    const pos = (needle, nth = 0) => {
        let seen = 0;
        for (let line = 0; line < ls.length; line++)
            for (let c = ls[line].indexOf(needle); c >= 0; c = ls[line].indexOf(needle, c + 1))
                if (seen++ === nth) return { line, character: c };
        throw new Error(needle);
    };
    const hover = (/** @type {number} */ id, /** @type {{ line: number, character: number }} */ position) =>
        ({ id, method: "textDocument/hover", params: { textDocument: { uri: URI }, position } });
    const { code, sent } = await session([
        { id: 1, method: "initialize", params: { capabilities: {} } },
        { method: "textDocument/didOpen", params: { textDocument: { uri: URI, languageId: "ds", version: 1, text } } },
        hover(2, pos("Reading")), hover(3, pos("Level")), hover(4, pos("Seen", 1)), hover(5, pos("l where")),
        { id: 9, method: "shutdown" }, { method: "exit" },
    ], ports);
    assert.equal(code, 0);
    const shown = (/** @type {number} */ id) => /** @type {string} */ (reply(sent, id)?.result?.contents?.value ?? "");
    assert.match(shown(2), /```ds\nschema Reading scope ttl 90_s:\n {4}sensor: String\n {4}note: String\?\n```/);
    assert.match(shown(3), /```ds\nschema Level scope logical:\n {4}sensor: String key\n {4}value: Int mutable\n```/);
    assert.match(shown(4), /```ds\nschema Seen scope logical:\n {4}sensor: String key\n```/, "in an emit");
    assert.match(shown(5), /schema Level scope logical:\n {4}sensor: String key\n {4}value: Int mutable/, "a binding's hover");
});

test("`ds lsp` takes -L and refuses any other option", async () => {
    let err = "";
    const io = { stdout: () => {}, stderr: (/** @type {string} */ s) => { err += s; }, input: chunks() };
    assert.equal(await main(["lsp", "--nope"], io), 2);
    assert.match(err, /lsp: no option --nope/);
});

// ── the lifecycle, as LSP 3.17 states it ───────────────────────────────────

const STUB = { dumpAst: () => ({ refused: "" }), compile: () => null };

test("lifecycle: a notification before initialize is dropped, answered by nothing", async () => {
    // LSP 3.17, `initialize`: "Notifications should be dropped, except for
    // the exit notification."
    const { code, sent } = await session([
        { method: "textDocument/didOpen", params: { textDocument: { uri: URI, languageId: "ds", version: 1, text: PROGRAM } } },
        { id: 1, method: "initialize", params: { capabilities: {} } },
        { id: 2, method: "shutdown" }, { method: "exit" },
    ], STUB);
    assert.equal(code, 0);
    assert.deepEqual(sent.filter((m) => m.method === "textDocument/publishDiagnostics"), [],
                     "the open was dropped, so there is no document to publish for");
});

test("lifecycle: after shutdown, a request other than exit is InvalidRequest", async () => {
    // LSP 3.17, `shutdown`: "If a server receives requests after a shutdown
    // request those requests should error with InvalidRequest."
    const { code, sent } = await session([
        { id: 1, method: "initialize", params: { capabilities: {} } }, { method: "initialized", params: {} },
        { id: 2, method: "shutdown" },
        { id: 3, method: "textDocument/hover", params: { textDocument: { uri: URI }, position: { line: 0, character: 0 } } },
        { id: 4, method: "shutdown" },
        { method: "exit" },
    ], STUB);
    assert.equal(code, 0, "shutdown then exit is 0, whatever came between");
    assert.equal(reply(sent, 3)?.error?.code, -32600, `hover after shutdown: ${JSON.stringify(reply(sent, 3))}`);
    assert.equal(reply(sent, 4)?.error?.code, -32600, `a second shutdown: ${JSON.stringify(reply(sent, 4))}`);
});

test("lifecycle: `$/` messages: an unknown notification is ignored, an unknown request is MethodNotFound, a cancel of nothing is harmless", async () => {
    // LSP 3.17, "$ Notifications and Requests": a notification the server
    // does not implement is ignored; a request it does not implement fails
    // with MethodNotFound.
    const { code, sent } = await session([
        { id: 1, method: "initialize", params: { capabilities: {} } }, { method: "initialized", params: {} },
        { method: "$/somethingNew", params: { x: 1 } },
        { method: "$/cancelRequest", params: { id: 77 } },
        { method: "$/setTrace", params: { value: "off" } },
        { id: 2, method: "$/somethingNew", params: {} },
        { id: 3, method: "shutdown" }, { method: "exit" },
    ], STUB);
    assert.equal(code, 0);
    assert.equal(reply(sent, 2)?.error?.code, -32601);
    assert.ok(!sent.some((m) => m.id === 77), "a cancel of a request never made answers nothing");
});

test("lifecycle: every request is answered exactly once, and no notification is answered", async () => {
    const msgs = [
        { id: 1, method: "initialize", params: { capabilities: {} } }, { method: "initialized", params: {} },
        { method: "textDocument/didOpen", params: { textDocument: { uri: URI, languageId: "ds", version: 1, text: PROGRAM } } },
        { id: 2, method: "textDocument/hover", params: { textDocument: { uri: URI }, position: { line: 0, character: 0 } } },
        { id: "three", method: "textDocument/documentSymbol", params: { textDocument: { uri: URI } } },
        { id: 4, method: "textDocument/nothing", params: {} },
        { method: "textDocument/didClose", params: { textDocument: { uri: URI } } },
        { id: 5, method: "shutdown" }, { method: "exit" },
    ];
    const { sent } = await session(msgs, STUB);
    const responses = sent.filter((m) => m.method === undefined);
    const ids = msgs.filter((m) => "id" in m).map((m) => m.id);
    assert.deepEqual(responses.map((m) => m.id).sort(), [...ids].sort(), "each request's id, once, and nothing else");
});

// ── capability honesty ─────────────────────────────────────────────────────
//
// What `initialize` answers is a promise the client acts on: it sends the
// requests a server capability gates only when the capability is there. So
// each capability is honest when every request it gates is served if it is
// advertised and refused as unknown (-32601) if it is not, an absent one
// being off. And the other way: the server sends the client no request the
// client's own capabilities did not enable.
//
// GATED is LSP 3.17's `ServerCapabilities`: each property that gates
// requests, and the requests, each with whether the advertised value turns it
// on (a sub-option, as `resolveProvider`, gates its own request). UNGATED are
// the properties that gate no request.

/** @type {(v: any) => boolean} */
const on = (v) => v !== undefined && v !== null && v !== false;
/** @type {Record<string, Array<[string, (v: any) => boolean]>>} */
const GATED = {
    hoverProvider: [["textDocument/hover", on]],
    declarationProvider: [["textDocument/declaration", on]],
    definitionProvider: [["textDocument/definition", on]],
    typeDefinitionProvider: [["textDocument/typeDefinition", on]],
    implementationProvider: [["textDocument/implementation", on]],
    referencesProvider: [["textDocument/references", on]],
    documentHighlightProvider: [["textDocument/documentHighlight", on]],
    documentSymbolProvider: [["textDocument/documentSymbol", on]],
    codeActionProvider: [["textDocument/codeAction", on], ["codeAction/resolve", (v) => v?.resolveProvider === true]],
    codeLensProvider: [["textDocument/codeLens", on], ["codeLens/resolve", (v) => v?.resolveProvider === true]],
    documentLinkProvider: [["textDocument/documentLink", on], ["documentLink/resolve", (v) => v?.resolveProvider === true]],
    colorProvider: [["textDocument/documentColor", on], ["textDocument/colorPresentation", on]],
    documentFormattingProvider: [["textDocument/formatting", on]],
    documentRangeFormattingProvider: [["textDocument/rangeFormatting", on]],
    documentOnTypeFormattingProvider: [["textDocument/onTypeFormatting", on]],
    renameProvider: [["textDocument/rename", on], ["textDocument/prepareRename", (v) => v?.prepareProvider === true]],
    foldingRangeProvider: [["textDocument/foldingRange", on]],
    selectionRangeProvider: [["textDocument/selectionRange", on]],
    executeCommandProvider: [["workspace/executeCommand", on]],
    callHierarchyProvider: [["textDocument/prepareCallHierarchy", on], ["callHierarchy/incomingCalls", on],
                            ["callHierarchy/outgoingCalls", on]],
    linkedEditingRangeProvider: [["textDocument/linkedEditingRange", on]],
    semanticTokensProvider: [["textDocument/semanticTokens/full", (v) => on(v?.full)],
                             ["textDocument/semanticTokens/full/delta", (v) => on(v?.full?.delta)],
                             ["textDocument/semanticTokens/range", (v) => on(v?.range)]],
    monikerProvider: [["textDocument/moniker", on]],
    typeHierarchyProvider: [["textDocument/prepareTypeHierarchy", on], ["typeHierarchy/supertypes", on],
                            ["typeHierarchy/subtypes", on]],
    inlineValueProvider: [["textDocument/inlineValue", on]],
    inlayHintProvider: [["textDocument/inlayHint", on], ["inlayHint/resolve", (v) => v?.resolveProvider === true]],
    diagnosticProvider: [["textDocument/diagnostic", on], ["workspace/diagnostic", (v) => v?.workspaceDiagnostics === true]],
    workspaceSymbolProvider: [["workspace/symbol", on], ["workspaceSymbol/resolve", (v) => v?.resolveProvider === true]],
    completionProvider: [["textDocument/completion", on], ["completionItem/resolve", (v) => v?.resolveProvider === true]],
    signatureHelpProvider: [["textDocument/signatureHelp", on]],
};
const UNGATED = new Set(["positionEncoding", "textDocumentSync", "notebookDocumentSync", "workspace", "experimental"]);

/**
 * The requests a server may send whatever the client declared; every other
 * one needs the client capability named. LSP 3.17's server-to-client
 * requests.
 * @type {Record<string, ((c: any) => boolean) | null>}
 */
const SERVER_REQUESTS = {
    "window/showMessageRequest": null,
    "window/showDocument": (c) => c?.window?.showDocument?.support === true,
    "window/workDoneProgress/create": (c) => c?.window?.workDoneProgress === true,
    "workspace/configuration": (c) => c?.workspace?.configuration === true,
    "workspace/workspaceFolders": (c) => c?.workspace?.workspaceFolders === true,
    "workspace/applyEdit": (c) => c?.workspace?.applyEdit === true,
    "client/registerCapability": (c) => JSON.stringify(c ?? {}).includes('"dynamicRegistration":true'),
    "client/unregisterCapability": (c) => JSON.stringify(c ?? {}).includes('"dynamicRegistration":true'),
    "workspace/semanticTokens/refresh": (c) => c?.workspace?.semanticTokens?.refreshSupport === true,
    "workspace/codeLens/refresh": (c) => c?.workspace?.codeLens?.refreshSupport === true,
    "workspace/inlayHint/refresh": (c) => c?.workspace?.inlayHint?.refreshSupport === true,
    "workspace/inlineValue/refresh": (c) => c?.workspace?.inlineValue?.refreshSupport === true,
    "workspace/diagnostic/refresh": (c) => c?.workspace?.diagnostics?.refreshSupport === true,
};

test("capability honesty: every request a server capability gates is served iff it is advertised", async () => {
    const ports = { dumpAst: () => ({ refused: "" }), compile: () => null };
    const open = { method: "textDocument/didOpen", params: { textDocument: { uri: URI, languageId: "ds", version: 1, text: PROGRAM } } };
    const first = await session([{ id: 1, method: "initialize", params: { capabilities: {} } }, { id: 2, method: "shutdown" },
                                 { method: "exit" }], ports);
    const caps = reply(first.sent, 1).result.capabilities;
    const loose = Object.keys(caps).filter((k) => !(k in GATED) && !UNGATED.has(k));
    assert.deepEqual(loose, [], "a capability with no row: say what it gates, and test it");

    const asks = Object.entries(GATED).flatMap(([k, rows]) => rows.map(([method, gate]) => ({ k, method, served: gate(caps[k]) })));
    assert.ok(asks.some((a) => a.served), "the server advertises requests: this check runs over them");
    const position = { textDocument: { uri: URI }, position: { line: 0, character: 0 } };
    const { sent } = await session([
        { id: 1, method: "initialize", params: { capabilities: {} } }, { method: "initialized", params: {} }, open,
        ...asks.map((a, i) => ({ id: 100 + i, method: a.method, params: position })),
        { id: 2, method: "shutdown" }, { method: "exit" },
    ], ports);
    /** @type {string[]} */
    const wrong = [];
    asks.forEach((a, i) => {
        const r = reply(sent, 100 + i);
        if (r === undefined) wrong.push(`${a.method}: no response`);
        else if (a.served && r.error?.code === -32601) wrong.push(`${a.method} (${a.k} advertised): refused as unknown`);
        else if (!a.served && r.error?.code !== -32601)
            wrong.push(`${a.method} (${a.k} not advertised): ${r.error ? `error ${r.error.code}` : "served"}`);
    });
    assert.deepEqual(wrong, []);
});

test("capability honesty: the server sends no request the client's capabilities did not enable", async () => {
    const ports = { dumpAst: () => ({ refused: "" }), compile: () => null };
    const open = { method: "textDocument/didOpen", params: { textDocument: { uri: URI, languageId: "ds", version: 1, text: PROGRAM } } };
    const change = { method: "textDocument/didChange", params: { textDocument: { uri: URI, version: 2 }, contentChanges: [{ text: PROGRAM }] } };
    const clientCaps = {};
    const { sent } = await session([
        { id: 1, method: "initialize", params: { capabilities: clientCaps } }, { method: "initialized", params: {} }, open, change,
        { method: "workspace/didChangeWatchedFiles", params: { changes: [] } },
        { id: 2, method: "shutdown" }, { method: "exit" },
    ], ports);
    const requests = sent.filter((m) => typeof m.method === "string" && "id" in m);
    const unenabled = requests.filter((m) => {
        const gate = SERVER_REQUESTS[m.method];
        return gate === undefined ? true : gate !== null && !gate(clientCaps);
    }).map((m) => m.method);
    assert.deepEqual(unenabled, [], "a request the client did not say it can take");
});

// ── the published metaModel ────────────────────────────────────────────────

test("the js gate hands the suite the pinned metaModel", () => {
    // In the gate, a missing metaModel is the lane's defect, not a skip: a
    // check that runs over nothing reads as a pass.
    if (process.env.DS_JS_FIXTURES) assert.ok(SCHEMAS, "DS_JS_FIXTURES is set and DS_PROTOCOL_SCHEMAS is not");
});

// The checker fires: what breaks the metaModel, each one way, is refused,
// and what keeps it is not. Over the pinned metaModel itself.
test("the metaModel checker refuses what breaks it and passes what keeps it", { skip: SCHEMAS ? false : "no DS_PROTOCOL_SCHEMAS" }, () => {
    const check = /** @type {(c: any[], s: any[]) => string[]} */ (CHECK);
    const asked = [{ jsonrpc: "2.0", id: 1, method: "initialize", params: { capabilities: {} } },
                   { jsonrpc: "2.0", id: 2, method: "shutdown" }];
    const range = { start: { line: 0, character: 0 }, end: { line: 0, character: 1 } };
    const pub = (/** @type {any} */ params) => ({ jsonrpc: "2.0", method: "textDocument/publishDiagnostics", params });
    /** @param {any} m */
    const ok = (m) => assert.deepEqual(check(asked, [m]), [], JSON.stringify(m));
    /** @param {any} m @param {string} says */
    const bad = (m, says) => {
        const got = check(asked, [m]);
        assert.ok(got.some((v) => v.includes(says)), `${JSON.stringify(m)}: want "${says}", got ${JSON.stringify(got)}`);
    };
    ok({ jsonrpc: "2.0", id: 1, result: { capabilities: { hoverProvider: true }, serverInfo: { name: "ds" } } });
    ok({ jsonrpc: "2.0", id: 2, result: null });
    ok({ jsonrpc: "2.0", id: 2, error: { code: -32601, message: "no" } });
    ok(pub({ uri: "file:///a.ds", diagnostics: [{ range, message: "m", severity: 1, code: "DS_X", extra: 1 }] }));
    ok({ jsonrpc: "2.0", method: "ds/whatever", params: { anything: 1 } });
    bad({ jsonrpc: "2.0", id: 2, result: 1 }, "is not null");
    bad({ jsonrpc: "2.0", id: 1, result: {} }, "lacks `capabilities`");
    bad(pub({ uri: "file:///a.ds" }), "lacks `diagnostics`");
    bad(pub({ uri: "file:///a.ds", diagnostics: [{ range, message: "m", severity: 7 }] }), "is no DiagnosticSeverity");
    bad(pub({ uri: "file:///a.ds", diagnostics: [{ range: { ...range, start: { line: -1, character: 0 } }, message: "m" }] }),
        "is not uinteger");
    bad({ jsonrpc: "2.0", id: 2, result: null, error: { code: 1, message: "x" } }, "both `result` and `error`");
    bad({ jsonrpc: "2.0", id: 2, error: { code: "x", message: "x" } }, "error.code");
    bad({ jsonrpc: "2.0", id: 99, result: null }, "answers no request");
    bad({ jsonrpc: "1.0", id: 2, result: null }, "not \"2.0\"");
    bad({ jsonrpc: "2.0", method: "textDocument/didOpen", params: {} }, "travels clientToServer");
});

test("the metaModel checker refuses a type kind it does not know, rather than pass it over", () => {
    const model = { requests: [{ method: "m", messageDirection: "clientToServer", result: { kind: "nope" } }],
                    notifications: [], structures: [], enumerations: [], typeAliases: [] };
    assert.throws(() => lspChecker(model)([{ id: 1, method: "m" }], [{ jsonrpc: "2.0", id: 1, result: 1 }]), /kind `nope`/);
});

// Last in the file, so every session above has been read: each message the
// server sent kept the metaModel.
test("every message ds lsp sent in this file keeps LSP's metaModel", { skip: SCHEMAS ? false : "no DS_PROTOCOL_SCHEMAS" }, () => {
    assert.deepEqual([...new Set(VIOLATIONS)], []);
});
