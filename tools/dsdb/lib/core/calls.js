// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// A call's arguments, the calls socket's protocol (DSDB.md §9.1), and the
// book of which calls are waiting. No I/O: the CLI owns the socket and hands
// lines in and out.
//
// One JSON object per line, both ways.
//
//   out  {"call":1,"service":"svc.ask","corr":"q1","args":{"n":3},"rule":"ask","at":"2_s"}
//   in   {"corr":"q1","response":{…the slots of the service's response schema…}}
//   in   {"corr":"q1","error":{"code":"svc.down","message":"…"}}
//
// `args` holds each argument the call supplies, written as batch mode writes a
// slot of its kind (core/facts-out.js), and a fact argument as
// `{"schema","asserted_at","external"}`; `corr` is null for a call with no
// `as`; `at` is the clock from the run's start as a duration literal, as `@at`
// reads. A `response` is read as one JSONL row of the response schema
// (core/facts.js), and dsdb gives it its `corr`.
//
// ARGUMENTS are kept as `{ name, type, value }`, in the order libds gives
// them (sorted by name): `type` is Int, Float, String, Bool, Json,
// Bytes, Null or Fact, and a Fact's value is `{ schema, assertedAt, external }`,
// `assertedAt` null when the wall clock had no value as the fact entered
// (RFCS.23.5), `external` its FactExternal bytes where they are known (a live
// engine's stream carries them; a trace holds them decoded) and null where not.

import { base64, durationLiteral, jsonValue } from "./facts-out.js";
import { FactFileError, scanObject, typeSlots } from "./facts.js";

/** @import { CallArgument } from "@ds-lang/ds" */
/** @import { CellValue, SchemaShape } from "./facts.js" */

/** A reply that cannot be delivered, and why. */
export class ReplyError extends Error {
    /** @param {string} message */
    constructor(message) {
        super(message);
        this.name = "ReplyError";
    }
}

/** @typedef {{ schema: string, assertedAt: bigint | null, external: Uint8Array | null }} FactArg */

/**
 * One argument of a call, in the order libds gives them. A kind this reader
 * does not know is its number, `kind 9`, with no value.
 * @typedef {{ name: string, type: "Fact", value: FactArg }
 *   | { name: string, type: "Int" | "Float" | "String" | "Bool" | "Json" | "Bytes" | "Null" | `kind ${string}`,
 *       value: bigint | number | string | boolean | Uint8Array | null }} CallArg
 */

/** @type {Map<string, CallArg["type"]>} FactExternal's Kind (proto/fact_external.proto) as an argument's type */
const KIND_TYPE = new Map([["KIND_INT", "Int"], ["KIND_FLOAT", "Float"], ["KIND_STRING", "String"],
                           ["KIND_BOOL", "Bool"], ["KIND_JSON", "Json"], ["KIND_BYTES", "Bytes"],
                           ["KIND_NULL", "Null"], ["KIND_ENCODED_FACT", "Fact"]]);

/** @type {Map<string, string>} each Kind's member of `Arg.value` */
const MEMBER = new Map([["Int", "int_value"], ["Float", "float_value"], ["String", "string_value"],
                        ["Bool", "bool_value"], ["Json", "json_value"], ["Bytes", "bytes_value"]]);

/**
 * A recorded call's arguments: CallIssued's `args`, as libds's reader gives
 * them, with the FactExternal bytes of its fact arguments where known.
 * @param {Array<Record<string, any>> | undefined} recorded  `Arg` messages: `{ name, kind, <the member set> }`,
 *   their fields as proto/call_issued.proto has them
 * @param {Map<string, Uint8Array> | null} [externals]  fact arguments' bytes, by name
 * @returns {CallArg[]}
 */
export function recordedArgs(recorded, externals = null) {
    return (recorded ?? []).map((a) => {
        /** @type {CallArg["type"]} */
        const type = KIND_TYPE.get(a.kind?.name) ?? `kind ${a.kind?.number}`;
        if (type === "Fact") {
            // has_asserted_at false: the wall clock had no value, and
            // asserted_at is not an instant (RFCS.23.5).
            const value = { schema: a.fact?.schema ?? "",
                            assertedAt: a.fact?.has_asserted_at ? a.fact.asserted_at : null,
                            external: externals?.get(a.name) ?? null };
            return { name: a.name, type, value };
        }
        const member = MEMBER.get(type);
        let value = member === undefined ? null : a[member];
        if (value instanceof Uint8Array && value.constructor !== Uint8Array) value = new Uint8Array(value);
        return { name: a.name, type, value };
    });
}

