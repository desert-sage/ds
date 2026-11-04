// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Records: one per atom, decoded once (DSTRACE_INTERACTIVE §3.1). The port of
// tools/dstrace_shell/records.py.
//
// NO CODEC HERE. libds reads every atom (through @ds-lang/ds's readAtoms) and
// types every fact body (decodeFactBody by the program, decodeAnnouncedFactBody
// by the stream's own Slot atoms). What this file does is put libds's
// answer into the shape `Bodies` below states, key for key and in its order:
// the shape dstrace printed, which the renderers print still, since dsdb's
// output was made byte-identical to dstrace's (DSDB.md §1).
//
// NUMBERS: every integer in a body is a BigInt, as Python's int prints; enum
// fields are their number, as a BigInt. `index` and `offset` are Numbers, and
// so are the 32-bit `node_id`, `module_id` and `sig_alg`, as libds reads them.
//
// The decoder is incremental so `-f` and an engine's own recording can grow a
// timeline: it is fed the stream so far and returns only the records
// completed since the last feed. A truncated trailing atom is not yet a
// record ([RFCS.19.2]); it is read on the next feed.

import { recordedArgs } from "./calls.js";
import { RecordedRef } from "./ref.js";

/** @import { AnnouncedSlot, Atom, Engine, SlotValue } from "@ds-lang/ds" */
/** @import { CallArg } from "./calls.js" */
/** @import { Ds } from "./types.js" */

// An atom is named by its body's message, as libds names it: one
// vocabulary, from atom.proto, and no second spelling.

/** What a replayer applies ([RFCS.17.5]): the host's inputs, the clock
    samples taken for them, and its pumps. An ExternalAssert is a host
    input whose fact holds a fact reference ([RFCS.24.1]). */
export const INJECT = new Set(["FactAssert", "ExternalAssert", "FactRetract", "ClockAdvance", "PumpBoundary"]);
/** The inputs among them: what the integrator asserted or retracted. */
export const INPUT = new Set(["FactAssert", "ExternalAssert", "FactRetract"]);
export const DERIVED = new Set(["FactEmit", "FactPublish", "FactWithdraw", "RuleFireAnnotation", "CallIssued",
                                "ComputationError", "TypeError", "BoundsError", "EngineError"]);
/** What stops a replay at an ExternalAssert libds cannot deliver as recorded,
    after `record <index>: ` and before libds's own detail: [RFCS.24.2]'s
    divergences, a delivery that refuses or asserts a different number of
    facts than the record lists. Going on would show a run the recording does
    not hold. */
export const EXTERNAL_DIVERGED = "the ExternalAssert does not replay as recorded ([RFCS.24.2])";
// Atoms whose body carries `seq` / `clock_ns`. FactRetract carries neither.
const HAS_SEQ = new Set([...DERIVED, "FactAssert", "ExternalAssert", "ClockAdvance", "PumpBoundary"]);

const utf8 = new TextDecoder("utf-8");                  // replaces, as Python's "replace"
/** @param {{ number: number } | null | undefined} e  an enum field */
const num = (e) => (e === undefined || e === null ? 0n : BigInt(e.number));
/** @param {Uint8Array | null | undefined} b */
const bytesOrNull = (b) => (b && b.length ? b : null);

/**
 * pyds's SLOT_KIND name, less its prefix: INT, STRING, ...; "" unknown.
 * @param {{ name: string | null } | null | undefined} e
 */
const kindName = (e) => (e && e.name ? e.name.replace(/^SLOT_KIND_/, "") : "");

/** `proto/slot.proto`'s SLOT_KIND_SCHEMA: a fact-ref slot. */
const SLOT_KIND_SCHEMA = 6;

/**
 * A fact body's slots, by name, as libds types them; a fact-ref slot's value
 * is the fact its record gave (core/ref.js).
 * @typedef {Record<string, SlotValue | RecordedRef>} FactSlots
 */

