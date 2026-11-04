// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The Language Server Protocol's base protocol: a header part, its lines ended
// by CRLF and itself by a blank line, then a body of exactly Content-Length
// bytes of UTF-8 JSON. `Content-Type` may be sent and is not read: the body is
// JSON-RPC in UTF-8, which is the only content type the protocol defines.
// Hand-rolled, as the MCP server's JSON-RPC is: dsdb has no dependencies.

/** The client's bytes cannot be read as messages: the stream is unusable. */
export class FrameError extends Error {
    /** @param {string} message */
    constructor(message) {
        super(message);
        this.name = "FrameError";
    }
}

const END_OF_HEADER = Buffer.from("\r\n\r\n");

/** The longest body read, in bytes: a document an editor sends whole, with room
    to spare. A header asking for more is refused before anything is buffered,
    as a loader refuses a malformed header rather than believe it. */
export const MAX_BODY = 64 * 1024 * 1024;

/** The longest header part, in bytes: a few short lines. */
const MAX_HEADER = 8 * 1024;

/**
 * Each message's body, as text, in the order the bytes bring them. A message
 * split across chunks waits for the rest; several in one chunk come out one
 * by one. Throws FrameError for a header with no Content-Length, a header past
 * MAX_HEADER bytes, or a Content-Length past MAX_BODY.
 * @param {AsyncIterable<Uint8Array>} chunks
 * @param {{ maxBody?: number }} [opts]
 * @returns {AsyncGenerator<string>}
 */
export async function* bodies(chunks, { maxBody = MAX_BODY } = {}) {
    let buf = Buffer.alloc(0);
    for await (const chunk of chunks) {
        buf = Buffer.concat([buf, chunk]);
        for (;;) {
            const end = buf.indexOf(END_OF_HEADER);
            if (end < 0) {
                if (buf.length > MAX_HEADER) throw new FrameError(`a header longer than ${MAX_HEADER} bytes`);
                break;
            }
            const header = buf.subarray(0, end).toString("ascii");
            /** @type {number | null} */
            let length = null;
            for (const line of header.split("\r\n")) {
                const m = /^content-length:[ \t]*(\d+)[ \t]*$/i.exec(line);
                if (m) length = Number(m[1]);
            }
            if (length === null) throw new FrameError(`a header with no Content-Length: ${JSON.stringify(header)}`);
            if (length > maxBody) throw new FrameError(`a Content-Length of ${length} bytes, past the ${maxBody} this reads`);
            const start = end + END_OF_HEADER.length;
            if (buf.length < start + length) break;
            yield buf.subarray(start, start + length).toString("utf8");
            buf = buf.subarray(start + length);
        }
    }
}

/**
 * One message, framed: the length is the body's in bytes, not characters.
 * @param {unknown} message
 * @returns {string}
 */
export function frame(message) {
    const body = JSON.stringify(message);
    return `Content-Length: ${Buffer.byteLength(body, "utf8")}\r\n\r\n${body}`;
}
