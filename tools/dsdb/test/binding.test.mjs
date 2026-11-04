// SPDX-FileCopyrightText: 2026 Dan Finster and the DS Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// [RFCS.4.5]'s binding check (lib/core/binding.js) on tuples made here: each
// case libds's replayer makes, in its order, with its code. The shell, the
// listing and the debug adapter run it on real traces (cli.test.mjs,
// dap.test.mjs); these are the cases no recorded trace reaches.
//
// dsdb makes the dialect-binding comparison in its own code ([RBND.6.3]), so it
// carries [RBND.8.1]'s four tests for it, linked to the adapter's clause
// [NDBG.14r.6.5]: identical tuples, a dsc_hash mismatch, a single-capability
// delta, and two dialect names that resolve alike.

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { compilerPort } from "../lib/cli/open.js";
import { bindingCheck, programTuple, streamTuple } from "../lib/core/binding.js";
import { NO_COMPILER, TARGET } from "./compiler.mjs";

const NO_ENGINE = process.env.DS_JS_FIXTURES ? false : "needs the js gate's engine (DS_JS_FIXTURES)";
const NO_DSC = NO_ENGINE || NO_COMPILER;

const H = (/** @type {number} */ b) => new Uint8Array(32).fill(b);
const cap = (/** @type {number} */ number, /** @type {string} */ name) => ({ number, name });
const A = cap(1, "CAPABILITY_FLOAT"), B = cap(2, "CAPABILITY_REGEX");
const tuple = (/** @type {any} */ o = {}) => ({ hash: H(1), capabilities: [A, B], def: H(2), ...o });

describe("the binding check", () => {
    // [RBND.8.1]'s first test: identical tuples bind.
    // @spec [RFCS.4.5] [NDBG.14r.6.5]
    test("the same tuple binds", () => {
        assert.deepEqual(bindingCheck(tuple(), tuple()), { checked: true, unbound: null });
    });

    // @spec [RFCS.4.5]
    test("a stream with neither hash replays with no check; so does a program that states no dsc_hash", () => {
        assert.deepEqual(bindingCheck(tuple({ hash: null, def: null }), tuple()), { checked: false, unbound: null });
        assert.deepEqual(bindingCheck(tuple(), tuple({ hash: null })), { checked: false, unbound: null });
    });

    // @spec [RFCS.4.5]
    test("a stream with one hash and not the other is incomplete, whatever the program", () => {
        for (const t of [tuple({ def: null }), tuple({ hash: null })])
            for (const p of [tuple(), tuple({ hash: null })])
                assert.equal(bindingCheck(t, p).unbound?.code, "DS_ERR_BND_INCOMPLETE");
    });

    // [RBND.8.1]'s second and third tests: a dsc_hash mismatch, and a
    // single-element capabilities delta under an equal dsc_hash.
    // @spec [RFCS.4.5] [NDBG.14r.6.5]
    test("each field that differs is refused with its code, the dsc_hash first", () => {
        const dsc = bindingCheck(tuple({ hash: H(9), def: H(9) }), tuple());
        assert.equal(dsc.unbound?.code, "DS_ERR_BND_DSC_MISMATCH", "dsc_hash is compared before the dialect");
        // [RBND.5.2]: each value truncated to 16 hex characters, as libds gives it.
        assert.match(dsc.unbound?.detail ?? "", /^dsc_hash: trace (09){8}, program (01){8}$/);
        const caps = bindingCheck(tuple({ capabilities: [A] }), tuple());
        assert.equal(caps.unbound?.code, "DS_ERR_BND_DIALECT_MISMATCH");
        assert.equal(caps.unbound?.detail, "capabilities: only the trace's (none), only the program's regex");
        const def = bindingCheck(tuple({ def: H(9) }), tuple());
        assert.equal(def.unbound?.code, "DS_ERR_BND_DIALECT_MISMATCH");
        assert.match(def.unbound?.detail ?? "", /^dialect_def_sha256: trace (09){8}, program (02){8}$/);
    });

    // @spec [NDBG.14r.6.5]
    test("capability 0, which names no setting, is written as its number, as libds writes it", () => {
        // The reader names 0 `CAPABILITY_UNSPECIFIED`; the detail does not.
        const r = bindingCheck(tuple({ capabilities: [cap(0, "CAPABILITY_UNSPECIFIED")] }), tuple({ capabilities: [] }));
        assert.equal(r.unbound?.code, "DS_ERR_BND_DIALECT_MISMATCH");
        assert.equal(r.unbound?.detail, "capabilities: only the trace's 0, only the program's (none)");
    });

    // @spec [RFCS.4.5]
    test("the capabilities are compared as a sequence, not a set", () => {
        const r = bindingCheck(tuple({ capabilities: [B, A] }), tuple());
        assert.equal(r.unbound?.code, "DS_ERR_BND_DIALECT_MISMATCH");
        assert.equal(r.unbound?.detail, "capabilities: the same, in another order");
    });

    // [RBND.8.1]'s fourth test, at the comparator as it allows: one program
    // compiled under `default` and under `base` with a `use` block turning on
    // exactly default's settings ([LDIA.9.2]), so two dialect names resolve
    // alike. The tuple carries no name ([RBND.1.3]), so the DscHeader read
    // (programTuple) gives equal capabilities and dialect_def_sha256, and
    // with the hash set to one value the comparison binds.
    // @spec [NDBG.14r.6.5]
    test("two dialect names whose settings resolve alike give one tuple, and it binds", { skip: NO_DSC }, async () => {
        const jsBinding = await import(new URL("../../../bindings/js/lib/index.js", import.meta.url).href);
        const ds = await jsBinding.open({ target: TARGET });
        const compile = compilerPort(ds);
        const body = "\nschema Trig scope logical:\n    v: Int key\n\nrule r:\n    Trig t where t.v > 0\n->\n    log info \"x\"\n";
        const asBase = "use base:\n" + ["linear_scan", "logical", "regex", "float", "call", "publish", "cache",
                                        "cache_delete", "nocooldown", "series"].map((c) => `    ${c}: true\n`).join("");
        const named = await compile(`use default\n${body}`, { file: "default.ds" });
        const unnamed = await compile(`${asBase}${body}`, { file: "base.ds" });
        const one = H(7);
        const a = programTuple(ds, named, one), b = programTuple(ds, unnamed, one);
        assert.ok(a.def !== null && a.capabilities.length > 0, "the DscHeader's tuple was read");
        assert.deepEqual(b.capabilities.map((c) => c.number), a.capabilities.map((c) => c.number),
                         "the same capabilities, in the same order");
        assert.deepEqual([...(b.def ?? [])], [...a.def], "the same dialect_def_sha256");
        assert.deepEqual(bindingCheck(a, b), { checked: true, unbound: null });
    });

    test("a StreamHeader's tuple as the reader gives it: a hash that is not 32 bytes is none", () => {
        assert.deepEqual(streamTuple({ dsc_hash: H(1), capabilities: [A], dialect_def_sha256: new Uint8Array() }),
                         { hash: H(1), capabilities: [A], def: null });
        assert.deepEqual(streamTuple(null), { hash: null, capabilities: [], def: null });
    });
});
