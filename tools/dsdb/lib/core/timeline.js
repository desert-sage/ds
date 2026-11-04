// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// A timeline: records plus the indexes every command reads
// (DSTRACE_INTERACTIVE §3, §7.6). The port of tools/dstrace_shell/timeline.py.
//
// POINTS ARE RECORD COUNTS. A point `k` is the state after the first `k`
// records, `0 <= k <= length`. Everything here takes and returns points; the
// shell's `@N` notation is a NAME for a point (§3.2), resolved by `resolve`
// and produced by `name`. Keeping the two apart is what lets a settled point
// that has no name of its own (§3.3) still be a point the shell can stand on.
//
// Nothing here runs an engine or interprets DS. Facts start at an assert and
// end at a retract or withdrawal, exactly as recorded; firings are the
// recorded begin and end annotations; calls pair with replies by `corr`. That
// is the trace read back, which §1's third principle requires, not the engine
// re-imagined.
//
// NUMBERS: points and record indexes are Numbers. Seqs, fact ids, timetags
// and clocks are BigInts, as trace.js gives them.
//
// Indexing is incremental (`extend`) so `-f` can grow a timeline without
// rebuilding it.

import { is } from "./trace.js";

/** @import { CallArg, CallOutcome } from "./calls.js" */
/** @import { Bodies, ExternalFact, FactSlots, TraceRecord } from "./trace.js" */

/**
 * A record of one of the messages `M`, with that atom's body.
 * @template {import("./trace.js").Message} M
 * @typedef {Extract<TraceRecord, { kind: M }>} RecordOf
 */

const SUPERSEDED = 3n;          // FactWithdraw.Cause.SUPERSEDED, fact_withdraw.proto

/**
 * Python's bisect_left, over Numbers or BigInts.
 * @template {number | bigint} T
 * @param {T[]} a
 * @param {T} x
 * @returns {number}
 */
export function bisectLeft(a, x) {
    let lo = 0, hi = a.length;
    while (lo < hi) {
        const mid = (lo + hi) >>> 1;
        if (a[mid] < x) lo = mid + 1;
        else hi = mid;
    }
    return lo;
}

/**
 * Python's bisect_right, over Numbers or BigInts.
 * @template {number | bigint} T
 * @param {T[]} a
 * @param {T} x
 * @returns {number}
 */
export function bisectRight(a, x) {
    let lo = 0, hi = a.length;
    while (lo < hi) {
        const mid = (lo + hi) >>> 1;
        if (x < a[mid]) hi = mid;
        else lo = mid + 1;
    }
    return lo;
}

/**
 * The schemas a FactExternal's delivery asserts when every inlined copy is
 * asserted, in [RFCS.24.3]'s order: each copy innermost first (a copy's own
 * references before it), then the received fact.
 * @param {ExternalFact} fact
 * @returns {string[]}
 */
function deliveryOrder(fact) {
    /** @type {string[]} */
    const out = [];
    /** @param {ExternalFact} fx */
    const copies = (fx) => {
        for (const a of /** @type {Array<{ fact?: ExternalFact | null }>} */ (fx.fields ?? [])) {
            if (a.fact === undefined || a.fact === null) continue;
            copies(a.fact);
            out.push(a.fact.schema);
        }
    };
    copies(fact);
    out.push(fact.schema);
    return out;
}

/** One fact's life in the trace. `asserted` and `ended` are record indexes;
    the fact is live at point `k` iff `asserted < k <= ended`, i.e. its assert
    is applied and its end is not. */
