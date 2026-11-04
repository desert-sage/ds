// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// `ds mcp` (dsdb/DSDB_MCP.md), build step 1: the protocol, the
// fence, bounded output, and the tools as a client drives them, one JSON-RPC
// message per line, through the command in process.
//
// The protocol, the fence and the bounds need no engine.

import { test, describe, before, after } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { Fence, Fenced } from "../lib/cli/fence.js";
import { main } from "../lib/cli/main.js";
import { bound, capTrees } from "../lib/api/bound.js";
import { PROTOCOLS } from "../lib/mcp/server.js";
import { NO_COMPILER, TARGET } from "./compiler.mjs";

const NO_ENGINE = process.env.DS_JS_FIXTURES ? false : "needs the js gate's engine (DS_JS_FIXTURES)";
// The server runs on either target, each compiling with its own
// compiler (compiler.mjs).
const NO_DSC = NO_ENGINE || NO_COMPILER;

before(() => {
    process.env.DSDB_JS = fileURLToPath(new URL("../../../bindings/js/lib/index.js", import.meta.url));
});

// The tests' files are made here, so the server reads and writes here (§7).
const SCRATCH = process.env.DS_MERCURY_SCRATCH || tmpdir();
mkdirSync(SCRATCH, { recursive: true });

/** Run `ds mcp` over `messages` (objects, or raw lines), and return its
    responses, one parsed message per line; `.all` holds its notifications
    too, in the order it sent them. Its fence is the scratch directory unless
    `options` gives one. */
async function serve(messages, options = []) {
    async function* lines() {
        for (const m of messages) yield typeof m === "string" ? m : JSON.stringify(m);
    }
    let out = "", err = "";
    const fence = options.includes("--root") || options.includes("--out") ? [] : ["--root", SCRATCH, "--out", SCRATCH];
    const code = await main(["mcp", ...fence, ...options], { stdout: (s) => { out += s; }, stderr: (s) => { err += s; },
                                                             lines: lines() });
    assert.equal(code, 0, err);
    const all = out.split("\n").filter(Boolean).map((l) => JSON.parse(l));
    return Object.assign(all.filter((m) => Object.hasOwn(m, "id")), { all });
}

