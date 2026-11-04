// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Semantic tokens (`textDocument/semanticTokens/full`) of `ds lsp`:
// how an editor colours DS with no grammar installed.
//
// The text is split into the lexer's token classes ([LLEX.4], [LLEX.11] to
// [LLEX.13]): a comment, a string, a numeric or unit literal (one token,
// suffix included: [LLEX.11.3.1]), a name, punctuation. This splits; it
// does not parse, and decides nothing the compiler decides. A name is then
// coloured by what it is, in this order:
//
// 1. what the program declares, as references.js `refAt` resolves it across
//    the file and the libraries it imports: a schema, a rule, a constant, an
//    opaque type, a unit, a slot, a rule's binding; and the file's services,
//    whose names are dotted (`svc.page`), each part coloured as the service;
// 2. a builtin function the call reaches ([LEXP.17.2]): a bare one, an
//    imported module's under its qualifier, a from-import's bare name; the
//    qualifier itself is a namespace;
// 3. a builtin type ([LGRA.22.8]);
// 4. a word the grammar reserves, by its [LLEX.9.8] class.
//
// The program comes first because a class-2 word may also be a name
// ([LLEX.9.3.1]): a slot called `key` is a slot where it is read.
//
// Positions are the tree's: lines 1-based, columns code points. `encode`
// converts to the client's and to LSP's relative form, one token per line: a
// triple-quoted string is a token on each line it spans.

import { imported } from "./complete.js";
import { nameRange, patternBodies } from "./analysis.js";
import { refAt } from "./references.js";
import { AGGREGATIONS, BUILTINS, GRAMMAR_WORDS, TYPES } from "./registries.js";
import { toClient } from "./positions.js";

/** @import { Unit, Ref } from "./references.js" */
/** @import { Encoding } from "./positions.js" */

/**
 * The legend the server gives in `initialize`. The types are LSP's own. Of
 * the modifiers, `action`, `clause` and `constant` are DS's: the [LLEX.9.8]
 * class of a reserved word coloured `keyword` (a `declaration`-class word
 * carries none, an `operator`-class one is an `operator`).
 */
export const LEGEND = Object.freeze({
    tokenTypes: Object.freeze(["namespace", "type", "struct", "interface", "function", "variable", "property",
                               "keyword", "operator", "string", "number", "comment"]),
    tokenModifiers: Object.freeze(["declaration", "readonly", "defaultLibrary", "action", "clause", "constant"]),
});

const T = Object.fromEntries(LEGEND.tokenTypes.map((t, i) => [t, i]));
const M = Object.fromEntries(LEGEND.tokenModifiers.map((m, i) => [m, 1 << i]));

/**
 * A piece of the text, as the lexer would class it.
 * @typedef {{ line: number, start: number, end: number, kind: "comment" | "string" | "number" | "name" | "punct", text: string }} Lexeme
 */

/**
 * A coloured token: one line, a code-point range, a legend type and a
 * modifier bit set.
 * @typedef {{ line: number, start: number, end: number, type: number, mods: number }} Token
 */

const NAME_START = /[\p{L}_]/u;
const NAME_CONT = /[\p{L}\p{N}_]/u;
const DIGIT = /[0-9]/;
/** A unit suffix's first character ([LLEX.12]): a letter or one of the glyphs, with their confusables ([LLEX.12.2.1]). */
const UNIT_START = /[\p{L}°′″ʹʺ]/u;
const UNIT_CONT = /[\p{L}\p{N}_°′″ʹʺ]/u;

/**
 * The text's lexemes, in order. A string that is not closed runs to the end
 * of its line (a single-quoted one) or of the text (a triple-quoted one), as
 * an editor shows it while it is typed; the compiler refuses it
 * ([LLEX.13.1.4]).
 * @param {string[]} lines
 * @param {{ line: number, col: number }} [until]  stop there: lines 1-based, a code-point column
 * @returns {Lexeme[]}
 */
