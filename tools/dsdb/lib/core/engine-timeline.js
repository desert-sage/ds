// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Engines that run the real program (DSTRACE_INTERACTIVE §8): the port of
// tools/dstrace_shell/engines.py's EngineTimeline, LiveSession and the
// helpers the program engine and hypotheses share.
//
// AN ENGINE-BACKED TIMELINE is a live `%0` or a hypothesis: an engine with
// dsdb as its integrator (§1, "actions are callbacks").
//
// ITS TIMELINE IS THE ENGINE'S OWN RECORDING. The engine records itself with
// its C recorder, through @ds-lang/ds's recordTo(sink): each atom arrives as it is
// framed and is kept IN MEMORY (DSDB.md §4), where the Python wrote a
// temporary file. After every input the new atoms are read back through the
// same decoder a recorded trace goes through, so the records are exactly
// what a recording of it would hold, withdrawal causes and TTL windows
// included, and `save` writes the bytes collected.
//
// The stream callback runs beside the recorder and adds the three
// things a trace does not hold: each firing's matched facts (§8.8), its log
// lines, and the FactExternal bytes of a call's fact arguments, which a trace
// holds decoded (DSDB.md §9.1).
//
// A HYPOTHESIS's engine is a clone (§8.3). Its timeline is the records of the
// timeline it forked from, up to the fork, followed by its own recording,
// whose sequence numbers and fact ids continue the source's because a clone
// copies both counters (§4.7, §10.5).
//
// Fact ids and clocks are BigInts; record indexes Numbers.

import { stepDeadline, stepDeadlines } from "./facts.js";
import { read as readProgram } from "./program.js";
import { Timeline } from "./timeline.js";
import { Decoder, EXTERNAL_DIVERGED, is } from "./trace.js";

/** @import { Engine, Int64, SchemaInfo, SlotValue, StreamEngineEvent } from "@ds-lang/ds" */
/** @import { Service } from "./program.js" */
/** @import { TraceRecord } from "./trace.js" */
/** @import { Ds } from "./types.js" */

/** The stream event kinds a timeline listens for: what its `#on` reads. */
const HEARD = /** @type {const} */ (["rule_lhs_facts", "rule_fire_begin", "rule_fire_end", "action_log", "action_call",
                                     "action_cache_get", "timer_armed"]);

/**
 * What a trace does not record of the cache and the timers, as the engine
 * reported it: each cache write and removal (its write-through), each read,
 * and each timer armed. `at` is the record it belongs to: the begin
 * annotation of the firing that made it, else the last record of the step.
 * @typedef {CacheOpBody & { at: number }} CacheOp
 */

/**
 * A cache operation as heard, before it is placed at a record.
 * @typedef {{ op: "set", key: string, value: string | null, ttlNs: bigint }
 *     | { op: "delete", key: string, reason: "delete" | "ttl" }
 *     | { op: "get", key: string, value: string | null }} CacheOpBody
 */

/** @typedef {{ at: number, rule: string, kind: string, windowNs: bigint, fireAtNs: bigint }} TimerArmed */

/**
 * The program on a mock clock at 0, as a live session starts (§4.9).
 * @param {Ds} ds
 * @param {Uint8Array} dsc
 * @returns {Engine}
 */
export function freshEngine(ds, dsc) {
    const e = new ds.Engine();
    e.loadDsc(dsc);
    e.clock.mode = "mock";
    e.clock.set(0n);
    return e;
}

/**
 * `eng.clone()`, ready to drive (§8.3): a clone has no callbacks
 * ([NLFC.8.3]), and a rule that calls cannot fire without a call callback.
 * @param {Engine} eng
 * @returns {Engine}
 */
export function cloneEngine(eng) {
    const c = eng.clone();
    c.setCallCallback(() => {});
    return c;
}

/**
 * One fact an input asserted: [its id in the recording, its id in this
 * engine]. The pairs are how a later FactRetract's recorded id finds its fact.
 * @typedef {[bigint, bigint]} Asserted
 */

