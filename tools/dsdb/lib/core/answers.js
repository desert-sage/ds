// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Queries at the prompt (DSTRACE_INTERACTIVE §4.3–4.5, §7): `?` answers and
// `#` counts of a query, at point, at a position or over time; `watch` and
// `next change`. The port of shell.py's engine_for, query,
// answers_over_time, watch_diff and seek_change. Returns results; prints
// nothing. The queries themselves are query.js's.

import { QueryError } from "./query.js";

/** @import { Counts, Options } from "./counts.js" */
/** @import { Answer, QueryEngine } from "./query.js" */
/** @import { SessionState } from "./state.js" */
/** @import { Result } from "./types.js" */

export class Answers {
    /** @type {SessionState} */
    #s;
    /** @type {Counts} */
    #counts;
    /** The watched query's text, or "" (§4.5). */
    watching = "";

    /**
     * @param {SessionState} state  each timeline's queries are its view's
     * @param {Counts} counts  for `#:`'s histogram
     */
    constructor(state, counts) {
        this.#s = state;
        this.#counts = counts;
    }

    /**
     * `[engine | null, results]`: the current timeline's query engine for
     * `body` fed to `upto`, or the refusal as results.
     * @param {string} body
     * @param {number} upto
     * @returns {Promise<[QueryEngine, Result[]] | [null, Result[]]>}
     */
    async engineFor(body, upto) {
        const queries = this.#s.view.queries;
        if (queries === null) return [null, [error("queries need the program's .dsc")]];
        body = body.trim();
        if (body.startsWith("(") && body.endsWith(")")) body = body.slice(1, -1);   // a bracket block (§4.2)
        try {
            return [await queries.get(body, upto), []];
        } catch (err) {
            if (!(err instanceof QueryError)) throw err;
            return [null, splitlines(err.message).map(error)];
        }
    }

    /**
     * `?.Q`, `?:Q`, `?@N Q`, and `#` with a query.
     * @param {string} sigil
     * @param {string} scope
     * @param {number} k
     * @param {string} body
     * @param {Options} opts
     * @returns {Promise<Result[]>}
     */
    async query(sigil, scope, k, body, opts) {
        const s = this.#s, tl = s.tl;
        const [qe, refused] = await this.engineFor(body, scope === ":" ? tl.length : k);
        if (qe === null) return refused;
        /** @type {Result[]} */
        const out = [];
        if (sigil === "#") {
            if (scope === ":") {
                /** @type {Array<[bigint, number]>} */
                const ch = qe.population().map(([pk, n]) => [tl.clockAt(pk), n]);
                const peak = ch.length ? Math.max(...ch.map(([, n]) => n)) : 0;
                return this.#counts.draw([["answers", ch, peak, qe.at(tl.length).length]], opts, true);
            }
            return [{ type: "answerCount", tl, k, count: qe.at(k).length }];
        }
        if (scope === ":") out.push(this.#overTime(qe));
        else {
            const answers = qe.at(k);
            s.rows = answers.map((a) => ["answer", [a, qe.compiled]]);
            out.push({ type: "answers", tl, k, answers, compiled: qe.compiled });
        }
        if (qe.skipped)
            out.push({ type: "note", text: `(${qe.skipped} recorded facts were not typed, or their schema is `
                                           + "unread by this query, and were not applied)" });
        return out;
    }

    /**
     * Each distinct answer once, with every span it held.
     * @param {QueryEngine} qe
     * @returns {Result}
     */
    #overTime(qe) {
        /** @type {Map<string, Answer[]>} */
        const groups = new Map();
        for (const a of qe.answers) {
            const g = groups.get(a.key) ?? [];
            groups.set(a.key, g);
            g.push(a);
        }
        const spans = [...groups.values()];
        this.#s.rows = spans.map((g) => ["answer", [g[0], qe.compiled]]);
        return { type: "answersOverTime", tl: this.#s.tl, groups: spans, compiled: qe.compiled };
    }

    /**
     * `watch Q`, and `watch` alone to say what is watched.
     * @param {string} args
     * @returns {Promise<Result[]>}
     */
    async watch(args) {
        if (!args) return [{ type: "note", text: `watching: ${this.watching || "nothing"}` }];
        const [qe, refused] = await this.engineFor(args, this.#s.k);
        if (qe === null) return refused;
        this.watching = args;
        return [{ type: "note", text: `watching ${args}` }];
    }

    /** @returns {Result[]} */
    unwatch() {
        this.watching = "";
        return [];
    }

    /**
     * What a move from `old` to `now` did to the watched answers: `+` those
     * that arrived, `-` those that left.
     * @param {number} old
     * @param {number} now
     * @returns {Promise<Result[]>}
     */
    async diff(old, now) {
        if (!this.watching) return [];
        const [qe, refused] = await this.engineFor(this.watching, Math.max(old, now));
        if (qe === null) return refused;
        const before = new Map(qe.at(old).map((a) => [a.key, a]));
        const after = new Map(qe.at(now).map((a) => [a.key, a]));
        const added = [...after].filter(([key]) => !before.has(key)).map(([, a]) => a);
        const removed = [...before].filter(([key]) => !after.has(key)).map(([, a]) => a);
        if (!added.length && !removed.length) return [];
        return [{ type: "watchDiff", tl: this.#s.tl, compiled: qe.compiled, added, removed }];
    }

    /**
     * `next change` and `prev change`: the point where the watched answers
     * next (or last) change.
     * @param {boolean} forward
     * @returns {Promise<[number | null, Result[]]>}
     */
    async seekChange(forward) {
        if (!this.watching) return [null, [error("`next change` needs a watched query: `watch <query>`")]];
        const [qe, refused] = await this.engineFor(this.watching, this.#s.tl.length);
        if (qe === null) return [null, refused];
        const k = this.#s.k;
        const cand = qe.changes().filter((p) => (forward ? p > k : p < k));
        if (!cand.length) return [null, [error(`no ${forward ? "later" : "earlier"} change`)]];
        return [forward ? Math.min(...cand) : Math.max(...cand), []];
    }
}

/**
 * @param {string} text
 * @returns {Result}
 */
const error = (text) => ({ type: "error", text });

// Python's line breaks. Built from a string of escapes: a literal U+2028 or
// U+2029 in a regex literal ends the line, and so the literal.
const LINE_BREAK = new RegExp("\\r\\n|[\\n\\r\\v\\f\\x1c\\x1d\\x1e\\x85\\u2028\\u2029]");

/**
 * Python's str.splitlines: every line break it knows, no empty last line.
 * @param {string} s
 * @returns {string[]}
 */
export function splitlines(s) {
    const out = s.split(LINE_BREAK);
    if (out.length && out[out.length - 1] === "") out.pop();
    return out;
}
