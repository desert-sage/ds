// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// dsdb's API (dsdb/DSDB_WEB.md §3): the operations a front end drives,
// typed, over one session, the shell's commands underneath. An operation runs
// the command the shell would for it and returns the session's results: as
// the objects themselves, as JSON (json.js) and as the shell's text. One with
// rows, or a tree, is bounded after it runs (bound.js, DSDB_MCP.md §10.1).
// Built for MCP (DSDB_MCP.md §4), whose tools these are, and shared by every
// transport. Nothing from Node: how a session is opened is the host's
// (`load`), which reads files natively and takes bytes in a page.
//
// LOOKING NEVER MOVES POINT (DSDB_MCP.md §3). A read operation's `at` is
// answered by standing the current timeline at that point for the one
// command, then putting point back. Only `move` moves it.

import { ReplyError, callWire, parseReply } from "../core/calls.js";
import { durationNs, position } from "../core/grammar.js";
import { resultLines } from "../text/session.js";
import { LIMIT, NODES, bound, capTrees } from "./bound.js";
import { outputSchema, project } from "./json.js";

/** @import { CallsPort } from "../core/batch.js" */
/** @import { Session } from "../core/session.js" */
/** @import { Progress, Row } from "../core/state.js" */
/** @import { Call, Fact, Firing, Timeline } from "../core/timeline.js" */
/** @import { Result } from "../core/types.js" */
/** @import { Json, Schema } from "./json.js" */

/**
 * An operation's arguments as the caller sent them: JSON, read by the steps
 * below, which check each one.
 * @typedef {Record<string, unknown>} Args
 */

/**
 * An operation: its name, what it does, its input schema, whether its results
 * are bounded (by rows, or as a tree), and how it runs.
 * @typedef {{ name: string, description: string, inputSchema: Schema, bound?: "rows" | "tree",
 *     run: (t: Api, a: Args) => Promise<Result[]> | Result[] }} Op
 */

/**
 * Where a load's messages go. `unbound`, where given, hears why a trace and
 * its program were refused as not belonging together ([RFCS.4.5]), before
 * the load returns its exit status.
 * @typedef {{ out: (line: string) => void, err: (line: string) => void,
 *     unbound?: (u: import("../core/binding.js").Unbound) => void }} Say
 */

/** @typedef {{ session: Session, close: () => void }} Opened  a session, and how to let it go */

/**
 * An operation's outcome: `results` as JSON, the shell's `text`, `isError`
 * when it was refused, and `raw`, the result objects themselves.
 * @typedef {{ results: Json[], text: string, isError: boolean, raw: Result[] }} Outcome
 */

/** @typedef {(progress: number, total: number, message: string) => void} OnProgress */

/** @typedef {ReturnType<typeof parseReply>} Reply  a reply on the calls socket, read */

/** An operation refused before it ran: the caller's to correct. */
export class OpError extends Error {}

const REFUSALS = new Set(["error", "midCascade", "pastEnd"]);

const POINT = {
    type: "string",
    description: "a point: a hex position as listings print it (`1aba`, `1aba-`), `start`, `end`, or a clock "
        + "from the first record with its underscore (`12_s`, `500_ms`); default: point",
};
const FROM = {
    type: "string",
    description: "where the change is made: `here` (point, the default), `start`, `end`, or a point as "
        + "listings print it (`1def`, `1def-`, `12_s`); point moves there first",
};
/** @param {string} what */
const REGEX = (what) => ({ type: "string", description: `a regular expression over ${what}` });
// §10.1: a tool with rows takes these, and `bound` says so.
const ROWS = {
    limit: { type: "integer", minimum: 1, description: `at most this many rows (default ${LIMIT}); past it, the result ends `
        + "with how many more there are and a cursor for them" },
    cursor: { type: "string", description: "a cursor a result gave, for the rows after it; the other arguments as before" },
};

/**
 * The operations: name, description, input schema, and how each runs.
 * `load` is not here: the host gives it (`Api`'s constructor).
 * @type {Op[]}
 */
