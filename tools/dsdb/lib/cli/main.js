#!/usr/bin/env node
// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// `ds` — the command line of dsdb, the DS Debugger (DSDB.md §10). Interactive
// and verbose by default: -b and -q turn those off.
//
// Files are recognised by what they are named: fact files by their extension
// (.csv, .tsv, .jsonl, .json), a program as a `.dsc` or its `.ds`, anything
// else as a trace.
//
//   ds [PROG.dsc | PROG.ds -L DIR…] [TRACE | FACTS…] [-f]         the shell (§11)
//   ds -b (PROG.dsc | PROG.ds -L DIR…) FACTS… [--out DIR --format csv|tsv|jsonl] [-q]  batch (§9)
//      [--calls SOCK | --listen SOCK] [--pumps N] [--call-timeout SECONDS]   calls (§9.1)
//   ds -b [PROG.dsc | PROG.ds -L DIR…] TRACE [-f] [--from SEQ]    the listing
//   ds test [-L DIR]… [--program PROG.ds] FILE…                   the .dstest runner
//   ds --version                                                  this, the libds and the dsc it runs on
//
// Exit status: 0 done, help or the version asked for; 1 the input was refused
// (a fact file, the engine, the compiler), a trace was malformed, or a test
// case failed; 2 a usage error, or a .ds that does not compile where the shell
// has no other program; 3 a trace and a program it was not recorded with; 4 a
// file that cannot be read, a calls socket that cannot be opened, or
// @ds-lang/ds (or the target asked for) not installed.

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, writeFileSync } from "node:fs";
import { basename, dirname, extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { dscHash, sniff } from "../api/open.js";
import { runBatch } from "../core/batch.js";
import { bindingCheck, programTuple, streamHeader, streamTuple } from "../core/binding.js";
import { DstestError, decodeCases, runCase, sourceModules } from "../core/dstest.js";
import { FactFileError, factFileName, loadFactFiles, rowSlots } from "../core/facts.js";
import { writeDoc, writeRows } from "../core/facts-out.js";
import { MAX_DURATION_NS, durationNs } from "../core/grammar.js";
import { Decoder } from "../core/trace.js";
import { callLine, eventLine, logLine, replyLine, waitingLine } from "../text/batch.js";
import { caseLines, summaryLine } from "../text/dstest.js";
import { recordLines } from "../text/listing.js";
import { Fence, Fenced } from "./fence.js";
import { NoBinding, Unreadable, compileFile, loadBinding, openSession, openTarget, read, target } from "./open.js";
import { runShell, stdTerminal } from "./shell.js";
import { LineSocket, SocketError } from "./socket.js";

/** @import { Say } from "../api/ops.js" */
/** @import { Terminal } from "./shell.js" */

/**
 * What the command reaches outside itself, given so a test can run it in
 * process: its output streams, and in place of the terminal's own, its
 * width, a terminal, the MCP server's input lines and the language server's
 * input bytes.
 * @typedef {{ stdout: (s: string) => void, stderr: (s: string) => void, columns?: number,
 *     terminal?: Terminal & { close?: () => void }, lines?: AsyncIterable<string>,
 *     input?: AsyncIterable<Uint8Array> }} Io
 */

/**
 * The command line, read (`parseArgs`).
 * @typedef {{ interactive: boolean, verbose: boolean, follow: boolean, search: string[], out: string | null,
 *     format: "csv" | "tsv" | "jsonl" | null, from: string | null, files: string[], calls: string | null,
 *     listen: string | null, pumps: number, callTimeoutMs: number, until: bigint | null, given: string[] }} Options
 */

/** @typedef {{ facts: string[], dsc: string[], ds: string[], other: string[] }} Kinds  the files by kind */

const USAGE = `usage: ds                  a live session on an empty program, to build up
       ds [PROG.dsc | PROG.ds -L DIR...] [TRACE | FACTS...] [-f]
                                the shell, on the program and what it is given
       ds -b (PROG.dsc | PROG.ds -L DIR...) FACTS... [--out DIR --format csv|tsv|jsonl]
             [--calls SOCK | --listen SOCK] [--pumps N] [--call-timeout SECONDS] [--until D]
                                run the facts through the program, with no shell
       ds -b [PROG.dsc | PROG.ds -L DIR...] TRACE [-f] [--from SEQ]
                                the trace, its facts typed by the program it was recorded with;
                                SEQ is in hex, as the listing prints it
       ds mcp [-L DIR]... [--root DIR]... [--out DIR] [--calls SOCK [--call-timeout SECONDS]]
                                an MCP server on stdin and stdout
       ds lsp [-L DIR]...       a language server on stdin and stdout, for an editor
       ds dap [-L DIR]...       a debug adapter on stdin and stdout, for an editor
       ds test [-L DIR]... [--program PROG.ds] FILE...
                                run the test cases in each .ds, .dstest or .dsc, on libds
       ds --version             this, and the libds and dsc it runs on
       ds serve [--host 127.0.0.1] [--port 7373] [--origin URL]... [--token T] [-L DIR]...
                [--root DIR]... [--out DIR] [--shell-lines]
                                a WebSocket a web page drives dsdb's API over;
                                --shell-lines lets it send shell lines as text too
mcp and serve read what a client names under each --root and --out, and write under --out;
each is the working directory when not given.
ds is dsdb, the DS Debugger. It is interactive and verbose unless -b, -q: -i and -v say so
outright. -b runs with no shell, and reads nothing from stdin. -q, with -b, shows no stream
events on stderr. A script runs ds -b -q.
FACTS are <Schema>.csv, <Schema>.tsv, <Schema>.jsonl (one per schema) or a .json of every schema;
the output is what the rules publish, every schema keyed.
--calls sends each call to a Unix socket a responder listens on; --listen makes the socket and
waits for the responder. Replies are delivered between pump cycles: --pumps N allows N (1).
--until D, a duration such as 10_s from the start, then moves the clock there and pumps once: the
run otherwise ends at the last row, before any timer or timeout due after it.`;

/**
 * Each subcommand's own usage: what `-h` after it prints, and what a usage
 * error in it is shown with. The lines are USAGE's for it, and what applies
 * to it alone.
 * @type {Readonly<Record<string, string>>}
 */
const SUB_USAGE = Object.freeze({
    test: `usage: ds test [-L DIR]... [--program PROG.ds] FILE...
Run the test cases in each .ds, .dstest or .dsc, on libds. A .dsc, or a .ds that
is a program, runs every case it carries; a .ds is compiled with its own
directory, then each -L DIR, on the import path. A foo.dstest is the tests of
module foo.ds beside it. A library's tests, and a companion's, run under a
program that imports the module: the module itself if it is one, else
--program, else the one program in its directory that imports it. Then only
that module's cases run.
Exit status: 0 when every case of every file passed; 1 when a case failed, or a
file did not compile, had no program to run under, or held no test case.`,
    lsp: `usage: ds lsp [-L DIR]...
A language server on stdin and stdout, for an editor. -L DIR adds a library
directory to every compile, after the document's own and any the editor gives.`,
    dap: `usage: ds dap [-L DIR]...
A debug adapter on stdin and stdout, for an editor. -L DIR adds a library
directory to every compile, after the launch's own \`libs\`.`,
    mcp: `usage: ds mcp [-L DIR]... [--root DIR]... [--out DIR] [--calls SOCK [--call-timeout SECONDS]]
An MCP server on stdin and stdout. It reads what a client names under each
--root and --out, and writes under --out; each is the working directory when
not given. --calls sends each call to a Unix socket a responder listens on.`,
    serve: `usage: ds serve [--host 127.0.0.1] [--port 7373] [--origin URL]... [--token T] [-L DIR]...
                [--root DIR]... [--out DIR] [--shell-lines]
A WebSocket a web page drives dsdb's API over, on this machine only. It reads
what a page names under each --root and --out, and writes under --out; each is
the working directory when not given. --shell-lines lets it send shell lines as
text too.`,
});

class Usage extends Error {}

/** `-h` or `--help`: the usage, asked for, on stdout and exit 0. */
class Help extends Error {}

/** The subcommands, for a mistyped one. */
const SUBCOMMANDS = ["test", "lsp", "dap", "mcp", "serve"];

/** What each subcommand flag that takes a value takes, for the usage error
    when it is given none. */
const NEEDS = Object.freeze(/** @type {Record<string, string>} */ ({
    "-L": "a directory", "--search-path": "a directory", "--root": "a directory", "--out": "a directory",
    "--calls": "a socket", "--call-timeout": "a number of seconds", "--host": "an address", "--port": "a port",
    "--origin": "a URL", "--token": "a token",
}));

/**
 * Refuse a subcommand flag given last, with no value, saying what it takes:
 * otherwise the loop reads it as an unknown flag.
 * @param {string} sub
 * @param {string[]} argv  after the subcommand
 */
function needValues(sub, argv) {
    const last = argv[argv.length - 1];
    if (last !== undefined && Object.hasOwn(NEEDS, last)) throw new Usage(`${sub}: ${last} needs ${NEEDS[last]}`);
}

/**
 * The subcommand `word` is a slip for: one edit or one swap away, or null.
 * @param {string} word
 */
function nearCommand(word) {
    /** @param {string} a @param {string} b */
    const near = (a, b) => {
        if (a === b) return false;
        if (a.length === b.length) {
            const diff = [...a].map((c, i) => (c === b[i] ? -1 : i)).filter((i) => i >= 0);
            return diff.length === 1 || (diff.length === 2 && diff[1] === diff[0] + 1
                                         && a[diff[0]] === b[diff[1]] && a[diff[1]] === b[diff[0]]);
        }
        const [s, l] = a.length < b.length ? [a, b] : [b, a];
        if (l.length - s.length !== 1) return false;
        for (let i = 0; i < l.length; i++) if (l.slice(0, i) + l.slice(i + 1) === s) return true;
        return false;
    };
    return SUBCOMMANDS.find((c) => near(word, c)) ?? null;
}

/** The options only a run with no shell reads: refused with the shell, which would ignore them. */
const BATCH_ONLY = ["--out", "--format", "--from", "--calls", "--listen", "--pumps", "--call-timeout", "--until"];

/** What a run on fact files does not read, and what the listing does not. */
const NOT_BATCH = ["-f", "--follow", "--from"];
const NOT_LISTING = ["--out", "--format", "--pumps", "--call-timeout", "--until"];

/**
 * Refuse an option the run would otherwise take and ignore. A run that ignored
 * `--out` would write nothing where its caller then looks ([RCLI.3.1] says the
 * same of `dsc`).
 * @param {Options} o
 * @param {string[]} unread
 * @param {string} why  what it goes with, and what does not read it
 */
function refuseUnread(o, unread, why) {
    const flag = o.given.find((a) => unread.includes(a));
    if (flag !== undefined) throw new Usage(`${flag} goes with ${why}`);
}

/**
 * argv (without node and the script) to options.
 * @param {string[]} argv
 * @returns {Options}
 */
export function parseArgs(argv) {
    /** @type {Options} */
    const o = { interactive: true, verbose: true, follow: false, search: [], out: null, format: null, from: null,
                files: [], calls: null, listen: null, pumps: 1, callTimeoutMs: 5000, until: null, given: [] };
    /** @type {string | null} */
    let format = null;
    /** @type {string | null} */
    let batchOnly = null;
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (BATCH_ONLY.includes(a)) batchOnly ??= a;
        if (a.startsWith("-") && a !== "-") o.given.push(a);
        const val = () => {
            if (i + 1 >= argv.length) throw new Usage(`${a} needs a value`);
            return argv[++i];
        };
        if (a === "-i" || a === "--interactive") o.interactive = true;
        else if (a === "-b" || a === "--batch") o.interactive = false;
        else if (a === "-f" || a === "--follow") o.follow = true;
        else if (a === "-v" || a === "--verbose") o.verbose = true;
        else if (a === "-q" || a === "--quiet") o.verbose = false;
        else if (a === "-L" || a === "--search-path") o.search.push(val());
        else if (a === "--out") o.out = val();
        else if (a === "--format") format = val();
        else if (a === "--from") o.from = val();
        else if (a === "--calls") o.calls = val();
        else if (a === "--listen") o.listen = val();
        else if (a === "--pumps") {
            const v = val();
            if (!/^[1-9]\d*$/.test(v)) throw new Usage(`--pumps ${v}: a whole number, 1 or more`);
            o.pumps = Number(v);
        } else if (a === "--call-timeout") {
            const v = val();
            const s = Number(v);
            if (v.trim() === "" || !Number.isFinite(s) || s < 0) throw new Usage(`--call-timeout ${v}: seconds, 0 or more`);
            o.callTimeoutMs = s * 1000;
        } else if (a === "--until") {
            const v = val();
            const d = durationNs(v) ?? (/^\d+$/.test(v) ? BigInt(v) : null);
            if (d === null || d > MAX_DURATION_NS)
                throw new Usage(`--until ${v}: a Duration from the start, such as 10_s, or whole nanoseconds`);
            o.until = d;
        } else if (a === "-h" || a === "--help") throw new Help();
        else if (a.startsWith("-") && a !== "-") throw new Usage(`no option ${a}`);
        else o.files.push(a);
    }
    // §4.16: the shell with no files is a live session on an empty program.
    if (!o.files.length && !o.interactive) throw new Usage("no files");
    if ((o.out === null) !== (format === null))
        throw new Usage("--out and --format go together: a directory and csv, tsv or jsonl");
    if (format !== null && format !== "csv" && format !== "tsv" && format !== "jsonl")
        throw new Usage(`--format ${format}: csv, tsv or jsonl`);
    o.format = format;
    if (o.calls !== null && o.listen !== null)
        throw new Usage("--calls or --listen: ds connects to the socket, or makes it, not both");
    if (o.pumps > 1 && o.calls === null && o.listen === null)
        throw new Usage("--pumps: later cycles deliver replies, so they need --calls or --listen");
    if (o.interactive && batchOnly !== null)
        throw new Usage(`${batchOnly} goes with -b: the shell does not read it`);
    return o;
}

