// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The Rete network at point (DSTRACE_INTERACTIVE §4.13, §8.7): `rete`,
// `rete @N`, `rete /regex/`, `rete schemas` and `rete dot FILE`. Stage 7.
// And `whynot RULE` (§13), which reads one rule's chain the same way.
// Returns results; prints nothing.
//
// WHAT THE NETWORK IS ([IRET.6], [IRET.7.4], [RDSC.4a.7]). One beta node per
// pattern, with that pattern's alpha node on its right, chained left to right
// down to the rule's terminal. The first pattern's beta is a ROOT: its left
// memory holds only the nil token, so what it holds is its alpha's facts, and
// it is shown as the alpha row §4.13 draws. A `no` pattern is a negative beta,
// a root one included. Alpha nodes are shared by rules with the same pattern
// ([IRET.6.6]); nothing here assumes betas are not.
//
// libds names nodes `alfa_N`, `beta_N` and `term_N` by their place in the
// engine's node arrays, so two engines loaded from one `.dsc` name them
// alike. That is what lets two readings be subtracted (§8.7 step 5); a
// reading taken under a different program is not subtracted at all.
//
// PATTERN TEXT (§8.7 step 3) is the rule's own source, found through the
// compiler's location for it and matched to the chain by position. Nothing
// here parses DS: a pattern is the text between the header and the `->`,
// one per line, a bracket left open continuing it ([LGRA.8.3.5]).
//
// A NODE'S CONTENTS need libds's node-contents accessor (§11.2), which libds
// does not have. Its row can be named, and says so.

import { position } from "./grammar.js";
import { RuleError, arrow, blockEnd, blockName } from "./rules.js";
import { fileProblem } from "./files.js";
import { aliases } from "./timelines.js";

/** @import { Refraction, ReteEdge, ReteNetwork, ReteNode } from "@ds-lang/ds" */
/** @import { Row, SessionState } from "./state.js" */
/** @import { Firing, Timeline } from "./timeline.js" */
/** @import { Timelines } from "./timelines.js" */
/** @import { Ds, Paged, Result } from "./types.js" */

/**
 * One rule's chain: its terminal, its compiled name, and its betas in
 * pattern order.
 * @typedef {{ terminal: string, rule: string, betas: string[] }} Chain
 */

/**
 * A network walked into chains (`reading`): its nodes by id, each beta's
 * alpha on its right, the chains, each alpha's rules in chain order, a
 * fingerprint of its shape, and its edges.
 * @typedef {{ nodes: Map<string, ReteNode>, right: Map<string, string>, chains: Chain[],
 *     users: Map<string, string[]>, shape: string, edges: ReteEdge[] }} Reading
 */

/**
 * The header's counts (`summary`).
 * @typedef {{ alpha: number, join: number, rules: number, facts: number, tokens: number }} Summary
 */

/**
 * A row of `rete`: an alpha shown for a positive root, a join, a `no`, or
 * the terminal. A join's `right` is the alpha it reads. `count` and
 * `delta` are null where the engine did not say, or there is nothing to
 * subtract.
 * @typedef {{ n: number, id: string, kind: "alpha" | "join" | "not" | "terminal", head: string, text: string,
 *     also: string[], count: number | null, delta: number | null,
 *     right: { id: string, schema: string, count: number | null, delta: number | null } | null }} NodeRow
 */

/**
 * One rule as `rete` lists it. `unaligned` says how many patterns the source
 * had against how many the network, when the two disagree.
 * @typedef {{ name: string, compiled: string, fired: number, pending: number, refracted: number,
 *     rows: NodeRow[], unaligned: { source: number, network: number } | null }} RuleView
 */

/**
 * An alpha node of `rete schemas`, and the rules that take it.
 * @typedef {{ n: number, id: string, filter: string, count: number | null, delta: number | null,
 *     rules: string[] }} AlphaRow
 */

/** @typedef {{ schema: string, alphas: AlphaRow[] }} SchemaView */

/** @typedef {{ id: bigint, detail: string }} Filtered  a fact an alpha test refused, and why */