/**
 * Each decoded atom's body, by its message, in the shape the renderers print.
 * @typedef {object} Bodies
 * @property {{ ds_version: string, session_id: string, tier_id: string, dsc_hash: Uint8Array | null }}
 *     StreamHeader
 * @property {{ schema_name: string, proto_source: string, compression: bigint, module_id: number }} SchemaDef
 * @property {{ schema_name: string, slot_name: string, kind: bigint, kind_name: string, schema_ref: string,
 *     sampled: boolean, retained: boolean, nullable: boolean, identity_role: bigint }} Slot
 * @property {FactBody} FactAssert
 * @property {FactBody} FactEmit
 * @property {{ schema_name: string, rule_name: string, clock_ns: bigint, seq: bigint, timetag: bigint }
 *     & Renamed} FactPublish  a rule's `publish` ran ([RFCS.27.1]): no value and no fact, since the
 *     fact is in no working memory ([LTIE.4.3])
 * @property {{ fact: ExternalFact, fact_ids: bigint[], ttl_ns: bigint, clock_ns: bigint, seq: bigint,
 *     bytes: Uint8Array }} ExternalAssert  `fact_ids`: the facts the input asserted, in [RFCS.24.3]'s
 *     order, the received one last; `bytes`, the body as framed
 * @property {{ fact_id: bigint }} FactRetract
 * @property {{ fact_id: bigint, cause: bigint, cause_name: string, clock_ns: bigint, seq: bigint }} FactWithdraw
 * @property {{ seq: bigint, clock_ns: bigint, wall_ns: bigint | null }} ClockAdvance
 * @property {{ seq: bigint, clock_ns: bigint, rule_name: string, timetag: bigint, end: boolean,
 *     matched?: bigint[] | null, logs?: string[] } & Renamed} RuleFireAnnotation  `matched` where a live
 *     engine or the provenance pass knows it; `logs`, a live engine's firing's log lines
 * @property {{ service: string, correlation: string, args: CallArg[], rule_name: string, timetag: bigint,
 *     clock_ns: bigint, seq: bigint } & Renamed} CallIssued
 * @property {{ seq: bigint, clock_ns: bigint }} PumpBoundary
 * @property {{ trap_kind: bigint, rule_name: string, timetag: bigint, schema_name: string, slot_name: string,
 *     fact_id: bigint, node_id: number, recoverable: boolean, clock_ns: bigint, seq: bigint } & Renamed}
 *     ComputationError
 * @property {{ node_id: number, schema_name: string, slot_name: string, actual: string, clock_ns: bigint,
 *     seq: bigint }} TypeError
 * @property {{ cap: bigint, limit: bigint, observed: bigint, rule_name: string, timetag: bigint,
 *     clock_ns: bigint, seq: bigint } & Renamed} BoundsError
 * @property {{ engine_fault: bigint, node_id: number, clock_ns: bigint, seq: bigint }} EngineError
 */

/**
 * An asserted or emitted fact's body. `slots` is null when nothing types it,
 * and `untyped` then says why.
 * @typedef {{ fact_id: bigint, schema_name: string, slots: FactSlots | null, untyped: string | null,
 *     fact_bytes: Uint8Array, ttl_ns: bigint, clock_ns: bigint, rule_name: string, seq: bigint,
 *     event_id: bigint } & Renamed} FactBody
 */

/**
 * An ExternalAssert's fact: the FactExternal message ([RFCS.23.1]) as libds's
 * reader visits it, field by field, its referenced facts inlined in `fields`.
 * What is shown; the record's `bytes` are what is applied.
 * @typedef {{ schema: string, schema_hash: Uint8Array, fields?: object[], asserted_at: bigint,
 *     has_asserted_at: boolean }} ExternalFact
 */

/**
 * A body naming a rule an engine-backed timeline knows by another name (a
 * changed program's, §8.6): `rule_name` is the user's, `compiled_name` the
 * engine's (engine-timeline.js).
 * @typedef {{ compiled_name?: string }} Renamed
 */

/**
 * One record: an atom, where it is, and its body.
 * @template {string} M
 * @template B
 * @typedef {object} RecordOf
 * @property {number} index   position in the stream, from 0
 * @property {M} kind         the atom's message: "FactAssert"
 * @property {"inject" | "derived" | "structural"} cls
 * @property {bigint | null} seq
 * @property {bigint} clockNs  its own clock, else the last seen before it (§3.4)
 * @property {boolean} ownClock
 * @property {number} offset  byte offset in the source
 * @property {B} body    the atom's body, as `Bodies` has it
 * @property {Map<string, Uint8Array>} [externals]  a live engine's CallIssued: its fact arguments' bytes, by name
 */

