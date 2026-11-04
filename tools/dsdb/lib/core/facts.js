// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Fact files (DSDB.md §8): facts given as `<schema>.csv`, `.tsv` or `.jsonl`,
// one file per schema, as many as wanted. Each row is an integrator assert;
// all the files' rows are merged by time and fed to the program, a pump after
// each, as a live session would be driven by hand.
//
// This is INPUT PARSING, not a codec: nothing here reads or writes the DS
// fact-stream or artefact formats (PLAN_jsds §7). Values are typed by the
// program's own schema, as @ds-lang/ds's `schemas` reports it.
//
// NUMBERS: a row's time is BigInt nanoseconds; Int slots are BigInt, exactly,
// from any format; Float slots are Numbers.

import { durationNs, MAX_DURATION_NS } from "./grammar.js";

/** @import { Engine, Fact } from "@ds-lang/ds" */

/** @typedef {"csv" | "tsv" | "jsonl"} RowFormat  a per-schema file's format */

/** @type {Map<string, RowFormat>} per-schema formats: the file's name is the schema */
export const FORMATS = new Map([[".csv", "csv"], [".tsv", "tsv"], [".jsonl", "jsonl"]]);

/** The single-file format: one JSON object, every schema's rows under its
    name, `{ "Reading": [ {…}, … ], "Alarm": [] }`. What batch mode writes to
    stdout, and so readable back. */
export const DOC = ".json";

/** The one column that is not a slot: the row's time. `@` cannot start a DS
    identifier, so it cannot collide with a slot. */
export const AT = "@at";

/**
 * Why a column is refused: not a slot of the schema, or, starting `@`, not
 * `@at`. There is no `@ttl`: no public entry point sets a per-fact TTL, so a
 * fact takes its schema's.
 * @param {string} name
 * @param {string} schema
 */
function notASlot(name, schema) {
    if (!name.startsWith("@")) return `\`${name}\` is not a slot of ${schema}`;
    return `\`${name}\` is not a fact-file column: \`@at\` is the only one that is not a slot`
        + (name === "@ttl" ? "; a fact takes its schema's TTL" : "");
}

/** A user's mistake in a fact file, with where. */
export class FactFileError extends Error {
    /**
     * @param {string} file
     * @param {number | null} line  0 or null for the file as a whole
     * @param {string} message
     */
    constructor(file, line, message) {
        super(`${file}${line ? `:${line}` : ""}: ${message}`);
        this.name = "FactFileError";
        this.file = file;
        this.line = line;
    }
}

/**
 * The format and the schema a fact file's name gives: `Reading.csv` is csv
 * rows of `Reading`; a `.json` document names its schemas inside. Null when
 * the name is not a fact file's.
 * @param {string} path
 * @returns {{ format: "json", schema: null } | { format: RowFormat, schema: string } | null}
 */
export function factFileName(path) {
    const base = path.split(/[\\/]/).pop() ?? "";
    if (base.toLowerCase().endsWith(DOC) && base.length > DOC.length) return { format: "json", schema: null };
    for (const [ext, format] of FORMATS) {
        if (base.toLowerCase().endsWith(ext) && base.length > ext.length)
            return { format, schema: base.slice(0, -ext.length) };
    }
    return null;
}

// ── cells ─────────────────────────────────────────────────────────────────
//
// Every format parses to rows of cells, and a cell says what the file wrote
// without typing it yet:
//   { null: true }                     absent-as-null (CSV bare empty, TSV \N, JSON null)
//   { text: "…" }                      a CSV/TSV field, or a JSON string's value
//   { json: "…", kind: "number"|… }    a JSON value other than a string, as its source text

/** @typedef {{ null: true, bare?: boolean, text?: undefined, json?: undefined, kind?: undefined }} NullCell */
/** @typedef {{ text: string, null?: undefined, bare?: undefined, json?: undefined, kind?: undefined }} TextCell */
/** @typedef {{ json: string, kind: "number" | "boolean" | "object" | "array", null?: undefined,
    bare?: undefined, text?: undefined }} JsonCell */
