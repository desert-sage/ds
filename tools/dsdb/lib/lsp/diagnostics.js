// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// `dsc`'s rendered diagnostics read back as records, until the compiler can
// write them as data. The shape is [RCLI.5.3]'s, as dsc.render.m
// writes it, one diagnostic after another with a blank line between:
//
//     File "<file>", line <L>, column <C>          C 1-based, in code points
//         <the source line>                        absent when L is out of range
//         <spaces>^^^^[ (continues to line L2, column C2)]
//     <CODE>: <message>
//       hint: <hint>                               optional
//     related: File "<file>", line <L>, column <C> zero or more, each a block
//         <the source line>
//         <spaces>^
//       <message>
//
// The caret row gives the span's end: its width on the line, or the line and
// column it continues to. A related span carries no end and underlines one
// code point.

/** @typedef {{ line: number, col: number }} Point  a line, 1-based, and a column, 0-based in code points */
/** @typedef {{ start: Point, end: Point }} Span */
/** @typedef {{ span: Span, message: string }} Related */
/** @typedef {{ code: string, message: string, hint: string | null, span: Span, related: Related[] }} Diagnostic */

const HEADER = /^(related: )?File "(.*)", line (\d+), column (\d+)$/;
const CARETS = /^( *)(\^+)(?: \(continues to line (\d+), column (\d+)\))?$/;
const CODE = /^([A-Z][A-Z0-9_]*): (.*)$/;
const HINT = "  hint: ";

/**
 * Every diagnostic in `dsc`'s report, in its order. Lines that are not part
 * of a diagnostic (a note the compiler printed first) are passed over.
 * @param {string} text
 * @returns {Diagnostic[]}
 */
export function parseDiagnostics(text) {
    const ls = text.split("\n");
    /** @type {Diagnostic[]} */
    const out = [];
    let i = 0;
    /** The block at `i`: its span, or null when `i` is no header. */
    const block = () => {
        const m = HEADER.exec(ls[i]);
        if (m === null) return null;
        const line = Number(m[3]), col = Number(m[4]) - 1;
        /** @type {Span} */
        const span = { start: { line, col }, end: { line, col: col + 1 } };
        i++;
        if (i + 1 < ls.length && ls[i].startsWith("    ")) {
            const c = CARETS.exec(ls[i + 1].slice(4));
            if (c !== null) {
                span.end = c[3] !== undefined
                    ? { line: Number(c[3]), col: Number(c[4]) - 1 }
                    : { line, col: col + c[2].length };
                i += 2;
            }
        }
        return { related: m[1] !== undefined, span };
    };
    while (i < ls.length) {
        const head = block();
        if (head === null || head.related) {
            if (head === null) i++;
            continue;
        }
        const code = CODE.exec(ls[i] ?? "");
        if (code === null) continue;
        i++;
        /** @type {Diagnostic} */
        const diag = { code: code[1], message: code[2], hint: null, span: head.span, related: [] };
        if (ls[i]?.startsWith(HINT)) diag.hint = ls[i++].slice(HINT.length);
        for (;;) {
            const save = i;
            const rel = block();
            if (rel === null || !rel.related) {
                i = save;
                break;
            }
            diag.related.push({ span: rel.span, message: (ls[i++] ?? "").trim() });
        }
        out.push(diag);
    }
    return out;
}
