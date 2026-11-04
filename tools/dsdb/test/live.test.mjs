// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// A live session from the command line (DSDB.md §11, stage 3): a program
// built up by definitions at the prompt, run, and saved as code. An emit and
// a definition compile, so this needs the lane's compiler for its target
// (compiler.mjs).

import { test, describe, before } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { main } from "../lib/cli/main.js";
import { NO_COMPILER, TARGET } from "./compiler.mjs";

const NO_ENGINE = process.env.DS_JS_FIXTURES ? false : "needs the js gate's engine (DS_JS_FIXTURES)";
const NO_DSC = NO_ENGINE || NO_COMPILER;

before(() => {
    process.env.DSDB_JS = fileURLToPath(new URL("../../../bindings/js/lib/index.js", import.meta.url));
});

describe(`a live session from the command line, on the ${TARGET} target`, () => {
    test("no program at all: built up by definitions, run, and saved as code (§4.16)", { skip: NO_DSC }, async () => {
        const base = process.env.DS_MERCURY_SCRATCH || tmpdir();
        mkdirSync(base, { recursive: true });
        const dir = mkdtempSync(join(base, "dsdb-repl-"));
        try {
            const code = join(dir, "built.ds");
            let out = "", err = "";
            const lines = [
                "schema Reading scope logical:", "    entity_id: String key", "    level: Float mutable", "", "",
                "rule hot:", "    Reading r where r.level > 80.0", "->", '    log info "hot {r.entity_id}"', "", "",
                'from here emit Reading entity_id: "a" level: 90.0',
                // The emit's listing is cut at the window and ends "… N more;
                // `list`": the stream's head announces every schema, the
                // built-in TimeZoneOffset among them, so the firing
                // falls past the cut. `list 40` shows the records around the
                // session's position, the firing among them.
                "list 40",
                "ls rules", `save code ${code}`, "quit"];
            const terminal = { read: async (p) => { out += p; return lines.shift() ?? null; }, write: (l) => { out += l + "\n"; } };
            const status = await main([], { stdout: (s) => { out += s; }, stderr: (s) => { err += s; }, terminal, columns: 100 });
            assert.equal(status, 0, err);
            assert.match(out, /live session on an empty program/);
            assert.match(out, /\+ schema Reading · replayed 0 inputs/);
            assert.match(out, /\+ rule hot · replayed 0 inputs/);
            assert.match(out, /RuleFireAnnotation {2}begin hot/);
            // After the prompt, `- `.
            assert.match(out, / {5}1 {2}hot {2}Reading r where r\.level > 80\.0 {2}fired 1\n/);
            const saved = readFileSync(code, "utf8");
            assert.ok(saved.indexOf("schema Reading") < saved.indexOf("rule hot"), saved);
            assert.match(saved, /^use default\n/);
        } finally {
            rmSync(dir, { recursive: true, force: true });
        }
    });

    // The path: Session.execute's `#logsCrossed` after the emit's move, the
    // `logs` result in text/session.js, and firingLine for `!:`. A move back
    // crosses nothing forward, so `@<` says no line.
    test("a rule's log line shows as the move that fires it, and `!:` names it", { skip: NO_DSC }, async () => {
        let out = "", err = "";
        const lines = [
            "schema Reading scope logical:", "    id: String key", "    level: Float mutable", "", "",
            "rule high:", "    Reading r where r.level > 80.0", "->", '    log warning "high {r.id}"', "", "",
            'from here emit Reading id: "a" level: 90.0', "!:", "@<", "quit"];
        // Each line read is marked in the output, so what each command printed can be cut out.
        const terminal = {
            read: async (/** @type {string} */ p) => { out += p; const l = lines.shift() ?? null; out += `<<${l}>>\n`; return l; },
            write: (/** @type {string} */ l) => { out += l + "\n"; },
        };
        const status = await main([], { stdout: (s) => { out += s; }, stderr: (s) => { err += s; }, terminal, columns: 100 });
        assert.equal(status, 0, err);
        const section = (/** @type {string} */ cmd) => {
            const from = out.indexOf(`<<${cmd}>>`);
            const next = out.indexOf("<<", from + cmd.length + 4);
            return out.slice(from, next < 0 ? undefined : next);
        };
        assert.match(section('from here emit Reading id: "a" level: 90.0'), /^ {2}!1 {2}0\.0s {2}WARNING {2}high a$/m,
                     "the emit says the line its firing logged");
        assert.match(section("!:"), /^ {2}1 {2}high +tt 0x1 {3}log WARNING: high a$/m, "the firing names its log");
        assert.doesNotMatch(section("!:"), /no fact or call recorded/);
        assert.doesNotMatch(section("@<"), /WARNING {2}high a/, "a move back says no line");
    });
});
