// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// A WebSocket's server end (RFC 6455), hand-rolled as the MCP server's
// JSON-RPC is, so dsdb keeps no dependencies (dsdb/DSDB_WEB.md §4):
// the opening handshake's answer, text messages both ways (fragmented ones
// reassembled), ping and pong, and the closing handshake. No extensions, no
// subprotocols; a binary message is refused. Native only (lib/serve).

import { createHash } from "node:crypto";
import { Socket } from "node:net";

/** @import { Duplex } from "node:stream" */

const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/** The largest message taken, in bytes: past it the connection closes (1009). */
export const MAX_MESSAGE = 16 * 1024 * 1024;

/** Close codes (RFC 6455 §7.4.1). */
export const CLOSE = { NORMAL: 1000, PROTOCOL: 1002, UNSUPPORTED: 1003, BAD_DATA: 1007, TOO_BIG: 1009 };

/**
 * `Sec-WebSocket-Accept` for a client's `Sec-WebSocket-Key` (§4.2.2).
 * @param {string} key
 */
export function acceptKey(key) {
    return createHash("sha1").update(key + GUID).digest("base64");
}

/**
 * A frame's header and payload, server to client: never masked (§5.1).
 * @param {number} opcode
 * @param {Buffer} payload
 */
function frame(opcode, payload) {
    const n = payload.length;
    const head = n < 126 ? Buffer.from([0x80 | opcode, n])
        : n < 0x10000 ? Buffer.from([0x80 | opcode, 126, n >> 8, n & 0xff])
        : Buffer.concat([Buffer.from([0x80 | opcode, 127]), (() => { const b = Buffer.alloc(8); b.writeBigUInt64BE(BigInt(n)); return b; })()]);
    return Buffer.concat([head, payload]);
}

/** One accepted connection: text in through `onText`, text out through `send`. */
export class WsConnection {
    /** @type {Duplex} */
    #socket;
    /** @type {Buffer} what has come in past the last whole frame */
    #buf = Buffer.alloc(0);
    /** @type {Buffer[] | null} a fragmented message's parts so far, or null */
    #parts = null;
    #size = 0;
    #closed = false;
    /** @type {(text: string) => void} */
    #onText;
    /** @type {() => void} */
    #onClose;
    /** @type {number} */
    #max;

    /**
     * @param {Duplex} socket  upgraded: the 101 already written
     * @param {Buffer} head  bytes that came with the upgrade request
     * @param {{ onText: (text: string) => void, onClose: () => void, max?: number }} on
     */
    constructor(socket, head, { onText, onClose, max = MAX_MESSAGE }) {
        this.#socket = socket;
        this.#onText = onText;
        this.#onClose = onClose;
        this.#max = max;
        // An http server's upgraded connection is its TCP socket.
        if (socket instanceof Socket) socket.setNoDelay(true);
        socket.on("data", (chunk) => this.#take(chunk));
        socket.on("close", () => this.#gone());
        socket.on("error", () => this.#gone());
        if (head?.length) this.#take(head);
    }

    /** @param {string} text */
    send(text) {
        if (!this.#closed) this.#socket.write(frame(0x1, Buffer.from(text, "utf8")));
    }

    /**
     * Start the closing handshake, or end at once when it cannot be had.
     * @param {number} [code]
     * @param {string} [reason]
     */
    close(code = CLOSE.NORMAL, reason = "") {
        if (this.#closed) return;
        const r = Buffer.from(reason, "utf8").subarray(0, 123);
        const body = Buffer.alloc(2 + r.length);
        body.writeUInt16BE(code);
        r.copy(body, 2);
        this.#socket.end(frame(0x8, body));
        this.#gone();
    }

    #gone() {
        if (this.#closed) return;
        this.#closed = true;
        this.#onClose();
    }

    /** @param {Buffer} chunk */
    #take(chunk) {
        this.#buf = this.#buf.length ? Buffer.concat([this.#buf, chunk]) : chunk;
        while (!this.#closed) {
            const b = this.#buf;
            if (b.length < 2) return;
            const fin = (b[0] & 0x80) !== 0, rsv = b[0] & 0x70, op = b[0] & 0x0f;
            const masked = (b[1] & 0x80) !== 0;
            let len = b[1] & 0x7f, at = 2;
            if (len === 126) {
                if (b.length < 4) return;
                len = b.readUInt16BE(2);
                at = 4;
            } else if (len === 127) {
                if (b.length < 10) return;
                const big = b.readBigUInt64BE(2);
                if (big > BigInt(this.#max)) return this.close(CLOSE.TOO_BIG, "message too big");
                len = Number(big);
                at = 10;
            }
            // A client masks every frame; no extension is agreed, so no RSV bit.
            if (!masked || rsv) return this.close(CLOSE.PROTOCOL, masked ? "reserved bits set" : "unmasked frame");
            if (b.length < at + 4 + len) return;
            const mask = b.subarray(at, at + 4);
            const payload = Buffer.from(b.subarray(at + 4, at + 4 + len));
            for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
            this.#buf = b.subarray(at + 4 + len);
            this.#frame(fin, op, payload);
        }
    }

    /**
     * One whole frame, unmasked.
     * @param {boolean} fin
     * @param {number} op
     * @param {Buffer} payload
     */
    #frame(fin, op, payload) {
        if (op >= 0x8) {
            if (!fin || payload.length > 125) return this.close(CLOSE.PROTOCOL, "bad control frame");
            if (op === 0x8) return this.close(payload.length >= 2 ? payload.readUInt16BE(0) : CLOSE.NORMAL);
            if (op === 0x9) return void this.#socket.write(frame(0xA, payload));
            if (op === 0xA) return;
            return this.close(CLOSE.PROTOCOL, "unknown opcode");
        }
        if (op === 0x2) return this.close(CLOSE.UNSUPPORTED, "text messages only");
        /** @type {Buffer[]} */
        let parts;
        if (op === 0x1) {
            if (this.#parts !== null) return this.close(CLOSE.PROTOCOL, "a new message inside a fragmented one");
            parts = this.#parts = [];
            this.#size = 0;
        } else if (op === 0x0) {
            if (this.#parts === null) return this.close(CLOSE.PROTOCOL, "a continuation with no message");
            parts = this.#parts;
        } else return this.close(CLOSE.PROTOCOL, "unknown opcode");
        this.#size += payload.length;
        if (this.#size > this.#max) return this.close(CLOSE.TOO_BIG, "message too big");
        parts.push(payload);
        if (!fin) return;
        const whole = Buffer.concat(parts);
        this.#parts = null;
        let text;
        try {
            text = new TextDecoder("utf-8", { fatal: true }).decode(whole);
        } catch {
            return this.close(CLOSE.BAD_DATA, "not UTF-8");
        }
        this.#onText(text);
    }
}
