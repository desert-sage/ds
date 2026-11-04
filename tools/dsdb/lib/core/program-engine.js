// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// `%0`'s program engine in replay (DSTRACE_INTERACTIVE §8.2): the port of
// engines.py's ProgramEngine and signature.
//
// The real program, fed the trace's inject records in order, as libds's
// replayer applies them (§10.3): a pump wherever the trace has one.
// Derived records are not fed: the engine re-derives them, into its own
// recording, and each is checked against the trace's. The first difference
// marks the timeline UNRELIABLE from that record (§6). Every CHECKPOINT_EVERY
// steps it keeps a clone, so an engine at an earlier point is a restore and a
// short replay, not a rebuild.
//
// A changed program (§8.6) is replayed the same way, over the timeline it
// changes, with `loose` checking and the timeline's rule `aliases`.

import { EngineTimeline, applyInject, cloneEngine, freshEngine } from "./engine-timeline.js";
import { INPUT, is } from "./trace.js";

/** @import { Engine } from "@ds-lang/ds" */
/** @import { Timeline } from "./timeline.js" */
/** @import { TraceRecord } from "./trace.js" */
/** @import { Ds } from "./types.js" */

export const CHECKPOINT_EVERY = 256;
const PROGRESS = "the program engine replaying the trace's inputs";

/**
 * What the self-check compares of a derived record (§8.2), as a string, or
 * null for a record it does not compare. `loose` is §8.6's check of a changed
 * program replayed: fact ids, schemas, rule names and withdrawals, but no
 * timetags, because the gates' extra network may number activations
 * differently while behaving the same.
 * @param {TraceRecord} r
 * @param {boolean} [loose]
 * @returns {string | null}
 */
export function signature(r, loose = false) {
    if (is(r, "FactEmit")) return `('emit', ${r.body.fact_id}, '${r.body.schema_name}')`;
    if (is(r, "RuleFireAnnotation") && !r.body.end)
        return `('fire', '${r.body.rule_name}', ${loose ? "None" : r.body.timetag})`;
    if (is(r, "CallIssued")) return `('call', ${loose ? "None" : r.body.timetag}, '${r.body.correlation}')`;
    if (loose && is(r, "FactWithdraw")) return `('withdraw', ${r.body.fact_id}, ${r.body.cause ?? "None"})`;
    return null;
}

export class ProgramEngine {
    /** @type {[number, string] | null} `[record index, message]` of the first difference, or null (§6) */
    unreliable = null;
    /** The point of `real` the engine is at. */
    k = 0;
    /** @type {Timeline} */
    #real;
    /** @type {boolean} */
    #loose;
    #steps = 0;             // steps begun: inject records through their pump
    #stepStart = true;      // the next inject record begins a step
    /** @type {Array<[number, Engine]>} [settled point, engine clone] */
    #checkpoints = [];
    /** @type {Array<[number, string]>} [record index, signature] */
    #realSigs = [];
    #ownSigs = 0;
    #realSeen = 0;
    /** @type {((done: number, total: number, what: string) => void) | null} */
    #progress;
    /** @type {Map<bigint, bigint>} a recorded fact id -> the engine's, where an input bound one
        ([RFCS.24.2]): what a FactRetract's recorded id is retracted by. A clone keeps its
        source's ids, so one map serves the run and every checkpoint. */
    #ids = new Map();

    /**
     * @param {Ds} ds
     * @param {Uint8Array} dsc  the program
     * @param {Timeline} real  the timeline it replays
     * @param {{ loose?: boolean, aliases?: Map<string, string>,
     *           progress?: ((done: number, total: number, what: string) => void) | null }} [opts]
     */
    constructor(ds, dsc, real, { loose = false, aliases = new Map(), progress = null } = {}) {
        this.#real = real;
        this.#loose = loose;
        this.#progress = progress;
        this.run = new EngineTimeline(ds, freshEngine(ds, dsc), { aliases, services: real.services, dsc });
    }

    close() {
        for (const [, cp] of this.#checkpoints) cp.close();
        this.#checkpoints = [];
        this.run.close();
    }

    /** Drive forward to settled point `k` of the trace, saying how far every
        CHECKPOINT_EVERY inputs to the `progress` hook, if any.
        @param {number} k */
    to(k) {
        const recs = this.#real.records.slice(this.k, k);
        const total = this.#progress === null ? 0 : recs.filter((r) => INPUT.has(r.kind)).length;
        let done = 0;
        for (const r of recs) {
            if (r.cls !== "inject") continue;
            // A checkpoint is taken only where a step begins, the engine
            // settled. Taken inside a step, it would be keyed at the
            // step's settled point while holding the step's first records,
            // and engineAt would apply them twice.
            if (this.#stepStart) {
                if (this.#steps % CHECKPOINT_EVERY === 0) {
                    const at = this.#real.prevSettled(r.index + 1);
                    this.#checkpoints.push([at ?? r.index, cloneEngine(this.run.eng)]);
                }
                this.#steps++;
            }
            this.#stepStart = r.kind === "PumpBoundary";
            for (const [rec, id] of this.run.feed(r, this.#own(r)) ?? []) this.#ids.set(rec, id);
            if (INPUT.has(r.kind) && ++done % CHECKPOINT_EVERY === 0 && done < total)
                this.#progress?.(done, total, PROGRESS);
        }
        if (total >= CHECKPOINT_EVERY) this.#progress?.(total, total, PROGRESS);
        this.k = Math.max(this.k, k);
        this.check();
    }

    /**
     * A new engine at settled point `k`: a clone, the caller's to close.
     * @param {number} k
     * @returns {Engine}
     */
    engineAt(k) {
        if (k >= this.k) {
            this.to(k);
            return cloneEngine(this.run.eng);
        }
        /** @type {Array<[number, Engine]>} */
        let before = this.#checkpoints.filter(([p]) => p <= k);
        if (!before.length)             // before the first input: a fresh engine
            before = this.#checkpoints.length ? [[0, this.#checkpoints[0][1]]] : [];
        const [at, cp] = before.reduce((a, b) => (b[0] > a[0] ? b : a));
        const eng = cloneEngine(cp);
        for (const r of this.#real.records.slice(at, k)) if (r.cls === "inject") applyInject(eng, r, this.#own(r));
        return eng;
    }

    /**
     * The engine's id for the fact a FactRetract names, where an input bound
     * the recorded one to another; else null, and the recorded id is used.
     * @param {TraceRecord} r
     * @returns {bigint | null}
     */
    #own(r) {
        return is(r, "FactRetract") ? (this.#ids.get(BigInt(r.body.fact_id)) ?? null) : null;
    }

    /** Compare what the engine derived with what the trace recorded, in
        order, up to where the engine is (§8.2). */
    check() {
        if (this.unreliable !== null) return;
        for (const r of this.#real.records.slice(this.#realSeen, this.k)) {
            const s = signature(r, this.#loose);
            if (s !== null) this.#realSigs.push([r.index, s]);
        }
        this.#realSeen = Math.max(this.#realSeen, this.k);
        const own = this.run.tl.records.map((r) => signature(r, this.#loose)).filter((s) => s !== null);
        for (let i = this.#ownSigs; i < Math.max(own.length, this.#realSigs.length); i++) {
            const want = i < this.#realSigs.length ? this.#realSigs[i] : null;
            const got = i < own.length ? own[i] : null;
            if (want === null || got !== want[1]) {
                const at = want ? want[0] : this.k;
                this.unreliable = [at, `the trace has ${want ? want[1] : "nothing"}, the program engine ${got ?? "nothing"}`];
                return;
            }
        }
        this.#ownSigs = own.length;
    }
}
