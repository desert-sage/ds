// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
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
export function attach<H extends Host>(entry: Entry, target: Target, load: () => Glue | Promise<Glue>, host: H): Promise<Api<H>>;
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
    constructor(statusCode: number, detail?: string, options?: ErrorOptions);
    /** libds's status number: compare it against `status.DS_ERR_*`. */
    status: number;
    /** libds's text, for logs. */
    detail: string;
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
    constructor(file: string, diagnostics: string);
    file: string;
    diagnostics: string;
}
/**
 * A call argument of kind `Json`: libds's canonical JSON text. A `String`
 * argument is a plain string, so `instanceof JsonText` tells the two apart.
 *
 * `text` is the document as libds wrote it. `JSON.parse` reads it where every
 * integer in it fits a Number; one past 2^53 comes back rounded.
 */
export class JsonText {
    /** @param {string} text  canonical JSON text, as libds writes it */
    constructor(text: string);
    /** The document, as libds wrote it. */
    get text(): string;
    /**
     * The document, so `String()` and a template literal give its text.
     * @returns {string}
     */
    toString(): string;
    #private;
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
    constructor(type: string, fields?: object);
}
/**
 * Every stream event kind: the `type` of each event an Engine dispatches for
 * its stream. A listener for the whole stream is added once per kind, and
 * hears every event in `seq` order.
 * @type {readonly StreamEventKind[]}
 */
export const STREAM_EVENT_KINDS: readonly StreamEventKind[];
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
    /**
     * @private
     * @param {Glue} b
     * @param {FactHandle} handle
     */
    private constructor();
    /** The engine's fact id: stable for the fact's life, never reused. */
    get id(): bigint;
    /**
     * Whether the fact is still in working memory. After a replay that halted
     * the engine, nothing can say, and this stays true until `close`.
     */
    get alive(): boolean;
    /**
     * The fact as it is now: `{ schema, id, slots }`.
     * @returns {FactRecord}
     */
    read(): FactRecord;
    #private;
}
/**
 * An engine's clock, live: each read gives the engine's clock as it is then.
 * The monotonic clock is integer nanoseconds. A mock clock moves only when the
 * host moves it, through `set` and `advance`; a live one moves with the host.
 *
 * A Clock comes from its engine (`engine.clock`) and is never made directly.
 */
export class Clock {
    /**
     * @private
     * @param {Glue} b
     * @param {EngineHandle} h
     */
    private constructor();
    /**
     * Setting "mock" starts the monotonic clock at 0 and leaves the wall
     * clock unset until `setWall`. DsError(DS_ERR_STATE) once the engine has
     * sampled its clock, for an input or a pump.
     * @param {ClockMode} mode
     */
    set mode(mode: ClockMode);
    /**
     * "live" or "mock".
     * @returns {ClockMode}
     */
    get mode(): ClockMode;
    /**
     * The monotonic clock, ns. Reading it is not a sample: it records nothing.
     * @returns {bigint}
     */
    get now(): bigint;
    /**
     * The earliest deadline after the clock's current value, ns, or null: a
     * live timer's fire_at, a live fact's TTL expiry or a cache entry's expiry.
     * Reading it is not a sample: it records nothing.
     * @returns {bigint | null}
     */
    get nextDeadline(): bigint | null;
    /**
     * Set the mock monotonic clock; DsError(DS_ERR_STATE) in live mode, and
     * below its current value once the engine has sampled it. Not a sample:
     * the next input or pump observes it.
     * @param {Int64} ns
     */
    set(ns: Int64): void;
    /**
     * Advance the mock monotonic clock, and the mock wall clock by the same
     * amount when it is set.
     * @param {Int64} ns
     */
    advance(ns: Int64): void;
    /**
     * Set the mock wall clock, UTC ns since the Unix epoch: any instant,
     * earlier or later, as a host clock can be stepped. DsError(DS_ERR_STATE)
     * in live mode.
     * @param {Int64} utcNs
     */
    setWall(utcNs: Int64): void;
    #private;
}
/**
 * An engine's cache, as the host reaches it: seeded before the first pump,
 * capped, and written through to the host's store. Rules read and write it;
 * the host does not read it.
 *
 * A Cache comes from its engine (`engine.cache`) and is never made directly.
 */
