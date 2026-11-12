// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// `ds dap` (lib/dap/; NDBG.9 to 15), driven as an editor drives it: DAP's base protocol in, through the command
// in process, and every message the adapter sends read back.
//
// The protocol needs no engine. Everything else runs the fixture
// dsdb_dap.ds, compiled by the branch's Mercury dsc in the js gate:
// in replay over a trace recorded from it, and live, over fact files.

import { test, describe, before } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { frame } from "../lib/lsp/framing.js";
import { main } from "../lib/cli/main.js";
import { compileFile, loadBinding, openTarget } from "../lib/cli/open.js";
import { hitTest, interpolation, ruleQuery } from "../lib/dap/adapter.js";
import { CAPABILITIES } from "../lib/dap/server.js";
import { NO_COMPILER } from "./compiler.mjs";
import { SCHEMAS, dapChecker, pinnedDapChecker } from "./dap_schema.mjs";

// Every message the adapter sends, in every test of this file, is checked
// against DAP's published schema (dap_schema.mjs). What breaks it is
// collected here and judged by the file's last test.
const CHECK = pinnedDapChecker();
/** @type {string[]} */
const VIOLATIONS = [];

const TARGET = process.env.DS_JS_TARGET ?? "native";
const FIXTURES = process.env.DS_JS_FIXTURES;
const NO_ENGINE = FIXTURES ? false : "needs the js gate's engine and compiled fixtures (DS_JS_FIXTURES)";
// The fixture is compiled by the gate; a source is compiled by the target's own
// compiler (compiler.mjs). The adapter runs on either target.
const NO_DSC = NO_ENGINE || NO_COMPILER;

const SOURCE = fileURLToPath(new URL("./fixtures/dsdb_dap.ds", import.meta.url));
const TEXT = readFileSync(SOURCE, "utf8");
/** The 1-based line `prefix` starts, in the fixture. */
const lineOf = (prefix) => {
    const i = TEXT.split("\n").findIndex((l) => l.startsWith(prefix));
    assert.ok(i >= 0, `no line ${prefix} in the fixture`);
    return i + 1;
};

const SCRATCH = process.env.DS_MERCURY_SCRATCH || tmpdir();
mkdirSync(SCRATCH, { recursive: true });

before(() => {
    process.env.DSDB_JS = fileURLToPath(new URL("../../../bindings/js/lib/index.js", import.meta.url));
});

// ── a client ───────────────────────────────────────────────────────────────

/**
 * An editor's end of the adapter: requests framed onto its input as they are
 * made, and every message it sends parsed. The adapter answers a request and
 * sends that answer's events before it reads the next request, so the events
 * a request made are the messages after its response.
 */