/**
 * The files by kind.
 * @param {string[]} files
 * @returns {Kinds}
 */
export function classify(files) {
    /** @type {Kinds} */
    const out = { facts: [], dsc: [], ds: [], other: [] };
    for (const f of files) {
        if (factFileName(f) !== null) out.facts.push(f);
        else if (f.endsWith(".dsc")) out.dsc.push(f);
        else if (f.endsWith(".ds")) out.ds.push(f);
        else out.other.push(f);
    }
    return out;
}

/**
 * Batch mode (§9). Every file is read before `@ds-lang/ds` is loaded, so a
 * missing one is reported as that.
 * @param {Options} o
 * @param {Kinds} kinds
 * @param {Io} io
 * @returns {Promise<number>} the exit status
 */
async function batch(o, kinds, io) {
    if (kinds.dsc.length + kinds.ds.length !== 1)
        throw new Usage("give the program once: one .dsc, or one .ds");
    /** @type {Uint8Array | null} */
    let dsc = kinds.dsc.length ? new Uint8Array(read(kinds.dsc[0])) : null;
    if (kinds.ds.length) read(kinds.ds[0]);
    const files = kinds.facts.map((path) => ({ path, text: read(path, "utf8") }));
    const ds = await openTarget(await loadBinding());
    if (dsc === null) dsc = await compileFile(ds, kinds.ds[0], o.search);
    /** @param {string} line */
    const err = (line) => io.stderr(line + "\n");
    // The socket last: every file is read and the program compiled before
    // anything waits on a peer (§9.1).
    /** @type {LineSocket | null} */
    let calls = null;
    if (o.calls !== null) calls = await LineSocket.connect(o.calls);
    else if (o.listen !== null)
        calls = await LineSocket.listen(o.listen, () => err(`ds: listening on ${o.listen} for the calls responder`));
    let run;
    try {
        run = await runBatch({
            ds, dsc, files, calls: calls ?? undefined, pumps: o.pumps, callTimeoutMs: o.callTimeoutMs, until: o.until,
            onLog: (x) => err(logLine(x)),
            onCall: (x) => err(callLine(x)),
            onReply: (x) => err(replyLine(x)),
            onEvent: o.verbose ? (ev, args) => err(eventLine(ev, args)) : undefined,
        });
    } finally {
        await calls?.close();
    }
    const { schemas, published } = run;
    if (calls) for (const c of run.waiting) err(waitingLine(c));
    // The output is what was published (§9). A run whose rules emitted and
    // published nothing writes every schema empty, which reads as nothing
    // having fired: say what did.
    const none = [...published.values()].every((rows) => !rows.length);
    if (none && run.emitted)
        err(`ds: no rule published a fact; ${run.emitted} ${run.emitted === 1 ? "was" : "were"} emitted, and an `
            + "emitted fact stays on this tier: batch output is what the rules `publish`");
    // parseArgs gives `out` and `format` together.
    const out = o.out, format = o.format;
    if (out === null || format === null) {
        io.stdout(writeDoc(schemas, published));
        return 0;
    }
    mkdirSync(out, { recursive: true });
    for (const s of schemas)
        writeFileSync(join(out, `${s.name}.${format}`), writeRows(s, published.get(s.name) ?? [], format));
    return 0;
}

