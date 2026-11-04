// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// dsdb in a page (dsdb/DSDB_WEB.md §5): the API's protocol in a
// worker, so the engine's synchronous work does not stall the page. The
// messages are §3's JSON-RPC, as text, exactly what `ds serve` sends over
// its WebSocket, so a UI written against one works with the other by changing
// its transport. Nothing from Node. A page's worker script is:
//
//     import { open } from "@ds-lang/ds/browser";
//     import { startWorker } from "dsdb/api/worker";
//     startWorker({ ds: await open({ glue, runtime }) });
//
// What the session saves (`save_code`, `save_trace`) cannot be written in a
// page: it goes to the page as a `saved` notification, `{ path, data }` with
// the bytes as base64, for the page to offer as a download.

import { replacer } from "./json.js";
import { bytesLoad } from "./bytes.js";
import { Api } from "./ops.js";
import { Rpc } from "./rpc.js";

/** @import { Compile, Ds } from "../core/types.js" */

/**
 * What a worker's global gives the protocol: messages out, and messages in
 * through a listener it can take back.
 * @typedef {{ postMessage: (message: string) => void,
 *     addEventListener: (type: "message", listener: (event: MessageEvent) => void) => void,
 *     removeEventListener?: (type: "message", listener: (event: MessageEvent) => void) => void }} Scope
 */

/**
 * Bytes as base64, with what a browser has (`btoa`).
 * @param {Uint8Array} bytes
 */
function toBase64(bytes) {
    let s = "";
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(s);
}

/**
 * Answer the page's messages from inside a worker, one session, until the
 * worker ends.
 * @param {object} o
 * @param {Ds} o.ds  a `@ds-lang/ds` API: `@ds-lang/ds/browser`'s `open`
 * @param {Compile | null} [o.compile]  the page's compiler, ds_dsc (`@ds-lang/ds`'s dsc-wasm.js
 *   `compileWasm`), which is async; with none, what compiles is refused
 * @param {Scope} [o.scope]  the worker's global
 * @param {boolean} [o.shellLines]  offer `ops/exec`, shell lines as text, for a terminal (DSDB_WEB.md §7.2)
 * @returns {{ api: Api, close: () => void }}
 */
export function startWorker({ ds, compile = null, scope = globalThis, shellLines = false }) {
    /** @param {Record<string, unknown>} msg */
    const post = (msg) => scope.postMessage(JSON.stringify(msg, replacer));
    /**
     * @param {string} path
     * @param {Uint8Array} bytes
     */
    const write = (path, bytes) => post({ jsonrpc: "2.0", method: "saved", params: { path, data: toBase64(bytes) } });
    const api = new Api({ load: bytesLoad(ds, { compile, write }) });
    const rpc = new Rpc(api, post, (line) => console.error(`dsdb worker: ${line}`), { shellLines });
    /** @type {Promise<unknown>} the messages so far, handled in turn */
    let chain = Promise.resolve();
    /** @param {MessageEvent} event */
    const listener = (event) => {
        let msg;
        try {
            msg = typeof event.data === "string" ? JSON.parse(event.data) : event.data;
        } catch {
            msg = event.data;
        }
        chain = chain.then(() => rpc.handle(msg));
    };
    scope.addEventListener("message", listener);
    return {
        api,
        close: () => {
            scope.removeEventListener?.("message", listener);
            chain.finally(() => api.close());
        },
    };
}