export class Cache {
    /**
     * @private
     * @param {Glue} b
     * @param {EngineHandle} h
     * @param {(handlers: WriteThrough | null) => void} register
     */
    private constructor();
    /**
     * Seed an entry before the first pump: `json` is its value as JSON text,
     * and `ttlNs` its TTL, 0 (the default) for none. A seed is not a write:
     * no action_cache_set event, and no write-through. DsError(DS_ERR_STATE)
     * after the first pump.
     * @param {string} key
     * @param {string} json
     * @param {{ ttlNs?: Int64 }} [options]
     */
    seed(key: string, json: string, { ttlNs }?: {
        ttlNs?: Int64;
    }): void;
    /**
     * Cap the cache's keys and its bytes; each left out, or 0, is unbounded.
     * A write past either fails with DS_ERR_CONTRACT_BREACH and changes
     * nothing.
     * @param {{ keys?: Int64, bytes?: Int64 }} [caps]
     */
    setCap({ keys, bytes }?: {
        keys?: Int64;
        bytes?: Int64;
    }): void;
    /** @param {WriteThrough | null} handlers */
    set writeThrough(handlers: WriteThrough | null);
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
    get writeThrough(): Readonly<WriteThrough> | null;
    #private;
}
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
    /**
     * An empty engine. Throws until this realm has opened libds.
     *
     * `runId` and `tierId` are the engine's identity, the integrator's to give
     * ([NLFC.1.2]): the stream header records them, and each `event_id` derives
     * from them. Absent, null or `""`, the engine has none.
     * @param {{ runId?: string | null, tierId?: string | null }} [options]
     */
    constructor(options?: {
        runId?: string | null;
        tierId?: string | null;
    });
    /**
     * An independent copy of this engine ([NLFC.8]): facts, working memory,
     * series, cache, clock and counters, sharing nothing. It starts with NO
     * listeners or callbacks: add them to the clone before pumping it ([NLFC.8.3]).
     * Refused mid-pump, inside a callback, and in real-time mode. Facts of this
     * engine are not facts of the clone.
     * @returns {Engine}
     */
    clone(): Engine;
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
    recordTo(target: string | ((bytes: Uint8Array) => void)): void;
    /**
     * Stop recording and report: the recorder's first error, if it had one, is
     * thrown as a DsError (a sink's own throw as its `cause`). Idempotent.
     */
    stopRecording(): void;
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
    replayStream(source: Uint8Array | Iterable<Uint8Array>, { maxAtomBytes }?: {
        maxAtomBytes?: number;
    }): ReplayCounts;
    /**
     * A FactAssert or FactEmit atom's `fact` bytes, typed by this engine's
     * schema `schema` (`ds_rfcs_decode_fact_body`): the slots as a fact's
     * `read()` gives them.
     * @param {string} schema
     * @param {Uint8Array} body
     * @returns {Record<string, SlotValue>}
     */
    decodeFactBody(schema: string, body: Uint8Array): Record<string, SlotValue>;
    /**
     * The session's header (LFST.4): a snapshot, made at each read.
     * @returns {SessionHeader}
     */
    get sessionHeader(): SessionHeader;
    /**
     * The run id this engine was given, or null.
     * @returns {string | null}
     */
    get runId(): string | null;
    /**
     * The tier id this engine was given, or null.
     * @returns {string | null}
     */
    get tierId(): string | null;
    /**
     * Release the engine now. Idempotent. A later call on it throws
     * DsError(DS_ERR_STATE), and passing or reading one of its Facts
     * DsError(DS_ERR_FACT_INVALID). Reading `clock`, `cache` or `writeThrough`
     * does not throw.
     */
    close(): void;
    /**
     * @template {keyof EngineEventMap} K
     * @overload
     * @param {K} type
     * @param {((event: EngineEventMap[K]) => void) | null} listener
     * @param {boolean | AddEventListenerOptions} [options]
     * @returns {void}
     */
    addEventListener<K extends keyof EngineEventMap>(type: K, listener: ((event: EngineEventMap[K]) => void) | null, options?: boolean | AddEventListenerOptions | undefined): void;
    /**
     * @overload
     * @param {string} type
     * @param {EventListenerOrEventListenerObject | null} listener
     * @param {boolean | AddEventListenerOptions} [options]
     * @returns {void}
     */
    addEventListener(type: string, listener: EventListenerOrEventListenerObject | null, options?: boolean | AddEventListenerOptions | undefined): void;
    /**
     * @template {keyof EngineEventMap} K
     * @overload
     * @param {K} type
     * @param {((event: EngineEventMap[K]) => void) | null} listener
     * @param {boolean | EventListenerOptions} [options]
     * @returns {void}
     */
    removeEventListener<K extends keyof EngineEventMap>(type: K, listener: ((event: EngineEventMap[K]) => void) | null, options?: boolean | EventListenerOptions | undefined): void;
    /**
     * @overload
     * @param {string} type
     * @param {EventListenerOrEventListenerObject | null} listener
     * @param {boolean | EventListenerOptions} [options]
     * @returns {void}
     */
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject | null, options?: boolean | EventListenerOptions | undefined): void;
    /** @param {((event: LogEngineEvent) => void) | null} fn */
    set onlog(fn: ((event: LogEngineEvent) => void) | null);
    /**
     * The "log" events' handler (TAG §7.5), or null: the log records libds
     * reports, as a listener added for "log" hears them.
     * @returns {((event: LogEngineEvent) => void) | null}
     */
    get onlog(): ((event: LogEngineEvent) => void) | null;
    /** @param {((event: MetricEngineEvent) => void) | null} fn */
    set onmetric(fn: ((event: MetricEngineEvent) => void) | null);
    /**
     * The "metric" events' handler, or null.
     * @returns {((event: MetricEngineEvent) => void) | null}
     */
    get onmetric(): ((event: MetricEngineEvent) => void) | null;
    /**
     * A rule's `call`. The reply is a fact of the service's response schema,
     * asserted after the pump.
     * @param {((request: CallRequest) => void) | null} fn
     */
    setCallCallback(fn: ((request: CallRequest) => void) | null): void;
    /**
     * The engine's cache: the same Cache at every read.
     * @returns {Cache}
     */
    get cache(): Cache;
    /**
     * Load a compiled `.dsc`. A load that fails once it has begun reading
     * spends the engine ([RDSC.9.8]): `halted` is 0, no engine error, and
     * every later call but `halted`, the platform signature, the session
     * header and close throws DS_ERR_ENGINE_HALTED.
     * @param {Uint8Array} bytes
     */
    loadDsc(bytes: Uint8Array): void;
    /**
     * The engine's schemas by name, its internal ones included: a snapshot
     * of the program as loaded, the same map at every read until loadDsc
     * or replayStream changes the schemas. Its schemas are frozen.
     * @returns {ReadonlyMap<string, SchemaInfo>}
     */
    get schemas(): ReadonlyMap<string, SchemaInfo>;
    /**
     * A number in the unit a slot names, as the number the slot stores
     * ([NFCT.1.4.6]): what `value::<unit>` gives a rule, which assert takes.
     * An Int is a BigInt or a safe integer Number and comes back a BigInt; a
     * Float is a Number. Changes nothing. Throws a DsError:
     * DS_ERR_SCHEMA_UNKNOWN or DS_ERR_SLOT_UNKNOWN for a name the engine has
     * no schema or slot by, DS_ERR_INVAL for a slot that names no unit,
     * DS_ERR_SLOT_TYPE_MISMATCH, DS_ERR_NAN_REJECTED, and
     * DS_ERR_NOT_REPRESENTABLE where the conversion has no result for the
     * number.
     * @param {string} schema
     * @param {string} slot
     * @param {bigint | number} value
     * @returns {bigint | number}
     */
    slotToStored(schema: string, slot: string, value: bigint | number): bigint | number;
    /**
     * A number a slot stores, in the unit the slot names: what a kwarg of
     * that unit receives ([NFCT.1.4.6]). The inverse of slotToStored, taken
     * and refused as it is.
     * @param {string} schema
     * @param {string} slot
     * @param {bigint | number} value
     * @returns {bigint | number}
     */
    slotFromStored(schema: string, slot: string, value: bigint | number): bigint | number;
    /**
     * The program's rules' metadata by rule name: a snapshot, as `schemas`
     * is, made again after loadDsc or replayStream. Its entries are frozen.
     * @returns {ReadonlyMap<string, RuleMeta>}
     */
    get rules(): ReadonlyMap<string, RuleMeta>;
    /**
     * Where each attributed node comes from ([NDBG.3.1]): the program's line
     * spans, in the artefact's order, a frozen snapshot as `rules` is. A node
     * id is unique in a program, so a node has at most one span; an alpha has
     * none ([RDSC.14.3.6]). Empty before a load.
     * @returns {readonly LineSpan[]}
     */
    get lineSpans(): readonly LineSpan[];
    /**
     * The line span of the node `nodeId`, as `reteNetwork()` and a fault
     * event name it ([NDBG.3.2]). A node with no span, an alpha among them,
     * throws a DsError with DS_ERR_NOT_FOUND ([NDBG.7.1]).
     * @param {number} nodeId
     * @returns {LineSpan}
     */
    lineSpan(nodeId: number): LineSpan;
    /**
     * Assert a fact: slots by name. An omitted nullable slot is null. Its
     * TTL is its schema's: there is no per-fact TTL.
     * @param {string} schema
     * @param {Record<string, SlotValue>} slots
     * @returns {Fact}
     */
    assert(schema: string, slots: Record<string, SlotValue>): Fact;
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
    assertExternal(data: Uint8Array | FactArgument): void;
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
    applyExternalAssert(body: Uint8Array): ExternalAssertApplied;
    /**
     * Retract a fact: a Fact, or a fact id, as the introspection calls take
     * either. A Fact that has left working memory is refused with
     * DS_ERR_FACT_INVALID, and an id no live fact has with DS_ERR_NOT_FOUND.
     * An id is found by walking working memory, O(live facts).
     * @param {Fact | Int64} fact
     */
    retract(fact: Fact | Int64): void;
    /**
     * Every live fact, or `schema`'s, as Facts: a snapshot, unordered. Sort by
     * `id` if order matters.
     * @param {{ schema?: string | null }} [options]
     * @returns {Fact[]}
     */
    facts({ schema }?: {
        schema?: string | null;
    }): Fact[];
    /**
     * How many facts are in working memory.
     * @returns {number}
     */
    get factCount(): number;
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
    get halted(): number | null;
    /**
     * The live fact with this engine-local id, or null. A clone's facts have
     * handles of their own: this is how a fact asserted before a clone is
     * retracted in it. Walks working memory, O(live facts).
     * @param {Int64} id
     * @returns {Fact | null}
     */
    factById(id: Int64): Fact | null;
    /**
     * The Rete structures' bytes. A method, not a property: it walks the
     * engine's structures to answer.
     * @returns {MemoryReport}
     */
    memory(): MemoryReport;
    /**
     * Run the agenda to exhaustion. Rules fire only here. A handler of the
     * cache's write-through that throws fails it: the DsError carries the
     * handler's exception as its `cause`.
     */
    pump(): void;
    /**
     * The engine's clock: the same Clock at every read, and live.
     * @returns {Clock}
     */
    get clock(): Clock;
    /**
     * The platform signature ([LDET.2.3]): a snapshot, made at each read.
     * @returns {PlatformSignature}
     */
    get platformSignature(): PlatformSignature;
    /**
     * The activations that logically support a fact; empty for a fact nothing
     * derived.
     * @param {Fact | Int64} fact  a Fact, or a fact id
     * @returns {Justifier[]}
     */
    justifiers(fact: Fact | Int64): Justifier[];
    /**
     * The Rete network, optionally only what one rule reaches.
     * @param {{ ruleFilter?: string | null, includeOccupancy?: boolean }} [options]
     * @returns {ReteNetwork}
     */
    reteNetwork({ ruleFilter, includeOccupancy }?: {
        ruleFilter?: string | null;
        includeOccupancy?: boolean;
    }): ReteNetwork;
    /**
     * A fact's path through the alpha network.
     * @param {Fact | Int64} fact  a Fact, or a fact id
     * @returns {MatchStep[]}
     */
    reteMatchTrace(fact: Fact | Int64): MatchStep[];
    /**
     * Activations refraction blocked this cycle.
     * @param {string | null} [ruleFilter]
     * @returns {Refraction[]}
     */
    refractedActivations(ruleFilter?: string | null): Refraction[];
    /** `close`, for `using`, where the platform has `Symbol.dispose`. */
    [Symbol.dispose](): void;
    #private;
}
export type Entry = "node" | "browser";
export type EngineHandle = {
    readonly brand: "@ds-lang/ds engine";
};
export type FactHandle = {
    readonly brand: "@ds-lang/ds fact";
};
export type ReplayHandle = {
    readonly brand: "@ds-lang/ds replay";
};
export type CallbackName = "stream" | "call" | "log" | "metric";
/**
 * The glue's exports, as src/ds.c defines them.
 */
