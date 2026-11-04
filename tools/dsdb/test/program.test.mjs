// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// A `.dsc` read back as declarations (core/program.js). The declarations are
// DS an author could compile, so what they print must be what the compiler
// takes. The fixtures are compiled by the js gate.

import { test, before } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { declaration, read as readProgram } from "../lib/core/program.js";

const TARGET = process.env.DS_JS_TARGET ?? "native";
const FIXTURES = process.env.DS_JS_FIXTURES;
const NO_ENGINE = FIXTURES ? false : "needs the js gate's engine and compiled fixtures (DS_JS_FIXTURES)";

let ds;
before(async () => {
    if (NO_ENGINE) return;
    const jsBinding = await import(new URL("../../../bindings/js/lib/index.js", import.meta.url).href);
    ds = await jsBinding.open({ target: TARGET });
});

test("a logical schema's `ts` is declared with no marker, as the compiler requires", { skip: NO_ENGINE }, () => {
    // The artefact gives `ts` the role ENGINE; a `key` or `mutable` on it is
    // refused ([LFAC.9.1]), so the declaration carries neither.
    const dsc = new Uint8Array(readFileSync(join(FIXTURES, "dsdb_ts.dsc")));
    const reading = readProgram(ds, dsc).schemas.get("Reading");
    assert.equal(reading.slots.find((s) => s.name === "ts").role, 3);
    const lines = declaration(reading);
    assert.deepEqual(lines.slice(0, 3), ["schema Reading scope logical:", "    id: Int key", "    v: Int mutable"]);
    // The type is the one the artefact's slot kind names; what this pins is
    // that nothing follows it.
    assert.match(lines[3], /^ {4}ts: \w+$/);
    assert.equal(lines.length, 4);
});
