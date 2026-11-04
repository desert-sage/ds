// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// `ds dap`'s debugger: what a DAP client sees of a dsdb session, as NDBG
// states it. The server (server.js) speaks
// the protocol; this holds the position, the step granularity, the
// breakpoints, and the threads, frames, scopes and variables at a stop. It
// moves the session's point and reads its timeline; it never prints.
//
// POSITIONS are the session's points (core/timeline.js): the state after the
// first `k` records. Where each granularity stops ([NDBG.14.1.1]):
//
// - `rule`: just after a firing's begin annotation, before its first action
//   ([NDBG.12.1.1]);
// - `action`: there, and just before each later action of the firing, so the
//   record at the point is the action about to apply;
// - `pump`: each settled point ([NDBG.11.1.1]);
// - `input`: just after each input the trace or the engine was fed, so what it
//   causes comes next.
//
// A live session stops only at settled points: the engine refuses every call
// from inside a pump ([NDBG.1.2]). Behind a live run's end it steps through
// what was recorded, as replay does, at `pump` or `input`.
//
// What the trace cannot say is said, not guessed: a firing whose matched facts
// are unknown has no Bindings, and an activation cancelled before it fired is
// no thread ([NDBG.10.1.1]).

import { readFileSync } from "node:fs";
import { basename, isAbsolute, resolve } from "node:path";

import { rowSlots } from "../core/facts.js";
import { durationNs } from "../core/grammar.js";
import { splitPattern } from "../core/rete.js";
import { bisectLeft, bisectRight } from "../core/timeline.js";
import { INPUT, is } from "../core/trace.js";
import { lhsOf } from "../core/why.js";
import { parseDiagnostics } from "../lsp/diagnostics.js";

/** @import { RuleMeta } from "@ds-lang/ds" */
/** @import { Session } from "../core/session.js" */
/** @import { Call, Fact, Firing, Timeline } from "../core/timeline.js" */
/** @import { TraceRecord } from "../core/trace.js" */

/**
 * A query's refusal in the terms of `text`, what the user wrote and dsdb built
 * the query around: an expression, a condition, a filter. Each of the
 * compiler's diagnostics that falls in `text` is said with its column into it
 * and a caret under it; the others by code and message alone. No line of the
 * program dsdb generated is shown. [NDBG.13.7.1] wants the detail carried, and
 * this is it, in the user's words.
 * @param {Error} err  a QueryError
 * @param {string} text
 * @returns {string}
 */
function refusalIn(err, text) {
    const c = /** @type {{ compiler?: { text: string, source: string } | null }} */ (/** @type {unknown} */ (err))
        .compiler ?? null;
    if (c === null) return err.message;
    const lines = c.source.split("\n");
    /** @type {string[]} */
    const out = [];
    for (const d of parseDiagnostics(c.text)) {
        const src = lines[d.span.start.line - 1] ?? "";
        const at = src.indexOf(text), col = d.span.start.col - at;
        const head = `${d.code}: ${d.message}`;
        if (at >= 0 && col >= 0 && col < text.length) {
            const width = d.span.end.line !== d.span.start.line ? 1
                : Math.min(Math.max(1, d.span.end.col - d.span.start.col), text.length - col);
            out.push(`\`${text}\`, column ${col + 1}: ${head}`, `    ${text}`, `    ${" ".repeat(col)}${"^".repeat(width)}`);
        } else {
            out.push(head);
        }
        if (d.hint !== null) out.push(`  hint: ${d.hint}`);
    }
    return out.length ? out.join("\n") : err.message;
}

/**
 * libds's DS_ERR_NOT_FOUND (proto/status.proto): what `lineSpan` throws for a
 * node no span maps ([NDBG.7.1]). `@ds-lang/ds`'s `status` is reached only through
 * the binding dsdb loads at run time, so the number is written here.
 */
const DS_ERR_NOT_FOUND = -3;

/** @typedef {"action" | "rule" | "pump" | "input"} Granularity */

/**
 * A line or function breakpoint: the rules it stops in, its hit count, and,
 * for a condition or a logpoint, the query each rule's firings are judged by
 * (rule name -> query body). A logpoint logs and never stops; `parts` is its
 * message cut at each `{…}`, whose expressions are the query's projection.
 * @typedef {{ id: number, rules: Set<string>, hit: ((n: number) => boolean) | null, verified: boolean,
 *     message?: string, line?: number, source?: string, queries: Map<string, string> | null,
 *     log: string[] | null }} RuleBreakpoint
 */

/**
 * A fact breakpoint ([NDBG.12.3]): a schema, the lifecycle events it stops
 * on, the condition its fact must meet, compiled as a query, and its hit count.
 * @typedef {{ id: number, schema: string, on: Set<string>, where: string | null,
 *     hit: ((n: number) => boolean) | null }} FactBreakpoint
 */

/** A cache breakpoint ([NDBG.12.5]): a key, `""` for any, and the operations it stops on. @typedef {{ id: number, key: string, on: Set<string> }} CacheBreakpoint */

/** @typedef {{ name: string, value: string, variablesReference: number, indexedVariables?: number }} Variable */

/** @typedef {{ reason: string, description?: string, focus: Firing | null, hits?: number[] }} Stop */

/**
 * A move's outcome: where it stopped, what to say, the logpoints' lines, the
 * program's own `log` lines ([NDBG.9.3.6]), and the stream events it crossed
 * ([NDBG.15.9]).
 * @typedef {{ stop: Stop, said: string[], logs: string[], stdout: string[],
 *     events: Array<{ event: string, body: Record<string, unknown> }> }} Moved
 */

/**
 * A standing answer ([NDBG.14.15]): matched by `corr` or by `service`,
 * answering with a response row or an error, `left` more times.
 * @typedef {{ id: string, corr: string | null, service: string | null, response: Record<string, unknown> | null,
 *     error: { code: string, message: string } | null, left: number }} Mock
 */

/** The DS stream events ([NDBG.15.1] to [NDBG.15.5]), by name without `ds/`. */
export const EVENT_KINDS = ["factAsserted", "factRetracted", "logicalFactFlipped", "callMade", "callAnswered"];

/** The step granularities, by mode ([NDBG.14.1.1]). */
export const GRANULARITIES = ["action", "rule", "pump", "input"];
const REPLAY_ONLY = new Set(["action", "rule"]);

/** The exception filters ([NDBG.12.6.1]). */
export const EXCEPTION_FILTERS = [
    { filter: "unanswered_call", label: "Unanswered call", default: false,
      description: "a pump ends with a call still waiting for its answer" },
    { filter: "fault", label: "Fault", default: false, description: "a firing raises a fault" },
    { filter: "engine_error", label: "Engine error", default: true,
      description: "a pump returns an error status, or the engine halts" },
];

/** The records that are a firing's fault ([LERR.9]), and the engine's error. */
const FAULTS = new Set(["ComputationError", "TypeError", "BoundsError"]);

/** Working memory pages by this many facts a schema ([NDBG.13.3.3]). */
export const PAGE = 100;

/** The thread that stands for the engine when no firing is at the point. */
const ENGINE_THREAD = 1;

/** Why `ds/assertFact` refuses a `ttl`, in batch mode's words. */
const NO_TTL = "`ttl`: no public entry point sets a per-fact TTL; a fact takes its schema's";

/**
 * A request the adapter understood and refuses; its message is the client's.
 * `code` is the libds status behind it, by name, where one is
 * ([NDBG.14r.6.5]): the error response carries it.
 */
export class Refused extends Error {
    /**
     * @param {string} message
     * @param {string | null} [code]
     */
    constructor(message, code = null) {
        super(message);
        this.code = code;
    }
}

export class Adapter {
    /** @type {Session} */
    #session;
    /** @type {Granularity | null} the client's, or null for the mode's default */
    #granularity = null;
    /** @type {Map<string, RuleBreakpoint[]>} line breakpoints by source path */
    #lines = new Map();
    /** @type {RuleBreakpoint[]} */
    #functions = [];
    /** @type {FactBreakpoint[]} */
    #facts = [];
    /** @type {CacheBreakpoint[]} */
    #caches = [];
    /** @type {Set<string>} */
    #filters = new Set(EXCEPTION_FILTERS.filter((f) => f.default).map((f) => f.filter));
    #nextBreakpoint = 1;
    /** @type {Map<string, number>} "timeline\0firing index" -> its thread id ([NDBG.10.1.2]) */
    #threadIds = new Map();
    #nextThread = ENGINE_THREAD + 1;
    /** @type {Map<number, () => Variable[]>} the variable references of this stop */
    #refs = new Map();
    /** @type {Stop} */
    #stop = { reason: "entry", focus: null };
    /** @type {Map<string, { file: string, line: number }>} each rule's declaration, by name */
    #where;
    /** @type {string[]} the program's source files, as given: where a `.dsc`'s file names are looked up */
    #given;
    /** @type {Map<number, { k: number, label: string, focus: Firing | null }>} the goto targets given since the last move */
    #gotos = new Map();
    #nextGoto = 1;
    /** @type {Map<string, import("../core/query.js").Answer[]>} each breakpoint query's answers, as `#prime` read them */
    #judged = new Map();
    /** @type {Set<string>} the stream events to send ([NDBG.15.9]): none, until chosen */
    #events_ = new Set();
    /** @type {import("../core/facts.js").FactRow[]} the fact files' rows not yet fed, in time order */
    #inputs;
    /** the live engine's clock when the session began: a row's `@at` counts from it */
    #start = 0n;
    /** @type {Mock[]} */
    #mocks = [];
    #nextMock = 1;

    /**
     * @param {Session} session
     * @param {object} o
     * @param {Map<string, { file: string, line: number }>} [o.lines]  each rule's declaration line, where the
     *   `.dsc` carries none and the `source` launch argument gave it
     * @param {string[]} [o.given]  the `.ds` files the launch named
     * @param {import("../core/facts.js").FactRow[]} [o.inputs]  a live session's fact-file rows, merged
     */
    constructor(session, { lines = new Map(), given = [], inputs = [] } = {}) {
        this.#session = session;
        this.#inputs = [...inputs];
        this.#start = session.state.liveRun?.clock() ?? 0n;
        this.#given = given.map((p) => resolve(p));
        this.#where = new Map();
        for (const [name, m] of session.rules() ?? new Map()) {
            const at = place(m);
            if (at !== null) this.#where.set(name, { file: this.#path(at.file), line: at.line });
        }
        for (const [name, at] of lines) if (!this.#where.has(name)) this.#where.set(name, { file: resolve(at.file), line: at.line });
        // Replay starts at the trace's start; a live session where it is.
        const s = session.state;
        if (!s.live) s.k = 0;
    }

    get session() {
        return this.#session;
    }

    get #s() {
        return this.#session.state;
    }

    /** Whether the current timeline is a live run, an engine's own. */
    get live() {
        return this.#s.live;
    }

    /** @returns {Granularity} */
    get granularity() {
        const g = this.#granularity;
        if (g !== null && !(this.live && REPLAY_ONLY.has(g))) return g;
        return this.live ? "pump" : "action";
    }

    /**
     * `ds/stepGranularity` ([NDBG.14.1.1]).
     * @param {unknown} g
     */
    setGranularity(g) {
        if (typeof g !== "string" || !GRANULARITIES.includes(g))
            throw new Refused(`granularity is one of ${GRANULARITIES.join(", ")}`);
        if (this.live && REPLAY_ONLY.has(g)) throw new Refused(`\`${g}\` steps are replay only; a live session steps by pump or input`);
        this.#granularity = /** @type {Granularity} */ (g);
    }

    /** The granularity the client set, or null: kept across a new session, where the getter applies the mode's rule. */
    get chosen() {
        return this.#granularity;
    }

    /**
     * Carry the client's choice to a new session ([NDBG.14.1.1]): it holds
     * where the new mode admits it, else the mode's default does.
     * @param {Granularity | null} g
     */
    prefer(g) {
        this.#granularity = g;
    }

    // ── breakpoints ([NDBG.12]) ────────────────────────────────────────────

    /** Whether the session knows where its rules are in source. */
    get hasLines() {
        return this.#where.size > 0;
    }

