// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Timelines (DSTRACE_INTERACTIVE §4.9, §8.1–§8.3): the program engine, forking
// a hypothesis, rebuilding one behind its end, where a change applies, feeding
// hypotheses reality, `%0` run again under an edited program (§4.16), and the
// timeline commands (`hyp`, `fg`, `real`, `bg`, `stop`, `fork`, `kill`,
// `match`, `save`, `changes`). The port of shell.py's hypotheses half.
// Returns results; prints nothing.

import { EngineTimeline, applyInject, cloneEngine, freshEngine } from "./engine-timeline.js";
import { Hypothesis } from "./hypotheses.js";
import { read as readProgram } from "./program.js";
import { CHECKPOINT_EVERY, ProgramEngine } from "./program-engine.js";
import { Queries } from "./query.js";
import { fileProblem } from "./files.js";
import { INPUT, is } from "./trace.js";

/** @import { Engine, MatchStep } from "@ds-lang/ds" */
/** @import { RuleChange } from "./hypotheses.js" */
/** @import { Program } from "./program.js" */
/** @import { SessionState, View } from "./state.js" */
/** @import { Fact } from "./timeline.js" */
/** @import { TraceRecord } from "./trace.js" */
/** @import { Compile, Ds, Result, TimelineRow } from "./types.js" */

/**
 * What the timelines are given (DSDB.md §3): the `@ds-lang/ds` API, the
 * compiler, the program's source as `[file, text]`, the trace's bytes in
 * replay, and somewhere to `save` to.
 * @typedef {{ ds: Ds, compile: Compile | null, source: Array<[string, string]>, stream: (() => Uint8Array) | null,
 *     write: ((path: string, bytes: Uint8Array) => void) | null }} Ports
 */

/**
 * Where a change applies (`target`): the engine timeline, the hypothesis it
 * lands in (null for a live `%0`), the `%0` position to recompute to after a
 * rebase, and what was said on the way; or the refusal.
 * @typedef {{ run: EngineTimeline, h: Hypothesis | null, upto: number | null, results: Result[], refused?: undefined }
 *   | { refused: Result[] }} Target
 */

/**
 * @param {string} text
 * @returns {Result}
 */
const error = (text) => ({ type: "error", text });
/**
 * @param {string} text
 * @returns {Result}
 */
const note = (text) => ({ type: "note", text });
/** @param {unknown} err */
const message = (err) => (err instanceof Error ? err.message : String(err));

/**
 * View `v`'s queries, and with them its program. Every timeline an engine
 * runs has them: an engine needs the program, and a session given one gives
 * every view queries.
 * @param {View} v
 */
function queriesOf(v) {
    if (v.queries === null) throw new TypeError(`%${v.n} has no program`);
    return v.queries;
}

/**
 * Compiled rule name -> the name the user gave it (§8.6).
 * @param {RuleChange[]} rules
 * @returns {Map<string, string>}
 */
export function aliases(rules) {
    /** @type {Map<string, string>} */
    const out = new Map();
    for (const c of rules) if (c.compiled && c.compiled !== c.name) out.set(c.compiled, c.name);
    return out;
}

export class Timelines {
    /** @type {SessionState} */
    #s;
    /** @type {Ds} */
    #ds;
    /** @type {Ports["compile"]} */
    #compile;
    /** @type {Ports["stream"]} */
    #stream;
    /** @type {Ports["write"]} */
    #write;
    /** @type {{ currentFact: () => Fact | null }} */
    #hooks;
    /** @type {ProgramEngine | null} */
    #program = null;
    #nextN = 1;
    /** @type {Array<[string, string]>} */
    #source;
    /** @type {EngineTimeline | null} Replay's `%0` once an edit rebuilt it (§4.16), or null. */
    #run0 = null;
    /** @type {WeakMap<Uint8Array, Array<[string, string]>>} `.dsc` -> the source it embeds */
    #sources = new WeakMap();
    /** @type {Uint8Array | null} `%0`'s program once an edit changed it (§4.16). */
    dsc0 = null;
    /** @type {RuleChange[]} Rule changes from a point, withdrawn (§4.16): always empty now, and
        with them every hypothesis's `rules` and every alias map. */
    rules0 = [];

