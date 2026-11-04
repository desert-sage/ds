// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Hypotheses (DSTRACE_INTERACTIVE §4.9, §8.3): a timeline forked from another
// at a settled point, with a change applied, whose future is recomputed by its
// own engine. The port of tools/dstrace_shell/hypotheses.py.
//
// A hypothesis FOLLOWS REALITY. Stepping it forward feeds it `%0`'s next step,
// its inject records through the pump that ends it, with two
// exceptions (§4.9): a recorded retract of a fact it
// no longer has, or never had, is skipped; a recorded reply is delivered only
// if it has a call waiting on that `corr`. Records on its skip list (a reply
// it replaced, §4.10) are never delivered. Each skip is reported as a note.
//
// FACT IDS. Up to the fork, a hypothesis's facts are reality's, with the same
// ids. After it, the two assign ids independently, so a reality fact fed to
// the hypothesis is mapped to the id the hypothesis gave it, which is how a
// later recorded retract of it finds it.
//
// BEHIND ITS END, a change rebuilds the hypothesis: its engine at the fork
// (kept as a checkpoint) is cloned, its own inputs are replayed up to point,
// the change is applied, and reality is fed again up to where its end was.

import { strRepr } from "../text/py.js";
import { is } from "./trace.js";

/** @import { Engine } from "@ds-lang/ds" */
/** @import { EngineTimeline } from "./engine-timeline.js" */
/** @import { Call, Timeline } from "./timeline.js" */
/** @import { TraceRecord } from "./trace.js" */

/**
 * How a change names a fact so it can be found again once the program
 * changes, and ids with it (§4.16): an input by its place among the inputs, a
 * derived fact by its schema and slots.
 * @typedef {{ input: number, schema?: undefined, slots?: undefined }
 *   | { input?: undefined, schema: string, slots: string }} FactKey
 */

/**
 * How to make a change again where it was made (§4.16): the word, its
 * arguments, the fact or call it named, and the point's name.
 * @typedef {{ word: string, args?: string, fact?: FactKey, call?: { service: string, corr: string | null },
 *     at: [bigint, number] | null }} Redo
 */

/**
 * A change applied to a hypothesis: its kind (emit, withdraw or reply), what
 * the shell says it was, the point it was applied at, and how to redo it.
 * @typedef {[string, string, number, Redo | null]} Change
 */

/**
 * A rule change that made a hypothesis's program (§4.12): its kind, the
 * rule's name, the point it was made at, and the name the rule was compiled
 * under where that differs (§8.6).
 * @typedef {{ kind: string, name: string, at: number, compiled?: string }} RuleChange
 */

export class Hypothesis {
    /** @type {Map<bigint, bigint>} reality's fact id -> this hypothesis's, for facts fed after the fork */
    ids = new Map();
    /** @type {Set<number>} %0 record indexes never to deliver here */
    skip = new Set();
    /** @type {Array<[number, number]>} `[own record index of the input, %0 record index]` per reality input fed */
    fed = [];
    /** @type {Change[]} */
    changes = [];
    /** @type {RuleChange[]} the rule changes that made this hypothesis's program (§4.12) */
    rules = [];
    background = false;
    /** @type {[number, string] | null} `[own point, message]` once an input fails */
    halted = null;
    /** %0 records considered so far */
    realK = 0;

    /**
     * @param {object} f
     * @param {number} f.number
     * @param {EngineTimeline} f.run
     * @param {Engine} f.origin  an engine clone at the fork, never driven
     * @param {number} f.source  the timeline number it forked from
     * @param {number} f.forkK  the point in `source` it forked at
     * @param {string} f.forkSeq  that point's name, for the prompt
     * @param {number} f.realStart  %0's point matching the fork
     * @param {bigint} f.floor  fact ids below this are reality's own
     * @param {Uint8Array} f.dsc  the program this hypothesis runs
     */
    constructor({ number, run, origin, source, forkK, forkSeq, realStart, floor, dsc }) {
        this.number = number;
        this.run = run;
        this.origin = origin;
        this.source = source;
        this.forkK = forkK;
        this.forkSeq = forkSeq;
        this.realStart = realStart;
        this.floor = floor;
        this.dsc = dsc;
    }

    get tl() {
        return this.run.tl;
    }

    close() {
        this.run.close();
        this.origin.close();
    }

