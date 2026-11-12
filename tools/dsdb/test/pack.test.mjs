// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// pack.mjs: the DS tools package, ds-tools-<version>.tgz, packed from a
// checkout. Packed here from fixtures standing in for the
// release's products (the wasm glue, ds_dsc's tarball, @emnapi/runtime
// and its dependency) and read back with the system's own `tar`, so what is
// checked is the archive, not the packer's opinion of it. The release installs
// the real one on a clean Node and runs it; this holds its layout.

import { test, describe, before, after } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

import { NOT_PACKED, PackError, ROOT, TOOLS_NAME, pack, packBinding, stripSections } from "../../../scripts/dsdb/pack.mjs";

const VERSION = "1.2.3";

/** @type {string} */
let DIR;
/** @type {{ glue: string, compiler: string, bundles: string[], stdlib: string }} */
let INPUTS;

/**
 * Write `files` (path -> text) under `dir`.
 * @param {string} dir
 * @param {Record<string, string>} files
 */
function tree(dir, files) {
    for (const [p, text] of Object.entries(files)) {
        mkdirSync(dirname(join(dir, p)), { recursive: true });
        writeFileSync(join(dir, p), text);
    }
}

/**
 * A tarball made by the system's tar, of `top` under `dir`.
 * @param {string} out
 * @param {string} dir
 * @param {string} top
 */
function tgz(out, dir, top) {
    execFileSync("tar", ["-czf", out, "-C", dir, top]);
    return out;
}

/** An npm package's tarball: package/ holding its package.json and an index. */
function npmTarball(name, version, deps = {}) {
    const d = mkdtempSync(join(DIR, "npm-"));
    tree(d, { "package/package.json": JSON.stringify({ name, version, dependencies: deps }, null, 2),
              "package/index.js": `// ${name}\n` });
    return tgz(join(DIR, `${name.replace("/", "-")}-${version}.tgz`), d, "package");
}

/** The archive's entries, as the system's tar lists them. @param {string} file */
const listing = (file) => execFileSync("tar", ["-tzf", file], { encoding: "utf8" }).split("\n").filter(Boolean);

/** One file of the archive, as the system's tar extracts it. @param {string} file @param {string} entry */
const member = (file, entry) => execFileSync("tar", ["-xzOf", file, entry]);

/** Every file under `dir`, relative, as a package's `files` gives it. @param {string} dir */
function filesUnder(dir) {
    /** @type {string[]} */
    const out = [];
    const walk = (/** @type {string} */ d) => {
        for (const e of readdirSync(d, { withFileTypes: true })) {
            if (e.name.startsWith(".") || e.name === "node_modules") continue;
            const p = join(d, e.name);
            if (e.isDirectory()) walk(p);
            else out.push(relative(dir, p));
        }
    };
    walk(dir);
    return out;
}

before(() => {
    DIR = mkdtempSync(join(process.env.DS_MERCURY_SCRATCH || tmpdir(), "dsdb-pack-"));
    const glue = join(DIR, "glue");
    tree(glue, { "ds_wasm.mjs": "// the glue\n", "ds_wasm.wasm": "\0asm glue" });
    const dsc = join(DIR, "dsc");
    tree(dsc, { "ds_dsc/ds_dsc.mjs": "// the compiler\n", "ds_dsc/dsc_cli.wasm": "\0asm dsc" });
    const stdlib = join(DIR, "stdlib");
    tree(stdlib, { "math.ds": "# math\n", "units/si.ds": "# si\n" });
    INPUTS = {
        glue: join(glue, "ds_wasm.mjs"),
        compiler: tgz(join(DIR, `ds_dsc-${VERSION}.tgz`), dsc, "ds_dsc"),
        bundles: [npmTarball("@emnapi/runtime", "1.11.3", { tslib: "^2.4.0" }), npmTarball("tslib", "2.8.1")],
        stdlib,
    };
});

