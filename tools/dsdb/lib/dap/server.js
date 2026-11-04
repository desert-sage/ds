// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// `ds dap`: a Debug Adapter Protocol server over stdio (NDBG.9 to 15). One
// client, one session, its own engine
// ([NDBG.9.1.2]); `attach` is refused ([NDBG.9.1.3]). DAP's base protocol
// frames messages as LSP's does (lib/lsp/framing.js). Requests are answered
// one at a time, in order; every move is synchronous, so the session is never
// running when a request arrives, and `pause` only says where it is.
//
// The session is dsdb's (lib/core/), opened from paths as the shell opens it
// (cli/open.js); adapter.js is what the protocol sees of it.
//
// NO FENCE, BY DECISION. `ds mcp` and `ds serve` read and write only under
// their --root and --out (cli/fence.js), because their client is an agent or a
// page, which the user approves call by call or not at all. `ds dap`'s client
// is the user's own editor, its launch configuration the user's own file, and
// the adapter opens the paths it names as the shell opens those on its command
// line. What it does guard is the stream: a message past the framing's size
// limit ends the session (lsp/framing.js), as a loader refuses a header it
// cannot believe. A trace and its program are read by libds, which must
// refuse a malformed one; whether a well-formed program can be trusted is the
// deployer's question, as for any program ([RDSC.9.9]).
//
// There is no `ds/getFactPath` ([NDBG.13.5.3]): the variable tree has
// no depth cap, so nothing needs it, and it is refused as any unknown request.

import { resolve } from "node:path";

import { compileFile, loadBinding, openSession, openTarget, read, Unreadable } from "../cli/open.js";
import { FactFileError, loadFactFiles } from "../core/facts.js";
import { FrameError, bodies, frame } from "../lsp/framing.js";
import { Adapter, EXCEPTION_FILTERS, Refused, place } from "./adapter.js";

/** @import { Opened, Say } from "../api/ops.js" */
/** @import { Moved } from "./adapter.js" */

/** The `initialize` response's capabilities ([NDBG.9.2.1]). */
export const CAPABILITIES = Object.freeze({
    supportsConfigurationDoneRequest: true,
    supportsStepBack: true,
    supportsRestartRequest: true,
    supportsGotoTargetsRequest: true,
    supportsStepInTargetsRequest: true,
    exceptionBreakpointFilters: EXCEPTION_FILTERS,
    supportsFunctionBreakpoints: true,
    supportsDataBreakpoints: false,
    supportsConditionalBreakpoints: true,
    supportsHitConditionalBreakpoints: true,
    supportsLogPoints: true,
    supportsRestartFrame: false,
    supportsSetVariable: false,
    supportsCompletionsRequest: false,
    supportsEvaluateForHovers: true,
    additionalModuleColumns: [],
});

/**
 * The launch arguments ([NDBG.9.3.1]), as the client sent them.
 * @typedef {{ program?: unknown, libs?: unknown, trace?: unknown, facts?: unknown, source?: unknown,
 *     events?: unknown }} Launch
 */

/**
 * Serve until the client disconnects, or the input ends.
 * @param {object} o
 * @param {AsyncIterable<Uint8Array>} o.input  the client's bytes
 * @param {(s: string) => void} o.write  to the client
 * @param {(s: string) => void} o.log  not to the client: stderr
 * @param {string[]} [o.libs]  library directories for every compile, after the launch's own
 * @returns {Promise<number>} the exit status: 0 after `disconnect`, 1 if the input ends without one
 */
