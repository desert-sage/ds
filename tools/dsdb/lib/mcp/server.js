// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// `ds mcp`: an MCP server over stdio (dsdb/DSDB_MCP.md §6).
// JSON-RPC 2.0, one message per line, hand-rolled: dsdb has no dependencies,
// and the part of the protocol a tools server needs is small: tools, and the
// resources of §10.2. One client, one session (§1), so requests are handled one
// at a time, in order.
//
// The tools are dsdb's API's operations (lib/api/, DSDB_WEB.md §3), opened
// from paths (cli/open.js `nativeLoad`). A tool that refuses (no such fact,
// mid-cascade) answers with `isError` and the shell's message: the agent reads
// it and adjusts. A protocol error (an unknown method or tool, a malformed
// message) is a JSON-RPC error.

import { readFileSync } from "node:fs";

import { replacer } from "../api/json.js";
import { Api } from "../api/ops.js";
import { ResourceError, TEMPLATES, list, read } from "../api/resources.js";
import { members } from "../api/rpc.js";
import { Fence } from "../cli/fence.js";
import { nativeLoad } from "../cli/open.js";

/** @import { OnProgress } from "../api/ops.js" */
/** @import { CallsPort } from "../core/batch.js" */

/** @typedef {(msg: Record<string, unknown>) => void} Send  a message to the client, the version added */

/** The protocol revisions spoken, newest first: the two newest. A client asking for one of them gets it; any other gets the
    newest. Both have outputSchema (§10.7), so tools/list is the same for each. */
export const PROTOCOLS = ["2025-11-25", "2025-06-18"];

const VERSION = JSON.parse(readFileSync(new URL("../../package.json", import.meta.url), "utf8")).version;

const INSTRUCTIONS = "dsdb debugs DS programs: `load` a program and a trace (or no trace, for a live session), "
    + "then look with `population`, `facts`, `query`, `firings`, `why`, `rete` and `calls`, each at a point "
    + "(`at`) without moving it, and move point with `move`. Facts are named by id, firings by rule and timetag, "
    + "points by the positions listings print.";

const PARSE = -32700, INVALID = -32600, NO_METHOD = -32601, BAD_PARAMS = -32602, INTERNAL = -32603;

/**
 * Serve until the input ends.
 * @param {object} o
 * @param {AsyncIterable<string>} o.lines  the client's messages, one per line
 * @param {(s: string) => void} o.write  to the client
 * @param {(s: string) => void} o.log  not to the client: stderr
 * @param {string[]} [o.search]  -L directories for every load
 * @param {CallsPort | null} [o.calls]  a calls socket (cli/socket.js), for a live session's calls (§10.8)
 * @param {number} [o.callTimeoutMs]  how long a round of calls waits for replies
 * @param {Fence} [o.fence]  where the tools may read and write (§7); default: the working directory
 */
export async function runMcp({ lines, write, log, search = [], calls = null, callTimeoutMs = 5000, fence = new Fence() }) {
    const tools = new Api({ load: nativeLoad(search, fence), calls, callTimeoutMs });
    /** @type {Send} */
    const send = (msg) => write(JSON.stringify({ jsonrpc: "2.0", ...msg }, replacer) + "\n");
    /**
     * @param {unknown} id  the request's
     * @param {number} code
     * @param {string} message
     */
    const fail = (id, code, message) => send({ id, error: { code, message } });
    // §10.2: the client hears when the resources listed change (a load, a
    // fork, a kill); what they hold changes with every edit, unannounced.
    const uris = () => list(tools.loaded).map((r) => r.uri).join("\n");
    let listed = uris();
    try {
        for await (const line of lines) {
            if (!line.trim()) continue;
            /** @type {unknown} */
            let parsed;
            try {
                parsed = JSON.parse(line);
            } catch {
                fail(null, PARSE, "not JSON");
                continue;
            }
            if (Array.isArray(parsed) || parsed === null || typeof parsed !== "object") {
                fail(null, INVALID, "one JSON-RPC message per line; batches are not accepted");
                continue;
            }
            const msg = members(parsed);
            if (typeof msg.method !== "string") continue;      // a response to nothing we asked
            const request = Object.hasOwn(msg, "id");
            try {
                const result = await handle(tools, msg.method, members(msg.params), send);
                if (request) send({ id: msg.id, result: result ?? {} });
            } catch (err) {
                if (err instanceof RpcError || err instanceof ResourceError) {
                    if (request) fail(msg.id, err.code, err.message);
                } else {
                    log(`ds mcp: ${msg.method}: ${err instanceof Error ? err.stack ?? err : err}`);
                    if (request) fail(msg.id, INTERNAL, err instanceof Error ? err.message : String(err));
                }
            }
            const now = uris();
            if (now !== listed) {
                listed = now;
                send({ method: "notifications/resources/list_changed" });
            }
        }
    } finally {
        tools.close();
    }
}

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

/**
 * A request's or notification's result: null for one that needs no answer.
 * @param {Api} tools
 * @param {string} method
 * @param {Record<string, unknown>} params
 * @param {Send} send
 * @returns {Promise<Record<string, unknown> | null>}
 */
async function handle(tools, method, params, send) {
    switch (method) {
    case "initialize": {
        const asked = params.protocolVersion;
        return {
            protocolVersion: typeof asked === "string" && PROTOCOLS.includes(asked) ? asked : PROTOCOLS[0],
            capabilities: { tools: {}, resources: { listChanged: true } },
            serverInfo: { name: "dsdb", version: VERSION },
            instructions: INSTRUCTIONS,
        };
    }
    case "ping":
        return {};
    case "tools/list":
        return { tools: tools.list({ outputSchemas: true }) };
    case "tools/call": {
        if (typeof params.name !== "string" || !tools.has(params.name))
            throw new RpcError(BAD_PARAMS, `no tool \`${params.name}\``);
        const args = params.arguments ?? {};
        if (typeof args !== "object" || Array.isArray(args)) throw new RpcError(BAD_PARAMS, "`arguments` is an object");
        // §10.3: long work says how far it has got while it runs; the work is
        // synchronous, and a write to a pipe is too, so each goes out then.
        const token = members(params._meta).progressToken;
        /** @type {OnProgress | null} */
        const progress = typeof token !== "string" && typeof token !== "number" ? null
            : (done, total, message) => send({ method: "notifications/progress",
                                              params: { progressToken: token, progress: done, total, message } });
        const got = await tools.call(params.name, members(args), progress);
        return { content: [{ type: "text", text: got.text }], structuredContent: { results: got.results },
                 isError: got.isError };
    }
    case "resources/list":
        return { resources: list(tools.loaded) };
    case "resources/templates/list":
        return { resourceTemplates: TEMPLATES };
    case "resources/read":
        if (typeof params.uri !== "string") throw new RpcError(BAD_PARAMS, "`uri` is a string");
        return { contents: read(tools.loaded, params.uri) };
    default:
        // Notifications (initialized, cancelled, …) need no answer.
        if (method.startsWith("notifications/")) return null;
        throw new RpcError(NO_METHOD, `no method \`${method}\``);
    }
}
