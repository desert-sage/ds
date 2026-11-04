// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The session's results as JSON (dsdb/DSDB_MCP.md §5), for an agent to
// chain: facts by id, firings by (rule, timetag), calls by number, points by
// position. A result holds its Timeline and BigInts, which do not serialise;
// each type is projected here once. A type with no projection yet goes out as
// its type alone, beside the text every tool returns, so nothing fails for
// want of one.

import { clock, pointLabel } from "../text/render.js";

/** @import { Call, Fact, Firing, Timeline } from "../core/timeline.js" */
/** @import { Result } from "../core/types.js" */
/** @import { EndStep, Trigger, WhyNode, WhyRoot } from "../core/why.js" */

/** @typedef {Record<string, unknown>} Json  a projection, ready for JSON.stringify with `replacer` */

/** @typedef {{ k: number, position: string, clock: string, settled: boolean }} Point */

/**
 * Bytes as base64, with what a browser has too (`btoa`), not Node's Buffer.
 * @param {Uint8Array} bytes
 */
function base64(bytes) {
    let s = "";
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(s);
}

/**
 * JSON.stringify's replacer: BigInt as decimal text, bytes as base64, a Map
 * as an object.
 * @param {string} _key
 * @param {unknown} v
 * @returns {unknown}
 */
export function replacer(_key, v) {
    if (typeof v === "bigint") return v.toString();
    if (v instanceof Uint8Array) return base64(v);
    if (v instanceof Map) return Object.fromEntries(v);
    return v;
}

/**
 * Point `k` of `tl`: `{ k, position, clock, settled }`.
 * @param {Timeline} tl
 * @param {number} k
 * @returns {Point}
 */
export function point(tl, k) {
    return { k, position: pointLabel(tl, k).slice(1), clock: clock(tl.clockAt(k), tl.clockAt(0)),
             settled: tl.isSettled(k) };
}

/**
 * A record's point: the one just after it.
 * @param {Timeline} tl
 * @param {number | null | undefined} i  a record index
 */
const at = (tl, i) => (i === null || i === undefined ? null : point(tl, i + 1));

/**
 * @param {Timeline} tl
 * @param {Fact} f
 * @returns {Json}
 */
export function fact(tl, f) {
    return { id: f.factId, schema: f.schema, slots: f.slots, origin: f.origin, rule: f.rule || null,
             asserted: at(tl, f.asserted), ended: at(tl, f.ended), cause: f.cause, prior: f.prior,
             successor: f.successor };
}

/**
 * @param {Timeline} tl
 * @param {Firing} fr
 * @returns {Json}
 */
export function firing(tl, fr) {
    return { rule: fr.rule, timetag: `0x${fr.timetag.toString(16)}`, fired: at(tl, fr.begin),
             matched: fr.matched === null ? null : fr.matched.map(String) };
}

/**
 * @param {Timeline} tl
 * @param {Call} c
 * @param {number} k  the point its outcome is read at
 * @returns {Json}
 */
export function call(tl, c, k) {
    return { number: c.number, service: c.service, corr: c.corr, rule: c.rule,
             timetag: `0x${BigInt(c.timetag).toString(16)}`, issued: at(tl, c.issued),
             outcome: c.waitingAt(k) ? "waiting" : c.outcome };
}

/**
 * An activation's trigger: the input, and the cascade's facts from it, each
 * with the rule that emitted it.
 * @param {Timeline} tl
 * @param {Trigger} t
 * @returns {Json}
 */
function trigger(tl, t) {
    return { input: at(tl, t.input.index), kind: t.input.kind,
             chain: t.chain.map((s) => ({ fact: s.fact.factId, by: s.firing?.rule ?? null })) };
}

/**
 * One step of how a fact ended (§4.14 "why it ended"): the fact, how, and
 * the firing and facts that how names, by id.
 * @param {Timeline} tl
 * @param {EndStep} st
 * @returns {Json}
 */
