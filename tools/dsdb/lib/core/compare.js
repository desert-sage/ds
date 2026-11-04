// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Other timelines in a query (DSTRACE_INTERACTIVE §4.8): `?.%0 %1 Q` and the
// other forms over several timelines. The port of shell.py's common, aligned,
// fact_key, compare, compare_answers and compare_population. Returns results;
// prints nothing.
//
// Points are aligned by settled points since the timelines parted: a
// hypothesis's records up to its fork ARE its source's record objects, so
// where two timelines part is where their records stop being the same
// objects.

import { options } from "./counts.js";

/** @import { Answers } from "./answers.js" */
/** @import { Counts, Options, Series } from "./counts.js" */
/** @import { Cmd } from "./grammar.js" */
/** @import { Answer, CompiledQuery, QueryEngine } from "./query.js" */
/** @import { SessionState, View } from "./state.js" */
/** @import { Timeline } from "./timeline.js" */
/** @import { CompareLine, Result } from "./types.js" */

/**
 * `map`'s entry for `key`, which this module set before reading it.
 * @template K, V
 * @param {Map<K, V>} map
 * @param {K} key
 * @returns {V}
 */
function entry(map, key) {
    const v = map.get(key);
    if (v === undefined) throw new TypeError(`no entry for ${String(key)}`);
    return v;
}

/**
 * How many records two timelines share.
 * @param {View} a
 * @param {View} b
 */
export function common(a, b) {
    const n = Math.min(a.tl.length, b.tl.length);
    let i = 0;
    while (i < n && a.tl.records[i] === b.tl.records[i]) i++;
    return i;
}

/**
 * The point of `other` matching `ref`'s point `k`: the same count of
 * settled points since the two diverged (§4.8).
 * @param {View} ref
 * @param {View} other
 * @param {number} k
 * @returns {number}
 */
export function aligned(ref, other, k) {
    const f = common(ref, other);
    if (k <= f) return Math.min(k, other.tl.length);
    /** @param {Timeline} tl */
    const after = (tl) => {
        const pts = tl.settled.filter((s) => s > f);
        return !pts.length || pts[pts.length - 1] !== tl.length ? [...pts, tl.length] : pts;
    };
    const c = after(ref.tl).filter((s) => s <= k).length;
    const pts = after(other.tl);
    return c ? pts[Math.min(c, pts.length) - 1] : f;
}

/**
 * A fact as it is matched across timelines: by id up to the fork, by schema
 * and slot values after it. A string, for a Map key.
 * @param {View} v
 * @param {bigint} id
 * @param {number} fork
 */
function factKey(v, id, fork) {
    const f = v.tl.facts.get(id);
    if (f === undefined || f.asserted < fork) return `id:${id}`;
    const slots = f.slots ?? {};
    const pairs = Object.keys(slots).sort().map((k) => [k, String(slots[k])]);
    return `val:${f.schema}:${JSON.stringify(pairs)}`;
}

export class Compare {
    /** @type {SessionState} */
    #s;
    /** @type {Answers} */
    #answers;
    /** @type {Counts} */
    #counts;
    /** @type {(c: Cmd) => Promise<Result[]>} */
    #queryHere;

    /**
     * @param {SessionState} state
     * @param {Answers} answers
     * @param {Counts} counts
     * @param {(c: Cmd) => Promise<Result[]>} queryHere  one timeline's query, at its point
     */
    constructor(state, answers, counts, queryHere) {
        this.#s = state;
        this.#answers = answers;
        this.#counts = counts;
        this.#queryHere = queryHere;
    }