export class Fact {
    /**
     * @param {{ factId: bigint, schema: string, slots: FactSlots | null, untyped?: string | null,
     *           origin: "integrator" | "rule", rule: string, ttlNs: bigint, asserted: number }} f
     */
    constructor({ factId, schema, slots, untyped = null, origin, rule, ttlNs, asserted }) {
        this.factId = factId;
        this.schema = schema;
        this.slots = slots;             // null when the stream did not type it
        this.untyped = untyped;         // and then why not (trace.js `Decoder`)
        this.origin = origin;           // "integrator" (FactAssert) or "rule" (FactEmit)
        this.rule = rule;
        this.ttlNs = ttlNs;
        this.asserted = asserted;
        /** @type {number | null} */
        this.ended = null;
        /** @type {"retract" | "withdraw" | null} "retract" (FactRetract) or "withdraw" (FactWithdraw) */
        this.endKind = null;
        /** @type {string | null} FactWithdraw cause name */
        this.cause = null;
        /** @type {bigint | null} fact id this one superseded */
        this.prior = null;
        /** @type {bigint | null} fact id that superseded this one */
        this.successor = null;
        /** @type {number[]} record indexes of FactEmits that coalesced with it */
        this.reemits = [];
    }

    /** @param {number} k */
    liveAt(k) {
        return this.asserted < k && (this.ended === null || this.ended >= k);
    }
}

export class Firing {
    /** @param {{ rule: string, timetag: bigint, begin: number, matched?: bigint[] | null }} f */
    constructor({ rule, timetag, begin, matched = null }) {
        this.rule = rule;
        this.timetag = timetag;
        this.begin = begin;
        /** @type {number | null} */
        this.end = null;
        /** @type {number[]} record indexes */
        this.effects = [];
        // The matched facts' ids, in pattern order: known in a live session or
        // a hypothesis (§8.4), from the provenance pass in replay (§8.8), and
        // otherwise null, because a trace does not record them.
        this.matched = matched;
    }
}

export class Call {
    /**
     * @param {{ number: number, rule: string, timetag: bigint, service: string, corr: string | null,
     *           args: CallArg[], waits: boolean, issued: number }} c
     */
    constructor({ number, rule, timetag, service, corr, args, waits, issued }) {
        this.number = number;           // per timeline, from 1, in issue order
        this.rule = rule;
        this.timetag = timetag;
        this.service = service;
        this.corr = corr;               // null for a call with no `as`
        this.args = args;               // core/calls.js's { name, type, value }, by name
        // Whether a response can answer it: its service declares one, and it
        // has a `corr` for the response to carry (§4.10).
        this.waits = waits;
        this.issued = issued;
        /** @type {CallOutcome} */
        this.outcome = waits ? "waiting" : "no response";
        /** @type {number | null} record index of the reply or superseder */
        this.resolved = null;
    }

    /** @param {number} k */
    waitingAt(k) {
        return this.waits && this.issued < k && (this.resolved === null || this.resolved >= k);
    }

    /**
     * Whether a recorded reply settled it before point `k`.
     * @param {number} k
     */
    repliedAt(k) {
        return (this.outcome === "answered" || this.outcome === "failed") && this.resolved !== null
            && this.resolved < k;
    }
}

export class Timeline {
    /** @type {Map<string, number[]>} schema -> record indexes of asserts */
    #starts = new Map();
    /** @type {Map<string, number[]>} schema -> record indexes of ends */
    #ends = new Map();
    /** @type {Map<string, Firing>} "rule\0timetag" -> Firing */
    #open = new Map();
    /** @type {Firing | null} */
    #current = null;
    /** @type {[string, bigint, number] | null} [schema, fact id, record index] */
    #supersede = null;
    #afterPump = true;         // the next inject record begins a step

    /**
     * @param {Iterable<TraceRecord>} [records]
     * @param {Bodies["StreamHeader"] | null} [header]  the decoder's header, if it has one
     * @param {Map<string, import("./program.js").Service>} [services]  the
     *   program's: what each service responds with. A trace does not say; a
     *   service missing here is read as declaring a response.
     */
    constructor(records = [], header = null, services = new Map()) {
        this.header = header;
        this.services = services;
        /** @type {TraceRecord[]} */
        this.records = [];
        /** @type {bigint[]} per record; -1n before any seq */
        this.anchors = [];
        /** @type {Set<bigint>} */
        this.seqs = new Set();
        /** @type {Map<bigint, Fact>} fact id -> Fact */
        this.facts = new Map();
        /** @type {number[]} ends naming no live fact */
        this.unmatched = [];
        /** @type {Firing[]} */
        this.firings = [];
        /** @type {Call[]} */
        this.calls = [];
        /** @type {number[]} settled points, except the end */
        this.settled = [];
        this.extend(records);
    }