/**
 * The plain listing (tools/dstrace.py without -i): every atom of a trace as
 * text. `--from SEQ` is a prefix cut, not a filter, and SEQ is in hex, as the
 * listing prints it and the shell's positions read it: atoms with no seq (the
 * header, schema announcements) are always shown. `-f` keeps reading as the
 * file grows; a partial atom at the end is not yet a record ([RFCS.19.2]) and
 * is read on the next pass. Nothing here is a clock: the poll only saves a
 * core, and the output is the same at any interval.
 *
 * `program`, a `.dsc` or a `.ds` (compiled with -L), types the facts: a trace
 * libds recorded embeds none, and a body is typed by its program alone. One
 * the trace was not recorded with is refused, exit 3, as
 * the shell refuses it (§2).
 * @param {Options} o
 * @param {string} path  the trace
 * @param {Io} io
 * @param {string | null} [program]  the program's path
 * @returns {Promise<number>} the exit status
 */
async function listing(o, path, io, program = null) {
    /** @type {bigint | null} */
    let from = null;
    if (o.from !== null) {
        if (!/^[0-9a-fA-F]+$/.test(o.from)) throw new Usage(`--from ${o.from}: a seq in hex, as the listing prints it`);
        from = BigInt(`0x${o.from}`);
    }
    let data = new Uint8Array(read(path));
    const source = program !== null && program.endsWith(".ds");
    const given = program === null ? null : new Uint8Array(read(program));
    const binding = await loadBinding();
    const ds = await openTarget(binding);
    // A self-contained trace's embedded program types its facts, and a
    // program given types them in its place; with neither, they are listed
    // untyped (trace.js `Decoder`).
    const what = sniff(ds, data);
    /** @type {Uint8Array | null} */
    let dsc = what.kind === "trace" && what.front > 0 ? data.slice(0, what.front) : null;
    if (program !== null) {
        /** @type {Uint8Array} */
        const mineDsc = source ? await compileFile(ds, program, o.search) : /** @type {Uint8Array} */ (given);
        dsc = mineDsc;
        // Checked before a body is read: one typed by another program's
        // schema is not this trace's fact. [RFCS.4.5]'s check, as the shell
        // and the debug adapter make it (api/open.js).
        const bound = bindingCheck(streamTuple(streamHeader(ds, data, what.kind === "trace" ? what.front : 0)),
                                   programTuple(ds, mineDsc, dscHash(ds, mineDsc)));
        if (bound.unbound !== null) {
            io.stderr(`ds: the trace was not recorded with this program (${bound.unbound.code})\n  ${bound.unbound.detail}\n`);
            return 3;
        }
        if (!bound.checked) io.stderr(`ds: the trace's program cannot be checked (one side carries no dsc_hash)\n`);
    }
    const dec = new Decoder(ds, { dsc });
    const emit = () => {
        for (const rec of dec.feed(data)) {
            const [seq, lines] = recordLines(rec);
            // An atom with no seq is always shown: suppressing the header or
            // an announcement would leave later facts untypeable for no gain.
            if (from === null || seq === null || seq >= from) io.stdout(lines.map((l) => l + "\n").join(""));
        }
        if (dec.error !== null) {
            // Bytes no append can rescue: distinct from a short tail, which
            // the reader ends on quietly.
            io.stderr(`ds: malformed at offset ${dec.error[0]}: ${dec.error[1]}\n`);
            return false;
        }
        return true;
    };
    try {
        if (!emit()) return 1;
        if (!o.follow) {
            // Not an error: a recording still being written ends this way, and
            // a crash's recovers to here ([RFCS.19.2], [RFCS.19.8]). But a run
            // that looks complete and is not must say so.
            if (dec.pos < data.length)
                io.stderr(`ds: ${path}: the last ${data.length - dec.pos} bytes, from offset ${dec.pos}, are a partial atom; `
                          + "listed to the last complete one\n");
            return 0;
        }
        for (;;) {
            await new Promise((r) => setTimeout(r, 200));
            const grown = new Uint8Array(read(path));
            if (grown.length <= dec.pos) continue;
            data = grown;
            if (!emit()) return 1;
        }
    } finally {
        dec.close();
    }
}

