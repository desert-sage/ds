// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Bounded output (dsdb/DSDB_MCP.md §10.1): an agent's context is the
// scarce thing. Rows past `limit` are cut, and a `more` result after them says
// how many are left and the cursor for them; a `why` tree past its node cap
// stops, each node it stopped in marked `…`. Only here: core and the shell
// print everything, as a person scrolls.

/** @import { Definition } from "../core/program-text.js" */
/** @import { Result } from "../core/types.js" */
/** @import { WhyNode, WhyRoot } from "../core/why.js" */

export const LIMIT = 50;
export const NODES = 200;

/**
 * `results` with each bounded one cut to rows `from` to `from + limit`, and a
 * `more` after it when rows are left. A cut result carries `offset` and
 * `total`, which the text numbers its rows by.
 * @param {Result[]} results
 * @param {{ limit?: number, from?: number }} [opts]
 * @returns {Result[]}
 */
export function bound(results, { limit = LIMIT, from = 0 } = {}) {
    return results.flatMap((r) => {
        const got = rows(r, from, limit);
        if (got === null) return [r];
        const [cut, total] = got;
        const left = total - from - limit;
        return left > 0 ? [cut, { type: "more", count: left, cursor: String(from + limit) }] : [cut];
    });
}

/**
 * `[r cut, how many rows it had]`, or null for a type with no rows.
 * @param {Result} r
 * @param {number} from
 * @param {number} limit
 * @returns {[Result, number] | null}
 */
function rows(r, from, limit) {
    const to = from + limit;
    /**
     * Rows `from` to `to` of `all`, and where they start among how many.
     * @template T
     * @param {T[]} all
     * @returns {[T[], { offset: number, total: number }]}
     */
    const cut = (all) => [all.slice(from, to), { offset: from, total: all.length }];
    switch (r.type) {
    case "listing": {
        const lo = Math.max(0, r.k - r.around), hi = Math.min(r.tl.length, r.k + r.around);
        return [{ ...r, offset: from, limit }, hi - lo];
    }
    case "programList": {
        // One row per definition, across the kinds.
        let i = 0;
        /** @type {Array<[string, Definition[]]>} */
        const kinds = [];
        for (const [k, defs] of r.kinds) {
            const kept = defs.filter(() => { const j = i++; return j >= from && j < to; });
            if (kept.length) kinds.push([k, kept]);
        }
        return [{ ...r, kinds, offset: from, total: i }, i];
    }
    case "answers": {
        const [answers, at] = cut(r.answers);
        return [{ ...r, answers, ...at }, at.total];
    }
    case "answersOverTime": {
        const [groups, at] = cut(r.groups);
        return [{ ...r, groups, ...at }, at.total];
    }
    case "firings": {
        const [firings, at] = cut(r.firings);
        return [{ ...r, firings, ...at }, at.total];
    }
    case "calls": {
        const [calls, at] = cut(r.calls);
        return [{ ...r, calls, ...at }, at.total];
    }
    case "definitionList": {
        const [defs, at] = cut(r.defs);
        return [{ ...r, defs, ...at }, at.total];
    }
    case "ruleList": {
        const [rules, at] = cut(r.rules);
        return [{ ...r, rules, ...at }, at.total];
    }
    case "rete": {
        // A cut network is a filtered one: rules are missing from it.
        const [rules, at] = cut(r.rules);
        return [{ ...r, rules, ...at, filtered: r.filtered || from > 0 || at.total > to }, at.total];
    }
    case "reteSchemas": {
        const [schemas, at] = cut(r.schemas);
        return [{ ...r, schemas, ...at }, at.total];
    }
    default:
        return null;
    }
}

/**
 * `results` with each `why` tree stopped after `cap` numbered nodes, in the
 * order they are numbered, so every `(see N)` left points at a node kept. A
 * node that lost children is marked `cut`; `why` on it goes on from it.
 * @param {Result[]} results
 * @param {number} [cap]
 * @returns {Result[]}
 */
export function capTrees(results, cap = NODES) {
    return results.flatMap(/** @returns {Result[]} */ (r) => {
        if (r.type !== "why") return [r];
        let seen = 0, stopped = false;
        /**
         * The nodes of `xs` kept, each cut in turn.
         * @param {WhyNode[]} xs
         * @returns {WhyNode[]}
         */
        const keep = (xs) => {
            /** @type {WhyNode[]} */
            const out = [];
            for (const c of xs) {
                const got = stopped ? null : walk(c);
                if (got !== null) out.push(got);
            }
            return out;
        };
        /**
         * `x` with its children kept, or null past the cap. Only a binding
         * and a firing are numbered, and only they have children.
         * @param {WhyNode} x
         * @returns {WhyNode | null}
         */
        const walk = (x) => {
            if (x.kind !== "binding" && x.kind !== "firing") return x;
            if (seen >= cap) {
                stopped = true;
                return null;
            }
            seen++;
            const children = keep(x.children);
            return children.length < x.children.length ? { ...x, children, cut: true } : { ...x, children };
        };
        // The root is not numbered.
        const children = keep(r.root.children);
        if (!stopped) return [r];
        /** @type {WhyRoot} */
        const root = children.length < r.root.children.length ? { ...r.root, children, cut: true }
            : { ...r.root, children };
        return [{ ...r, root }, { type: "note",
                                   text: `(stopped at ${cap} node${cap === 1 ? "" : "s"}: \`why\` on a fact or firing `
                                       + "marked … goes on from it)" }];
    });
}
