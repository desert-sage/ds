// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// A rule's block in the program's source: its header, its `->` at column 0,
// and its end. Nothing here reads a pattern or an expression; the column-0
// structure is enough. `rete` and `why` read rule text through these
// (rete.js `ruleBlock`).
//
// There are no rule hypotheses (§4.16): the program is edited for all time,
// by its definitions (program-text.js, edit.js).

const HEADER = /^rule\s+([A-Za-z_]\w*)/;

/** A rule block that is not what it should be, with a message. */
export class RuleError extends Error {
    /** @param {string} message */
    constructor(message) {
        super(message);
        this.name = "RuleError";
    }
}

/**
 * The rule a `rule NAME:` line starts, or null.
 * @param {string} line
 * @returns {string | null}
 */
export function blockName(line) {
    const m = HEADER.exec(line);
    return m ? m[1] : null;
}

/**
 * The `->` line of the rule whose header is line `start`.
 * @param {string[]} lines
 * @param {number} start
 * @returns {number}
 */
export function arrow(lines, start) {
    let i = start + 1;
    while (i < lines.length && lines[i].trimEnd() !== "->") i++;
    if (i === lines.length) throw new RuleError(`no \`->\` at column 0 after the header on line ${start + 1}`);
    return i;
}

/**
 * The line after the rule block whose header is line `start`: the first line
 * past its `->` at column 0 that is not blank, indented or a comment, less
 * the blank lines before it.
 * @param {string[]} lines
 * @param {number} start
 * @returns {number}
 */
export function blockEnd(lines, start) {
    let i = arrow(lines, start) + 1;
    while (i < lines.length && (!lines[i].trim() || " \t#".includes(lines[i][0]))) i++;
    while (i > start + 1 && !lines[i - 1].trim()) i--;
    return i;
}
