// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// `ds lsp`'s semantic tokens (lib/lsp/semantic.js). The lexical split
// and the reserved words' classes need no compiler; the program's names do: a
// rule file and the library it imports a schema from, dumped by the lane's
// compiler for its target (compiler.mjs), the library served from memory
// through the server's `read` port.

import { test } from "node:test";
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";

import { bodies, frame } from "../lib/lsp/framing.js";
import { runLsp } from "../lib/lsp/server.js";
import { encode, LEGEND, scan, tokens } from "../lib/lsp/semantic.js";
import { NO_COMPILER as NO_DSC, dumpAst } from "./compiler.mjs";

/** A token as `type` or `type+mod+mod`, modifiers in legend order. @param {{ type: number, mods: number }} t */
const name = (t) => [LEGEND.tokenTypes[t.type], ...LEGEND.tokenModifiers.filter((_, i) => t.mods & (1 << i))].join("+");

/** Each lexeme as `kind:text`. @param {string} text */
const lexed = (text) => scan(text.split("\n")).map((x) => `${x.kind}:${x.text}`);

/** The tokens of a text with no tree, as `text=type+mods`. @param {string} text */
const coloured = (text) => {
    const ls = text.split("\n");
    return tokens(ls, null).map((t) => `${[...ls[t.line - 1]].slice(t.start, t.end).join("")}=${name(t)}`);
};

test("the split: a comment runs to the line's end, and a word in it or in a string is not a name", () => {
    assert.deepEqual(lexed('emit X msg: "emit # not" # emit too'),
                     ["name:emit", "name:X", "name:msg", "punct::", 'string:"emit # not"', "comment:# emit too"]);
    assert.deepEqual(lexed('log "a \\" b" x'), ["name:log", 'string:"a \\" b"', "name:x"], "an escaped quote does not end it");
    assert.deepEqual(lexed('log "open'), ["name:log", 'string:"open'], "an unclosed string runs to the line's end");
});

test("the split: a triple-quoted string is a piece on each line it spans", () => {
    const xs = scan(['x """one', "two # no", 'three""" y']);
    assert.deepEqual(xs.map((x) => `${x.line}:${x.kind}:${x.text}`),
                     ['1:name:x', '1:string:"""one', "2:string:two # no", '3:string:three"""', "3:name:y"]);
});

test("the split: a numeric or unit literal is one piece, its suffix included ([LLEX.11.3.1], [LLEX.12])", () => {
    for (const lit of ["30s", "30_s", "23_000_m", "23°C", "45′", "100km", "1e6", "1.5e-3_ms", "1e6_s", "0x1F_FF", "0b1010", "12.5", "5µs"])
        assert.deepEqual(lexed(lit), [`number:${lit}`], lit);
    assert.deepEqual(lexed("r.temp > 3.0"), ["name:r", "punct:.", "name:temp", "punct:>", "number:3.0"]);
    assert.deepEqual(lexed("-5"), ["punct:-", "number:5"], "the minus is its own token ([LLEX.11.4.1])");
});

test("a reserved word is coloured by its class ([LLEX.9.8]), with no tree", () => {
    assert.deepEqual(coloured("schema A scope logical:"),
                     ["schema=keyword", "scope=keyword+clause", "logical=keyword+clause"]);
    assert.deepEqual(coloured("    emit A x: a and not b or true"),
                     ["emit=keyword+action", "and=operator", "not=operator", "or=operator", "true=keyword+constant"]);
});

test("a builtin is a function where it is called, and a builtin type a type", () => {
    assert.deepEqual(coloured("x: Float where abs(y) > 0 and Json"),
                     ["Float=type+defaultLibrary", "where=keyword+clause", "abs=function+defaultLibrary",
                      "0=number", "and=operator", "Json=type+defaultLibrary"]);
    assert.deepEqual(coloured("abs"), [], "a builtin's name not called is not coloured as one");
    assert.deepEqual(coloured("math.sqrt(x)"), [], "a module member is reached only through an import ([LIMP.3.3.4])");
});

test("the encoding: relative lines and starts, lengths as the client counts", () => {
    const ls = ['"𝔸" emit', "  log"];
    const toks = tokens(ls, null);
    // UTF-16: 𝔸 is two units, so the string is four long and `emit` starts at 5.
    assert.deepEqual(encode(toks, ls, "utf-16"), [0, 0, 4, 9, 0, 0, 5, 4, 7, 8, 1, 2, 3, 7, 8]);
    assert.deepEqual(encode(toks, ls, "utf-32"), [0, 0, 3, 9, 0, 0, 4, 4, 7, 8, 1, 2, 3, 7, 8]);
});