export const OPS = [
    {
        name: "where",
        description: "Where point is on the current timeline: position, clock, and whether it is settled.",
        inputSchema: { type: "object", properties: {} },
        run: (t) => t.exec("@"),
    },
    {
        name: "move",
        description: "Move point, the one tool that does. Give `to` (a point), `by` (a count of records such as "
            + "`+10`, or a duration such as `-2_s`), or `step` (`next` or `prev`, by `unit`). At the end of a live "
            + "session, moving by a duration advances the clock and `step` pumps.",
        inputSchema: { type: "object", properties: {
            to: POINT,
            by: { type: "string", description: "`+10`, `-3`, `+500_ms`, `-2_s`" },
            step: { type: "string", enum: ["next", "prev"] },
            unit: { type: "string", enum: ["settled", "record", "firing", "tick"], description: "default: settled" },
        } },
        run: (t, a) => t.move(a),
    },
    {
        name: "population",
        description: "Live facts per schema at a point, with the change since the settled point before it; or, "
            + "with `over_time`, each schema's population over the whole timeline.",
        inputSchema: { type: "object", properties: { schema: REGEX("schema names"), at: POINT, over_time: { type: "boolean" } } },
        run: (t, a) => t.at(a.at, () => t.exec(`#${a.over_time ? ":" : "."}${t.filter(a.schema)}`)),
    },
    {
        name: "facts",
        description: "The live facts of one schema at a point, each bound to `f`; `where` narrows them with a DS "
            + "condition over `f`, such as `f.level > 80.0`.",
        inputSchema: { type: "object", required: ["schema"], properties: {
            schema: { type: "string" }, where: { type: "string" }, at: POINT, ...ROWS } },
        bound: "rows",
        run: (t, a) => t.at(a.at, () => t.exec(`?.${t.word(a.schema)} f${a.where ? ` where ${a.where}` : ""}`)),
    },
    {
        name: "query",
        description: "Answers to a query, a rule's left-hand side such as `Reading r where r.level > 80.0`, with "
            + "`-> a, b` for values: at a point, or with `over_time` every answer that held and when; with `count`, "
            + "how many.",
        inputSchema: { type: "object", required: ["body"], properties: {
            body: { type: "string", description: "one pattern per line for a join; a last line `-> a, b` projects" },
            at: POINT, over_time: { type: "boolean" }, count: { type: "boolean" }, ...ROWS } },
        bound: "rows",
        run: (t, a) => t.at(a.at, () => t.exec(`${a.count ? "#" : "?"}${a.over_time ? ":" : "."}${t.body(a.body)}`)),
    },
    {
        name: "fact",
        description: "One fact: its slots, lifecycle, where it began and ended, and its versions.",
        inputSchema: { type: "object", required: ["id"], properties: { id: { type: ["string", "integer"] } } },
        run: (t, a) => t.show(["fact", t.fact(a.id)]),
    },
    {
        name: "firings",
        description: "Rule firings: in the cascade that led to a point, or with `scope: all` every one; with "
            + "`count`, how many per rule.",
        inputSchema: { type: "object", properties: {
            scope: { type: "string", enum: ["cascade", "all"] }, rule: REGEX("rule names"), at: POINT,
            count: { type: "boolean" }, ...ROWS } },
        bound: "rows",
        run: (t, a) => t.at(a.at, () => t.exec(`${a.count ? "^" : "!"}${a.scope === "all" ? ":" : "."}${t.filter(a.rule)}`)),
    },
    {
        name: "firing",
        description: "One firing, by rule and timetag: its matched facts and its effects.",
        inputSchema: { type: "object", required: ["rule", "timetag"], properties: {
            rule: { type: "string" }, timetag: { type: ["string", "integer"], description: "as listings print it, `0x4f1`" } } },
        run: (t, a) => t.show(["firing", t.firing(a.rule, a.timetag)]),
    },
    {
        name: "calls",
        description: "Service calls waiting at a point, or with `all` every call and its outcome.",
        inputSchema: { type: "object", properties: { all: { type: "boolean" }, at: POINT, ...ROWS } },
        bound: "rows",
        run: (t, a) => t.at(a.at, () => t.exec(a.all ? "calls all" : "calls")),
    },
    {
        name: "why",
        description: "The derivation tree at a point: of a fact (`fact`), or of a firing (`rule` and `timetag`), "
            + "down to the inputs. `depth` stops after that many firing levels, `nodes` after that many numbered "
            + `nodes (default ${NODES}); a fact or firing marked … has more below it, and \`why\` on it goes on.`,
        inputSchema: { type: "object", properties: {
            fact: { type: ["string", "integer"] }, rule: { type: "string" }, timetag: { type: ["string", "integer"] },
            depth: { type: "integer", minimum: 1 }, nodes: { type: "integer", minimum: 1 }, at: POINT } },
        bound: "tree",
        run: (t, a) => t.why(a),
    },
    {
        name: "rete",
        description: "The matching network at a point: each rule's chain with the facts, tokens and activations "
            + "each node holds and their change since the settled point before; or `view: schemas`, alpha-first.",
        inputSchema: { type: "object", properties: {
            rule: REGEX("rule names"), view: { type: "string", enum: ["rules", "schemas"] }, at: POINT, ...ROWS } },
        bound: "rows",
        run: (t, a) => t.at(a.at, () => t.exec(a.view === "schemas" ? "rete schemas" : `rete${t.filter(a.rule)}`)),
    },
    {
        name: "whynot",
        description: "Why a rule has not fired, or not again, at a point: its chain of patterns, the live facts each "
            + "pattern's test passes (and those it turns away, with the test that failed), the tokens each join "
            + "holds, and where the match stops. When every pattern matches, how often it fired and what keeps it "
            + "from firing again. Which join test rejected which pair needs libds's node contents, which this build does not have.",
        inputSchema: { type: "object", required: ["rule"], properties: { rule: { type: "string" }, at: POINT } },
        run: (t, a) => t.at(a.at, () => t.exec(`whynot ${t.word(a.rule)}`)),
    },
    {
        name: "match",
        description: "A fact through the network's alpha tests, on the engine holding it at a point.",
        inputSchema: { type: "object", required: ["fact"], properties: { fact: { type: ["string", "integer"] }, at: POINT } },
        run: (t, a) => t.at(a.at, async () => {
            t.show(["fact", t.fact(a.fact)]);
            return t.exec("match");
        }),
    },
    {
        name: "listing",
        description: "The plain record listing, `around` records either side of a point (default 10).",
        inputSchema: { type: "object", properties: { around: { type: "integer", minimum: 0 }, at: POINT, ...ROWS } },
        bound: "rows",
        run: (t, a) => t.at(a.at, () => t.exec(`list ${a.around ?? 10}`)),
    },
    {
        name: "timelines",
        description: "Every timeline: %0, reality, and each hypothesis with its fork, point, changes and memory.",
        inputSchema: { type: "object", properties: {} },
        run: (t) => t.exec("hyp"),
    },
    {
        name: "switch",
        description: "Make timeline N current.",
        inputSchema: { type: "object", required: ["timeline"], properties: { timeline: { type: "integer", minimum: 0 } } },
        run: (t, a) => t.exec(`fg %${a.timeline}`),
    },
    {
        name: "fork",
        description: "A new hypothesis, forked from the current timeline at point, and made current.",
        inputSchema: { type: "object", properties: {} },
        run: (t) => t.exec("fork"),
    },
    {
        name: "kill",
        description: "Close hypothesis N.",
        inputSchema: { type: "object", required: ["timeline"], properties: { timeline: { type: "integer", minimum: 1 } } },
        run: (t, a) => t.exec(`kill %${a.timeline}`),
    },
    {
        name: "save_trace",
        description: "Write a timeline's record as a trace file: the current one, or `timeline`.",
        inputSchema: { type: "object", required: ["path"], properties: {
            path: { type: "string" }, timeline: { type: "integer", minimum: 0 } } },
        run: (t, a) => t.exec(`save trace ${a.timeline === undefined ? "" : `%${a.timeline} `}${t.path(a.path)}`),
    },

    // ── from here: changes to the current timeline's inputs at point (§4.16) ──
    {
        name: "from_here_emit",
        description: "Assert an input at point and run to quiescence: at a live session's end it applies to the "
            + "session; anywhere else it opens or extends a hypothesis. `text` is the fact as DS writes it after "
            + "`emit`: `Reading entity_id: \"a\" level: 85.0`.",
        inputSchema: { type: "object", required: ["text"], properties: { text: { type: "string" }, from: FROM } },
        run: (t, a) => t.exec(`${t.from(a.from)} emit ${t.oneLine(a.text)}`),
    },
    {
        name: "from_here_withdraw",
        description: "Retract a live fact at point, as the integrator would. From a point before the fact was "
            + "asserted (`from: start`, say), its input never happens instead.",
        inputSchema: { type: "object", required: ["fact"], properties: { fact: { type: ["string", "integer"] }, from: FROM } },
        run: (t, a) => t.exec(`${t.from(a.from)} withdraw #${t.id(a.fact)}`),
    },
    {
        name: "from_here_answer",
        description: "Reply to call N with its response, a fact of the service's response schema: a waiting call "
            + "is answered; an answered one has its reply replaced in a hypothesis forked just before it. "
            + "`response` holds the schema's slots by name, typed as fact files type them; the call's `corr` is "
            + "given for you. A call to a `no response` service cannot be answered, only failed.",
        inputSchema: { type: "object", required: ["call"], properties: {
            call: { type: "integer", minimum: 1 },
            response: { type: "object", description: "the response schema's slots, `corr` aside; default {}" }, from: FROM } },
        run: (t, a) => t.exec(`${t.from(a.from)} answer ${a.call} ${JSON.stringify(a.response ?? {})}`),
    },
    {
        name: "from_here_fail",
        description: "Fail call N with a code and a message, as a CallError.",
        inputSchema: { type: "object", required: ["call"], properties: {
            call: { type: "integer", minimum: 1 }, code: { type: "string" }, message: { type: "string" }, from: FROM } },
        run: (t, a) => t.exec(`${t.from(a.from)} fail ${a.call} code: ${t.quoted(a.code ?? "")} message: ${t.quoted(a.message ?? "")}`),
    },
    {
        name: "from_here_silence",
        description: "Suppress an answered call's recorded reply, in a hypothesis forked just before it.",
        inputSchema: { type: "object", required: ["call"], properties: { call: { type: "integer", minimum: 1 }, from: FROM } },
        run: (t, a) => t.exec(`${t.from(a.from)} silence ${a.call}`),
    },

    // ── the program, edited for all time (§4.16) ───────────────────────────
    {
        name: "define",
        description: "Add a DS definition to the program, or replace the one of its kind and name: a schema, a "
            + "rule, a service, a series, a const, a unit, an import, `use`. One definition per call. The program "
            + "is compiled (nothing changes if it does not compile), every timeline runs again under it, and the "
            + "result says what that did to the current timeline at point. A new rule goes last in the rule order; "
            + "a replaced one keeps its place.",
        inputSchema: { type: "object", required: ["text"], properties: { text: { type: "string" } } },
        run: (t, a) => t.define(a.text),
    },
    {
        name: "del",
        description: "Remove a definition by name; `kind` where a schema and a rule share the name. `use` and "
            + "`import MODULE` are names too. Every timeline runs again.",
        inputSchema: { type: "object", required: ["name"], properties: {
            name: { type: "string" }, kind: { type: "string", enum: ["use", "import", "const", "unit", "schema",
                                                                      "service", "series", "rule", "test"] } } },
        run: (t, a) => t.exec(`del ${a.kind ? `${a.kind} ` : ""}${t.word(a.name)}`),
    },
    {
        name: "mv",
        description: "Move a rule in the rule order, which is firing order: `to` a position from 1, or `before` or "
            + "`after` another rule. Every timeline runs again.",
        inputSchema: { type: "object", required: ["rule"], properties: {
            rule: { type: "string" }, to: { type: "integer", minimum: 1 }, before: { type: "string" }, after: { type: "string" } } },
        run: (t, a) => t.exec(`mv ${t.word(a.rule)} ${a.to ?? (a.before ? `before ${t.word(a.before)}` : a.after ? `after ${t.word(a.after)}` : "")}`),
    },
    {
        name: "ls",
        description: "The program's definitions by kind; `kind: rules` for the rule order, each rule's first "
            + "pattern and how often it fired up to point.",
        inputSchema: { type: "object", properties: { kind: { type: "string", enum: ["rules", "schemas", "services",
                                                                                      "series", "consts", "units",
                                                                                      "imports", "tests"] }, ...ROWS } },
        bound: "rows",
        run: (t, a) => t.exec(a.kind ? `ls ${a.kind}` : "ls"),
    },
    {
        name: "source",
        description: "One definition's text, by kind and name: `rule hot`, `schema Reading`.",
        inputSchema: { type: "object", required: ["kind", "name"], properties: { kind: { type: "string" }, name: { type: "string" } } },
        run: (t, a) => t.exec(`show ${t.word(a.kind)} ${t.word(a.name)}`),
    },
    {
        name: "save_code",
        description: "Write the program as it now stands to one file, in DS's order with rules in the rule order: a "
            + "record of the work that `load` reads again.",
        inputSchema: { type: "object", required: ["path"], properties: { path: { type: "string" } } },
        run: (t, a) => t.exec(`save code ${t.path(a.path)}`),
    },
    {
        name: "changes",
        description: "The current timeline's changes at a point, in the order they were made, each where it was made.",
        inputSchema: { type: "object", properties: {} },
        run: (t) => t.exec("changes"),
    },
    {
        name: "advance",
        description: "Let time pass by a duration (`5_s`): at a live session's end, moves its clock and pumps; at a "
            + "hypothesis's end, feeds it reality's inputs up to then.",
        inputSchema: { type: "object", required: ["by"], properties: { by: { type: "string", description: "`500_ms`, `5_s`" } } },
        run: (t, a) => t.exec(`@+${t.duration(a.by)}`),
    },
];


