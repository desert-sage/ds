// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The `.dstest` interpreter ([RTIM.14]): the test cases a compiled `.dsc`
// carries, each run on a fresh engine on the mock clock and checked against its
// assertions. `ds test` (cli/main.js) runs it on libds, with no Python.
//
// It decodes no atom itself: libds reads every Test* and Oracle* atom
// (@ds-lang/ds's `readAtoms`, DSDB.md §1). It evaluates no predicate itself: a
// `where` is the compiler's oracle rule, matched by the engine ([RTIM.14.8],
// [RTIM.14.11]). An assertion it cannot evaluate fails the case that carries
// it, by name, and is never skipped ([RTIM.14.9]). Test atoms it cannot read
// refuse the run before any case runs ([RTIM.14.15]), and a step the engine
// refuses fails the case and stops it ([RTIM.14.14]). Nothing here prints or
// does I/O.

/** @import { AtomBody, AtomEnum, CallArgument, DsError, Engine, SlotValue, StreamEngineEvent, StreamEventKind } from "@ds-lang/ds" */
/** @import { Ds } from "./types.js" */

/** The prefix of the rule the compiler synthesizes for a `where` ([RTIM.14.13]):
    a synthetic name ([LLEX.10.6.1]), so no author rule shares it. */
export const ORACLE_RULE = "$dstest_oracle_";

/**
 * A TestSlotLiteral's value, by its kind: Int and Duration as BigInt, Float as
 * a Number, Json as its text. `none` is a literal with no value.
 * @typedef {{ kind: "int" | "duration", value: bigint } | { kind: "float", value: number }
 *   | { kind: "string" | "json", value: string } | { kind: "bool", value: boolean } | { kind: "none" }} Literal
 */

/** @typedef {Array<[string, Literal]>} Slots  slot literals by name, in the order the atom gives them */

/**
 * One constructed fact: an `initial` arrange fact or a timeline input.
 * @typedef {{ initial: boolean, whenNs: bigint, schema: string, slots: Slots, order: number }} TestFact
 */

/**
 * A `for call` stub ([LTSL.7.2]) and its replies, in reply order.
 * @typedef {{ id: number, service: string, correlation: string, argMatch: Slots, afterNs: bigint,
 *     noResponse: boolean, replies: Array<{ schema: string, slots: Slots, order: number }> }} Stub
 */

/**
 * One assertion, by its head ([LTSL.8.2]).
 * @typedef {{ head: "activated", rule: string }
 *   | { head: "emitted" | "published", schema: string, slots: Slots, where: boolean }
 *   | { head: "retracted" | "wm has", schema: string, slots: Slots }
 *   | { head: "called", service: string, correlation: string | null }
 *   | { head: "cached", key: string, value: Literal | null }
 *   | { head: "cache_deleted", key: string }
 *   | { head: "logged", level: string, text: string | null }
 *   | { head: "wm count", schema: string, count: number }
 *   | { head: "wm empty" }} Assertion
 */

/**
 * An assertion as a case carries it: `never` for the NEVER polarity, and
 * `index`, its position among the case's oracle atoms, which names its oracle
 * rule ([RTIM.14.13]).
 * @typedef {Assertion & { never: boolean, index: number }} Oracle
 */

/**
 * One test case, as its atoms state it. `unread` names what fails it before it
 * runs: each atom under its test_id this interpreter cannot evaluate. `undriven`
 * names each scenario atom it carries with a field this interpreter does not
 * know: the case is not driven at all, since driving it would run the atom as
 * though the field were absent ([RTIM.14.9]).
 * @typedef {object} TestCase
 * @property {number} testId
 * @property {string} name
 * @property {number} moduleId  the module whose test it is ([LTSL.2.4]), its DsSource's `module_id`
 * @property {bigint} untilNs  0n for none
 * @property {boolean} absolute  absolute time, `calendar.time` coordinates ([LTSL.3.2])
 * @property {TestFact[]} facts
 * @property {Array<{ key: string, value: Literal }>} seeds
 * @property {Stub[]} stubs  in stub_id order
 * @property {Oracle[]} oracles  in atom order
 * @property {string[]} unread
 * @property {string[]} undriven
 */

/**
 * What one assertion observed: how many matches over the run, or for `wm
 * count` and `wm empty` how many live facts at the end; and the verdict.
 * @typedef {{ oracle: Oracle, observed: number, ok: boolean }} Verdict
 */

/**
 * One fault event the case's engine raised ([NCBK.2.8]), as [RTIM.14.16]
 * reports it: its kind, the mock clock's instant at the step that raised it,
 * the rule whose activation it abandoned where the event names one, and what
 * the event gives of its cause.
 * @typedef {{ kind: "TypeError" | "BoundsError" | "EngineError" | "ComputationError", atNs: bigint,
 *     rule: string | null, cause: string }} Fault
 */

/**
 * A case's result. It passed when every verdict is ok and `failures` is empty:
 * an assertion it could not read, a call no stub answers, a step the engine
 * refused. `faults` is every fault event the run met, in stream order; a
 * fault fails nothing by itself ([RTIM.14.16]).
 * @typedef {{ testId: number, name: string, moduleId: number, verdicts: Verdict[], failures: string[],
 *     faults: Fault[], passed: boolean }} CaseResult
 */

/**
 * One source module a compiled `.dsc` carries ([RDSC.14.2]): the name its
 * DsSource gives it, its text as compiled, and the `module_id` its test cases
 * carry.
 * @typedef {{ moduleId: number, file: string, data: Uint8Array }} SourceModule
 */

/**
 * A `.dsc` this interpreter refuses to run ([RTIM.14.15]): no case ran. `code`
 * is the status's name, `DS_ERR_DSC_DECODE` or `DS_ERR_DSC_DANGLING`.
 */
export class DstestError extends Error {
    /**
     * @param {"DS_ERR_DSC_DECODE" | "DS_ERR_DSC_DANGLING"} code
     * @param {string} detail  names the atom
     */
    constructor(code, detail) {
        super(`${code}: ${detail}`);
        this.code = code;
    }
}

/**
 * Every test case a compiled `.dsc` carries, in test_id order. Throws
 * DstestError over a body that does not decode, and then over an atom that names
 * a test or a stub no atom declares: bodies before names, as a load checks them
 * ([RTIM.14.15], [RDSC.8.7]).
 * @param {Ds} ds
 * @param {Uint8Array} dsc
 * @returns {TestCase[]}
 */