/** The screen's width, as Python's shutil.get_terminal_size asks: COLUMNS,
    then the terminal, then 100. */
function columns() {
    const env = Number(process.env.COLUMNS);
    if (Number.isInteger(env) && env > 0) return env;
    return process.stdout.isTTY && process.stdout.columns ? process.stdout.columns : 100;
}

/**
 * The shell (DSTRACE_INTERACTIVE §2, §4) over a trace, or live. The program
 * comes from a `.dsc`, the trace's own embedded one, or a `.ds` compiled with
 * -L; the trace must have been recorded with it (open.js).
 *
 * With fact files the session is live and starts from them (DSDB.md §8): each
 * row asserted at its `@at`, merged by time, a pump after each, as batch mode
 * feeds them. Each row is a step of its own, so every one is a settled point
 * to go back to, and the shell opens at the end.
 * @param {Options} o
 * @param {Kinds} kinds
 * @param {Io} io
 * @returns {Promise<number>} the exit status
 */
async function shell(o, kinds, io) {
    if (kinds.facts.length && kinds.other.length)
        throw new Usage(`fact files start a live session, and ${kinds.other[0]} is a trace: give one or the other`);
    const files = kinds.facts.map((path) => ({ path, text: read(path, "utf8") }));
    /** @type {Say} */
    const say = { out: (line) => io.stdout(line + "\n"), err: (line) => io.stderr(line + "\n") };
    const opened = await openSession({ kinds, search: o.search, follow: o.follow, facts: files.length > 0, width: io.columns ?? columns() },
                                     say, "ds");
    if (typeof opened === "number") return opened;
    let term = null;
    try {
        if (files.length) {
            const s = opened.session.state, run = s.liveRun;
            if (run === null) throw new Usage("fact files go with a program to run them on");
            const rows = loadFactFiles(files, run.eng);
            const start = run.clock();
            for (const row of rows) {
                // The clock moves with no pump of its own, as batch mode's
                // `feed` moves it: what falls due meanwhile fires in the
                // row's pump, so the two runs are one run.
                const want = start + row.at, now = run.clock();
                try {
                    if (want > now) run.eng.clock.advance(want - now);
                    run.assertFact(row.schema, rowSlots(row, want));
                } catch (err) {
                    if (!(err instanceof Error) || err.name !== "DsError") throw err;
                    throw new FactFileError(row.file, row.line, err.message);
                }
            }
            s.k = s.tl.length;
            say.out(`${rows.length} row${rows.length === 1 ? "" : "s"} from ${files.length} fact file`
                    + `${files.length === 1 ? "" : "s"}; point is at the end`);
        }
        // Made only once the session runs: readline holds stdin open.
        term = io.terminal ?? stdTerminal(io);
        return await runShell(opened.session, term);
    } finally {
        term?.close?.();
        opened.close();
    }
}

/**
 * `ds mcp`: the MCP server on stdin and stdout (dsdb/DSDB_MCP.md).
 * Messages are JSON-RPC, one per line; anything else goes to stderr. `io.lines`
 * is the input, for a test; stdin otherwise.
 *
 * On either target, and loaded only here, so
 * nothing else that runs dsdb brings the server with it.
 * @param {string[]} argv  after `mcp`
 * @param {Io} io
 * @returns {Promise<number>} the exit status
 */