/** @typedef {NullCell | TextCell | JsonCell} Cell */

/** @typedef {{ line: number, cells: Map<string, Cell> }} Row  one record, its cells by column */
/** @typedef {{ header: string[] | null, rows: Row[] }} Parsed  a file's rows, and its header if it has one */

/**
 * CSV, RFC 4180: comma-separated, `"`-quoted fields with `""` for a quote,
 * CRLF or LF line ends. A bare empty field is null; a quoted `""` is the empty
 * string. The first record is the header.
 * @param {string} text
 * @param {string} file  for messages
 * @returns {Parsed}
 */
export function parseCsv(text, file) {
    /** @type {Array<{ line: number, cells: Array<NullCell | TextCell> }>} */
    const records = [];
    /** @type {Array<NullCell | TextCell>} */
    let fields = [];
    let field = "", quoted = false, inQuotes = false, line = 1, start = 1;
    const endField = () => {
        fields.push(!quoted && field === "" ? { null: true, bare: true } : { text: field });
        field = "";
        quoted = false;
    };
    const endRecord = () => {
        endField();
        if (!(fields.length === 1 && fields[0].null)) records.push({ line: start, cells: fields });
        fields = [];
        start = line;
    };
    for (let i = 0; i < text.length; i++) {
        const ch = text[i];
        if (inQuotes) {
            if (ch === '"') {
                if (text[i + 1] === '"') { field += '"'; i++; }
                else inQuotes = false;
            } else {
                if (ch === "\n") line++;
                field += ch;
            }
        } else if (ch === '"') {
            if (field !== "") throw new FactFileError(file, line, "a quote inside an unquoted field");
            inQuotes = quoted = true;
        } else if (ch === ",") {
            endField();
        } else if (ch === "\n" || ch === "\r") {
            if (ch === "\r" && text[i + 1] === "\n") i++;
            line++;
            endRecord();
        } else {
            if (quoted) throw new FactFileError(file, line, "text after a closing quote");
            field += ch;
        }
    }
    if (inQuotes) throw new FactFileError(file, start, "a quoted field is not closed");
    if (field !== "" || quoted || fields.length) endRecord();
    return header(records, file);
}

/**
 * TSV: tab-separated, one record per line, no quoting. Within a field `\t`,
 * `\n`, `\r` and `\\` are escapes, and a field of exactly `\N` is null (the
 * PostgreSQL text format's conventions). An empty field is the empty string.
 * @param {string} text
 * @param {string} file  for messages
 * @returns {Parsed}
 */
export function parseTsv(text, file) {
    /** @type {Array<{ line: number, cells: Array<NullCell | TextCell> }>} */
    const records = [];
    text.split(/\r?\n/).forEach((ln, i) => {
        if (ln === "") return;
        records.push({ line: i + 1, cells: ln.split("\t").map((f) => (f === "\\N" ? { null: true }
            : { text: unescapeTsv(f, file, i + 1) })) });
    });
    return header(records, file);
}

/** @type {Record<string, string>} TSV's escapes, by the character after the backslash */
const TSV_ESCAPES = { t: "\t", n: "\n", r: "\r", "\\": "\\" };

/**
 * @param {string} f
 * @param {string} file
 * @param {number} line
 */
function unescapeTsv(f, file, line) {
    return f.replace(/\\(.)/g, (_, c) => {
        const out = TSV_ESCAPES[c];
        if (out === undefined) throw new FactFileError(file, line, `\`\\${c}\` is not an escape (\\t \\n \\r \\\\ \\N)`);
        return out;
    });
}

/**
 * The first record as the column names, and the rest as rows by column.
 * @param {Array<{ line: number, cells: Array<NullCell | TextCell> }>} records
 * @param {string} file
 * @returns {Parsed}
 */
