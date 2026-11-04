// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The program as the REPL edits it (DSTRACE_INTERACTIVE §4.16): an ordered
// list of named definitions, each the text of one top-level declaration.
//
// NOT A DS PARSER. A definition begins at a column-0 header (`schema NAME`,
// `rule NAME`, `service NAME`, …) and runs to the next one; the compiler
// judges every edit. That is the same column-0 structure rules.js already
// relies on to find a rule block. Comment lines just before a header belong to
// the definition they introduce; comments before the first one are the
// program's preamble.
//
// ORDER. DS has one order for everything but rules, and this keeps it when the
// program is written out: `use`, imports, constants, units, schemas, services,
// series, rules, tests. Rules are in the user's order: ready rules fire in
// source order, so their order is behaviour. A new rule goes last; a replaced
// one keeps its place.

/**
 * Each kind of definition: its header at column 0, and its name in it.
 * @type {Array<[string, RegExp, (m: RegExpExecArray) => string]>}
 */
const HEADERS = [
    ["use", /^use\b/, () => "use"],
    ["import", /^from\s+(\S+)\s+import\b/, (m) => m[1]],
    ["const", /^const\s+([A-Za-z_]\w*)/, (m) => m[1]],
    ["unit", /^unit\s+([A-Za-z_]\w*)/, (m) => m[1]],
    ["schema", /^schema\s+([A-Za-z_][\w;.]*)/, (m) => m[1]],
    ["service", /^service\s+([A-Za-z_][\w.]*)/, (m) => m[1]],
    ["series", /^series\s+([A-Za-z_][\w.]*)/, (m) => m[1]],
    ["rule", /^rule\s+([A-Za-z_]\w*)/, (m) => m[1]],
    ["test", /^test\s+("(?:[^"\\]|\\.)*")/, (m) => m[1]],
];

/** The order a program is written in. */
export const ORDER = HEADERS.map(([kind]) => kind);

/** A definition refused before the compiler sees it. */
export class ProgramError extends Error {
    /** @param {string} message */
    constructor(message) {
        super(message);
        this.name = "ProgramError";
    }
}

/**
 * `{ kind, name }` of a column-0 header line, or null.
 * @param {string | undefined} line
 * @returns {{ kind: string, name: string } | null}
 */
export function header(line) {
    if (!line || /^\s/.test(line)) return null;
    for (const [kind, re, name] of HEADERS) {
        const m = re.exec(line);
        if (m !== null) return { kind, name: name(m) };
    }
    return null;
}

/** @param {string} line */
const isComment = (line) => /^#/.test(line);
/** @param {string[]} lines */
const trimBlank = (lines) => {
    let a = 0, b = lines.length;
    while (a < b && !lines[a].trim()) a++;
    while (b > a && !lines[b - 1].trim()) b--;
    return lines.slice(a, b);
};

/** One definition: its kind, its name, and its text. */
export class Definition {
    /**
     * @param {string} kind  one of ORDER
     * @param {string} name
     * @param {string} text
     */
    constructor(kind, name, text) {
        this.kind = kind;
        this.name = name;
        this.text = text;
    }

    /** `rule hot`, as the shell names it. */
    get label() {
        return this.kind === "use" ? "use" : `${this.kind} ${this.name}`;
    }
}

export class ProgramText {
    /** @type {Definition[]} in the order entered; rules in rule order */
    defs = [];
    /** @type {string[]} comments before the first definition */
    preamble = [];

    /**
     * A program's source, split into its definitions.
     * @param {string} text
     * @returns {ProgramText}
     */
    static parse(text) {
        const p = new ProgramText();
        /** @type {{ kind: string, name: string, body: string[] } | null} */
        let cur = null;
        /** @type {string[]} blank and column-0 comment lines since the last content line */
        let held = [];
        const flush = () => {
            if (cur !== null) p.defs.push(new Definition(cur.kind, cur.name, trimBlank(cur.body).join("\n")));
        };
        for (const line of text.replace(/\r\n/g, "\n").split("\n")) {
            const h = header(line);
            if (h !== null) {
                // The comment lines touching a header, no blank line between,
                // introduce it; any before them end what came before.
                let i = held.length;
                while (i > 0 && isComment(held[i - 1])) i--;
                if (cur === null) p.preamble = trimBlank(held.slice(0, i));
                else cur.body.push(...held.slice(0, i));
                flush();
                cur = { ...h, body: [...held.slice(i), line] };
                held = [];
            } else if (!line.trim() || isComment(line) || cur === null) {
                held.push(line);
            } else {
                cur.body.push(...held, line);
                held = [];
            }
        }
        if (cur === null) p.preamble = trimBlank(held);
        else cur.body.push(...held);
        flush();
        return p;
    }

