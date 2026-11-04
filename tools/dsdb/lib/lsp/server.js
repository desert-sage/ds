// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// `ds lsp`: a Language Server Protocol server over stdio. The
// compiler is the only parser
// ([LTSL.1.2]), so this server parses nothing: every change is compiled for
// its diagnostics, and dumped (`dsc dump-ast`) for the tree hover,
// definition (analysis.js), completion (complete.js), references and rename
// (references.js), the outline (symbols.js) and semantic tokens
// (semantic.js) read. Signature help (signature.js) reads the text and the
// registries. All of it runs through ports, the libraries a
// program imports read through one too, so a test can give its own and the
// server does no I/O but the protocol's.
//
// The client's `initializationOptions` may give `libs`, library directories
// for every compile, and `docs`, where the rendered documentation is (a URL,
// or a path; a relative path is the workspace root's), which a builtin's
// hover links the clauses that define it into (builtins.js).
//
// Full document sync: the client sends the whole text on every change. One
// client; requests are answered one at a time, in order. A tree is kept per
// document whenever the source parses, and the last good one is kept while it
// does not, so hover and definition still answer mid-edit.
//
// ONE THING AT A TIME. The compiler may be async (ds_dsc is),
// so an analysis and a message could interleave; they take turns instead
// (`inTurn`), in the order they arrive, and each runs to its end before the
// next begins.
//
// AN EDIT IS ANALYSED WHEN TYPING SETTLES, not on every keystroke: compiling
// runs `dsc`, and the server answers nothing while it does. A change waits
// `settleMs` with no change after it. Opening or saving a document analyses it
// at once. Any request but completion and signature help first analyses
// whatever is waiting, so it answers about the text as it is. Those two are
// asked for while typing, and answer from the last good tree and the line's
// own text. A library changed on disk (`workspace/didChangeWatchedFiles`)
// waits the same way, for every open document, since any of them may import
// it.

import { readFileSync } from "node:fs";
import { dirname, isAbsolute, resolve as resolvePath } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { readModule, TreeError } from "../ast/read.js";
import { definition, hoverText, resolve } from "./analysis.js";
import { builtinAt, builtinHover, docsBase } from "./builtins.js";
import { complete } from "./complete.js";
import { program, refAt, sites, units } from "./references.js";
import { GRAMMAR_WORDS, TYPES } from "./registries.js";
import { encode, LEGEND, tokens } from "./semantic.js";
import { signatureHelp } from "./signature.js";
import { flat, matches, outline } from "./symbols.js";
import { parseDiagnostics } from "./diagnostics.js";
import { FrameError, bodies, frame } from "./framing.js";
import { fromClient, lines, negotiate, toClient } from "./positions.js";

/** @import { Module } from "../ast/nodes.js" */
/** @import { Diagnostic, Point } from "./diagnostics.js" */
/** @import { Encoding } from "./positions.js" */

/** @typedef {{ tree: unknown } | { refused: string }} Dumped */

/**
 * The compiler, as the server reaches it: synchronously or not, since the
 * wasm compiler is async.
 * @typedef {object} LspPorts
 * @property {(text: string, file: string) => Dumped | Promise<Dumped>} dumpAst
 *     the source's tree as `dsc dump-ast` writes it, or what it said refusing it
 * @property {(text: string, file: string, search: string[]) => string | null | Promise<string | null>} compile
 *     the compiler's diagnostics, or null when the source compiles
 * @property {(path: string) => string | null} [read]
 *     a library's text, or null when there is no such file; none reads nothing
 */

/** @import { Site, Unit } from "./references.js" */
/** @import { Outline } from "./symbols.js" */

/** The words a rename may not take: the grammar's and the builtin types ([LLEX.9.6], [LGRA.22.8]). */
const RESERVED = new Set([...Object.values(GRAMMAR_WORDS).flat(), ...TYPES.map((t) => t.name)]);

/** @typedef {{ text: string, lines: string[], tree: Module | null }} Doc */

const PARSE = -32700, INVALID = -32600, NO_METHOD = -32601, INTERNAL = -32603, NOT_INITIALIZED = -32002,
    REQUEST_FAILED = -32803;

const VERSION = JSON.parse(readFileSync(new URL("../../package.json", import.meta.url), "utf8")).version;