function header(records, file) {
    if (!records.length) return { header: [], rows: [] };
    const [head, ...rows] = records;
    const names = head.cells.map((c, i) => {
        if (c.null || c.text === "") throw new FactFileError(file, head.line, `column ${i + 1} has no name`);
        return c.text;
    });
    const dup = names.find((n, i) => names.indexOf(n) !== i);
    if (dup) throw new FactFileError(file, head.line, `column \`${dup}\` twice`);
    for (const r of rows) {
        if (r.cells.length !== names.length)
            throw new FactFileError(file, r.line, `${r.cells.length} fields, the header has ${names.length}`);
    }
    return { header: names, rows: rows.map((r) => ({ line: r.line, cells: new Map(names.map((n, i) => [n, r.cells[i]])) })) };
}

/**
 * JSONL: one JSON object per line, keyed by slot name. Values keep their
 * source text, so an integer past 2^53 and a `Json` slot's value are exact:
 * Node 20's JSON.parse gives neither.
 * @param {string} text
 * @param {string} file  for messages
 * @returns {Parsed}
 */
export function parseJsonl(text, file) {
    /** @type {Row[]} */
    const rows = [];
    text.split(/\r?\n/).forEach((ln, i) => {
        if (ln.trim() === "") return;
        const p = new JsonScan(ln, file, i + 1);
        rows.push({ line: i + 1, cells: p.object() });
        p.end();
    });
    return { header: null, rows };
}

/**
 * The single-file format: `{ "Schema": [ {slot: value, …}, … ], … }`. Rows
 * are typed exactly as JSONL's; a row's line is the line its object starts on.
 * @param {string} text
 * @param {string} file  for messages
 * @returns {Map<string, Row[]>}
 */
export function parseJsonDoc(text, file) {
    const p = new JsonScan(text, file, null);
    p.ws();
    if (p.s[p.i] !== "{") p.fail("the file must be one JSON object of schema name to rows");
    p.i++;
    /** @type {Map<string, Row[]>} */
    const out = new Map();
    p.ws();
    if (p.s[p.i] === "}") { p.i++; p.end(); return out; }
    for (;;) {
        p.ws();
        if (p.s[p.i] !== '"') p.fail("a schema name must be a string");
        const schema = p.string();
        if (out.has(schema)) p.fail(`schema \`${schema}\` twice`);
        p.ws();
        if (p.s[p.i] !== ":") p.fail("expected `:`");
        p.i++;
        p.ws();
        if (p.s[p.i] !== "[") p.fail(`\`${schema}\` must be an array of rows`);
        p.i++;
        /** @type {Row[]} */
        const rows = [];
        p.ws();
        if (p.s[p.i] === "]") p.i++;
        else {
            for (;;) {
                p.ws();
                const line = p.lineHere();
                rows.push({ line, cells: p.object() });
                p.ws();
                if (p.s[p.i] === ",") { p.i++; continue; }
                if (p.s[p.i] === "]") { p.i++; break; }
                p.fail("expected `,` or `]`");
            }
        }
        out.set(schema, rows);
        p.ws();
        if (p.s[p.i] === ",") { p.i++; continue; }
        if (p.s[p.i] === "}") { p.i++; break; }
        p.fail("expected `,` or `}`");
    }
    p.end();
    return out;
}

/**
 * One JSON object on one line, split into its top-level fields as cells: what
 * a JSONL row is, and what a reply on the calls socket is (§9.1).
 * @param {string} text
 * @param {string} what  the source, for messages
 * @returns {Map<string, Cell>}
 */
export function scanObject(text, what) {
    const p = new JsonScan(text, what, null);
    const cells = p.object();
    p.end();
    return cells;
}

/** Just enough JSON to split an object into top-level fields with their
    source text. Nested values are validated and kept as text. `line` is the
    line the text is on (JSONL), or null for a whole document, where the line
    is counted from the offset. */
class JsonScan {
    /**
     * @param {string} s
     * @param {string} file
     * @param {number | null} line
     */
    constructor(s, file, line) {
        this.s = s;
        this.i = 0;
        this.file = file;
        this.line = line;
    }

