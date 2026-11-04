// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Text for the shell (DSTRACE_INTERACTIVE.md §4.4): the pieces every listing,
// bar chart, histogram and inspector is built from. Each returns strings and
// prints nothing, so the CLI and the tests read the same output.

import { argsText } from "../core/calls.js";
import { bucketOf } from "../core/histogram.js";
import { is } from "../core/trace.js";
import { slotFlags } from "./listing.js";
import { fixed, hexAlt, jsonString, ljust, repr, rjust, roundHalfEven, width } from "./py.js";

/** @import { Call, Fact, Firing, Timeline } from "../core/timeline.js" */
/** @import { TraceRecord } from "../core/trace.js" */

export const GLYPHS = " ▁▂▃▄▅▆▇█";            // §4.4: eight heights and a blank
const PARTIAL = " ▏▎▍▌▋▊▉";                  // eighths, for shared-scale bars
export const KIND_W = 18;                    // widest message name, RuleFireAnnotation

/**
 * `seq` as 8 zero-padded hex digits (more past 2^32, never truncated).
 * @param {bigint | number} n
 */
export function hex8(n) {
    return BigInt(n).toString(16).padStart(8, "0");
}

/**
 * Seconds from the timeline's first clock: `12.0s`, `41.215s`.
 * @param {bigint} ns
 * @param {bigint} t0
 */
export function clock(ns, t0) {
    const txt = fixed(Number(ns - t0) / 1e9, 3).replace(/0+$/, "");
    return txt + (txt.endsWith(".") ? "0s" : "s");
}

/**
 * `@0000011f`, with a minus sign per record past the anchor (§3.3), or
 * `@start` before any seq.
 * @param {Timeline} tl
 * @param {number} k
 */
export function pointLabel(tl, k) {
    const nm = tl.name(k);
    if (nm === null) return "@start";
    const [n, m] = nm;
    return `@${hex8(n)}${"-".repeat(m)}`;
}

/**
 * `@0000011f  12.0s  settled` — the line every move prints.
 * @param {Timeline} tl
 * @param {number} k
 */
export function where(tl, k) {
    const t0 = tl.clockAt(0);
    const state = tl.isSettled(k) ? "settled" : tl.canonical ? "mid-cascade" : "cadence unknown";
    return `${pointLabel(tl, k)}  ${clock(tl.clockAt(k), t0)}  ${state}`;
}

/**
 * A slot or field value as the shell shows it: strings as JSON, booleans
 * lower case, everything else as Python's repr.
 * @param {unknown} v
 * @returns {string}
 */
export function value(v) {
    if (typeof v === "string") return jsonString(v);
    if (typeof v === "boolean") return v ? "true" : "false";
    return repr(v);
}

/**
 * A fact's slots, `k=v` apart by two spaces; when nothing typed them, why not
 * (core/trace.js `Decoder`: a fact-ref slot, or no schema to type by).
 * @param {Map<string, unknown> | Record<string, unknown> | null} slots
 * @param {string | null} [untyped]  why the slots are null, as the decoder said
 */
export function slotsText(slots, untyped = null) {
    if (slots === null || slots === undefined) return `(slots not typed: ${untyped ?? "nothing types this schema"})`;
    const entries = slots instanceof Map ? [...slots] : Object.entries(slots);
    return entries.map(([k, v]) => `${k}=${value(v)}`).join("  ");
}

/**
 * `Reading#3`
 * @param {{ schema: string, factId: bigint }} f
 */
export function factRef(f) {
    return `${f.schema}#${f.factId}`;
}

// ── the record listing (`list`) ────────────────────────────────────────

/**
 * Python's `v in (None, "", 0)`: equality, so False, 0.0 and 0n are in it
 * and empty bytes are not.
 * @param {unknown} v
 */
const blank = (v) => v === null || v === undefined || v === "" || v === false || v === 0 || v === 0n;

