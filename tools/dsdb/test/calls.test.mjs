// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Batch mode's calls socket (DSDB.md §9.1): the protocol on its own, then
// `ds -b PROG FACTS --calls SOCK` and `--listen SOCK` end to end, with this file
// as the responder on a real Unix domain socket. The end-to-end half needs
// the js gate's engine and compiled fixture (DS_JS_FIXTURES/dsdb_calls.dsc).

import { test, describe, before } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { JsonText } from "../../../bindings/js/lib/index.js";
import { CallBook, ReplyError, argsText, callWire, liveArgs, parseReply, recordedArgs, responseSlots }
    from "../lib/core/calls.js";
import { main, parseArgs } from "../lib/cli/main.js";

/** One argument of each kind, as core/calls.js keeps them. */
const ARGS = [
    { name: "doc", type: "Json", value: '{"a":[1,\nnull]}' },
    { name: "n", type: "Int", value: 9007199254740993n },
    { name: "none", type: "Null", value: null },
    { name: "ok", type: "Bool", value: true },
    { name: "raw", type: "Bytes", value: new Uint8Array([0, 1, 255]) },
    { name: "s", type: "String", value: "q\"1" },
    { name: "sent", type: "Fact", value: { schema: "Reading", assertedAt: 5n, external: new Uint8Array([1, 2]) } },
    { name: "x", type: "Float", value: Infinity },
];