    lineHere() {
        if (this.line !== null) return this.line;
        let n = 1;
        for (let j = 0; j < this.i; j++) if (this.s[j] === "\n") n++;
        return n;
    }

    /**
     * @param {string} msg
     * @returns {never}
     */
    fail(msg) {
        const col = this.line !== null ? this.i + 1 : this.i - this.s.lastIndexOf("\n", this.i - 1);
        throw new FactFileError(this.file, this.lineHere(), `${msg} (column ${col})`);
    }

    ws() {
        while (this.i < this.s.length && " \t\r\n".includes(this.s[this.i])) this.i++;
    }

    end() {
        this.ws();
        if (this.i !== this.s.length) this.fail("more after the object");
    }

    /** @returns {Map<string, Cell>} */
    object() {
        this.ws();
        if (this.s[this.i] !== "{") this.fail("a line must be one JSON object");
        this.i++;
        /** @type {Map<string, Cell>} */
        const out = new Map();
        this.ws();
        if (this.s[this.i] === "}") { this.i++; return out; }
        for (;;) {
            this.ws();
            if (this.s[this.i] !== '"') this.fail("a key must be a string");
            const key = this.string();
            if (out.has(key)) this.fail(`key \`${key}\` twice`);
            this.ws();
            if (this.s[this.i] !== ":") this.fail("expected `:`");
            this.i++;
            this.ws();
            out.set(key, this.cell());
            this.ws();
            if (this.s[this.i] === ",") { this.i++; continue; }
            if (this.s[this.i] === "}") { this.i++; return out; }
            this.fail("expected `,` or `}`");
        }
    }

    /** @returns {Cell} */
    cell() {
        const c = this.s[this.i];
        if (c === '"') return { text: this.string() };
        const from = this.i;
        const kind = this.value();
        if (kind === "null") return { null: true };
        if (kind === "string") return this.fail("a string is read as text");     // not reached: `"` is above
        return { json: this.s.slice(from, this.i), kind };
    }

    /**
     * Skip one value; return its kind.
     * @returns {"string" | "object" | "array" | "null" | "boolean" | "number"}
     */
    value() {
        this.ws();
        const c = this.s[this.i];
        if (c === '"') { this.string(); return "string"; }
        if (c === "{" || c === "[") { this.nested(); return c === "{" ? "object" : "array"; }
        for (const w of ["true", "false", "null"]) {
            if (this.s.startsWith(w, this.i)) { this.i += w.length; return w === "null" ? "null" : "boolean"; }
        }
        const m = /^-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?/.exec(this.s.slice(this.i));
        if (!m) return this.fail("not a JSON value");
        this.i += m[0].length;
        return "number";
    }

    nested() {
        const close = this.s[this.i] === "{" ? "}" : "]";
        const isObj = close === "}";
        this.i++;
        this.ws();
        if (this.s[this.i] === close) { this.i++; return; }
        for (;;) {
            this.ws();
            if (isObj) {
                if (this.s[this.i] !== '"') this.fail("a key must be a string");
                this.string();
                this.ws();
                if (this.s[this.i] !== ":") this.fail("expected `:`");
                this.i++;
            }
            this.value();
            this.ws();
            if (this.s[this.i] === ",") { this.i++; continue; }
            if (this.s[this.i] === close) { this.i++; return; }
            this.fail(`expected \`,\` or \`${close}\``);
        }
    }

    /** @returns {string} */
    string() {
        const from = this.i;
        this.i++;
        while (this.i < this.s.length && this.s[this.i] !== '"') {
            if (this.s[this.i] === "\\") this.i++;
            else if (this.s.charCodeAt(this.i) < 0x20) this.fail("a control character in a string");
            this.i++;
        }
        if (this.i >= this.s.length) this.fail("a string is not closed");
        this.i++;
        try {
            return JSON.parse(this.s.slice(from, this.i));
        } catch {
            return this.fail("a bad escape in a string");
        }
    }
}