    /**
     * One block typed at the prompt, as exactly one definition (§4.16).
     * @param {string} text
     * @returns {Definition}
     * @throws {ProgramError}
     */
    static definition(text) {
        const p = ProgramText.parse(text);
        if (p.preamble.some((l) => l.trim() && !isComment(l)))
            throw new ProgramError("a definition starts at column 0 with use, from, const, unit, schema, service, "
                                   + "series, rule or test");
        if (p.defs.length !== 1)
            throw new ProgramError(p.defs.length ? `a block is one definition; this one has ${p.defs.length}: `
                                                   + p.defs.map((d) => d.label).join(", ")
                                                 : "nothing to define");
        const d = p.defs[0];
        if (p.preamble.length) d.text = [...p.preamble, d.text].join("\n");
        return d;
    }

    /**
     * The definition of `kind` called `name`, or null.
     * @param {string} kind
     * @param {string} name
     * @returns {Definition | null}
     */
    find(kind, name) {
        return this.defs.find((d) => d.kind === kind && d.name === name) ?? null;
    }

    /**
     * Every definition called `name`, whatever its kind.
     * @param {string} name
     * @returns {Definition[]}
     */
    named(name) {
        return this.defs.filter((d) => d.name === name);
    }

    /**
     * Add `d`, or replace the definition of its kind and name in place.
     * @param {Definition} d
     * @returns {Definition | null} what it replaced
     */
    define(d) {
        const i = this.defs.findIndex((x) => x.kind === d.kind && x.name === d.name);
        if (i < 0) {
            this.defs.push(d);
            return null;
        }
        const old = this.defs[i];
        this.defs[i] = d;
        return old;
    }

    /**
     * Remove the definition called `name`: `del NAME`, `del use`, `del import
     * MODULE`, and `del KIND NAME` where a name is two kinds' (§4.16).
     * @param {string} words  what follows `del`
     * @returns {Definition} what was removed
     * @throws {ProgramError}
     */
    del(words) {
        const w = words.trim().split(/\s+/).filter(Boolean);
        let hits;
        if (w.length === 1 && w[0] === "use") hits = this.defs.filter((d) => d.kind === "use");
        else if (w.length === 2 && ORDER.includes(w[0])) hits = this.defs.filter((d) => d.kind === w[0] && d.name === w[1]);
        else if (w.length === 1) hits = this.named(w[0]).filter((d) => d.kind !== "use");
        else throw new ProgramError("del NAME, del KIND NAME, del use, or del import MODULE");
        if (!hits.length) throw new ProgramError(`no definition called \`${w.join(" ")}\``);
        if (hits.length > 1)
            throw new ProgramError(`\`${w[0]}\` is ${hits.map((d) => `a ${d.kind}`).join(" and ")}: `
                                   + hits.map((d) => `\`del ${d.kind} ${d.name}\``).join(" or "));
        this.defs.splice(this.defs.indexOf(hits[0]), 1);
        return hits[0];
    }

    /** The rules, in rule order. */
    rules() {
        return this.defs.filter((d) => d.kind === "rule");
    }

    /**
     * Move a rule in the rule order (§4.16): `mv RULE N` (from 1), `mv RULE
     * before OTHER`, `mv RULE after OTHER`. Returns its new position, from 1.
     * @param {string} args  what follows `mv`
     * @returns {number}
     * @throws {ProgramError}
     */
    mv(args) {
        const w = args.trim().split(/\s+/).filter(Boolean);
        const rules = this.rules();
        const rule = rules.find((d) => d.name === w[0]);
        if (w.length < 2 || rule === undefined)
            throw new ProgramError(w.length < 2 ? "mv RULE N, mv RULE before OTHER, or mv RULE after OTHER"
                                                : `no rule \`${w[0]}\``);
        const rest = rules.filter((d) => d !== rule);
        let at;
        if (w.length === 2 && /^\d+$/.test(w[1])) {
            at = Number(w[1]) - 1;
            if (at < 0 || at > rest.length) throw new ProgramError(`there are ${rules.length} rules: 1 to ${rules.length}`);
        } else if (w.length === 3 && (w[1] === "before" || w[1] === "after")) {
            const j = rest.findIndex((d) => d.name === w[2]);
            if (j < 0) throw new ProgramError(`no rule \`${w[2]}\``);
            at = w[1] === "before" ? j : j + 1;
        } else throw new ProgramError("mv RULE N, mv RULE before OTHER, or mv RULE after OTHER");
        rest.splice(at, 0, rule);
        // Rules keep their slots among the definitions; only their order changes.
        let r = 0;
        this.defs = this.defs.map((d) => (d.kind === "rule" ? rest[r++] : d));
        return at + 1;
    }

    /** The program as one file, in DS's order, rules in rule order (§4.16). */
    text() {
        const parts = [];
        if (this.preamble.length) parts.push(this.preamble.join("\n"));
        for (const kind of ORDER) for (const d of this.defs) if (d.kind === kind) parts.push(d.text);
        return parts.join("\n\n") + "\n";
    }

    /**
     * How many definitions of each kind, in order, the kinds with none left out.
     * @returns {Array<[string, number]>}
     */
    counts() {
        /** @type {Array<[string, number]>} */
        const all = ORDER.map((kind) => [kind, this.defs.filter((d) => d.kind === kind).length]);
        return all.filter(([, n]) => n);
    }
}