/**
 * Serve until the client sends `exit`, or the input ends.
 * @param {object} o
 * @param {AsyncIterable<Uint8Array>} o.input  the client's bytes
 * @param {(s: string) => void} o.write  to the client
 * @param {(s: string) => void} o.log  not to the client: stderr
 * @param {LspPorts} o.ports
 * @param {string[]} [o.libs]  library directories for every compile, after the document's own
 * @param {number} [o.settleMs]  how long a change waits, with no change after it, to be analysed
 * @returns {Promise<number>} the exit status: 0 after `shutdown`, 1 if the client exits without one
 */
export async function runLsp({ input, write, log, ports, libs = [], settleMs = 200 }) {
    /** @type {Map<string, Doc>} */
    const docs = new Map();
    /** @type {Encoding} */
    let enc = "utf-16";
    let initialized = false, shutdown = false;
    let search = [...libs];
    /** @type {string[]} the workspace folders' paths: a rename edits nothing outside them */
    let folders = [];
    /** @type {string | null} the rendered documentation's base URL, for a builtin's clause links */
    let docsAt = null;
    /** @param {Record<string, unknown>} msg */
    const send = (msg) => write(frame({ jsonrpc: "2.0", ...msg }));
    /** set at `exit`: nothing is sent to a client that has gone */
    let closed = false;

    /** @type {Promise<void>} the last turn's end */
    let turn = Promise.resolve();
    /**
     * Run `fn` when every turn before it has ended: analyses and messages, one
     * at a time, in order. Its own failure is its caller's, not the next turn's.
     * @template T
     * @param {() => Promise<T>} fn
     * @returns {Promise<T>}
     */
    const inTurn = (fn) => {
        const p = turn.then(fn);
        turn = p.then(() => {}, () => {});
        return p;
    };

    /**
     * A document's tree and diagnostics, from its current text.
     * @param {string} uri
     */
    const analyse = async (uri) => {
        const doc = docs.get(uri);
        if (doc === undefined || closed) return;
        const path = uriPath(uri);
        const file = path ?? uri;
        const dumped = await ports.dumpAst(doc.text, file);
        if ("tree" in dumped) {
            try {
                doc.tree = readModule(dumped.tree);
            } catch (err) {
                // The compiler and ds.asdl disagree: a defect to report, and
                // the last good tree kept.
                if (!(err instanceof TreeError)) throw err;
                log(`ds lsp: ${file}: ${err.message}`);
            }
        }
        const dirs = path === null ? search : [dirname(path), ...search];
        const report = await ports.compile(doc.text, file, dirs);
        if (closed) return;
        const diagnostics = report === null ? [] : parseDiagnostics(report).map((d) => toLsp(d, doc.lines, uri, enc));
        send({ method: "textDocument/publishDiagnostics", params: { uri, diagnostics } });
    };

    /** @type {Map<string, ReturnType<typeof setTimeout>>} each document waiting to be analysed, and its timer */
    const waiting = new Map();

    /**
     * Analyse a document once its changes settle: `settleMs` after the last.
     * @param {string} uri
     */
    const settle = (uri) => {
        clearTimeout(waiting.get(uri));
        waiting.set(uri, setTimeout(() => {
            // A request may have caught it up before its turn came.
            inTurn(async () => {
                if (!waiting.has(uri)) return;
                waiting.delete(uri);
                await analyse(uri);
            }).catch((err) => log(`ds lsp: ${uri}: ${err instanceof Error ? err.message : String(err)}`));
        }, settleMs));
    };

    /** Analyse now whatever is waiting: a request answers about the text as it is. */
    const catchUp = async () => {
        for (const [uri, timer] of waiting) {
            clearTimeout(timer);
            waiting.delete(uri);
            await analyse(uri);
        }
    };

    /**
     * A request's answer.
     * @param {string} method
     * @param {any} params
     * @returns {Promise<unknown>}
     */
    const answer = async (method, params) => {
        switch (method) {
        case "initialize": {
            initialized = true;
            enc = negotiate(params?.capabilities?.general?.positionEncodings);
            const opts = params?.initializationOptions;
            const root = params?.rootUri ? uriPath(params.rootUri) : null;
            if (Array.isArray(opts?.libs))
                search = [...opts.libs.filter((/** @type {unknown} */ l) => typeof l === "string")
                    .map((/** @type {string} */ l) => (isAbsolute(l) || root === null ? l : resolvePath(root, l))), ...libs];
            const d = opts?.docs;
            docsAt = docsBase(typeof d === "string" && !/^[a-z][a-z0-9+.-]*:/i.test(d) && !isAbsolute(d) && root !== null
                ? resolvePath(root, d) : d);
            const wf = Array.isArray(params?.workspaceFolders) ? params.workspaceFolders : [];
            folders = [...wf.map((/** @type {any} */ f) => uriPath(f?.uri)), root]
                .flatMap((/** @type {string | null} */ p) => (p === null ? [] : [p]));
            return {
                capabilities: {
                    positionEncoding: enc,
                    textDocumentSync: { openClose: true, change: 1, save: { includeText: false } },
                    hoverProvider: true,
                    definitionProvider: true,
                    completionProvider: { triggerCharacters: [".", ":"] },
                    referencesProvider: true,
                    renameProvider: true,
                    documentSymbolProvider: true,
                    workspaceSymbolProvider: true,
                    semanticTokensProvider: { legend: LEGEND, full: true },
                    signatureHelpProvider: { triggerCharacters: ["(", ","] },
                },
                serverInfo: { name: "ds lsp", version: VERSION },
            };
        }
        case "shutdown":
            shutdown = true;
            return null;
        case "textDocument/hover": {
            const at = target(params);
            if (at !== null) return { contents: { kind: "markdown", value: hoverText(at.t) } };
            // Not a name the program declares: a builtin, where it is called.
            const doc = docs.get(params?.textDocument?.uri);
            const pos = params?.position;
            if (doc === undefined || typeof pos?.line !== "number") return null;
            const text = doc.lines[pos.line] ?? "";
            const b = builtinAt(doc.tree, text, fromClient(text, pos.character, enc));
            return b === null ? null : { contents: { kind: "markdown", value: builtinHover(b, docsAt) } };
        }
        case "textDocument/completion": {
            const doc = docs.get(params?.textDocument?.uri);
            const pos = params?.position;
            if (doc === undefined || typeof pos?.line !== "number") return null;
            const text = doc.lines[pos.line] ?? "";
            return { isIncomplete: false, items: complete(doc.tree, doc.lines, pos.line + 1, fromClient(text, pos.character, enc)) };
        }
        case "textDocument/references": {
            const found = await found_(params);
            if (found === null) return [];
            const keep = params?.context?.includeDeclaration !== false;
            return found.all.filter((s) => keep || !s.declaration)
                .map((s) => ({ uri: s.unit.uri, range: range(s.unit.lines, s.range.line, s.range.start, s.range.line, s.range.end, enc) }));
        }
        case "textDocument/rename": {
            const name = params?.newName;
            if (typeof name !== "string" || !/^[\p{L}_][\p{L}\p{N}_]*$/u.test(name))
                throw new RequestFailed(`${JSON.stringify(name)} is not a DS name`);
            if (RESERVED.has(name)) throw new RequestFailed(`\`${name}\` is a reserved word ([LLEX.9.6])`);
            const found = await found_(params);
            if (found === null) throw new RequestFailed("nothing the program declares is named here");
            const outside = found.all.find((s) => !inside(s.unit.path, s.unit.uri === params.textDocument.uri));
            if (outside !== undefined)
                throw new RequestFailed(`${outside.unit.path ?? outside.unit.uri} is outside the workspace, so the rename would leave it behind`);
            /** @type {Record<string, { range: unknown, newText: string }[]>} */
            const changes = {};
            for (const s of found.all)
                (changes[s.unit.uri] ??= []).push({ range: range(s.unit.lines, s.range.line, s.range.start, s.range.line, s.range.end, enc), newText: name });
            return { changes };
        }
        case "textDocument/definition": {
            const at = target(params);
            if (at === null) return null;
            const r = definition(at.doc.lines, at.t);
            return { uri: params.textDocument.uri, range: range(at.doc.lines, r.line, r.start, r.line, r.end, enc) };
        }
        case "textDocument/documentSymbol": {
            const doc = docs.get(params?.textDocument?.uri);
            if (doc === undefined || doc.tree === null) return [];
            const ls = doc.lines;
            /** @param {Outline} o @returns {unknown} */
            const toLspSymbol = (o) => ({
                name: o.name, detail: o.detail, kind: o.kind,
                range: range(ls, o.range.start.line, o.range.start.col, o.range.end.line, o.range.end.col, enc),
                selectionRange: range(ls, o.selection.line, o.selection.start, o.selection.line, o.selection.end, enc),
                children: o.children.map(toLspSymbol),
            });
            return outline(doc.tree, ls).map(toLspSymbol);
        }
        case "textDocument/semanticTokens/full": {
            // A document that has never parsed is still split and its
            // reserved words coloured; only the program's names need a tree.
            const uri = params?.textDocument?.uri;
            const doc = docs.get(uri);
            if (doc === undefined) return { data: [] };
            const unit = doc.tree === null ? null : await programOf(uri, doc, doc.tree);
            return { data: encode(tokens(doc.lines, unit), doc.lines, enc) };
        }
        case "textDocument/signatureHelp": {
            const doc = docs.get(params?.textDocument?.uri);
            const pos = params?.position;
            if (doc === undefined || typeof pos?.line !== "number") return null;
            const text = doc.lines[pos.line] ?? "";
            return signatureHelp(doc.tree, doc.lines, pos.line + 1, fromClient(text, pos.character, enc));
        }
        case "workspace/symbol": {
            // Every file an open document's program reaches, each once: the
            // workspace as the server knows it, without walking the disk.
            const query = typeof params?.query === "string" ? params.query : "";
            /** @type {Set<string>} */
            const seen = new Set();
            /** @type {unknown[]} */
            const out = [];
            for (const [uri, d] of docs) {
                if (d.tree === null) continue;
                for (const u of units(await programOf(uri, d, d.tree))) {
                    if (seen.has(u.uri)) continue;
                    seen.add(u.uri);
                    for (const s of flat(outline(u.tree, u.lines))) {
                        if (!matches(s.name, query)) continue;
                        const r = s.range;
                        out.push({
                            name: s.name, kind: s.kind, ...(s.container === null ? {} : { containerName: s.container }),
                            location: { uri: u.uri, range: range(u.lines, r.start.line, r.start.col, r.end.line, r.end.col, enc) },
                        });
                    }
                }
            }
            return out;
        }
        default:
            throw new NoMethod(method);
        }
    };

    /**
     * What the name at a request's position refers to, in its document.
     * @param {any} params  a TextDocumentPositionParams
     */
    const target = (params) => {
        const doc = docs.get(params?.textDocument?.uri);
        const pos = params?.position;
        if (doc === undefined || doc.tree === null || typeof pos?.line !== "number") return null;
        const text = doc.lines[pos.line] ?? "";
        const t = resolve(doc.tree, text, pos.line + 1, fromClient(text, pos.character, enc));
        return t === null ? null : { doc, t };
    };

    /**
     * What the name at a request's position refers to across the program,
     * and every site of it, once each.
     * @param {any} params  a TextDocumentPositionParams
     * @returns {Promise<{ all: Site[] } | null>}
     */
    const found_ = async (params) => {
        const uri = params?.textDocument?.uri;
        const doc = docs.get(uri);
        const pos = params?.position;
        if (doc === undefined || doc.tree === null || typeof pos?.line !== "number") return null;
        const top = await programOf(uri, doc, doc.tree);
        const text = doc.lines[pos.line] ?? "";
        const ref = refAt(top, pos.line + 1, fromClient(text, pos.character, enc));
        if (ref === null) return null;
        /** @type {Map<string, Site>} */
        const once = new Map();
        for (const s of sites(top, ref)) {
            const key = `${s.unit.uri}\0${s.range.line}:${s.range.start}`;
            if (!once.has(key) || s.declaration) once.set(key, s);
        }
        return { all: [...once.values()] };
    };

    /**
     * The program rooted at an open document: it and every library it
     * imports. A library open in the editor is read from there, not the disk.
     *
     * references.js walks the imports synchronously and asks for each
     * library's tree as it reaches it; dumping one may be async. So the walk
     * is run with the trees dumped so far, each one it asks for and has not
     * got is dumped, and it is run again, until it asks for none it has not
     * got: one more round per level of imports.
     * @param {string} uri
     * @param {Doc} doc
     * @param {Module} tree  its tree, which the caller has seen is there
     * @returns {Promise<Unit>}
     */
    const programOf = async (uri, doc, tree) => {
        /** @type {Map<string, string>} the open documents' text, by path: what the editor has, not what is saved */
        const open = new Map();
        for (const [u, d] of docs) {
            const p = uriPath(u);
            if (p !== null) open.set(p, d.text);
        }
        /** @type {Map<string, Module | null>} each library's tree, by its file and text */
        const trees = new Map();
        for (;;) {
            /** @type {Map<string, [string, string]>} what this round asked for and had not got */
            const missing = new Map();
            const top = program({ uri, path: uriPath(uri), lines: doc.lines, tree }, search, {
                read: (p) => open.get(p) ?? ports.read?.(p) ?? null,
                tree: (text, file) => {
                    const key = `${file}\0${text}`;
                    const got = trees.get(key);
                    if (got !== undefined) return got;
                    missing.set(key, [text, file]);
                    return null;
                },
                uri: (p) => pathToFileURL(p).href,
            });
            if (!missing.size) return top;
            for (const [key, [text, file]] of missing) trees.set(key, await treeOf(text, file));
        }
    };

    /**
     * A library's tree, or null when it does not parse or its tree does not
     * read (that said on stderr).
     * @param {string} text
     * @param {string} file
     * @returns {Promise<Module | null>}
     */
    const treeOf = async (text, file) => {
        const dumped = await ports.dumpAst(text, file);
        if (!("tree" in dumped)) return null;
        try {
            return readModule(dumped.tree);
        } catch (err) {
            if (!(err instanceof TreeError)) throw err;
            log(`ds lsp: ${file}: ${err.message}`);
            return null;
        }
    };

    /**
     * A file a rename may edit: inside a workspace folder, or the document
     * the rename was asked in, if it is not saved anywhere.
     * @param {string | null} path
     * @param {boolean} isRequestDoc
     */
    const inside = (path, isRequestDoc) => {
        if (path === null) return isRequestDoc;
        return folders.some((f) => path === f || path.startsWith(f.endsWith("/") ? f : f + "/"));
    };

    /**
     * A notification, acted on.
     * @param {string} method
     * @param {any} params
     */
    const notice = async (method, params) => {
        const uri = params?.textDocument?.uri;
        switch (method) {
        case "textDocument/didOpen":
            docs.set(uri, doc(params.textDocument.text, null));
            await analyse(uri);
            return;
        case "textDocument/didChange": {
            const changes = params.contentChanges;
            // Full sync: the last change is the whole document.
            const text = changes[changes.length - 1].text;
            docs.set(uri, doc(text, docs.get(uri)?.tree ?? null));
            settle(uri);
            return;
        }
        case "textDocument/didSave":
            clearTimeout(waiting.get(uri));
            waiting.delete(uri);
            await analyse(uri);
            return;
        case "textDocument/didClose":
            clearTimeout(waiting.get(uri));
            waiting.delete(uri);
            docs.delete(uri);
            send({ method: "textDocument/publishDiagnostics", params: { uri, diagnostics: [] } });
            return;
        case "workspace/didChangeWatchedFiles":
            for (const u of docs.keys()) settle(u);
            return;
        }
        // Anything else (`initialized`, `$/cancelRequest`, a setting) is
        // not acted on, as the protocol allows for a notification.
    };

    /** The client's messages, ended by bytes that cannot be read as one, which stderr hears of. */
    async function* read() {
        try {
            yield* bodies(input);
        } catch (err) {
            if (!(err instanceof FrameError)) throw err;
            log(`ds lsp: ${err.message}`);
        }
    }

    /**
     * The session's end: nothing waits past it, since an analysis after
     * `exit` would write to a client that has gone.
     * @param {number} code
     */
    const done = (code) => {
        closed = true;
        for (const timer of waiting.values()) clearTimeout(timer);
        waiting.clear();
        return code;
    };

    /**
     * A request answered, or a notification acted on, in its turn.
     * @param {any} msg
     * @param {boolean} isRequest
     */
    const handle = async (msg, isRequest) => {
        try {
            if (isRequest && !WHILE_TYPING.has(msg.method)) await catchUp();
            if (isRequest) send({ id: msg.id, result: await answer(msg.method, msg.params) });
            else await notice(msg.method, msg.params);
        } catch (err) {
            if (err instanceof NoMethod) {
                if (isRequest) send({ id: msg.id, error: { code: NO_METHOD, message: `no method ${err.message}` } });
                return;
            }
            if (err instanceof RequestFailed) {
                if (isRequest) send({ id: msg.id, error: { code: REQUEST_FAILED, message: err.message } });
                return;
            }
            const text = err instanceof Error ? err.message : String(err);
            log(`ds lsp: ${msg.method}: ${text}`);
            if (isRequest) send({ id: msg.id, error: { code: INTERNAL, message: text } });
        }
    };

    for await (const body of read()) {
        /** @type {any} */
        let msg;
        try {
            msg = JSON.parse(body);
        } catch {
            send({ id: null, error: { code: PARSE, message: "not JSON" } });
            continue;
        }
        if (msg === null || typeof msg !== "object" || typeof msg.method !== "string") {
            // A response to a request of ours: the server sends none yet.
            if (msg?.id === undefined) send({ id: null, error: { code: INVALID, message: "not a request or notification" } });
            continue;
        }
        const isRequest = msg.id !== undefined;
        if (msg.method === "exit") return done(shutdown ? 0 : 1);
        if (!initialized && msg.method !== "initialize") {
            if (isRequest) send({ id: msg.id, error: { code: NOT_INITIALIZED, message: "initialize first" } });
            continue;
        }
        // LSP 3.17, `shutdown`: a request after it errors with InvalidRequest.
        // `exit` is the one message left to act on; a notification
        // is dropped, as before `initialize`.
        if (shutdown) {
            if (isRequest) send({ id: msg.id, error: { code: INVALID, message: "the server is shut down: only `exit` is left" } });
            continue;
        }
        await inTurn(() => handle(msg, isRequest));
    }
    return done(shutdown ? 0 : 1);
}

