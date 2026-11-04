// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// @ds-lang/ds's public types: the records the API hands out and takes, as JSDoc
// typedefs, which `tsc` turns into types/types.d.ts. Both entries re-export
// them (`export * from "./types.js"`), so a TypeScript program imports them
// from "@ds-lang/ds" as it imports the classes. The module holds no value, and
// it must not: a page loads it, and each entry's exports are what it says.

/** @import { CompileRefused, DsError, Engine, EngineEvent, Fact, JsonText } from "./bind.js" */
/** @import * as status from "./status.js" */

/**
 * A 64-bit integer going in: a BigInt, or a Number that `Number.isSafeInteger`
 * accepts. A fact id, a duration, a cap or a monotonic time is refused when
 * negative.
 * One coming out is always a BigInt.
 * @typedef {bigint | number} Int64
 */

/** @typedef {"native" | "wasm"} Target */
/** @typedef {"live" | "mock"} ClockMode */
/** @typedef {"logical" | "ttl" | "internal"} Lifecycle */
/** @typedef {"Int" | "Float" | "String" | "Bool" | "Json" | "Bytes" | "Time" | "Date" | "Duration"} SlotType */

/**
 * A slot's value: an Int as a BigInt, a Float as a Number, Json as canonical
 * JSON text, Bytes as a Uint8Array, a fact-ref slot as the Fact it names, and
 * null for no value. An Int going in may also be a safe integer Number.
 * @typedef {SlotValueOf<Fact>} SlotValue
 */

/**
 * A slot's value with fact references as `F`.
 * @template F
 * @typedef {bigint | number | string | boolean | null | Uint8Array | F} SlotValueOf
 */

/**
 * A fact as read: its schema, its engine-local id and its slots by name.
 * @typedef {FactRecordOf<Fact>} FactRecord
 */

/**
 * A fact as read, with fact references as `F`.
 * @template F
 * @typedef {{ schema: string, id: bigint, slots: Record<string, SlotValueOf<F>> }} FactRecordOf
 */

/**
 * One slot of a schema: its type (a slot type, or the schema a fact-ref slot
 * names), its identity role, and whether it may be null.
 * @typedef {{ name: string, type: string, identity: "key" | "mutable" | "engine" | null, nullable: boolean }} SlotInfo
 */

/**
 * A schema the engine knows.
 * @typedef {{ name: string, lifecycle: Lifecycle, ttlNs: bigint, slots: SlotInfo[] }} SchemaInfo
 */

/**
 * A rule's metadata from the `.dsc`; each optional field is null when its
 * atom is absent.
 * @typedef {object} RuleMeta
 * @property {string} ruleName
 * @property {bigint | null} coolWindowNs
 * @property {string | null} srcFile
 * @property {number | null} srcLine
 * @property {number | null} srcCol
 * @property {string | null} debugNameTemplate
 */

/**
 * Where a Rete node comes from in the program's source ([NDBG.3.1]): its
 * node id, the module it is in (`moduleId`, and that module's display path),
 * and its 1-based line and column there.
 * @typedef {object} LineSpan
 * @property {number} nodeId
 * @property {number} moduleId
 * @property {string | null} file
 * @property {number} line
 * @property {number} column
 */

/**
 * The bytes the engine's structures hold (`ds_engine_mem`).
 * @typedef {object} MemoryReport
 * @property {number} wmFactCount
 * @property {number} wmFactBytes
 * @property {number} wmIndexBytes
 * @property {number} alphaNodeCount
 * @property {number} alphaMatchCount
 * @property {number} alphaIndexBytes
 * @property {number} betaNodeCount
 * @property {number} betaTokenCount
 * @property {number} betaTokenBytes
 * @property {number} betaIndexBytes
 * @property {number} internCount
 * @property {number} internStringBytes
 * @property {number} internIndexBytes
 * @property {number} poolReservedBytes
 * @property {number} totalBytes
 */

/**
 * @typedef {object} PlatformSignature
 * @property {string} osFamily
 * @property {string} cpuArch
 * @property {string} libc
 * @property {string} compiler
 * @property {string} libdsVersion
 * @property {string[]} backends
 */

/**
 * The session's header: `dscHash` is the loaded `.dsc`'s SHA-256, or null
 * before a load.
 * @typedef {{ dsVersion: string, sessionId: string, tierId: string, dscHash: Uint8Array | null }} SessionHeader
 */

/** @typedef {{ timetag: bigint, ruleName: string }} Justifier */