/**
 * @param {string} text
 * @returns {Result}
 */
const note = (text) => ({ type: "note", text });

/**
 * A call, the same across an edit's rebuild: a live `%0` issues its calls
 * again in the same order.
 * @param {Call} c
 */
const callKey = (c) => `${c.number}\0${c.service}\0${c.corr}`;

/** The result types each tool gives, for its outputSchema (§10.7). Every tool
    may also give these; a bounded one, `more` too. */
const ANY_OP =["note", "error", "midCascade", "pastEnd", "refresh", "logs"];
const CHANGE = ["forked", "discarded", "recomputed", "newRecords", "replyEmit", "where", "issued"];
const EDIT = ["edited", "editDiff"];
/** @type {Record<string, string[]>} */
const RETURNS = {
    load: ["banner"], where: ["where"], move: ["where", "newRecords", "issued", "noSeq"],
    population: ["bars", "histogram"], facts: ["answers"], query: ["answers", "answersOverTime", "answerCount"],
    fact: ["factView"], firings: ["firings", "bars"], firing: ["firingView"], calls: ["calls"], why: ["why"],
    whynot: ["whynot"], rete: ["rete", "reteSchemas"], match: ["matchTrace"], listing: ["listing"],
    timelines: ["timelines"], switch: ["where"], fork: ["forked"], kill: [], save_trace: [],
    from_here_emit: CHANGE, from_here_withdraw: CHANGE, from_here_answer: CHANGE, from_here_fail: CHANGE,
    from_here_silence: CHANGE, define: EDIT, del: EDIT, mv: EDIT,
    ls: ["programList", "definitionList", "ruleList"], source: [], save_code: ["savedCode"],
    changes: ["changeList"], advance: ["newRecords", "where", "issued"],
};