/**
 * Apply one recorded inject record to `eng`, as libds's replayer does
 * (§10.3). Returns the facts an input asserted, else null.
 *
 * - A ClockAdvance sets both mock clocks to its sample, for the input or pump
 *   after it to observe. Setting is not a sample: the engine's next step is.
 * - A FactAssert asserts and a FactRetract retracts, and neither pumps.
 * - An ExternalAssert is delivered by libds as its replayer delivers one
 *   ([RFCS.24.2], `applyExternalAssert`): the received fact and the facts it
 *   refers to, with the recorded `ttl_ns`, and no pump. Its `fact_ids` are
 *   bound in order to what was asserted. A delivery libds cannot make as
 *   recorded stops the replay, naming the record (EXTERNAL_DIVERGED).
 * - A PumpBoundary pumps: the recording says where every pump was.
 *
 * `factId` is this engine's id for the fact a FactRetract names, when it
 * differs from the recorded one (a hypothesis after its fork). A retract of a
 * fact the engine does not hold does nothing.
 * @param {Engine} eng
 * @param {TraceRecord} r
 * @param {bigint | null} [factId]
 * @returns {Asserted[] | null}
 */
export function applyInject(eng, r, factId = null) {
    if (is(r, "ClockAdvance")) {
        const b = r.body;
        if (BigInt(b.clock_ns) > eng.clock.now) eng.clock.set(BigInt(b.clock_ns));
        // libds's replayer unsets the wall clock for an unset sample, so a run
        // whose wall clock faulted replays to the same fault. libds.h has no
        // call to unset it, so @ds-lang/ds cannot: an unset sample after a set
        // one is not applied here, and the engine keeps the earlier time.
        if (b.wall_ns != null) eng.clock.setWall(BigInt(b.wall_ns));
        return null;
    }
    if (is(r, "FactAssert")) {
        const b = r.body;
        if (b.slots === null || b.slots === undefined)
            throw new Error(`record ${r.index}: an untyped FactAssert cannot be applied (no schema announcement)`);
        refuseOwnTtl(eng, r.index, b.schema_name, b.ttl_ns);
        // A host assert holds no reference: one that does is recorded as an
        // ExternalAssert ([RFCS.24.1]), applied below, so these are values.
        return [[BigInt(b.fact_id), eng.assert(b.schema_name, /** @type {Record<string, SlotValue>} */ (b.slots)).id]];
    }
    if (is(r, "ExternalAssert")) {
        let got;
        try {
            got = eng.applyExternalAssert(r.body.bytes);
        } catch (err) {
            if (err instanceof Error && err.name === "DsError")
                throw new Error(`record ${r.index}: ${EXTERNAL_DIVERGED}: ${err.message}`, { cause: err });
            throw err;
        }
        return got.recordedIds.map((rec, i) => /** @type {Asserted} */ ([rec, got.factIds[i]]));
    }
    if (is(r, "FactRetract")) {
        const f = eng.factById(factId ?? r.body.fact_id);
        if (f !== null) eng.retract(f);
        return null;
    }
    if (r.kind === "PumpBoundary") eng.pump();
    return null;
}

/**
 * Refuse a recorded host assert whose TTL window is not its schema's own. No
 * public entry point sets a per-fact TTL, so a plain assert gives the
 * schema's TTL, and a fact recorded with another would replay with the wrong
 * deadline. Refused, never approximated: no 1.0
 * engine can reproduce it. A recorded 0 is the schema's own ([RFCS.6.2]).
 * @param {Engine} eng
 * @param {number} index  the record's, for the message
 * @param {string} schema
 * @param {Int64 | null | undefined} ttlNs  the recorded window; 0 or absent for the schema's
 */
export function refuseOwnTtl(eng, index, schema, ttlNs) {
    const recorded = BigInt(ttlNs ?? 0n);
    const own = eng.schemas.get(schema)?.ttlNs ?? 0n;
    if (recorded !== 0n && recorded !== own)
        throw new Error(`record ${index}: ${schema} was recorded with a ${recorded} ns TTL, not its schema's `
            + `${own} ns, and no public entry point sets a per-fact TTL`);
}

/**
 * @param {string} rule
 * @param {bigint} timetag
 */
const firingKey = (rule, timetag) => `${rule}\0${timetag}`;