    /**
     * `setBreakpoints` on one source file ([NDBG.12.1.1]): every breakpoint the
     * client gave, verified or why not.
     * @param {string} path
     * @param {Array<{ line: number, condition?: string, hitCondition?: string, logMessage?: string }>} given
     * @returns {Promise<RuleBreakpoint[]>}
     */
    async setLineBreakpoints(path, given) {
        const file = resolve(path);
        const out = [];
        for (const b of given) {
            /** @type {RuleBreakpoint} */
            const bp = { id: this.#nextBreakpoint++, rules: new Set(), hit: null, verified: false, line: b.line, source: file,
                         queries: null, log: null };
            if (!this.hasLines) {
                out.push({ ...bp, message: "no source lines: give the program's .ds" });
                continue;
            }
            for (const [rule, at] of this.#where) if (at.file === file && at.line === b.line) bp.rules.add(rule);
            if (!bp.rules.size) {
                out.push({ ...bp, message: "DS breakpoints must be on rule, after or on response lines, or use "
                           + "ds/setFactBreakpoints for fact-event breakpoints" });
                continue;
            }
            out.push(await this.#qualify(bp, b));
        }
        this.#lines.set(file, out.filter((b) => b.verified));
        return out;
    }

    /**
     * `setFunctionBreakpoints` ([NDBG.12.2]): a name is a rule's.
     * @param {Array<{ name: string, condition?: string, hitCondition?: string, logMessage?: string }>} given
     * @returns {Promise<RuleBreakpoint[]>}
     */
    async setFunctionBreakpoints(given) {
        const rules = this.#ruleNames();
        const out = [];
        for (const b of given) {
            /** @type {RuleBreakpoint} */
            const bp = { id: this.#nextBreakpoint++, rules: new Set([b.name]), hit: null, verified: false, queries: null, log: null };
            if (!rules.has(b.name)) out.push({ ...bp, message: `no rule named '${b.name}' in the loaded rule set` });
            else out.push(await this.#qualify(bp, b));
        }
        this.#functions = out.filter((b) => b.verified);
        return out;
    }

    /**
     * `ds/setFactBreakpoints` ([NDBG.12.3]): each breakpoint verified, or why
     * not, before any is registered ([NDBG.12.3.3]). A `where` names the fact
     * by its schema's name lowercased, and is compiled as the query
     * `Schema schema where …` over the program, so its errors are the
     * compiler's.
     * @param {unknown} given
     * @returns {Promise<Array<{ id: number, verified: boolean, message?: string }>>}
     */
    async setFactBreakpoints(given) {
        const list = Array.isArray(given) ? given : [];
        const v = this.#s.view, schemas = v.queries?.prog.schemas ?? new Map();
        /** @type {FactBreakpoint[]} */
        const keep = [];
        const out = [];
        for (const b of list) {
            const id = this.#nextBreakpoint++;
            /** @param {string} message */
            const no = (message) => ({ id, verified: false, message });
            const schema = typeof b?.schema === "string" ? b.schema : "";
            if (!schema || !schemas.has(schema) || schema.startsWith("$")) {
                out.push(no(`no schema '${schema}'`));
                continue;
            }
            const on = Array.isArray(b.on) ? b.on : [];
            if (!on.length || !on.every((/** @type {unknown} */ x) => x === "assert" || x === "retract")) {
                out.push(no('on must be a non-empty list of "assert" and "retract"'));
                continue;
            }
            /** @type {((n: number) => boolean) | null} */
            let hit = null;
            if (b.hitCondition) {
                hit = hitTest(String(b.hitCondition));
                if (hit === null) {
                    out.push(no(`\`${b.hitCondition}\` is not a hit count: \`5\`, \`>= 3\`, \`% 2\``));
                    continue;
                }
            }
            const where = typeof b.where === "string" && b.where.trim() ? b.where.trim() : null;
            if (where !== null) {
                if (v.queries === null) {
                    out.push(no("needs the program's source"));
                    continue;
                }
                try {
                    await v.queries.get(factQuery(schema, where), 0);
                } catch (err) {
                    if (!(err instanceof Error) || err.name !== "QueryError") throw err;
                    out.push(no(refusalIn(err, where)));
                    continue;
                }
            }
            keep.push({ id, schema, on: new Set(on), where, hit });
            out.push({ id, verified: true });
        }
        this.#facts = keep;
        return out;
    }

    /**
     * `ds/setCacheBreakpoints` ([NDBG.12.5]): a key (`""` for any) and the
     * operations to stop on. In replay a `get` is unverified, since a trace
     * does not record cache reads; its `set` and `delete` still stand.
     * @param {unknown} given
     * @returns {Array<{ id: number, verified: boolean, message?: string }>}
     */
    setCacheBreakpoints(given) {
        const list = Array.isArray(given) ? given : [];
        /** @type {CacheBreakpoint[]} */
        const keep = [];
        const out = [];
        for (const b of list) {
            const id = this.#nextBreakpoint++;
            const on = Array.isArray(b?.on) ? b.on : [];
            if (typeof b?.key !== "string") {
                out.push({ id, verified: false, message: "`key` is the cache key, or \"\" for any" });
                continue;
            }
            if (!on.length || !on.every((/** @type {unknown} */ x) => x === "get" || x === "set" || x === "delete")) {
                out.push({ id, verified: false, message: 'on must be a non-empty list of "get", "set" and "delete"' });
                continue;
            }
            const ops = new Set(on);
            const replay = !this.live;
            if (replay) ops.delete("get");
            if (ops.size) keep.push({ id, key: b.key, on: ops });
            out.push(replay && on.includes("get") ? { id, verified: false, message: "a trace does not record cache reads" }
                : { id, verified: true });
        }
        this.#caches = keep;
        return out;
    }

    /**
     * Every stop the cache breakpoints make on the current timeline
     * ([NDBG.12.5.3]): just after the firing (or the step) that made the
     * operation began.
     * @param {Timeline} tl
     * @returns {Array<{ k: number, stop: Stop }>}
     */
    #cacheStops(tl) {
        if (!this.#caches.length) return [];
        const rec = this.#session.engineRecord();
        if (rec === null) return [];
        const out = [];
        for (const op of rec.ops) {
            const bp = this.#caches.find((b) => (b.key === "" || b.key === op.key) && b.on.has(op.op));
            if (bp === undefined) continue;
            const what = op.op === "set" ? `cache set ${op.key} = ${op.value ?? "null"}`
                : op.op === "delete" ? `cache delete ${op.key} (${op.reason})` : `cache get ${op.key}`;
            const k = Math.min(op.at + 1, tl.length);
            out.push({ k, stop: { reason: "data breakpoint", description: what, focus: this.#firingAt(tl, k), hits: [bp.id] } });
        }
        return out;
    }

    /**
     * A fact's lifetime: its own, as its assert recorded it, else its schema's
     * (an assert's 0 is the schema's own, [NDBG.14.13.2]); 0 for none.
     * @param {Fact} f
     * @returns {bigint}
     */
    #ttlOf(f) {
        if (f.ttlNs > 0n) return f.ttlNs;
        return this.#s.view.queries?.prog.schemas.get(f.schema)?.ttlNs ?? 0n;
    }

    /**
     * The stops the fact and cache breakpoints make on `tl`, in order.
     * @param {Timeline} tl
     */
    async #dataStops(tl) {
        return [...await this.#factStops(tl), ...this.#cacheStops(tl)].sort((a, b) => a.k - b.k);
    }

    /**
     * `ds/getTimerAgenda` ([NDBG.14.8]): the cooldown windows armed and still
     * open at the point, and each live fact's TTL deadline, in clock order.
     * Pending `after` timers are not listed: the engine does not report them.
     */
    timerAgenda() {
        const s = this.#s, tl = s.tl, k = s.k, now = tl.clockAt(k), t0 = tl.clockAt(0);
        /** @type {Array<{ ends: bigint, row: Record<string, unknown> }>} */
        const rows = [];
        for (const t of this.#session.engineRecord()?.timers ?? []) {
            if (t.at >= k || t.fireAtNs <= now) continue;
            rows.push({ ends: t.fireAtNs, row: { kind: t.kind, rule_name: t.rule, ends_at_ns: Number(t.fireAtNs - t0),
                                                 remaining_ns: Number(t.fireAtNs - now) } });
        }
        for (const f of tl.liveFacts(k)) {
            const ttl = this.#ttlOf(f);
            if (ttl <= 0n) continue;
            const ends = tl.clockAt(f.asserted + 1) + ttl;
            rows.push({ ends, row: { kind: "ttl", fact_id: `#${f.factId}`, ends_at_ns: Number(ends - t0),
                                     remaining_ns: Number(ends - now) } });
        }
        rows.sort((a, b) => (a.ends < b.ends ? -1 : a.ends > b.ends ? 1 : 0));
        return { timers: rows.map((r) => r.row), after_listed: false };
    }

    /**
     * Every stop the fact breakpoints make on `tl`, in order: each assert and
     * retract of a fact of the schema that meets the condition, counted from
     * the timeline's start ([NDBG.12.3.5]).
     * @param {Timeline} tl
     * @returns {Promise<Array<{ k: number, stop: Stop }>>}
     */
    async #factStops(tl) {
        if (!this.#facts.length) return [];
        const v = this.#s.view;
        /** @type {Array<{ k: number, stop: Stop }>} */
        const out = [];
        for (const bp of this.#facts) {
            /** @type {Set<bigint> | null} the facts that met the condition as they were asserted */
            let metAt = null;
            /** @type {Set<bigint> | null} the facts that met it until they were retracted */
            let metEnd = null;
            if (bp.where !== null && v.queries !== null) {
                const qe = await v.queries.get(factQuery(bp.schema, bp.where), tl.length);
                metAt = new Set();
                metEnd = new Set();
                for (const a of qe.answers) {
                    const id = a.bindings[0], f = tl.facts.get(id);
                    if (f === undefined) continue;
                    if (a.start === f.asserted) metAt.add(id);
                    if (a.end !== null && a.end === f.ended) metEnd.add(id);
                }
            }
            /** @type {Array<{ k: number, f: Fact, what: "asserted" | "retracted" }>} */
            const events = [];
            for (const f of tl.facts.values()) {
                if (f.schema !== bp.schema) continue;
                if (bp.on.has("assert") && (metAt === null || metAt.has(f.factId)))
                    events.push({ k: f.asserted + 1, f, what: "asserted" });
                if (bp.on.has("retract") && f.ended !== null && (metEnd === null || metEnd.has(f.factId)))
                    events.push({ k: f.ended + 1, f, what: "retracted" });
            }
            events.sort((a, b) => a.k - b.k);
            events.forEach((e, i) => {
                if (bp.hit !== null && !bp.hit(i + 1)) return;
                const why = e.what === "retracted" ? ` (${retractor(tl, e.f)})` : "";
                const slots = Object.entries(e.f.slots ?? {}).map(([s, x]) => `${s}=${typeof x === "string" ? x : show(x)}`);
                out.push({ k: e.k, stop: { reason: "data breakpoint", focus: this.#firingAt(tl, e.k), hits: [bp.id],
                                           description: `${e.f.schema} #${e.f.factId} ${e.what}${why}: ${slots.join(", ")}` } });
            });
        }
        return out.sort((a, b) => a.k - b.k);
    }

    /**
     * `setExceptionBreakpoints` ([NDBG.12.6.1]).
     * @param {unknown} filters
     */
    setExceptionFilters(filters) {
        const known = new Set(EXCEPTION_FILTERS.map((f) => f.filter));
        const want = Array.isArray(filters) ? filters.filter((f) => typeof f === "string") : [];
        const bad = want.find((f) => !known.has(f));
        if (bad !== undefined) throw new Refused(`no exception filter \`${bad}\`: ${[...known].join(", ")}`);
        this.#filters = new Set(want);
    }

    /**
     * A breakpoint with its hit count read, and its condition and log message
     * compiled for each rule it stops in ([NDBG.12.1.2], [NDBG.12.1.4]): the
     * rule's own patterns as a query, the condition added to the last of
     * them, the message's `{…}` expressions as its projection. What the
     * compiler refuses, the breakpoint is unverified with.
     * @param {RuleBreakpoint} bp
     * @param {{ condition?: string, hitCondition?: string, logMessage?: string }} b
     * @returns {Promise<RuleBreakpoint>}
     */
    async #qualify(bp, b) {
        if (b.hitCondition) {
            const hit = hitTest(b.hitCondition);
            if (hit === null) return { ...bp, message: `\`${b.hitCondition}\` is not a hit count: \`5\`, \`>= 3\`, \`% 2\`` };
            bp.hit = hit;
        }
        const cond = b.condition?.trim() || null;
        const log = b.logMessage ? interpolation(b.logMessage) : null;
        if (log !== null && log.error !== undefined) return { ...bp, message: log.error };
        if (cond !== null || log !== null) {
            const queries = this.#s.view.queries;
            if (queries === null) return { ...bp, message: "needs the program's source" };
            bp.queries = new Map();
            for (const rule of bp.rules) {
                const pats = this.#session.patterns(rule);
                if (pats === null || !pats.length) return { ...bp, message: "needs the program's source" };
                const body = ruleQuery(pats, cond, log?.exprs ?? []);
                try {
                    await queries.get(body, 0);
                } catch (err) {
                    if (!(err instanceof Error) || err.name !== "QueryError") throw err;
                    return { ...bp, message: cond === null ? err.message : refusalIn(err, cond) };
                }
                bp.queries.set(rule, body);
            }
            bp.log = log?.parts ?? null;
        }
        bp.verified = true;
        return bp;
    }

    /**
     * The answers to every breakpoint's queries over `tl`, for the sync
     * judgements below to read (`#judged`).
     * @param {Timeline} tl
     */
    async #prime(tl) {
        const queries = this.#s.view.queries;
        /** @type {Map<string, import("../core/query.js").Answer[]>} */
        const got = new Map();
        if (queries !== null)
            for (const bp of this.#ruleBreakpoints())
                for (const body of bp.queries?.values() ?? [])
                    if (!got.has(body)) got.set(body, (await queries.get(body, tl.length)).answers);
        this.#judged = got;
    }

    /** @returns {RuleBreakpoint[]} every line and function breakpoint */
    #ruleBreakpoints() {
        return [...[...this.#lines.values()].flat(), ...this.#functions];
    }

    /**
     * Whether `fr` meets `bp`'s query: an answer to it, binding the facts the
     * firing matched, held as the firing began. Its projected values, for a
     * logpoint, or null when it does not; true with no query at all.
     * @param {RuleBreakpoint} bp
     * @param {Firing} fr
     * @returns {string[] | boolean}
     */
    #meets(bp, fr) {
        const body = bp.queries?.get(fr.rule);
        if (body === undefined) return true;
        const ids = this.#session.bindings(fr)?.map((b) => b.id);
        if (ids === undefined) return false;
        const key = ids.join(",");
        const a = (this.#judged.get(body) ?? []).find((x) => x.key === key && x.liveAt(fr.begin + 1));
        if (a === undefined) return false;
        return a.values ?? true;
    }

    /** @returns {Set<string>} the program's rules, by name */
    #ruleNames() {
        const metas = this.#session.rules();
        if (metas !== null) return new Set(metas.keys());
        return new Set(this.#s.tl.firings.map((f) => f.rule));
    }

    /**
     * The breakpoints `fr` hits, each counted from the timeline's start
     * ([NDBG.12.1.3]).
     * @param {Timeline} tl
     * @param {Firing} fr
     * @returns {number[]}
     */
    #hits(tl, fr) {
        const out = [];
        for (const bp of this.#ruleBreakpoints()) if (bp.log === null && this.#hit(tl, bp, fr) !== false) out.push(bp.id);
        return out;
    }

    /**
     * Whether `fr` is a hit of `bp`, counted from the timeline's start among
     * the firings that meet its condition: false, or what `#meets` gave.
     * @param {Timeline} tl
     * @param {RuleBreakpoint} bp
     * @param {Firing} fr
     * @returns {string[] | boolean}
     */
    #hit(tl, bp, fr) {
        if (!bp.rules.has(fr.rule)) return false;
        const met = this.#meets(bp, fr);
        if (met === false || bp.hit === null) return met;
        let n = 0;
        for (const f of tl.firings) {
            if (f.begin > fr.begin) break;
            if (bp.rules.has(f.rule) && this.#meets(bp, f) !== false) n++;
        }
        return bp.hit(n) ? met : false;
    }

    /**
     * The logpoints' lines for the firings that begin as the session moves
     * forward from point `from` to `to` ([NDBG.12.1.4]): each opens with the
     * firing and its instant.
     * @param {Timeline} tl
     * @param {number} from
     * @param {number} to
     * @returns {string[]}
     */
    #logs(tl, from, to) {
        /** @type {string[]} */
        const out = [];
        const points = this.#ruleBreakpoints().filter((b) => b.log !== null);
        if (!points.length || to <= from) return out;
        for (const fr of tl.firings) {
            const at = fr.begin + 1;
            if (at <= from || at > to) continue;
            for (const bp of points) {
                const got = this.#hit(tl, bp, fr);
                if (got === false) continue;
                const values = Array.isArray(got) ? got : [];
                const parts = /** @type {string[]} */ (bp.log);
                const text = parts.map((p, i) => (i % 2 ? values[(i - 1) / 2] ?? "" : p)).join("");
                out.push(`!${tl.firings.indexOf(fr) + 1} at T=${seconds(tl, at)}: ${text}`);
            }
        }
        return out;
    }

    // ── moving ─────────────────────────────────────────────────────────────

    /**
     * `next` and `stepBack` ([NDBG.11.1.1], [NDBG.14r.3.1]): one step at the
     * current granularity. At a live run's end a forward step would feed the
     * engine its next input; with none to feed it stays where it is
     * ([NDBG.14.1.1]), and says so.
     * @param {boolean} forward
     * @returns {Promise<Moved>}
     */
    async step(forward) {
        const s = this.#s, tl = s.tl, k = s.k;
        if (forward && s.atEngineEnd()) return this.#feed();
        await this.#prime(tl);
        const stops = this.#stops(tl, this.granularity);
        const i = forward ? bisectRight(stops, k) : bisectLeft(stops, k) - 1;
        if (i < 0) return this.#stay("at the start: nothing before it");
        if (i >= stops.length) {
            if (k === tl.length) return this.#stay(this.live ? "nothing left to feed the engine: the session stays paused"
                : "at the end of the trace: nothing after it");
            return this.#land(tl.length, { reason: "step", focus: null });
        }
        return this.#land(stops[i], { reason: "step", focus: this.#firingAt(tl, stops[i]) });
    }

    /**
     * `continue` and `reverseContinue` ([NDBG.11.1.1], [NDBG.14r.4.1]): to
     * the nearest stop a breakpoint or an exception filter makes, or to the
     * end, or the start.
     * @param {boolean} forward
     * @returns {Promise<Moved>}
     */
    async run(forward) {
        const s = this.#s, tl = s.tl, k = s.k;
        if (forward && s.atEngineEnd()) {
            // A fork runs on through the real run's inputs, and a live run
            // through its fact files' rows, to a stop.
            /** @type {string[]} */
            const logs = [], stdout = [];
            /** @type {Moved["events"]} */
            const events = [];
            for (;;) {
                const from = s.k;
                let got;
                try {
                    got = await this.#feedOne();
                } catch (err) {
                    if (!(err instanceof Refused)) throw err;
                    const end = this.#stay(err.message);
                    return { ...end, logs, stdout, events };
                }
                logs.push(...got.logs);
                stdout.push(...got.stdout);
                events.push(...got.events);
                const hit = this.#nearest(s.tl, from, true, await this.#dataStops(s.tl));
                if (hit !== null) {
                    const moved = this.#land(hit.k, hit.stop, [], s.k, false);
                    return { ...moved, logs, stdout, events };
                }
            }
        }
        await this.#prime(tl);
        const found = this.#nearest(tl, k, forward, await this.#dataStops(tl));
        if (found !== null) return this.#land(found.k, found.stop);
        if (!forward) return this.#land(0, { reason: "step", description: "the start of the timeline", focus: null });
        return this.#land(tl.length, { reason: "pause", description: this.live
            ? "the end of the run: nothing left to feed the engine" : "the end of the trace", focus: null });
    }

    /**
     * The firings the action at the point caused, in order ([NDBG.11.1.1]):
     * each later firing whose match includes a fact the action asserted.
     * Empty when the action asserted nothing; refused when the trace does not
     * say what the later firings matched, since that is not the same as none.
     * @returns {Firing[]}
     */
    #caused() {
        const s = this.#s, tl = s.tl, k = s.k;
        const fr = this.#firingAt(tl, k);
        if (fr === null) return [];
        const e = fr.effects.find((i) => i >= k);
        const r = e === undefined ? undefined : tl.records[e];
        if (r === undefined || !is(r, "FactEmit")) return [];
        return this.#matching(tl, new Set([r.body.fact_id]), e ?? k, tl.length);
    }

    /**
     * The firings that begin in `(after, before)` and match any of `ids`.
     * @param {Timeline} tl
     * @param {Set<bigint>} ids
     * @param {number} after  a record index
     * @param {number} before
     * @returns {Firing[]}
     */
    #matching(tl, ids, after, before) {
        const out = [];
        for (const f of tl.firings) {
            if (f.begin <= after || f.begin >= before) continue;
            const got = this.#session.bindings(f);
            if (got === null) throw new Refused("this trace does not record which facts each firing matched, so what an "
                                                + "action caused cannot be followed");
            if (got.some((b) => ids.has(b.id))) out.push(f);
        }
        return out;
    }

