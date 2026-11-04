// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// `rete` as the shell prints it (DSTRACE_INTERACTIVE §4.13): one chain per
// rule, read top to bottom, a row per node with what it holds and how that
// changed since the previous settled point. Formats only; core/rete.js read
// the network. Stage 7 has no Python to match: the section's example is the
// reference.

import { duration } from "../core/program.js";
import { ljust, rjust, width } from "./py.js";
import { clock, pointLabel } from "./render.js";

/** @import { NodeRow, Stage } from "../core/rete.js" */
/** @import { Timeline } from "../core/timeline.js" */
/** @import { Result } from "../core/types.js" */

// A join is `∧`, "and": the pattern holds too, of what arrives from above.
// Not the bowtie, whose relational reading invites database thinking (§4.13).
/** @type {Record<NodeRow["kind"], string>} */
const GLYPH = { alpha: "α", join: "∧", not: "¬", terminal: "▶" };
/** @type {Record<NodeRow["kind"], string>} */
const UNIT = { alpha: "fact", join: "token", not: "token", terminal: "activation" };

/**
 * @param {number} n
 * @param {string} one
 */
const plural = (n, one) => `${n} ${one}${n === 1 ? "" : "s"}`;
/**
 * @param {number | null | undefined} n
 * @param {string} one
 */
const count = (n, one) => (n === null || n === undefined ? `? ${one}s` : plural(n, one));
/** @param {number | null | undefined} d */
const change = (d) => (d === null || d === undefined || d === 0 ? "" : d > 0 ? `+${d}` : `${d}`);

// A header, as `rete at @00001aba 12.0s`.
/**
 * What was asked, at which point and clock.
 * @param {{ tl: Timeline, k: number }} r
 * @param {string} what
 */
function at(r, what) {
    return `  ${what} at ${pointLabel(r.tl, r.k)} ${clock(r.tl.clockAt(r.k), r.tl.clockAt(0))}`;
}

/**
 * The notes a reading can carry, under its header.
 * @param {{ changed: boolean, noSource?: boolean }} r
 */
function notes(r) {
    const out = [];
    if (r.changed) out.push("  (the program changed since the previous settled point, so no changes are shown)");
    if (r.noSource) out.push("  (no program source, so each pattern is shown by its alpha test)");
    return out;
}

/**
 * `rete`, `rete @N`, `rete /regex/`
 * @param {Extract<Result, { type: "rete" }>} r
 * @returns {string[]}
 */
export function reteLines(r) {
    const s = r.summary;
    const head = at(r, "rete") + ` · ${s.alpha} alpha · ${s.join} join · ${plural(s.rules, "rule")}`
        + ` · ${plural(s.facts, "fact")} held · ${plural(s.tokens, "token")}`
        + (r.filtered ? ` · ${r.rules.length} shown` : "");
    const out = [head, ...notes(r)];
    if (!r.rules.length) return [...out, "  (no rule matches)"];
    const rows = r.rules.flatMap((x) => x.rows);
    /** @param {NodeRow} row */
    const text = (row) => row.text + (row.also.length ? `  (also ${row.also.join(", ")})` : "");
    const W = {
        n: Math.max(4, ...rows.map((x) => String(x.n).length)),
        head: Math.max(...rows.map((x) => width(x.head))),
        text: Math.max(0, ...rows.map((x) => width(text(x)))),
        count: Math.max(...rows.map((x) => width(count(x.count, UNIT[x.kind])))),
        delta: Math.max(0, ...rows.map((x) => change(x.delta).length)),
        right: Math.max(0, ...rows.flatMap((x) => (x.right ? [width(x.right.schema)] : []))),
    };
    /** @param {NodeRow} x */
    const line = (x) => {
        let s = `  ${rjust(String(x.n), W.n)}  ${GLYPH[x.kind]} ${ljust(x.head, W.head)}`;
        if (W.text) s += `  ${ljust(text(x), W.text)}`;
        s += `  ${ljust(count(x.count, UNIT[x.kind]), W.count)}`;
        if (W.delta) s += `  ${ljust(change(x.delta), W.delta)}`;
        if (x.right) {
            const d = change(x.right.delta);
            s += `  ◀ α ${ljust(x.right.schema, W.right)}  ${count(x.right.count, "fact")}${d ? `  ${d}` : ""}`;
        }
        return s.trimEnd();
    };
    // The rule's counts end where the rows' counts do.
    const end = 2 + W.n + 2 + 2 + W.head + (W.text ? 2 + W.text : 0) + 2 + W.count + (W.delta ? 2 + W.delta : 0);
    for (const rule of r.rules) {
        let left = `  rule ${rule.name}`;
        if (rule.compiled !== rule.name) left += `  (as ${rule.compiled})`;
        if (rule.unaligned)
            left += `  (patterns not lined up: ${rule.unaligned.source} in the source, `
                + `${rule.unaligned.network} in the network)`;
        const stats = [`fired ${rule.fired}`];
        if (rule.pending) stats.push(`pending ${rule.pending}`);
        if (rule.refracted) stats.push(`refracted ${rule.refracted}`);
        const right = stats.join(" · ");
        out.push("", left + " ".repeat(Math.max(2, end - width(left) - width(right))) + right);
        out.push(...rule.rows.map(line));
    }
    return out;
}

