// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Batch mode (DSDB.md §9): a program and fact files, no shell. The facts are
// fed as a live session would be (core/facts.js), and what the rules do is
// reported rather than explored:
//
// - what they `log` goes to the log sink;
// - what they `publish` is collected, per schema, with its slot values as they
//   were at the moment it was published;
// - a `call` is reported, and NOT made unless a calls socket is given (§9.1):
//   then it is sent there, and the replies that come back are delivered
//   between pump cycles, a response as a fact of the service's response
//   schema and an error as a CallError.
//
// Everything is read from the engine's stream events, which carry each one's
// clock. Nothing here prints, and nothing here does I/O: the caller is given
// the pieces, and a calls socket is a port the caller provides.

import { CallBook, ReplyError, callWire, liveArgs, parseReply, responseSlots } from "./calls.js";
import { FactFileError, feed, loadFactFiles } from "./facts.js";
import { read as readProgram, reservedName } from "./program.js";

/** @import { Engine, SchemaInfo, StreamEngineEvent } from "@ds-lang/ds" */
/** @import { BookedCall, CallArg, CallOutcome } from "./calls.js" */
/** @import { CellValue } from "./facts.js" */
/** @import { OutRow } from "./facts-out.js" */
/** @import { Ds } from "./types.js" */

/**
 * The calls socket (§9.1), as the CLI provides it (cli/socket.js) to batch
 * mode and to the API (api/ops.js).
 * @typedef {object} CallsPort
 * @property {(line: string) => void} send  a line out, without its newline
 * @property {(ms: number) => number} after  a deadline `ms` of real time from now, in milliseconds
 *   since the epoch
 * @property {(deadline: number) => Promise<string | null>} receive
 *   the next line in, or null once the deadline passes or the peer is gone
 */

/** @typedef {{ at: bigint, level: string, category: string, message: string }} LogEntry  a rule's `log` */

/** @typedef {BookedCall & { sent: boolean }} CallEntry  a call, and whether it went to the socket */

/**
 * What became of a reply: delivered (`error` null for a response), not
 * deliverable as a fact, or dropped, with the line, before reaching a call.
 * @typedef {{ at: bigint, call: BookedCall, outcome: CallOutcome, error: { code: string, message: string } | null }
 *   | { at: bigint, call: BookedCall, outcome: CallOutcome, undeliverable: string }
 *   | { at: bigint, dropped: string, line: string }} ReplyEntry
 */

/**
 * A reply that settles a call: a response typed as its schema's row, or an
 * error.
 * @typedef {{ corr: string, call: BookedCall, slots: Record<string, CellValue>, error?: undefined }
 *   | { corr: string, call: BookedCall, error: { code: string, message: string } }} Reply
 */

/**
 * @param {object} args
 * @param {Ds} args.ds  a `@ds-lang/ds` API from `open()`
 * @param {Uint8Array} args.dsc  the program
 * @param {Array<{ path: string, text: string }>} args.files  fact files, in command-line order
 * @param {CallsPort} [args.calls]  where calls go and replies come from
 * @param {number} [args.pumps]  pump cycles, 1 by default: the facts. Each
 *   further cycle delivers the replies to waiting calls and pumps once.
 * @param {number} [args.callTimeoutMs]  how long a cycle waits for replies
 * @param {bigint | null} [args.until]  nanoseconds from the start: after every
 *   cycle, the clock moves there and the engine pumps once. Null ends the run
 *   at the last row's time.
 * @param {(entry: LogEntry) => void} [args.onLog]
 * @param {(entry: CallEntry) => void} [args.onCall]  `args` as core/calls.js keeps them
 * @param {(entry: ReplyEntry) => void} [args.onReply]
 * @param {(ev: StreamEngineEvent, args?: CallArg[]) => void} [args.onEvent]
 *   every stream event, for `-v`; an action_call's arguments typed beside it
 * @returns {Promise<{ schemas: SchemaInfo[], published: Map<string, OutRow[]>, emitted: number, rows: number,
 *                     cycles: number, waiting: BookedCall[] }>}
 *   `at` is BigInt nanoseconds from the start; `emitted` how many facts the rules emitted, which are not
 *   output; `waiting` the calls no reply reached.
 */