/**
 * One record as `list` shows it.
 * @param {TraceRecord} r
 */
export function recordLine(r) {
    const seq = r.seq !== null ? hex8(r.seq) : " ".repeat(8);
    let detail;
    if (is(r, "FactAssert", "FactEmit")) {
        const rule = is(r, "FactEmit") ? `  by ${r.body.rule_name}` : "";
        detail = `${r.body.schema_name}#${r.body.fact_id}  ${slotsText(r.body.slots, r.body.untyped)}${rule}`;
    } else if (is(r, "FactRetract")) detail = `#${r.body.fact_id}`;
    else if (is(r, "FactWithdraw")) detail = `#${r.body.fact_id}  ${r.body.cause_name ?? ""}`;
    else if (is(r, "RuleFireAnnotation"))
        detail = `${r.body.end ? "end" : "begin"} ${r.body.rule_name}  tt ${hexAlt(r.body.timetag)}`;
    else if (is(r, "CallIssued"))
        detail = `${r.body.service}  as ${value(r.body.correlation)}  ${argsText(r.body.args)}`;
    else if (is(r, "ClockAdvance")) detail = `clock ${r.body.clock_ns}`;
    else if (is(r, "SchemaDef")) detail = `schema ${r.body.schema_name}`;
    else if (is(r, "Slot")) detail = `${r.body.schema_name}.${r.body.slot_name}: ${r.body.kind_name || "?"}${slotFlags(r.body)}`;
    else {
        detail = Object.entries(r.body).filter(([k, v]) => k !== "seq" && k !== "clock_ns" && !blank(v))
            // A record's bytes are a hash, written as the listing writes one.
            .map(([k, v]) => `${k}=${v instanceof Uint8Array ? Array.from(v, (x) => x.toString(16).padStart(2, "0")).join("") : value(v)}`).join("  ");
    }
    return `${seq}  ${ljust(r.kind, KIND_W)}  ${detail}`;
}

/**
 * Records either side of point `k`, with the point drawn between them.
 * @param {Timeline} tl
 * @param {number} k
 * @param {number} around
 * @param {number} [offset]
 * @param {number} [limit]
 * @returns {string[]}
 */
export function listing(tl, k, around, offset = 0, limit = Infinity) {
    const lo = Math.max(0, k - around), hi = Math.min(tl.length, k + around);
    // `offset` and `limit` page the window by records (DSDB_MCP.md §10.1).
    const a = Math.min(hi, lo + offset), b = Math.min(hi, a + limit);
    const mark = `${" ".repeat(8)}  ── point ${where(tl, k)}`;
    const out = [];
    for (let i = a; i < b; i++) {
        if (i === k) out.push(mark);
        out.push(recordLine(tl.records[i]));
    }
    if (k === hi && b === hi) out.push(mark);
    return out;
}

/**
 * `[label, count, suffix]` rows on ONE scale (§4.4): at a single instant,
 * comparing rows is the point.
 * @param {Array<[string, number, string]>} rows
 * @param {number} w  the terminal's width
 */
export function bars(rows, w) {
    if (!rows.length) return ["  (nothing)"];
    const lw = Math.max(...rows.map((r) => width(r[0])));
    const peak = Math.max(...rows.map((r) => r[1])) || 1;
    const room = Math.max(8, w - lw - 16);
    return rows.map(([label, n, suffix]) => {
        const eighths = roundHalfEven(n / peak * room * 8);
        const bar = "█".repeat(Math.floor(eighths / 8)) + (eighths % 8 ? PARTIAL[eighths % 8] : "");
        return `  ${ljust(label, lw)}  ${ljust(bar, room)}  ${n}${suffix}`;
    });
}

/**
 * One glyph per bucket, scaled to `peak`.
 * @param {number[]} vals
 * @param {number} peak
 */
export function glyphRow(vals, peak) {
    if (peak <= 0) return " ".repeat(vals.length);
    return vals.map((v) => (v <= 0 ? GLYPHS[0]
        : GLYPHS[Math.max(1, Math.ceil(v / peak * 8))])).join("");
}

