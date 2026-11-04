// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The session's state (DSDB.md §2): the timelines, each with its own point
// and queries, the current one, the inspector's stack and the last listing's
// rows. The collaborators read and change it; session.js routes lines to them.
// Nothing here computes or prints.
//
// Timelines are numbered as the shell names them: `%0` is the trace in replay
// (or the running session, when live), `%1` and up are hypotheses
// (DSTRACE_INTERACTIVE §3.5, §4.9).

/**
 * One timeline in the session, with its own point (§3.2) and queries.
 * @typedef {object} View
 * @property {number} n        its number: 0 for `%0`
 * @property {import("./timeline.js").Timeline} tl
 * @property {number} k        its point, a record count
 * @property {import("./hypotheses.js").Hypothesis | null} hyp  for `%1` and up
 * @property {import("./query.js").Queries | null} queries  over `tl`; null without the program
 */

/** @import { Answer, CompiledQuery } from "./query.js" */
/** @import { AlphaRow, NodeRow } from "./rete.js" */
/** @import { Call, Fact, Firing } from "./timeline.js" */
/** @import { TraceRecord } from "./trace.js" */

/**
 * A node of a derivation tree (§4.14): the fact or firing it stands for.
 * @typedef {["fact", Fact] | ["firing", Firing]} TreeItem
 */

/**
 * A row of a listing, or an entry of the inspector's stack: what kind of
 * thing it is, and the thing. The inspector reads the thing by its kind:
 * `node` is a row of `rete` (§4.13), `why` a node of a derivation tree.
 * @typedef {TreeItem | ["call", Call] | ["answer", [Answer, CompiledQuery]] | ["record", TraceRecord]
 *   | ["node", NodeRow | AlphaRow] | ["why", TreeItem]} Row
 */

/**
 * Long work's progress: how much is done of how much, and of what.
 * @typedef {(done: number, total: number, what: string) => void} Progress
 */

export class SessionState {
    /** @type {Map<number, View>} */
    views = new Map();
    cur = 0;
    /** @type {Row[]} the last listing's rows, for `N` to drill into */
    rows = [];
    /** @type {Row[]} the inspector's stack, for `up` */
    stack = [];
    /** @type {import("./timeline.js").Firing[]} the last `!` listing's firings, for `why !N` (§4.14) */
    firingRows = [];
    /** @type {bigint[] | null} the last histogram's bucket edges, nanoseconds, for `@#N` */
    edges = null;
    /** @type {import("./engine-timeline.js").EngineTimeline | null} a live `%0`'s engine timeline (§3.5),
        or null in replay. Here, not in a collaborator: a rule change at its end replaces it (§4.12). */
    liveRun = null;
    /** @type {Progress | null} called every CHECKPOINT_EVERY inputs of a replay; set by a front end for
        one command, or null (DSDB_MCP.md §10.3) */
    progress = null;

    /** Whether `%0` is a live session, not a trace. */
    get live() {
        return this.liveRun !== null;
    }

    /**
     * @param {import("./timeline.js").Timeline} tl  `%0`; point starts at its end
     * @param {number} width  the terminal's columns: how many buckets a
     *   histogram has, and so what `@#N` means, depends on it
     * @param {import("./query.js").Queries | null} [queries]  `%0`'s
     */
    constructor(tl, width, queries = null) {
        this.views.set(0, { n: 0, tl, k: tl.length, hyp: null, queries });
        this.width = width;
    }

    /**
     * Timeline `n`'s view. Every number the session hands out names one; a
     * number from the user is checked against `views` first.
     * @param {number} n
     * @returns {View}
     */
    at(n) {
        const v = this.views.get(n);
        if (v === undefined) throw new Error(`no timeline %${n}`);
        return v;
    }

    /** @returns {View} the current timeline's */
    get view() {
        return this.at(this.cur);
    }

    get tl() {
        return this.view.tl;
    }

    get k() {
        return this.view.k;
    }

    set k(v) {
        this.view.k = v;
    }

    /** `%0`, reality. */
    get real() {
        return this.at(0).tl;
    }

    /**
     * Run `fn` with timeline `n` as the current one, as if it were (§4.8).
     * @template T
     * @param {number} n
     * @param {(view: View) => T | Promise<T>} fn
     * @returns {Promise<T>}
     */
    async on(n, fn) {
        const was = this.cur;
        const view = this.at(n);
        this.cur = n;
        try {
            return await fn(view);
        } finally {
            this.cur = was;
        }
    }

    /** At the end of a timeline an engine can extend: a live `%0` or a
        hypothesis. */
    atEngineEnd() {
        const v = this.view;
        return (v.hyp !== null || (v.n === 0 && this.live)) && v.k === v.tl.length;
    }
}