/**
 * A live call's arguments, as `@ds-lang/ds`'s call request or action_call event
 * gives them (`args`, name to value), each typed by its value: a Json one is a
 * JsonText, kept here as its text.
 * @param {Record<string, CallArgument> | null | undefined} args
 * @returns {CallArg[]}
 */
export function liveArgs(args) {
    return Object.entries(args ?? {}).map(([name, v]) => {
        /** @type {Exclude<CallArg["type"], "Fact" | "Json">} */
        let type;
        if (v === null) type = "Null";
        else if (typeof v === "bigint") type = "Int";
        else if (typeof v === "number") type = "Float";
        else if (typeof v === "boolean") type = "Bool";
        else if (typeof v === "string") type = "String";
        else if (v instanceof Uint8Array) type = "Bytes";
        else if ("text" in v) return { name, type: "Json", value: v.text };
        else return { name, type: "Fact", value: { schema: v.schema, assertedAt: v.assertedAt,
                                                   external: v.external } };
        return { name, type, value: v };
    });
}

/**
 * Arguments as one JSON object's text, each as batch mode writes a slot of its
 * kind. A fact argument is `{"schema","asserted_at"}`, `asserted_at` null when
 * there was no wall clock, and with `external` its FactExternal bytes in
 * base64 too, which the socket sends and the shell does not show.
 * @param {CallArg[]} args
 * @param {{ external?: boolean }} [opts]
 */
export function argsText(args, { external = false } = {}) {
    const fields = args.map((a) => {
        let v;
        if (a.type === "Fact") {
            const value = a.value;
            const at = value.assertedAt === null ? "null" : `${BigInt(value.assertedAt)}`;
            v = `{"schema":${JSON.stringify(value.schema)},"asserted_at":${at}`
                + (external && value.external ? `,"external":"${base64(value.external)}"` : "") + "}";
        } else {
            // libds's canonical JSON has no raw newline inside a string, so
            // one outside a string is whitespace, and a space serves as well.
            v = jsonValue(a.value, a.type).replace(/[\r\n]+/g, " ");
        }
        return `${JSON.stringify(a.name)}:${v}`;
    });
    return `{${fields.join(",")}}`;
}

/**
 * A call as its line on the socket, without the newline.
 * @param {{ number: number, service: string, correlation: string | null, args: CallArg[],
 *           ruleName: string | null, at: bigint }} c
 */
export function callWire(c) {
    return `{"call":${c.number},"service":${JSON.stringify(c.service)},"corr":${JSON.stringify(c.correlation)},`
        + `"args":${argsText(c.args, { external: true })},"rule":${JSON.stringify(c.ruleName ?? "")},`
        + `"at":"${durationLiteral(c.at)}"}`;
}

/**
 * A reply line to what it asks for: `{ corr, response }`, the response the
 * text of a JSON object (typed later, against the response schema, by
 * `responseSlots`), or `{ corr, error: { code, message } }`.
 * @param {string} line
 * @returns {{ corr: string, response: string, error?: undefined } | { corr: string, error: { code: string, message: string } }}
 * @throws {ReplyError}
 */
export function parseReply(line) {
    let cells;
    try {
        cells = scanObject(line, "reply");
    } catch (err) {
        // The scanner says where as `reply:LINE: `; a reply is one line.
        if (err instanceof FactFileError) throw new ReplyError(err.message.replace(/^reply(:\d+)?: /, ""));
        throw err;
    }
    for (const k of cells.keys())
        if (!["corr", "response", "error"].includes(k)) throw new ReplyError(`no field \`${k}\` in a reply`);
    const corr = cells.get("corr");
    if (!corr || corr.text === undefined) throw new ReplyError("`corr` must be a string");
    const response = cells.get("response"), e = cells.get("error");
    if ((response === undefined) === (e === undefined)) throw new ReplyError("give one of `response` and `error`");
    if (response !== undefined) {
        if (response.kind !== "object")
            throw new ReplyError("`response` must be an object: the response schema's slots");
        return { corr: corr.text, response: response.json };
    }
    if (e === undefined || e.kind !== "object") throw new ReplyError("`error` must be an object: { code, message }");
    const fields = scanObject(e.json, "error");
    /** @param {string} k */
    const str = (k) => {
        const c = fields.get(k);
        if (!c || c.text === undefined) throw new ReplyError(`\`error.${k}\` must be a string`);
        return c.text;
    };
    return { corr: corr.text, error: { code: str("code"), message: str("message") } };
}

