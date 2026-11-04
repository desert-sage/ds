// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
/**
 * A 64-bit integer going in: a BigInt, or a Number that `Number.isSafeInteger`
 * accepts. A fact id, a duration, a cap or a monotonic time is refused when
 * negative.
 * One coming out is always a BigInt.
 */
export type Int64 = bigint | number;
export type Target = "native" | "wasm";
export type ClockMode = "live" | "mock";
export type Lifecycle = "logical" | "ttl" | "internal";
export type SlotType = "Int" | "Float" | "String" | "Bool" | "Json" | "Bytes" | "Time" | "Date" | "Duration";
/**
 * A slot's value: an Int as a BigInt, a Float as a Number, Json as canonical
 * JSON text, Bytes as a Uint8Array, a fact-ref slot as the Fact it names, and
 * null for no value. An Int going in may also be a safe integer Number.
 */
export type SlotValue = SlotValueOf<Fact>;
/**
 * A slot's value with fact references as `F`.
 */
export type SlotValueOf<F> = bigint | number | string | boolean | null | Uint8Array | F;
/**
 * A fact as read: its schema, its engine-local id and its slots by name.
 */
export type FactRecord = FactRecordOf<Fact>;
/**
 * A fact as read, with fact references as `F`.
 */
export type FactRecordOf<F> = {
    schema: string;
    id: bigint;
    slots: Record<string, SlotValueOf<F>>;
};
/**
 * One slot of a schema: its type (a slot type, or the schema a fact-ref slot
 * names), its identity role, and whether it may be null.
 */
export type SlotInfo = {
    name: string;
    type: string;
    identity: "key" | "mutable" | "engine" | null;
    nullable: boolean;
};
/**
 * A schema the engine knows.
 */
export type SchemaInfo = {
    name: string;
    lifecycle: Lifecycle;
    ttlNs: bigint;
    slots: SlotInfo[];
};
/**
 * A rule's metadata from the `.dsc`; each optional field is null when its
 * atom is absent.
 */
export type RuleMeta = {
    ruleName: string;
    coolWindowNs: bigint | null;
    srcFile: string | null;
    srcLine: number | null;
    srcCol: number | null;
    debugNameTemplate: string | null;
};
/**
 * Where a Rete node comes from in the program's source ([NDBG.3.1]): its
 * node id, the module it is in (`moduleId`, and that module's display path),
 * and its 1-based line and column there.
 */
export type LineSpan = {
    nodeId: number;
    moduleId: number;
    file: string | null;
    line: number;
    column: number;
};
/**
 * The bytes the engine's structures hold (`ds_engine_mem`).
 */
export type MemoryReport = {
    wmFactCount: number;
    wmFactBytes: number;
    wmIndexBytes: number;
    alphaNodeCount: number;
    alphaMatchCount: number;
    alphaIndexBytes: number;
    betaNodeCount: number;
    betaTokenCount: number;
    betaTokenBytes: number;
    betaIndexBytes: number;
    internCount: number;
    internStringBytes: number;
    internIndexBytes: number;
    poolReservedBytes: number;
    totalBytes: number;
};
export type PlatformSignature = {
    osFamily: string;
    cpuArch: string;
    libc: string;
    compiler: string;
    libdsVersion: string;
    backends: string[];
};
/**
 * The session's header: `dscHash` is the loaded `.dsc`'s SHA-256, or null
 * before a load.
 */
export type SessionHeader = {
    dsVersion: string;
    sessionId: string;
    tierId: string;
    dscHash: Uint8Array | null;
};
export type Justifier = {
    timetag: bigint;
    ruleName: string;
};
/**
 * One node of the Rete network. `occupancy` is null unless it was asked for
 * and the engine is paused.
 */
export type ReteNode = {
    id: string;
    kind: string;
    label: string;
    filter: string;
    occupancy: number | null;
    isNegative: boolean;
};
export type ReteEdge = {
    fromId: string;
    toId: string;
};
export type ReteNetwork = {
    nodes: ReteNode[];
    edges: ReteEdge[];
};
export type MatchStep = {
    nodeId: string;
    nodeKind: string;
    result: string;
    detail: string;
};
/**
 * An activation refraction blocked; every fact it names is live ([NDBG.4.3]).
 */
