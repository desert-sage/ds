// SPDX-FileCopyrightText: 2026 Dan Finster and the DS Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// [RFCS.4.5]'s binding check: a trace paired with a program, compared on the
// dialect-binding tuple ([RBND.1.3]), `dsc_hash`, `capabilities` and
// `dialect_def_sha256`, field by field, as [RBND.6]'s comparison makes it.
// libds makes it when its replayer opens a stream (rfcs/codec.c,
// `replay_verify_header` and `ds_binding_compare_dialect`); dsdb decodes a
// trace itself and never runs that replayer, so the same cases are made here,
// in the same order, with the same codes. The shell, the listing and the
// debug adapter all pair a trace with a program through this one check.

/** @import { Ds } from "./types.js" */

/**
 * One side's dialect-binding tuple ([RBND.1.3]): each hash 32 raw bytes, or
 * null where that side holds none; the capabilities in the order written,
 * which [RBND.1.3] makes ascending.
 * @typedef {{ hash: Uint8Array | null, capabilities: Array<{ number: number, name: string | null }>,
 *     def: Uint8Array | null }} Tuple
 */

/**
 * Why a trace and a program do not belong together: libds's status for it,
 * by name, and what differs.
 * @typedef {{ code: "DS_ERR_BND_DSC_MISMATCH" | "DS_ERR_BND_DIALECT_MISMATCH" | "DS_ERR_BND_INCOMPLETE",
 *     detail: string }} Unbound
 */

/**
 * The check's outcome. `checked` is false when there was nothing to compare:
 * a stream whose header holds neither `dsc_hash` nor `dialect_def_sha256`,
 * which replays without a binding check ([RBND.2.1]), or a program whose
 * engine states no `dsc_hash`. `unbound` is the refusal, or null.
 * @typedef {{ checked: boolean, unbound: Unbound | null }} Bound
 */

/**
 * A hash as [RBND.5.2]'s detail gives it, "truncated to 16 hex characters":
 * its first eight bytes in lowercase hex, or all of a shorter one, as libds's
 * `bnd_short_hex` writes it.
 * @param {Uint8Array} b
 */
const hex = (b) => Array.from(b.subarray(0, 8), (x) => x.toString(16).padStart(2, "0")).join("");

/**
 * A 32-byte hash field, or null for any other value: proto3 gives an absent
 * `bytes` field as empty.
 * @param {unknown} v
 * @returns {Uint8Array | null}
 */
const hash32 = (v) => (v instanceof Uint8Array && v.length === 32 ? v : null);

/**
 * A repeated `Capability` field, as `readAtoms` gives it.
 * @param {unknown} v
 * @returns {Tuple["capabilities"]}
 */
function capabilities(v) {
    if (!Array.isArray(v)) return [];
    return v.map((c) => (c !== null && typeof c === "object"
        ? { number: Number(c.number), name: typeof c.name === "string" ? c.name : null }
        : { number: Number(c), name: null }));
}

/**
 * A capability by its [LCAP.1] name, the enum member's without `CAPABILITY_`
 * in lower case; as its number where no member names it, and for 0, which
 * names no setting, as libds's `bnd_cap_names` writes them.
 * @param {{ number: number, name: string | null }} c
 */
const capName = (c) => (c.number !== 0 && c.name !== null && c.name.startsWith("CAPABILITY_")
    ? c.name.slice("CAPABILITY_".length).toLowerCase() : String(c.number));

/**
 * The capabilities of `xs` that `ys` does not hold, comma-separated, or
 * "(none)".
 * @param {Tuple["capabilities"]} xs
 * @param {Tuple["capabilities"]} ys
 */
function only(xs, ys) {
    const out = xs.filter((x) => !ys.some((y) => y.number === x.number)).map(capName);
    return out.length ? out.join(",") : "(none)";
}

/**
 * @param {Uint8Array | null} a
 * @param {Uint8Array | null} b
 */
const sameBytes = (a, b) => (a === null || b === null ? a === b : a.length === b.length && a.every((x, i) => x === b[i]));

