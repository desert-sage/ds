// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Derivation trees (DSTRACE_INTERACTIVE §4.14, §8.8): `why #N`, `why !N`,
// `why RULE TT`, `depth D`, and `why` in the fact and firing inspectors.
// Stage 8. Returns results; prints nothing.
//
// A TREE IS BUILT FROM THE TIMELINE, and three things it does not hold:
//
// - each firing's MATCHED FACTS. A live timeline and a hypothesis keep them
//   from the stream callback (§8.4). In replay they come from the PROVENANCE
//   PASS (§8.8): the program engine, run to the end of the trace, is itself an
//   engine timeline and keeps them the same way. Its fact ids and firings are
//   the trace's (the self-check, §8.2), so its index joins straight on;
// - a logical fact's CURRENT SUPPORT, `justifiers` on an engine at point;
// - the SOURCE: binding names and `no` patterns from the rule's left-hand side,
//   the `emit` line from its right, read as `rete` reads it (rete.js).
//
// The graph of causes is a DAG. Every fact and firing gets a number the first
// time it is printed, and is a reference to that number after.

import { patterns, ruleBlock, splitPattern } from "./rete.js";
import { aliases } from "./timelines.js";
import { INPUT, is } from "./trace.js";

/** @import { Justifier, RuleMeta, SlotValue } from "@ds-lang/ds" */
/** @import { Row, SessionState, TreeItem } from "./state.js" */
/** @import { Call, Fact, Firing, Timeline } from "./timeline.js" */
/** @import { Timelines } from "./timelines.js" */
/** @import { TraceRecord } from "./trace.js" */
/** @import { Ds, Result } from "./types.js" */

/** @typedef {{ line: string, lets: string[] }} Emit  an `emit` line and the `let` lines its values come through */

/** @typedef {{ fact: Fact, life: string, ended: number | null }} FactPart  a fact, its lifecycle word, and its end before point */

/**
 * Where a fact came from, under it: an input, with the call it replied to
 * and that call's firing; or a rule's emit, and the firings that support or
 * produced it.
 * @typedef {{ input: number, reply?: Call, emit?: undefined, children: WhyNode[] }
 *   | { input?: undefined, reply?: undefined, emit: Emit | null, children: WhyNode[] }} Causes
 */

/**
 * A node of a derivation tree, beneath its root. A fact or firing printed
 * before is a `ref` to its number, 0 for the root. A binding is `cut` when a
 * bounded tree (api/bound.js) stopped among its children.
 * @typedef {({ kind: "binding", n: number, name: string | null, cut?: boolean } & FactPart & Causes)
 *   | { kind: "firing", n: number, firing: Firing, support: boolean, children: WhyNode[], cut: boolean }
 *   | { kind: "ref", ref: number, firing: Firing }
 *   | { kind: "ref", ref: number, name: string | null, fact: Fact }
 *   | { kind: "missing", name: string | null, id: bigint }
 *   | { kind: "unrecorded" }
 *   | { kind: "absence", text: string, clock: bigint }
 *   | { kind: "condition", what: "cooldown", window: bigint, at: bigint, previous: bigint | null }
 *   | { kind: "condition", what: "sequence", text: string, ts: Array<[string, SlotValue]> }} WhyNode
 */

/** @typedef {{ fact: Fact, firing: Firing | null }} ChainStep  a fact in a cascade, and the firing that emitted it */

/**
 * The input that began a firing's cascade, and the chain from it (§8.8).
 * @typedef {{ input: TraceRecord, chain: ChainStep[], reached: boolean, negated: boolean }} Trigger
 */

/**
 * A firing against the rule's earlier firings: the first for its facts, the
 * same facts again, or facts that became others, `[was, is]`.
 * @typedef {{ kind: "first" } | { kind: "again" } | { kind: "changed", changed: Array<[bigint, bigint]> }} Refiring
 */

/**
 * How a fact ended (§4.14 "why it ended"): the integrator retracted it, its
 * ttl ran out, a successor replaced it, a firing's `withdraw` took it, the
 * activation that emitted it completed; or, for a `logical` fact, its support
 * was lost, because a fact a supporting firing matched ended, or a `no`
 * pattern began to match. `appeared` holds every fact that could have made it
 * match.
 * @typedef {{ kind: "retracted" } | { kind: "ttl" } | { kind: "replaced", by: Fact | null }
 *   | { kind: "withdrawn", firing: Firing | null } | { kind: "completed", firing: Firing | null }
 *   | { kind: "lost", firing: Firing, name: string | null, lost: Fact }
 *   | { kind: "absence", firing: Firing, pattern: string, appeared: Fact[] }
 *   | { kind: "unknown" }} EndHow
 */

/** @typedef {{ fact: Fact, how: EndHow }} EndStep  a fact that ended, and how */

