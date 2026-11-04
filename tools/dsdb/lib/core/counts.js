// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The forms without a query (DSTRACE_INTERACTIVE §4.3, §4.4, §4.11): `#` facts
// per schema, `!` firings, `^` firings per rule, each at point (`.`), at a
// position (`@N`) or over time (`:`), and the histogram options. The port of
// shell.py's options, population, firings, firing_counts and draw. Returns
// results; prints nothing.
//
// Clocks and histogram edges are BigInt nanoseconds; counts are Numbers.

import { durationNs } from "./grammar.js";
import { countBuckets, edges, stepBuckets } from "./histogram.js";

/** @import { SessionState } from "./state.js" */
/** @import { Timeline } from "./timeline.js" */
/** @import { Result } from "./types.js" */

/**
 * A histogram's options: a name filter, tumbling windows, and how a step
 * series is summarised in a bucket.
 * @typedef {{ regex: RegExp | null, tumbling: bigint | null, how: "max" | "min" | "mean" }} Options
 */

/**
 * One series a histogram draws: `[label, data, peak, now]`. A step series
 * (a population) has `[clock, value]` changes as its data; any other has the
 * clocks of the events it counts, and no `now`.
 * @typedef {[string, Array<[bigint, number]> | bigint[], number, number]} Series
 */

/**
 * The histogram options off the END of a body, and a name filter when it is
 * the whole of what is left; the rest is a DS query.
 *
 * Only from the end, and a regex only alone, because a DS query may itself
 * contain `/regex/` or a slot named `max`: reading options out of its middle
 * would change the query.
 * @param {string} body
 * @returns {{ opts: Options, rest: string, error?: undefined } | { error: string }}
 */
export function options(body) {
    /** @type {Options} */
    const opts = { regex: null, tumbling: null, how: "max" };
    const toks = body.includes("\n") ? [body] : body.split(" ");
    while (toks.length) {
        const t = toks[toks.length - 1];
        if (t === "min" || t === "max" || t === "mean") {
            opts.how = t;
            toks.pop();
        } else if (toks.length >= 2 && toks[toks.length - 2] === "tumbling" && durationNs(t) !== null) {
            opts.tumbling = durationNs(t);
            toks.splice(-2);
        } else if (t === "") {
            toks.pop();
        } else break;
    }
    let rest = toks.join(" ").trim();
    if (rest.length >= 2 && rest.startsWith("/") && rest.endsWith("/") && !rest.includes(" ")) {
        try {
            opts.regex = new RegExp(rest.slice(1, -1));
        } catch (err) {
            return { error: `${rest}: ${err instanceof Error ? err.message : String(err)}` };
        }
        rest = "";
    }
    return { opts, rest };
}

/**
 * @param {string} name
 * @param {Options} opts
 */
const keep = (name, opts) => opts.regex === null || opts.regex.test(name);
/**
 * @param {[string, number]} a
 * @param {[string, number]} b
 */
const byCountThenName = (a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0);

export class Counts {
    /** @type {SessionState} */
    #s;

    /** @param {SessionState} state */
    constructor(state) {
        this.#s = state;
    }