/** @param {Uint8Array | null} b */
const shown = (b) => (b === null ? "(none)" : hex(b));

/**
 * The tuple a trace's StreamHeader carries.
 * @param {Record<string, unknown> | null | undefined} header  its body, as `readAtoms` gives it
 * @returns {Tuple}
 */
export function streamTuple(header) {
    return { hash: hash32(header?.dsc_hash), capabilities: capabilities(header?.capabilities),
             def: hash32(header?.dialect_def_sha256) };
}

/**
 * The tuple a program carries: its DscHeader's capabilities and
 * `dialect_def_sha256`, with the `dsc_hash` an engine loading it states, the
 * value a trace recorded with it copies ([RBND.3.1]), which the load checked
 * against the program's bytes ([RDSC.3.6]).
 * @param {Ds} ds
 * @param {Uint8Array} dsc
 * @param {Uint8Array | null} hash  the engine's `dsc_hash` (api/open.js `dscHash`)
 * @returns {Tuple}
 */
export function programTuple(ds, dsc, hash) {
    const h = ds.readAtoms(dsc, { incremental: true }).atoms.find((a) => a.message === "DscHeader");
    const body = /** @type {Record<string, unknown> | null | undefined} */ (h?.body);
    return { hash, capabilities: capabilities(body?.capabilities), def: hash32(body?.dialect_def_sha256) };
}

/**
 * A trace's StreamHeader body, read from where it begins.
 * @param {Ds} ds
 * @param {Uint8Array} data  the trace's bytes
 * @param {number} [front]  where its StreamHeader begins: past an embedded program
 * @returns {Record<string, unknown> | null}
 */
export function streamHeader(ds, data, front = 0) {
    const a = ds.readAtoms(data.subarray(front), { incremental: true }).atoms.find((x) => x.message === "StreamHeader");
    return /** @type {Record<string, unknown> | null} */ (a?.body ?? null);
}

/**
 * [RFCS.4.5]'s check of a trace's tuple against its program's.
 * - The stream holds one of a 32-byte `dsc_hash` and a 32-byte
 *   `dialect_def_sha256` and not the other: incomplete ([RBND.2.1]),
 *   whatever the program.
 * - It holds neither: no binding check ([RBND.2.1]).
 * - It holds both and the program states a `dsc_hash`: the three fields must
 *   equal the program's, in that order; the capabilities as a sequence, not
 *   a set ([RBND.6]).
 * @param {Tuple} trace
 * @param {Tuple} program
 * @returns {Bound}
 */
export function bindingCheck(trace, program) {
    /** @type {(code: Unbound["code"], detail: string) => Bound} */
    const refuse = (code, detail) => ({ checked: true, unbound: { code, detail } });
    if (trace.hash !== null && trace.def === null)
        return refuse("DS_ERR_BND_INCOMPLETE", "the trace's StreamHeader carries a dsc_hash and no dialect_def_sha256");
    if (trace.def !== null && trace.hash === null)
        return refuse("DS_ERR_BND_INCOMPLETE", "the trace's StreamHeader carries a dialect_def_sha256 and no dsc_hash");
    if (trace.hash === null || program.hash === null) return { checked: false, unbound: null };
    if (!sameBytes(trace.hash, program.hash))
        return refuse("DS_ERR_BND_DSC_MISMATCH", `dsc_hash: trace ${hex(trace.hash)}, program ${hex(program.hash)}`);
    const a = trace.capabilities, b = program.capabilities;
    if (a.length !== b.length || a.some((c, i) => c.number !== b[i].number)) {
        const mine = only(a, b), theirs = only(b, a);
        return refuse("DS_ERR_BND_DIALECT_MISMATCH", mine === "(none)" && theirs === "(none)"
            ? "capabilities: the same, in another order"
            : `capabilities: only the trace's ${mine}, only the program's ${theirs}`);
    }
    if (!sameBytes(trace.def, program.def))
        return refuse("DS_ERR_BND_DIALECT_MISMATCH",
                      `dialect_def_sha256: trace ${shown(trace.def)}, program ${shown(program.def)}`);
    return { checked: true, unbound: null };
}