/** @typedef {keyof Bodies} Message  an atom the decoder decodes */

/**
 * A record of an atom the decoder does not decode (an unknown field number, such
 * as 259, or one a newer writer added): kept, so positions and counts stay
 * true. Its `kind` is its message, or `atom <field number>` for one this build
 * has no entry for.
 * @typedef {RecordOf<string, { body_len: number }>} OtherRecord
 */

/** @typedef {{ [M in Message]: RecordOf<M, Bodies[M]> }[Message] | OtherRecord} TraceRecord */

/**
 * Whether `r` is a record of one of `messages`, and so carries that atom's
 * body. The test is the message alone: the decoder decodes every atom whose
 * message it knows. (An undecoded record's kind is any string, so comparing
 * `r.kind` itself does not narrow the union.)
 * @template {Message} M
 * @param {TraceRecord} r
 * @param {...M} messages
 * @returns {r is Extract<TraceRecord, { kind: M }>}
 */
export function is(r, ...messages) {
    return /** @type {readonly string[]} */ (messages).includes(r.kind);
}

export class Decoder {
    /** @type {Ds} */
    #ds;
    /** @type {Uint8Array | null} the program the stream was recorded with, if known */
    #dsc;
    /** @type {Engine | null} a scratch engine with that program loaded, made on first use */
    #typer = null;
    /** @type {Map<string, Array<[string, string, boolean]>>} schema name -> [slot, kind name, nullable],
        from the stream's Slot atoms ([RFCS.5.1]) */
    slots = new Map();
    /** @type {Map<string, AnnouncedSlot[]>} the same announcement, as libds types a body by it */
    #announced = new Map();
    /** @type {Bodies["StreamHeader"] | null} */
    header = null;
    pos = 0;                       // byte offset of the next unread atom
    count = 0;                     // records produced so far
    clock = 0n;
    /** @type {[number, string] | null} `[offset, message]` of the first malformed atom, if any (§6) */
    error = null;

    /**
     * @param {Ds} ds  a `@ds-lang/ds` API from `open()`
     * @param {{ dsc?: Uint8Array | null }} [o]  `dsc`, the program the stream
     *   was recorded with: a fact body is typed by its schema there. Without
     *   it, by the stream's own announcement.
     */
    constructor(ds, { dsc = null } = {}) {
        this.#ds = ds;
        this.#dsc = dsc;
    }

    close() {
        this.#typer?.close();
        this.#typer = null;
    }

    /**
     * Every complete atom of `data` past what was already read.
     * @param {Uint8Array} data  the source from byte `start` on, normally all of it
     * @param {number} [start]
     * @returns {TraceRecord[]}
     */
    feed(data, start = 0) {
        if (this.error !== null) return [];
        const base = this.pos;
        const view = data.subarray(base - start);
        const r = this.#ds.readAtoms(view, { incremental: true });
        const out = r.atoms.map((a) => this.#record(a, base + a.offset, view));
        // Where the read stopped: the end, a partial atom's start, or the bad
        // atom. Everything after an error stays unread for good, since no
        // append can make those bytes a record (§6).
        this.pos = base + r.end;
        if (r.error !== null) this.error = [base + r.error.offset, r.error.detail];
        return out;
    }

    /**
     * @param {Atom} a
     * @param {number} offset
     * @param {Uint8Array} view  what `a` was read from
     * @returns {TraceRecord}
     */
    #record(a, offset, view) {
        const kind = a.message ?? `atom ${a.field}`;
        const body = this.#body(kind, a, view);
        const seq = HAS_SEQ.has(kind) && "seq" in body ? (body.seq ?? null) : null;
        const clockNs = HAS_SEQ.has(kind) && "clock_ns" in body ? body.clock_ns : 0n;
        const own = Boolean(clockNs);
        // Clocks only move forward in a recording; a smaller one is a proto3
        // zero standing for "not set", not a rewind.
        if (own && clockNs > this.clock) this.clock = clockNs;
        const cls = INJECT.has(kind) ? "inject" : DERIVED.has(kind) ? "derived" : "structural";
        // #body chose the body by the same message, which is what pairs the two.
        return /** @type {TraceRecord} */ ({ index: this.count++, kind, cls, seq, clockNs: this.clock,
                                             ownClock: own, offset, body });
    }