/**
 * A stage of `whynot`: a row of the rule's chain, with its schema's facts
 * that pass the alpha test (`candidates`) and those that do not.
 * @typedef {{ n: number, kind: NodeRow["kind"], head: string, text: string, count: number | null,
 *     schema: string | null, candidates: bigint[] | null, filtered: Filtered[] }} Stage
 */

/**
 * Why a rule's chain stops where it does (§13).
 * @typedef {{ why: "blocked", tokens: number | null, by: bigint[] | null }
 *   | { why: "filtered", schema: string | null, filtered: Filtered[] }
 *   | { why: "none", schema: string | null }
 *   | { why: "joins" | "unseen", tokens: number | null, candidates: number }} WhyNot
 */

/**
 * The results this module gives.
 * @typedef {({ type: "rete", tl: Timeline, k: number, summary: Summary, changed: boolean, rules: RuleView[],
 *     filtered: boolean, noSource: boolean } & Paged)
 *   | ({ type: "reteSchemas", tl: Timeline, k: number, summary: Summary, changed: boolean, schemas: SchemaView[] }
 *       & Paged)
 *   | { type: "reteDot", tl: Timeline, k: number, file: string, nodes: number, edges: number }
 *   | { type: "whynot", tl: Timeline, k: number, rule: string, stages: Stage[], stop: number | null,
 *       reason: WhyNot | null, complete: number | null, pending: number | null, fired: number,
 *       last: Firing | null, refracted: number, cooldown: bigint | null, noSource: boolean }} ReteResult
 */

/**
 * @param {string} text
 * @returns {Result}
 */
const error = (text) => ({ type: "error", text });
/** @param {unknown} err */
const message = (err) => (err instanceof Error ? err.message : String(err));

/**
 * Why a command that reads settled points cannot run: a session with nothing
 * in it yet, or a trace with no header.
 * @param {string} command
 * @param {Timeline} tl
 */
const notSettled = (command, tl) => (tl.length === 0
    ? `\`${command}\` reads a settled point, and nothing has run yet`
    : `\`${command}\` reads a settled point, and this trace has no header to find them by`);

export const USAGE = "rete [@N] [/regex/], rete schemas [@N], or rete dot FILE";
export const WHYNOT = "whynot RULE: how far the rule matches at point, and where it stops";
export const CONTENTS ="a node's facts and tokens need libds's node-contents accessor, which is not in "
    + "this build; its counts are in the listing";

// ── one reading of the network ──────────────────────────────────────────

/**
 * A network as `reteNetwork` reports it, walked into chains (§8.7 steps 1-2).
 * @param {ReteNetwork} net
 * @returns {Reading}
 */
export function reading(net) {
    const nodes = new Map(net.nodes.map((n) => [n.id, n]));
    /** @type {Map<string, string>} */
    const parent = new Map(), right = new Map(), feeds = new Map();
    for (const { fromId, toId } of net.edges) {
        const from = nodes.get(fromId), to = nodes.get(toId);
        if (from === undefined || to === undefined) continue;
        if (to.kind === "terminal") feeds.set(toId, fromId);
        else if (from.kind === "alpha") right.set(toId, fromId);
        else parent.set(toId, fromId);
    }
    /** @type {Chain[]} */
    const chains = [];
    for (const t of net.nodes) {
        if (t.kind !== "terminal") continue;
        /** @type {string[]} */
        const betas = [];
        const seen = new Set();
        for (let b = feeds.get(t.id); b !== undefined && !seen.has(b); b = parent.get(b)) {
            seen.add(b);
            betas.unshift(b);
        }
        chains.push({ terminal: t.id, rule: t.label, betas });
    }
    /** @type {Map<string, string[]>} alpha id -> the rules whose chains take it, in chain order */
    const users = new Map();
    for (const c of chains) for (const b of c.betas) {
        const a = right.get(b);
        if (a === undefined) continue;
        const us = users.get(a) ?? [];
        users.set(a, us);
        if (!us.includes(c.rule)) us.push(c.rule);
    }
    const shape = JSON.stringify([net.nodes.map((n) => [n.id, n.kind, n.label, n.filter, n.isNegative]),
                                  net.edges.map((e) => [e.fromId, e.toId])]);
    return { nodes, right, chains, users, shape, edges: net.edges };
}