/**
 * Rows of `[label, bucket values, peak, now]`, EACH scaled to its own peak
 * (§4.4): a 3-fact schema must not vanish beside a 10,000-fact one. `now` is
 * "" for a series that has none.
 * @param {Array<[string, number[], number, number | ""]>} rows
 * @param {bigint[]} e  bucket edges
 * @param {bigint} t0
 * @param {bigint} pointClock
 * @param {string} point  the point's label
 * @param {[string, string]} [head]
 */
export function histogram(rows, e, t0, pointClock, point, head = ["peak", "now"]) {
    const n = e.length - 1;
    const lw = Math.max(4, ...rows.map((r) => width(r[0])));
    const left = clock(e[0], t0), right = clock(e[e.length - 1], t0);
    const axis = `${left} ` + "─".repeat(Math.max(1, n - left.length - right.length - 2)) + ` ${right}`;
    const out = [`  ${ljust("", lw)}  ${ljust(axis, n)}  ${rjust(head[0], 6)} ${rjust(head[1], 6)}`];
    for (const [label, vals, peak, now] of rows) {
        out.push(`  ${ljust(label, lw)}  ${glyphRow(vals, vals.length ? Math.max(...vals) : 0)}`
                 + `  ${rjust(String(peak), 6)} ${rjust(String(now), 6)}`);
    }
    const col = Math.min(n - 1, Math.max(0, bucketOf(pointClock, e)));
    out.push(`  ${ljust("", lw)}  ${" ".repeat(col)}▲ point ${point}`);
    let ruler = "";
    for (let i = 0; i < n; i++) ruler += i % 10 === 0 ? String(Math.floor(i / 10) % 10) : " ";
    out.push(`  ${ljust("", lw)}  ${ruler}   (@#N moves point to bucket N)`);
    return out;
}

// ── inspectors (§4.6, §4.11) and calls (§4.10) ─────────────────────────

/**
 * A fact's life: asserted where and by whom, its slots, its end, and the
 * versions either side of it.
 * @param {Timeline} tl
 * @param {Fact} f
 * @returns {string[]}
 */
export function factView(tl, f) {
    const t0 = tl.clockAt(0);
    const by = f.origin === "rule" ? `rule ${f.rule}` : "the integrator";
    const at = f.asserted + 1;
    const out = [`  ${factRef(f)}  asserted ${pointLabel(tl, at)} ${clock(tl.clockAt(at), t0)} by ${by}`];
    for (const [k, v] of Object.entries(f.slots ?? {})) out.push(`    ${ljust(k, 14)} ${value(v)}`);
    if (f.slots === null) out.push(`    ${slotsText(null, f.untyped)}`);
    if (f.ended === null) out.push("  withdrawn      not yet");
    else {
        const end = f.ended + 1;
        const how = f.endKind === "withdraw" ? f.cause : "retracted by the integrator";
        out.push(`  withdrawn      ${pointLabel(tl, end)} ${clock(tl.clockAt(end), t0)}  ${how}`);
    }
    /** @type {Array<[string, bigint | null]>} */
    const versions = [["prior version", f.prior], ["next version", f.successor]];
    for (const [label, other] of versions) {
        const o = other === null ? undefined : tl.facts.get(other);
        if (o === undefined) continue;
        const span = `${pointLabel(tl, o.asserted + 1)}..${o.ended !== null ? pointLabel(tl, o.ended + 1) : "now"}`;
        out.push(`  ${ljust(label, 14)} ${factRef(o)}, held ${span}   (\`<\` / \`>\`)`);
    }
    return out;
}

/**
 * A firing on one line: its rule, timetag and effects, its `log` lines among
 * them where the session's engine heard them (as `firingView` lists them). A
 * trace records no `log` ([RFCS.3.6]), so a firing with no effect recorded
 * and no line heard says so.
 * @param {Timeline} tl
 * @param {number} n  its row number
 * @param {Firing} fr
 */