    /**
     * @param {string} kind  the atom's message
     * @param {Atom} a
     * @param {Uint8Array} view  what `a` was read from
     * @returns {Bodies[Message] | { body_len: number }}
     */
    #body(kind, a, view) {
        if (a.body === null) return { body_len: a.bodyLength };
        // An atom's fields are its message's in proto/, as libds decodes them;
        // this is where dsdb reads them by name, and the bodies below are
        // what it makes of them.
        /** @type {Record<string, any>} */
        const v = a.body;
        switch (kind) {
        case "StreamHeader":
            // There is no fire_cadence: the stream records every pump.
            this.header = {
                ds_version: v.ds_version, session_id: v.session_id, tier_id: v.tier_id,
                dsc_hash: bytesOrNull(v.dsc_hash),
            };
            return { ...this.header };
        case "SchemaDef":
            if (!this.slots.has(v.schema_name)) this.slots.set(v.schema_name, []);
            if (!this.#announced.has(v.schema_name)) this.#announced.set(v.schema_name, []);
            return { schema_name: v.schema_name, proto_source: utf8.decode(v.proto_source ?? new Uint8Array()),
                     compression: num(v.compression), module_id: v.module_id };
        case "Slot": {
            const kn = kindName(v.kind);
            const slots = this.slots.get(v.schema_name) ?? [];
            this.slots.set(v.schema_name, slots);
            // Whether the slot is nullable rides with it: a nullable slot's
            // body field has presence ([RFCS.6.3]), so #typed must say so.
            slots.push([v.slot_name, kn, Boolean(v.nullable)]);
            const announced = this.#announced.get(v.schema_name) ?? [];
            this.#announced.set(v.schema_name, announced);
            announced.push({ name: v.slot_name, kind: v.kind?.number ?? 0, nullable: Boolean(v.nullable),
                             schemaRef: v.schema_ref || null });
            return { schema_name: v.schema_name, slot_name: v.slot_name, kind: num(v.kind), kind_name: kn,
                     schema_ref: v.schema_ref, sampled: v.sampled, retained: v.retained,
                     nullable: v.nullable, identity_role: num(v.identity_role) };
        }
        case "FactAssert": {
            const [slots, untyped] = this.#typed(v.schema_name, v.fact);
            return { fact_id: v.fact_id, schema_name: v.schema_name, slots, untyped,
                     fact_bytes: v.fact, ttl_ns: v.ttl_ns, clock_ns: v.clock_ns, rule_name: v.rule_name,
                     seq: v.seq, event_id: v.event_id };
        }
        case "FactEmit": {
            const [slots, untyped] = this.#typed(v.schema_name, v.fact);
            return { fact_id: v.fact_id, schema_name: v.schema_name, slots, untyped,
                     fact_bytes: v.fact, ttl_ns: v.ttl_ns, clock_ns: v.clock_ns, rule_name: v.rule_name,
                     seq: v.seq, event_id: v.event_id };
        }
        case "FactPublish":
            return { schema_name: v.schema_name, rule_name: v.rule_name, clock_ns: v.clock_ns, seq: v.seq,
                     timetag: v.timetag };
        case "ExternalAssert":
            // A repeated field with no element is not visited. `bytes` is the
            // body as framed, a copy, which libds applies (applyInject).
            return { fact: v.fact, fact_ids: v.fact_ids ?? [], ttl_ns: v.ttl_ns, clock_ns: v.clock_ns, seq: v.seq,
                     bytes: view.slice(a.bodyOffset, a.bodyOffset + a.bodyLength) };
        case "FactRetract":
            return { fact_id: v.fact_id };
        case "FactWithdraw":
            return { fact_id: v.fact_id, cause: num(v.cause),
                     cause_name: v.cause?.name ?? `CAUSE_${v.cause?.number ?? 0}`,
                     clock_ns: v.clock_ns, seq: v.seq };
        case "ClockAdvance":
            // Both clocks' sample: the wall clock's only when set.
            return { seq: v.seq, clock_ns: v.clock_ns, wall_ns: v.has_wall ? v.wall_ns : null };
        case "RuleFireAnnotation":
            return { seq: v.seq, clock_ns: v.clock_ns, rule_name: v.rule_name, timetag: v.timetag, end: v.end };
        case "CallIssued":
            // The arguments as core/calls.js keeps them. A fact
            // argument's FactExternal is decoded here, not its bytes; a live
            // engine's timeline adds those (engine-timeline.js).
            return { service: v.service, correlation: v.correlation, args: recordedArgs(v.args),
                     rule_name: v.rule_name, timetag: v.timetag, clock_ns: v.clock_ns, seq: v.seq };
        case "PumpBoundary":
            return { seq: v.seq, clock_ns: v.clock_ns };
        case "ComputationError":
            return { trap_kind: num(v.kind), rule_name: v.rule_name, timetag: v.timetag,
                     schema_name: v.schema_name, slot_name: v.slot_name, fact_id: v.fact_id,
                     node_id: v.node_id, recoverable: v.recoverable, clock_ns: v.clock_ns, seq: v.seq };
        case "TypeError":
            return { node_id: v.node_id, schema_name: v.schema_name, slot_name: v.slot_name,
                     actual: v.actual, clock_ns: v.clock_ns, seq: v.seq };
        case "BoundsError":
            return { cap: num(v.cap), limit: v.limit, observed: v.observed, rule_name: v.rule_name,
                     timetag: v.timetag, clock_ns: v.clock_ns, seq: v.seq };
        case "EngineError":
            return { engine_fault: num(v.fault), node_id: v.node_id, clock_ns: v.clock_ns, seq: v.seq };
        default:
            // An atom this decoder gives no body (an unknown field number, such
            // as 259, or one a newer writer added): kept as a record, so
            // positions and counts stay true.
            return { body_len: a.bodyLength };
        }
    }

