// (c) 2025, 2026 Dan Finster, All Rights Reserved
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Language Server Protocol's published metaModel, as lsp.test.mjs checks
// every message `ds lsp` sends against it. The metaModel is LSP
// 3.17.0's metaModel.json, pinned at a commit and checked against its sha256
// by the js gate, which hands the suite its directory in
// DS_PROTOCOL_SCHEMAS. It is not JSON Schema: it names each
// request and notification, the direction it travels, and the types of its
// params and result, built from structures, enumerations and type aliases.
//
// WHAT IS CHECKED, from the server's side of a session:
//   - every message is JSON-RPC 2.0: `jsonrpc` is "2.0";
//   - a response answers a request the client sent, by `id`, and carries
//     exactly one of `result` and `error`; a `result` keeps the request's
//     result type, an `error` is { code: integer, message: string, data? };
//   - a request or notification the server sends travels in a direction the
//     metaModel allows (serverToClient or both), and its `params` keep the
//     method's params type. A method the metaModel does not name is the
//     server's own and is held to the envelope alone.
//
// THE TYPES, as the specification reads them:
//   - a structure is open: a property it does not declare is allowed (LSP's
//     peers ignore what they do not know); every property it declares that
//     is not `optional` is required, and each present one keeps its type.
//     `extends` and `mixins` contribute their properties;
//   - an enumeration is closed unless it `supportsCustomValues`, and its
//     values keep its base type;
//   - `integer` is a signed 32-bit integer and `uinteger` 0 to 2^31 - 1, as
//     the specification defines them; `decimal` is any finite number;
//     `URI`, `DocumentUri` and `RegExp` are strings;
//   - `or` is met by any one of its items, `and` by all, a `tuple` by an
//     array of its length whose items each keep theirs.
// A type kind or base name outside these throws, so a newer pin that starts
// using one fails the suite rather than being passed over.

import { readFileSync } from "node:fs";
import { join } from "node:path";

/** The directory the gate puts the pinned schemas in, or undefined. */
export const SCHEMAS = process.env.DS_PROTOCOL_SCHEMAS;

const INT_MIN = -(2 ** 31), INT_MAX = 2 ** 31 - 1;

/** @param {unknown} v */
const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
/** @param {unknown} v */
const shown = (v) => { const s = JSON.stringify(v) ?? String(v); return s.length > 60 ? s.slice(0, 57) + "..." : s; };

/**
 * A checker for `model`: given every message the client sent and every
 * message the server sent, the ways the server's broke the metaModel.
 * @param {any} model  metaModel.json, parsed
 * @returns {(fromClient: any[], fromServer: any[]) => string[]}
 */
