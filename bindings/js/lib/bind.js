// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// @ds-lang/ds — the JavaScript binding to libds (../JS_BINDING.md): the API
// over a loaded glue, the SAME for every target and every host. The C
// glue (src/ds.c) converts values and owns pointers; names, argument
// shapes and the classes live here. How the glue is loaded is the host's:
// index.js under Node (native, or wasm), browser.js in a page
// (tools/dsdb/DSDB_WEB.md §5). Nothing here imports from Node; what needs
// a platform (a file to record to, the compiler) comes in as the host.
//
// ONE GLUE PER REALM. Engine and Fact are module-level
// classes, so a TypeScript program can name them, and they reach libds through
// the one glue this realm loaded. A second open() for the same target, through
// the same entry, returns the first's API; any other open() is refused.
//
// The public records are types.js's. The glue's own shape is the `Glue`
// typedef below, and it is the one place types are asserted rather than
// checked: what a Node-API module returns is whatever its C builds, and
// src/ds.c is what the typedef is read against.

import * as status from "./status.js";

/**
 * @import {
 *     AnnouncedBody, AnnouncedSlot, Api, AtomField, AtomsRead, CacheRemoval, CallArgument, CallRequest, ClockMode, EngineEventMap,
 *     ExternalAssertApplied, FactArgument, FactRecord, FactRecordOf, FileSink, FromSource, Host, Int64, Justifier, LineSpan,
 *     LogEngineEvent,
 *     LogRecord, MatchStep, MemoryReport, Metric, MetricEngineEvent, PlatformSignature, Refraction, ReplayCounts,
 *     ReteNetwork, RuleMeta, SchemaInfo, SessionHeader,
 *     SlotValue, SlotValueOf, StreamEvent, StreamEventKind, StreamEventOf, Target,
 *     UnraisableHook, WriteThrough,
 * } from "./types.js"
 */

export { status };

/**
 * A failing libds call: the JavaScript form of a non-OK `ds_result_t`.
 *
 * Branch on `status`, never on `detail`. A failure a handler of the host's
 * caused carries the handler's exception as its `cause`.
 */
export class DsError extends Error {
    /**
     * @param {number} statusCode  libds's status number, from `proto/status.proto`
     * @param {string} [detail]  libds's text, copied when the error was made
     * @param {ErrorOptions} [options]  the error's `cause`, as Error takes it
     */
    constructor(statusCode, detail, options) {
        super(detail ? `ds status ${statusCode}: ${detail}` : `ds status ${statusCode}`, options);
        this.name = "DsError";
        /** libds's status number: compare it against `status.DS_ERR_*`. */
        this.status = statusCode;
        /** libds's text, for logs. */
        this.detail = detail ?? "";
    }
}

/**
 * A compile the compiler refused (its exit status 1): `file`, and dsc's
 * `diagnostics`. Here, not in compile.js, so every host throws the same class.
 */
export class CompileRefused extends Error {
    /**
     * @param {string} file  what the source was called
     * @param {string} diagnostics  dsc's report
     */
    constructor(file, diagnostics) {
        super(`${file}: refused by dsc\n${diagnostics}`);
        this.name = "CompileRefused";
        this.file = file;
        this.diagnostics = diagnostics;
    }
}

/**
 * A call argument of kind `Json`: libds's canonical JSON text. A `String`
 * argument is a plain string, so `instanceof JsonText` tells the two apart.
 *
 * `text` is the document as libds wrote it. `JSON.parse` reads it where every
 * integer in it fits a Number; one past 2^53 comes back rounded.
 */
export class JsonText {
    #text;

    /** @param {string} text  canonical JSON text, as libds writes it */
    constructor(text) {
        if (typeof text !== "string") throw new TypeError("text: want a string of JSON text");
        this.#text = text;
    }

