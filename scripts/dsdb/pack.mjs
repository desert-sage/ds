#!/usr/bin/env node
// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// pack -- the DS tools package, ds-tools-<version>.tgz, and the JavaScript
// binding's package, ds-lang-ds-<version>.tgz, from a checkout.
//
//     node scripts/dsdb/pack.mjs [--binding] --version 1.0.0 \
//         --glue bindings/js/build/ds_wasm.mjs \
//         --compiler ds_dsc-1.0.0.tgz \
//         --bundle runtime-1.11.3.tgz --bundle tslib-2.8.1.tgz \
//         --out dist
//
// THE TOOLS PACKAGE, @ds-lang/tools: dsdb on wasm @ds-lang/ds,
// which runs wherever Node runs. `npm install ./ds-tools-<version>.tgz
// --offline` installs `ds` at node_modules/.bin/ds under the prefix, and needs
// nothing else:
//
//   package/                          dsdb: its `files`, LICENSE, the notices
//     node_modules/@ds-lang/ds/       @ds-lang/ds: its `files`, and in build/:
//       build/ds_wasm.mjs      the wasm glue, and its .wasm (--glue)
//       build/ds_dsc/          the compiler (--compiler)
//       build/share/ds/stdlib/        the standard library (--stdlib)
//     node_modules/<each --bundle>/   @emnapi/runtime, and what it depends on
//
// THE BINDING'S PACKAGE, @ds-lang/ds (--binding): the same @ds-lang/ds, with
// the same build/, at the top of its own tarball, and the bundles beside it:
//
//   package/                          @ds-lang/ds: its `files`, LICENSE, build/
//     node_modules/<each --bundle>/   @emnapi/runtime, and what it depends on
//
// Each is where lib/index.js looks for it with no variable set. The standard
// library is `<the compiler's directory>/../share/ds/stdlib`, where the
// compiler looks itself ([LIMP.3.3.1]), as the libds tarball's `bin/dsc`
// finds `share/ds/stdlib`. Both package.json files are stamped with the
// version, dsdb's `@ds-lang/ds` dependency with it too, and @ds-lang/ds's with the
// @emnapi/runtime its index.js requires under Node, at the version bundled.
// Every bundle's own dependencies must be bundled too, or npm would fetch.
//
// PUBLISHABLE AS PACKED, AND ONLY AS PACKED: a checkout's package.json files
// are `"private": true`, which refuses an `npm publish` of a working tree;
// the packed ones drop it and carry `publishConfig.access: public`, which a
// scoped package needs on its first publish. So what reaches npm is what the
// release built, installed and tested, and nothing else (#5776).
//
// THE COMPILER AND THE RUNTIME COME FROM ONE RELEASE: libds loads the .dsc of
// its own version only ([LDET.1.10]), so --compiler must be the
// ds_dsc-<version>.tgz of this --version.
//
// DETERMINISTIC: entries sorted by path, every time SOURCE_DATE_EPOCH (else
// npm's own fixed time), owner and group 0, a mode of 0644, or 0755 where the
// input is executable, and gzip's own time 0. The same inputs give the same
// bytes.
//
// Node's standard library only, so a checkout packs it with Node alone.