/**
 * A response's slots: the text of a JSON object, typed as a row of the
 * response schema `schema` (`@ds-lang/ds`'s `schemas`), with `corr` given.
 * The response schema declares `corr`, and it is the call's,
 * so a response that names it is refused. Every other slot that is not
 * nullable must be given.
 * @param {string} text
 * @param {SchemaShape} schema
 * @param {string} corr
 * @returns {Record<string, CellValue>}
 * @throws {ReplyError}
 */
export function responseSlots(text, schema, corr) {
    try {
        const cells = scanObject(text, "response");
        if (cells.has("corr")) throw new ReplyError("`corr` is the call's: leave it out of `response`");
        const slots = typeSlots(cells, schema, "response");
        // Refused here, where it is the reply's fault, rather than by the
        // engine's assert, which would end the session instead.
        const missing = schema.slots.find((s) => s.name !== "corr" && !s.nullable && !(s.name in slots));
        if (missing) throw new ReplyError(`\`${missing.name}\` is missing: ${schema.name} requires it`);
        return { corr, ...slots };
    } catch (err) {
        if (err instanceof FactFileError) throw new ReplyError(err.message.replace(/^response: /, ""));
        throw err;
    }
}

/** @typedef {"waiting" | "no response" | "answered" | "failed" | "superseded"} CallOutcome */

/**
 * A call the book holds.
 * @typedef {object} BookedCall
 * @property {number} number  from 1, in issue order
 * @property {string} service
 * @property {string | null} correlation  null for a call with no `as`
 * @property {CallArg[]} args
 * @property {string | null} ruleName
 * @property {bigint} at  the clock from the run's start
 * @property {string} response  the service's response schema, "" for `no response`
 * @property {boolean} waits
 * @property {CallOutcome} outcome
 */

/**
 * The calls made and which are waiting. A call waits until a reply names its
 * `corr`; a later call with the same `corr` takes its place, and the earlier
 * one is superseded, as the timeline reads them (DSTRACE_INTERACTIVE §4.10).
 * A call no response can answer, to a `no response` service or with no
 * `corr`, does not wait; one with a `corr` can still fail.
 */
export class CallBook {
    /** @type {BookedCall[]} every call, in order */
    calls = [];
    /** @type {Map<string | null, BookedCall>} corr -> call */
    #waiting = new Map();
    /** @type {Map<string | null, BookedCall>} corr -> a call that does not wait, but may fail */
    #failable = new Map();

    /**
     * Book a call the engine reported; return it, numbered from 1.
     * `response` is its service's response schema, "" for `no response`.
     * @param {{ service: string, correlation: string | null, args: CallArg[], ruleName: string | null,
     *           at: bigint, response: string }} call
     * @returns {BookedCall}
     */
    issue({ service, correlation, args, ruleName, at, response }) {
        const waits = response !== "" && correlation !== null;
        /** @type {BookedCall} */
        const c = { number: this.calls.length + 1, service, correlation, args, ruleName, at, response,
                    waits, outcome: waits ? "waiting" : "no response" };
        for (const m of [this.#waiting, this.#failable]) {
            const old = m.get(correlation);
            if (old) {
                old.outcome = "superseded";
                m.delete(correlation);
            }
        }
        if (waits) this.#waiting.set(correlation, c);
        else if (correlation !== null) this.#failable.set(correlation, c);
        this.calls.push(c);
        return c;
    }

    get waiting() {
        return [...this.#waiting.values()];
    }

    /**
     * The call a reply's `corr` names, or undefined: a waiting one, or for an
     * error, one that does not wait.
     * @param {string} corr
     * @param {boolean} [error]
     * @returns {BookedCall | undefined}
     */
    find(corr, error = false) {
        return this.#waiting.get(corr) ?? (error ? this.#failable.get(corr) : undefined);
    }

    /**
     * The call is answered (or failed): it waits no longer.
     * @param {BookedCall} c
     * @param {CallOutcome} outcome
     */
    settle(c, outcome) {
        c.outcome = outcome;
        for (const m of [this.#waiting, this.#failable])
            if (m.get(c.correlation) === c) m.delete(c.correlation);
    }
}