/**
 * A tree's root: a fact, or an activation with its trigger and refraction.
 * It is `cut`, as a node is, when a bounded tree stopped among its children.
 * A fact gone by point carries how it ended, `end`, and what ended that.
 * @typedef {({ kind: "fact", live: boolean, cut?: boolean, end: EndStep[] | null } & FactPart & Causes)
 *   | { kind: "activation", firing: Firing, trigger: Trigger | null, refraction: Refiring | null,
 *       children: WhyNode[], cut?: boolean }} WhyRoot
 */

/**
 * @param {string} text
 * @returns {Result}
 */
const error = (text) => ({ type: "error", text });
/**
 * @param {string} text
 * @returns {Result}
 */
const note = (text) => ({ type: "note", text });
/** @param {unknown} err */
const message = (err) => (err instanceof Error ? err.message : String(err));
/**
 * A programming error, which a refusal must not hide.
 * @param {unknown} err
 */
const isBug = (err) => err instanceof TypeError || err instanceof ReferenceError || err instanceof RangeError;

export const USAGE = "why #N, why !N, why RULE TT, each optionally `depth D`; or `why` in the inspector";

const KEYWORDS = new Set(["where", "within", "then", "latest"]);

/**
 * The binding a pattern body names, or null ([LGRA.8.1]: `type_ref binding?`).
 * @param {string} body
 * @returns {string | null}
 */
export function bindingOf(body) {
    const w = body.trim().split(/\s+/);
    const i = w[0] === "latest" ? 1 : 0;
    const b = w[i + 1];
    return b !== undefined && /^[A-Za-z_]\w*$/.test(b) && !KEYWORDS.has(b) ? b : null;
}

/**
 * A rule's left-hand side as `why` reads it: the binding of each fact a
 * firing matches, in pattern order, and the `no` patterns, as written. A
 * `then` sequence matches one fact per step.
 * @param {string[]} pats  the rule's patterns (rete.js `patterns`)
 * @returns {{ names: Array<string | null>, negated: string[], sequences: string[] }}
 */
export function lhsOf(pats) {
    /** @type {Array<string | null>} */
    const names = [];
    /** @type {string[]} */
    const negated = [], sequences = [];
    for (const p of pats) {
        if (/^no\b/.test(p)) {
            negated.push(p);
            continue;
        }
        const [head] = splitPattern(p);
        const steps = head.split(/ then /);
        if (steps.length > 1) sequences.push(p);
        for (const s of steps) names.push(bindingOf(s));
    }
    return { names, negated, sequences };
}

/**
 * The `emit` of `schema` in a rule's actions, with the `let` lines its values
 * come through. null when the source has none. Never a `publish`: it puts
 * nothing in working memory ([LTIE.4.3]), so no fact there came from one.
 * @param {string[]} block  the whole rule, header to its last action
 * @param {string} schema
 * @returns {Emit | null}
 */
export function emitOf(block, schema) {
    const a = block.findIndex((l) => l.trimEnd() === "->");
    if (a < 0) return null;
    const rhs = block.slice(a + 1).map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
    const re = new RegExp(`^emit\\s+${schema.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(\\s|$)`);
    const line = rhs.find((l) => re.test(l));
    if (line === undefined) return null;
    const lets = rhs.filter((l) => {
        const m = /^let\s+([A-Za-z_]\w*)/.exec(l);
        return m !== null && new RegExp(`\\b${m[1]}\\b`).test(line);
    });
    return { line, lets };
}

/**
 * A whole rule block's left-hand side: its header to its `->`.
 * @param {string[]} block
 */
const lhsLines = (block) => {
    const a = block.findIndex((l) => l.trimEnd() === "->");
    return a < 0 ? block : block.slice(0, a);
};

/**
 * Whether `a` and `b` hold the same ids.
 * @param {bigint[]} a
 * @param {bigint[]} b
 */
const sameIds = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);

/**
 * The settled point the cascade holding record `i` began from.
 * @param {Timeline} tl
 * @param {number} i
 */
const cascadeOf = (tl, i) => tl.settled.filter((p) => p <= i).pop() ?? 0;

/**
 * The schema a `no` pattern names, or null.
 * @param {string} p  `no Schema x where …`, or `no (…)`
 */