export async function runDap({ input, write, log, libs = [] }) {
    let seq = 1;
    /** @param {Record<string, unknown>} msg */
    const send = (msg) => write(frame({ seq: seq++, ...msg }));
    /**
     * @param {string} event
     * @param {Record<string, unknown>} [body]
     */
    const event = (event, body) => send({ type: "event", event, ...(body === undefined ? {} : { body }) });
    /** @param {string} text @param {string} [category] */
    const output = (text, category = "console") => event("output", { category, output: text.endsWith("\n") ? text : text + "\n" });

    /** @type {{ opened: Opened, adapter: Adapter } | null} */
    let live = null;
    /** @type {Launch | null} */
    let launched = null;
    /** @type {Set<number>} the thread ids the client has been told of */
    let told = new Set();
    /** @type {{ lines: Map<string, any[]>, functions: any[], facts: unknown, caches: unknown, filters: unknown,
        events: unknown }} what the client set, for `restart` */
    const asked = { lines: new Map(), functions: [], facts: [], caches: [], filters: undefined, events: undefined };

    /** Let the session go, if there is one. */
    const end = () => {
        live?.opened.close();
        live = null;
    };

    /** @returns {Adapter} */
    const adapter = () => {
        if (live === null) throw new Refused("nothing is launched: `launch` first");
        return live.adapter;
    };

    /**
     * What a move said, the logpoints' lines ([NDBG.12.1.4]) and the
     * program's own ([NDBG.9.3.6]), the thread events the stop makes
     * ([NDBG.10.1.2]), then `stopped`.
     * @param {Moved} moved
     */
    const stopped = ({ stop, said, logs, stdout, events }) => {
        const a = adapter();
        for (const line of said) output(line);
        for (const line of logs) output(line, "important");
        for (const line of stdout) output(line, "stdout");
        for (const e of events) event(e.event, e.body);
        const now = new Set(a.threads().map((t) => t.id));
        for (const id of told) if (!now.has(id)) event("thread", { reason: "exited", threadId: id });
        for (const id of now) if (!told.has(id)) event("thread", { reason: "started", threadId: id });
        told = now;
        event("stopped", { reason: stop.reason, threadId: a.focusedThread(), allThreadsStopped: true,
                           ...(stop.description ? { description: stop.description } : {}),
                           ...(stop.hits?.length ? { hitBreakpointIds: stop.hits } : {}) });
    };

    /**
     * Open the session the launch arguments name.
     * @param {Launch} args
     */
    const open = async (args) => {
        const program = optPath(args.program, "program"), trace = optPath(args.trace, "trace");
        const source = optPath(args.source, "source");
        const dirs = paths(args.libs, "libs");
        const factFiles = paths(args.facts, "facts");
        if (factFiles.length && trace !== null) throw new Refused("`facts` feed a live session: give them without `trace`");
        if (program === null && trace === null) throw new Refused("give the `program`, or a `trace` that embeds it");
        /** @type {{ dsc: string[], ds: string[], other: string[] }} */
        const kinds = { dsc: [], ds: [], other: [] };
        if (program !== null) (program.endsWith(".ds") ? kinds.ds : kinds.other).push(program);
        if (trace !== null) kinds.other.push(trace);
        // The `.ds` of a `.dsc` is the session's source too, as the shell
        // takes one beside a `.dsc`: rule blocks for conditions and logpoints.
        if (source !== null && !kinds.ds.includes(source)) kinds.ds.unshift(source);
        /** @type {string[]} */
        const said = [];
        /** @type {string | null} why a trace and the program were refused ([RFCS.4.5]) */
        let unbound = null;
        /** @type {Say} */
        const say = { out: (l) => said.push(l), err: (l) => said.push(l), unbound: (u) => { unbound = u.code; } };
        const search = [...dirs, ...libs];
        let opened;
        try {
            // No shell banner: it names shell commands an editor cannot send,
            // and says "empty" of an engine the fact files are about to feed.
            opened = await openSession({ kinds, search, width: 100, banner: false }, say, "ds dap");
        } catch (err) {
            if (err instanceof Unreadable) throw new Refused(err.message);
            if (err instanceof Error && (err.name === "DsError" || err.name === "CompileRefused")) throw new Refused(err.message);
            throw err;
        }
        // [NDBG.14r.6.5]: a trace the binding check refuses is fatal to the
        // load, and the error response carries the DS_ERR_BND_* code.
        if (typeof opened === "number")
            throw new Refused([...said, opened === 3 ? "the trace was not recorded with this program" : "not launched"].join("\n"),
                              opened === 3 ? unbound : null);
        for (const l of said) output(l);
        const lines = source === null ? new Map() : await sourceLines(source, search);
        const given = [program, source].filter((p) => p !== null && p.endsWith(".ds")).map((p) => /** @type {string} */ (p));
        /** @type {import("../core/facts.js").FactRow[]} */
        let inputs = [];
        try {
            // [NDBG.9.3.1]: fed as dsdb's fact-file mode feeds them, typed
            // against the live engine's schemas and merged by `@at`.
            const run = opened.session.state.liveRun;
            if (factFiles.length && run !== null)
                inputs = loadFactFiles(factFiles.map((p) => ({ path: p, text: readText(p) })), run.eng);
            const a = new Adapter(opened.session, { lines, given, inputs });
            if (args.events !== undefined && args.events !== null) a.setEvents(args.events);
            if (inputs.length) output(`${inputs.length} input${inputs.length === 1 ? "" : "s"} to feed from the fact files`);
            return { opened, adapter: a };
        } catch (err) {
            opened.close();
            if (err instanceof FactFileError) throw new Refused(err.message);
            throw err;
        }
    };

    /**
     * Set again what the client set, on a new session ([NDBG.9.3.2]), the
     * step granularity carried under [NDBG.14.1.1]'s rule.
     * @param {import("./adapter.js").Granularity | null} granularity
     */
    const reapply = async (granularity) => {
        const a = adapter();
        a.prefer(granularity);
        /** @type {Array<{ id: number, verified: boolean, message?: string, line?: number, source?: string }>} */
        const again = [];
        for (const [path, bps] of asked.lines) again.push(...await a.setLineBreakpoints(path, bps));
        again.push(...await a.setFunctionBreakpoints(asked.functions), ...await a.setFactBreakpoints(asked.facts),
                   ...a.setCacheBreakpoints(asked.caches));
        if (asked.filters !== undefined) a.setExceptionFilters(asked.filters);
        if (asked.events !== undefined) a.setEvents(asked.events);
        // Sent after the request's response, as the events of a request are.
        return () => {
            for (const b of again) event("breakpoint", { reason: "changed", breakpoint: wire(b) });
        };
    };

    /**
     * A request's answer; null for a `disconnect`, which ends the loop.
     * @param {string} command
     * @param {any} args
     * @returns {Promise<{ body?: unknown, after?: () => void } | null>}
     */
    const answer = async (command, args) => {
        switch (command) {
        case "initialize":
            return { body: CAPABILITIES, after: () => event("initialized") };
        case "launch": {
            live?.opened.close();
            live = null;
            live = await open(args ?? {});
            launched = args ?? {};
            told = new Set();
            return {};
        }
        case "attach":
            throw new Refused("there is no ds server to attach to; use launch");
        case "configurationDone": {
            // Refused before it is answered when nothing is launched: an
            // `after` runs once the response is sent.
            const a = adapter();
            return { after: () => stopped({ stop: a.stop, said: [], logs: [], stdout: [], events: [] }) };
        }
        case "restart": {
            if (launched === null) throw new Refused("nothing is launched: `launch` first");
            const again = await open(launched);
            const chosen = live?.adapter.chosen ?? null;
            live?.opened.close();
            live = again;
            const tell = await reapply(chosen);
            return { after: () => {
                tell();
                stopped({ stop: adapter().stop, said: ["restarted"], logs: [], stdout: [], events: [] });
            } };
        }
        case "ds/loadRecording": {
            // [NDBG.14.2]: the session's program, now over this trace, from its
            // start; the trace must have been recorded with it ([NDBG.14r.6.5]).
            if (launched === null) throw new Refused("nothing is launched: `launch` first");
            const path = optPath(args?.path, "path");
            if (path === null) throw new Refused("`path` names the trace");
            if (optPath(launched.program, "program") === null)
                throw new Refused("ds/loadRecording needs the program as a file: launch with `program`");
            const next = { ...launched, trace: path };
            const again = await open(next);
            const chosen = live?.adapter.chosen ?? null;
            live?.opened.close();
            live = again;
            launched = next;
            const tell = await reapply(chosen);
            return { body: adapter().recording(), after: () => {
                tell();
                stopped({ stop: adapter().stop, said: [`replaying ${path}`], logs: [], stdout: [], events: [] });
            } };
        }
        case "disconnect":
            return null;
        case "setBreakpoints": {
            const path = args?.source?.path;
            if (typeof path !== "string") throw new Refused("`source.path` names the file");
            const given = Array.isArray(args?.breakpoints) ? args.breakpoints : [];
            asked.lines.set(resolve(path), given);
            return { body: { breakpoints: (await adapter().setLineBreakpoints(path, given)).map(wire) } };
        }
        case "setFunctionBreakpoints": {
            const given = Array.isArray(args?.breakpoints) ? args.breakpoints : [];
            asked.functions = given;
            return { body: { breakpoints: (await adapter().setFunctionBreakpoints(given)).map(wire) } };
        }
        case "ds/setFactBreakpoints": {
            const given = Array.isArray(args?.breakpoints) ? args.breakpoints : [];
            asked.facts = given;
            return { body: { breakpoints: (await adapter().setFactBreakpoints(given)).map(wire) } };
        }
        case "ds/setCacheBreakpoints": {
            const given = Array.isArray(args?.breakpoints) ? args.breakpoints : [];
            asked.caches = given;
            return { body: { breakpoints: adapter().setCacheBreakpoints(given).map(wire) } };
        }
        case "ds/getTimerAgenda":
            return { body: adapter().timerAgenda() };
        case "setExceptionBreakpoints":
            adapter().setExceptionFilters(args?.filters ?? []);
            asked.filters = args?.filters ?? [];
            return { body: { breakpoints: [] } };
        case "threads":
            return { body: { threads: adapter().threads().map((t) => ({ id: t.id, name: t.name })) } };
        case "stackTrace": {
            const frames = adapter().frames(Number(args?.threadId));
            const from = Number(args?.startFrame ?? 0), levels = Number(args?.levels ?? 0);
            return { body: { stackFrames: frames.slice(from, levels ? from + levels : undefined), totalFrames: frames.length } };
        }
        case "scopes":
            return { body: { scopes: adapter().scopes(Number(args?.frameId)) } };
        case "variables": {
            const start = typeof args?.start === "number" ? args.start : undefined;
            const count = typeof args?.count === "number" && args.count > 0 ? args.count : undefined;
            return { body: { variables: adapter().variables(Number(args?.variablesReference), start, count) } };
        }
        case "evaluate":
            return { body: await adapter().evaluate(args) };
        case "next":
        case "stepBack": {
            const got = await adapter().step(command === "next");
            return { after: () => stopped(got) };
        }
        case "stepIn": {
            const got = await adapter().stepIn(args?.targetId);
            return { after: () => stopped(got) };
        }
        case "stepOut": {
            const got = await adapter().stepOut();
            return { after: () => stopped(got) };
        }
        case "stepInTargets":
            return { body: { targets: adapter().stepInTargets() } };
        case "gotoTargets": {
            const path = args?.source?.path, line = Number(args?.line);
            if (typeof path !== "string" || !Number.isInteger(line)) throw new Refused("`source.path` and `line` name the line");
            return { body: { targets: adapter().gotoTargets(path, line) } };
        }
        case "goto": {
            const got = adapter().goto(args?.targetId);
            return { after: () => stopped(got) };
        }
        case "continue":
        case "reverseContinue": {
            const got = await adapter().run(command === "continue");
            return { body: command === "continue" ? { allThreadsContinued: true } : {},
                     after: () => stopped(got) };
        }
        case "pause": {
            const a = adapter();
            return { after: () => stopped({ stop: { ...a.stop, reason: "pause" }, said: [], logs: [], stdout: [], events: [] }) };
        }
        case "ds/stepGranularity":
            adapter().setGranularity(args?.granularity);
            return { body: { granularity: adapter().granularity } };
        case "ds/assertFact":
        case "ds/retractFact":
        case "ds/answerCall": {
            // [NDBG.14.13.2]: the message is sent as output too; the session
            // follows where the change landed.
            const a = adapter();
            const got = command === "ds/assertFact" ? await a.assertFact(args)
                : command === "ds/retractFact" ? await a.retractFact(args) : await a.answerCall(args);
            return { body: got.body, after: () => {
                output(got.body.message);
                stopped(got.moved);
            } };
        }
        case "ds/streamEvents":
            adapter().setEvents(args?.kinds);
            asked.events = args?.kinds;
            return {};
        case "ds/getWorkingMemory":
            return { body: await adapter().workingMemory(args) };
        case "ds/diffWorkingMemory":
            return { body: adapter().diffWorkingMemory(args) };
        case "ds/getFactLineage":
            return { body: adapter().lineage(args) };
        case "ds/getActivationPath":
            return { body: adapter().activationPath(args) };
        case "ds/getJustifiers":
            return { body: adapter().justifiers(args) };
        case "ds/getReteNetwork":
            return { body: adapter().reteNetwork(args) };
        case "ds/getMatchTrace":
            return { body: adapter().matchTrace(args) };
        case "ds/getRefractedActivations":
            return { body: adapter().refracted(args) };
        case "ds/installMock": {
            const got = await adapter().installMock(args);
            const moved = got.moved;
            return { body: got.body, after: moved === null ? undefined : () => {
                if (typeof got.body.message === "string") output(got.body.message);
                stopped(moved);
            } };
        }
        case "ds/removeMock":
            adapter().removeMock(args?.mock_id);
            return {};
        case "ds/timelines":
            return { body: { timelines: adapter().timelines() } };
        case "ds/switchTimeline": {
            const got = adapter().switchTimeline(args?.timeline);
            return { after: () => stopped(got) };
        }
        case "ds/dropTimeline":
            return { body: { dropped: await adapter().dropTimeline(args?.timeline) } };
        case "ds/advanceClock": {
            const got = await adapter().advance(args?.by);
            return { after: () => stopped(got) };
        }
        default:
            throw new Refused(`no request \`${command}\``);
        }
    };

    try {
        for await (const body of bodies(input)) {
            /** @type {any} */
            let msg;
            try {
                msg = JSON.parse(body);
            } catch {
                log("ds dap: a message that is not JSON, dropped");
                continue;
            }
            if (msg === null || typeof msg !== "object" || msg.type !== "request" || typeof msg.command !== "string") continue;
            /** @param {boolean} success @param {Record<string, unknown>} [more] */
            const respond = (success, more = {}) =>
                send({ type: "response", request_seq: msg.seq, success, command: msg.command, ...more });
            /**
             * A failed response. DAP's ErrorResponse requires a `body`, whose
             * `error` is the Message an editor shows: `id` says which
             * of the three kinds below it is. A refusal with a libds status
             * behind it names it in the Message's `variables.code`
             * ([NDBG.14r.6.5]).
             * @param {number} id @param {string} text @param {string | null} [code]
             */
            const refuse = (id, text, code = null) => respond(false, { message: text, body: { error: {
                id, format: text, ...(code === null ? {} : { variables: { code } }) } } });
            /** @type {(() => void) | undefined} */
            let after;
            try {
                const got = await answer(msg.command, msg.arguments);
                if (got === null) {
                    respond(true);
                    return 0;
                }
                respond(true, got.body === undefined ? {} : { body: got.body });
                after = got.after;
            } catch (err) {
                if (err instanceof Refused) {
                    refuse(1, err.message, err.code);
                    continue;
                }
                // [NDBG.9.3.3]: an engine that trapped is gone. Say so, end
                // the session, and do not start another: every id it gave is
                // void.
                if (typeof WebAssembly !== "undefined" && err instanceof WebAssembly.RuntimeError) {
                    refuse(2, `the engine trapped: ${err.message}`);
                    output(`the engine trapped: ${err.message}`, "important");
                    event("terminated");
                    end();
                    continue;
                }
                const text = err instanceof Error ? err.message : String(err);
                log(`ds dap: ${msg.command}: ${err instanceof Error ? err.stack ?? text : text}`);
                refuse(3, text);
                continue;
            }
            // What follows an answer runs once its response is sent, so its
            // failure is no second response to the request: it is said
            // as output, and logged.
            try {
                after?.();
            } catch (err) {
                const text = err instanceof Error ? err.message : String(err);
                log(`ds dap: ${msg.command}, after its response: ${err instanceof Error ? err.stack ?? text : text}`);
                output(`${msg.command}: ${text}`, "important");
            }
        }
        return 1;
    } catch (err) {
        // Bytes that cannot be read as messages: the stream is unusable.
        if (!(err instanceof FrameError)) throw err;
        log(`ds dap: ${err.message}`);
        return 1;
    } finally {
        // [NDBG.9.3.2]: the engine and every timeline go with the session.
        end();
    }
}