export function decodeCases(ds, dsc) {
    const r = ds.readAtoms(dsc);
    if (r.error !== null)
        throw new DstestError("DS_ERR_DSC_DECODE", `${stoppedAt(r.error)} does not decode: ${r.error.detail}`);
    /** @type {Set<number>} test_ids a TestCase atom declares */
    const tests = new Set();
    /** @type {Set<number>} stub_ids a TestResponse atom declares */
    const stubIds = new Set();
    for (const a of r.atoms) {
        if (a.body === null) continue;
        if (a.message === "TestCase") tests.add(num(a.body, "test_id"));
        else if (a.message === "TestResponse") stubIds.add(num(a.body, "stub_id"));
    }
    /** @type {Map<number, TestCase>} */
    const cases = new Map();
    /** @type {Map<number, Stub>} */
    const stubs = new Map();
    /** @type {Map<number, number>} stub id -> its case's test_id */
    const stubCase = new Map();
    /** @type {Array<{ stub: number, schema: string, slots: Slots, order: number, unknown: string | null }>} */
    const replies = [];
    /** What fails every case: an atom no test_id can be read from. @type {string[]} */
    const everyCase = [];
    /** @param {number} id */
    const testCase = (id) => {
        let c = cases.get(id);
        if (c === undefined) {
            c = { testId: id, name: "", moduleId: 0, untilNs: 0n, absolute: false, facts: [], seeds: [], stubs: [],
                  oracles: [], unread: [], undriven: [] };
            cases.set(id, c);
        }
        return c;
    };
    /** The case an atom names: refused when no TestCase declares it. @param {string} kind @param {AtomBody} b */
    const member = (kind, b) => {
        const id = num(b, "test_id");
        if (!tests.has(id))
            throw new DstestError("DS_ERR_DSC_DANGLING", `a ${kind} names test_id ${id}, which no TestCase declares`);
        return testCase(id);
    };
    for (const a of r.atoms) {
        if (a.body === null) {
            // [RTIM.14.10]: a reader that skips an atom it cannot read may be
            // skipping an assertion, so it is not skipped.
            everyCase.push(`atom ${a.field}, which this libds cannot read, and which may be an assertion`);
            continue;
        }
        const b = a.body;
        const unknown = a.unknownFields.length ? unknownFields(a.message, a.unknownFields) : null;
        switch (a.message) {
        case "TestCase": {
            const c = testCase(num(b, "test_id"));
            c.name = str(b, "name");
            c.moduleId = num(b, "module_id");
            c.untilNs = big(b, "until_ns");
            c.absolute = bool(b, "absolute_time");
            if (unknown !== null) c.undriven.push(unknown);
            break;
        }
        case "TestFact": {
            const c = member(a.message, b);
            c.facts.push({ initial: bool(b, "is_initial"), whenNs: big(b, "when_ns"), schema: str(b, "schema_name"),
                           slots: slots(b, "slots"), order: num(b, "source_order") });
            if (unknown !== null) c.undriven.push(unknown);
            break;
        }
        case "TestCacheSeed": {
            const c = member(a.message, b);
            c.seeds.push({ key: str(b, "key"), value: literal(message(b, "value")) });
            if (unknown !== null) c.undriven.push(unknown);
            break;
        }
        case "TestResponse": {
            const id = num(b, "stub_id");
            const c = member(a.message, b);
            stubs.set(id, { id, service: str(b, "service"), correlation: str(b, "correlation"),
                            argMatch: slots(b, "arg_match"), afterNs: big(b, "after_ns"),
                            noResponse: bool(b, "no_response"), replies: [] });
            stubCase.set(id, c.testId);
            if (unknown !== null) c.undriven.push(unknown);
            break;
        }
        case "TestReply": {
            const stub = num(b, "stub_id");
            if (!stubIds.has(stub))
                throw new DstestError("DS_ERR_DSC_DANGLING", `a TestReply names stub_id ${stub}, which no TestResponse declares`);
            replies.push({ stub, schema: str(b, "schema_name"), slots: slots(b, "slots"),
                           order: num(b, "reply_order"), unknown });
            break;
        }
        default:
            if (a.message !== null && a.message.startsWith("Oracle")) {
                const c = member(a.message, b);
                const index = c.oracles.length + c.unread.length;
                // An atom is understood only whole ([RTIM.14.9]): one with a
                // field unknown here is not evaluated as its bare head.
                const o = unknown ?? oracle(a.message, b);
                if (typeof o === "string") c.unread.push(o);
                else c.oracles.push({ ...o.assertion, never: o.never, index });
            }
            // Every other atom is the program, which the engine loads.
        }
    }
    for (const rp of replies) {
        /** @type {Stub} */ (stubs.get(rp.stub)).replies.push({ schema: rp.schema, slots: rp.slots, order: rp.order });
        if (rp.unknown !== null) testCase(/** @type {number} */ (stubCase.get(rp.stub))).undriven.push(rp.unknown);
    }
    for (const [id, stub] of [...stubs].sort((x, y) => x[0] - y[0])) {
        stub.replies.sort((x, y) => x.order - y.order);
        testCase(/** @type {number} */ (stubCase.get(id))).stubs.push(stub);
    }
    for (const c of cases.values()) c.unread.push(...everyCase);
    return [...cases.values()].sort((x, y) => x.testId - y.testId);
}

/**
 * A test atom with fields this interpreter does not know, named with each
 * field's number ([RTIM.14.9]).
 * @param {string | null} message
 * @param {number[]} fields  at any depth, in the order read
 */
function unknownFields(message, fields) {
    return `${message} with unknown field${fields.length > 1 ? "s" : ""} ${fields.join(", ")}`;
}

/**
 * The atom a read stopped at, as `readAtoms`'s error names it: by its field and
 * message at a body ([RTIM.14.15]), and only by where it starts at framing,
 * where the error names no atom.
 * @param {{ offset: number, field: number | null, message: string | null }} error
 */
function stoppedAt({ offset, field, message }) {
    if (field === null) return `the atom at byte ${offset}`;
    return `${message ?? "an atom"} (field ${field}) at byte ${offset}`;
}

/**
 * Run every case a compiled `.dsc` carries ([RTIM.14.1]). Throws
 * DstestError, with no case run, over test atoms it cannot read ([RTIM.14.15]).
 * @param {Ds} ds
 * @param {Uint8Array} dsc
 * @returns {CaseResult[]}
 */
export function runAll(ds, dsc) {
    return decodeCases(ds, dsc).map((c) => runCase(ds, dsc, c));
}

/**
 * The source modules a compiled `.dsc` carries, one per DsSource atom, in
 * stream order ([RDSC.14.2.4]). Throws DstestError when the `.dsc` does not
 * read.
 * @param {Ds} ds
 * @param {Uint8Array} dsc
 * @returns {SourceModule[]}
 */