export type Refraction = {
    ruleName: string;
    reason: string;
    detail: string;
    factIds: bigint[];
};
/**
 * What a replay did.
 */
export type ReplayCounts = {
    asserts: bigint;
    retracts: bigint;
    clocks: bigint;
    ruleFires: bigint;
    calls: bigint;
    withdrawals: bigint;
    skipped: bigint;
    headerVerified: boolean;
};
/**
 * An enum field of an atom: its number, and its name where this build has one.
 */
export type AtomEnum = {
    number: number;
    name: string | null;
};
/**
 * An atom's message, field by field: nested messages as objects, repeated
 * fields as arrays, 64-bit integers as BigInts.
 */
export type AtomBody = {
    [field: string]: AtomField;
};
export type AtomScalar = bigint | number | boolean | string | Uint8Array;
/**
 * One field of an atom's message. A repeated field is an array of one kind:
 * protobuf has no repeated field of repeated fields.
 */
export type AtomField = AtomScalar | AtomEnum | AtomBody | AtomScalar[] | AtomEnum[] | AtomBody[];
/**
 * One atom, named by its field number ([RFCS.16.1]). `message` is the proto
 * message its body is, and `body` its fields; both are null for an atom this
 * build has no entry for. `unknownFields` is the number of each field in the
 * body, at any depth, that its message does not name, in the order read:
 * empty when there are none ([RTIM.14.9]). `bodyOffset` and `bodyLength` are
 * where its body's bytes are in what was read, as framed.
 */
export type Atom = {
    offset: number;
    field: number;
    message: string | null;
    body: AtomBody | null;
    unknownFields: number[];
    bodyOffset: number;
    bodyLength: number;
};
/**
 * What `applyExternalAssert` asserted ([RFCS.24.2]): `factIds[i]` is the
 * engine's id for the recorded `recordedIds[i]`, in [RFCS.24.3]'s order.
 */
export type ExternalAssertApplied = {
    factIds: bigint[];
    recordedIds: bigint[];
};
/**
 * What `readAtoms` read: the atoms before any error, where reading stopped,
 * whether it stopped at a partial trailing atom, and the error that stopped
 * it, if one did. The error's `field` and `message` name the atom when reading
 * stopped at its body, and are null when it stopped at framing.
 */
export type AtomsRead = {
    atoms: Atom[];
    end: number;
    incomplete: boolean;
    error: {
        offset: number;
        status: number;
        detail: string;
        field: number | null;
        message: string | null;
    } | null;
};
/**
 * One slot as a stream announces it, a `Slot` atom's fields ([RFCS.5.1]):
 * what `decodeAnnouncedFactBody` types a fact body by. `kind` is
 * `Slot.kind`'s number; `schemaRef` is a fact-ref slot's schema, else null
 * or "".
 */
export type AnnouncedSlot = {
    name: string;
    kind: number;
    nullable: boolean;
    schemaRef: string | null;
};
/**
 * What `decodeAnnouncedFactBodyHandles` gives: every slot but a fact-ref one,
 * and each fact-ref slot's recorded handle, or null where a nullable one is
 * absent ([RFCS.6.3]).
 */
export type AnnouncedBody = {
    slots: Record<string, SlotValue>;
    refs: Record<string, bigint | null>;
};
export type LogLevel = "DEBUG" | "INFO" | "WARNING" | "ERROR" | "CRITICAL" | "UNKNOWN";
export type LogRecord = {
    level: LogLevel;
    category: string;
    message: string;
};
export type Metric = {
    name: string;
    kind: "counter" | "gauge" | "histogram" | "unknown";
    value: number;
    labels: Record<string, string>;
};
/**
 * A fact passed to a call: not live in this engine, so no Fact, but its
 * schema, the UTC instant it entered working memory (null when the wall clock
 * had no value then), and its FactExternal bytes.
 */
export type FactArgument = {
    schema: string;
    assertedAt: bigint | null;
    external: Uint8Array;
};
/**
 * One argument of a call, typed as a slot of its kind reads, except Json: a
 * slot's schema says it is a document, and a call argument has none beside it,
 * so a Json argument is a JsonText and a String one a string.
 */