export type Glue = {
    init: (errorClass: typeof DsError, hook: UnraisableHook) => void;
    newEngine: (runId: string | null, tierId: string | null) => EngineHandle;
    close: (e: EngineHandle) => void;
    clone: (e: EngineHandle) => EngineHandle;
    loadDsc: (e: EngineHandle, bytes: Uint8Array) => void;
    schemaCount: (e: EngineHandle) => number;
    schemaAt: (e: EngineHandle, i: number) => SchemaInfo;
    slotConvert: (e: EngineHandle, schema: string, slot: string, value: bigint | number, toStored: boolean) => bigint | number;
    assert: (e: EngineHandle, schema: string, slots: Record<string, SlotValueOf<FactHandle>>) => FactHandle;
    assertExternal: (e: EngineHandle, bytes: Uint8Array) => void;
    applyExternalAssert: (e: EngineHandle, body: Uint8Array) => ExternalAssertApplied;
    retract: (e: EngineHandle, f: FactHandle) => void;
    factId: (f: FactHandle) => bigint;
    factAlive: (f: FactHandle) => boolean;
    factRead: (f: FactHandle) => FactRecordOf<FactHandle>;
    facts: (e: EngineHandle, schema: string | null) => FactHandle[];
    factCount: (e: EngineHandle) => number;
    halted: (e: EngineHandle) => number | null;
    factById: (e: EngineHandle, id: Int64) => FactHandle | null;
    mem: (e: EngineHandle) => MemoryReport;
    pump: (e: EngineHandle) => void;
    clockMode: (e: EngineHandle) => ClockMode;
    clockSetMode: (e: EngineHandle, mode: ClockMode) => void;
    clockNow: (e: EngineHandle) => bigint;
    clockNextDeadline: (e: EngineHandle) => bigint | null;
    clockSet: (e: EngineHandle, ns: Int64) => void;
    clockAdvance: (e: EngineHandle, ns: Int64) => void;
    wallClockSet: (e: EngineHandle, utcNs: Int64) => void;
    platformSignature: (e: EngineHandle) => PlatformSignature;
    setCallback: (e: EngineHandle, name: CallbackName, fn: ((...args: never[]) => unknown) | null) => void;
    setCacheCallbacks: (e: EngineHandle, set: ((key: string, value: string | null, ttlNs: bigint) => void) | null, del: ((key: string, reason: CacheRemoval["reason"]) => void) | null) => void;
    cacheSeed: (e: EngineHandle, key: string, json: string, ttlNs: Int64) => void;
    ruleMetaCount: (e: EngineHandle) => number;
    ruleMetaAt: (e: EngineHandle, i: number) => RuleMeta;
    lineSpanCount: (e: EngineHandle) => number;
    lineSpanAt: (e: EngineHandle, i: number) => LineSpan;
    lineSpanFind: (e: EngineHandle, nodeId: number) => LineSpan;
    getJustifiers: (e: EngineHandle, factId: Int64) => Justifier[];
    reteNetwork: (e: EngineHandle, ruleFilter: string | null, includeOccupancy: boolean) => ReteNetwork;
    reteMatchTrace: (e: EngineHandle, factId: Int64) => MatchStep[];
    refractedActivations: (e: EngineHandle, ruleFilter: string | null) => Refraction[];
    setCacheCap: (e: EngineHandle, capKeys: Int64, capBytes: Int64) => void;
    sessionHeader: (e: EngineHandle) => SessionHeader;
    runId: (e: EngineHandle) => string | null;
    tierId: (e: EngineHandle) => string | null;
    recordTo: (e: EngineHandle, sink: (bytes: Uint8Array) => void) => void;
    stopRecording: (e: EngineHandle) => void;
    replayBegin: (e: EngineHandle, maxAtomBytes: number) => ReplayHandle;
    replayFeed: (r: ReplayHandle, chunk: Uint8Array) => void;
    replayFinish: (r: ReplayHandle) => ReplayCounts & {
        tailBytes: bigint;
    };
    readAtoms: (bytes: Uint8Array, incremental: boolean) => AtomsRead;
    messageName: (field: number) => string | null;
    decodeFactBody: (e: EngineHandle, schema: string, body: Uint8Array) => Record<string, SlotValueOf<FactHandle>>;
    decodeAnnouncedFactBody: (slots: AnnouncedSlot[], body: Uint8Array) => Record<string, SlotValueOf<FactHandle>>;
    decodeAnnouncedFactBodyHandles: (slots: AnnouncedSlot[], body: Uint8Array) => {
        slots: Record<string, SlotValueOf<FactHandle>>;
        refs: Record<string, bigint | null>;
    };
};
import type { Host } from "./types.js";
import type { Target } from "./types.js";
import type { Api } from "./types.js";
import * as status from "./status.js";
import type { StreamEventKind } from "./types.js";
import type { FactRecord } from "./types.js";
import type { ClockMode } from "./types.js";
import type { Int64 } from "./types.js";
import type { WriteThrough } from "./types.js";
import type { ReplayCounts } from "./types.js";
import type { SlotValue } from "./types.js";
import type { SessionHeader } from "./types.js";
import type { EngineEventMap } from "./types.js";
import type { LogEngineEvent } from "./types.js";
import type { MetricEngineEvent } from "./types.js";
import type { CallRequest } from "./types.js";
import type { SchemaInfo } from "./types.js";
import type { RuleMeta } from "./types.js";
import type { LineSpan } from "./types.js";
import type { FactArgument } from "./types.js";
import type { ExternalAssertApplied } from "./types.js";
import type { MemoryReport } from "./types.js";
import type { PlatformSignature } from "./types.js";
import type { Justifier } from "./types.js";
import type { ReteNetwork } from "./types.js";
import type { MatchStep } from "./types.js";
import type { Refraction } from "./types.js";
import type { UnraisableHook } from "./types.js";
import type { SlotValueOf } from "./types.js";
import type { FactRecordOf } from "./types.js";
import type { CacheRemoval } from "./types.js";
import type { AtomsRead } from "./types.js";
import type { AnnouncedSlot } from "./types.js";
