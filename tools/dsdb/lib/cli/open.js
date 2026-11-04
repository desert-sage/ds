// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Opening a session from files (DSTRACE_INTERACTIVE §2): the files read, the
// binding loaded, a `.ds` compiled with -L, and the scratch directory a rule
// change is compiled in; then lib/api/open.js, which does the rest from bytes.
// Shared by the shell (main.js) and the MCP server's `load` (lib/mcp/), which
// say the same things through `say`.

import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";

import { OpError } from "../api/ops.js";
import { emptyProgram, openSession as openBytes, sniff } from "../api/open.js";
import { fileProblem } from "../core/files.js";
import { Fenced } from "./fence.js";

/** @import { Target } from "@ds-lang/ds" */
/** @import { Load, Opened, Say } from "../api/ops.js" */
/** @import { Compile } from "../core/types.js" */
/** @import { Fence } from "./fence.js" */

/** @typedef {typeof import("@ds-lang/ds")} Binding  `@ds-lang/ds`'s Node entry */

/** A file that cannot be read: exit 4. */
export class Unreadable extends Error {}

/** `@ds-lang/ds`, or the target it is asked for, is not installed: exit 4, said in a sentence. */
export class NoBinding extends Error {}

/**
 * A file's bytes. Throws Unreadable.
 * @overload
 * @param {string} path
 * @returns {Buffer}
 */
/**
 * A file's text, in `encoding`. Throws Unreadable.
 * @overload
 * @param {string} path
 * @param {BufferEncoding} encoding
 * @returns {string}
 */
/**
 * @param {string} path
 * @param {BufferEncoding} [encoding]
 * @returns {Buffer | string}
 */
export function read(path, encoding) {
    try {
        return readFileSync(path, encoding);
    } catch (err) {
        throw new Unreadable(`cannot read ${path}: ${fileProblem(err)}`);
    }
}

/**
 * The binding, `@ds-lang/ds`, from DSDB_JS (a path to its lib/index.js)
 * or the package. Throws NoBinding when neither is there, with the loader's
 * own message, so a broken install still says what broke.
 * @returns {Promise<Binding>}
 */
export async function loadBinding() {
    const where = process.env.DSDB_JS;
    try {
        return await import(where ? pathToFileURL(resolve(where)).href : "@ds-lang/ds");
    } catch (err) {
        if (!(err instanceof Error && "code" in err && err.code === "ERR_MODULE_NOT_FOUND")) throw err;
        throw new NoBinding(where
            ? `@ds-lang/ds is not where DSDB_JS says (${where}): ${err.message}`
            : "@ds-lang/ds, the binding dsdb runs on, is not installed; install the DS tools package, "
              + `or set DSDB_JS to a checkout's bindings/js/lib/index.js (${err.message})`,
                            { cause: err });
    }
}

/** @typedef {Awaited<ReturnType<Binding["open"]>>} BoundDs  the `@ds-lang/ds` API on one target */

/**
 * The `@ds-lang/ds` API on the target dsdb runs on (`target`), with a target that
 * is not installed (no native addon built, no wasm build) said as NoBinding
 * rather than thrown raw.
 * @param {Binding} binding
 * @returns {Promise<BoundDs>}
 */
export async function openTarget(binding) {
    const t = target(binding);
    try {
        return await binding.open({ target: t });
    } catch (err) {
        // @ds-lang/ds's own words for it (bindings/js/lib/index.js,
        // loadNative and loadWasm); anything else is not this.
        if (err instanceof Error && /^@ds-lang\/ds: the (native|wasm) target is not installed/.test(err.message))
            throw new NoBinding(process.env.DS_JS_TARGET === undefined
                ? "@ds-lang/ds has neither target installed, no native addon and no wasm build; install the DS "
                  + "tools package, or set DS_JS_NATIVE or DS_JS_WASM to a build elsewhere"
                : `${err.message}; DS_JS_NATIVE (or DS_JS_WASM) names a build elsewhere`, { cause: err });
        throw err;
    }
}

/**
 * The target dsdb runs on: DS_JS_TARGET where it names one; else native
 * where its addon is installed, and wasm otherwise. `@ds-lang/ds` never falls back
 * from one to the other ([LDET.2.3]): dsdb chooses before it opens, and says
 * which (`--version`, the shell's banner); a recording says so in its
 * platform signature.
 * @param {Binding} binding
 * @returns {Target}
 */
export function target(binding) {
    const t = process.env.DS_JS_TARGET;
    if (t === "native" || t === "wasm") return t;
    if (t !== undefined) throw new TypeError(`DS_JS_TARGET is ${JSON.stringify(t)}: native or wasm`);
    const got = binding.installed();
    return got.native === null && got.wasm !== null ? "wasm" : "native";
}