    /** The document, as libds wrote it. */
    get text() { return this.#text; }

    /**
     * The document, so `String()` and a template literal give its text.
     * @returns {string}
     */
    toString() { return this.#text; }
}

/**
 * An event an Engine dispatches: a stream event, whose `type` is its kind
 * (one of STREAM_EVENT_KINDS), or a "log" or "metric" record. The record's
 * fields are the event's own: `event.fact`, `event.seq`, `event.message`.
 */
export class EngineEvent extends Event {
    /**
     * @param {string} type
     * @param {object} [fields]  set on the event as its own properties
     */
    constructor(type, fields = {}) {
        super(type);
        Object.assign(this, fields);
    }
}

/**
 * Every stream event kind, as runtime/src/bindings/ds_names.h names them. Keyed
 * by StreamEventKind, so tsc refuses a kind missing here or one the type does
 * not have.
 * @type {Record<StreamEventKind, true>}
 */
const KINDS = {
    fact_assert: true,
    fact_retract: true,
    fact_modify: true,
    rule_fire_begin: true,
    rule_fire_end: true,
    action_call: true,
    action_emit: true,
    action_publish: true,
    action_cache_set: true,
    action_cache_get: true,
    action_log: true,
    tick: true,
    action_cache_delete: true,
    rule_lhs_facts: true,
    timer_armed: true,
    timer_fired: true,
    type_error: true,
    bounds_error: true,
    engine_error: true,
    computation_error: true,
    pump: true,
    unknown: true,
};

/**
 * Every stream event kind: the `type` of each event an Engine dispatches for
 * its stream. A listener for the whole stream is added once per kind, and
 * hears every event in `seq` order.
 * @type {readonly StreamEventKind[]}
 */
export const STREAM_EVENT_KINDS = Object.freeze(/** @type {StreamEventKind[]} */ (Object.keys(KINDS)));

// ── the glue ────────────────────────────────────────────────────────────────

/** @typedef {"node" | "browser"} Entry */
/** @typedef {{ readonly brand: "@ds-lang/ds engine" }} EngineHandle */
/** @typedef {{ readonly brand: "@ds-lang/ds fact" }} FactHandle */
/** @typedef {{ readonly brand: "@ds-lang/ds replay" }} ReplayHandle */
/** @typedef {"stream" | "call" | "log" | "metric"} CallbackName */

/**
 * The glue's exports, as src/ds.c defines them.
 * @typedef {object} Glue
 * @property {(errorClass: typeof DsError, hook: UnraisableHook) => void} init
 * @property {(runId: string | null, tierId: string | null) => EngineHandle} newEngine
 * @property {(e: EngineHandle) => void} close
 * @property {(e: EngineHandle) => EngineHandle} clone
 * @property {(e: EngineHandle, bytes: Uint8Array) => void} loadDsc
 * @property {(e: EngineHandle) => number} schemaCount
 * @property {(e: EngineHandle, i: number) => SchemaInfo} schemaAt
 * @property {(e: EngineHandle, schema: string, slots: Record<string, SlotValueOf<FactHandle>>) => FactHandle} assert
 * @property {(e: EngineHandle, bytes: Uint8Array) => void} assertExternal
 * @property {(e: EngineHandle, body: Uint8Array) => ExternalAssertApplied} applyExternalAssert
 * @property {(e: EngineHandle, f: FactHandle) => void} retract
 * @property {(f: FactHandle) => bigint} factId
 * @property {(f: FactHandle) => boolean} factAlive
 * @property {(f: FactHandle) => FactRecordOf<FactHandle>} factRead
 * @property {(e: EngineHandle, schema: string | null) => FactHandle[]} facts
 * @property {(e: EngineHandle) => number} factCount
 * @property {(e: EngineHandle) => number | null} halted
 * @property {(e: EngineHandle, id: Int64) => FactHandle | null} factById
 * @property {(e: EngineHandle) => MemoryReport} mem
 * @property {(e: EngineHandle) => void} pump
 * @property {(e: EngineHandle) => ClockMode} clockMode
 * @property {(e: EngineHandle, mode: ClockMode) => void} clockSetMode
 * @property {(e: EngineHandle) => bigint} clockNow
 * @property {(e: EngineHandle, ns: Int64) => void} clockSet
 * @property {(e: EngineHandle, ns: Int64) => void} clockAdvance
 * @property {(e: EngineHandle, utcNs: Int64) => void} wallClockSet
 * @property {(e: EngineHandle) => PlatformSignature} platformSignature
 * @property {(e: EngineHandle, name: CallbackName, fn: ((...args: never[]) => unknown) | null) => void} setCallback
 * @property {(e: EngineHandle, set: ((key: string, value: string | null, ttlNs: bigint) => void) | null,
 *     del: ((key: string, reason: CacheRemoval["reason"]) => void) | null) => void} setCacheCallbacks
 * @property {(e: EngineHandle, key: string, json: string, ttlNs: Int64) => void} cacheSeed
 * @property {(e: EngineHandle) => number} ruleMetaCount
 * @property {(e: EngineHandle, i: number) => RuleMeta} ruleMetaAt
 * @property {(e: EngineHandle) => number} lineSpanCount
 * @property {(e: EngineHandle, i: number) => LineSpan} lineSpanAt
 * @property {(e: EngineHandle, nodeId: number) => LineSpan} lineSpanFind
 * @property {(e: EngineHandle, factId: Int64) => Justifier[]} getJustifiers
 * @property {(e: EngineHandle, ruleFilter: string | null, includeOccupancy: boolean) => ReteNetwork} reteNetwork
 * @property {(e: EngineHandle, factId: Int64) => MatchStep[]} reteMatchTrace
 * @property {(e: EngineHandle, ruleFilter: string | null) => Refraction[]} refractedActivations
 * @property {(e: EngineHandle, capKeys: Int64, capBytes: Int64) => void} setCacheCap
 * @property {(e: EngineHandle) => SessionHeader} sessionHeader
 * @property {(e: EngineHandle) => string | null} runId
 * @property {(e: EngineHandle) => string | null} tierId
 * @property {(e: EngineHandle, sink: (bytes: Uint8Array) => void) => void} recordTo
 * @property {(e: EngineHandle) => void} stopRecording
 * @property {(e: EngineHandle, maxAtomBytes: number) => ReplayHandle} replayBegin
 * @property {(r: ReplayHandle, chunk: Uint8Array) => void} replayFeed
 * @property {(r: ReplayHandle) => ReplayCounts & { tailBytes: bigint }} replayFinish
 * @property {(bytes: Uint8Array, incremental: boolean) => AtomsRead} readAtoms
 * @property {(field: number) => string | null} messageName
 * @property {(e: EngineHandle, schema: string, body: Uint8Array) => Record<string, SlotValueOf<FactHandle>>}
 *     decodeFactBody
 * @property {(slots: AnnouncedSlot[], body: Uint8Array) => Record<string, SlotValueOf<FactHandle>>}
 *     decodeAnnouncedFactBody
 * @property {(slots: AnnouncedSlot[], body: Uint8Array) =>
 *     { slots: Record<string, SlotValueOf<FactHandle>>, refs: Record<string, bigint | null> }}
 *     decodeAnnouncedFactBodyHandles
 */

// ── this realm's libds ──────────────────────────────────────────────────────

/** @type {Glue | null} */
let glue = null;

/**
 * The host this realm opened with, for `recordTo`'s paths.
 * @type {Host | null}
 */
let realmHost = null;

/**
 * Which target this realm loaded, through which entry, and the API over it:
 * set by the first attach(), cleared again if its load fails.
 * @type {{ target: Target, entry: Entry, api: Promise<unknown> } | null}
 */
let realm = null;

/** @returns {Glue} */
function loadedGlue() {
    if (glue === null) throw new Error("@ds-lang/ds: libds is not loaded in this realm; open() it first");
    return glue;
}

/**
 * The API over this realm's libds, loading it (`load`) the first time.
 *
 * A second call for the same target through the same entry returns the
 * first's API, as the first opened it. Any other is refused: a realm holds one
 * glue, and Engine and Fact are its classes. A load that fails leaves the
 * realm free.
 *
 * @template {Host} H
 * @param {Entry} entry  the module opening libds: index.js is "node", browser.js "browser"
 * @param {Target} target
 * @param {() => Glue | Promise<Glue>} load
 * @param {H} host
 * @returns {Promise<Api<H>>}
 */
export function attach(entry, target, load, host) {
    if (realm !== null) {
        if (realm.target !== target || realm.entry !== entry)
            return Promise.reject(new Error(
                `@ds-lang/ds: this realm loaded libds as ${realm.target} through the ${realm.entry} entry, `
                + `and cannot also load ${target} through the ${entry} entry`));
        // One entry always builds the same kind of host, so the API is an Api<H>.
        return /** @type {Promise<Api<H>>} */ (realm.api);
    }
    const api = (async () => bind(await load(), target, host))();
    const mine = { target, entry, api };
    realm = mine;
    api.catch(() => { if (realm === mine) realm = null; });
    return api;
}

/**
 * @template {Host} H
 * @param {Glue} b
 * @param {Target} target
 * @param {H} host
 * @returns {Api<H>}
 */
function bind(b, target, host) {
    // The call callback reports a throw to the hook, and the engine carries
    // on. A handler's throw is not the hook's:
    // the Engine reports it (`#handler`), and libds hears that it failed.
    // See the glue's header.
    b.init(DsError, (error, where) => hook(error, where));
    glue = b;
    realmHost = host;
    const { compile, compileFile } = host;
    // fromSource gives an Engine exactly when the host's compiler returns
    // bytes and a Promise when it returns one, which is what FromSource says;
    // tsc cannot follow the conditional through the generic, so it is cast.
    const fromSourceHere = /** @type {FromSource<H["compile"]>} */ (/** @type {unknown} */ (
        (/** @type {string} */ source, /** @type {unknown} */ options) => fromSource(compile, source, options)));
    return Object.freeze({
        target,
        Engine,
        Fact,
        JsonText,
        EngineEvent,
        STREAM_EVENT_KINDS,
        DsError,
        CompileRefused,
        status,
        setUnraisableHook,
        compile,
        compileFile,
        fromSource: fromSourceHere,
        readAtoms,
        messageName,
        decodeAnnouncedFactBody,
        decodeAnnouncedFactBodyHandles,
    });
}

/** @type {UnraisableHook} */
function defaultUnraisableHook(error, where) {
    console.error(`@ds-lang/ds: exception ignored in the ${where} callback:`, error);
}

/** @type {UnraisableHook} */
let hook = defaultUnraisableHook;

/**
 * Replace where a throwing callback's exception is reported. null restores
 * the default, which prints to stderr. Returns the previous hook.
 * @param {UnraisableHook | null} fn
 * @returns {UnraisableHook}
 */
function setUnraisableHook(fn) {
    if (fn !== null && typeof fn !== "function")
        throw new TypeError("setUnraisableHook: want a function or null");
    const prev = hook;
    hook = fn ?? defaultUnraisableHook;
    return prev;
}

// ── facts ───────────────────────────────────────────────────────────────────

/** @type {(b: Glue, handle: FactHandle) => Fact} */
let makeFact;
/** @type {(fact: Fact) => FactHandle} */
let handleOf;

/**
 * A handle to one fact in one engine. Valid until the fact leaves working
 * memory (retracted, replaced by an upsert, or expired), after which `read`,
 * and passing it to the engine, throw DsError(DS_ERR_FACT_INVALID) instead of
 * reading freed memory. `id` and `alive` still answer.
 *
 * A Fact comes from its engine (`assert`, `factById`, a slot, an event) and is
 * never made directly.
 */
export class Fact {
    /** @type {Glue} */
    #b;
    /** @type {FactHandle} */
    #h;

    /**
     * @private
     * @param {Glue} b
     * @param {FactHandle} handle
     */
    constructor(b, handle) {
        this.#b = b;
        this.#h = handle;
    }

    static {
        makeFact = (b, handle) => new Fact(b, handle);
        handleOf = (fact) => fact.#h;
    }

    /** The engine's fact id: stable for the fact's life, never reused. */
    get id() { return this.#b.factId(this.#h); }

    /**
     * Whether the fact is still in working memory. After a replay that halted
     * the engine, nothing can say, and this stays true until `close`.
     */
    get alive() { return this.#b.factAlive(this.#h); }

    /**
     * The fact as it is now: `{ schema, id, slots }`.
     * @returns {FactRecord}
     */
    read() { return publicRecord(this.#b, this.#b.factRead(this.#h)); }
}

/**
 * A slot's value as the API gives it: a fact handle as a Fact, and bytes as a
 * plain Uint8Array (the glue returns a Buffer on Node, and the targets must
 * hand back the same type).
 * @param {Glue} b
 * @param {SlotValueOf<FactHandle>} v
 * @returns {SlotValue}
 */
function publicValue(b, v) {
    if (v instanceof Uint8Array) return plainBytes(v);
    if (v !== null && typeof v === "object") return makeFact(b, v);
    return v;
}

/**
 * @param {Glue} b
 * @param {Record<string, SlotValueOf<FactHandle>>} slots
 * @returns {Record<string, SlotValue>}
 */
function publicSlots(b, slots) {
    /** @type {Record<string, SlotValue>} */
    const out = {};
    for (const [k, v] of Object.entries(slots)) out[k] = publicValue(b, v);
    return out;
}

/**
 * @param {Glue} b
 * @param {FactRecordOf<FactHandle>} r
 * @returns {FactRecord}
 */
function publicRecord(b, r) {
    return { schema: r.schema, id: r.id, slots: publicSlots(b, r.slots) };
}

/**
 * Slot values that are facts go in as their handles; everything else as is.
 * @param {Record<string, SlotValue>} slots
 * @returns {Record<string, SlotValueOf<FactHandle>>}
 */
function glueSlots(slots) {
    if (slots === null || typeof slots !== "object" || Array.isArray(slots))
        throw new TypeError("slots: want an object of slot name -> value");
    /** @type {Record<string, SlotValueOf<FactHandle>>} */
    const out = {};
    for (const [k, v] of Object.entries(slots)) out[k] = v instanceof Fact ? handleOf(v) : v;
    return out;
}

/**
 * Bytes as a plain Uint8Array: the glue's are a Buffer on Node.
 * @param {Uint8Array} v
 * @returns {Uint8Array}
 */
function plainBytes(v) {
    return v.constructor === Uint8Array ? v : new Uint8Array(v);
}

/**
 * A call's arguments as the API gives them: a Json one, which the glue gives
 * as `{ json }`, as a JsonText, and bytes plain, a fact argument's included.
 * @param {Record<string, CallArgument | { json: string }>} args
 * @returns {Record<string, CallArgument>}
 */
function plainArgs(args) {
    /** @type {Record<string, CallArgument>} */
    const out = {};
    for (const [k, v] of Object.entries(args)) {
        if (v instanceof Uint8Array) out[k] = plainBytes(v);
        else if (v === null || typeof v !== "object" || v instanceof JsonText) out[k] = v;
        else if ("json" in v) out[k] = new JsonText(v.json);
        else out[k] = { ...v, external: plainBytes(v.external) };
    }
    return out;
}

/**
 * A stream event as the API gives it: its fact handles as Facts, its bytes
 * plain. A fact's handle stays good while the fact is in working memory: the
 * one a fact_retract carries is readable during that callback and dead once
 * it returns.
 * @param {Glue} b
 * @param {StreamEventOf<FactHandle>} ev
 * @returns {StreamEvent}
 */
function publicEvent(b, ev) {
    /** @type {Record<string, unknown>} */
    const out = { ...ev };
    if ("fact" in ev) out.fact = makeFact(b, ev.fact);
    if ("lhsFacts" in ev) out.lhsFacts = ev.lhsFacts.map((h) => makeFact(b, h));
    // A publish's slot values, copied in the callback ([NCBK.2.5]): a fact
    // reference among them is a Fact, as in a read.
    if ("slots" in ev) out.slots = publicSlots(b, ev.slots);
    if ("args" in ev) out.args = plainArgs(ev.args);
    if ("external" in ev) out.external = plainBytes(ev.external);
    // Every FactHandle the union carries is replaced above.
    return /** @type {StreamEvent} */ (/** @type {unknown} */ (out));
}

/**
 * An atom's field with every bytes value a plain Uint8Array, converted in
 * place: a message's fields, and a repeated field's items.
 * @param {AtomField} v
 * @returns {AtomField}
 */
function plainField(v) {
    if (v instanceof Uint8Array) return plainBytes(v);
    if (Array.isArray(v)) {
        // A repeated field's items are one kind, and each converts to that kind.
        const items = /** @type {AtomField[]} */ (v);
        for (let i = 0; i < items.length; i++) items[i] = plainField(items[i]);
        return v;
    }
    if (typeof v === "object") {
        // A message, or an enum, whose `name` may be null.
        const fields = /** @type {Record<string, AtomField | null>} */ (v);
        for (const [k, f] of Object.entries(fields)) if (f !== null) fields[k] = plainField(f);
    }
    return v;
}

/**
 * @param {unknown} fn
 * @param {string} what
 */
function wantCallback(fn, what) {
    if (fn != null && typeof fn !== "function")
        throw new TypeError(`${what}: want a function or null`);
}

/**
 * Report `error` as the platform reports an event listener's throw: thrown on
 * its own once the running call has returned, so it is the host's uncaught
 * exception. For a handler's failure that no call can throw.
 * @param {unknown} error
 */
function reportUncaught(error) {
    queueMicrotask(() => { throw error; });
}

// ── engines ─────────────────────────────────────────────────────────────────

/** @type {(b: Glue, h: EngineHandle) => Clock} */
let makeClock;

/**
 * An engine's clock, live: each read gives the engine's clock as it is then.
 * The monotonic clock is integer nanoseconds. A mock clock moves only when the
 * host moves it, through `set` and `advance`; a live one moves with the host.
 *
 * A Clock comes from its engine (`engine.clock`) and is never made directly.
 */
export class Clock {
    /** @type {Glue} */
    #b;
    /** @type {EngineHandle} */
    #h;

    /**
     * @private
     * @param {Glue} b
     * @param {EngineHandle} h
     */
    constructor(b, h) {
        this.#b = b;
        this.#h = h;
    }

    static {
        makeClock = (b, h) => new Clock(b, h);
    }

    /**
     * "live" or "mock".
     * @returns {ClockMode}
     */
    get mode() { return this.#b.clockMode(this.#h); }

    /**
     * Setting "mock" starts the monotonic clock at 0 and leaves the wall
     * clock unset until `setWall`. DsError(DS_ERR_STATE) once the engine has
     * sampled its clock, for an input or a pump.
     * @param {ClockMode} mode
     */
    set mode(mode) { this.#b.clockSetMode(this.#h, mode); }

    /**
     * The monotonic clock, ns. Reading it is not a sample: it records nothing.
     * @returns {bigint}
     */
    get now() { return this.#b.clockNow(this.#h); }

    /**
     * Set the mock monotonic clock; DsError(DS_ERR_STATE) in live mode, and
     * below its current value once the engine has sampled it. Not a sample:
     * the next input or pump observes it.
     * @param {Int64} ns
     */
    set(ns) { this.#b.clockSet(this.#h, ns); }

    /**
     * Advance the mock monotonic clock, and the mock wall clock by the same
     * amount when it is set.
     * @param {Int64} ns
     */
    advance(ns) { this.#b.clockAdvance(this.#h, ns); }

    /**
     * Set the mock wall clock, UTC ns since the Unix epoch: any instant,
     * earlier or later, as a host clock can be stepped. DsError(DS_ERR_STATE)
     * in live mode.
     * @param {Int64} utcNs
     */
    setWall(utcNs) { this.#b.wallClockSet(this.#h, utcNs); }
}

/** @type {(b: Glue, h: EngineHandle, register: (handlers: WriteThrough | null) => void) => Cache} */
let makeCache;

/**
 * An engine's cache, as the host reaches it: seeded before the first pump,
 * capped, and written through to the host's store. Rules read and write it;
 * the host does not read it.
 *
 * A Cache comes from its engine (`engine.cache`) and is never made directly.
 */
export class Cache {
    /** @type {Glue} */
    #b;
    /** @type {EngineHandle} */
    #h;
    /** @type {(handlers: WriteThrough | null) => void} */
    #register;
    /** @type {Readonly<WriteThrough> | null} */
    #writeThrough = null;

    /**
     * @private
     * @param {Glue} b
     * @param {EngineHandle} h
     * @param {(handlers: WriteThrough | null) => void} register
     */
    constructor(b, h, register) {
        this.#b = b;
        this.#h = h;
        this.#register = register;
    }

    static {
        makeCache = (b, h, register) => new Cache(b, h, register);
    }

    /**
     * Seed an entry before the first pump: `json` is its value as JSON text,
     * and `ttlNs` its TTL, 0 (the default) for none. A seed is not a write:
     * no action_cache_set event, and no write-through. DsError(DS_ERR_STATE)
     * after the first pump.
     * @param {string} key
     * @param {string} json
     * @param {{ ttlNs?: Int64 }} [options]
     */
    seed(key, json, { ttlNs = 0n } = {}) { this.#b.cacheSeed(this.#h, key, json, ttlNs); }

    /**
     * Cap the cache's keys and its bytes; each left out, or 0, is unbounded.
     * A write past either fails with DS_ERR_CONTRACT_BREACH and changes
     * nothing.
     * @param {{ keys?: Int64, bytes?: Int64 }} [caps]
     */
    setCap({ keys = 0n, bytes = 0n } = {}) { this.#b.setCacheCap(this.#h, keys, bytes); }

    /**
     * The write-through ([NCBK.7]), or null: `set` hears each write the rules
     * make, `delete` each entry that leaves, by a rule's `cache_delete` or its
     * TTL. Each is called with the object as `this`, as an event listener
     * object's `handleEvent` is. A handler that throws has failed the write:
     * the pump that ran it throws DsError(DS_ERR_ACTION_FAILED) with the
     * handler's exception as its `cause`, and the cache keeps the change. The
     * value read back is a frozen copy of the handlers as they were set.
     * @returns {Readonly<WriteThrough> | null}
     */
    get writeThrough() { return this.#writeThrough; }

    /** @param {WriteThrough | null} handlers */
    set writeThrough(handlers) {
        if (handlers !== null && typeof handlers !== "object")
            throw new TypeError("writeThrough: want { set, delete } or null");
        this.#register(handlers);
        this.#writeThrough = handlers === null ? null
            : Object.freeze({ set: handlers.set ?? null, delete: handlers.delete ?? null });
    }
}

/**
 * A read-only map by name, as the platform's `readonly maplike` is: `get`,
 * `has`, `size`, iteration, and nothing that changes it. Built once from a
 * snapshot, its values frozen, so every reader sees the same entries.
 * @template V
 * @implements {ReadonlyMap<string, V>}
 */
class NameMap {
    /** @type {Map<string, V>} */
    #map;

    /** @param {Iterable<[string, V]>} entries */
    constructor(entries) { this.#map = new Map(entries); }

    get size() { return this.#map.size; }

    /** @param {string} name */
    get(name) { return this.#map.get(name); }

    /** @param {string} name */
    has(name) { return this.#map.has(name); }

    keys() { return this.#map.keys(); }

    values() { return this.#map.values(); }

    entries() { return this.#map.entries(); }

    /**
     * @param {(value: V, key: string, map: ReadonlyMap<string, V>) => void} fn
     * @param {unknown} [thisArg]
     */
    forEach(fn, thisArg) {
        for (const [k, v] of this.#map) fn.call(thisArg, v, k, this);
    }

    [Symbol.iterator]() { return this.#map[Symbol.iterator](); }
}

/**
 * `v`, and every object and array it holds, frozen.
 * @template T
 * @param {T} v
 * @returns {T}
 */
function deepFrozen(v) {
    if (v !== null && typeof v === "object" && !Object.isFrozen(v)) {
        for (const x of Object.values(v)) deepFrozen(x);
        Object.freeze(v);
    }
    return v;
}

/**
 * Set by clone() for the one construction that adopts the handle it made,
 * since the constructor takes no handle.
 * @type {EngineHandle | null}
 */
let adopting = null;

/**
 * One libds engine, on this realm's libds. `close()` frees it, as `using`
 * does where the platform has `Symbol.dispose`.
 *
 * An EventTarget (TAG §7.4): its stream is an event per stream event, of the
 * event's kind, and its log and metric records are "log" and "metric" events.
 * A listener that throws is reported as the platform reports any listener's
 * throw, the listeners after it still run, and the engine carries on.
 */
export class Engine extends EventTarget {
    /** @type {Glue} */
    #b;
    /** @type {EngineHandle} */
    #h;
    /**
     * The functions the glue calls. It holds them weakly (a strong hold would
     * be a GC root, and a callback closing over its own Engine would keep the
     * engine alive forever), so the Engine holds them here.
     * @type {Map<string, unknown>}
     */
    #cbs = new Map();
    /** @type {{ sink: (bytes: Uint8Array) => void, file: FileSink | null } | null} */
    #rec = null;
    /** @type {Clock} */
    #clock;
    /** @type {Cache} */
    #cache;
    /**
     * The handlers' failures during the running pump or loadDsc, for the
     * DsError it throws; null outside one.
     * @type {unknown[] | null}
     */
    #failures = null;
    /**
     * The snapshots `schemas`, `rules` and `lineSpans` give, made at the
     * first read after a change. Only loadDsc and replayStream change
     * them, and each clears them, as close does.
     * @type {NameMap<SchemaInfo> | null}
     */
    #schemas = null;
    /** @type {NameMap<RuleMeta> | null} */
    #rules = null;
    /** @type {readonly LineSpan[] | null} */
    #lineSpans = null;
    /**
     * The handler properties' functions, and the listener each was added as.
     * @type {Map<string, { handler: Function, listener: (event: Event) => void }>}
     */
    #handlers = new Map();

    /**
     * An empty engine. Throws until this realm has opened libds.
     *
     * `runId` and `tierId` are the engine's identity, the integrator's to give
     * ([NLFC.1.2]): the stream header records them, and each `event_id` derives
     * from them. Absent, null or `""`, the engine has none.
     * @param {{ runId?: string | null, tierId?: string | null }} [options]
     */
    constructor(options = {}) {
        super();
        const b = loadedGlue();
        this.#b = b;
        this.#h = adopting ?? b.newEngine(options.runId ?? null, options.tierId ?? null);
        adopting = null;
        this.#clock = makeClock(b, this.#h);
        this.#cache = makeCache(b, this.#h, (handlers) => this.#setWriteThrough(handlers));
    }

    /**
     * An independent copy of this engine ([NLFC.8]): facts, working memory,
     * series, cache, clock and counters, sharing nothing. It starts with NO
     * listeners or callbacks: add them to the clone before pumping it ([NLFC.8.3]).
     * Refused mid-pump, inside a callback, and in real-time mode. Facts of this
     * engine are not facts of the clone.
     * @returns {Engine}
     */
    clone() {
        adopting = this.#b.clone(this.#h);
        return new Engine();
    }

    /**
     * Record this engine's fact stream through the C recorder, as the
     * canonical RFCS stream. `target` is a path (each atom is written as it is
     * framed, so the file can be read while the recording runs) or a function
     * that receives each atom as a Uint8Array. The recorder is chained beside
     * the engine's stream events, which keep coming. One recording at a
     * time.
     *
     * The stream's header and its schema announcements are written at the
     * engine's first stream event, or by `recordTo` itself if the engine has
     * already had one ([RFCS.5.1]). A sink that throws while `recordTo` writes
     * them makes `recordTo` throw; one that throws later stops the recording,
     * and `stopRecording` throws, with the sink's error as its `cause`.
     * @param {string | ((bytes: Uint8Array) => void)} target
     */
    recordTo(target) {
        if (this.#rec) throw new DsError(status.DS_ERR_STATE, "recordTo: already recording; stopRecording first");
        /** @type {FileSink | null} */
        let file = null;
        /** @type {(bytes: Uint8Array) => void} */
        let sink;
        if (typeof target === "function") {
            sink = target;
        } else if (typeof target === "string") {
            const open = realmHost?.file ?? null;
            if (open === null)
                throw new TypeError("recordTo: a path needs a file system, which this host has none of; "
                                    + "give a sink function");
            // A closed engine refuses here, ahead of the open, which truncates.
            this.#b.halted(this.#h);
            const f = open(target);
            file = f;
            sink = (bytes) => { f.write(bytes); };
        } else {
            throw new TypeError("recordTo: want a path or a sink function");
        }
        // The glue holds the sink weakly, as it holds callbacks.
        this.#rec = { sink, file };
        try {
            this.#b.recordTo(this.#h, sink);
        } catch (err) {
            this.#rec = null;
            file?.close();
            throw err;
        }
    }

    /**
     * Stop recording and report: the recorder's first error, if it had one, is
     * thrown as a DsError (a sink's own throw as its `cause`). Idempotent.
     */
    stopRecording() {
        const rec = this.#rec;
        this.#rec = null;
        try {
            this.#b.stopRecording(this.#h);
        } finally {
            rec?.file?.close();
        }
    }

    /**
     * Replay an RFCS stream through the C replayer: a Uint8Array, or an
     * iterable of Uint8Array chunks with any boundaries. Inputs are delivered,
     * the rules re-fire, and every re-derived compare atom is checked against
     * the record ([LFST.9.6]); there is no apply-only form. Listeners and a
     * running recording hear no event of the replay, and hear events again
     * once it ends, however it ends, unless it halted the engine, which emits
     * none after that. While `source` is being iterated, a
     * `Fact`'s `read()` and passing a `Fact` to the engine throw
     * `DS_ERR_STATE`.
     * @param {Uint8Array | Iterable<Uint8Array>} source
     * @param {{ maxAtomBytes?: number }} [options]
     * @returns {ReplayCounts}
     */
    replayStream(source, { maxAtomBytes = 0 } = {}) {
        const chunks = source instanceof Uint8Array ? [source] : source;
        if (chunks == null || typeof chunks[Symbol.iterator] !== "function")
            throw new TypeError("replayStream: want a Uint8Array or an iterable of them");
        // A stream can announce schemas, so the snapshots are made again.
        this.#forgetProgram();
        const r = this.#b.replayBegin(this.#h, maxAtomBytes);
        try {
            for (const chunk of chunks) this.#b.replayFeed(r, chunk);
        } catch (err) {
            try { this.#b.replayFinish(r); } catch { /* the feed's error is the one to report */ }
            this.#forgetProgram();
            throw err;
        }
        /** @type {ReplayCounts & { tailBytes: bigint }} */
        let finished;
        try {
            finished = this.#b.replayFinish(r);
        } finally {
            this.#forgetProgram();
        }
        const { tailBytes, ...counts } = finished;
        // replayStream is handed the whole stream, so a partial trailing atom
        // is a truncated stream, refused as ds_rfcs_replay refuses one. (The
        // chunked C reader reports it and lets the caller say.)
        if (tailBytes > 0n)
            throw new DsError(status.DS_ERR_PARSE, `the stream ends inside an atom (${tailBytes} bytes of it)`);
        return counts;
    }

    /**
     * A FactAssert or FactEmit atom's `fact` bytes, typed by this engine's
     * schema `schema` (`ds_rfcs_decode_fact_body`): the slots as a fact's
     * `read()` gives them.
     * @param {string} schema
     * @param {Uint8Array} body
     * @returns {Record<string, SlotValue>}
     */
    decodeFactBody(schema, body) {
        return publicSlots(this.#b, this.#b.decodeFactBody(this.#h, schema, body));
    }

    /**
     * The session's header (LFST.4): a snapshot, made at each read.
     * @returns {SessionHeader}
     */
    get sessionHeader() {
        const h = this.#b.sessionHeader(this.#h);
        return { ...h, dscHash: h.dscHash === null ? null : plainBytes(h.dscHash) };
    }

    /**
     * The run id this engine was given, or null.
     * @returns {string | null}
     */
    get runId() {
        return this.#b.runId(this.#h);
    }

    /**
     * The tier id this engine was given, or null.
     * @returns {string | null}
     */
    get tierId() {
        return this.#b.tierId(this.#h);
    }

    /**
     * Release the engine now. Idempotent. A later call on it throws
     * DsError(DS_ERR_STATE), and passing or reading one of its Facts
     * DsError(DS_ERR_FACT_INVALID). Reading `clock`, `cache` or `writeThrough`
     * does not throw.
     */
    close() {
        this.#b.close(this.#h);     // detaches the recorder, unchecked
        this.#cbs.clear();
        this.#forgetProgram();      // a closed engine's `schemas` throws, as its other reads do
        this.#rec?.file?.close();
        this.#rec = null;
    }

    /** `close`, for `using`, where the platform has `Symbol.dispose`. */
    [Symbol.dispose]() { this.close(); }

    /**
     * @param {CallbackName} name
     * @param {unknown} fn  what the caller passed, checked here
     * @param {((...args: never[]) => unknown) | null} f  what the glue calls
     */
    #setCallback(name, fn, f) {
        wantCallback(fn, name);
        this.#b.setCallback(this.#h, name, f);
        this.#cbs.set(name, f);
    }

    /**
     * @template {keyof EngineEventMap} K
     * @overload
     * @param {K} type
     * @param {((event: EngineEventMap[K]) => void) | null} listener
     * @param {boolean | AddEventListenerOptions} [options]
     * @returns {void}
     */
    /**
     * @overload
     * @param {string} type
     * @param {EventListenerOrEventListenerObject | null} listener
     * @param {boolean | AddEventListenerOptions} [options]
     * @returns {void}
     */
    /**
     * Listen for an event, as EventTarget does: a stream kind
     * (STREAM_EVENT_KINDS), "log" or "metric". The first listener for the
     * stream, for the log or for metrics has libds deliver them from then on,
     * so an engine nobody listens to pays nothing for them.
     * @param {string} type
     * @param {EventListenerOrEventListenerObject | null} listener
     * @param {boolean | AddEventListenerOptions} [options]
     */
    addEventListener(type, listener, options) {
        // libds first, so an engine that refuses (a closed one) adds nothing.
        if (listener != null) this.#deliver(type);
        super.addEventListener(type, listener, options);
    }

    /**
     * @template {keyof EngineEventMap} K
     * @overload
     * @param {K} type
     * @param {((event: EngineEventMap[K]) => void) | null} listener
     * @param {boolean | EventListenerOptions} [options]
     * @returns {void}
     */
    /**
     * @overload
     * @param {string} type
     * @param {EventListenerOrEventListenerObject | null} listener
     * @param {boolean | EventListenerOptions} [options]
     * @returns {void}
     */
    /**
     * Stop listening, as EventTarget does.
     * @param {string} type
     * @param {EventListenerOrEventListenerObject | null} listener
     * @param {boolean | EventListenerOptions} [options]
     */
    removeEventListener(type, listener, options) {
        super.removeEventListener(type, listener, options);
    }

    /**
     * Have libds deliver what a listener of `type` hears. Once on, it stays on
     * until close: a listener a `once` or an AbortSignal removes tells no one,
     * so the listeners left cannot be counted.
     * @param {string} type
     */
    #deliver(type) {
        const b = this.#b;
        if (Object.hasOwn(KINDS, type)) {
            if (this.#cbs.has("stream")) return;
            const f = (/** @type {StreamEventOf<FactHandle>} */ ev) => {
                const { kind, ...fields } = publicEvent(b, ev);
                this.dispatchEvent(new EngineEvent(kind, fields));
            };
            b.setCallback(this.#h, "stream", f);
            this.#cbs.set("stream", f);
        } else if ((type === "log" || type === "metric") && !this.#cbs.has(type)) {
            const f = (/** @type {LogRecord | Metric} */ r) => { this.dispatchEvent(new EngineEvent(type, r)); };
            b.setCallback(this.#h, type, f);
            this.#cbs.set(type, f);
        }
    }

    /**
     * A handler property's setter: the listener it added goes, and `fn`, if
     * it is a function, is added in its place. Anything else clears it, as
     * the platform's handler properties do.
     * @param {"log" | "metric"} type
     * @param {unknown} fn
     */
    #setHandler(type, fn) {
        const old = this.#handlers.get(type);
        if (old !== undefined) super.removeEventListener(type, old.listener);
        this.#handlers.delete(type);
        if (typeof fn !== "function") return;
        const listener = (/** @type {Event} */ event) => { fn.call(this, event); };
        this.#handlers.set(type, { handler: fn, listener });
        this.addEventListener(type, listener);
    }

    /**
     * The "log" events' handler (TAG §7.5), or null: the log records libds
     * reports, as a listener added for "log" hears them.
     * @returns {((event: LogEngineEvent) => void) | null}
     */
    get onlog() {
        const fn = this.#handlers.get("log")?.handler ?? null;
        return /** @type {((event: LogEngineEvent) => void) | null} */ (fn);
    }

    /** @param {((event: LogEngineEvent) => void) | null} fn */
    set onlog(fn) { this.#setHandler("log", fn); }

    /**
     * The "metric" events' handler, or null.
     * @returns {((event: MetricEngineEvent) => void) | null}
     */
    get onmetric() {
        const fn = this.#handlers.get("metric")?.handler ?? null;
        return /** @type {((event: MetricEngineEvent) => void) | null} */ (fn);
    }

    /** @param {((event: MetricEngineEvent) => void) | null} fn */
    set onmetric(fn) { this.#setHandler("metric", fn); }

    /**
     * A rule's `call`. The reply is a fact of the service's response schema,
     * asserted after the pump.
     * @param {((request: CallRequest) => void) | null} fn
     */
    setCallCallback(fn) {
        this.#setCallback("call", fn, fn == null ? null
            : (/** @type {CallRequest} */ req) => fn({ ...req, args: plainArgs(req.args) }));
    }

    /**
     * A handler of the host's, for the glue: its throw is kept for the
     * DsError the running pump or loadDsc throws, or, where no call can throw
     * it (`uncaught`, or none running), reported as uncaught. Either way it is
     * thrown on, so libds hears that the handler failed, and the glue
     * reports it nowhere else.
     * @template {unknown[]} A
     * @param {(...args: A) => void} fn
     * @param {boolean} [uncaught]
     * @returns {(...args: A) => void}
     */
    #duty(fn, uncaught = false) {
        return (...args) => {
            try {
                fn(...args);
            } catch (err) {
                if (uncaught || this.#failures === null) reportUncaught(err);
                else this.#failures.push(err);
                throw err;
            }
        };
    }

    // NO sampleSink AND NO seriesProvisioner: there is no samples plane, and
    // NSTG.5 is deferred.

    /**
     * The engine's cache: the same Cache at every read.
     * @returns {Cache}
     */
    get cache() { return this.#cache; }

    /**
     * Cache's `writeThrough` setter: each handler called with the object as
     * `this`, and one record argument. libds registers the pair as one.
     * @param {WriteThrough | null} handlers
     */
    #setWriteThrough(handlers) {
        const set = handlers?.set ?? null, del = handlers?.delete ?? null;
        wantCallback(set, "writeThrough.set");
        wantCallback(del, "writeThrough.delete");
        const s = set === null ? null : this.#duty(
            (/** @type {string} */ key, /** @type {string | null} */ value, /** @type {bigint} */ ttlNs) => {
                set.call(handlers, { key, value, ttlNs });
            });
        const d = del === null ? null : this.#duty(
            (/** @type {string} */ key, /** @type {CacheRemoval["reason"]} */ reason) => {
                del.call(handlers, { key, reason });
            });
        this.#b.setCacheCallbacks(this.#h, s, d);
        this.#cbs.set("cacheSet", s);
        this.#cbs.set("cacheDelete", d);
    }

    /**
     * Run `op`, a libds call that may run the host's handlers. The DsError it
     * throws carries the first handler's failure as its `cause`; any other
     * failure, which no call is left to throw, is reported as uncaught.
     * @template T
     * @param {() => T} op
     * @returns {T}
     */
    #withHandlers(op) {
        const outer = this.#failures;
        /** @type {unknown[]} */
        const failures = [];
        this.#failures = failures;
        try {
            return op();
        } catch (err) {
            if (!(err instanceof DsError) || failures.length === 0) throw err;
            throw new DsError(err.status, err.detail, { cause: failures.shift() });
        } finally {
            this.#failures = outer;
            for (const f of failures) reportUncaught(f);
        }
    }

    /**
     * Load a compiled `.dsc`. A load that fails once it has begun reading
     * spends the engine ([RDSC.9.8]): `halted` is 0, no engine error, and
     * every later call but `halted`, the platform signature, the session
     * header and close throws DS_ERR_ENGINE_HALTED.
     * @param {Uint8Array} bytes
     */
    loadDsc(bytes) {
        try {
            this.#withHandlers(() => this.#b.loadDsc(this.#h, bytes));
        } finally {
            this.#forgetProgram();
        }
    }

    /**
     * The engine's schemas by name, its internal ones included: a snapshot
     * of the program as loaded, the same map at every read until loadDsc
     * or replayStream changes the schemas. Its schemas are frozen.
     * @returns {ReadonlyMap<string, SchemaInfo>}
     */
    get schemas() {
        if (this.#schemas === null) {
            const b = this.#b, h = this.#h, n = b.schemaCount(h);
            /** @type {Array<[string, SchemaInfo]>} */
            const all = [];
            for (let i = 0; i < n; i++) {
                const s = deepFrozen(b.schemaAt(h, i));
                all.push([s.name, s]);
            }
            this.#schemas = new NameMap(all);
        }
        return this.#schemas;
    }

    /**
     * The program's rules' metadata by rule name: a snapshot, as `schemas`
     * is, made again after loadDsc or replayStream. Its entries are frozen.
     * @returns {ReadonlyMap<string, RuleMeta>}
     */
    get rules() {
        if (this.#rules === null) {
            const b = this.#b, h = this.#h, n = b.ruleMetaCount(h);
            /** @type {Array<[string, RuleMeta]>} */
            const all = [];
            for (let i = 0; i < n; i++) {
                const m = deepFrozen(b.ruleMetaAt(h, i));
                all.push([m.ruleName, m]);
            }
            this.#rules = new NameMap(all);
        }
        return this.#rules;
    }

    /**
     * Where each attributed node comes from ([NDBG.3.1]): the program's line
     * spans, in the artefact's order, a frozen snapshot as `rules` is. A node
     * id is unique in a program, so a node has at most one span; an alpha has
     * none ([RDSC.14.3.6]). Empty before a load.
     * @returns {readonly LineSpan[]}
     */
    get lineSpans() {
        if (this.#lineSpans === null) {
            const b = this.#b, h = this.#h, n = b.lineSpanCount(h);
            /** @type {LineSpan[]} */
            const all = [];
            for (let i = 0; i < n; i++) all.push(deepFrozen(b.lineSpanAt(h, i)));
            this.#lineSpans = Object.freeze(all);
        }
        return this.#lineSpans;
    }

    /**
     * The line span of the node `nodeId`, as `reteNetwork()` and a fault
     * event name it ([NDBG.3.2]). A node with no span, an alpha among them,
     * throws a DsError with DS_ERR_NOT_FOUND ([NDBG.7.1]).
     * @param {number} nodeId
     * @returns {LineSpan}
     */
    lineSpan(nodeId) {
        if (!Number.isInteger(nodeId) || nodeId < 0 || nodeId > 0xFFFF_FFFF)
            throw new TypeError(`lineSpan: want a node id, a uint32, not ${nodeId}`);
        return deepFrozen(this.#b.lineSpanFind(this.#h, nodeId));
    }

    /** The schemas, rules and spans have changed, or may have: read them again. */
    #forgetProgram() {
        this.#schemas = null;
        this.#rules = null;
        this.#lineSpans = null;
    }

    /**
     * Assert a fact: slots by name. An omitted nullable slot is null. Its
     * TTL is its schema's: there is no per-fact TTL.
     * @param {string} schema
     * @param {Record<string, SlotValue>} slots
     * @returns {Fact}
     */
    assert(schema, slots) {
        const b = this.#b;
        return makeFact(b, b.assert(this.#h, schema, glueSlots(slots)));
    }

    /**
     * Assert a fact another engine handed out, from its FactExternal bytes
     * (NCBK.10.4): a fact argument's `external`, or an `action_publish`
     * event's. Takes the bytes, or the FactArgument itself. Its references
     * resolve against this engine's working memory, and a refusal throws a
     * DsError with nothing asserted: DS_ERR_PARSE, DS_ERR_SCHEMA_UNKNOWN,
     * DS_ERR_SCHEMA_HASH_MISMATCH or DS_ERR_FACT_REF_CONFLICT. libds returns
     * no fact, so neither does this: what it asserted is in the stream.
     * @param {Uint8Array | FactArgument} data
     */
    assertExternal(data) {
        const bytes = data instanceof Uint8Array ? data : data?.external;
        if (!(bytes instanceof Uint8Array))
            throw new TypeError("assertExternal: want a Uint8Array or a fact argument");
        this.#b.assertExternal(this.#h, bytes);
    }

    /**
     * Apply one recorded ExternalAssert as libds's replayer does ([RFCS.24.2],
     * `ds_rfcs_apply_external_assert`): `body` is the atom's body as framed in
     * the stream (`readAtoms` gives where). One input: its fact delivered as a
     * received FactExternal is, the recorded `ttl_ns` on the received fact,
     * and no pump. `factIds[i]` is this engine's id for the recorded
     * `recordedIds[i]`, in [RFCS.24.3]'s order, which is how a later
     * FactRetract's recorded id finds its fact. Throws a DsError:
     * DS_ERR_FS_DIVERGENCE when the delivery refuses or asserts a different
     * number of facts than the record lists, DS_ERR_PARSE for a malformed body,
     * DS_ERR_STATE or DS_ERR_ENGINE_HALTED for an engine that cannot take an
     * input now.
     * @param {Uint8Array} body
     * @returns {ExternalAssertApplied}
     */
    applyExternalAssert(body) {
        if (!(body instanceof Uint8Array))
            throw new TypeError("applyExternalAssert: want the atom's body, a Uint8Array");
        return this.#b.applyExternalAssert(this.#h, body);
    }

    /**
     * Retract a fact: a Fact, or a fact id, as the introspection calls take
     * either. A Fact that has left working memory is refused with
     * DS_ERR_FACT_INVALID, and an id no live fact has with DS_ERR_NOT_FOUND.
     * An id is found by walking working memory, O(live facts).
     * @param {Fact | Int64} fact
     */
    retract(fact) {
        const b = this.#b;
        if (fact instanceof Fact) {
            b.retract(this.#h, handleOf(fact));
            return;
        }
        const h = b.factById(this.#h, fact);
        if (h === null) throw new DsError(status.DS_ERR_NOT_FOUND, `retract: no live fact has id ${fact}`);
        b.retract(this.#h, h);
    }

    /**
     * Every live fact, or `schema`'s, as Facts: a snapshot, unordered. Sort by
     * `id` if order matters.
     * @param {{ schema?: string | null }} [options]
     * @returns {Fact[]}
     */
    facts({ schema = null } = {}) {
        const b = this.#b;
        return b.facts(this.#h, schema).map((h) => makeFact(b, h));
    }

    /**
     * How many facts are in working memory.
     * @returns {number}
     */
    get factCount() { return this.#b.factCount(this.#h); }

    /**
     * null while the engine runs. Once an engine error has halted it, every
     * call but this, the platform signature and the session header throws
     * DS_ERR_ENGINE_HALTED, reads of its state
     * included ([NCBK.2.9]), and this is the fault that did
     * it: the EngineFault number, as the engine_error event's `engineFault`
     * ([NCBK.2.11]). Still answers on a halted engine, so the cause is readable
     * without a stream listener. An engine a failed load spent ([RDSC.9.8])
     * reads 0, UNSPECIFIED: no engine error was raised. Test it against null.
     */
    get halted() { return this.#b.halted(this.#h); }

    /**
     * The live fact with this engine-local id, or null. A clone's facts have
     * handles of their own: this is how a fact asserted before a clone is
     * retracted in it. Walks working memory, O(live facts).
     * @param {Int64} id
     * @returns {Fact | null}
     */
    factById(id) {
        const h = this.#b.factById(this.#h, id);
        return h === null ? null : makeFact(this.#b, h);
    }

    /**
     * The Rete structures' bytes. A method, not a property: it walks the
     * engine's structures to answer.
     * @returns {MemoryReport}
     */
    memory() { return this.#b.mem(this.#h); }

    /**
     * Run the agenda to exhaustion. Rules fire only here. A handler of the
     * cache's write-through that throws fails it: the DsError carries the
     * handler's exception as its `cause`.
     */
    pump() { this.#withHandlers(() => this.#b.pump(this.#h)); }

    /**
     * The engine's clock: the same Clock at every read, and live.
     * @returns {Clock}
     */
    get clock() { return this.#clock; }

    /**
     * The platform signature ([LDET.2.3]): a snapshot, made at each read.
     * @returns {PlatformSignature}
     */
    get platformSignature() { return this.#b.platformSignature(this.#h); }

    // NO seriesValue: no public function reads a series ([NSBK.6.3]).
    // A series' values reach the host through what rules do with them.

    // NO registerSchema: a schema reaches the engine from a compiled
    // artefact and in no other way ([NFCT.1.1]), through loadDsc.

    /**
     * The activations that logically support a fact; empty for a fact nothing
     * derived.
     * @param {Fact | Int64} fact  a Fact, or a fact id
     * @returns {Justifier[]}
     */
    justifiers(fact) { return this.#b.getJustifiers(this.#h, factId(fact)); }

    /**
     * The Rete network, optionally only what one rule reaches.
     * @param {{ ruleFilter?: string | null, includeOccupancy?: boolean }} [options]
     * @returns {ReteNetwork}
     */
    reteNetwork({ ruleFilter = null, includeOccupancy = false } = {}) {
        return this.#b.reteNetwork(this.#h, ruleFilter, includeOccupancy);
    }

    /**
     * A fact's path through the alpha network.
     * @param {Fact | Int64} fact  a Fact, or a fact id
     * @returns {MatchStep[]}
     */
    reteMatchTrace(fact) { return this.#b.reteMatchTrace(this.#h, factId(fact)); }

    /**
     * Activations refraction blocked this cycle.
     * @param {string | null} [ruleFilter]
     * @returns {Refraction[]}
     */
    refractedActivations(ruleFilter = null) { return this.#b.refractedActivations(this.#h, ruleFilter); }
}

// A platform with no `Symbol.dispose` named that method "undefined".
if (typeof Symbol.dispose !== "symbol") Reflect.deleteProperty(Engine.prototype, "undefined");

/**
 * A Fact, or a fact id: the introspection calls take either.
 * @param {Fact | Int64} fact
 * @returns {Int64}
 */
function factId(fact) { return fact instanceof Fact ? fact.id : fact; }

// ── reading streams, and compiling ──────────────────────────────────────────

/**
 * Every atom of a trace or a .dsc, read by libds (no codec here).
 *
 * A fact's typed slots are the `fact` bytes: `engine.decodeFactBody` types
 * them by a program's schema, and `decodeAnnouncedFactBody` by the stream's
 * own `Slot` atoms. `incremental` reads a stream that may still be growing: a partial
 * trailing atom stops the read with `incomplete` true and `end` where it
 * starts ([RFCS.19.2]). Otherwise it is an error, and the atoms before it are
 * still returned.
 * @param {Uint8Array} bytes
 * @param {{ incremental?: boolean }} [options]
 * @returns {AtomsRead}
 */
function readAtoms(bytes, { incremental = false } = {}) {
    const r = loadedGlue().readAtoms(bytes, incremental);
    for (const a of r.atoms) if (a.body !== null) plainField(a.body);
    return r;
}

/**
 * The proto message an atom's body is ("FactAssert" for FactAssert's field
 * number), or null for a field number this build has no entry for.
 * @param {number} field  an integer in 0..2^32-1
 * @returns {string | null}
 */
function messageName(field) {
    if (typeof field !== "number" || !Number.isInteger(field))
        throw new TypeError("messageName: want an atom's field number, an integer");
    if (field < 0 || field > 0xffffffff)
        throw new RangeError(`messageName: field number ${field} is outside 0..2^32-1`);
    return loadedGlue().messageName(field);
}

/**
 * A FactAssert or FactEmit atom's `fact` bytes, typed by the stream's own
 * announcement of the schema, its `Slot` atoms in order
 * (`ds_rfcs_decode_announced_fact_body`, [RFCS.5.1]): what a reader holding
 * no program types a body by. The values are those `engine.decodeFactBody`
 * gives by the program's schema. A fact-ref slot is refused (DS_ERR_INVAL):
 * its handle names a fact only within its stream ([RFCS.4]);
 * `decodeAnnouncedFactBodyHandles` gives it as recorded.
 * @param {AnnouncedSlot[]} slots  `kind` is `Slot.kind`'s number
 * @param {Uint8Array} body
 * @returns {Record<string, SlotValue>}
 */
function decodeAnnouncedFactBody(slots, body) {
    checkAnnounced("decodeAnnouncedFactBody", slots, body);
    const b = loadedGlue();
    return publicSlots(b, b.decodeAnnouncedFactBody(slots, body));
}

/**
 * `decodeAnnouncedFactBody`, with each fact-ref slot as the stream recorded
 * it (`ds_rfcs_decode_announced_fact_body_handles`): `slots` holds
 * every other slot, as that call gives it, and `refs` each fact-ref slot,
 * its recorded handle, or null where a nullable one is absent. [RFCS.6.3]:
 * the handle is the `fact_id` of the earlier record in the same stream that
 * carried the referenced fact; it names nothing outside that stream.
 * @param {AnnouncedSlot[]} slots  `kind` is `Slot.kind`'s number
 * @param {Uint8Array} body
 * @returns {AnnouncedBody}
 */
function decodeAnnouncedFactBodyHandles(slots, body) {
    checkAnnounced("decodeAnnouncedFactBodyHandles", slots, body);
    const b = loadedGlue();
    const got = b.decodeAnnouncedFactBodyHandles(slots, body);
    return { slots: publicSlots(b, got.slots), refs: got.refs };
}

/**
 * What both announced decodes take, refused before libds with a TypeError
 * naming `fn` where it is not that.
 * @param {string} fn
 * @param {unknown} slots
 * @param {unknown} body
 */
function checkAnnounced(fn, slots, body) {
    if (!Array.isArray(slots))
        throw new TypeError(`${fn}: want an array of announced slots`);
    for (const s of slots) {
        if (s === null || typeof s !== "object" || typeof s.name !== "string")
            throw new TypeError(`${fn}: each slot wants a name, a string`);
        if (typeof s.kind !== "number" || !Number.isInteger(s.kind) || s.kind < 0 || s.kind > 0xffffffff)
            throw new TypeError(`${fn}: slot ${s.name}'s kind is not a SlotKind number`);
        if (typeof s.nullable !== "boolean")
            throw new TypeError(`${fn}: slot ${s.name}'s nullable is not a boolean`);
    }
    if (!(body instanceof Uint8Array))
        throw new TypeError(`${fn}: want a Uint8Array body`);
}

/**
 * Compile, then a fresh Engine with it loaded; a Promise of one where
 * compiling is async.
 * @param {Host["compile"]} compile
 * @param {string} source
 * @param {unknown} options  the compiler's, passed on as given
 * @returns {Engine | Promise<Engine>}
 */
function fromSource(compile, source, options) {
    /** @param {Uint8Array} dsc */
    const load = (dsc) => {
        const e = new Engine();
        try {
            e.loadDsc(dsc);
        } catch (err) {
            e.close();
            throw err;
        }
        return e;
    };
    const dsc = compile(source, /** @type {never} */ (options));
    return dsc instanceof Uint8Array ? load(dsc) : dsc.then(load);
}