    /**
     * A fact body's slots, and null; or null, and why it is not typed, which
     * a listing says in its place. libds types it ([LFST.8.10]): by its schema
     * in the program the stream was recorded with (decodeFactBody, in a
     * scratch engine with the program loaded), or, given no program, by the
     * stream's own Slot atoms for the schema ([RFCS.5.1]).
     *
     * A body holding a fact reference is typed by the announcement, program
     * or none: a decode by a schema refuses a reference outside a replay,
     * since its handle names a fact only within its stream ([RFCS.4]). The
     * announced decode gives each one's recorded handle, which is the
     * referenced fact's fact_id ([RFCS.6.3]). Nothing stops for a body that
     * cannot be typed.
     * @param {string} schema
     * @param {Uint8Array} bytes
     * @returns {[FactSlots, null] | [null, string]}
     */
    #typed(schema, bytes) {
        const announced = this.#announced.get(schema);
        if (this.#dsc === null) {
            if (announced === undefined) return [null, `the stream announces no schema ${schema}, and no program was given`];
            return [this.#byAnnouncement(announced, bytes), null];
        }
        if (this.#typer === null) {
            const typer = new this.#ds.Engine();
            try {
                typer.loadDsc(this.#dsc);
            } catch (e) {
                typer.close();
                throw e;
            }
            this.#typer = typer;
        }
        const info = this.#typer.schemas.get(schema);
        if (info === undefined) return [null, `the program has no schema ${schema}`];
        // A fact-ref slot's type is the schema it names (SlotInfo).
        const typer = this.#typer;
        const ref = info.slots.find((s) => typer.schemas.has(s.type));
        if (ref === undefined) return [typer.decodeFactBody(schema, bytes), null];
        if (announced === undefined)
            return [null, `${ref.name} holds a fact reference, and the stream announces no schema ${schema} to read it by`];
        return [this.#byAnnouncement(announced, bytes), null];
    }

    /**
     * A body's slots by the stream's announcement, in declaration order, each
     * fact-ref slot as the fact its record gave (decodeAnnouncedFactBodyHandles).
     * @param {AnnouncedSlot[]} slots
     * @param {Uint8Array} bytes
     * @returns {FactSlots}
     */
    #byAnnouncement(slots, bytes) {
        const got = this.#ds.decodeAnnouncedFactBodyHandles(slots, bytes);
        /** @type {FactSlots} */
        const out = {};
        for (const s of slots) {
            if (s.kind !== SLOT_KIND_SCHEMA) {
                out[s.name] = got.slots[s.name];
                continue;
            }
            const handle = got.refs[s.name];
            out[s.name] = handle === null || handle === undefined ? null : new RecordedRef(s.schemaRef ?? "", handle);
        }
        return out;
    }
}
