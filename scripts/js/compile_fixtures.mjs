// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Compile .ds sources to .dsc with ds_dsc, the wasm compiler, through
// the package's own wasm runner (lib/dsc-wasm.js): what check.py's wasm target
// compiles its fixtures with, so it needs no native `dsc`.
//
//     node scripts/js/compile_fixtures.mjs <ds_dsc.mjs> <out dir> <root> <source>...
//
// Each source is compiled under its path relative to <root>, as check.py's
// native compile names it, and written to <out dir>/<stem>.dsc. A refusal
// stops the run, exit 1, with the compiler's own report.
import { readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, join, relative } from "node:path";
import { pathToFileURL } from "node:url";
import { compileWasm } from "../../bindings/js/lib/dsc-wasm.js";

const [mjs, out, root, ...sources] = process.argv.slice(2);
if (mjs === undefined || out === undefined || root === undefined || sources.length === 0) {
    process.stderr.write("usage: compile_fixtures.mjs <ds_dsc.mjs> <out dir> <root> <source>...\n");
    process.exit(2);
}
const compiler = await import(pathToFileURL(mjs).href);
// Compiled once, instantiated per source: each compile is a fresh `main`.
const wasmModule = await WebAssembly.compile(readFileSync(join(dirname(mjs), "dsc_cli.wasm")));
for (const src of sources) {
    const rel = relative(root, src);
    let bytes;
    try {
        bytes = await compileWasm(compiler, readFileSync(src, "utf8"), { file: rel, wasmModule });
    } catch (e) {
        process.stderr.write(`ds_dsc refused ${rel}:\n${e instanceof Error ? e.message : String(e)}\n`);
        process.exit(1);
    }
    writeFileSync(join(out, `${basename(src, ".ds")}.dsc`), bytes);
    process.stdout.write(`  ${rel} -> ${bytes.length} bytes\n`);
}