export function sourceModules(ds, dsc) {
    const r = ds.readAtoms(dsc);
    if (r.error !== null)
        throw new DstestError("DS_ERR_DSC_DECODE", `${stoppedAt(r.error)} does not decode: ${r.error.detail}`);
    /** @type {SourceModule[]} */
    const out = [];
    for (const a of r.atoms) {
        if (a.message !== "DsSource" || a.body === null) continue;
        const data = a.body.data;
        out.push({ moduleId: num(a.body, "module_id"), file: str(a.body, "file"),
                   data: data instanceof Uint8Array ? data : new Uint8Array() });
    }
    return out;
}

/**
 * Run one case on a fresh engine ([RTIM.14.2]) and check every assertion it
 * carries over the whole run ([RTIM.14.7]).
 * @param {Ds} ds
 * @param {Uint8Array} dsc
 * @param {TestCase} c
 * @returns {CaseResult}
 */
export function runCase(ds, dsc, c) {
    if (c.undriven.length)
        return { testId: c.testId, name: c.name, moduleId: c.moduleId, verdicts: [],
                 failures: [...c.unread, ...c.undriven], faults: [], passed: false };
    const e = new ds.Engine();
    try {
        const run = new Run(ds, e, c);
        /** @type {string[]} */
        const failures = [...c.unread];
        try {
            run.drive(dsc);
        } catch (err) {
            // The run stops where it was refused ([RTIM.14.14]); the verdicts
            // below are over what it saw until then, and the case fails either
            // way.
            if (err instanceof Refused) failures.push(err.message);
            else throw err;
        }
        // A halted engine answers no read of its state ([NCBK.2.9]), so what
        // only working memory or its rule table could answer has no verdict;
        // the halt fails the case.
        const halted = e.halted !== null;
        if (halted) failures.push(`the engine halted (status ${e.halted})`);
        const seen = halted ? c.oracles.filter((o) => !END_OF_RUN.has(o.head)) : c.oracles;
        const verdicts = seen.map((o) => run.verdict(o));
        if (!halted) {
            for (const o of c.oracles) {
                const missing = run.missingOracleRule(o);
                if (missing !== null) failures.push(missing);
            }
        }
        failures.push(...run.unaccounted());
        return { testId: c.testId, name: c.name, moduleId: c.moduleId, verdicts, failures, faults: run.faults(),
                 passed: failures.length === 0 && verdicts.every((v) => v.ok) };
    } finally {
        e.close();
    }
}

// ── reading the atoms ───────────────────────────────────────────────────────

/** @param {AtomBody} b @param {string} k */
function str(b, k) {
    const v = b[k];
    return typeof v === "string" ? v : "";
}

/** A 64-bit field. @param {AtomBody} b @param {string} k */
function big(b, k) {
    const v = b[k];
    return typeof v === "bigint" ? v : 0n;
}

/** A 32-bit field, which fits a Number. @param {AtomBody} b @param {string} k */
function num(b, k) {
    return Number(big(b, k));
}

/** @param {AtomBody} b @param {string} k */
function bool(b, k) {
    return b[k] === true;
}

/** A message field, or null when it is absent. @param {AtomBody} b @param {string} k @returns {AtomBody | null} */
function message(b, k) {
    const v = b[k];
    return v !== undefined && typeof v === "object" && !Array.isArray(v) && !(v instanceof Uint8Array)
        && !isEnum(v) ? v : null;
}

/** @param {object} v @returns {v is AtomEnum} */
function isEnum(v) {
    return "number" in v && typeof v.number === "number";
}

/** An enum field's number, or null when it is absent. @param {AtomBody} b @param {string} k */
function enumNumber(b, k) {
    const v = b[k];
    return v !== undefined && typeof v === "object" && !Array.isArray(v) && isEnum(v) ? v.number : null;
}

/** An enum field's name, or null. @param {AtomBody} b @param {string} k */
function enumName(b, k) {
    const v = b[k];
    return v !== undefined && typeof v === "object" && !Array.isArray(v) && isEnum(v) ? v.name : null;
}

/**
 * A repeated TestSlotLiteral field, as slot literals by name. The reader
 * leaves out a repeated field with no elements.
 * @param {AtomBody} b
 * @param {string} k
 * @returns {Slots}
 */
function slots(b, k) {
    const v = b[k];
    if (!Array.isArray(v)) return [];
    /** @type {Slots} */
    const out = [];
    for (const item of v) {
        if (typeof item === "object" && !(item instanceof Uint8Array) && !isEnum(item)) {
            const lit = /** @type {AtomBody} */ (item);
            out.push([str(lit, "slot_name"), literal(lit)]);
        }
    }
    return out;
}

/**
 * A TestSlotLiteral's value: the oneof member that is set, which is the only
 * one the reader visits.
 * @param {AtomBody | null} b
 * @returns {Literal}
 */
function literal(b) {
    if (b === null) return { kind: "none" };
    if (typeof b.i_val === "bigint") return { kind: "int", value: b.i_val };
    if (typeof b.f_val === "number") return { kind: "float", value: b.f_val };
    if (typeof b.s_val === "string") return { kind: "string", value: b.s_val };
    if (typeof b.b_val === "boolean") return { kind: "bool", value: b.b_val };
    if (typeof b.d_val === "bigint") return { kind: "duration", value: b.d_val };
    if (typeof b.j_val === "string") return { kind: "json", value: b.j_val };
    return { kind: "none" };
}

/** TestPolarity's numbers (proto/test_oracle.proto). */
const POS = 1, NEVER = 2;

/** OracleWorkingMemory.Mode's numbers. */
const MODE = new Map([[1, "wm has"], [2, "wm count"], [3, "wm empty"]]);

/**
 * One oracle atom as an assertion and its polarity, or, when this interpreter
 * cannot evaluate it as written, a sentence naming it ([RTIM.14.9]).
 * @param {string} name  the atom's message
 * @param {AtomBody} b
 * @returns {{ assertion: Assertion, never: boolean } | string}
 */
