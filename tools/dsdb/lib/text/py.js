// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Python's text formatting, exactly, where dstrace's output depends on it.
//
// dsdb's output is byte-identical to dstrace's (DSDB.md §1), and several of
// Python's formatting rules differ from JavaScript's in ways a listing shows:
//
// - repr(float): `80.0`, not `80`; an exponent from 1e16 and below 1e-4, with
//   at least two digits (`1e-05`, `1e+16`), where JavaScript switches at 1e21
//   and 1e-7 and writes `1e-7`;
// - format(x, ".3f"): the exact binary value rounded half to even, where
//   toFixed rounds a tie up (0.0625 is `0.062` in Python, `0.063` in JS);
// - round(x): half to even;
// - repr(bytes): `b'\x00ab'`;
// - json.dumps(str, ensure_ascii=False);
// - width in code points, not UTF-16 units.
//
// Everything here takes the value Python would have: a float is a Number, an
// int a BigInt (or a safe-integer Number where the caller says so).

import { RecordedRef } from "../core/ref.js";

/**
 * Python's `round(x)` for a finite double: to the nearest integer, a tie to
 * the even one.
 * @param {number} x
 * @returns {number}
 */
export function roundHalfEven(x) {
    const f = Math.floor(x);
    const d = x - f;
    if (d > 0.5) return f + 1;
    if (d < 0.5) return f;
    return f % 2 === 0 ? f : f + 1;
}

/**
 * A finite double as `[negative, mantissa, exponent]`, value = m * 2^e, exact.
 * @param {number} x
 * @returns {[boolean, bigint, number]}
 */
function decompose(x) {
    const view = new DataView(new ArrayBuffer(8));
    view.setFloat64(0, x);
    const bits = view.getBigUint64(0);
    const neg = bits >> 63n === 1n;
    const expBits = Number((bits >> 52n) & 0x7ffn);
    const frac = bits & 0xfffffffffffffn;
    if (expBits === 0) return [neg, frac, -1074];               // subnormal or zero
    return [neg, frac | (1n << 52n), expBits - 1075];
}

/**
 * Python's `format(x, f".{digits}f")`: the exact binary value, rounded half
 * to even at `digits` places.
 * @param {number} x
 * @param {number} digits
 */
export function fixed(x, digits) {
    if (Number.isNaN(x)) return "nan";
    if (!Number.isFinite(x)) return x > 0 ? "inf" : "-inf";
    const [neg, m, e] = decompose(x);
    const scale = 10n ** BigInt(digits);
    let q;
    if (e >= 0) {
        q = m * (1n << BigInt(e)) * scale;
    } else {
        const num = m * scale, den = 1n << BigInt(-e);
        q = num / den;
        const twice = 2n * (num % den);
        if (twice > den || (twice === den && q % 2n === 1n)) q += 1n;
    }
    let s = q.toString().padStart(digits + 1, "0");
    if (digits > 0) s = s.slice(0, -digits) + "." + s.slice(-digits);
    return (neg ? "-" : "") + s;
}

/**
 * Python's `repr(x)` for a float.
 * @param {number} x
 */
export function floatRepr(x) {
    if (Number.isNaN(x)) return "nan";
    if (!Number.isFinite(x)) return x > 0 ? "inf" : "-inf";
    if (x === 0) return Object.is(x, -0) ? "-0.0" : "0.0";
    // toExponential() with no argument gives the shortest digits that round
    // trip, which is what repr uses too.
    const [mant, expText] = Math.abs(x).toExponential().split("e");
    const digits = mant.replace(".", "");
    const exp = Number(expText);
    const sign = x < 0 ? "-" : "";
    if (exp >= -4 && exp < 16) {
        let s;
        if (exp >= 0) {
            const whole = digits.padEnd(exp + 1, "0");
            const intPart = whole.slice(0, exp + 1), fracPart = digits.slice(exp + 1);
            s = intPart + "." + (fracPart || "0");
        } else {
            s = "0." + "0".repeat(-exp - 1) + digits;
        }
        return sign + s;
    }
    const m = digits.length > 1 ? digits[0] + "." + digits.slice(1) : digits;
    const es = (exp < 0 ? "-" : "+") + String(Math.abs(exp)).padStart(2, "0");
    return sign + m + "e" + es;
}