export class EngineTimeline {
    /** @type {Timeline} */
    tl;
    /** Records that are the prefix's, not this engine's. */
    base = 0;
    /** @type {Engine} */
    #eng;
    /** @type {Decoder} */
    #dec;
    #buf = new Uint8Array(1 << 16);
    #len = 0;
    #headEnd = 0;           // where this engine's own records start in its recording
    /** @type {[Uint8Array, number[]]} [bytes, offsets] of the prefix, cut at `base` */
    #prefix;
    /** @type {Map<string, string>} */
    #aliases;
    /** @type {Map<string, bigint[]>} "rule\0timetag" -> matched fact ids */
    #matched = new Map();
    /** @type {Map<string, string[]>} "rule\0timetag" -> log lines */
    #logs = new Map();
    /** @type {Map<bigint, Map<string, Uint8Array>>} a call's seq -> its fact arguments' bytes, by name */
    #externals = new Map();
    /** @type {bigint[]} */
    #lhs = [];
    /** @type {string | null} */
    #firing = null;
    #closed = false;
    /** @type {CacheOp[]} this engine's cache operations, in order */
    cacheOps = [];
    /** @type {TimerArmed[]} the timers this engine armed, in order */
    timers = [];
    /** @type {Array<{ firing: string | null, op: CacheOpBody | null, timer: Omit<TimerArmed, "at"> | null }>}
        what was heard since the last sync, not yet placed at a record */
    #heard = [];

