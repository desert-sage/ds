// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The ds command, run in process against a real @ds-lang/ds engine: batch mode
// (DSDB.md §9) end to end. Runs in the js gate, which provides the engine
// (DS_JS_TARGET, DS_JS_NATIVE / DS_JS_WASM) and the compiled fixture
// (DS_JS_FIXTURES/dsdb_batch.dsc); anywhere else it is skipped, and says so.

import { test, describe, before } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { belowNodeFloor, main, parseArgs } from "../lib/cli/main.js";
import { stagingPort, target } from "../lib/cli/open.js";
import { W, recordLines } from "../lib/text/listing.js";
import { NO_COMPILER } from "./compiler.mjs";

const FIXTURES = process.env.DS_JS_FIXTURES;
const DSC = FIXTURES && join(FIXTURES, "dsdb_batch.dsc");
const NO_ENGINE = DSC && existsSync(DSC) ? false
    : "needs the js gate's engine and compiled fixtures (DS_JS_FIXTURES)";
const TARGET = process.env.DS_JS_TARGET ?? "native";

before(() => {
    process.env.DSDB_JS = fileURLToPath(new URL("../../../bindings/js/lib/index.js", import.meta.url));
});

/** Run the command with `files` written into a scratch directory; return what
    it did. `typed`, the lines a shell is given at its prompt. */
async function run(args, files = {}, typed = []) {
    // The gate names a scratch directory it has not necessarily made yet.
    const base = process.env.DS_MERCURY_SCRATCH || tmpdir();
    mkdirSync(base, { recursive: true });
    const dir = mkdtempSync(join(base, "dsdb-cli-"));
    try {
        for (const [name, text] of Object.entries(files)) {
            mkdirSync(join(dir, name, ".."), { recursive: true });
            writeFileSync(join(dir, name), text);
        }
        const argv = args.map((a) => (a in files ? join(dir, a) : a.replace(/^\$D/, dir)));
        let out = "", err = "";
        const lines = [...typed];
        const terminal = { read: async (/** @type {string} */ p) => { out += p; return lines.shift() ?? null; },
                           write: (/** @type {string} */ l) => { out += l + "\n"; } };
        const code = await main(argv, { stdout: (s) => { out += s; }, stderr: (s) => { err += s; }, terminal, columns: 100 });
        const outDir = join(dir, "out");
        const written = existsSync(outDir)
            ? Object.fromEntries(readdirSync(outDir).sort().map((f) => [f, readFileSync(join(outDir, f), "utf8")]))
            : null;
        return { code, out, err, written };
    } finally {
        rmSync(dir, { recursive: true, force: true });
    }
}

/** `ds -b -q`: no shell and no stream events. */
const batch = (args, files = {}) => run(["-b", "-q", ...args], files);

const NO_DSC_YET = NO_ENGINE || NO_COMPILER;

const READINGS = "@at,id,level\n0,a,50.0\n1_s,b,85.5\n2_s,c,95.0\n3_s,d,-1\n";

/** Three incidents paged at once, two acknowledged: for dsdb_escalate's two
    timeouts, due between the rows. */
const ESCALATE = JSON.stringify({
    Incident: [
        { "@at": "0_s", id: "db-1", summary: "Database replica lagging" },
        { "@at": "0_s", id: "web-2", summary: "Checkout returning errors" },
        { "@at": "0_s", id: "disk-3", summary: "Disk 95% full" },
    ],
    Ack: [
        { "@at": "2_min", corr: "page-db-1", responder: "sam" },
        { "@at": "8_min", corr: "page-web-2", responder: "alex" },
    ],
});

describe(`the wall clock of a run on fact files, on the ${TARGET} target`, () => {
    const WALL = () => join(FIXTURES, "dsdb_wall.dsc");

    // @spec [LTIM.2.8.3]
    test("batch: a publish fills `ts` from it, and `now()` reads it, as the row's @at", { skip: NO_ENGINE }, async () => {
        const fresh = await batch([WALL(), "Reading.jsonl"], { "Reading.jsonl": '{"@at":"10_min","id":"a"}\n' });
        assert.equal(fresh.code, 0, fresh.err);
        assert.doesNotMatch(fresh.err, /DOMAIN/);
        const doc = JSON.parse(fresh.out);
        assert.deepEqual(doc.Stamped.map((x) => [x.id, x.ts]), [["a", 600_000_000_000]]);
        assert.deepEqual(doc.Old, [], "its own @at is its ts, so it is no age");
        const old = await batch([WALL(), "Reading.jsonl"], { "Reading.jsonl": '{"@at":"10_min","id":"a","ts":0}\n' });
        assert.equal(old.code, 0, old.err);
        assert.deepEqual(JSON.parse(old.out).Old.map((x) => x.id), ["a"], "ts 0 is ten minutes old at @at");
    });

    // @spec [LTIM.2.8.3]
    test("the shell: rules, a query, a typed emit and a hypothesis all read it", { skip: NO_ENGINE }, async () => {
        const r = await run([WALL(), "Reading.jsonl"], { "Reading.jsonl": '{"@at":"10_min","id":"a","ts":0}\n' },
                            ["ls rules", "#.Reading r where now() - r.ts > 5_min", "@+1_min",
                             'from here emit Reading id: "typed"', "?.Reading r", "fork",
                             'from here emit Reading id: "hyp"', "quit"]);
        assert.equal(r.code, 0, r.err);
        assert.match(r.out, /stamp .*fired 1\n/);
        assert.match(r.out, /aged .*fired 1\n/);
        assert.match(r.out, /^- +1 at @/m, "the query's now() is the run's");
        assert.match(r.out, /id="typed" +ts=660000000000\b/, "a typed emit's ts is the session's clock, not the machine's");
        assert.doesNotMatch(r.out, /ComputationError|DOMAIN/);
    });
});

