// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The session (DSDB.md §2, §3): a line in, results out. It parses the line
// (grammar.js), routes it to the collaborator that owns the command, and
// returns what that produced. The port of shell.py's Shell, split: the state
// is state.js's, and navigator.js, inspector.js, counts.js, answers.js,
// compare.js, changes.js and timelines.js own their commands. Nothing here
// prints; text/session.js turns results into lines.
//
// Stages 1 to 5 of the port (DSDB.md §11): replay, queries, live sessions,
// hypotheses and rule changes; and the spec's stages 7 and 8, the Rete network
// (rete.js) and derivation trees (why.js).

import { Answers } from "./answers.js";
import { Changes } from "./changes.js";
import { Compare } from "./compare.js";
import { Counts, options } from "./counts.js";
import { Edit } from "./edit.js";
import { LATER, parse } from "./grammar.js";
import { Inspector } from "./inspector.js";
import { Navigator } from "./navigator.js";
import { Rete } from "./rete.js";
import { SessionState } from "./state.js";
import { Timelines } from "./timelines.js";
import { Why } from "./why.js";

/** @import { EngineTimeline } from "./engine-timeline.js" */
/** @import { Cmd } from "./grammar.js" */
/** @import { Queries } from "./query.js" */
/** @import { Row } from "./state.js" */
/** @import { Timeline } from "./timeline.js" */
/** @import { TraceRecord } from "./trace.js" */
/** @import { Compile, Ds, Result } from "./types.js" */

/**
 * What the prompt shows (`prompt`): the calls waiting at point and, on a
 * hypothesis, its number, fork, change counts and state.
 * @typedef {{ waitingCalls: number, hyp: { number: number, forkSeq: string, counts: string, unreliable: boolean,
 *     halted: boolean } | null }} Prompt
 */

// Changes (§4.9, §4.10).
const CHANGES = new Set(["emit", "withdraw", "answer", "fail", "silence"]);

export class Session {
    /** @type {Navigator} */
    #nav;
    /** @type {Inspector} */
    #insp;
    /** @type {Counts} */
    #counts;
    /** @type {Answers} */
    #answers;
    /** @type {Compare} */
    #compare;
    /** @type {Changes} */
    #changes;
    /** @type {Timelines} */
    #timelines;
    /** @type {Rete} */
    #rete;
    /** @type {Why} */
    #why;
    /** @type {Edit} */
    #edit;
    /** @type {(() => TraceRecord[]) | null} */
    #refresh;