/**
 * Parse a fact file's text by its format.
 * @param {string} text
 * @param {RowFormat} format
 * @param {string} file  for messages
 * @returns {Parsed}
 */
export function parseFactFile(text, format, file) {
    if (format === "csv") return parseCsv(text, file);
    if (format === "tsv") return parseTsv(text, file);
    if (format === "jsonl") return parseJsonl(text, file);
    throw new TypeError(`no fact file format ${format}`);
}

// ── typing, by the program's schema ──────────────────────────────────────

const INT = /^-?\d+$/;
const FLOAT = /^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$|^[+-]?(inf|infinity|nan)$/i;

/** @typedef {{ name: string, type: string, nullable: boolean }} SlotShape  a slot as `@ds-lang/ds` describes it */
/** @typedef {{ name: string, slots: SlotShape[] }} SchemaShape  a schema as `@ds-lang/ds`'s `schemas` gives it */
/** @typedef {bigint | number | string | boolean | Uint8Array | null} CellValue  a typed cell */

/**
 * A fact file's row, typed: its file and line, its schema, its time, and the
 * slots it gave.
 * @typedef {object} FactRow
 * @property {string} file
 * @property {number} line
 * @property {string} schema
 * @property {bigint} at     nanoseconds from the start
 * @property {Record<string, CellValue>} slots
 * @property {boolean} stamped  the schema declares `ts` and the row gave none:
 *     `feed` supplies it, as a host supplies source time ([LFAC.9.2])
 */

/**
 * One cell as the slot's type. Throws a FactFileError naming the slot.
 * @param {Cell} cell
 * @param {SlotShape} slot  `@ds-lang/ds`'s slot description
 * @param {string} file
 * @param {number | null} line
 * @returns {CellValue}
 */
function typeCell(cell, slot, file, line) {
    /** @type {(why: string) => never} */
    const bad = (why) => { throw new FactFileError(file, line, `slot \`${slot.name}\` (${slot.type}): ${why}`); };
    if (cell.null) {
        if (slot.nullable) return null;
        // A CSV export writes an empty string as a bare empty field, so in a
        // String slot that cannot be null, that is what it is.
        if (cell.bare && slot.type === "String") return "";
        bad("null in a slot that is not nullable");
    }
    const t = cell.text ?? cell.json;
    switch (slot.type) {
    case "Int":
    // The temporal types are Int-represented, and read as their integer:
    // nanoseconds since the epoch, days since the epoch, nanoseconds.
    case "Time":
    case "Date":
    case "Duration":
        // A JSON string of digits is an Int too: JSON producers write 64-bit
        // integers as strings to keep them exact.
        if (cell.kind && cell.kind !== "number") bad(`want an integer, got JSON ${cell.kind}`);
        if (!INT.test(t)) bad(`\`${t}\` is not an integer`);
        return BigInt(t);
    case "Float": {
        if (cell.kind && cell.kind !== "number") bad(`want a number, got JSON ${cell.kind}`);
        if (!FLOAT.test(t.trim())) bad(`\`${t}\` is not a number`);
        const low = t.trim().toLowerCase().replace(/^\+/, "");
        if (low === "inf" || low === "infinity") return Infinity;
        if (low === "-inf" || low === "-infinity") return -Infinity;
        if (low.endsWith("nan")) return NaN;
        return Number(t);
    }
    case "Bool":
        if (cell.kind === "boolean" || cell.text === "true" || cell.text === "false") return t === "true";
        return bad(`\`${t}\` is not true or false`);
    case "String":
        if (cell.text === undefined) bad(`want a string, got JSON ${cell.kind}`);
        return cell.text;
    case "Json":
        // CSV and TSV: the cell IS JSON text. JSONL: a string is JSON text too
        // (so either form works); any other value is its own source text.
        // libds parses it, and refuses what is not JSON.
        return cell.text !== undefined ? cell.text : cell.json;
    case "Bytes":
        if (cell.text === undefined) bad(`want base64 text, got JSON ${cell.kind}`);
        return base64(cell.text, bad);
    default:
        return bad("a reference to another fact cannot come from a file");
    }
}