function oracle(name, b) {
    const polarity = enumNumber(b, "polarity");
    if (polarity !== POS && polarity !== NEVER) return `${name} with polarity ${polarity ?? "absent"}`;
    // `exactly N` ([LTSL.8.7]) is deferred: read as the bare head, it would
    // pass a case that asserts more than it checks.
    const occurrence = big(b, "occurrence");
    if (occurrence !== 0n) return `${name} with \`exactly ${occurrence}\`, which this runner does not evaluate`;
    const never = polarity === NEVER;
    /** @param {Assertion} assertion */
    const ok = (assertion) => ({ assertion, never });
    switch (name) {
    case "OracleActivated":
        return ok({ head: "activated", rule: str(b, "rule_name") });
    case "OracleEmit":
    case "OraclePublish": {
        // where_expr_id is reserved and unassigned ([RTIM.14.11]): one that is
        // set means something this interpreter was not written for.
        if (big(b, "where_expr_id") !== 0n) return `${name} with where_expr_id ${big(b, "where_expr_id")}`;
        const match = slots(b, "slot_match");
        const where = bool(b, "has_where");
        // [RTIM.14.7]: slot arguments or a `where`, never both
        // ([LTSL.8.4]). No conforming compiler writes the pair, so it fails the
        // case, named, and neither half is checked alone: the `where` count
        // below never reads the slots, so checking it would pass an assertion
        // weaker than the one written.
        if (where && match.length)
            return `${name} for ${str(b, "schema_name")} (test_id ${num(b, "test_id")}) with both slot_match `
                + "and a where predicate, which no conforming compiler writes ([LTSL.8.4])";
        return ok({ head: name === "OracleEmit" ? "emitted" : "published", schema: str(b, "schema_name"),
                    slots: match, where });
    }
    case "OracleRetract":
        return ok({ head: "retracted", schema: str(b, "schema_name"), slots: slots(b, "slot_match") });
    case "OracleCall":
        // `called` matches by service and correlation; argument equality is
        // the stub's ([LTSL.8.4]).
        if (slots(b, "arg_match").length) return `${name} with argument keys, which \`called\` does not take`;
        return ok({ head: "called", service: str(b, "service"),
                    correlation: bool(b, "has_correlation") ? str(b, "correlation") : null });
    case "OracleCacheSet":
        return ok({ head: "cached", key: str(b, "key"),
                    value: bool(b, "has_value") ? literal(message(b, "value_match")) : null });
    case "OracleCacheDelete":
        return ok({ head: "cache_deleted", key: str(b, "key") });
    case "OracleLog": {
        // The level's one definition is proto/log_level.proto; a
        // number it names nothing for matches no event, and a `never` would
        // pass on an empty assertion.
        const level = enumName(b, "severity");
        if (level === null || !level.startsWith("LOG_SEVERITY_"))
            return `${name} with severity ${enumNumber(b, "severity") ?? "absent"}`;
        return ok({ head: "logged", level: level.slice("LOG_SEVERITY_".length),
                    text: bool(b, "has_msg") ? str(b, "msg_substr") : null });
    }
    case "OracleWorkingMemory": {
        const mode = MODE.get(enumNumber(b, "mode") ?? 0);
        if (mode === "wm has") return ok({ head: mode, schema: str(b, "schema_name"), slots: slots(b, "slot_match") });
        if (mode === "wm count") return ok({ head: mode, schema: str(b, "schema_name"), count: num(b, "count") });
        if (mode === "wm empty") return ok({ head: mode });
        return `${name} with mode ${enumNumber(b, "mode") ?? "absent"}`;
    }
    default:
        // OracleExclusive ([LTSL.8.8], deferred), and any oracle added after
        // this was written.
        return name;
    }
}

// ── running a case ──────────────────────────────────────────────────────────

/** A case that cannot go on: an input the runner cannot construct, or a step the engine refused. */
class Refused extends Error {}

/** The heads read from working memory at the end of the run. */
const END_OF_RUN = new Set(["wm has", "wm count", "wm empty"]);

/**
 * A fact the run emitted, published or retracted, with its slots as they were
 * at that moment.
 * @typedef {{ kind: "emitted" | "published" | "retracted", schema: string, slots: Record<string, SlotValue> }}
 *   FactSeen
 */

/** @typedef {{ service: string, correlation: string | null, args: Record<string, CallArgument> }} CallMade */

/** The stream events the run observes ([RTIM.14.1]). @type {StreamEventKind[]} */
const OBSERVED = ["fact_assert", "fact_retract", "rule_lhs_facts", "rule_fire_begin", "rule_fire_end",
                  "action_emit", "action_publish", "action_call", "action_cache_set", "action_cache_delete",
                  "action_log", "type_error", "bounds_error", "engine_error", "computation_error"];

// What a fault event gives of its cause by number, as its proto names it with
// the prefix dropped: `TrapKind` (proto/engine_error.proto, [LERR.1.4.9]),
// `CapName` (proto/bounds_error.proto) and `EngineFault`
// (proto/engine_fault.proto). The stream event carries the number alone. A
// number with no row is written as the number. dstest.test.mjs holds each
// table to its proto.
/** @type {ReadonlyMap<number, string>} */
export const TRAP_KINDS = new Map([[1, "DIVIDE_BY_ZERO"], [2, "DOMAIN"], [3, "NOT_REPRESENTABLE"]]);
/** @type {ReadonlyMap<number, string>} */
export const CAP_NAMES = new Map([[1, "WM_MAX"], [2, "AGENDA"], [3, "MAX_FIRES_PER_PUMP"], [4, "TOKEN_POOL"],
                                  [5, "INTERN"], [6, "INTERN_BYTES"], [7, "PUMP_WCET_NS"], [8, "CACHE"],
                                  [9, "CACHE_BYTES"], [10, "NODE_CAPACITY"], [11, "SERIES_CAPACITY"],
                                  [12, "VALUE_CAPACITY"]]);
/** @type {ReadonlyMap<number, string>} */
export const ENGINE_FAULTS = new Map([[1, "ARTEFACT_LIED"], [2, "PATTERN_INDEX"], [3, "BINDING_ORDER"],
                                      [4, "ORDER_KEY"], [6, "ALLOCATION"], [7, "PUMP_WCET"]]);

/**
 * A fault event as [RTIM.14.16] reports it.
 * @param {StreamEngineEvent} ev  one of the four fault kinds ([NCBK.2.8])
 * @param {bigint} atNs  the mock clock when the engine raised it
 * @returns {Fault | null}  null for any other kind
 */
export function faultOf(ev, atNs) {
    /** @param {ReadonlyMap<number, string>} names @param {number} n @param {string} what */
    const named = (names, n, what) => names.get(n) ?? `${what} ${n}`;
    /** @param {string | null} schema @param {string | null} slot */
    const site = (schema, slot) => (schema && slot ? `${schema}.${slot}` : schema ?? slot ?? null);
    switch (ev.type) {
    case "computation_error": {
        const at = site(ev.schemaName, ev.slotName);
        return { kind: "ComputationError", atNs, rule: ev.ruleName || null,
                 cause: named(TRAP_KINDS, ev.trapKind, "kind") + (at ? ` at ${at}` : "") };
    }
    case "type_error": {
        const at = site(ev.schemaName, ev.slotName);
        return { kind: "TypeError", atNs, rule: ev.ruleName || null,
                 cause: (at ?? "a value") + (ev.actual ? `, given ${ev.actual}` : "") };
    }
    case "bounds_error":
        return { kind: "BoundsError", atNs, rule: ev.ruleName || null,
                 cause: `${named(CAP_NAMES, ev.cap, "cap")} (limit ${ev.limit}, observed ${ev.observed})` };
    case "engine_error":
        return { kind: "EngineError", atNs, rule: ev.ruleName || null,
                 cause: named(ENGINE_FAULTS, ev.engineFault, "fault") };
    default:
        return null;
    }
}

