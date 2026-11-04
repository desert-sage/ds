// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Which target open() loads under Node. With none named, the one installed:
// native where it is, else wasm with its compiler, else a refusal naming each
// path. A named target is loaded or refused, never swapped for the other.
//
// Each install is a separate Node process, since a realm loads one target,
// with DS_JS_NATIVE / DS_JS_WASM / DS_JS_DSC naming what it holds. A stub
// stands in for each target: a module where its build would be that throws
// its own name when loaded, so a case reads which loader open() ran, builds
// neither target, and runs the same on both lanes. The last test opens the
// lane's real install with no target named, which is the call the bindings
// book shows.

import { test, describe, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { installed, open } from "../lib/index.js";

const INDEX = new URL("../lib/index.js", import.meta.url).href;

// The child: open() with the options it is handed, and what came of it.
const CHILD = `
const [index, options] = process.argv.slice(1);
const { open } = await import(index);
try {
    process.stdout.write(JSON.stringify({ target: (await open(JSON.parse(options))).target }));
} catch (err) {
    process.stdout.write(JSON.stringify({ refused: err.message }));
}
`;

/** The variables that name an install; each case sets its own. */
const INSTALL_ENV = ["DS_JS_NATIVE", "DS_JS_WASM", "DS_JS_DSC", "DS_JS_EMNAPI_RUNTIME"];

let dir;
let stub;
let absent;

before(() => {
    dir = mkdtempSync(join(process.env.DS_MERCURY_SCRATCH || tmpdir(), "ds-js-open-"));
    stub = {
        native: join(dir, "ds.cjs"),
        wasm: join(dir, "ds_wasm.mjs"),
        dsc: join(dir, "ds_dsc.mjs"),
        runtime: join(dir, "emnapi_runtime.cjs"),
    };
    writeFileSync(stub.native, "throw new Error(\"stub native target loaded\");\n");
    // The shape emcc writes: a default export that makes the module.
    writeFileSync(stub.wasm, `export default async function createDsWasm() {
    throw new Error("stub wasm target loaded");
}
`);
    // installed() asks only that ds_dsc is there; no case compiles.
    writeFileSync(stub.dsc, "");
    writeFileSync(stub.runtime, "exports.getDefaultContext = () => ({});\n");
    absent = { native: join(dir, "absent", "ds.node"), wasm: join(dir, "absent", "ds_wasm.mjs"),
               dsc: join(dir, "absent", "ds_dsc.mjs") };
});

after(() => { if (dir) rmSync(dir, { recursive: true, force: true }); });

/**
 * open(`options`) in a Node process whose install is `native`, `wasm` and
 * `dsc`, each a path: what it loaded, or the message it was refused with.
 */
function openIn({ native, wasm, dsc }, options = {}) {
    const env = { ...process.env };
    for (const name of [...INSTALL_ENV, "NODE_V8_COVERAGE"]) delete env[name];
    Object.assign(env, { DS_JS_NATIVE: native, DS_JS_WASM: wasm, DS_JS_DSC: dsc,
                         DS_JS_EMNAPI_RUNTIME: stub.runtime });
    const r = spawnSync(process.execPath, ["--input-type=module", "-e", CHILD, INDEX, JSON.stringify(options)],
                        { env, encoding: "utf8" });
    assert.equal(r.status, 0, `the child exited ${r.status}:\n${r.stderr}`);
    return JSON.parse(r.stdout);
}

describe("open() with no target, under Node", () => {
    test("loads native where native is installed, though wasm is too", () => {
        assert.deepEqual(openIn({ native: stub.native, wasm: stub.wasm, dsc: stub.dsc }),
                         { refused: "stub native target loaded" });
    });

    test("loads wasm where native is not installed and wasm and its compiler are", () => {
        assert.deepEqual(openIn({ native: absent.native, wasm: stub.wasm, dsc: stub.dsc }),
                         { refused: "stub wasm target loaded" });
    });

    test("is refused, naming each path, where neither target is installed", () => {
        const { refused } = openIn(absent);
        assert.match(refused, /^@ds-lang\/ds: no target is installed: /);
        for (const path of [absent.native, absent.wasm, absent.dsc])
            assert.ok(refused.includes(`(${path})`), `the refusal names ${path}: ${refused}`);
    });

    test("is refused where wasm is installed without its compiler", () => {
        const { refused } = openIn({ native: absent.native, wasm: stub.wasm, dsc: absent.dsc });
        assert.match(refused, /^@ds-lang\/ds: no target is installed: /);
        assert.ok(refused.includes(`(${absent.dsc})`), `the refusal names ${absent.dsc}: ${refused}`);
    });
});

describe("open() with a target named", () => {
    test("native, not installed, is refused though wasm is installed", () => {
        assert.deepEqual(openIn({ native: absent.native, wasm: stub.wasm, dsc: stub.dsc }, { target: "native" }),
                         { refused: `@ds-lang/ds: the native target is not installed (${absent.native})` });
    });

    test("wasm, not installed, is refused though native is installed", () => {
        assert.deepEqual(openIn({ native: stub.native, wasm: absent.wasm, dsc: stub.dsc }, { target: "wasm" }),
                         { refused: `@ds-lang/ds: the wasm target is not installed (${absent.wasm})` });
    });
});

const HERE = installed();
const NOTHING_HERE = HERE.native === null && (HERE.wasm === null || HERE.wasmCompiler === null)
    ? "no target is installed here: the js lanes name one (DS_JS_NATIVE, or DS_JS_WASM and DS_JS_DSC)" : false;

test("open() with no target loads this install's target, and an engine runs on it", {
    skip: NOTHING_HERE,
}, async () => {
    const ds = await open();
    assert.equal(ds.target, HERE.native !== null ? "native" : "wasm");
    const e = new ds.Engine();
    e.close();
});