import { mkdirSync, readFileSync, readdirSync, renameSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { gunzipSync, gzipSync } from "node:zlib";

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const DSDB = join(ROOT, "tools", "dsdb");
const JS_BINDING = join(ROOT, "bindings", "js");
/** `@ds-lang/ds`'s npm name: what dsdb imports, so where it is bundled. */
const JS_NAME = "@ds-lang/ds";
export const STDLIB = join(ROOT, "stdlib");
/** The licence and the notices, at the repository's root: both packages carry the licence. */
const LICENSE = "LICENSE";
const NOTICES = "THIRD_PARTY_NOTICES.md";
/** npm's own time for a packed entry, 1985-10-26T08:15:00Z, when no SOURCE_DATE_EPOCH is given. */
export const NPM_EPOCH = 499162500;

const USAGE = `usage: node scripts/dsdb/pack.mjs [--binding] --version V --glue ds_wasm.mjs --compiler ds_dsc-V.tgz
                                [--bundle PKG.tgz]... [--stdlib DIR] --out DIR`;

/** A version npm takes: 1.0.0, 0.19.0-rc.1, 0.0.0+dev. */
const VERSION = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;

/** What the packer refuses, said as the command line says it. */
export class PackError extends Error {}

/** @typedef {{ data: Buffer, mode: number }} Entry  a file to pack: its bytes, and 0o644 or 0o755 */

/**
 * A file on disk as an entry.
 * @param {string} path
 * @returns {Entry}
 */
function fileEntry(path) {
    return { data: readFileSync(path), mode: statSync(path).mode & 0o111 ? 0o755 : 0o644 };
}

/**
 * The notices' sections for a component neither package contains: the
 * rendered books' font ships in the docs tarball alone. A notice for a
 * component that is absent is its own kind of inaccuracy, the notices file
 * says, so the packages leave these out, as the libds tarball and wheel do.
 */
export const NOT_PACKED = Object.freeze(["Fira Code"]);

/**
 * The notices text without the `## ` sections named in `drop`, each from its
 * heading to the next `## ` heading, as the release's notices check strips
 * them for the libds tarball and wheel: a heading is `## NAME`, trailing space
 * ignored.
 * @param {string} text
 * @param {readonly string[]} drop
 * @returns {string}
 */
export function stripSections(text, drop) {
    let keep = true;
    return text.split(/(?<=\n)/).filter((line) => {
        const m = /^## (.+?)\s*$/.exec(line);
        if (m) keep = !drop.includes(m[1]);
        return keep;
    }).join("");
}

/** The notices as a package carries them: the repository's, less NOT_PACKED. @returns {Entry} */
function noticesEntry() {
    const e = fileEntry(join(ROOT, NOTICES));
    return { data: Buffer.from(stripSections(e.data.toString("utf8"), NOT_PACKED), "utf8"), mode: e.mode };
}

/**
 * Every file under `dir`, by its path relative to it, leaving out dotfiles and
 * node_modules, as npm leaves them out of a package.
 * @param {string} dir
 * @param {string} [prefix]
 * @returns {string[]}
 */
function walk(dir, prefix = "") {
    /** @type {string[]} */
    const out = [];
    for (const e of readdirSync(dir, { withFileTypes: true })) {
        if (e.name.startsWith(".") || e.name === "node_modules") continue;
        const rel = prefix + e.name;
        if (e.isDirectory()) out.push(...walk(join(dir, e.name), `${rel}/`));
        else if (e.isFile()) out.push(rel);
        else throw new PackError(`${join(dir, e.name)} is neither a file nor a directory`);
    }
    return out;
}

/**
 * A package's files, as its package.json's `files` names them, by path.
 * @param {string} dir
 * @param {{ files?: string[] }} pkg
 * @returns {Map<string, Entry>}
 */
function packageFiles(dir, pkg) {
    /** @type {Map<string, Entry>} */
    const out = new Map();
    for (const f of pkg.files ?? []) {
        const at = join(dir, f);
        if (statSync(at).isDirectory())
            for (const rel of walk(at)) out.set(`${f.replace(/\/$/, "")}/${rel}`, fileEntry(join(at, rel)));
        else out.set(f, fileEntry(at));
    }
    return out;
}

/** @param {string} path */
function readJson(path) {
    return JSON.parse(readFileSync(path, "utf8"));
}

/** @param {unknown} v @returns {Entry} */
const jsonEntry = (v) => ({ data: Buffer.from(`${JSON.stringify(v, null, 2)}\n`), mode: 0o644 });

// ── tar ──────────────────────────────────────────────────────────────────────

/**
 * A NUL-terminated header field as text.
 * @param {Buffer} b
 */
const cstr = (b) => {
    const end = b.indexOf(0);
    return b.subarray(0, end < 0 ? b.length : end).toString("utf8");
};

/**
 * An octal header field.
 * @param {Buffer} h
 * @param {number} at
 * @param {number} len
 * @param {string} file  for the refusal
 */
function octal(h, at, len, file) {
    if (h[at] & 0x80) throw new PackError(`${file}: a base-256 header field, which this reader does not read`);
    const s = cstr(h.subarray(at, at + len)).trim();
    return s === "" ? 0 : parseInt(s, 8);
}

/**
 * A pax extended header's field (`<len> <key>=<value>\n` records), or null.
 * @param {Buffer} body
 * @param {string} key
 */
function paxField(body, key) {
    let at = 0;
    while (at < body.length) {
        const sp = body.indexOf(0x20, at);
        if (sp < 0) break;
        const len = parseInt(body.subarray(at, sp).toString("ascii"), 10);
        if (!(len > 0)) break;
        const rec = body.subarray(sp + 1, at + len - 1).toString("utf8");
        const eq = rec.indexOf("=");
        if (rec.slice(0, eq) === key) return rec.slice(eq + 1);
        at += len;
    }
    return null;
}

/**
 * The regular files of a gzipped tarball, by path: ustar, GNU's long names
 * and pax's paths read; directories passed over; a link refused, since a
 * package holds files.
 * @param {string} file
 * @returns {Map<string, Entry>}
 */
export function readTgz(file) {
    /** @type {Buffer} */
    let buf;
    try {
        buf = gunzipSync(readFileSync(file));
    } catch (err) {
        throw new PackError(`${file}: not a gzipped tarball (${err instanceof Error ? err.message : err})`);
    }
    /** @type {Map<string, Entry>} */
    const out = new Map();
    /** @type {string | null} */
    let longName = null;
    for (let at = 0; at + 512 <= buf.length;) {
        const h = buf.subarray(at, at + 512);
        if (h.every((b) => b === 0)) break;
        const size = octal(h, 124, 12, file);
        const type = h[156] === 0 ? "0" : String.fromCharCode(h[156]);
        const body = buf.subarray(at + 512, at + 512 + size);
        at += 512 + Math.ceil(size / 512) * 512;
        if (type === "L") { longName = cstr(body); continue; }
        if (type === "x") { longName = paxField(body, "path") ?? longName; continue; }
        if (type === "g") continue;
        const ustar = h.subarray(257, 263).toString("latin1") === "ustar\0";
        const prefix = ustar ? cstr(h.subarray(345, 500)) : "";
        const short = cstr(h.subarray(0, 100));
        const name = (longName ?? (prefix ? `${prefix}/${short}` : short)).replace(/^\.\//, "");
        longName = null;
        if (type === "5") continue;
        if (type !== "0" && type !== "7") throw new PackError(`${file}: ${name} is not a regular file (type ${type})`);
        out.set(name, { data: Buffer.from(body), mode: octal(h, 100, 8, file) & 0o111 ? 0o755 : 0o644 });
    }
    return out;
}

/**
 * One ustar header: a long path split at a `/` into prefix and name.
 * @param {string} path
 * @param {number} size
 * @param {number} mode
 * @param {number} mtime
 */
function header(path, size, mode, mtime) {
    const h = Buffer.alloc(512);
    let name = path, prefix = "";
    if (Buffer.byteLength(path) > 100) {
        let cut = -1;
        for (let i = path.indexOf("/"); i >= 0 && cut < 0; i = path.indexOf("/", i + 1))
            if (Buffer.byteLength(path.slice(0, i)) <= 155 && Buffer.byteLength(path.slice(i + 1)) <= 100) cut = i;
        if (cut < 0) throw new PackError(`${path}: too long a path for a tar header`);
        prefix = path.slice(0, cut);
        name = path.slice(cut + 1);
    }
    /** @param {number} v @param {number} width */
    const oct = (v, width) => `${v.toString(8).padStart(width - 1, "0")}\0`;
    h.write(name, 0, 100, "utf8");
    h.write(oct(mode, 8), 100, "ascii");
    h.write(oct(0, 8), 108, "ascii");                 // uid
    h.write(oct(0, 8), 116, "ascii");                 // gid
    h.write(oct(size, 12), 124, "ascii");
    h.write(oct(mtime, 12), 136, "ascii");
    h.write("        ", 148, "ascii");                // the checksum, as spaces while it is summed
    h.write("0", 156, "ascii");                       // a regular file
    h.write("ustar\0", 257, "latin1");
    h.write("00", 263, "ascii");
    h.write(oct(0, 8), 329, "ascii");                 // devmajor
    h.write(oct(0, 8), 337, "ascii");                 // devminor
    h.write(prefix, 345, 155, "utf8");
    let sum = 0;
    for (const b of h) sum += b;
    h.write(`${sum.toString(8).padStart(6, "0")}\0 `, 148, "ascii");
    return h;
}

/**
 * A gzipped tarball of `files`, sorted by path, every entry at `mtime`.
 * @param {Map<string, Entry>} files
 * @param {number} mtime
 */
function tgz(files, mtime) {
    /** @type {Buffer[]} */
    const parts = [];
    for (const path of [...files.keys()].sort()) {
        const { data, mode } = /** @type {Entry} */ (files.get(path));
        parts.push(header(path, data.length, mode, mtime), data, Buffer.alloc((512 - (data.length % 512)) % 512));
    }
    parts.push(Buffer.alloc(1024));
    return gzipSync(Buffer.concat(parts), { level: 9 });
}

// ── the packages ─────────────────────────────────────────────────────────────

/** The npm name of the tools package, which `npm install` puts at node_modules/@ds-lang/tools. */
export const TOOLS_NAME = "@ds-lang/tools";

/**
 * A package.json as it is packed: stamped with `version`, publishable.
 * @param {Record<string, unknown>} pkg
 * @param {string} version
 * @param {Record<string, unknown>} more
 */
function packed(pkg, version, more) {
    const out = { ...pkg, version, ...more, publishConfig: { access: "public" } };
    delete out.private;
    return jsonEntry(out);
}

/**
 * A new archive's files: `put` refuses a path two inputs give.
 * @param {string} version
 * @param {number} epoch
 */
function archive(version, epoch) {
    if (typeof version !== "string" || !VERSION.test(version))
        throw new PackError(`--version ${JSON.stringify(version)} is not a version: 1.0.0, 0.19.0-rc.1`);
    if (!Number.isSafeInteger(epoch) || epoch < 0 || epoch >= 8 ** 11)
        throw new PackError(`SOURCE_DATE_EPOCH ${epoch} is not a time a tar header holds`);
    /** @type {Map<string, Entry>} */
    const files = new Map();
    /** @param {string} path @param {Entry} e */
    const put = (path, e) => {
        if (files.has(path)) throw new PackError(`two inputs give ${path}`);
        files.set(path, e);
    };
    return { files, put };
}

/**
 * Write `files` as `<out>/<name>`; its path.
 * @param {Map<string, Entry>} files
 * @param {string} out
 * @param {string} name
 * @param {number} epoch
 */
function write(files, out, name, epoch) {
    mkdirSync(out, { recursive: true });
    const file = join(out, name);
    writeFileSync(`${file}.part`, tgz(files, epoch));
    renameSync(`${file}.part`, file);
    return file;
}

/**
 * Pack the DS tools package, @ds-lang/tools; its path.
 * @param {object} o
 * @param {string} o.version  the release's, stamped into both packages
 * @param {string} o.glue  ds_wasm.mjs as the wasm lane builds it, its .wasm beside it
 * @param {string} o.compiler  ds_dsc-<version>.tgz
 * @param {string[]} [o.bundles]  npm tarballs: @emnapi/runtime, and each package it depends on
 * @param {string} [o.stdlib]  the standard library's directory
 * @param {string} o.out  the directory ds-tools-<version>.tgz is written to
 * @param {number} [o.epoch]  every entry's time, in seconds
 * @returns {string}
 */
export function pack({ version, glue, compiler, bundles = [], stdlib = STDLIB, out, epoch = NPM_EPOCH }) {
    const { files, put } = archive(version, epoch);

    // dsdb, at the top.
    const dsdb = readJson(join(DSDB, "package.json"));
    if (dsdb.name !== TOOLS_NAME)
        throw new PackError(`tools/dsdb/package.json is named ${dsdb.name}, not ${TOOLS_NAME}`);
    if (!(dsdb.bundleDependencies ?? []).includes(JS_NAME))
        throw new PackError(`tools/dsdb/package.json does not bundle ${JS_NAME}`);
    for (const [rel, e] of packageFiles(DSDB, dsdb)) put(`package/${rel}`, e);
    put("package/package.json",
        packed(dsdb, version, { dependencies: { ...dsdb.dependencies, [JS_NAME]: version } }));
    put(`package/${LICENSE}`, fileEntry(join(ROOT, LICENSE)));
    put(`package/${NOTICES}`, noticesEntry());

    // @ds-lang/ds, bundled, with what it loads under Node in build/.
    const js = `package/node_modules/${JS_NAME}`;
    const runtime = binding(put, js, { version, glue, compiler, stdlib }, bundles, "package/node_modules");
    const jsPkg = readJson(join(JS_BINDING, "package.json"));
    put(`${js}/package.json`,
        packed(jsPkg, version, { dependencies: { ...jsPkg.dependencies, "@emnapi/runtime": runtime } }));
    return write(files, out, `ds-tools-${version}.tgz`, epoch);
}

/**
 * Pack the JavaScript binding's package, @ds-lang/ds, alone: the tools
 * package's @ds-lang/ds at the top, with what it requires bundled; its path.
 * Its tarball is named as `npm pack` names a scoped package's.
 * @param {Parameters<typeof pack>[0]} o
 * @returns {string}
 */
export function packBinding({ version, glue, compiler, bundles = [], stdlib = STDLIB, out, epoch = NPM_EPOCH }) {
    const { files, put } = archive(version, epoch);
    const runtime = binding(put, "package", { version, glue, compiler, stdlib }, bundles, "package/node_modules");
    const jsPkg = readJson(join(JS_BINDING, "package.json"));
    put("package/package.json",
        packed(jsPkg, version, { dependencies: { ...jsPkg.dependencies, "@emnapi/runtime": runtime },
                                 bundleDependencies: ["@emnapi/runtime"] }));
    return write(files, out, `${JS_NAME.slice(1).replace("/", "-")}-${version}.tgz`, epoch);
}

/**
 * @ds-lang/ds's files under `js`, but its package.json, and the bundles
 * under `modules`; the version of the @emnapi/runtime bundled.
 * @param {(path: string, e: Entry) => void} put
 * @param {string} js
 * @param {{ version: string, glue: string, compiler: string, stdlib: string }} o
 * @param {string[]} bundles
 * @param {string} modules
 * @returns {string}
 */
function binding(put, js, { version, glue, compiler, stdlib }, bundles, modules) {
    const jsPkg = readJson(join(JS_BINDING, "package.json"));
    if (jsPkg.name !== JS_NAME)
        throw new PackError(`bindings/js/package.json is named ${jsPkg.name}, not ${JS_NAME}`);
    for (const [rel, e] of packageFiles(JS_BINDING, jsPkg)) put(`${js}/${rel}`, e);
    put(`${js}/${LICENSE}`, fileEntry(join(ROOT, LICENSE)));
    // It carries libds, RE2 and Abseil in its .wasm and the compiler in
    // build/ds_dsc, so it gives their notices wherever it is installed alone.
    put(`${js}/${NOTICES}`, noticesEntry());

    // The glue names its .wasm by its own name, so both keep theirs.
    if (basename(glue) !== "ds_wasm.mjs")
        throw new PackError(`--glue ${glue}: the glue is ds_wasm.mjs, which loads ds_wasm.wasm by name`);
    const wasm = join(dirname(glue), "ds_wasm.wasm");
    for (const p of [glue, wasm]) {
        try {
            put(`${js}/build/${basename(p)}`, fileEntry(p));
        } catch (err) {
            if (err instanceof PackError) throw err;
            throw new PackError(`--glue: no ${p}`);
        }
    }

    const want = `ds_dsc-${version}.tgz`;
    if (basename(compiler) !== want)
        throw new PackError(`--compiler ${basename(compiler)} is not ${want}: libds loads the .dsc of its own `
                            + "version only, so the compiler is this release's ([LDET.1.10])");
    const dsc = readTgz(compiler);
    const parts = ["ds_dsc/ds_dsc.mjs", "ds_dsc/dsc_cli.wasm"];
    if ([...dsc.keys()].sort().join("\n") !== parts.join("\n"))
        throw new PackError(`--compiler ${compiler} holds ${[...dsc.keys()].sort().join(", ")}, not ${parts.join(", ")}`);
    for (const [rel, e] of dsc) put(`${js}/build/${rel}`, e);

    // [LIMP.3.3.1]: <the compiler's directory>/../share/ds/stdlib.
    let library;
    try {
        library = walk(stdlib);
    } catch (err) {
        if (err instanceof PackError) throw err;
        throw new PackError(`--stdlib ${stdlib}: not a directory`);
    }
    for (const rel of library) put(`${js}/build/share/ds/stdlib/${rel}`, fileEntry(join(stdlib, rel)));

    // The bundled npm packages, flat under node_modules/, as npm lays out a
    // bundle's dependencies.
    /** @type {Map<string, { name: string, version: string, dependencies?: Record<string, string> }>} */
    const bundled = new Map();
    for (const b of bundles) {
        const t = readTgz(b);
        const pj = t.get("package/package.json");
        if (pj === undefined) throw new PackError(`--bundle ${b}: no package/package.json; an npm tarball has one`);
        const p = JSON.parse(pj.data.toString("utf8"));
        if (bundled.has(p.name)) throw new PackError(`--bundle ${b}: ${p.name} is bundled twice`);
        bundled.set(p.name, p);
        for (const [rel, e] of t) {
            if (!rel.startsWith("package/")) throw new PackError(`--bundle ${b}: ${rel} is outside package/`);
            put(`${modules}/${p.name}/${rel.slice("package/".length)}`, e);
        }
    }
    const runtime = bundled.get("@emnapi/runtime");
    if (runtime === undefined)
        throw new PackError("no --bundle gives @emnapi/runtime, which @ds-lang/ds's lib/index.js requires under Node");
    for (const [name, p] of bundled)
        for (const dep of Object.keys(p.dependencies ?? {}))
            if (!bundled.has(dep)) throw new PackError(`${name} depends on ${dep}, which no --bundle gives`);
    return runtime.version;
}

/**
 * The command line: what it packed, or why not.
 * @param {string[]} argv
 * @returns {number}
 */
export function main(argv) {
    /** @type {{ version?: string, glue?: string, compiler?: string, bundles: string[], stdlib?: string, out?: string }} */
    const o = { bundles: [] };
    let which = pack;
    for (let i = 0; i < argv.length; i++) {
        const flag = argv[i];
        const value = () => {
            const v = argv[++i];
            if (v === undefined) throw new PackError(`${flag} needs a value`);
            return v;
        };
        switch (flag) {
        case "--version": o.version = value(); break;
        case "--glue": o.glue = value(); break;
        case "--compiler": o.compiler = value(); break;
        case "--bundle": o.bundles.push(value()); break;
        case "--stdlib": o.stdlib = value(); break;
        case "--out": o.out = value(); break;
        case "--binding": which = packBinding; break;
        case "-h": case "--help":
            process.stdout.write(`${USAGE}\n`);
            return 0;
        default: throw new PackError(`no option ${flag}\n${USAGE}`);
        }
    }
    for (const k of /** @type {const} */ (["version", "glue", "compiler", "out"]))
        if (o[k] === undefined) throw new PackError(`--${k} is needed\n${USAGE}`);
    const env = process.env.SOURCE_DATE_EPOCH;
    if (env !== undefined && env !== "" && !/^\d+$/.test(env))
        throw new PackError(`SOURCE_DATE_EPOCH ${JSON.stringify(env)} is not whole seconds`);
    const file = which({ version: /** @type {string} */ (o.version), glue: /** @type {string} */ (o.glue),
                        compiler: /** @type {string} */ (o.compiler), bundles: o.bundles, stdlib: o.stdlib,
                        out: /** @type {string} */ (o.out), epoch: env ? Number(env) : NPM_EPOCH });
    process.stdout.write(`pack: ${file} (${statSync(file).size} bytes)\n`);
    return 0;
}

if (process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    try {
        process.exitCode = main(process.argv.slice(2));
    } catch (err) {
        if (!(err instanceof PackError)) throw err;
        process.stderr.write(`pack: ${err.message}\n`);
        process.exitCode = 1;
    }
}