export async function runBatch({ ds, dsc, files, calls, pumps = 1, callTimeoutMs = 5000, until = null,
                                 onLog, onCall, onReply, onEvent }) {
    const { services } = readProgram(ds, dsc);
    const e = new ds.Engine();
    try {
        e.clock.mode = "mock";
        e.clock.set(0n);
        // With no wall clock, `now()` and an emitted `ts` fault ([LTIM.2.8.3]).
        // From the epoch, so `now()` is a row's `@at`, as its `ts` is.
        e.clock.setWall(0n);
        e.loadDsc(dsc);
        const rows = loadFactFiles(files, e);
        const last = rows.at(-1);       // merged by time, so the latest
        if (until !== null && last !== undefined && last.at > until)
            throw new FactFileError(last.file, last.line, "this row's `@at` is past `--until`");
        const schemas =[...e.schemas.values()].filter((s) => !reservedName(s.name));
        /** @type {Map<string, OutRow[]>} */
        const published = new Map(schemas.map((s) => [s.name, []]));
        const book = new CallBook();
        // What was emitted is not output (it stays on this tier), but how
        // many is: a run that published nothing says so.
        let emitted = 0;

        const onStream = (/** @type {StreamEngineEvent} */ ev) => {
            const at = ev.clockNs;                  // the clock started at 0
            /** @type {CallArg[] | undefined} */
            let args;
            switch (ev.type) {
            case "action_emit":
                emitted++;
                break;
            case "action_publish": {
                // The event's copy: the fact is in no working memory here
                // ([LTIE.4.3]), so there is nothing to read back.
                const rows = published.get(ev.schema) ?? [];
                published.set(ev.schema, rows);
                rows.push({ at, slots: ev.slots });
                break;
            }
            case "action_log":
                onLog?.({ at, level: ev.level, category: ev.category, message: ev.message });
                break;
            case "action_call": {
                const svc = services.get(ev.service);
                args = liveArgs(ev.args);
                const c = book.issue({ service: ev.service, correlation: ev.correlation, args,
                                       ruleName: ev.ruleName, at, response: svc?.response ?? "" });
                calls?.send(callWire(c));
                onCall?.({ ...c, sent: Boolean(calls) });
                break;
            }
            }
            onEvent?.(ev, args);
        };
        // `-v` prints every event; without it, the four read above are all.
        const kinds = onEvent ? ds.STREAM_EVENT_KINDS
                              : /** @type {const} */ (["action_emit", "action_publish", "action_log", "action_call"]);
        for (const kind of kinds) e.addEventListener(kind, onStream);
        // `call` is essential: with no callback, libds fails the action
        // (DS_ERR_STORAGE_UNAVAILABLE). dsdb takes it and does nothing; the
        // stream events above are what report calls, and send them.
        e.setCallCallback(() => {});

        feed(e, rows);
        let cycles = 1;
        while (calls && cycles < pumps && book.waiting.length) {
            const replies = await collect(calls, book, callTimeoutMs, e, onReply);
            // Nothing came back in time: no later cycle would fare better.
            if (!replies.length) break;
            cycles++;
            deliver(e, book, replies, onReply);
            e.pump();
        }
        if (until !== null) {
            const now = e.clock.now;
            if (until > now) e.clock.advance(until - now);
            e.pump();
        }
        return { schemas, published, emitted, rows: rows.length, cycles, waiting: book.waiting };
    } finally {
        e.close();
    }
}

/**
 * Read replies until every waiting call has one, the deadline passes, or
 * the peer is gone. A line that is not a reply to a call it can settle is
 * reported and dropped: a response must name a waiting call and be a row of
 * its response schema; an error may also name a call that does not wait
 * (§9.1).
 * @param {CallsPort} port
 * @param {CallBook} book
 * @param {number} timeoutMs
 * @param {Engine} e
 * @param {((entry: ReplyEntry) => void) | undefined} onReply
 * @returns {Promise<Reply[]>}
 */
async function collect(port, book, timeoutMs, e, onReply) {
    const at = e.clock.now;
    const deadline = port.after(timeoutMs);
    /** @type {Map<string, Reply>} corr -> reply; a second reply to one call is the later */
    const got = new Map();
    const want = new Set(book.waiting.map((c) => c.correlation));
    while ([...want].some((corr) => corr === null || !got.has(corr))) {
        const line = await port.receive(deadline);
        if (line === null) break;
        if (line.trim() === "") continue;
        /** @type {Reply} */
        let r;
        try {
            const p = parseReply(line);
            const call = book.find(p.corr, p.error !== undefined);
            if (call === undefined) throw new ReplyError(`no call ${p.error ? "can fail" : "waits"} on corr ${JSON.stringify(p.corr)}`);
            if (p.error !== undefined) r = { corr: p.corr, call, error: p.error };
            else {
                const schema = e.schemas.get(call.response);
                if (schema === undefined) throw new ReplyError(`the program has no schema ${call.response}`);
                r = { corr: p.corr, call, slots: responseSlots(p.response, schema, p.corr) };
            }
        } catch (err) {
            if (!(err instanceof ReplyError)) throw err;
            onReply?.({ at, dropped: err.message, line });
            continue;
        }
        got.set(r.corr, r);
    }
    return [...got.values()];
}

/**
 * Assert each reply as its fact, at the engine's clock. A program with no
 * rule reading CallError did not register it, so an error goes nowhere,
 * and that is said.
 * @param {Engine} e
 * @param {CallBook} book
 * @param {Reply[]} replies
 * @param {((entry: ReplyEntry) => void) | undefined} onReply
 */
function deliver(e, book, replies, onReply) {
    const at = e.clock.now;
    for (const r of replies) {
        const call = r.call;
        const outcome = r.error ? "failed" : "answered";
        book.settle(call, outcome);
        if (r.error && !e.schemas.has("CallError")) {
            onReply?.({ at, call, outcome, undeliverable: "no rule reads CallError, so the program has no such schema" });
            continue;
        }
        try {
            if (r.error) e.assert("CallError", { corr: r.corr, code: r.error.code, message: r.error.message, ts: Number(at) });
            else e.assert(call.response, r.slots);
        } catch (err) {
            // The engine refusing the fact: a response missing a slot that
            // cannot be null, say.
            if (!(err instanceof Error && err.name === "DsError")) throw err;
            onReply?.({ at, call, outcome, undeliverable: err.message });
            continue;
        }
        onReply?.({ at, call, outcome, error: r.error ?? null });
    }
}