function endStep(tl, st) {
    const h = st.how;
    return { fact: st.fact.factId, ended: at(tl, st.fact.ended), cause: st.fact.cause, how: h.kind,
             ...("firing" in h ? { firing: h.firing === null ? null : firing(tl, h.firing) } : {}),
             ...(h.kind === "replaced" ? { by: h.by?.factId ?? null } : {}),
             ...(h.kind === "lost" ? { name: h.name, lost: h.lost.factId } : {}),
             ...(h.kind === "absence" ? { pattern: h.pattern, appeared: h.appeared.map((f) => f.factId) } : {}) };
}

/**
 * A `why` tree's node, with its facts and firings projected. Every field is
 * carried, so a field a node kind gains goes out with it.
 * @param {Timeline} tl
 * @param {WhyRoot | WhyNode} x
 * @returns {Json}
 */
function node(tl, x) {
    /** @type {Json} */
    const out = { kind: x.kind };
    for (const [k, v] of Object.entries(x)) {
        if (k === "kind" || k === "children") continue;
        if (k === "fact") out.fact = fact(tl, v);
        else if (k === "firing") out.firing = firing(tl, v);
        else if (k === "input" || k === "ended") out[k] = at(tl, v);
        else if (k === "reply") out.reply = { number: v.number, service: v.service, corr: v.corr };
        else if (k === "trigger") out.trigger = v === null ? null : trigger(tl, v);
        else if (k === "end") out.end = v === null ? null : v.map((/** @type {EndStep} */ st) => endStep(tl, st));
        else if (k === "clock" || k === "at" || k === "since" || k === "previous")
            out[k] = v === null ? null : clock(v, tl.clockAt(0));
        else out[k] = v;
    }
    if ("children" in x) out.children = x.children.map((c) => node(tl, c));
    return out;
}

/**
 * One result, as JSON; a bounded one (bound.js) says which rows it holds.
 * @param {Result} r
 * @returns {Json}
 */
export function project(r) {
    const out = one(r);
    if ("total" in r && r.total !== undefined) Object.assign(out, { offset: r.offset, total: r.total });
    return out;
}

/**
 * @param {Result} r
 * @returns {Json}
 */