export function scan(lines, until) {
    /** @type {Lexeme[]} */
    const out = [];
    let inTriple = false;
    const last = until === undefined ? lines.length : Math.min(until.line, lines.length);
    for (let l = 1; l <= last; l++) {
        const all = [...(lines[l - 1] ?? "")];
        const cps = until !== undefined && l === until.line ? all.slice(0, until.col) : all;
        /** @param {number} start @param {number} end @param {Lexeme["kind"]} kind */
        const push = (start, end, kind) => out.push({ line: l, start, end, kind, text: cps.slice(start, end).join("") });
        let i = 0;
        if (inTriple) {
            const close = tripleEnd(cps, 0);
            if (close < 0) {
                if (cps.length) push(0, cps.length, "string");
                continue;
            }
            push(0, close, "string");
            inTriple = false;
            i = close;
        }
        while (i < cps.length) {
            const c = cps[i];
            if (c === " " || c === "\t") {
                i++;
            } else if (c === "#") {
                push(i, cps.length, "comment");
                i = cps.length;
            } else if (c === '"' && cps[i + 1] === '"' && cps[i + 2] === '"') {
                const close = tripleEnd(cps, i + 3);
                if (close < 0) {
                    push(i, cps.length, "string");
                    inTriple = true;
                    i = cps.length;
                } else {
                    push(i, close, "string");
                    i = close;
                }
            } else if (c === '"') {
                let j = i + 1;
                while (j < cps.length && cps[j] !== '"') j += cps[j] === "\\" ? 2 : 1;
                const end = Math.min(j + 1, cps.length);
                push(i, end, "string");
                i = end;
            } else if (DIGIT.test(c)) {
                const end = numberEnd(cps, i);
                push(i, end, "number");
                i = end;
            } else if (NAME_START.test(c)) {
                let j = i + 1;
                while (j < cps.length && NAME_CONT.test(cps[j])) j++;
                push(i, j, "name");
                i = j;
            } else {
                push(i, i + 1, "punct");
                i++;
            }
        }
    }
    return out;
}

/**
 * Just past the `"""` that closes a triple-quoted string, searching from
 * `from`; -1 if the line does not close it. A backslash escapes what follows.
 * @param {string[]} cps
 * @param {number} from
 */
function tripleEnd(cps, from) {
    for (let j = from; j < cps.length; j++) {
        if (cps[j] === "\\") j++;
        else if (cps[j] === '"' && cps[j + 1] === '"' && cps[j + 2] === '"') return j + 3;
    }
    return -1;
}

/**
 * Just past a numeric or unit literal that starts at `i` ([LLEX.11],
 * [LLEX.12]): a based integer, or a decimal with its fraction and exponent,
 * then a unit suffix with its optional `_`. The withheld `e` of [LLEX.11.3.1]
 * is taken as the exponent when digits follow it.
 * @param {string[]} cps
 * @param {number} i
 */
function numberEnd(cps, i) {
    let j = i;
    const digits = (/** @type {RegExp} */ re) => {
        while (j < cps.length && (re.test(cps[j]) || (cps[j] === "_" && re.test(cps[j + 1] ?? "")))) j++;
    };
    if (cps[i] === "0" && /[xob]/.test(cps[i + 1] ?? "")) {
        j = i + 2;
        digits(/[0-9a-fA-F]/);
        return j;
    }
    digits(DIGIT);
    if (cps[j] === "." && DIGIT.test(cps[j + 1] ?? "")) {
        j++;
        digits(DIGIT);
    }
    if ((cps[j] === "e" || cps[j] === "E")) {
        const sign = cps[j + 1] === "+" || cps[j + 1] === "-" ? 1 : 0;
        if (DIGIT.test(cps[j + 1 + sign] ?? "")) {
            j += 1 + sign;
            digits(DIGIT);
        }
    }
    const u = cps[j] === "_" && UNIT_START.test(cps[j + 1] ?? "") ? j + 1 : j;
    if (UNIT_START.test(cps[u] ?? "")) {
        j = u + 1;
        while (j < cps.length && UNIT_CONT.test(cps[j])) j++;
    }
    return j;
}