    /**
     * @param {Timeline} tl  `%0`: the trace, or a live session's own timeline (`live.tl`)
     * @param {object} opts
     * @param {Ds} opts.ds  a `@ds-lang/ds` API, for engines
     * @param {number} [opts.width]  the terminal's columns (100 when unknown, as the Python)
     * @param {(() => TraceRecord[]) | null} [opts.refresh]  `-f`: the records appended since the last call
     * @param {Queries | null} [opts.queries]  over `tl`, with the program; null without one
     * @param {EngineTimeline | null} [opts.live]  a live `%0`
     * @param {Compile | null} [opts.compile]  the compiler port (DSDB.md §3); null without one
     * @param {(() => Uint8Array) | null} [opts.stream]  replay: the trace's bytes, for forks and `save`
     * @param {((path: string, bytes: Uint8Array) => void) | null} [opts.write]  the files port, for `save`
     * @param {Array<[string, string]>} [opts.source]  the program's source, `[file, text]`, for rule changes
     * @param {((files: Map<string, string>, entry: string) => Promise<Uint8Array>) | null} [opts.compileFiles]
     *   the compiler port for a staged, changed program (DSDB.md §3)
     */
    constructor(tl, { width = 100, refresh = null, queries = null, live = null, ds, compile = null,
                      stream = null, write = null, source = [], compileFiles = null }) {
        const s = this.state = new SessionState(tl, width, queries);
        s.liveRun = live;
        this.#insp = new Inspector(s, (item) => this.#why.tree(item));
        this.#counts = new Counts(s);
        this.#answers = new Answers(s, this.#counts);
        this.#timelines = new Timelines(s, { ds, compile, source, stream, write },
                                        { currentFact: () => this.#insp.currentFact() });
        this.#nav = new Navigator(s, () => this.#insp.currentFact(), (old, now) => this.#answers.diff(old, now),
                                  { pump: () => this.#changes.pump(), advance: (ns) => this.#changes.advance(ns) });
        this.#changes = new Changes(s, { ds, compile }, this.#timelines, (k) => this.#nav.move(k));
        this.#compare = new Compare(s, this.#answers, this.#counts, (c) => this.#queryHere(c));
        this.#rete = new Rete(s, { ds, write }, this.#timelines);
        this.#why = new Why(s, { ds }, this.#timelines);
        this.#edit = new Edit(s, { ds, write, compileFiles }, this.#timelines, (w, a) => this.#changes.change(w, a));
        this.#refresh = refresh;
    }

    /** Let go of the hypotheses, the program engine, the query engines and
        the live engine. */
    close() {
        this.#timelines.close();
        this.state.at(0).queries?.close();
        this.state.liveRun?.close();
    }

    /**
     * What the session says as it starts. Result: `banner`.
     * @returns {Result[]}
     */
    banner() {
        const s = this.state;
        return [{ type: "banner", tl: s.tl, k: s.k }];
    }

    /**
     * What an MCP resource reads (dsdb/DSDB_MCP.md §10.2): `program`,
     * `rules`, `timelines`, or a timeline's number for its whole listing.
     * Looking only, with none of `execute`'s refreshing and following.
     * @param {"program" | "rules" | "timelines" | number} what
     * @returns {Result[]}
     */
    resource(what) {
        if (what === "program") return this.#edit.code();
        if (what === "rules") return this.#edit.ls("rules");
        if (what === "timelines") return this.#timelines.hyp();
        const v = this.state.views.get(what);
        if (v === undefined) return [error(`no timeline %${what}`)];
        return [{ type: "listing", tl: v.tl, k: v.k, around: v.tl.length }];
    }

    /**
     * What the prompt shows: calls waiting at point and, on a hypothesis,
     * its number, fork, change counts and state (§4.9).
     * @returns {Prompt}
     */
    prompt() {
        const s = this.state, h = s.view.hyp;
        /** @type {Prompt} */
        const out = { waitingCalls: s.tl.waitingCalls(s.k).length, hyp: null };
        if (h !== null)
            out.hyp = { number: h.number, forkSeq: h.forkSeq, counts: h.counts(),
                        unreliable: this.#timelines.unreliable(h) !== null, halted: h.halted !== null };
        return out;
    }

    /**
     * One line of input. Async because a query or an emit compiles, and the
     * wasm compiler is async (§3).
     * @param {string} line
     * @returns {Promise<Result[]>} results; `{ type: "quit" }` ends the session
     */
    async execute(line) {
        /** @type {Result[]} */
        const out = [];
        if (this.#refresh !== null) {
            const recs = this.#refresh();
            if (recs.length) {
                this.state.real.extend(recs);
                out.push({ type: "refresh", count: recs.length });
            }
        }
        const c = parse(line);
        const before = { cur: this.state.cur, k: this.state.k };
        switch (c.kind) {
        case "empty": break;
        case "error": out.push(error(c.error)); break;
        case "row": if (c.row !== null) out.push(...this.#insp.row(c.row)); break;
        case "step": out.push(...await this.#nav.step(c)); break;
        case "nav": out.push(...await this.#nav.nav(c)); break;
        case "query": out.push(...await this.#query(c)); break;
        case "word": out.push(...await this.#word(c)); break;
        case "define": out.push(...await this.#edit.define(c.body)); break;
        }
        const logs = this.#logsCrossed(before);
        if (logs !== null) out.push(logs);
        out.push(...this.#timelines.followBackground());
        return out;
    }

    /**
     * The program's `log` lines for what the line just moved point across,
     * forward on one timeline: each firing whose last record it crossed, in
     * firing order, as `ds dap` sends them as output (adapter.js `#output`)
     * and `ds -b` writes them. A move back, a switch of timeline, and a line
     * that moved nothing say none. Result: `logs`, or null when there is
     * none.
     * @param {{ cur: number, k: number }} before  where point was
     * @returns {Result | null}
     */
    #logsCrossed(before) {
        const s = this.state;
        if (s.cur !== before.cur || s.k <= before.k) return null;
        const tl = s.tl;
        /** @type {Array<{ firing: number, at: number, line: string }>} */
        const lines = [];
        tl.firings.forEach((fr, i) => {
            const done = (fr.end ?? fr.effects[fr.effects.length - 1] ?? fr.begin) + 1;
            if (done <= before.k || done > s.k) return;
            for (const line of this.logs(fr) ?? []) lines.push({ firing: i, at: fr.begin + 1, line });
        });
        return lines.length ? { type: "logs", tl, lines } : null;
    }

    /**
     * @param {Cmd} c  a word
     * @returns {Promise<Result[]>}
     */
    async #word(c) {
        const s = this.state, w = c.word, args = c.args, tls = this.#timelines;
        if (w === "watch") return this.#answers.watch(args);
        if (w === "unwatch") return this.#answers.unwatch();
        if ((w === "next" || w === "prev") && args === "change") {
            const [k, refused] = await this.#answers.seekChange(w === "next");
            return k === null ? refused : this.#nav.move(k);
        }
        if (CHANGES.has(w)) {
            // §4.16: `from @N WORD …` is `@N`, then the change at point.
            if (c.at === null) return this.#changes.change(w, args);
            const moved = await this.#nav.nav(c.at);
            if (moved.some((r) => r.type === "error" || r.type === "pastEnd")) return moved;
            return [...moved, ...await this.#changes.change(w, args)];
        }
        if (w === "save") {
            // §4.16: `save trace` is the timeline, `save code` the program;
            // a bare `save` is `save trace`, its old spelling.
            if (/^code\b/.test(args)) return this.#edit.saveCode(args.replace(/^code\b\s*/, ""));
            return tls.save(args.replace(/^trace\b\s*/, ""));
        }
        if (w === "hyp") return tls.hyp();
        if (w === "fg") return tls.fg(args);
        if (w === "real") return tls.fg("%0");
        if (w === "bg") return tls.bg(args);
        if (w === "stop") return tls.stop(args);
        if (w === "fork") return tls.fork();
        if (w === "kill") return tls.kill(args);
        if (w === "match") return tls.match();
        // §4.16: the program changes only for all time, by its definitions.
        if (w === "rule") return [error("a rule is a definition: `rule NAME:`, its patterns, `->`, its actions, "
                                        + "then two blank lines")];
        if (w === "unrule") return [error("`unrule` is withdrawn: `del rule NAME` removes a rule from the program")];
        if (w === "changes") return tls.changes();
        if (w === "rules") return [error("`rules` is now `changes`: every change at a point, not only rules")];
        if (w === "show") return this.#edit.show(args);
        if (w === "ls") return this.#edit.ls(args);
        if (w === "del") return this.#edit.del(args);
        if (w === "mv") return this.#edit.mv(args);
        if (w === "rete") return this.#rete.command(args);
        if (w === "why") return this.#why.command(args);
        if (w === "whynot") return this.#rete.whynot(args);
        if (w === "skip" || w === "change" || w === "add")
            return [{ type: "note", text: "changing a firing is deferred until after stage 8: libds asserts an "
                      + "emit before any callback sees it, so no callback can drop or alter one" }];
        if (LATER.has(w)) return [{ type: "note", text: `\`${w}\` arrives in stage ${LATER.get(w)}` }];
        if (w === "quit" || w === "exit") return [{ type: "quit" }];
        if (w === "help") return [{ type: "help" }];
        if (w === "%") return [{ type: "note", text: `%${s.cur}` }];
        if (w === "list") return [{ type: "listing", tl: s.tl, k: s.k, around: /^\d+$/.test(args) ? Number(args) : 10 }];
        if (w === "calls") return this.#insp.calls(args === "all");
        if (w === "up") return this.#insp.up();
        if (w === "<" || w === ">") return this.#insp.version(w);
        return [];
    }

    /**
     * @param {Cmd} c  a query
     * @returns {Promise<Result[]>}
     */
    async #query(c) {
        const s = this.state;
        const missing = c.timelines.filter((n) => !s.views.has(n));
        if (missing.length) return [error(`no timeline %${missing[0]}; \`hyp\` lists them`)];
        let names = [...new Set(c.timelines)];
        // §4.8: within a hypothesis, one named timeline is compared with %0.
        if (names.length === 1 && s.cur !== 0 && names[0] !== 0) names = [0, ...names];
        if (names.length === 1 && names[0] !== s.cur) return s.on(names[0], () => this.#queryHere(c));
        if (names.length > 1) return this.#compare.compare(c, names);
        return this.#queryHere(c);
    }

    /**
     * A query form on the current timeline, at its point.
     * @param {Cmd} c  a query
     * @returns {Promise<Result[]>}
     */
    async #queryHere(c) {
        const s = this.state;
        const o = options(c.body);
        if (o.error !== undefined) return [error(o.error)];
        const { opts, rest } = o;
        if (rest && "!^".includes(c.sigil)) return [error(`\`${rest}\` is not a filter or histogram option`)];
        let k = s.k;
        if (c.scope === "@" && c.pos !== null) {
            const got = s.tl.resolve(c.pos.seq, c.pos.minus);
            if (got === null) return [error("past the last position")];
            k = got[0];
        }
        if (c.sigil === "?" || (c.sigil === "#" && rest)) {
            const body = c.sigil === "#" ? rest : c.body;
            if (!body) return [error("`?` needs a query, as `?.Reading r where r.level > 80.0`")];
            return this.#answers.query(c.sigil, c.scope, k, body, opts);
        }
        if (c.sigil === "#") return this.#counts.population(c.scope, k, opts);
        if (c.sigil === "!") return this.#counts.firings(c.scope, k, opts);
        return this.#counts.firingCounts(c.scope, k, opts);
    }

    /**
     * Show an item in the inspector, as drilling into a row does.
     * @param {Row} item
     * @returns {Result[]}
     */
    show(item) {
        return this.#insp.show(item);
    }

    /**
     * A firing of the current timeline's matched facts, by binding, in
     * pattern order; null when they are not known. For `ds dap`'s Bindings
     * scope ([NDBG.13.2.1]).
     * @param {import("./timeline.js").Firing} fr
     */
    bindings(fr) {
        return this.#why.bindings(this.state.cur, fr);
    }

    /**
     * The lines a firing of the current timeline logged, in order, each
     * `level: message`; null when no engine ran it. For `ds dap`'s program
     * output ([NDBG.9.3.6]).
     * @param {import("./timeline.js").Firing} fr
     */
    logs(fr) {
        return this.#why.logs(this.state.cur, fr);
    }

    /**
     * Rule `rule`'s patterns as the current timeline's program's source
     * writes them, or null without that source.
     * @param {string} rule
     */
    patterns(rule) {
        return this.#why.patternsOf(this.state.cur, rule);
    }

    /**
     * The current timeline's program's rules' metadata ([RDSC.6]), by name,
     * or null without the program: where each rule is in its source.
     */
    rules() {
        return this.#why.metas(this.state.cur);
    }

    /**
     * `fn` on an engine standing at point, to read, not drive (§8.7): the
     * running one at an engine timeline's end, else one replayed there. Point
     * must be settled: no engine exists mid-cascade.
     * @template T
     * @param {(eng: import("@ds-lang/ds").Engine) => T} fn
     * @returns {T}
     */
    readEngine(fn) {
        const s = this.state;
        if (!s.tl.isSettled(s.k)) throw new RangeError("no engine exists mid-cascade: step to a settled point");
        return this.#timelines.readEngine(s.cur, s.k, fn);
    }

    /**
     * What the engine did with its cache and timers on the current timeline
     * (EngineTimeline's `cacheOps` and `timers`), by record: a live `%0`'s own
     * engine; a hypothesis's, after its source's up to the fork; in replay,
     * the program engine's, run over the trace, whose records stand where the
     * trace's do while it agrees with it (§6). null without the program.
     * @returns {{ ops: import("./engine-timeline.js").CacheOp[], timers: import("./engine-timeline.js").TimerArmed[] } | null}
     */
    engineRecord() {
        return this.#record(this.state.cur);
    }

    /**
     * @param {number} n
     * @returns {{ ops: import("./engine-timeline.js").CacheOp[], timers: import("./engine-timeline.js").TimerArmed[] } | null}
     */
    #record(n) {
        const s = this.state, v = s.at(n);
        if (v.hyp !== null) {
            const src = this.#record(v.hyp.source), run = v.hyp.run, fork = v.hyp.forkK;
            return { ops: [...(src?.ops ?? []).filter((x) => x.at < fork), ...run.cacheOps.filter((x) => x.at >= run.base)],
                     timers: [...(src?.timers ?? []).filter((x) => x.at < fork), ...run.timers.filter((x) => x.at >= run.base)] };
        }
        if (s.liveRun !== null) return { ops: s.liveRun.cacheOps, timers: s.liveRun.timers };
        if (s.at(0).queries === null) return null;
        const pe = this.#timelines.programEngine();
        pe.to(s.real.length);
        return { ops: pe.run.cacheOps, timers: pe.run.timers };
    }

    /**
     * A debugger's inject at point (Changes.inject): `schema`'s fact, its
     * slots one JSON row, landing where `emit` does.
     * @param {string} schema
     * @param {string} row
     * @returns {Result[]}
     */
    inject(schema, row) {
        return [...this.#changes.inject(schema, row), ...this.#timelines.followBackground()];
    }

    /**
     * A schema's lifecycle word in the program: `logical`, `ttl`, or "".
     * @param {string} schema
     */
    lifecycle(schema) {
        return this.#why.lifecycle(schema);
    }
}

/**
 * @param {string} text
 * @returns {Result}
 */
const error = (text) => ({ type: "error", text });
