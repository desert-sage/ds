// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Editing the program (DSTRACE_INTERACTIVE §4.16): the session's program as
// text, by its definitions (program-text.js). A definition block, `del`, `mv`,
// `ls`, `ls rules` and `save code`. Returns results; prints nothing.
//
// The program's text is the entry file's: the source the `.dsc` embeds, or
// the `.ds` given with -L. Files it imports stay imports, staged beside it.
//
// AN EDIT IS FOR ALL TIME. The changed program is compiled; if the compiler
// refuses, nothing changes. Otherwise `%0` is run again from its inputs under
// it (Timelines.rebuild0), and each hypothesis is forked again at its fork's
// position and has its changes made again, each at its position: positions
// keep their meaning and name points in the new timeline. What the edit did is
// the current timeline's facts at point and firings, before against after.

import { read as readProgram } from "./program.js";
import { ORDER, ProgramError, ProgramText } from "./program-text.js";
import { patterns } from "./rete.js";
import { fileProblem } from "./files.js";
import { INPUT, is } from "./trace.js";
import { slotsText } from "../text/render.js";

/** @import { Change, Hypothesis, Redo } from "./hypotheses.js" */
/** @import { Definition } from "./program-text.js" */
/** @import { SessionState } from "./state.js" */
/** @import { Timeline } from "./timeline.js" */
/** @import { Timelines } from "./timelines.js" */
/** @import { Ds, Paged, Result } from "./types.js" */

/**
 * The results this module gives: an edit made, and what it did at point;
 * the program's definitions, by kind; one kind's; its rules; the program
 * written, or as text.
 * @typedef {{ type: "edited", what: string, inputs: number,
 *     skipped: Array<{ index: number, kind: string, why: string }> }
 *   | { type: "editDiff", tl: Timeline, k: number, timeline: number, added: string[], removed: string[],
 *       firings: Array<[string, number, number]> }
 *   | ({ type: "programList", kinds: Array<[string, Definition[]]> } & Paged)
 *   | ({ type: "definitionList", kind: string, defs: Definition[] } & Paged)
 *   | ({ type: "ruleList",
 *       rules: Array<{ n: number, name: string, pattern: string, patterns: number, fired: number }> } & Paged)
 *   | { type: "savedCode", path: string, counts: Array<[string, number]>, lines: number }
 *   | { type: "code", text: string }} EditResult
 */

/**
 * A hypothesis as an edit finds it, to make again on the rebuilt timeline:
 * where it forked and stood, by position, and its changes after its fork.
 * @typedef {{ n: number, source: number, forkName: [bigint, number] | null, point: [bigint, number] | null,
 *     atEnd: boolean, changes: Change[], rules: number, background: boolean }} Kept
 */

/**
 * @param {string} text
 * @returns {Result}
 */
const error = (text) => ({ type: "error", text });
/** @param {unknown} err */
const message = (err) => (err instanceof Error ? err.message : String(err));

/**
 * A recorded file name's base, as rules.js stages them.
 * @param {string} name
 */
const baseName = (name) => {
    const b = name.replace(/^[<>]+|[<>]+$/g, "").split("/").pop() || "program";
    return b.endsWith(".ds") ? b : b + ".ds";
};

/** `ls` words to kinds. */
const PLURAL = new Map([["uses", "use"], ["imports", "import"], ["consts", "const"], ["units", "unit"],
                        ["schemas", "schema"], ["services", "service"], ["series", "series"], ["rules", "rule"],
                        ["tests", "test"]]);

/**
 * A copy to edit: the definitions are replaced, never changed in place.
 * @param {ProgramText} p
 */
function copy(p) {
    const c = new ProgramText();
    c.defs = [...p.defs];
    c.preamble = [...p.preamble];
    return c;
}

/**
 * Point `name` of `tl` (a `[seq, minus]` or null for the start), at the
 * settled point at or before it; the end if it is past the end.
 * @param {Timeline} tl
 * @param {[bigint, number] | null | undefined} name
 * @returns {number}
 */
export function settledAt(tl, name) {
    let k = 0;
    if (name !== null && name !== undefined) {
        const got = tl.resolve(name[0], name[1]);
        k = got === null ? tl.length : got[0];
    }
    while (k > 0 && !tl.isSettled(k)) k--;
    return k;
}

export class Edit {
    /** @type {SessionState} */
    #s;
    /** @type {Timelines} */
    #tls;
    /** @type {Ds | null} */
    #ds;
    /** @type {((path: string, bytes: Uint8Array) => void) | null} */
    #write;
    /** @type {((files: Map<string, string>, entry: string) => Promise<Uint8Array>) | null} */
    #compileFiles;
    /** @type {(word: string, args: string) => Promise<Result[]>} */
    #redo;
    /** @type {ProgramText | null} */
    #program = null;

