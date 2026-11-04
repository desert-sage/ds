// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// fuzz_host_values's op scripts through @ds-lang/ds.
//
//     node host_values_js.mjs PROGRAM.dsc DIR [DIR ...]
//     node host_values_js.mjs --self-test
//
// host_values_pyds.py, translated: the same scripts, read the same way, handed
// to @ds-lang/ds in JavaScript's form, so the C glue that turns JS values into
// libds's (bindings/js/src/ds.c) meets them, and held to the same
// checks. DS_JS_NATIVE names the built `.node`, as the js lane and
// the binding differential set it. Every regular file in each DIR is one
// input, in name order, one engine each, on the mock clock with the wall
// clock set.
//
// THE VALUES. A JS string is UTF-16, so the octets of `s` and `u` are decoded
// as UTF-8 the way Python's `surrogateescape` does: a well-formed sequence is
// its code point, and each octet that starts none is the lone surrogate
// U+DC00 + octet. A String slot takes only a string here. `j` is a Json
// slot's JSON TEXT, which @ds-lang/ds hands libds to parse, decoded the same
// way. id, i are BigInts, f a Number (NaN included), ok a boolean, b a
// Uint8Array. A SEED's key is decoded as `s` is, its value as `j` is. A
// WHEN's t and d are BigInts and its z decoded as `s` is; a ZONE's zone the
// same, and its three others BigInts. An IDS is `new Engine({ runId, tierId })`,
// each decoded as `s` is, which replaces the engine; refused, the engine stays.
// @ds-lang/ds refuses an id holding a lone surrogate or U+0000 with a TypeError
// (ds.c `opt_id_arg`), and that is the refusal taken for one. So is its
// TypeError for a seed's key holding U+0000 (ds.c `get_string`).
//
// WHAT IT ASSERTS, each a finding that ends the run with exit 1:
//
//   1. EVERY REFUSAL IS ONE THE BINDING DOCUMENTS: a DsError whose status
//      libds.h names for the call (an assert's, with the Json text's PARSE,
//      JSON_NONFINITE and JSON_LIMIT; a seed's), or a seed key's TypeError
//      above. Anything else, a TypeError included, is a finding: every value
//      has its slot's type.
//   2. A LONE SURROGATE IS NEVER TAKEN ([LSTR.8.5], [LSTR.1.1]). An assert
//      whose `s`, `u` or `j`, a When's `z` or a row's `zone` holds one must
//      be refused, and so must an engine whose id does ([NLFC.1.2]): a glue
//      that replaced it with U+FFFD would have changed the host's value,
//      silently.
//   3. NO HOST VALUE HALTS THE ENGINE.
//   4. WHAT LEAVES THE ENGINE IS WELL-FORMED: every log message, String call
//      argument, cache key and cache value is a well-formed string with no
//      U+0000, and every Json argument is JSON text JavaScript reads. (Text
//      @ds-lang/ds makes from libds's octets has any ill-formed sequence
//      replaced by U+FFFD already, which this cannot tell from a real one.)
//   5. A CALL IS THE ONE DECLARED: `sink.take`, its arguments sorted by
//      name, each of its kwarg's type, and no NaN.
//   6. NOTHING IS REPORTED UNCAUGHT: a handler's failure @ds-lang/ds cannot
//      throw from a call is reported so, and this driver counts each.
//
// At exit it prints its counts, as host_values_pyds.py does, which the gate
// reads (scripts/private/gate/gate.py `_binding_judged_all`).

