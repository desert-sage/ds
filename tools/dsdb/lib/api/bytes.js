// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The API's `load` where there are no files (dsdb/DSDB_WEB.md §5): the
// program and trace as the page holds them, sent as base64 so the same JSON
// carries them over a WebSocket or to a worker. Nothing from Node.

import { OpError } from "./ops.js";
import { emptyProgram, openSession, sniff } from "./open.js";

/** @import { Compile, Ds } from "../core/types.js" */
/** @import { Load } from "./ops.js" */

/**
 * base64 to bytes, with what a browser has (`atob`).
 * @param {unknown} s
 * @returns {Uint8Array}
 */
export function fromBase64(s) {
    let bin;
    try {
        bin = atob(String(s));
    } catch {
        throw new OpError("not base64");
    }
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
}

/**
 * `load` from bytes.
 * @param {Ds} ds  a `@ds-lang/ds` API (in a page, `@ds-lang/ds/browser`'s `open`)
 * @param {object} [ports]
 * @param {Compile | null} [ports.compile]
 *   the compiler (in a page ds_dsc, which is async); with none,
 *   what compiles is refused
 * @param {((path: string, bytes: Uint8Array) => void) | null} [ports.write]  what a save does
 * @returns {Load}
 */
export function bytesLoad(ds, { compile = null, write = null } = {}) {
    // An edit's program and the files it imports, staged in the compiler's own
    // file system and compiled from there (DSDB.md §3), as the CLI stages them
    // in a scratch directory.
    const STAGE = "/.dsdb/program";
    const compileFiles = compile === null ? null
        : /**
           * @param {Map<string, string>} files  by name, the entry among them
           * @param {string} entry
           */
          async (files, entry) => {
              const text = files.get(entry);
              if (text === undefined) throw new TypeError(`${entry} is not among the staged files`);
              return compile(text, { file: entry, searchPath: [STAGE],
                                     files: Object.fromEntries([...files].map(([name, t]) => [`${STAGE}/${name}`, t])) });
          };
    /**
     * The compiler or the engine refusing what it was given.
     * @param {unknown} err
     * @returns {err is Error}
     */
    const refused = (err) => err instanceof Error && (err.name === "CompileRefused" || err.name === "DsError");
    return {
        description: "Load a DS program and, optionally, a trace to replay, as base64: the program a `.dsc`, or "
            + "its `.ds` when the compiler is here, or none when the trace embeds it; with no trace, a live session "
            + "starts. With neither, a live session on an empty program, which needs the compiler. Replaces "
            + "whatever was loaded.",
        inputSchema: { type: "object", properties: {
            program: { type: "string", description: "a .dsc, or its .ds with the compiler; base64" },
            trace: { type: "string", description: "a trace to replay, base64" },
        } },
        async open({ program, trace }, say) {
            /** @type {Uint8Array | null} */
            let dsc = null;
            /** @type {{ name: string, data: Uint8Array, front: number } | null} */
            let tr = null;
            /** @type {Uint8Array | null} */
            let compiled = null;
            /** @type {string | null} */
            let src = null;
            /** @type {Array<[string, unknown]>} */
            const given = [["program", program], ["trace", trace]];
            for (const [what, b64] of given) {
                if (b64 === undefined || b64 === null || b64 === "") continue;
                const data = fromBase64(b64);
                const got = sniff(ds, data);
                if (got.kind === "dsc") dsc = data;
                else if (got.kind === "trace") {
                    tr = { name: what, data, front: got.front };
                    if (got.front && dsc === null) dsc = data.subarray(0, got.front);
                } else if (got.kind === "source") {
                    if (compile === null) throw new OpError(`the ${what} is source: give its .dsc, or the compiler`);
                    src = "program.ds";
                    try {
                        compiled = await compile(new TextDecoder().decode(data), { file: src });
                    } catch (err) {
                        if (!refused(err)) throw err;
                        const diagnostics = "diagnostics" in err ? err.diagnostics : undefined;
                        throw new OpError(`the ${what} does not compile:\n${diagnostics ?? err.message}`);
                    }
                } else throw new OpError(`the ${what} is not a trace or a .dsc (${got.why})`);
            }
            const empty = dsc === null && tr === null && compiled === null;
            if (empty) {
                if (compile === null) throw new OpError("an empty program to build up needs the compiler, which is not here");
                const got = await emptyProgram(compile);
                if (got.dsc === undefined) throw new OpError(`an empty program does not compile:\n${got.why}`);
                compiled = got.dsc;
            }
            return openSession({ ds, dsc, trace: tr, compiled, src, empty,
                                 ports: { compile, compileFiles, write }, width: 100 }, say, "dsdb");
        },
    };
}
