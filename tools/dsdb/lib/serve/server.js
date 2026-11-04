// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// `ds serve` (dsdb/DSDB_WEB.md §4): dsdb's API (lib/api) over a
// WebSocket, for a page written separately to drive a native dsdb. One
// session per connection, opened from paths as the MCP server's are
// (`nativeLoad`); the protocol is the API's (lib/api/rpc.js), requests
// answered in order.
//
// ACCESS: a loopback address only; a token, given at
// start, that the page presents as `?token=` (a browser's WebSocket cannot
// set a header); and the page's `Origin` checked: a loopback page by default,
// otherwise only the origins `--origin` names. A client that sends no Origin
// (a program, not a browser) is let in by its token alone. Native only.

import { randomBytes, timingSafeEqual } from "node:crypto";
import { createServer } from "node:http";

import { replacer } from "../api/json.js";
import { Api } from "../api/ops.js";
import { Rpc } from "../api/rpc.js";
import { Fence } from "../cli/fence.js";
import { nativeLoad } from "../cli/open.js";
import { WsConnection, acceptKey } from "./ws.js";

/** @import { IncomingMessage } from "node:http" */

const LOOPBACK = new Set(["127.0.0.1", "::1", "localhost"]);

/**
 * Whether `host` names this machine only.
 * @param {string} host
 */
export function loopback(host) {
    return LOOPBACK.has(String(host).replace(/^\[|\]$/g, ""));
}

/** A fresh token: 24 random bytes, hex. */
export function newToken() {
    return randomBytes(24).toString("hex");
}

/**
 * Whether two tokens are the same, in time that does not say where they
 * differ.
 * @param {string} a
 * @param {string} b
 */
const same = (a, b) => {
    const x = Buffer.from(String(a)), y = Buffer.from(String(b));
    return x.length === y.length && timingSafeEqual(x, y);
};

/**
 * Why an upgrade request is refused, as `[status, text]`, or null to accept it.
 * @param {IncomingMessage} req
 * @param {{ token: string, origins: string[] }} access
 * @returns {[number, string] | null}
 */
function refusal(req, { token, origins }) {
    const url = new URL(req.url ?? "/", "http://dsdb");
    if (url.pathname !== "/") return [404, "Not Found"];
    if (String(req.headers.upgrade ?? "").toLowerCase() !== "websocket" || !req.headers["sec-websocket-key"])
        return [400, "Bad Request"];
    if (req.headers["sec-websocket-version"] !== "13") return [426, "Upgrade Required"];
    if (!same(url.searchParams.get("token") ?? "", token)) return [401, "Unauthorized"];
    const origin = req.headers.origin;
    if (origin !== undefined) {
        const ok = origins.length ? origins.includes(origin) : (() => {
            try {
                return loopback(new URL(origin).hostname);
            } catch {
                return false;
            }
        })();
        if (!ok) return [403, "Forbidden"];
    }
    return null;
}

/**
 * Serve until `close` is called.
 * @param {object} o
 * @param {string} [o.host]  a loopback address
 * @param {number} [o.port]  0 for any free one
 * @param {string} o.token
 * @param {string[]} [o.origins]  the page origins let in; none: loopback pages
 * @param {string[]} [o.search]  -L directories for every load
 * @param {Fence} [o.fence]  where a page may have dsdb read and write (DSDB_MCP.md §7); default: the working directory
 * @param {boolean} [o.shellLines]  offer `ops/exec`, shell lines as text (DSDB_WEB.md §7.2)
 * @param {(line: string) => void} [o.log]
 * @returns {Promise<{ port: number, close: () => Promise<void> }>}
 */
export async function runServe({ host = "127.0.0.1", port = 7373, token, origins = [], search = [], fence = new Fence(),
                                 shellLines = false, log = () => {} }) {
    if (!loopback(host)) throw new Error(`serve: ${host} is not a loopback address; ds serve listens on this machine only`);
    if (!token) throw new Error("serve: no token");
    /** @type {Set<WsConnection>} */
    const open = new Set();
    const server = createServer((req, res) => {
        res.writeHead(426, { "content-type": "text/plain", upgrade: "websocket", connection: "Upgrade" });
        res.end("ds serve speaks WebSocket: connect to ws://HOST:PORT/?token=TOKEN\n");
    });
    server.on("upgrade", (req, socket, head) => {
        const no = refusal(req, { token, origins }), key = req.headers["sec-websocket-key"];
        if (no !== null || key === undefined) {
            // refusal() refuses a request with no key, so `no` says why.
            const [status, text] = no ?? [400, "Bad Request"];
            socket.end(`HTTP/1.1 ${status} ${text}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
            return;
        }
        socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                     + `Sec-WebSocket-Accept: ${acceptKey(key)}\r\n\r\n`);
        const api = new Api({ load: nativeLoad(search, fence) });
        /** @type {Promise<unknown>} the messages so far, handled in turn */
        let chain = Promise.resolve();
        /** @type {WsConnection} */
        let conn;
        const rpc = new Rpc(api, (msg) => conn.send(JSON.stringify(msg, replacer)), (l) => log(`ds serve: ${l}`),
                            { shellLines });
        conn = new WsConnection(socket, head, {
            onText: (text) => {
                /** @type {unknown} */
                let msg;
                try {
                    msg = JSON.parse(text);
                } catch {
                    msg = text;
                }
                chain = chain.then(() => rpc.handle(msg));
            },
            onClose: () => {
                open.delete(conn);
                chain.finally(() => api.close());
            },
        });
        open.add(conn);
    });
    await /** @type {Promise<void>} */ (new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(port, host, resolve);
    }));
    const address = server.address();
    // A server listening on a host and port has a TCP address.
    if (address === null || typeof address === "string") throw new Error(`serve: listening, but on no port (${address})`);
    return {
        port: address.port,
        close: () => /** @type {Promise<void>} */ (new Promise((resolve) => {
            for (const c of open) c.close(1001, "ds serve is stopping");
            server.close(() => resolve());
        })),
    };
}