async function mcp(argv, io) {
    /** @type {string[]} */
    const search = [], roots = [];
    /** @type {string | null} */
    let sock = null, out = null;
    let callTimeoutMs = 5000;
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i], more = i + 1 < argv.length;
        if ((a === "-L" || a === "--search-path") && more) search.push(argv[++i]);
        else if (a === "--root" && more) roots.push(argv[++i]);
        else if (a === "--out" && more) out = argv[++i];
        else if (a === "--calls" && more) sock = argv[++i];
        else if (a === "--call-timeout" && more) {
            // As batch mode reads it: seconds, 0 or more.
            const v = argv[++i], s = Number(v);
            if (v.trim() === "" || !Number.isFinite(s) || s < 0) throw new Usage(`mcp: --call-timeout ${v}: seconds, 0 or more`);
            callTimeoutMs = Math.round(s * 1000);
        } else throw new Usage(`mcp: no option ${a}`);
    }
    const fence = fenceFor("mcp", roots, out);
    const { runMcp } = await import("../mcp/server.js");
    const { createInterface } = await import("node:readline");
    // §10.8: a live session's calls go to a responder, explicitly.
    const calls = sock === null ? null : await LineSocket.connect(sock);
    // The reader is made after every await, and its iterator with it.
    // readline emits a line as soon as stdin has one, and its iterator holds
    // only what arrives once it exists, so a line emitted before then is
    // lost: the client's `initialize`, written the moment it spawned us.
    const lines = io.lines
        ?? createInterface({ input: process.stdin, crlfDelay: Infinity })[Symbol.asyncIterator]();
    try {
        await runMcp({ lines, write: (s) => io.stdout(s), log: (s) => io.stderr(s + "\n"), search, calls, callTimeoutMs,
                       fence });
    } finally {
        await calls?.close();
    }
    return 0;
}

/**
 * `ds lsp`: the language server on stdin and stdout. `-L DIR` adds a
 * library directory to every compile, after the document's own and any the
 * client gives as `initializationOptions.libs`. `io.input` is the input, for
 * a test; stdin otherwise.
 *
 * On either target, as `mcp` is, and loaded only here.
 * @param {string[]} argv  after `lsp`
 * @param {Io} io
 * @returns {Promise<number>} the exit status: 0 after the client's `shutdown`
 */
async function lsp(argv, io) {
    /** @type {string[]} */
    const libs = [];
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if ((a === "-L" || a === "--search-path") && i + 1 < argv.length) libs.push(argv[++i]);
        else throw new Usage(`lsp: no option ${a}`);
    }
    const { runLsp } = await import("../lsp/server.js");
    const { lspPorts } = await import("../lsp/ports.js");
    const binding = await loadBinding();
    return runLsp({ input: io.input ?? process.stdin, write: (s) => io.stdout(s), log: (s) => io.stderr(s + "\n"),
                    ports: lspPorts(binding, await openTarget(binding)), libs });
}

/**
 * `ds dap`: the debug adapter on stdin and stdout (NDBG.9). `-L DIR`
 * adds a library directory to every compile, after the launch's own `libs`.
 * `io.input` is the input, for a test; stdin otherwise.
 *
 * On either target, as `mcp` and `lsp` are, and loaded only here.
 * @param {string[]} argv  after `dap`
 * @param {Io} io
 * @returns {Promise<number>} the exit status: 0 after the client's `disconnect`
 */
async function dap(argv, io) {
    /** @type {string[]} */
    const libs = [];
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if ((a === "-L" || a === "--search-path") && i + 1 < argv.length) libs.push(argv[++i]);
        else throw new Usage(`dap: no option ${a}`);
    }
    const { runDap } = await import("../dap/server.js");
    return runDap({ input: io.input ?? process.stdin, write: (s) => io.stdout(s), log: (s) => io.stderr(s + "\n"), libs });
}

/**
 * One program `ds test` runs, and what of it: every case, or the cases of the
 * modules named. `given` are the files it was asked for that it serves.
 * @typedef {{ path: string, dsc: Uint8Array, all: boolean, modules: Set<number>, given: string[] }} TestRun
 */

/** The diagnostic code `dsc` refuses a library with when asked to build it ([LDIA.2.10.8]). */
const NOT_A_PROGRAM = /\bDS_VALIDATE_NOT_A_PROGRAM\b/;

/**
 * `ds test`: the test cases in each file run on libds, through `@ds-lang/ds`,
 * with no Python (the interpreter is core/dstest.js). Every file is read
 * before `@ds-lang/ds` is loaded, so a missing one is reported as that.
 *
 * A `.dsc` runs every case it carries, and so does a `.ds` that `dsc` compiles
 * as a program, with its own directory and then each `-L` on the import path.
 * Any other `.ds` is a library, and a `.dstest` is the companion of the module
 * of its name beside it ([LTSL.2.4]): its tests are that module's. A module runs
 * under a program, whose settings its tests take ([LTSL.2.2]): itself when it
 * is one; else `--program`, or the one program in its directory whose artefact
 * carries it. Then only that module's cases run. Each program is compiled once,
 * and each case runs once however many files name it.
 *
 * Each case's verdict goes to stdout; a file that cannot be run, does not
 * compile, or carries no test case goes to stderr, and the files after it
 * still run. 0 when every case passed; 1 when a case failed or a file gave
 * none to run, so a run that tested nothing does not pass.
 * @param {string[]} argv  after `test`
 * @param {Io} io
 * @returns {Promise<number>} the exit status
 */