let nextId = 1;
const req = (method, params) => ({ jsonrpc: "2.0", id: nextId++, method, params });
const call = (name, args = {}) => req("tools/call", { name, arguments: args });
const INIT = req("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "0" } });

// A client writes `initialize` the moment it has spawned the server,
// before the server reads stdin. The path: cli/main.js `mcp` and its line
// reader over the real stdin, which the in-process `serve` above never
// takes. A reader made before an `await` and iterated after it drops the
// lines that arrive between, so this run has no answer to `initialize`.
test("ds mcp as a process answers what the client wrote before the server read stdin", async () => {
    const { spawn } = await import("node:child_process");
    const cli = fileURLToPath(new URL("../lib/cli/main.js", import.meta.url));
    const child = spawn(process.execPath, [cli, "mcp", "--root", SCRATCH, "--out", SCRATCH],
                        { env: process.env, stdio: ["pipe", "pipe", "pipe"] });
    const first = req("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "0" } });
    const second = req("ping");
    // At once, in one write, as a client does: nothing has been read yet.
    child.stdin.write(`${JSON.stringify(first)}\n${JSON.stringify(second)}\n`);
    let out = "", err = "";
    child.stdout.on("data", (d) => { out += d; });
    child.stderr.on("data", (d) => { err += d; });
    const answered = () => out.split("\n").filter(Boolean).map((l) => JSON.parse(l)).filter((m) => Object.hasOwn(m, "id"));
    const t0 = Date.now();
    while (answered().length < 2 && Date.now() - t0 < 20_000) await new Promise((r) => setTimeout(r, 50));
    child.stdin.end();
    const code = await new Promise((r) => child.on("exit", r));
    const got = answered();
    assert.deepEqual(got.map((m) => m.id), [first.id, second.id], `both answered, in order; stderr: ${err}`);
    assert.equal(got[0].result.serverInfo.name, "dsdb");
    assert.equal(code, 0, err);
});

// An argument a tool does not declare is refused, naming it and the
// ones the tool takes, before the tool runs. The path: lib/api/ops.js
// `Api.call`, which `ds serve` shares. Before, `load` with misnamed
// arguments opened an empty live session and answered isError false.
test("a tool refuses an argument it does not declare, before it runs, and its schema says so", async () => {
    const [, list, load, where] = await serve([
        INIT, req("tools/list"),
        call("load", { program: "hot.ds", facts: ["Reading.csv"] }),
        call("where", { bogus: 1 })]);
    for (const t of list.result.tools)
        assert.equal(t.inputSchema.additionalProperties, false, `${t.name}'s schema allows no other argument`);
    assert.equal(load.result.isError, true, JSON.stringify(load.result));
    assert.match(load.result.content[0].text, /`load` takes no `facts`; it takes `program`, `trace`, `search`/);
    assert.doesNotMatch(load.result.content[0].text, /live session/, "nothing was opened");
    assert.equal(where.result.isError, true);
    assert.match(where.result.content[0].text, /`where` takes no `bogus`; it takes no arguments/,
                 "refused for the argument, before `nothing is loaded`");
});

describe("the protocol", () => {
    test("initialize, tools/list, ping; notifications need no answer", async () => {
        const [init, list, ping, ...rest] = await serve([
            INIT, { jsonrpc: "2.0", method: "notifications/initialized" }, req("tools/list"), req("ping")]);
        assert.equal(rest.length, 0, "a notification is not answered");
        assert.equal(init.result.protocolVersion, "2025-06-18");
        assert.equal(init.result.serverInfo.name, "dsdb");
        assert.ok(init.result.capabilities.tools);
        const names = list.result.tools.map((t) => t.name);
        for (const n of ["load", "where", "move", "population", "facts", "query", "fact", "firings", "firing",
                         "calls", "why", "whynot", "rete", "match", "listing", "timelines", "switch", "fork", "kill",
                         "save_trace", "from_here_emit", "from_here_withdraw", "from_here_answer", "from_here_fail",
                         "from_here_silence", "advance", "define", "del", "mv", "ls", "source", "save_code",
                         "changes"])
            assert.ok(names.includes(n), n);
        for (const t of list.result.tools) {
            assert.equal(t.inputSchema.type, "object", t.name);
            assert.deepEqual(t.outputSchema.required, ["results"], t.name);
        }
        assert.deepEqual(ping.result, {});
    });

    test("the two newest revisions are spoken; any other, 2025-03-26 included, gets the newest", async () => {
        assert.deepEqual(PROTOCOLS, ["2025-11-25", "2025-06-18"]);
        for (const asked of ["2025-03-26", "1999-01-01"]) {
            const [init, list] = await serve([req("initialize", { protocolVersion: asked }), req("tools/list")]);
            assert.equal(init.result.protocolVersion, "2025-11-25", asked);
            assert.ok(list.result.tools.every((t) => t.outputSchema), asked);
        }
    });

    test("protocol errors: not JSON, a batch, no such method, no such tool", async () => {
        const [a, b, c, d] = await serve(["{nope", "[]", req("nope"), call("nope")]);
        assert.equal(a.error.code, -32700);
        assert.equal(b.error.code, -32600);
        assert.equal(c.error.code, -32601);
        assert.equal(d.error.code, -32602);
    });

    test("resources before `load`: none listed, the template, a read refused (§10.2)", async () => {
        const [init, list, templates, before, nowhere] = await serve([
            INIT, req("resources/list"), req("resources/templates/list"),
            req("resources/read", { uri: "dsdb://program" }), req("resources/read", { uri: "dsdb://nope" })]);
        assert.deepEqual(init.result.capabilities.resources, { listChanged: true });
        assert.deepEqual(list.result.resources, []);
        assert.deepEqual(templates.result.resourceTemplates.map((t) => t.uriTemplate), ["dsdb://timeline/{n}/listing"]);
        assert.equal(before.error.code, -32002);
        assert.match(before.error.message, /nothing is loaded/);
        assert.equal(nowhere.error.code, -32002);
    });

    test("a tool before `load` refuses, as a tool result the agent can read", async () => {
        const [r] = await serve([call("where")]);
        assert.equal(r.result.isError, true);
        assert.match(r.result.content[0].text, /nothing is loaded/);
        assert.deepEqual(r.result.structuredContent.results, [{ type: "error", text: "nothing is loaded: `load` a program first" }]);
    });
});

describe("where the server reads and writes: --root, --out (§7)", () => {
    let top, a, b;
    before(() => {
        top = mkdtempSync(join(SCRATCH, "dsdb-fence-"));
        a = join(top, "a");
        b = join(top, "b");
        mkdirSync(join(a, "sub"), { recursive: true });
        mkdirSync(b);
        writeFileSync(join(a, "p.dsc"), "");
        writeFileSync(join(top, "outside.dsc"), "");
        symlinkSync(top, join(a, "up"));
    });
    after(() => { if (top) rmSync(top, { recursive: true, force: true }); });

    test("read under a root or --out, written under --out; `..` and a link do not lead out", () => {
        const f = new Fence({ roots: [a], out: b });
        assert.equal(f.readable(join(a, "p.dsc")), join(a, "p.dsc"));
        assert.equal(f.readable(join(a, "sub", "not-yet.dsc")), join(a, "sub", "not-yet.dsc"));
        assert.equal(f.readable(join(b, "saved.dstrace")), join(b, "saved.dstrace"));
        assert.throws(() => f.readable(join(top, "outside.dsc")), /outside the directories dsdb may read/);
        assert.throws(() => f.readable(join(a, "..", "outside.dsc")), Fenced);
        assert.throws(() => f.readable(join(a, "up", "outside.dsc")), Fenced);
        assert.equal(f.writable(join(b, "new", "x.ds")), join(b, "new", "x.ds"));
        assert.throws(() => f.writable(join(a, "x.ds")), /outside the directory dsdb may write/);
        // Relative to the working directory, which is the default for both.
        const here = new Fence({ cwd: a });
        assert.deepEqual([here.roots, here.out], [[realpathSync(a)], realpathSync(a)]);
        assert.equal(here.readable("p.dsc"), "p.dsc");
        assert.throws(() => here.writable("../b/x.ds"), Fenced);
    });

    test("a --root that is not a directory is a usage error", async () => {
        let err = "";
        const code = await main(["mcp", "--root", join(top, "nowhere")],
                                { stdout: () => {}, stderr: (s) => { err += s; }, lines: (async function* () {})() });
        assert.equal(code, 2);
        assert.match(err, /mcp: --root .*nowhere/);
    });
});

describe("bounded output (§10.1)", () => {
    test("rows past the limit are cut, with how many are left and the cursor for them", () => {
        const calls = { type: "calls", calls: [1, 2, 3, 4, 5] };
        const [first, more] = bound([calls], { limit: 2 });
        assert.deepEqual(first.calls, [1, 2]);
        assert.deepEqual([first.offset, first.total], [0, 5]);
        assert.deepEqual(more, { type: "more", count: 3, cursor: "2" });
        const [last, ...rest] = bound([calls], { limit: 2, from: 4 });
        assert.deepEqual(last.calls, [5]);
        assert.equal(rest.length, 0, "nothing left, no cursor");
        const note = { type: "note", text: "x" };
        assert.deepEqual(bound([note], { limit: 1 }), [note], "a result with no rows is as it was");
    });

    test("`ls`: one row per definition, across the kinds", () => {
        const d = (name) => ({ name });
        const r = { type: "programList", kinds: [["schema", [d("A"), d("B")]], ["rule", [d("r1"), d("r2"), d("r3")]]] };
        const [cut, more] = bound([r], { limit: 3, from: 1 });
        assert.deepEqual(cut.kinds.map(([k, ds]) => [k, ds.map((x) => x.name)]), [["schema", ["B"]], ["rule", ["r1", "r2"]]]);
        assert.deepEqual(more, { type: "more", count: 1, cursor: "4" });
    });

    test("a `why` tree stops after its node cap, in numbering order; each node that lost children is marked", () => {
        const tree = { kind: "fact", children: [
            { kind: "firing", n: 1, children: [
                { kind: "binding", n: 2, children: [{ kind: "firing", n: 3, children: [] }] },
                { kind: "ref", ref: 1 }] },
            { kind: "firing", n: 4, children: [] }] };
        const [whole] = capTrees([{ type: "why", root: tree }], 4);
        assert.equal(whole.root, tree, "under the cap, the tree as it was");
        const [cut, note] = capTrees([{ type: "why", root: tree }], 2);
        const f1 = cut.root.children[0];
        assert.equal(cut.root.children.length, 1);
        assert.deepEqual([f1.n, f1.cut, f1.children.length], [1, true, 1]);
        assert.deepEqual([f1.children[0].n, f1.children[0].cut, f1.children[0].children.length], [2, true, 0]);
        assert.match(note.text, /stopped at 2 nodes/);
    });
});

describe(`the tools, on the ${TARGET} target`, () => {
    const results = (r) => r.result.structuredContent.results;
    const only = (r, type) => results(r).find((x) => x.type === type) ?? assert.fail(JSON.stringify(results(r)));

    test("the loop: nothing loaded, defined up, run, changed, saved as code, and loaded again (§4.16)", { skip: NO_DSC },
         async () => {
        const dir = mkdtempSync(join(SCRATCH, "dsdb-mcp-"));
        try {
            const code = join(dir, "built.ds");
            const SCHEMA = "schema Reading scope logical:\n    entity_id: String key\n    level: Float mutable\n";
            const HOT = (t) => `rule hot:\n    Reading r where r.level > ${t}\n->\n    log info "hot {r.entity_id}"\n`;
            const [load, schema, rule, emit, ls, redefine, moved, bad, saved, again, rules, missing] = await serve([
                call("load"),
                call("define", { text: SCHEMA }),
                call("define", { text: HOT("80.0") }),
                call("from_here_emit", { text: 'Reading entity_id: "a" level: 75.0' }),
                call("ls", { kind: "rules" }),
                call("define", { text: HOT("70.0") }),
                call("mv", { rule: "hot", to: 1 }),
                call("define", { text: "rule broken:\n    Nope n\n->\n    log info \"x\"\n" }),
                call("save_code", { path: code }),
                call("load", { program: code }),
                call("ls", { kind: "rules" }),
                call("load", { program: code.replace(/built\.ds$/, "nosuch.ds") })]);
            assert.match(load.result.content[0].text, /live session on an empty program/);
            assert.equal(only(schema, "edited").what, "+ schema Reading");
            assert.equal(only(rule, "edited").what, "+ rule hot");
            assert.equal(emit.result.isError, false, emit.result.content[0].text);
            assert.deepEqual(only(ls, "ruleList").rules.map((r) => [r.name, r.fired]), [["hot", 0]]);
            // 70.0 catches the 75.0 reading the 80.0 did not: the edit says so.
            const diff = only(redefine, "editDiff");
            assert.deepEqual(diff.firings, [{ rule: "hot", before: 0, after: 1 }]);
            assert.equal(only(redefine, "edited").inputs, 1);
            assert.equal(moved.result.isError, false, moved.result.content[0].text);
            assert.equal(bad.result.isError, true, "a program that does not compile changes nothing");
            assert.equal(missing.result.isError, true);
            assert.match(missing.result.content[0].text, /cannot read .*nosuch\.ds: no such file/);
            assert.doesNotMatch(missing.result.content[0].text, /does not compile|ENOENT/);
            assert.match(only(saved, "savedCode").path, /built\.ds$/);
            assert.match(readFileSync(code, "utf8"), /level > 70\.0/);
            assert.equal(again.result.isError, false, again.result.content[0].text);
            assert.deepEqual(only(rules, "ruleList").rules.map((r) => r.name), ["hot"]);
        } finally {
            rmSync(dir, { recursive: true, force: true });
        }
    });

    test("--calls to a socket nobody listens on is exit 4, as an unreadable file", async () => {
        let err = "";
        const code = await main(["mcp", "--calls", join(tmpdir(), "dsdb-mcp-nobody.sock")],
                                { stdout: () => {}, stderr: (s) => { err += s; }, lines: (async function* () {})() });
        assert.equal(code, 4);
        assert.match(err, /dsdb-mcp-nobody\.sock/);
    });

    test("a load that is refused keeps nothing new, and says why", { skip: NO_ENGINE }, async () => {
        const [r] = await serve([call("load", { program: "/no/such/file.dsc" })]);
        assert.equal(r.result.isError, true);
        assert.match(r.result.content[0].text, /\/no\/such\/file\.dsc/);
    });
});
