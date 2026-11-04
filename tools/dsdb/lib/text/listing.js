// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The plain listing: a trace as text, one line per atom (more for a header).
// The port of tools/dstrace.py's Renderer, byte for byte (DSDB.md §1), over
// the records core/trace.js builds, whose bodies are its `Bodies`.
//
// Two string forms appear, and they differ: `str(v)` in the header's `k=v`
// lines (a string bare, bytes as hex) and Python's `repr(v)` everywhere else
// (a string quoted).

import { argsText } from "../core/calls.js";
import { is } from "../core/trace.js";
import { ljust, repr } from "./py.js";

/** @import { FactSlots, TraceRecord } from "../core/trace.js" */

/** The kind column's width: the widest message name among the atoms
    DECODED names, RuleFireAnnotation. Fixed before any record is read, so
    the column never re-aligns partway down a file. */
export const W = 18;

/** The atoms core/trace.js decodes a body for; any other is named with its
    length. */
const DECODED = new Set(["StreamHeader", "SchemaDef", "Slot", "FactAssert", "ExternalAssert", "FactRetract",
                         "FactEmit", "ClockAdvance", "RuleFireAnnotation", "FactWithdraw", "CallIssued", "PumpBoundary",
                         "ComputationError", "TypeError", "BoundsError", "EngineError"]);

/**
 * A Slot atom's flags, as `  [key nullable]`, or "" for none: its identity
 * role by name (slot.proto's IdentityRole: KEY, MUTABLE; nothing for none,
 * and for ENGINE, the `ts` slot no author marks), then sampled, retained and
 * nullable; a mutable slot is never flagged `key`. The plain listing's and
 * the shell's (text/render.js).
 * @param {{ identity_role: bigint, sampled: boolean, retained: boolean, nullable: boolean }} b
 */
export function slotFlags(b) {
    const role = b.identity_role === 1n ? "key" : b.identity_role === 2n ? "mutable" : null;
    const flags = [role, b.sampled ? "sampled" : null, b.retained ? "retained" : null, b.nullable ? "nullable" : null]
        .filter((f) => f !== null);
    return flags.length ? `  [${flags.join(" ")}]` : "";
}

/**
 * `seq` as 8 zero-padded hex digits, or 8 blanks for an atom carrying none.
 * @param {bigint | number | null | undefined} seq
 */
export function seqCol(seq) {
    return seq === null || seq === undefined ? " ".repeat(8) : BigInt(seq).toString(16).padStart(8, "0");
}

/**
 * A header field's value: a string bare, bytes (a hash) as hex, as
 * everything else that names a hash writes it, not as a Python bytes literal,
 * anything else as Python's `repr`.
 * @param {unknown} v
 */
function str(v) {
    if (typeof v === "string") return v;
    if (v instanceof Uint8Array) return Array.from(v, (x) => x.toString(16).padStart(2, "0")).join("");
    return repr(v);
}

/**
 * Python's `v not in (None, "", 0)`: None, the empty string, and anything
 * equal to 0 (False, 0.0) are left out. Empty bytes are not.
 * @param {unknown} v
 */
const shown = (v) => !(v === null || v === undefined || v === "" || v === 0n || v === 0 || v === false);

/**
 * A body's own `seq`, or null for an atom with none.
 * @param {Record<string, unknown>} fields
 * @returns {bigint | null}
 */
const seqOf = (fields) => (typeof fields.seq === "bigint" ? fields.seq : null);

/**
 * One record's lines, and its seq for `--from` (null for an atom with none).
 * @param {TraceRecord} rec
 * @returns {[bigint | null, string[]]}
 */
export function recordLines(rec) {
    const name = rec.kind;
    /** @type {Record<string, unknown>} the body's fields, as core/trace.js's `Bodies` has them */
    const fields = rec.body;
    /** @param {bigint | null} s */
    const col = (s) => `${seqCol(s)}  ${ljust(name, W)}  `;
    if (!DECODED.has(rec.kind))
        return [null, [`${col(null)}<${fields.body_len} bytes; no body decoded for this atom>`]];
    if (is(rec, "SchemaDef")) {
        const note = rec.body.proto_source ? "" : "   (no proto_source: registered at runtime)";
        return [null, [`${col(null)}schema ${rec.body.schema_name}${note}`]];
    }
    if (is(rec, "Slot")) {
        const b = rec.body;
        return [null, [`${col(null)}${b.schema_name}.${b.slot_name}: ${b.kind_name || "?"}${slotFlags(b)}`]];
    }
    if (is(rec, "StreamHeader"))
        return [null, Object.keys(fields).sort().filter((k) => shown(fields[k])).map((k) => `${col(null)}${k}=${str(fields[k])}`)];
    if (is(rec, "FactAssert", "FactRetract", "FactEmit"))
        return [seqOf(fields), [fact(name, rec.body)]];
    if (is(rec, "ExternalAssert")) {
        // The received fact's schema and the facts the input asserted, in
        // [RFCS.24.3]'s order; the FactExternal's values are not spelled out.
        const b = rec.body;
        /** @type {Array<[string, bigint]>} */
        const set = [["ttl_ns", b.ttl_ns], ["clock_ns", b.clock_ns]];
        const rest = set.filter(([, v]) => shown(v)).map(([k, v]) => `  ${k}=${repr(v)}`).join("");
        return [seqOf(fields), [`${col(seqOf(fields))}${b.fact.schema}  fact_ids=[${b.fact_ids.join(", ")}]${rest}`]];
    }
    if (is(rec, "CallIssued")) {
        // The arguments as one JSON object, as the shell shows a call's.
        const args = rec.body.args;
        const rest = Object.entries(fields).filter(([k, v]) => k !== "seq" && (k === "args" ? args.length : shown(v)))
            .map(([k, v]) => `${k}=${repr(k === "args" ? argsText(args) : v)}`).join("  ");
        return [seqOf(fields), [`${col(seqOf(fields))}${rest}`]];
    }
    const rest = Object.entries(fields).filter(([k, v]) => k !== "seq" && shown(v))
        .map(([k, v]) => `${k}=${repr(v)}`).join("  ");
    return [seqOf(fields), [`${col(seqOf(fields))}${rest}`]];
}

/**
 * An asserted, emitted or retracted fact's line.
 * @param {string} name  the atom's message name
 * @param {{ fact_id?: bigint, schema_name?: string, slots?: FactSlots | null, untyped?: string | null,
 *     seq?: bigint }} b
 */
function fact(name, b) {
    const seq = b.seq ?? null;
    let head = `${seqCol(seq)}  ${ljust(name, W)}  ${b.schema_name ?? "?"}`;
    if (b.fact_id !== null && b.fact_id !== undefined) head += `#${b.fact_id}`;
    // A FactRetract carries no body at all.
    if (name === "FactRetract") return head;
    if (b.slots === null || b.slots === undefined)
        // [LFST.8.10]: typed values need the schema table; the envelope still
        // decoded ([LFST.8.2]). Say what is missing, not an empty fact.
        return head + `   (slots not typed: ${b.untyped ?? "nothing types this schema"})`;
    const body = Object.entries(b.slots).map(([k, v]) => `${k}=${repr(v)}`).join("  ");
    return body ? `${head}  ${body}` : head;
}