    // ── building ──────────────────────────────────────────────────────

    /** @param {Iterable<TraceRecord>} records */
    extend(records) {
        for (const r of records) this.#add(r);
    }

    /** @param {TraceRecord} r */
    #add(r) {
        if (r.index !== this.records.length)
            throw new RangeError(`record ${r.index} out of order at ${this.records.length}`);
        if (r.cls === "inject") {
            // A settled point is where a pump's cascade has ended: just
            // before the first inject record after a PumpBoundary, which
            // begins the host's next step. A logical assert that
            // supersedes is recorded AFTER the withdrawal it causes (the
            // recorder writes the FactWithdraw first), so a step it begins
            // starts one record earlier, at that withdrawal.
            if (this.#afterPump) {
                const p = this.records.length ? this.records[this.records.length - 1] : null;
                const old = p !== null && is(p, "FactWithdraw") ? this.facts.get(p.body.fact_id) : undefined;
                if (is(r, "FactAssert") && p !== null && is(p, "FactWithdraw")
                        && p.body.cause === SUPERSEDED && old !== undefined
                        && old.schema === r.body.schema_name)
                    this.settled.push(p.index);
                else
                    this.settled.push(r.index);
            }
            this.#afterPump = r.kind === "PumpBoundary";
        }
        this.records.push(r);
        const prev = this.anchors.length ? this.anchors[this.anchors.length - 1] : -1n;
        // Anchors must never decrease, or `resolve` bisects a list that is not
        // sorted. A seq lower than the last one is a proto3 zero standing for
        // "not set" (a hand-written FactAssert, say), so it anchors like a record
        // with no seq at all.
        const own = r.seq !== null && r.seq > prev;
        this.anchors.push(own && r.seq !== null ? r.seq : prev);
        if (own && r.seq !== null) this.seqs.add(r.seq);
        if (is(r, "StreamHeader")) this.header = r.body;

        if (is(r, "FactAssert", "FactEmit")) this.#assert(r);
        else if (is(r, "ExternalAssert")) this.#external(r);
        else if (is(r, "FactRetract", "FactWithdraw")) this.#end(r);
        else if (is(r, "RuleFireAnnotation")) this.#annotation(r);
        else if (is(r, "CallIssued")) this.#call(r);

        if (r.cls === "derived" && r.kind !== "RuleFireAnnotation" && this.#current !== null)
            this.#current.effects.push(r.index);
    }

    /** @param {RecordOf<"FactAssert" | "FactEmit">} r */
    #assert(r) {
        const b = r.body;
        // A rule re-deriving a live logical fact with the same values
        // coalesces with it ([LFAC.2.5.1]), and the recorder still writes a
        // FactEmit, with the live fact's id (§10.13 check 2). It is one more
        // emitter of that fact, not a second fact: the first assert stays
        // where the fact began, and the population does not count it twice.
        const live = this.facts.get(b.fact_id);
        if (r.kind === "FactEmit" && live !== undefined && live.ended === null) {
            live.reemits.push(r.index);
            this.#supersede = null;
            return;
        }
        const f = new Fact({
            factId: b.fact_id, schema: b.schema_name, slots: b.slots ?? null, untyped: b.untyped ?? null,
            origin: r.kind === "FactEmit" ? "rule" : "integrator",
            rule: b.rule_name ?? "", ttlNs: b.ttl_ns ?? 0n, asserted: r.index,
        });
        this.facts.set(f.factId, f);
        push(this.#starts, f.schema, r.index);
        // A supersession pairs the withdrawn fact with the assert beside it in
        // the same cascade (§4.6). The key slots are not in a trace,
        // so the pairing is positional, never by value.
        const s = this.#supersede;
        if (s && s[0] === f.schema && s[2] === r.index - 1) this.#link(s[1], f.factId);
        this.#supersede = null;
        // `corr` is the slot the language gives a meaning: the correlation of
        // the call that brought the fact in. An integrator
        // assert carrying one is a reply.
        const corr = f.slots?.corr;
        if (r.kind === "FactAssert" && typeof corr === "string") this.#reply(f, corr, r.index);
    }