    /**
     * `stepInTargets` ([NDBG.11.1.1]): every firing the action at the point
     * caused, the earliest first.
     * @returns {Array<{ id: number, label: string }>}
     */
    stepInTargets() {
        if (this.live) return [];
        const tl = this.#s.tl;
        return this.#caused().map((f) => ({ id: this.threadId(f), label: `!${tl.firings.indexOf(f) + 1} ${this.#threadName(tl, f)}` }));
    }

    /**
     * `stepIn` ([NDBG.11.1.1], [NDBG.11.1.2]): in replay, to the firing the
     * action caused (`target`, a thread id `stepInTargets` gave, else the
     * earliest), passing the firings between; a breakpoint on the way stops
     * it there ([NDBG.11.1.3]). Live, or where the action caused nothing,
     * `next`.
     * @param {unknown} target
     * @returns {Promise<Moved>}
     */
    async stepIn(target) {
        if (this.live) return this.step(true);
        const tl = this.#s.tl;
        const caused = this.#caused();
        if (!caused.length) return this.step(true);
        const to = target === undefined || target === null ? caused[0]
            : caused.find((f) => this.threadId(f) === Number(target));
        if (to === undefined) throw new Refused(`step-in target ${target} is not one the action caused`);
        return this.#toward(to.begin + 1, { reason: "step", focus: to });
    }

    /**
     * `stepOut` ([NDBG.11.1.1]): in replay, until every firing the current
     * one caused, directly or through others, within this pump has fired;
     * then to the next firing, or the pump's settled point when there is
     * none. Live, `next` ([NDBG.11.1.2]).
     * @returns {Promise<Moved>}
     */
    async stepOut() {
        if (this.live) return this.step(true);
        const s = this.#s, tl = s.tl, k = s.k;
        const fr = this.#firingAt(tl, k);
        if (fr === null) return this.step(true);
        const end = tl.nextSettled(k) ?? tl.length;
        /** @type {Set<Firing>} */
        const done = new Set([fr]);
        let wave = [fr], last = fr;
        while (wave.length) {
            /** @type {Set<bigint>} */
            const ids = new Set();
            for (const f of wave) for (const e of f.effects) {
                const r = tl.records[e];
                if (r !== undefined && is(r, "FactEmit")) ids.add(r.body.fact_id);
            }
            wave = ids.size ? this.#matching(tl, ids, fr.begin, end).filter((f) => !done.has(f)) : [];
            for (const f of wave) {
                done.add(f);
                if (f.begin > last.begin) last = f;
            }
        }
        const after = last.end ?? last.begin;
        const next = tl.firings.find((f) => f.begin > after);
        if (next === undefined || next.begin >= end) return this.#toward(end, { reason: "step", focus: null });
        return this.#toward(next.begin + 1, { reason: "step", focus: next });
    }