export function firingLine(tl, n, fr) {
    const begin = tl.records[fr.begin];
    const logs = (is(begin, "RuleFireAnnotation") ? begin.body.logs : undefined) || [];
    const effects = [...fr.effects.map((i) => effectText(tl, i)), ...logs.map((l) => `log ${l}`)];
    return `  ${n}  ${ljust(fr.rule, 16)}  tt ${hexAlt(fr.timetag)}   `
        + (effects.length ? effects.join("; ") : "(no fact or call recorded)");
}

/**
 * A firing's effect: the record at index `i`, briefly.
 * @param {Timeline} tl
 * @param {number} i
 */
export function effectText(tl, i) {
    const r = tl.records[i];
    if (is(r, "FactEmit")) return `emit ${r.body.schema_name}#${r.body.fact_id}`;
    // A publish names no fact: none is in working memory ([LTIE.4.3]).
    if (is(r, "FactPublish")) return `publish ${r.body.schema_name}`;
    if (is(r, "FactWithdraw")) return `withdraw #${r.body.fact_id} ${r.body.cause_name ?? ""}`;
    if (is(r, "CallIssued")) {
        const c = tl.calls.find((x) => x.issued === i);
        const tail = c ? ` (call ${c.number}, ${c.outcome})` : "";
        return `call ${r.body.service} as ${value(r.body.correlation)}${tail}`;
    }
    return r.kind;
}

/**
 * A firing's inspector: when it began, what it matched, what it did. A
 * firing begins at its RuleFireAnnotation, which holds a live engine's log
 * lines.
 * @param {Timeline} tl
 * @param {Firing} fr
 * @returns {string[]}
 */
export function firingView(tl, fr) {
    const t0 = tl.clockAt(0);
    const at = fr.begin + 1;
    const out = [`  ${fr.rule}  tt ${hexAlt(fr.timetag)}  began ${pointLabel(tl, at)} ${clock(tl.clockAt(at), t0)}`];
    if (fr.matched === null) out.push("  matched   (not recorded in a trace)");
    else {
        const refs = fr.matched.map((id) => {
            const f = tl.facts.get(id);
            return f !== undefined ? factRef(f) : `#${id}`;
        });
        out.push("  matched   " + (refs.join(", ") || "(no positive pattern)"));
    }
    out.push("  effects");
    const begin = tl.records[fr.begin];
    const logs = (is(begin, "RuleFireAnnotation") ? begin.body.logs : undefined) || [];
    if (!fr.effects.length && !logs.length)
        out.push("    (none recorded: log and cache are not in traces)");
    fr.effects.forEach((i, n) => out.push(`    ${n + 1}  ${effectText(tl, i)}`));
    for (const line of logs) out.push(`       log ${line}`);
    return out;
}

/**
 * A call at point `k`: what was asked, by whom, and where it stands.
 * @param {Timeline} tl
 * @param {Call} c
 * @param {number} k
 */
export function callLine(tl, c, k) {
    const t0 = tl.clockAt(0);
    const waited = clock(tl.clockAt(k), tl.clockAt(c.issued + 1)).replace(/s+$/, "");
    // A call that does not wait is `no response` until a CallError fails it.
    const state = c.waitingAt(k) ? `waiting ${waited}s`
        : !c.waits && (c.resolved === null || c.resolved >= k) ? "no response"
        : `${c.outcome} ${pointLabel(tl, (c.resolved ?? 0) + 1)}`;
    return `  ${c.number}  ${c.service}  as ${value(c.corr)}  ${argsText(c.args)}  `
        + `by ${c.rule} tt ${hexAlt(c.timetag)}  issued ${pointLabel(tl, c.issued + 1)} `
        + `${clock(tl.clockAt(c.issued + 1), t0)}  ${state}`;
}