/** One case's run on its engine: the timeline driven, and what was seen. */
class Run {
    /** @type {Ds} */
    #ds;
    /** @type {Engine} */
    #e;
    /** @type {TestCase} */
    #c;
    /** Where the case's clock starts: 0, or its first absolute instant. */
    #startNs = 0n;
    /** The mock monotonic clock, as the last move set it. */
    #clockNs = 0n;
    /** The program's schemas, once it has loaded. @type {Engine["schemas"] | null} */
    #schemas = null;
    /** The program's rules that fired, once per firing. @type {string[]} */
    #fired = [];
    /** @type {FactSeen[]} */
    #factsSeen = [];
    /** @type {Array<{ key: string, valueJson: string | null }>} */
    #cacheSets = [];
    /** @type {string[]} */
    #cacheDeletes = [];
    /** @type {Array<{ level: string, message: string }>} */
    #logs = [];
    /** Every fault event the engine raised, in stream order ([RTIM.14.16]). @type {Fault[]} */
    #faults = [];
    /** @type {Map<bigint, string>} live fact id -> its schema, from the stream */
    #live = new Map();
    /** @type {Map<string, bigint[]>} oracle rule -> the facts it matched, each firing */
    #oracleFires = new Map();
    /** @type {Set<bigint>} */
    #emitted = new Set();
    /** Inside an oracle rule's firing, whose effects are not the program's ([RTIM.14.7]). */
    #inOracle = false;
    /** @type {CallMade[]} */
    #calls = [];
    #answered = 0;
    /** @type {CallMade[]} */
    #unaccounted = [];
    /**
     * Replies an `after` delays ([LTSL.7.4]), by deadline and then call order
     * ([RTIM.14.6]).
     * @type {Array<{ atNs: bigint, seq: number, call: CallMade, stub: Stub }>}
     */
    #scheduled = [];
    #seq = 0;

    /**
     * @param {Ds} ds
     * @param {Engine} e
     * @param {TestCase} c
     */
    constructor(ds, e, c) {
        this.#ds = ds;
        this.#e = e;
        this.#c = c;
    }

