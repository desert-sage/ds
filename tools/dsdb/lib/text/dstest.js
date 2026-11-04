// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// `ds test`'s output (cli/main.js): each case's verdict and, for one that
// failed, why, as lines. Assertions are written back in the test language's
// own surface ([LTSL.8.2]). It formats and decides nothing: core/dstest.js
// decides.

/** @import { CaseResult, Fault, Literal, Oracle, Slots, Verdict } from "../core/dstest.js" */

/**
 * One case: `[PASS] "name"` or `[FAIL] "name"`, and for a failed case each
 * failure, each assertion that did not hold, and then each fault the run met,
 * in stream order ([RTIM.14.16]), indented. A passing case's faults are not
 * shown.
 * @param {CaseResult} r
 * @returns {string[]}
 */
export function caseLines(r) {
    const lines = [`[${r.passed ? "PASS" : "FAIL"}] ${JSON.stringify(r.name)}`];
    if (r.passed) return lines;
    for (const f of r.failures) lines.push(`    ${f}`);
    for (const v of r.verdicts) if (!v.ok) lines.push(`    ${assertionText(v.oracle)}: ${verdictText(v)}`);
    for (const f of r.faults) lines.push(`    ${faultText(f)}`);
    return lines;
}

/**
 * A fault as a failing case reports it: its kind, the instant on the case's
 * mock clock, the rule whose activation it abandoned where the event names
 * one, and its cause. `ComputationError at T=0.000s in rule alert: DOMAIN at
 * Alert.ts`.
 * @param {Fault} f
 */
export function faultText(f) {
    const at = `T=${(Number(f.atNs) / 1e9).toFixed(3)}s`;
    return `${f.kind} at ${at}${f.rule === null ? "" : ` in rule ${f.rule}`}: ${f.cause}`;
}

/**
 * The last line: how many cases passed of how many.
 * @param {number} passed
 * @param {number} total
 */
export function summaryLine(passed, total) {
    return `ds test: ${passed}/${total} case${total === 1 ? "" : "s"} passed`;
}

/**
 * What an assertion wanted and what the run observed.
 * @param {Verdict} v
 */
export function verdictText(v) {
    const o = v.oracle, n = v.observed;
    if (o.head === "wm count")
        return o.never ? `want other than ${o.count} live, observed ${n}` : `want ${o.count} live, observed ${n}`;
    if (o.head === "wm empty")
        return o.never ? "want facts live at the end, observed none" : `want none live at the end, observed ${n}`;
    return o.never ? `want none, observed ${n}` : `want at least one, observed ${n}`;
}

/**
 * An assertion as the test wrote it, or near it: a `where` predicate is the
 * compiler's rule and its text is not in the atom, so it is shown as `…`.
 * @param {Oracle} o
 */
export function assertionText(o) {
    return (o.never ? "never " : "") + headText(o);
}

/** @param {Oracle} o */
function headText(o) {
    switch (o.head) {
    case "activated":
        return `activated ${o.rule}`;
    case "emitted":
    case "published":
        return o.where ? `${o.head} ${o.schema} … where …` : `${o.head} ${o.schema}${slotsText(o.slots)}`;
    case "retracted":
    case "wm has":
        return `${o.head} ${o.schema}${slotsText(o.slots)}`;
    case "called":
        return `called ${o.service}${o.correlation === null ? "" : ` as ${JSON.stringify(o.correlation)}`}`;
    case "cached":
        return `cached ${JSON.stringify(o.key)}${o.value === null ? "" : `: ${literalText(o.value)}`}`;
    case "cache_deleted":
        return `cache_deleted ${JSON.stringify(o.key)}`;
    case "logged":
        return `logged ${o.level.toLowerCase()}${o.text === null ? "" : ` ${JSON.stringify(o.text)}`}`;
    case "wm count":
        return `wm count ${o.schema} == ${o.count}`;
    case "wm empty":
        return "wm empty";
    }
}

/** @param {Slots} slots */
function slotsText(slots) {
    return slots.map(([k, lit]) => ` ${k}: ${literalText(lit)}`).join("");
}

/**
 * A literal as DS writes it: a Float always with a point or an exponent, a
 * Duration in nanoseconds.
 * @param {Literal} lit
 */
export function literalText(lit) {
    switch (lit.kind) {
    case "none":
        return "null";
    case "int":
        return lit.value.toString();
    case "duration":
        return `${lit.value}_ns`;
    case "float": {
        const s = String(lit.value);
        return Number.isFinite(lit.value) && /^-?\d+$/.test(s) ? `${s}.0` : s;
    }
    case "string":
        return JSON.stringify(lit.value);
    case "json":
        return `json(${JSON.stringify(lit.value)})`;
    case "bool":
        return String(lit.value);
    }
}