    /**
     * @param {SessionState} state
     * @param {Ports} ports
     * @param {{ currentFact: () => Fact | null }} hooks
     */
    constructor(state, { ds, compile, source, stream, write }, hooks) {
        this.#s = state;
        this.#ds = ds;
        this.#compile = compile;
        this.#source = source;
        this.#stream = stream;
        this.#write = write;
        this.#hooks = hooks;
    }

    /** A live `%0`'s engine timeline, or null: the state's, since a rule
        change at its end replaces it. */
    get #live() {
        return this.#s.liveRun;
    }

    close() {
        for (const v of this.#s.views.values()) if (v.hyp !== null) {
            v.hyp.close();
            v.queries?.close();
        }
        this.#program?.close();
        this.#run0?.close();
    }

    // ── the program engine, and engines at a point (§8.1–§8.3) ──────────────

    /** `%0`'s program engine (§8.1): over the trace in replay, or over the
        session's own record when live, with the rules `%0` now has. */
    programEngine() {
        if (this.#program === null)
            this.#program = new ProgramEngine(this.#ds, this.programOf(0), this.#s.real,
                                              { loose: this.rules0.length > 0, aliases: aliases(this.rules0),
                                                progress: (...a) => this.#s.progress?.(...a) });
        return this.#program;
    }

    /**
     * @param {number} n
     * @returns {Uint8Array}
     */
    programOf(n) {
        const h = this.#s.at(n).hyp;
        return h !== null ? h.dsc : (this.dsc0 ?? queriesOf(this.#s.at(0)).prog.dsc);
    }

    /**
     * @param {number} n
     * @returns {RuleChange[]}
     */
    rulesOf(n) {
        const h = this.#s.at(n).hyp;
        return h !== null ? h.rules : this.rules0;
    }

    /**
     * The source timeline `n`'s program embeds (§10.11), `[file, text]`; the
     * session's own (`-L`) for the program when it was stripped. A changed
     * program embeds its staged source, gates and renamed rules included.
     * @param {number} n
     * @returns {Array<[string, string]>}
     */
    sourcesOf(n) {
        const dsc = this.programOf(n);
        let src = this.#sources.get(dsc);
        if (src === undefined) {
            src = readProgram(this.#ds, dsc).sources;
            if (!src.length && dsc === queriesOf(this.#s.at(0)).prog.dsc) src = this.#source ?? [];
            this.#sources.set(dsc, src);
        }
        return src;
    }

    /**
     * §6: the self-check of the engine a replay hypothesis came from.
     * `[record index, message]` or null.
     * @param {Hypothesis} h
     * @returns {[number, string] | null}
     */
    unreliable(h) {
        if (this.#live !== null || this.#program === null) return null;
        const u = this.#program.unreliable;
        return u !== null && u[0] < h.realStart ? u : null;
    }

    /**
     * `%0` again under a new program (§4.16): a fresh engine fed `%0`'s
     * inputs in order. Fact ids may differ under it, so an integrator's
     * retract is mapped from the old id to the new. An input the program no
     * longer takes is skipped. In replay the recording is not changed; `%0` is
     * now this run. Hypotheses are the caller's to rebuild.
     * @param {Uint8Array} dsc
     * @param {Program} prog  its declarations, for queries
     * @returns {Array<[TraceRecord, string]>} each skipped input and why
     */
    rebuild0(dsc, prog) {
        const s = this.#s, v = s.at(0);
        const run = new EngineTimeline(this.#ds, freshEngine(this.#ds, dsc), { services: prog.services, dsc });
        /** @type {Map<bigint, bigint | null>} */
        const ids = new Map();
        /** @type {Array<[TraceRecord, string]>} */
        const skipped = [];
        // Every inject record is applied, clock samples and pumps among them;
        // progress counts the inputs.
        const total = v.tl.records.filter((r) => INPUT.has(r.kind)).length;
        let done = 0;
        /** @param {number} n */
        const said = (n) => s.progress?.(n, total, "%0 run again from its inputs under the new program");
        for (const r of v.tl.records) {
            if (r.cls !== "inject") continue;
            if (INPUT.has(r.kind)) {
                if (done > 0 && done % CHECKPOINT_EVERY === 0) said(done);
                done++;
            }
            try {
                if (is(r, "FactRetract")) {
                    const id = ids.get(r.body.fact_id);
                    if (id === undefined) {
                        skipped.push([r, "it retracts a fact the program no longer has"]);
                        continue;
                    }
                    run.feed(r, id);
                } else {
                    for (const [rec, id] of run.feed(r) ?? []) ids.set(rec, id);
                }
            } catch (err) {
                if (!(err instanceof Error && (err.name === "DsError" || err.constructor === Error))) throw err;
                skipped.push([r, err.message]);
            }
        }
        if (total >= CHECKPOINT_EVERY) said(total);
        if (this.#live !== null) {
            this.#live.close();
            s.liveRun = run;
        } else {
            this.#run0?.close();
            this.#run0 = run;
        }
        v.tl = run.tl;
        v.queries?.close();
        v.queries = new Queries(this.#ds, prog, run.tl, this.#compile);
        this.dsc0 = dsc;
        this.rules0 = [];
        this.#program?.close();
        this.#program = null;
        return skipped;
    }

    /**
     * Timeline `n`'s stream and the offset of each record in it, or null.
     * @param {number} n
     * @returns {[Uint8Array, number[]] | null}
     */
    image(n) {
        const v = this.#s.at(n);
        if (v.hyp !== null) return v.hyp.run.image();
        if (this.#live !== null) return this.#live.image();
        if (this.#run0 !== null) return this.#run0.image();
        if (this.#stream === null) return null;
        return [this.#stream(), v.tl.records.map((r) => r.offset)];
    }

    /**
     * The image cut at point `k`: what a fork of `n` there starts with.
     * @param {number} n
     * @param {number} k
     * @returns {[Uint8Array, number[]]}
     */
    imageUpto(n, k) {
        const img = this.image(n);
        if (img === null) return [new Uint8Array(0), new Array(k).fill(0)];
        const [data, offs] = img;
        return [k < offs.length ? data.slice(0, offs[k]) : data, offs.slice(0, k)];
    }

    /**
     * @param {number} n
     * @param {number} k
     * @returns {Uint8Array | null}
     */
    streamUpto(n, k) {
        return this.image(n) === null ? null : this.imageUpto(n, k)[0];
    }

    /**
     * A new engine at settled point `k` of timeline `n` (§8.2, §8.3). The
     * caller owns it.
     * @param {number} n
     * @param {number} k
     * @returns {Engine}
     */
    engineAt(n, k) {
        const v = this.#s.at(n), h = v.hyp;
        if (h === null) {
            if (this.#live !== null && k === v.tl.length) return cloneEngine(this.#live.eng);
            return this.programEngine().engineAt(k);
        }
        if (k < h.forkK) return this.engineAt(h.source, k);
        if (k === h.tl.length) return cloneEngine(h.run.eng);
        if (k >= h.run.base) {
            const eng = cloneEngine(h.origin);
            for (const r of h.tl.records.slice(h.run.base, k)) if (r.cls === "inject") applyInject(eng, r);
            return eng;
        }
        // Before a rebase (§8.6): the hypothesis's own program, replayed.
        const pe = new ProgramEngine(this.#ds, h.dsc, h.tl, { loose: h.rules.length > 0, aliases: aliases(h.rules) });
        try {
            return pe.engineAt(k);
        } finally {
            pe.close();
        }
    }

    /**
     * `fn(engine)` on an engine at settled point `k` of timeline `n`, to
     * read, not drive: the running one at the end of a live `%0` or a
     * hypothesis, else a new one, closed after (§4.6 `match`, §8.7).
     * @template T
     * @param {number} n
     * @param {number} k
     * @param {(eng: Engine) => T} fn
     * @returns {T}
     */
    readEngine(n, k, fn) {
        const v = this.#s.at(n);
        /** @type {Engine} */
        let eng;
        /** @type {Engine | null} */
        let own = null;
        if (k === v.tl.length && v.hyp !== null) eng = v.hyp.run.eng;
        else if (k === v.tl.length && this.#live !== null) eng = this.#live.eng;
        else eng = own = this.engineAt(n, k);
        try {
            return fn(eng);
        } finally {
            own?.close();
        }
    }

    // ── forking, and rebuilding behind the end (§4.9, §8.3) ─────────────────

    /**
     * Fork timeline `n` at settled point `k` into a new hypothesis and make it
     * current. `skip` holds `%0` record indexes never to deliver to it. A
     * hypothesis rebuilt after an edit keeps its `number` (§4.16).
     * @param {number} n
     * @param {number} k
     * @param {Set<number>} [skip]
     * @param {{ number?: number | null }} [opts]
     * @returns {[Hypothesis, Result[]]}
     */
    openHypothesis(n, k, skip = new Set(), { number = null } = {}) {
        const s = this.#s;
        const src = s.at(n);
        if (src.hyp !== null && k < src.hyp.forkK)     // before a fork: its source's records
            return this.openHypothesis(src.hyp.source, k, skip, { number });
        const eng = this.engineAt(n, k);
        const rules = this.rulesOf(n).filter((c) => c.at < k);
        const dsc = this.programOf(n);
        const origin = cloneEngine(eng);
        const run = new EngineTimeline(this.#ds, eng, { prefix: src.tl, k, image: this.imageUpto(n, k),
                                                         aliases: aliases(rules), dsc });
        const num = number ?? this.#nextN++;
        const name = src.tl.name(k);
        const forkSeq = name ? name[0].toString(16) + "-".repeat(name[1]) : "<";
        const p = src.hyp;
        /** @type {Hypothesis} */
        let h;
        if (p === null) {
            let floor = 0n;
            for (const f of src.tl.facts.values()) if (f.asserted < k && f.factId > floor) floor = f.factId;
            h = new Hypothesis({ number: num, run, origin, source: n, forkK: k, forkSeq, realStart: k,
                                 floor: floor + 1n, dsc });
            h.skip = new Set(skip);
        } else {
            h = new Hypothesis({ number: num, run, origin, source: n, forkK: k, forkSeq,
                                 realStart: p.realAt(k), floor: p.floor, dsc });
            for (const [r, o] of p.ids) {
                const f = p.tl.facts.get(o);
                if (f !== undefined && f.asserted < k) h.ids.set(r, o);
            }
            h.skip = new Set([...p.skip, ...skip]);
            h.fed = p.fed.filter(([q]) => q < k);
            h.changes = p.changes.filter((c) => c[2] < k);
        }
        h.rules = [...rules];
        h.realK = h.realStart;
        const qs = new Queries(this.#ds, queriesOf(src).prog, run.tl, this.#compile);
        s.views.set(num, { n: num, tl: run.tl, k: run.tl.length, hyp: h, queries: qs });
        s.cur = num;
        const u = this.unreliable(h);
        return [h, [{ type: "forked", num, from: n, tl: src.tl, k, unreliable: u ? u[1] : null }]];
    }

    /**
     * Hypothesis `h` continues from its point `k` with its engine there
     * (§4.9, a change behind its end). Its records after `k` are discarded;
     * those up to `k` are kept, and the engine at `k` becomes its checkpoint.
     * @param {Hypothesis} h
     * @param {number} k
     * @returns {[number, Result[]]} the `%0` position its end had reached, to recompute up to
     */
    rebase(h, k) {
        const oldReal = h.realK, old = h.run;
        const eng = this.engineAt(h.number, k);
        h.rules = h.rules.filter((c) => c.at < k);
        const origin = cloneEngine(eng);
        const run = new EngineTimeline(this.#ds, eng, { prefix: old.tl, k, image: this.imageUpto(h.number, k),
                                                         aliases: aliases(h.rules), dsc: h.dsc });
        /** @type {Map<bigint, bigint>} */
        const kept = new Map();
        for (const [ri, o] of h.ids) {
            const f = old.tl.facts.get(o);
            if (f !== undefined && f.asserted < k) kept.set(ri, o);
        }
        h.ids = kept;
        h.fed = h.fed.filter(([q]) => q < k);
        h.changes = h.changes.filter((c) => c[2] < k);
        h.realK = h.realAt(k);
        h.run = run;
        old.close();
        h.origin.close();
        h.origin = origin;
        const v = this.#s.at(h.number);
        v.tl = run.tl;
        v.k = run.tl.length;
        const queries = queriesOf(v);
        queries.close();
        v.queries = new Queries(this.#ds, queries.prog, run.tl, this.#compile);
        /** @type {Result[]} */
        const out = k < old.tl.length ? [{ type: "discarded", num: h.number, tl: run.tl, k }] : [];
        return [oldReal, out];
    }

    /**
     * `%0`'s record index for record `i` of timeline `n`, or null when it
     * did not come from reality (an input typed into a hypothesis).
     * @param {number} n
     * @param {number} i
     * @returns {number | null}
     */
    realIndex(n, i) {
        const h = this.#s.at(n).hyp;
        if (h === null) return i;
        if (i < h.forkK) return this.realIndex(h.source, i);
        const f = h.fed.find(([q]) => q === i);
        return f ? f[1] : null;
    }

    /**
     * Where a change applies (§4.9's table). `word` is the command, for a
     * refusal's message; `skipAt` is a record of the current timeline to leave
     * out (a replaced reply, §4.10).
     * @param {string} word
     * @param {number | null} [skipAt]
     * @returns {Target}
     */
    target(word, skipAt = null) {
        const s = this.#s, v = s.view, tl = s.tl, k = s.k;
        if (v.hyp === null && this.#live !== null && k === tl.length && skipAt === null)
            return { run: this.#live, h: null, upto: null, results: [] };
        if (!tl.isSettled(k)) {
            const lo = tl.prevSettled(k), hi = tl.nextSettled(k);
            return { refused: [{ type: "midCascade", word, tl, lo: lo || 0, hi: hi ?? tl.length }] };
        }
        /** @type {Set<number>} */
        const realSkip = new Set();
        if (skipAt !== null) {
            const ri = this.realIndex(v.n, skipAt);
            if (ri !== null) realSkip.add(ri);
        }
        const h = v.hyp;
        if (h === null || k < h.forkK) {
            const [opened, results] = this.openHypothesis(v.n, k, realSkip);
            return { run: opened.run, h: opened, upto: null, results };
        }
        if (h.halted) return { refused: [error(`%${h.number} is halted: ${h.halted[1]}`)] };
        /** @type {number | null} */
        let upto = null;
        /** @type {Result[]} */
        const results = [];
        if (k < tl.length) {
            const [was, res] = this.rebase(h, k);
            upto = was;
            results.push(...res);
        }
        for (const x of realSkip) h.skip.add(x);
        return { run: h.run, h, upto, results };
    }

    // ── following reality (§4.9) ────────────────────────────────────────────

    /**
     * `n` at a hypothesis's end: reality's next input. `[ok, results]`.
     * @param {Hypothesis} h
     * @returns {[boolean, Result[]]}
     */
    feedReality(h) {
        const real = this.#s.real;
        if (h.halted) return [false, [error(`%${h.number} is halted: ${h.halted[1]}`)]];
        if (h.nextReal(real) === null) return [false, [error("reality has no more inputs; `@+D` advances the clock")]];
        try {
            return [true, h.step(real).map((n) => note(`note: ${n}`))];
        } catch (err) {
            h.halted = [h.tl.length, message(err)];
            return [false, [error(`%${h.number} halted: ${message(err)}`)]];
        }
    }

    /**
     * `@+D` at a hypothesis's end: reality's inputs up to that clock, then
     * the mock clock itself once reality has none left before it.
     * @param {Hypothesis} h
     * @param {bigint} ns
     * @returns {[boolean, Result[]]}
     */
    advanceHypothesis(h, ns) {
        const real = this.#s.real;
        const target = h.run.clock() + ns;
        /** @type {Result[]} */
        const out = [];
        for (;;) {
            const i = h.nextReal(real);
            if (i === null || real.records[i].clockNs > target) break;
            const [ok, res] = this.feedReality(h);
            out.push(...res);
            if (!ok) return [false, out];
        }
        if (h.run.clock() < target) h.run.advance(target - h.run.clock());
        return [true, out];
    }

    /**
     * §4.9 `bg`: hypotheses that follow `%0`'s point, after every command.
     * @returns {Result[]}
     */
    followBackground() {
        const s = this.#s;
        /** @type {Result[]} */
        const out = [];
        for (const v of [...s.views.values()]) {
            const h = v.hyp;
            if (h === null || !h.background || v.n === s.cur) continue;
            const before = h.tl.length;
            /** @type {string[]} */
            let notes;
            try {
                notes = h.follow(s.real, s.at(0).k);
            } catch (err) {
                h.halted = [h.tl.length, message(err)];
                out.push(error(`%${h.number} halted: ${message(err)}`));
                continue;
            }
            if (h.tl.length !== before) {
                if (v.k === before) v.k = h.tl.length;
                out.push(note(`%${h.number} follows: +${h.tl.length - before} records` + notes.map((n) => `; ${n}`).join("")));
            }
        }
        return out;
    }

    // ── the timeline commands (§4.9) ────────────────────────────────────────

    /**
     * `[n | null, results]`: the timeline `args` names.
     * @param {string} args
     * @param {number | null} [dflt]
     * @returns {[number, Result[]] | [null, Result[]]}
     */
    timelineArg(args, dflt = null) {
        const m = /^%(\d+)$/.exec(args.trim());
        if (m === null) {
            if (dflt !== null && !args.trim()) return [dflt, []];
            return [null, [error("name a timeline, as %1")]];
        }
        const n = Number(m[1]);
        if (!this.#s.views.has(n)) return [null, [error(`no timeline %${n}; \`hyp\` lists them`)]];
        return [n, []];
    }

    /**
     * `hyp`: every timeline, where it stands, and its memory.
     * @returns {Result[]}
     */
    hyp() {
        const s = this.#s;
        /** @type {TimelineRow[]} */
        const rows = [];
        for (const v of s.views.values()) {
            const h = v.hyp;
            if (h === null) {
                const run = this.#live ?? (this.#program ? this.#program.run : null);
                const mem = (run ? run.mem() : 0) + (this.streamUpto(0, v.tl.length)?.length ?? 0);
                rows.push({ n: v.n, reality: true, tl: v.tl, k: v.k,
                            extra: this.rules0.length ? "  rules: " + this.rules0.map((c) => `${c.kind} ${c.name}`).join(", ") : "",
                            mem, current: v.n === s.cur });
            } else {
                const mem = h.run.mem() + h.run.image()[0].length;
                let extra = h.background ? "background" : "stopped";
                if (h.rules.length) extra += "  rules: " + h.rules.map((c) => `${c.kind} ${c.name}`).join(", ");
                const u = this.unreliable(h);
                if (u) extra += `  unreliable at record ${u[0]}: ${u[1]}`;
                if (h.halted) extra += `  halted: ${h.halted[1]}`;
                rows.push({ n: v.n, reality: false, tl: v.tl, k: v.k, forkK: h.forkK, counts: h.counts(), extra,
                            mem, current: v.n === s.cur });
            }
        }
        return [{ type: "timelines", rows }];
    }

    /**
     * @param {string} args
     * @returns {Result[]}
     */
    fg(args) {
        const [n, refused] = this.timelineArg(args);
        if (n === null) return refused;
        const s = this.#s;
        s.cur = n;
        s.rows = [];
        s.stack = [];
        return [{ type: "where", tl: s.tl, k: s.k, timeline: n }];
    }

    /**
     * @param {string} args
     * @returns {Result[]}
     */
    bg(args) {
        const [n, refused] = this.timelineArg(args);
        if (n === null) return refused;
        const h = this.#s.at(n).hyp;
        if (h === null) return [error("%0 is reality; only a hypothesis follows it")];
        h.background = true;
        return [note(`%${n} follows %0's point from here`)];
    }

    /**
     * @param {string} args
     * @returns {Result[]}
     */
    stop(args) {
        const [n, refused] = this.timelineArg(args);
        if (n === null) return refused;
        const h = this.#s.at(n).hyp;
        if (h !== null) h.background = false;
        return [note(`%${n} stays where it is`)];
    }

    /** @returns {Result[]} */
    fork() {
        const s = this.#s;
        if (!s.tl.isSettled(s.k)) return [error("`fork` needs a settled point")];
        try {
            return this.openHypothesis(s.cur, s.k)[1];
        } catch (err) {
            return [error(`cannot fork here: ${message(err)}`)];
        }
    }

    /**
     * @param {string} args
     * @returns {Result[]}
     */
    kill(args) {
        const s = this.#s;
        const [n, refused] = this.timelineArg(args, s.cur);
        if (n === null) return refused;
        if (n === 0) return [error("%0 is reality; it cannot be killed")];
        const kids = [...s.views.values()].filter((v) => v.hyp !== null && v.hyp.source === n).map((v) => v.n);
        if (kids.length) return [error(`%${kids[0]} was forked from %${n}; kill it first`)];
        const v = s.at(n);
        s.views.delete(n);
        v.hyp?.close();
        v.queries?.close();
        if (s.cur === n) {
            s.cur = 0;
            s.rows = [];
            s.stack = [];
        }
        return [note(`%${n} closed`)];
    }

    /**
     * §4.6: the inspected fact through the alpha tests, on the engine that
     * holds it at point.
     * @returns {Result[]}
     */
    match() {
        const s = this.#s;
        const f = this.#hooks.currentFact();
        if (f === null) return [error("`match` needs a fact in the inspector")];
        if (!f.liveAt(s.k)) return [error(`#${f.factId} is not live at point`)];
        if (!s.tl.isSettled(s.k)) return [error("`match` needs a settled point")];
        /** @type {MatchStep[]} */
        let steps;
        try {
            steps = this.readEngine(s.cur, s.k, (eng) => eng.reteMatchTrace(f.factId));
        } catch (err) {
            return [error(`the engine refused: ${message(err)}`)];
        }
        if (!steps.length) return [error("(no alpha node tests this fact's schema)")];
        // pyds's keys, snake_case: the Python prints them.
        /** @param {string} k */
        const snake = (k) => k.replace(/[A-Z]/g, (c) => "_" + c.toLowerCase());
        return [{ type: "matchTrace",
                  steps: steps.map((st) => Object.entries(st).map(([k, x]) => /** @type {[string, string]} */ ([snake(k), x]))) }];
    }

    // ── changes (§4.16) ─────────────────────────────────────────────────────

    /**
     * `changes`: the current timeline's changes at a point, in the order
     * they were made, each where it was made.
     * @returns {Result[]}
     */
    changes() {
        const s = this.#s, h = s.view.hyp;
        if (h === null)
            return [note(s.live ? "%0 is the live session: its inputs are its own record, not changes"
                                : "%0 is the recording: it has no changes")];
        if (!h.changes.length) return [note(`%${h.number} has no changes yet`)];
        return [{ type: "changeList", tl: s.tl, changes: h.changes.map((c, i) => ({ n: i + 1, text: c[1], at: c[2] })) }];
    }

    /**
     * `save [%N] PATH` (§4.9): a timeline's stream, written as recorded. For
     * a hypothesis the description -- its fork and changes -- is printed and
     * not written: the stream carries no annotation.
     * @param {string} args
     * @returns {Result[]}
     */
    save(args) {
        const s = this.#s;
        const parts = args.split(/\s+/).filter(Boolean);
        let n = s.cur;
        if (parts.length && parts[0].startsWith("%")) {
            const [m, refused] = this.timelineArg(parts[0]);
            parts.shift();
            if (m === null) return refused;
            n = m;
        }
        if (parts.length !== 1) return [error("save trace [%N] PATH")];
        const path = parts[0];
        const v = s.at(n);
        /** @type {Uint8Array} */
        let data;
        /** @type {string} */
        let text;
        /** @type {Result[]} */
        let described = [];
        if (v.hyp === null) {
            if (this.#live !== null) {
                data = this.#live.dataUpto(v.tl.length);
                text = `wrote ${path}: the engine's own recording, ${data.length} bytes`
                    + (this.rules0.length ? `, under ${this.rules0.length} rule changes` : "");
            } else {
                const stream = this.streamUpto(0, v.tl.length);
                if (stream === null) return [error("%0 is the trace on disk")];
                data = stream;
                text = `wrote ${path}: the trace, ${data.length} bytes`;
            }
        } else {
            const h = v.hyp;
            data = h.run.dataUpto(v.tl.length);
            const sid = s.real.header?.session_id ?? "";
            text = `wrote ${path}: %${n}, ${data.length} bytes`;
            described = [`hypothesis %${h.number}, forked at @${h.forkSeq} of session ${sid}`,
                ...h.changes.map((c) => `${c[0]}: ${c[1]}`),
                ...h.rules.map((c) => `rule ${c.kind}: ${c.name}`)].map(note);
        }
        if (this.#write === null) return [error("nowhere to save to")];
        try {
            this.#write(path, data);
        } catch (err) {
            return [error(`${path}: ${fileProblem(err)}`)];
        }
        return [note(text), ...described];
    }
}