describe("the protocol", () => {
    test("a call is one line: its number, service, corr, arguments, rule, and when", () => {
        const line = callWire({ number: 3, service: "svc.ask", correlation: "q\"1", args: ARGS.slice(0, 2),
                                ruleName: "ask", at: 1_500_000_000n });
        assert.equal(line, '{"call":3,"service":"svc.ask","corr":"q\\"1","args":{"doc":{"a":[1, null]},'
                           + '"n":9007199254740993},"rule":"ask","at":"1500_ms"}');
        assert.ok(!line.includes("\n"));
        assert.equal(JSON.parse(callWire({ number: 1, service: "s", correlation: null, args: [], ruleName: "r", at: 0n })).corr,
                     null, "a call with no `as` has a null corr");
    });

    test("each argument is written as batch mode writes a slot of its kind; a fact as its schema, instant and bytes", () => {
        assert.equal(argsText(ARGS, { external: true }),
                     '{"doc":{"a":[1, null]},"n":9007199254740993,"none":null,"ok":true,"raw":"AAH/","s":"q\\"1",'
                     + '"sent":{"schema":"Reading","asserted_at":5,"external":"AQI="},"x":"inf"}');
        // The shell shows a fact argument without its bytes.
        assert.match(argsText(ARGS), /"sent":\{"schema":"Reading","asserted_at":5\},/);
        // No wall clock as the fact entered: null, not 0.
        const unset = [{ name: "f", type: "Fact", value: { schema: "Reading", assertedAt: null, external: null } }];
        assert.equal(argsText(unset), '{"f":{"schema":"Reading","asserted_at":null}}');
    });

    test("a live call's arguments are typed by value: a JsonText is Json, a string with the same text String", () => {
        const fact = { schema: "Reading", assertedAt: 5n, external: new Uint8Array([1]) };
        const got = liveArgs({ doc: new JsonText("[1]"), n: 3n, s: "[1]", x: 2.5, ok: false, raw: new Uint8Array([7]),
                               none: null, f: fact });
        assert.deepEqual(got.map((a) => [a.name, a.type]),
                         [["doc", "Json"], ["n", "Int"], ["s", "String"], ["x", "Float"], ["ok", "Bool"],
                          ["raw", "Bytes"], ["none", "Null"], ["f", "Fact"]]);
        assert.equal(got[0].value, "[1]");
        assert.deepEqual(got[7].value, fact);
    });

    test("a recorded call's arguments are read by their kind; a fact's bytes come from the live stream", () => {
        const kind = (name) => ({ number: 0, name });
        const got = recordedArgs([
            { name: "n", kind: kind("KIND_INT"), int_value: 7n },
            { name: "doc", kind: kind("KIND_JSON"), json_value: "{}" },
            { name: "none", kind: kind("KIND_NULL") },
            { name: "f", kind: kind("KIND_ENCODED_FACT"),
              fact: { schema: "Reading", asserted_at: 9n, has_asserted_at: true, fields: [] } },
            // has_asserted_at false: asserted_at is no instant, whatever it holds.
            { name: "g", kind: kind("KIND_ENCODED_FACT"), fact: { schema: "Reading", asserted_at: 0n, fields: [] } },
        ], new Map([["f", new Uint8Array([4])]]));
        assert.deepEqual(got, [
            { name: "n", type: "Int", value: 7n },
            { name: "doc", type: "Json", value: "{}" },
            { name: "none", type: "Null", value: null },
            { name: "f", type: "Fact", value: { schema: "Reading", assertedAt: 9n, external: new Uint8Array([4]) } },
            { name: "g", type: "Fact", value: { schema: "Reading", assertedAt: null, external: null } },
        ]);
    });

    test("a response is an object, kept as its JSON text until its schema types it", () => {
        assert.deepEqual(parseReply('{"corr":"a","response":{"n":12345678901234567890}}'),
                         { corr: "a", response: '{"n":12345678901234567890}' });
        assert.deepEqual(parseReply('{"response": {}, "corr": "a"}'), { corr: "a", response: "{}" });
    });

    test("a response is typed as a row of the response schema, and given the call's corr", () => {
        const schema = { name: "AskReply", slots: [{ name: "corr", type: "String", nullable: false },
                                                   { name: "n", type: "Int", nullable: false },
                                                   { name: "note", type: "String", nullable: true }] };
        assert.deepEqual(responseSlots('{"n":12345678901234567890}', schema, "a"), { corr: "a", n: 12345678901234567890n });
        assert.throws(() => responseSlots('{"corr":"b","n":1}', schema, "a"),
                      (e) => e instanceof ReplyError && /`corr` is the call's/.test(e.message));
        assert.throws(() => responseSlots('{"m":1}', schema, "a"),
                      (e) => e instanceof ReplyError && /`m` is not a slot of AskReply/.test(e.message));
        assert.throws(() => responseSlots('{"n":"x"}', schema, "a"),
                      (e) => e instanceof ReplyError && /slot `n` \(Int\)/.test(e.message));
        // A slot that is not nullable must be given; a nullable one may be left out (line 88).
        assert.throws(() => responseSlots('{"note":"x"}', schema, "a"),
                      (e) => e instanceof ReplyError && /`n` is missing: AskReply requires it/.test(e.message));
    });

    test("an error is a code and a message", () => {
        assert.deepEqual(parseReply('{"corr":"a","error":{"code":"svc.down","message":"it is down"}}'),
                         { corr: "a", error: { code: "svc.down", message: "it is down" } });
    });

    test("anything else is refused, and says why", () => {
        const bad = [
            ["not json", /^a line must be one JSON object \(column 1\)$/],
            ['{"corr":1,"response":1}', /`corr` must be a string/],
            ['{"corr":"a"}', /one of `response` and `error`/],
            ['{"corr":"a","response":1}', /`response` must be an object/],
            ['{"corr":"a","response":null}', /`response` must be an object/],
            ['{"corr":"a","response":1,"error":{}}', /one of `response` and `error`/],
            ['{"corr":"a","error":"down"}', /`error` must be an object/],
            ['{"corr":"a","error":{"code":"x"}}', /`error.message` must be a string/],
            ['{"corr":"a","response":1,"extra":2}', /no field `extra`/],
            ['{"corr":"a","corr":"b","response":1}', /twice/],
            ['{"corr":"a","response":1} trailing', /more after the object/],
        ];
        for (const [line, want] of bad) assert.throws(() => parseReply(line), (e) => e instanceof ReplyError && want.test(e.message), line);
    });

    test("a later call with the same corr supersedes the one waiting", () => {
        const book = new CallBook();
        const issue = (correlation, at) => book.issue({ service: "s", correlation, args: [], ruleName: "r", at, response: "R" });
        const one = issue("a", 0n), two = issue("a", 1n), three = issue("b", 1n);
        assert.deepEqual([one.number, two.number, three.number], [1, 2, 3]);
        assert.equal(one.outcome, "superseded");
        assert.deepEqual(book.waiting, [two, three]);
        assert.equal(book.find("a"), two);
        book.settle(two, "answered");
        assert.deepEqual(book.waiting, [three]);
        assert.equal(book.find("a"), undefined);
    });

    test("a call no response can answer does not wait; with a corr, an error can still fail it", () => {
        const book = new CallBook();
        const tell = book.issue({ service: "s", correlation: "t", args: [], ruleName: "r", at: 0n, response: "" });
        const bare = book.issue({ service: "s", correlation: null, args: [], ruleName: "r", at: 0n, response: "R" });
        assert.deepEqual([tell.waits, tell.outcome, bare.waits, bare.outcome],
                         [false, "no response", false, "no response"]);
        assert.deepEqual(book.waiting, []);
        assert.equal(book.find("t"), undefined, "no response names it");
        assert.equal(book.find("t", true), tell, "an error does");
        book.settle(tell, "failed");
        assert.equal(book.find("t", true), undefined);
    });

    test("usage: one socket, and later cycles only with one", () => {
        assert.throws(() => parseArgs(["p.dsc", "R.csv", "--calls", "a", "--listen", "b"]), /not both/);
        assert.throws(() => parseArgs(["p.dsc", "R.csv", "--pumps", "2"]), /need --calls or --listen/);
        assert.throws(() => parseArgs(["p.dsc", "R.csv", "--calls", "a", "--pumps", "0"]), /1 or more/);
        assert.throws(() => parseArgs(["p.dsc", "R.csv", "--calls", "a", "--call-timeout", "soon"]), /seconds/);
        const o = parseArgs(["-b", "p.dsc", "R.csv", "--listen", "s", "--pumps", "4", "--call-timeout", "0.25"]);
        assert.deepEqual([o.listen, o.pumps, o.callTimeoutMs], ["s", 4, 250]);
    });
});

// ── end to end ─────────────────────────────────────────────────────────────

const FIXTURES = process.env.DS_JS_FIXTURES;
const DSC = FIXTURES && join(FIXTURES, "dsdb_calls.dsc");
const NO_ENGINE = DSC && existsSync(DSC) ? false
    : "needs the js gate's engine and compiled fixtures (DS_JS_FIXTURES)";
const TARGET = process.env.DS_JS_TARGET ?? "native";

before(() => {
    process.env.DSDB_JS = fileURLToPath(new URL("../../../bindings/js/lib/index.js", import.meta.url));
});

/** The responder's side: every call line it was sent, parsed, and a reply
    for each from `answer` (a line, or null for none). */
function responder(sock, answer, got) {
    let buf = "";
    sock.setEncoding("utf8");
    sock.on("data", (s) => {
        buf += s;
        let i;
        while ((i = buf.indexOf("\n")) >= 0) {
            const call = JSON.parse(buf.slice(0, i));
            buf = buf.slice(i + 1);
            got.push(call);
            for (const line of [answer(call)].flat()) if (line !== null) sock.write(line + "\n");
        }
    });
    sock.on("error", () => {});
}

/** Run `ds -b -q DSC Question.csv ARGS…` with a responder on a socket in a scratch
    directory: listening before the run (`--calls`), or connecting once dsdb
    says it listens (`--listen`). */
async function withResponder(mode, args, answer, questions = "id\nfirst\n") {
    const base = process.env.DS_MERCURY_SCRATCH || tmpdir();
    mkdirSync(base, { recursive: true });
    const dir = mkdtempSync(join(base, "dsdb-calls-"));
    const sock = join(dir, "calls.sock");
    const facts = join(dir, "Question.csv");
    writeFileSync(facts, questions);
    const got = [];
    let server = null;
    try {
        if (mode === "--calls") {
            server = net.createServer((s) => responder(s, answer, got));
            await new Promise((r) => server.listen(sock, r));
        }
        let out = "", err = "";
        const io = {
            stdout: (s) => { out += s; },
            stderr: (s) => {
                err += s;
                if (mode === "--listen" && s.includes("listening on"))
                    responder(net.createConnection({ path: sock }), answer, got);
            },
        };
        const code = await main(["-b", "-q", DSC, facts, mode, sock, ...args], io);
        return { code, out, err, got, left: existsSync(sock) };
    } finally {
        if (server) await new Promise((r) => server.close(r));
        rmSync(dir, { recursive: true, force: true });
    }
}

/** `first` is answered; the answer calls `second`, which fails. */
const ANSWER = (c) => (c.corr === "first"
    ? JSON.stringify({ corr: c.corr, response: { ok: true } })
    : JSON.stringify({ corr: c.corr, error: { code: "svc.down", message: "it is down" } }));

const lines = (s) => s.trim().split("\n");

describe(`the calls socket on the ${TARGET} target`, () => {
    for (const mode of ["--calls", "--listen"]) {
        test(`${mode}: each call is sent; each reply is a fact, a cycle at a time`, { skip: NO_ENGINE }, async () => {
            const r = await withResponder(mode, ["--pumps", "3"], ANSWER);
            assert.equal(r.code, 0, r.err);
            assert.deepEqual(r.got.map((c) => [c.call, c.service, c.corr, c.rule, c.at]),
                             [[1, "svc.ask", "first", "ask", "0_s"], [2, "svc.ask", "second", "again", "0_s"]]);
            const e = lines(r.err).filter((l) => !/listening on/.test(l));
            assert.match(e[0], /^0\.0s {2}call svc\.ask as "first" {2}.* {2}by ask {2}\(call 1, sent\)$/);
            assert.equal(e[1], '0.0s  reply to call 1 (svc.ask as "first"): answered');
            assert.ok(e.includes("0.0s  INFO  answered first"), r.err);
            assert.ok(e.some((l) => /call svc\.ask as "second" .* by again {2}\(call 2, sent\)$/.test(l)), r.err);
            assert.ok(e.includes('0.0s  reply to call 2 (svc.ask as "second"): failed: svc.down  it is down'), r.err);
            assert.ok(e.includes("0.0s  WARNING  failed second svc.down"), r.err);
            assert.ok(!/no reply/.test(r.err), r.err);
            // Listening, the socket file is dsdb's, and gone at the end;
            // connecting, it is the responder's, and left alone.
            assert.equal(r.left, mode === "--calls");
        });
    }

    test("one cycle, the default: calls are sent, and what waits is listed at the end", { skip: NO_ENGINE }, async () => {
        const r = await withResponder("--calls", [], ANSWER);
        assert.equal(r.code, 0, r.err);
        assert.ok(!/reply to/.test(r.err), r.err);
        assert.equal(lines(r.err).pop(), 'call 1 svc.ask as "first"  by ask: no reply');
    });

    test("more cycles than replies: the run stops when nothing waits", { skip: NO_ENGINE }, async () => {
        const r = await withResponder("--calls", ["--pumps", "10"], ANSWER);
        assert.equal(r.code, 0, r.err);
        assert.equal(r.got.length, 2);
    });

    test("fewer cycles than replies: the last call is left waiting", { skip: NO_ENGINE }, async () => {
        const r = await withResponder("--calls", ["--pumps", "2"], ANSWER);
        assert.equal(r.code, 0, r.err);
        assert.equal(lines(r.err).pop(), 'call 2 svc.ask as "second"  by again: no reply');
    });

    test("a responder that never answers: the cycle ends at the timeout", { skip: NO_ENGINE }, async () => {
        const t = Date.now();
        const r = await withResponder("--calls", ["--pumps", "3", "--call-timeout", "0.2"], () => null);
        assert.equal(r.code, 0, r.err);
        assert.ok(Date.now() - t < 5000);
        assert.equal(lines(r.err).pop(), 'call 1 svc.ask as "first"  by ask: no reply');
    });

    test("lines that are not a reply to a waiting call are dropped, and said", { skip: NO_ENGINE }, async () => {
        const r = await withResponder("--calls", ["--pumps", "2"], (c) => [
            "not json", JSON.stringify({ corr: "nobody", response: {} }), ANSWER(c)]);
        assert.equal(r.code, 0, r.err);
        assert.ok(lines(r.err).some((l) => /^0\.0s {2}reply dropped: a line must be one JSON object.* {2}not json$/.test(l)), r.err);
        assert.ok(r.err.includes('reply dropped: no call waits on corr "nobody"'), r.err);
        assert.ok(r.err.includes("answered first"), r.err);
    });

    test("no socket there: exit 4, and says which", { skip: NO_ENGINE }, async () => {
        const base = process.env.DS_MERCURY_SCRATCH || tmpdir();
        mkdirSync(base, { recursive: true });
        const dir = mkdtempSync(join(base, "dsdb-calls-"));
        try {
            const facts = join(dir, "Question.csv");
            writeFileSync(facts, "id\nfirst\n");
            let err = "";
            const code = await main(["-b", "-q", DSC, facts, "--calls", join(dir, "nobody.sock")],
                                    { stdout: () => {}, stderr: (s) => { err += s; } });
            assert.equal(code, 4, err);
            assert.match(err, /nobody\.sock: no such socket$/m);
        } finally {
            rmSync(dir, { recursive: true, force: true });
        }
    });
});
