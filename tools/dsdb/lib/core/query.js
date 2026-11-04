// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Queries: a rule the engine answers, over a timeline (DSTRACE_INTERACTIVE
// §7.2–7.5). The port of tools/dstrace_shell/query.py.
//
// A query is the left-hand side of a rule. dsdb compiles
//
//     <the program's declarations>
//     schema QH<n> scope logical:             one fact-reference key per binding
//         t: Thermometer key
//     rule q<n>:
//         <the query's patterns>
//     ->
//         let col_1 = <projection>            only with a projection
//         emit QH<n> logical t: t
//         log debug "{col_1}\x1f{col_2}"      only with a projection
//
// and runs it in a QUERY ENGINE: the program's schemas and this one rule, none
// of the program's rules, fed the timeline's records one at a time (§7.3).
// Truth maintenance keeps each hit fact alive exactly as long as its binding
// tuple matches, so the hits' assert and withdrawal history is the ANSWER
// TIMELINE.
//
// WHAT IS READ FROM THE QUERY TEXT, AND WHY IT IS SAFE. The hit schema needs
// each positive pattern's schema and binding, so the pattern HEADS are read:
// `[latest] [lib.]Schema binding`, at the start of each pattern line and after
// each `then`. Expressions are not. Nothing read here is trusted: the compiler
// validates the whole rule, and the binding names read are checked against the
// ones the compiler itself reports in the rule's display-name template (DNAM,
// [RDSC.6.8]). A disagreement is refused, never guessed through.
//
// Record indexes and points are Numbers; fact ids BigInts.

import { RecordedRef } from "./ref.js";
import { EXTERNAL_DIVERGED, is } from "./trace.js";

/** @import { Engine, Fact, SlotValue, StreamEngineEvent } from "@ds-lang/ds" */
/** @import { Program } from "./program.js" */
/** @import { Timeline } from "./timeline.js" */
/** @import { FactSlots, TraceRecord } from "./trace.js" */
/** @import { Compile, Ds } from "./types.js" */

/** The stream event kinds a query's engine listens for: what its `#on` reads. */
const ANSWERING = /** @type {const} */ (
    ["rule_lhs_facts", "rule_fire_begin", "rule_fire_end", "action_emit", "action_log", "action_cache_set",
     "fact_retract", "computation_error", "type_error"]);

/** The tags `Queries.evaluate` projects beside a value, in order ([LNUL.4.9]). */
export const TAGS = /** @type {const} */ (["null", "Bool", "Int", "Float", "String", "Bytes", "Json"]);

