// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The language server's ports, on the target dsdb runs on: the
// compiler as @ds-lang/ds runs it, natively `dsc` (`DS_MERCURY_DSC`, else `dsc`
// on PATH) and under wasm ds_dsc. A compile goes through @ds-lang/ds's
// own runner, so its command line is the one every host builds; @ds-lang/ds has
// no `dump-ast`, so that one is run here, through the same compiler: the
// binary natively, @ds-lang/ds's `runDscUnderWasm` under wasm.

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";

/** @import { LspPorts } from "./server.js" */
/** @import { Binding, BoundDs } from "../cli/open.js" */

/**
 * @param {Binding} binding  `@ds-lang/ds`'s Node entry
 * @param {BoundDs} ds  the API on the target dsdb runs on
 * @returns {LspPorts}
 */
export function lspPorts(binding, ds) {
    return {
        async dumpAst(text, file) {
            const argv = ["dump-ast", "-", "--filename", file];
            /** @type {{ status: number | null, stdout: string, stderr: string, signal?: string | null }} */
            let run;
            if (ds.target === "wasm") {
                const r = await binding.runDscUnderWasm(argv, { stdin: new TextEncoder().encode(text) });
                run = { status: r.status, stdout: new TextDecoder().decode(r.stdout), stderr: r.stderr };
            } else {
                const dsc = process.env.DS_MERCURY_DSC || "dsc";
                const r = spawnSync(dsc, argv, { input: text, encoding: "utf8", maxBuffer: 1 << 28 });
                if (r.error) throw r.error;
                run = r;
            }
            if (run.status === 0) return { tree: JSON.parse(run.stdout) };
            if (run.status === 1) return { refused: run.stderr };
            throw new Error(`dsc dump-ast exited ${run.status ?? run.signal}: ${run.stderr.trim()}`);
        },
        read(path) {
            try {
                return readFileSync(path, "utf8");
            } catch {
                return null;
            }
        },
        async compile(text, file, search) {
            // A directory that is not there finds no import, and `dsc` refuses
            // the whole compile over it: a buffer not saved yet, or a library
            // directory the editor names that has gone.
            const searchPath = search.filter((d) => existsSync(d));
            try {
                await ds.compile(text, { file, searchPath });
                return null;
            } catch (err) {
                if (err instanceof ds.CompileRefused) return err.diagnostics;
                throw err;
            }
        },
    };
}