    /**
     * The case, run: load, arrange, then the timeline to its end ([RTIM.14.3]
     * to [RTIM.14.6]). Throws Refused at the first step refused ([RTIM.14.14]).
     * @param {Uint8Array} dsc
     */
    drive(dsc) {
        const e = this.#e, c = this.#c;
        const timeline = c.facts.filter((f) => !f.initial);
        // [LTSL.3.2]: an absolute coordinate sets the wall clock to its instant
        // and moves the monotonic clock by the interval since the last, so the
        // monotonic clock starts at 0 at the first one.
        if (c.absolute) {
            const instants = timeline.map((f) => f.whenNs);
            if (c.untilNs !== 0n) instants.push(c.untilNs);
            if (instants.length) this.#startNs = instants.reduce((a, b) => (b < a ? b : a));
        }
        this.#step("clock mode", () => { e.clock.mode = "mock"; });
        this.#setClocks(this.#startNs);
        // Listening first, so working memory includes whatever the load puts
        // there.
        this.#step("listening", () => this.#listen());
        this.#step("load", () => {
            e.loadDsc(dsc);
            // A snapshot, which a halted engine's facts are still matched by.
            this.#schemas = e.schemas;
        });
        // Arrange, before the timeline and unobserved ([RTIM.14.4]): a seed is
        // not a cache write, and the engine takes one only before the first
        // pump.
        for (const s of c.seeds) {
            const json = seedJson(s.value);
            this.#step(`cache seed ${s.key}`, () => e.cache.seed(s.key, json));
        }
        for (const f of c.facts) if (f.initial) this.#put("arrange assert", f.schema, f.slots, this.#startNs, null);

        /** @type {Map<bigint, TestFact[]>} */
        const byStamp = new Map();
        for (const f of timeline) {
            const at = byStamp.get(f.whenNs);
            if (at) at.push(f);
            else byStamp.set(f.whenNs, [f]);
        }
        const stamps = [...byStamp.keys()];
        if (c.untilNs !== 0n && !byStamp.has(c.untilNs)) stamps.push(c.untilNs);
        stamps.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
        if (!stamps.length) stamps.push(this.#startNs);     // arrange only: one pump to quiescence

        // [RTIM.14.5]: the clock moves across the input stamps, `until` and
        // each delayed reply's deadline, found as its call is made. At a shared
        // instant the inputs go before the replies.
        let i = 0;
        while (i < stamps.length || this.#scheduled.length) {
            const nextInput = i < stamps.length ? stamps[i] : null;
            const nextReply = this.#scheduled.length ? this.#scheduled[0].atNs : null;
            const t = nextInput === null ? /** @type {bigint} */ (nextReply)
                : nextReply === null || nextInput <= nextReply ? nextInput : nextReply;
            this.#setClocks(t);
            if (t === nextInput) {
                for (const f of [...(byStamp.get(t) ?? [])].sort((x, y) => x.order - y.order))
                    this.#put("input assert", f.schema, f.slots, t, null);
                i++;
            }
            while (this.#scheduled.length && this.#scheduled[0].atNs === t) {
                const due = /** @type {{ call: CallMade, stub: Stub }} */ (this.#scheduled.shift());
                this.#reply(due.call, due.stub, t);
            }
            this.#pump(t);
            this.#answer(t);
        }
    }

    /**
     * One operation that drives the case. Anything but success fails the case
     * there, naming the operation and its status ([RTIM.14.14]).
     * @template T
     * @param {string} what
     * @param {() => T} op
     * @returns {T}
     */
    #step(what, op) {
        try {
            return op();
        } catch (err) {
            if (!(err instanceof Error) || err.name !== "DsError") throw err;
            const { status, detail } = /** @type {DsError} */ (err);
            const name = Object.entries(this.#ds.status).find(([, n]) => n === status)?.[0] ?? `status ${status}`;
            throw new Refused(`${what} refused: ${name}${detail ? `: ${detail}` : ""}`);
        }
    }

    /** @param {bigint} stampNs */
    #pump(stampNs) {
        this.#step(`pump at ${stampNs}`, () => this.#e.pump());
    }

    /**
     * One assertion's verdict over the whole run ([RTIM.14.7], [LTSL.8.6]).
     * @param {Oracle} o
     * @returns {Verdict}
     */
    verdict(o) {
        if (o.head === "wm count") {
            const n = this.#wm().filter((f) => f.schema === o.schema).length;
            return { oracle: o, observed: n, ok: (n === o.count) !== o.never };
        }
        if (o.head === "wm empty") {
            const n = this.#wm().length;
            return { oracle: o, observed: n, ok: (n === 0) !== o.never };
        }
        const n = this.#count(o);
        return { oracle: o, observed: n, ok: o.never ? n === 0 : n >= 1 };
    }

    /**
     * The failure an `emitted … where` or `published … where` reports when the
     * program has no oracle rule of its name: counted against a rule that is
     * not there, a `never` would pass on nothing ([RTIM.14.13]).
     * @param {Oracle} o
     * @returns {string | null}
     */
    missingOracleRule(o) {
        if ((o.head !== "emitted" && o.head !== "published") || !o.where) return null;
        const rule = oracleRule(this.#c.testId, o.index);
        return this.#e.rules.has(rule) ? null : `no oracle rule ${rule} in the program for \`${o.head} … where\``;
    }

    /** Every fault event the run met, in stream order, from the load through the last pump ([RTIM.14.16]). */
    faults() {
        return [...this.#faults];
    }

    /** Each outbound call no stub answered ([LTSL.7.6]), as a failure. */
    unaccounted() {
        return this.#unaccounted.map((call) => {
            const as = call.correlation === null ? "" : ` as ${JSON.stringify(call.correlation)}`;
            return `a call no stub answers: ${call.service}${as}`;
        });
    }

    /**
     * Both clocks to a coordinate. The wall clock is the stamp in either mode:
     * an absolute coordinate's instant ([LTSL.3.2]), or a relative one's offset
     * from the Unix epoch, the epoch itself at the start ([LTSL.3.1]).
     * @param {bigint} stampNs
     */
    #setClocks(stampNs) {
        this.#clockNs = stampNs - this.#startNs;
        this.#step(`clock move to ${stampNs}`, () => {
            this.#e.clock.set(this.#clockNs);
            this.#e.clock.setWall(stampNs);
        });
    }

    /** The stream, observed ([RTIM.14.1]): what the assertions read, and every call. */
    #listen() {
        const e = this.#e;
        const on = (/** @type {StreamEngineEvent} */ ev) => this.#observe(ev);
        for (const kind of OBSERVED) e.addEventListener(kind, on);
        // With no call callback libds fails the action; the stream event above
        // is what books the call, so this one does nothing.
        e.setCallCallback(() => {});
    }

    /** @param {StreamEngineEvent} ev */
    #observe(ev) {
        switch (ev.type) {
        case "rule_lhs_facts":
            if (ev.ruleName.startsWith(ORACLE_RULE)) {
                const got = this.#oracleFires.get(ev.ruleName) ?? [];
                got.push(...ev.lhsFacts.map((f) => f.id));
                this.#oracleFires.set(ev.ruleName, got);
            }
            return;
        case "rule_fire_begin":
            if (ev.ruleName.startsWith(ORACLE_RULE)) this.#inOracle = true;
            else this.#fired.push(ev.ruleName);
            return;
        case "rule_fire_end":
            if (ev.ruleName.startsWith(ORACLE_RULE)) this.#inOracle = false;
            return;
        case "type_error":
        case "bounds_error":
        case "engine_error":
        case "computation_error": {
            // Every fault the engine raised ([RTIM.14.16]), at the mock clock
            // of the step being driven: an event is never a time to sample.
            const f = faultOf(ev, this.#clockNs);
            if (f !== null) this.#faults.push(f);
            return;
        }
        }
        if (this.#inOracle) return;
        switch (ev.type) {
        case "fact_assert":
            this.#live.set(ev.fact.id, ev.fact.read().schema);
            break;
        case "fact_retract": {
            // The fact is readable during this event only.
            const f = ev.fact.read();
            this.#factsSeen.push({ kind: "retracted", schema: f.schema, slots: f.slots });
            this.#live.delete(f.id);
            break;
        }
        case "action_emit": {
            const f = ev.fact.read();
            this.#emitted.add(f.id);
            this.#factsSeen.push({ kind: "emitted", schema: f.schema, slots: f.slots });
            break;
        }
        case "action_publish":
            // The event's copy: a publish puts nothing in working memory
            // ([LTIE.4.3]), so there is no fact to read or to number.
            this.#factsSeen.push({ kind: "published", schema: ev.schema, slots: ev.slots });
            break;
        case "action_call":
            this.#calls.push({ service: ev.service, correlation: ev.correlation, args: ev.args });
            break;
        case "action_cache_set":
            this.#cacheSets.push({ key: ev.key, valueJson: ev.valueJson });
            break;
        case "action_cache_delete":
            this.#cacheDeletes.push(ev.key);
            break;
        case "action_log":
            this.#logs.push({ level: ev.level, message: ev.message });
            break;
        }
    }

    /**
     * Answer each call made since the last answer from its stub ([RTIM.14.6]):
     * its replies now, a pump, and again for the calls those make; or later,
     * after `after`; or never, for `no response`.
     * @param {bigint} stampNs  the instant now
     */
    #answer(stampNs) {
        let replied = true;
        while (replied) {
            replied = false;
            while (this.#answered < this.#calls.length) {
                const call = this.#calls[this.#answered++];
                const stub = matchStub(this.#ds, call, this.#c.stubs);
                if (stub === null) this.#unaccounted.push(call);
                else if (stub.noResponse) continue;
                else if (stub.afterNs > 0n) this.#schedule(stampNs + stub.afterNs, call, stub);
                else {
                    this.#reply(call, stub, stampNs);
                    replied = true;
                }
            }
            if (replied) this.#pump(stampNs);
        }
    }

    /**
     * @param {bigint} atNs
     * @param {CallMade} call
     * @param {Stub} stub
     */
    #schedule(atNs, call, stub) {
        const entry = { atNs, seq: this.#seq++, call, stub };
        const at = this.#scheduled.findIndex((s) => s.atNs > atNs);
        if (at < 0) this.#scheduled.push(entry);
        else this.#scheduled.splice(at, 0, entry);
    }

    /**
     * A stub's replies asserted: a reply that writes no `corr` is given the
     * call's ([LTSL.7.2]).
     * @param {CallMade} call
     * @param {Stub} stub
     * @param {bigint} stampNs
     */
    #reply(call, stub, stampNs) {
        for (const r of stub.replies) this.#put("reply assert", r.schema, r.slots, stampNs, call.correlation);
    }

    /**
     * Assert one constructed fact as a host input ([LTSL.6.2]).
     * - A schema that declares `ts` gets the fact's instant: a test input
     *   writes none, and the runner supplies it as a host supplies source time
     *   ([LFAC.9.2]): the wall clock's sample at the fact's coordinate, which
     *   is the stamp in either mode (`#setClocks`).
     * - `corr`, when not null, is the correlation a reply leaves out.
     * @param {string} what  the operation, for a refusal
     * @param {string} schema
     * @param {Slots} lits
     * @param {bigint} stampNs
     * @param {string | null} corr
     */
    #put(what, schema, lits, stampNs, corr) {
        /** @type {Record<string, SlotValue>} */
        const values = {};
        for (const [name, lit] of lits) values[name] = slotValue(lit, schema, name);
        this.#step(`${what} ${schema}`, () => {
            const info = this.#e.schemas.get(schema);
            if (info === undefined) throw new Refused(`the program has no schema ${schema}`);
            const has = (/** @type {string} */ name) => info.slots.some((s) => s.name === name);
            if (corr !== null && has("corr") && !Object.hasOwn(values, "corr")) values.corr = corr;
            if (has("ts") && !Object.hasOwn(values, "ts")) values.ts = stampNs;
            this.#e.assert(schema, values);
        });
    }

    /**
     * Working memory at the end of the run: every fact the stream asserted and
     * did not retract, read now.
     * @returns {Array<{ schema: string, slots: Record<string, SlotValue> }>}
     */
    #wm() {
        /** @type {Array<{ schema: string, slots: Record<string, SlotValue> }>} */
        const out = [];
        for (const id of this.#live.keys()) {
            const f = this.#e.factById(id);
            if (f !== null && f.alive) out.push(f.read());
        }
        return out;
    }

    /**
     * Whether every slot a head names equals the observed fact's ([LTSL.4.2]);
     * the others are free.
     * @param {Slots} want
     * @param {{ schema: string, slots: Record<string, SlotValue> }} fact
     */
    #subset(want, fact) {
        const types = this.#schemas?.get(fact.schema)?.slots;
        return want.every(([k, lit]) => Object.hasOwn(fact.slots, k)
                                        && slotEquals(lit, fact.slots[k], types?.find((s) => s.name === k)?.type));
    }

    /**
     * How many times an occurrence head was observed over the run.
     * @param {Oracle} o
     * @returns {number}
     */
    #count(o) {
        switch (o.head) {
        case "activated":
            return this.#fired.filter((rule) => rule === o.rule).length;
        case "emitted":
        case "published": {
            if (o.where) {
                // A match is the oracle rule firing on a fact this run emitted,
                // not on an input that satisfies it ([RTIM.14.7]). Only an
                // `emitted` head carries one: `published … where` is refused
                // ([LTSL.8.4]), since a publish puts nothing in working memory
                // for an oracle rule to match.
                return (this.#oracleFires.get(oracleRule(this.#c.testId, o.index)) ?? [])
                    .filter((id) => this.#emitted.has(id)).length;
            }
            const head = o.head;
            return this.#factsSeen
                .filter((f) => f.kind === head && f.schema === o.schema && this.#subset(o.slots, f)).length;
        }
        case "retracted":
            return this.#factsSeen
                .filter((f) => f.kind === "retracted" && f.schema === o.schema && this.#subset(o.slots, f)).length;
        case "called":
            return this.#calls.filter((c) => c.service === o.service
                                             && (o.correlation === null || c.correlation === o.correlation)).length;
        case "cached": {
            // A value match is JSON-value equality ([LTSL.8.2]); a literal with
            // no JSON form matches nothing.
            const value = o.value;
            const want = value === null ? null : literalJson(value);
            if (value !== null && want === null) return 0;
            return this.#cacheSets
                .filter((s) => s.key === o.key && (want === null || jsonOf(s.valueJson) === want)).length;
        }
        case "cache_deleted":
            return this.#cacheDeletes.filter((key) => key === o.key).length;
        case "logged":
            return this.#logs.filter((l) => l.level === o.level && (o.text === null || l.message.includes(o.text)))
                .length;
        case "wm has":
            return this.#wm().filter((f) => f.schema === o.schema && this.#subset(o.slots, f)).length;
        default:
            return 0;
        }
    }
}

/**
 * The rule the compiler synthesizes for assertion `index` of test `testId`
 * ([RTIM.14.13]).
 * @param {number} testId
 * @param {number} index
 */
export function oracleRule(testId, index) {
    return `${ORACLE_RULE}${testId}_${index}`;
}

/**
 * The stub that answers a call ([LTSL.7.2]): the first, in stub order, for
 * its service whose correlation, if it names one, is the call's, and whose
 * argument keys the call's arguments all equal.
 * @param {Ds} ds
 * @param {CallMade} call
 * @param {Stub[]} stubs
 * @returns {Stub | null}
 */
export function matchStub(ds, call, stubs) {
    for (const s of stubs) {
        if (s.service !== call.service) continue;
        if (s.correlation !== "" && s.correlation !== call.correlation) continue;
        const args = call.args;
        if (s.argMatch.every(([k, lit]) => Object.hasOwn(args, k) && argEquals(ds, lit, args[k]))) return s;
    }
    return null;
}

/**
 * @param {Ds} ds
 * @param {Literal} lit
 * @param {CallArgument} arg
 */
function argEquals(ds, lit, arg) {
    if (arg instanceof ds.JsonText) return lit.kind === "json" && jsonOf(lit.value) === jsonOf(arg.text);
    if (arg !== null && typeof arg === "object" && !(arg instanceof Uint8Array)) return false;     // a fact
    if (lit.kind === "json") return false;     // a Json argument is a JsonText, so this one is another kind
    return equals(lit, arg);
}

/**
 * A literal against a slot's value ([LTSL.4.3]). A String and a Json slot both
 * read as a JavaScript string, so the slot's type says which kind of value it
 * holds: a `String` literal equals a String slot's only, and a `json()` literal
 * a Json slot's only.
 * @param {Literal} lit
 * @param {SlotValue} v
 * @param {string | undefined} type  the slot's type in its schema
 */
function slotEquals(lit, v, type) {
    if (lit.kind === "string" && type !== "String") return false;
    if (lit.kind === "json" && type !== "Json") return false;
    return equals(lit, v);
}

/**
 * A literal against a value read from the engine, exactly ([LTSL.4.3]): an
 * integer and a Float are equal when they are the same number, and a Json
 * value by JSON value. A value alone does not say whether a string is a String
 * or a Json value: `slotEquals` and `argEquals` settle that first.
 * @param {Literal} lit
 * @param {SlotValue | CallArgument} v
 */
export function equals(lit, v) {
    switch (lit.kind) {
    case "none":
        return v === null;
    case "int":
    case "duration":
        if (typeof v === "bigint") return v === lit.value;
        return typeof v === "number" && Number.isInteger(v) && BigInt(v) === lit.value;
    case "float":
        if (typeof v === "number") return v === lit.value;
        return typeof v === "bigint" && Number.isInteger(lit.value) && BigInt(lit.value) === v;
    case "json":
        return typeof v === "string" && jsonOf(v) !== null && jsonOf(v) === jsonOf(lit.value);
    default:
        return v === lit.value;
    }
}

/**
 * A literal as the slot value the engine takes. A `json()` literal's text
 * must be a JSON value, and a case with one that is not is refused
 * ([LTSL.4.1]).
 * @param {Literal} lit
 * @param {string} schema  for the refusal
 * @param {string} slot
 * @returns {SlotValue}
 */
function slotValue(lit, schema, slot) {
    if (lit.kind === "none") return null;
    if (lit.kind === "json" && jsonOf(lit.value) === null)
        throw new Refused(`${schema}.${slot}: json(${JSON.stringify(lit.value)}) is not a JSON value ([LTSL.4.1])`);
    return lit.value;
}

/**
 * A cache seed's value as the JSON text the cache takes: a `json()` literal's
 * own text, anything else rendered. A Float's shortest round-trip digits.
 * @param {Literal} lit
 * @returns {string}
 */
function seedJson(lit) {
    switch (lit.kind) {
    case "none":
        return "null";
    case "json":
        if (jsonOf(lit.value) === null)
            throw new Refused(`cache seed json(${JSON.stringify(lit.value)}) is not a JSON value ([LTSL.4.1])`);
        return lit.value;
    case "int":
    case "duration":
        return lit.value.toString();
    case "float":
        if (!Number.isFinite(lit.value)) throw new Refused(`cache seed ${lit.value} has no JSON form`);
        return String(lit.value);
    default:
        return JSON.stringify(lit.value);
    }
}

/**
 * A literal as a cache value is compared ([LTSL.8.2]): its canonical JSON
 * (`jsonOf`), or null for a Float with no JSON form, which nothing equals.
 * @param {Literal} lit
 * @returns {string | null}
 */
function literalJson(lit) {
    if (lit.kind === "float" && !Number.isFinite(lit.value)) return null;
    try {
        return jsonOf(seedJson(lit));
    } catch (err) {
        if (err instanceof Refused) return null;
        throw err;
    }
}

// ── JSON-value equality ─────────────────────────────────────────────────────

/**
 * JSON text in a canonical form, so that two texts are equal JSON values
 * exactly when their forms are equal ([LTSL.8.2]): object keys sorted, and a
 * number as its exact decimal value, so that `42` and `42.0` are one number
 * and a 64-bit integer is not rounded through a double. Null for text that is
 * not one JSON value.
 * @param {string | null} text
 * @returns {string | null}
 */
export function jsonOf(text) {
    if (text === null) return "null";
    const p = { s: text, i: 0 };
    try {
        const v = jsonValue(p);
        ws(p);
        return p.i === text.length ? v : null;
    } catch (err) {
        if (err instanceof SyntaxError) return null;
        throw err;
    }
}

/** @typedef {{ s: string, i: number }} Cursor */

/** @param {Cursor} p */
function ws(p) {
    while (p.i < p.s.length && " \t\r\n".includes(p.s[p.i])) p.i++;
}

/**
 * One value's canonical form. Throws SyntaxError.
 * @param {Cursor} p
 * @returns {string}
 */
function jsonValue(p) {
    ws(p);
    const c = p.s[p.i];
    if (c === "{") {
        p.i++;
        /** @type {Map<string, string>} */
        const members = new Map();
        ws(p);
        if (p.s[p.i] === "}") {
            p.i++;
            return "{}";
        }
        for (;;) {
            ws(p);
            if (p.s[p.i] !== '"') throw new SyntaxError("a key must be a string");
            const key = jsonString(p);
            ws(p);
            if (p.s[p.i++] !== ":") throw new SyntaxError("expected `:`");
            members.set(key, jsonValue(p));
            ws(p);
            const sep = p.s[p.i++];
            if (sep === "}") break;
            if (sep !== ",") throw new SyntaxError("expected `,` or `}`");
        }
        const keys = [...members.keys()].sort();
        return `{${keys.map((k) => `${JSON.stringify(k)}:${members.get(k)}`).join(",")}}`;
    }
    if (c === "[") {
        p.i++;
        /** @type {string[]} */
        const items = [];
        ws(p);
        if (p.s[p.i] === "]") {
            p.i++;
            return "[]";
        }
        for (;;) {
            items.push(jsonValue(p));
            ws(p);
            const sep = p.s[p.i++];
            if (sep === "]") break;
            if (sep !== ",") throw new SyntaxError("expected `,` or `]`");
        }
        return `[${items.join(",")}]`;
    }
    if (c === '"') return JSON.stringify(jsonString(p));
    for (const w of ["true", "false", "null"]) {
        if (p.s.startsWith(w, p.i)) {
            p.i += w.length;
            return w;
        }
    }
    const m = /^(-?)(0|[1-9]\d*)(?:\.(\d+))?(?:[eE]([+-]?\d+))?/.exec(p.s.slice(p.i));
    if (!m) throw new SyntaxError("not a JSON value");
    p.i += m[0].length;
    return canonicalNumber(m[1] === "-", m[2] + (m[3] ?? ""), BigInt(m[4] ?? "0") - BigInt((m[3] ?? "").length));
}

/**
 * A string token, decoded. Throws SyntaxError.
 * @param {Cursor} p
 * @returns {string}
 */
function jsonString(p) {
    const from = p.i++;
    while (p.i < p.s.length && p.s[p.i] !== '"') p.i += p.s[p.i] === "\\" ? 2 : 1;
    if (p.i >= p.s.length) throw new SyntaxError("a string is not closed");
    p.i++;
    return JSON.parse(p.s.slice(from, p.i));
}

/**
 * The number `digits` × 10^`exp` as `<digits>e<exp>` with no leading or
 * trailing zero in the digits; zero, of either sign, as `0`.
 * @param {boolean} negative
 * @param {string} digits
 * @param {bigint} exp
 */
function canonicalNumber(negative, digits, exp) {
    let d = digits.replace(/^0+/, "");
    if (d === "") return "0";
    const trailing = d.length - d.replace(/0+$/, "").length;
    d = d.slice(0, d.length - trailing);
    return `${negative ? "-" : ""}${d}e${exp + BigInt(trailing)}`;
}