async function dstest(argv, io) {
    /** @type {string[]} */
    const search = [], files = [];
    /** @type {string | null} */
    let program = null;
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a === "-L" || a === "--search-path") {
            if (i + 1 >= argv.length) throw new Usage(`test: ${a} needs a directory`);
            search.push(argv[++i]);
        } else if (a === "--program") {
            if (i + 1 >= argv.length) throw new Usage("test: --program needs a .ds");
            program = argv[++i];
        } else if (a === "-h" || a === "--help") throw new Help();
        else if (a.startsWith("-")) throw new Usage(`test: no option ${a}`);
        else files.push(a);
    }
    if (!files.length) throw new Usage("test: give a .ds, .dstest or .dsc");
    const blobs = files.map((path) => ({ path, data: new Uint8Array(read(path)) }));
    if (program !== null) read(program);
    const ds = await openTarget(await loadBinding());
    /** @param {string} line */
    const err = (line) => io.stderr(`ds test: ${line}\n`);
    let refused = false;
    /** @param {string} line */
    const refuse = (line) => { err(line); refused = true; };

    /** Each `.ds` compiled once, by its resolved path: its artefact, or why not. */
    /** @type {Map<string, { dsc: Uint8Array } | { refusal: Error }>} */
    const compiled = new Map();
    /** @param {string} path */
    const compileOnce = async (path) => {
        const key = resolve(path);
        let got = compiled.get(key);
        if (got === undefined) {
            try {
                got = { dsc: await compileFile(ds, path, search) };
            } catch (e) {
                if (!(e instanceof Error && e.name === "CompileRefused")) throw e;
                got = { refusal: e };
            }
            compiled.set(key, got);
        }
        return got;
    };
    /**
     * The module of the artefact whose source is `path`: its DsSource names a
     * file of that name, with that text ([RDSC.14.2.3]: the name is spelled as
     * the search path spells it, so the text decides). null when it carries none.
     * @param {Uint8Array} dsc @param {string} path
     */
    const moduleOf = (dsc, path) => {
        const text = new Uint8Array(readFileSync(path));
        const m = sourceModules(ds, dsc).find((s) => basename(s.file) === basename(path) && sameBytes(s.data, text));
        return m === undefined ? null : m.moduleId;
    };
    /**
     * The program a library runs under: `--program`, or the one program in its
     * directory whose artefact carries it. A string is why there is none.
     * @param {string} lib
     * @returns {Promise<{ path: string, dsc: Uint8Array, id: number } | string>}
     */
    const programFor = async (lib) => {
        if (program !== null) {
            const got = await compileOnce(program);
            if ("refusal" in got) return got.refusal.message;
            const id = moduleOf(got.dsc, lib);
            return id === null ? `${lib}: ${program} does not import it` : { path: program, dsc: got.dsc, id };
        }
        const dir = dirname(lib);
        /** @type {Array<{ path: string, dsc: Uint8Array, id: number }>} */
        const importers = [];
        /** @type {string[]} */
        const broken = [];
        for (const name of readdirSync(dir).filter((n) => n.endsWith(".ds")).sort()) {
            const path = join(dir, name);
            if (resolve(path) === resolve(lib)) continue;
            const got = await compileOnce(path);
            if ("refusal" in got) {
                if (!NOT_A_PROGRAM.test(got.refusal.message)) broken.push(name);
                continue;
            }
            const id = moduleOf(got.dsc, lib);
            if (id !== null) importers.push({ path, dsc: got.dsc, id });
        }
        if (importers.length === 1) return importers[0];
        const named = importers.length
            ? `${importers.length} programs import it: ${importers.map((p) => basename(p.path)).join(", ")}`
            : `no program in ${dir} imports it`;
        const also = broken.length ? `; ${broken.join(", ")} did not compile` : "";
        return `${lib}: a library runs under the program that imports it ([LTSL.2.2]), and ${named}${also}; `
            + "name one with --program";
    };

    /** The programs to run, in the order first named. @type {Map<string, TestRun>} */
    const runs = new Map();
    /** @param {string} path @param {Uint8Array} dsc @param {string} given @param {number | null} id  null for all */
    const plan = (path, dsc, given, id) => {
        const key = resolve(path);
        let r = runs.get(key);
        if (r === undefined) {
            r = { path, dsc, all: false, modules: new Set(), given: [] };
            runs.set(key, r);
        }
        if (id === null) r.all = true;
        else r.modules.add(id);
        if (!r.given.includes(given)) r.given.push(given);
    };

    for (const { path, data } of blobs) {
        const what = sniff(ds, data);
        if (what.kind === "dsc") {
            plan(path, data, path, null);
            continue;
        }
        if (what.kind !== "source") {
            refuse(`${path}: not a .ds, .dstest or .dsc (${what.kind === "trace" ? "a trace" : what.why})`);
            continue;
        }
        const companion = extname(path) === ".dstest";
        const source = companion ? join(dirname(path), `${basename(path, ".dstest")}.ds`) : path;
        if (companion && !existsSync(source)) {
            refuse(`${path}: a .dstest is the tests of the module of its name beside it ([LTSL.2.4]), `
                   + `and there is no ${basename(source)}`);
            continue;
        }
        const got = await compileOnce(source);
        if ("dsc" in got) {
            // A program: all of it, or for its companion, its own cases.
            plan(source, got.dsc, path, companion ? moduleOf(got.dsc, source) ?? 0 : null);
            continue;
        }
        if (!NOT_A_PROGRAM.test(got.refusal.message)) {
            refuse(got.refusal.message);
            continue;
        }
        const host = await programFor(source);
        if (typeof host === "string") refuse(host);
        else plan(host.path, host.dsc, path, host.id);
    }

    let passed = 0, total = 0;
    for (const r of runs.values()) {
        let cases;
        try {
            cases = decodeCases(ds, r.dsc).filter((c) => r.all || r.modules.has(c.moduleId));
        } catch (e) {
            if (!(e instanceof DstestError)) throw e;
            refuse(`${r.path}: ${e.message}`);
            continue;
        }
        const label = r.given.includes(r.path) ? r.given.join(", ") : `${r.given.join(", ")}, under ${r.path}`;
        if (!cases.length) {
            refuse(`${label}: no test cases`);
            continue;
        }
        if (runs.size > 1 || label !== r.path) io.stdout(`${label}\n`);
        const results = cases.map((c) => runCase(ds, r.dsc, c));
        for (const res of results) io.stdout(caseLines(res).map((l) => `${l}\n`).join(""));
        passed += results.filter((res) => res.passed).length;
        total += results.length;
    }
    // With no case run, the refusals above are the whole story.
    io.stdout(total ? `${summaryLine(passed, total)}\n` : "ds test: no case ran\n");
    return refused || passed < total ? 1 : 0;
}

