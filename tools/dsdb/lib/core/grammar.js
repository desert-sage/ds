// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The shell's line grammar (DSTRACE_INTERACTIVE.md §4.2).
//
// This splits a line into a sigil, a scope, timelines and a body, or a
// navigation, or a command word. It is SHELL syntax. A DS body is never looked
// into here: it is carried as text to the compiler (§1, "the compiler is the
// only parser"). The only DS-shaped tokens read here are durations such as
// `500_ms` in navigation, which §4.2 defines as part of the shell's grammar.
//
// NUMBERS (DSDB.md §4): a position's seq and a clock amount are BigInt, as
// everything 64-bit in the format is; a count of records, a bucket and a row
// number are Numbers.

import { header } from "./program-text.js";

export const SIGILS = "?#!^";
export const SCOPES = ".:@";

const POS = /^([0-9A-Fa-f]+)(-*)$/;
const DUR = /^(\d+(?:\.\d+)?)_(ns|us|µs|ms|s|min|h|d)$/;
const TIMELINE = /^%(\d+)$/;
const UNIT_NS = new Map([
    ["ns", 1], ["us", 1_000], ["µs", 1_000], ["ms", 1_000_000],
    ["s", 1_000_000_000], ["min", 60_000_000_000],
    ["h", 3_600_000_000_000], ["d", 86_400_000_000_000],
]);

/** Command words by the stage that brings them (§12). A word from a later
    stage is recognised, so it can say when it arrives rather than "unknown". */
export const LATER = new Map();

/** Changes to a timeline's inputs at point, written `from here WORD …`
    (§4.16). The bare words are not commands: a bare `emit` is left to DS. */
export const FROM_HERE = new Set(["emit", "withdraw", "answer", "fail", "silence"]);

export const WORDS = new Set([
    "list", "calls", "help", "quit", "exit", "up", "<", ">", "%",
    "watch", "unwatch", "next", "prev", "save",
    "hyp", "fg", "real", "bg", "stop", "fork", "kill", "match",
    "skip", "change", "add", "rule", "unrule", "rules", "changes", "show", "rete", "why", "whynot", "ls", "del", "mv",
]);

/** The longest `Duration` ([LTIM.1.3.1]), and so the most one advance moves a clock ([NTST.3.1]). */
export const MAX_DURATION_NS = (1n << 63n) - 1n;

/**
 * `500_ms` -> 500000000n. The underscore is required (§4.2): `1d` would
 * otherwise be both hex and a day. Returns null when `tok` is not a duration.
 *
 * The arithmetic is the Python's, on purpose: `round(float(n) * unit)`, an
 * IEEE double product rounded half to even. dsdb's output must be
 * byte-identical to dstrace's (DSDB.md §1), and an exact decimal would differ
 * wherever the double does not land on the exact value. A product past the
 * double's range is not a duration either.
 * @param {string} tok
 * @returns {bigint | null}
 */
export function durationNs(tok) {
    const m = DUR.exec(tok);
    if (!m) return null;
    const unit = /** @type {number} */ (UNIT_NS.get(m[2]));      // DUR admits only UNIT_NS's units
    const ns = Number(m[1]) * unit;
    return Number.isFinite(ns) ? BigInt(roundHalfEven(ns)) : null;
}

/**
 * Python's `round(x)` for a finite double: to the nearest integer, a tie to
 * the even one.
 * @param {number} x
 * @returns {number}
 */
function roundHalfEven(x) {
    const f = Math.floor(x);
    const d = x - f;
    if (d > 0.5) return f + 1;
    if (d < 0.5) return f;
    return f % 2 === 0 ? f : f + 1;
}

/**
 * `1aba--` -> { seq: 0x1aban, minus: 2 }: a seq and its minus signs (§3.3),
 * or null.
 * @param {string} tok
 * @returns {{ seq: bigint, minus: number } | null}
 */
export function position(tok) {
    const m = POS.exec(tok);
    if (!m) return null;
    return { seq: BigInt("0x" + m[1]), minus: m[2].length };
}

/**
 * A parsed line. `kind` is one of query, nav, step, word, row, define, empty,
 * error. A define is a DS definition typed as a block (§4.16), in `body`.
 * Fields not meaningful for a kind keep their defaults.
 *
 * - query: `sigil`, `scope`, `pos` (scope `@` only), `timelines` (Numbers),
 *   `body`
 * - nav: `nav` is one of show, start, end, abs_pos, rel_pos, abs_clock,
 *   rel_clock, bucket, fact_asserted, fact_ended; `pos` for abs_pos;
 *   `amount` a Number for rel_pos and bucket, a BigInt of nanoseconds for
 *   abs_clock and rel_clock
 * - step: `word` n or p, `args` pump, atom, fire or tick
 * - word: `word` and `args`; `fromHere` for a change at a point (§4.16), and
 *   `at`, the move to that point, for `from start` and `from @N`
 * - row: `row`
 * - error: `error`
 */
export class Cmd {
    /**
     * @param {string} kind
     * @param {Partial<Cmd>} [fields]
     */
    constructor(kind, fields = {}) {
        this.kind = kind;
        this.sigil = "";
        this.scope = "";
        /** @type {{ seq: bigint, minus: number } | null} */
        this.pos = null;
        /** @type {number[]} */
        this.timelines = [];
        this.body = "";
        this.word = "";
        this.args = "";
        /** @type {number | null} */
        this.row = null;
        this.nav = "";
        /** @type {number | bigint} a count for rel_pos and bucket, nanoseconds for the clocks */
        this.amount = 0;
        this.error = "";
        this.fromHere = false;
        /** @type {Cmd | null} `from start` or `from @N`: a nav Cmd to the point */
        this.at = null;

        Object.assign(this, fields);
    }
}

