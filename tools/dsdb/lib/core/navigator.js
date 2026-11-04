// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Moving point (DSTRACE_INTERACTIVE §4.5): `@…` navigation, `n` and `p`
// steps, and what a move reports. The port of shell.py's do_nav, do_step and
// move. Returns results; prints nothing.
//
// Points are Numbers; clocks and durations BigInt nanoseconds.

import { is } from "./trace.js";

/** @import { Cmd } from "./grammar.js" */
/** @import { SessionState } from "./state.js" */
/** @import { Fact } from "./timeline.js" */
/** @import { Result } from "./types.js" */

/**
 * What `n` and `@+D` do at the end of an engine's timeline (§3.5, §4.9).
 * @typedef {{ pump: () => Result[] | Promise<Result[]>, advance: (ns: bigint) => Result[] | Promise<Result[]> }} EngineEnd
 */

export class Navigator {
    /** @type {SessionState} */
    #s;
    /** @type {() => Fact | null} */
    #fact;
    /** @type {(old: number, now: number) => Promise<Result[]>} */
    #watch;
    /** @type {EngineEnd} */
    #end;

    /**
     * @param {SessionState} state
     * @param {() => Fact | null} currentFact  the inspector's fact, for `@[` and `@]`
     * @param {(old: number, now: number) => Promise<Result[]>} watchDiff
     *   what a move did to the watched query's answers (§4.5)
     * @param {EngineEnd} engineEnd
     */
    constructor(state, currentFact, watchDiff, engineEnd) {
        this.#s = state;
        this.#fact = currentFact;
        this.#watch = watchDiff;
        this.#end = engineEnd;
    }

    /**
     * Point to `k`: where it is now, what the move did to the watched
     * answers, and the calls issued on the way there (§4.10). Results:
     * `where`, then `watchDiff` and `issued` when there are any.
     * @param {number} k
     * @returns {Promise<Result[]>}
     */
    async move(k) {
        const s = this.#s;
        const old = s.k;
        s.k = k;
        /** @type {Result[]} */
        const out = [{ type: "where", tl: s.tl, k }, ...await this.#watch(old, k)];
        if (k > old) {
            const issued = s.tl.calls.filter((c) => old <= c.issued && c.issued < k);
            if (issued.length)
                out.push({ type: "issued", tl: s.tl, k, calls: issued.slice(0, 10), more: Math.max(0, issued.length - 10) });
        }
        return out;
    }

    /**
     * `@…` (§4.5).
     * @param {Cmd} c  a nav
     * @returns {Promise<Result[]>}
     */
    async nav(c) {
        const s = this.#s, tl = s.tl;
        const t0 = tl.clockAt(0);
        // grammar.js's amount: a count for rel_pos and bucket, nanoseconds for the clocks.
        const count = /** @type {number} */ (c.amount), ns = /** @type {bigint} */ (c.amount);
        switch (c.nav) {
        case "show":
            return [{ type: "where", tl, k: s.k, timeline: s.cur }];
        case "end":
            return this.move(tl.length);
        case "start":
            return this.move(0);
        case "abs_pos": {
            const pos = c.pos;
            if (pos === null) return [];                        // grammar.js gives abs_pos its position
            const got = tl.resolve(pos.seq, pos.minus);
            if (got === null) return [{ type: "pastEnd", tl }];
            const [k, exact] = got;
            /** @type {Result[]} */
            const out = [];
            if (!exact && pos.minus === 0) out.push({ type: "noSeq", seq: pos.seq });
            return [...out, ...await this.move(k)];
        }
        case "rel_pos":
            return this.move(Math.max(0, Math.min(tl.length, s.k + count)));
        case "abs_clock":
            return this.move(tl.firstAtClock(t0 + ns));
        case "rel_clock": {
            // §3.5, §4.9: past the end of an engine's timeline, time moves
            // when the user moves it.
            if (ns > 0n && s.atEngineEnd()) return this.#end.advance(ns);
            const target = tl.clockAt(s.k) + ns;
            if (ns >= 0n) return this.move(tl.firstAtClock(target));
            let last = null;
            for (let k = 0; k <= tl.length; k++) if (tl.clockAt(k) <= target) last = k;
            return this.move(last ?? 0);
        }
        case "bucket":
            if (!s.edges || count >= s.edges.length - 1)
                return [error("no histogram bucket with that number; draw one with `#:`")];
            return this.move(tl.firstAtClock(s.edges[count]));
        case "fact_asserted":
        case "fact_ended": {
            const f = this.#fact();
            if (f === null) return [error("`@[` and `@]` need a fact in the inspector")];
            const i = c.nav === "fact_asserted" ? f.asserted : f.ended;
            if (i === null) return [error("this fact has not ended")];
            return this.move(i + 1);
        }
        }
        return [];
    }

    /**
     * `n` and `p`, by settled point (`pump`), record, firing or clock tick.
     * @param {Cmd} c  a step
     * @returns {Promise<Result[]>}
     */
    async step(c) {
        const s = this.#s, tl = s.tl, k = s.k, forward = c.word === "n";
        if (c.args === "pump" && forward && s.atEngineEnd())    // §3.5, §4.9: `n` at the end
            return this.#end.pump();
        let nk;
        if (c.args === "pump") {
            if (!tl.canonical) {
                return [note("settled points unknown for this trace; stepping one record"),
                        ...await this.move(Math.max(0, Math.min(tl.length, k + (forward ? 1 : -1))))];
            }
            nk = forward ? tl.nextSettled(k) : tl.prevSettled(k);
        } else if (c.args === "atom") {
            nk = k + (forward ? 1 : -1);
        } else {
            const want = c.args === "fire" ? "RuleFireAnnotation" : "ClockAdvance";
            const after = tl.records.filter((r) => is(r, want) && !(is(r, "RuleFireAnnotation") && r.body.end))
                .map((r) => r.index + 1).filter((i) => (forward ? i > k : i < k));
            nk = after.length ? (forward ? Math.min(...after) : Math.max(...after)) : null;
        }
        if (nk === null || nk < 0 || nk > tl.length)
            return [error(`no ${forward ? "next" : "previous"} ${c.args === "pump" ? "settled point" : c.args}`)];
        return this.move(nk);
    }
}

/**
 * @param {string} text
 * @returns {Result}
 */
const note = (text) => ({ type: "note", text });
/**
 * @param {string} text
 * @returns {Result}
 */
const error = (text) => ({ type: "error", text });