const APP = `use default

from sensors import Reading
import math

const LIMIT = 90.0

schema Alert scope logical:
    sensor: String key
    level: Float mutable

service svc.page:
    kwarg who: String
    no response

rule hot:
    Reading r where r.temp > LIMIT and math.sqrt(r.temp) > 3.0
->
    emit Alert logical sensor: r.sensor level: abs(r.temp)
`;

const LIB = `schema Reading scope ttl 60_s:
    sensor: String
    temp: Float
`;

const APP_URI = pathToFileURL("/work/app.ds").href;

const ports = {
    dumpAst,
    compile: () => null,
    /** @param {string} path */
    read: (path) => (path === "/work/sensors.ds" ? LIB : null),
};

/** Open APP and ask; the answers by id. @param {object[]} asks */
async function session(asks, initializationOptions = {}) {
    const msgs = [
        { id: 1, method: "initialize", params: { capabilities: {}, rootUri: pathToFileURL("/work").href, initializationOptions } },
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

test("the server gives its legend, and answers signature help and a builtin's hover over the protocol", { skip: NO_DSC }, async () => {
    const r = await session([
        { id: 2, method: "textDocument/signatureHelp", params: { textDocument: { uri: APP_URI }, position: { line: 18, character: 51 } } },
        { id: 3, method: "textDocument/hover", params: { textDocument: { uri: APP_URI }, position: { line: 18, character: 48 } } },
        { id: 4, method: "textDocument/hover", params: { textDocument: { uri: APP_URI }, position: { line: 16, character: 45 } } },
    ], { docs: "site" });
    const caps = r.get(1).result.capabilities;
    assert.deepEqual(caps.semanticTokensProvider.legend, LEGEND);
    assert.equal(caps.semanticTokensProvider.full, true);
    assert.deepEqual(caps.signatureHelpProvider.triggerCharacters, ["(", ","]);
    assert.deepEqual(r.get(2).result.signatures.map((/** @type {any} */ s) => s.label),
                     ["abs(x: Int) → Int", "abs(x: Float) → Float"], "inside `abs(r.temp)`");
    const abs = r.get(3).result.contents.value;
    assert.ok(abs.startsWith("```ds\nabs(x: Int) → Int\nabs(x: Float) → Float\n```"), abs);
    assert.ok(abs.endsWith("[[LEXP.3.2]](file:///work/site/specs/language/EXPRESSIONS.html#lexp-3-2)"),
              `a relative docs path is the workspace root's: ${abs}`);
    assert.ok(r.get(4).result.contents.value.startsWith("```ds\nmath.sqrt(x: Float) → Float"), "through `import math`");
});

test("the program's names: declared where they are declared, imports followed", { skip: NO_DSC }, async () => {
    const data = (await session([{ id: 2, method: "textDocument/semanticTokens/full",
                                   params: { textDocument: { uri: APP_URI } } }])).get(2).result.data;
    /** @type {Map<string, string>} each token, by `line:char` (0-based), as `text=type+mods` */
    const got = new Map();
    const ls = APP.split("\n");
    let line = 0, char = 0;
    for (let i = 0; i < data.length; i += 5) {
        line += data[i];
        char = data[i] === 0 ? char + data[i + 1] : data[i + 1];
        got.set(`${line}:${char}`, `${ls[line].slice(char, char + data[i + 2])}=${name({ type: data[i + 3], mods: data[i + 4] })}`);
    }
    const want = {
        "2:5": "sensors=namespace",
        "2:20": "Reading=struct",
        "3:7": "math=namespace",
        "5:6": "LIMIT=variable+declaration+readonly",
        "7:7": "Alert=struct+declaration",
        "8:4": "sensor=property+declaration",
        "8:19": "key=keyword+clause",
        "11:8": "svc=interface+declaration",
        "11:12": "page=interface+declaration",
        "16:4": "Reading=struct",
        "16:12": "r=variable+declaration",
        "16:20": "r=variable",
        "16:22": "temp=property",
        "16:29": "LIMIT=variable+readonly",
        "16:39": "math=namespace+defaultLibrary",
        "16:44": "sqrt=function+defaultLibrary",
        "16:59": "3.0=number",
        "18:4": "emit=keyword+action",
        "18:9": "Alert=struct",
        "18:23": "sensor=property",
        "18:33": "sensor=property",
        "18:40": "level=property",
        "18:47": "abs=function+defaultLibrary",
    };
    for (const [at, t] of Object.entries(want)) assert.equal(got.get(at), t, at);
    assert.equal(got.get("12:10"), undefined, "a service's kwarg is not a slot of any schema");
});