/**
 * One node of the Rete network. `occupancy` is null unless it was asked for
 * and the engine is paused.
 * @typedef {object} ReteNode
 * @property {string} id
 * @property {string} kind
 * @property {string} label
 * @property {string} filter
 * @property {number | null} occupancy
 * @property {boolean} isNegative
 */

/** @typedef {{ fromId: string, toId: string }} ReteEdge */

/** @typedef {{ nodes: ReteNode[], edges: ReteEdge[] }} ReteNetwork */

/** @typedef {{ nodeId: string, nodeKind: string, result: string, detail: string }} MatchStep */

/**
 * An activation refraction blocked; every fact it names is live ([NDBG.4.3]).
 * @typedef {{ ruleName: string, reason: string, detail: string, factIds: bigint[] }} Refraction
 */

/**
 * What a replay did.
 * @typedef {object} ReplayCounts
 * @property {bigint} asserts
 * @property {bigint} retracts
 * @property {bigint} clocks
 * @property {bigint} ruleFires
 * @property {bigint} calls
 * @property {bigint} withdrawals
 * @property {bigint} skipped
 * @property {boolean} headerVerified
 */

/**
 * An enum field of an atom: its number, and its name where this build has one.
 * @typedef {{ number: number, name: string | null }} AtomEnum
 */

/**
 * An atom's message, field by field: nested messages as objects, repeated
 * fields as arrays, 64-bit integers as BigInts.
 * @typedef {{ [field: string]: AtomField }} AtomBody
 */

/** @typedef {bigint | number | boolean | string | Uint8Array} AtomScalar */

/**
 * One field of an atom's message. A repeated field is an array of one kind:
 * protobuf has no repeated field of repeated fields.
 * @typedef {AtomScalar | AtomEnum | AtomBody | AtomScalar[] | AtomEnum[] | AtomBody[]} AtomField
 */

/**
 * One atom, named by its field number ([RFCS.16.1]). `message` is the proto
 * message its body is, and `body` its fields; both are null for an atom this
 * build has no entry for. `unknownFields` is the number of each field in the
 * body, at any depth, that its message does not name, in the order read:
 * empty when there are none ([RTIM.14.9]). `bodyOffset` and `bodyLength` are
 * where its body's bytes are in what was read, as framed.
 * @typedef {object} Atom
 * @property {number} offset
 * @property {number} field
 * @property {string | null} message
 * @property {AtomBody | null} body
 * @property {number[]} unknownFields
 * @property {number} bodyOffset
 * @property {number} bodyLength
 */

/**
 * What `applyExternalAssert` asserted ([RFCS.24.2]): `factIds[i]` is the
 * engine's id for the recorded `recordedIds[i]`, in [RFCS.24.3]'s order.
 * @typedef {object} ExternalAssertApplied
 * @property {bigint[]} factIds
 * @property {bigint[]} recordedIds
 */

/**
 * What `readAtoms` read: the atoms before any error, where reading stopped,
 * whether it stopped at a partial trailing atom, and the error that stopped
 * it, if one did. The error's `field` and `message` name the atom when reading
 * stopped at its body, and are null when it stopped at framing.
 * @typedef {object} AtomsRead
 * @property {Atom[]} atoms
 * @property {number} end
 * @property {boolean} incomplete
 * @property {{ offset: number, status: number, detail: string, field: number | null, message: string | null } | null} error
 */

/**
 * One slot as a stream announces it, a `Slot` atom's fields ([RFCS.5.1]):
 * what `decodeAnnouncedFactBody` types a fact body by. `kind` is
 * `Slot.kind`'s number; `schemaRef` is a fact-ref slot's schema, else null
 * or "".
 * @typedef {object} AnnouncedSlot
 * @property {string} name
 * @property {number} kind
 * @property {boolean} nullable
 * @property {string | null} schemaRef
 */

/**
 * What `decodeAnnouncedFactBodyHandles` gives: every slot but a fact-ref one,
 * and each fact-ref slot's recorded handle, or null where a nullable one is
 * absent ([RFCS.6.3]).
 * @typedef {object} AnnouncedBody
 * @property {Record<string, SlotValue>} slots
 * @property {Record<string, bigint | null>} refs
 */

/** @typedef {"DEBUG" | "INFO" | "WARNING" | "ERROR" | "CRITICAL" | "UNKNOWN"} LogLevel */

/** @typedef {{ level: LogLevel, category: string, message: string }} LogRecord */