    /**
     * The facts an ExternalAssert asserted, one per `fact_ids` entry, in
     * [RFCS.24.3]'s order: each inlined copy, innermost first, then the
     * received fact, which carries the record's `ttl_ns`. A copy that resolved
     * to a live fact asserted nothing and has no entry ([RFCS.23.7]). So when
     * every copy has one, the walk of the FactExternal names each copy's
     * schema; when some do not, which copies remain depends on the engine's
     * state, and only the received fact's schema is read.
     * @param {RecordOf<"ExternalAssert">} r
     */
    #external(r) {
        const b = r.body, ids = b.fact_ids;
        const order = deliveryOrder(b.fact);
        const known = order.length === ids.length;
        ids.forEach((id, i) => {
            const last = i === ids.length - 1;
            const schema = last ? b.fact.schema : known ? order[i] : "";
            const f = new Fact({
                factId: id, schema, slots: null, origin: "integrator", rule: "",
                ttlNs: last ? (b.ttl_ns ?? 0n) : 0n, asserted: r.index,
                untyped: schema === ""
                    ? "an inlined copy whose schema the record does not fix: some copies resolved to live facts ([RFCS.23.7])"
                    : "delivered by an ExternalAssert: its values are the FactExternal's, as the record lists them",
            });
            this.facts.set(f.factId, f);
            if (schema !== "") push(this.#starts, schema, r.index);
        });
        this.#supersede = null;
    }

    /** @param {RecordOf<"FactRetract" | "FactWithdraw">} r */
    #end(r) {
        const fid = r.body.fact_id;
        const f = this.facts.get(fid);
        if (f === undefined || f.ended !== null) {
            this.unmatched.push(r.index);
            return;
        }
        f.ended = r.index;
        f.endKind = r.kind === "FactWithdraw" ? "withdraw" : "retract";
        if (is(r, "FactWithdraw")) {
            f.cause = r.body.cause_name ?? null;
            if (r.body.cause === SUPERSEDED) {
                const prev = r.index ? this.records[r.index - 1] : null;
                if (prev !== null && is(prev, "FactAssert", "FactEmit") && prev.body.schema_name === f.schema)
                    this.#link(fid, prev.body.fact_id);
                else
                    this.#supersede = [f.schema, fid, r.index];
            }
        }
        push(this.#ends, f.schema, r.index);
    }