/**
 * Python's `repr(b)` for bytes.
 * @param {Uint8Array} b
 */
export function bytesRepr(b) {
    const hasSingle = b.includes(0x27), hasDouble = b.includes(0x22);
    const q = hasSingle && !hasDouble ? '"' : "'";
    let out = "b" + q;
    for (const c of b) {
        if (c === 0x5c) out += "\\\\";
        else if (c === q.charCodeAt(0)) out += "\\" + q;
        else if (c === 0x09) out += "\\t";
        else if (c === 0x0a) out += "\\n";
        else if (c === 0x0d) out += "\\r";
        else if (c < 0x20 || c >= 0x7f) out += "\\x" + c.toString(16).padStart(2, "0");
        else out += String.fromCharCode(c);
    }
    return out + q;
}

/**
 * Python's `json.dumps(s, ensure_ascii=False)` for a string.
 * @param {string} s
 */
export function jsonString(s) {
    let out = '"';
    for (const ch of s) {
        const c = /** @type {number} */ (ch.codePointAt(0));    // a string's iteration yields no empty one
        if (ch === '"') out += '\\"';
        else if (ch === "\\") out += "\\\\";
        else if (ch === "\n") out += "\\n";
        else if (ch === "\r") out += "\\r";
        else if (ch === "\t") out += "\\t";
        else if (ch === "\b") out += "\\b";
        else if (ch === "\f") out += "\\f";
        else if (c < 0x20) out += "\\u" + c.toString(16).padStart(4, "0");
        else out += ch;
    }
    return out + '"';
}

/**
 * Python's `repr(s)` for a string: single quotes unless the string has one
 * and no double quote.
 * @param {string} s
 */
export function strRepr(s) {
    const q = s.includes("'") && !s.includes('"') ? '"' : "'";
    let out = q;
    for (const ch of s) {
        const c = /** @type {number} */ (ch.codePointAt(0));    // a string's iteration yields no empty one
        if (ch === "\\") out += "\\\\";
        else if (ch === q) out += "\\" + q;
        else if (ch === "\n") out += "\\n";
        else if (ch === "\r") out += "\\r";
        else if (ch === "\t") out += "\\t";
        else if (c < 0x20 || c === 0x7f) out += "\\x" + c.toString(16).padStart(2, "0");
        else if (c >= 0x80 && c < 0xa0) out += "\\x" + c.toString(16).padStart(2, "0");
        else out += ch;
    }
    return out + q;
}

/**
 * Python's `repr(v)` for the values a fact slot, a record field or a result
 * can hold: None, bool, int (BigInt), float (Number), str, bytes (Uint8Array),
 * and a list of them; and a fact a recording's reference names, as dsdb names
 * a fact, `Motion#2` (core/ref.js), which Python had no form for.
 * @param {unknown} v
 * @returns {string}
 */
export function repr(v) {
    if (v === null || v === undefined) return "None";
    if (typeof v === "boolean") return v ? "True" : "False";
    if (typeof v === "bigint") return v.toString();
    if (typeof v === "number") return floatRepr(v);
    if (typeof v === "string") return strRepr(v);
    if (v instanceof Uint8Array) return bytesRepr(v);
    if (v instanceof RecordedRef) return v.toString();
    if (Array.isArray(v)) return "[" + v.map(repr).join(", ") + "]";
    throw new TypeError(`repr: no Python form for ${Object.prototype.toString.call(v)}`);
}

/**
 * `value(json.loads(text))` as the shell prints it: a string as JSON, a
 * boolean lower case, anything else as Python's repr of what json.loads
 * made of it (`{'ok': True, 'n': [1, 2.5, None]}`). Integers stay exact and
 * `2.0` stays a float, as they do in Python.
 * @param {string} text  JSON text, already known to parse
 */
export function jsonValue(text) {
    const p = { s: text, i: 0 };
    const v = parseJson(p);
    if (v.kind === "str") return jsonString(v.v);
    if (v.kind === "bool") return v.v ? "true" : "false";
    return reprJson(v);
}

