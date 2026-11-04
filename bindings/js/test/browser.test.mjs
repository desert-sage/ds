// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// @ds-lang/ds's browser entry (lib/browser.js; tools/dsdb/DSDB_WEB.md §5).
// What a page loads imports nothing from Node; the two entries share their
// error classes; and, on the wasm target, libds opened through the browser
// entry, as a page opens it (the glue as a URL, the runtime as a module, the
// .wasm as bytes), is the same API: an engine loads, matches exactly and
// records to a sink. What a page has not got is refused, saying why.
// Node stands in for the page; nothing the entry imports is Node's.

import { test, describe, before } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

import * as node from "../lib/index.js";
import * as browser from "../lib/browser.js";

const TARGET = process.env.DS_JS_TARGET ?? "native";
const FIXTURES = process.env.DS_JS_FIXTURES;
const NOT_WASM = TARGET === "wasm" && FIXTURES && process.env.DS_JS_WASM ? false
    : "the browser entry loads the wasm target (DS_JS_WASM), in the js-wasm lane";
const TWO_53 = 9007199254740992n;

/** A module's code with its comments taken out, so prose can name Node. */
const code = (text) => text.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:"'`])\/\/.*$/gm, "$1");

describe("what a page loads", () => {
    for (const f of ["bind.js", "browser.js", "dsc-wasm.js", "status.js", "types.js"]) {
        test(`lib/${f} imports nothing from Node`, () => {
            const src = code(readFileSync(new URL(`../lib/${f}`, import.meta.url), "utf8"));
            for (const [bad, why] of [[/from\s+["']node:/, "a node: import"], [/\brequire\s*\(/, "require"],
                                      [/\bprocess\./, "process"], [/\bBuffer\b/, "Buffer"],
                                      [/from\s+["']\.\/(index|compile)\.js["']/,
                                       "the Node entry or the compiler shim"]])
                assert.doesNotMatch(src, bad, `lib/${f}: ${why}`);
        });
    }

    test("both entries give the same classes", () => {
        assert.equal(browser.DsError, node.DsError);
        assert.equal(browser.CompileRefused, node.CompileRefused);
        assert.equal(browser.status, node.status);
        assert.equal(browser.Engine, node.Engine);
        assert.equal(browser.Fact, node.Fact);
    });
});

describe("the browser entry, on the wasm target", { skip: NOT_WASM }, () => {
    let ds;
    before(async () => {
        if (NOT_WASM) return;
        const glue = process.env.DS_JS_WASM;
        const runtime = createRequire(import.meta.url)(process.env.DS_JS_EMNAPI_RUNTIME ?? "@emnapi/runtime");
        ds = await browser.open({ glue: pathToFileURL(glue).href, runtime,
                                  wasmBinary: new Uint8Array(readFileSync(glue.replace(/\.mjs$/, ".wasm"))) });
    });

    test("the same API: an engine loads a program and matches exactly", () => {
        assert.equal(ds.target, "wasm");
        const e = new ds.Engine();
        try {
            e.clock.mode = "mock";
            e.clock.set(0n);
            e.loadDsc(new Uint8Array(readFileSync(join(FIXTURES, "r1.dsc"))));
            e.assert("Reading", { id: "a", n: TWO_53 + 1n, x: 1.5, ok: true });
            e.pump();
            assert.deepEqual(e.facts({ schema: "Big" }).map((f) => f.read().slots).map((s) => [s.id, s.n]),
                             [["a", TWO_53 + 2n]]);
        } finally {
            e.close();
        }
    });

    test("recording goes to a sink; a path, which needs a file system, is refused", () => {
        const e = new ds.Engine();
        try {
            e.loadDsc(new Uint8Array(readFileSync(join(FIXTURES, "r1.dsc"))));
            assert.throws(() => e.recordTo("/tmp/x.dstrace"), /a path needs a file system/);
            let bytes = 0;
            e.recordTo((b) => { bytes += b.length; });
            e.assert("Reading", { id: "b", n: 1n, x: 0.5, ok: true });
            e.pump();
            e.stopRecording();
            assert.ok(bytes > 0);
        } finally {
            e.close();
        }
    });

    test("compiling waits for ds_dsc, and says so", () => {
        assert.throws(() => ds.compile("use default\n"), /ds_dsc/);
        assert.throws(() => ds.fromSource("use default\n"), /ds_dsc/);
    });
});