/**
 * Core's progress hook `(done, total, what)`, per replay, as one count that
 * only rises across a call's replays: each starts where the last ended.
 * @param {OnProgress} send
 * @returns {Progress}
 */
function rising(send) {
    let base = 0;
    /** @type {{ done: number, total: number, what: string } | null} */
    let last = null;
    return (done, total, what) => {
        if (last !== null && (what !== last.what || done <= last.done)) base += last.total;
        last = { done, total, what };
        send(base + done, base + total, what);
    };
}

/**
 * How the host opens a session (DSDB_WEB.md §3): the `load` operation's
 * description and input schema, and `open(args, say)`, which returns an exit
 * status when what it was given is refused (as lib/api/open.js does), or
 * `{ session, close }`. It throws OpError for what the caller can correct.
 * @typedef {{ description: string, inputSchema: Schema,
 *             open: (args: Args, say: Say) => Promise<number | Opened> }} Load
 */

/** One session, and the operations over it: dsdb's API. */
export class Api {
    /** @type {Opened | null} */
    #opened = null;
    /** @type {Map<string, Op>} `load` first, then OPS */
    #ops;
    /** @type {CallsPort | null} */
    #calls;
    /** @type {number} */
    #callTimeoutMs;
    /** @type {Set<string>} the calls sent to the responder, by `callKey` */
    #sent = new Set();

