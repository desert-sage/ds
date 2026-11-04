// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Changes (DSTRACE_INTERACTIVE §4.9, §4.10): `emit`, `withdraw`, `answer`,
// `fail`, `silence`, and what `n` and `@+D` do at the end of an engine's
// timeline. The port of shell.py's change, apply, run_change and show_new.
// Where a change applies is timelines.js's `target`: the end of a live `%0`,
// or a hypothesis, opened or rebuilt. Returns results; prints nothing.

import { QueryError, evaluateEmit } from "./query.js";
import { splitlines } from "./answers.js";
import { ReplyError, responseSlots } from "./calls.js";
import { FactFileError, scanObject, typeSlots } from "./facts.js";
import { MAX_DURATION_NS } from "./grammar.js";
import { is } from "./trace.js";
// A change's description is kept on its hypothesis and printed when a saved
// one is written, in the words the shell uses for the same things.
import { factRef, slotsText, value } from "../text/render.js";

/** @import { SchemaInfo, SlotValue } from "@ds-lang/ds" */
/** @import { EngineTimeline } from "./engine-timeline.js" */
/** @import { CellValue } from "./facts.js" */
/** @import { FactKey, Redo } from "./hypotheses.js" */
/** @import { SessionState } from "./state.js" */
/** @import { Fact } from "./timeline.js" */
/** @import { Timelines } from "./timelines.js" */
/** @import { Compile, Ds, ReplyField, Result } from "./types.js" */

/**
 * A change, made on the engine timeline it applies to; `false` when there
 * was nothing to do.
 * @typedef {(run: EngineTimeline) => unknown} Act
 */

/**
 * An engine's refusal, or the Error applying a record raises: said, not thrown.
 * @param {unknown} err
 * @returns {err is Error}
 */
const refusal = (err) => err instanceof Error && (err.name === "DsError" || err.constructor === Error);
/** @param {unknown} err */
const message = (err) => (err instanceof Error ? err.message : String(err));

export class Changes {
    /** @type {SessionState} */
    #s;
    /** @type {Ds} */
    #ds;
    /** @type {Compile | null} */
    #compile;
    /** @type {Timelines} */
    #timelines;
    /** @type {(k: number) => Promise<Result[]>} */
    #move;
    #emits = 0;

    /**
     * @param {SessionState} state
     * @param {{ ds: Ds, compile: Compile | null }} ports
     * @param {Timelines} timelines
     * @param {(k: number) => Promise<Result[]>} move  the navigator's move
     */
    constructor(state, { ds, compile }, timelines, move) {
        this.#s = state;
        this.#ds = ds;
        this.#compile = compile;
        this.#timelines = timelines;
        this.#move = move;
    }