function one(r) {
    switch (r.type) {
    case "note":
    case "error":
        return { type: r.type, text: r.text };
    case "more":
        return { type: r.type, count: r.count, cursor: r.cursor };
    case "listing":
        return { type: r.type, point: point(r.tl, r.k), around: r.around };
    case "banner":
        return { type: r.type, records: r.tl.length, point: point(r.tl, r.k) };
    case "where":
        return { type: r.type, timeline: r.timeline ?? null, point: point(r.tl, r.k) };
    case "factView":
        return { type: r.type, fact: fact(r.tl, r.fact) };
    case "firingView":
        return { type: r.type, firing: { ...firing(r.tl, r.firing), effects: r.firing.effects.length } };
    case "firings": {
        const tl = r.tl;
        return { type: r.type, count: r.head.count, firings: r.firings.map((f) => firing(tl, f)) };
    }
    case "calls": {
        const tl = r.tl, k = r.k;
        return { type: r.type, calls: r.calls.map((c) => call(tl, c, k)) };
    }
    case "bars":
        return { type: r.type, point: point(r.tl, r.k), rows: r.rows.map(([name, count, change]) => ({ name, count, change })) };
    case "answerCount":
        return { type: r.type, point: point(r.tl, r.k), count: r.count };
    case "answers": {
        const tl = r.tl;
        const names = r.compiled.bindings.map(([, b]) => b);
        return {
            type: r.type, point: point(tl, r.k), count: r.total ?? r.answers.length,
            answers: r.answers.map((a) => ({
                bindings: Object.fromEntries(a.bindings.map((id, i) => {
                    const f = tl.facts.get(id);
                    return [names[i] ?? `_${i}`, f === undefined ? { id } : fact(tl, f)];
                })),
                values: a.values ?? null,
            })),
        };
    }
    case "why":
        return { type: r.type, point: point(r.tl, r.k), root: node(r.tl, r.root) };
    case "rete":
        return { type: r.type, point: point(r.tl, r.k), summary: r.summary, changed: r.changed, rules: r.rules };
    case "whynot":
        return { type: r.type, point: point(r.tl, r.k), rule: r.rule,
                 stages: r.stages.map((x) => ({ n: x.n, kind: x.kind, pattern: x.head, test: x.text, count: x.count,
                                                schema: x.schema, candidates: x.candidates, filtered: x.filtered })),
                 stop: r.stop === null ? null : r.stages[r.stop].n, reason: r.reason, complete: r.complete,
                 fired: r.fired, last: r.last === null ? null : firing(r.tl, r.last), refracted: r.refracted,
                 pending: r.pending, cooldown: r.cooldown };
    case "reteSchemas":
        return { type: r.type, point: point(r.tl, r.k), summary: r.summary, schemas: r.schemas };
    case "matchTrace":
        return { type: r.type, steps: r.steps.map((st) => Object.fromEntries(st)) };
    case "timelines":
        return { type: r.type, timelines: r.rows.map((row) => ({
            n: row.n, current: row.current, reality: row.reality, point: point(row.tl, row.k),
            forked: row.reality ? null : point(row.tl, row.forkK), bytes: row.mem })) };
    case "edited":
        return { type: r.type, what: r.what, inputs: r.inputs, skipped: r.skipped };
    case "editDiff":
        return { type: r.type, timeline: r.timeline, point: point(r.tl, r.k), added: r.added, removed: r.removed,
                 firings: r.firings.map(([rule, before, after]) => ({ rule, before, after })) };
    case "programList":
        return { type: r.type, definitions: Object.fromEntries(r.kinds.map(([k, ds]) => [k, ds.map((d) => d.name)])) };
    case "definitionList":
        return { type: r.type, kind: r.kind, definitions: r.defs.map((d) => ({ name: d.name, text: d.text })) };
    case "ruleList":
        return { type: r.type, rules: r.rules };
    case "savedCode":
        return { type: r.type, path: r.path, counts: Object.fromEntries(r.counts), lines: r.lines };
    case "changeList": {
        const tl = r.tl;
        return { type: r.type, changes: r.changes.map((c) => ({ n: c.n, change: c.text, at: point(tl, c.at) })) };
    }
    case "newRecords":
        return { type: r.type, records: r.k - r.from, point: point(r.tl, r.k) };
    case "forked":
        return { type: r.type, timeline: r.num, from: r.from, at: point(r.tl, r.k), unreliable: r.unreliable };
    case "discarded":
    case "recomputed":
        return { type: r.type, point: point(r.tl, r.k) };
    case "midCascade":
        return { type: r.type, word: r.word, before: point(r.tl, r.lo), after: point(r.tl, r.hi) };
    case "logs": {
        const tl = r.tl;
        return { type: r.type, lines: r.lines.map((l) => ({ firing: firing(tl, tl.firings[l.firing]), text: l.line })) };
    }
    default:
        return { type: r.type };
    }
}

// ── the projections' JSON Schemas, for each tool's outputSchema (§10.7) ──

/** @typedef {Record<string, unknown>} Schema  a JSON Schema */

/** @typedef {{ type: "object", properties: Record<string, Schema>, required: string[] }} ObjectSchema */

const STR = { type: "string" }, INT = { type: "integer" }, BOOL = { type: "boolean" }, OBJ = { type: "object" };
/**
 * @param {Schema} s
 * @returns {Schema}
 */
const nullable = (s) => ({ anyOf: [s, { type: "null" }] });
/**
 * @param {Schema} items
 * @returns {Schema}
 */
const array = (items) => ({ type: "array", items });
/**
 * @param {Record<string, Schema>} properties
 * @param {string[]} [required]  all of them, unless given
 * @returns {ObjectSchema}
 */
const object = (properties, required = Object.keys(properties)) => ({ type: "object", properties, required });

const POINT = object({ k: INT, position: STR, clock: STR, settled: BOOL });
const FACT = object({ id: STR, schema: STR, slots: OBJ, origin: STR, rule: nullable(STR), asserted: nullable(POINT),
                      ended: nullable(POINT), cause: {}, prior: {}, successor: {} }, ["id", "schema", "slots"]);
const FIRING = object({ rule: STR, timetag: STR, fired: nullable(POINT), matched: nullable(array(STR)) },
                      ["rule", "timetag"]);