/**
 * Compile a `.ds` file with the target's compiler, `dir` and then `search`
 * on its import path: `dsc` natively, ds_dsc under wasm.
 * @param {BoundDs} ds
 * @param {string} path
 * @param {string[]} search  -L directories, after the file's own
 * @returns {Promise<Uint8Array>}
 */
export async function compileFile(ds, path, search) {
    return ds.compileFile(path, { searchPath: [dirname(path), ...search] });
}

/**
 * The compiler port over files (DSDB.md §3): what a compile's `files` holds is
 * written under one scratch directory for that compile, in place of the
 * `searchPath` entry it names, since this compiler reads the disk.
 * @param {BoundDs} ds  the target's compiler
 * @returns {Compile}
 */
export function compilerPort(ds) {
    return async (text, opts) => {
        const { files, searchPath = [], ...rest } = opts;
        if (files === undefined) return ds.compile(text, opts);
        const base = process.env.DS_MERCURY_SCRATCH || tmpdir();
        mkdirSync(base, { recursive: true });
        const dir = mkdtempSync(join(base, "dsdb-libraries-"));
        try {
            for (const [path, source] of Object.entries(files)) {
                const root = searchPath.find((p) => path.startsWith(`${p}/`));
                if (root === undefined) throw new TypeError(`${path} is under no searchPath entry`);
                const file = join(dir, path.slice(root.length + 1));
                mkdirSync(dirname(file), { recursive: true });
                writeFileSync(file, source);
            }
            return await ds.compile(text, { ...rest, searchPath: [dir] });
        } finally {
            rmSync(dir, { recursive: true, force: true });
        }
    };
}

/**
 * The compiler port for rule changes (DSDB.md §3): a changed program's staged
 * `{ name: text }` files written into one scratch directory for the session,
 * and compiled with it and -L on the search path. The directory goes when the
 * session ends. A refusal names a staged file by its own name: the user never
 * made the directory, and `save code` is how to see the program.
 * @param {BoundDs} ds  the target's compiler
 * @param {string[]} search  -L directories
 * @returns {{ compileFiles: (files: Map<string, string>, entry: string) => Promise<Uint8Array>, close: () => void }}
 */
export function stagingPort(ds, search) {
    /** @type {string | null} */
    let dir = null;
    return {
        async compileFiles(files, entry) {
            if (dir === null) {
                const base = process.env.DS_MERCURY_SCRATCH || tmpdir();
                mkdirSync(base, { recursive: true });
                dir = mkdtempSync(join(base, "dstrace-rules-"));
            }
            for (const [name, text] of files) writeFileSync(join(dir, name), text);
            try {
                return await ds.compileFile(join(dir, entry), { searchPath: [dir, ...search] });
            } catch (err) {
                // Its diagnostics cite the staged file by path.
                if (err instanceof Error && err.name === "CompileRefused")
                    err.message = err.message.replaceAll(join(dir, sep), "");
                throw err;
            }
        },
        close() {
            if (dir !== null) rmSync(dir, { recursive: true, force: true });
        },
    };
}

/**
 * A session over files. Every file is read before `@ds-lang/ds` is loaded, so a
 * missing one is reported as that (throws Unreadable).
 *
 * @param {object} o
 * @param {{ dsc: string[], ds: string[], other: string[] }} o.kinds  the files by kind (main.js `classify`)
 * @param {string[]} o.search  -L directories
 * @param {boolean} [o.follow]  -f: take in records appended to the trace
 * @param {number} o.width  the terminal's columns
 * @param {Fence | null} [o.fence]  where a save may write (the MCP server's, `ds serve`'s)
 * @param {boolean} [o.facts]  the caller feeds fact files, so the session does not open empty
 * @param {boolean} [o.banner]  a live session opens with the shell's line saying how to begin
 *   (api/open.js `openSession`)
 * @param {Say} say
 * @param {string} prog  the name run as, for messages
 * @returns {Promise<number | Opened>} an exit status when the files are refused (§2), else the
 *   session and how to let it go
 */