/** Each grammar word's class ([LLEX.9.8]), as a type and modifiers. */
const WORDS = new Map(/** @type {Array<[string, { type: number, mods: number }]>} */ ([
    ...GRAMMAR_WORDS.declaration.map((w) => [w, { type: T.keyword, mods: 0 }]),
    ...GRAMMAR_WORDS.action.map((w) => [w, { type: T.keyword, mods: M.action }]),
    ...GRAMMAR_WORDS.clause.map((w) => [w, { type: T.keyword, mods: M.clause }]),
    ...GRAMMAR_WORDS.constant.map((w) => [w, { type: T.keyword, mods: M.constant }]),
    ...GRAMMAR_WORDS.operator.map((w) => [w, { type: T.operator, mods: 0 }]),
]));

const BUILTIN_TYPES = new Set(TYPES.map((t) => t.name));
const CALLABLE = new Set(BUILTINS.map((b) => b.name));
const AGGREGATION = new Set(AGGREGATIONS);

/**
 * The document's tokens, in order.
 * @param {string[]} lines
 * @param {Unit | null} unit  the document as a file of its program; null when it has never parsed
 * @returns {Token[]}
 */
export function tokens(lines, unit) {
    const lexemes = scan(lines);
    const { modules, bare } = imported(unit?.tree ?? null);
    /** The file's services, by their dotted name, to the line each is declared on. */
    const services = new Map((unit?.tree.body ?? []).flatMap((d) => (d._type === "Service" ? [[d.name.join("."), d.lineno]] : [])));
    /** @type {Token[]} */
    const out = [];
    for (let k = 0; k < lexemes.length; k++) {
        const x = lexemes[k];
        /** @param {number} type @param {number} [mods] */
        const add = (type, mods = 0) => out.push({ line: x.line, start: x.start, end: x.end, type, mods });
        if (x.kind === "comment") add(T.comment);
        else if (x.kind === "string") add(T.string);
        else if (x.kind === "number") add(T.number);
        if (x.kind !== "name") continue;
        const prev = lexemes[k - 1], next = lexemes[k + 1];
        const dotBefore = prev?.kind === "punct" && prev.text === "." && prev.line === x.line && prev.end === x.start;
        const qualifier = dotBefore && lexemes[k - 2]?.kind === "name" && lexemes[k - 2].end === prev.start ? lexemes[k - 2].text : null;
        const dotAfter = next?.kind === "punct" && next.text === "." && next.line === x.line && next.start === x.end;
        const member = dotAfter && lexemes[k + 2]?.kind === "name" && lexemes[k + 2].start === next.end ? lexemes[k + 2].text : null;
        const calls = next?.kind === "punct" && next.text === "(" && next.line === x.line;
        // A service's name is dotted, and each of its parts is the service.
        const chain = dotted(lexemes, k);
        const service = chain.length > 1 ? services.get(chain) : undefined;
        if (service !== undefined) {
            add(T.interface, service === x.line ? M.declaration : 0);
            continue;
        }
        const ref = unit === null ? null : refAt(unit, x.line, x.start);
        if (ref !== null && unit !== null) {
            const t = declared(ref, unit, x);
            if (t !== null) {
                add(t.type, t.mods);
                continue;
            }
        }
        // `math.sqrt`, through `import math` (or `as m`), or `sqrt` from `from math import sqrt`.
        const viaModule = qualifier !== null ? modules.get(qualifier) : undefined;
        if (viaModule !== undefined && CALLABLE.has(`${viaModule}.${x.text}`)) {
            add(T.function, M.defaultLibrary);
            continue;
        }
        const m = modules.get(x.text);
        if (member !== null && m !== undefined && CALLABLE.has(`${m}.${member}`)) {
            add(T.namespace, M.defaultLibrary);
            continue;
        }
        if (qualifier === null && calls && (CALLABLE.has(x.text) || CALLABLE.has(bare.get(x.text) ?? "") || AGGREGATION.has(x.text))) {
            add(T.function, M.defaultLibrary);
            continue;
        }
        if (qualifier !== null) continue;
        if (BUILTIN_TYPES.has(x.text)) {
            add(T.type, M.defaultLibrary);
            continue;
        }
        const w = WORDS.get(x.text);
        if (w !== undefined) {
            add(w.type, w.mods);
            continue;
        }
        if (unit !== null && importLine(unit, x.line)) add(T.namespace);
    }
    return out;
}