/**
 * Node `id` of reading `r`. A chain names only nodes the network has.
 * @param {Reading} r
 * @param {string} id
 * @returns {ReteNode}
 */
function node(r, id) {
    const n = r.nodes.get(id);
    if (n === undefined) throw new TypeError(`no node ${id} in the network`);
    return n;
}

/**
 * Whether beta `b`, at `i` in its chain, is shown as a join: every beta but
 * a positive root.
 * @param {Reading} r
 * @param {string} b
 * @param {number} i
 */
const isJoin = (r, b, i) => i > 0 || node(r, b).isNegative;

/**
 * `{ alpha, join, rules, facts, tokens }` for the header.
 * @param {Reading} r
 * @returns {Summary}
 */
export function summary(r) {
    /** @type {Set<string>} */
    const joins = new Set();
    for (const c of r.chains) c.betas.forEach((b, i) => { if (isJoin(r, b, i)) joins.add(b); });
    let alpha = 0, facts = 0, tokens = 0;
    for (const n of r.nodes.values()) if (n.kind === "alpha") {
        alpha++;
        facts += n.occupancy ?? 0;
    }
    for (const b of joins) tokens += node(r, b).occupancy ?? 0;
    return { alpha, join: joins.size, rules: r.chains.length, facts, tokens };
}

// ── pattern text from the source ────────────────────────────────────────

/**
 * `[depth change, text without a trailing comment]` for one line: brackets
 * outside string literals, and a `#` comment after whitespace.
 * @param {string} line
 * @returns {[number, string]}
 */
function scan(line) {
    let depth = 0, cut = line.length;
    /** @type {string | null} */
    let quote = null;
    for (let i = 0; i < line.length; i++) {
        const c = line[i];
        if (quote !== null) {
            if (c === "\\") i++;
            else if (c === quote) quote = null;
        } else if (c === '"' || c === "'") quote = c;
        else if (c === "(" || c === "[" || c === "{") depth++;
        else if (c === ")" || c === "]" || c === "}") depth--;
        else if (c === "#" && (i === 0 || /\s/.test(line[i - 1]))) {
            cut = i;
            break;
        }
    }
    return [depth, line.slice(0, cut)];
}

/** @param {string} s */
const tidy = (s) => s.replace(/\s+/g, " ").replace(/([([{]) /g, "$1").replace(/ ([)\]}])/g, "$1").trim();

/**
 * A rule's patterns, from its block: the lines after its header up to its
 * `->`, less a docstring, comments and blank lines. A line that leaves a
 * bracket open continues on the next ([LGRA.8.3.5]).
 * @param {string[]} lines  the block, header first, `->` excluded
 * @returns {string[]}
 */
export function patterns(lines) {
    /** @type {string[]} */
    const out = [];
    /** @type {string | null} */
    let cur = null;
    let depth = 0, inDoc = false;
    for (const raw of lines.slice(1)) {
        const t = raw.trim();
        if (inDoc) {
            if (t.includes('"""')) inDoc = false;
            continue;
        }
        if (cur === null) {
            if (!t || t.startsWith("#")) continue;
            // [LGRA.6.5]: a bare string first in the body is its docstring.
            if (!out.length && t.startsWith('"""')) {
                inDoc = !t.slice(3).includes('"""');
                continue;
            }
            if (!out.length && t.startsWith('"')) continue;
        }
        const [d, text] = scan(t);
        cur = cur === null ? text : `${cur} ${text}`;
        depth += d;
        if (depth <= 0) {
            out.push(tidy(cur));
            cur = null;
            depth = 0;
        }
    }
    if (cur !== null) out.push(tidy(cur));
    return out;
}

/**
 * `[head, condition]`: a pattern split at its top-level `where`.
 * @param {string} p
 * @returns {[string, string]}
 */
export function splitPattern(p) {
    let depth = 0;
    /** @type {string | null} */
    let quote = null;
    for (let i = 0; i < p.length; i++) {
        const c = p[i];
        if (quote !== null) {
            if (c === "\\") i++;
            else if (c === quote) quote = null;
        } else if (c === '"' || c === "'") quote = c;
        else if ("([{".includes(c)) depth++;
        else if (")]}".includes(c)) depth--;
        else if (depth === 0 && p.startsWith(" where ", i)) return [p.slice(0, i), p.slice(i + 7).trim()];
    }
    return [p, ""];
}