import { readFileSync, readdirSync, statSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..", "..", "..");

const OPS = 8;
const [OP_ASSERT, OP_PUMP, OP_ADVANCE, OP_WALL, OP_SEED, OP_WHEN, OP_ZONE, OP_IDS] =
    [0, 1, 2, 3, 4, 5, 6, 7];

const ASSERT_STATUSES = new Set([-1, -104, -222, -205, -216, -710, -100, -217, -221]);
const SEED_STATUSES = new Set([-4, -222, -710, -205, -217, -100, -221]);
const ADVANCE_STATUSES = new Set([-205]);
const PUMP_STATUSES = new Set([-710]);
const NEW_STATUSES = new Set([-222]);
const ENGINE_HALTED = -10;
const WALL_NS = 1_700_000_000_000_000_000n;
const KWARGS = ["b", "f", "i", "j", "s"];

const findings = [];
const counts = { judged: 0, asserted: 0, pumped: 0, logged: 0, called: 0, cached: 0,
                 timed: 0, zoned: 0, named: 0, surrogates: 0 };

// Python's `surrogateescape`: each well-formed UTF-8 sequence its code point,
// each other octet U+DC00 + octet (RFC 3629: no overlong, no surrogate,
// nothing above U+10FFFF).
export function surrogateEscape(bytes) {
    let out = "";
    let i = 0;
    while (i < bytes.length) {
        const c = bytes[i];
        if (c < 0x80) { out += String.fromCharCode(c); i++; continue; }
        let k = 0, cp = 0;
        if (c >= 0xc2 && c <= 0xdf) { k = 1; cp = c & 0x1f; }
        else if (c >= 0xe0 && c <= 0xef) { k = 2; cp = c & 0x0f; }
        else if (c >= 0xf0 && c <= 0xf4) { k = 3; cp = c & 0x07; }
        let ok = k > 0 && i + k < bytes.length;       // the sequence fits
        for (let j = 1; ok && j <= k; j++) {
            const t = bytes[i + j];
            if ((t & 0xc0) !== 0x80) ok = false;
            else cp = (cp << 6) | (t & 0x3f);
        }
        if (ok && ((k === 2 && cp < 0x800) || (k === 3 && cp < 0x10000)
                   || (cp >= 0xd800 && cp <= 0xdfff) || cp > 0x10ffff)) ok = false;
        if (ok) { out += String.fromCodePoint(cp); i += k + 1; }
        else { out += String.fromCharCode(0xdc00 + c); i++; }
    }
    return out;
}

export function hasSurrogate(s) {
    return typeof s === "string" && !s.isWellFormed();
}

export function wellFormed(text, what) {
    if (typeof text !== "string") findings.push(`${what} is ${typeof text}, not a string`);
    else if (text.includes("\0") || !text.isWellFormed()) findings.push(`${what} is not well-formed: ${JSON.stringify(text)}`);
}

export function refused(err, statuses) {
    return err !== null && typeof err === "object" && err.name === "DsError"
        && typeof err.status === "number" && statuses.has(err.status);
}

// An engine id @ds-lang/ds refuses: libds's ENCODING, or the TypeError
// `opt_id_arg` throws for a lone surrogate or U+0000, which it never hands on.
export function idRefused(err) {
    return refused(err, NEW_STATUSES)
        || (err instanceof TypeError && /a string holding (a lone surrogate|U\+0000)/.test(err.message));
}

// A seed @ds-lang/ds refuses: a status libds.h names, or the TypeError
// `get_string` throws for a key holding U+0000, which a C string cannot carry.
export function seedRefused(err) {
    return refused(err, SEED_STATUSES)
        || (err instanceof TypeError && err.message === "a name holding U+0000");
}

class Reader {
    constructor(data) { this.data = data; this.at = 0; }
    take(n) {
        if (this.data.length - this.at < n) return null;
        const out = this.data.subarray(this.at, this.at + n);
        this.at += n;
        return out;
    }
    str() {
        const n = this.take(2);
        return n === null ? null : this.take(n[0] | (n[1] << 8));
    }
}

function onCall(req, JsonText) {
    counts.called++;
    if (req.service !== "sink.take") findings.push(`a call names a service the program does not call: ${req.service}`);
    if (!req.correlation) findings.push("a call has no correlation");
    const args = req.args ?? {};
    const names = Object.keys(args);
    if (names.join(",") !== KWARGS.join(",")) {
        findings.push(`a call's arguments are not its kwargs, sorted by name: ${names}`);
        return;
    }
    if (!(args.b instanceof Uint8Array)) findings.push("call argument b is not a Uint8Array");
    if (typeof args.f !== "number" || Number.isNaN(args.f)) findings.push(`call argument f is ${String(args.f)}`);
    if (typeof args.i !== "bigint") findings.push(`call argument i is ${typeof args.i}, not a BigInt`);
    if (!(args.j instanceof JsonText)) findings.push("call argument j is not a JsonText");
    else {
        wellFormed(args.j.text, "call argument j");
        try { JSON.parse(args.j.text); } catch { findings.push(`call argument j is not JSON text: ${args.j.text}`); }
    }
    wellFormed(args.s, "call argument s");
}

function pump(engine, halts) {
    counts.pumped++;
    try {
        engine.pump();
    } catch (err) {
        if (err?.status === ENGINE_HALTED) findings.push(`a host value halted the engine: ${JSON.stringify(halts)} ${err}`);
        else if (!(err?.name === "DsError" && PUMP_STATUSES.has(err.status)))
            findings.push(`pump threw what @ds-lang/ds does not document: ${err}`);
    }
}

// One fact, judged as an ASSERT is: a documented refusal, and a lone surrogate
// never taken. `count` is the count an accepted one adds to.
function asserted(engine, schema, slots, lone, count) {
    try {
        engine.assert(schema, slots);
    } catch (err) {
        if (!refused(err, ASSERT_STATUSES)) findings.push(`assert ${schema} threw what @ds-lang/ds does not document: ${err}`);
        if (lone) counts.surrogates++;
        return;
    }
    if (lone) findings.push(`a lone surrogate was taken by ${schema}: ${JSON.stringify(slots, (_, v) => typeof v === "bigint" ? String(v) : v)}`);
    counts[count]++;
}

// A new engine with these ids, the program loaded and set up as every input's
// is. `new api.Engine` throws for ids it refuses.
function engineUp(api, JsonText, program, halts, ids) {
    const engine = new api.Engine(ids);
    try {
        engine.loadDsc(program);
        engine.clock.mode = "mock";
        engine.clock.setWall(WALL_NS);
        engine.addEventListener("log", (ev) => { counts.logged++; wellFormed(ev.message, "a log message"); });
        engine.addEventListener("engine_error", (ev) => halts.push({ fault: ev.engineFault, rule: ev.ruleName ?? null }));
        engine.setCallCallback((req) => onCall(req, JsonText));
        engine.cache.writeThrough = {
            set: ({ key, value }) => {
                counts.cached++;
                if (key !== "s" && key !== "j") findings.push(`a rule wrote a cache key the program does not write: ${key}`);
                wellFormed(value, "a cache value");
            },
        };
    } catch (err) {
        engine.close();
        throw err;
    }
    return engine;
}

// The script's ops on `engine`, or on the engine an IDS put in its place,
// which is returned.
function run(rig, engine, data, halts) {
    const r = new Reader(data);
    const dv = (x) => new DataView(x.buffer, x.byteOffset, x.byteLength);
    for (;;) {
        const opb = r.take(1);
        if (opb === null) return engine;
        const op = opb[0] % OPS;
        if (op === OP_WHEN) {
            const fields = [r.take(1), r.take(8), r.take(8), r.str()];
            if (fields.some((x) => x === null)) return engine;
            const [fid, t, d, z] = fields;
            const slots = { id: BigInt(fid[0] % 8), t: dv(t).getBigInt64(0, true),
                            d: dv(d).getBigInt64(0, true), z: surrogateEscape(z) };
            asserted(engine, "When", slots, hasSurrogate(slots.z), "timed");
        } else if (op === OP_ZONE) {
            const fields = [r.str(), r.take(8), r.take(8), r.take(8)];
            if (fields.some((x) => x === null)) return engine;
            const [name, from, until, offset] = fields;
            const slots = { zone: surrogateEscape(name), valid_from: dv(from).getBigInt64(0, true),
                            valid_until: dv(until).getBigInt64(0, true),
                            offset_s: dv(offset).getBigInt64(0, true) };
            asserted(engine, "TimeZoneOffset", slots, hasSurrogate(slots.zone), "zoned");
        } else if (op === OP_IDS) {
            const runId = r.str();
            const tierId = runId === null ? null : r.str();
            if (tierId === null) return engine;
            const ids = { runId: surrogateEscape(runId), tierId: surrogateEscape(tierId) };
            const lone = hasSurrogate(ids.runId) || hasSurrogate(ids.tierId);
            let fresh;
            try {
                fresh = engineUp(rig.api, rig.JsonText, rig.program, halts, ids);
            } catch (err) {
                if (!idRefused(err)) findings.push(`new Engine threw what @ds-lang/ds does not document: ${err}`);
                if (lone) counts.surrogates++;
                continue;
            }
            if (lone) findings.push(`a lone surrogate was taken as an engine id: ${JSON.stringify(ids)}`);
            pump(engine, halts);
            engine.close();
            engine = fresh;
            counts.named++;
        } else if (op === OP_ASSERT) {
            const fields = [r.take(1), r.str(), r.str(), r.take(8), r.take(8), r.take(1), r.str(), r.str()];
            if (fields.some((x) => x === null)) return engine;
            const [fid, s, u, i, f, ok, b, j] = fields;
            const slots = {
                id: BigInt(fid[0] % 8), s: surrogateEscape(s), u: surrogateEscape(u),
                i: dv(i).getBigInt64(0, true), f: dv(f).getFloat64(0, true),
                ok: (ok[0] & 1) === 1, b: Uint8Array.from(b), j: surrogateEscape(j),
            };
            asserted(engine, "Host", slots,
                     hasSurrogate(slots.s) || hasSurrogate(slots.u) || hasSurrogate(slots.j), "asserted");
        } else if (op === OP_PUMP) {
            pump(engine, halts);
        } else if (op === OP_ADVANCE) {
            const us = r.take(4);
            if (us === null) return engine;
            try {
                engine.clock.advance(BigInt(new DataView(us.buffer, us.byteOffset, 4).getUint32(0, true)) * 1000n);
            } catch (err) {
                if (!refused(err, ADVANCE_STATUSES)) findings.push(`clock.advance threw what @ds-lang/ds does not document: ${err}`);
            }
        } else if (op === OP_WALL) {
            const utc = r.take(8);
            if (utc === null) return engine;
            engine.clock.setWall(new DataView(utc.buffer, utc.byteOffset, 8).getBigInt64(0, true));
        } else {
            const key = r.str();
            const val = key === null ? null : r.str();
            if (val === null) return engine;
            try {
                engine.cache.seed(surrogateEscape(key), surrogateEscape(val));
            } catch (err) {
                if (!seedRefused(err)) findings.push(`cache.seed threw what @ds-lang/ds does not document: ${err}`);
            }
        }
    }
}

function summary() {
    return `host_values_js: judged ${counts.judged} input(s): ${counts.asserted} asserted, `
        + `${counts.pumped} pumped, ${counts.logged} logged, ${counts.called} called, `
        + `${counts.cached} cached, ${counts.timed} timed, ${counts.zoned} zoned, `
        + `${counts.named} named, ${counts.surrogates} surrogates refused`;
}

function selfTest(DsError) {
    const bad = [];
    const expect = (ok, what) => { if (!ok) bad.push(what); };
    const enc = (a) => Uint8Array.from(a);
    expect(surrogateEscape(enc([0x61, 0xff])) === "a\udcff", "surrogateEscape keeps 0xff as a letter");
    expect(surrogateEscape(enc([0xc3, 0xa9])) === "é", "surrogateEscape breaks a two-octet sequence");
    expect(surrogateEscape(enc([0xf0, 0x9f, 0x98, 0x80])) === "😀", "surrogateEscape breaks a four-octet sequence");
    expect(surrogateEscape(enc([0xed, 0xa0, 0x80])) === "\udced\udca0\udc80", "surrogateEscape takes an encoded surrogate");
    expect(surrogateEscape(enc([0xc0, 0x80])) === "\udcc0\udc80", "surrogateEscape takes an overlong");
    expect(surrogateEscape(enc([0xe2, 0x82])) === "\udce2\udc82", "surrogateEscape takes a cut sequence");
    expect(hasSurrogate("a\udcff") && !hasSurrogate("é😀"), "hasSurrogate is wrong");
    const before = findings.length;
    wellFormed("ok é", "self-test");
    expect(findings.length === before, "wellFormed refuses well-formed text");
    for (const t of ["a\0b", "a\udcff", new Uint8Array(1)]) wellFormed(t, "self-test");
    expect(findings.length === before + 3, "wellFormed takes a NUL, a surrogate or bytes");
    findings.length = before;
    expect(refused(new DsError(-222, "x"), ASSERT_STATUSES), "ENCODING not taken");
    expect(!refused(new DsError(-10, "halted"), ASSERT_STATUSES), "ENGINE_HALTED taken for an assert");
    expect(!refused(new TypeError("slot"), ASSERT_STATUSES), "TypeError taken");
    expect(!refused(new DsError(-4, "state"), ASSERT_STATUSES), "STATE taken for an assert");
    expect(refused(new DsError(-4, "state"), SEED_STATUSES), "STATE not taken for a seed");
    expect(refused(new DsError(-205, "range"), ADVANCE_STATUSES), "TIME_RANGE not taken for an advance");
    expect(!refused(new DsError(-4, "state"), ADVANCE_STATUSES), "STATE taken for an advance");
    expect(idRefused(new DsError(-222, "x")), "ENCODING not taken for an id");
    expect(idRefused(new TypeError("runId: a string holding a lone surrogate")), "the glue's id TypeError not taken");
    expect(!idRefused(new TypeError("runId: want a string or null")), "an id of another type taken");
    expect(!idRefused(new DsError(-1, "x")), "INVAL taken for an id");
    expect(seedRefused(new TypeError("a name holding U+0000")), "the glue's seed key TypeError not taken");
    expect(seedRefused(new DsError(-4, "state")), "STATE not taken for a seed key");
    expect(!seedRefused(new TypeError("cache.seed: want a key and JSON text")), "a seed of another type taken");
    const rd = new Reader(enc([0x03, 0x00, 0x61, 0x62, 0x63, 0x05]));
    const s = rd.str();
    expect(s !== null && s.length === 3 && rd.take(1)?.[0] === 5 && rd.take(1) === null, "Reader reads a str operand wrong");
    return bad;
}

async function main(argv) {
    const { open, DsError, JsonText } = await import(
        pathToFileURL(join(ROOT, "bindings", "js", "lib", "index.js")).href);
    if (argv.length === 1 && argv[0] === "--self-test") {
        const bad = selfTest(DsError);
        for (const b of bad) process.stderr.write(`host_values_js: self-test: ${b}\n`);
        process.stdout.write(`host_values_js: self-test: ${bad.length ? "FAILED" : "ok"}\n`);
        return bad.length ? 1 : 0;
    }
    if (argv.length < 2) {
        process.stderr.write("usage: node host_values_js.mjs PROGRAM.dsc DIR [DIR ...]\n");
        return 2;
    }
    process.on("uncaughtException", (err) => findings.push(`uncaught: ${err}`));
    const api = await open({ target: "native" });
    const program = new Uint8Array(readFileSync(argv[0]));
    for (const dir of argv.slice(1)) {
        const names = readdirSync(dir).sort();
        for (const name of names) {
            const path = join(dir, name);
            if (!statSync(path).isFile()) continue;
            const data = new Uint8Array(readFileSync(path));
            if (data.length === 0) continue;
            counts.judged++;
            const halts = [];
            const rig = { api, JsonText, program };
            let engine = engineUp(api, JsonText, program, halts, {});
            try {
                engine = run(rig, engine, data, halts);
                pump(engine, halts);
            } finally {
                engine.close();
            }
            if (findings.length) {
                process.stderr.write(`host_values_js: ${path}: ${Buffer.from(data).toString("hex")}\n`);
                for (const f of findings) process.stderr.write(`host_values_js: ${f}\n`);
                return 1;
            }
        }
    }
    await new Promise((resolve) => process.stdout.write(summary() + "\n", resolve));
    return 0;
}

// The driver leaves on its own once its line is written, as trace_js.mjs does.
process.exit(await main(process.argv.slice(2)));