    /**
     * `#.`, `#@N`: facts per schema at a point, on one scale, each with its
     * change since the previous settled point (not at `@N`, which is a look,
     * not a stop). `#:`: each schema's population over time.
     * @param {string} scope
     * @param {number} k
     * @param {Options} opts
     * @returns {Result[]}
     */
    population(scope, k, opts) {
        const tl = this.#s.tl;
        if (scope === "." || scope === "@") {
            const pop = [...tl.population(k)].filter(([s]) => keep(s, opts));
            const prev = scope === "." ? tl.prevSettled(k) : null;
            const before = prev !== null ? tl.population(prev) : null;
            /** @type {Array<[string, number, number]>} */
            const rows = pop.sort(byCountThenName)
                .map(([s, n]) => [s, n, before !== null ? n - (before.get(s) ?? 0) : 0]);
            return [{ type: "bars", head: "at", tl, k, rows, width: this.#s.width }];
        }
        return this.draw(this.schemaSeries(opts), opts, true);
    }

    /**
     * `!.`, `!@N`: the firings of the cascade that led to a point; `!:` all.
     * @param {string} scope
     * @param {number} k
     * @param {Options} opts
     * @returns {Result[]}
     */
    firings(scope, k, opts) {
        const s = this.#s, tl = s.tl;
        let frs;
        /** @type {{ scope: ":", count: number } | { scope: "cascade", k: number, count: number }} */
        let head;
        if (scope === ":") {
            frs = tl.firings;
            head = { scope: ":", count: frs.length };
        } else {
            const { start, stop } = tl.cascade(k);
            frs = tl.firingsIn(start, stop);
            head = { scope: "cascade", k, count: frs.length };
        }
        frs = frs.filter((f) => keep(f.rule, opts));
        s.rows = frs.map((f) => ["firing", f]);
        s.firingRows = frs;
        return [{ type: "firings", tl, head, firings: frs }];
    }

    /**
     * `^.`, `^@N`: firings per rule in the cascade to a point; `^:` each rule's
     * firings over time.
     * @param {string} scope
     * @param {number} k
     * @param {Options} opts
     * @returns {Result[]}
     */
    firingCounts(scope, k, opts) {
        const tl = this.#s.tl;
        if (scope === "." || scope === "@") {
            const { start, stop } = tl.cascade(k);
            /** @type {Array<[string, number, number]>} */
            const rows = [...tl.firingCounts(start, stop)].filter(([r]) => keep(r, opts))
                .sort(byCountThenName).map(([r, n]) => [r, n, 0]);
            return [{ type: "bars", head: "cascade", tl, k, rows, width: this.#s.width }];
        }
        const rules = [...new Set(tl.firings.filter((f) => keep(f.rule, opts)).map((f) => f.rule))].sort();
        /** @type {Series[]} */
        const series = rules.map((rule) => {
            const clocks = tl.firings.filter((f) => f.rule === rule).map((f) => tl.clockAt(f.begin + 1));
            return [rule, clocks, clocks.length, 0];
        });
        return this.draw(series, opts, false);
    }

    /**
     * Each schema's population over a timeline's clock, `[label, changes,
     * peak, now]`, the label prefixed with `label`.
     * @param {Options} opts
     * @param {Timeline} [tl]
     * @param {string} [label]
     * @returns {Series[]}
     */
    schemaSeries(opts, tl = this.#s.tl, label = "") {
        const end = tl.population(tl.length);
        return tl.schemas().filter((s) => keep(s, opts)).map((s) => {
            /** @type {Array<[bigint, number]>} */
            const ch = tl.changes(s).map(([pk, n]) => [tl.clockAt(pk), n]);
            return [label + s, ch, ch.length ? Math.max(...ch.map(([, n]) => n)) : 0, end.get(s) ?? 0];
        });
    }

    /**
     * Bucket each series over the timeline's clock; the edges are kept for
     * `@#N`. A step series (populations) is summarised by `how`; any other is
     * counted.
     * @param {Series[]} series
     * @param {Options} opts
     * @param {boolean} step  whether the series are step series
     * @param {[bigint, bigint] | null} [span]  the clocks to draw between; the timeline's whole
     * @returns {Result[]}
     */
    draw(series, opts, step, span = null) {
        const s = this.#s, tl = s.tl;
        if (!series.length) return [{ type: "note", text: "(nothing)" }];
        const [lo, hi] = span ?? [tl.clockAt(0), tl.clockAt(tl.length)];
        const lw = Math.max(...series.map(([label]) => [...label].length));
        /** @type {bigint[]} */
        let e;
        if (opts.tumbling) {
            const t = opts.tumbling;
            const span = hi - lo;
            let n = (span + t - 1n) / t;
            if (n < 1n) n = 1n;
            e = [];
            for (let i = 0n; i <= n; i++) e.push(lo + t * i);
        } else {
            e = edges(lo, hi, Math.max(10, s.width - lw - 20));
        }
        s.edges = e;
        /** @type {Array<[string, number[], number, number | ""]>} */
        const rows = series.map(([label, data, peak, now]) =>
            [label, step ? stepBuckets(/** @type {Array<[bigint, number]>} */ (data), e, opts.how)
                         : countBuckets(/** @type {bigint[]} */ (data), e), peak, step ? now : ""]);
        return [{ type: "histogram", tl, k: s.k, rows, edges: e, t0: lo,
                  head: step ? ["peak", "now"] : ["total", ""] }];
    }
}