/**
 * The block of rule `name` in `sources`: at the compiler's location for it
 * where the text agrees, else the one header naming it. null when neither.
 * From its header to its `->`, or `whole`, to the end of its actions.
 * @param {Array<[string, string]>} sources
 * @param {string} name
 * @param {{ srcFile?: string | null, srcLine?: number | bigint | null } | null} meta
 * @param {{ whole?: boolean }} [opts]
 * @returns {string[] | null}
 */
export function ruleBlock(sources, name, meta, { whole = false } = {}) {
    const texts = new Map(sources);
    /** @type {[string[], number] | null} */
    let at = null;
    const located = meta?.srcFile ? texts.get(meta.srcFile) : undefined;
    if (located !== undefined && meta?.srcLine) {
        const lines = located.split("\n"), i = Number(meta.srcLine) - 1;
        if (i >= 0 && i < lines.length && blockName(lines[i]) === name) at = [lines, i];
    }
    if (at === null) for (const text of texts.values()) {
        const lines = text.split("\n"), i = lines.findIndex((ln) => blockName(ln) === name);
        if (i >= 0) {
            at = [lines, i];
            break;
        }
    }
    if (at === null) return null;
    const [lines, i] = at;
    try {
        return lines.slice(i, whole ? blockEnd(lines, i) : arrow(lines, i));
    } catch (err) {
        if (err instanceof RuleError) return null;
        throw err;
    }
}

// ── the views ───────────────────────────────────────────────────────────

/**
 * `now - before` for a node, or null when there is nothing to subtract.
 * @param {Reading} now
 * @param {Reading | null} before
 * @param {string} id
 * @returns {number | null}
 */
function delta(now, before, id) {
    if (before === null) return null;
    const a = now.nodes.get(id)?.occupancy, b = before.nodes.get(id)?.occupancy;
    return a === undefined || a === null || b === undefined || b === null ? null : a - b;
}

/**
 * Each rule's chain as rows (§4.13).
 * @param {Reading} now  a reading at point
 * @param {Reading | null} before  one at the previous settled point, same program
 * @param {object} ctx
 * @param {(compiled: string) => string} ctx.name  the rule as the user knows it
 * @param {(compiled: string) => string[] | null} ctx.source  its patterns, or null
 * @param {Map<string, number>} ctx.fired  by user name, up to point
 * @param {Map<string, number>} ctx.refracted  by user name
 * @param {RegExp | null} ctx.filter  over user names
 * @returns {RuleView[]}
 */
export function ruleRows(now, before, { name, source, fired, refracted, filter }) {
    /** @type {RuleView[]} */
    const rules = [];
    let n = 0;
    for (const c of now.chains) {
        const user = name(c.rule);
        if (filter !== null && !filter.test(user) && !filter.test(c.rule)) continue;
        const pats = source(c.rule);
        const aligned = pats !== null && pats.length === c.betas.length;
        /** @type {NodeRow[]} */
        const rows = [];
        c.betas.forEach((b, i) => {
            const beta = node(now, b), a = now.right.get(b), alpha = a === undefined ? null : node(now, a);
            let head, text;
            if (aligned) [head, text] = splitPattern(pats[i]);
            else {
                head = (beta.isNegative ? "no " : "") + (alpha?.label ?? "join");
                text = alpha?.filter ?? "";
            }
            if (!isJoin(now, b, i)) {
                const also = (a === undefined ? [] : now.users.get(a) ?? []).filter((r) => r !== c.rule).map(name);
                rows.push({ n: ++n, id: a ?? b, kind: "alpha", head, text, also,
                            count: alpha?.occupancy ?? null, delta: delta(now, before, a ?? b), right: null });
                return;
            }
            rows.push({ n: ++n, id: b, kind: beta.isNegative ? "not" : "join", head, text, also: [],
                        count: beta.occupancy, delta: delta(now, before, b),
                        right: a === undefined || alpha === null ? null
                            : { id: a, schema: alpha.label, count: alpha.occupancy, delta: delta(now, before, a) } });
        });
        const t = node(now, c.terminal);
        rows.push({ n: ++n, id: c.terminal, kind: "terminal", head: user, text: "", also: [],
                    count: t.occupancy, delta: delta(now, before, c.terminal), right: null });
        rules.push({ name: user, compiled: c.rule, fired: fired.get(user) ?? 0, pending: t.occupancy ?? 0,
                     refracted: refracted.get(user) ?? 0, rows,
                     unaligned: pats === null || aligned ? null : { source: pats.length, network: c.betas.length } });
    }
    return rules;
}