    /**
     * @param {SessionState} state
     * @param {object} ports
     * @param {Ds | null} ports.ds  a `@ds-lang/ds` API
     * @param {((path: string, bytes: Uint8Array) => void) | null} ports.write
     * @param {((files: Map<string, string>, entry: string) => Promise<Uint8Array>) | null} ports.compileFiles
     * @param {Timelines} timelines
     * @param {(word: string, args: string) => Promise<Result[]>} redo  a from-here change, at point
     */
    constructor(state, { ds, write, compileFiles }, timelines, redo) {
        this.#s = state;
        this.#tls = timelines;
        this.#ds = ds;
        this.#write = write;
        this.#compileFiles = compileFiles;
        this.#redo = redo;
    }

    // ── the edits (§4.16) ───────────────────────────────────────────────────

    /**
     * A definition block: added, or replacing the one of its kind and name.
     * @param {string} text
     * @returns {Promise<Result[]>}
     */
    async define(text) {
        /** @type {ProgramText} */
        let next;
        /** @type {string} */
        let what;
        try {
            const d = ProgramText.definition(text);
            next = copy(this.program());
            what = next.define(d) === null ? `+ ${d.label}` : `~ ${d.label}`;
        } catch (err) {
            if (err instanceof ProgramError) return [error(err.message)];
            throw err;
        }
        return this.#apply(next, what);
    }

    /**
     * `del NAME`, `del KIND NAME`, `del use`, `del import MODULE`.
     * @param {string} args
     * @returns {Promise<Result[]>}
     */
    async del(args) {
        /** @type {ProgramText} */
        let next;
        /** @type {string} */
        let what;
        try {
            next = copy(this.program());
            what = `- ${next.del(args).label}`;
        } catch (err) {
            if (err instanceof ProgramError) return [error(err.message)];
            throw err;
        }
        return this.#apply(next, what);
    }

    /**
     * `mv RULE N`, `mv RULE before OTHER`, `mv RULE after OTHER`.
     * @param {string} args
     * @returns {Promise<Result[]>}
     */
    async mv(args) {
        /** @type {ProgramText} */
        let next;
        /** @type {string} */
        let what;
        try {
            next = copy(this.program());
            const at = next.mv(args);
            what = `rule ${args.trim().split(/\s+/)[0]} moved to ${at} of ${next.rules().length}`;
        } catch (err) {
            if (err instanceof ProgramError) return [error(err.message)];
            throw err;
        }
        return this.#apply(next, what);
    }

