// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// dsdb's API (dsdb/DSDB_WEB.md §3): what a page will drive. The layers
// it rests on import nothing from Node and nothing from the front ends, so they
// run in a browser.

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";

/** A module's code with its comments taken out, so prose can name Node. */
const code = (text) => text.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:"'`])\/\/.*$/gm, "$1");

describe("what a page loads (§2)", () => {
    for (const dir of ["core", "text", "api"]) {
        test(`lib/${dir} imports nothing from Node and nothing from the front ends`, () => {
            const base = new URL(`../lib/${dir}/`, import.meta.url);
            const files = readdirSync(base).filter((f) => f.endsWith(".js"));
            assert.ok(files.length);
            for (const f of files) {
                const src = code(readFileSync(new URL(f, base), "utf8"));
                for (const [bad, why] of [[/from\s+["']node:/, "a node: import"], [/\brequire\s*\(/, "require"],
                                          [/\bprocess\./, "process"], [/\bBuffer\b/, "Buffer"],
                                          [/from\s+["']\.\.\/(cli|mcp|serve)\//, "a front end"]])
                    assert.doesNotMatch(src, bad, `lib/${dir}/${f}: ${why}`);
            }
        });
    }
});
