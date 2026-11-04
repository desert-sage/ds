// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// `ds serve` (dsdb/DSDB_WEB.md §4): dsdb's API over a WebSocket,
// driven by a client written here, frame by frame, as mcp.test.mjs drives
// stdio. Access (a token, the page's origin), the frames (masking, ping,
// fragments, binary refused), the protocol, and the fence. On either target.

import { test, describe, after, before } from "node:test";
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { Fence } from "../lib/cli/fence.js";
import { loopback, runServe } from "../lib/serve/server.js";

const TOKEN = "t0ken-for-the-tests";
// The tests' files are made here, so the server reads and writes here (DSDB_MCP.md §7).
const SCRATCH = process.env.DS_MERCURY_SCRATCH || tmpdir();

before(() => {
    process.env.DSDB_JS = fileURLToPath(new URL("../../../bindings/js/lib/index.js", import.meta.url));
});

/** A client frame: always masked (RFC 6455 §5.1). */
function frame(op, payload, fin = true) {
    const n = payload.length, mask = randomBytes(4);
    const head = n < 126 ? Buffer.from([(fin ? 0x80 : 0) | op, 0x80 | n])
        : Buffer.from([(fin ? 0x80 : 0) | op, 0x80 | 126, n >> 8, n & 0xff]);
    const body = Buffer.from(payload);
    for (let i = 0; i < body.length; i++) body[i] ^= mask[i & 3];
    return Buffer.concat([head, mask, body]);
}

/** Open a connection: `{ status }` when refused, else a client. */
async function connect(port, { token = TOKEN, origin, path = "/" } = {}) {
    const sock = net.connect(port, "127.0.0.1");
    await new Promise((resolve, reject) => { sock.once("connect", resolve); sock.once("error", reject); });
    sock.write(`GET ${path}?token=${encodeURIComponent(token)} HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\n`
               + "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
               + `Sec-WebSocket-Key: ${randomBytes(16).toString("base64")}\r\n`
               + (origin ? `Origin: ${origin}\r\n` : "") + "\r\n");
    let buf = Buffer.alloc(0);
    const status = await new Promise((resolve) => {
        const on = (chunk) => {
            buf = Buffer.concat([buf, chunk]);
            const end = buf.indexOf("\r\n\r\n");
            if (end < 0) return;
            sock.off("data", on);
            const line = buf.subarray(0, buf.indexOf("\r\n")).toString();
            buf = buf.subarray(end + 4);
            resolve(Number(line.split(" ")[1]));
        };
        sock.on("data", on);
        sock.once("close", () => resolve(0));
    });
    if (status !== 101) {
        sock.destroy();
        return { status };
    }
    return new Client(sock, buf);
}

class Client {
    status = 101;
    #sock;
    #buf;
    #got = [];              // frames arrived: { op, payload }
    #wake = null;
    #id = 0;
    notes = [];             // notifications, in order

