// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Writing facts out (DSDB.md §9): batch mode's published facts, one file per
// schema in CSV, TSV or JSONL, or one JSON document of every schema. Every
// format writes what core/facts.js reads, so a run's output can be the next
// run's input.
//
// Values arrive as @ds-lang/ds gives them (Int, Time, Date and Duration a BigInt,
// Float a Number, Json as JSON text, Bytes a Uint8Array, a fact reference a
// @ds-lang/ds Fact); the schema says which is which, since Json and String are
// both strings.

import { AT } from "./facts.js";

/** @import { SlotValue } from "@ds-lang/ds" */

/** @typedef {{ name: string, slots: Array<{ name: string, type: string }> }} OutSchema */
/** @typedef {{ at: bigint, slots: Record<string, SlotValue> }} OutRow  a published fact, and when */

/** @type {Array<[string, bigint]>} */
const UNITS = [["d", 86_400_000_000_000n], ["h", 3_600_000_000_000n], ["min", 60_000_000_000n],
               ["s", 1_000_000_000n], ["ms", 1_000_000n], ["us", 1_000n], ["ns", 1n]];

/**
 * The exact duration literal for `ns`, in the largest unit that divides it:
 * `2_s`, `1500_ms`, `0_s`. Exact, readable, and what `@at` reads back.
 * @param {bigint} ns
 */
export function durationLiteral(ns) {
    if (ns === 0n) return "0_s";
    for (const [u, size] of UNITS) if (ns % size === 0n) return `${ns / size}_${u}`;
    return `${ns}_ns`;
}

/**
 * A Float as text the reader takes back: shortest round-trip digits, and
 * `inf`, `-inf`, `nan` for the three values JSON has no number for.
 * @param {number} x
 */
function floatText(x) {
    if (Number.isNaN(x)) return "nan";
    if (x === Infinity) return "inf";
    if (x === -Infinity) return "-inf";
    return Object.is(x, -0) ? "-0.0" : String(x);
}

/** @param {Uint8Array} bytes */
export function base64(bytes) {
    let bin = "";
    for (const b of bytes) bin += String.fromCharCode(b);
    return btoa(bin);
}

/**
 * A slot value as cell text, or null for a null. The slot's type says which
 * of `@ds-lang/ds`'s representations `v` is.
 * @param {SlotValue | undefined} v
 * @param {string | undefined} type
 * @returns {string | null}
 */
function cellText(v, type) {
    if (v === null || v === undefined) return null;
    switch (type) {
    case "Int": case "Time": case "Date": case "Duration":
        return BigInt(/** @type {bigint} */ (v)).toString();
    case "Float": return floatText(/** @type {number} */ (v));
    case "Bool": return v ? "true" : "false";
    case "String": case "Json": return /** @type {string} */ (v);
    case "Bytes": return base64(/** @type {Uint8Array} */ (v));
    default:
        // A reference to another fact: its id, for reading. The loader
        // refuses it as input, since a fact id is this run's own.
        return typeof v === "object" && "id" in v ? `#${v.id}` : String(v);
    }
}

/**
 * A slot value as JSON source text. The slot's type says which of `@ds-lang/ds`'s
 * representations `v` is.
 * @param {SlotValue | undefined} v
 * @param {string | undefined} type
 * @returns {string}
 */
export function jsonValue(v, type) {
    if (v === null || v === undefined) return "null";
    switch (type) {
    case "Int": case "Time": case "Date": case "Duration":
        return BigInt(/** @type {bigint} */ (v)).toString();   // exact at any width
    case "Float": {
        const x = /** @type {number} */ (v);
        return Number.isFinite(x) ? floatText(x) : JSON.stringify(floatText(x));
    }
    case "Bool": return v ? "true" : "false";
    case "Json": {
        // An object or array is written as itself, readably. Anything else
        // is written as a string of its JSON text: a JSON `null` or string
        // written bare would read back as a null slot or as text that is not
        // JSON (the loader takes a JSON string in a Json slot as JSON text).
        const text = /** @type {string} */ (v);
        return /^\s*[{[]/.test(text) ? text : JSON.stringify(text);
    }
    default: return JSON.stringify(cellText(v, type));
    }
}

/** @param {OutSchema} schema */
const columns = (schema) => [AT, ...schema.slots.map((s) => s.name)];

/** @param {string | null} t */
function csvCell(t) {
    if (t === null) return "";                             // a bare empty field is null
    return t === "" || /[",\r\n]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t;
}

/** @type {Record<string, string>} */
const TSV_ESCAPED = { "\\": "\\\\", "\t": "\\t", "\n": "\\n", "\r": "\\r" };

/** @param {string | null} t */
function tsvCell(t) {
    if (t === null) return "\\N";
    return t.replace(/[\\\t\n\r]/g, (c) => TSV_ESCAPED[c]);
}

/**
 * One schema's rows in one per-schema format.
 * @param {OutSchema} schema
 * @param {OutRow[]} rows
 * @param {"csv" | "tsv" | "jsonl"} format
 * @returns {string}
 */
export function writeRows(schema, rows, format) {
    const typeOf = new Map(schema.slots.map((s) => [s.name, s.type]));
    /** @param {OutRow} r */
    const cellsOf = (r) => [durationLiteral(r.at), ...schema.slots.map((s) => cellText(r.slots[s.name], s.type))];
    if (format === "csv")
        return [columns(schema).map(csvCell), ...rows.map((r) => cellsOf(r).map(csvCell))]
            .map((cells) => cells.join(",") + "\r\n").join("");
    if (format === "tsv")
        return [columns(schema).map(tsvCell), ...rows.map((r) => cellsOf(r).map(tsvCell))]
            .map((cells) => cells.join("\t") + "\n").join("");
    if (format === "jsonl")
        return rows.map((r) => jsonRow(r, schema, typeOf) + "\n").join("");
    throw new TypeError(`no per-schema format ${format}`);
}

/**
 * @param {OutRow} r
 * @param {OutSchema} schema
 * @param {Map<string, string>} typeOf
 */
function jsonRow(r, schema, typeOf) {
    const fields = [`${JSON.stringify(AT)}: ${JSON.stringify(durationLiteral(r.at))}`];
    for (const s of schema.slots)
        fields.push(`${JSON.stringify(s.name)}: ${jsonValue(r.slots[s.name], typeOf.get(s.name))}`);
    return `{${fields.join(", ")}}`;
}

/**
 * Every schema's rows as one JSON document, schemas in the order given, one
 * row per line: `{ "Reading": [ … ], "Alarm": [] }`.
 * @param {OutSchema[]} schemas
 * @param {Map<string, OutRow[]>} rowsBySchema
 */
export function writeDoc(schemas, rowsBySchema) {
    if (!schemas.length) return "{}\n";
    const parts = schemas.map((schema) => {
        const typeOf = new Map(schema.slots.map((s) => [s.name, s.type]));
        const rows = rowsBySchema.get(schema.name) ?? [];
        const body = rows.length
            ? "[\n" + rows.map((r) => "    " + jsonRow(r, schema, typeOf)).join(",\n") + "\n  ]"
            : "[]";
        return `  ${JSON.stringify(schema.name)}: ${body}`;
    });
    return "{\n" + parts.join(",\n") + "\n}\n";
}