/**
 * @param {string} s
 * @param {(why: string) => never} bad
 * @returns {Uint8Array}
 */
function base64(s, bad) {
    if (!/^[A-Za-z0-9+/]*={0,2}$/.test(s) || s.length % 4 !== 0) bad("not base64");
    const bin = atob(s);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
}

/**
 * `@at`: a duration with its unit (`12_s`) or whole nanoseconds. One longer
 * than any `Duration` is refused here, before any row is fed.
 * @param {Cell | undefined} cell
 * @param {string} what  the column
 * @param {string} file
 * @param {number} line
 * @returns {bigint | null}
 */
function nanos(cell, what, file, line) {
    if (cell === undefined || cell.null) return null;
    const t = cell.text ?? cell.json;
    const d = durationNs(t) ?? (/^\d+$/.test(t) ? BigInt(t) : null);
    if (d === null)
        throw new FactFileError(file, line, `\`${what}\` \`${t}\` is not a duration such as \`12_s\` or whole nanoseconds`);
    if (d > MAX_DURATION_NS)
        throw new FactFileError(file, line, `\`${what}\` \`${t}\` is longer than any Duration, 2^63 - 1 nanoseconds`);
    return d;
}

/**
 * The typed rows of one fact file.
 * @param {{ schema: string, format: RowFormat, file: string, text: string }} f
 * @param {SchemaShape} schema  `@ds-lang/ds`'s `schemas.get(f.schema)`
 * @returns {FactRow[]}
 */
export function typedRows(f, schema) {
    return typeParsed(parseFactFile(f.text, f.format, f.file), f, schema);
}

/**
 * Cells as the slots of `schema`, by name. A slot not written at all (no
 * column, no key) is left out, and the engine decides: null if it is
 * nullable ([LNUL.4.1]).
 * @param {Map<string, Cell>} cells
 * @param {Map<string, SlotShape>} bySlot
 * @param {SchemaShape} schema
 * @param {string} file
 * @param {number | null} line
 * @returns {Record<string, CellValue>}
 */
function typeCells(cells, bySlot, schema, file, line) {
    /** @type {Record<string, CellValue>} */
    const slots = {};
    for (const [name, cell] of cells) {
        const slot = bySlot.get(name);
        if (!slot) throw new FactFileError(file, line, notASlot(name, schema.name));
        slots[name] = typeCell(cell, slot, file, line);
    }
    return slots;
}

/**
 * One JSON object's fields (`scanObject`'s cells) as the slots of `schema`,
 * typed as a JSONL row's are: what a reply's `response` is (DSDB.md §9.1).
 * `@at` is not a slot here.
 * @param {Map<string, Cell>} cells
 * @param {SchemaShape} schema
 * @param {string} what  the source, for messages
 * @returns {Record<string, CellValue>}
 * @throws {FactFileError}
 */
export function typeSlots(cells, schema, what) {
    return typeCells(cells, new Map(schema.slots.map((s) => [s.name, s])), schema, what, null);
}

/**
 * Type already-parsed rows (a per-schema file's, or one schema's out of a
 * single-file document).
 * @param {Parsed} parsed
 * @param {{ file: string, schema: string }} f
 * @param {SchemaShape} schema
 * @returns {FactRow[]}
 */
function typeParsed(parsed, f, schema) {
    const bySlot = new Map(schema.slots.map((s) => [s.name, s]));
    if (parsed.header) {
        const unknown = parsed.header.find((n) => n !== AT && !bySlot.has(n));
        if (unknown) throw new FactFileError(f.file, 1, notASlot(unknown, schema.name));
    }
    return parsed.rows.map(({ line, cells }) => {
        const own = new Map([...cells].filter(([name]) => name !== AT));
        const slots = typeCells(own, bySlot, schema, f.file, line);
        const at = nanos(cells.get(AT), AT, f.file, line) ?? 0n;
        return { file: f.file, line, schema: f.schema, at, slots, stamped: bySlot.has("ts") && !own.has("ts") };
    });
}