    constructor(sock, rest) {
        this.#sock = sock;
        this.#buf = rest;
        sock.on("data", (c) => { this.#buf = Buffer.concat([this.#buf, c]); this.#parse(); });
        sock.on("close", () => { this.#got.push({ op: -1 }); this.#wake?.(); });
        this.#parse();
    }

    #parse() {
        for (;;) {
            const b = this.#buf;
            if (b.length < 2) break;
            let len = b[1] & 0x7f, at = 2;
            if (len === 126) { if (b.length < 4) break; len = b.readUInt16BE(2); at = 4; }
            else if (len === 127) { if (b.length < 10) break; len = Number(b.readBigUInt64BE(2)); at = 10; }
            if (b[1] & 0x80) throw new Error("the server masked a frame");
            if (b.length < at + len) break;
            this.#got.push({ op: b[0] & 0x0f, payload: b.subarray(at, at + len) });
            this.#buf = b.subarray(at + len);
        }
        this.#wake?.();
    }

    /** The next frame: `{ op, payload }`; op -1 when the connection closed. */
    async frame() {
        while (!this.#got.length) await new Promise((resolve) => { this.#wake = resolve; });
        this.#wake = null;
        return this.#got.shift();
    }

    raw(op, payload, fin = true) {
        this.#sock.write(frame(op, typeof payload === "string" ? Buffer.from(payload) : payload, fin));
    }

    send(msg) {
        this.raw(0x1, typeof msg === "string" ? msg : JSON.stringify(msg));
    }

    /** The next JSON message; notifications before it are kept in `notes`. */
    async message() {
        for (;;) {
            const f = await this.frame();
            if (f.op === -1 || f.op === 0x8) return { closed: f.op === 0x8 ? f.payload.readUInt16BE(0) : null };
            if (f.op !== 0x1) continue;
            return JSON.parse(f.payload.toString());
        }
    }

    /** A request, and its answer; notifications meanwhile into `notes`. */
    async request(method, params) {
        const id = ++this.#id;
        this.send({ jsonrpc: "2.0", id, method, params });
        for (;;) {
            const m = await this.message();
            if (m.closed !== undefined) throw new Error(`closed (${m.closed}) waiting for ${method}`);
            if (m.id === id) return m;
            this.notes.push(m);
        }
    }

    close() {
        this.#sock.destroy();
    }
}

describe("ds serve", () => {
    let server, port;
    before(async () => {
        mkdirSync(SCRATCH, { recursive: true });
        server = await runServe({ port: 0, token: TOKEN, fence: new Fence({ roots: [SCRATCH], out: SCRATCH }) });
        port = server.port;
    });
    after(async () => { await server?.close(); });

    test("refused: a missing or wrong token, a page from elsewhere, another path; plain HTTP is told to upgrade",
         async () => {
        assert.equal((await connect(port, { token: "" })).status, 401);
        assert.equal((await connect(port, { token: "wrong" })).status, 401);
        assert.equal((await connect(port, { origin: "https://evil.example" })).status, 403);
        assert.equal((await connect(port, { path: "/other" })).status, 404);
        const res = await fetch(`http://127.0.0.1:${port}/`);
        assert.equal(res.status, 426);
        assert.match(await res.text(), /speaks WebSocket/);
    });

    test("let in: a page from this machine, and a program that sends no Origin", async () => {
        for (const origin of ["http://localhost:5173", "http://127.0.0.1:8080", undefined]) {
            const c = await connect(port, { origin });
            assert.equal(c.status, 101, String(origin));
            c.close();
        }
    });

    test("--origin: only the pages it names, and no loopback page besides", async () => {
        const s = await runServe({ port: 0, token: TOKEN, origins: ["https://ui.example"] });
        try {
            assert.equal((await connect(s.port, { origin: "https://ui.example" })).status, 101);
            assert.equal((await connect(s.port, { origin: "http://localhost:5173" })).status, 403);
        } finally {
            await s.close();
        }
    });

    test("only a loopback address", async () => {
        assert.equal(loopback("127.0.0.1") && loopback("::1") && loopback("[::1]") && loopback("localhost"), true);
        assert.equal(loopback("0.0.0.0"), false);
        await assert.rejects(runServe({ host: "0.0.0.0", port: 0, token: TOKEN }), /not a loopback address/);
    });

    test("the protocol: ops/list, ping, a refusal before load, not JSON, no method", async () => {
        const c = await connect(port);
        try {
            const ops = await c.request("ops/list");
            const names = ops.result.ops.map((o) => o.name);
            for (const n of ["load", "where", "why", "whynot", "define", "save_code"]) assert.ok(names.includes(n), n);
            assert.ok(ops.result.ops.every((o) => o.outputSchema));
            // Shell lines are off unless the host turns them on (§7.2).
            assert.equal(ops.result.shellLines, false);
            const exec = await c.request("ops/exec", { line: "@" });
            assert.equal(exec.error.code, -32601);
            assert.match(exec.error.message, /shell lines are off/);
            assert.deepEqual((await c.request("ping")).result, {});
            const where = await c.request("ops/call", { name: "where" });
            assert.equal(where.result.isError, true);
            assert.match(where.result.text, /nothing is loaded/);
            c.send("{nope");
            assert.equal((await c.message()).error.code, -32700);
            assert.equal((await c.request("nope")).error.code, -32601);
            assert.equal((await c.request("ops/call", { name: "nope" })).error.code, -32602);
        } finally {
            c.close();
        }
    });

    test("frames: a ping answered, a fragmented message put together, a binary one refused", async () => {
        const c = await connect(port);
        try {
            c.raw(0x9, "hi");
            const pong = await c.frame();
            assert.deepEqual([pong.op, pong.payload.toString()], [0xA, "hi"]);
            const text = JSON.stringify({ jsonrpc: "2.0", id: 7, method: "ping" });
            c.raw(0x1, text.slice(0, 10), false);
            c.raw(0x0, text.slice(10), true);
            assert.deepEqual(await c.message(), { jsonrpc: "2.0", id: 7, result: {} });
            c.raw(0x2, Buffer.from([1, 2, 3]));
            assert.deepEqual(await c.message(), { closed: 1003 });
        } finally {
            c.close();
        }
    });

    test("a page has dsdb read only under --root and --out", async () => {
        const dir = mkdtempSync(join(SCRATCH, "dsdb-serve-fence-"));
        const s = await runServe({ port: 0, token: TOKEN, fence: new Fence({ roots: [dir], out: dir }) });
        const c = await connect(s.port);
        try {
            const r = await c.request("ops/call", { name: "load", args: { program: join(SCRATCH, "elsewhere.dsc") } });
            assert.equal(r.result.isError, true);
            assert.match(r.result.text, /elsewhere\.dsc: outside the directories dsdb may read/);
        } finally {
            c.close();
            await s.close();
            rmSync(dir, { recursive: true, force: true });
        }
    });
});