/** @param {string} msg */
const error = (msg) => new Cmd("error", { error: msg });

/**
 * @param {string} line
 * @returns {Cmd}
 */
export function parse(line) {
    const s = line.trim();
    if (!s) return new Cmd("empty");
    // §4.16: a DS definition typed at the prompt edits the program.
    if (header(s.split("\n")[0]) !== null) return new Cmd("define", { body: s });
    if (/^\d+$/.test(s)) return new Cmd("row", { row: Number(s) });
    if (SIGILS.includes(s[0]) && s.length > 1 && SCOPES.includes(s[1])) return query(s);
    if (s[0] === "@") return nav(s.slice(1).trim());
    const sp = s.indexOf(" ");
    const head = sp < 0 ? s : s.slice(0, sp);
    const rest = sp < 0 ? "" : s.slice(sp + 1);
    if (head === "n" || head === "p") {
        const unit = rest.trim() || "pump";
        if (!["pump", "atom", "fire", "tick"].includes(unit))
            return error(`\`${head}\` steps by atom, fire or tick, not \`${unit}\``);
        return new Cmd("step", { word: head, args: unit });
    }
    if (WORDS.has(head) || LATER.has(head)) return new Cmd("word", { word: head, args: rest.trim() });
    if (head === "from") {
        // §4.16: `from here`, `from start`, or `from @N`, before a change.
        const m = /^(here|start|@\S+)\s+(\S+)\s*(.*)$/s.exec(rest.trim());
        if (m === null || !FROM_HERE.has(m[2]))
            return error("`from here`, `from start` or `from @N` goes before emit, withdraw, answer, fail or silence");
        let at = null;
        if (m[1] === "start") at = new Cmd("nav", { nav: "start" });
        else if (m[1] !== "here") {
            at = nav(m[1].slice(1));
            if (at.kind !== "nav" || !["start", "end", "abs_pos", "abs_clock"].includes(at.nav))
                return error(`\`from ${m[1]}\` needs a point: a position, @<, @>, or a clock such as @12_s`);
        }
        return new Cmd("word", { word: m[2], args: m[3].trim(), fromHere: true, at });
    }
    if (FROM_HERE.has(head)) return error(`a change at point is written \`from here ${head}\``);
    return error(`no command \`${head}\`; \`help\` lists them`);
}

/**
 * `s` split at its first space.
 * @param {string} s
 * @returns {[string, string]}
 */
function partition(s) {
    const sp = s.indexOf(" ");
    return sp < 0 ? [s, ""] : [s.slice(0, sp), s.slice(sp + 1)];
}

/**
 * @param {string} s  a line starting with a sigil and a scope
 * @returns {Cmd}
 */
function query(s) {
    const c = new Cmd("query", { sigil: s[0], scope: s[1] });
    let rest = s.slice(2);
    if (c.scope === "@") {
        const [tok, tail] = partition(rest);
        c.pos = position(tok);
        if (c.pos === null) return error(`\`@${tok}\` is not a position; positions are hex`);
        rest = tail;
    }
    rest = rest.trim();
    while (rest.startsWith("%")) {
        const [tok, tail] = partition(rest);
        const m = TIMELINE.exec(tok);
        if (!m) return error(`\`${tok}\` is not a timeline; timelines are %0, %1, ...`);
        c.timelines.push(Number(m[1]));
        rest = tail.trim();
    }
    c.body = rest;
    return c;
}

/**
 * @param {string} t  what follows `@`
 * @returns {Cmd}
 */
function nav(t) {
    if (t === "") return new Cmd("nav", { nav: "show" });
    // §4.5: `@<` is the start of time, before any record, and `@>` the end.
    // `@$` stays as an alias for the end. `@0` is an ordinary position, seq 0,
    // like any other hex: the start has its own spelling, so no number needs
    // a special meaning.
    if (t === "<") return new Cmd("nav", { nav: "start" });
    if (t === ">" || t === "$") return new Cmd("nav", { nav: "end" });
    // §4.6: in the fact inspector, `@[` and `@]` bracket the fact's life.
    if (t === "[" || t === "]") return new Cmd("nav", { nav: t === "[" ? "fact_asserted" : "fact_ended" });
    if (t.startsWith("#")) {
        if (/^\d+$/.test(t.slice(1))) return new Cmd("nav", { nav: "bucket", amount: Number(t.slice(1)) });
        return error(`\`@${t}\` needs a bucket number, as \`@#12\``);
    }
    if (t[0] === "+" || t[0] === "-") {
        const neg = t[0] === "-";
        const body = t.slice(1);
        const d = durationNs(body);
        if (d !== null) return new Cmd("nav", { nav: "rel_clock", amount: neg ? -d : d });
        // A COUNT, so decimal: `@+10` is ten records. Positions are hex because
        // they are copied from listings; a step count is typed as a number.
        if (/^\d+$/.test(body)) return new Cmd("nav", { nav: "rel_pos", amount: (neg ? -1 : 1) * Number(body) });
        return error(`\`@${t}\` moves by a count of records or a duration such as \`500_ms\``);
    }
    const d = durationNs(t);
    if (d !== null) return new Cmd("nav", { nav: "abs_clock", amount: d });
    const p = position(t);
    if (p !== null) return new Cmd("nav", { nav: "abs_pos", pos: p });
    return error(`\`@${t}\` is neither a hex position nor a duration with its \`_\``);
}