    /**
     * Forward to point `k` as `stop`, unless a breakpoint or a filter stops
     * the way first ([NDBG.11.1.3]).
     * @param {number} k
     * @param {Stop} stop
     */
    async #toward(k, stop) {
        const tl = this.#s.tl;
        await this.#prime(tl);
        const first = this.#nearest(tl, this.#s.k, true, await this.#dataStops(tl));
        if (first !== null && first.k < k) return this.#land(first.k, first.stop);
        return this.#land(k, stop);
    }

    /**
     * `gotoTargets` ([NDBG.14r.5.1]): on a rule, `after` or `on response`
     * line, each firing of that body; on a `schema` line, each assert of
     * that schema. At most the 1,000 nearest the point.
     * @param {string} path
     * @param {number} line
     * @returns {Array<{ id: number, label: string, line: number }>}
     */
    gotoTargets(path, line) {
        const s = this.#s, tl = s.tl, k = s.k, file = resolve(path);
        /** @type {Array<{ k: number, label: string, focus: Firing | null }>} */
        const found = [];
        const rules = new Set([...this.#where].filter(([, at]) => at.file === file && at.line === line).map(([r]) => r));
        for (const f of tl.firings)
            if (rules.has(f.rule))
                found.push({ k: f.begin + 1, label: `!${tl.firings.indexOf(f) + 1} at T=${seconds(tl, f.begin + 1)}`, focus: f });
        const schema = this.#schemaAt(file, line);
        if (schema !== null)
            for (const f of tl.facts.values())
                if (f.schema === schema)
                    found.push({ k: f.asserted + 1, label: `#${f.factId} at T=${seconds(tl, f.asserted + 1)}`, focus: null });
        found.sort((a, b) => Math.abs(a.k - k) - Math.abs(b.k - k) || a.k - b.k);
        const near = found.slice(0, 1000).sort((a, b) => a.k - b.k);
        // Each target keeps its id until the session moves: a client may ask
        // for several lines' targets before it goes to one.
        return near.map((t) => {
            const id = this.#nextGoto++;
            this.#gotos.set(id, t);
            return { id, label: t.label, line };
        });
    }

    /**
     * `goto` ([NDBG.14r.5.2]): to a target the last `gotoTargets` gave.
     * @param {unknown} id
     * @returns {Moved}
     */
    goto(id) {
        const t = this.#gotos.get(Number(id));
        if (t === undefined) throw new Refused(`no goto target ${id} at this stop: ask gotoTargets first`);
        return this.#land(t.k, { reason: "goto", focus: t.focus }, [], this.#s.k, false);
    }

    /**
     * The schema a `schema` declaration on `line` of `file` names, or null.
     * @param {string} file
     * @param {number} line
     */
    #schemaAt(file, line) {
        if (!this.#given.includes(file)) return null;
        let text;
        try {
            text = readFileSync(file, "utf8");
        } catch {
            return null;
        }
        const m = /^schema\s+([A-Za-z_]\w*)/.exec(text.split(/\r?\n/)[line - 1] ?? "");
        return m === null ? null : m[1];
    }

    /**
     * A forward step at the end of an engine's timeline: a fork takes the
     * real run's next input (dsdb's `n`); a live run has nothing to feed
     * until the `facts` launch argument arrives, and stays paused, saying so
     * ([NDBG.14.1.1]).
     * @returns {Promise<Moved>}
     */
    async #feed() {
        try {
            return await this.#feedOne();
        } catch (err) {
            if (!(err instanceof Refused)) throw err;
            return this.#stay(err.message);
        }
    }

    /**
     * One input at an engine timeline's end: a fork's next input from the
     * real run, or a live run's next fact-file row ([NDBG.9.3.1] `facts`):
     * the clock moved to its `@at` with no pump, the fact asserted, one
     * pump, as batch mode feeds a row. Refused when there is none.
     * @returns {Promise<Moved>}
     */
    async #feedOne() {
        const s = this.#s;
        if (s.view.hyp !== null) return (await this.#change(() => this.#session.execute("n"))).moved;
        const run = s.liveRun, row = this.#inputs[0];
        if (run === null || s.cur !== 0 || row === undefined)
            throw new Refused("nothing left to feed the engine: the session stays paused");
        this.#inputs.shift();
        const from = s.k;
        try {
            const at = this.#start + row.at;
            run.assertFactAt(at, row.schema, rowSlots(row, at));
        } catch (err) {
            if (!(err instanceof Error) || err.name !== "DsError") throw err;
            throw new Refused(`${row.file}:${row.line}: the engine refused the row: ${err.message}`);
        }
        const said = await this.#autoAnswer();
        const tl = s.tl;
        await this.#prime(tl);
        const fired = tl.firingsIn(from, tl.length);
        return this.#land(tl.length, { reason: "step", focus: fired[0] ?? null }, said, from);
    }

    // ── mocks ([NDBG.14.15], [NDBG.14.16]) ────────────────────────────────────

    /**
     * `ds/installMock`: a standing answer, by `corr` or by `service`, with a
     * `response` row or an `error`, for `times` calls (0: until removed;
     * absent: 1). In replay, or behind a live run's end, a mock that would
     * answer a recorded call after the point differently opens a fork at the
     * first such call, and the session follows it ([NDBG.14.15.2]).
     * @param {any} args
     * @returns {Promise<{ body: Record<string, unknown>, moved: Moved | null }>}
     */
    async installMock(args) {
        const by = ["corr", "service"].filter((x) => args?.[x] !== undefined && args[x] !== null);
        const with_ = ["response", "error"].filter((x) => args?.[x] !== undefined && args[x] !== null);
        if (by.length !== 1) throw new Refused("a mock carries exactly one of `corr` and `service`");
        if (with_.length !== 1) throw new Refused("a mock carries exactly one of `response` and `error`");
        const times = args.times === undefined || args.times === null ? 1 : Number(args.times);
        if (!Number.isInteger(times) || times < 0) throw new Refused("`times` is a whole number: 0 until removed");
        if (with_[0] === "response" && (typeof args.response !== "object" || Array.isArray(args.response)))
            throw new Refused("`response` is one row of the response schema: a JSON object");
        const id = `mock-${String(this.#nextMock++).padStart(4, "0")}`;
        /** @type {Mock} */
        const m = { id, corr: by[0] === "corr" ? String(args.corr) : null, service: by[0] === "service" ? String(args.service) : null,
                    response: with_[0] === "response" ? args.response : null,
                    error: with_[0] === "error" ? { code: String(args.error.code ?? ""), message: String(args.error.message ?? "") } : null,
                    left: times === 0 ? Infinity : times };
        this.#mocks.push(m);
        const s = this.#s;
        if (s.atEngineEnd()) {
            const said = await this.#autoAnswer();
            if (!said.length) return { body: { mock_id: id }, moved: null };
            await this.#prime(s.tl);
            return { body: { mock_id: id }, moved: this.#land(s.tl.length, { reason: "step", focus: null }, said) };
        }
        const tl = s.tl;
        const c = tl.calls.find((x) => x.issued >= s.k && this.#matches(m, x) && this.#differs(tl, m, x));
        if (c === undefined) return { body: { mock_id: id }, moved: null };
        // dsdb replaces a recorded reply from just after it, forking before
        // it; an unanswered call is answered from the settled point after it.
        const answered = c.outcome === "answered" || c.outcome === "failed";
        s.k = answered && c.resolved !== null ? c.resolved + 1 : tl.nextSettled(c.issued) ?? tl.length;
        const got = await this.#change(() => this.#session.execute(this.#answerLine(m, c)));
        this.#spend(m);
        return { body: { mock_id: id, message: this.#landed(got.forked, `answered call ${c.number} from ${id}`,
                                                             `call ${c.number} answered from ${id}`) },
                 moved: got.moved };
    }

    /**
     * `ds/removeMock` ([NDBG.14.16]).
     * @param {unknown} id
     */
    removeMock(id) {
        const i = this.#mocks.findIndex((m) => m.id === id);
        if (i < 0) throw new Refused(`no mock ${JSON.stringify(id)}`);
        this.#mocks.splice(i, 1);
    }

    /**
     * Answer, from the mocks, every call waiting at an engine timeline's
     * end that one matches, and the calls those answers make, until none is
     * left. What was answered, said.
     * @returns {Promise<string[]>}
     */
    async #autoAnswer() {
        const s = this.#s, said = [];
        /** @type {Set<string>} */
        const tried = new Set();
        for (;;) {
            if (!s.atEngineEnd() || !this.#mocks.length) return said;
            const tl = s.tl, end = tl.length;
            let made = false;
            for (const c of tl.calls) {
                const open = c.waitingAt(end) || (!c.waits && c.corr !== null && c.resolved === null && c.issued < end);
                const key = `${s.cur}\0${c.number}`;
                if (!open || tried.has(key)) continue;
                const m = this.#mocks.find((x) => x.left > 0 && this.#matches(x, c) && (x.response === null || c.waits));
                if (m === undefined) continue;
                tried.add(key);
                const r = await this.#session.execute(this.#answerLine(m, c));
                const e = r.find((x) => x.type === "error");
                if (e !== undefined && e.type === "error") said.push(`${m.id} could not answer call ${c.number}: ${e.text}`);
                else {
                    said.push(`${m.id} answered call ${c.number} (${c.service})`);
                    this.#spend(m);
                    made = true;
                }
                break;
            }
            if (!made) return said;
        }
    }

    /**
     * @param {Mock} m
     * @param {Call} c
     */
    #matches(m, c) {
        return m.corr !== null ? c.corr === m.corr : c.service === m.service;
    }

    /**
     * Whether `m` answers recorded call `c` otherwise than the trace did.
     * @param {Timeline} tl
     * @param {Mock} m
     * @param {Call} c
     */
    #differs(tl, m, c) {
        const reply = c.resolved === null ? undefined : tl.records[c.resolved];
        const f = reply !== undefined && is(reply, "FactAssert") ? tl.facts.get(reply.body.fact_id) : undefined;
        if (m.error !== null) {
            if (c.outcome !== "failed" || f === undefined) return true;
            return String(f.slots?.code ?? "") !== m.error.code || String(f.slots?.message ?? "") !== m.error.message;
        }
        if (c.outcome !== "answered" || f === undefined) return true;
        return Object.entries(m.response ?? {}).some(([k, v]) => String(f.slots?.[k]) !== String(v));
    }

    /**
     * The dsdb change that answers `c` as `m` says.
     * @param {Mock} m
     * @param {Call} c
     */
    #answerLine(m, c) {
        if (m.error !== null) {
            if (/["\n\r]/.test(m.error.code + m.error.message)) throw new Refused("a mock's code and message hold no double quote or newline");
            return `from here fail ${c.number} code: "${m.error.code}" message: "${m.error.message}"`;
        }
        return `from here answer ${c.number} ${JSON.stringify(m.response ?? {})}`;
    }

    /**
     * One answer spent; a mock with none left goes ([NDBG.14.15.3]).
     * @param {Mock} m
     */
    #spend(m) {
        m.left -= 1;
        if (m.left <= 0) this.#mocks = this.#mocks.filter((x) => x !== m);
    }

    /** How many fact-file rows are still to feed. */
    get inputsLeft() {
        return this.#inputs.length;
    }

    // ── inspection ([NDBG.14.3] to [NDBG.14.12]) ───────────────────────────

    /**
     * A firing of the current timeline by `"!N"` or by its thread id
     * ([NDBG.14.11.3]).
     * @param {any} args  `{ firing }` or `{ threadId }`
     * @returns {Firing}
     */
    #firing(args) {
        const s = this.#s, tl = s.tl;
        if (args?.firing !== undefined) {
            const m = /^!(\d+)$/.exec(String(args.firing));
            const fr = m === null ? undefined : tl.firings[Number(m[1]) - 1];
            if (fr === undefined) throw new Refused(`no firing ${args.firing} in %${s.cur}`);
            return fr;
        }
        const id = Number(args?.threadId);
        for (const [key, tid] of this.#threadIds) {
            if (tid !== id) continue;
            const [n, i] = key.split("\0").map(Number);
            const fr = n === s.cur ? tl.firings[i] : undefined;
            if (fr !== undefined) return fr;
        }
        throw new Refused(`no firing with thread id ${args?.threadId} in %${s.cur}`);
    }

    /**
     * A firing's `"!N"`, clock and display name, as the inspection requests
     * give a firing.
     * @param {Timeline} tl
     * @param {Firing} fr
     */
    #firingRef(tl, fr) {
        return { rule_name: fr.rule, firing: `!${tl.firings.indexOf(fr) + 1}`, display_name: this.#threadName(tl, fr),
                 clock_ns: clockNs(tl, fr.begin + 1) };
    }

    /**
     * The firing whose actions include record `i`, or null.
     * @param {Timeline} tl
     * @param {number} i
     */
    #by(tl, i) {
        return tl.firings.find((f) => f.effects.includes(i)) ?? null;
    }

    /**
     * `ds/getFactLineage` ([NDBG.14.4]): who asserted a fact and, if it is
     * gone at the point, what retracted it.
     * @param {any} args  `{ fact_id }`
     */
    lineage(args) {
        const s = this.#s, tl = s.tl, id = factId(args?.fact_id);
        const f = tl.facts.get(id);
        if (f === undefined || f.asserted >= s.k) throw new Refused(`no fact #${id} at this point in %${s.cur}`);
        const asserter = this.#asserter(tl, f);
        /** @type {Record<string, unknown> | null} */
        let gone = null;
        if (f.ended !== null && f.ended < s.k) {
            const kind = retractor(tl, f);
            const by2 = kind === "rule" ? this.#by(tl, f.ended) : null;
            gone = { kind, clock_ns: clockNs(tl, f.ended + 1),
                     ...(by2 === null ? {} : { rule_name: by2.rule, firing: `!${tl.firings.indexOf(by2) + 1}` }) };
        }
        return { asserter, retractor: gone };
    }

    /**
     * `ds/getActivationPath` ([NDBG.14.11]): the facts that matched each
     * pattern of a firing, in pattern order.
     * @param {any} args
     */
    activationPath(args) {
        const tl = this.#s.tl, fr = this.#firing(args);
        const got = this.#session.bindings(fr);
        if (got === null) throw new Refused("this trace does not record which facts the firing matched");
        const steps = got.map((b, i) => {
            const f = tl.facts.get(b.id);
            return { pattern_index: i, schema: f?.schema ?? null, binding: b.name, fact_id: `#${b.id}`,
                     slots: f === undefined ? null : wireSlots(f.slots), join_result: "passed",
                     join_detail: i === 0 ? "the first pattern: its alpha tests passed"
                         : `joined with the ${i === 1 ? "pattern" : `${i} patterns`} before it` };
        });
        return { rule_name: fr.rule, display_name: this.#threadName(tl, fr), steps };
    }

    /**
     * `ds/getJustifiers` ([NDBG.14.3]): a logical fact's active justifiers,
     * as the engine at the point reports them.
     * @param {any} args  `{ fact_id }`
     */
    justifiers(args) {
        const s = this.#s, tl = s.tl, id = factId(args?.fact_id);
        const f = tl.facts.get(id);
        if (f === undefined || !f.liveAt(s.k)) throw new Refused(`fact '#${id}' not in working memory`);
        const just = this.#engine((eng) => eng.justifiers(id));
        return { justifiers: just.map((j) => {
            const fr = tl.firings.find((x) => x.rule === j.ruleName && x.timetag === j.timetag);
            return fr === undefined ? { rule_name: j.ruleName, firing: null, display_name: j.ruleName, clock_ns: null }
                : this.#firingRef(tl, fr);
        }) };
    }

    /**
     * `ds/getReteNetwork` ([NDBG.14.6]): the network, or one rule's part of
     * it, with each node's occupancy at the point when asked.
     * @param {any} args  `{ rule_name, include_occupancy }`
     */
    reteNetwork(args) {
        const rule = typeof args?.rule_name === "string" && args.rule_name ? args.rule_name : null;
        const occupancy = args?.include_occupancy === true;
        if (rule !== null && !this.#ruleNames().has(rule)) throw new Refused(`no rule named '${rule}' in the loaded rule set`);
        const { nodes, edges, spans } = this.#engine((eng) => {
            const net = eng.reteNetwork({ ruleFilter: rule, includeOccupancy: occupancy });
            return { ...net, spans: new Map(net.nodes.slice(0, 1000).map((n) => [n.id, this.#span(eng, n.id)])) };
        });
        const truncated = nodes.length > 1000;
        const out = nodes.slice(0, 1000).map((n) => {
            const at = spans.get(n.id) ?? null;
            return { id: n.id, kind: n.kind, label: n.label, ...(n.filter ? { filter: n.filter } : {}),
                     ...(n.kind === "terminal" ? { pending_activations: occupancy ? n.occupancy : null }
                         : { occupancy: occupancy ? n.occupancy : null }),
                     ...(at === null ? {} : { source: at }) };
        });
        const ids = new Set(out.map((n) => n.id));
        return { nodes: out, edges: edges.filter((e) => ids.has(e.fromId) && ids.has(e.toId)).map((e) => ({ from: e.fromId, to: e.toId })),
                 ...(truncated ? { truncated: true, node_count: nodes.length } : {}) };
    }

    /**
     * `ds/getMatchTrace` ([NDBG.14.7]): a fact through the alpha tests; the
     * joins are not traced ([NDBG.4.2]).
     * @param {any} args  `{ fact_id }`
     */
    matchTrace(args) {
        const s = this.#s, tl = s.tl, id = factId(args?.fact_id);
        const f = tl.facts.get(id);
        if (f === undefined || !f.liveAt(s.k)) throw new Refused(`fact '#${id}' not in working memory`);
        const steps = this.#engine((eng) => eng.reteMatchTrace(id).map((x) => ({ x, at: this.#span(eng, x.nodeId) })));
        return { fact: { schema: f.schema, slots: wireSlots(f.slots) },
                 path: steps.map(({ x, at }) => ({ node_id: x.nodeId, node_kind: x.nodeKind, result: x.result, detail: x.detail,
                                                   ...(at === null ? {} : { source: at }) })),
                 joins_traced: false };
    }

    /**
     * `ds/getRefractedActivations` ([NDBG.14.12]): what refraction held back
     * at the point, each binding by its source name. Supersedure is not
     * reported.
     * @param {any} args  `{ rule_name }`
     */
    refracted(args) {
        const tl = this.#s.tl;
        const rule = typeof args?.rule_name === "string" && args.rule_name ? args.rule_name : null;
        const got = this.#engine((eng) => eng.refractedActivations(rule));
        const refracted = got.map((r) => {
            const pats = this.#session.patterns(r.ruleName);
            const names = pats === null ? [] : lhsOf(pats).names;
            /** @type {Record<string, unknown>} */
            const bindings = {};
            r.factIds.forEach((fid, i) => {
                const name = (names.length === r.factIds.length ? names[i] : null) ?? `[${i}]`;
                const f = fid === null ? undefined : tl.facts.get(fid);
                bindings[name] = fid === null ? { fact_id: null } : { fact_id: `#${fid}`, ...(f === undefined ? {} : wireSlots(f.slots)) };
            });
            return { rule_name: r.ruleName, display_name: r.ruleName, reason: "refraction", detail: r.detail, bindings };
        });
        return { refracted, suppressed: [], supersedure_reported: false };
    }

    /**
     * `ds/getWorkingMemory` ([NDBG.14w]): the facts at the point, of one
     * schema or all, a `where` (which needs `schema`) compiled as a fact
     * breakpoint's is.
     * @param {any} args  `{ schema, where, limit, offset }`
     */
    async workingMemory(args) {
        const s = this.#s, tl = s.tl, k = s.k, v = s.view;
        const schema = typeof args?.schema === "string" && args.schema ? args.schema : null;
        const where = typeof args?.where === "string" && args.where.trim() ? args.where.trim() : null;
        if (where !== null && schema === null) throw new Refused("`where` needs `schema`: it names the fact by its schema");
        if (schema !== null && !(v.queries?.prog.schemas.has(schema) ?? tl.schemas().includes(schema)))
            throw new Refused(`no schema '${schema}'`);
        let facts = tl.liveFacts(k).filter((f) => schema === null || f.schema === schema);
        if (where !== null && schema !== null) {
            if (v.queries === null) throw new Refused("`where` needs the program's source");
            /** @type {Set<bigint>} */
            let met;
            try {
                met = new Set((await v.queries.get(factQuery(schema, where), k)).at(k).map((a) => a.bindings[0]));
            } catch (err) {
                if (!(err instanceof Error) || err.name !== "QueryError") throw err;
                throw new Refused(refusalIn(err, where));
            }
            facts = facts.filter((f) => met.has(f.factId));
        }
        facts.sort((a, b) => a.asserted - b.asserted);
        const offset = Number.isInteger(args?.offset) && args.offset > 0 ? args.offset : 0;
        const limit = Number.isInteger(args?.limit) && args.limit > 0 ? args.limit : facts.length;
        const now = tl.clockAt(k);
        const page = facts.slice(offset, offset + limit).map((f) => {
            const logical = this.#session.lifecycle(f.schema) === "logical";
            const ttl = this.#ttlOf(f);
            const ends = ttl > 0n ? tl.clockAt(f.asserted + 1) + ttl : null;
            /** @type {number | null} */
            let just = null;
            if (logical) {
                try {
                    just = this.justifiers({ fact_id: `#${f.factId}` }).justifiers.length;
                } catch (err) {
                    if (!(err instanceof Refused)) throw err;
                }
            }
            return { fact_id: `#${f.factId}`, schema: f.schema, slots: wireSlots(f.slots), logical,
                     ttl_remaining_ns: ends === null ? null : Number(ends - now), ...(logical ? { _justifiers: just } : {}) };
        });
        return { facts: page, total: facts.length };
    }

    /**
     * `ds/diffWorkingMemory` ([NDBG.20]): what entered and left working memory
     * between two positions, each a timeline and an instant in it.
     * @param {any} args  `{ from: { timeline, at_ns }, to: { timeline, at_ns } }`
     */
    diffWorkingMemory(args) {
        const a = this.#position(args?.from, "from"), b = this.#position(args?.to, "to");
        /** @param {Fact} f @param {Timeline} tl */
        const row = (f, tl) => ({ schema: f.schema, fact_id: `#${f.factId}`, slots: wireSlots(f.slots), at: tl.clockAt(f.asserted + 1) });
        if (a.n === b.n) {
            if (a.ns >= b.ns) throw new Refused("from must be strictly before to");
            const tl = a.tl, t0 = tl.clockAt(0);
            /** @param {number} i  a record index */
            const inside = (i) => {
                const c = tl.records[i].clockNs - t0;
                return c >= a.ns && c < b.ns;
            };
            const facts = [...tl.facts.values()];
            const asserted = facts.filter((f) => inside(f.asserted)).sort((x, y) => x.asserted - y.asserted);
            const retracted = facts.filter((f) => f.ended !== null && inside(f.ended))
                .sort((x, y) => /** @type {number} */ (x.ended) - /** @type {number} */ (y.ended));
            return { asserted: asserted.map((f) => strip(row(f, tl))),
                     retracted: retracted.map((f) => strip({ ...row(f, tl), at: tl.clockAt(/** @type {number} */ (f.ended) + 1) })) };
        }
        // Across timelines, a fact is its schema and slots: ids are each
        // timeline's own after the fork. Facts are immutable, so the two
        // agree on a fact exactly when they agree on those.
        /** @param {Fact} f */
        const key = (f) => `${f.schema}\0${JSON.stringify(wireSlots(f.slots))}`;
        /** @param {{ tl: Timeline, k: number }} p */
        const live = (p) => {
            /** @type {Map<string, Fact[]>} */
            const m = new Map();
            for (const f of p.tl.liveFacts(p.k)) m.set(key(f), [...(m.get(key(f)) ?? []), f]);
            return m;
        };
        const was = live(a), now = live(b);
        /** @param {Map<string, Fact[]>} x @param {Map<string, Fact[]>} y */
        const minus = (x, y) => [...x].flatMap(([kk, fs]) => fs.slice(y.get(kk)?.length ?? 0));
        const asserted = minus(now, was).map((f) => row(f, b.tl)).sort((x, y) => (x.at < y.at ? -1 : x.at > y.at ? 1 : 0));
        const retracted = minus(was, now).map((f) => row(f, a.tl)).sort((x, y) => (x.at < y.at ? -1 : x.at > y.at ? 1 : 0));
        return { asserted: asserted.map(strip), retracted: retracted.map(strip) };
    }

    /**
     * A position ([NDBG.20.1]): a timeline and an instant in it, which must lie
     * within what the timeline recorded ([NDBG.20.5]).
     * @param {any} p
     * @param {string} what
     */
    #position(p, what) {
        const n = this.#timeline(p?.timeline ?? `%${this.#s.cur}`);
        const tl = this.#s.at(n).tl;
        const ns = Number(p?.at_ns);
        if (!Number.isFinite(ns) || ns < 0) throw new Refused(`\`${what}.at_ns\` is an instant in ns from the timeline's start`);
        const span = Number(tl.clockAt(tl.length) - tl.clockAt(0));
        if (ns > span) throw new Refused(`\`${what}\`: %${n} has recorded ${span} ns, not ${ns}`);
        const k = tl.firstAtClock(tl.clockAt(0) + BigInt(Math.trunc(ns)));
        return { n, tl, k, ns: BigInt(Math.trunc(ns)) };
    }

    /**
     * `fn` on the engine at the point.
     * @template T
     * @param {(eng: import("@ds-lang/ds").Engine) => T} fn
     * @returns {T}
     */
    #engine(fn) {
        try {
            return this.#session.readEngine(fn);
        } catch (err) {
            if (err instanceof RangeError) throw new Refused(`${err.message} (ds/stepGranularity pump)`);
            if (err instanceof Error && err.name === "DsError") throw new Refused(`the engine refused: ${err.message}`);
            throw err;
        }
    }

    /**
     * Where a Rete node is in the source, as the artefact's LineSpan maps it
     * ([NDBG.3.1]): the only route from a node to a line. null for a
     * node no span maps, which is every alpha ([RDSC.14.3.6]), or one whose
     * module has no path.
     * @param {import("@ds-lang/ds").Engine} eng
     * @param {string | number} id  as reteNetwork and reteMatchTrace give it
     * @returns {{ path: string, line: number, col: number } | null}
     */
    #span(eng, id) {
        let s;
        try {
            s = eng.lineSpan(Number(id));
        } catch (err) {
            if (err instanceof Error && err.name === "DsError" && /** @type {any} */ (err).status === DS_ERR_NOT_FOUND) return null;
            throw err;
        }
        return s.file ? { path: this.#path(s.file), line: s.line, col: s.column } : null;
    }

    // ── injects and timelines ([NDBG.14.13], [NDBG.14.17], [NDBG.14.19]) ──────

    /**
     * Run a change the session makes (an inject, a withdrawal, an answer)
     * and land at its end: into a live run at its end, else into a
     * hypothesis fork the session then follows.
     * @param {() => Promise<import("../core/types.js").Result[]> | import("../core/types.js").Result[]} change
     * @returns {Promise<{ moved: Moved, records: TraceRecord[], forked: boolean }>}
     */
    async #change(change) {
        const s = this.#s, was = s.cur;
        const results = await change();
        const errors = results.flatMap((r) => (r.type === "error" ? [r.text] : []));
        if (errors.length) throw new Refused(errors.join("\n"));
        const tl = s.tl;
        const shown = results.find((r) => r.type === "newRecords");
        const from = shown !== undefined && shown.type === "newRecords" ? shown.from : tl.length;
        const said = results.flatMap((r) => (r.type === "note" ? [r.text] : []));
        said.push(...await this.#autoAnswer());
        await this.#prime(tl);
        const fired = tl.firingsIn(from, tl.length);
        const moved = this.#land(tl.length, { reason: "step", focus: fired[0] ?? null }, said, from);
        return { moved, records: tl.records.slice(from), forked: s.cur !== was };
    }

    /**
     * Where a change landed, said ([NDBG.14.13.2]): "asserted Sensor #42 into
     * the real run", "opened fork %1 at T=12.000s with Sensor #42 asserted".
     * @param {boolean} forked
     * @param {string} done  the change, verb first
     * @param {string} change  the change, verb last
     */
    #landed(forked, done, change) {
        const s = this.#s;
        if (s.cur === 0) return `${done} into the real run`;
        const h = s.view.hyp;
        const at = h === null ? "" : ` at T=${seconds(s.at(h.source).tl, h.forkK)}`;
        return forked ? `opened fork %${s.cur}${at} with ${change}` : `${done} into %${s.cur}`;
    }

    /**
     * `ds/assertFact` ([NDBG.14.13]). A `ttl` is refused, as a fact file's
     * `@ttl` is: no public entry point sets a per-fact TTL, and a fact given
     * its schema's lifetime instead would expire at another time than the
     * request says. [NDBG.14.13.2] still offers `ttl`; the contradiction is
     * filed with the spec coordinator.
     * @param {any} args  `{ schema, slots }`
     */
    async assertFact(args) {
        const schema = typeof args?.schema === "string" ? args.schema : "";
        if (!schema) throw new Refused("`schema` names the fact's schema");
        const slots = args?.slots ?? {};
        if (slots === null || typeof slots !== "object" || Array.isArray(slots)) throw new Refused("`slots` is one row: a JSON object");
        if (args?.ttl !== undefined && args.ttl !== null) throw new Refused(NO_TTL);
        const got = await this.#change(() => this.#session.inject(schema, JSON.stringify(slots)));
        const r = got.records.find((x) => is(x, "FactAssert") && x.body.schema_name === schema);
        const id = r !== undefined && is(r, "FactAssert") ? r.body.fact_id : null;
        const fact = `${schema}${id === null ? "" : ` #${id}`}`;
        const message = this.#landed(got.forked, `asserted ${fact}`, `${fact} asserted`);
        return { ...got, body: { fact_id: id === null ? null : `#${id}`, timeline: `%${this.#s.cur}`, message } };
    }

    /**
     * `ds/retractFact` ([NDBG.14.14]): as dsdb's `withdraw` does it.
     * @param {any} args  `{ fact_id: "#42" }`
     */
    async retractFact(args) {
        const id = factId(args?.fact_id);
        const s = this.#s, f = s.tl.facts.get(id);
        // [NDBG.14.14.2]
        if (f === undefined || !f.liveAt(s.k)) throw new Refused(`fact '#${id}' not in working memory`);
        const got = await this.#change(() => this.#session.execute(`from here withdraw #${id}`));
        const what = `${f.schema} #${id}`;
        const message = s.cur === 0 ? `retracted ${what} from the real run`
            : this.#landed(got.forked, `retracted ${what}`, `${what} retracted`);
        return { ...got, body: { timeline: `%${this.#s.cur}`, message } };
    }

    /**
     * `ds/answerCall` ([NDBG.14.19]): one waiting call answered, with a row of
     * its response schema, or failed, as a CallError.
     * @param {any} args  `{ corr, response }` or `{ corr, error: { code, message } }`
     */
    async answerCall(args) {
        const s = this.#s, corr = args?.corr;
        const c = s.tl.waitingCalls(s.k).find((x) => x.corr === corr)
            ?? s.tl.calls.find((x) => x.corr === corr && !x.waits && x.issued < s.k && (x.resolved === null || x.resolved >= s.k));
        if (c === undefined) throw new Refused(`no call waiting as ${JSON.stringify(corr)}`);
        /** @type {string} */
        let line;
        if (args?.error !== undefined && args.error !== null) {
            const code = String(args.error.code ?? ""), msg = String(args.error.message ?? "");
            if (/["\n\r]/.test(code + msg)) throw new Refused("an error's code and message hold no double quote or newline");
            line = `from here fail ${c.number} code: "${code}" message: "${msg}"`;
        } else {
            const response = args?.response ?? {};
            if (response === null || typeof response !== "object" || Array.isArray(response))
                throw new Refused("`response` is one row of the response schema: a JSON object");
            line = `from here answer ${c.number} ${JSON.stringify(response)}`;
        }
        const got = await this.#change(() => this.#session.execute(line));
        const verb = args?.error ? "failed" : "answered", call = `call ${c.number} (${c.service})`;
        const message = this.#landed(got.forked, `${verb} ${call}`, `${call} ${verb}`);
        return { ...got, body: { timeline: `%${this.#s.cur}`, message } };
    }

    /** `ds/timelines` ([NDBG.14.17.2]). */
    timelines() {
        const s = this.#s;
        return [...s.views.values()].sort((a, b) => a.n - b.n).map((v) => {
            const h = v.hyp;
            if (h === null) return { timeline: `%${v.n}`, current: v.n === s.cur };
            const src = s.at(h.source).tl;
            return { timeline: `%${v.n}`, from: `%${h.source}`, at_ns: Number(src.clockAt(h.forkK) - src.clockAt(0)),
                     change: h.changes[0]?.[1] ?? "", current: v.n === s.cur };
        });
    }

    /**
     * `ds/switchTimeline` ([NDBG.14.17.2]): follow another timeline, at the
     * position it held.
     * @param {unknown} name  `%N`
     * @returns {Moved}
     */
    switchTimeline(name) {
        const n = this.#timeline(name);
        this.#s.cur = n;
        this.#s.rows = [];
        this.#s.stack = [];
        const tl = this.#s.tl;
        return this.#land(this.#s.k, { reason: "goto", focus: this.#firingAt(tl, this.#s.k) }, [], this.#s.k, false);
    }

    /**
     * `ds/dropTimeline` ([NDBG.14.17.2]): a fork and every fork opened from
     * it; never `%0`, nor the timeline the session follows.
     * @param {unknown} name
     */
    async dropTimeline(name) {
        const s = this.#s, n = this.#timeline(name);
        if (n === 0) throw new Refused("%0 is the real run: it cannot be dropped");
        if (n === s.cur) throw new Refused(`%${n} is the timeline the session follows: switch to another first`);
        /** @param {number} m @returns {number[]} m's forks, theirs first */
        const under = (m) => [...s.views.values()].filter((v) => v.hyp !== null && v.hyp.source === m)
            .flatMap((v) => [...under(v.n), v.n]);
        const gone = [...under(n), n];
        if (gone.includes(s.cur)) throw new Refused(`%${s.cur}, which the session follows, was forked from %${n}: switch first`);
        for (const m of gone) {
            const r = await this.#session.execute(`kill %${m}`);
            const e = r.find((x) => x.type === "error");
            if (e !== undefined && e.type === "error") throw new Refused(e.text);
        }
        return gone.map((m) => `%${m}`);
    }

    /**
     * @param {unknown} name  `%N`
     * @returns {number}
     */
    #timeline(name) {
        const m = /^%(\d+)$/.exec(String(name ?? ""));
        if (m === null) throw new Refused(`\`${name}\` is not a timeline: \`%0\`, \`%1\`, …`);
        const n = Number(m[1]);
        if (!this.#s.views.has(n)) throw new Refused(`no timeline %${n}`);
        return n;
    }

    /**
     * `ds/advanceClock` ([NDBG.14.18]): the clock moved and a pump run, at a
     * live run's end.
     * @param {unknown} by  a duration, `5_s`
     * @returns {Promise<Moved>}
     */
    async advance(by) {
        // [NDBG.14.18.1]: a duration, or whole nanoseconds.
        const raw = typeof by === "number" && Number.isSafeInteger(by) && by >= 0 ? `${by}` : typeof by === "string" ? by.trim() : "";
        const d = /^\d+$/.test(raw) ? `${raw}_ns` : raw;
        if (durationNs(d) === null || d.startsWith("-")) throw new Refused("`by` is a duration (`500_ms`, `5_s`) or whole nanoseconds");
        if (!(this.#s.cur === 0 && this.#s.atEngineEnd()))
            throw new Refused("the clock here is the recorded run's: ds/advanceClock moves a live run's clock, at its end");
        const from = this.#s.k;
        const results = await this.#session.execute(`@+${d}`);
        const said = results.flatMap((r) => (r.type === "error" || r.type === "note" ? [r.text] : []));
        if (results.some((r) => r.type === "error")) throw new Refused(said.join("\n"));
        const tl = this.#s.tl;
        await this.#prime(tl);
        const fired = tl.firingsIn(tl.cascade(tl.length).start, tl.length);
        return this.#land(tl.length, { reason: "step", focus: fired[0] ?? null, hits: [] }, said, from);
    }

    /**
     * Stay where the session is, and say why.
     * @param {string} why
     * @returns {Moved}
     */
    #stay(why) {
        return this.#land(this.#s.k, { ...this.#stop, reason: "step" }, [why]);
    }

    /**
     * Point to `k`, as the stop `stop`, with the logpoints' lines
     * ([NDBG.12.1.4]) and the program's own ([NDBG.9.3.6]) for what was
     * crossed moving forward from `from`; `log` false for a jump, which
     * crosses nothing.
     * @param {number} k
     * @param {Stop} stop
     * @param {string[]} [said]
     * @param {number} [from]
     * @param {boolean} [log]
     * @returns {Moved}
     */
    #land(k, stop, said = [], from = this.#s.k, log = true) {
        const tl = this.#s.tl;
        const logs = log ? this.#logs(tl, from, k) : [];
        const stdout = log ? this.#output(tl, from, k) : [];
        const events = log ? this.#events(tl, from, k) : [];
        this.#s.k = k;
        this.#stop = stop;
        this.#refs.clear();
        this.#gotos.clear();
        return { stop, said, logs, stdout, events };
    }

    /**
     * The program's own lines for what the session crosses moving forward from
     * point `from` to `to` ([NDBG.9.3.6]): each firing's `log` lines, each
     * opening with the firing, its instant and the action's level, as the
     * session's engine logged them (core/why.js `logs`). A trace records no
     * atom for a `log` ([RFCS.3.6]), so where among a firing's actions a line
     * was logged is not known: a firing's lines are sent once the move has
     * crossed every action of it, so none goes out before its action does.
     * @param {Timeline} tl
     * @param {number} from
     * @param {number} to
     * @returns {string[]}
     */
    #output(tl, from, to) {
        /** @type {string[]} */
        const out = [];
        if (to <= from) return out;
        tl.firings.forEach((fr, i) => {
            const done = (fr.end ?? fr.effects[fr.effects.length - 1] ?? fr.begin) + 1;
            if (done <= from || done > to) return;
            const head = `!${i + 1} at T=${seconds(tl, fr.begin + 1)}`;
            for (const line of this.#session.logs(fr) ?? []) out.push(`${head}: ${line}`);
        });
        return out;
    }

    /**
     * `ds/streamEvents` and the `events` launch argument ([NDBG.14.20]): the
     * kinds to send from now on, each named with or without `ds/`.
     * @param {unknown} kinds
     */
    setEvents(kinds) {
        if (!Array.isArray(kinds)) throw new Refused("`kinds` is a list of event names: factAsserted, callMade, …");
        const want = kinds.map((k) => String(k).replace(/^ds\//, ""));
        const bad = want.find((k) => !EVENT_KINDS.includes(k));
        if (bad !== undefined) throw new Refused(`no event \`${bad}\`: ${EVENT_KINDS.join(", ")}`);
        this.#events_ = new Set(want);
    }

    /**
     * The stream events the records in `[from, to)` make, of the kinds
     * chosen, moving forward only ([NDBG.15.9]).
     * @param {Timeline} tl
     * @param {number} from
     * @param {number} to
     * @returns {Array<{ event: string, body: Record<string, unknown> }>}
     */
    #events(tl, from, to) {
        const want = this.#events_;
        /** @type {Array<{ event: string, body: Record<string, unknown> }>} */
        const out = [];
        if (!want.size || to <= from) return out;
        for (const r of tl.records.slice(from, to)) {
            const clock_ns = clockNs(tl, r.index + 1);
            if (is(r, "FactAssert", "FactEmit")) {
                const f = tl.facts.get(r.body.fact_id);
                if (f === undefined || f.asserted !== r.index) continue;
                const logical = this.#session.lifecycle(f.schema) === "logical";
                if (want.has("factAsserted"))
                    out.push({ event: "ds/factAsserted", body: { schema: f.schema, fact_id: `#${f.factId}`, slots: wireSlots(f.slots),
                                                                 asserter: this.#asserter(tl, f), clock_ns, logical } });
                if (logical && want.has("logicalFactFlipped"))
                    out.push({ event: "ds/logicalFactFlipped", body: { schema: f.schema, fact_id: `#${f.factId}`, direction: "assert",
                                                                       justifier_count: 1 + f.reemits.filter((i) => i < to).length, clock_ns } });
                const c = tl.calls.find((x) => x.resolved === r.index && (x.outcome === "answered" || x.outcome === "failed"));
                if (c !== undefined && want.has("callAnswered")) {
                    const slots = wireSlots(f.slots);
                    delete slots.corr;
                    out.push({ event: "ds/callAnswered", body: { corr: c.corr, service: c.service, clock_ns,
                        ...(c.outcome === "failed" ? { error: { code: slots.code ?? "", message: slots.message ?? "" } } : { response: slots }) } });
                }
            } else if (is(r, "FactRetract", "FactWithdraw")) {
                const f = tl.facts.get(r.body.fact_id);
                if (f === undefined || f.ended !== r.index) continue;
                const kind = retractor(tl, f);
                if (want.has("factRetracted"))
                    out.push({ event: "ds/factRetracted", body: { schema: f.schema, fact_id: `#${f.factId}`, retractor: { kind }, clock_ns } });
                if (kind === "support_lost" && want.has("logicalFactFlipped"))
                    out.push({ event: "ds/logicalFactFlipped", body: { schema: f.schema, fact_id: `#${f.factId}`, direction: "retract",
                                                                       justifier_count: 0, clock_ns } });
            } else if (is(r, "CallIssued") && want.has("callMade")) {
                const c = tl.calls.find((x) => x.issued === r.index);
                if (c === undefined) continue;
                /** @type {Record<string, unknown>} */
                const kwargs = {};
                for (const a of c.args)
                    kwargs[a.name] = a.type === "Fact" ? { schema: a.value.schema } : wireSlots({ v: a.value }).v;
                const by = this.#by(tl, r.index);
                out.push({ event: "ds/callMade", body: { corr: c.corr, service: c.service, kwargs,
                                                         firing: by === null ? null : `!${tl.firings.indexOf(by) + 1}`, clock_ns } });
            }
        }
        return out;
    }

    /**
     * Who asserted `f` ([NDBG.14.4.2]).
     * @param {Timeline} tl
     * @param {Fact} f
     * @returns {Record<string, unknown>}
     */
    #asserter(tl, f) {
        const by = f.origin === "rule" ? this.#by(tl, f.asserted) : null;
        if (by !== null) return { kind: "rule", rule_name: by.rule, firing: `!${tl.firings.indexOf(by) + 1}`,
                                  clock_ns: clockNs(tl, f.asserted + 1) };
        const reply = tl.calls.some((c) => c.resolved === f.asserted);
        return { kind: reply ? "response" : FAULT_FACTS.has(f.schema) ? "engine" : "input", clock_ns: clockNs(tl, f.asserted + 1) };
    }

    /**
     * Where each step of granularity `g` stops on `tl`, in order.
     * @param {Timeline} tl
     * @param {Granularity} g
     * @returns {number[]}
     */
    #stops(tl, g) {
        if (g === "pump") {
            if (!tl.canonical) return tl.records.map((r) => r.index + 1);
            // The first settled point is before any input, where nothing has
            // happened: a pump step ends where a pump has run.
            const first = tl.records.findIndex((r) => r.kind === "PumpBoundary");
            return [...tl.settled.filter((p) => first >= 0 && p > first), tl.length];
        }
        if (g === "input") return tl.records.filter((r) => INPUT.has(r.kind)).map((r) => r.index + 1);
        /** @type {number[]} */
        const out = [];
        for (const fr of tl.firings) {
            out.push(fr.begin + 1);
            if (g === "action") for (const e of fr.effects) if (e > fr.begin + 1) out.push(e);
        }
        return out;
    }

    /**
     * The nearest stop past `k` (or before it) that a breakpoint or a filter
     * makes, or null.
     * @param {Timeline} tl
     * @param {number} k
     * @param {boolean} forward
     * @param {Array<{ k: number, stop: Stop }>} facts  the fact breakpoints' stops, in order
     * @returns {{ k: number, stop: Stop } | null}
     */
    #nearest(tl, k, forward, facts) {
        /** @type {{ k: number, stop: Stop } | null} */
        let best = null;
        /** @param {number} at @param {() => Stop} make */
        const offer = (at, make) => {
            if (forward ? at <= k : at >= k) return;
            if (best === null || (forward ? at < best.k : at > best.k)) best = { k: at, stop: make() };
        };
        const fact = forward ? facts.find((x) => x.k > k) : [...facts].reverse().find((x) => x.k < k);
        if (fact !== undefined) offer(fact.k, () => fact.stop);
        const firings = forward ? tl.firings : [...tl.firings].reverse();
        for (const fr of firings) {
            const at = fr.begin + 1;
            if (forward ? at <= k : at >= k) continue;
            const hits = this.#hits(tl, fr);
            if (hits.length) {
                offer(at, () => ({ reason: "breakpoint", focus: fr, hits }));
                break;
            }
        }
        const records = forward ? tl.records.slice(k) : tl.records.slice(0, Math.max(0, k - 1)).reverse();
        for (const r of records) {
            const fault = this.#filters.has("fault") && FAULTS.has(r.kind);
            const engine = this.#filters.has("engine_error") && r.kind === "EngineError";
            if (fault || engine) {
                offer(r.index + 1, () => ({ reason: "exception", description: faultText(r),
                                            focus: this.#firingAt(tl, r.index + 1) }));
                break;
            }
        }
        if (this.#filters.has("unanswered_call") && tl.canonical) {
            const points = forward ? [...tl.settled, tl.length] : [...tl.settled].reverse();
            for (const p of points) {
                if (forward ? p <= k : p >= k) continue;
                const start = tl.cascade(p).start;
                const left = tl.waitingCalls(p).filter((c) => c.issued >= start);
                if (left.length) {
                    const c = left[0];
                    offer(p, () => ({ reason: "exception", focus: null,
                                      description: `call ${c.number} ${c.service} is still waiting for its answer` }));
                    break;
                }
            }
        }
        return best;
    }

    // ── what holds at the stop ([NDBG.10], [NDBG.13]) ────────────────────────

    /** The stop the session is at. */
    get stop() {
        return this.#stop;
    }

    /**
     * The firing in progress at point `k`: begun and not yet ended.
     * @param {Timeline} tl
     * @param {number} k
     * @returns {Firing | null}
     */
    #firingAt(tl, k) {
        const i = bisectLeft(tl.firings.map((f) => f.begin), k) - 1;
        const fr = i >= 0 ? tl.firings[i] : undefined;
        return fr !== undefined && (fr.end === null || k <= fr.end) ? fr : null;
    }

    /**
     * The threads at the stop ([NDBG.10.1.1]): the firing in progress and the
     * rest of its pump, or at a settled point the pump just run. The first is
     * focused. With no firing at all, one thread stands for the engine, so
     * its working memory can be looked at.
     * @returns {Array<{ id: number, name: string, firing: Firing | null, focused: boolean, toCome: boolean }>}
     */
    threads() {
        const s = this.#s, tl = s.tl, k = s.k;
        const now = this.#firingAt(tl, k);
        /** @type {Firing[]} */
        let firings;
        /** @type {Firing | null} */
        let focus;
        if (now !== null) {
            const end = tl.nextSettled(k) ?? tl.length;
            firings = [now, ...tl.firings.filter((f) => f.begin >= k && f.begin < end)];
            focus = now;
        } else {
            const c = tl.cascade(k);
            firings = tl.firingsIn(c.start, c.stop);
            focus = this.#stop.focus !== null && firings.includes(this.#stop.focus) ? this.#stop.focus : firings[0] ?? null;
        }
        if (!firings.length)
            return [{ id: ENGINE_THREAD, name: `engine at T=${seconds(tl, k)}`, firing: null, focused: true, toCome: false }];
        return firings.map((fr) => ({
            id: this.threadId(fr), name: this.#threadName(tl, fr) + (now !== null && fr !== now ? " (still to fire in this pump)" : ""),
            firing: fr, focused: fr === focus, toCome: now !== null && fr !== now,
        }));
    }

    /**
     * A firing's thread id: its own for the session ([NDBG.10.1.2]).
     * @param {Firing} fr
     */
    threadId(fr) {
        const s = this.#s;
        const key = `${s.cur}\0${s.tl.firings.indexOf(fr)}`;
        let id = this.#threadIds.get(key);
        if (id === undefined) {
            id = this.#nextThread++;
            this.#threadIds.set(key, id);
        }
        return id;
    }

    /** The focused thread's id, for `stopped`. */
    focusedThread() {
        return this.threads().find((t) => t.focused)?.id ?? ENGINE_THREAD;
    }

    /**
     * A thread's name ([NDBG.10.1.3]): the rule's display-name template filled
     * with the firing's bound values, else the rule and its firing number,
     * written `!N` as [NDBG.9.3.5] writes a firing.
     * @param {Timeline} tl
     * @param {Firing} fr
     */
    #threadName(tl, fr) {
        const fallback = `${fr.rule} !${tl.firings.indexOf(fr) + 1}`;
        const tpl = this.#session.rules()?.get(fr.rule)?.debugNameTemplate;
        if (!tpl) return fallback;
        /** @type {Map<string, bigint>} */
        const by = new Map();
        for (const b of this.#session.bindings(fr) ?? []) if (b.name !== null) by.set(b.name, b.id);
        let whole = true;
        const name = tpl.replace(/\{([A-Za-z_]\w*)\.([A-Za-z_]\w*)\}/g, (all, b, slot) => {
            const id = by.get(b), f = id === undefined ? undefined : tl.facts.get(id);
            const v = f?.slots?.[slot];
            if (f === undefined || v === undefined) {
                whole = false;
                return all;
            }
            return typeof v === "string" ? v : show(v);
        });
        return whole ? name : fallback;
    }

    /**
     * A thread's frames ([NDBG.10.2]): the focused one has the action at the
     * point and the rule; any other, its rule alone, `subtle`.
     * @param {number} threadId
     */
    frames(threadId) {
        const t = this.threads().find((x) => x.id === threadId);
        if (t === undefined) throw new Refused(`no thread ${threadId} at this stop`);
        const tl = this.#s.tl, fr = t.firing;
        if (fr === null) return [{ id: frameId(threadId, 0), name: `engine at T=${seconds(tl, this.#s.k)}`, line: 0, column: 0 }];
        const at = this.#where.get(fr.rule);
        const source = at === undefined ? undefined : { name: basename(at.file), path: at.file };
        const line = at?.line ?? 0;
        const rule = { id: frameId(threadId, t.focused ? 1 : 0), name: t.focused ? `rule ${fr.rule}` : this.#threadName(tl, fr),
                       source, line, column: at === undefined ? 0 : 1,
                       presentationHint: t.focused ? "normal" : "subtle" };
        if (!t.focused) return [rule];
        // A `.dsc` carries a span per terminal, not per action ([RDSC.14.3.6]),
        // so the action's frame points at the rule too.
        const action = { id: frameId(threadId, 0), name: actionName(tl, fr, this.#s.k), source, line,
                         column: at === undefined ? 0 : 1, presentationHint: "normal" };
        return [action, rule];
    }

    /**
     * A frame's scopes ([NDBG.13.1]): the focused thread's top frame has five,
     * any other frame only its Bindings.
     * @param {number} id  a frame id `frames` gave
     */
    scopes(id) {
        const threadId = Math.floor(id / 2), index = id % 2;
        const t = this.threads().find((x) => x.id === threadId);
        if (t === undefined) throw new Refused(`no frame ${id} at this stop`);
        const fr = t.firing;
        const out = [];
        if (fr !== null) out.push(this.#scope("Bindings", () => this.#bindings(fr)));
        if (!t.focused || index !== 0) return out;
        out.push(this.#scope("Working Memory", () => this.#memory()),
                 this.#scope("Agenda", () => this.#agenda()),
                 this.#scope("Cache", () => this.#cache()),
                 this.#scope("Calls", () => this.#calls()));
        return out;
    }

    /**
     * `evaluate` ([NDBG.13.7]): a DS expression, written as a `where` clause
     * writes one, against the bindings of the firing `frameId` names (none on
     * the engine's thread, or with no frame), at the session's point. A
     * `repl` line, which a debug console sends, is answered exactly as a
     * `watch`: an expression and nothing else, so no dsdb command
     * ([NDBG.13.7.1]).
     * Compiled with the rule's patterns, as a breakpoint condition is
     * ([NDBG.12.1.2]), and answered by a query engine of its own
     * (core/query.js `Queries.evaluate`), so no engine of the session moves
     * ([LDEB.7.4.1]). The result is written as `variables` writes a value of
     * its tag ([LNUL.4.9]), a Json value as its tree ([NDBG.13.7.2]); a
     * `Time`, `Date` or `Duration` answers as the `Int` that carries it.
     * @param {any} args
     * @returns {Promise<{ result: string, variablesReference: number }>}
     */
    async evaluate(args) {
        const context = args?.context;
        if (context !== "watch" && context !== "hover" && context !== "repl")
            throw new Refused(`evaluate answers a \`watch\`, a \`hover\` or a \`repl\`, not ${JSON.stringify(context ?? null)}`);
        const expr = typeof args?.expression === "string" ? args.expression.trim() : "";
        if (!expr) throw new Refused("`expression` is a DS expression");
        const s = this.#s, queries = s.view.queries;
        if (queries === null) throw new Refused("evaluate needs the program's source");
        /** @type {Firing | null} */
        let fr = null;
        if (args?.frameId !== undefined) {
            const t = this.threads().find((x) => x.id === Math.floor(Number(args.frameId) / 2));
            if (t === undefined) throw new Refused(`no frame ${args.frameId} at this stop`);
            fr = t.firing;
        }
        const pats = fr === null ? [] : this.#session.patterns(fr.rule);
        if (pats === null || (fr !== null && !pats.length)) throw new Refused("evaluate needs the program's source");
        let got;
        try {
            got = await queries.evaluate(pats, expr, s.k);
        } catch (err) {
            if (!(err instanceof Error) || err.name !== "QueryError") throw err;
            const said = refusalIn(err, expr);
            throw new Refused(fr === null && /DS_VALIDATE_UNKNOWN_BINDING/.test(said)
                ? `${said}\n(the engine's thread binds nothing: pause in a firing to read its bindings)` : said);
        }
        const want = fr === null ? [] : (this.#session.bindings(fr) ?? []).map((b) => b.id);
        const mine = (/** @type {{ bindings: bigint[] }} */ x) => want.every((id, i) => x.bindings[i] === id);
        const fault = got.faults.find(mine);
        if (fault !== undefined)
            throw new Refused(`the expression faulted: a ${fault.kind === "type_error" ? "TypeError" : "ComputationError"}`);
        const a = got.answers.find(mine);
        if (a === undefined)
            throw new Refused(fr === null ? "the expression gave no value here"
                : `the facts ${fr.rule} matched are not all in working memory at this point`);
        // The value arrives as the cache's JSON text ([LDET.3.2.7]), which
        // refuses a non-finite Float.
        if (a.json === null) throw new Refused("the value has no JSON text: a non-finite Float");
        if (a.tag === "Json") {
            const v = this.#json("result", a.json);
            return { result: v.value, variablesReference: v.variablesReference };
        }
        // A String's JSON text is the quoted form `variables` writes; the
        // other scalars' are their text.
        return { result: a.json, variablesReference: 0 };
    }

    /**
     * A variable reference's children ([NDBG.13.1.3]: on demand).
     * @param {number} ref
     * @param {number} [start]
     * @param {number} [count]
     */
    variables(ref, start, count) {
        const make = this.#refs.get(ref);
        if (make === undefined) throw new Refused(`variable reference ${ref} is not valid at this stop`);
        const all = make();
        if (start === undefined && count === undefined) return all;
        const from = start ?? 0;
        return all.slice(from, count ? from + count : undefined);
    }

    /**
     * @param {string} name
     * @param {() => Variable[]} make
     */
    #scope(name, make) {
        return { name, variablesReference: this.#ref(make), expensive: false };
    }

    /** @param {() => Variable[]} make */
    #ref(make) {
        const id = this.#refs.size + 1;
        this.#refs.set(id, make);
        return id;
    }

    /**
     * @param {Firing} fr
     * @returns {Variable[]}
     */
    #bindings(fr) {
        const got = this.#session.bindings(fr);
        if (got === null) return [leaf("(unknown)", "this trace does not record which facts the firing matched")];
        const tl = this.#s.tl;
        return got.map((b, i) => {
            const f = tl.facts.get(b.id);
            const name = b.name ?? `[${i}]`;
            return f === undefined ? leaf(name, `#${b.id} (not in this timeline)`) : this.#fact(name, f);
        });
    }

    /** @returns {Variable[]} */
    #memory() {
        const s = this.#s, tl = s.tl, k = s.k;
        return [...tl.population(k)].filter(([, n]) => n > 0).map(([schema, n]) => {
            const facts = () => tl.liveFacts(k).filter((f) => f.schema === schema).map((f) => this.#fact(`#${f.factId}`, f));
            return { name: schema, value: `${schema} (${n} fact${n === 1 ? "" : "s"})`, variablesReference: this.#ref(facts),
                     ...(n > PAGE ? { indexedVariables: n } : {}) };
        });
    }

    /** @returns {Variable[]} in replay, the firings still to come in this pump ([NDBG.13.6.1]) */
    #agenda() {
        const s = this.#s, tl = s.tl, k = s.k;
        if (this.#firingAt(tl, k) === null) return [];
        const end = tl.nextSettled(k) ?? tl.length;
        // The terminal ordinal is the rule's place in the program's order
        // ([LDET.5.4]), as the `.dsc` lists its rules.
        const order = [...(this.#session.rules()?.keys() ?? [])];
        return tl.firings.filter((f) => f.begin >= k && f.begin < end).map((f) => {
            const ord = order.indexOf(f.rule);
            return leaf(`!${tl.firings.indexOf(f) + 1}`, `${this.#threadName(tl, f)}${ord < 0 ? "" : ` (terminal ${ord})`}`);
        });
    }

    /**
     * What `ds/loadRecording` answers ([NDBG.14.2.1]), of the session as
     * opened on the trace.
     */
    recording() {
        const s = this.#s, tl = s.tl;
        return { duration_ns: Number(tl.clockAt(tl.length) - tl.clockAt(0)), event_count: tl.length,
                 rule_count: this.#session.rules()?.size ?? new Set(tl.firings.map((f) => f.rule)).size,
                 schema_count: s.view.queries?.prog.schemas.size ?? tl.schemas().length };
    }

    /**
     * The cache at the point ([NDBG.13.1.1]): each key, its value and its TTL,
     * from what the engine wrote and removed before it.
     * @returns {Variable[]}
     */
    #cache() {
        const s = this.#s, tl = s.tl, k = s.k;
        const rec = this.#session.engineRecord();
        if (rec === null) return [leaf("(unknown)", "the cache needs the program")];
        /** @type {Map<string, { value: string | null, ttlNs: bigint, at: number }>} */
        const held = new Map();
        for (const op of rec.ops) {
            if (op.at >= k) break;
            if (op.op === "set") held.set(op.key, { value: op.value, ttlNs: op.ttlNs, at: op.at });
            else if (op.op === "delete") held.delete(op.key);
        }
        const now = tl.clockAt(k);
        return [...held].map(([key, e]) => {
            const ends = e.ttlNs > 0n ? tl.clockAt(e.at + 1) + e.ttlNs : null;
            const ttl = ends === null ? "no TTL" : `TTL ${(Number(ends - now) / 1e9).toFixed(3)}s left`;
            return leaf(key, `${e.value ?? "null"} (${ttl})`);
        });
    }

    /** @returns {Variable[]} the calls waiting, then those answered in this pump ([NDBG.13.1.1]) */
    #calls() {
        const s = this.#s, tl = s.tl, k = s.k;
        const start = tl.cascade(k).start;
        const waiting = tl.waitingCalls(k).map((c) => this.#call(c, "waiting"));
        const settled = tl.calls.filter((c) => c.resolved !== null && c.resolved >= start && c.resolved < k)
            .map((c) => this.#call(c, c.outcome));
        return [...waiting, ...settled];
    }

    /**
     * @param {Call} c
     * @param {string} state
     * @returns {Variable}
     */
    #call(c, state) {
        const args = () => c.args.map((a) => leaf(a.name, show(a.value)));
        return { name: `call ${c.number}`, value: `${c.service}${c.corr === null ? "" : ` as ${JSON.stringify(c.corr)}`}: ${state}`,
                 variablesReference: c.args.length ? this.#ref(args) : 0 };
    }

    /**
     * A fact as a variable ([NDBG.13.2]): its slots, and `_id`.
     * @param {string} name
     * @param {Fact} f
     * @returns {Variable}
     */
    #fact(name, f) {
        const sc = this.#s.view.queries?.prog.schemas.get(f.schema);
        /** @param {string} slot */
        const isJson = (slot) => sc?.slots.find((x) => x.name === slot)?.kind === "JSON";
        const kids = () => [...Object.entries(f.slots ?? {}).map(([slot, v]) => (isJson(slot) ? this.#json(slot, v) : leaf(slot, show(v)))),
                            leaf("_id", `#${f.factId}`),
                            ...(this.#session.lifecycle(f.schema) === "logical" ? [this.#justifiersVar(f)] : [])];
        return { name, value: `${f.schema} #${f.factId}`, variablesReference: this.#ref(kids) };
    }

    /**
     * A `Json` slot as a tree ([NDBG.13.5]): an object's keys and an array's
     * indices are children, each level built when the client expands it, to
     * the value's full depth ([NDBG.13.5.2]: no cap; [LGRA.5.8.6] bounds it).
     * @param {string} name
     * @param {unknown} v  the slot's value: its canonical JSON text
     * @param {boolean} [parsed]  `v` is a value inside the document, not its text
     * @returns {Variable}
     */
    #json(name, v, parsed = false) {
        /** @type {unknown} */
        let doc = v;
        if (!parsed) {
            if (v === null || v === undefined) return leaf(name, "null");
            try {
                doc = JSON.parse(String(v));
            } catch {
                return leaf(name, show(v));
            }
        }
        if (doc === null || typeof doc !== "object") return leaf(name, JSON.stringify(doc));
        const entries = Array.isArray(doc) ? doc.map((x, i) => [`[${i}]`, x]) : Object.entries(doc);
        const value = Array.isArray(doc) ? `[${doc.length}]` : `{${entries.length}}`;
        return { name, value, variablesReference: this.#ref(() => entries.map(([kk, x]) => this.#json(String(kk), x, true))) };
    }

    /**
     * A logical fact's `_justifiers` child ([NDBG.13.4]): one per active
     * justifier, as the engine at the point reports them.
     * @param {Fact} f
     * @returns {Variable}
     */
    #justifiersVar(f) {
        /** @type {Array<Record<string, unknown>>} */
        let got;
        try {
            got = this.justifiers({ fact_id: `#${f.factId}` }).justifiers;
        } catch (err) {
            if (!(err instanceof Refused)) throw err;
            return leaf("_justifiers", `(${err.message})`);
        }
        const kids = () => got.map((j, i) => leaf(`[${i}]`, `${j.display_name} at T=${(Number(j.clock_ns ?? 0) / 1e9).toFixed(3)}s`));
        return { name: "_justifiers", value: `(${got.length} active)`, variablesReference: got.length ? this.#ref(kids) : 0 };
    }

    /**
     * A `.dsc`'s file name as a path on this machine: the `.ds` the launch
     * named with that name, else the name itself.
     * @param {string} file
     */
    #path(file) {
        const named = this.#given.find((p) => basename(p) === basename(file));
        if (named !== undefined) return named;
        return isAbsolute(file) ? file : resolve(file);
    }
}

/**
 * A rule's declaration in its source, from the `.dsc`, or null when the
 * artefact carries none.
 * @param {RuleMeta} m
 * @returns {{ file: string, line: number } | null}
 */
export function place(m) {
    return m.srcFile && m.srcLine ? { file: m.srcFile, line: Number(m.srcLine) } : null;
}

/**
 * A DAP hit condition ([NDBG.12.1.3]): `5` is the fifth hit, `>= 3` the third
 * on, and `> N`, `== N`, `% N` as they read. null for one that is not.
 * @param {string} text
 * @returns {((n: number) => boolean) | null}
 */
export function hitTest(text) {
    const m = /^\s*(>=|<=|==|>|<|%)?\s*(\d+)\s*$/.exec(text);
    if (m === null) return null;
    const v = Number(m[2]);
    switch (m[1]) {
    case ">=": return (n) => n >= v;
    case "<=": return (n) => n <= v;
    case ">": return (n) => n > v;
    case "<": return (n) => n < v;
    case "%": return v === 0 ? null : (n) => n % v === 0;
    default: return (n) => n === v;
    }
}

/**
 * The action at point `k` of firing `fr`: the record about to apply, as the
 * source writes it (`emit Alert`).
 * @param {Timeline} tl
 * @param {Firing} fr
 * @param {number} k
 */
function actionName(tl, fr, k) {
    const e = fr.effects.find((i) => i >= k) ?? fr.effects[0];
    const r = e === undefined ? undefined : tl.records[e];
    if (r === undefined) return `${fr.rule}: no action`;
    if (is(r, "FactEmit")) return `emit ${r.body.schema_name}`;
    if (is(r, "FactPublish")) return `publish ${r.body.schema_name}`;
    if (is(r, "FactWithdraw")) return `withdraw #${r.body.fact_id}`;
    if (is(r, "CallIssued")) return `call ${r.body.service}`;
    return r.kind;
}

/**
 * A fault or engine-error record, said ([NDBG.12.6.1]).
 * @param {TraceRecord} r
 */
function faultText(r) {
    if (is(r, "ComputationError")) return `a computation error in ${r.body.rule_name || "a rule"}`;
    if (is(r, "TypeError")) return `a type error${r.body.schema_name ? ` on ${r.body.schema_name}.${r.body.slot_name}` : ""}`;
    if (is(r, "BoundsError")) return `a bounds error${r.body.rule_name ? ` in ${r.body.rule_name}` : ""}`;
    if (is(r, "EngineError")) return `an engine error (fault ${r.body.engine_fault})`;
    return r.kind;
}

/**
 * A rule's patterns as a query that a firing of it meets when `cond` held of
 * its bindings ([NDBG.12.1.2]): the condition added to the last positive
 * pattern's `where`, and `exprs` projected, for a logpoint's message.
 * @param {string[]} pats
 * @param {string | null} cond
 * @param {string[]} exprs
 */
export function ruleQuery(pats, cond, exprs) {
    const lines = [...pats];
    if (cond !== null) {
        let i = lines.length - 1;
        while (i > 0 && /^no\b/.test(lines[i])) i--;
        const [head, where] = splitPattern(lines[i]);
        lines[i] = where ? `${head} where (${where}) and (${cond})` : `${lines[i]} where ${cond}`;
    }
    if (exprs.length) lines.push(`-> ${exprs.join(", ")}`);
    return lines.join("\n");
}

/**
 * A logpoint's message ([NDBG.12.1.4]), a DS interpolation string: its text
 * cut at each `{…}`, literal and expression in turn, and the expressions.
 * @param {string} msg
 * @returns {{ parts: string[], exprs: string[], error?: undefined } | { error: string }}
 */
export function interpolation(msg) {
    /** @type {string[]} */
    const parts = [];
    /** @type {string[]} */
    const exprs = [];
    let cur = "";
    for (let i = 0; i < msg.length; i++) {
        const c = msg[i];
        if (c === "{") {
            const end = msg.indexOf("}", i);
            if (end < 0) return { error: `the logpoint's \`{\` at ${i + 1} is not closed` };
            const e = msg.slice(i + 1, end).trim();
            if (!e) return { error: `the logpoint's \`{}\` at ${i + 1} holds no expression` };
            parts.push(cur, e);
            exprs.push(e);
            cur = "";
            i = end;
        } else cur += c;
    }
    parts.push(cur);
    return { parts, exprs };
}

/**
 * A diff row without its sort key.
 * @param {{ at: bigint } & Record<string, unknown>} r
 */
function strip(r) {
    const { at: _, ...rest } = r;
    return rest;
}

/** The engine's own facts: the fault facts it asserts ([LERR.9]). */
const FAULT_FACTS = new Set(["ComputationError", "TypeError"]);

/**
 * Point `k`'s clock in ns from the timeline's first record.
 * @param {Timeline} tl
 * @param {number} k
 */
const clockNs = (tl, k) => Number(tl.clockAt(k) - tl.clockAt(0));

/**
 * A fact's slots as JSON: an Int as a number where it is safe, else as text.
 * @param {Record<string, unknown> | null} slots
 * @returns {Record<string, unknown>}
 */
function wireSlots(slots) {
    /** @type {Record<string, unknown>} */
    const out = {};
    for (const [k, v] of Object.entries(slots ?? {})) {
        if (typeof v === "bigint") out[k] = v >= BigInt(Number.MIN_SAFE_INTEGER) && v <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(v) : v.toString();
        else if (v instanceof Uint8Array) out[k] = show(v);
        else if (v === null || ["string", "number", "boolean"].includes(typeof v)) out[k] = v;
        else out[k] = String(v);
    }
    return out;
}

/**
 * A fact id as the protocol writes it ([NDBG.9.3.5]): `#42`, or 42.
 * @param {unknown} v
 * @returns {bigint}
 */
function factId(v) {
    const m = /^#?(\d+)$/.exec(String(v ?? "").trim());
    if (m === null) throw new Refused(`\`${v}\` is not a fact id: \`#42\``);
    return BigInt(m[1]);
}


/**
 * A fact breakpoint's condition as a query: the fact bound to its schema's
 * name lowercased ([NDBG.12.3.2]).
 * @param {string} schema
 * @param {string} where
 */
const factQuery = (schema, where) => `${schema} ${schema.toLowerCase()} where ${where}`;

/**
 * How a fact left working memory, as [NDBG.14.4.2]'s retractor kinds: an
 * integrator's retract is `input`; a withdrawal is named by its cause
 * (fact_withdraw.proto).
 * @param {Timeline} tl
 * @param {Fact} f
 */
function retractor(tl, f) {
    if (f.endKind === "retract") return "input";
    const c = f.cause ?? "";
    if (c.includes("TTL_EXPIRED")) return "ttl_expiry";
    if (c.includes("JUSTIFIER_ENDED")) return "support_lost";
    if (c.includes("ADAPTER_DISCONNECTED")) return "input";
    const r = f.ended === null ? undefined : tl.records[f.ended];
    return r !== undefined && r.cls === "derived" ? "rule" : "input";
}

/**
 * @param {number} threadId
 * @param {number} index  0 or 1
 */
const frameId = (threadId, index) => threadId * 2 + index;

/**
 * A variable with no children.
 * @param {string} name
 * @param {string} value
 * @returns {Variable}
 */
const leaf = (name, value) => ({ name, value, variablesReference: 0 });

/**
 * A slot value as text.
 * @param {unknown} v
 * @returns {string}
 */
export function show(v) {
    if (v === null || v === undefined) return "null";
    if (typeof v === "string") return JSON.stringify(v);
    if (typeof v === "bigint" || typeof v === "number" || typeof v === "boolean") return String(v);
    if (v instanceof Uint8Array) return `b"${[...v].map((b) => b.toString(16).padStart(2, "0")).join("")}"`;
    return String(v);
}

/**
 * Point `k`'s clock, in seconds from the timeline's first record.
 * @param {Timeline} tl
 * @param {number} k
 */
export function seconds(tl, k) {
    const ns = tl.clockAt(k) - tl.clockAt(0);
    return `${(Number(ns) / 1e9).toFixed(3)}s`;
}