    /**
     * Compile `next`, and rebuild every timeline under it.
     * @param {ProgramText} next
     * @param {string} what  the edit, for its messages
     * @returns {Promise<Result[]>}
     */
    async #apply(next, what) {
        const s = this.#s, ds = this.#ds, compileFiles = this.#compileFiles;
        if (compileFiles === null || ds === null) return [error("editing the program needs the compiler")];
        const text = next.text();
        let dsc;
        try {
            dsc = await compileFiles(this.#staged(text), this.#entry());
        } catch (err) {
            if (!(err instanceof Error && err.name === "CompileRefused")) throw err;
            return [error(`the program with ${what} does not compile; nothing changed`),
                    ...err.message.split("\n").map(error),
                    { type: "note", text: "(its line numbers are the program's as `save code` would write it)" }];
        }
        const cur = s.cur;
        const before = this.#snapshot();
        /** @type {Kept[]} */
        const hyps = [];
        for (const v of [...s.views.values()].sort((a, b) => a.n - b.n)) {
            const h = v.hyp;
            if (h === null) continue;
            const src = s.at(h.source);
            hyps.push({ n: v.n, source: h.source, forkName: src.tl.name(h.forkK), point: v.tl.name(v.k),
                        atEnd: v.k === v.tl.length, changes: h.changes.filter((c) => c[2] >= h.forkK),
                        rules: h.rules.length, background: h.background });
        }
        // A point at a timeline's end stays at its end; any other keeps its
        // position, which may now name another moment (§4.16).
        const v0was = s.at(0);
        const point0 = v0was.k === v0was.tl.length ? "end" : v0was.tl.name(v0was.k);
        for (const x of hyps) {
            const v = s.at(x.n);
            v.hyp?.close();
            v.queries?.close();
            s.views.delete(x.n);
        }
        const skipped = this.#tls.rebuild0(dsc, readProgram(ds, dsc));
        this.#program = next;
        const v0 = s.at(0);
        v0.k = s.live || point0 === "end" ? v0.tl.length : settledAt(v0.tl, point0);
        /** @type {string[]} */
        const notes = [];
        for (const x of hyps) notes.push(...await this.#rebuild(x));
        s.cur = s.views.has(cur) ? cur : 0;
        s.rows = [];
        s.stack = [];
        const inputs = s.at(0).tl.records.filter((r) => INPUT.has(r.kind)).length;
        return [{ type: "edited", what, inputs, skipped: skipped.map(([r, why]) => ({ index: r.index, kind: r.kind, why })) },
                ...notes.map((t) => /** @satisfies {Result} */ ({ type: "note", text: t })), this.#diff(before)];
    }

    /**
     * Hypothesis `x` again, on its rebuilt source: forked at its fork's
     * position, its changes made again at theirs.
     * @param {Kept} x
     * @returns {Promise<string[]>}
     */
    async #rebuild(x) {
        const s = this.#s;
        if (x.rules) return [`%${x.n} changed rules from a point, which is withdrawn; it is closed`];
        if (!s.views.has(x.source)) return [`%${x.n}'s source %${x.source} is gone; it is closed`];
        const src = s.at(x.source);
        /** @type {Hypothesis} */
        let h;
        try {
            [h] = this.#tls.openHypothesis(x.source, settledAt(src.tl, x.forkName), new Set(), { number: x.n });
        } catch (err) {
            if (err instanceof TypeError || err instanceof ReferenceError) throw err;
            return [`%${x.n} cannot fork again: ${message(err)}; it is closed`];
        }
        h.background = x.background;
        s.cur = x.n;
        for (const c of x.changes) {
            const redo = c[3];
            if (redo === null || redo === undefined) continue;
            s.k = settledAt(s.tl, redo.at);
            const args = this.#argsFor(redo);
            /** @param {string} why */
            const halt = (why) => {
                h.halted = [s.tl.length, why];
                return [`%${x.n} halted at its change \`${c[1]}\`: ${why}`];
            };
            if (args === null) return halt("what it names is not in the new timeline");
            const res = await this.#redo(redo.word, args);
            const bad = res.find((r) => r.type === "error" || r.type === "midCascade");
            if (bad !== undefined) return halt(bad.type === "error" ? bad.text : "it was refused");
        }
        s.at(x.n).k = x.atEnd ? s.tl.length : Math.min(settledAt(s.tl, x.point), s.tl.length);
        return [];
    }

    /**
     * A change's arguments in the rebuilt timeline, or null.
     * @param {Redo} redo
     * @returns {string | null}
     */
    #argsFor(redo) {
        const s = this.#s, tl = s.tl;
        const key = redo.fact, call = redo.call;
        if (key) {
            let id = null;
            if (key.input !== undefined) {
                const r = tl.records.filter((x) => x.kind === "FactAssert")[key.input];
                id = r !== undefined && is(r, "FactAssert") ? r.body.fact_id : null;
            } else {
                const f = tl.liveFacts(s.k).find((x) => x.schema === key.schema && slotsText(x.slots) === key.slots);
                id = f?.factId ?? null;
            }
            return id === null ? null : `#${id}`;
        }
        if (call) {
            const c = tl.calls.filter((x) => x.service === call.service && x.corr === call.corr && x.issued < s.k).pop();
            return c === undefined ? null : `${c.number} ${redo.args}`.trim();
        }
        return redo.args ?? null;
    }

