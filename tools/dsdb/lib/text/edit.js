// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The program's definitions as the shell prints them (DSTRACE_INTERACTIVE
// §4.16): `ls`, `ls rules`, `ls KIND`, and what `save code` wrote. Formats
// only; core/edit.js made every choice.

import { ljust, rjust, width } from "./py.js";
import { pointLabel } from "./render.js";

/** @import { Definition } from "../core/program-text.js" */
/** @import { Result } from "../core/types.js" */

/** @type {Record<string, string>} each definition kind's plural */
const PLURAL = { use: "use", import: "imports", const: "consts", unit: "units", schema: "schemas",
                 service: "services", series: "series", rule: "rules", test: "tests" };
/**
 * @param {number} n
 * @param {string} kind
 */
const plural = (n, kind) => `${n} ${n === 1 ? kind : PLURAL[kind]}`;

/**
 * A definition's header line: its first line that is not a comment.
 * @param {Definition} d
 */
const headerLine = (d) => d.text.split("\n").find((l) => l.trim() && !l.startsWith("#")) ?? "";

/**
 * `ls`: every definition, by kind, in the order the program is written.
 * @param {Extract<Result, { type: "programList" }>} r
 * @returns {string[]}
 */
export function programLines(r) {
    const w = Math.max(...r.kinds.map(([k]) => width(PLURAL[k])));
    return r.kinds.map(([k, defs]) =>
        `  ${ljust(PLURAL[k], w)}  ${k === "use" ? headerLine(defs[0]) : defs.map((d) => d.name).join("  ")}`);
}

/**
 * `ls schemas`, `ls services`, …: one header line each.
 * @param {Extract<Result, { type: "definitionList" }>} r
 * @returns {string[]}
 */
export function definitionLines(r) {
    if (!r.defs.length) return [`  no ${PLURAL[r.kind]}`];
    return r.defs.map((d) => `  ${headerLine(d)}`);
}

/**
 * `ls rules`: the rule order, each rule's first pattern and its firings.
 * @param {Extract<Result, { type: "ruleList" }>} r
 * @returns {string[]}
 */
export function ruleListLines(r) {
    if (!r.rules.length) return ["  no rules"];
    const nw = Math.max(4, ...r.rules.map((x) => String(x.n).length));
    const name = Math.max(...r.rules.map((x) => width(x.name)));
    const pat = Math.max(...r.rules.map((x) => width(x.pattern + (x.patterns > 1 ? `  (+${x.patterns - 1})` : ""))));
    return r.rules.map((x) => `  ${rjust(String(x.n), nw)}  ${ljust(x.name, name)}  `
        + `${ljust(x.pattern + (x.patterns > 1 ? `  (+${x.patterns - 1})` : ""), pat)}  fired ${x.fired}`);
}

/**
 * An edit, and the inputs replayed under it (§4.16).
 * @param {Extract<Result, { type: "edited" }>} r
 * @returns {string[]}
 */
export function editedLines(r) {
    return [`  ${r.what} · replayed ${r.inputs} input${r.inputs === 1 ? "" : "s"}`,
            ...r.skipped.map((x) => `  skipped a ${x.kind}: ${x.why}`)];
}

/**
 * What an edit did to the current timeline: its facts at point, and its
 * firings per rule.
 * @param {Extract<Result, { type: "editDiff" }>} r
 * @returns {string[]}
 */
export function editDiffLines(r) {
    const at = `%${r.timeline} at ${pointLabel(r.tl, r.k)}`;
    if (!r.added.length && !r.removed.length && !r.firings.length) return [`  no change to ${at}`];
    return [`  ${at}:`,
            ...r.added.map((x) => `    + ${x}`),
            ...r.removed.map((x) => `    - ${x}`),
            ...(r.firings.length ? [`    fired: ${r.firings.map(([rule, a, b]) => `${rule} ${a} → ${b}`).join(", ")}`] : [])];
}

/**
 * What `save code` wrote.
 * @param {Extract<Result, { type: "savedCode" }>} r
 */
export function savedCodeLine(r) {
    return `  wrote ${r.path}: ${r.counts.filter(([k]) => k !== "use").map(([k, n]) => plural(n, k)).join(", ")}; `
        + `${r.lines} lines`;
}
