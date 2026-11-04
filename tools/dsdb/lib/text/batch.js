// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Batch mode's stderr lines (DSDB.md §9): what the rules logged, the calls
// they attempted, and with `-v` every stream event as it happens. Each line
// starts with the clock from the run's start, so the streams interleave in
// time order when read together.

import { argsText } from "../core/calls.js";
import { clock, hex8, value } from "./render.js";
import { hexAlt, ljust } from "./py.js";

/** @import { Fact, SlotValue, StreamEngineEvent } from "@ds-lang/ds" */
/** @import { CallEntry, LogEntry, ReplyEntry } from "../core/batch.js" */
/** @import { BookedCall, CallArg } from "../core/calls.js" */

const T0 = 0n;

/**
 * `2.0s  INFO  reply kitchen`
 * @param {LogEntry} e
 */
export function logLine({ at, level, message }) {
    return `${clock(at, T0)}  ${level}  ${message}`;
}

/**
 * `2.0s  call svc.foo as "kitchen"  {"n":3}  by alarm  (not made)`, or with a
 * calls socket (§9.1) `… by alarm  (call 1, sent)`, and `(call 1, sent; no
 * response)` for a call no response can answer.
 * @param {CallEntry} e
 */
export function callLine({ at, number, service, correlation, args, ruleName, waits, sent }) {
    const by = ruleName ? `  by ${ruleName}` : "";
    const what = !sent ? "not made" : waits ? `call ${number}, sent` : `call ${number}, sent; no response`;
    return `${clock(at, T0)}  call ${service} as ${value(correlation)}  ${argsText(args)}${by}  (${what})`;
}

/**
 * What became of a reply on the calls socket (§9.1):
 * `7.0s  reply to call 1 (svc.foo as "b"): answered`,
 * `… failed: svc.down  it is down`, or `7.0s  reply dropped: why  <line>`.
 * @param {ReplyEntry} e
 */
export function replyLine(e) {
    if ("dropped" in e) return `${clock(e.at, T0)}  reply dropped: ${e.dropped}  ${e.line}`;
    const call = e.call;
    const head = `${clock(e.at, T0)}  reply to call ${call.number} (${call.service} as ${value(call.correlation)}): ${e.outcome}`;
    if ("undeliverable" in e) return `${head}, not delivered: ${e.undeliverable}`;
    return e.error ? `${head}: ${e.error.code}  ${e.error.message}` : head;
}

/**
 * A call no reply reached by the end: `call 2 svc.foo as "b"  by ask: no reply`.
 * @param {BookedCall} c
 */
export function waitingLine(c) {
    return `call ${c.number} ${c.service} as ${value(c.correlation)}  by ${c.ruleName}: no reply`;
}

/**
 * A fact as `-v` shows it: its schema, id and slots, a reference to another
 * fact as that fact's id; just its id once it can no longer be read.
 * @param {Fact} f
 */
function factText(f) {
    if (!f) return "";
    let r;
    try {
        r = f.read();
    } catch {
        return `#${f.id}`;
    }
    return `${r.schema}#${r.id}` + slotsText(r.slots);
}

/**
 * A publish as `-v` shows it: its schema and slots, and no id, since the fact
 * is in no working memory here ([LTIE.4.3]).
 * @param {string} schema
 * @param {Record<string, SlotValue>} slots
 */
function publishText(schema, slots) {
    return schema + slotsText(slots);
}

/**
 * Slot values after a fact's head, a reference to another fact as that
 * fact's id; "" for none.
 * @param {Record<string, SlotValue>} slots
 */
function slotsText(slots) {
    const parts = Object.entries(slots).map(([k, v]) =>
        `${k}=${v !== null && typeof v === "object" && !(v instanceof Uint8Array) ? `#${v.id}` : value(v)}`);
    return parts.length ? "  " + parts.join("  ") : "";
}

/**
 * One stream event, for `-v`: `seq  clock  kind  detail`.
 * @param {StreamEngineEvent} ev  a `@ds-lang/ds` stream event; its `type` is its kind
 * @param {CallArg[]} [args]  an action_call's arguments, as core/calls.js keeps them
 */
export function eventLine(ev, args) {
    let detail;
    switch (ev.type) {
    case "fact_assert": case "fact_retract": case "fact_modify":
    case "action_emit":
        detail = factText(ev.fact);
        break;
    case "action_publish":
        detail = publishText(ev.schema, ev.slots);
        break;
    case "rule_fire_begin": case "rule_fire_end":
        detail = `${ev.ruleName}  tt ${hexAlt(ev.timetag)}`;
        break;
    case "rule_lhs_facts":
        detail = `${ev.ruleName}  ${ev.lhsFacts.map((f) => `#${f.id}`).join(" ")}`;
        break;
    case "action_log":
        detail = `${ev.level}  ${ev.message}`;
        break;
    case "action_call":
        detail = `${ev.service} as ${value(ev.correlation)}  ${argsText(args ?? [])}`;
        break;
    case "action_cache_set":
        detail = `${ev.key} = ${ev.valueJson}`;
        break;
    case "action_cache_get": case "action_cache_delete":
        detail = ev.key;
        break;
    case "timer_armed": case "timer_fired":
        detail = `${ev.ruleName}  ${ev.timerKind}`;
        break;
    default: {
        // The event's own fields are the record's; an Event's own `isTrusted` is not one.
        const skip = new Set(["seq", "clockNs", "isTrusted"]);
        detail = Object.entries(ev).filter(([k]) => !skip.has(k))
            .map(([k, v]) => `${k}=${v === null ? "null" : typeof v === "string" ? value(v) : String(v)}`).join("  ");
    }
    }
    return `${hex8(ev.seq)}  ${ljust(clock(ev.clockNs, T0), 9)}  ${ljust(ev.type, 19)}  ${detail}`;
}