    /**
     * A query form over the timelines `names` (§4.8).
     * @param {Cmd} c
     * @param {number[]} names
     * @returns {Promise<Result[]>}
     */
    async compare(c, names) {
        const s = this.#s;
        const views = names.map((n) => s.at(n));
        const ref = names.includes(s.cur) ? s.view : views[0];
        let kRef = ref.k;
        if (c.scope === "@" && c.pos !== null) {
            const got = ref.tl.resolve(c.pos.seq, c.pos.minus);
            if (got === null) return [error("past the last position")];
            kRef = got[0];
        }
        /** @type {Map<number, number>} */
        const points = new Map(views.map((v) => [v.n, v === ref ? kRef : aligned(ref, v, kRef)]));
        const o = options(c.body);
        if (o.error !== undefined) return [error(o.error)];
        const { opts, rest } = o;
        /** @type {Result[]} */
        const out = [];
        if ("!^".includes(c.sigil) || (c.sigil === "?" && c.scope === ":")) {
            for (const v of views) {
                out.push({ type: "note", text: `── %${v.n}` });
                out.push(...await s.on(v.n, async (view) => {
                    const was = view.k;
                    view.k = entry(points, v.n);
                    try {
                        return await this.#queryHere(c);
                    } finally {
                        view.k = was;
                    }
                }));
            }
            return out;
        }
        if (c.sigil === "#" && !rest) return this.#population(c.scope, views, points, opts);
        const body = c.sigil === "#" ? rest : c.body;
        if (!body) return [error("`?` needs a query")];
        if (c.sigil === "#" && c.scope === ":") {
            /** @type {Series[]} */
            const series = [];
            /** @type {bigint | null} */
            let lo = null;
            /** @type {bigint | null} */
            let hi = null;
            for (const v of views) {
                const [qe, refused] = await s.on(v.n, () => this.#answers.engineFor(body, v.tl.length));
                if (qe === null) return refused;
                /** @type {Array<[bigint, number]>} */
                const ch = qe.population().map(([pk, n]) => [v.tl.clockAt(pk), n]);
                series.push([`%${v.n}`, ch, ch.length ? Math.max(...ch.map(([, n]) => n)) : 0, qe.at(v.tl.length).length]);
                lo = lo === null || v.tl.clockAt(0) < lo ? v.tl.clockAt(0) : lo;
                hi = hi === null || v.tl.clockAt(v.tl.length) > hi ? v.tl.clockAt(v.tl.length) : hi;
            }
            return this.#counts.draw(series, opts, true, lo === null || hi === null ? null : [lo, hi]);
        }
        /** @type {Map<number, [QueryEngine, Answer[]]>} */
        const found = new Map();
        for (const v of views) {
            const k = entry(points, v.n);
            const [qe, refused] = await s.on(v.n, () => this.#answers.engineFor(body, k));
            if (qe === null) return refused;
            found.set(v.n, [qe, qe.at(k)]);
        }
        if (c.sigil === "#")
            return views.map((v) => ({ type: "answerCount", tl: v.tl, k: entry(points, v.n),
                                       count: entry(found, v.n)[1].length, timeline: v.n }));
        return this.#answersCompared(views, points, found);
    }

    /**
     * @param {View[]} views  the baseline first
     * @param {Map<number, number>} points  each timeline's point
     * @param {Map<number, [QueryEngine, Answer[]]>} found  each timeline's answers there
     * @returns {Result[]}
     */
    #answersCompared(views, points, found) {
        const s = this.#s;
        const base = views[0];
        // Where each timeline parts from the baseline; the baseline's own
        // facts are matched by id up to the earliest of those.
        const fork = new Map(views.slice(1).map((v) => [v.n, common(base, v)]));
        fork.set(base.n, Math.min(...fork.values()));
        /** @type {Map<string, Map<number, [Answer, CompiledQuery]>>} key -> timeline -> [answer, compiled] */
        const keyed = new Map();
        for (const v of views) {
            const [qe, answers] = entry(found, v.n);
            for (const a of answers) {
                const key = qe.compiled.projection.length && a.values !== null
                    ? "values:" + JSON.stringify(a.values)
                    : a.bindings.map((id) => factKey(v, id, entry(fork, v.n))).join("\0");
                if (!keyed.has(key)) keyed.set(key, new Map());
                entry(keyed, key).set(v.n, [a, qe.compiled]);
            }
        }
        const others = new Set(views.slice(1).map((v) => v.n));
        s.rows = [];
        /** @type {CompareLine[]} */
        const lines = [];
        let n = 0;
        for (const where of keyed.values()) {
            n++;
            const mark = !where.has(base.n) ? "+" : ![...where.keys()].some((t) => others.has(t)) ? "-" : " ";
            const [tn, [a, comp]] = [...where][0];
            s.rows.push(["answer", [a, comp]]);
            lines.push({ mark, n, answer: a, compiled: comp, tl: s.at(tn).tl, tn, base: base.n,
                         tags: views.length > 2 ? [...where.keys()] : null });
        }
        const summary = views.map((v) => ({ n: v.n, count: entry(found, v.n)[1].length, tl: v.tl, k: entry(points, v.n) }));
        return [{ type: "compareAnswers", lines, summary }];
    }

    /**
     * @param {string} scope
     * @param {View[]} views
     * @param {Map<number, number>} points
     * @param {Options} opts
     * @returns {Result[]}
     */
    #population(scope, views, points, opts) {
        if (scope === ":") {
            /** @type {Series[]} */
            const series = [];
            /** @type {bigint | null} */
            let lo = null;
            /** @type {bigint | null} */
            let hi = null;
            for (const v of views) {
                series.push(...this.#counts.schemaSeries(opts, v.tl, `%${v.n} `));
                lo = lo === null || v.tl.clockAt(0) < lo ? v.tl.clockAt(0) : lo;
                hi = hi === null || v.tl.clockAt(v.tl.length) > hi ? v.tl.clockAt(v.tl.length) : hi;
            }
            return this.#counts.draw(series, opts, true, lo === null || hi === null ? null : [lo, hi]);
        }
        const pops = new Map(views.map((v) => [v.n, v.tl.population(entry(points, v.n))]));
        /** @param {string} name */
        const keep = (name) => opts.regex === null || opts.regex.test(name);
        const schemas = [...new Set([...pops.values()].flatMap((p) => [...p.keys()]))].filter(keep).sort();
        return [{ type: "populationTable", timelines: views.map((v) => v.n),
                  rows: schemas.map((sch) => [sch, views.map((v) => entry(pops, v.n).get(sch) ?? 0)]) }];
    }
}

/**
 * @param {string} text
 * @returns {Result}
 */
const error = (text) => ({ type: "error", text });