/**
 * Every file's rows, merged by time: by `@at`, then by the files' order as
 * given, then by row. A stable sort, so equal times keep that order.
 * @param {FactRow[][]} perFile  `typedRows` of each file, in the order given
 * @returns {FactRow[]}
 */
export function merge(perFile) {
    /** @type {Array<{ r: FactRow, fi: number, ri: number }>} */
    const all = [];
    perFile.forEach((rows, fi) => rows.forEach((r, ri) => all.push({ r, fi, ri })));
    all.sort((a, b) => (a.r.at < b.r.at ? -1 : a.r.at > b.r.at ? 1 : a.fi - b.fi || a.ri - b.ri));
    return all.map((x) => x.r);
}

/**
 * What to assert for a row at clock `at`: its slots, and, for a schema declaring
 * `ts` that gave none, that time, as a `.dstest` input takes its coordinate
 * ([LFAC.9.2]). Every path that feeds rows asserts these.
 * @param {FactRow} row
 * @param {bigint} at
 * @returns {Record<string, CellValue>}
 */
export function rowSlots(row, at) {
    return row.stamped ? { ...row.slots, ts: at } : row.slots;
}

/**
 * Feed merged rows to an engine on the mock clock: move the clock to each
 * row's time (never back), assert it, pump. Each row is a step, so the
 * session's settled points are the rows (DSTRACE_INTERACTIVE §3.3).
 *
 * @param {Engine} engine  on the mock clock
 * @param {FactRow[]} rows  `merge`'s output
 * @param {(row: FactRow, fact: Fact) => void} [each]  after each row's pump
 * @returns {number} rows fed
 */
export function feed(engine, rows, each) {
    const start = engine.clock.now;
    for (const row of rows) {
        const want = start + row.at;
        const now = engine.clock.now;
        let fact;
        try {
            if (want > now) engine.clock.advance(want - now);
            fact = engine.assert(row.schema, rowSlots(row, want));
        } catch (err) {
            throw new FactFileError(row.file, row.line, err instanceof Error ? err.message : String(err));
        }
        engine.pump();
        each?.(row, fact);
    }
    return rows.length;
}

/**
 * Fact files to typed, merged rows, against the program an engine holds.
 * @param {Array<{ path: string, text: string }>} files  in command-line order
 * @param {Engine} engine  with the program loaded
 * @returns {FactRow[]}
 */
export function loadFactFiles(files, engine) {
    // Each source of rows is one schema from one file: a per-schema file is
    // one, a single-file document one per schema it holds. The order they are
    // merged in is the command line's, and a document's schemas in its order.
    /** @type {Map<string, string>} */
    const seen = new Map();
    /** @type {Array<{ schema: string, file: string, parsed: Parsed }>} */
    const sources = [];
    /**
     * @param {string} schema
     * @param {string} file
     */
    const claim = (schema, file) => {
        if (seen.has(schema))
            throw new FactFileError(file, 0, `\`${schema}\` a second time (first in ${seen.get(schema)}); one source per schema`);
        seen.set(schema, file);
    };
    for (const { path, text } of files) {
        const name = factFileName(path);
        if (name === null) throw new FactFileError(path, 0, "not a fact file (.csv, .tsv, .jsonl or .json)");
        if (name.format === "json") {
            for (const [schema, rows] of parseJsonDoc(text, path)) {
                claim(schema, path);
                sources.push({ schema, file: path, parsed: { header: null, rows } });
            }
        } else {
            claim(name.schema, path);
            sources.push({ schema: name.schema, file: path, parsed: parseFactFile(text, name.format, path) });
        }
    }
    return merge(sources.map((s) => {
        const schema = engine.schemas.get(s.schema);
        if (schema === undefined) throw new FactFileError(s.file, 0, `the program has no schema \`${s.schema}\``);
        return typeParsed(s.parsed, { file: s.file, schema: s.schema }, schema);
    }));
}