    /**
     * @param {bigint} old
     * @param {bigint} now
     */
    #link(old, now) {
        const o = this.facts.get(old), n = this.facts.get(now);
        if (o !== undefined && n !== undefined) {
            o.successor = now;
            n.prior = old;
        }
    }

    /** @param {RecordOf<"RuleFireAnnotation">} r */
    #annotation(r) {
        const rule = r.body.rule_name, timetag = r.body.timetag;
        const key = `${rule}\0${timetag}`;
        if (!r.body.end) {
            const fr = new Firing({ rule, timetag, begin: r.index, matched: r.body.matched ?? null });
            this.firings.push(fr);
            this.#open.set(key, fr);
            this.#current = fr;
        } else {
            const fr = this.#open.get(key);
            if (fr !== undefined) {
                this.#open.delete(key);
                fr.end = r.index;
            }
            this.#current = null;
        }
    }

    /** @param {RecordOf<"CallIssued">} r */
    #call(r) {
        const b = r.body;
        // Every call carries a correlation, never empty ([LCCO.3.4]). This
        // guards a trace recorded before that held, whose CallIssued carries
        // proto3's unset "", so that it reads as no correlation and joins no
        // reply.
        const corr = b.correlation === "" ? null : b.correlation;
        for (const c of this.calls) {
            if (corr !== null && c.corr === corr && open(c)) {
                c.outcome = "superseded";
                c.resolved = r.index;
            }
        }
        const responds = (this.services.get(b.service)?.response ?? "?") !== "";
        // A live engine's timeline gives a fact argument its bytes, by name.
        const ext = r.externals;
        const args = ext ? b.args.map((a) => (a.type === "Fact" && ext.has(a.name)
            ? { ...a, value: { ...a.value, external: ext.get(a.name) ?? null } } : a)) : b.args;
        this.calls.push(new Call({
            number: this.calls.length + 1, rule: b.rule_name, timetag: b.timetag,
            service: b.service, corr, args, waits: responds && corr !== null, issued: r.index,
        }));
    }

    /**
     * A reply settles the latest open call with its `corr`: a `CallError`
     * fails it, waiting or not, since a `no response` service may still fail;
     * a response answers a waiting call, when it is of the call's response
     * schema.
     * @param {Fact} f
     * @param {string} corr  `f`'s
     * @param {number} index
     */
    #reply(f, corr, index) {
        const failed = f.schema === CALL_ERROR;
        for (let i = this.calls.length - 1; i >= 0; i--) {
            const c = this.calls[i];
            if (c.corr !== corr || !open(c)) continue;
            if (!failed && (c.outcome !== "waiting" || !this.#answers(c, f.schema))) return;
            c.outcome = failed ? "failed" : "answered";
            c.resolved = index;
            return;
        }
    }

    /**
     * @param {Call} c
     * @param {string} schema
     */
    #answers(c, schema) {
        const s = this.services.get(c.service);
        return s === undefined || s.response === schema;
    }

    // ── points and their names (§3.2, §3.3) ───────────────────────────

    get length() {
        return this.records.length;
    }

    /** Whether settled points are known (§3.3). The stream records every
        pump, so they are known for any trace with a header; one
        without a header is not a whole stream. */
    get canonical() {
        return this.header !== null;
    }

    /** @param {number} k */
    isSettled(k) {
        if (!this.canonical) return false;
        if (k === this.records.length) return true;
        const i = bisectLeft(this.settled, k);
        return i < this.settled.length && this.settled[i] === k;
    }

    /**
     * The first settled point after `k`, the end included.
     * @param {number} k
     * @returns {number | null}
     */
    nextSettled(k) {
        if (!this.canonical || k >= this.records.length) return null;
        const i = bisectRight(this.settled, k);
        return i < this.settled.length ? this.settled[i] : this.records.length;
    }

    /**
     * @param {number} k
     * @returns {number | null}
     */
    prevSettled(k) {
        if (!this.canonical || k <= 0) return null;
        const i = bisectLeft(this.settled, k);
        return i ? this.settled[i - 1] : null;
    }

    /**
     * `[N, m]` for the point written `@N` followed by `m` minus signs, or null
     * for a point before any sequence number. `m` is how many records with no
     * seq of their own follow `k` under the same anchor (§3.3).
     * @param {number} k
     * @returns {[bigint, number] | null}
     */
    name(k) {
        if (k === 0 || this.anchors[k - 1] < 0n) return null;
        const n = this.anchors[k - 1];
        return [n, bisectRight(this.anchors, n) - k];
    }

    /**
     * `[k, exact]`: the point `@seq` (with `minus` minus signs) names, and
     * whether a record carries exactly that seq. A seq no record has names the
     * nearest earlier point (§3.2). Past the last seq, null.
     * @param {bigint} seq
     * @param {number} [minus]
     * @returns {[number, boolean] | null}
     */
    resolve(seq, minus = 0) {
        // Own seqs strictly increase, so the last anchor is the largest.
        if (!this.seqs.size || seq > this.anchors[this.anchors.length - 1]) return null;
        const top = bisectRight(this.anchors, seq);
        const k = top - minus;
        if (minus && (k < 1 || this.anchors[k - 1] !== this.anchors[top - 1])) return null;
        return [k, this.seqs.has(seq)];
    }

    /**
     * @param {number} k
     * @returns {bigint}
     */
    clockAt(k) {
        if (k > 0) return this.records[k - 1].clockNs;
        return this.records.length ? this.records[0].clockNs : 0n;
    }

    /**
     * The first point whose clock is at or after `clockNs`.
     * @param {bigint} clockNs
     */
    firstAtClock(clockNs) {
        for (let k = 1; k <= this.records.length; k++)
            if (this.records[k - 1].clockNs >= clockNs) return k;
        return this.records.length;
    }

    // ── what holds at a point ─────────────────────────────────────────

    /** @param {number} k */
    liveFacts(k) {
        return [...this.facts.values()].filter((f) => f.liveAt(k));
    }

    /**
     * Live facts per schema at point `k` (§4.4 `#.`), as a Map. Every schema
     * seen in the trace is present, zero rows included.
     * @param {number} k
     * @returns {Map<string, number>}
     */
    population(k) {
        const out = new Map();
        for (const schema of this.schemas()) {
            const started = bisectLeft(this.#starts.get(schema) ?? [], k);
            const ended = bisectLeft(this.#ends.get(schema) ?? [], k);
            out.set(schema, started - ended);
        }
        return out;
    }

    /**
     * `[point, population]` at every point the schema's count changes, in
     * order — the step function a histogram (§4.4 `#:`) samples.
     * @param {string} schema
     * @returns {Array<[number, number]>}
     */
    changes(schema) {
        /** @type {Array<[number, number]>} */
        const events = [];
        for (const i of this.#starts.get(schema) ?? []) events.push([i + 1, 1]);
        for (const i of this.#ends.get(schema) ?? []) events.push([i + 1, -1]);
        // Python sorts the tuples: by point, then -1 before +1.
        events.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
        /** @type {Array<[number, number]>} */
        const out = [];
        let n = 0;
        for (const [k, d] of events) {
            n += d;
            if (out.length && out[out.length - 1][0] === k) out[out.length - 1] = [k, n];
            else out.push([k, n]);
        }
        return out;
    }

    /** @returns {string[]} */
    schemas() {
        return [...new Set([...this.#starts.keys(), ...this.#ends.keys()])].sort();
    }

    // ── cascades and firings (§4.3, §4.11) ────────────────────────────

    /**
     * `{ start, stop }`: the record indexes `[start, stop)` of the cascade that
     * led to point `k`, from the previous settled point (or the one at `k`, if
     * `k` is mid-cascade) up to `k`. Empty when settled points are unknown.
     * @param {number} k
     * @returns {{ start: number, stop: number }}
     */
    cascade(k) {
        if (!this.canonical || k === 0) return { start: 0, stop: 0 };
        let start;
        if (this.isSettled(k)) start = this.prevSettled(k);
        else {
            const i = bisectRight(this.settled, k);
            start = i ? this.settled[i - 1] : 0;
        }
        return { start: start ?? 0, stop: k };
    }

    /**
     * Firings whose begin annotation is a record index in `[lo, hi)`.
     * @param {number} lo
     * @param {number} hi
     */
    firingsIn(lo, hi) {
        return this.firings.filter((f) => lo <= f.begin && f.begin < hi);
    }

    /**
     * Firings per rule in `[lo, hi)`, as a Map in first-firing order.
     * @param {number} lo
     * @param {number} hi
     * @returns {Map<string, number>}
     */
    firingCounts(lo, hi) {
        const out = new Map();
        for (const f of this.firingsIn(lo, hi)) out.set(f.rule, (out.get(f.rule) ?? 0) + 1);
        return out;
    }

    // ── calls (§4.10) ─────────────────────────────────────────────────

    /** @param {number} k */
    waitingCalls(k) {
        return this.calls.filter((c) => c.waitingAt(k));
    }
}

const CALL_ERROR = "CallError";

/** Whether a reply could still settle `c`: it waits, or it does not but has a
    `corr` a `CallError` can name.
    @param {Call} c */
const open = (c) => c.outcome === "waiting" || (c.outcome === "no response" && c.corr !== null);

/**
 * @param {Map<string, number[]>} map
 * @param {string} key
 * @param {number} value
 */
function push(map, key, value) {
    const a = map.get(key);
    if (a === undefined) map.set(key, [value]);
    else a.push(value);
}
