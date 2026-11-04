// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Columns, three ways. `dsc`'s diagnostics count code points from 1
// ([ICOM.7.4]); the syntax tree counts them from 0 (`col_offset`, as Python's
// `ast`, but in code points); LSP counts UTF-16 code units from 0, unless the
// client accepts "utf-32", which is code points again. Lines are 0-based in
// LSP and 1-based everywhere else.

/** @typedef {"utf-16" | "utf-32"} Encoding  how a client counts a column */

/**
 * The encoding to speak: code points when the client takes them, since that
 * is what DS counts in; else UTF-16, which every client takes.
 * @param {unknown} offered  the client's `general.positionEncodings`
 * @returns {Encoding}
 */
export function negotiate(offered) {
    return Array.isArray(offered) && offered.includes("utf-32") ? "utf-32" : "utf-16";
}

/**
 * A 0-based code-point column on `line` as the client counts it. A column
 * past the end of the line counts one unit per missing code point.
 * @param {string} line
 * @param {number} cp
 * @param {Encoding} enc
 */
export function toClient(line, cp, enc) {
    if (enc === "utf-32") return cp;
    let units = 0, seen = 0;
    for (const ch of line) {
        if (seen >= cp) return units;
        units += ch.length;
        seen++;
    }
    return units + (cp - seen);
}

/**
 * A client's column on `line` as a 0-based code-point column. A column inside
 * a surrogate pair is the code point it is part of.
 * @param {string} line
 * @param {number} col
 * @param {Encoding} enc
 */
export function fromClient(line, col, enc) {
    if (enc === "utf-32") return col;
    let units = 0, cp = 0;
    for (const ch of line) {
        if (units + ch.length > col) return cp;
        units += ch.length;
        cp++;
    }
    return cp + Math.max(0, col - units);
}

/**
 * A document's lines, as LSP splits them: on CRLF, LF or CR.
 * @param {string} text
 */
export function lines(text) {
    return text.split(/\r\n|\n|\r/);
}