const CALL = object({ number: INT, service: STR, corr: {}, rule: STR, timetag: STR, issued: nullable(POINT),
                      outcome: nullable(STR) }, ["number", "service"]);

/**
 * Each projected type's own properties, `type` aside. A type not here goes
 * out as `{ type }` alone.
 * @type {Record<string, ObjectSchema>}
 */
const SHAPES = {
    note: object({ text: STR }),
    error: object({ text: STR }),
    more: object({ count: INT, cursor: STR }),
    listing: object({ point: POINT, around: INT }),
    banner: object({ records: INT, point: POINT }),
    where: object({ timeline: nullable(INT), point: POINT }),
    factView: object({ fact: FACT }),
    firingView: object({ firing: FIRING }),
    firings: object({ count: INT, firings: array(FIRING) }),
    calls: object({ calls: array(CALL) }),
    bars: object({ point: POINT, rows: array(object({ name: STR, count: INT, change: {} }, ["name", "count"])) }),
    answerCount: object({ point: POINT, count: INT }),
    answers: object({ point: POINT, count: INT,
                      answers: array(object({ bindings: OBJ, values: nullable({ type: "array" }) })) }),
    why: object({ point: POINT, root: OBJ }),
    rete: object({ point: POINT, summary: OBJ, changed: BOOL, rules: array(OBJ) }),
    reteSchemas: object({ point: POINT, summary: OBJ, schemas: array(OBJ) }),
    whynot: object({ point: POINT, rule: STR,
                     stages: array(object({ n: INT, kind: STR, pattern: STR, test: STR, count: nullable(INT),
                                            schema: nullable(STR), candidates: nullable(array(STR)),
                                            filtered: array(object({ id: STR, detail: STR })) })),
                     stop: nullable(INT), reason: nullable(OBJ), complete: nullable(INT), fired: INT,
                     last: nullable(FIRING), refracted: INT, pending: nullable(INT), cooldown: nullable(STR) }),
    matchTrace: object({ steps: array(OBJ) }),
    timelines: object({ timelines: array(object({ n: INT, current: BOOL, reality: BOOL, point: POINT,
                                                  forked: nullable(POINT), bytes: INT })) }),
    edited: object({ what: STR, inputs: INT, skipped: array(OBJ) }),
    editDiff: object({ timeline: INT, point: POINT, added: array(STR), removed: array(STR),
                       firings: array(object({ rule: STR, before: INT, after: INT })) }),
    programList: object({ definitions: OBJ }),
    definitionList: object({ kind: STR, definitions: array(object({ name: STR, text: STR })) }),
    ruleList: object({ rules: array(OBJ) }),
    savedCode: object({ path: STR, counts: OBJ, lines: INT }),
    changeList: object({ changes: array(object({ n: INT, change: STR, at: POINT })) }),
    newRecords: object({ records: INT, point: POINT }),
    forked: object({ timeline: INT, from: INT, at: POINT, unreliable: {} }, ["timeline", "from", "at"]),
    discarded: object({ point: POINT }),
    recomputed: object({ point: POINT }),
    midCascade: object({ word: STR, before: POINT, after: POINT }),
    logs: object({ lines: array(object({ firing: FIRING, text: STR })) }),
};

/** Any result: what a type not listed for a tool still matches, so a
    client never refuses a result for want of a listing. */
const ANY = { type: "object", properties: { type: STR }, required: ["type"] };

/**
 * One result type's schema: its shape, and `type` fixed. A bounded one
 * (bound.js) also carries `offset` and `total`.
 * @param {string} type
 * @returns {ObjectSchema}
 */
export function resultSchema(type) {
    const s = SHAPES[type] ?? object({});
    return { type: "object", properties: { type: { const: type }, ...s.properties, offset: INT, total: INT },
             required: ["type", ...s.required] };
}

/**
 * A tool's outputSchema: `{ results }`, each one of `types` or any other.
 * @param {string[]} types
 * @returns {ObjectSchema}
 */
export function outputSchema(types) {
    return object({ results: array({ anyOf: [...types.map(resultSchema), ANY] }) });
}