const HEAD = /^\s*(?:latest\s+)?((?:[A-Za-z_]\w*\.)*[A-Za-z_]\w*)\s+([A-Za-z_]\w*)/;
const THEN = /\bthen\b/;
// A binding in the template: a NAME, or a synthetic `$`-led one the compiler
// gave a pattern written without a binding ([RDSC.6.8.9], [LLEX.10.6.1]).
const DNAM_BINDING = /\{(\$*[A-Za-z_]\w*)\./g;
const SEP = "\x1f";

/** A query the compiler or dsdb refused, with a message for the user. */
export class QueryError extends Error {
    /**
     * @param {string} message
     * @param {{ text: string, source: string } | null} [compiler]  when the compiler refused it: its
     *   report as it rendered it, and the program it was given, so a caller that built the query
     *   around a user's expression can say the refusal in that expression's terms
     */
    constructor(message, compiler = null) {
        super(message);
        this.name = "QueryError";
        this.compiler = compiler;
    }
}

/** One answer: a binding tuple, live from the application of record
    `start` until the application of record `end`. */
export class Answer {
    /**
     * @param {bigint[]} bindings  trace fact ids, in pattern order; -1n where unknown
     * @param {number} start
     */
    constructor(bindings, start) {
        this.bindings = bindings;
        this.start = start;
        /** @type {number | null} */
        this.end = null;
        /** @type {string[] | null} projected values, as the engine printed them */
        this.values = null;
        /** @type {string | null} the first value's tag, of `TAGS`, for a tagged query; null when none is */
        this.tag = null;
        /** @type {string | null} a tagged query's value as JSON text, as the cache wrote it */
        this.json = null;
    }

    /** @param {number} k */
    liveAt(k) {
        return this.start < k && (this.end === null || this.end >= k);
    }

    /** The binding tuple as a Map key. */
    get key() {
        return this.bindings.join(",");
    }
}

// ── splitting the line (shell syntax only) ──────────────────────────────────

/**
 * Split on `sep` outside quotes and brackets.
 * @param {string} text
 * @param {string} sep
 * @returns {string[]}
 */
function topLevelSplit(text, sep) {
    const out = [];
    let depth = 0, quote = false, cur = "";
    for (let i = 0; i < text.length; i++) {
        const ch = text[i];
        if (quote) {
            cur += ch;
            if (ch === "\\" && i + 1 < text.length) cur += text[++i];
            else if (ch === '"') quote = false;
        } else if (ch === '"') {
            quote = true;
            cur += ch;
        } else if ("([{".includes(ch)) {
            depth++;
            cur += ch;
        } else if (")]}".includes(ch)) {
            depth--;
            cur += ch;
        } else if (depth === 0 && text.startsWith(sep, i)) {
            out.push(cur);
            cur = "";
            i += sep.length - 1;
        } else cur += ch;
    }
    out.push(cur);
    return out;
}

/**
 * `[pattern lines, projection expressions]` from a query body. A bracket
 * block (§4.2) arrives as its lines; a projection is written on the same line
 * after ` -> `, or as a block line starting `->`.
 * @param {string} body
 * @returns {[string[], string[]]}
 */
export function splitBody(body) {
    let lines = body.split("\n").filter((ln) => ln.trim()).map((ln) => ln.trimEnd());
    let proj = "";
    if (lines.length && lines[lines.length - 1].trimStart().startsWith("->")) {
        proj = (lines.pop() ?? "").trimStart().slice(2);
    } else if (lines.length === 1) {
        const parts = topLevelSplit(lines[0], " -> ");
        if (parts.length > 1) {
            lines = [parts[0]];
            proj = parts.slice(1).join(" -> ");
        }
    }
    const exprs = proj ? topLevelSplit(proj, ",").map((e) => e.trim()).filter(Boolean) : [];
    return [lines.map((ln) => ln.trim()), exprs];
}

/**
 * `[schema, binding]` for each positive pattern, in order.
 * @param {string[]} lines
 * @returns {Array<[string, string]>}
 */
export function heads(lines) {
    /** @type {Array<[string, string]>} */
    const out = [];
    for (const line of lines) {
        if (/^\s*no\b/.test(line)) continue;          // absence binds nothing
        for (const seg of line.split(THEN)) {
            const m = HEAD.exec(seg);
            if (m) out.push([m[1], m[2]]);
        }
    }
    return out;
}

// ── compiling ───────────────────────────────────────────────────────────────

/**
 * @param {string} name
 * @param {Set<string>} taken
 */
const fresh = (name, taken) => {
    while (taken.has(name)) name += "_";
    return name;
};

/**
 * The compiler's message, with line numbers shifted so line 1 is the query's
 * first (the generated program's prefix is `offset` lines).
 * @param {unknown} err  what the compile threw
 * @param {number} offset
 */
export function compileMessage(err, offset) {
    const message = typeof err === "object" && err !== null && "message" in err ? err.message : undefined;
    return String(message ?? err).replace(/line (\d+)/g,
        (_, n) => `query line ${Math.max(1, Number(n) - offset)}`);
}

/**
 * A query compiled to its one-rule program.
 * @typedef {object} CompiledQuery
 * @property {string} text  as typed
 * @property {number} n
 * @property {string} rule  its rule's name
 * @property {string} hit   its hit schema's name
 * @property {Array<[string, string]>} bindings  `[schema, binding]` per positive pattern
 * @property {string[]} projection  its projection's expressions
 * @property {Uint8Array} dsc
 * @property {number} prefixLines  how many lines the program puts before the query's
 * @property {string | null} probe  its probe schema, with `probe`; else null
 * @property {Map<string, string>} tagSlots  with `tags`, the hit's tag slots and the tag each tests; else empty
 */

/**
 * A query compiled to its one-rule program.
 * @param {object} args
 * @param {Program} args.prog
 * @param {string} args.body
 * @param {number} args.n  the query's number, for its rule and hit schema names
 * @param {Set<string>} args.names  names not to reuse
 * @param {Compile | null} args.compile  null when the session has no compiler
 * @param {Ds} args.ds  to read the compiled rule's metadata
 * @param {boolean} [args.probe]  add a last pattern of a scratch schema, so the rule
 *     fires only once `QueryEngine.probe` asserts its one fact; no other pattern is needed
 * @param {boolean} [args.tags]  give the hit a Bool slot per `TAGS`, set to whether the
 *     first projected value has that tag ([LNUL.4.9]), and write that value with `cache`
 *     rather than a log; `Answer.tag` and `Answer.json` read them
 * @returns {Promise<CompiledQuery>}
 * @throws {QueryError}
 */
export async function compileQuery({ prog, body, n, names, compile, ds, probe = false, tags = false }) {
    const [given, proj] = splitBody(body);
    if (!given.length && !probe) throw new QueryError("a query needs at least one pattern");
    if (tags && !proj.length) throw new QueryError("a tagged query needs a projection");
    const rule = fresh(`q${n}`, names), hit = fresh(`QH${n}`, names);
    const taken = new Set(heads(given).map(([, b]) => b));
    const probeSchema = probe ? fresh(`QP${n}`, names) : null;
    const lines = probeSchema === null ? given : [...given, `${probeSchema} ${fresh("qp", taken)}`];
    const bindings = heads(lines);
    for (const [, b] of bindings) taken.add(b);
    // A tagged query writes its value with `cache`, whose write-through
    // gives any value's JSON text, and its tags as slots on the hit. It
    // interpolates nothing: interpolating a Json object is a fault
    // ([LGRA.2.9.6.11]), and dsc does not lower interpolating a `let` bound
    // to an `is` test or a comparison.
    /** @type {Array<[string, string]>} [tag, slot] */
    const tagSlots = tags ? TAGS.map((t) => /** @type {[string, string]} */ ([t, fresh(`is_${t.toLowerCase()}`, taken)])) : [];

    const hitDecl = [`schema ${hit} scope logical:`,
                     ...(bindings.length ? bindings.map(([s, b]) => `    ${b}: ${prog.spelling(s)} key`) : ["    one: Int key"]),
                     ...tagSlots.map(([, slot]) => `    ${slot}: Bool mutable`)];
    const emitArgs = [bindings.map(([, b]) => `${b}: ${b}`).join(" ") || "one: 1",
                      ...tagSlots.map(([t, slot]) => `${slot}: col_1 is ${t}`)].join(" ");
    // `col_N`, not `pN`: `p1`, `p2`, ... are reserved as percentile names
    // ([LGRA.22.7]).
    const rhs = proj.map((e, i) => `    let col_${i + 1} = ${e}`);
    rhs.push(`    emit ${hit} logical ${emitArgs}`);
    if (tags) rhs.push(`    cache key: "${hit}" value: col_1 ttl: 1_h`);
    else if (proj.length) rhs.push('    log debug "' + proj.map((_, i) => `{col_${i + 1}}`).join("\\x1f") + '"');
    const probeDecl = probeSchema === null ? "" : `schema ${probeSchema} scope ttl 1_h:\n    n: Int\n\n`;
    // No `ttl` scope: the query engine expires nothing, and each fact leaves
    // at its recorded withdrawal ([RFCS.7.4]).
    const prefix = prog.declarations(false, { ttl: false }) + "\n" + probeDecl + hitDecl.join("\n") + `\n\nrule ${rule}:\n`;
    const source = prefix + lines.map((ln) => `    ${ln}`).join("\n") + "\n->\n" + rhs.join("\n") + "\n";
    const offset = prefix.split("\n").length - 1;
    if (compile === null) throw new QueryError("a query needs the compiler, which is not here");
    let dsc;
    try {
        dsc = await compile(source, { file: "<query>", ...prog.stage(false, { ttl: false }) });
    } catch (err) {
        throw new QueryError(compileMessage(err, offset), { text: String(err instanceof Error ? err.message : err), source });
    }
    const got = dnamBindings(ds, dsc, rule);
    const want = bindings.map(([, b]) => b);
    if (got !== null && got.join("\0") !== want.join("\0"))
        throw new QueryError(`could not read this query's patterns (read ${pyList(want)}, the compiler has `
                             + `${pyList(got)}); write one pattern per line in a ( ) block`);
    return { text: body, n, rule, hit, bindings, projection: proj, dsc, prefixLines: offset, probe: probeSchema,
             tagSlots: new Map(tagSlots.map(([t, slot]) => /** @type {[string, string]} */ ([slot, t]))) };
}

/**
 * `[schema, slots]` for an `emit` typed at the prompt (§7.2). The compiler
 * checks it and the engine computes it: dsdb compiles
 *
 *     <scratch declarations>
 *     schema DstraceTrigger<n> scope ttl 1_h:
 *         n: Int
 *     rule e<n>:
 *         DstraceTrigger<n> x where x.n == 1
 *     ->
 *         <the emit line>
 *
 * runs it once in a scratch engine, and reads the emitted fact from the
 * stream. Nothing here reads the emit's expressions.
 * @param {object} args
 * @param {Program} args.prog
 * @param {string} args.line
 * @param {number} args.n
 * @param {Set<string>} args.names  names not to reuse
 * @param {Compile | null} args.compile  null when the session has no compiler
 * @param {Ds} args.ds
 * @returns {Promise<[string, Record<string, SlotValue>]>}
 * @throws {QueryError}
 */
export async function evaluateEmit({ prog, line, n, names, compile, ds }) {
    const text = line.trim();
    if (!/^(emit|publish)\b/.test(text)) throw new QueryError("an input is written `emit Schema slot: value …`");
    if (/^(emit|publish)\s+\S+\s+logical\b/.test(text))
        throw new QueryError("an emit at the prompt is an input, not truth-maintained: drop `logical`");
    const trig = fresh(`DstraceTrigger${n}`, names);
    const prefix = prog.declarations(true) + `\nschema ${trig} scope ttl 1_h:\n    n: Int\n\n`
        + `rule e${n}:\n    ${trig} x where x.n == 1\n->\n`;
    if (compile === null) throw new QueryError("an input at the prompt needs the compiler, which is not here");
    let dsc;
    try {
        dsc = await compile(prefix + `    ${text}\n`, { file: "<emit>", ...prog.stage(true) });
    } catch (err) {
        throw new QueryError(compileMessage(err, prefix.split("\n").length - 1));
    }
    const e = new ds.Engine();
    /** @type {[string, Record<string, SlotValue>] | null} */
    let got = null;
    try {
        e.loadDsc(dsc);
        e.addEventListener("action_emit", (ev) => {
            if (got !== null) return;
            const f = ev.fact.read();
            got = [f.schema, f.slots];
        });
        // A publish carries its own copy: it puts nothing in working memory
        // ([LTIE.4.3]).
        e.addEventListener("action_publish", (ev) => {
            if (got === null) got = [ev.schema, ev.slots];
        });
        e.assert(trig, { n: 1n });
        e.pump();
    } finally {
        e.close();
    }
    if (got === null) throw new QueryError("the emit produced no fact");
    return got;
}

/**
 * Python's repr of a list of strings, for the message above.
 * @param {string[]} xs
 */
const pyList = (xs) => "[" + xs.map((x) => `'${x}'`).join(", ") + "]";

/**
 * The bindings the compiler reports for `rule`, in order, or null when the
 * artefact carries no display-name template.
 * @param {Ds} ds
 * @param {Uint8Array} dsc
 * @param {string} rule
 * @returns {string[] | null}
 */
function dnamBindings(ds, dsc, rule) {
    const e = new ds.Engine();
    let tpl;
    try {
        e.loadDsc(dsc);
        tpl = e.rules.get(rule)?.debugNameTemplate ?? null;
    } finally {
        e.close();
    }
    if (!tpl) return null;              // a stripped artefact: nothing to check
    return [...tpl.matchAll(DNAM_BINDING)].map((m) => m[1]);
}

// ── the query engine (§7.3, §7.4) ───────────────────────────────────────────

const APPLIED = new Set(["FactAssert", "FactEmit", "ExternalAssert", "FactRetract", "FactWithdraw", "ClockAdvance"]);

export class QueryEngine {
    /** @type {Answer[]} */
    answers = [];
    /** @type {Array<{ bindings: bigint[], kind: "computation_error" | "type_error" }>}
        the faults the query's own firings raised, each with its binding tuple */
    faults = [];
    /** records applied so far */
    fed = 0;
    /** records the engine has no schema for, or that are not typed */
    skipped = 0;
    /** @type {Engine} */
    #eng;
    /** @type {string} */
    #rule;
    /** @type {Map<bigint, Fact>} trace id -> engine Fact */
    #handles = new Map();
    /** @type {Map<bigint, bigint>} engine id -> trace id */
    #traceOf = new Map();
    /** @type {Map<bigint, Answer>} engine id of a hit -> Answer */
    #hits = new Map();
    /** @type {bigint[]} */
    #lhs = [];
    #firing = false;
    /** @type {Answer | null} */
    #current = null;
    #index = 0;

    /**
     * @param {Ds} ds
     * @param {CompiledQuery} compiled  from compileQuery
     */
    constructor(ds, compiled) {
        this.compiled = compiled;
        this.#rule = compiled.rule;
        const e = this.#eng = new ds.Engine();
        e.loadDsc(compiled.dsc);
        e.clock.mode = "mock";
        e.clock.set(0n);
        const on = (/** @type {StreamEngineEvent} */ ev) => this.#on(ev);
        for (const kind of ANSWERING) e.addEventListener(kind, on);
    }

    close() {
        this.#eng.close();
    }

    /** @param {StreamEngineEvent} ev  one of ANSWERING */
    #on(ev) {
        switch (ev.type) {
        case "rule_lhs_facts":
            if (ev.ruleName === this.#rule) this.#lhs = ev.lhsFacts.map((f) => this.#traceOf.get(f.id) ?? -1n);
            break;
        case "rule_fire_begin":
            this.#firing = ev.ruleName === this.#rule;
            break;
        case "rule_fire_end":
            this.#firing = false;
            this.#current = null;
            break;
        case "action_emit":
            if (this.#firing) {
                const a = new Answer(this.#lhs, this.#index);
                const tags = this.compiled.tagSlots;
                if (tags.size) {
                    const slots = ev.fact.read().slots ?? {};
                    for (const [slot, t] of tags) if (slots[slot] === true) a.tag = t;
                }
                this.#hits.set(ev.fact.id, a);
                this.answers.push(a);
                this.#current = a;
            }
            break;
        case "action_log":
            if (this.#firing && this.#current !== null) this.#current.values = ev.message.split(SEP);
            break;
        case "action_cache_set":
            if (this.#firing && this.#current !== null && ev.key === this.compiled.hit) this.#current.json = ev.valueJson;
            break;
        case "computation_error":
        case "type_error":
            // The activation is abandoned, so it emits no hit: its fault is
            // the answer.
            if (this.#firing) this.faults.push({ bindings: this.#lhs, kind: ev.type });
            break;
        case "fact_retract": {
            // The handle is readable during this callback and dead after it.
            const fid = ev.fact.id;
            const tid = this.#traceOf.get(fid);
            if (tid !== undefined) {
                this.#traceOf.delete(fid);
                this.#handles.delete(tid);
            }
            const a = this.#hits.get(fid);
            if (a !== undefined) {
                this.#hits.delete(fid);
                if (a.end === null) a.end = this.#index;
            }
            break;
        }
        }
    }

    /**
     * Apply records `[fed, upto)` (§7.3's table), pumping after each that
     * changed state.
     * @param {TraceRecord[]} records
     * @param {number} upto
     */
    feed(records, upto) {
        const e = this.#eng;
        for (const r of records.slice(this.fed, upto)) {
            this.#index = r.index;
            // A query reading `now()` reads the wall clock the run had.
            if (is(r, "ClockAdvance") && r.body.wall_ns != null) e.clock.setWall(BigInt(r.body.wall_ns));
            if (!APPLIED.has(r.kind)) {
                this.fed = r.index + 1;
                continue;
            }
            if (r.clockNs > e.clock.now) e.clock.set(r.clockNs);
            if (is(r, "ExternalAssert")) {
                // Refused before `fed` moves, so asking again refuses again:
                // the answers would be those of a run the recording does not
                // hold. Otherwise its facts join the trace-id map, so a later
                // retract or withdrawal of one is applied.
                this.#external(r);
                this.fed = r.index + 1;
                e.pump();
                continue;
            }
            this.fed = r.index + 1;
            if (is(r, "FactAssert", "FactEmit")) {
                if (!this.#assert(r)) continue;
            } else if (is(r, "FactRetract", "FactWithdraw")) {
                const f = this.#handles.get(r.body.fact_id);
                if (f === undefined) continue;          // never asserted here, or already gone
                this.#handles.delete(r.body.fact_id);
                e.retract(f);
            }
            e.pump();
        }
    }

    /**
     * Assert the probe of a query compiled with one (`compileQuery`'s
     * `probe`) and pump once: the rule fires for every binding tuple live
     * now, at this instant.
     */
    probe() {
        const schema = this.compiled.probe;
        if (schema === null) throw new QueryError("this query was compiled without a probe");
        this.#eng.assert(schema, { n: 1n });
        this.#eng.pump();
    }

    /**
     * An ExternalAssert, delivered as libds's replayer delivers one
     * ([RFCS.24.2]): this engine holds the program's schemas, so the received
     * fact and the facts it refers to arrive as recorded. A delivery libds
     * cannot make as recorded is a QueryError naming the record.
     * @param {Extract<TraceRecord, { kind: "ExternalAssert" }>} r
     */
    #external(r) {
        let got;
        try {
            got = this.#eng.applyExternalAssert(r.body.bytes);
        } catch (err) {
            if (err instanceof Error && err.name === "DsError")
                throw new QueryError(`record ${r.index}: ${EXTERNAL_DIVERGED}: ${err.message}`);
            throw err;
        }
        got.recordedIds.forEach((rec, i) => {
            const f = this.#eng.factById(got.factIds[i]);
            if (f === null) return;
            this.#handles.set(rec, f);
            this.#traceOf.set(f.id, rec);
        });
    }

    /** @param {Extract<TraceRecord, { kind: "FactAssert" | "FactEmit" }>} r */
    #assert(r) {
        const b = r.body;
        const schema = b.schema_name;
        if (schema.startsWith("DstraceGate")) return false;     // a rule change's gate (§8.6), not data
        if (b.slots === null || b.slots === undefined || !this.#eng.schemas.has(schema)) {
            this.skipped++;                                     // untyped, or no rule here reads it
            return false;
        }
        const slots = this.#engineSlots(b.slots);
        if (slots === null) {
            this.skipped++;                                     // it names a fact this engine does not hold
            return false;
        }
        // Whatever TTL it was recorded with: this engine expires nothing
        // (compileQuery), so the fact stays until its recorded withdrawal.
        const f = this.#eng.assert(schema, slots);
        this.#handles.set(b.fact_id, f);
        this.#traceOf.set(f.id, b.fact_id);
        return true;
    }

    /**
     * A recorded body's slots as this engine takes them: a reference, which
     * names a record's fact (core/ref.js), becomes this engine's own
     * fact for that record. Null when this engine holds no live fact for it,
     * and the fact is left unapplied, as an untyped one is.
     * @param {FactSlots} slots
     * @returns {Record<string, SlotValue> | null}
     */
    #engineSlots(slots) {
        /** @type {Record<string, SlotValue>} */
        const out = {};
        for (const [k, v] of Object.entries(slots)) {
            if (!(v instanceof RecordedRef)) {
                out[k] = v;
                continue;
            }
            const f = this.#handles.get(v.id);
            if (f === undefined || !f.alive) return null;
            out[k] = f;
        }
        return out;
    }

    // ── reading the answer timeline ─────────────────────────────────────────

    /** @param {number} k */
    at(k) {
        return this.answers.filter((a) => a.liveAt(k));
    }

    /** Every point at which the answer set changes, in order. */
    changes() {
        const pts = new Set(this.answers.map((a) => a.start + 1));
        for (const a of this.answers) if (a.end !== null) pts.add(a.end + 1);
        return [...pts].sort((x, y) => x - y);
    }

    /**
     * `[point, count]` steps, as Timeline.changes gives for a schema.
     * @returns {Array<[number, number]>}
     */
    population() {
        /** @type {Array<[number, number]>} */
        const ev = [];
        for (const a of this.answers) {
            ev.push([a.start + 1, 1]);
            if (a.end !== null) ev.push([a.end + 1, -1]);
        }
        ev.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
        /** @type {Array<[number, number]>} */
        const out = [];
        let n = 0;
        for (const [k, d] of ev) {
            n += d;
            if (out.length && out[out.length - 1][0] === k) out[out.length - 1] = [k, n];
            else out.push([k, n]);
        }
        return out;
    }
}

/** Compiled queries and their engines, cached by text (§7.5). */
export class Queries {
    /** @type {Ds} */
    #ds;
    /** @type {Compile | null} */
    #compile;
    /** @type {Map<string, QueryEngine>} */
    #cache = new Map();
    /** @type {Map<string, CompiledQuery>} `evaluate`'s, compiled once; each call runs an engine of its own */
    #probes = new Map();
    #n = 0;

    /**
     * @param {Ds} ds
     * @param {Program} prog
     * @param {Timeline} tl
     * @param {Compile | null} compile  null when the session has no compiler
     */
    constructor(ds, prog, tl, compile) {
        this.#ds = ds;
        this.prog = prog;
        this.tl = tl;
        this.#compile = compile;
    }

    /**
     * The engine for `body`, fed to `upto`.
     * @param {string} body
     * @param {number} upto
     * @returns {Promise<QueryEngine>}
     * @throws {QueryError}
     */
    async get(body, upto) {
        const key = body.split(/\s+/).filter(Boolean).join(" ");
        let qe = this.#cache.get(key);
        if (qe === undefined) {
            this.#n++;
            const c = await compileQuery({ prog: this.prog, body, n: this.#n,
                                           names: new Set([...this.prog.names(), "q", "QH"]),
                                           compile: this.#compile, ds: this.#ds });
            qe = new QueryEngine(this.#ds, c);
            this.#cache.set(key, qe);
        }
        qe.feed(this.tl.records, upto);
        return qe;
    }

    /**
     * `expr` at point `upto`, against the bindings of `pats` (`ds dap`'s
     * `evaluate`, [NDBG.13.7]): the query `pats` with a probe, in an engine
     * of its own fed to `upto`, the probe asserted there. Each answer's
     * `json` is the value as JSON text and its `tag` says which of `TAGS` it
     * has; a binding tuple whose evaluation faulted is in `faults` instead.
     * No other engine moves.
     * @param {string[]} pats  a rule's patterns, or none
     * @param {string} expr
     * @param {number} upto
     * @returns {Promise<{ answers: Answer[], faults: QueryEngine["faults"] }>}
     * @throws {QueryError}
     */
    async evaluate(pats, expr, upto) {
        const body = [...pats, `-> ${expr}`].join("\n");
        const key = body.split(/\s+/).filter(Boolean).join(" ");
        let c = this.#probes.get(key);
        if (c === undefined) {
            this.#n++;
            c = await compileQuery({ prog: this.prog, body, n: this.#n, names: new Set([...this.prog.names(), "q", "QH", "QP"]),
                                     compile: this.#compile, ds: this.#ds, probe: true, tags: true });
            this.#probes.set(key, c);
        }
        const qe = new QueryEngine(this.#ds, c);
        try {
            qe.feed(this.tl.records, upto);
            qe.probe();
            return { answers: qe.answers, faults: qe.faults };
        } finally {
            qe.close();
        }
    }

    close() {
        for (const qe of this.#cache.values()) qe.close();
        this.#cache.clear();
    }
}