/**
 * A JSON value as Python's json.loads makes it, tagged with its Python type.
 * @typedef {{ kind: "null" } | { kind: "bool", v: boolean } | { kind: "int", v: bigint }
 *   | { kind: "float", v: number } | { kind: "str", v: string } | { kind: "list", v: PyJson[] }
 *   | { kind: "dict", v: Map<string, PyJson> }} PyJson
 */

/**
 * @param {PyJson} v
 * @returns {string}
 */
function reprJson(v) {
    switch (v.kind) {
    case "null": return "None";
    case "bool": return v.v ? "True" : "False";
    case "int": return v.v.toString();
    case "float": return floatRepr(v.v);
    case "str": return strRepr(v.v);
    case "list": return "[" + v.v.map(reprJson).join(", ") + "]";
    case "dict": return "{" + [...v.v].map(([k, x]) => `${strRepr(k)}: ${reprJson(x)}`).join(", ") + "}";
    }
}

/**
 * Python's json.loads, to tagged values: ints as BigInt, NaN and the
 * infinities accepted, a repeated key's last value kept where it first
 * appeared (a dict's insertion order). The text is known to parse.
 * @param {{ s: string, i: number }} p  the text, and where reading is
 * @returns {PyJson}
 */
function parseJson(p) {
    const ws = () => { while (p.i < p.s.length && " \t\r\n".includes(p.s[p.i])) p.i++; };
    ws();
    const c = p.s[p.i];
    /** @type {PyJson} */
    let v;
    if (c === "{") {
        p.i++;
        /** @type {Map<string, PyJson>} */
        const m = new Map();
        ws();
        if (p.s[p.i] === "}") p.i++;
        else for (;;) {
            ws();
            const key = parseJson(p);
            if (key.kind !== "str") throw new SyntaxError(`JSON: an object key at ${p.i} is not a string`);
            const k = key.v;
            ws();
            p.i++;                                  // :
            m.set(k, parseJson(p));
            ws();
            if (p.s[p.i++] === "}") break;          // else ,
        }
        v = { kind: "dict", v: m };
    } else if (c === "[") {
        p.i++;
        /** @type {PyJson[]} */
        const a = [];
        ws();
        if (p.s[p.i] === "]") p.i++;
        else for (;;) {
            a.push(parseJson(p));
            ws();
            if (p.s[p.i++] === "]") break;
        }
        v = { kind: "list", v: a };
    } else if (c === '"') {
        const from = p.i++;
        while (p.s[p.i] !== '"') p.i += p.s[p.i] === "\\" ? 2 : 1;
        p.i++;
        v = { kind: "str", v: JSON.parse(p.s.slice(from, p.i)) };
    } else {
        const lit = /^(true|false|null|NaN|-?Infinity)/.exec(p.s.slice(p.i));
        if (lit) {
            p.i += lit[0].length;
            const w = lit[0];
            v = w === "null" ? { kind: "null" } : w === "true" || w === "false" ? { kind: "bool", v: w === "true" }
                : { kind: "float", v: w === "NaN" ? NaN : w.startsWith("-") ? -Infinity : Infinity };
        } else {
            const m = /^-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?/.exec(p.s.slice(p.i));
            if (m === null) throw new SyntaxError(`JSON: no value at ${p.i}`);
            p.i += m[0].length;
            v = m[2] || m[3] ? { kind: "float", v: Number(m[0]) } : { kind: "int", v: BigInt(m[0]) };
        }
    }
    ws();
    return v;
}

/**
 * Width in code points, as Python's `len` counts.
 * @param {string} s
 * @returns {number}
 */
export function width(s) {
    let n = 0;
    for (const _ of s) n++;
    return n;
}

/**
 * `f"{s:<{w}}"`
 * @param {string} s
 * @param {number} w
 * @returns {string}
 */
export function ljust(s, w) {
    return s + " ".repeat(Math.max(0, w - width(s)));
}

/**
 * `f"{s:>{w}}"`
 * @param {string} s
 * @param {number} w
 * @returns {string}
 */
export function rjust(s, w) {
    return " ".repeat(Math.max(0, w - width(s))) + s;
}

/**
 * `f"{n:#x}"` for an int.
 * @param {bigint | number} n
 * @returns {string}
 */
export function hexAlt(n) {
    const b = BigInt(n);
    return (b < 0n ? "-0x" + (-b).toString(16) : "0x" + b.toString(16));
}
