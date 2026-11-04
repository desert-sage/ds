// (c) 2025, 2026 Dan Finster, All Rights Reserved
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Debug Adapter Protocol's published schema, as dap.test.mjs checks every
// message `ds dap` sends against it. The schema is
// debugAdapterProtocol.json, pinned at a commit and checked against its
// sha256 by the js gate, which hands the suite its directory in
// DS_PROTOCOL_SCHEMAS. Neither protocol has an official
// conformance suite; the machine-readable spec is what there is to check
// against.
//
// THE VALIDATOR KNOWS THE KEYWORDS THIS SCHEMA USES AND REFUSES ANY OTHER.
// The schema is JSON Schema draft-04, and it uses a small part of it: `$ref`,
// `allOf`, `oneOf`, `type`, `properties`, `required`, `additionalProperties`,
// `items`, `enum`, `minimum` and `maximum` constrain; `description`, `title`,
// `format`, `_enum` (an open set: any string is allowed), `enumDescriptions`,
// `$schema` and `definitions` do not. A keyword outside both lists throws, so
// a newer pin that starts using one fails the suite instead of being passed
// over: a validator that ignores a constraint reports a message valid that
// is not.

import { readFileSync } from "node:fs";
import { join } from "node:path";

/** The directory the gate puts the pinned schemas in, or undefined. */
export const SCHEMAS = process.env.DS_PROTOCOL_SCHEMAS;

const CONSTRAINS = new Set(["$ref", "allOf", "oneOf", "type", "properties", "required",
                            "additionalProperties", "items", "enum", "minimum", "maximum"]);
const ANNOTATES = new Set(["description", "title", "format", "_enum", "enumDescriptions",
                           "$schema", "definitions"]);

/** @param {string} t @param {unknown} v */
function isType(t, v) {
    switch (t) {
    case "null": return v === null;
    case "boolean": return typeof v === "boolean";
    case "integer": return Number.isInteger(v);
    case "number": return typeof v === "number" && Number.isFinite(v);
    case "string": return typeof v === "string";
    case "array": return Array.isArray(v);
    case "object": return v !== null && typeof v === "object" && !Array.isArray(v);
    default: throw new Error(`schema type \`${t}\`: not one this validator knows`);
    }
}

/**
 * A checker for `schema`: each message's violations, as `path: what`; none
 * for a message that keeps it.
 * @param {any} schema  debugAdapterProtocol.json, parsed
 * @returns {(msg: any) => string[]}
 */
export function dapChecker(schema) {
    const defs = schema.definitions;
    for (const base of ["ProtocolMessage", "Request", "Response", "ErrorResponse", "Event"])
        if (!defs[base]) throw new Error(`the schema has no ${base}: not debugAdapterProtocol.json`);

    /** @param {any} s @param {unknown} v @param {string} path @param {string[]} out */
    function check(s, v, path, out) {
        for (const k of Object.keys(s))
            if (!CONSTRAINS.has(k) && !ANNOTATES.has(k))
                throw new Error(`schema keyword \`${k}\` at ${path}: not one this validator knows`);
        if (s.$ref !== undefined) {
            const m = /^#\/definitions\/(.+)$/.exec(s.$ref);
            if (!m || !defs[m[1]]) throw new Error(`schema $ref ${s.$ref} at ${path}: no such definition`);
            check(defs[m[1]], v, path, out);
        }
        for (const sub of s.allOf ?? []) check(sub, v, path, out);
        if (s.oneOf !== undefined) {
            const n = s.oneOf.filter((/** @type {any} */ sub) => {
                /** @type {string[]} */
                const o = [];
                check(sub, v, path, o);
                return o.length === 0;
            }).length;
            if (n !== 1) out.push(`${path}: matches ${n} of oneOf's ${s.oneOf.length}, not one`);
        }
        if (s.type !== undefined) {
            const ts = Array.isArray(s.type) ? s.type : [s.type];
            if (!ts.some((/** @type {string} */ t) => isType(t, v))) {
                out.push(`${path}: ${JSON.stringify(v)} is not ${ts.join(" | ")}`);
                return;
            }
        }
        if (s.enum !== undefined && !s.enum.some((/** @type {unknown} */ e) => e === v))
            out.push(`${path}: ${JSON.stringify(v)} is not one of ${JSON.stringify(s.enum)}`);
        if (typeof v === "number") {
            if (s.minimum !== undefined && v < s.minimum) out.push(`${path}: ${v} is below ${s.minimum}`);
            if (s.maximum !== undefined && v > s.maximum) out.push(`${path}: ${v} is above ${s.maximum}`);
        }
        if (isType("object", v)) {
            const o = /** @type {Record<string, unknown>} */ (v);
            for (const r of s.required ?? []) if (!(r in o)) out.push(`${path}: lacks \`${r}\``);
            const props = s.properties ?? {};
            for (const [k, sub] of Object.entries(props)) if (k in o) check(sub, o[k], `${path}.${k}`, out);
            const extra = s.additionalProperties;
            if (extra !== undefined && extra !== true)
                for (const k of Object.keys(o))
                    if (!(k in props)) {
                        if (extra === false) out.push(`${path}: carries \`${k}\`, which it may not`);
                        else check(extra, o[k], `${path}.${k}`, out);
                    }
        }
        if (Array.isArray(v) && s.items !== undefined) v.forEach((x, i) => check(s.items, x, `${path}[${i}]`, out));
    }

    /** @param {string} s */
    const cap = (s) => s.charAt(0).toUpperCase() + s.slice(1);
    /** The definition a message is held to: its own where the schema has one, else its kind's. */
    function definition(/** @type {any} */ msg) {
        if (msg?.type === "response") {
            // A failed request answers with an ErrorResponse, whatever was asked.
            if (msg.success === false) return "ErrorResponse";
            const own = typeof msg.command === "string" ? `${cap(msg.command)}Response` : "";
            return defs[own] ? own : "Response";
        }
        if (msg?.type === "event") {
            const own = typeof msg.event === "string" ? `${cap(msg.event)}Event` : "";
            return defs[own] ? own : "Event";
        }
        if (msg?.type === "request") {
            const own = typeof msg.command === "string" ? `${cap(msg.command)}Request` : "";
            return defs[own] ? own : "Request";
        }
        return "ProtocolMessage";
    }

    return (msg) => {
        const name = definition(msg);
        /** @type {string[]} */
        const out = [];
        check({ $ref: `#/definitions/${name}` }, msg, name, out);
        return out;
    };
}

/** The checker over the gate's pinned schema; null when the suite has none. */
export function pinnedDapChecker() {
    if (!SCHEMAS) return null;
    return dapChecker(JSON.parse(readFileSync(join(SCHEMAS, "debugAdapterProtocol.json"), "utf8")));
}