/** @param {Uint8Array} a @param {Uint8Array} b */
function sameBytes(a, b) {
    return a.length === b.length && a.every((x, i) => x === b[i]);
}

/**
 * `--root` and `--out` (DSDB_MCP.md §7), a directory that is not one a usage error.
 * @param {string} cmd  `mcp` or `serve`, for the message
 * @param {string[]} roots
 * @param {string | null} out
 */
function fenceFor(cmd, roots, out) {
    try {
        return new Fence({ roots, out });
    } catch (err) {
        if (err instanceof Fenced) throw new Usage(`${cmd}: ${err.message}`);
        throw err;
    }
}

/**
 * `ds serve`: dsdb's API over a WebSocket, for a page (dsdb/DSDB_WEB.md
 * §4). On either target, as `mcp` is, and loaded only here. Runs until
 * interrupted; says where to connect on stderr, token included.
 * @param {string[]} argv  after `serve`
 * @param {Io} io
 * @returns {Promise<number>} the exit status
 */
async function serve(argv, io) {
    /** @type {{ host: string, port: number, origins: string[], token: string | null, search: string[], shellLines: boolean }} */
    const o = { host: "127.0.0.1", port: 7373, origins: [], token: null, search: [], shellLines: false };
    /** @type {string[]} */
    const roots = [];
    /** @type {string | null} */
    let out = null;
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i], more = i + 1 < argv.length;
        if ((a === "-L" || a === "--search-path") && more) o.search.push(argv[++i]);
        else if (a === "--root" && more) roots.push(argv[++i]);
        else if (a === "--out" && more) out = argv[++i];
        else if (a === "--shell-lines") o.shellLines = true;
        else if (a === "--host" && more) o.host = argv[++i];
        else if (a === "--origin" && more) o.origins.push(argv[++i]);
        else if (a === "--token" && more) o.token = argv[++i];
        else if (a === "--port" && more) {
            o.port = Number(argv[++i]);
            if (!Number.isInteger(o.port) || o.port < 0 || o.port > 65535) throw new Usage("serve: --port is 0 to 65535");
        } else throw new Usage(`serve: no option ${a}`);
    }
    const { loopback, newToken, runServe } = await import("../serve/server.js");
    if (!loopback(o.host)) throw new Usage(`serve: --host ${o.host} is not a loopback address; ds serve listens on this machine only`);
    const fence = fenceFor("serve", roots, out);
    const token = o.token ?? newToken();
    /** @param {string} l */
    const log = (l) => io.stderr(l + "\n");
    const host = o.host.includes(":") ? `[${o.host}]` : o.host;
    const s = await runServe({ ...o, token, fence, log }).catch((/** @type {NodeJS.ErrnoException} */ err) => {
        // The port is taken, or this user may not listen on it: neither is a fault in `ds`.
        if (err.code === "EADDRINUSE") throw new SocketError(`serve: ${host}:${o.port} is already in use; --port names another`);
        if (err.code === "EACCES") throw new SocketError(`serve: not permitted to listen on ${host}:${o.port}; --port names another`);
        throw err;
    });
    log(`ds serve: ws://${host}:${s.port}/?token=${token}`);
    log(o.origins.length ? `ds serve: pages from ${o.origins.join(", ")}` : "ds serve: pages from this machine only");
    log(`ds serve: reads under ${fence.roots.join(", ")}; writes under ${fence.out}`);
    if (o.shellLines) log("ds serve: shell lines on (ops/exec)");
    await /** @type {Promise<void>} */ (new Promise((resolve) => {
        const stop = () => resolve();
        process.once("SIGINT", stop);
        process.once("SIGTERM", stop);
    }));
    await s.close();
    return 0;
}

/**
 * A message with `ds status -216`, as `@ds-lang/ds`'s DsError words it, saying
 * `DS_ERR_NAN_REJECTED` instead: the name the books and `libds.h` use.
 * @param {string} message
 * @returns {Promise<string>}
 */
async function statusNamed(message) {
    const m = /\bds status (-?\d+)/.exec(message);
    if (m === null) return message;
    const { status } = await loadBinding();
    const name = Object.entries(status).find(([, v]) => v === Number(m[1]))?.[0];
    return name === undefined ? message : message.replace(m[0], name);
}

/** This package's package.json: its version, and the Node it declares. */
const packageJson = () => JSON.parse(readFileSync(new URL("../../package.json", import.meta.url), "utf8"));

/**
 * The warning `ds` gives on a Node older than its package's
 * `engines.node` (`>=N`), the oldest Node the release is tested on. npm only
 * warns at install, and a distribution's own Node can be older (Ubuntu
 * 24.04's is 18), so `ds` says it again where it runs, and runs anyway.
 * @param {string} running  `process.versions.node`
 * @param {unknown} declared  package.json's `engines.node`
 * @returns {string | null}  null at or above the floor, or for a floor not of the form `>=N`
 */
export function belowNodeFloor(running, declared) {
    const floor = typeof declared === "string" ? /^>=\s*(\d+)/.exec(declared) : null;
    const major = Number(/^(\d+)\./.exec(running)?.[1]);
    if (floor === null || !Number.isInteger(major) || major >= Number(floor[1])) return null;
    return `ds: this is Node ${running}; ds is tested on Node ${floor[1]} and later, and may fail here`;
}

/**
 * The command, with its I/O given, so a test can run it in process.
 * @param {string[]} argv
 * @param {Io} io
 * @returns {Promise<number>} the exit status
 */