    /** A live `%0`'s engine timeline, or null: the state's, since a rule
        change replaces it. */
    get #live() {
        return this.#s.liveRun;
    }

    /**
     * `from here emit`, `withdraw`, `answer`, `fail`, `silence` (§4.16).
     * @param {string} word
     * @param {string} args
     * @returns {Promise<Result[]>}
     */
    async change(word, args) {
        try {
            return await this.#apply(word, args);
        } catch (err) {
            if (!(err instanceof QueryError)) throw err;
            return splitlines(err.message).map(error);
        }
    }

    /**
     * @param {string} word
     * @param {string} args
     * @returns {Promise<Result[]>}
     */
    async #apply(word, args) {
        const s = this.#s, tl = s.tl;
        if (word === "emit") {
            const queries = s.view.queries;
            if (queries === null) return [error("`from here emit` needs the program's .dsc")];
            this.#emits++;
            const prog = queries.prog;
            const [schema, slots] = await evaluateEmit({ prog, line: "emit " + args, n: this.#emits,
                                                         names: prog.names(), compile: this.#compile, ds: this.#ds });
            // The scratch engine that evaluated it filled `ts` from the machine's
            // clock. An input takes the time of the run it goes into ([LFAC.9.2]).
            const stamped = "ts" in slots;
            delete slots.ts;
            return this.#run(word, "emit", `emit ${schema} ` + slotsText(slots),
                             (run) => run.assertFact(schema, stamped ? { ...slots, ts: run.clock() } : slots),
                             { redo: { word, args } });
        }
        if (word === "withdraw") {
            const m = /^#(\d+)$/.exec(args.trim());
            if (!m) return [error("from here withdraw #N")];
            const id = BigInt(m[1]);
            const f = tl.facts.get(id);
            if (f !== undefined && f.asserted >= s.k) return this.#unassert(word, f);
            if (f === undefined || !f.liveAt(s.k)) return [error(`#${m[1]} is not a live fact`)];
            return this.#run(word, "withdraw", `withdraw ${factRef(f)}`, (run) => run.retract(id),
                             { withdrawn: f, redo: { word, fact: this.#factKey(f) } });
        }
        const trimmed = args.trim();
        const sp = trimmed.indexOf(" ");
        const head = sp < 0 ? trimmed : trimmed.slice(0, sp), rest = sp < 0 ? "" : trimmed.slice(sp + 1);
        const call = tl.calls.find((c) => String(c.number) === head);
        if (call === undefined || call.issued >= s.k) return [error(`no call ${head} at point; \`calls all\` lists them`)];
        const answered = call.repliedAt(s.k);
        // A call that does not wait may still fail, if it has a corr (§4.10).
        const open = call.waitingAt(s.k) || (!call.waits && call.corr !== null && !answered
                                              && (call.resolved === null || call.resolved >= s.k));
        if (word === "silence" && !answered) return [error(`call ${head} has no reply to silence`)];
        if (!answered && !open)
            return [error(`call ${head} was ${call.outcome}; there is no reply to replace`)];
        if (word === "answer" && !call.waits)
            return [error(call.corr === null ? `call ${head} has no corr, so no response can name it`
                : `${call.service} declares no response: \`fail\` call ${head}, or nothing`)];
        const schema = word === "answer" ? tl.services.get(call.service)?.response ?? null
            : word === "fail" ? "CallError" : null;
        if (word === "answer" && schema === null)
            return [error(`the program declares no service ${call.service}, so call ${head} cannot be answered`)];
        const info = schema === null ? null : this.#schemaOf(schema);
        if (schema !== null && info === null)
            return [error(schema === "CallError" ? "the program has no rule reading CallError, so it cannot be failed"
                : `the program has no schema ${schema}, so call ${head} cannot be answered`)];
        /** @type {Result[]} */
        const out = [];
        // The recorded reply's record: a replied call has one (Call.repliedAt).
        const reply = answered ? /** @type {number} */ (call.resolved) : null;
        if (reply !== null) {
            // §4.10: replacing a reply forks at the settled point before the
            // recorded one, with that record on the skip list.
            out.push(...await this.#move(reply));
            out.push({ type: "note", text: "point moved to the settled point before the recorded reply" });
        }
        /** @type {Act} */
        let act = () => null;
        if (schema !== null && info !== null) {
            const clock = s.tl.clockAt(s.k);
            /** @type {Array<[string, ReplyField]>} */
            let fields;
            /** @type {Record<string, SlotValue>} */
            let slots;
            if (word === "answer") {
                // The response schema's slots, as a reply on the calls
                // socket gives them (DSDB.md §9.1). An answered call waits,
                // so it has a corr (Call.waits).
                /** @type {Record<string, CellValue>} */
                let typed;
                try {
                    typed = responseSlots(rest || "{}", info, /** @type {string} */ (call.corr));
                } catch (err) {
                    if (!(err instanceof ReplyError)) throw err;
                    return [...out, error(`not a response of ${schema}: ${err.message}`)];
                }
                fields = Object.entries(typed).map(([k, v]) => [k, { value: v }]);
                slots = typed;
            } else {
                const code = /code:\s*"([^"]*)"/.exec(rest), msg = /message:\s*"([^"]*)"/.exec(rest);
                fields = [["corr", { str: call.corr }], ["code", { str: code ? code[1] : "" }],
                          ["message", { str: msg ? msg[1] : "" }], ["ts", { int: clock }]];
                slots = { corr: call.corr, code: code ? code[1] : "", message: msg ? msg[1] : "", ts: Number(clock) };
            }
            out.push({ type: "replyEmit", schema, fields });
            act = (run) => run.assertFact(schema, slots);
        }
        // Answering a waiting call is an input like any emit; replacing or
        // silencing a recorded reply is the prompt's `r` (§4.9).
        out.push(...this.#run(word, answered ? "reply" : "emit",
                              `${word} call ${call.number} (${call.service} as ${value(call.corr)})`, act,
                              { skipAt: reply,
                                redo: { word, args: rest, call: { service: call.service, corr: call.corr } } }));
        return out;
    }

    /**
     * An inject from a debugger (`ds dap`, [NDBG.14.13]): a fact of `schema`
     * whose slots are `row`, the text of one JSON object typed as a row of the
     * schema is in a fact file. It takes its schema's lifetime: no public
     * entry point sets a per-fact TTL. It lands where `emit` does:
     * at a live `%0`'s end, or in a hypothesis.
     * @param {string} schema
     * @param {string} row
     * @returns {Result[]}
     */
    inject(schema, row) {
        const info = this.#schemaOf(schema);
        if (info === null) return [error(`no schema '${schema}'`)];
        /** @type {Record<string, CellValue>} */
        let slots;
        try {
            slots = typeSlots(scanObject(row, "slots"), info, "slots");
        } catch (err) {
            if (!(err instanceof FactFileError)) throw err;
            return [error(err.message)];
        }
        return this.#run("emit", "emit", `emit ${schema} ` + slotsText(slots), (run) => run.assertFact(schema, slots));
    }

    /**
     * `withdraw #N` from a point before `#N` was asserted (§4.16): its input
     * never happens. Point moves to the settled point just before that input,
     * and a hypothesis forks there with the input on its skip list, as a
     * replaced reply's is (§4.10). A rule-derived fact has no input to skip.
     * @param {string} word
     * @param {Fact} f
     * @returns {Promise<Result[]>}
     */
    async #unassert(word, f) {
        if (f.origin !== "integrator")
            return [error(`#${f.factId} is derived by rule ${f.rule}, not an input: withdraw an input behind it, or edit the rule`)];
        const tl = this.#s.tl;
        const out = [...await this.#move(tl.prevSettled(f.asserted + 1) ?? f.asserted)];
        out.push({ type: "note", text: `point moved to the settled point before ${factRef(f)}'s input, which will not happen` });
        out.push(...this.#run(word, "withdraw", `withdraw ${factRef(f)} before it was asserted`, () => null,
                              { skipAt: f.asserted, redo: { word, fact: this.#factKey(f) } }));
        return out;
    }

    /**
     * How a change names a fact so it can be found again once the program
     * changes and ids with it (§4.16): an input by its place among the
     * inputs, a derived fact by its schema and slots.
     * @param {Fact} f
     * @returns {FactKey}
     */
    #factKey(f) {
        const tl = this.#s.tl;
        if (f.origin === "integrator")
            return { input: tl.records.slice(0, f.asserted).filter((r) => r.kind === "FactAssert").length };
        return { schema: f.schema, slots: slotsText(f.slots) };
    }

    /**
     * The program's schema called `name`, from the engine at point, or null.
     * A schema the program does not register is null: CallError exists only
     * when a rule reads it (§4.10).
     * @param {string} name
     * @returns {SchemaInfo | null}
     */
    #schemaOf(name) {
        if (this.#live !== null) return this.#live.schema(name);
        const h = this.#s.view.hyp;
        if (h !== null) return h.run.schema(name);
        return this.#timelines.programEngine().run.schema(name);
    }

    /**
     * Apply a change where §4.9's table says, and record it as `kind` (emit,
     * withdraw or reply) on the hypothesis it lands in.
     * @param {string} word
     * @param {string} kind
     * @param {string} text  what the shell says the change was
     * @param {Act} act
     * @param {{ skipAt?: number | null, withdrawn?: Fact | null, redo?: Omit<Redo, "at"> | null }} [opts]
     * @returns {Result[]}
     */
    #run(word, kind, text, act, { skipAt = null, withdrawn = null, redo = null } = {}) {
        // Where the change is made, by the point's name: an all-time edit
        // makes it again there (§4.16).
        const at = this.#s.tl.name(this.#s.k);
        let got;
        try {
            // The command as typed, for a refusal's message (§4.16).
            got = this.#timelines.target(`from here ${word}`, skipAt);
        } catch (err) {
            if (!refusal(err)) throw err;
            return [error(`cannot fork here: ${err.message}`)];
        }
        if (got.refused) return got.refused;
        const { run, h, upto } = got;
        const out = [...got.results];
        const before = run.tl.length;
        try {
            if (act(run) === false) return [...out, error("nothing to withdraw")];
        } catch (err) {
            if (!refusal(err)) throw err;
            return [...out, error(`refused: ${err.message}`)];
        }
        if (h !== null) h.changes.push([kind, text, before, redo === null ? null : { ...redo, at }]);
        if (withdrawn !== null) {
            for (const r of run.tl.records.slice(before))
                if (is(r, "FactEmit") && r.body.schema_name === withdrawn.schema)
                    out.push({ type: "note", text: `${r.body.schema_name}#${r.body.fact_id} asserted again by `
                                                   + `rule ${r.body.rule_name}: its support still holds` });
        }
        out.push(...this.showNew(before));
        if (h !== null && upto !== null) {
            /** @type {string[]} */
            let notes;
            try {
                notes = h.follow(this.#s.real, upto);
            } catch (err) {
                h.halted = [h.tl.length, message(err)];
                return [...out, error(`%${h.number} halted: ${message(err)}`)];
            }
            for (const n of notes) out.push({ type: "note", text: `note: ${n}` });
            this.#s.k = h.tl.length;
            out.push({ type: "recomputed", tl: h.tl, k: this.#s.k });
        }
        return out;
    }

    /**
     * Point follows the end of the timeline; show what the input did. The
     * records are `[before, k)`, fixed now: a recompute that follows may
     * append more before the result is rendered.
     * @param {number} before
     * @returns {Result[]}
     */
    showNew(before) {
        const s = this.#s;
        s.k = s.tl.length;
        return [{ type: "newRecords", tl: s.tl, from: before, k: s.k }];
    }

    /**
     * `n` at the end of an engine's timeline: a live `%0` pumps once (§3.5);
     * a hypothesis takes reality's next input (§4.9).
     * @returns {Result[]}
     */
    pump() {
        const s = this.#s, before = s.tl.length, h = s.view.hyp;
        if (h === null) {
            this.#liveEnd().pump();
            // Every pump is recorded, one that fires nothing included, so the timeline always grows by its PumpBoundary.
            // Point moves to the end with it, so `%0` stays at its end.
            if (!s.tl.records.slice(before).some((r) => r.cls === "derived")) {
                s.k = s.tl.length;
                return [error("pumped: nothing was ready")];
            }
            return this.showNew(before);
        }
        const [ok, notes] = this.#timelines.feedReality(h);
        return ok ? [...notes, ...this.showNew(before)] : notes;
    }

    /**
     * `@+D` at the end of an engine's timeline: a live `%0`'s mock clock
     * moves (§3.5); a hypothesis takes reality's inputs up to that clock
     * first (§4.9). An advance the engine refuses ([NTST.3.1]) is an error
     * for the command, and the session goes on.
     * @param {bigint} ns
     * @returns {Result[]}
     */
    advance(ns) {
        if (ns > MAX_DURATION_NS) return [error("that is longer than any Duration, 2^63 - 1 nanoseconds")];
        const s = this.#s, before = s.tl.length, h = s.view.hyp;
        try {
            if (h === null) {
                this.#liveEnd().advance(ns);
                return this.showNew(before);
            }
            const [ok, notes] = this.#timelines.advanceHypothesis(h, ns);
            return ok ? [...notes, ...this.showNew(before)] : notes;
        } catch (err) {
            if (!refusal(err)) throw err;
            return [error(message(err))];
        }
    }

    /** `%0`'s engine, for `n` and `@+D` at its end: only an engine's end
        steps (SessionState.atEngineEnd), and `%0`'s is a live session's. */
    #liveEnd() {
        if (this.#live === null) throw new TypeError("%0 is a recording: it has no engine to step");
        return this.#live;
    }
}

/**
 * @param {string} text
 * @returns {Result}
 */
const error = (text) => ({ type: "error", text });