/**
 * How a name the program declares is coloured; null for a declaration that
 * names nothing a colour tells apart (a test, an import).
 * @param {Ref} ref
 * @param {Unit} unit  the document's
 * @param {Lexeme} x
 * @returns {{ type: number, mods: number } | null}
 */
function declared(ref, unit, x) {
    /** @param {import("./analysis.js").NameRange} r */
    const here = (r) => ref.unit === unit && r.line === x.line && r.start === x.start;
    switch (ref.kind) {
    case "binding": {
        const at = patternBodies(ref.rule.lhs).some((b) => b.binding === ref.name && here(nameRange(unit.lines, b, ref.name)));
        return { type: T.variable, mods: at ? M.declaration : 0 };
    }
    case "slot":
        return { type: T.property, mods: here(nameRange(ref.unit.lines, ref.slot, ref.slot.name)) ? M.declaration : 0 };
    case "decl": {
        const decl = here(nameRange(ref.unit.lines, ref.decl, ref.name)) ? M.declaration : 0;
        switch (ref.decl._type) {
        case "Schema": return { type: T.struct, mods: decl };
        case "Rule": return { type: T.function, mods: decl };
        case "Const": return { type: T.variable, mods: decl | M.readonly };
        case "Service": return { type: T.interface, mods: decl };
        case "Opaque": case "UnitDimension": case "UnitScalar": case "UnitSymbol": case "UnitFormula": case "UnitFxPair":
            return { type: T.type, mods: decl };
        default: return null;
        }
    }
    }
}

/**
 * The dotted name the name lexeme at `k` is part of, `a.b.c`, written with no
 * space around its dots; the name alone if it is part of none.
 * @param {Lexeme[]} xs
 * @param {number} k
 */
export function dotted(xs, k) {
    /** @param {number} i @param {number} j  `xs[i]` and `xs[j]` touch, on one line */
    const touch = (i, j) => xs[i] !== undefined && xs[j] !== undefined && xs[i].line === xs[j].line && xs[i].end === xs[j].start;
    /** @param {number} i */
    const isDot = (i) => xs[i]?.kind === "punct" && xs[i].text === ".";
    let a = k, b = k;
    while (isDot(a - 1) && xs[a - 2]?.kind === "name" && touch(a - 2, a - 1) && touch(a - 1, a)) a -= 2;
    while (isDot(b + 1) && xs[b + 2]?.kind === "name" && touch(b, b + 1) && touch(b + 1, b + 2)) b += 2;
    return xs.slice(a, b + 1).map((x) => x.text).join("");
}

/**
 * The line is in an `import` or `from … import`: its names that are not
 * declarations are module paths.
 * @param {Unit} unit
 * @param {number} line
 */
function importLine(unit, line) {
    return unit.tree.body.some((d) => (d._type === "Import" || d._type === "ImportFrom")
        && line >= d.lineno && line <= (d.end_lineno ?? d.lineno));
}

/**
 * Tokens as LSP sends them: five integers each, the line and start relative
 * to the token before, the length, the type, the modifiers; columns as the
 * client counts them.
 * @param {Token[]} toks  in order
 * @param {string[]} lines
 * @param {Encoding} enc
 * @returns {number[]}
 */
export function encode(toks, lines, enc) {
    /** @type {number[]} */
    const data = [];
    let line = 0, char = 0;
    for (const t of toks) {
        const text = lines[t.line - 1] ?? "";
        const start = toClient(text, t.start, enc), end = toClient(text, t.end, enc);
        if (end <= start) continue;
        const l = t.line - 1;
        data.push(l - line, l === line ? start - char : start, end - start, t.type, t.mods);
        line = l;
        char = start;
    }
    return data;
}