export async function openSession({ kinds, search, follow = false, width, fence = null, facts = false, banner = true },
                                  say, prog) {
    for (const path of kinds.ds) read(path);    // an absent file is that, not a compile that failed
    const blobs = [...kinds.dsc, ...kinds.other].map((path) => ({ path, data: new Uint8Array(read(path)) }));
    const binding = await loadBinding();
    const ds = await openTarget(binding);
    /** @type {Uint8Array | null} */
    let dsc = null;
    /** @type {{ name: string, data: Uint8Array, front: number } | null} */
    let trace = null;
    let src = kinds.ds.length ? kinds.ds[kinds.ds.length - 1] : null;
    for (const b of blobs) {
        const what = sniff(ds, b.data);
        if (what.kind === null) {
            say.err(`${prog}: ${b.path}: not a trace, a .dsc or a .ds (${what.why})`);
            return 4;
        }
        if (what.kind === "source") src = b.path;
        else if (what.kind === "dsc") dsc = b.data;
        else {
            trace = { name: b.path, data: b.data, front: what.front };
            if (what.front && dsc === null) dsc = b.data.subarray(0, what.front);
        }
    }
    // A .ds is compiled whenever it is given: it is the program when there is
    // no other, and otherwise checked against the one there is (§2).
    /** @type {Uint8Array | null} */
    let compiled = null;
    if (src !== null) {
        try {
            compiled = await compileFile(ds, src, search);
        } catch (err) {
            say.err(`${prog}: ${src} does not compile:\n${err instanceof Error ? err.message : String(err)}`);
            if (dsc === null) return 2;
        }
    }
    const compile = compilerPort(ds);
    // §4.16: no program at all is an empty one, to build up by definitions.
    const empty = dsc === null && src === null && trace === null;
    if (empty) {
        const got = await emptyProgram(compile);
        if (got.dsc === undefined) {
            say.err(`${prog}: an empty program does not compile:\n${got.why}`);
            return 2;
        }
        compiled = got.dsc;
    }
    const staging = stagingPort(ds, search);
    const ports = { compile, compileFiles: staging.compileFiles,
                    /**
                     * @param {string} path
                     * @param {Uint8Array} bytes
                     */
                    write: (path, bytes) => writeFileSync(fence === null ? path : fence.writable(path), bytes) };
    const name = trace?.name;
    const reread = follow && name !== undefined ? () => new Uint8Array(read(name)) : null;
    const opened = openBytes({ ds, dsc, trace, compiled, src, empty, ports, reread, width, facts, banner }, say, prog);
    if (typeof opened === "number") {
        staging.close();
        return opened;
    }
    return { session: opened.session, close: () => { opened.close(); staging.close(); } };
}

/**
 * A load's path argument, or null when it is not given. Throws OpError for
 * one that is not text.
 * @param {unknown} p
 * @param {string} what  the argument, for the refusal
 * @returns {string | null}
 */
function pathArg(p, what) {
    if (p === undefined || p === null || p === "") return null;
    if (typeof p !== "string") throw new OpError(`\`${what}\` is a path`);
    return p;
}

/**
 * The API's `load` natively (DSDB_WEB.md §3): the program and trace as paths,
 * for the MCP server and `ds serve`, read and saved to within `fence`
 * (DSDB_MCP.md §7): the program, the trace and the load's own search
 * directories are refused outside it.
 * @param {string[]} search  -L directories for every load
 * @param {Fence} fence
 * @returns {Load}
 */
export function nativeLoad(search, fence) {
    return {
        description: "Load a DS program and, optionally, a trace to replay; with no trace, a live session starts. "
            + "Replaces whatever was loaded. The program is a `.dsc` or its `.ds`; a trace that embeds its program "
            + "needs no other. With neither, a live session on an empty program starts, to build up.",
        inputSchema: { type: "object", properties: {
            program: { type: "string", description: "a .dsc or .ds file" },
            trace: { type: "string", description: "a trace to replay" },
            search: { type: "array", items: { type: "string" }, description: "directories for a .ds's imports (-L)" },
        } },
        async open({ program, trace, search: dirs = [] }, say) {
            const prog = pathArg(program, "program"), tr = pathArg(trace, "trace");
            if (!Array.isArray(dirs) || !dirs.every((d) => typeof d === "string"))
                throw new OpError("`search` is a list of directories");
            /** @type {string[]} */
            const more = dirs;
            // Neither: a live session on an empty program, to build up (§4.16).
            /** @type {{ dsc: string[], ds: string[], other: string[] }} */
            const kinds = { dsc: [], ds: [], other: [] };
            if (prog !== null) (prog.endsWith(".ds") ? kinds.ds : kinds.other).push(prog);
            if (tr !== null) kinds.other.push(tr);
            try {
                for (const p of [prog, tr, ...more]) if (p) fence.readable(p);
                return await openSession({ kinds, search: [...more, ...search], width: 100, fence }, say, "ds");
            } catch (err) {
                if (err instanceof Unreadable || err instanceof Fenced || err instanceof NoBinding)
                    throw new OpError(err.message);
                throw err;
            }
        },
    };
}