    /**
     * The current timeline's facts at point and firings per rule.
     * @returns {{ n: number, facts: Map<string, number>, fired: Map<string, number> }}
     */
    #snapshot() {
        const s = this.#s, tl = s.tl;
        /** @type {Map<string, number>} */
        const facts = new Map(), fired = new Map();
        for (const f of tl.liveFacts(s.k)) {
            const key = `${f.schema}  ${slotsText(f.slots)}`;
            facts.set(key, (facts.get(key) ?? 0) + 1);
        }
        for (const f of tl.firingsIn(0, s.k)) fired.set(f.rule, (fired.get(f.rule) ?? 0) + 1);
        return { n: s.cur, facts, fired };
    }

    /**
     * What the edit did to the current timeline, at point (§4.16).
     * @param {{ facts: Map<string, number>, fired: Map<string, number> }} before
     * @returns {Result}
     */
    #diff(before) {
        const s = this.#s, after = this.#snapshot();
        /** @type {string[]} */
        const added = [], removed = [];
        for (const [key, n] of after.facts) for (let i = n - (before.facts.get(key) ?? 0); i > 0; i--) added.push(key);
        for (const [key, n] of before.facts) for (let i = n - (after.facts.get(key) ?? 0); i > 0; i--) removed.push(key);
        /** @type {Array<[string, number, number]>} */
        const firings = [];
        for (const rule of new Set([...before.fired.keys(), ...after.fired.keys()])) {
            const a = before.fired.get(rule) ?? 0, b = after.fired.get(rule) ?? 0;
            if (a !== b) firings.push([rule, a, b]);
        }
        return { type: "editDiff", tl: s.tl, k: s.k, timeline: s.cur, added: added.sort(), removed: removed.sort(), firings };
    }

    /**
     * The program's files for the compiler: this one, and the files the
     * source it came from imports, by their base names.
     * @param {string} text
     */
    #staged(text) {
        /** @type {Map<string, string>} */
        const files = new Map();
        const src = this.#tls.sourcesOf(0);
        src.slice(1).forEach(([name, t]) => files.set(baseName(name), t));
        files.set(this.#entry(), text);
        return files;
    }

    #entry() {
        const src = this.#tls.sourcesOf(0);
        return src.length ? baseName(src[0][0]) : "program.ds";
    }

    /**
     * The program's text, read once from its source.
     * @returns {ProgramText}
     * @throws {ProgramError}
     */
    program() {
        if (this.#program === null) {
            if (this.#s.at(0).queries === null) throw new ProgramError("editing the program needs the program's .dsc");
            const src = this.#tls.sourcesOf(0);
            if (!src.length)
                throw new ProgramError("the program's source is not available: the .dsc was stripped; give its .ds with -L");
            this.#program = ProgramText.parse(src[0][1]);
        }
        return this.#program;
    }

    /**
     * @param {() => Result[]} fn
     * @returns {Result[]}
     */
    #guard(fn) {
        try {
            return fn();
        } catch (err) {
            if (err instanceof ProgramError) return [error(err.message)];
            throw err;
        }
    }

    /**
     * `ls`, `ls rules`, `ls schemas`, …
     * @param {string} args
     * @returns {Result[]}
     */
    ls(args) {
        return this.#guard(() => {
            const p = this.program(), w = args.trim();
            if (!w) {
                /** @type {Array<[string, Definition[]]>} */
                const kinds = ORDER.map((k) => [k, p.defs.filter((d) => d.kind === k)]);
                return [{ type: "programList", kinds: kinds.filter(([, ds]) => ds.length) }];
            }
            const kind = PLURAL.get(w) ?? (ORDER.includes(w) ? w : null);
            if (kind === null) return [error(`ls, or ls ${[...PLURAL.keys()].join(", ")}`)];
            if (kind !== "rule") return [{ type: "definitionList", kind, defs: p.defs.filter((d) => d.kind === kind) }];
            const s = this.#s;
            /** @type {Map<string, number>} */
            const fired = new Map();
            for (const f of s.tl.firingsIn(0, s.k)) fired.set(f.rule, (fired.get(f.rule) ?? 0) + 1);
            return [{
                type: "ruleList",
                rules: p.rules().map((d, i) => {
                    const lines = d.text.split("\n");
                    const hd = lines.findIndex((l) => /^rule\s/.test(l));
                    const a = lines.findIndex((l) => l.trimEnd() === "->");
                    const pats = patterns(lines.slice(hd, a < 0 ? lines.length : a));
                    return { n: i + 1, name: d.name, pattern: pats[0] ?? "", patterns: pats.length,
                             fired: fired.get(d.name) ?? 0 };
                }),
            }];
        });
    }

    /**
     * `show rule NAME`, `show schema NAME`, …: a definition's text.
     * @param {string} args
     * @returns {Result[]}
     */
    show(args) {
        return this.#guard(() => {
            const m = /^(\w+)\s+(\S+)$/.exec(args.trim());
            if (m === null || !ORDER.includes(m[1])) return [error("show KIND NAME, as show rule hot")];
            const d = this.program().find(m[1], m[2]);
            if (d === null) return [error(`no ${m[1]} \`${m[2]}\` in the program`)];
            return d.text.split("\n").map((text) => /** @satisfies {Result} */ ({ type: "note", text }));
        });
    }

    /**
     * The program as `save code` writes it, unwritten.
     * @returns {Result[]}
     */
    code() {
        return this.#guard(() => [{ type: "code", text: this.program().text() }]);
    }

    /**
     * `save code FILE` (§4.16): the program as one file.
     * @param {string} args
     * @returns {Result[]}
     */
    saveCode(args) {
        return this.#guard(() => {
            const parts = args.split(/\s+/).filter(Boolean);
            if (parts.length !== 1) return [error("save code FILE")];
            const p = this.program(), text = p.text();
            if (this.#write === null) return [error("nowhere to save to")];
            try {
                this.#write(parts[0], new TextEncoder().encode(text));
            } catch (err) {
                return [error(`${parts[0]}: ${fileProblem(err)}`)];
            }
            return [{ type: "savedCode", path: parts[0], counts: p.counts(), lines: text.split("\n").length - 1 }];
        });
    }
}