/**
 * Each schema's alpha nodes, their tests and the rules taking them.
 * @param {Reading} now
 * @param {Reading | null} before
 * @param {(compiled: string) => string} name
 * @returns {SchemaView[]}
 */
export function schemaRows(now, before, name) {
    /** @type {Map<string, ReteNode[]>} */
    const by = new Map();
    for (const nd of now.nodes.values()) {
        if (nd.kind !== "alpha") continue;
        const alphas = by.get(nd.label) ?? [];
        by.set(nd.label, alphas);
        alphas.push(nd);
    }
    let n = 0;
    return [...by.keys()].sort().map((schema) => ({
        schema,
        alphas: (by.get(schema) ?? []).map((a) => ({ n: ++n, id: a.id, filter: a.filter, count: a.occupancy,
                                                     delta: delta(now, before, a.id),
                                                     rules: (now.users.get(a.id) ?? []).map(name) })),
    }));
}

/** @param {unknown} s */
const dotString = (s) => '"' + String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n") + '"';
/**
 * @param {number} n
 * @param {string} one
 */
const plural = (n, one) => `${n} ${one}${n === 1 ? "" : "s"}`;

/**
 * The whole network as Graphviz, with counts on the nodes (§4.13 `rete dot`).
 * A file format, not the terminal's text, so it is made here.
 * @param {Reading} r  a reading
 * @param {(compiled: string) => string} name
 * @param {string} at  where the counts are from, for the graph's label
 * @returns {string}
 */
export function dot(r, name, at) {
    const out = ["digraph rete {", `    label=${dotString(`rete at ${at}`)};`, "    rankdir=TB;",
                 '    node [fontname="monospace"];'];
    /**
     * @param {number | null} x
     * @param {string} one
     */
    const count = (x, one) => (x === null || x === undefined ? "" : `\n${plural(x, one)}`);
    for (const n of r.nodes.values()) {
        let attrs;
        if (n.kind === "alpha")
            attrs = `shape=box, label=${dotString(`α ${n.label}${n.filter ? `\n${n.filter}` : ""}${count(n.occupancy, "fact")}`)}`;
        else if (n.kind === "terminal")
            attrs = `shape=doubleoctagon, label=${dotString(`▶ ${name(n.label)}${count(n.occupancy, "activation")}`)}`;
        else attrs = `shape=ellipse, label=${dotString(`${n.isNegative ? "¬" : "∧"}${count(n.occupancy, "token")}`)}`;
        out.push(`    ${dotString(n.id)} [${attrs}];`);
    }
    // An alpha feeds a join from the right; a join's parent from the left.
    for (const e of r.edges) {
        const from = r.nodes.get(e.fromId);
        if (from === undefined || !r.nodes.has(e.toId)) continue;
        out.push(`    ${dotString(e.fromId)} -> ${dotString(e.toId)}${from.kind === "alpha" ? " [style=dashed]" : ""};`);
    }
    out.push("}", "");
    return out.join("\n");
}

// ── the command ─────────────────────────────────────────────────────────

/**
 * `@N` and `/regex/` after `rete`, or its mode word. `{ error }` when not.
 * @param {string} args
 * @returns {{ mode: "dot", file: string, pos: null, filter: null, error?: undefined }
 *   | { mode: "rules" | "schemas", file: null, pos: { seq: bigint, minus: number } | null, filter: RegExp | null,
 *       error?: undefined }
 *   | { error: string }}
 */
