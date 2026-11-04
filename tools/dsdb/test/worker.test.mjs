// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// dsdb in a page (dsdb/DSDB_WEB.md §5): the API's protocol in a
// worker, driven by messages as a page drives it. A stand-in for the worker's
// global carries the messages; on the wasm target the binding is @ds-lang/ds's
// browser entry, so this is the stack a page runs: nothing from Node below
// the test itself. A program goes in as base64.

import { test, describe, before } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

import { startWorker } from "../lib/api/worker.js";
import { NO_COMPILER, TARGET } from "./compiler.mjs";

const NO_ENGINE = process.env.DS_JS_FIXTURES ? false : "needs the js gate's engine (DS_JS_FIXTURES)";
const NO_DSC = NO_ENGINE || NO_COMPILER;
const BINDING = new URL("../../../bindings/js/lib/", import.meta.url);

/** The binding as the target has it: in a page, `@ds-lang/ds`'s browser entry. */
async function binding() {
    if (TARGET !== "wasm") return (await import(new URL("index.js", BINDING).href)).open({ target: TARGET });
    const glue = process.env.DS_JS_WASM;
    const runtime = createRequire(import.meta.url)(process.env.DS_JS_EMNAPI_RUNTIME ?? "@emnapi/runtime");
    return (await import(new URL("browser.js", BINDING).href)).open({
        glue: pathToFileURL(glue).href, runtime, wasmBinary: new Uint8Array(readFileSync(glue.replace(/\.mjs$/, ".wasm"))) });
}

/** A worker's global, as far as startWorker uses it, and the page's end. */
function page() {
    const scope = {
        posted: [],
        postMessage(text) { this.posted.push(JSON.parse(text)); },
        addEventListener(type, fn) { if (type === "message") this.onmessage = fn; },
        removeEventListener() {},
    };
    let id = 0;
    return {
        scope,
        /**
         * A request, and its answer, once the worker has made it. Waited for
         * by the clock, not by turns of the event loop: a compile by
         * ds_dsc instantiates the compiler, which takes many turns.
         */
        async request(method, params) {
            const n = ++id;
            scope.onmessage({ data: JSON.stringify({ jsonrpc: "2.0", id: n, method, params }) });
            const until = Date.now() + 60_000;
            while (Date.now() < until) {
                const got = scope.posted.find((m) => m.id === n);
                if (got) return got;
                await new Promise((resolve) => setTimeout(resolve, 5));
            }
            throw new Error(`no answer to ${method} in 60 s`);
        },
        call(name, args = {}) {
            return this.request("ops/call", { name, args });
        },
    };
}

describe(`dsdb in a worker, on the ${TARGET} target`, () => {
    let ds;
    before(async () => {
        if (!NO_ENGINE) ds = await binding();
    });

    test("with a compiler, async as ds_dsc is: a .ds loads, and an empty program is built up",
         { skip: NO_DSC }, async () => {
        const { compile } = await import(new URL("index.js", BINDING).href);
        const { compileWasm } = await import(new URL("dsc-wasm.js", BINDING).href);
        // On wasm, ds_dsc itself, as a page runs it: the files it is
        // given (the page's staged program) go into its file system. Natively,
        // its shape over the native dsc: async, those files at their paths.
        const compileLater = TARGET === "wasm"
            ? (source, options = {}) => compileWasm(pathToFileURL(process.env.DS_JS_DSC).href, source, options)
            : async (source, { files = {}, searchPath = [], ...rest } = {}) => {
                const dir = mkdtempSync(join(process.env.DS_MERCURY_SCRATCH || tmpdir(), "dsdb-worker-"));
                const at = (p) => (p.startsWith("/.dsdb/") ? join(dir, p) : p);
                try {
                    for (const [p, text] of Object.entries(files)) {
                        mkdirSync(dirname(at(p)), { recursive: true });
                        writeFileSync(at(p), text);
                    }
                    return compile(source, { ...rest, searchPath: searchPath.map(at) });
                } finally {
                    rmSync(dir, { recursive: true, force: true });
                }
            };
        const SCHEMA = "schema Reading scope logical:\n    entity_id: String key\n    level: Float mutable\n";
        const HOT = "rule hot:\n    Reading r where r.level > 80.0\n->\n    log info \"hot {r.entity_id}\"\n";
        const p = page();
        const w = startWorker({ ds, scope: p.scope, compile: compileLater });
        try {
            const src = await p.call("load", { program: btoa(`use default\n\n${SCHEMA}\n${HOT}`) });
            assert.equal(src.result.isError, false, src.result.text);
            const empty = await p.call("load");
            assert.equal(empty.result.isError, false, empty.result.text);
            assert.equal((await p.call("define", { text: SCHEMA })).result.isError, false);
            const rule = await p.call("define", { text: HOT });
            assert.equal(rule.result.isError, false, rule.result.text);
            const emit = await p.call("from_here_emit", { text: 'Reading entity_id: "a" level: 95.0' });
            assert.equal(emit.result.isError, false, emit.result.text);
            const fired = await p.call("firings", { scope: "all", rule: "^hot$" });
            assert.equal(fired.result.results[0].count, 1);
        } finally {
            w.close();
        }
    });

    test("what the page cannot give yet is refused, saying why", { skip: NO_ENGINE }, async () => {
        const p = page();
        const w = startWorker({ ds, scope: p.scope });
        try {
            const src = await p.call("load", { program: btoa("rule r:\n    Reading r\n->\n    log info \"x\"\n") });
            assert.equal(src.result.isError, true);
            assert.match(src.result.text, /source: give its \.dsc, or the compiler/);
            const none = await p.call("load");
            assert.equal(none.result.isError, true);
            assert.match(none.result.text, /needs the compiler/);
            const bad = await p.call("load", { trace: "%%%" });
            assert.match(bad.result.text, /not base64/);
        } finally {
            w.close();
        }
    });
});