export function lspChecker(model) {
    for (const k of ["requests", "notifications", "structures", "enumerations", "typeAliases"])
        if (!Array.isArray(model[k])) throw new Error(`the model has no ${k}: not LSP's metaModel.json`);
    const structs = new Map(model.structures.map((/** @type {any} */ s) => [s.name, s]));
    const enums = new Map(model.enumerations.map((/** @type {any} */ e) => [e.name, e]));
    const aliases = new Map(model.typeAliases.map((/** @type {any} */ a) => [a.name, a]));
    const requests = new Map(model.requests.map((/** @type {any} */ r) => [r.method, r]));
    const notifications = new Map(model.notifications.map((/** @type {any} */ n) => [n.method, n]));

    /** @type {Map<string, any[]>} */
    const propsMemo = new Map();
    /** A structure's properties, its `extends` and `mixins` first. @param {string} name @returns {any[]} */
    function propertiesOf(name) {
        const hit = propsMemo.get(name);
        if (hit) return hit;
        const s = structs.get(name);
        const out = [];
        for (const t of [...(s.extends ?? []), ...(s.mixins ?? [])]) {
            if (t.kind !== "reference" || !structs.has(t.name))
                throw new Error(`metaModel ${name}: extends or mixes in ${JSON.stringify(t)}, no structure`);
            out.push(...propertiesOf(t.name));
        }
        out.push(...s.properties);
        propsMemo.set(name, out);
        return out;
    }

    /** @param {string} name @param {unknown} v @param {string} path @param {string[]} out */
    function base(name, v, path, out) {
        const ok = (() => {
            switch (name) {
            case "string": case "URI": case "DocumentUri": case "RegExp": return typeof v === "string";
            case "boolean": return typeof v === "boolean";
            case "null": return v === null;
            case "integer": return Number.isInteger(v) && /** @type {number} */ (v) >= INT_MIN && /** @type {number} */ (v) <= INT_MAX;
            case "uinteger": return Number.isInteger(v) && /** @type {number} */ (v) >= 0 && /** @type {number} */ (v) <= INT_MAX;
            case "decimal": return typeof v === "number" && Number.isFinite(v);
            default: throw new Error(`metaModel base type \`${name}\`: not one this checker knows`);
            }
        })();
        if (!ok) out.push(`${path}: ${shown(v)} is not ${name}`);
    }

    /** @param {any[]} properties @param {unknown} v @param {string} path @param {string[]} out */
    function object(properties, v, path, out) {
        if (!isObject(v)) {
            out.push(`${path}: ${shown(v)} is not an object`);
            return;
        }
        const o = /** @type {Record<string, unknown>} */ (v);
        for (const p of properties) {
            if (!(p.name in o)) {
                if (!p.optional) out.push(`${path}: lacks \`${p.name}\``);
                continue;
            }
            check(p.type, o[p.name], `${path}.${p.name}`, out);
        }
    }

    /** @param {any} t @param {unknown} v @param {string} path @param {string[]} out */
    function check(t, v, path, out) {
        switch (t.kind) {
        case "base":
            base(t.name, v, path, out);
            return;
        case "reference": {
            const n = t.name;
            if (structs.has(n)) return object(propertiesOf(n), v, `${path}<${n}>`, out);
            if (aliases.has(n)) return check(aliases.get(n).type, v, path, out);
            if (enums.has(n)) {
                const e = enums.get(n);
                base(e.type.name, v, path, out);
                if (!e.supportsCustomValues && !e.values.some((/** @type {any} */ x) => x.value === v))
                    out.push(`${path}: ${shown(v)} is no ${n}`);
                return;
            }
            throw new Error(`metaModel reference \`${n}\` at ${path}: nothing of that name`);
        }
        case "array":
            if (!Array.isArray(v)) out.push(`${path}: ${shown(v)} is not an array`);
            else v.forEach((x, i) => check(t.element, x, `${path}[${i}]`, out));
            return;
        case "map":
            if (!isObject(v)) out.push(`${path}: ${shown(v)} is not a map`);
            else for (const [k, x] of Object.entries(/** @type {object} */ (v))) check(t.value, x, `${path}[${JSON.stringify(k)}]`, out);
            return;
        case "or": {
            /** @type {string[] | null} */
            let closest = null;
            for (const item of t.items) {
                /** @type {string[]} */
                const o = [];
                check(item, v, path, o);
                if (o.length === 0) return;
                if (closest === null || o.length < closest.length) closest = o;
            }
            out.push(`${path}: ${shown(v)} is none of its ${t.items.length} alternatives; the closest: ${(closest ?? []).join("; ")}`);
            return;
        }
        case "and":
            for (const item of t.items) check(item, v, path, out);
            return;
        case "tuple":
            if (!Array.isArray(v) || v.length !== t.items.length) out.push(`${path}: ${shown(v)} is not a ${t.items.length}-tuple`);
            else t.items.forEach((/** @type {any} */ item, /** @type {number} */ i) => check(item, v[i], `${path}[${i}]`, out));
            return;
        case "literal":
            object(t.value.properties, v, path, out);
            return;
        case "stringLiteral": case "integerLiteral": case "booleanLiteral":
            if (v !== t.value) out.push(`${path}: ${shown(v)} is not ${shown(t.value)}`);
            return;
        default:
            throw new Error(`metaModel type kind \`${t.kind}\` at ${path}: not one this checker knows`);
        }
    }

    /** @param {any} def @param {string} what @param {string[]} out */
    function direction(def, what, out) {
        if (def.messageDirection !== "serverToClient" && def.messageDirection !== "both")
            out.push(`${what}: the server sent it, and it travels ${def.messageDirection}`);
    }

    return (fromClient, fromServer) => {
        /** @type {Map<unknown, string>} */
        const asked = new Map();
        for (const m of fromClient) if ("id" in m && typeof m.method === "string") asked.set(m.id, m.method);
        /** @type {string[]} */
        const out = [];
        for (const m of fromServer) {
            if (!isObject(m)) {
                out.push(`${shown(m)}: not a JSON-RPC message`);
                continue;
            }
            const what = typeof m.method === "string" ? m.method : `response ${shown(m.id)}`;
            if (m.jsonrpc !== "2.0") out.push(`${what}: jsonrpc is ${shown(m.jsonrpc)}, not "2.0"`);
            if (typeof m.method === "string") {
                const def = "id" in m ? requests.get(m.method) : notifications.get(m.method);
                if (def === undefined) continue;
                direction(def, what, out);
                if (def.params !== undefined) {
                    if (!("params" in m)) out.push(`${what}: lacks \`params\``);
                    else check(def.params, m.params, `${what}.params`, out);
                }
                continue;
            }
            const method = asked.get(m.id);
            if (method === undefined) {
                out.push(`${what}: answers no request the client sent`);
                continue;
            }
            const label = `response to ${method}`;
            if (("result" in m) === ("error" in m)) {
                out.push(`${label}: carries ${"result" in m ? "both `result` and `error`" : "neither `result` nor `error`"}`);
                continue;
            }
            if ("error" in m) {
                const e = m.error;
                if (!isObject(e)) out.push(`${label}.error: ${shown(e)} is not an object`);
                else {
                    if (!Number.isInteger(e.code)) out.push(`${label}.error.code: ${shown(e.code)} is not an integer`);
                    if (typeof e.message !== "string") out.push(`${label}.error.message: ${shown(e.message)} is not a string`);
                }
                continue;
            }
            const def = requests.get(method);
            if (def !== undefined && def.result !== undefined) check(def.result, m.result, `${label}.result`, out);
        }
        return out;
    };
}

/** The checker over the gate's pinned metaModel; null when the suite has none. */
export function pinnedLspChecker() {
    if (!SCHEMAS) return null;
    return lspChecker(JSON.parse(readFileSync(join(SCHEMAS, "metaModel.json"), "utf8")));
}
