// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Opening a session from bytes (DSTRACE_INTERACTIVE §2, DSDB_WEB.md §3): the
// program as a `.dsc`, a trace's embedded one, or one compiled from source; a
// trace to replay, or none for a live session. No I/O and nothing from Node:
// what a platform supplies arrives as bytes and ports. The CLI reads files and
// calls this (lib/cli/open.js); a page hands it what the user picked.

import { bindingCheck, programTuple, streamHeader, streamTuple } from "../core/binding.js";
import { EngineTimeline } from "../core/engine-timeline.js";
import { read as readProgram, ruleNames } from "../core/program.js";
import { Queries, compileMessage } from "../core/query.js";
import { Session } from "../core/session.js";
import { Timeline } from "../core/timeline.js";
import { Decoder } from "../core/trace.js";

/** @import { Program } from "../core/program.js" */
/** @import { Compile, Ds } from "../core/types.js" */
/** @import { Opened, Say } from "./ops.js" */

/**
 * What a session is given to reach outside itself (DSDB.md §3): the compiler
 * for source, the compiler for a staged, changed program, and where a save
 * writes. Each is null where the platform has none.
 * @typedef {{ compile: Compile | null,
 *     compileFiles: ((files: Map<string, string>, entry: string) => Promise<Uint8Array>) | null,
 *     write: ((path: string, bytes: Uint8Array) => void) | null }} Ports
 */

/**
 * What some bytes are (`sniff`): a trace, with where its StreamHeader begins;
 * a `.dsc`; DS source; or none of them, and why not.
 * @typedef {{ kind: "trace", front: number } | { kind: "dsc" } | { kind: "source" }
 *   | { kind: null, why: string }} Sniffed
 */

/** The program a session with none starts from (§4.16). */
export const EMPTY_PROGRAM = "use default\n";

/**
 * The `dsc_hash` an engine loading `dsc` states in its session header, which
 * a trace recorded with it carries ([RFCS.4.3]); null when there is none.
 * @param {Ds} ds
 * @param {Uint8Array} dsc
 * @returns {Uint8Array | null}
 */
export function dscHash(ds, dsc) {
    const e = new ds.Engine();
    try {
        e.loadDsc(dsc);
        return e.sessionHeader.dscHash ?? null;
    } finally {
        e.close();
    }
}

/**
 * What some bytes are, by what they hold (§2): a trace has a StreamHeader,
 * and anything before it is an embedded program ([RFCS.13]); a `.dsc` is
 * atoms with none; source is text. `kind` is null when they are none of
 * them.
 * @param {Ds} ds
 * @param {Uint8Array} data
 * @returns {Sniffed}
 */
export function sniff(ds, data) {
    const r = ds.readAtoms(data, { incremental: true });
    const header = r.atoms.find((a) => a.message === "StreamHeader");
    if (header) return { kind: "trace", front: header.offset };
    // The incremental reader finds no error in text, only an atom not yet
    // whole: a `.dsc` is one whose atoms read.
    if (r.error === null && r.atoms.length) return { kind: "dsc" };
    if (!data.includes(0)) {
        try {
            new TextDecoder("utf-8", { fatal: true }).decode(data);
            return { kind: "source" };
        } catch { /* not text either */ }
    }
    // Binary, and too short for one whole atom: the reader stopped with no
    // error, waiting for the rest.
    return { kind: null, why: r.error === null ? "no whole atom" : r.error.detail };
}

/**
 * §2's order of preference for the program's source: the `.dsc`'s embedded
 * source, then a `.ds` checked against it, then none. Says which, once, at
 * start. The port of shell.py's pick_source.
 * @param {Ds} ds
 * @param {Program} program  the `.dsc`'s
 * @param {Uint8Array} dsc
 * @param {Uint8Array | null} compiled  the `.ds` given, compiled; null when none was
 * @param {string | null} src  that `.ds`'s name
 * @param {boolean} fromSource  the `.ds` is all there is: `dsc` is `compiled`
 * @param {(line: string) => void} say
 * @returns {Array<[string, string]>} `[file, text]` pairs
 */
export function pickSource(ds, program, dsc, compiled, src, fromSource, say) {
    if (program.sources.length) {
        if (src !== null && !fromSource) say(`source: embedded in the .dsc; ${src} ignored`);
        return program.sources;
    }
    if (compiled === null) {
        if (src === null) say("source: none (a stripped .dsc); give its .ds and -L to enable what needs it");
        return [];
    }
    const theirs = readProgram(ds, compiled);
    let diff = program.sameShape(theirs);
    if (diff === null) {
        const want = ruleNames(ds, dsc), got = ruleNames(ds, compiled);
        const only = [...want].filter((r) => !got.has(r)).concat([...got].filter((r) => !want.has(r))).sort();
        if (only.length) diff = `rules differ: ${only.slice(0, 5).join(", ")}`;
    }
    if (diff !== null) {
        say(`source: ${src} refused, it is not the program in the .dsc (${diff})`);
        return [];
    }
    say(`source: ${src}, checked against the .dsc`);
    return theirs.sources;
}