class Client {
    constructor(argv = []) {
        /** @type {Buffer[]} */
        this.queue = [];
        this.wake = null;
        this.ended = false;
        this.buf = Buffer.alloc(0);
        /** @type {any[]} */
        this.msgs = [];
        /** @type {Array<{ seq: number, resolve: (i: number) => void }>} */
        this.waiting = [];
        this.seq = 1;
        this.err = "";
        const self = this;
        async function* input() {
            for (;;) {
                while (self.queue.length) yield self.queue.shift();
                if (self.ended) return;
                await new Promise((r) => { self.wake = r; });
                self.wake = null;
            }
        }
        this.done = main(["dap", ...argv], { stdout: (s) => this.#out(s), stderr: (s) => { this.err += s; }, input: input() });
    }

    /** @param {string} s */
    #out(s) {
        this.buf = Buffer.concat([this.buf, Buffer.from(s, "utf8")]);
        for (;;) {
            const end = this.buf.indexOf("\r\n\r\n");
            if (end < 0) return;
            const m = /Content-Length: (\d+)/i.exec(this.buf.subarray(0, end).toString("ascii"));
            assert.ok(m, "every message has a Content-Length");
            const start = end + 4, len = Number(m[1]);
            if (this.buf.length < start + len) return;
            const msg = JSON.parse(this.buf.subarray(start, start + len).toString("utf8"));
            this.buf = this.buf.subarray(start + len);
            this.msgs.push(msg);
            if (CHECK) {
                const what = msg.type === "event" ? `event ${msg.event}` : `${msg.type} to ${msg.command}`;
                for (const v of CHECK(msg)) VIOLATIONS.push(`${what}: ${v}`);
            }
            const i = this.msgs.length - 1;
            if (msg.type === "response") {
                const w = this.waiting.find((x) => x.seq === msg.request_seq);
                if (w) {
                    this.waiting.splice(this.waiting.indexOf(w), 1);
                    w.resolve(i);
                }
            }
        }
    }

    /**
     * A request, and what came back: its response and the events after it.
     * @param {string} command
     * @param {object} [args]
     */
    async request(command, args = {}) {
        const seq = this.seq++;
        const at = new Promise((resolve) => this.waiting.push({ seq, resolve }));
        this.queue.push(Buffer.from(frame({ seq, type: "request", command, arguments: args }), "utf8"));
        this.wake?.();
        const i = await at;
        const res = this.msgs[i];
        const events = this.msgs.slice(i + 1).filter((m) => m.type === "event");
        return { res, events, ok: res.success, body: res.body, message: res.message,
                 stopped: events.find((e) => e.event === "stopped")?.body ?? null,
                 output: events.filter((e) => e.event === "output").map((e) => e.body) };
    }

    /** End the input without a disconnect. */
    end() {
        this.ended = true;
        this.wake?.();
        return this.done;
    }
}

/**
 * A client through initialize, launch and configurationDone.
 * @param {object} launch
 * @param {(c: Client) => Promise<void>} [configure]  breakpoints set before configurationDone
 */
async function session(launch, configure) {
    const c = new Client();
    const init = await c.request("initialize", { adapterID: "ds", linesStartAt1: true });
    assert.ok(init.ok);
    const l = await c.request("launch", launch);
    assert.ok(l.ok, l.message);
    c.launched = l;
    if (configure) await configure(c);
    c.entry = await c.request("configurationDone");
    return c;
}

/** @param {Client} c */
async function threads(c) {
    return (await c.request("threads")).body.threads;
}

/** The focused thread at the last stop, with its frames. @param {Client} c @param {any} stopped */
async function focused(c, stopped) {
    const id = stopped.threadId;
    const ts = await threads(c);
    const t = ts.find((x) => x.id === id);
    assert.ok(t, `the stopped thread ${id} is listed`);
    const frames = (await c.request("stackTrace", { threadId: id })).body.stackFrames;
    return { ...t, frames };
}

/** A scope's variables, by scope name, on frame `frameId`. @param {Client} c */
async function scope(c, frameId, name) {
    const scopes = (await c.request("scopes", { frameId })).body.scopes;
    const s = scopes.find((x) => x.name === name);
    assert.ok(s, `a ${name} scope (have ${scopes.map((x) => x.name)})`);
    return (await c.request("variables", { variablesReference: s.variablesReference })).body.variables;
}

/** A variable's children. @param {Client} c */
async function kids(c, v) {
    assert.ok(v.variablesReference > 0, `${v.name} has children`);
    return (await c.request("variables", { variablesReference: v.variablesReference })).body.variables;
}

const named = (vars, name) => vars.find((v) => v.name === name) ?? assert.fail(`no ${name} in ${vars.map((v) => v.name)}`);

// ── without an engine ──────────────────────────────────────────────────────

describe("the protocol", () => {
    // What follows an answer runs once its response is sent, so a request
    // gets one response; a refusal carries the body DAP's ErrorResponse
    // requires.
    test("configurationDone before launch gets one response, refused with a body, saying to launch first", async () => {
        const c = new Client();
        await c.request("initialize", { adapterID: "ds" });
        const r = await c.request("configurationDone");
        await c.request("disconnect");
        const answers = c.msgs.filter((m) => m.type === "response" && m.request_seq === r.res.request_seq);
        assert.equal(answers.length, 1, `one response, not ${JSON.stringify(answers)}`);
        assert.equal(r.ok, false);
        assert.match(r.message, /nothing is launched: `launch` first/);
        assert.deepEqual(r.body, { error: { id: 1, format: r.message } });
    });

    // @spec [NDBG.9.2.1]
    test("initialize answers NDBG.9.2.1's capabilities, then `initialized`", async () => {
        const c = new Client();
        const r = await c.request("initialize", { adapterID: "ds" });
        assert.ok(r.ok);
        for (const [k, v] of Object.entries({
            supportsStepBack: true, supportsRestartRequest: true, supportsGotoTargetsRequest: true,
            supportsStepInTargetsRequest: true, supportsFunctionBreakpoints: true, supportsDataBreakpoints: false,
            supportsConditionalBreakpoints: true, supportsHitConditionalBreakpoints: true, supportsLogPoints: true,
            supportsRestartFrame: false, supportsSetVariable: false, supportsCompletionsRequest: false,
            supportsEvaluateForHovers: true }))
            assert.equal(r.body[k], v, k);
        assert.deepEqual(r.body.additionalModuleColumns, []);
        // [NDBG.12.6.1]'s three filters, engine_error alone on by default.
        assert.deepEqual(r.body.exceptionBreakpointFilters.map((f) => [f.filter, f.label, f.default]),
                         [["unanswered_call", "Unanswered call", false], ["fault", "Fault", false],
                          ["engine_error", "Engine error", true]]);
        assert.deepEqual(r.body, JSON.parse(JSON.stringify(CAPABILITIES)));
        assert.ok(r.events.some((e) => e.event === "initialized"), "`initialized` follows the response");
        await c.request("disconnect");
        assert.equal(await c.done, 0, "disconnect ends with 0");
    });

    test("attach is refused, saying to launch; nothing works before a launch; an unknown request is refused", async () => {
        const c = new Client();
        await c.request("initialize");
        const a = await c.request("attach", {});
        assert.equal(a.ok, false);
        assert.match(a.message, /no ds server to attach to; use launch/);
        const t = await c.request("threads");
        assert.equal(t.ok, false);
        assert.match(t.message, /launch/);
        const u = await c.request("nothingLikeThis");
        assert.equal(u.ok, false);
        assert.match(u.message, /no request `nothingLikeThis`/);
        // Not a request (NDBG.13.5.3): refused as any unknown request.
        const p = await c.request("ds/getFactPath", {});
        assert.equal(p.ok, false);
        assert.match(p.message, /no request `ds\/getFactPath`/);
        assert.equal(await c.end(), 1, "input that ends without a disconnect is status 1");
    });

    test("a launch needs a program or a trace; `facts` go with no trace", async () => {
        const c = new Client();
        await c.request("initialize");
        const none = await c.request("launch", {});
        assert.equal(none.ok, false);
        assert.match(none.message, /give the `program`/);
        const both = await c.request("launch", { program: "x.dsc", trace: "x.trace", facts: ["Reading.jsonl"] });
        assert.equal(both.ok, false);
        assert.match(both.message, /`facts` feed a live session/);
        const libs = await c.request("launch", { program: "x.dsc", libs: "not a list" });
        assert.equal(libs.ok, false);
        assert.match(libs.message, /`libs` is a list/);
        await c.request("disconnect");
        assert.equal(await c.done, 0);
    });

    test("a message past the size limit ends the adapter with status 1, saying why", async () => {
        const { MAX_BODY } = await import("../lib/lsp/framing.js");
        let err = "";
        const code = await main(["dap"], { stdout: () => {}, stderr: (s) => { err += s; },
                                           input: (async function* () { yield Buffer.from(`Content-Length: ${MAX_BODY + 1}\r\n\r\n`); })() });
        assert.equal(code, 1);
        assert.match(err, /^ds dap: a Content-Length of \d+ bytes, past the/m);
    });

    // @spec [NDBG.9.3.8]
    test("the exit status: 0 after `disconnect`, 1 when the input ends without one, 2 for a refused command line",
         async () => {
        const bye = new Client();
        await bye.request("initialize", { adapterID: "ds" });
        await bye.request("disconnect");
        assert.equal(await bye.done, 0, "disconnect");
        const cut = new Client();
        await cut.request("initialize", { adapterID: "ds" });
        assert.equal(await cut.end(), 1, "input that ends with no disconnect");
        const bogus = new Client(["--bogus"]);
        assert.equal(await bogus.done, 2, "`ds dap --bogus`");
        assert.match(bogus.err, /no option --bogus/);
    });

    test("hit conditions as DAP writes them", () => {
        assert.equal(hitTest("5")(5), true);
        assert.equal(hitTest("5")(4), false);
        assert.equal(hitTest(">= 3")(2), false);
        assert.equal(hitTest(">= 3")(3), true);
        assert.equal(hitTest("> 3")(3), false);
        assert.equal(hitTest("% 2")(4), true);
        assert.equal(hitTest("% 2")(3), false);
        assert.equal(hitTest("== 2")(2), true);
        assert.equal(hitTest("x"), null);
        assert.equal(hitTest("% 0"), null);
    });

    test("a logpoint's message cut at each {…}", () => {
        assert.deepEqual(interpolation("level={r.level}, sensor {r.sensor}!"),
                         { parts: ["level=", "r.level", ", sensor ", "r.sensor", "!"], exprs: ["r.level", "r.sensor"] });
        assert.deepEqual(interpolation("plain"), { parts: ["plain"], exprs: [] });
        assert.match(interpolation("open {r.x").error, /not closed/);
        assert.match(interpolation("empty {}").error, /no expression/);
    });

    test("a condition joins the last positive pattern's where; a logpoint's expressions are the projection", () => {
        assert.equal(ruleQuery(["Reading r where r.level > 80.0"], 'r.sensor == "a"', []),
                     'Reading r where (r.level > 80.0) and (r.sensor == "a")');
        assert.equal(ruleQuery(["High h"], 'h.sensor == "a"', ["h.sensor"]), 'High h where h.sensor == "a"\n-> h.sensor');
        assert.equal(ruleQuery(["Sensor s", "no Suppress x where x.room == s.room"], 's.room == "k"', []),
                     'Sensor s where s.room == "k"\nno Suppress x where x.room == s.room');
        assert.equal(ruleQuery(["High h"], null, ["h.sensor", "1"]), "High h\n-> h.sensor, 1");
    });
});

// ── on an engine ───────────────────────────────────────────────────────────

let DSC_PATH, TRACE_PATH, FACTS_PATH, DIR;
before(async () => {
    if (NO_DSC) return;
    const jsBinding = await import(new URL("../../../bindings/js/lib/index.js", import.meta.url).href);
    const ds = await jsBinding.open({ target: TARGET });
    const { EngineTimeline } = await import("../lib/core/engine-timeline.js");
    const dsc = new Uint8Array(readFileSync(join(FIXTURES, "dsdb_dap.dsc")));
    DIR = mkdtempSync(join(SCRATCH, "dsdb-dap-"));
    DSC_PATH = join(DIR, "dsdb_dap.dsc");
    writeFileSync(DSC_PATH, dsc);
    // The recorded run, input by input. Firings in order: !1 high, !2 alert
    // (one pump), !3 noted, !4 remember, !5 recall, !6 forget, !7 divide (a
    // fault), !8 cooled, !9 ping (a call), !10 pong (its answer); then the
    // clock passes every TTL, at 62 s, and the run ends at 63 s.
    const live = EngineTimeline.live(ds, dsc);
    live.assertFact("Reading", { sensor: "a", level: 90.0 });
    live.assertFact("Reading", { sensor: "b", level: 10.0 });
    live.advance(1_000_000_000n);
    live.assertFact("Note", { doc: '{"a":{"b":[1,2]}}' });
    live.assertFact("Trig", { tag: "set", x: 7n, y: 1n });
    live.assertFact("Trig", { tag: "get", x: 0n, y: 1n });
    live.assertFact("Trig", { tag: "del", x: 0n, y: 1n });
    live.assertFact("Trig", { tag: "div", x: 1n, y: 0n });
    live.assertFact("Trig", { tag: "cool", x: 0n, y: 1n });
    live.assertFact("Trig", { tag: "ping", x: 0n, y: 1n });
    live.assertFact("PingReply", { corr: "ping", ok: true });
    live.advance(61_000_000_000n);
    // A last step, so what the TTLs retracted at 62 s is inside the run's
    // half-open span ([NDBG.20.2]).
    live.advance(1_000_000_000n);
    TRACE_PATH = join(DIR, "dsdb_dap.trace");
    writeFileSync(TRACE_PATH, live.bytes());
    live.close();
    FACTS_PATH = join(DIR, "Reading.jsonl");
    writeFileSync(FACTS_PATH, '{"@at": "0_s", "sensor": "a", "level": 90.0}\n{"@at": "2_s", "sensor": "b", "level": 10.0}\n');
});

const REPLAY = () => ({ program: DSC_PATH, trace: TRACE_PATH, source: SOURCE });
const LIVE = (more = {}) => ({ program: DSC_PATH, source: SOURCE, ...more });

// ── capability honesty ─────────────────────────────────────────────────────
//
// What `initialize` advertises is a promise the client acts on: it sends the
// requests a capability gates only when the capability is true, and never
// otherwise. So each capability is honest when every request it gates is
// served if it is advertised, and refused as unknown if it is not, an absent
// capability being false. A schema-valid response can still promise a feature
// that is not there.
//
// GATED is DAP's own table, the `Capabilities` of debugAdapterProtocol.json:
// each capability that gates requests, and the requests. FIELDS are the
// capabilities that gate a field of a request rather than a request, each
// with the test in this file that exercises it in a live session.

const GATED = {
    supportsConfigurationDoneRequest: ["configurationDone"],
    supportsFunctionBreakpoints: ["setFunctionBreakpoints"],
    supportsStepBack: ["stepBack", "reverseContinue"],
    supportsRestartFrame: ["restartFrame"],
    supportsGotoTargetsRequest: ["gotoTargets", "goto"],
    supportsStepInTargetsRequest: ["stepInTargets"],
    supportsCompletionsRequest: ["completions"],
    supportsModulesRequest: ["modules"],
    supportsRestartRequest: ["restart"],
    supportsSetVariable: ["setVariable"],
    supportsExceptionInfoRequest: ["exceptionInfo"],
    supportsTerminateThreadsRequest: ["terminateThreads"],
    supportsSetExpression: ["setExpression"],
    supportsTerminateRequest: ["terminate"],
    supportsDataBreakpoints: ["dataBreakpointInfo", "setDataBreakpoints"],
    supportsReadMemoryRequest: ["readMemory"],
    supportsWriteMemoryRequest: ["writeMemory"],
    supportsDisassembleRequest: ["disassemble"],
    supportsCancelRequest: ["cancel"],
    supportsBreakpointLocationsRequest: ["breakpointLocations"],
    supportsLoadedSourcesRequest: ["loadedSources"],
    supportsInstructionBreakpoints: ["setInstructionBreakpoints"],
};

const FIELDS = {
    supportsConditionalBreakpoints: "conditions: compiled against the rule's patterns",
    supportsHitConditionalBreakpoints: "hit counts count from the timeline's start",
    supportsLogPoints: "a logpoint logs as the session passes its firing forward",
    supportsEvaluateForHovers: "evaluate: a DS expression over the frame's bindings",
};

/** Whether the adapter advertises capability `k`; absent is false. */
const advertised = (k) => CAPABILITIES?.[k] === true;

/** A response that says the adapter has no such request. */
const unknown = (r, command) => r.ok === false && r.message === `no request \`${command}\``;

describe("capability honesty", () => {
    test("every capability initialize advertises is in DAP's table of what it gates", () => {
        const known = new Set([...Object.keys(GATED), ...Object.keys(FIELDS),
                               "exceptionBreakpointFilters", "additionalModuleColumns"]);
        const loose = Object.keys(CAPABILITIES).filter((k) => !known.has(k));
        assert.deepEqual(loose, [], "a capability with no row: say what it gates, and test it");
    });

    test("each request a capability gates is refused as unknown unless the capability is advertised", async () => {
        const c = new Client();
        await c.request("initialize", { adapterID: "ds" });
        /** @type {string[]} */
        const served = [];
        for (const [k, commands] of Object.entries(GATED)) {
            if (advertised(k)) continue;
            for (const command of commands) {
                const r = await c.request(command, {});
                if (!unknown(r, command)) served.push(`${command} (${k} is not advertised): ${r.ok ? "ok" : r.message}`);
            }
        }
        assert.deepEqual(served, [], "a request served behind a capability the client was told is off");
        // No modules request is served, so there are no module columns to add.
        assert.deepEqual(CAPABILITIES.additionalModuleColumns, []);
        await c.request("disconnect");
        assert.equal(await c.done, 0);
    });

    test("each request an advertised capability gates is served, in a launched session", { skip: NO_DSC }, async () => {
        const c = await session(REPLAY());
        /** @type {string[]} */
        const missing = [];
        const gated = Object.entries(GATED).filter(([k]) => advertised(k));
        assert.ok(gated.length > 0, "the adapter advertises requests: this check runs over them");
        for (const [k, commands] of gated)
            for (const command of commands) {
                const r = await c.request(command, {});
                if (unknown(r, command)) missing.push(`${command} (${k} is advertised)`);
            }
        // [NDBG.12.6.1]'s filters: setExceptionBreakpoints is served with every
        // one the adapter advertises.
        const filters = CAPABILITIES.exceptionBreakpointFilters.map((f) => f.filter);
        assert.ok(filters.length > 0);
        const set = await c.request("setExceptionBreakpoints", { filters });
        assert.ok(set.ok, set.message);
        assert.deepEqual(missing, [], "an advertised request the adapter does not serve");
        await c.request("disconnect");
    });

    test("each advertised field-level capability names the live test that exercises it", () => {
        const here = readFileSync(fileURLToPath(import.meta.url), "utf8");
        for (const [k, title] of Object.entries(FIELDS)) {
            assert.ok(advertised(k), `${k} is not advertised: its row needs a test that the field is refused`);
            assert.ok(here.includes(`test("${title}`), `${k}: no test titled "${title}…" in this file`);
        }
    });
});

describe("replay: launch, threads, frames and scopes", { skip: NO_DSC }, () => {
    test("the session starts at the trace's start, on the engine's thread, with four scopes and no Bindings", async () => {
        const c = await session(REPLAY());
        assert.equal(c.entry.stopped.reason, "entry");
        const ts = await threads(c);
        assert.equal(ts.length, 1);
        assert.match(ts[0].name, /^engine at T=0\.000s$/);
        const frames = (await c.request("stackTrace", { threadId: ts[0].id })).body.stackFrames;
        const scopes = (await c.request("scopes", { frameId: frames[0].id })).body.scopes.map((s) => s.name);
        assert.deepEqual(scopes, ["Working Memory", "Agenda", "Cache", "Calls"]);
        await c.request("disconnect");
        assert.equal(await c.done, 0);
    });

    test("a function breakpoint stops in its rule; the focused thread has the action and the rule, at the rule's line", async () => {
        let set;
        const c = await session(REPLAY(), async (cl) => {
            set = await cl.request("setFunctionBreakpoints", { breakpoints: [{ name: "alert" }, { name: "nope" }] });
        });
        assert.equal(set.body.breakpoints[0].verified, true);
        assert.equal(set.body.breakpoints[1].verified, false);
        assert.equal(set.body.breakpoints[1].message, "no rule named 'nope' in the loaded rule set");
        const r = await c.request("continue");
        assert.equal(r.body.allThreadsContinued, true);
        assert.equal(r.stopped.reason, "breakpoint");
        assert.deepEqual(r.stopped.hitBreakpointIds, [set.body.breakpoints[0].id]);
        const t = await focused(c, r.stopped);
        assert.match(t.name, /^alert/);
        assert.equal(t.frames.length, 2, "the focused thread: the action and the rule");
        assert.equal(t.frames[0].name, "emit Alert");
        assert.equal(t.frames[1].name, "rule alert");
        assert.equal(t.frames[1].line, lineOf("rule alert:"));
        assert.equal(t.frames[1].source.path, SOURCE);
        // Bindings, by source name; the fact's slots, `_id`, and, logical, `_justifiers`.
        const b = await scope(c, t.frames[0].id, "Bindings");
        assert.equal(b.length, 1);
        assert.equal(b[0].name, "h");
        assert.match(b[0].value, /^High #\d+$/);
        const slots = await kids(c, b[0]);
        assert.equal(named(slots, "sensor").value, '"a"');
        assert.match(named(slots, "_id").value, /^#\d+$/);
        named(slots, "_justifiers");
        // The rule frame has its Bindings only.
        const ruleScopes = (await c.request("scopes", { frameId: t.frames[1].id })).body.scopes.map((s) => s.name);
        assert.deepEqual(ruleScopes, ["Bindings"]);
        const wm = await scope(c, t.frames[0].id, "Working Memory");
        assert.ok(wm.some((v) => v.value === "Reading (1 fact)"), wm.map((v) => v.value).join(", "));
        assert.ok(wm.some((v) => v.value === "High (1 fact)"));
        const reading = await kids(c, named(wm, "Reading"));
        assert.match(reading[0].name, /^#\d+$/);
        await c.request("disconnect");
    });

    test("in replay the threads are the firing in progress and the rest of its pump, those to come subtle", async () => {
        const c = await session(REPLAY(), async (cl) => {
            await cl.request("setFunctionBreakpoints", { breakpoints: [{ name: "high" }] });
        });
        const r = await c.request("continue");
        const ts = await threads(c);
        assert.equal(ts.length, 2);
        assert.match(ts[0].name, /^high/);
        assert.match(ts[1].name, /^alert.*still to fire in this pump/);
        assert.ok(r.events.some((e) => e.event === "thread" && e.body.reason === "started"));
        const other = (await c.request("stackTrace", { threadId: ts[1].id })).body.stackFrames;
        assert.equal(other.length, 1);
        assert.equal(other[0].presentationHint, "subtle");
        const agenda = await scope(c, (await focused(c, r.stopped)).frames[0].id, "Agenda");
        assert.equal(agenda.length, 1);
        assert.match(agenda[0].value, /^alert.*\(terminal \d+\)$/);
        // A thread keeps its id: the step to alert's firing names the same one.
        const id = ts[1].id;
        const n = await c.request("next");
        assert.equal(n.stopped.threadId, id);
        assert.ok(n.events.some((e) => e.event === "thread" && e.body.reason === "exited"));
        await c.request("disconnect");
    });
});

describe("replay: stepping", { skip: NO_DSC }, () => {
    test("granularity: `action` by default; a bad one refused; `rule`, `pump` and `input` step by theirs; stepBack goes back", async () => {
        const c = await session(REPLAY());
        const bad = await c.request("ds/stepGranularity", { granularity: "line" });
        assert.equal(bad.ok, false);
        assert.match(bad.message, /granularity is one of action, rule, pump, input/);
        const first = await c.request("next");
        assert.equal(first.stopped.reason, "step");
        const t = await focused(c, first.stopped);
        assert.equal(t.frames[0].name, "emit High", "an action step stops before the first action");
        const r = await c.request("ds/stepGranularity", { granularity: "rule" });
        assert.equal(r.body.granularity, "rule");
        const second = await focused(c, (await c.request("next")).stopped);
        assert.match(second.name, /^alert/);
        const back = await focused(c, (await c.request("stepBack")).stopped);
        assert.match(back.name, /^high/);
        await c.request("ds/stepGranularity", { granularity: "pump" });
        const pump = await c.request("next");
        const ts = await threads(c);
        assert.deepEqual(ts.map((x) => x.name.replace(/\(.*$/, "").replace(/ !\d+$/, "")), ["high", "alert"],
                         "at a settled point, the pump just run");
        assert.ok(pump.stopped);
        await c.request("ds/stepGranularity", { granularity: "input" });
        const input = await c.request("next");
        assert.ok(input.stopped);
        const pause = await c.request("pause");
        assert.equal(pause.stopped.reason, "pause");
        const start = await c.request("reverseContinue");
        assert.equal(start.stopped.reason, "step");
        assert.match(start.stopped.description, /the start/);
        const before = await c.request("stepBack");
        assert.ok(before.output.some((o) => /at the start/.test(o.output)));
        await c.request("disconnect");
    });

    // @spec [NDBG.11.1.4]
    test("pause after a step is answered, then stopped with reason `pause` where the session is, which does not move",
         async () => {
        const c = await session(REPLAY());
        const step = await c.request("next");
        assert.equal(step.stopped.reason, "step");
        const at = await focused(c, step.stopped);
        const p = await c.request("pause");
        assert.equal(p.ok, true, p.message);
        assert.equal(p.events.filter((e) => e.event === "stopped").length, 1, "one stopped, after the response");
        assert.equal(p.stopped.reason, "pause");
        assert.equal(p.stopped.threadId, step.stopped.threadId);
        const still = await focused(c, p.stopped);
        // A frame's id is the stop's to give; where it is, is the frame's name and place.
        const where = (/** @type {any[]} */ fs) => fs.map((f) => [f.name, f.line, f.column, f.source?.path ?? null]);
        assert.deepEqual(where(still.frames), where(at.frames), "the same position as before");
        assert.equal(still.name, at.name);
        await c.request("disconnect");
    });

    test("stepIn goes to the firing the action caused; stepInTargets lists it; stepOut runs past what the firing caused", async () => {
        const c = await session(REPLAY());
        const s = await c.request("next");
        assert.match((await focused(c, s.stopped)).name, /^high/);
        const targets = (await c.request("stepInTargets", { frameId: 0 })).body.targets;
        assert.equal(targets.length, 1);
        assert.match(targets[0].label, /^!2 alert/);
        const into = await c.request("stepIn", { threadId: s.stopped.threadId, targetId: targets[0].id });
        assert.match((await focused(c, into.stopped)).name, /^alert/);
        const back = await c.request("stepBack");
        assert.match((await focused(c, back.stopped)).name, /^high/);
        const wrong = await c.request("stepIn", { targetId: 999 });
        assert.equal(wrong.ok, false);
        assert.match(wrong.message, /not one the action caused/);
        const out = await c.request("stepOut");
        assert.equal(out.stopped.reason, "step");
        const ts = await threads(c);
        assert.ok(!ts.some((x) => /still to fire/.test(x.name)), "out of high: alert, which it caused, has fired");
        await c.request("disconnect");
    });

    test("reverseContinue runs back to the last breakpoint", async () => {
        const c = await session(REPLAY());
        await c.request("ds/stepGranularity", { granularity: "pump" });
        for (let i = 0; i < 4; i++) await c.request("next");
        await c.request("setFunctionBreakpoints", { breakpoints: [{ name: "alert" }] });
        const r = await c.request("reverseContinue");
        assert.equal(r.stopped.reason, "breakpoint");
        assert.match((await focused(c, r.stopped)).name, /^alert/);
        await c.request("disconnect");
    });

    test("goto targets: each firing on a rule line, each assert on a schema line; goto lands on one", async () => {
        const c = await session(REPLAY());
        const rule = (await c.request("gotoTargets", { source: { path: SOURCE }, line: lineOf("rule high:") })).body.targets;
        assert.equal(rule.length, 1);
        assert.match(rule[0].label, /^!1 at T=0\.000s$/);
        const schema = (await c.request("gotoTargets", { source: { path: SOURCE }, line: lineOf("schema Reading") })).body.targets;
        assert.equal(schema.length, 2);
        for (const t of schema) assert.match(t.label, /^#\d+ at T=\d+\.\d{3}s$/);
        const none = (await c.request("gotoTargets", { source: { path: SOURCE }, line: lineOf("use default") })).body.targets;
        assert.deepEqual(none, []);
        const g = await c.request("goto", { threadId: 1, targetId: rule[0].id });
        assert.equal(g.stopped.reason, "goto");
        assert.match((await focused(c, g.stopped)).name, /^high/);
        const bad = await c.request("goto", { targetId: 999 });
        assert.equal(bad.ok, false);
        await c.request("disconnect");
    });
});

describe("replay: breakpoints", { skip: NO_DSC }, () => {
    test("a line breakpoint holds on a rule line and is refused on any other", async () => {
        let set;
        const c = await session(REPLAY(), async (cl) => {
            set = await cl.request("setBreakpoints", { source: { path: SOURCE },
                                                       breakpoints: [{ line: lineOf("rule high:") }, { line: lineOf("rule high:") + 1 }] });
        });
        const [on, off] = set.body.breakpoints;
        assert.equal(on.verified, true);
        assert.equal(on.line, lineOf("rule high:"));
        assert.equal(off.verified, false);
        assert.equal(off.message, "DS breakpoints must be on rule, after or on response lines, or use "
            + "ds/setFactBreakpoints for fact-event breakpoints");
        const r = await c.request("continue");
        assert.equal(r.stopped.reason, "breakpoint");
        assert.deepEqual(r.stopped.hitBreakpointIds, [on.id]);
        await c.request("disconnect");
    });

    // @spec [NDBG.12.1.1]
    test("a breakpoint on an `after` line stops only in that body's firings, one on an `on response` line only in its",
         async () => {
        const text = `use default

schema Trig scope logical:
    tag: String key

schema Reply scope ttl 1_min:
    corr: String
    ok: Bool

service svc.ask:
    "test stub"
    response Reply

rule later:
    Trig t where t.tag == "later"
->
    after 5_s:
        log info "later"

rule asking:
    Trig t where t.tag == "ask"
->
    call svc.ask nocooldown as t.tag
        on response.ok == true:
            log info "answered"
`;
        const src = join(DIR, "dsdb_bodies.ds");
        writeFileSync(src, text);
        const ds = await openTarget(await loadBinding());
        const dsc = await compileFile(ds, src, []);
        const dscPath = join(DIR, "dsdb_bodies.dsc");
        writeFileSync(dscPath, dsc);
        // Both rules fire at 0 s; the reply answers the call at 1 s, and the
        // timer falls due at 5 s, so each body fires once, after its rule.
        const { EngineTimeline } = await import("../lib/core/engine-timeline.js");
        const live = EngineTimeline.live(ds, dsc);
        live.assertFact("Trig", { tag: "later" });
        live.assertFact("Trig", { tag: "ask" });
        live.advance(1_000_000_000n);
        live.assertFact("Reply", { corr: "ask", ok: true });
        live.advance(5_000_000_000n);
        const tracePath = join(DIR, "dsdb_bodies.trace");
        writeFileSync(tracePath, live.bytes());
        live.close();

        const lines = text.split("\n");
        const lineOfIn = (/** @type {string} */ s) => lines.findIndex((l) => l.trimStart().startsWith(s)) + 1;
        const afterLine = lineOfIn("after 5_s:"), responseLine = lineOfIn("on response.ok");
        let set;
        const c = await session({ program: dscPath, trace: tracePath, source: src }, async (cl) => {
            set = await cl.request("setBreakpoints", { source: { path: src },
                                                       breakpoints: [{ line: afterLine }, { line: responseLine }] });
        });
        const [onAfter, onResponse] = set.body.breakpoints;
        assert.equal(onAfter.verified, true, onAfter.message);
        assert.equal(onResponse.verified, true, onResponse.message);
        // Neither rule's own firing stops: the response's body at 1 s, then the
        // timer's at 5 s, then nothing.
        const first = await c.request("continue");
        assert.equal(first.stopped.reason, "breakpoint");
        assert.deepEqual(first.stopped.hitBreakpointIds, [onResponse.id], "the on response body");
        const second = await c.request("continue");
        assert.equal(second.stopped.reason, "breakpoint");
        assert.deepEqual(second.stopped.hitBreakpointIds, [onAfter.id], "the after body");
        const end = await c.request("continue");
        assert.notEqual(end.stopped.reason, "breakpoint", "no other firing stops");
        await c.request("disconnect");
    });

    test("conditions: compiled against the rule's patterns; a false one never stops, a bad one is unverified", async () => {
        const c = await session(REPLAY());
        const set = await c.request("setFunctionBreakpoints", { breakpoints: [
            { name: "high", condition: 'r.sensor == "zzz"' }, { name: "alert", condition: "h.nope > 1.0" }] });
        assert.equal(set.body.breakpoints[0].verified, true);
        assert.equal(set.body.breakpoints[1].verified, false);
        assert.ok(set.body.breakpoints[1].message);
        const end = await c.request("continue");
        assert.equal(end.stopped.reason, "pause");
        assert.equal(end.stopped.description, "the end of the trace");
        await c.request("reverseContinue");
        await c.request("setFunctionBreakpoints", { breakpoints: [{ name: "high", condition: 'r.sensor == "a"' }] });
        const hit = await c.request("continue");
        assert.equal(hit.stopped.reason, "breakpoint");
        await c.request("disconnect");
    });

    test("hit counts count from the timeline's start; a malformed one is unverified", async () => {
        const c = await session(REPLAY());
        const set = await c.request("setFunctionBreakpoints", { breakpoints: [{ name: "alert", hitCondition: "2" },
                                                                              { name: "high", hitCondition: "often" }] });
        assert.equal(set.body.breakpoints[0].verified, true);
        assert.match(set.body.breakpoints[1].message, /not a hit count/);
        assert.equal((await c.request("continue")).stopped.reason, "pause", "alert fires once: no second hit");
        await c.request("reverseContinue");
        await c.request("setFunctionBreakpoints", { breakpoints: [{ name: "alert", hitCondition: "1" }] });
        assert.equal((await c.request("continue")).stopped.reason, "breakpoint");
        await c.request("disconnect");
    });

    test("a logpoint logs as the session passes its firing forward, opening with the firing and instant, and never stops", async () => {
        const c = await session(REPLAY());
        const set = await c.request("setFunctionBreakpoints", { breakpoints: [{ name: "high", logMessage: "level={r.level}" }] });
        assert.equal(set.body.breakpoints[0].verified, true);
        const r = await c.request("continue");
        assert.equal(r.stopped.reason, "pause");
        const lines = r.output.filter((o) => o.category === "important").map((o) => o.output);
        assert.equal(lines.length, 1);
        assert.match(lines[0], /^!1 at T=0\.000s: level=90/);
        const back = await c.request("reverseContinue");
        assert.ok(!back.output.some((o) => o.category === "important"), "moving back logs nothing");
        await c.request("disconnect");
    });

    test("fact breakpoints: assert with a condition, retract by TTL and by lost support, each described; bad ones unverified", async () => {
        const c = await session(REPLAY());
        const set = await c.request("ds/setFactBreakpoints", { breakpoints: [
            { schema: "Reading", on: ["assert"], where: "reading.level > 50.0" },
            { schema: "Nope", on: ["assert"] },
            { schema: "Reading", on: ["modify"] },
            { schema: "Reading", on: ["assert"], where: "reading.nope > 1.0" },
            { schema: "$ClockTick", on: ["assert"] }] });
        const [ok, schema, on, where, tick] = set.body.breakpoints;
        assert.equal(ok.verified, true);
        assert.equal(schema.message, "no schema 'Nope'");
        assert.match(on.message, /^on must be/);
        assert.equal(where.verified, false);
        assert.equal(tick.verified, false);
        const a = await c.request("continue");
        assert.equal(a.stopped.reason, "data breakpoint");
        assert.match(a.stopped.description, /^Reading #\d+ asserted: sensor=a, level=90/);
        assert.equal((await c.request("continue")).stopped.reason, "pause", "Reading b's level fails the condition");
        await c.request("reverseContinue");
        await c.request("ds/setFactBreakpoints", { breakpoints: [{ schema: "Reading", on: ["retract"] },
                                                                 { schema: "High", on: ["retract"] }] });
        const seen = [];
        for (let i = 0; i < 3; i++) {
            const r = await c.request("continue");
            if (r.stopped.reason !== "data breakpoint") break;
            seen.push(r.stopped.description);
        }
        assert.ok(seen.some((d) => /^Reading #\d+ retracted \(ttl_expiry\)/.test(d)), seen.join("\n"));
        assert.ok(seen.some((d) => /^High #\d+ retracted \(support_lost\)/.test(d)), seen.join("\n"));
        await c.request("disconnect");
    });

    test("cache breakpoints: set and delete stop in replay, a get is unverified; the Cache scope shows the key", async () => {
        const c = await session(REPLAY());
        const set = await c.request("ds/setCacheBreakpoints", { breakpoints: [{ key: "last", on: ["set", "delete"] },
                                                                              { key: "", on: ["get"] },
                                                                              { key: "last", on: ["write"] }] });
        assert.equal(set.body.breakpoints[0].verified, true);
        assert.equal(set.body.breakpoints[1].message, "a trace does not record cache reads");
        assert.match(set.body.breakpoints[2].message, /^on must be/);
        const s = await c.request("continue");
        assert.equal(s.stopped.reason, "data breakpoint");
        assert.equal(s.stopped.description, "cache set last = 7");
        const t = await focused(c, s.stopped);
        assert.match(t.name, /^remember/);
        const cache = await scope(c, t.frames[0].id, "Cache");
        assert.match(named(cache, "last").value, /^7 \(TTL 30\.000s left\)$/);
        const d = await c.request("continue");
        assert.equal(d.stopped.description, "cache delete last (delete)");
        await c.request("disconnect");
    });

    test("exception filters: a fault, and a pump that ends with a call waiting; an unknown filter is refused", async () => {
        const c = await session(REPLAY());
        const bad = await c.request("setExceptionBreakpoints", { filters: ["nope"] });
        assert.equal(bad.ok, false);
        await c.request("setExceptionBreakpoints", { filters: ["fault"] });
        const f = await c.request("continue");
        assert.equal(f.stopped.reason, "exception");
        assert.match(f.stopped.description, /computation error in divide/);
        await c.request("setExceptionBreakpoints", { filters: ["unanswered_call"] });
        const w = await c.request("continue");
        assert.equal(w.stopped.reason, "exception");
        assert.match(w.stopped.description, /^call 1 svc\.ping is still waiting for its answer$/);
        const calls = await scope(c, (await focused(c, w.stopped)).frames[0].id, "Calls");
        assert.match(named(calls, "call 1").value, /^svc\.ping as "ping": waiting$/);
        await c.request("disconnect");
    });
});

describe("replay: inspection", { skip: NO_DSC }, () => {
    test("at a settled point: justifiers, working memory, lineage, activation path, the network, a match trace, refractions", async () => {
        const c = await session(REPLAY());
        await c.request("ds/stepGranularity", { granularity: "pump" });
        await c.request("next");
        const high = (await c.request("ds/getWorkingMemory", { schema: "High" })).body;
        assert.equal(high.total, 1);
        assert.equal(high.facts[0].logical, true);
        assert.equal(high.facts[0]._justifiers, 1);
        const j = (await c.request("ds/getJustifiers", { fact_id: high.facts[0].fact_id })).body.justifiers;
        assert.equal(j.length, 1);
        assert.equal(j[0].rule_name, "high");
        assert.equal(j[0].firing, "!1");
        const readings = (await c.request("ds/getWorkingMemory", { schema: "Reading" })).body;
        assert.equal(readings.total, 1);
        assert.equal(readings.facts[0].slots.sensor, "a");
        assert.equal(readings.facts[0].ttl_remaining_ns, 60_000_000_000);
        const where = (await c.request("ds/getWorkingMemory", { schema: "Reading", where: "reading.level > 95.0" })).body;
        assert.equal(where.total, 0);
        const noSchema = await c.request("ds/getWorkingMemory", { where: "reading.level > 1.0" });
        assert.equal(noSchema.ok, false);
        assert.match(noSchema.message, /`where` needs `schema`/);
        const all = (await c.request("ds/getWorkingMemory", { limit: 1 })).body;
        assert.equal(all.facts.length, 1);
        assert.ok(all.total >= 3, `Reading, High and Alert at least (${all.total})`);
        const alert = (await c.request("ds/getWorkingMemory", { schema: "Alert" })).body.facts[0];
        const lineage = (await c.request("ds/getFactLineage", { fact_id: alert.fact_id })).body;
        assert.equal(lineage.asserter.kind, "rule");
        assert.equal(lineage.asserter.rule_name, "alert");
        assert.equal(lineage.asserter.firing, "!2");
        assert.equal(lineage.retractor, null);
        const input = (await c.request("ds/getFactLineage", { fact_id: readings.facts[0].fact_id })).body;
        assert.equal(input.asserter.kind, "input");
        const path = (await c.request("ds/getActivationPath", { firing: "!2" })).body;
        assert.equal(path.rule_name, "alert");
        assert.equal(path.steps[0].binding, "h");
        assert.equal(path.steps[0].schema, "High");
        assert.equal(path.steps[0].join_result, "passed");
        const ts = await threads(c);
        const byThread = (await c.request("ds/getActivationPath", { threadId: ts.find((t) => /^alert/.test(t.name)).id })).body;
        assert.equal(byThread.rule_name, "alert");
        const missing = await c.request("ds/getActivationPath", { firing: "!99" });
        assert.equal(missing.ok, false);
        const net = (await c.request("ds/getReteNetwork", { rule_name: "alert", include_occupancy: true })).body;
        assert.ok(net.nodes.some((n) => n.kind === "terminal" && n.label === "alert"));
        assert.ok(Array.isArray(net.edges));
        // A node's line is its LineSpan's ([NDBG.3.1]): the terminal
        // has one, in the program's source; an alpha has none ([RDSC.14.3.6]).
        const term = net.nodes.find((n) => n.kind === "terminal" && n.label === "alert");
        assert.ok(term.source?.path.endsWith("dsdb_dap.ds"), JSON.stringify(term));
        assert.ok(Number.isInteger(term.source.line) && term.source.line >= 1, JSON.stringify(term.source));
        const alphas = net.nodes.filter((n) => n.kind === "alpha");
        assert.ok(alphas.length > 0, `alpha nodes among ${JSON.stringify(net.nodes.map((n) => n.kind))}`);
        assert.ok(alphas.every((n) => n.source === undefined), "no alpha carries a line");
        assert.equal((await c.request("ds/getReteNetwork", { rule_name: "nope" })).ok, false);
        const trace = (await c.request("ds/getMatchTrace", { fact_id: readings.facts[0].fact_id })).body;
        assert.equal(trace.joins_traced, false);
        assert.equal(trace.fact.schema, "Reading");
        assert.ok(Array.isArray(trace.path));
        assert.ok(trace.path.every((/** @type {any} */ x) => x.node_kind !== "alpha" || x.source === undefined),
                  "a traced alpha carries no line either");
        const refr = (await c.request("ds/getRefractedActivations", { rule_name: "" })).body;
        assert.deepEqual(refr.suppressed, []);
        assert.equal(refr.supersedure_reported, false);
        assert.ok(Array.isArray(refr.refracted));
        await c.request("disconnect");
    });

    test("mid-cascade, reading the engine is refused: no engine exists there", async () => {
        const c = await session(REPLAY());
        // To alert's firing: High is emitted, and the pump not yet over.
        await c.request("next");
        await c.request("next");
        const high = (await c.request("ds/getWorkingMemory", { schema: "High" })).body.facts[0];
        const j = await c.request("ds/getJustifiers", { fact_id: high.fact_id });
        assert.equal(j.ok, false);
        assert.match(j.message, /mid-cascade/);
        await c.request("disconnect");
    });

    test("at the end: what TTL and lost support retracted; the diff of working memory over the run", async () => {
        const c = await session(REPLAY());
        await c.request("continue");
        const facts = [];
        // Every fact the run held, from the diff over the whole of it.
        const span = (await c.request("ds/diffWorkingMemory", { from: { timeline: "%0", at_ns: 0 },
                                                                to: { timeline: "%0", at_ns: 63_000_000_000 } })).body;
        assert.ok(span.asserted.some((f) => f.schema === "Reading" && f.slots.sensor === "a"));
        assert.ok(span.retracted.some((f) => f.schema === "Reading" && f.slots.sensor === "a"), "the churn shows in both lists");
        for (const f of span.asserted) facts.push(f);
        const reading = facts.find((f) => f.schema === "Reading");
        const lr = (await c.request("ds/getFactLineage", { fact_id: reading.fact_id })).body;
        assert.equal(lr.retractor.kind, "ttl_expiry");
        const high = facts.find((f) => f.schema === "High");
        assert.equal((await c.request("ds/getFactLineage", { fact_id: high.fact_id })).body.retractor.kind, "support_lost");
        const same = await c.request("ds/diffWorkingMemory", { from: { timeline: "%0", at_ns: 5 }, to: { timeline: "%0", at_ns: 5 } });
        assert.equal(same.message, "from must be strictly before to");
        const past = await c.request("ds/diffWorkingMemory", { from: { timeline: "%0", at_ns: 0 },
                                                               to: { timeline: "%0", at_ns: 1e15 } });
        assert.equal(past.ok, false);
        assert.match(past.message, /has recorded/);
        await c.request("disconnect");
    });

    test("the timer agenda: the cooldown armed and the TTL deadlines, in clock order, after timers not listed", async () => {
        const c = await session(REPLAY(), async (cl) => {
            await cl.request("setFunctionBreakpoints", { breakpoints: [{ name: "cooled" }] });
        });
        await c.request("continue");
        await c.request("ds/stepGranularity", { granularity: "pump" });
        await c.request("next");
        const a = (await c.request("ds/getTimerAgenda")).body;
        assert.equal(a.after_listed, false);
        const cool = a.timers.find((t) => t.kind === "cooldown");
        assert.ok(cool, JSON.stringify(a.timers));
        assert.equal(cool.rule_name, "cooled");
        assert.ok(cool.remaining_ns > 0 && cool.remaining_ns <= 10_000_000_000);
        assert.ok(a.timers.some((t) => t.kind === "ttl" && /^#\d+$/.test(t.fact_id)));
        const ends = a.timers.map((t) => t.ends_at_ns);
        assert.deepEqual(ends, [...ends].sort((x, y) => x - y));
        await c.request("disconnect");
    });

    test("a Json slot is a tree of its keys and indices", async () => {
        const c = await session(REPLAY(), async (cl) => {
            await cl.request("setFunctionBreakpoints", { breakpoints: [{ name: "noted" }] });
        });
        const r = await c.request("continue");
        const wm = await scope(c, (await focused(c, r.stopped)).frames[0].id, "Working Memory");
        const notes = await kids(c, named(wm, "Note"));
        const note = await kids(c, notes[0]);
        const doc = named(note, "doc");
        assert.equal(doc.value, "{1}");
        const a = named(await kids(c, doc), "a");
        assert.equal(a.value, "{1}");
        const arr = named(await kids(c, a), "b");
        assert.equal(arr.value, "[2]");
        assert.deepEqual((await kids(c, arr)).map((v) => [v.name, v.value]), [["[0]", "1"], ["[1]", "2"]]);
        await c.request("disconnect");
    });

    // @spec [NDBG.13.7.1]
    test("evaluate: a DS expression over the frame's bindings, at the point; with no frame, none; what does not compile is refused", async () => {
        const c = await session(REPLAY(), async (cl) => {
            await cl.request("setFunctionBreakpoints", { breakpoints: [{ name: "alert" }] });
        });
        const r = await c.request("continue");
        const frame = (await focused(c, r.stopped)).frames[0].id;
        const slot = await c.request("evaluate", { expression: "h.sensor", frameId: frame, context: "watch" });
        assert.ok(slot.ok, slot.message);
        assert.deepEqual([slot.body.result, slot.body.variablesReference], ['"a"', 0], "a String, as variables writes one");
        const hover = await c.request("evaluate", { expression: "h.sensor", frameId: frame, context: "hover" });
        assert.equal(hover.body?.result, '"a"', hover.message);
        const sum = await c.request("evaluate", { expression: "1 + 2", context: "watch" });
        assert.equal(sum.body?.result, "3", sum.message);
        const unbound = await c.request("evaluate", { expression: "h.sensor", context: "watch" });
        assert.equal(unbound.ok, false, "no frame, no bindings");
        const bad = await c.request("evaluate", { expression: "h.nope", frameId: frame, context: "watch" });
        assert.equal(bad.ok, false);
        assert.match(bad.message, /nope/, "the compiler's detail");
        // A refusal is in the user's terms: the expression, its column
        // and a caret under it, never the program dsdb compiled it into.
        for (const [r, why] of [[unbound, "no frame"], [bad, "a slot that is not there"]]) {
            assert.doesNotMatch(r.message, /col_\d|query line|<query>|let /, `${why}: ${r.message}`);
            assert.match(r.message, /^`h\.\w+`, column \d+: DS_VALIDATE_\w+: /, `${why}: ${r.message}`);
        }
        assert.match(unbound.message, /^ {4}h\.sensor\n {4}\^/m, unbound.message);
        assert.match(unbound.message, /the engine's thread binds nothing: pause in a firing to read its bindings/,
                     unbound.message);
        await c.request("disconnect");
    });

    // @spec [NDBG.13.7.1]
    test("evaluate: a `repl` line, typed in the debug console, is answered exactly as a `watch`; any other context is refused, naming it", async () => {
        const c = await session(REPLAY(), async (cl) => {
            await cl.request("setFunctionBreakpoints", { breakpoints: [{ name: "high" }] });
        });
        const r = await c.request("continue");
        const frame = (await focused(c, r.stopped)).frames[0].id;
        const watch = await c.request("evaluate", { expression: "r.level + 1.0", frameId: frame, context: "watch" });
        assert.ok(watch.ok, watch.message);
        const repl = await c.request("evaluate", { expression: "r.level + 1.0", frameId: frame, context: "repl" });
        assert.ok(repl.ok, repl.message);
        assert.deepEqual(repl.body, watch.body);
        const clip = await c.request("evaluate", { expression: "r.level + 1.0", frameId: frame, context: "clipboard" });
        assert.equal(clip.ok, false);
        assert.match(clip.message, /"clipboard"/);
        await c.request("disconnect");
    });

    // @spec [NDBG.13.7.2]
    test("evaluate: a Json value is a tree, seven levels down to its leaf", async () => {
        const c = await session(LIVE());
        const doc = '{"a":{"b":{"c":{"d":{"e":{"f":{"g":1}}}}}}}';
        assert.ok((await c.request("ds/assertFact", { schema: "Note", slots: { doc } })).ok);
        const noted = (await threads(c)).find((t) => /^noted/.test(t.name));
        assert.ok(noted, "the pump just run fired noted");
        const frame = (await c.request("stackTrace", { threadId: noted.id })).body.stackFrames[0].id;
        const got = await c.request("evaluate", { expression: "n.doc", frameId: frame, context: "watch" });
        assert.ok(got.ok, got.message);
        assert.equal(got.body.result, "{1}");
        let v = { name: "result", variablesReference: got.body.variablesReference };
        for (const key of ["a", "b", "c", "d", "e", "f"]) v = named(await kids(c, v), key);
        assert.equal(named(await kids(c, v), "g").value, "1");
        await c.request("disconnect");
    });

    // @spec [NDBG.13.7.2]
    test("evaluate: an expression whose evaluation faults is refused, naming the fault's class", async () => {
        const c = await session(REPLAY(), async (cl) => {
            await cl.request("setFunctionBreakpoints", { breakpoints: [{ name: "divide" }] });
        });
        const r = await c.request("continue");
        const frame = (await focused(c, r.stopped)).frames[0].id;
        const x = await c.request("evaluate", { expression: "t.x", frameId: frame, context: "watch" });
        assert.equal(x.body?.result, "1", x.message);
        const q = await c.request("evaluate", { expression: "t.x / t.y", frameId: frame, context: "watch" });
        assert.equal(q.ok, false);
        assert.match(q.message, /^the expression faulted: a ComputationError$/);
        await c.request("disconnect");
    });

    // @spec [NDBG.13.5.2]
    test("a Json slot has no depth cap: seven levels down, the leaf", async () => {
        const c = await session(LIVE());
        const doc = '{"a":{"b":{"c":{"d":{"e":{"f":{"g":1}}}}}}}';
        const t = await c.request("ds/assertFact", { schema: "Note", slots: { doc } });
        assert.ok(t.ok, t.message);
        const frame0 = (await c.request("stackTrace", { threadId: (await threads(c))[0].id })).body.stackFrames[0].id;
        const notes = await kids(c, named(await scope(c, frame0, "Working Memory"), "Note"));
        let v = named(await kids(c, notes[0]), "doc");
        for (const key of ["a", "b", "c", "d", "e", "f"]) {
            assert.equal(v.value, "{1}", key);
            v = named(await kids(c, v), key);
        }
        const g = named(await kids(c, v), "g");
        assert.equal(g.value, "1");
        assert.equal(g.variablesReference, 0, "a leaf");
        await c.request("disconnect");
    });

    test("a variable reference ends with its stop", async () => {
        const c = await session(REPLAY());
        const first = await c.request("next");
        const frame0 = (await focused(c, first.stopped)).frames[0].id;
        const ref = (await c.request("scopes", { frameId: frame0 })).body.scopes[0].variablesReference;
        await c.request("next");
        const stale = await c.request("variables", { variablesReference: ref });
        assert.equal(stale.ok, false);
        assert.match(stale.message, /not valid at this stop/);
        await c.request("disconnect");
    });
});

describe("replay: injects and timelines", { skip: NO_DSC }, () => {
    test("an inject behind the end opens a fork the session follows; timelines are listed, switched and dropped", async () => {
        const c = await session(REPLAY());
        await c.request("ds/stepGranularity", { granularity: "pump" });
        await c.request("next");
        const r = await c.request("ds/assertFact", { schema: "Reading", slots: { sensor: "c", level: 95.0 } });
        assert.ok(r.ok, r.message);
        assert.equal(r.body.timeline, "%1");
        assert.match(r.body.fact_id, /^#\d+$/);
        assert.match(r.body.message, /^opened fork %1 at T=0\.000s with Reading #\d+ asserted$/);
        assert.ok(r.output.some((o) => o.output.startsWith(r.body.message)), "the message goes out as output too");
        assert.ok(r.stopped);
        const lineage = (await c.request("ds/getFactLineage", { fact_id: r.body.fact_id })).body;
        assert.equal(lineage.asserter.kind, "input", "the fork holds the injected fact");
        const tls = (await c.request("ds/timelines")).body.timelines;
        assert.deepEqual(tls.map((t) => [t.timeline, t.current]), [["%0", false], ["%1", true]]);
        assert.equal(tls[1].from, "%0");
        assert.ok(tls[1].change);
        const dropHere = await c.request("ds/dropTimeline", { timeline: "%1" });
        assert.equal(dropHere.ok, false);
        assert.match(dropHere.message, /the session follows/);
        const sw = await c.request("ds/switchTimeline", { timeline: "%0" });
        assert.equal(sw.stopped.reason, "goto");
        const dropReal = await c.request("ds/dropTimeline", { timeline: "%0" });
        assert.equal(dropReal.ok, false);
        assert.match(dropReal.message, /real run/);
        assert.deepEqual((await c.request("ds/dropTimeline", { timeline: "%1" })).body.dropped, ["%1"]);
        assert.equal((await c.request("ds/timelines")).body.timelines.length, 1);
        assert.equal((await c.request("ds/switchTimeline", { timeline: "%7" })).ok, false);
        await c.request("disconnect");
    });

    test("injects are refused for an unknown schema, a slot of the wrong type, a fact not in working memory, a call not waiting", async () => {
        const c = await session(REPLAY());
        await c.request("ds/stepGranularity", { granularity: "pump" });
        await c.request("next");
        const schema = await c.request("ds/assertFact", { schema: "Nope", slots: {} });
        assert.equal(schema.message, "no schema 'Nope'");
        const slot = await c.request("ds/assertFact", { schema: "Reading", slots: { sensor: "c", level: "high" } });
        assert.equal(slot.ok, false);
        assert.match(slot.message, /level/);
        // No per-fact TTL: a well-formed `ttl` is refused too.
        const ttl = await c.request("ds/assertFact", { schema: "Reading", slots: { sensor: "c", level: 1.0 }, ttl: "30_s" });
        assert.equal(ttl.ok, false);
        assert.match(ttl.message, /per-fact TTL/);
        const gone = await c.request("ds/retractFact", { fact_id: "#999" });
        assert.equal(gone.message, "fact '#999' not in working memory");
        const call = await c.request("ds/answerCall", { corr: "zzz", response: {} });
        assert.equal(call.ok, false);
        assert.match(call.message, /no call waiting/);
        const clock = await c.request("ds/advanceClock", { by: "5_s" });
        assert.equal(clock.ok, false);
        assert.match(clock.message, /recorded run's/);
        await c.request("disconnect");
    });

    test("a mock that answers a recorded call otherwise opens a fork at it", async () => {
        const c = await session(REPLAY());
        const bad = await c.request("ds/installMock", { corr: "ping", service: "svc.ping", response: {} });
        assert.match(bad.message, /exactly one of `corr` and `service`/);
        const none = await c.request("ds/installMock", { service: "svc.ping" });
        assert.match(none.message, /exactly one of `response` and `error`/);
        const m = await c.request("ds/installMock", { service: "svc.ping", response: { ok: false } });
        assert.equal(m.body.mock_id, "mock-0001");
        assert.match(m.body.message, /^opened fork %1/);
        assert.ok(m.stopped);
        assert.equal((await c.request("ds/timelines")).body.timelines.length, 2);
        const removed = await c.request("ds/removeMock", { mock_id: "mock-0001" });
        assert.equal(removed.ok, false, "a mock of `times: 1` went when it answered");
        await c.request("disconnect");
    });
});

describe("live", { skip: NO_DSC }, () => {
    // The shell's opening line names shell commands, which an editor cannot
    // send, and calls the engine empty when fact files are about to feed it.
    // The adapter's own lines are what it says, the fact files' count among
    // them, which shows the client is hearing the launch's output at all.
    test("a live launch says nothing of the shell: no `from here emit`, no empty engine", async () => {
        const said = (/** @type {Client} */ c) => c.msgs.filter((m) => m.type === "event" && m.event === "output")
            .map((m) => m.body.output).join("");
        for (const launch of [LIVE({ facts: [FACTS_PATH] }), LIVE()]) {
            const c = await session(launch);
            const out = said(c);
            assert.doesNotMatch(out, /from here emit|an empty engine/, out);
            if (launch.facts) assert.match(out, /^2 inputs to feed from the fact files$/m, out);
            await c.request("disconnect");
            assert.equal(await c.done, 0);
        }
    });

    // @spec [LFAC.9.2]
    test("a fact-file row with no `ts` takes its `@at`, as batch's and the shell's do", async () => {
        const facts = join(DIR, "then", "Reading.jsonl");
        mkdirSync(join(DIR, "then"), { recursive: true });
        writeFileSync(facts, '{"@at":"1_s","id":"a"}\n{"@at":"2_s","id":"a"}\n');
        const c = await session({ program: join(FIXTURES, "dsdb_then.dsc"), facts: [facts] });
        for (const step of ["first", "second"]) assert.ok((await c.request("next")).ok, `${step} row`);
        // `Paired`, the rule's emit: its `publish Pair` asserts nothing here ([LTIE.4.3]).
        const pairs = (await c.request("ds/getWorkingMemory", { schema: "Paired" })).body.facts;
        assert.equal(pairs.length, 1, "`then ... within 3_s` compared the rows' `ts`, 1 s apart");
        await c.request("disconnect");
        assert.equal(await c.done, 0);
    });

    test("a live session feeds its fact files one input at a step, says when none is left, and moves its clock", async () => {
        const c = await session(LIVE({ facts: [FACTS_PATH], events: ["factAsserted", "callMade"] }));
        // Said as the launch opens the session, so before its response.
        assert.ok(c.msgs.some((m) => m.event === "output" && /2 inputs to feed from the fact files/.test(m.body.output)));
        assert.equal(c.entry.stopped.reason, "entry");
        const action = await c.request("ds/stepGranularity", { granularity: "action" });
        assert.equal(action.ok, false);
        assert.match(action.message, /replay only/);
        const first = await c.request("next");
        const asserted = first.events.find((e) => e.event === "ds/factAsserted");
        assert.ok(asserted, "ds/factAsserted, chosen at launch");
        assert.equal(asserted.body.schema, "Reading");
        assert.equal(asserted.body.asserter.kind, "input");
        assert.match(asserted.body.fact_id, /^#\d+$/);
        const ts = await threads(c);
        assert.deepEqual(ts.map((t) => t.name.replace(/[( ].*$/, "")), ["high", "alert"], "the firings of the pump just run");
        const second = await c.request("stepIn");
        assert.ok(second.stopped, "stepIn live is next");
        const none = await c.request("next");
        assert.ok(none.output.some((o) => /nothing left to feed the engine/.test(o.output)));
        const tick = await c.request("ds/advanceClock", { by: "5_s" });
        assert.ok(tick.ok, tick.message);
        assert.equal(tick.stopped.reason, "step");
        assert.ok((await c.request("ds/advanceClock", { by: 1000 })).ok, "whole nanoseconds too");
        assert.equal((await c.request("ds/advanceClock", { by: "soon" })).ok, false);
        const bad = await c.request("ds/streamEvents", { kinds: ["bogus"] });
        assert.match(bad.message, /no event `bogus`/);
        await c.request("disconnect");
    });

    test("a fact-file row is fed as batch mode feeds one: a deadline before its `@at` is a pump at its own instant", async () => {
        const dir = join(DIR, "expiry");
        mkdirSync(dir, { recursive: true });
        const facts = join(dir, "Reading.jsonl");
        // a's 60 s TTL falls due before b's row.
        writeFileSync(facts, '{"@at": "0_s", "sensor": "a", "level": 90.0}\n{"@at": "61_s", "sensor": "b", "level": 10.0}\n');
        const readings = (/** @type {any} */ r) => r.events.filter((e) => e.event.startsWith("ds/") && e.body.schema === "Reading")
            .map((e) => `${e.event} ${e.event === "ds/factAsserted" ? e.body.slots.sensor : e.body.retractor.kind}`);
        const launch = LIVE({ facts: [facts], events: ["factAsserted", "factRetracted"] });

        const pump = await session(launch);
        assert.deepEqual(readings(await pump.request("next")), ["ds/factAsserted a"]);
        assert.deepEqual(readings(await pump.request("next")), ["ds/factRetracted ttl_expiry"],
                         "`pump`, live's default: a's expiry is a step of its own, and b waits for the next");
        assert.deepEqual(readings(await pump.request("next")), ["ds/factAsserted b"]);
        await pump.request("disconnect");

        const input = await session(launch);
        assert.ok((await input.request("ds/stepGranularity", { granularity: "input" })).ok);
        assert.deepEqual(readings(await input.request("next")), ["ds/factAsserted a"]);
        assert.deepEqual(readings(await input.request("next")), ["ds/factRetracted ttl_expiry", "ds/factAsserted b"],
                         "`input`: the step takes a's expiry, at 60 s, and then b's row; not b first, as a 61 s pump would");
        await input.request("disconnect");
    });

    test("live injects land in the run; a call is answered; a fact retracted; the call events are sent", async () => {
        const c = await session(LIVE({ events: ["callMade", "callAnswered", "factRetracted"] }));
        const t = await c.request("ds/assertFact", { schema: "Trig", slots: { tag: "ping", x: 0, y: 1 } });
        assert.ok(t.ok, t.message);
        assert.match(t.body.message, /^asserted Trig #\d+ into the real run$/);
        assert.equal(t.body.timeline, "%0");
        const made = t.events.find((e) => e.event === "ds/callMade");
        assert.ok(made);
        assert.equal(made.body.service, "svc.ping");
        assert.equal(made.body.corr, "ping");
        assert.match(made.body.firing, /^!\d+$/);
        const a = await c.request("ds/answerCall", { corr: "ping", response: { ok: true } });
        assert.ok(a.ok, a.message);
        assert.match(a.body.message, /^answered call 1 \(svc\.ping\) into the real run$/);
        const answered = a.events.find((e) => e.event === "ds/callAnswered");
        assert.ok(answered);
        assert.deepEqual(answered.body.response, { ok: true });
        const r = await c.request("ds/retractFact", { fact_id: t.body.fact_id });
        assert.ok(r.ok, r.message);
        assert.equal(r.body.message, `retracted Trig ${t.body.fact_id} from the real run`);
        assert.ok(r.events.some((e) => e.event === "ds/factRetracted" && e.body.retractor.kind === "input"));
        await c.request("disconnect");
    });

    test("a standing mock answers each call it matches as it is issued; removeMock takes it out", async () => {
        const c = await session(LIVE());
        const m = await c.request("ds/installMock", { service: "svc.ping", response: { ok: false }, times: 0 });
        assert.equal(m.body.mock_id, "mock-0001");
        const t = await c.request("ds/assertFact", { schema: "Trig", slots: { tag: "ping", x: 0, y: 1 } });
        assert.ok(t.output.some((o) => /mock-0001 answered call 1 \(svc\.ping\)/.test(o.output)), JSON.stringify(t.output));
        const calls = await scope(c, (await focused(c, t.stopped)).frames[0].id, "Calls");
        assert.ok(calls.some((v) => /answered/.test(v.value)));
        assert.ok((await c.request("ds/removeMock", { mock_id: "mock-0001" })).ok);
        assert.equal((await c.request("ds/removeMock", { mock_id: "mock-0001" })).ok, false);
        await c.request("disconnect");
    });
});

// ── the program's own `log` lines ([NDBG.9.3.6]) ───────────────────────────

/** The `stdout` lines among a request's events. */
const stdout = (r) => r.output.filter((o) => o.category === "stdout").map((o) => o.output);
/** A program's line: the firing, the instant and the action's level open it. */
const PROGRAM_LINE = /^!\d+ at T=\d+\.\d{3}s: \w+: .*\n$/;

describe("the program's log lines are its output", { skip: NO_DSC }, () => {
    // @spec [NDBG.9.3.6]
    test("live: a `next` over a pump whose firing logs sends the line once, as `stdout`, with no stream event chosen", async () => {
        const dir = join(DIR, "logs");
        mkdirSync(dir, { recursive: true });
        const facts = join(dir, "Trig.jsonl");
        writeFileSync(facts, '{"@at": "0_s", "tag": "cool", "x": 0, "y": 1}\n');
        const c = await session(LIVE({ facts: [facts], events: [] }));
        const r = await c.request("next");
        assert.ok(r.ok, r.message);
        assert.deepEqual(stdout(r), ["!1 at T=0.000s: INFO: cooled\n"]);
        assert.ok(!r.events.some((e) => e.event.startsWith("ds/")), "`events: []` chose no stream event");
        await c.request("disconnect");
    });

    // @spec [NDBG.9.3.6]
    test("replay: stepping forward over a firing that logs sends its line once; moving back, and the re-drive reverse navigation does, send none", async () => {
        const c = await session(REPLAY());
        await c.request("ds/stepGranularity", { granularity: "rule" });
        // !3 noted logs "noted". Its line is sent once every action of the
        // firing is crossed: on the step from !3 to !4.
        const early = [];
        for (let i = 0; i < 3; i++) early.push(...stdout(await c.request("next")));
        assert.deepEqual(early, [], "up to !3's start, nothing has logged");
        const over = await c.request("next");
        assert.match((await focused(c, over.stopped)).name, /^remember/);
        assert.deepEqual(stdout(over), ["!3 at T=1.000s: INFO: noted\n"]);
        const back = await c.request("stepBack");
        assert.match((await focused(c, back.stopped)).name, /^noted/);
        const further = await c.request("stepBack");
        // Reverse navigation seeks a checkpoint and re-drives the engine from
        // it ([NDBG.14r.2.3]).
        const start = await c.request("reverseContinue");
        assert.match(start.stopped.description, /the start/);
        assert.deepEqual([...stdout(back), ...stdout(further), ...stdout(start)], [],
                         "moving back and re-driving log nothing: the line was sent once");
        // Each forward crossing sends it: the run to the end crosses !3 again.
        const all = stdout(await c.request("continue"));
        for (const l of all) assert.match(l, PROGRAM_LINE);
        assert.deepEqual(all.map((l) => l.replace(/^!\d+ at T=\S+ /, "")).filter((l) => /noted|cooled/.test(l)),
                         ["INFO: noted\n", "INFO: cooled\n"]);
        await c.request("disconnect");
    });
});

describe("session lifecycle", { skip: NO_DSC }, () => {
    test("restart opens the session again, keeps and re-verifies the breakpoints, and stops", async () => {
        const c = await session(REPLAY(), async (cl) => {
            await cl.request("setFunctionBreakpoints", { breakpoints: [{ name: "alert" }] });
        });
        // A fork to drop: opened at a settled point.
        await c.request("ds/stepGranularity", { granularity: "pump" });
        await c.request("next");
        assert.ok((await c.request("ds/assertFact", { schema: "Reading", slots: { sensor: "c", level: 95.0 } })).ok);
        assert.equal((await c.request("ds/timelines")).body.timelines.length, 2);
        const r = await c.request("restart");
        assert.ok(r.ok, r.message);
        assert.ok(r.events.some((e) => e.event === "breakpoint" && e.body.breakpoint.verified === true));
        assert.ok(r.output.some((o) => /restarted/.test(o.output)));
        assert.ok(r.stopped);
        assert.equal((await c.request("ds/timelines")).body.timelines.length, 1, "restart drops every fork");
        assert.equal((await c.request("continue")).stopped.reason, "breakpoint");
        await c.request("disconnect");
        assert.equal(await c.done, 0);
    });

    test("ds/loadRecording enters replay of a trace recorded with the session's program", async () => {
        const c = await session(LIVE());
        const r = await c.request("ds/loadRecording", { path: TRACE_PATH });
        assert.ok(r.ok, r.message);
        assert.ok(r.body.event_count > 0);
        assert.ok(r.body.rule_count >= 10);
        assert.ok(r.body.schema_count >= 6);
        assert.ok(r.body.duration_ns >= 63_000_000_000);
        assert.ok(r.stopped);
        assert.ok((await c.request("ds/stepGranularity", { granularity: "action" })).ok, "replay admits action steps");
        assert.equal((await c.request("ds/loadRecording", {})).ok, false);
        await c.request("disconnect");
    });

    // @spec [NDBG.14r.6.5]
    test("a trace recorded with another program is refused, the error body carrying DS_ERR_BND_DSC_MISMATCH",
         async () => {
        const other = join(DIR, "other.dsc");
        writeFileSync(other, readFileSync(join(FIXTURES, "dsdb_why.dsc")));
        const c = new Client();
        await c.request("initialize");
        const r = await c.request("launch", { program: other, trace: TRACE_PATH });
        assert.equal(r.ok, false);
        assert.match(r.message, /not recorded with this/);
        assert.match(r.message, /^ {2}dsc_hash: trace [0-9a-f]{16}, program [0-9a-f]{16}$/m);
        assert.deepEqual(r.body.error, { id: 1, format: r.message, variables: { code: "DS_ERR_BND_DSC_MISMATCH" } });
        assert.equal((await c.request("threads")).ok, false, "nothing is launched");
        await c.request("disconnect");
    });

    // @spec [NDBG.14r.6.5]
    test("a trace whose dialect_def_sha256 is not the program's, with the same dsc_hash, is refused with "
         + "DS_ERR_BND_DIALECT_MISMATCH", async () => {
        const jsBinding = await import(new URL("../../../bindings/js/lib/index.js", import.meta.url).href);
        const ds = await jsBinding.open({ target: TARGET });
        // The recorded trace, its StreamHeader's dialect_def_sha256 changed in
        // one byte in place: its length, its framing and its dsc_hash stay.
        const bytes = new Uint8Array(readFileSync(TRACE_PATH));
        const h = ds.readAtoms(bytes, { incremental: true }).atoms.find((a) => a.message === "StreamHeader");
        assert.ok(h, "the trace has a StreamHeader");
        const def = h.body.dialect_def_sha256;
        assert.equal(def.length, 32, "the recorded header carries a dialect_def_sha256");
        const body = bytes.subarray(h.bodyOffset, h.bodyOffset + h.bodyLength);
        const at = body.findIndex((_, i) => def.every((x, j) => body[i + j] === x));
        assert.ok(at >= 0, "the def's bytes are in the header's body");
        body[at] ^= 0xff;
        const changed = ds.readAtoms(bytes, { incremental: true }).atoms.find((a) => a.message === "StreamHeader").body;
        assert.notDeepEqual([...changed.dialect_def_sha256], [...def]);
        assert.deepEqual([...changed.dsc_hash], [...h.body.dsc_hash], "the dsc_hash is the recorded one");
        const path = join(DIR, "dialect.trace");
        writeFileSync(path, bytes);
        const c = new Client();
        await c.request("initialize");
        const r = await c.request("launch", { program: DSC_PATH, trace: path, source: SOURCE });
        assert.equal(r.ok, false, "the load is refused");
        assert.match(r.message, /not recorded with this/);
        assert.match(r.message, /^ {2}dialect_def_sha256: trace [0-9a-f]{16}, program [0-9a-f]{16}$/m);
        assert.deepEqual(r.body.error, { id: 1, format: r.message, variables: { code: "DS_ERR_BND_DIALECT_MISMATCH" } });
        await c.request("disconnect");
    });

    // @spec [NDBG.9.3.7]
    test("configurationDone before a launch is refused; after one it is answered, then stopped with reason `entry`",
         async () => {
        const c = new Client();
        await c.request("initialize", { adapterID: "ds" });
        const early = await c.request("configurationDone");
        assert.equal(early.ok, false);
        assert.ok(early.body?.error, "an error response, with its body");
        assert.equal(early.stopped, null, "no stopped before a launch");
        assert.ok((await c.request("launch", REPLAY())).ok);
        const done = await c.request("configurationDone");
        assert.equal(done.ok, true, done.message);
        const i = c.msgs.indexOf(done.res);
        const stop = c.msgs.findIndex((m, k) => k > i && m.type === "event" && m.event === "stopped");
        assert.ok(stop > i, "stopped follows the response");
        assert.equal(done.stopped.reason, "entry", "the session has not moved");
        await c.request("disconnect");
    });

    test("stream events: each kind as replay crosses it forward, none moving back; ds/streamEvents replaces the choice", async () => {
        const c = await session({ ...REPLAY(), events: ["factAsserted", "factRetracted", "logicalFactFlipped", "callMade",
                                                        "callAnswered"] });
        const fwd = await c.request("continue");
        const kinds = new Set(fwd.events.map((e) => e.event).filter((e) => e.startsWith("ds/")));
        for (const k of ["ds/factAsserted", "ds/factRetracted", "ds/logicalFactFlipped", "ds/callMade", "ds/callAnswered"])
            assert.ok(kinds.has(k), `${k} in ${[...kinds]}`);
        const flip = fwd.events.find((e) => e.event === "ds/logicalFactFlipped" && e.body.direction === "retract");
        assert.equal(flip.body.justifier_count, 0);
        const ttl = fwd.events.find((e) => e.event === "ds/factRetracted" && e.body.schema === "Reading");
        assert.equal(ttl.body.retractor.kind, "ttl_expiry");
        const back = await c.request("reverseContinue");
        assert.ok(!back.events.some((e) => e.event.startsWith("ds/")), "nothing moving back");
        assert.ok((await c.request("ds/streamEvents", { kinds: [] })).ok);
        const quiet = await c.request("continue");
        assert.ok(!quiet.events.some((e) => e.event.startsWith("ds/")), "an empty choice sends none");
        await c.request("disconnect");
    });

    test("a fact file that cannot be read refuses the launch", async () => {
        const c = new Client();
        await c.request("initialize");
        const r = await c.request("launch", LIVE({ facts: [join(DIR, "Missing.jsonl")] }));
        assert.equal(r.ok, false);
        assert.match(r.message, /Missing\.jsonl/);
        await c.request("disconnect");
    });

    test("a mock by corr with an error fails the call as a CallError", async () => {
        const c = await session(LIVE({ events: ["callAnswered"] }));
        // A code as [LECC.1.2] writes one: a malformed one (NDBG.14.15.3's
        // example `503`) enters as `internal.invariant` ([LECC.1.5]).
        const m = await c.request("ds/installMock", { corr: "ping", error: { code: "transport.unreachable", message: "bridge offline" } });
        assert.equal(m.body.mock_id, "mock-0001");
        const t = await c.request("ds/assertFact", { schema: "Trig", slots: { tag: "ping", x: 0, y: 1 } });
        assert.ok(t.output.some((o) => /mock-0001 answered call 1/.test(o.output)), JSON.stringify(t.output));
        const failed = t.events.find((e) => e.event === "ds/callAnswered");
        assert.ok(failed);
        assert.deepEqual(failed.body.error, { code: "transport.unreachable", message: "bridge offline" });
        await c.request("disconnect");
    });

    test("the `events` launch argument refuses an unknown event", async () => {
        const c = new Client();
        await c.request("initialize");
        const r = await c.request("launch", LIVE({ events: ["nope"] }));
        assert.equal(r.ok, false);
        assert.match(r.message, /no event `nope`/);
        await c.request("disconnect");
    });
});

// ── the published schema ───────────────────────────────────────────────────

describe("DAP's schema", () => {
    test("the js gate hands the suite the pinned schema", () => {
        // In the gate, a missing schema is the lane's defect, not a skip: a
        // check that runs over nothing reads as a pass.
        if (FIXTURES) assert.ok(SCHEMAS, "DS_JS_FIXTURES is set and DS_PROTOCOL_SCHEMAS is not");
    });

    // The checker fires: messages that break the schema, each one way, are
    // refused, and ones that keep it are not. Over the pinned schema itself.
    test("the checker refuses what breaks the schema and passes what keeps it", { skip: SCHEMAS ? false : "no DS_PROTOCOL_SCHEMAS" }, () => {
        const check = /** @type {(m: any) => string[]} */ (CHECK);
        const ok = (m) => assert.deepEqual(check(m), [], JSON.stringify(m));
        const bad = (m, says) => {
            const got = check(m);
            assert.ok(got.some((v) => v.includes(says)), `${JSON.stringify(m)}: want "${says}", got ${JSON.stringify(got)}`);
        };
        ok({ seq: 1, type: "event", event: "stopped", body: { reason: "step", threadId: 1 } });
        ok({ seq: 2, type: "response", request_seq: 1, success: true, command: "threads",
             body: { threads: [{ id: 1, name: "t" }] } });
        ok({ seq: 3, type: "response", request_seq: 1, success: false, command: "next", message: "no", body: {} });
        ok({ seq: 4, type: "event", event: "ds/custom", body: { anything: 1 } });
        bad({ seq: 1, type: "event", event: "stopped", body: {} }, "lacks `reason`");
        bad({ seq: 1, type: "event", event: "stopped", body: { reason: 5 } }, "is not string");
        bad({ seq: 1, type: "response", request_seq: 1, success: true, command: "threads", body: { threads: [{ id: "1", name: "t" }] } },
            "threads[0].id");
        bad({ seq: 0, type: "event", event: "initialized" }, "below 1");
        bad({ seq: 1, type: "response", request_seq: 1, success: false, command: "next", message: "no" }, "lacks `body`");
        bad({ seq: 1, type: "event" }, "lacks `event`");
        bad({ seq: 1, type: "response", request_seq: 1, success: true, command: "stackTrace", body: {} }, "lacks `stackFrames`");
    });

    test("the checker refuses a schema keyword it does not know, rather than pass it over", () => {
        const schema = { definitions: { ProtocolMessage: { type: "object", patternProperties: {} },
                                        Request: {}, Response: {}, ErrorResponse: {}, Event: {} } };
        assert.throws(() => dapChecker(schema)({ seq: 1, type: "x" }), /keyword `patternProperties`/);
    });

    // Last in the file, so every session above has been read: each message
    // the adapter sent kept the schema.
    test("every message ds dap sent in this file keeps DAP's schema", { skip: SCHEMAS ? false : "no DS_PROTOCOL_SCHEMAS" }, () => {
        assert.deepEqual([...new Set(VIOLATIONS)], []);
    });
});