/**
 * @typedef {object} Metric
 * @property {string} name
 * @property {"counter" | "gauge" | "histogram" | "unknown"} kind
 * @property {number} value
 * @property {Record<string, string>} labels
 */

/**
 * A fact passed to a call: not live in this engine, so no Fact, but its
 * schema, the UTC instant it entered working memory (null when the wall clock
 * had no value then), and its FactExternal bytes.
 * @typedef {{ schema: string, assertedAt: bigint | null, external: Uint8Array }} FactArgument
 */

/**
 * One argument of a call, typed as a slot of its kind reads, except Json: a
 * slot's schema says it is a document, and a call argument has none beside it,
 * so a Json argument is a JsonText and a String one a string.
 * @typedef {bigint | number | string | boolean | null | Uint8Array | JsonText | FactArgument} CallArgument
 */

/**
 * A rule's `call`. `correlation` is the call's `as` value, or the one the
 * compiler generates for a call with none or whose computed `as` renders `""`
 * ([LCRS.3.1]): always a string, never empty. `args` maps each argument the
 * call supplies to its value.
 * @typedef {object} CallRequest
 * @property {string} service
 * @property {string} correlation
 * @property {Record<string, CallArgument>} args
 * @property {bigint} timetag
 * @property {string} ruleName
 */

/**
 * One write the rules made to the cache: the value as canonical JSON text,
 * and its TTL in ns, 0 for none.
 * @typedef {{ key: string, value: string | null, ttlNs: bigint }} CacheWrite
 */

/**
 * One entry leaving the cache: by a rule's `cache_delete`, or its TTL.
 * @typedef {{ key: string, reason: "delete" | "ttl" }} CacheRemoval
 */

/**
 * The cache's write-through: `set` hears each write, `delete` each removal.
 * One left out, or null, hears nothing.
 * @typedef {object} WriteThrough
 * @property {((write: CacheWrite) => void) | null} [set]
 * @property {((removal: CacheRemoval) => void) | null} [delete]
 */

/**
 * One observable event of the engine, in `seq` order.
 * @typedef {StreamEventOf<Fact>} StreamEvent
 */

/**
 * A stream event with facts as `F`. The kinds are the names
 * runtime/src/bindings/ds_names.h gives every binding.
 * @template F
 * @typedef {{ seq: bigint, clockNs: bigint } & (
 *     | { kind: "fact_assert" | "fact_retract" | "fact_modify" | "action_emit", fact: F }
 *     | { kind: "action_publish", schema: string, slots: Record<string, SlotValueOf<F>>,
 *         external: Uint8Array }
 *     | { kind: "rule_fire_begin" | "rule_fire_end", ruleName: string, timetag: bigint }
 *     | { kind: "rule_lhs_facts", ruleName: string, lhsFacts: F[], timetag: bigint }
 *     | { kind: "action_log" } & LogRecord
 *     | { kind: "action_cache_set", key: string, valueJson: string | null, ttlNs: bigint }
 *     | { kind: "action_cache_get", key: string, valueJson: string | null }
 *     | { kind: "action_cache_delete", key: string }
 *     | { kind: "action_call" } & CallRequest
 *     | { kind: "timer_armed", ruleName: string, timerKind: string, windowNs: bigint, fireAtNs: bigint,
 *         timetag: bigint }
 *     | { kind: "timer_fired", ruleName: string, timerKind: string }
 *     | { kind: "type_error", nodeId: number, schemaName: string | null, slotName: string | null,
 *         actual: string | null, ruleName: string }
 *     | { kind: "bounds_error", cap: number, limit: bigint, observed: bigint, ruleName: string | null,
 *         timetag: bigint }
 *     | { kind: "engine_error", engineFault: number, nodeId: number, ruleName: string }
 *     | { kind: "computation_error", trapKind: number, ruleName: string, timetag: bigint,
 *         schemaName: string | null, slotName: string | null, factId: bigint, nodeId: number }
 *     | { kind: "tick", wallNs: bigint | null }
 *     | { kind: "pump" | "unknown" }
 * )} StreamEventOf
 */

/** @typedef {StreamEvent["kind"]} StreamEventKind */

/**
 * A stream record as the event the engine dispatches for it: its kind is the
 * event's `type`, and its other fields are the event's.
 * @template R
 * @typedef {R extends { kind: infer K } ? EngineEvent & Omit<R, "kind"> & { readonly type: K } : never} AsEngineEvent
 */