/**
 * A session over bytes already in hand.
 *
 * @param {object} o
 * @param {Ds} o.ds  a `@ds-lang/ds` API from `open()`
 * @param {Uint8Array | null} o.dsc  the program, or null
 * @param {{ name: string, data: Uint8Array, front: number } | null} o.trace  a trace (sniffed), or null
 * @param {Uint8Array | null} o.compiled  the program compiled from source, or null
 * @param {string | null} o.src  that source's name, for messages
 * @param {boolean} o.empty  no program was given at all: `compiled` is the empty one (§4.16)
 * @param {Ports} o.ports
 * @param {(() => Uint8Array) | null} [o.reread]  -f: the trace's bytes as they now are
 * @param {number} o.width  the terminal's columns
 * @param {boolean} [o.facts]  the caller feeds fact files, so a live session does not open empty
 * @param {boolean} [o.banner]  a live session opens with the shell's line saying how to begin; false for
 *   a front end with no shell, whose user cannot type the commands it names (`ds dap`)
 * @param {Say} say
 * @param {string} prog  the name run as, for messages
 * @returns {number | Opened} an exit status when what was given is refused
 *   (§2), else the session and how to let it go
 */
export function openSession({ ds, dsc, trace, compiled, src, empty, ports, reread = null, width, facts = false,
                              banner = true }, say, prog) {
    const fromSource = dsc === null && compiled !== null;
    if (fromSource) dsc = compiled;
    if (dsc === null) {
        say.err(`${prog}: -i needs the program: a .dsc, a self-contained trace, or its .ds`);
        return 2;
    }
    const program = readProgram(ds, dsc);
    const source = empty ? program.sources : pickSource(ds, program, dsc, compiled, src, fromSource, say.out);
    const all = { ds, ...ports, source };

    if (trace === null) {
        // No trace: a live session (§3.5), %0 the engine's own recording.
        const live = EngineTimeline.live(ds, dsc);
        const queries = new Queries(ds, program, live.tl, ports.compile);
        if (banner && !facts) say.out(empty ?"live session on an empty program: type a DS definition, a schema or a rule; "
                                    + "two blank lines end each"
                                  : "live session: an empty engine at 0.0s; `from here emit` to begin");
        const session = new Session(live.tl, { width, queries, live, ...all });
        return { session, close: () => session.close() };
    }

    const dec = new Decoder(ds, { dsc });
    dec.pos = trace.front;
    let data = trace.data;
    const records = dec.feed(data);
    // §2: a trace and a program that do not belong together is exit 3, by
    // [RFCS.4.5]'s check, whether the program came embedded or was given.
    const bound = bindingCheck(streamTuple(streamHeader(ds, data, trace.front)), programTuple(ds, dsc, dscHash(ds, dsc)));
    if (bound.unbound !== null) {
        const { code, detail } = bound.unbound;
        say.err(`${prog}: the trace was not recorded with this program (${code})\n  ${detail}`);
        if (fromSource && code === "DS_ERR_BND_DSC_MISMATCH")
            say.err(`${prog}: the .ds does not compile to the program this trace was recorded with; give the .dsc`);
        say.unbound?.(bound.unbound);
        dec.close();
        return 3;
    }
    if (!bound.checked) say.err(`${prog}: the trace's program cannot be checked (one side carries no dsc_hash)`);
    if (dec.error !== null) {
        const [at, why] = dec.error;
        say.out(`${prog}: malformed record at byte ${at} (${why}); the ${records.length} records before it `
                + "are shown, nothing after");
    }
    const refresh = reread === null ? null : () => {
        data = reread();
        return dec.feed(data);
    };
    const tl = new Timeline(records, dec.header, program.services);
    const queries = new Queries(ds, program, tl, ports.compile);
    const session = new Session(tl, { width, refresh, queries, ...all, stream: () => data });
    return { session, close: () => { session.close(); dec.close(); } };
}

/**
 * An empty program's bytes, compiled by `compile`, or why not. Async: the
 * wasm compiler, ds_dsc, is.
 * @param {Compile} compile
 * @returns {Promise<{ dsc: Uint8Array, why?: undefined } | { dsc?: undefined, why: string }>}
 */
export async function emptyProgram(compile) {
    try {
        return { dsc: await compile(EMPTY_PROGRAM, { file: "program.ds" }) };
    } catch (err) {
        return { why: compileMessage(err, 0) };
    }
}