after(() => rmSync(DIR, { recursive: true, force: true }));

/** Pack the fixtures into a fresh directory, with `more` over them. */
function packed(more = {}) {
    return pack({ version: VERSION, ...INPUTS, out: mkdtempSync(join(DIR, "out-")), epoch: 1_700_000_000, ...more });
}

describe("pack.mjs: the DS tools package", () => {
    test("it is ds-tools-<version>.tgz, every entry under package/, as npm installs a tarball", () => {
        const file = packed();
        assert.equal(file.split("/").pop(), `ds-tools-${VERSION}.tgz`);
        const names = listing(file);
        assert.ok(names.length > 0);
        for (const n of names) assert.ok(n.startsWith("package/"), n);
        assert.deepEqual(names, [...names].sort(), "sorted, so the bytes do not depend on a directory's order");
    });

    test("dsdb at the top: its files, stamped, with @ds-lang/ds bundled and the licence beside it", () => {
        const file = packed();
        const names = new Set(listing(file));
        const dsdb = join(ROOT, "tools", "dsdb");
        for (const f of [...filesUnder(join(dsdb, "lib")).map((p) => `lib/${p}`),
                         ...filesUnder(join(dsdb, "skills")).map((p) => `skills/${p}`)])
            assert.ok(names.has(`package/${f}`), `package/${f}`);
        assert.ok(!names.has("package/test/pack.test.mjs"), "what `files` leaves out is not packed");
        for (const f of ["package/LICENSE", "package/THIRD_PARTY_NOTICES.md"]) assert.ok(names.has(f), f);
        assert.ok(member(file, "package/README.md").equals(readFileSync(join(dsdb, "npm", "README.md"))),
                  "npm builds the package's page from package/README.md: tools/dsdb/npm/README.md");
        const pkg = JSON.parse(member(file, "package/package.json").toString("utf8"));
        assert.equal(pkg.version, VERSION, "`ds --version` and `ds lsp`'s serverInfo read it");
        assert.deepEqual(pkg.dependencies, { "@ds-lang/ds": VERSION });
        assert.deepEqual(pkg.bundleDependencies, ["@ds-lang/ds"]);
        assert.deepEqual(pkg.bin, { ds: "./lib/cli/main.js" });
        assert.equal(pkg.name, TOOLS_NAME);
    });

    test("publishable as packed, and only as packed: private in the checkout, not in the archive", () => {
        const file = packed();
        for (const [src, at] of [[join(ROOT, "tools", "dsdb"), "package"],
                                 [join(ROOT, "bindings", "js"), "package/node_modules/@ds-lang/ds"]]) {
            const tree = JSON.parse(readFileSync(join(src, "package.json"), "utf8"));
            assert.equal(tree.private, true, `${src}/package.json refuses an npm publish of a checkout`);
            const pkg = JSON.parse(member(file, `${at}/package.json`).toString("utf8"));
            assert.ok(!("private" in pkg), `${at}/package.json is private, so npm would refuse to publish it`);
            assert.deepEqual(pkg.publishConfig, { access: "public" }, "a scoped package's first publish needs it");
        }
    });

    test("@ds-lang/ds bundled: stamped, its wasm glue, the compiler, and the standard library beside it", () => {
        const file = packed();
        const names = new Set(listing(file));
        // Bundled under the name dsdb imports it by.
        const js = "package/node_modules/@ds-lang/ds";
        for (const f of filesUnder(join(ROOT, "bindings", "js", "lib")))
            assert.ok(names.has(`${js}/lib/${f}`), `${js}/lib/${f}`);
        const pkg = JSON.parse(member(file, `${js}/package.json`).toString("utf8"));
        assert.equal(pkg.version, VERSION);
        assert.deepEqual(pkg.dependencies, { "@emnapi/runtime": "1.11.3" },
                         "index.js requires it under Node, so the package says so, at the version bundled");
        // Where lib/index.js looks for each, with no environment variable set.
        assert.equal(member(file, `${js}/build/ds_wasm.mjs`).toString(), "// the glue\n");
        assert.equal(member(file, `${js}/build/ds_wasm.wasm`).toString(), "\0asm glue");
        assert.equal(member(file, `${js}/build/ds_dsc/ds_dsc.mjs`).toString(), "// the compiler\n");
        assert.equal(member(file, `${js}/build/ds_dsc/dsc_cli.wasm`).toString(), "\0asm dsc");
        // [LIMP.3.3.1]: <the compiler's directory>/../share/ds/stdlib.
        assert.deepEqual([...names].filter((n) => n.startsWith(`${js}/build/share/`)),
                         [`${js}/build/share/ds/stdlib/math.ds`, `${js}/build/share/ds/stdlib/units/si.ds`]);
        assert.equal(member(file, `${js}/build/share/ds/stdlib/units/si.ds`).toString(), "# si\n");
    });

    test("@emnapi/runtime bundled, with its own dependencies, beside @ds-lang/ds", () => {
        const file = packed();
        const runtime = JSON.parse(member(file, "package/node_modules/@emnapi/runtime/package.json").toString());
        assert.equal(runtime.version, "1.11.3");
        const tslib = JSON.parse(member(file, "package/node_modules/tslib/package.json").toString());
        assert.equal(tslib.version, "2.8.1");
        assert.equal(member(file, "package/node_modules/tslib/index.js").toString(), "// tslib\n");
    });

    test("deterministic: the same inputs and epoch give the same bytes; every entry carries the epoch", () => {
        const a = readFileSync(packed()), b = readFileSync(packed());
        assert.ok(a.equals(b), "two packs of the same inputs differ");
        const c = readFileSync(packed({ epoch: 1_700_000_001 }));
        assert.ok(!a.equals(c), "the epoch is in the bytes");
        const verbose = execFileSync("tar", ["--full-time", "--utc", "-tvzf", packed()], { encoding: "utf8" });
        for (const line of verbose.split("\n").filter(Boolean))
            assert.match(line, / 2023-11-14 22:13:20 package\//, line);
    });

    test("refused, by name: a compiler of another version, a dependency no bundle gives, a bad version", () => {
        const other = tgz(join(DIR, "ds_dsc-9.9.9.tgz"), join(DIR, "dsc"), "ds_dsc");
        assert.throws(() => packed({ compiler: other }), (e) => e instanceof PackError && /9\.9\.9/.test(e.message));
        assert.throws(() => packed({ bundles: [INPUTS.bundles[0]] }),
                      (e) => e instanceof PackError && /tslib/.test(e.message));
        assert.throws(() => packed({ bundles: [INPUTS.bundles[1]] }),
                      (e) => e instanceof PackError && /@emnapi\/runtime/.test(e.message));
        assert.throws(() => packed({ version: "one" }), (e) => e instanceof PackError && /one/.test(e.message));
        const noWasm = join(DIR, "glue-alone");
        tree(noWasm, { "ds_wasm.mjs": "// the glue\n" });
        assert.throws(() => packed({ glue: join(noWasm, "ds_wasm.mjs") }),
                      (e) => e instanceof PackError && /ds_wasm\.wasm/.test(e.message));
    });

    test("the command line packs as pack() does, and says where it wrote", () => {
        const out = mkdtempSync(join(DIR, "cli-"));
        const said = execFileSync(process.execPath, [fileURLToPath(new URL("../../../scripts/dsdb/pack.mjs", import.meta.url)),
            "--version", VERSION, "--glue", INPUTS.glue, "--compiler", INPUTS.compiler,
            "--bundle", INPUTS.bundles[0], "--bundle", INPUTS.bundles[1], "--stdlib", INPUTS.stdlib, "--out", out],
            { encoding: "utf8", env: { ...process.env, SOURCE_DATE_EPOCH: "1700000000" } });
        const file = join(out, `ds-tools-${VERSION}.tgz`);
        assert.match(said, new RegExp(`${file.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`));
        assert.ok(readFileSync(file).equals(readFileSync(packed())), "the same bytes as pack() with the same epoch");
    });
});

/** Pack the binding's package from the fixtures, with `more` over them. */
function bindingPacked(more = {}) {
    return packBinding({ version: VERSION, ...INPUTS, out: mkdtempSync(join(DIR, "out-")), epoch: 1_700_000_000, ...more });
}

describe("pack.mjs --binding: @ds-lang/ds alone", () => {
    test("it is ds-lang-ds-<version>.tgz, as npm pack names it, every entry under package/", () => {
        const file = bindingPacked();
        assert.equal(file.split("/").pop(), `ds-lang-ds-${VERSION}.tgz`);
        const names = listing(file);
        for (const n of names) assert.ok(n.startsWith("package/"), n);
        assert.deepEqual(names, [...names].sort());
    });

    test("the tools package's @ds-lang/ds, byte for byte, at the top", () => {
        const tools = packed(), alone = bindingPacked();
        const inTools = listing(tools).filter((n) => n.startsWith("package/node_modules/@ds-lang/ds/"));
        const want = inTools.map((n) => n.replace("package/node_modules/@ds-lang/ds/", "package/"));
        const have = listing(alone).filter((n) => !n.startsWith("package/node_modules/"));
        assert.deepEqual(have, want.sort());
        for (const n of inTools.filter((p) => !p.endsWith("/package.json")))
            assert.ok(member(tools, n).equals(member(alone, n.replace("package/node_modules/@ds-lang/ds/", "package/"))), n);
        assert.equal(member(alone, "package/build/ds_wasm.wasm").toString(), "\0asm glue");
        assert.equal(member(alone, "package/build/ds_dsc/dsc_cli.wasm").toString(), "\0asm dsc");
        assert.equal(member(alone, "package/build/share/ds/stdlib/units/si.ds").toString(), "# si\n");
        for (const f of ["package/LICENSE", "package/THIRD_PARTY_NOTICES.md"])
            assert.ok(have.includes(f), `${f}: the package carries libds and the compiler, so their notices`);
        assert.ok(member(alone, "package/README.md").equals(readFileSync(join(ROOT, "bindings", "js", "npm", "README.md"))),
                  "npm builds the package's page from package/README.md: bindings/js/npm/README.md, "
                  + "not the contributors' README beside package.json");
    });

    test("its manifest: stamped, publishable, and @emnapi/runtime bundled with what it depends on", () => {
        const file = bindingPacked();
        const pkg = JSON.parse(member(file, "package/package.json").toString("utf8"));
        assert.equal(pkg.name, "@ds-lang/ds");
        assert.equal(pkg.version, VERSION);
        assert.doesNotMatch(pkg.description, /native|Node-API/i,
                            "npm shows the description above the README, and the package has no native target");
        assert.deepEqual(pkg.dependencies, { "@emnapi/runtime": "1.11.3" });
        assert.deepEqual(pkg.bundleDependencies, ["@emnapi/runtime"], "so npm installs it offline, and from the tarball");
        assert.ok(!("private" in pkg));
        assert.deepEqual(pkg.publishConfig, { access: "public" });
        assert.equal(JSON.parse(member(file, "package/node_modules/@emnapi/runtime/package.json").toString()).version,
                     "1.11.3");
        assert.equal(member(file, "package/node_modules/tslib/index.js").toString(), "// tslib\n");
    });

    test("deterministic, and refused as the tools package is", () => {
        assert.ok(readFileSync(bindingPacked()).equals(readFileSync(bindingPacked())));
        const other = tgz(join(DIR, "ds_dsc-9.9.9.tgz"), join(DIR, "dsc"), "ds_dsc");
        assert.throws(() => bindingPacked({ compiler: other }), (e) => e instanceof PackError && /9\.9\.9/.test(e.message));
        assert.throws(() => bindingPacked({ bundles: [INPUTS.bundles[1]] }),
                      (e) => e instanceof PackError && /@emnapi\/runtime/.test(e.message));
    });

    test("the command line's --binding packs as packBinding() does", () => {
        const out = mkdtempSync(join(DIR, "cli-"));
        execFileSync(process.execPath, [fileURLToPath(new URL("../../../scripts/dsdb/pack.mjs", import.meta.url)),
            "--binding", "--version", VERSION, "--glue", INPUTS.glue, "--compiler", INPUTS.compiler,
            "--bundle", INPUTS.bundles[0], "--bundle", INPUTS.bundles[1], "--stdlib", INPUTS.stdlib, "--out", out],
            { encoding: "utf8", env: { ...process.env, SOURCE_DATE_EPOCH: "1700000000" } });
        assert.ok(readFileSync(join(out, `ds-lang-ds-${VERSION}.tgz`)).equals(readFileSync(bindingPacked())));
    });
});

// The packages carry the repository's notices less the sections for what
// neither contains (pack.mjs NOT_PACKED): the books' font, which only the
// docs tarball ships. The path: noticesEntry, through stripSections, in pack()
// and packBinding().
describe("pack.mjs: the notices both packages carry", () => {
    /** The `## ` section names of a notices text, in order. @param {string} text */
    const sectionsOf = (text) => [...text.matchAll(/^## (.+?)\s*$/gm)].map((m) => m[1]);
    const CHECK = join(ROOT, "scripts", "private", "release", "notices_check.py");

    test("stripSections drops a named section from its heading to the next, and nothing else", () => {
        const text = "# Notices\n\nintro\n\n## RE2\nre2\n\n## Fira Code  \nfont\n#### a sub-heading\nmore\n\n## musl\nm\n";
        assert.equal(stripSections(text, ["Fira Code"]), "# Notices\n\nintro\n\n## RE2\nre2\n\n## musl\nm\n");
        assert.equal(stripSections(text, []), text, "nothing named, nothing dropped");
        assert.equal(stripSections(text, ["Fira"]), text, "a name is the whole heading, not a prefix of it");
    });

    test("NOT_PACKED is the release's docs-only components, as its notices check names them",
         { skip: existsSync(CHECK) ? false : "no scripts/private in this tree" }, () => {
        const m = /^DOCS_COMPONENTS = \(([^)]*)\)/m.exec(readFileSync(CHECK, "utf8"));
        assert.ok(m, "notices_check.py states DOCS_COMPONENTS");
        assert.deepEqual([...NOT_PACKED].sort(), [...m[1].matchAll(/"([^"]+)"/g)].map((x) => x[1]).sort());
    });

    test("each package's notices: the repository's, every section but NOT_PACKED's", () => {
        const repo = readFileSync(join(ROOT, "THIRD_PARTY_NOTICES.md"), "utf8");
        for (const n of NOT_PACKED)
            assert.ok(sectionsOf(repo).includes(n), `the repository's notices have a ## ${n} to leave out`);
        const want = sectionsOf(repo).filter((s) => !NOT_PACKED.includes(s));
        const tools = packed(), alone = bindingPacked();
        for (const [file, entry] of [[tools, "package/THIRD_PARTY_NOTICES.md"],
                                     [tools, "package/node_modules/@ds-lang/ds/THIRD_PARTY_NOTICES.md"],
                                     [alone, "package/THIRD_PARTY_NOTICES.md"]]) {
            const text = member(file, entry).toString("utf8");
            assert.deepEqual(sectionsOf(text), want, entry);
            assert.equal(text, stripSections(repo, NOT_PACKED), `${entry}: the rest byte for byte`);
        }
    });
});