/** The requests asked for while typing, answered without waiting for an analysis. */
const WHILE_TYPING = new Set(["textDocument/completion", "textDocument/signatureHelp"]);

/** A request this server does not answer. */
class NoMethod extends Error {}

/** A request understood and refused: a rename that cannot be made, and why. */
class RequestFailed extends Error {}

/**
 * @param {string} text
 * @param {Module | null} tree  the last good one
 * @returns {Doc}
 */
function doc(text, tree) {
    return { text, lines: lines(text), tree };
}

/**
 * A `file:` URI's path; null for any other scheme (an unsaved buffer).
 * @param {string} uri
 */
function uriPath(uri) {
    return typeof uri === "string" && uri.startsWith("file:") ? fileURLToPath(uri) : null;
}

/**
 * An LSP range from tree positions: lines 1-based, columns code points.
 * @param {string[]} ls
 * @param {number} l1
 * @param {number} c1
 * @param {number} l2
 * @param {number} c2
 * @param {Encoding} enc
 */
function range(ls, l1, c1, l2, c2, enc) {
    return {
        start: { line: l1 - 1, character: toClient(ls[l1 - 1] ?? "", c1, enc) },
        end: { line: l2 - 1, character: toClient(ls[l2 - 1] ?? "", c2, enc) },
    };
}

/**
 * A diagnostic as LSP has it. An empty span is widened to one character, so
 * an editor has something to underline.
 * @param {Diagnostic} d
 * @param {string[]} ls
 * @param {string} uri
 * @param {Encoding} enc
 */
function toLsp(d, ls, uri, enc) {
    /** @param {Point} a @param {Point} b */
    const span = (a, b) => {
        const wide = b.line > a.line || b.col > a.col;
        return range(ls, a.line, a.col, b.line, wide ? b.col : a.col + 1, enc);
    };
    return {
        range: span(d.span.start, d.span.end),
        severity: 1,
        code: d.code,
        source: "ds lsp",
        message: d.hint === null ? d.message : `${d.message}\n\nhint: ${d.hint}`,
        ...(d.related.length ? {
            relatedInformation: d.related.map((r) => ({ location: { uri, range: span(r.span.start, r.span.end) }, message: r.message })),
        } : {}),
    };
}