export function parseArgs(args) {
    let rest = args.trim();
    /** @type {"rules" | "schemas" | "dot"} */
    let mode = "rules";
    /** @type {{ seq: bigint, minus: number } | null} */
    let pos = null;
    /** @type {RegExp | null} */
    let filter = null;
    if (rest.startsWith("%")) return { error: "`rete` shows the current timeline's network; `fg %N` to see another's" };
    const m = /^(schemas|dot)(?:\s+|$)/.exec(rest);
    if (m !== null) {
        mode = m[1] === "dot" ? "dot" : "schemas";
        rest = rest.slice(m[0].length);
    }
    if (mode === "dot") {
        const file = rest.trim();
        return file && !/\s/.test(file) ? { mode, file, pos: null, filter: null } : { error: USAGE };
    }
    const at = /^@(\S+)(?:\s+|$)/.exec(rest);
    if (at !== null) {
        pos = position(at[1]);
        if (pos === null) return { error: `\`@${at[1]}\` is not a position; positions are hex` };
        rest = rest.slice(at[0].length);
    }
    if (rest && mode === "rules" && rest.length >= 2 && rest.startsWith("/") && rest.endsWith("/")) {
        try {
            filter = new RegExp(rest.slice(1, -1));
        } catch (err) {
            return { error: `${rest}: ${message(err)}` };
        }
        rest = "";
    }
    return rest ? { error: USAGE } : { mode, file: null, pos, filter };
}

/**
 * A programming error, which a refusal must not hide.
 * @param {unknown} err
 */
const isBug = (err) => err instanceof TypeError || err instanceof ReferenceError || err instanceof RangeError;

export class Rete {
    /** @type {SessionState} */
    #s;
    /** @type {Ds | null} */
    #ds;
    /** @type {((path: string, bytes: Uint8Array) => void) | null} */
    #write;
    /** @type {Timelines} */
    #tls;

    /**
     * @param {SessionState} state
     * @param {object} ports
     * @param {Ds | null} ports.ds  a `@ds-lang/ds` API
     * @param {((path: string, bytes: Uint8Array) => void) | null} ports.write
     * @param {Timelines} timelines
     */
    constructor(state, { ds, write }, timelines) {
        this.#s = state;
        this.#ds = ds;
        this.#write = write;
        this.#tls = timelines;
    }

    /**
     * `rete …`
     * @param {string} args
     * @returns {Result[]}
     */
    command(args) {
        const s = this.#s, tl = s.tl;
        if (this.#ds === null || s.at(0).queries === null) return [error("`rete` needs the program's .dsc")];
        const a = parseArgs(args);
        if (a.error !== undefined) return [error(a.error)];
        let k = s.k;
        if (a.pos !== null) {
            const got = tl.resolve(a.pos.seq, a.pos.minus);
            if (got === null) return [error("past the last position")];
            k = got[0];
        }
        if (!tl.canonical) return [error(notSettled("rete", tl))];
        if (!tl.isSettled(k)) {
            const lo = tl.prevSettled(k), hi = tl.nextSettled(k);
            return [{ type: "midCascade", word: "rete", tl, lo: lo || 0, hi: hi ?? tl.length }];
        }
        const n = s.cur;
        const al = aliases(this.#tls.rulesOf(n));
        /** @param {string} compiled */
        const name = (compiled) => al.get(compiled) ?? compiled;
        const sources = this.#tls.sourcesOf(n);
        /** @type {Reading} */
        let now;
        /** @type {Map<string, string[] | null>} */
        let blocks;
        /** @type {Refraction[]} */
        let refracted;
        /** @type {Reading | null} */
        let before = null;
        try {
            [now, blocks, refracted] = this.#tls.readEngine(n, k, (eng) => {
                const r = reading(eng.reteNetwork({ includeOccupancy: true }));
                /** @type {Map<string, string[] | null>} */
                const b = new Map(r.chains.map((c) => {
                    const block = ruleBlock(sources, c.rule, eng.rules.get(c.rule) ?? null);
                    return [c.rule, block === null ? null : patterns(block)];
                }));
                /** @type {[Reading, Map<string, string[] | null>, Refraction[]]} */
                const got = [r, b, a.mode === "rules" ? eng.refractedActivations() : []];
                return got;
            });
            const prev = a.mode === "dot" ? null : tl.prevSettled(k);
            if (prev !== null) before = this.#tls.readEngine(n, prev, (eng) => reading(eng.reteNetwork({ includeOccupancy: true })));
        } catch (err) {
            if (isBug(err)) throw err;
            return [error(`the engine refused: ${message(err)}`)];
        }
        const changed = before !== null && before.shape !== now.shape;
        if (changed) before = null;
        if (a.mode === "dot") return this.#dot(now, name, tl, k, a.file);
        const head = { tl, k, summary: summary(now), changed };
        if (a.mode === "schemas") {
            const schemas = schemaRows(now, before, name);
            s.rows = schemas.flatMap((sc) => sc.alphas.map((x) => /** @satisfies {Row} */ (["node", x])));
            return [{ type: "reteSchemas", ...head, schemas }];
        }
        /** @type {Map<string, number>} */
        const fired = new Map(), refr = new Map();
        for (const f of tl.firingsIn(0, k)) fired.set(f.rule, (fired.get(f.rule) ?? 0) + 1);
        for (const x of refracted) refr.set(name(x.ruleName), (refr.get(name(x.ruleName)) ?? 0) + 1);
        const rules = ruleRows(now, before, { name, source: (r) => blocks.get(r) ?? null, fired, refracted: refr,
                                              filter: a.filter });
        s.rows = rules.flatMap((r) => r.rows.map((x) => /** @satisfies {Row} */ (["node", x])));
        return [{ type: "rete", ...head, rules, filtered: a.filter !== null, noSource: !sources.length }];
    }