const negatedSchema = (p) => /^no\s+\(?\s*(?:latest\s+)?([A-Za-z_][\w.]*)/.exec(p)?.[1] ?? null;

export class Why {
    /** @type {SessionState} */
    #s;
    /** @type {Ds | null} */
    #ds;
    /** @type {Timelines} */
    #tls;
    /** @type {Map<string, bigint[]> | null} `%0`'s provenance index, "rule\0timetag" -> matched ids */
    #prov = null;
    /** @type {Map<string, string[]> | null} the same pass's firings' log lines, "rule\0timetag" -> lines */
    #provLogs = null;
    /** how far the provenance index goes */
    #provK = -1;
    /** @type {WeakMap<Uint8Array, Map<string, RuleMeta>>} compiled rule -> its metadata, per program */
    #metas = new WeakMap();

    /**
     * @param {SessionState} state
     * @param {{ ds: Ds | null }} ports
     * @param {Timelines} timelines
     */
    constructor(state, { ds }, timelines) {
        this.#s = state;
        this.#ds = ds;
        this.#tls = timelines;
    }

    /**
     * `why …`
     * @param {string} args
     * @returns {Result[]}
     */
    command(args) {
        const s = this.#s, tl = s.tl;
        const m = /^(.*?)(?:\s*\bdepth\s+(\d+))?$/.exec(args.trim());
        if (m === null) return [error(USAGE)];
        const target = m[1].trim(), depth = m[2] === undefined ? Infinity : Number(m[2]);
        if (m[2] !== undefined && depth < 1) return [error("`depth` counts firing levels, from 1")];
        /** @type {TreeItem} */
        let t;
        if (!target) {
            const top = s.stack[s.stack.length - 1];
            if (top === undefined || (top[0] !== "fact" && top[0] !== "firing"))
                return [error("`why` needs a fact or a firing: " + USAGE)];
            t = top;
        } else if (/^#\d+$/.test(target)) {
            const f = tl.facts.get(BigInt(target.slice(1)));
            if (f === undefined) return [error(`no fact ${target} in %${s.cur}`)];
            t = ["fact", f];
        } else if (/^!\d+$/.test(target)) {
            const i = Number(target.slice(1));
            const fr = s.firingRows[i - 1];
            if (fr === undefined || !tl.firings.includes(fr)) return [error(`no row ${i} in the last \`!\` listing of %${s.cur}`)];
            t = ["firing", fr];
        } else {
            const r = /^([A-Za-z_]\w*)\s+(?:0x)?([0-9A-Fa-f]+)$/.exec(target);
            if (r === null) return [error(USAGE)];
            const tt = BigInt("0x" + r[2]);
            const fr = tl.firings.find((f) => f.rule === r[1] && f.timetag === tt);
            if (fr === undefined) return [error(`no firing of \`${r[1]}\` with timetag 0x${r[2]} in %${s.cur}`)];
            t = ["firing", fr];
        }
        return this.tree(t, depth);
    }

    /**
     * The tree of an inspector item, `["fact", Fact]` or `["firing", Firing]`.
     * @param {TreeItem} item
     * @param {number} [depth]
     * @returns {Result[]}
     */
    tree(item, depth = Infinity) {
        const s = this.#s, tl = s.tl, k = s.k, n = s.cur;
        /** @type {string[]} */
        const notes = [];
        if (item[0] === "fact" && item[1].asserted >= k) return [error(`#${item[1].factId} is not asserted until after point`)];
        if (item[0] === "firing" && item[1].begin >= k) return [error("that firing is after point")];
        // A root fact gone by point: what supported each fact that ended in
        // its cascade, just before that cascade, where an engine can say.
        /** @type {Map<bigint, Justifier[]> | null} */
        let before = null;
        const gone = item[0] === "fact" ? item[1] : null;
        if (gone !== null && gone.ended !== null && gone.ended < k && this.#ds !== null && s.at(0).queries !== null) {
            const end = gone.ended, start = cascadeOf(tl, end);
            try {
                before = this.#tls.readEngine(n, start, (eng) => {
                    /** @type {Map<bigint, Justifier[]>} */
                    const m = new Map();
                    for (const g of tl.facts.values())
                        if (g.liveAt(start) && g.ended !== null && g.ended <= end && this.lifecycle(g.schema) === "logical")
                            m.set(g.factId, eng.justifiers(g.factId));
                    return m;
                });
            } catch (err) {
                if (isBug(err)) throw err;
                notes.push(`the support it lost not read: the engine refused: ${message(err)}`);
            }
        }
        /**
         * @param {((id: bigint) => Justifier[]) | null} just
         * @returns {{ root: WhyRoot, rows: Row[] }}
         */
        const build = (just) => {
            const b = new Builder(this, n, tl, k, depth, just, before);
            const root = item[0] === "fact" ? b.factRoot(item[1]) : b.activationRoot(item[1]);
            return { root, rows: b.rows };
        };
        let got;
        const wantsEngine = this.#ds !== null && s.at(0).queries !== null && tl.isSettled(k);
        if (wantsEngine) {
            try {
                got = this.#tls.readEngine(n, k, (eng) => build((id) => eng.justifiers(id)));
            } catch (err) {
                if (isBug(err)) throw err;
                notes.push(`current support not read: the engine refused: ${message(err)}`);
                got = build(null);
            }
        } else {
            if (!tl.isSettled(k)) notes.push("mid-cascade, no engine exists to ask for support at point: each fact "
                                             + "is shown with every firing that derived it up to point, and a "
                                             + "support that ended within this cascade cannot be seen");
            got = build(null);
        }
        const u = this.#unreliable(n);
        if (u !== null) notes.push(`the program engine differs from the trace at record ${u}: matched facts after it may be wrong`);
        s.rows = got.rows;
        return [{ type: "why", tl, k, root: got.root }, ...notes.map((x) => note(`(${x})`))];
    }

    // ── what the builder asks for ───────────────────────────────────────────

    /**
     * The facts `fr` matched on timeline `n`, in pattern order, or null.
     * @param {number} n
     * @param {Firing} fr
     * @returns {bigint[] | null}
     */
    matched(n, fr) {
        if (fr.matched !== null) return fr.matched.map(BigInt);
        const v = this.#s.at(n);
        if (v.hyp !== null) {
            if (fr.begin >= v.hyp.forkK) return null;
            const src = this.#s.at(v.hyp.source).tl;
            const same = src.firings.find((f) => f.begin === fr.begin);
            return same === undefined ? null : this.matched(v.hyp.source, same);
        }
        const prov = this.#provenance();
        const ids = prov?.get(`${fr.rule}\0${fr.timetag}`);
        return ids === undefined ? null : ids;
    }

    /**
     * The lines `fr`'s `log` actions logged on timeline `n`, in order, each
     * `level: message`; null when no engine ran it. A trace records no atom
     * for a `log` ([RFCS.3.6]), so an engine says them: a live run's or a
     * hypothesis's own, as it fired; in replay, the program engine's, as it
     * derives the firing again (§8.8). Only the engine's forward run hears
     * them: an engine re-driven from a checkpoint is a clone, which has no
     * listeners ([NLFC.8.3]).
     * @param {number} n
     * @param {Firing} fr
     * @returns {string[] | null}
     */
    logs(n, fr) {
        const v = this.#s.at(n), r = v.tl.records[fr.begin];
        if (r !== undefined && is(r, "RuleFireAnnotation") && r.body.logs !== undefined) return r.body.logs;
        if (v.hyp !== null) {
            if (fr.begin >= v.hyp.forkK) return null;
            const src = this.#s.at(v.hyp.source).tl;
            const same = src.firings.find((f) => f.begin === fr.begin);
            return same === undefined ? null : this.logs(v.hyp.source, same);
        }
        if (this.#provenance() === null) return null;
        return this.#provLogs?.get(`${fr.rule}\0${fr.timetag}`) ?? null;
    }

    /**
     * §8.8: the program engine run to the end of `%0`, its firings indexed:
     * what each matched, and what each logged.
     * @returns {Map<string, bigint[]> | null}
     */
    #provenance() {
        const s = this.#s;
        if (this.#ds === null || s.at(0).queries === null || s.live) return null;
        const real = s.real;
        if (this.#provK !== real.length) {
            try {
                const pe = this.#tls.programEngine();
                pe.to(real.length);
                const tl = pe.run.tl;
                /** @type {Map<string, bigint[]>} */
                const prov = new Map();
                /** @type {Map<string, string[]>} */
                const logs = new Map();
                for (const f of tl.firings) {
                    const key = `${f.rule}\0${f.timetag}`;
                    if (f.matched !== null) prov.set(key, f.matched.map(BigInt));
                    const begin = tl.records[f.begin];
                    if (begin !== undefined && is(begin, "RuleFireAnnotation")) logs.set(key, begin.body.logs ?? []);
                }
                this.#prov = prov;
                this.#provLogs = logs;
            } catch (err) {
                if (isBug(err)) throw err;
                this.#prov = null;
                this.#provLogs = null;
            }
            this.#provK = real.length;
        }
        return this.#prov;
    }

    /**
     * @param {number} n
     * @returns {number | null}
     */
    #unreliable(n) {
        const h = this.#s.at(n).hyp;
        if (h !== null) return this.#tls.unreliable(h)?.[0] ?? null;
        if (this.#s.live || this.#provK < 0) return null;
        return this.#tls.programEngine().unreliable?.[0] ?? null;
    }

    /**
     * The rule `fr` ran as: its compiled name, for its source (§8.6). A
     * firing begins at its RuleFireAnnotation.
     * @param {Timeline} tl
     * @param {Firing} fr
     * @returns {string}
     */
    compiledOf(tl, fr) {
        const r = tl.records[fr.begin];
        return (r !== undefined && is(r, "RuleFireAnnotation") ? r.body.compiled_name : undefined) ?? fr.rule;
    }

    /**
     * Rule `compiled`'s whole block in timeline `n`'s program, or null.
     * @param {number} n
     * @param {string} compiled
     */
    block(n, compiled) {
        return ruleBlock(this.#tls.sourcesOf(n), compiled, null, { whole: true });
    }

    /**
     * Rule `compiled`'s metadata ([RDSC.6]), or null.
     * @param {number} n
     * @param {string} compiled
     * @returns {RuleMeta | null}
     */
    meta(n, compiled) {
        return this.metas(n)?.get(compiled) ?? null;
    }

    /**
     * Every rule's metadata in timeline `n`'s program, by compiled name, or
     * null without the program.
     * @param {number} n
     * @returns {Map<string, RuleMeta> | null}
     */
    metas(n) {
        const ds = this.#ds;
        if (ds === null || this.#s.at(0).queries === null) return null;
        const dsc = this.#tls.programOf(n);
        let m = this.#metas.get(dsc);
        if (m === undefined) {
            m = new Map();
            const e = new ds.Engine();
            try {
                e.loadDsc(dsc);
                for (const [name, x] of e.rules) m.set(name, x);
            } finally {
                e.close();
            }
            this.#metas.set(dsc, m);
        }
        return m;
    }

    /**
     * Rule `compiled`'s patterns in timeline `n`'s program, as its source
     * writes them, or null when the source does not have the rule.
     * @param {number} n
     * @param {string} compiled
     * @returns {string[] | null}
     */
    patternsOf(n, compiled) {
        const block = this.block(n, compiled);
        return block === null ? null : patterns(lhsLines(block));
    }

    /**
     * A firing's matched facts on timeline `n`, each with the binding its
     * pattern names, in pattern order; null when the matched facts are not
     * known (§8.8). A name is null where the source does not say it.
     * @param {number} n
     * @param {Firing} fr
     * @returns {Array<{ name: string | null, id: bigint }> | null}
     */
    bindings(n, fr) {
        const ids = this.matched(n, fr);
        if (ids === null) return null;
        const block = this.block(n, this.compiledOf(this.#s.at(n).tl, fr));
        const names = block === null ? [] : lhsOf(patterns(lhsLines(block))).names;
        return ids.map((id, i) => ({ name: names.length === ids.length ? names[i] : null, id }));
    }

    /**
     * A schema's lifecycle word, from the program.
     * @param {string} schema
     */
    lifecycle(schema) {
        const sc = this.#s.at(0).queries?.prog.schemas.get(schema);
        if (sc === undefined) return "";
        return sc.logical ? "logical" : sc.ttlNs ? "ttl" : "";
    }

    /** @param {number} n */
    aliases(n) {
        return aliases(this.#tls.rulesOf(n));
    }
}

/** One tree's making: numbering, references and rows. */
class Builder {
    /** @type {Row[]} */
    rows = [];
    /** @type {Why} */
    #w;
    /** @type {number} */
    #n;
    /** @type {Timeline} */
    #tl;
    /** @type {number} */
    #k;
    /** @type {number} */
    #depth;
    /** @type {((id: bigint) => Justifier[]) | null} */
    #just;
    /** @type {Map<bigint, Justifier[]> | null} */
    #before;
    /** @type {Map<string, number>} */
    #seen = new Map();
    /** @type {Map<number, Firing> | null} */
    #emitter = null;

    /**
     * @param {Why} why
     * @param {number} n  the timeline
     * @param {Timeline} tl
     * @param {number} k  its point
     * @param {number} depth  firing levels to expand
     * @param {((id: bigint) => Justifier[]) | null} just  a logical fact's current support, where an engine can say
     * @param {Map<bigint, Justifier[]> | null} before  for a root gone by point: each fact's support just before
     *   the cascade it ended in, where an engine could say
     */
    constructor(why, n, tl, k, depth, just, before) {
        this.#w = why;
        this.#n = n;
        this.#tl = tl;
        this.#k = k;
        this.#depth = depth;
        this.#just = just;
        this.#before = before;
    }

    /**
     * The firings `js` name that began before point `k`.
     * @param {Justifier[]} js
     * @param {number} k
     * @returns {Firing[]}
     */
    #justifying(js, k) {
        const al = this.#w.aliases(this.#n);
        /** @type {Firing[]} */
        const out = [];
        for (const j of js) {
            const rule = al.get(j.ruleName) ?? j.ruleName, tt = BigInt(j.timetag);
            const fr = this.#tl.firings.find((x) => x.rule === rule && x.timetag === tt && x.begin < k);
            if (fr !== undefined) out.push(fr);
        }
        return out;
    }

    /**
     * A node's row: its number expands it, into its own tree (§4.14).
     * @param {string} key
     * @param {TreeItem} item
     */
    #number(key, item) {
        this.rows.push(["why", item]);
        const num = this.rows.length;
        this.#seen.set(key, num);
        return num;
    }

    /**
     * The firing whose effects hold record `i`.
     * @param {number} i
     * @returns {Firing | null}
     */
    #firingOf(i) {
        if (this.#emitter === null) {
            this.#emitter = new Map();
            for (const fr of this.#tl.firings) for (const e of fr.effects) this.#emitter.set(e, fr);
        }
        return this.#emitter.get(i) ?? null;
    }

    /**
     * @param {Fact} f
     * @returns {FactPart}
     */
    #fact(f) {
        return { fact: f, life: this.#w.lifecycle(f.schema),
                 ended: f.ended !== null && f.ended < this.#k ? f.ended : null };
    }

    /**
     * What supports or produced a derived fact: `[[firing, supporting]]`.
     * @param {Fact} f
     * @returns {Array<[Firing, boolean]>}
     */
    #supporters(f) {
        if (this.#just !== null && this.#w.lifecycle(f.schema) === "logical" && f.liveAt(this.#k)) {
            const out = this.#justifying(this.#just(f.factId), this.#k);
            if (out.length) return out.map((fr) => /** @type {[Firing, boolean]} */ ([fr, true]));
        }
        // No engine to ask (mid-cascade, §3.3): every firing that emitted it
        // before point, its first emit and each re-emit that coalesced with
        // it. A trace does not record one justification ending while others
        // hold, so a supporter lost within the cascade cannot be seen.
        /** @type {Array<[Firing, boolean]>} */
        const out = [];
        for (const i of [f.asserted, ...f.reemits]) {
            if (i >= this.#k) continue;
            const fr = this.#firingOf(i);
            if (fr !== null && !out.some(([x]) => x === fr)) out.push([fr, false]);
        }
        return out;
    }

    /**
     * The `emit` a fact came from: the source of the firing that emitted it.
     * @param {Fact} f
     * @returns {Emit | null}
     */
    #emit(f) {
        const fr = this.#firingOf(f.asserted);
        if (fr === null) return null;
        const block = this.#w.block(this.#n, this.#w.compiledOf(this.#tl, fr));
        return block === null ? null : emitOf(block, f.schema);
    }

    /**
     * A fact's causes, beneath it: firings, an input, or a reply's call.
     * @param {Fact} f
     * @param {number} level
     * @returns {Causes}
     */
    #causes(f, level) {
        if (f.origin === "integrator") {
            const call = this.#tl.calls.find((c) => c.resolved === f.asserted
                                             && (c.outcome === "answered" || c.outcome === "failed"));
            if (call === undefined) return { input: f.asserted, children: [] };
            const fr = this.#firingOf(call.issued);
            return { input: f.asserted, reply: call,
                     children: fr === null ? [] : [this.#firingNode(fr, false, level)] };
        }
        return { emit: this.#emit(f), children: this.#supporters(f).map(([fr, sup]) => this.#firingNode(fr, sup, level)) };
    }

    /**
     * @param {Fact} f
     * @returns {WhyRoot}
     */
    factRoot(f) {
        this.#seen.set(`f${f.factId}`, 0);
        const end = f.ended !== null && f.ended < this.#k ? this.#ending(f) : null;
        return { kind: "fact", ...this.#fact(f), live: f.liveAt(this.#k), end, ...this.#causes(f, 1) };
    }

    /**
     * §4.14 "why it ended": how `f` ended, then how the fact whose end ended
     * it ended, and so on, back to what began the cascade it ended in.
     * @param {Fact} f  a fact gone by point
     * @returns {EndStep[]}
     */
    #ending(f) {
        const start = cascadeOf(this.#tl, /** @type {number} */ (f.ended));
        /** @type {EndStep[]} */
        const steps = [];
        /** @type {Set<bigint>} */
        const seen = new Set();
        /** @type {Fact | null} */
        let g = f;
        while (g !== null && g.ended !== null && !seen.has(g.factId)) {
            seen.add(g.factId);
            const how = this.#how(g, start);
            steps.push({ fact: g, how });
            g = how.kind === "lost" ? how.lost : null;
        }
        return steps;
    }

    /**
     * How fact `f` ended, in the cascade begun at settled point `start`.
     * @param {Fact} f
     * @param {number} start
     * @returns {EndHow}
     */
    #how(f, start) {
        const tl = this.#tl, end = /** @type {number} */ (f.ended);
        if (f.endKind === "retract") return { kind: "retracted" };
        switch (f.cause) {
        case "TTL_EXPIRED":
            return { kind: "ttl" };
        case "SUPERSEDED":
            return { kind: "replaced", by: f.successor === null ? null : tl.facts.get(f.successor) ?? null };
        case "AUTHOR_WITHDRAWN":
            return { kind: "withdrawn", firing: this.#firingOf(end) };
        case "ACTIVATION_COMPLETED":
            return { kind: "completed", firing: this.#firingOf(f.asserted) };
        default:
            break;
        }
        // A support lost: a fact a supporting firing matched ended before it
        // in this cascade, or a fact a `no` pattern names began in it.
        for (const fr of this.#lastSupport(f, start)) {
            const ids = this.#w.matched(this.#n, fr);
            const block = this.#w.block(this.#n, this.#w.compiledOf(tl, fr));
            const side = block === null ? { names: [], negated: [], sequences: [] } : lhsOf(patterns(lhsLines(block)));
            if (ids !== null) {
                const names = side.names.length === ids.length ? side.names : [];
                for (const [i, id] of ids.entries()) {
                    const lost = tl.facts.get(id);
                    if (lost !== undefined && lost.ended !== null && lost.ended >= start && lost.ended < end)
                        return { kind: "lost", firing: fr, name: names[i] ?? null, lost };
                }
            }
            for (const p of side.negated) {
                const schema = negatedSchema(p);
                // The trace does not say which fact made the pattern match, so
                // every one that began in the cascade could have.
                const appeared = [...tl.facts.values()].filter((x) => x.schema === schema && x.asserted >= start
                                                                     && x.asserted < end);
                if (appeared.length) return { kind: "absence", firing: fr, pattern: p, appeared };
            }
        }
        return { kind: "unknown" };
    }

    /**
     * The firings that supported `f` just before the cascade, begun at
     * settled point `start`, that it ended in: its justifiers there where an
     * engine said, else every firing that emitted it before its end.
     * @param {Fact} f
     * @param {number} start
     * @returns {Firing[]}
     */
    #lastSupport(f, start) {
        const js = this.#before?.get(f.factId);
        if (js !== undefined) {
            const got = this.#justifying(js, start);
            if (got.length) return got;
        }
        /** @type {Firing[]} */
        const out = [];
        for (const i of [f.asserted, ...f.reemits]) {
            if (f.ended !== null && i >= f.ended) continue;
            const fr = this.#firingOf(i);
            if (fr !== null && !out.includes(fr)) out.push(fr);
        }
        return out;
    }

    /**
     * @param {Firing} fr
     * @param {boolean} support
     * @param {number} level
     * @returns {WhyNode}
     */
    #firingNode(fr, support, level) {
        const key = `r${fr.begin}`;
        const seen = this.#seen.get(key);
        if (seen !== undefined) return { kind: "ref", ref: seen, firing: fr };
        const n = this.#number(key, ["firing", fr]);
        /** @type {Extract<WhyNode, { kind: "firing" }>} */
        const node = { kind: "firing", n, firing: fr, support, children: [], cut: false };
        if (level > this.#depth) {
            node.cut = true;
            return node;
        }
        node.children = this.#matches(fr, level);
        return node;
    }

    /**
     * A firing's matched facts, each with its own causes, then its `no`
     * patterns.
     * @param {Firing} fr
     * @param {number} level
     * @returns {WhyNode[]}
     */
    #matches(fr, level) {
        const ids = this.#w.matched(this.#n, fr);
        const block = this.#w.block(this.#n, this.#w.compiledOf(this.#tl, fr));
        const side = block === null ? { names: [], negated: [], sequences: [] } : lhsOf(patterns(lhsLines(block)));
        /** @type {WhyNode[]} */
        const out = [];
        if (ids === null) out.push({ kind: "unrecorded" });
        else {
            const names = side.names.length === ids.length ? side.names : [];
            ids.forEach((id, i) => out.push(this.#binding(id, names[i] ?? null, level)));
        }
        const held = this.#tl.clockAt(fr.begin + 1);
        for (const p of side.negated) out.push({ kind: "absence", text: p, clock: held });
        return out;
    }

    /**
     * @param {bigint} id
     * @param {string | null} name
     * @param {number} level
     * @returns {WhyNode}
     */
    #binding(id, name, level) {
        const f = this.#tl.facts.get(id);
        if (f === undefined) return { kind: "missing", name, id };
        const key = `f${id}`;
        const seen = this.#seen.get(key);
        if (seen !== undefined) return { kind: "ref", ref: seen, name, fact: f };
        const n = this.#number(key, ["fact", f]);
        return { kind: "binding", n, name, ...this.#fact(f), ...this.#causes(f, level + 1) };
    }

    /**
     * §4.14 "an activation's tree": the firing, what triggered it, its
     * bindings and absences, its rule conditions and refraction.
     * @param {Firing} fr
     * @returns {WhyRoot}
     */
    activationRoot(fr) {
        this.#seen.set(`r${fr.begin}`, 0);
        const children = this.#matches(fr, 1);
        children.push(...this.#conditions(fr));
        return { kind: "activation", firing: fr, trigger: this.#trigger(fr), refraction: this.#refraction(fr), children };
    }

    /**
     * The input that began the cascade `fr` fired in, and the chain of
     * firings in that cascade from it to `fr` (§8.8 step 5).
     * A step may hold several inputs and the clock sample taken for them,
     * before the pump that runs the cascade. The input is the one
     * the chain reaches, else the step's first assert or retract, else its
     * clock sample; a step that is a pump alone has none.
     * @param {Firing} fr
     * @returns {Trigger | null}
     */
    #trigger(fr) {
        const tl = this.#tl;
        const i = cascadeOf(tl, fr.begin);
        const step = tl.records.slice(i, fr.begin).filter((r) => r.cls === "inject");
        const inputs = step.filter((r) => INPUT.has(r.kind));
        const chain = this.#chain(fr, i);
        const origin = chain.length > 0 && chain[0].firing === null ? chain[0].fact.asserted : null;
        const input = inputs.find((r) => r.index === origin) ?? inputs[0]
            ?? step.find((r) => r.kind === "ClockAdvance") ?? null;
        if (input === null) return null;
        const reached = origin !== null && origin === input.index;
        const negated = (() => {
            const block = this.#w.block(this.#n, this.#w.compiledOf(tl, fr));
            return block !== null && lhsOf(patterns(lhsLines(block))).negated.length > 0;
        })();
        return { input, chain, reached, negated };
    }

    /**
     * The chain of firings in the cascade begun at settled point `i` that
     * led to `fr`, back to the integrator's fact that started it.
     * @param {Firing} fr
     * @param {number} i
     * @returns {ChainStep[]}
     */
    #chain(fr, i) {
        const tl = this.#tl;
        /** @type {ChainStep[]} */
        const chain = [];
        let at = fr;
        for (let guard = 0; guard < 64; guard++) {
            const ids = this.#w.matched(this.#n, at);
            if (ids === null) break;
            /** @type {Fact[]} */
            const inCascade = [];
            for (const id of ids) {
                const f = tl.facts.get(id);
                if (f !== undefined && f.asserted >= i && f.asserted < at.begin) inCascade.push(f);
            }
            if (!inCascade.length) break;
            const f = inCascade.reduce((a, b) => (b.asserted > a.asserted ? b : a));
            if (f.origin === "integrator") {
                chain.unshift({ fact: f, firing: null });
                break;
            }
            const g = this.#firingOf(f.asserted);
            chain.unshift({ fact: f, firing: g });
            if (g === null) break;
            at = g;
        }
        return chain;
    }

    /**
     * Cooldown and `then … within`, with what each was judged on.
     * @param {Firing} fr
     * @returns {WhyNode[]}
     */
    #conditions(fr) {
        const tl = this.#tl;
        /** @type {WhyNode[]} */
        const out = [];
        const compiled = this.#w.compiledOf(tl, fr);
        const meta = this.#w.meta(this.#n, compiled);
        const before = tl.firings.filter((x) => x.rule === fr.rule && x.begin < fr.begin);
        const at = tl.clockAt(fr.begin + 1);
        if (meta?.coolWindowNs) {
            const prev = before[before.length - 1];
            out.push({ kind: "condition", what: "cooldown", window: BigInt(meta.coolWindowNs), at,
                       previous: prev === undefined ? null : tl.clockAt(prev.begin + 1) });
        }
        const ids = this.#w.matched(this.#n, fr);
        const block = this.#w.block(this.#n, compiled);
        if (block !== null) {
            const side = lhsOf(patterns(lhsLines(block)));
            for (const p of side.sequences) {
                /** @type {Array<[string, SlotValue]>} */
                const ts = [];
                if (ids !== null) ids.forEach((id, i) => {
                    const f = tl.facts.get(id);
                    // `ts` is a sequence's Time slot, never a reference.
                    if (f !== undefined && f.slots !== null && f.slots.ts !== undefined)
                        ts.push([side.names[i] ?? `#${f.factId}`, /** @type {SlotValue} */ (f.slots.ts)]);
                });
                out.push({ kind: "condition", what: "sequence", text: p, ts });
            }
        }
        return out;
    }

    /**
     * First firing for these facts, or a re-firing and on what change.
     * @param {Firing} fr
     * @returns {Refiring | null}
     */
    #refraction(fr) {
        const ids = this.#w.matched(this.#n, fr);
        if (ids === null) return null;
        const tl = this.#tl;
        /** @param {bigint} id */
        const priorOf = (id) => tl.facts.get(id)?.prior ?? null;
        const earlier = tl.firings.filter((x) => x.rule === fr.rule && x.begin < fr.begin).reverse();
        for (const x of earlier) {
            const was = this.#w.matched(this.#n, x);
            if (was === null || was.length !== ids.length) continue;
            if (sameIds(was, ids)) return { kind: "again" };
            /** @type {Array<[bigint, bigint]>} */
            const changed = [];
            let related = true;
            ids.forEach((id, i) => {
                if (was[i] === id) return;
                let p = priorOf(id);
                while (p !== null && p !== was[i]) p = priorOf(p);
                if (p === null) related = false;
                else changed.push([was[i], id]);
            });
            if (related && changed.length) return { kind: "changed", changed };
        }
        return { kind: "first" };
    }
}