export async function main(argv, io) {
    const old = belowNodeFloor(process.versions.node, packageJson().engines?.node);
    if (old !== null) io.stderr(old + "\n");
    // A subcommand's help and usage errors show its own lines.
    const usage = Object.hasOwn(SUB_USAGE, argv[0] ?? "") ? SUB_USAGE[argv[0]] : USAGE;
    try {
        // Help is asked for, so it is no usage error: stdout, and 0. Every
        // subcommand takes it.
        if (argv.includes("-h") || argv.includes("--help")) throw new Help();
        if (argv[0] === "--version") return await version(io);
        if (SUBCOMMANDS.includes(argv[0])) needValues(argv[0], argv.slice(1));
        if (argv[0] === "mcp") return await mcp(argv.slice(1), io);
        if (argv[0] === "lsp") return await lsp(argv.slice(1), io);
        if (argv[0] === "dap") return await dap(argv.slice(1), io);
        if (argv[0] === "serve") return await serve(argv.slice(1), io);
        if (argv[0] === "test") return await dstest(argv.slice(1), io);
        // A slip for a subcommand is not a file to read.
        const slip = argv[0] !== undefined && !/[./\\]/.test(argv[0]) && !existsSync(argv[0]) ? nearCommand(argv[0]) : null;
        if (slip !== null) throw new Usage(`no command \`${argv[0]}\`; did you mean \`${slip}\`?`);
        const o = parseArgs(argv);
        const kinds = classify(o.files);
        if (o.interactive) return await shell(o, kinds, io);
        if (kinds.facts.length) {
            if (kinds.other.length) throw new Usage(`with fact files, give the program and facts only (${kinds.other[0]}?)`);
            refuseUnread(o, NOT_BATCH, "a trace: a run on fact files does not read it");
            if (o.calls === null && o.listen === null && o.given.includes("--call-timeout"))
                throw new Usage("--call-timeout: it bounds the wait for replies, so it needs --calls or --listen");
            return await batch(o, kinds, io);
        }
        if (o.calls !== null || o.listen !== null)
            throw new Usage("--calls and --listen go with a program and fact files");
        // A program alone is not a trace to list: say what it can be given.
        const [only, ...more] = [...kinds.ds, ...kinds.dsc];
        if (only !== undefined && !more.length && !kinds.other.length)
            throw new Usage(`${only} is a program: with -b, give fact files to run it (ds -b ${only} FACTS...); `
                            + `without -b it opens in the shell, and \`ds test ${only}\` runs its tests`);
        refuseUnread(o, NOT_LISTING, "a program and fact files: the listing does not read it");
        // A program and one trace, in either order: the listing, typed by
        // that program.
        if (only !== undefined && !more.length && kinds.other.length === 1)
            return await listing(o, kinds.other[0], io, only);
        if (o.files.length !== 1)
            throw new Usage("with -b, give exactly one trace, or a program and fact files");
        return await listing(o, o.files[0], io);
    } catch (err) {
        if (err instanceof Help) {
            io.stdout(usage + "\n");
            return 0;
        }
        if (err instanceof Usage) {
            // A subcommand's usage is a few lines, and goes with its error;
            // the whole command's would scroll the one line that matters
            // away, so it is pointed to.
            const after = usage === USAGE ? "run `ds --help` for the usage" : usage;
            io.stderr((err.message ? `ds: ${err.message}\n` : "") + after + "\n");
            return 2;
        }
        if (err instanceof Unreadable || err instanceof SocketError || err instanceof NoBinding) {
            io.stderr(`ds: ${err.message}\n`);
            return 4;
        }
        if (err instanceof FactFileError
            || (err instanceof Error && (err.name === "DsError" || err.name === "CompileRefused"))) {
            io.stderr(`ds: ${await statusNamed(err.message)}\n`);
            return 1;
        }
        throw err;
    }
}

/**
 * `--version`: this package's version, then the libds and the compiler it
 * runs on, each from the thing itself, and which target: natively `dsc`,
 * under wasm ds_dsc. One that is not there is said, not fatal: the
 * version is what someone asks for when something is missing.
 * @param {Io} io
 * @returns {Promise<number>} 0
 */
async function version(io) {
    const pkg = packageJson();
    // The release stamps package.json; in a checkout it is the placeholder,
    // and the tree's own VERSION says what it is a checkout of.
    const tree = new URL("../../../../VERSION", import.meta.url);
    const mine = pkg.version === "0.0.0+dev" && existsSync(tree)
        ? `${readFileSync(tree, "utf8").trim()}+dev (a checkout)` : pkg.version;
    const lines = [`ds ${mine}`];
    /** @type {import("./open.js").Binding | null} */
    let binding = null;
    try {
        binding = await loadBinding();
        const ds = await openTarget(binding);
        const e = new ds.Engine();
        try {
            lines.push(`libds ${e.platformSignature.libdsVersion} (@ds-lang/ds, ${ds.target})`);
        } finally {
            e.close();
        }
    } catch (err) {
        if (!(err instanceof NoBinding)) throw err;
        lines.push(`libds: not available: ${err.message}`);
    }
    lines.push(binding !== null && target(binding) === "wasm" ? await wasmCompilerVersion(binding) : nativeDscVersion());
    io.stdout(lines.map((l) => `${l}\n`).join(""));
    return 0;
}

/** The native `dsc`'s version line, or that it is not there. */
function nativeDscVersion() {
    const dsc = process.env.DS_MERCURY_DSC || "dsc";
    const run = spawnSync(dsc, ["--version"], { encoding: "utf8" });
    return run.status === 0 ? run.stdout.trim().split("\n")[0]
                            : `dsc: not found (${dsc}; DS_MERCURY_DSC names one elsewhere)`;
}

/**
 * ds_dsc's version line, from the compiler itself, or that it is not
 * there.
 * @param {import("./open.js").Binding} binding
 * @returns {Promise<string>}
 */
async function wasmCompilerVersion(binding) {
    if (binding.installed().wasmCompiler === null)
        return "ds_dsc: not installed (DS_JS_DSC names one elsewhere)";
    const run = await binding.runDscUnderWasm(["--version"]);
    return run.status === 0 ? `${new TextDecoder().decode(run.stdout).trim().split("\n")[0]} (ds_dsc)`
                            : `ds_dsc: --version exited ${run.status}: ${run.stderr.trim()}`;
}

// Run when this file is the program: a symlink to it (npm's `bin`) resolves to it.
function isMain() {
    if (!process.argv[1]) return false;
    try {
        return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
    } catch {
        return false;
    }
}

if (isMain()) {
    /** @type {Io} */
    const io = { stdout: (s) => process.stdout.write(s), stderr: (s) => process.stderr.write(s) };
    // -f runs until interrupted, and an interrupt is how it ends: 0, as
    // dstrace's KeyboardInterrupt is.
    process.on("SIGINT", () => process.exit(0));
    main(process.argv.slice(2), io).then((code) => { process.exitCode = code; });
}