    /**
     * `whynot RULE` (§13, DSDB_MCP.md §10.6): how far the rule's chain matches
     * at point, and where it stops. Each pattern's candidates are the live
     * facts of its schema its alpha test passes, found by tracing each through
     * the alpha nodes; a join's count is the tokens that reached it. Which
     * join test rejected which pair needs the node contents, and the result
     * says so.
     * @param {string} args
     * @returns {Result[]}
     */
    whynot(args) {
        const s = this.#s, tl = s.tl, k = s.k;
        if (this.#ds === null || s.at(0).queries === null) return [error("`whynot` needs the program's .dsc")];
        const want = args.trim();
        if (!/^[A-Za-z_]\w*$/.test(want)) return [error(WHYNOT)];
        if (!tl.canonical) return [error(notSettled("whynot", tl))];
        if (!tl.isSettled(k)) {
            const lo = tl.prevSettled(k), hi = tl.nextSettled(k);
            return [{ type: "midCascade", word: "whynot", tl, lo: lo || 0, hi: hi ?? tl.length }];
        }
        const n = s.cur;
        const al = aliases(this.#tls.rulesOf(n));
        /** @param {string} compiled */
        const name = (compiled) => al.get(compiled) ?? compiled;
        const sources = this.#tls.sourcesOf(n);
        let got;
        try {
            got = this.#tls.readEngine(n, k, (eng) => {
                const r = reading(eng.reteNetwork({ includeOccupancy: true }));
                const c = r.chains.find((x) => name(x.rule) === want || x.rule === want);
                if (c === undefined) return null;
                const meta = eng.rules.get(c.rule) ?? null;
                const block = ruleBlock(sources, c.rule, meta);
                // Each alpha on the chain: the live facts of its schema, each
                // through the alpha tests ([RDAP1c]).
                /** @type {Map<string, { schema: string, passed: bigint[], filtered: Filtered[] }>} */
                const alphas = new Map();
                for (const b of c.betas) {
                    const a = r.right.get(b);
                    if (a === undefined || alphas.has(a)) continue;
                    const schema = node(r, a).label;
                    /** @type {bigint[]} */
                    const passed = [];
                    /** @type {Filtered[]} */
                    const filtered = [];
                    for (const f of eng.facts({ schema })) {
                        const step = eng.reteMatchTrace(f.id).find((x) => x.nodeId === a);
                        if (step === undefined) continue;
                        if (step.result === "passed") passed.push(BigInt(f.id));
                        else filtered.push({ id: BigInt(f.id), detail: step.detail });
                    }
                    alphas.set(a, { schema, passed, filtered });
                }
                const refracted = eng.refractedActivations().filter((x) => x.ruleName === c.rule).length;
                return { r, c, meta, pats: block === null ? null : patterns(block), alphas, refracted };
            });
        } catch (err) {
            if (isBug(err)) throw err;
            return [error(`the engine refused: ${message(err)}`)];
        }
        if (got === null) return [error(`no rule \`${want}\` in %${n}'s program`)];
        const { r, c, meta, pats, alphas } = got, user = name(c.rule);
        const [rule] = ruleRows({ ...r, chains: [c] }, null, { name, source: () => pats, fired: new Map(),
                                                               refracted: new Map(), filter: null });
        const rows = rule.rows.filter((x) => x.kind !== "terminal");
        /** @type {Stage[]} */
        const stages = rows.map((x) => {
            const id = x.kind === "alpha" ? x.id : x.right?.id;
            const a = id === undefined ? null : alphas.get(id) ?? null;
            return { n: x.n, kind: x.kind, head: x.head, text: x.text, count: x.count,
                     schema: a?.schema ?? null, candidates: a?.passed ?? null, filtered: a?.filtered ?? [] };
        });
        // Where it stops. A beta counts the tokens in its left memory: what
        // arrived from the patterns before it ([RDBG.6.6.3]). So what gets
        // through a stage is the next one's count; through a positive root,
        // its alpha's facts. What gets through the last is not counted (the
        // terminal counts only activations not yet fired) except where it
        // follows: a root, or a `no` with nothing to block. Elsewhere it
        // needs the node contents.
        const last = stages.length - 1;
        /**
         * @param {number} i
         * @returns {number | null}
         */
        const input = (i) => (i === 0 ? 1 : stages[i].count);
        /**
         * @param {number} i
         * @returns {number | null}
         */
        const output = (i) => {
            if (i < last) return stages[i + 1].count;
            const x = stages[i];
            if (x.kind === "alpha") return x.count;
            if (!x.candidates?.length) return x.kind === "not" ? input(i) : 0;
            return null;
        };
        /** @type {number | null} */
        let stop = null;
        /** @type {number | null} */
        let blind = null;
        for (let i = 0; i <= last && stop === null && blind === null; i++) {
            const out = output(i);
            if (out === null) blind = i;
            else if (out === 0) stop = i;
        }
        /** @type {WhyNot | null} */
        let reason = null;
        if (stop !== null) {
            const x = stages[stop];
            if (x.kind === "not") reason = { why: "blocked", tokens: input(stop), by: x.candidates };
            else if (!x.candidates?.length)
                reason = x.filtered.length ? { why: "filtered", schema: x.schema, filtered: x.filtered }
                    : { why: "none", schema: x.schema };
            else reason = { why: "joins", tokens: input(stop), candidates: x.candidates.length };
        } else if (blind !== null && blind === last) {
            const candidates = stages[last].candidates;
            if (candidates !== null) reason = { why: "unseen", tokens: input(last), candidates: candidates.length };
        }
        const complete = stop !== null ? 0 : blind !== null || last < 0 ? null : output(last);
        const frs = tl.firingsIn(0, k).filter((f) => f.rule === user);
        const pending = r.nodes.get(c.terminal)?.occupancy ?? null;
        return [{ type: "whynot", tl, k, rule: user, stages, stop, reason, complete, pending,
                  fired: frs.length, last: frs.length ? frs[frs.length - 1] : null,
                  refracted: got.refracted,
                  cooldown: meta?.coolWindowNs ? BigInt(meta.coolWindowNs) : null,
                  noSource: pats === null }];
    }

    /**
     * @param {Reading} now
     * @param {(compiled: string) => string} name
     * @param {Timeline} tl
     * @param {number} k
     * @param {string} file
     * @returns {Result[]}
     */
    #dot(now, name, tl, k, file) {
        if (this.#write === null) return [error("nowhere to write to")];
        const nm = tl.name(k);
        const at = nm === null ? "@start" : `@${nm[0].toString(16).padStart(8, "0")}${"-".repeat(nm[1])}`;
        try {
            this.#write(file, new TextEncoder().encode(dot(now, name, at)));
        } catch (err) {
            return [error(`${file}: ${fileProblem(err)}`)];
        }
        return [{ type: "reteDot", tl, k, file, nodes: now.nodes.size, edges: now.edges.length }];
    }
}