/**
 * Each rule's declaration line in a `.ds`, for a `.dsc` that carries none
 * (the `source` launch argument, [NDBG.9.3.1]).
 * @param {string} source
 * @param {string[]} search
 * @returns {Promise<Map<string, { file: string, line: number }>>}
 */
async function sourceLines(source, search) {
    const ds = await openTarget(await loadBinding());
    let dsc;
    try {
        dsc = await compileFile(ds, source, search);
    } catch (err) {
        if (err instanceof Error && err.name === "CompileRefused") throw new Refused(`${source} does not compile:\n${err.message}`);
        throw err;
    }
    const e = new ds.Engine();
    /** @type {Map<string, { file: string, line: number }>} */
    const out = new Map();
    try {
        e.loadDsc(dsc);
        for (const [name, m] of e.rules) {
            const at = place(m);
            if (at !== null) out.set(name, { file: source, line: at.line });
        }
    } finally {
        e.close();
    }
    return out;
}

/**
 * A breakpoint as DAP has it.
 * @param {{ id: number, verified: boolean, message?: string, line?: number, source?: string }} b
 */
function wire(b) {
    return { id: b.id, verified: b.verified, ...(b.message ? { message: b.message } : {}),
             ...(b.line === undefined ? {} : { line: b.line }), ...(b.source ? { source: { path: b.source } } : {}) };
}

/**
 * A file's text, or refused naming it.
 * @param {string} path
 */
function readText(path) {
    try {
        return read(path, "utf8");
    } catch (err) {
        if (err instanceof Unreadable) throw new Refused(err.message);
        throw err;
    }
}

/**
 * A launch argument that is a path, or null when it is not given.
 * @param {unknown} p
 * @param {string} what
 * @returns {string | null}
 */
function optPath(p, what) {
    if (p === undefined || p === null || p === "") return null;
    if (typeof p !== "string") throw new Refused(`\`${what}\` is a path`);
    return p;
}

/**
 * @param {unknown} p
 * @param {string} what
 * @returns {string[]}
 */
function paths(p, what) {
    if (p === undefined || p === null) return [];
    if (!Array.isArray(p) || !p.every((d) => typeof d === "string")) throw new Refused(`\`${what}\` is a list of directories`);
    return p;
}