    /**
     * Fresh (`prefix` null) this is a live `%0`. Given a `prefix` timeline and
     * a point `k` in it, `eng` is an engine at `k` (a clone, or a changed
     * program replayed there), and the timeline continues the prefix's first
     * `k` records. `image` is the prefix's stream as `[bytes, offset of each
     * record]`, cut at `k`: what `save` and a fork's stream start with.
     * `aliases` maps a compiled rule name to the one the user knows it by
     * (§8.6), applied as records are read. `services` are the program's
     * (program.js), what its calls respond with; a prefix's by default.
     * `dsc` is the program `eng` holds, which types the recorded facts'
     * bodies (trace.js `Decoder`); without it they are untyped.
     * @param {Ds} ds
     * @param {Engine} eng  with the program loaded
     * @param {{ prefix?: Timeline | null, k?: number, image?: [Uint8Array, number[]], aliases?: Map<string, string>,
     *           services?: Map<string, Service>, dsc?: Uint8Array | null }} [opts]
     */
    constructor(ds, eng, { prefix = null, k = 0, image = [new Uint8Array(0), []], aliases = new Map(),
                           services = prefix?.services ?? new Map(), dsc = null } = {}) {
        this.#eng = eng;
        this.#prefix = image;
        this.#aliases = aliases;
        const on = (/** @type {StreamEngineEvent} */ ev) => this.#on(ev);
        for (const kind of HEARD) eng.addEventListener(kind, on);
        // A rule that calls cannot fire without a call callback; dsdb is the
        // integrator, and answers with `answer` (§4.10).
        eng.setCallCallback(() => {});
        // The cache's write-through is the one place the engine says what it
        // wrote and what left (by a delete, or its TTL): a trace holds neither.
        eng.cache.writeThrough = {
            set: (w) => this.#hear({ op: "set", key: w.key, value: w.value, ttlNs: w.ttlNs }, null),
            delete: (r) => this.#hear({ op: "delete", key: r.key, reason: r.reason }, null),
        };
        eng.recordTo((atom) => this.#keep(atom));
        this.#dec = new Decoder(ds, { dsc });
        this.base = k;
        if (prefix === null) {
            this.tl = new Timeline([], null, services);
            this.#sync();
        } else {
            // The clone's recording opens with its own header and schema
            // announcements. The prefix already has both, so they are read
            // (for the slot table) and not added to the timeline.
            this.#dec.feed(this.#view());
            this.#headEnd = this.#dec.pos;
            this.#dec.count = k;
            this.#dec.clock = prefix.clockAt(k);
            this.tl = new Timeline(prefix.records.slice(0, k), prefix.header, services);
        }
    }

    /**
     * A live `%0`: the program, fresh (§3.5).
     * @param {Ds} ds
     * @param {Uint8Array} dsc
     */
    static live(ds, dsc) {
        const eng = freshEngine(ds, dsc);
        // Not in `freshEngine`, which also replays a recording: an unset
        // sample there has to stay unset. A session of its own has no other
        // wall clock, and with none `now()` and an emitted `ts` fault
        // ([LTIM.2.8.3]). Its clock starts at the epoch, so `@at` is both.
        eng.clock.setWall(0n);
        return new EngineTimeline(ds, eng, { services: readProgram(ds, dsc).services, dsc });
    }

    /** The engine, to clone. */
    get eng() {
        return this.#eng;
    }

    /** Idempotent. */
    close() {
        if (this.#closed) return;
        this.#closed = true;
        try {
            this.#eng.stopRecording();
        } finally {
            this.#eng.close();
            this.#dec.close();
        }
    }

    // ── inputs ──────────────────────────────────────────────────────────────

    /**
     * An integrator assert, then a pump: a step of its own (§3.3). Returns the
     * new fact's id. Its TTL is its schema's: there is no per-fact one.
     * @param {string} schema
     * @param {Record<string, SlotValue>} slots
     * @returns {bigint}
     */
    assertFact(schema, slots) {
        const id = this.#eng.assert(schema, slots).id;
        this.#eng.pump();
        this.#sync();
        return id;
    }

    /**
     * The engine's next deadline earlier than `ns`, as a step of its own: the
     * mock clock moves there and the engine pumps (core/facts.js
     * `stepDeadline`). False when there is none before `ns`.
     * @param {bigint} ns
     * @returns {boolean}
     */
    stepDeadline(ns) {
        return stepDeadline(this.#eng, ns, () => this.pump());
    }

    /**
     * `assertFact` at the instant `ns`, as batch mode feeds a fact-file row:
     * each engine deadline before `ns` is a step of its own at its own
     * instant, then the mock clock moves to `ns` (never back) with no pump of
     * its own, so what falls due at `ns` is the assert's pump's. Returns the
     * new fact's id.
     * @param {bigint} ns
     * @param {string} schema
     * @param {Record<string, SlotValue>} slots
     * @returns {bigint}
     */
    assertFactAt(ns, schema, slots) {
        stepDeadlines(this.#eng, ns, () => this.pump());
        const now = this.#eng.clock.now;
        if (ns > now) this.#eng.clock.advance(ns - now);
        return this.assertFact(schema, slots);
    }

    /**
     * An integrator retract of a live fact, then a pump. False when the fact
     * is not live.
     * @param {bigint} id
     */
    retract(id) {
        const f = this.#eng.factById(id);
        if (f === null) return false;
        this.#eng.retract(f);
        this.#eng.pump();
        this.#sync();
        return true;
    }

    /**
     * Move the mock clock forward and pump: timers, windows, expiry.
     * @param {Int64} ns
     */
    advance(ns) {
        this.#eng.clock.advance(BigInt(ns));
        this.#eng.pump();
        this.#sync();
    }

    pump() {
        this.#eng.pump();
        this.#sync();
    }

    /**
     * Apply another timeline's inject record `r` (§4.9, §8.2). Returns the
     * facts an input asserted, as `applyInject` does.
     * @param {TraceRecord} r
     * @param {bigint | null} [factId]
     */
    feed(r, factId = null) {
        const out = applyInject(this.#eng, r, factId);
        this.#sync();
        return out;
    }

    /** @param {string} name */
    hasSchema(name) {
        return this.#eng.schemas.has(name);
    }

    /**
     * The engine's schema called `name` (`@ds-lang/ds`'s `schemas`), or null.
     * @param {string} name
     * @returns {SchemaInfo | null}
     */
    schema(name) {
        return this.#eng.schemas.get(name) ?? null;
    }

    /** @param {bigint} id */
    isLive(id) {
        return this.#eng.factById(id) !== null;
    }

    /** The engine's clock, BigInt nanoseconds. */
    clock() {
        return this.#eng.clock.now;
    }

    /** The engine's own bytes (§4.9 `hyp`); 0 for a program with no rules. */
    mem() {
        try {
            return this.#eng.memory().totalBytes;
        } catch {
            return 0;
        }
    }

    // ── bytes, for `save` and for forks of this timeline ────────────────────

    /**
     * This timeline's stream as one byte string, with the offset in it of
     * each record: the prefix's, then this engine's own atoms after its header
     * and schema announcements.
     * @returns {[Uint8Array, number[]]}
     */
    image() {
        const [pb, po] = this.#prefix;
        const own = this.#view().subarray(this.#headEnd);
        const out = new Uint8Array(pb.length + own.length);
        out.set(pb);
        out.set(own, pb.length);
        const offs = [...po.slice(0, this.base),
                      ...this.tl.records.slice(this.base).map((r) => pb.length + r.offset - this.#headEnd)];
        return [out, offs];
    }

    /** The stream so far: for a live `%0`, the engine's own recording, a
        canonical trace (§4.9). */
    bytes() {
        return this.image()[0];
    }

    /**
     * The stream up to point `k`.
     * @param {number} k
     */
    dataUpto(k) {
        const [data, offs] = this.image();
        return k < offs.length ? data.slice(0, offs[k]) : data;
    }

    // ── the recording, and what the callback adds ───────────────────────────

    #view() {
        return this.#buf.subarray(0, this.#len);
    }

    /** @param {Uint8Array} atom */
    #keep(atom) {
        if (this.#len + atom.length > this.#buf.length) {
            let n = this.#buf.length * 2;
            while (n < this.#len + atom.length) n *= 2;
            const grown = new Uint8Array(n);
            grown.set(this.#buf.subarray(0, this.#len));
            this.#buf = grown;
        }
        this.#buf.set(atom, this.#len);
        this.#len += atom.length;
    }

    /**
     * Something the stream or the write-through said, to place at a record
     * once the step's records are read.
     * @param {CacheOpBody | null} op
     * @param {Omit<TimerArmed, "at"> | null} timer
     */
    #hear(op, timer) {
        this.#heard.push({ firing: this.#firing, op, timer });
    }

    /** Read the atoms recorded since the last input. */
    #sync() {
        const recs = this.#dec.feed(this.#view());
        // What was heard goes with the firing that made it, by the firing's
        // begin annotation, before rule names are aliased; the rest with the
        // step's last record.
        if (this.#heard.length) {
            const last = recs.length ? recs[recs.length - 1].index : Math.max(0, this.tl.length - 1);
            for (const h of this.#heard) {
                const begin = h.firing === null ? undefined
                    : recs.find((r) => is(r, "RuleFireAnnotation") && !r.body.end
                                  && firingKey(r.body.rule_name, r.body.timetag) === h.firing);
                const at = begin?.index ?? last;
                if (h.op !== null) this.cacheOps.push({ at, ...h.op });
                if (h.timer !== null) this.timers.push({ at, ...h.timer });
            }
            this.#heard = [];
        }
        for (const r of recs) {
            if (is(r, "RuleFireAnnotation") && !r.body.end) {
                const key = firingKey(r.body.rule_name, r.body.timetag);
                r.body.matched = this.#matched.get(key) ?? null;
                r.body.logs = this.#logs.get(key) ?? [];
            }
            if (is(r, "CallIssued")) {
                const ext = this.#externals.get(r.body.seq);
                if (ext !== undefined) {
                    r.externals = ext;
                    this.#externals.delete(r.body.seq);
                }
            }
            const b = r.body;
            if ("rule_name" in b) {
                const alias = this.#aliases.get(b.rule_name);
                if (alias !== undefined) {
                    b.compiled_name = b.rule_name;
                    b.rule_name = alias;
                }
            }
        }
        if (this.tl.header === null && this.#dec.header !== null) this.tl.header = this.#dec.header;
        this.tl.extend(recs);
    }

    /** @param {StreamEngineEvent} ev  one of HEARD */
    #on(ev) {
        switch (ev.type) {
        case "rule_lhs_facts":
            this.#lhs = ev.lhsFacts.map((f) => f.id);
            break;
        case "rule_fire_begin":
            this.#firing = firingKey(ev.ruleName, ev.timetag);
            this.#matched.set(this.#firing, this.#lhs);
            this.#lhs = [];
            break;
        case "rule_fire_end":
            this.#firing = null;
            break;
        case "action_log":
            if (this.#firing !== null) {
                const lines = this.#logs.get(this.#firing) ?? [];
                this.#logs.set(this.#firing, lines);
                lines.push(`${ev.level}: ${ev.message}`);
            }
            break;
        case "action_call": {
            /** @type {Array<[string, Uint8Array]>} */
            const facts = [];
            for (const [name, v] of Object.entries(ev.args)) {
                // A fact argument is the one object with its FactExternal bytes.
                if (typeof v === "object" && v !== null && "external" in v && v.external instanceof Uint8Array)
                    facts.push([name, v.external]);
            }
            if (facts.length) this.#externals.set(ev.seq, new Map(facts));
            break;
        }
        case "action_cache_get":
            this.#hear({ op: "get", key: ev.key, value: ev.valueJson }, null);
            break;
        case "timer_armed":
            this.#hear(null, { rule: ev.ruleName, kind: ev.timerKind, windowNs: ev.windowNs, fireAtNs: ev.fireAtNs });
            break;
        }
    }
}