    /**
     * @param {object} opts
     * @param {Load} opts.load  how the host opens a session
     * @param {CallsPort | null} [opts.calls]  a calls socket (cli/socket.js), or null: the caller answers
     * @param {number} [opts.callTimeoutMs]  how long a round of calls waits for replies
     */
    constructor({ load, calls = null, callTimeoutMs = 5000 }) {
        /** @type {Op} */
        const loadOp = { name: "load", description: load.description, inputSchema: load.inputSchema,
                         run: (t, a) => t.load(load, a) };
        this.#ops = new Map([loadOp, ...OPS].map((x) => [x.name, x]));
        this.#calls = calls;
        this.#callTimeoutMs = callTimeoutMs;
    }

    close() {
        this.#opened?.close();
        this.#opened = null;
    }

    /**
     * Each operation: `{ name, description, inputSchema }`, and with
     * `outputSchema`, what its results can be (DSDB_MCP.md §10.7).
     * @param {{ outputSchemas?: boolean }} [opts]
     */
    list({ outputSchemas = true } = {}) {
        return [...this.#ops.values()].map(({ name, description, inputSchema, bound: b }) => ({
            // What `call` refuses, said in the schema too.
            name, description, inputSchema: { ...inputSchema, additionalProperties: false },
            ...(outputSchemas ? { outputSchema: outputSchema([...new Set([...RETURNS[name], ...ANY_OP, ...(b ? ["more"] : [])])]) }
                : {}),
        }));
    }

    /** @param {string} name */
    has(name) {
        return this.#ops.has(name);
    }

    /**
     * Operation `name`, run with `args`.
     * @param {string} name  one `list` gives; `has` says whether it is
     * @param {Args | null} [args]
     * @param {OnProgress | null} [progress]
     *   told how far long work has got (DSDB_MCP.md §10.3), rising across the call
     * @returns {Promise<Outcome>}
     */
    async call(name, args = {}, progress = null) {
        const tool = this.#ops.get(name), a = args ?? {};
        if (tool === undefined) throw new TypeError(`no operation \`${name}\``);
        return this.#invoke(async () => {
            // An argument the tool does not declare is refused before it runs
            // a misspelt one would otherwise be its default, silently.
            const takes = Object.keys(/** @type {Record<string, unknown>} */ (tool.inputSchema.properties ?? {}));
            const other = Object.keys(a).find((k) => !takes.includes(k));
            if (other !== undefined)
                throw new OpError(`\`${name}\` takes no \`${other}\`; it takes `
                                  + (takes.length ? takes.map((k) => `\`${k}\``).join(", ") : "no arguments"));
            let results = await tool.run(this, a);
            results.push(...await this.#relay());
            if (tool.bound === "rows") results = bound(results, { limit: this.#count(a.limit, LIMIT, "limit"),
                                                                  from: this.#cursor(a.cursor) });
            if (tool.bound === "tree") results = capTrees(results, this.#count(a.nodes, NODES, "nodes"));
            return results;
        }, progress);
    }

    /**
     * A shell line as the shell takes it, or a definition block
     * (DSDB_WEB.md §7.2), for a terminal in a page: what `call` returns,
     * unbounded, as the shell prints everything. A transport offers it only
     * when its host turns it on; MCP never does (DSDB_MCP.md §1).
     * @param {unknown} text
     * @param {OnProgress | null} [progress]
     * @returns {Promise<Outcome>}
     */
    async line(text, progress = null) {
        return this.#invoke(async () => {
            const results = await this.exec(String(text));
            results.push(...await this.#relay());
            return results;
        }, progress);
    }

    /**
     * @param {() => Promise<Result[]>} run
     * @param {OnProgress | null} progress
     * @returns {Promise<Outcome>}
     */
    async #invoke(run, progress) {
        /** @type {Result[]} */
        let results;
        const session = this.loaded;
        if (session !== null && progress !== null) session.state.progress = rising(progress);
        try {
            results = await run();
        } catch (err) {
            if (!(err instanceof OpError)) throw err;
            results = [{ type: "error", text: err.message }];
        } finally {
            if (session !== null) session.state.progress = null;
        }
        return { results: results.map(project), text: results.flatMap(resultLines).join("\n"),
                 isError: results.some((r) => REFUSALS.has(r.type)), raw: results };
    }

    /**
     * The session, or null before a `load`: what the resources read.
     * @returns {Session | null}
     */
    get loaded() {
        return this.#opened?.session ?? null;
    }

    /** @returns {Session} the session, which an operation other than `load` needs */
    get #session() {
        if (this.#opened === null) throw new OpError("nothing is loaded: `load` a program first");
        return this.#opened.session;
    }

    // ── the steps the table uses ───────────────────────────────────────────

    /**
     * `load`: a session opened by the host, replacing the one before.
     * @param {Load} host
     * @param {Args} args
     * @returns {Promise<Result[]>}
     */
    async load(host, args) {
        /** @type {string[]} */
        const said = [];
        /** @type {Say} */
        const say = { out: (l) => said.push(l), err: (l) => said.push(l) };
        let opened;
        try {
            opened = await host.open(args, say);
        } catch (err) {
            // The engine or compiler refusing what it was given.
            if (!(err instanceof Error) || (err.name !== "DsError" && err.name !== "CompileRefused")) throw err;
            throw new OpError(err.message);
        }
        if (typeof opened === "number") return [...said.map(/** @returns {Result} */ (text) => ({ type: "error", text })),
                                                { type: "error", text: `not loaded (${opened === 3 ? "the trace and program do not belong together" : "refused"})` }];
        this.close();
        this.#opened = opened;
        this.#sent = new Set();
        return [...said.map(note), ...opened.session.banner()];
    }

    /**
     * §10.8, with `--calls`: at a live session's end, each call not yet sent
     * goes to the responder; the replies back within the timeout are made
     * there together, in call order, as `from here answer` and `fail`; and
     * again for the calls those make, until none is new or none is answered.
     * Only a waiting call is waited for: a call to a `no response` service is
     * sent, and an error naming it is still made (DSDB.md §9.1). Anywhere
     * else the agent answers, as without a responder.
     */
    async #relay() {
        /** @type {Result[]} */
        const out = [];
        const session = this.loaded, sock = this.#calls;
        if (sock === null || session === null) return out;
        for (;;) {
            const s = session.state;
            if (!s.live || s.cur !== 0 || s.k !== s.tl.length) return out;
            const tl = s.tl, end = tl.length;
            /** @param {Call} c */
            const sendable = (c) => c.waitingAt(end) || (c.outcome === "no response" && c.resolved === null);
            const fresh = tl.calls.filter((c) => sendable(c) && !this.#sent.has(callKey(c)));
            if (!fresh.length) return out;
            for (const c of fresh) {
                this.#sent.add(callKey(c));
                sock.send(callWire({ number: c.number, service: c.service, correlation: c.corr, args: c.args,
                                     ruleName: c.rule, at: tl.clockAt(c.issued + 1) - tl.clockAt(0) }));
                out.push(note(`call ${c.number} ${c.service} as ${JSON.stringify(c.corr)} sent to the responder`
                              + (c.waits ? "" : "; no response")));
            }
            const awaited = fresh.filter((c) => c.waits);
            if (!awaited.length) return out;
            // Replies until each waiting call sent has one, or the time is up.
            /** @type {Map<number, [Call, Reply]>} */
            const replies = new Map();
            const deadline = sock.after(this.#callTimeoutMs);
            while (awaited.some((c) => !replies.has(c.number))) {
                const line = await sock.receive(deadline);
                if (line === null) break;
                /** @type {Reply} */
                let r;
                try {
                    r = parseReply(line);
                } catch (err) {
                    if (!(err instanceof ReplyError)) throw err;
                    out.push(note(`reply dropped: ${err.message}`));
                    continue;
                }
                /** @param {Call} x */
                const settles = (x) => x.waitingAt(end) || (r.error && x.outcome === "no response" && x.resolved === null);
                const c = tl.calls.find((x) => x.corr === r.corr && settles(x) && this.#sent.has(callKey(x)));
                if (c === undefined) out.push(note(`reply dropped: no call sent as ${JSON.stringify(r.corr)} `
                                                   + `${r.error ? "can fail" : "is waiting"}`));
                else replies.set(c.number, [c, r]);
            }
            if (!replies.size) {
                out.push(note(`no reply within ${this.#callTimeoutMs / 1000} s: the calls wait, for a reply or for `
                              + "`from_here_answer`"));
                return out;
            }
            for (const [c, r] of [...replies.values()].sort(([a], [b]) => a.number - b.number)) {
                /** @type {string} */
                let line;
                try {
                    line = r.error === undefined ? `from here answer ${c.number} ${r.response}`
                        : `from here fail ${c.number} code: ${this.quoted(r.error.code)} message: ${this.quoted(r.error.message)}`;
                } catch (err) {
                    if (!(err instanceof OpError)) throw err;
                    out.push(note(`reply to call ${c.number} dropped: ${err.message}`));
                    continue;
                }
                out.push(...await this.exec(line));
            }
        }
    }

    /**
     * A shell line, run.
     * @param {string} line
     * @returns {Promise<Result[]>}
     */
    exec(line) {
        return this.#session.execute(line);
    }

    /**
     * A definition, as the shell takes a block (§4.16).
     * @param {unknown} text
     * @returns {Promise<Result[]>}
     */
    define(text) {
        const t = String(text ?? "").replace(/\r\n/g, "\n").replace(/^\n+|\s+$/g, "");
        if (!t) throw new OpError("`define` needs the definition's text");
        if (/^\s/.test(t)) throw new OpError("a definition starts at column 0: `schema …`, `rule NAME:`, …");
        return this.exec(t);
    }

    /**
     * A fact or firing, shown as the shell shows the row.
     * @param {Row} item
     * @returns {Result[]}
     */
    show(item) {
        return this.#session.show(item);
    }

    /**
     * `fn` with the current timeline stood at point `at`, then put back.
     * @param {unknown} at  a point, as `#point` reads it; none: point
     * @param {() => Promise<Result[]> | Result[]} fn
     * @returns {Promise<Result[]>}
     */
    async at(at, fn) {
        if (at === undefined || at === null || at === "") return fn();
        const s = this.#session.state, v = s.view, tl = v.tl;
        const k = this.#point(tl, at);
        const was = v.k;
        v.k = k;
        try {
            return await fn();
        } finally {
            v.k = was;
        }
    }

    /**
     * @param {Timeline} tl
     * @param {unknown} at
     * @returns {number}
     */
    #point(tl, at) {
        const t = String(at).trim();
        if (t === "start") return 0;
        if (t === "end") return tl.length;
        const ns = durationNs(t);
        if (ns !== null) return tl.firstAtClock(tl.clockAt(0) + ns);
        const p = position(t.replace(/^@/, ""));
        if (p === null) throw new OpError(`\`${t}\` is not a point: a hex position, \`start\`, \`end\`, or a clock such as \`12_s\``);
        const got = tl.resolve(p.seq, p.minus);
        if (got === null) throw new OpError(`\`${t}\` is past the last position`);
        return got[0];
    }

    /**
     * @param {Args} args
     * @returns {Promise<Result[]>}
     */
    move({ to, by, step, unit = "settled" }) {
        const given = [to, by, step].filter((x) => x !== undefined && x !== null && x !== "");
        if (given.length !== 1) throw new OpError("`move` takes one of `to`, `by` or `step`");
        if (to !== undefined && to !== null && to !== "") {
            const t = String(to).trim();
            return this.exec(t === "start" ? "@<" : t === "end" ? "@>" : `@${t.replace(/^@/, "")}`);
        }
        if (by !== undefined && by !== null && by !== "") {
            const b = String(by).trim();
            if (!/^[+-]/.test(b)) throw new OpError("`by` starts with + or -: `+10`, `-2_s`");
            return this.exec(`@${b}`);
        }
        const word = step === "next" ? "n" : step === "prev" ? "p" : null;
        if (word === null) throw new OpError("`step` is `next` or `prev`");
        const units = new Map([["settled", ""], ["record", " atom"], ["firing", " fire"], ["tick", " tick"]]);
        const suffix = typeof unit === "string" ? units.get(unit) : undefined;
        if (suffix === undefined) throw new OpError("`unit` is settled, record, firing or tick");
        return this.exec(word + suffix);
    }

    /**
     * @param {Args} args
     * @returns {Promise<Result[]>}
     */
    why({ fact, rule, timetag, depth, at }) {
        const d = depth ? ` depth ${Number(depth)}` : "";
        if (fact !== undefined && fact !== null) return this.at(at, () => this.exec(`why #${this.#id(fact)}${d}`));
        if (!rule || timetag === undefined) throw new OpError("`why` takes a `fact`, or a `rule` and its `timetag`");
        return this.at(at, () => this.exec(`why ${this.word(rule)} ${this.#tt(timetag).toString(16)}${d}`));
    }

    /**
     * @param {unknown} id
     * @returns {Fact}
     */
    fact(id) {
        const tl = this.#session.state.tl;
        const f = tl.facts.get(this.#id(id));
        if (f === undefined) throw new OpError(`no fact #${id} in the current timeline`);
        return f;
    }

    /**
     * @param {unknown} rule
     * @param {unknown} timetag
     * @returns {Firing}
     */
    firing(rule, timetag) {
        const tl = this.#session.state.tl, tt = this.#tt(timetag);
        const fr = tl.firings.find((f) => f.rule === rule && f.timetag === tt);
        if (fr === undefined) throw new OpError(`no firing of \`${rule}\` with timetag 0x${tt.toString(16)}`);
        return fr;
    }

    /**
     * A count from 1, or its default.
     * @param {unknown} v
     * @param {number} dflt
     * @param {string} what  the argument, for the refusal
     * @returns {number}
     */
    #count(v, dflt, what) {
        if (v === undefined || v === null) return dflt;
        if (typeof v !== "number" || !Number.isInteger(v) || v < 1) throw new OpError(`\`${what}\` is a whole number from 1`);
        return v;
    }

    /**
     * The row a cursor stands for (§10.1).
     * @param {unknown} c
     * @returns {number}
     */
    #cursor(c) {
        if (c === undefined || c === null || c === "") return 0;
        if (!/^\d+$/.test(String(c))) throw new OpError(`\`${c}\` is not a cursor a result gave`);
        return Number(c);
    }

    /**
     * @param {unknown} id  `42` or `#42`
     * @returns {bigint}
     */
    #id(id) {
        const t = String(id).replace(/^#/, "");
        if (!/^\d+$/.test(t)) throw new OpError(`\`${id}\` is not a fact id`);
        return BigInt(t);
    }

    /**
     * @param {unknown} tt  `0x4f1` or a decimal
     * @returns {bigint}
     */
    #tt(tt) {
        const t = String(tt).trim();
        if (/^0x[0-9a-f]+$/i.test(t)) return BigInt(t);
        if (/^\d+$/.test(t)) return BigInt(t);
        throw new OpError(`\`${tt}\` is not a timetag: \`0x4f1\` or a decimal`);
    }

    /**
     * A name, checked to be one word, for a command line.
     * @param {unknown} name
     * @returns {string}
     */
    word(name) {
        const s = String(name);
        if (!/^[A-Za-z_][\w.;]*$/.test(s)) throw new OpError(`\`${name}\` is not a name`);
        return s;
    }

    /**
     * A query body: one line as it is, several as the shell's bracket block
     * (DSTRACE_INTERACTIVE §4.2), one pattern per line.
     * @param {unknown} body
     * @returns {string}
     */
    body(body) {
        const lines = String(body).split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
        if (!lines.length) throw new OpError("the query is empty");
        return lines.length === 1 ? lines[0] : `(\n${lines.join("\n")}\n)`;
    }

    /**
     * `from here`, `from start` or `from @N` (§4.16), from a tool's `from`.
     * @param {unknown} at
     * @returns {string}
     */
    from(at) {
        const t = at === undefined || at === null ? "here" : String(at).trim().replace(/^@/, "");
        if (t === "here" || t === "start") return `from ${t}`;
        if (t === "end") return "from @>";
        if (!/^[0-9A-Fa-f]+-*$/.test(t) && durationNs(t) === null)
            throw new OpError(`\`${at}\` is not a point: \`here\`, \`start\`, \`end\`, a hex position or a clock such as \`12_s\``);
        return `from @${t}`;
    }

    /**
     * A fact id, for a command line.
     * @param {unknown} id
     */
    id(id) {
        return this.#id(id).toString();
    }

    /**
     * Text that must stay one command line.
     * @param {unknown} text
     */
    oneLine(text) {
        const s = String(text).trim();
        if (!s || /[\n\r]/.test(s)) throw new OpError("give it on one line");
        return s;
    }

    /**
     * A path, one word on the command line.
     * @param {unknown} p
     */
    path(p) {
        const s = String(p);
        if (!s || /\s/.test(s)) throw new OpError(`\`${p}\`: a path with no spaces`);
        return s;
    }

    /**
     * A string in double quotes, for `code:` and `message:`.
     * @param {unknown} s
     */
    quoted(s) {
        if (/["\n\r]/.test(String(s))) throw new OpError("a code or message holds no double quote or newline");
        return `"${s}"`;
    }

    /**
     * A duration with its underscore (§4.2).
     * @param {unknown} d
     */
    duration(d) {
        const s = String(d).trim().replace(/^\+/, "");
        if (durationNs(s) === null) throw new OpError(`\`${d}\` is not a duration: \`500_ms\`, \`5_s\``);
        return s;
    }

    /**
     * ` /regex/`, or nothing.
     * @param {unknown} re
     */
    filter(re) {
        if (re === undefined || re === null || re === "") return "";
        if (/[\n\r]/.test(String(re))) throw new OpError("a filter is one line");
        return ` /${re}/`;
    }
}