export type CallArgument = bigint | number | string | boolean | null | Uint8Array | JsonText | FactArgument;
/**
 * A rule's `call`. `correlation` is the call's `as` value, or the one the
 * compiler generates for a call with none or whose computed `as` renders `""`
 * ([LCRS.3.1]): always a string, never empty. `args` maps each argument the
 * call supplies to its value.
 */
export type CallRequest = {
    service: string;
    correlation: string;
    args: Record<string, CallArgument>;
    timetag: bigint;
    ruleName: string;
};
/**
 * One write the rules made to the cache: the value as canonical JSON text,
 * and its TTL in ns, 0 for none.
 */
export type CacheWrite = {
    key: string;
    value: string | null;
    ttlNs: bigint;
};
/**
 * One entry leaving the cache: by a rule's `cache_delete`, or its TTL.
 */
export type CacheRemoval = {
    key: string;
    reason: "delete" | "ttl";
};
/**
 * The cache's write-through: `set` hears each write, `delete` each removal.
 * One left out, or null, hears nothing.
 */
export type WriteThrough = {
    set?: ((write: CacheWrite) => void) | null | undefined;
    delete?: ((removal: CacheRemoval) => void) | null | undefined;
};
/**
 * One observable event of the engine, in `seq` order.
 */
export type StreamEvent = StreamEventOf<Fact>;
/**
 * A stream event with facts as `F`. The kinds are the names
 * runtime/src/bindings/ds_names.h gives every binding.
 */
export type StreamEventOf<F> = {
    seq: bigint;
    clockNs: bigint;
} & ({
    kind: "fact_assert" | "fact_retract" | "fact_modify" | "action_emit";
    fact: F;
} | {
    kind: "action_publish";
    schema: string;
    slots: Record<string, SlotValueOf<F>>;
    external: Uint8Array;
} | {
    kind: "rule_fire_begin" | "rule_fire_end";
    ruleName: string;
    timetag: bigint;
} | {
    kind: "rule_lhs_facts";
    ruleName: string;
    lhsFacts: F[];
    timetag: bigint;
} | ({
    kind: "action_log";
} & LogRecord) | {
    kind: "action_cache_set";
    key: string;
    valueJson: string | null;
    ttlNs: bigint;
} | {
    kind: "action_cache_get";
    key: string;
    valueJson: string | null;
} | {
    kind: "action_cache_delete";
    key: string;
} | ({
    kind: "action_call";
} & CallRequest) | {
    kind: "timer_armed";
    ruleName: string;
    timerKind: string;
    windowNs: bigint;
    fireAtNs: bigint;
    timetag: bigint;
} | {
    kind: "timer_fired";
    ruleName: string;
    timerKind: string;
} | {
    kind: "type_error";
    nodeId: number;
    schemaName: string | null;
    slotName: string | null;
    actual: string | null;
    ruleName: string;
} | {
    kind: "bounds_error";
    cap: number;
    limit: bigint;
    observed: bigint;
    ruleName: string | null;
    timetag: bigint;
} | {
    kind: "engine_error";
    engineFault: number;
    nodeId: number;
    ruleName: string;
} | {
    kind: "computation_error";
    trapKind: number;
    ruleName: string;
    timetag: bigint;
    schemaName: string | null;
    slotName: string | null;
    factId: bigint;
    nodeId: number;
} | {
    kind: "tick";
    wallNs: bigint | null;
} | {
    kind: "pump" | "unknown";
});
export type StreamEventKind = StreamEvent["kind"];
/**
 * A stream record as the event the engine dispatches for it: its kind is the
 * event's `type`, and its other fields are the event's.
 */
export type AsEngineEvent<R> = R extends {
    kind: infer K;
} ? EngineEvent & Omit<R, "kind"> & {
    readonly type: K;
} : never;
/**
 * The event an Engine dispatches for one stream event, of any kind.
 */
export type StreamEngineEvent = AsEngineEvent<StreamEvent>;
export type LogEngineEvent = EngineEvent & LogRecord & {
    readonly type: "log";
};
export type MetricEngineEvent = EngineEvent & Metric & {
    readonly type: "metric";
};
/**
 * The events an Engine dispatches, by type: what a listener added for each
 * is given.
 */