describe(`ds batch mode on the ${TARGET} target`, () => {
    // @spec [LFAC.9.2]
    test("a row with no `ts` takes its @at; one that gives `ts` keeps it", { skip: NO_ENGINE }, async () => {
        const THEN = join(FIXTURES, "dsdb_then.dsc");   // `follows`: `then ... within 3_s` compares ts
        const pairs = async (text) => {
            const r = await batch([THEN, "Reading.jsonl"], { "Reading.jsonl": text });
            assert.equal(r.code, 0, r.err);
            return JSON.parse(r.out).Pair.length;
        };
        assert.equal(await pairs('{"@at":"1_s","id":"a"}\n{"@at":"2_s","id":"a"}\n'), 1, "@at 1 s apart: within 3 s");
        assert.equal(await pairs('{"@at":"1_s","id":"a"}\n{"@at":"10_s","id":"a"}\n'), 0, "@at 9 s apart: not within 3 s");
        assert.equal(await pairs('{"@at":"1_s","id":"a","ts":0}\n{"@at":"10_s","id":"a","ts":1000000000}\n'), 1,
                     "a written ts is what is compared, whatever the @at");
    });

    // A timeout due between two rows fires at its own time, so a row at a later
    // instant that answers its call comes too late to cancel it.
    test("each engine deadline between rows and before --until is a step of its own", { skip: NO_ENGINE }, async () => {
        const r = await batch([join(FIXTURES, "dsdb_escalate.dsc"), "facts.json", "--until", "20_min"],
                              { "facts.json": ESCALATE });
        assert.equal(r.code, 0, r.err);
        assert.deepEqual(r.err.split("\n").filter((l) => /^[\d.]+s {2}(INFO|WARNING|CRITICAL) /.test(l)), [
            "120.0s  INFO  db-1: sam acknowledged",
            "300.0s  WARNING  web-2: no answer in 5 minutes, paging the backup",
            "300.0s  WARNING  disk-3: no answer in 5 minutes, paging the backup",
            "480.0s  INFO  web-2: alex acknowledged",
            "900.0s  CRITICAL  disk-3: no answer in 15 minutes, calling the manager",
        ]);
    });

    // A run ends at its last row, before what is due after it.
    test("--until moves the clock past the last row, through each deadline, and pumps once there",
         { skip: NO_ENGINE }, async () => {
        const UNTIL = join(FIXTURES, "dsdb_until.dsc");
        const files = { "Reading.jsonl": '{"@at":"2_s","id":"a","level":9.0}\n' };
        const done = (r) => JSON.parse(r.out).Done.map((x) => [x["@at"], x.why]).sort();

        const ended = await batch([UNTIL, "Reading.jsonl"], files);
        assert.equal(ended.code, 0, ended.err);
        assert.deepEqual(done(ended), [], "no timer is due at 2_s, and the row's sample is not yet absorbed");

        const after = await batch([UNTIL, "Reading.jsonl", "--until", "10_s"], files);
        assert.equal(after.code, 0, after.err);
        assert.deepEqual(done(after), [["7_s", "series"], ["7_s", "timer"]],
                         "the timer's deadline is a pump, which also reads the absorbed sample");

        const same = await batch([UNTIL, "Reading.jsonl", "--until", "2_s"], files);
        assert.equal(same.code, 0, same.err);
        assert.deepEqual(done(same), [["2_s", "series"]], "the last row's own time: one pump, no clock move");

        const early = await batch([UNTIL, "Reading.jsonl", "--until", "1_s"], files);
        assert.equal(early.code, 1);
        assert.match(early.err, /Reading\.jsonl:1: this row's `@at` is past `--until`/);
        assert.equal(early.out, "");
    });

    test("no --out: every schema as one JSON document on stdout; logs and calls on stderr", { skip: NO_ENGINE }, async () => {
        const r = await batch([DSC, "Reading.csv"], { "Reading.csv": READINGS });
        assert.equal(r.code, 0, r.err);
        const doc = JSON.parse(r.out);
        assert.deepEqual(Object.keys(doc).sort(), ["Alert", "FooReply", "Reading"]);
        assert.deepEqual(doc.Reading, [], "only published facts are written");
        assert.deepEqual(doc.Alert.map((x) => [x["@at"], x.id, x.level]), [["1_s", "b", 85.5], ["2_s", "c", 95]]);
        // An Int past 2^53 is written exactly.
        assert.match(r.out, /"big": 9007199254740993/);
        const lines = r.err.trim().split("\n");
        assert.deepEqual(lines.filter((l) => /WARNING/.test(l)), ["1.0s  WARNING  hot b", "2.0s  WARNING  hot c"]);
        // A call's arguments as batch mode writes a slot of their kind.
        assert.deepEqual(lines.filter((l) => / call /.test(l)), ['2.0s  call svc.foo as "c"  {"level":95}  by ask  (not made)']);
    });

    test("--out and --format: one file per schema, which reads back in", { skip: NO_ENGINE }, async () => {
        for (const format of ["csv", "tsv", "jsonl"]) {
            const r = await batch([DSC, "Reading.jsonl", "--out", "$D/out", "--format", format], {
                "Reading.jsonl": '{"@at":"1_s","id":"b","level":85.5}\n',
            });
            assert.equal(r.code, 0, r.err);
            assert.equal(r.out, "");
            assert.deepEqual(Object.keys(r.written), [`Alert.${format}`, `FooReply.${format}`, `Reading.${format}`]);
            // The published file is input for the next run: fed back, Alert's
            // rows arrive as Alert facts.
            const again = await batch([DSC, `Alert.${format}`], { [`Alert.${format}`]: r.written[`Alert.${format}`] });
            assert.equal(again.code, 0, again.err);
        }
    });

    test("the single-file .json is input too", { skip: NO_ENGINE }, async () => {
        const r = await batch([DSC, "in.json"], { "in.json": '{"Reading": [{"@at": "1_s", "id": "b", "level": 99.0}]}' });
        assert.equal(r.code, 0, r.err);
        assert.equal(JSON.parse(r.out).Alert.length, 1);
    });

    test("-v shows every stream event on stderr as it runs", { skip: NO_ENGINE }, async () => {
        const r = await batch([DSC, "Reading.csv", "-v"], { "Reading.csv": "id,level\nb,85.5\n" });
        assert.equal(r.code, 0, r.err);
        assert.match(r.err, /fact_assert\s+Reading#\d+  id="b"  level=85\.5/);
        assert.match(r.err, /rule_fire_begin\s+hot/);
        // A publish has no id: the fact is in no working memory ([LTIE.4.3]).
        assert.match(r.err, /action_publish\s+Alert {2}\w+=/);
        assert.doesNotMatch(r.err, /action_publish\s+Alert#/);
        const v = await batch([DSC, "Reading.csv", "-v"], { "Reading.csv": "id,level\nc,95.0\n" });
        assert.equal(v.code, 0, v.err);
        assert.match(v.err, /action_call\s+svc\.foo as "c" {2}\{"level":95\}/);
    });

    test("a bad row is exit 1 and names the file and line", { skip: NO_ENGINE }, async () => {
        const r = await batch([DSC, "Reading.csv"], { "Reading.csv": "id,level\na,hot\n" });
        assert.equal(r.code, 1);
        assert.match(r.err, /Reading\.csv:2: slot `level` \(Float\): `hot` is not a number/);
        const s = await batch([DSC, "Nope.csv"], { "Nope.csv": "x\n1\n" });
        assert.equal(s.code, 1);
        assert.match(s.err, /no schema `Nope`/);
    });

    test("an @at longer than any Duration is exit 1 and names the file and line, in batch and in the shell",
         { skip: NO_ENGINE }, async () => {
        for (const at of ["9223372036854775808", "18446744073709551616"]) {
            const files = { "Reading.csv": `@at,id,level\n${at},a,1.0\n` };
            for (const r of [await batch([DSC, "Reading.csv"], files), await run([DSC, "Reading.csv"], files, ["quit"])]) {
                assert.equal(r.code, 1, r.err);
                assert.match(r.err, new RegExp(`Reading\\.csv:2: \`@at\` \`${at}\` is longer than any Duration`));
            }
        }
    });
});

test("one command: interactive and verbose unless -b, -q, and -i, -v say so outright", () => {
    assert.deepEqual(pick(parseArgs(["p.dsc"])), [true, true]);
    assert.deepEqual(pick(parseArgs(["-i", "-v", "p.dsc"])), [true, true]);
    assert.deepEqual(pick(parseArgs(["-b", "p.dsc"])), [false, true]);
    assert.deepEqual(pick(parseArgs(["-q", "p.dsc"])), [true, false]);
    assert.deepEqual(pick(parseArgs(["-b", "-q", "p.dsc"])), [false, false]);
    // The last word wins.
    assert.deepEqual(pick(parseArgs(["-b", "-i", "-q", "-v", "p.dsc"])), [true, true]);
});

const pick = (o) => [o.interactive, o.verbose];

test("what only a run with no shell reads is refused with the shell, and taken with -b", () => {
    for (const [flag, ...more] of [["--out", "d", "--format", "csv"], ["--from", "3"], ["--calls", "s"], ["--listen", "s"],
                                   ["--calls", "s", "--pumps", "2"], ["--call-timeout", "1"]]) {
        const argv = ["p.dsc", "R.csv", flag, ...more];
        assert.throws(() => parseArgs(argv), new RegExp(`^Error: ${flag} goes with -b`), argv.join(" "));
        assert.equal(parseArgs(["-b", ...argv]).interactive, false, argv.join(" "));
    }
});

// An option the run would ignore is refused, before any file is read.
test("what a run on fact files or the listing does not read is refused, exit 2", async () => {
    for (const [args, message] of [
        [["p.dsc", "R.csv", "--from", "3"], /^ds: --from goes with a trace: /],
        [["p.dsc", "R.csv", "-f"], /^ds: -f goes with a trace: /],
        [["p.dsc", "R.csv", "--follow"], /^ds: --follow goes with a trace: /],
        [["p.dsc", "R.csv", "--call-timeout", "1"], /^ds: --call-timeout: it bounds the wait for replies, /],
        [["t.trace", "--out", "d", "--format", "csv"], /^ds: --out goes with a program and fact files: /],
        [["t.trace", "--pumps", "1"], /^ds: --pumps goes with a program and fact files: /],
        [["t.trace", "--until", "1_s"], /^ds: --until goes with a program and fact files: /],
        [["p.dsc", "R.csv", "--until", "soon"], /^ds: --until soon: a Duration from the start/],
        [["p.dsc", "R.csv", "--until", "-1_s"], /^ds: --until -1_s: a Duration from the start/],
        [["p.dsc", "R.csv", "--until", "9223372036854775808"], /^ds: --until 9223372036854775808: a Duration from the start/],
        [["t.trace", "--call-timeout", "1"], /^ds: --call-timeout goes with a program and fact files: /],
        [["p.dsc", "t.trace", "--out", "d", "--format", "tsv"], /^ds: --out goes with a program and fact files: /],
    ]) {
        const r = await batch(args);
        assert.equal(r.code, 2, args.join(" "));
        assert.match(r.err, message, args.join(" "));
    }
    // What a script gives every run stays: -q, and -L with a program that needs none.
    assert.deepEqual(parseArgs(["-b", "-q", "-L", "d", "t.trace"]).given, ["-b", "-q", "-L"]);
});

test("a refused definition names the staged file by its own name, and its directory goes with the session", async () => {
    const base = mkdtempSync(join(process.env.DS_MERCURY_SCRATCH || tmpdir(), "dsdb-staging-"));
    const before = process.env.DS_MERCURY_SCRATCH;
    process.env.DS_MERCURY_SCRATCH = base;
    try {
        const refuse = {
            compileFile: async (/** @type {string} */ path) => {
                assert.ok(path.startsWith(base), "staged under the scratch directory");
                const err = new Error(`${path}: refused by dsc\nFile "${path}", line 7, column 5`);
                err.name = "CompileRefused";
                throw err;
            },
        };
        const staging = stagingPort(refuse, []);
        await assert.rejects(staging.compileFiles(new Map([["program.ds", "use default\n"]]), "program.ds"), (err) => {
            assert.equal(err.message, 'program.ds: refused by dsc\nFile "program.ds", line 7, column 5');
            return true;
        });
        assert.equal(readdirSync(base).length, 1, "staged while the session lasts");
        staging.close();
        assert.deepEqual(readdirSync(base), [], "gone with the session, refusal or no");
    } finally {
        if (before === undefined) delete process.env.DS_MERCURY_SCRATCH;
        else process.env.DS_MERCURY_SCRATCH = before;
        rmSync(base, { recursive: true, force: true });
    }
});

test("ds serve on a port in use says so, exit 4, with no stack trace", async () => {
    const taken = createServer();
    await new Promise((resolve) => { taken.listen(0, "127.0.0.1", resolve); });
    const { port } = /** @type {import("node:net").AddressInfo} */ (taken.address());
    try {
        const r = await run(["serve", "--port", String(port)]);
        assert.equal(r.code, 4);
        assert.equal(r.err, `ds: serve: 127.0.0.1:${port} is already in use; --port names another\n`);
    } finally {
        await new Promise((resolve) => { taken.close(resolve); });
    }
});

test("--from is a seq in hex: anything else is a usage error", async () => {
    for (const bad of ["12g", "-1", "+1", "0x10", "1.5"]) {
        const r = await batch(["t.trace", "--from", bad]);
        assert.equal(r.code, 2, bad);
        assert.match(r.err, /a seq in hex, as the listing prints it/, bad);
    }
});

test("the usage names a .ds wherever a .dsc goes, and the listing's SEQ as hex", async () => {
    const { out } = await run(["-h"]);
    for (const form of ["ds [PROG.dsc | PROG.ds -L DIR...] [TRACE | FACTS...]",
                        "ds -b (PROG.dsc | PROG.ds -L DIR...) FACTS...",
                        "ds -b [PROG.dsc | PROG.ds -L DIR...] TRACE"])
        assert.ok(out.includes(form), form);
    assert.match(out, /SEQ is in hex/);
});

// A .ds and -L: compiled on the fly, then run (DSDB.md §9), by the target's
// own compiler: natively `dsc`, under wasm ds_dsc (compiler.mjs).
const NO_DSC = NO_ENGINE || NO_COMPILER;

describe(`ds with a .ds source on the ${TARGET} target`, () => {
    // pyds's test_import_search_path, the library moved out of the importer's
    // directory so only -L finds it.
    const LIB = "schema Soc scope logical:\n    chip: String key\n    sdk: String mutable\n";
    const PROG = "use default\n\nfrom board_model import Soc\n\nrule sees_it:\n    Soc s where s.sdk == \"esp-idf\"\n->\n"
               + "    log critical \"{s.chip}\"\n";
    // A fact file is named for the schema's own name ([LIMP.13.1], DSDB.md §8).
    const files = { "lib/board_model.ds": LIB, "probe.ds": PROG,
                    "board_model.Soc.csv": "chip,sdk\nesp32,esp-idf\nrp2040,pico\n" };

    test("compiled with -L, then run", { skip: NO_DSC }, async () => {
        const r = await batch(["probe.ds", "-L", "$D/lib", "board_model.Soc.csv"], files);
        assert.equal(r.code, 0, r.err);
        assert.deepEqual(r.err.trim().split("\n"), ["0.0s  CRITICAL  esp32"]);
        assert.deepEqual(Object.keys(JSON.parse(r.out)), ["board_model.Soc"]);
    });

    test("without -L the import is not found: the compiler's refusal, exit 1", { skip: NO_DSC }, async () => {
        const r = await batch(["probe.ds", "board_model.Soc.csv"], files);
        assert.equal(r.code, 1);
        assert.match(r.err, /probe\.ds: refused by dsc/);
        assert.match(r.err, /DS_/);
    });
});

describe(`ds's defaults, run for real, on the ${TARGET} target`, () => {
    test("ds runs the shell unless -b; ds -b is verbose unless -q", { skip: NO_ENGINE }, async () => {
        const files = { "Reading.csv": "id,level\nb,85.5\n" };
        const shell = await run([DSC, "Reading.csv"], files, ["quit"]);
        assert.equal(shell.code, 0, shell.err);
        assert.match(shell.out, /1 row from 1 fact file; point is at the end/);
        const loud = await run(["-b", DSC, "Reading.csv"], files);
        assert.equal(loud.code, 0, loud.err);
        assert.match(loud.err, /fact_assert/);
        const quiet = await batch([DSC, "Reading.csv"], files);
        assert.equal(quiet.code, 0, quiet.err);
        assert.doesNotMatch(quiet.err, /fact_assert/);
        assert.equal(quiet.out, loud.out, "the same run, whatever it prints on the side");
    });
});

// DSDB.md §8: fact files start a live session, a row a step, and the shell
// opens at the end with every row behind it.
describe(`the shell over fact files, on the ${TARGET} target`, () => {
    test("each row asserted at its @at and pumped; the rules fired on them; a trace beside them refused",
         { skip: NO_ENGINE }, async () => {
        const r = await run([DSC, "Reading.csv"], { "Reading.csv": READINGS }, ["ls rules", "quit"]);
        assert.equal(r.code, 0, r.err);
        assert.match(r.out, /4 rows from 1 fact file; point is at the end/);
        assert.match(r.out, /hot .*fired 2\n/, "85.5 and 95.0 are over 80");
        assert.match(r.out, /ask .*fired 1\n/, "95.0 is over 90");
        const both = await run([DSC, "Reading.csv", "run.dstrace"], { "Reading.csv": READINGS, "run.dstrace": "" });
        assert.equal(both.code, 2);
        assert.match(both.err, /fact files start a live session, and \S*run\.dstrace is a trace/);
        const bad = await run([DSC, "Reading.csv"], { "Reading.csv": "id,level\nb,hot\n" }, ["quit"]);
        assert.equal(bad.code, 1);
        assert.match(bad.err, /Reading\.csv/);
    });

    // As batch mode feeds them: a timeout due between two rows fires at its
    // own time, a step of its own, and not in the later row's pump.
    test("each engine deadline between rows is a step of its own, as batch mode's", { skip: NO_ENGINE }, async () => {
        const r = await run([join(FIXTURES, "dsdb_escalate.dsc"), "facts.json"], { "facts.json": ESCALATE },
                            ["@<", "@>", "quit"]);
        assert.equal(r.code, 0, r.err);
        assert.match(r.out, /5 rows from 1 fact file; point is at the end/);
        // The log lines crossed on the way from the start to the end: the
        // firing, the clock, the level, the message.
        const logs = r.out.split("\n").map((l) => /^ {2}!\d+ {2}(\S+) {2}\S* {2}(.*)$/.exec(l))
            .filter((m) => m !== null).map((m) => `${m[1]}  ${m[2]}`);
        assert.deepEqual(logs, [
            "120.0s  db-1: sam acknowledged",
            "300.0s  web-2: no answer in 5 minutes, paging the backup",
            "300.0s  disk-3: no answer in 5 minutes, paging the backup",
            "480.0s  web-2: alex acknowledged",
        ], r.out);
    });

    test("the shell's words: rows say what happened, a fresh session has nothing to read, a save names no errno",
         { skip: NO_ENGINE }, async () => {
        const fed = await run([DSC, "Reading.csv"], { "Reading.csv": READINGS }, ["quit"]);
        assert.doesNotMatch(fed.out, /an empty engine/, "it was given rows");
        assert.match(fed.out, /4 rows from 1 fact file/);
        const fresh = await run([DSC], {}, ["rete", "whynot hot", "save code /nonexistent/x.ds", "quit"]);
        assert.match(fresh.out, /an empty engine/);
        assert.match(fresh.out, /`rete` reads a settled point, and nothing has run yet/);
        assert.match(fresh.out, /`whynot` reads a settled point, and nothing has run yet/);
        assert.match(fresh.out, /\/nonexistent\/x\.ds: no such file or directory/);
        assert.doesNotMatch(fresh.out, /ENOENT|§/);
    });

    test("a libds refusal is named as the books name it, not by its number", { skip: NO_ENGINE }, async () => {
        const nan = await batch([DSC, "Reading.csv"], { "Reading.csv": "id,level\na,nan\n" });
        assert.equal(nan.code, 1);
        assert.match(nan.err, /Reading\.csv:2: DS_ERR_NAN_REJECTED: /);
        assert.doesNotMatch(nan.err, /ds status/);
    });

    test("a .ds that does not compile reports the file's own line numbers", { skip: NO_DSC_YET }, async () => {
        const r = await run(["brk.ds"], { "brk.ds": "use default\nrule x:\n" }, ["quit"]);
        assert.equal(r.code, 2);
        assert.match(r.err, /line 2, column/);
        assert.doesNotMatch(r.err, /query line/);
    });

    // @spec [LFAC.9.2]
    test("a row with no `ts` takes its @at, as batch's does", { skip: NO_ENGINE }, async () => {
        const THEN = join(FIXTURES, "dsdb_then.dsc");
        const fired = async (text) => {
            const r = await run([THEN, "Reading.jsonl"], { "Reading.jsonl": text }, ["ls rules", "quit"]);
            assert.equal(r.code, 0, r.err);
            return /follows .*fired (\d+)\n/.exec(r.out)?.[1];
        };
        assert.equal(await fired('{"@at":"1_s","id":"a"}\n{"@at":"2_s","id":"a"}\n'), "1", "1 s apart: within 3 s");
        assert.equal(await fired('{"@at":"1_s","id":"a"}\n{"@at":"10_s","id":"a"}\n'), "0", "9 s apart: not within 3 s");
    });

    test("the firing list names the verb the rule ran", { skip: NO_ENGINE }, async () => {
        const r = await run([DSC, "Reading.csv"], { "Reading.csv": READINGS }, ["!:", "quit"]);
        assert.equal(r.code, 0, r.err);
        // A FactPublish names no fact ([RFCS.27.1]), so the effect has no id.
        assert.match(r.out, /hot +tt \S+ +publish Alert(?![#\w])/);
        assert.doesNotMatch(r.out, /emit Alert#/);
    });

    test("a live session's first change shows what it did; `list` shows the header, its hash in hex", { skip: NO_ENGINE }, async () => {
        const EMIT = 'from here emit Reading id: "x" level: 1.0';
        const first = await run([DSC], {}, [EMIT, "quit"]);
        assert.equal(first.code, 0, first.err);
        assert.match(first.out, /FactAssert +Reading#\d+ +id="x"/);
        assert.doesNotMatch(first.out, /StreamHeader|SchemaDef|more; `list`/);
        const listed = await run([DSC], {}, [EMIT, "@<", "list 40", "quit"]);
        assert.equal(listed.code, 0, listed.err);
        assert.match(listed.out, /StreamHeader .*dsc_hash=[0-9a-f]{64}/);
        assert.doesNotMatch(listed.out, /dsc_hash=b'/);
    });

    test("what the shell prints cites nothing a user does not have", { skip: NO_ENGINE }, async () => {
        const r = await run([DSC], {}, ["help", "rule", "rules", "emit", "rete %1", "why", "quit"]);
        assert.equal(r.code, 0, r.err);
        assert.match(r.out, /queries and counts/, "help ran");
        assert.doesNotMatch(r.out + r.err, /§|DSTRACE_INTERACTIVE|DSDB\.md/);
    });

    // @spec [NTST.3.1]
    test("an @+D the clock refuses is an error for that command, and the session goes on", { skip: NO_ENGINE }, async () => {
        const files = { "Reading.csv": READINGS };
        const long = await run([DSC, "Reading.csv"], files, ["@+106752_d", "ls rules", "quit"]);
        assert.equal(long.code, 0, long.err);
        assert.match(long.out + long.err, /longer than any Duration/);
        assert.match(long.out, /hot .*fired 2\n/, "`ls rules` ran after it");
        // Each is a Duration; the second takes the wall clock, which starts at the
        // epoch, past a Time's range, 2^63 - 1 ns.
        const past = await run([DSC, "Reading.csv"], files, ["@+106751_d", "@+106751_d", "@+106751_d", "quit"]);
        assert.equal(past.code, 0, past.err);
        assert.match(past.out + past.err, /past the wall clock's Time range/);
    });
});

// Batch output is what the rules publish (DSDB.md §9), so a program
// that only emits wrote `[]` for every schema, and the run looked as if
// nothing fired. The path: core/batch.js `runBatch`'s count of emits, and
// main.js `batch`'s note.
test("a run whose rules emit and publish nothing says so on stderr; one that publishes does not", { skip: NO_DSC },
     async () => {
    const EMITS = "use default\n\nschema Reading scope logical:\n    id: String key\n    level: Float mutable\n\n"
                + "schema Hot scope logical:\n    id: String key\n\nrule hot:\n    Reading r where r.level > 80.0\n->\n"
                + "    emit Hot logical id: r.id\n";
    const r = await batch(["emits.ds", "Reading.csv"], { "emits.ds": EMITS, "Reading.csv": READINGS });
    assert.equal(r.code, 0, r.err);
    assert.deepEqual(JSON.parse(r.out), { Reading: [], Hot: [] }, "the document is as §9 has it");
    assert.match(r.err, /^ds: no rule published a fact; 2 were emitted, and an emitted fact stays on this tier: batch output is what the rules `publish`$/m);
    const p = await batch([DSC, "Reading.csv"], { "Reading.csv": READINGS });
    assert.equal(p.code, 0, p.err);
    assert.doesNotMatch(p.err, /no rule published/);
});

test("usage: --out and --format together, a known format, some files", async () => {
    assert.throws(() => parseArgs(["p.dsc", "R.csv", "--out", "d"]), /go together/);
    assert.throws(() => parseArgs(["p.dsc", "R.csv", "--out", "d", "--format", "xml"]), /csv, tsv or jsonl/);
    assert.throws(() => parseArgs(["-b"]), /no files/);
    assert.deepEqual(parseArgs([]).files, [], "the shell with no files is a live session");
    // The shell, live on a program that is not there: the file cannot be read.
    for (const argv of [["-i", "p.dsc"], ["p.dsc"]]) {
        const r = await run(argv);
        assert.equal(r.code, 4, argv.join(" "));
        assert.match(r.err, /p\.dsc/);
    }
    const u = await batch(["missing.dsc", "R.csv"], { "R.csv": "id\n" });
    assert.equal(u.code, 4);
});

test("-h and --help are the usage, asked for: stdout and 0, for every subcommand", async () => {
    for (const argv of [["-h"], ["--help"], ["test", "-h"], ["lsp", "--help"], ["mcp", "-h"], ["p.dsc", "R.csv", "-h"]]) {
        const r = await run(argv);
        assert.equal(r.code, 0, argv.join(" "));
        assert.match(r.out, /^usage: ds /, argv.join(" "));
        assert.equal(r.err, "", argv.join(" "));
    }
});

// A subcommand's help is its own, not the whole command's.
test("a subcommand's help, and its usage errors, show its own lines", async () => {
    const whole = (await run(["-h"])).out;
    for (const [sub, first] of [["test", "usage: ds test "], ["lsp", "usage: ds lsp "], ["mcp", "usage: ds mcp "],
                                ["serve", "usage: ds serve "]]) {
        const r = await run([sub, "--help"]);
        assert.ok(r.out.startsWith(first), `${sub}: ${r.out}`);
        assert.ok(r.out.length < whole.length, `${sub}'s help is not the whole usage`);
        assert.ok(!/FACTS/.test(r.out), `${sub}'s help says nothing of fact files`);
    }
    const bad = await run(["test"]);
    assert.equal(bad.code, 2);
    assert.match(bad.err, /^ds: test: give a \.ds, \.dstest or \.dsc\nusage: ds test /);
});

// libds's recorder embeds no program. Given one, a listing types each body by
// it; given none, by the stream's own announcement.
// The path: main.js's dispatch of a program and one trace to `listing`, which
// types by that program and refuses one the trace was not recorded with.
describe("the listing, given the trace's program", { skip: NO_ENGINE }, () => {
    /** @type {Buffer} */
    let trace;
    before(async () => {
        const jsBinding = await import(new URL("../../../bindings/js/lib/index.js", import.meta.url).href);
        const ds = await jsBinding.open({ target: TARGET });
        const e = new ds.Engine();
        try {
            e.loadDsc(new Uint8Array(readFileSync(/** @type {string} */ (DSC))));
            e.clock.mode = "mock";
            e.clock.set(0n);
            /** @type {Buffer[]} */
            const parts = [];
            e.recordTo((/** @type {Uint8Array} */ a) => parts.push(Buffer.from(a)));
            e.assert("Reading", { id: "a", level: 50.5 });
            e.pump();
            e.stopRecording();
            trace = Buffer.concat(parts);
        } finally {
            e.close();
        }
    });
    const prog = () => readFileSync(/** @type {string} */ (DSC));
    test("ds -b PROG.dsc TRACE, in either order, lists the facts typed", async () => {
        for (const args of [["p.dsc", "t.trace"], ["t.trace", "p.dsc"]]) {
            const r = await batch(args, { "p.dsc": prog(), "t.trace": trace });
            assert.equal(r.code, 0, `${args.join(" ")}: ${r.err}`);
            // The one line, so a failure shows it.
            const line = r.out.split("\n").find((l) => / FactAssert /.test(l)) ?? "";
            assert.match(line, /^\S+ {2}FactAssert {10}Reading#1 {2}\S/, `${args.join(" ")}: ${line}`);
            assert.match(line, / id='a'/, `${args.join(" ")}: ${line}`);   // Python's repr, as the listing writes
            assert.match(line, / level=50\.5/, `${args.join(" ")}: ${line}`);
            assert.doesNotMatch(r.out, /slots not typed/, args.join(" "));
        }
    });

    // --from reads what the listing prints.
    test("--from takes a seq as the listing prints it, and keeps atoms with none", async () => {
        /** A line's seq, or null for an atom with none. */
        const seqOf = (/** @type {string} */ l) => (/^[0-9a-f]{8}(?= )/.exec(l) ?? [null])[0];
        const lines = (/** @type {string} */ out) => out.split("\n").filter((l) => l);
        const all = lines((await batch(["t.trace"], { "t.trace": trace })).out);
        const seqs = all.map(seqOf).filter((s) => s !== null);
        assert.ok(seqs.length > 0, "the trace has atoms with a seq");
        const last = /** @type {string} */ (seqs[seqs.length - 1]);
        const r = await batch(["t.trace", "--from", last], { "t.trace": trace });
        assert.equal(r.code, 0, r.err);
        assert.deepEqual(lines(r.out), all.filter((l) => {
            const s = seqOf(l);
            return s === null || BigInt(`0x${s}`) >= BigInt(`0x${last}`);
        }));
        // A seq with a letter in it, past every atom: read as hex, not refused.
        const past = await batch(["t.trace", "--from", "ffffffff"], { "t.trace": trace });
        assert.equal(past.code, 0, past.err);
        assert.deepEqual(lines(past.out), all.filter((l) => seqOf(l) === null));
    });

    // @spec [RFCS.4.5]
    test("a program the trace was not recorded with is refused: exit 3, its code and both hashes", { skip: NO_DSC },
         async () => {
        const r = await batch(["p.ds", "t.trace"], { "p.ds": "use default\n\nschema Other scope logical:\n    k: Int key\n",
                                                  "t.trace": trace });
        assert.equal(r.code, 3, r.err);
        assert.match(r.err, /the trace was not recorded with this program \(DS_ERR_BND_DSC_MISMATCH\)\n {2}dsc_hash: trace [0-9a-f]{16}, program [0-9a-f]{16}\n/);
        assert.equal(r.out, "", "nothing listed");
    });

    // With none, the stream's own announcement types the facts.
    test("with no program, the facts are typed by the trace's own announcement", async () => {
        const r = await batch(["t.trace"], { "t.trace": trace });
        assert.equal(r.code, 0, r.err);
        const line = r.out.split("\n").find((l) => / FactAssert /.test(l)) ?? "";
        assert.match(line, /^\S+ {2}FactAssert {10}Reading#1 {2}\S/, line);
        assert.match(line, / id='a'/, line);
        assert.match(line, / level=50\.5/, line);
        assert.doesNotMatch(r.out, /slots not typed/);
    });
});

test("with -b, a program alone is not read as a trace: it says what to give", async () => {
    const r = await batch(["rules.ds"], { "rules.ds": "use default\n" });
    assert.equal(r.code, 2);
    assert.match(r.err, /^ds: \S*rules\.ds is a program: with -b, give fact files to run it \(ds -b \S*rules\.ds FACTS\.\.\.\); /);
    assert.match(r.err, /without -b it opens in the shell, and `ds test \S*rules\.ds` runs its tests\n/);
});

test("--version: this package's, then the libds and the dsc it runs on", { skip: NO_ENGINE }, async () => {
    const pkg = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
    const r = await run(["--version"]);
    assert.equal(r.code, 0, r.err);
    const [me, libds, dsc] = r.out.trim().split("\n");
    // From a checkout, whose package.json is the placeholder the
    // release stamps, the tree's own version (the repo-root VERSION).
    const tree = readFileSync(new URL("../../../VERSION", import.meta.url), "utf8").trim();
    assert.equal(me, pkg.version === "0.0.0+dev" ? `ds ${tree}+dev (a checkout)` : `ds ${pkg.version}`);
    assert.match(libds, new RegExp(`^libds \\S+ \\(@ds-lang/ds, ${TARGET}\\)$`));
    // Each target's own compiler: natively `dsc`, under wasm ds_dsc.
    if (TARGET === "wasm") assert.match(dsc, process.env.DS_JS_DSC ? /^dsc \S+ \(ds_dsc\)$/ : /^ds_dsc: not installed/);
    else if (process.env.DS_MERCURY_DSC) assert.match(dsc, /^dsc \S+$/);
    else assert.match(dsc, /^dsc: not found/);
});

test("the target dsdb opens: DS_JS_TARGET, else native where its addon is installed, else wasm", () => {
    const was = process.env.DS_JS_TARGET;
    /** @param {string | null} native @param {string | null} wasm */
    const has = (native, wasm) => ({ installed: () => ({ native, wasm, wasmCompiler: null }) });
    try {
        delete process.env.DS_JS_TARGET;
        assert.equal(target(has("/n", "/w")), "native");
        assert.equal(target(has(null, "/w")), "wasm", "a ds-tools install: the wasm build alone");
        assert.equal(target(has(null, null)), "native", "neither: the refusal then names what to install");
        process.env.DS_JS_TARGET = "wasm";
        assert.equal(target(has("/n", "/w")), "wasm", "the variable wins");
        process.env.DS_JS_TARGET = "elsewhere";
        assert.throws(() => target(has("/n", null)), /DS_JS_TARGET is "elsewhere": native or wasm/);
    } finally {
        if (was === undefined) delete process.env.DS_JS_TARGET;
        else process.env.DS_JS_TARGET = was;
    }
});

test("a binding that is not there is one sentence and exit 4, not a stack trace", async () => {
    const saved = process.env.DSDB_JS;
    process.env.DSDB_JS = "/no/such/binding/lib/index.js";
    try {
        const r = await run(["test", "x.ds"], { "x.ds": "use default\n" });
        assert.equal(r.code, 4);
        assert.match(r.err, /^ds: @ds-lang\/ds is not where DSDB_JS says \(\/no\/such\/binding\/lib\/index\.js\): /);
        assert.doesNotMatch(r.err, /\n\s+at /, "no stack trace");
        // --version still answers, and says which part is missing.
        const v = await run(["--version"]);
        assert.equal(v.code, 0);
        assert.match(v.out, /^libds: not available: @ds-lang\/ds is not where DSDB_JS says/m);
    } finally {
        if (saved === undefined) delete process.env.DSDB_JS;
        else process.env.DSDB_JS = saved;
    }
});

// An atom dsdb decodes no body for (an unknown field number, such as 259, or
// one a newer writer added) is listed by its length, and the line names no
// module the tree does not have.
test("the listing gives an atom with no decoded body its length, and names no deleted module", () => {
    const rec = { index: 0, kind: "atom 259", cls: "structural", seq: null, clockNs: 0n, ownClock: false,
                  offset: 0, body: { body_len: 12 } };
    const [seq, lines] = recordLines(/** @type {any} */ (rec));
    assert.equal(seq, null);
    assert.deepEqual(lines, [`${" ".repeat(8)}  ${"atom 259".padEnd(W)}  <12 bytes; no body decoded for this atom>`]);
});

// What the command line says when a user trips, item by item, numbered. The
// path for each: lib/cli/main.js, and for 8, 9 and
// 11 text/listing.js and text/render.js, for 10 main.js `dstest`.
describe("the command line's own words", () => {
    // The floor is package.json's, read as main reads it; this Node is at or
    // above it (the gate runs Node 20 and later), so `ds` says nothing.
    test("0: on a Node older than package.json's engines floor, ds warns and runs; at or above it, says nothing",
         async () => {
        const pkg = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
        assert.equal(pkg.engines.node, ">=20", "the floor the release's install check holds (release.build ds-tools-install)");
        assert.equal(belowNodeFloor("18.19.1", pkg.engines.node),
                     "ds: this is Node 18.19.1; ds is tested on Node 20 and later, and may fail here");
        for (const v of ["20.0.0", "22.20.0", "24.1.0"]) assert.equal(belowNodeFloor(v, pkg.engines.node), null, v);
        assert.equal(belowNodeFloor("18.19.1", undefined), null, "no floor declared: no warning");
        assert.equal(belowNodeFloor(process.versions.node, pkg.engines.node), null, "this test's own Node");
        const r = await run(["--version"]);
        assert.doesNotMatch(r.err, /is tested on Node/, r.err);
    });

    test("1: a usage error is its message and where the usage is, not the whole usage", async () => {
        for (const [argv, said] of [[["--bogus"], "no option --bogus"], [["-b", "a.dsc", "b.dsc", "c.trace"], null]]) {
            const r = await run(argv);
            assert.equal(r.code, 2, argv.join(" "));
            assert.doesNotMatch(r.err, /^usage: /m, `${argv.join(" ")}: ${r.err}`);
            assert.match(r.err, /\nrun `ds --help` for the usage\n$/, argv.join(" "));
            if (said) assert.ok(r.err.startsWith(`ds: ${said}\n`), r.err);
        }
    });

    test("2: `ds dap -h` is dap's own usage", async () => {
        const r = await run(["dap", "-h"]);
        assert.equal(r.code, 0);
        assert.ok(r.out.startsWith("usage: ds dap [-L DIR]...\n"), r.out);
    });

    test("3: a flag with no value says it needs one, in every subcommand", async () => {
        for (const sub of ["lsp", "dap", "mcp", "serve"]) {
            const r = await run([sub, "-L"]);
            assert.equal(r.code, 2, sub);
            assert.match(r.err, new RegExp(`^ds: ${sub}: -L needs a directory\\n`), `${sub}: ${r.err}`);
        }
    });

    test("4: a mistyped subcommand is named as one, with the one it is near", async () => {
        const r = await run(["tset", "hot.ds"]);
        assert.equal(r.code, 2);
        assert.match(r.err, /^ds: no command `tset`; did you mean `test`\?\n/);
    });

    test("5: a file that cannot be read says so in a sentence, not Node's error", async () => {
        const r = await batch(["nosuch.ds", "R.csv"], { "R.csv": "id\n" });
        assert.equal(r.code, 4);
        assert.equal(r.err, "ds: cannot read nosuch.ds: no such file or directory\n");
    });

    test("6: `--call-timeout 0` is taken by `ds mcp`, as by batch mode", async () => {
        let err = "";
        const dir = mkdtempSync(join(process.env.DS_MERCURY_SCRATCH || tmpdir(), "dsdb-cli-"));
        try {
            const code = await main(["mcp", "--call-timeout", "0", "--root", dir, "--out", dir],
                                    { stdout: () => {}, stderr: (s) => { err += s; }, lines: (async function* () {})() });
            assert.equal(code, 0, err);
        } finally {
            rmSync(dir, { recursive: true, force: true });
        }
    });

    describe("a trace's listing", { skip: NO_ENGINE }, () => {
        /** @type {Buffer} */
        let trace;
        before(async () => {
            const jsBinding = await import(new URL("../../../bindings/js/lib/index.js", import.meta.url).href);
            const ds = await jsBinding.open({ target: TARGET });
            const e = new ds.Engine();
            try {
                e.loadDsc(new Uint8Array(readFileSync(/** @type {string} */ (DSC))));
                e.clock.mode = "mock";
                e.clock.set(0n);
                /** @type {Buffer[]} */
                const parts = [];
                e.recordTo((/** @type {Uint8Array} */ a) => parts.push(Buffer.from(a)));
                e.assert("Reading", { id: "a", level: 50.5 });
                e.pump();
                e.stopRecording();
                trace = Buffer.concat(parts);
            } finally {
                e.close();
            }
        });

        test("8: the header's dsc_hash is hex, not a Python bytes literal", async () => {
            const r = await batch(["t.trace"], { "t.trace": trace });
            assert.equal(r.code, 0, r.err);
            assert.match(r.out, /^ {10}StreamHeader {8}dsc_hash=[0-9a-f]{64}$/m, r.out.slice(0, 300));
        });

        // @spec [RFCS.19.2]
        test("a trace ending in a partial atom lists what is whole, says where it stops, and exits 0", async () => {
            const whole = await batch(["t.trace"], { "t.trace": trace });
            assert.equal(whole.err, "", "a complete trace says nothing");
            const cut = await batch(["t.trace"], { "t.trace": trace.subarray(0, trace.length - 1) });
            assert.equal(cut.code, 0, cut.err);
            assert.match(cut.err, /t\.trace: the last \d+ bytes, from offset \d+, are a partial atom; listed to the last complete one\n$/);
            assert.ok(cut.out.length > 0 && whole.out.startsWith(cut.out), "the same listing, up to the cut");
            assert.ok(cut.out.length < whole.out.length, "with less in it");
        });

        test("11: a slot's flag names its role: key, mutable, and nothing for a slot with none", async () => {
            const r = await batch(["t.trace"], { "t.trace": trace });
            assert.equal(r.code, 0, r.err);
            assert.match(r.out, /^ {10}Slot {16}Reading\.id: STRING {2}\[key\]$/m);
            assert.match(r.out, /^ {10}Slot {16}Reading\.level: FLOAT {2}\[mutable\]$/m);
            assert.match(r.out, /^ {10}Slot {16}Reading\.raw: BYTES {2}\[mutable nullable\]$/m);
            assert.match(r.out, /^ {10}Slot {16}Alert\.id: STRING$/m, "a ttl schema's slot has no role");
        });

        test("9: the shell's listing shows the same flags", async () => {
            const r = await run(["p.dsc", "t.trace"], { "p.dsc": readFileSync(/** @type {string} */ (DSC)), "t.trace": trace },
                                ["@<", "list 60", "quit"]);
            assert.equal(r.code, 0, r.err);
            assert.match(r.out, /Reading\.id: STRING {2}\[key\]/, r.out.slice(0, 2000));
            assert.match(r.out, /Reading\.level: FLOAT {2}\[mutable\]/);
        });
    });

    test("10: `ds test` with no case run says that, not `0/0 cases passed`", { skip: NO_ENGINE }, async () => {
        const r = await run(["test", "x.dsc"], { "x.dsc": Buffer.from([0xff, 0x00, 0xff]) });
        assert.equal(r.code, 1);
        assert.equal(r.out, "ds test: no case ran\n");
    });
});
