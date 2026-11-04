// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The API's protocol (dsdb/DSDB_WEB.md §3): JSON-RPC 2.0 over one
// session, the same whichever transport carries it: a WebSocket (lib/serve)
// or a worker's messages (step 4). Messages in and out are objects; the
// transport frames them, and serialises with json.js's `replacer`. Nothing
// from Node.
//
//   ops/list                                   the operations and their schemas, and `shellLines`
//   ops/call      { name, args, progress? }    { results, text, isError }
//   ops/exec      { line, progress? }          the same, for a shell line: only when the
//                                              host turns shell lines on (§7.2)
//   resources/list, resources/templates/list, resources/read { uri }
//   ping
//
// Notifications out: `progress` { token, progress, total, message } while a
// call with a `progress` token runs, and `resources/list_changed` when the
// resources listed change (a load, a fork, a kill).

import { ResourceError, TEMPLATES, list, read } from "./resources.js";

/** @import { Api, OnProgress } from "./ops.js" */

export const PARSE = -32700, INVALID = -32600, NO_METHOD = -32601, BAD_PARAMS = -32602, INTERNAL = -32603;

/**
 * A JSON object's members, by name; any other value has none. JSON.parse
 * makes an object's keys strings, which is why its members are a record.
 * @param {unknown} v
 * @returns {Record<string, unknown>}
 */
export const members = (v) => (typeof v === "object" && v !== null ? /** @type {Record<string, unknown>} */ (v) : {});

class RpcError extends Error {
    /**
     * @param {number} code  its JSON-RPC error code
     * @param {string} message
     */
    constructor(code, message) {
        super(message);
        this.code = code;
    }
}

/** One session's protocol end: `handle` each message as it arrives, in order. */
export class Rpc {
    /** @type {Api} */
    #api;
    /** @type {(msg: Record<string, unknown>) => void} */
    #send;
    /** @type {(line: string) => void} */
    #log;
    /** @type {string} the URIs `resources/list` gave last, one per line */
    #listed;
    /** @type {boolean} */
    #shellLines;

    /**
     * @param {Api} api
     * @param {(msg: Record<string, unknown>) => void} send  to the other end
     * @param {(line: string) => void} [log]  what is not the other end's: a defect
     * @param {object} [o]
     * @param {boolean} [o.shellLines]  offer `ops/exec` (an option a web interface turns on)
     */
    constructor(api, send, log = () => {}, { shellLines = false } = {}) {
        this.#api = api;
        this.#send = (msg) => send({ jsonrpc: "2.0", ...msg });
        this.#log = log;
        this.#listed = this.#uris();
        this.#shellLines = shellLines;
    }

    /**
     * The `progress` notifications for a request's token, or null.
     * @param {unknown} token
     * @returns {OnProgress | null}
     */
    #progress(token) {
        return typeof token !== "string" && typeof token !== "number" ? null
            : (done, total, message) => this.#send({ method: "progress", params: { token, progress: done, total, message } });
    }

    #uris() {
        return list(this.#api.loaded).map((r) => r.uri).join("\n");
    }

    /**
     * A message: a request is answered, a notification is not. `msg` is
     * what arrived, parsed, or a string that did not parse.
     * @param {unknown} msg
     */
    async handle(msg) {
        if (typeof msg === "string") return this.#send({ id: null, error: { code: PARSE, message: "not JSON" } });
        if (Array.isArray(msg) || msg === null || typeof msg !== "object")
            return this.#send({ id: null, error: { code: INVALID, message: "one JSON-RPC message at a time; batches are not accepted" } });
        const m = members(msg);
        if (typeof m.method !== "string") return;          // a response to nothing asked
        const request = Object.hasOwn(m, "id");
        try {
            const result = await this.#method(m.method, members(m.params));
            if (request) this.#send({ id: m.id, result: result ?? {} });
        } catch (err) {
            if (err instanceof RpcError || err instanceof ResourceError) {
                if (request) this.#send({ id: m.id, error: { code: err.code, message: err.message } });
            } else {
                this.#log(`${m.method}: ${err instanceof Error ? err.stack ?? err : err}`);
                if (request) this.#send({ id: m.id, error: { code: INTERNAL, message: err instanceof Error ? err.message : String(err) } });
            }
        }
        const now = this.#uris();
        if (now !== this.#listed) {
            this.#listed = now;
            this.#send({ method: "resources/list_changed" });
        }
    }

    /**
     * @param {string} method
     * @param {Record<string, unknown>} params
     * @returns {Promise<Record<string, unknown>>}
     */
    async #method(method, params) {
        const api = this.#api;
        switch (method) {
        case "ping":
            return {};
        case "ops/list":
            return { ops: api.list(), shellLines: this.#shellLines };
        case "ops/call": {
            if (typeof params.name !== "string" || !api.has(params.name))
                throw new RpcError(BAD_PARAMS, `no operation \`${params.name}\``);
            const args = params.args ?? {};
            if (typeof args !== "object" || Array.isArray(args)) throw new RpcError(BAD_PARAMS, "`args` is an object");
            const got = await api.call(params.name, members(args), this.#progress(params.progress));
            return { results: got.results, text: got.text, isError: got.isError };
        }
        case "ops/exec": {
            if (!this.#shellLines)
                throw new RpcError(NO_METHOD, "shell lines are off: the host turns them on "
                                   + "(`ds serve --shell-lines`, `startWorker({ shellLines: true })`)");
            if (typeof params.line !== "string" || !params.line.trim()) throw new RpcError(BAD_PARAMS, "`line` is a shell line");
            const got = await api.line(params.line, this.#progress(params.progress));
            return { results: got.results, text: got.text, isError: got.isError };
        }
        case "resources/list":
            return { resources: list(api.loaded) };
        case "resources/templates/list":
            return { resourceTemplates: TEMPLATES };
        case "resources/read":
            if (typeof params.uri !== "string") throw new RpcError(BAD_PARAMS, "`uri` is a string");
            return { contents: read(api.loaded, params.uri) };
        default:
            throw new RpcError(NO_METHOD, `no method \`${method}\``);
        }
    }
}