export type EngineEventMap = { [K in StreamEventKind]: StreamEngineEvent & {
    readonly type: K;
}; } & {
    log: LogEngineEvent;
    metric: MetricEngineEvent;
};
/**
 * Where a throwing callback's exception is reported: the exception, and the
 * callback's name, "call", or the name of one whose argument could not be
 * built ("stream", "log", "metric", "cacheSet", "cacheDelete"). An event
 * listener's exception is not one: the platform reports it, as it reports any
 * listener's. Nor is a handler's: the call that ran it throws it as a
 * DsError's `cause`, or, where no call fails, it is reported as a listener's is.
 */
export type UnraisableHook = (error: unknown, where: string) => void;
/**
 * How a compile is run: what the source is called, and where its imports are
 * found.
 */
export type CompileOptions = {
    file?: string;
    searchPath?: string[];
};
/**
 * A compile under wasm (ds_dsc): what `files` holds is what the compile
 * reads by path (each `searchPath` directory's files), and `wasmBinary` is the
 * compiler's `.wasm`, rather than the module fetching it beside itself, or
 * `wasmModule` that `.wasm` compiled already. `program` is the compiler's own
 * path, its argv[0]: it finds the standard library it ships with at `<its
 * directory>/../share/ds/stdlib` ([LIMP.3.3.1]), among `files`.
 */
export type WasmCompileOptions = CompileOptions & {
    files?: Record<string, string | Uint8Array>;
    wasmBinary?: Uint8Array | ArrayBuffer;
    wasmModule?: WebAssembly.Module;
    program?: string;
};
/**
 * An emscripten module a page hands over: its factory, the module, or a URL to
 * import it from.
 */
export type ModuleSource = Function | object | string | URL;
export type FileSink = {
    write: (bytes: Uint8Array) => void;
    close: () => void;
};
/**
 * What a host gives the API: how `recordTo` opens a path (null where there is
 * no file system, and `recordTo` then takes only a sink), and the compiler,
 * whose runner may be async (ds_dsc's is).
 */
export type Host = {
    file: ((path: string) => FileSink) | null;
    compile: (source: string, options?: never) => Uint8Array | Promise<Uint8Array>;
    compileFile: (path: string, options?: never) => Uint8Array | Promise<Uint8Array>;
};
/**
 * `fromSource` for a host's compiler: an Engine where compiling is
 * synchronous, a Promise of one where it is not.
 */
export type FromSource<C extends Host["compile"]> = (source: string, options?: Parameters<C>[1]) => ReturnType<C> extends Promise<Uint8Array> ? Promise<Engine> : Engine;
/**
 * The API over this realm's libds, for the host `H` that opened it.
 */
export type Api<H extends Host> = {
    target: Target;
    Engine: typeof Engine;
    Fact: typeof Fact;
    JsonText: typeof JsonText;
    EngineEvent: typeof EngineEvent;
    /**
     * every stream event kind: an Engine's stream
     * event types
     */
    STREAM_EVENT_KINDS: readonly StreamEventKind[];
    DsError: typeof DsError;
    CompileRefused: typeof CompileRefused;
    status: typeof status;
    /**
     *   replace where a throwing callback's exception is reported; null restores
     *   the default, which prints to stderr; returns the previous hook
     */
    setUnraisableHook: (fn: UnraisableHook | null) => UnraisableHook;
    compile: H["compile"];
    compileFile: H["compileFile"];
    fromSource: FromSource<H["compile"]>;
    readAtoms: (bytes: Uint8Array, options?: {
        incremental?: boolean;
    }) => AtomsRead;
    messageName: (field: number) => string | null;
    decodeAnnouncedFactBody: (slots: AnnouncedSlot[], body: Uint8Array) => Record<string, SlotValue>;
    decodeAnnouncedFactBodyHandles: (slots: AnnouncedSlot[], body: Uint8Array) => AnnouncedBody;
};
import type { Fact } from "./bind.js";
import type { JsonText } from "./bind.js";
import type { EngineEvent } from "./bind.js";
import type { Engine } from "./bind.js";
import type { DsError } from "./bind.js";
import type { CompileRefused } from "./bind.js";
import type * as status from "./status.js";
