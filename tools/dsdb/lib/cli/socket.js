// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The calls socket (DSDB.md §9.1): a Unix domain socket carrying one line per
// call out and one line per reply in. dsdb either connects to one a responder
// already listens on (`--calls PATH`) or listens itself and waits for the
// responder to connect (`--listen PATH`). Either way it is one peer, and the
// port core/batch.js reads and writes.

import { rmSync } from "node:fs";
import net from "node:net";

/** A socket that cannot be opened: exit 4, as an unreadable file is. */
export class SocketError extends Error {}

/**
 * Why a socket could not be opened, as a sentence.
 * @param {NodeJS.ErrnoException} err
 * @returns {string}
 */
function socketProblem(err) {
    if (err.code === "ENOENT") return "no such socket";
    if (err.code === "ECONNREFUSED") return "nothing is listening on it";
    if (err.code === "EADDRINUSE") return "it already exists";
    if (err.code === "EACCES") return "permission denied";
    return err.message;
}

export class LineSocket {
    /** @type {net.Socket} */
    #sock;
    /** @type {string} what has come in past the last whole line */
    #buf = "";
    /** @type {string[]} whole lines, not yet received */
    #lines = [];
    #closed = false;
    /** @type {(() => void) | null} what a waiting `receive` is woken by */
    #wake = null;
    /** @type {() => void} */
    #cleanup;

    /**
     * @param {net.Socket} sock  connected
     * @param {() => void} [cleanup]  what letting go of it also does
     */
    constructor(sock, cleanup = () => {}) {
        this.#sock = sock;
        this.#cleanup = cleanup;
        sock.setEncoding("utf8");
        sock.on("data", (s) => {
            this.#buf += s;
            let i;
            while ((i = this.#buf.indexOf("\n")) >= 0) {
                this.#lines.push(this.#buf.slice(0, i).replace(/\r$/, ""));
                this.#buf = this.#buf.slice(i + 1);
            }
            this.#notify();
        });
        const gone = () => {
            this.#closed = true;
            this.#notify();
        };
        sock.on("end", gone);
        sock.on("close", gone);
        // A peer that vanishes mid-run ends the waiting, not the run.
        sock.on("error", gone);
    }

    /**
     * Connect to a socket a responder listens on.
     * @param {string} path
     * @returns {Promise<LineSocket>}
     */
    static connect(path) {
        return new Promise((resolve, reject) => {
            const sock = net.createConnection({ path });
            sock.once("connect", () => {
                sock.removeAllListeners("error");
                resolve(new LineSocket(sock));
            });
            sock.once("error", (err) => reject(new SocketError(`${path}: ${socketProblem(err)}`)));
        });
    }

    /**
     * Listen on `path` and take the first peer that connects; no other is
     * accepted. The socket file is dsdb's, and removed when it is done.
     * `onListening` is called once the path exists.
     * @param {string} path
     * @param {() => void} [onListening]
     * @returns {Promise<LineSocket>}
     */
    static listen(path, onListening = () => {}) {
        return new Promise((resolve, reject) => {
            const server = net.createServer();
            let bound = false;
            const unlink = () => { if (bound) rmSync(path, { force: true }); };
            server.once("error", (err) => reject(new SocketError(`${path}: ${socketProblem(err)}`)));
            server.once("connection", (sock) => {
                server.close();
                resolve(new LineSocket(sock, () => {
                    unlink();
                    bound = false;
                    process.removeListener("exit", unlink);
                }));
            });
            server.listen(path, () => {
                bound = true;
                // Interrupted while waiting, the file must not outlive us.
                process.once("exit", unlink);
                onListening();
            });
        });
    }

    /**
     * A line out, without its newline; nothing once the peer is gone.
     * @param {string} line
     */
    send(line) {
        if (!this.#closed) this.#sock.write(line + "\n");
    }

    /**
     * The deadline `ms` of real time from now, for `receive`.
     * @param {number} ms
     * @returns {number} milliseconds since the epoch
     */
    after(ms) {
        return Date.now() + ms;
    }

    /**
     * The next line, or null once `deadline` passes or the peer is gone.
     * @param {number} deadline  as `after` gives it
     * @returns {Promise<string | null>}
     */
    async receive(deadline) {
        for (;;) {
            const line = this.#lines.shift();
            if (line !== undefined) return line;
            if (this.#closed) return null;
            const left = deadline - Date.now();
            if (left <= 0) return null;
            await /** @type {Promise<void>} */ (new Promise((resolve) => {
                const t = setTimeout(resolve, left);
                this.#wake = () => { clearTimeout(t); resolve(); };
            }));
        }
    }

    #notify() {
        const w = this.#wake;
        this.#wake = null;
        w?.();
    }

    /**
     * Finish writing, then let go.
     * @returns {Promise<void>}
     */
    close() {
        return new Promise((resolve) => {
            const done = () => { this.#cleanup(); resolve(); };
            if (this.#closed || this.#sock.destroyed) { this.#sock.destroy(); done(); return; }
            this.#sock.end(() => { this.#sock.destroy(); done(); });
        });
    }
}