/**
 * `rete schemas`: alpha-first.
 * @param {Extract<Result, { type: "reteSchemas" }>} r
 * @returns {string[]}
 */
export function reteSchemaLines(r) {
    const s = r.summary;
    const alphas = r.schemas.flatMap((x) => x.alphas);
    const out = [at(r, "rete schemas") + ` · ${plural(r.schemas.length, "schema")} · ${s.alpha} alpha`
                 + ` · ${plural(s.facts, "fact")} held`, ...notes(r)];
    /** @param {{ filter: string }} a */
    const test = (a) => a.filter || "(no test)";
    const W = {
        n: Math.max(4, ...alphas.map((a) => String(a.n).length)),
        test: Math.max(0, ...alphas.map((a) => width(test(a)))),
        count: Math.max(0, ...alphas.map((a) => width(count(a.count, "fact")))),
        delta: Math.max(0, ...alphas.map((a) => change(a.delta).length)),
    };
    for (const sc of r.schemas) {
        out.push("", `  ${sc.schema}`);
        for (const a of sc.alphas) {
            let line = `  ${rjust(String(a.n), W.n)}  α ${ljust(test(a), W.test)}  ${ljust(count(a.count, "fact"), W.count)}`;
            if (W.delta) line += `  ${ljust(change(a.delta), W.delta)}`;
            line += `  ${a.rules.length ? a.rules.join(", ") : "(no rule)"}`;
            out.push(line.trimEnd());
        }
    }
    return out;
}

/**
 * `whynot RULE` (§13, DSDB_MCP.md §10.6): the rule's chain at point, what
 * each pattern has to match, and where the match stops.
 * @param {Extract<Result, { type: "whynot" }>} r
 * @returns {string[]}
 */