    /** The prompt's change counts (§4.9): `+2-1 r1 a1 R1`. */
    counts() {
        /** @param {string} k */
        const n = (k) => this.changes.filter((c) => c[0] === k).length;
        let out = "";
        if (n("emit")) out += `+${n("emit")}`;
        if (n("withdraw")) out += `-${n("withdraw")}`;
        const parts = out ? [out] : [];
        if (n("reply")) parts.push(`r${n("reply")}`);
        if (n("firing")) parts.push(`a${n("firing")}`);
        if (this.rules.length) parts.push(`R${this.rules.length}`);
        return parts.join(" ");
    }

    // ── following reality ───────────────────────────────────────────────────

    /**
     * @param {bigint} realId
     * @returns {bigint | null}
     */
    ownId(realId) {
        return realId < this.floor ? realId : (this.ids.get(realId) ?? null);
    }

    /**
     * %0's record index this hypothesis has consumed up to, as of its own
     * point `k`.
     * @param {number} k
     */
    realAt(k) {
        const before = this.fed.filter(([p]) => p < k).map(([, ri]) => ri + 1);
        return before.length ? Math.max(...before) : this.realStart;
    }

    /**
     * @param {Timeline} real
     * @returns {number | null}
     */
    nextReal(real) {
        for (let i = this.realK; i < real.records.length; i++) if (real.records[i].cls === "inject") return i;
        return null;
    }

    /**
     * Feed reality's next step (§4.9): its inject records up to and including
     * the PumpBoundary that ends it, so the hypothesis lands on a settled
     * point as reality did. Returns a note for each record not
     * delivered. The caller checks nextReal first.
     * @param {Timeline} real
     * @returns {string[]}
     */
    step(real) {
        const notes = [];
        const at = this.tl.length;
        let last = null;
        for (let i = this.nextReal(real); i !== null; i = this.nextReal(real)) {
            const r = real.records[i];
            this.realK = i + 1;
            last = i;
            const why = this.withheld(r);
            if (why) notes.push(`reality's ${r.kind} at record ${i} not delivered: ${why}`);
            else {
                const own = is(r, "FactRetract") ? this.ownId(r.body.fact_id) : null;
                for (const [rec, id] of this.run.feed(r, own) ?? []) if (rec >= this.floor) this.ids.set(rec, id);
            }
            if (r.kind === "PumpBoundary") break;
        }
        if (last === null) {
            this.realK = real.records.length;
            return notes;
        }
        // The step's own record: the last inject among those it wrote, its
        // pump's, which is what the hypothesis's point lands after.
        const mine = this.tl.records.slice(at).filter((x) => x.cls === "inject").map((x) => x.index);
        this.fed.push([mine.length ? mine[mine.length - 1] : at, last]);
        return notes;
    }

    /**
     * Why reality's record `r` is not delivered here, or null (§4.9).
     * @param {TraceRecord} r
     * @returns {string | null}
     */
    withheld(r) {
        if (this.skip.has(r.index)) return "this hypothesis replaced it";
        if (is(r, "FactRetract")) {
            const own = this.ownId(r.body.fact_id);
            if (own === null) return `#${r.body.fact_id} was never in this hypothesis`;
            if (!this.run.isLive(own)) return `#${own} is already gone here`;
        }
        // A reply is an integrator assert carrying `corr`; a
        // CallError may also fail a call that does not wait (§4.10).
        if (is(r, "FactAssert")) {
            const corr = r.body.slots?.corr;
            if (typeof corr !== "string") return null;
            const end = this.tl.length;
            /** @param {Call} c */
            const failable = (c) => c.outcome === "no response" && c.corr === corr && c.issued < end;
            const waiting = this.tl.waitingCalls(end).some((c) => c.corr === corr);
            if (!waiting && !(r.body.schema_name === "CallError" && this.tl.calls.some(failable)))
                return `no call waiting on corr ${strRepr(corr)} here`;
        }
        return null;
    }

    /**
     * Feed every reality step that begins before `upto` (§4.9 `bg`).
     * @param {Timeline} real
     * @param {number} upto
     * @returns {string[]}
     */
    follow(real, upto) {
        const notes = [];
        while (this.halted === null) {
            const i = this.nextReal(real);
            if (i === null || i >= upto) break;
            notes.push(...this.step(real));
        }
        return notes;
    }
}