/**
 * The event an Engine dispatches for one stream event, of any kind.
 * @typedef {AsEngineEvent<StreamEvent>} StreamEngineEvent
 */

/** @typedef {EngineEvent & LogRecord & { readonly type: "log" }} LogEngineEvent */

/** @typedef {EngineEvent & Metric & { readonly type: "metric" }} MetricEngineEvent */

/**
 * The events an Engine dispatches, by type: what a listener added for each
 * is given.
 * @typedef {{ [K in StreamEventKind]: StreamEngineEvent & { readonly type: K } }
 *     & { log: LogEngineEvent, metric: MetricEngineEvent }} EngineEventMap
 */

/**
 * Where a throwing callback's exception is reported: the exception, and the
 * callback's name, "call", or the name of one whose argument could not be
 * built ("stream", "log", "metric", "cacheSet", "cacheDelete"). An event
 * listener's exception is not one: the platform reports it, as it reports any
 * listener's. Nor is a handler's: the call that ran it throws it as a
 * DsError's `cause`, or, where no call fails, it is reported as a listener's is.
 * @typedef {(error: unknown, where: string) => void} UnraisableHook
 */

/**
 * How a compile is run: what the source is called, and where its imports are
 * found.
 * @typedef {{ file?: string, searchPath?: string[] }} CompileOptions
 */

/**
 * A compile under wasm (ds_dsc): what `files` holds is what the compile
 * reads by path (each `searchPath` directory's files), and `wasmBinary` is the
 * compiler's `.wasm`, rather than the module fetching it beside itself, or
 * `wasmModule` that `.wasm` compiled already. `program` is the compiler's own
 * path, its argv[0]: it finds the standard library it ships with at `<its
 * directory>/../share/ds/stdlib` ([LIMP.3.3.1]), among `files`.
 * @typedef {CompileOptions & { files?: Record<string, string | Uint8Array>, wasmBinary?: Uint8Array | ArrayBuffer,
 *     wasmModule?: WebAssembly.Module, program?: string }} WasmCompileOptions
 */

/**
 * An emscripten module a page hands over: its factory, the module, or a URL to
 * import it from.
 * @typedef {Function | object | string | URL} ModuleSource
 */

/** @typedef {{ write: (bytes: Uint8Array) => void, close: () => void }} FileSink */

/**
 * What a host gives the API: how `recordTo` opens a path (null where there is
 * no file system, and `recordTo` then takes only a sink), and the compiler,
 * whose runner may be async (ds_dsc's is).
 * @typedef {object} Host
 * @property {((path: string) => FileSink) | null} file
 * @property {(source: string, options?: never) => Uint8Array | Promise<Uint8Array>} compile
 * @property {(path: string, options?: never) => Uint8Array | Promise<Uint8Array>} compileFile
 */

/**
 * `fromSource` for a host's compiler: an Engine where compiling is
 * synchronous, a Promise of one where it is not.
 * @template {Host["compile"]} C
 * @typedef {(source: string, options?: Parameters<C>[1]) =>
 *     ReturnType<C> extends Promise<Uint8Array> ? Promise<Engine> : Engine} FromSource
 */

/**
 * The API over this realm's libds, for the host `H` that opened it.
 * @template {Host} H
 * @typedef {object} Api
 * @property {Target} target
 * @property {typeof Engine} Engine
 * @property {typeof Fact} Fact
 * @property {typeof JsonText} JsonText
 * @property {typeof EngineEvent} EngineEvent
 * @property {readonly StreamEventKind[]} STREAM_EVENT_KINDS  every stream event kind: an Engine's stream
 *   event types
 * @property {typeof DsError} DsError
 * @property {typeof CompileRefused} CompileRefused
 * @property {typeof status} status
 * @property {(fn: UnraisableHook | null) => UnraisableHook} setUnraisableHook
 *   replace where a throwing callback's exception is reported; null restores
 *   the default, which prints to stderr; returns the previous hook
 * @property {H["compile"]} compile
 * @property {H["compileFile"]} compileFile
 * @property {FromSource<H["compile"]>} fromSource
 * @property {(bytes: Uint8Array, options?: { incremental?: boolean }) => AtomsRead} readAtoms
 * @property {(field: number) => string | null} messageName
 * @property {(slots: AnnouncedSlot[], body: Uint8Array) => Record<string, SlotValue>} decodeAnnouncedFactBody
 * @property {(slots: AnnouncedSlot[], body: Uint8Array) => AnnouncedBody} decodeAnnouncedFactBodyHandles
 */

export {};