export function whynotLines(r) {
    const tl = r.tl, t0 = tl.clockAt(0);
    /** @param {bigint[]} xs */
    const ids = (xs) => [...xs.slice(0, 6).map((x) => `#${x}`), ...(xs.length > 6 ? [`+${xs.length - 6}`] : [])].join(" ");
    /** @param {number} n */
    const matches = (n) => `${n} complete match${n === 1 ? "" : "es"}`;
    /** @param {number | null} n */
    const arrive = (n) => (n === 1 ? "1 token arrives" : `${n} tokens arrive`);
    const stopped = r.stop === null ? null : r.stages[r.stop];
    const verdict = stopped !== null ? `no complete match; it stops at ${stopped.n}`
        : r.reason?.why === "unseen" ? `it matches up to its last pattern, ${r.stages[r.stages.length - 1].n}`
        : r.complete === null ? "its counts are not reported" : matches(r.complete);
    const out = [at(r, `whynot ${r.rule}`) + `: ${verdict}`];
    if (r.noSource) out.push("  (no program source, so each pattern is shown by its alpha test)");
    /** @param {Stage} x */
    const has = (x) => (x.candidates === null ? "" : x.kind === "alpha" ? ids(x.candidates)
        : `◀ ${x.schema} ${x.candidates.length ? ids(x.candidates) : "none"}`);
    const W = {
        n: Math.max(4, ...r.stages.map((x) => String(x.n).length)),
        head: Math.max(0, ...r.stages.map((x) => width(x.head))),
        text: Math.max(0, ...r.stages.map((x) => width(x.text))),
        count: Math.max(0, ...r.stages.map((x) => width(count(x.count, UNIT[x.kind])))),
    };
    for (const x of r.stages) {
        let s = `  ${rjust(String(x.n), W.n)}  ${GLYPH[x.kind]} ${ljust(x.head, W.head)}`;
        if (W.text) s += `  ${ljust(x.text, W.text)}`;
        out.push(`${s}  ${ljust(count(x.count, UNIT[x.kind]), W.count)}  ${has(x)}`.trimEnd());
    }
    const why = r.reason, n = stopped === null ? null : stopped.n;
    if (why?.why === "none") out.push(`  stops at ${n}: no ${why.schema} is live at point`);
    else if (why?.why === "filtered") {
        const shown = why.filtered.slice(0, 4).map((f) => `#${f.id} (${f.detail})`);
        out.push(`  stops at ${n}: no ${why.schema} passes its test: ${shown.join(", ")}`
                 + (why.filtered.length > 4 ? `, +${why.filtered.length - 4}` : ""));
    } else if (why?.why === "joins") {
        out.push(`  stops at ${n}: ${arrive(why.tokens)} and ${why.candidates} ${stopped?.schema} `
                 + `pass${why.candidates === 1 ? "es" : ""} its test, and no pair joins`,
                 "  (which join test rejected which pair needs libds's node contents)");
    } else if (why?.why === "blocked") {
        out.push(`  stops at ${n}: ${arrive(why.tokens)}, blocked by what the \`no\` pattern matches: ${ids(why.by ?? [])}`,
                 "  (which fact blocks which token needs libds's node contents)");
    } else if (why?.why === "unseen") {
        const x = r.stages[r.stages.length - 1];
        out.push(`  ${x.n}: ${arrive(why.tokens)}, and ${why.candidates} ${x.schema} `
                 + (x.kind === "not" ? `could block ${why.tokens === 1 ? "it" : "them"}: ${ids(x.candidates ?? [])}`
                     : `pass${why.candidates === 1 ? "es" : ""} its test`),
                 `  (whether ${x.kind === "not" ? "one blocks" : "a pair joins"} needs libds's node contents)`);
    } else if (n !== null) out.push(`  stops at ${n}`);
    if (r.stop === null && r.complete !== 0 && r.fired) {
        const last = r.last === null ? "" : `, the last at ${pointLabel(tl, r.last.begin + 1)} ${clock(tl.clockAt(r.last.begin + 1), t0)}`;
        out.push(`  it fired ${plural(r.fired, "time")} up to point${last}`,
                 "  a match fires once, and again only when one of its facts changes (refraction)");
        if (r.refracted) out.push(`  ${r.refracted} refracted now`);
    }
    if (r.pending) out.push(`  ${plural(r.pending, "activation")} not yet fired`);
    if (r.cooldown !== null) out.push(`  cooldown ${duration(r.cooldown)}`);
    return out;
}

/**
 * `rete dot FILE`
 * @param {Extract<Result, { type: "reteDot" }>} r
 */
export function reteDotLine(r) {
    return `  wrote ${r.file}: the network at ${pointLabel(r.tl, r.k)} ${clock(r.tl.clockAt(r.k), r.tl.clockAt(0))}`
        + ` as Graphviz, ${plural(r.nodes, "node")} and ${plural(r.edges, "edge")}`;
}
