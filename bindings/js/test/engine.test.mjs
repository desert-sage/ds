// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The @ds-lang/ds suite. ONE suite for both targets: DS_JS_TARGET picks
// the lane, and a test that passes on one and is skipped on the other is a
// defect to explain, not a result. DS_JS_FIXTURES names the directory the gate
// compiled test/fixtures/*.ds into, with the branch's own Mercury dsc.
//
// node:test and node:assert only — the suite adds no dependency to the tree.

// @spec [NFCT.1.1]
import { test, describe, before } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
    open, Cache, Clock, DsError, Engine, EngineEvent, Fact, JsonText, STREAM_EVENT_KINDS, status as S, compile,
    compileFile, CompileRefused,
} from "../lib/index.js";

const TARGET = process.env.DS_JS_TARGET ?? "native";
const FIXTURES = process.env.DS_JS_FIXTURES;
if (!FIXTURES) throw new Error("DS_JS_FIXTURES is not set — run the suite through the js gate");
const fixture = (name) => new Uint8Array(readFileSync(join(FIXTURES, `${name}.dsc`)));
const R1 = fixture("r1");
const R2 = fixture("r2");
const R2_SERIES = fixture("r2_series");
const R3 = fixture("r3");
const R4_FAULTS = fixture("r4_faults");
const TS_ENGINE = fixture("ts_engine");
const TEMPORAL = fixture("temporal");
const R5_HALTS = fixture("r5_halts");
const R6_TIME_ZONE = fixture("r6_time_zone");
const R7_REFS = fixture("r7_refs");
const R8_COOLDOWN = fixture("r8_cooldown");
const NEXT_DEADLINE = fixture("next_deadline");
const NEXT_DEADLINE_DWELL = fixture("next_deadline_dwell");

const TWO_53 = 9007199254740992n;
const INT64_MAX = 9223372036854775807n;
const SEC = 1_000_000_000n;

let ds;
before(async () => { ds = await open({ target: TARGET }); });

/** A fresh engine on the mock clock at 0, with a fixture (R1 by default) loaded. */
function engine(dsc = R1) {
    const e = new ds.Engine();
    e.clock.mode = "mock";
    e.clock.set(0n);
    e.loadDsc(dsc);
    return e;
}

/** The slots of `schema`'s live facts in engine `e`, sorted by their `id` slot. */
function slotsOf(e, schema) {
    return e.facts({ schema }).map((f) => f.read().slots).sort((p, q) => (p.id < q.id ? -1 : 1));
}

/** Add `listener` for every stream event kind: the whole stream, in `seq` order. */
function onStream(e, listener) {
    for (const kind of STREAM_EVENT_KINDS) e.addEventListener(kind, listener);
}

/**
 * Run `fn`, capturing what the platform reports from a throwing event
 * listener. Node rethrows it as uncaught on the next tick, so this waits for
 * the tick before it answers.
 */
async function capturingListenerErrors(fn) {
    const got = [];
    process.setUncaughtExceptionCaptureCallback((err) => got.push(err));
    try {
        fn();
        await new Promise((resolve) => setImmediate(resolve));
    } finally {
        process.setUncaughtExceptionCaptureCallback(null);
    }
    return got;
}

/** Run `fn` with the unraisable hook capturing into the returned list. */
function capturingUnraisable(fn) {
    const got = [];
    const prev = ds.setUnraisableHook((error, where) => got.push({ error, where }));
    try { fn(); } finally { ds.setUnraisableHook(prev); }
    return got;
}

/** The error a call throws, asserted to be a DsError with `code`. */
function dsError(fn, code) {
    let err;
    try { fn(); } catch (e) { err = e; }
    assert.ok(err instanceof DsError, `expected a DsError, got ${err}`);
    assert.equal(err.status, code, `status ${err.status} (${err.detail}), wanted ${code}`);
    assert.equal(typeof err.detail, "string");
    return err;
}

describe(`@ds-lang/ds on the ${TARGET} target`, () => {
    test("open() reports its target and refuses an unknown one", async () => {
        assert.equal(ds.target, TARGET);
        await assert.rejects(open({ target: "bogus" }), TypeError);
    });

    test("a realm loads one target: open() again is the same API, the other target is refused", async () => {
        assert.equal(await open({ target: TARGET }), ds);
        const other = TARGET === "native" ? "wasm" : "native";
        await assert.rejects(open({ target: other }), /cannot also load/);
        assert.equal(ds.Engine, Engine);
        assert.equal(ds.Fact, Fact);
        assert.equal(ds.JsonText, JsonText);
    });

    test("the loaded schemas, their slots and identity roles", () => {
        const e = engine();
        const reading = e.schemas.get("Reading");
        assert.equal(reading.name, "Reading");
        assert.equal(reading.lifecycle, "logical");
        assert.deepEqual(reading.slots.map((s) => [s.name, s.type, s.identity, s.nullable]), [
            ["id", "String", "key", false],
            ["n", "Int", "mutable", false],
            ["x", "Float", "mutable", false],
            ["ok", "Bool", "mutable", false],
        ]);
        const ping = e.schemas.get("Ping");
        assert.equal(ping.lifecycle, "ttl");
        assert.equal(ping.ttlNs, 5n * SEC);
        assert.equal(e.schemas.get("NoSuchSchema"), undefined);      // as Map.get
        assert.equal(e.schemas.has("NoSuchSchema"), false);
        // The built-in fault schemas enumerate too, and say so by lifecycle
        // (NDBG.2.2).
        assert.equal(e.schemas.get("ComputationError").lifecycle, "internal");
        assert.equal(e.schemas.get("TypeError").lifecycle, "internal");
        const names = [...e.schemas.keys()];
        for (const n of ["Reading", "Big", "Blob", "Ping"]) assert.ok(names.includes(n), n);
        assert.equal(names.length, e.schemas.size);
        for (const [name, s] of e.schemas) assert.equal(s.name, name);
        e.close();
    });

    // TAG §6.2, §6.3: one snapshot until the program changes, and nobody can
    // change it but the engine.
    test("schemas and rules are read-only maps, the same until a load", () => {
        const e = new ds.Engine();
        const empty = e.schemas;
        assert.equal(e.schemas, empty);
        assert.equal(typeof empty.set, "undefined");
        assert.equal(typeof empty.delete, "undefined");
        e.loadDsc(R1);
        const loaded = e.schemas;
        assert.notEqual(loaded, empty, "a load makes the snapshot again");
        assert.ok(loaded.has("Reading"));
        assert.ok(Object.isFrozen(loaded.get("Reading")));
        assert.ok(Object.isFrozen(loaded.get("Reading").slots[0]));
        assert.throws(() => { loaded.get("Reading").name = "x"; }, TypeError);
        const seen = [];
        loaded.forEach((s, name, map) => seen.push([name === s.name, map === loaded]));
        assert.ok(seen.length > 0 && seen.every(([a, b]) => a && b));
        assert.equal(e.rules, e.rules);
        e.close();
        dsError(() => e.schemas, S.DS_ERR_STATE);
    });

    test("64-bit exactness: 2^53+1 fires the rule, and n+1 comes back exact", () => {
        const e = engine();
        e.assert("Reading", { id: "a", n: TWO_53 + 1n, x: 1.5, ok: true });
        e.assert("Reading", { id: "b", n: INT64_MAX - 1n, x: 0.25, ok: true });
        e.assert("Reading", { id: "c", n: TWO_53, x: 0.5, ok: true });    // not past it
        e.pump();
        const big = e.facts({ schema: "Big" }).map((f) => f.read())
            .sort((p, q) => p.slots.id.localeCompare(q.slots.id));
        assert.deepEqual(big.map((f) => [f.slots.id, f.slots.n]), [
            ["a", TWO_53 + 2n],
            ["b", INT64_MAX],
        ]);
        assert.equal(typeof big[0].slots.n, "bigint");
        e.close();
    });

    test("an Int slot takes a safe Number, and refuses anything it would round", () => {
        const e = engine();
        const f = e.assert("Reading", { id: "s", n: 5, x: 0.5, ok: false });
        assert.equal(f.read().slots.n, 5n);
        assert.throws(() => e.assert("Reading", { id: "u", n: 2 ** 53, x: 0, ok: true }), TypeError);
        assert.throws(() => e.assert("Reading", { id: "f", n: 1.5, x: 0, ok: true }), TypeError);
        assert.throws(() => e.assert("Reading", { id: "o", n: 2n ** 63n, x: 0, ok: true }), TypeError);
        assert.throws(() => e.assert("Reading", { id: "o", n: -(2n ** 63n) - 1n, x: 0, ok: true }), TypeError);
        e.assert("Reading", { id: "m", n: -(2n ** 63n), x: 0, ok: false });
        assert.equal(e.factCount, 2);
        e.close();
    });

    test("Float, String and Bool round-trip exactly", () => {
        const e = engine();
        const x = 0.1 + 0.2;
        const id = "ünïcødé ✓ 🙂";
        const f = e.assert("Reading", { id, n: 1n, x, ok: true });
        const s = f.read().slots;
        assert.equal(s.x, x);
        assert.ok(Object.is(e.assert("Reading", { id: "z", n: 1n, x: -0, ok: false }).read().slots.x, -0));
        assert.equal(s.id, id);
        assert.equal(s.ok, true);
        e.close();
    });

    test("a Float slot takes a Number and refuses a BigInt, which it would convert", () => {
        // NFCT.2.3: no implicit conversion. 2n ** 53n + 1n has no double.
        const e = engine();
        for (const x of [3n, 2n ** 53n + 1n]) {
            assert.throws(() => e.assert("Reading", { id: "b", n: 1n, x, ok: true }),
                          { name: "TypeError", message: /slot `x` is Float: want a Number/ });
        }
        assert.equal(e.factCount, 0);
        e.close();
    });

    test("Json is text in and libds's canonical text out; Bytes is a copied Uint8Array", () => {
        const e = engine();
        const raw = new Uint8Array([0, 1, 2, 250, 255]);
        const f = e.assert("Blob", { id: "j", doc: '{"b": [1, 2.5, "x"], "a": null}', raw, note: "hi" });
        const s = f.read().slots;
        assert.equal(typeof s.doc, "string");
        assert.deepEqual(JSON.parse(s.doc), { a: null, b: [1, 2.5, "x"] });
        // libds's own canonical form, so a re-assert of it reads back unchanged.
        const g = e.assert("Blob", { id: "k", doc: s.doc, raw, note: "hi" });
        assert.equal(g.read().slots.doc, s.doc);
        assert.deepEqual([...s.raw], [...raw]);
        assert.equal(s.raw.constructor, Uint8Array);         // the same type on both targets
        raw[0] = 99;                                         // the engine copied
        assert.equal(f.read().slots.raw[0], 0);
        dsError(() => e.assert("Blob", { id: "bad", doc: "{not json", raw }), S.DS_ERR_PARSE);
        e.close();
    });

    // libds bounds a Json value: depth 16, 256 nodes, 16 KiB of string
    // bytes, 24 KiB of text. Each row is a limit's largest admitted text and
    // the smallest refused one.
    const JSON_LIMITS = [
        ["depth", `${"[".repeat(15)}1${"]".repeat(15)}`, `${"[".repeat(16)}1${"]".repeat(16)}`],
        ["nodes", JSON.stringify(Array(255).fill(0)), JSON.stringify(Array(256).fill(0))],
        ["string bytes", JSON.stringify("a".repeat(16384)), JSON.stringify("a".repeat(16385))],
        ["text bytes", `0${" ".repeat(24575)}`, `0${" ".repeat(24576)}`],
    ];

    test("a Json value at a limit is admitted and one past it refused with DS_ERR_JSON_LIMIT, changing nothing", () => {
        for (const [limit, at, over] of JSON_LIMITS) {
            const e = engine();
            const raw = new Uint8Array();
            e.assert("Blob", { id: "at", doc: at, raw });
            const err = dsError(() => e.assert("Blob", { id: "over", doc: over, raw }), S.DS_ERR_JSON_LIMIT);
            assert.equal(e.factCount, 1, `${limit}: the refused assert added a fact (${err.detail})`);
            e.close();

            const c = engine(R2);
            c.cache.seed("at", at);
            dsError(() => c.cache.seed("over", over), S.DS_ERR_JSON_LIMIT);
            c.close();
        }
    });

    // LSTR.1.5's host arm: a String holds no U+0000 (LSTR.1.1), and a
    // value that would carry one is refused where it enters, never cut short.
    test("a String holding U+0000 is DS_ERR_INVAL, and Json text holding one is malformed; nothing is asserted", () => {
        const e = engine();
        const raw = new Uint8Array();
        // Break: pass the C string, and libds stores "a" for "a\0b".
        dsError(() => e.assert("Blob", { id: "a\0b", doc: "{}", raw }), S.DS_ERR_INVAL);
        dsError(() => e.assert("Blob", { id: "n", doc: "{}", raw, note: "x\0" }), S.DS_ERR_INVAL);
        // Json text reaches libds's parser whole. Break: parse strlen bytes,
        // and the raw NUL cuts the text to a valid prefix.
        dsError(() => e.assert("Blob", { id: "j", doc: '{"k": "a\\u0000b"}', raw }), S.DS_ERR_PARSE);
        dsError(() => e.assert("Blob", { id: "j", doc: '"a\0b"', raw }), S.DS_ERR_PARSE);
        dsError(() => e.assert("Blob", { id: "j", doc: "{}\0garbage", raw }), S.DS_ERR_PARSE);
        assert.equal(e.factCount, 0);
        // The control: the same values without a NUL assert, and read back whole.
        const f = e.assert("Blob", { id: "ab", doc: '{"k": "ab"}', raw, note: "x" });
        assert.equal(f.read().slots.id, "ab");
        e.close();
    });

    // LSTR.8.5: text a host hands the engine is well-formed UTF-8, and
    // a JS string holding a lone surrogate has no UTF-8 form. libds refuses
    // it where it enters; it is never repaired to U+FFFD.
    test("a lone surrogate in a String, Json text or a cache seed is DS_ERR_ENCODING, and changes nothing", () => {
        const e = engine();
        const raw = new Uint8Array();
        // Break: convert with napi_get_value_string_utf8, which writes U+FFFD
        // for the surrogate, and each of these asserts.
        for (const s of ["\udcff", "a\ud800", "\ude00\ud83d", "\ud83d"]) {
            dsError(() => e.assert("Blob", { id: s, doc: "{}", raw }), S.DS_ERR_ENCODING);
            dsError(() => e.assert("Blob", { id: "n", doc: "{}", raw, note: s }), S.DS_ERR_ENCODING);
            dsError(() => e.assert("Blob", { id: "j", doc: `"${s}"`, raw }), S.DS_ERR_ENCODING);
            dsError(() => e.assert("Blob", { id: "k", doc: `{"${s}": 1}`, raw }), S.DS_ERR_ENCODING);
        }
        // libds's refusal, in NFCT.2.11's order: a NaN in a later slot is
        // step 5, before the text's step 7. Break: refuse the surrogate in
        // the glue, before the call, and this is DS_ERR_ENCODING.
        dsError(() => e.assert("Reading", { id: "\udcff", n: 1n, x: NaN, ok: true }), S.DS_ERR_NAN_REJECTED);
        assert.equal(e.factCount, 0);
        // A schema name is looked up, and no name holds a surrogate.
        dsError(() => e.assert("Blob\udcff", { id: "x", doc: "{}", raw }), S.DS_ERR_SCHEMA_UNKNOWN);
        // The control: a surrogate pair is one code point, and reads back whole.
        const pair = "a😀b";
        const f = e.assert("Blob", { id: pair, doc: `{"${pair}": "${pair}"}`, raw, note: pair });
        assert.deepEqual([f.read().slots.id, f.read().slots.note], [pair, pair]);
        assert.deepEqual(JSON.parse(f.read().slots.doc), { [pair]: pair });
        e.close();

        const c = engine(R2);
        dsError(() => c.cache.seed("\udcff", "{}"), S.DS_ERR_ENCODING);
        dsError(() => c.cache.seed("k", '"\udcff"'), S.DS_ERR_ENCODING);
        c.cache.seed(pair, `"${pair}"`);
        c.close();
    });

    // A lone surrogate has no UTF-8 form, so the glue refuses it before any
    // call: in an engine's identity, which the stream header records
    // and libds itself refuses as DS_ERR_ENCODING when its bytes are
    // ill-formed ([NLFC.1.2]), and in an announced slot's name, which
    // becomes a key of the result.
    // @spec [NLFC.1.2]
    test("an engine identity or an announced slot name holding a lone surrogate is a TypeError", () => {
        assert.throws(() => new ds.Engine({ runId: "r\udcff" }), { name: "TypeError", message: /lone surrogate/ });
        assert.throws(() => new ds.Engine({ tierId: "\ud800t" }), { name: "TypeError", message: /lone surrogate/ });
        const ok = new ds.Engine({ runId: "r😀" });
        assert.equal(ok.runId, "r😀");
        ok.close();
        assert.throws(() => ds.decodeAnnouncedFactBody([{ name: "s\udcff", kind: 1, nullable: true }], new Uint8Array()),
                      { name: "TypeError", message: /lone surrogate/ });
        assert.throws(() => ds.decodeAnnouncedFactBody([{ name: "s", kind: 6, nullable: true, schemaRef: "\udcff" }],
                                                       new Uint8Array()),
                      { name: "TypeError", message: /lone surrogate/ });
    });

    test("an announced slot's name or schemaRef holding U+0000 is a TypeError, not the text before it", () => {
        assert.throws(() => ds.decodeAnnouncedFactBody([{ name: "s\0x", kind: 1, nullable: true }], new Uint8Array()),
                      { name: "TypeError", message: /name holds U\+0000/ });
        assert.throws(() => ds.decodeAnnouncedFactBody([{ name: "s", kind: 6, nullable: true, schemaRef: "T\0x" }],
                                                       new Uint8Array()),
                      { name: "TypeError", message: /schemaRef holds U\+0000/ });
        assert.deepEqual(ds.decodeAnnouncedFactBody([{ name: "s", kind: 1, nullable: true }], new Uint8Array()),
                         { s: null }, "the same slot with no U+0000 decodes");
    });

    test("facts: a schema that is neither a name nor null is a TypeError, not every schema", () => {
        const e = engine();
        e.assert("Reading", { id: "a", n: 1n, x: 0, ok: false });
        for (const schema of [5, true, {}, 5n])
            assert.throws(() => e.facts({ schema }), { name: "TypeError", message: /want a name or null/ });
        assert.ok(e.factCount >= 1);
        assert.equal(e.facts({ schema: null }).length, e.factCount, "null is every schema");
        assert.equal(e.facts().length, e.factCount, "so is none");
        e.close();
    });

    test("slots by name: an omitted nullable slot is null; other omissions and unknown names are refused", () => {
        const e = engine();
        const f = e.assert("Blob", { id: "n", doc: "{}", raw: new Uint8Array() });
        assert.equal(f.read().slots.note, null);
        assert.throws(() => e.assert("Reading", { id: "m", n: 1n, x: 0 }), TypeError);   // ok missing
        assert.throws(() => e.assert("Reading", { id: "m", n: 1n, x: 0, ok: true, extra: 1 }), TypeError);
        assert.throws(() => e.assert("Reading", { id: "m", n: 1n, x: "0", ok: true }), TypeError);
        dsError(() => e.assert("NoSuchSchema", {}), S.DS_ERR_SCHEMA_UNKNOWN);
        e.close();
    });

    test("retract; a retracted handle is refused, not dereferenced", () => {
        const e = engine();
        const f = e.assert("Reading", { id: "r", n: 1n, x: 0, ok: false });
        const id = f.id;
        assert.equal(typeof id, "bigint");
        assert.equal(f.alive, true);
        e.retract(f);
        assert.equal(f.alive, false);
        assert.equal(f.id, id);                               // the id outlives the fact
        assert.equal(e.factCount, 0);
        dsError(() => e.retract(f), S.DS_ERR_FACT_INVALID);
        dsError(() => f.read(), S.DS_ERR_FACT_INVALID);
        e.close();
    });

    test("an upsert replaces the fact, and the replaced handle dies with it", () => {
        const e = engine();
        const old = e.assert("Reading", { id: "u", n: 1n, x: 0, ok: false });
        const now = e.assert("Reading", { id: "u", n: 2n, x: 0, ok: false });
        assert.equal(old.alive, false);
        assert.equal(now.alive, true);
        assert.notEqual(old.id, now.id);
        assert.equal(e.factCount, 1);
        dsError(() => e.retract(old), S.DS_ERR_FACT_INVALID);
        e.close();
    });

    test("TTL: the sweep retracts on the mock clock, and the handle dies by expiry", () => {
        const e = engine();
        const p = e.assert("Ping", { seq: 1n });
        e.clock.advance(4n * SEC);
        e.pump();
        assert.equal(p.alive, true);
        e.clock.advance(2n * SEC);
        e.pump();
        assert.equal(p.alive, false);
        assert.equal(e.facts({ schema: "Ping" }).length, 0);
        e.close();
    });

    // No per-fact TTL: assert takes no `{ ttlNs }` option, and the glue has
    // no assertWithTtl.
    test("assert takes a schema and slots only: a fact's TTL is its schema's", () => {
        const e = engine();
        assert.equal(e.assert.length, 2);
        e.close();
    });

    // JS_BINDING.md §3.7: one kind of fact out, and one rule for what a call takes.
    test("facts() is a snapshot of Facts; retract takes a Fact or an id", () => {
        const e = engine();
        const a = e.assert("Reading", { id: "a", n: 1n, x: 0, ok: false });
        const b = e.assert("Reading", { id: "b", n: 1n, x: 0, ok: false });
        const all = e.facts();
        assert.ok(all.length === 2 && all.every((f) => f instanceof Fact));
        assert.deepEqual(new Set(e.facts({ schema: "Reading" }).map((f) => f.id)), new Set([a.id, b.id]));
        e.retract(b.id);
        assert.equal(b.alive, false);
        assert.equal(all.length, 2, "an earlier snapshot keeps what it held");
        dsError(() => e.retract(b.id), S.DS_ERR_NOT_FOUND);
        dsError(() => e.retract(b), S.DS_ERR_FACT_INVALID);
        assert.throws(() => e.retract("a"), TypeError);
        e.retract(a);
        assert.equal(e.factCount, 0);
        assert.deepEqual(e.facts(), []);
        e.close();
    });

    test("the clock: BigInt nanoseconds; the mock setters refuse in live mode", () => {
        const e = new ds.Engine();
        assert.equal(e.clock.mode, "live");
        dsError(() => e.clock.set(0n), S.DS_ERR_STATE);
        e.clock.mode = "mock";
        e.clock.set(10n * SEC);
        e.clock.advance(1);                                  // a safe Number is accepted
        assert.equal(e.clock.now, 10n * SEC + 1n);
        assert.throws(() => { e.clock.mode = "sideways"; }, TypeError);
        e.close();
    });

    // TAG §6.2: a getter gives the same value until something changes it.
    test("an engine's clock is one live Clock, and its data are properties", () => {
        const e = engine();
        assert.ok(e.clock instanceof Clock);
        assert.equal(e.clock, e.clock);
        const { clock } = e;
        e.clock.advance(SEC);
        assert.equal(clock.now, SEC, "a Clock read earlier reads the clock as it is now");
        assert.equal(typeof e.factCount, "number");
        assert.equal(typeof e.platformSignature, "object");
        assert.equal(typeof e.sessionHeader, "object");
        e.close();
        dsError(() => clock.now, S.DS_ERR_STATE);
    });

    // [NLFC.1.2]: the engine's identity is the integrator's to give.
    // The header's session id is the run id given, "" for none; the engine mints
    // none.
    test("an engine takes a run id and a tier id, and the session header records them", () => {
        const e = new ds.Engine({ runId: "r1", tierId: "t1" });
        assert.equal(e.runId, "r1");
        assert.equal(e.tierId, "t1");
        assert.equal(e.sessionHeader.sessionId, "r1");
        assert.equal(e.sessionHeader.tierId, "t1");
        e.close();

        const none = new ds.Engine();
        assert.equal(none.runId, null);
        assert.equal(none.tierId, null);
        assert.equal(none.sessionHeader.sessionId, "");
        none.close();

        const empty = new ds.Engine({ runId: "", tierId: null });
        assert.equal(empty.runId, null, "\"\" is the same as no run id");
        empty.close();

        assert.throws(() => new ds.Engine({ runId: 7 }), TypeError);
        assert.throws(() => new ds.Engine({ tierId: "a\u0000b" }), TypeError);
    });

    // Two clocks, one sample per input or pump.
    test("a tick carries the wall sample, null until the mock wall clock is set", () => {
        const e = engine();
        const ticks = [];
        e.addEventListener("tick", (ev) => ticks.push(ev));
        e.clock.advance(SEC);
        e.pump();
        assert.ok(ticks.length > 0, "a sample that moved the clock is a tick");
        assert.equal(ticks.at(-1).wallNs, null);
        const wall = 1_760_000_000n * SEC;
        e.clock.setWall(wall);
        e.clock.advance(SEC);                                 // moves the wall clock too
        e.pump();
        assert.equal(ticks.at(-1).clockNs, 2n * SEC);
        assert.equal(ticks.at(-1).wallNs, wall + SEC);
        e.clock.setWall(-1n);                                // any instant, before the epoch included
        assert.throws(() => e.clock.setWall(2 ** 53), TypeError);
        e.close();
        const live = new ds.Engine();
        dsError(() => live.clock.setWall(0n), S.DS_ERR_STATE);
        live.close();
    });

    test("every pump is a pump event, one that fires nothing included", () => {
        const e = engine();
        const kinds = [];
        onStream(e, (ev) => kinds.push(ev.type));
        e.pump();
        e.pump();
        assert.equal(kinds.filter((k) => k === "pump").length, 2, kinds.join());
        e.close();
    });

    test("the mock clock is refused once the live clock has been sampled, a pump's sample included", () => {
        // The held sample is then the live reading, and a mock clock starting
        // at 0 would run backward ([NLFC.5.4]).
        const sampled = new ds.Engine();
        sampled.loadDsc(R1);
        sampled.pump();
        dsError(() => { sampled.clock.mode = "mock"; }, S.DS_ERR_STATE);
        assert.equal(sampled.clock.mode, "live");
        sampled.close();
        const fresh = new ds.Engine();
        fresh.loadDsc(R1);
        fresh.clock.mode = "mock";
        assert.equal(fresh.clock.mode, "mock");
        fresh.close();
    });

    test("a bad artefact is a libds status from the loader band, and spends the engine", () => {
        // A fresh engine: one that holds an artefact refuses any second load
        // with DS_ERR_STATE before reading a byte ([NFCT.1.1]), so the
        // loader's own status is seen only where nothing was loaded yet. The
        // failed load spends the engine ([RDSC.9.8]): halted with no
        // fault, every later call refused but `halted` and close.
        const e = new ds.Engine();
        const err = dsError(() => e.loadDsc(new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8])),
                            S.DS_ERR_DSC_BAD_MAGIC);
        assert.ok(err.detail.length > 0);
        assert.equal(e.halted, 0);   // DS_ENGINE_FAULT_UNSPECIFIED: no engine error
        dsError(() => e.schemas.size, S.DS_ERR_ENGINE_HALTED);
        dsError(() => e.loadDsc(R1), S.DS_ERR_ENGINE_HALTED);
        e.close();
        // Another load takes an engine of its own ([NERR.8.2]).
        const fresh = new ds.Engine();
        fresh.loadDsc(R1);
        assert.ok(fresh.schemas.size > 0);
        dsError(() => fresh.loadDsc(R1), S.DS_ERR_STATE);
        fresh.close();
    });

    test("the platform signature names this libds", () => {
        const e = new ds.Engine();
        const sig = e.platformSignature;
        for (const k of ["osFamily", "cpuArch", "libc", "compiler", "libdsVersion"])
            assert.equal(typeof sig[k], "string", k);
        const version = readFileSync(new URL("../../../VERSION", import.meta.url), "utf8").trim();
        const series = version.split(".").slice(0, 2).join(".") + ".";
        assert.ok(sig.libdsVersion.startsWith(series), `${sig.libdsVersion} vs ${series}`);
        assert.ok(Array.isArray(sig.backends));
        e.close();
    });

    test("close is idempotent, and a closed engine refuses every call", () => {
        const e = engine();
        const f = e.assert("Reading", { id: "c", n: 1n, x: 0, ok: false });
        e.close();
        e.close();
        dsError(() => e.pump(), S.DS_ERR_STATE);
        dsError(() => e.factCount, S.DS_ERR_STATE);
        assert.equal(f.alive, false);
        dsError(() => f.read(), S.DS_ERR_FACT_INVALID);
    });

    test("Symbol.dispose closes the engine", () => {
        const e = engine();
        assert.equal(typeof e[Symbol.dispose], "function");
        e[Symbol.dispose]();
        dsError(() => e.pump(), S.DS_ERR_STATE);
    });

    // A recording sink runs inside the engine's dispatch, as any
    // callback does, so freeing the engine from one is refused.
    test("close() from inside a recording sink is refused, and the engine carries on", () => {
        const e = engine();
        let err = null;
        e.recordTo(() => {
            if (err !== null) return;
            try { e.close(); } catch (x) { err = x; }
        });
        e.assert("Reading", { id: "a", n: 1n, x: 0, ok: false });
        e.pump();
        assert.ok(err instanceof DsError, `${err}`);
        assert.equal(err.status, S.DS_ERR_STATE);
        assert.equal(e.factCount, 1, "the engine was not freed");
        e.stopRecording();
        e.close();
    });

    // U+0000 would cut a name short for libds, so "Reading\0x" would find
    // Reading.
    test("a name holding U+0000 is a TypeError, not the name before it", () => {
        const e = engine();
        const name = "Reading\0x";
        assert.throws(() => e.assert(name, { id: "a", n: 1n, x: 0, ok: false }), TypeError);
        assert.throws(() => e.facts({ schema: name }), TypeError);
        assert.throws(() => e.decodeFactBody(name, new Uint8Array(0)), TypeError);
        assert.throws(() => e.cache.seed("k\0x", "1"), TypeError);
        assert.throws(() => e.refractedActivations("past_2_53\0x"), TypeError);
        assert.throws(() => { e.clock.mode = "mock\0x"; }, TypeError);
        assert.equal(e.factCount, 0);
        e.close();
    });

    test("engines are independent, and a handle is refused by another engine", () => {
        const a = engine();
        const b = engine();
        const f = a.assert("Reading", { id: "x", n: 1n, x: 0, ok: false });
        assert.equal(b.factCount, 0);
        dsError(() => b.retract(f), S.DS_ERR_FACT_INVALID);
        a.close();
        b.close();
    });

    test("status constants are libds's numbers", () => {
        assert.equal(S.DS_OK, 0);
        assert.equal(S.DS_ERR_INVAL, -1);
        assert.equal(S.STATUS.DS_ERR_FACT_INVALID, S.DS_ERR_FACT_INVALID);
        assert.ok(Object.isFrozen(S.STATUS));
    });
});

// [NLFC.2.5]: the engine reports its next deadline. In next_deadline.ds a cache
// entry falls due 10 s after its write, a `Lease` 20 s after its assert and an
// `after` timer 30 s after its firing.
describe(`@ds-lang/ds next deadline on the ${TARGET} target`, () => {
    /** Arm all three kinds at the current clock; the `Lease` fact. */
    function allThree(e) {
        e.assert("Write", { id: 1n });
        e.assert("Arm", { id: 1n });
        const lease = e.assert("Lease", { id: 1n });
        e.pump();
        return lease;
    }

    // @spec [NLFC.2.5]
    test("test_nlfc_2_5__none_when_nothing_is_due", () => {
        const e = engine(NEXT_DEADLINE);
        assert.equal(e.clock.nextDeadline, null);
        e.close();
    });

    // @spec [NLFC.2.5]
    test("test_nlfc_2_5__reports_a_timer_fire_at", () => {
        const e = engine(NEXT_DEADLINE);
        e.clock.set(100n * SEC);
        e.assert("Arm", { id: 1n });
        e.pump();
        assert.equal(e.clock.nextDeadline, 130n * SEC);
        e.close();
    });

    // @spec [NLFC.2.5]
    test("test_nlfc_2_5__reports_a_fact_ttl", () => {
        const e = engine(NEXT_DEADLINE);
        e.clock.set(5n * SEC);
        e.assert("Lease", { id: 1n });
        assert.equal(e.clock.nextDeadline, 25n * SEC);
        e.close();
    });

    // @spec [NLFC.2.5]
    test("test_nlfc_2_5__reports_a_cache_entry_expiry", () => {
        const e = engine(NEXT_DEADLINE);
        e.clock.set(7n * SEC);
        e.assert("Write", { id: 1n });
        e.pump();
        assert.equal(e.clock.nextDeadline, 17n * SEC);
        e.close();
    });

    // @spec [NLFC.2.5]
    test("test_nlfc_2_5__earliest_of_the_three_kinds", () => {
        const e = engine(NEXT_DEADLINE);
        const lease = allThree(e);
        assert.equal(e.clock.nextDeadline, 10n * SEC);
        e.assert("Drop", { id: 1n });
        e.pump();
        assert.equal(e.clock.nextDeadline, 20n * SEC);
        e.retract(lease);
        e.pump();
        assert.equal(e.clock.nextDeadline, 30n * SEC);
        e.close();
    });

    // @spec [NLFC.2.5]
    test("test_nlfc_2_5__later_than_the_clock", () => {
        const e = engine(NEXT_DEADLINE);
        allThree(e);
        e.clock.set(10n * SEC);
        assert.equal(e.clock.nextDeadline, 20n * SEC, "a deadline exactly at the clock is not reported");
        e.clock.set(25n * SEC);
        assert.equal(e.clock.nextDeadline, 30n * SEC, "and neither is one before it");
        e.close();
    });

    // @spec [NLFC.2.5]
    test("test_nlfc_2_5__a_time_dependent_condition_is_not_a_deadline", () => {
        const e = engine(NEXT_DEADLINE_DWELL);
        e.assert("Ping", { k: "a" });
        e.pump();
        assert.equal(e.clock.nextDeadline, null);
        e.close();
    });

    // @spec [NLFC.2.5]
    test("test_nlfc_2_5__takes_no_sample", () => {
        const run = (queried) => {
            const e = engine(NEXT_DEADLINE);
            const seen = [];
            onStream(e, (ev) => seen.push([ev.type, ev.seq]));
            e.clock.set(5n * SEC);
            if (queried) void e.clock.nextDeadline;
            e.clock.set(7n * SEC);
            if (queried) void e.clock.nextDeadline;
            e.assert("Write", { id: 1n });
            e.pump();
            e.close();
            return seen;
        };
        assert.deepEqual(run(true), run(false));
    });

    // @spec [NLFC.2.5]
    test("test_nlfc_2_5__refused_from_a_callback", () => {
        const e = engine(NEXT_DEADLINE);
        const refused = [];
        e.addEventListener("fact_assert", () => {
            let err;
            try { void e.clock.nextDeadline; } catch (x) { err = x; }
            refused.push(err?.status);
        });
        e.assert("Write", { id: 1n });
        e.pump();
        assert.ok(refused.length > 0, "the listener ran");
        assert.ok(refused.every((s) => s === S.DS_ERR_STATE));
        e.close();
    });
});

// The events, the handlers and the callbacks (JS_BINDING.md §3.5). The
// stream, log and metric are events: a listener that throws is reported by the
// platform and the engine carries on. A handler that throws fails the call that
// ran it, whose DsError carries the exception as its `cause`. The callbacks
// left go to the unraisable hook on a throw.
describe(`@ds-lang/ds events and callbacks on the ${TARGET} target`, () => {
    test("the stream: every event in seq order, as an EngineEvent of its kind, facts as Facts", () => {
        const e = engine();
        const events = [];
        onStream(e, (ev) => events.push(ev));
        e.assert("Reading", { id: "a", n: TWO_53 + 1n, x: 1.5, ok: true });
        e.pump();
        assert.ok(events.length > 0);
        for (let i = 1; i < events.length; i++)
            assert.ok(events[i].seq > events[i - 1].seq, "seq is strictly increasing");
        for (const ev of events) {
            assert.ok(ev instanceof EngineEvent && ev instanceof Event);
            assert.ok(STREAM_EVENT_KINDS.includes(ev.type), ev.type);
            assert.equal("kind" in ev, false, "the kind is the event's type");
            assert.equal(ev.target, e);
            assert.equal(typeof ev.seq, "bigint");
            assert.equal(typeof ev.clockNs, "bigint");
        }
        const kinds = events.map((ev) => ev.type);
        const at = (k) => kinds.indexOf(k);
        assert.ok(at("fact_assert") >= 0 && at("fact_assert") < at("rule_fire_begin"), kinds.join());
        assert.ok(at("rule_fire_begin") < at("rule_fire_end"), kinds.join());
        const first = events[at("fact_assert")];
        assert.ok(first.fact instanceof ds.Fact);
        assert.equal(first.fact.read().schema, "Reading");
        const begin = events[at("rule_fire_begin")];
        assert.equal(begin.ruleName, "past_2_53");
        assert.equal(typeof begin.timetag, "bigint");
        const lhs = events.find((ev) => ev.type === "rule_lhs_facts" && ev.ruleName === begin.ruleName);
        assert.ok(lhs, "the firing matched a live fact, so it records its LHS facts");
        assert.ok(lhs.lhsFacts.every((f) => f instanceof ds.Fact));
        // [NCBK.2.12]: the firing's timetag, the key that joins the two.
        assert.equal(lhs.timetag, begin.timetag);
        e.close();
    });

    // @spec [NCBK.2.12]
    test("each firing's rule_lhs_facts and timer_armed carry its timetag, joined by key", () => {
        const e = engine(R8_COOLDOWN);
        // A non-zero base: the cooldown table reads a last firing at 0 as
        // "never fired", so a firing at t=0 would arm nothing to observe.
        e.clock.set(SEC);
        const events = [];
        onStream(e, (ev) => events.push(ev));
        e.assert("Ping", { id: 1n });
        e.assert("Ping", { id: 2n });
        e.pump();
        const of = (type) => events.filter((ev) => ev.type === type && ev.ruleName === "echo");
        const begins = of("rule_fire_begin");
        const lhs = of("rule_lhs_facts");
        const armed = of("timer_armed");
        assert.equal(begins.length, 2, events.map((ev) => ev.type).join());
        assert.equal(lhs.length, 2, events.map((ev) => ev.type).join());
        assert.equal(armed.length, 2, events.map((ev) => ev.type).join());
        const firings = begins.map((b) => b.timetag);
        assert.ok(firings.every((t) => typeof t === "bigint" && t > 0n), String(firings));
        assert.equal(new Set(firings).size, 2, "two firings, two timetags");
        // Joined by key, so this holds whatever order the events came in.
        const sorted = (ts) => [...ts].sort((p, q) => (p < q ? -1 : p > q ? 1 : 0));
        assert.deepEqual(sorted(lhs.map((ev) => ev.timetag)), sorted(firings));
        assert.deepEqual(sorted(armed.map((ev) => ev.timetag)), sorted(firings));
        e.close();
    });

    test("a fact_retract's fact is readable in its listener and dead once the listeners return", () => {
        const e = engine();
        const f = e.assert("Reading", { id: "r", n: 1n, x: 0, ok: false });
        let seen = null;
        e.addEventListener("fact_retract", (ev) => {
            seen = { fact: ev.fact, alive: ev.fact.alive, read: ev.fact.read() };
        });
        e.retract(f);
        assert.ok(seen, "no fact_retract event");
        assert.equal(seen.alive, true);
        assert.equal(seen.read.slots.id, "r");
        assert.equal(seen.fact.id, f.id);
        assert.equal(seen.fact.alive, false);
        assert.equal(f.alive, false);
        dsError(() => seen.fact.read(), S.DS_ERR_FACT_INVALID);
        e.close();
    });

    // TAG §7.4: an EventTarget's listener that throws is reported as uncaught,
    // the listeners after it still run, and the dispatch carries on.
    test("a listener that throws is reported by the platform, not the hook, and the engine carries on", async () => {
        const e = engine();
        const boom = new Error("boom");
        let calls = 0, after = 0, hooked;
        onStream(e, () => { calls++; throw boom; });
        onStream(e, () => { after++; });
        const reported = await capturingListenerErrors(() => {
            hooked = capturingUnraisable(() => {
                e.assert("Reading", { id: "a", n: TWO_53 + 1n, x: 1.5, ok: true });
                e.pump();
            });
        });
        assert.ok(calls > 1, "later events still arrived");
        assert.equal(after, calls, "the listeners after a throwing one still ran");
        assert.equal(reported.length, calls);
        assert.ok(reported.every((x) => x === boom));
        assert.deepEqual(hooked, []);
        // The rule still fired: the throw stopped nothing.
        assert.equal(e.facts({ schema: "Big" }).length, 1);
        e.close();
    });

    test("a hook that throws is dropped, and the engine carries on", () => {
        const prev = ds.setUnraisableHook(() => { throw new Error("hook"); });
        try {
            // The call callback is the one whose throw the hook is told of.
            const e = engine(R2);
            e.setCallCallback(() => { throw new Error("call callback"); });
            e.assert("Call", { v: 1n });
            dsError(() => e.pump(), S.DS_ERR_ACTION_FAILED);
            assert.equal(e.halted, null, "a throwing callback, then a throwing hook");
            e.close();
        } finally { ds.setUnraisableHook(prev); }
    });

    test("log: level, category and message, as \"log\" events", () => {
        const e = engine(R2);
        const logs = [];
        e.addEventListener("log", (l) => logs.push(l));
        e.assert("Say", { v: 1n });
        e.pump();
        const hello = logs.filter((l) => l.message === "hello");
        assert.equal(hello.length, 1, JSON.stringify(logs));
        assert.equal(hello[0].level, "WARNING");
        assert.equal(typeof hello[0].category, "string");
        e.close();
    });

    test("a trap is a ComputationError fact a rule matches, and its stream event names the rule", () => {
        const e = engine(R4_FAULTS);
        const logs = [], faults = [];
        e.onlog = (l) => logs.push(l.message);
        e.addEventListener("computation_error", (ev) => faults.push(ev));
        e.assert("S", { entity_id: "one", a: 1n, b: 0n });
        e.pump();
        assert.deepEqual(logs, ["handled DIVIDE_BY_ZERO"]);
        const held = e.facts({ schema: "ComputationError" }).map((f) => f.read());
        assert.equal(held.length, 1, JSON.stringify(held, (k, v) => typeof v === "bigint" ? `${v}` : v));
        assert.equal(held[0].slots.rule, "divide");
        assert.equal(held[0].slots.kind, "DIVIDE_BY_ZERO");
        assert.deepEqual(faults.map((f) => f.ruleName), ["divide"]);
        // Both fault schemas are in every artefact, whatever the program declares.
        assert.ok(e.schemas.has("TypeError"));
        e.close();
    });

    // R6_TIME_ZONE's P is seen at 23:30 UTC on day 19000; its date an hour
    // ahead is day 19001, which `ahead` matches.
    const SEEN_NS = (19_000n * 86_400n + 84_600n) * SEC;
    const NEXT_DAY = 19_001n;
    const FAULT_KINDS = new Set(["computation_error", "type_error", "engine_error"]);
    const TRAP_DOMAIN = 2;                  // proto/engine_error.proto#TrapKind
    const DOMAIN = `computation_error/${TRAP_DOMAIN}`;

    // A zone's offsets are facts of the built-in TimeZoneOffset
    // ([LTIM.10.6]), each one zone's offset over [valid_from, valid_until). The
    // longest period a row can state is [INT64_MIN, INT64_MAX) ([LTIM.10.7]).
    const MIN = -(2n ** 63n), MAX = 2n ** 63n - 1n;

    /** Assert one TimeZoneOffset row; its fact. */
    function zone(e, name, offsetS, from = MIN, until = MAX) {
        return e.assert("TimeZoneOffset", { zone: name, valid_from: from, valid_until: until, offset_s: offsetS });
    }

    /** R6_TIME_ZONE with `rows` asserted, each [zone, offset_s, from, until],
        then its P: the critical log lines and each fault event as
        "kind/trapKind". A zone no row answers, whatever supplied it, is a
        DOMAIN computation_error and the engine carries on ([LTIM.10.5.3]),
        so no halt is tolerated. */
    function aheadWith(rows, e = engine(R6_TIME_ZONE)) {
        const logs = [], faults = [];
        e.addEventListener("log", (l) => { if (l.level === "CRITICAL") logs.push(l.message); });
        for (const kind of FAULT_KINDS) e.addEventListener(kind, (ev) => faults.push(`${ev.type}/${ev.trapKind}`));
        for (const [name, offsetS, from, until] of rows) zone(e, name, offsetS, from, until);
        e.assert("P", { id: 1n, seen: SEEN_NS, day: NEXT_DAY });
        e.pump();
        return { e, logs, faults };
    }

    /** Every fault is a DOMAIN computation_error, and there is one. */
    function onlyDomain(faults, what) {
        assert.ok(faults.length > 0, `${what}: a zone no row answers is a fault on the stream`);
        assert.deepEqual([...new Set(faults)], [DOMAIN], what);
    }

    test("the row's offset is the one date() uses", () => {
        const { e, logs, faults } = aheadWith([["Test/Ahead", 3600n]]);
        assert.deepEqual(logs, ["ahead"]);
        assert.deepEqual(faults, []);
        e.close();
    });

    test("an offset of zero is used too: the date stays day 19000", () => {
        const { e, logs, faults } = aheadWith([["Test/Ahead", 0n]]);
        assert.deepEqual(logs, []);
        assert.deepEqual(faults, []);
        e.close();
    });

    test("the row with the greatest valid_from not after the instant answers ([LTIM.10.7])", () => {
        const later = SEEN_NS - SEC;
        const { e, logs, faults } = aheadWith([["Test/Ahead", 3600n, later, MAX], ["Test/Ahead", 0n]]);
        assert.deepEqual(logs, ["ahead"]);
        assert.deepEqual(faults, []);
        e.close();
    });

    test("a floor row whose period has ended answers nothing, whatever an earlier row covers", () => {
        const { e, logs, faults } = aheadWith([["Test/Ahead", 3600n], ["Test/Ahead", 3600n, SEEN_NS - SEC, SEEN_NS]]);
        assert.deepEqual(logs, []);
        onlyDomain(faults, "ended");
        e.close();
    });

    // [LTIM.10.5.3]: rows for another zone only, "test/ahead" being another
    // zone byte for byte ([LTIM.10.6]).
    test("a zone no row answers faults its rule, and the engine carries on", () => {
        let run;
        const reported = capturingUnraisable(() => { run = aheadWith([["test/ahead", 3600n]]); });
        const { e, logs, faults } = run;
        onlyDomain(faults, "no row");
        assert.deepEqual(reported, []);
        assert.deepEqual(logs, [], "`ahead` took no action");
        e.assert("Q", { id: 1n });
        e.pump();
        assert.deepEqual(logs, ["later"]);
        assert.equal(e.halted, null);
        e.close();
    });

    test("a clone holds the rows, and a row retracted on the source leaves the clone's answer alone", () => {
        const e = engine(R6_TIME_ZONE);
        const row = zone(e, "Test/Ahead", 3600n);
        const shadow = e.clone();
        e.retract(row);
        assert.deepEqual(aheadWith([], e).logs, []);
        assert.deepEqual(aheadWith([], shadow).logs, ["ahead"]);
        e.close();
        shadow.close();
    });

    test("a malformed TimeZoneOffset row is DS_ERR_INVAL, and nothing is asserted ([LTIM.10.9])", () => {
        const e = engine(R6_TIME_ZONE);
        for (const [name, offsetS, from, until] of [
            ["Test/Ahead", 3600n, 10n, 10n],
            ["Test/Ahead", 3600n, 20n, 10n],
            ["Test/Ahead", 64801n, MIN, MAX],
            ["Test/Ahead", -64801n, MIN, MAX],
            ["UTC", 0n, MIN, MAX],
        ]) {
            const err = dsError(() => zone(e, name, offsetS, from, until), S.DS_ERR_INVAL);
            assert.match(err.detail, /TimeZoneOffset/);
        }
        assert.equal(e.facts().length, 0);
        zone(e, "Test/East", 64800n);
        zone(e, "Test/West", -64800n);
        assert.equal(e.facts().length, 2);
        e.close();
    });

    // A protobuf varint at `pos`: [value, next position], or null if it runs
    // off the end.
    function varint(buf, pos) {
        let value = 0;
        for (let shift = 0; pos < buf.length && shift < 64; shift += 7) {
            const b = buf[pos++];
            value += (b & 0x7f) * 2 ** shift;
            if ((b & 0x80) === 0) return [value, pos];
        }
        return null;
    }

    // Where an artefact's own `dsc_sha256` is, or null when it has none. The
    // header is walked, as specs/conformance/harness/dsc_seal.py walks it: the
    // first atom is a DscHeader (field 263, [RFCS.19.4]), and the hash is field
    // 7 of its body, 32 bytes. A search for 32 bytes could also find them
    // anywhere else they occur.
    function sha256Offset(dsc) {
        const DSC_HEADER_TAG = (263 << 3) | 2;
        if (dsc.length === 0 || dsc[0] !== 0x0a) return null;
        let step = varint(dsc, 1);                  // the outer Atom's length
        if (step === null) return null;
        step = varint(dsc, step[1]);                // the inner tag
        if (step === null || step[0] !== DSC_HEADER_TAG) return null;
        step = varint(dsc, step[1]);                // the header body's length
        if (step === null) return null;
        let [length, pos] = step;
        const end = pos + length;
        while (pos < end) {
            step = varint(dsc, pos);
            if (step === null) return null;
            const field = Math.floor(step[0] / 8);
            const wire = step[0] % 8;
            pos = step[1];
            if (wire === 2) {
                step = varint(dsc, pos);
                if (step === null) return null;
                [length, pos] = step;
                if (field === 7 && length === 32) return pos;
                pos += length;
            } else if (wire === 0) {
                step = varint(dsc, pos);
                if (step === null) return null;
                pos = step[1];
            } else if (wire === 1) pos += 8;
            else if (wire === 5) pos += 4;
            else return null;
        }
        return null;
    }

    // `dsc` sealed as the compiler seals it: the field zeroed, the whole
    // artefact hashed, the digest written in. A runtime refuses an artefact
    // whose `dsc_sha256` does not match ([RDSC.3.6]), so an edit that means to
    // test something else is resealed.
    function sealed(dsc) {
        const at = sha256Offset(dsc);
        assert.notEqual(at, null, "the artefact has no dsc_sha256 to reseal");
        const out = new Uint8Array(dsc);
        out.fill(0, at, at + 32);
        out.set(createHash("sha256").update(out).digest(), at);
        return out;
    }

    // r5_halts.dsc with slot `lied` declared String, resealed: the Slot atom's
    // `slot_name = "lied"` (field 2) then `kind = SLOT_KIND_INT` (field 3,
    // value 1) becomes SLOT_KIND_STRING (3), proto/slot.proto. One byte inside
    // one atom, so no length prefix moves; finding the bytes exactly once says
    // the edit landed. Unsealed, the load is refused for its hash before the
    // halt these tests are about. pyds's test_binding_contracts.py `_lying` is
    // the same.
    function lying(dsc) {
        const from = [0x12, 0x04, 0x6c, 0x69, 0x65, 0x64, 0x18, 0x01];
        const at = [];
        for (let i = 0; i + from.length <= dsc.length; i++)
            if (from.every((b, j) => dsc[i + j] === b)) at.push(i);
        assert.equal(at.length, 1, "the Slot atom for `lied` is not where this test expects it");
        const out = new Uint8Array(dsc);
        out[at[0] + from.length - 1] = 0x03;
        return sealed(out);
    }

    test("halted is null until an engine error halts the engine, then the fault that did", () => {
        const e = engine(lying(R5_HALTS));
        const faults = [];
        e.addEventListener("engine_error", (ev) => faults.push(ev.engineFault));
        assert.equal(e.halted, null);
        // The `where` runs as the fact joins, so the halt can surface at the
        // assert as well as at the pump.
        dsError(() => {
            e.assert("P", { id: 1n, lied: "x" });
            e.pump();
        }, S.DS_ERR_ENGINE_HALTED);
        assert.equal(faults.length, 1);
        assert.equal(e.halted, faults[0]);
        assert.notEqual(e.halted, 0);   // never UNSPECIFIED once set
        e.close();
    });

    test("halted answers with no stream listener, after the halt", () => {
        const e = engine(lying(R5_HALTS));
        dsError(() => {
            e.assert("P", { id: 1n, lied: "x" });
            e.pump();
        }, S.DS_ERR_ENGINE_HALTED);
        assert.equal(typeof e.halted, "number");
        e.close();
    });

    test("a replay that halts the engine leaves a Fact refused, never read", () => {
        const dsc = lying(R5_HALTS);
        const rec = engine(dsc);
        const chunks = [];
        rec.recordTo((b) => chunks.push(b));
        dsError(() => {
            rec.assert("P", { id: 1n, lied: "x" });
            rec.pump();
        }, S.DS_ERR_ENGINE_HALTED);
        rec.stopRecording();
        rec.close();
        const bytes = Uint8Array.from(chunks.flatMap((c) => [...c]));

        const e = engine(dsc);
        // No rule reads Doc, so this is a handle from before the halt.
        const held = e.assert("Doc", { id: 2n, doc: "{}" });
        assert.equal(e.halted, null);
        // That input is not in the recording, so the re-derived EngineError's
        // `seq` is not the recorded one: the fault atom is compared (RFCS.3.1),
        // and the replay halts the engine and reports the divergence.
        dsError(() => e.replayStream(bytes), S.DS_ERR_FS_DIVERGENCE);
        assert.equal(typeof e.halted, "number");
        dsError(() => held.read(), S.DS_ERR_ENGINE_HALTED);
        e.close();
    });

    // LSTR.8.5: JSON text a host hands the engine is judged as
    // text first -- its limit, then its encoding, then its parse -- and only
    // text that passes all three becomes the value NLFC.9.6 and NFCT.2.11
    // order. So a refusal of the text comes before a halted engine (step 1 of
    // both) and before the closed seeding window (NLFC.9.6's step 2). Each
    // engine's control is valid text, answering its state. A lone surrogate
    // crosses as ill-formed UTF-8, which libds refuses.
    const TEXT_OVER = `0${" ".repeat(24576)}`;
    const TEXT_CASES = [
        ["malformed", "{not json", S.DS_ERR_PARSE],
        ["ill-formed", '"\udcff"', S.DS_ERR_ENCODING],
        ["over the limit", TEXT_OVER, S.DS_ERR_JSON_LIMIT],
        // The text's own order: limit before encoding, encoding before parse.
        ["over the limit and ill-formed", `"\udcff"${" ".repeat(24576)}`, S.DS_ERR_JSON_LIMIT],
        ["ill-formed and malformed", "{\udcff", S.DS_ERR_ENCODING],
    ];

    function halted() {
        const e = engine(lying(R5_HALTS));
        dsError(() => {
            e.assert("P", { id: 1n, lied: "x" });
            e.pump();
        }, S.DS_ERR_ENGINE_HALTED);
        assert.notEqual(e.halted, null);
        return e;
    }

    // @spec [NLFC.9.6]
    test("a seed's text is refused for the text before a halted engine or a closed window", () => {
        const e = halted();
        dsError(() => e.cache.seed("k", "1"), S.DS_ERR_ENGINE_HALTED);   // the control
        for (const [what, text, code] of TEXT_CASES) {
            assert.doesNotThrow(() => dsError(() => e.cache.seed("k", text), code), `seed, ${what}`);
        }
        e.close();

        // Past the first stream event: the window, NLFC.9.6's step 2.
        const w = engine(R2);
        w.pump();
        dsError(() => w.cache.seed("late", "1"), S.DS_ERR_STATE);         // the control
        dsError(() => w.cache.seed("late", "{not json"), S.DS_ERR_PARSE);
        w.close();
    });

    // @spec [NFCT.2.11]
    test("a Json slot's text is refused for the text before a halted engine", () => {
        const e = halted();
        dsError(() => e.assert("Doc", { id: 1n, doc: "{}" }), S.DS_ERR_ENGINE_HALTED);   // the control
        for (const [what, text, code] of TEXT_CASES) {
            assert.doesNotThrow(() => dsError(() => e.assert("Doc", { id: 1n, doc: text }), code), `Json slot, ${what}`);
        }
        e.close();
    });

    test("call: service, correlation, arguments and the firing activation", () => {
        const e = engine(R2);
        const calls = [];
        e.setCallCallback((c) => calls.push(c));
        e.assert("Call", { v: 1n });
        e.pump();
        assert.equal(calls.length, 1);
        assert.equal(calls[0].service, "svc.foo");
        assert.equal(calls[0].correlation, "corr-1");
        assert.deepEqual(calls[0].args, {});
        assert.equal(calls[0].ruleName, "call_out");
        assert.equal(typeof calls[0].timetag, "bigint");
        e.close();
    });

    // One typed value per kwarg, as a slot of its kind reads. `setup`
    // runs on the engine before anything is asserted.
    function oneSend(setup = () => {}) {
        const e = engine(R2);
        setup(e);
        const calls = [], issued = [];
        e.setCallCallback((c) => calls.push(c));
        e.addEventListener("action_call", (ev) => issued.push(ev));
        e.assert("Send", { id: "k", n: TWO_53 + 1n, x: 2.5, ok: true,
                           raw: new Uint8Array([0, 1, 255]), doc: '{"b": "c", "a": [1, null]}' });
        e.pump();
        e.close();
        assert.equal(calls.length, 1, "one call");
        assert.equal(issued.length, 1, "one action_call event");
        return [calls[0], issued[0]];
    }

    test("call arguments: each kind as a slot of that kind reads", () => {
        const { args } = oneSend()[0];
        assert.deepEqual(Object.keys(args), ["doc", "n", "ok", "raw", "s", "sent", "x"]);
        assert.equal(args.n, TWO_53 + 1n);
        assert.equal(args.x, 2.5);
        assert.equal(args.s, "k");
        assert.equal(args.ok, true);
        assert.deepEqual([...args.raw], [0, 1, 255]);
        assert.equal(args.raw.constructor, Uint8Array);
        assert.deepEqual(JSON.parse(args.doc.text), { a: [1, null], b: "c" });
    });

    // NCBK.6.10: each argument reaches the host as the kind its value has. A
    // Json argument has no schema beside it to say so, so it is no string.
    test("a Json argument is a JsonText of libds's canonical text, and a String one a string", () => {
        const [call, ev] = oneSend();
        for (const { args } of [call, ev]) {
            assert.ok(args.doc instanceof JsonText, "doc: a JsonText");
            assert.equal(args.doc.text, '{"a":[1,null],"b":"c"}');
            assert.equal(String(args.doc), args.doc.text);
            assert.equal(`${args.doc}`, args.doc.text);
            assert.equal(typeof args.s, "string");
        }
    });

    test("a JsonText holds the text it was given, and refuses anything but a string", () => {
        const j = new JsonText("[1]");
        assert.equal(j.text, "[1]");
        assert.deepEqual(Object.keys(j), []);                    // the text is private, as Fact's handle is
        for (const bad of [undefined, null, 1, ["[1]"], { text: "[1]" }])
            assert.throws(() => new JsonText(bad), TypeError, String(bad));
    });

    test("a fact argument is its schema, when it was asserted, and its FactExternal bytes", () => {
        const { sent } = oneSend()[0].args;
        assert.deepEqual(Object.keys(sent), ["schema", "assertedAt", "external"]);
        assert.equal(sent.schema, "Send");
        assert.equal(sent.external.constructor, Uint8Array);
        assert.ok(sent.external.length > 0);
    });

    // engine() leaves the mock wall clock unset.
    test("a fact argument's assertedAt is null when the wall clock had no value, not 0 (RFCS.23.5)", () => {
        const { sent } = oneSend()[0].args;
        assert.equal(sent.assertedAt, null);
    });

    test("a fact argument's assertedAt is the wall instant it entered", () => {
        const wallNs = 1_760_000_000n * SEC;
        const { sent } = oneSend((e) => e.clock.setWall(wallNs))[0].args;
        assert.equal(sent.assertedAt, wallNs);
    });

    // NCBK.10.4: the bytes go back in, to another engine. How references
    // resolve (RFCS.23.7) is libds's and is tested there; these pin the binding.
    test("assertExternal: a fact argument, or its bytes, asserts the fact in another engine", () => {
        const { sent } = oneSend()[0].args;
        for (const data of [sent, sent.external]) {
            const rx = engine(R2);
            assert.equal(rx.assertExternal(data), undefined);
            const got = rx.facts({ schema: "Send" }).map((f) => f.read());
            assert.equal(got.length, 1);
            assert.equal(got[0].slots.id, "k");
            assert.equal(got[0].slots.n, TWO_53 + 1n);
            rx.close();
        }
    });

    test("assertExternal refuses with nothing asserted, and wants bytes or a fact argument", () => {
        const { sent } = oneSend()[0].args;
        const rx = engine(R1);                      // declares no Send
        const before = rx.factCount;
        dsError(() => rx.assertExternal(sent), S.DS_ERR_SCHEMA_UNKNOWN);
        dsError(() => rx.assertExternal(new Uint8Array([0xff, 0xff, 0xff])), S.DS_ERR_PARSE);
        assert.equal(rx.factCount, before);
        for (const bad of ["bytes", 3, null, {}])
            assert.throws(() => rx.assertExternal(bad), TypeError, String(bad));
        rx.close();
    });

    // [LCRS.3.1]: every call carries a correlation, and one with no `as` gets
    // the compiler's ([LCCO.3.4]). The binding hands it over as libds gives it.
    test("the action_call event carries what the callback receives; no `as` is the generated correlation", () => {
        const [call, ev] = oneSend();
        assert.equal(call.correlation, "$send_c0_g0");
        assert.equal(ev.correlation, "$send_c0_g0");
        assert.deepEqual(ev.args, call.args);
        assert.equal(ev.service, "svc.all");
    });

    // A typed callback that throws has failed, and libds is told, so
    // pump reports it. [IDSP.1.4]: the engine's part of the verb succeeded, so
    // action_call is in the stream before the callback runs; the callback's
    // failure is the pump's status, not the event's absence.
    test("a call callback that throws: pump throws ACTION_FAILED, after the call is streamed", () => {
        const e = engine(R2);
        const kinds = [];
        onStream(e, (ev) => kinds.push(ev.type));
        const boom = new Error("handler failed");
        e.setCallCallback(() => { kinds.push("call callback"); throw boom; });
        e.assert("Call", { v: 1n });
        const got = capturingUnraisable(() => dsError(() => e.pump(), S.DS_ERR_ACTION_FAILED));
        assert.deepEqual(got.map((g) => [g.error, g.where]), [[boom, "call"]]);
        assert.deepEqual(kinds.filter((k) => k === "action_call" || k === "call callback"),
            ["action_call", "call callback"]);
        e.close();
    });

    // [NCBK.6.9]: the event does not depend on a callback being registered.
    test("a call with no callback: pump throws STORAGE_UNAVAILABLE, and the call is still streamed", () => {
        const e = engine(R2);
        const kinds = [];
        onStream(e, (ev) => kinds.push(ev.type));
        e.assert("Call", { v: 1n });
        dsError(() => e.pump(), S.DS_ERR_STORAGE_UNAVAILABLE);
        assert.deepEqual(kinds.filter((k) => k === "action_call"), ["action_call"]);
        e.close();
    });

    test("the cache's write-through: set({ key, value, ttlNs }) and delete({ key, reason }), on its object", () => {
        const e = engine(R2);
        const sets = [], dels = [];
        const store = {
            set(write) { sets.push({ ...write, self: this === store }); },
            delete(removal) { dels.push({ ...removal, self: this === store }); },
        };
        assert.equal(e.cache.writeThrough, null);
        e.cache.writeThrough = store;
        e.assert("Cache", { v: 42n });
        e.pump();
        assert.deepEqual(sets, [{ key: "last", value: "42", ttlNs: 5n * 60n * SEC, self: true }]);
        e.assert("Uncache", { v: 1n });
        e.pump();
        assert.deepEqual(dels, [{ key: "last", reason: "delete", self: true }]);
        // Clearing it: later writes reach no handler.
        e.cache.writeThrough = null;
        assert.equal(e.cache.writeThrough, null);
        e.assert("Cache", { v: 43n });
        e.pump();
        assert.equal(sets.length, 1);
        e.close();
    });

    test("writeThrough reads back as a frozen copy, the same until it is set again", () => {
        const e = engine(R2);
        const set = () => {};
        const handlers = { set };
        e.cache.writeThrough = handlers;
        const got = e.cache.writeThrough;
        assert.ok(Object.isFrozen(got));
        assert.notEqual(got, handlers);
        assert.equal(got.set, set);
        assert.equal(got.delete, null, "one left out is null");
        assert.equal(e.cache.writeThrough, got, "the same value at every read");
        assert.equal(e.cache, e.cache, "the same Cache at every read");
        assert.ok(e.cache instanceof Cache);
        assert.throws(() => { e.cache.writeThrough = { set: "no" }; }, TypeError);
        assert.throws(() => { e.cache.writeThrough = () => {}; }, TypeError);
        assert.equal(e.cache.writeThrough, got, "a refused setting changes nothing");
        const c = e.clone();
        assert.equal(c.cache.writeThrough, null, "a clone starts with none");
        c.close();
        e.close();
    });

    // A write-through that throws has failed the write, and the pump
    // that ran it says so, with the handler's exception as the cause.
    test("a write-through handler that throws fails the pump, "
         + "its exception the DsError's cause, not the hook's", () => {
        const e = engine(R2);
        const boom = new Error("store offline");
        e.cache.writeThrough = { set() { throw boom; } };
        e.assert("Cache", { v: 42n });
        let err;
        const hooked = capturingUnraisable(() => { err = dsError(() => e.pump(), S.DS_ERR_ACTION_FAILED); });
        assert.equal(err.cause, boom);
        assert.deepEqual(hooked, []);
        // The engine carries on: a pump with no write runs clean.
        e.cache.writeThrough = null;
        e.assert("Say", { v: 1n });
        e.pump();
        e.close();
    });

    test("cache.seed before the first pump; refused after it", () => {
        const e = engine(R2);
        const sets = [];
        e.cache.writeThrough = { set: (w) => sets.push(w) };
        e.cache.seed("seeded", '{"a": 1}');
        e.cache.seed("with-ttl", "2", { ttlNs: 10n * SEC });
        assert.equal(sets.length, 0, "a seed is not a write: no write-through");
        assert.throws(() => e.cache.seed("bad", "{not json"), DsError);
        e.pump();
        dsError(() => e.cache.seed("late", "1"), S.DS_ERR_STATE);
        e.close();
    });

    // NO seriesProvisioner AND NO sampleSink: there is no samples plane. An
    // engine has neither property.
    test("no seriesProvisioner and no sampleSink: there is no samples plane", () => {
        const e = new ds.Engine();
        assert.equal("seriesProvisioner" in e, false);
        assert.equal("sampleSink" in e, false);
        e.close();
    });

    // TAG §7.5: a handler property holds one listener, replaced by the next,
    // cleared by null, and by anything that is not a function, as the
    // platform's are.
    test("onlog: set, replaced and cleared as a platform handler property", () => {
        const e = engine(R2);
        const first = [], second = [];
        e.onlog = (l) => first.push(l.message);
        e.onlog = (l) => second.push(l.message);
        assert.equal(typeof e.onlog, "function");
        e.assert("Say", { v: 1n });
        e.pump();
        assert.deepEqual(first, []);
        assert.deepEqual(second.filter((m) => m === "hello"), ["hello"]);
        const heard = second.length;
        e.onlog = null;
        assert.equal(e.onlog, null);
        e.onlog = 42;
        assert.equal(e.onlog, null);
        e.assert("Say", { v: 2n });
        e.pump();
        assert.equal(second.length, heard, "a cleared handler hears nothing");
        assert.throws(() => ds.setUnraisableHook(1), TypeError);
        e.close();
        dsError(() => e.addEventListener("log", () => {}), S.DS_ERR_STATE);
    });

    test("metric: name, kind, value and labels, as \"metric\" events, and onmetric", () => {
        const e = engine();
        const metrics = [], handled = [];
        e.addEventListener("metric", (m) => metrics.push(m));
        e.onmetric = (m) => handled.push(m);
        e.assert("Reading", { id: "a", n: 1n, x: 0, ok: false });
        e.pump();
        for (const m of metrics) {
            assert.equal(m.type, "metric");
            assert.equal(typeof m.name, "string");
            assert.ok(["counter", "gauge", "histogram"].includes(m.kind), m.kind);
            assert.equal(typeof m.value, "number");
            assert.equal(typeof m.labels, "object");
        }
        assert.deepEqual(handled, metrics);
        e.close();
    });

    test("close() from inside a listener is refused, and reported as a listener's throw", async () => {
        const e = engine();
        e.addEventListener("fact_assert", () => e.close());
        const reported = await capturingListenerErrors(() => {
            e.assert("Reading", { id: "a", n: 1n, x: 0, ok: false });
        });
        assert.ok(reported.length > 0);
        assert.ok(reported[0] instanceof DsError);
        assert.equal(reported[0].status, S.DS_ERR_STATE);
        assert.equal(e.factCount, 1, "the engine is still open");
        e.close();
    });
});

// Introspection. No registerSchema: a schema reaches the engine from a
// compiled artefact and in no other way ([NFCT.1.1]).
describe(`@ds-lang/ds introspection on the ${TARGET} target`, () => {
    test("rule metadata: every rule, by name", () => {
        const e = engine(R3);
        const names = [...e.rules.values()].map((m) => m.ruleName).sort();
        assert.deepEqual(names, ["from_a", "from_b", "too_hot"]);
        assert.deepEqual([...e.rules.keys()].sort(), names);
        assert.equal(e.rules.size, 3);
        const m = e.rules.get("too_hot");
        assert.equal(m.ruleName, "too_hot");
        for (const k of ["coolWindowNs", "debugNameTemplate"])
            assert.ok(k in m, k);
        // There is no RuleRefraction, and no key for it.
        assert.ok(!("refrKeyExpr" in m), "no refraction key");
        assert.equal(m.coolWindowNs, null, "no cooldown declared");
        if (m.srcFile !== null) {
            assert.match(m.srcFile, /r3\.ds$/);
            assert.equal(typeof m.srcLine, "number");
        }
        assert.equal(e.rules.get("no_such_rule"), undefined);
        assert.ok(Object.isFrozen(m));
        e.close();
    });

    test("justifiers: both rules that support a coalesced logical fact", () => {
        const e = engine(R3);
        const a = e.assert("A", { id: 1n });
        e.assert("B", { id: 1n });
        e.pump();
        const [l] = e.facts({ schema: "L" });
        assert.ok(l instanceof Fact, "L was derived, and facts() gives it as a Fact");
        const just = e.justifiers(l.id);
        assert.deepEqual(just.map((j) => j.ruleName).sort(), ["from_a", "from_b"]);
        for (const j of just) assert.equal(typeof j.timetag, "bigint");
        // A Fact works as well as an id; an asserted fact has no justifier.
        assert.deepEqual(e.justifiers(a), []);
        assert.deepEqual(e.justifiers(123456789n), []);
        e.close();
    });

    test("reteNetwork: nodes and edges, and a rule filter narrows it", () => {
        const e = engine(R3);
        const net = e.reteNetwork();
        const ids = new Set(net.nodes.map((n) => n.id));
        assert.equal(ids.size, net.nodes.length, "node ids are unique");
        for (const n of net.nodes) {
            assert.ok(["alpha", "beta", "terminal"].includes(n.kind), n.kind);
            assert.equal(typeof n.filter, "string");
            assert.equal(typeof n.isNegative, "boolean");
            assert.equal(n.occupancy, null, "not asked for");
        }
        for (const ed of net.edges) assert.ok(ids.has(ed.fromId) && ids.has(ed.toId));
        const terminals = (nw) => nw.nodes.filter((n) => n.kind === "terminal").map((n) => n.label).sort();
        assert.deepEqual(terminals(net), ["from_a", "from_b", "too_hot"]);
        const hot = e.reteNetwork({ ruleFilter: "too_hot" });
        assert.deepEqual(terminals(hot), ["too_hot"]);
        assert.ok(hot.nodes.length < net.nodes.length);
        assert.throws(() => e.reteNetwork({ ruleFilter: 7 }), TypeError);
        e.close();
    });

    // @spec [NDBG.3.1]
    test("lineSpans and lineSpan: each attributed node's source line, and none for an alpha", () => {
        const e = engine(R3);
        const spans = e.lineSpans;
        assert.ok(spans.length > 0, "a program with rules has line spans");
        assert.ok(Object.isFrozen(spans) && spans.every((s) => Object.isFrozen(s)));
        assert.equal(e.lineSpans, spans, "the same snapshot until the program changes");
        for (const s of spans) {
            for (const k of ["nodeId", "moduleId", "line", "column"])
                assert.ok(Number.isInteger(s[k]) && s[k] >= 0, `${k}: ${s[k]}`);
            assert.ok(s.line >= 1 && s.column >= 1, "1-based");
            assert.ok(s.file === null || typeof s.file === "string");
        }
        // Every span names a beta or a terminal, and the find on its node id
        // gives the span the enumeration gave. An alpha has none
        // (RDSC.14.3.6), so the find on one throws DS_ERR_NOT_FOUND (NDBG.7.1).
        const kindOf = new Map(e.reteNetwork().nodes.map((n) => [Number(n.id), n.kind]));
        for (const s of spans) {
            const kind = kindOf.get(s.nodeId);
            assert.ok(kind === "beta" || kind === "terminal", `span on node ${s.nodeId}, a ${kind}`);
            assert.deepEqual(e.lineSpan(s.nodeId), s, `node ${s.nodeId}`);
        }
        assert.ok(spans.some((s) => kindOf.get(s.nodeId) === "terminal"), "a rule's terminal has a span");
        const alphas = [...kindOf].filter(([, kind]) => kind === "alpha").map(([id]) => id);
        assert.ok(alphas.length > 0);
        for (const id of alphas) dsError(() => e.lineSpan(id), S.DS_ERR_NOT_FOUND);
        assert.throws(() => e.lineSpan(-1), TypeError);
        assert.throws(() => e.lineSpan(1.5), TypeError);
        e.close();
    });

    test("reteMatchTrace: a fact's path through the alpha network, pass and fail", () => {
        const e = engine(R3);
        const hot = e.assert("Temp", { room: "k", c: 35.0 });
        const cool = e.assert("Temp", { room: "b", c: 20.0 });
        const th = e.reteMatchTrace(hot);
        const tc = e.reteMatchTrace(cool.id);
        assert.ok(th.length > 0 && tc.length > 0);
        for (const s of [...th, ...tc])
            for (const k of ["nodeId", "nodeKind", "result", "detail"]) assert.equal(typeof s[k], "string", k);
        // The two facts meet the `c > 30.0` test differently.
        assert.notDeepEqual(th.map((s) => s.result), tc.map((s) => s.result));
        assert.deepEqual(e.reteMatchTrace(999999n), []);
        e.close();
    });

    test("refractedActivations: the shape, and a rule filter holds", () => {
        const e = engine(R3);
        e.assert("A", { id: 1n });
        e.assert("Temp", { room: "k", c: 35.0 });
        e.pump();
        const all = e.refractedActivations();
        assert.ok(Array.isArray(all));
        for (const r of all) {
            assert.ok(["from_a", "from_b", "too_hot"].includes(r.ruleName), r.ruleName);
            assert.equal(typeof r.reason, "string");
            assert.ok(r.factIds.every((id) => typeof id === "bigint"));
        }
        for (const r of e.refractedActivations("too_hot")) assert.equal(r.ruleName, "too_hot");
        e.close();
    });

    test("a load after the engine's first stream event is refused, and adds no schema", () => {
        // NFCT.1.1: an assert emits the first stream event, and the schema
        // set is final from then on, so a recording's prelude can name it.
        const e = engine(R1);
        const before = [...e.schemas.keys()];
        e.assert("Reading", { id: "x", n: 1n, x: 1.5, ok: true });
        dsError(() => e.loadDsc(R3), S.DS_ERR_STATE);
        assert.deepEqual([...e.schemas.keys()], before);
        assert.equal(e.factCount, 1);
        assert.equal("registerSchema" in e, false, "no host registers a schema");
        e.close();
    });

    test("a logical schema's `ts` has the engine role, outside identity and the no-op test", () => {
        const roles = (s) => s.slots.map((x) => [x.name, x.identity]);
        const e = engine(TS_ENGINE);
        assert.deepEqual(roles(e.schemas.get("Reading")), [["id", "key"], ["v", "mutable"], ["ts", "engine"]]);
        e.assert("Reading", { id: 1n, v: 7n, ts: 1_000n });
        e.assert("Reading", { id: 1n, v: 7n, ts: 2_000n });
        assert.equal(e.factCount, 1, "differing only in ts is one fact");
        e.assert("Reading", { id: 2n, v: 7n, ts: 2_000n });
        assert.equal(e.factCount, 2, "a differing key is another");
        e.close();
    });

    test("Time, Date and Duration slots keep their type and carry a BigInt", () => {
        const e = engine(TEMPORAL);
        const types = (s) => s.slots.map((x) => [x.name, x.type]);
        assert.deepEqual(types(e.schemas.get("Visit")),
                         [["id", "Int"], ["seen", "Time"], ["due", "Date"], ["span", "Duration"]]);
        // Nanoseconds since the epoch, days since the epoch, nanoseconds.
        const seen = 1_700_000_000n * SEC + 1n;
        const f = e.assert("Visit", { id: 1n, seen, due: 19_675n, span: 2n * SEC });
        assert.deepEqual(f.read().slots, { id: 1n, seen, due: 19_675n, span: 2n * SEC });
        e.assert("Visit", { id: 2n, seen, due: 19_675n, span: SEC / 2n });
        e.pump();
        assert.deepEqual(e.facts({ schema: "Long" }).map((l) => l.read().slots.id), [1n], "only the visit past 1_s");
        // A value that is no integer is refused naming the declared type.
        assert.throws(() => e.assert("Visit", { id: 3n, seen: "2026-10-11", due: 0n, span: 0n }),
                      { name: "TypeError", message: /slot `seen` is Time: want a BigInt/ });
        // Past 2^53, before the epoch, and a Number zero, each read back exact.
        const g = e.assert("Visit", { id: 4n, seen: TWO_53 + 1n, due: -1n, span: 0 });
        assert.deepEqual(g.read().slots, { id: 4n, seen: TWO_53 + 1n, due: -1n, span: 0n });
        e.close();
    });
});

// The cache's bounds. Hydration is not in v1, so there is no budget to test,
// and the working-memory bound and the pool sizes are realtime's
// ([NRTM.9.1]).
describe(`@ds-lang/ds cache bounds on the ${TARGET} target`, () => {
    test("cache.setCap: a seed past the key cap is a contract breach and changes nothing", () => {
        const e = new ds.Engine();
        e.cache.setCap({ keys: 1 });
        e.loadDsc(R2);
        e.cache.seed("a", "1");
        dsError(() => e.cache.seed("b", "2"), S.DS_ERR_CONTRACT_BREACH);
        e.cache.seed("a", "3");     // an upsert of the one key is within the cap
        e.close();
    });

    test("cache.setCap: a cap left out is unbounded", () => {
        const e = new ds.Engine();
        e.cache.setCap({ keys: 1 });
        e.cache.setCap();
        e.loadDsc(R2);
        e.cache.seed("a", "1");
        e.cache.seed("b", "2");
        e.close();
    });
});

// The compiler shim, native runner. It needs a `dsc` binary: the native lane
// has the branch's own (DS_MERCURY_DSC); the wasm lane's container has none,
// and its runner is ds_dsc (dsc-wasm.js). That is the skip's reason,
// and the only one.
const NO_DSC = process.env.DS_MERCURY_DSC ? false
    : "no dsc binary in this lane (DS_MERCURY_DSC unset); the wasm runner is ds_dsc";
const FIXTURE_DIR = fileURLToPath(new URL("./fixtures/", import.meta.url));

describe(`@ds-lang/ds compile (native runner) on the ${TARGET} target`, () => {
    test("compile() gives the bytes the gate's own dsc run gave", { skip: NO_DSC }, () => {
        // The gate compiled r1.ds from the repo root with --filename <repo path>.
        const abs = join(FIXTURE_DIR, "r1.ds");
        const file = relative(process.cwd(), abs);
        const got = compile(readFileSync(abs, "utf8"), { file });
        assert.ok(got instanceof Uint8Array);
        assert.deepEqual(got, R1);
    });

    test("a refusal is CompileRefused, with the file and the diagnostics", { skip: NO_DSC }, () => {
        let err;
        try { compile("use default\n\nschema Broken scope logical:\n    x: NoSuchType key\n", { file: "broken.ds" }); }
        catch (e) { err = e; }
        assert.ok(err instanceof CompileRefused, `${err}`);
        assert.equal(err.file, "broken.ds");
        assert.match(err.diagnostics, /DS_/);
    });

    test("a source with no use line is a library, and compile refuses it", { skip: NO_DSC }, () => {
        // [LDIA.2.10.1]: no `use` line makes a file a library, and the compiler
        // refuses to build one ([LDIA.2.10.8]).
        let err;
        try { compile("schema T scope logical:\n    k: Int key\n", { file: "lib.ds" }); }
        catch (e) { err = e; }
        assert.ok(err instanceof CompileRefused, `${err}`);
        assert.match(err.diagnostics, /DS_VALIDATE_NOT_A_PROGRAM/);
    });

    // ds.fromSource compiles with the target's own runner: on the wasm target
    // that is ds_dsc, and the wasm runner's suite tests it.
    test("fromSource loads what it compiled", {
        skip: NO_DSC || (TARGET === "wasm" && "on the wasm target, fromSource is the wasm runner's"),
    }, () => {
        const e = ds.fromSource("use default\n\nschema T scope logical:\n    k: Int key\n", { file: "t.ds" });
        e.assert("T", { k: 1n });
        assert.equal(e.factCount, 1);
        e.close();
        assert.throws(() => ds.fromSource("rule r:\n", { file: "bad.ds" }), CompileRefused);
    });

    test("no binary is an Error, not a refusal", () => {
        const saved = process.env.DS_MERCURY_DSC;
        process.env.DS_MERCURY_DSC = "/nonexistent/ds-js-test-dsc";
        try {
            let err;
            try { compile("schema T scope logical:\n    k: Int key\n"); } catch (e) { err = e; }
            assert.ok(err instanceof Error && !(err instanceof CompileRefused), `${err}`);
            assert.match(err.message, /no dsc binary/);
        } finally {
            if (saved === undefined) delete process.env.DS_MERCURY_DSC;
            else process.env.DS_MERCURY_DSC = saved;
        }
    });
});

// The compiler shim, wasm runner: under Node the wasm target compiles
// with ds_dsc, which the js-wasm lane gives as DS_JS_DSC.
const NO_WASM_DSC = TARGET === "wasm" && process.env.DS_JS_DSC ? false
    : "the wasm runner: ds_dsc (DS_JS_DSC) on the wasm target, in the js-wasm lane";

describe(`@ds-lang/ds compile (wasm runner) on the ${TARGET} target`, { skip: NO_WASM_DSC }, () => {
    test("compile() gives a program the engine loads; a refusal is CompileRefused", async () => {
        const dsc = await ds.compile("use default\n\nschema T scope logical:\n    k: Int key\n", { file: "t.ds" });
        const e = engine(dsc);
        e.assert("T", { k: 1n });
        assert.equal(e.factCount, 1);
        e.close();
        await assert.rejects(ds.compile("use default\n\nschema Broken scope logical:\n    x: NoSuchType key\n",
                                        { file: "broken.ds" }),
                             (err) => err instanceof CompileRefused && err.file === "broken.ds" && /DS_/.test(err.diagnostics));
    });

    test("fromSource gives a Promise of an Engine with what it compiled loaded", async () => {
        const e = await ds.fromSource("use default\n\nschema T scope logical:\n    k: Int key\n", { file: "t.ds" });
        e.assert("T", { k: 1n });
        assert.equal(e.factCount, 1);
        e.close();
        await assert.rejects(ds.fromSource("rule r:\n", { file: "bad.ds" }), CompileRefused);
    });

    // [LIMP.3.3.1]: the compiler searches the standard library it ships with,
    // at `<its directory>/../share/ds/stdlib`, after every -L directory, as the
    // native binary finds the tarball's beside bin/dsc. ds_dsc's
    // directory is its module's, so a package holding build/ds_dsc/ and
    // build/share/ds/stdlib/ (the DS tools package) resolves an import
    // from it with no -L. The library here is the test's own, so the test is
    // about where the compiler looks, not what the standard library holds.
    // @spec [LIMP.3.3.1]
    test("a library beside the compiler, at ../share/ds/stdlib, resolves an import with no -L", async () => {
        const dir = mkdtempSync(join(process.env.DS_MERCURY_SCRATCH || tmpdir(), "ds-js-stdlib-"));
        const saved = process.env.DS_JS_DSC;
        try {
            const given = resolve(/** @type {string} */ (saved));
            const mjs = join(dir, "build", "ds_dsc", "ds_dsc.mjs");
            mkdirSync(dirname(mjs), { recursive: true });
            symlinkSync(given, mjs);
            symlinkSync(join(dirname(given), "dsc_cli.wasm"), join(dirname(mjs), "dsc_cli.wasm"));
            process.env.DS_JS_DSC = mjs;
            const src = "use default\nimport testlib.greet\n\nschema T scope logical:\n    k: Int key\n";
            await assert.rejects(ds.compile(src, { file: "t.ds" }), CompileRefused,
                                 "with no library beside the compiler, the import has nothing to resolve to");
            const lib = join(dir, "build", "share", "ds", "stdlib", "testlib");
            mkdirSync(lib, { recursive: true });
            writeFileSync(join(lib, "greet.ds"), "schema Greeting scope logical:\n    k: Int key\n");
            const dsc = await ds.compile(src, { file: "t.ds" });
            const e = engine(dsc);
            e.assert("T", { k: 1n });
            assert.equal(e.factCount, 1);
            e.close();
        } finally {
            if (saved === undefined) delete process.env.DS_JS_DSC;
            else process.env.DS_JS_DSC = saved;
            rmSync(dir, { recursive: true, force: true });
        }
    });

    // A host names a library's schema by its path and NAME, and by nothing else
    // ([LIMP.13.2]): an alias is a spelling in one source file. The path:
    // engine.schemas over ds_engine_schema_find and ds_schema_get_name.
    // @spec [NFCT.1.4.2]
    test("test_nfct_1_4_2__a_schema_is_found_by_its_own_name", async () => {
        const dir = mkdtempSync(join(process.env.DS_MERCURY_SCRATCH || tmpdir(), "ds-js-own-name-"));
        try {
            writeFileSync(join(dir, "board_model.ds"), "schema Soc scope logical:\n    chip: String key\n");
            const src = "use default\n\nfrom board_model import Soc as Chip\n\n"
                + "rule r:\n    Chip c\n->\n    log info \"{c.chip}\"\n";
            const e = engine(await ds.compile(src, { file: "alias.ds", searchPath: [dir] }));
            assert.equal(e.schemas.get("board_model.Soc").name, "board_model.Soc");
            for (const other of ["Soc", "Chip", "board_model"]) assert.equal(e.schemas.has(other), false, other);
            e.close();
        } finally {
            rmSync(dir, { recursive: true, force: true });
        }
    });

    // The compiler's own exit is its run's status, never the process's: a
    // compile that a tool runs must not decide how the tool's process ends.
    test("a compile, refused or not, leaves process.exitCode as it was", async () => {
        const was = process.exitCode;
        try {
            for (const before of [undefined, 7]) {
                process.exitCode = before;
                await ds.compile("use default\n\nschema T scope logical:\n    k: Int key\n", { file: "t.ds" });
                assert.equal(process.exitCode, before, "after a clean compile");
                await assert.rejects(ds.compile("rule r:\n", { file: "bad.ds" }), CompileRefused);
                assert.equal(process.exitCode, before, "after a refused one");
            }
        } finally {
            process.exitCode = was;
        }
    });
});

// Clone and the session header.
describe(`@ds-lang/ds clone and session header on the ${TARGET} target`, () => {
    test("clone: an independent engine that starts with no listeners and no callbacks", () => {
        const e = engine();
        const srcEvents = [];
        onStream(e, (ev) => srcEvents.push(ev.type));
        e.assert("Reading", { id: "a", n: TWO_53 + 1n, x: 1.5, ok: true });
        const c = e.clone();
        assert.ok(c instanceof ds.Engine);
        assert.equal(c.factCount, e.factCount);
        const seen = srcEvents.length;
        // The clone fires the pending rule on its own, and the source's
        // listeners hear none of it.
        c.pump();
        assert.equal(srcEvents.length, seen, "the clone's pump reached the source's listeners");
        assert.equal(c.facts({ schema: "Big" }).length, 1);
        assert.equal(e.facts({ schema: "Big" }).length, 0, "the source has not pumped");
        // Its own listeners work; the source's facts are not its facts.
        const cloneEvents = [];
        onStream(c, (ev) => cloneEvents.push(ev.type));
        const f = c.assert("Reading", { id: "b", n: 1n, x: 0, ok: false });
        assert.ok(cloneEvents.includes("fact_assert"));
        dsError(() => c.retract(e.assert("Reading", { id: "s", n: 1n, x: 0, ok: false })),
                S.DS_ERR_FACT_INVALID);
        // Closing either leaves the other working.
        e.close();
        assert.equal(f.read().slots.id, "b");
        c.pump();
        c.close();
    });

    test("clone is refused inside a listener", () => {
        const e = engine();
        let err;
        onStream(e, () => { if (!err) { try { e.clone(); } catch (x) { err = x; } } });
        e.assert("Reading", { id: "a", n: 1n, x: 0, ok: false });
        assert.ok(err instanceof DsError, `${err}`);
        assert.equal(err.status, S.DS_ERR_STATE);
        e.close();
    });

    test("the session header: version and id, and the .dsc's hash once loaded", () => {
        const e = new ds.Engine();
        const before = e.sessionHeader;
        assert.equal(typeof before.dsVersion, "string");
        assert.ok(before.dsVersion.length > 0);
        assert.equal(typeof before.sessionId, "string");
        assert.equal(typeof before.tierId, "string");
        assert.equal(before.dscHash, null);
        e.loadDsc(R1);
        const after = e.sessionHeader;
        assert.ok(after.dscHash instanceof Uint8Array);
        assert.equal(after.dscHash.constructor, Uint8Array);
        assert.equal(after.dscHash.length, 32);
        assert.equal(after.sessionId, before.sessionId);
        // A different .dsc, a different hash.
        const other = new ds.Engine();
        other.loadDsc(R3);
        assert.notDeepEqual(other.sessionHeader.dscHash, after.dscHash);
        other.close();
        e.close();
    });
});

// Recording and replay, through the C recorder and replayer, the
// recorder chained beside @ds-lang/ds's own stream events.
describe(`@ds-lang/ds recording and replay on the ${TARGET} target`, () => {
    /** Run a fixed session on a fresh R1 engine, recording it; return the
        stream's bytes, what the stream listeners heard, and the final facts. */
    function recordSession() {
        const e = engine();
        const chunks = [], kinds = [];
        let dead = null;
        onStream(e, (ev) => kinds.push(ev.type));
        e.recordTo((bytes) => chunks.push(bytes));
        // A pump after each assert: verify-mode replay re-fires per inject
        // atom, so this is the cadence it reproduces.
        e.assert("Reading", { id: "a", n: TWO_53 + 1n, x: 1.5, ok: true });
        e.pump();
        e.clock.advance(SEC);
        const gone = e.assert("Reading", { id: "b", n: 1n, x: 0.5, ok: false });
        e.pump();
        e.retract(gone);
        e.pump();
        dead = gone.alive;
        e.stopRecording();
        e.stopRecording();                       // idempotent
        const facts = (schema) => slotsOf(e, schema);
        const out = { bytes: concat(chunks), kinds, dead, readings: facts("Reading"), bigs: facts("Big"), chunks };
        e.close();
        return out;
    }
    const concat = (parts) => {
        const all = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
        let at = 0;
        for (const p of parts) { all.set(p, at); at += p.length; }
        return all;
    };

    test("a recording replays into a fresh engine, facts and rule fires alike", () => {
        const s = recordSession();
        assert.ok(s.bytes.length > 0);
        assert.ok(s.chunks.every((c) => c.constructor === Uint8Array || c instanceof Uint8Array));
        // The stream events kept coming, and the fence kept working.
        assert.ok(s.kinds.includes("fact_assert") && s.kinds.includes("fact_retract"));
        assert.equal(s.dead, false, "the retracted fact's handle died while recording");

        const r = engine();
        const res = r.replayStream(s.bytes);
        assert.equal(res.headerVerified, true);
        assert.equal(typeof res.asserts, "bigint");
        assert.ok(res.asserts >= 2n && res.retracts >= 1n && res.clocks >= 1n,
                  JSON.stringify(res, (k, v) => typeof v === "bigint" ? `${v}` : v));
        const facts = (schema) => slotsOf(r, schema);
        assert.deepEqual(facts("Reading"), s.readings);
        assert.deepEqual(facts("Big"), s.bigs, "the rule re-fired on replay");
        assert.equal(s.bigs.length, 1);
        r.close();
    });

    test("a recording attached after the first input is refused on replay", () => {
        const e = engine();
        e.assert("Reading", { id: "a", n: 1n, x: 0, ok: false });
        e.pump();
        const chunks = [];
        e.recordTo((bytes) => chunks.push(bytes));
        e.assert("Reading", { id: "b", n: 1n, x: 0, ok: false });
        e.pump();
        e.stopRecording();
        e.close();
        const r = engine();
        dsError(() => r.replayStream(concat(chunks)), S.DS_ERR_FS_RECORDING_INCOMPLETE);
        r.close();
    });

    test("any chunking of the stream replays the same", () => {
        const s = recordSession();
        const whole = engine();
        const a = whole.replayStream(s.bytes);
        const sliced = engine();
        const pieces = [];
        for (let i = 0; i < s.bytes.length; i += 7) pieces.push(s.bytes.subarray(i, i + 7));
        const b = sliced.replayStream(pieces);
        assert.deepEqual(b, a);
        assert.deepEqual(slotsOf(sliced, "Reading"), slotsOf(whole, "Reading"));
        // A truncated stream is a parse error, not a short read.
        const cut = engine();
        dsError(() => cut.replayStream(s.bytes.subarray(0, s.bytes.length - 3)), S.DS_ERR_PARSE);
        whole.close(); sliced.close(); cut.close();
    });

    test("recordTo a path writes the same bytes as a sink", () => {
        // The scratch root may not exist yet: nothing guarantees an earlier
        // step created it, so make it, as the dsdb tests do.
        const base = process.env.DS_MERCURY_SCRATCH || tmpdir();
        mkdirSync(base, { recursive: true });
        const dir = mkdtempSync(join(base, "ds-js-rec-"));
        try {
            const path = join(dir, "session.rfcs");
            const e = engine();
            const viaSink = [];
            e.recordTo(path);
            e.assert("Reading", { id: "p", n: 5n, x: 0, ok: false });
            e.pump();
            e.stopRecording();
            e.close();
            const f = engine();
            f.recordTo((b) => viaSink.push(b));
            f.assert("Reading", { id: "p", n: 5n, x: 0, ok: false });
            f.pump();
            f.stopRecording();
            f.close();
            const onDisk = new Uint8Array(readFileSync(path));
            // Session ids differ run to run, so compare what replay makes of each.
            const a = engine(), b = engine();
            assert.deepEqual(a.replayStream(onDisk), b.replayStream(concat(viaSink)));
            assert.deepEqual(slotsOf(a, "Reading"), slotsOf(b, "Reading"));
            a.close(); b.close();
        } finally {
            rmSync(dir, { recursive: true, force: true });
        }
    });

    test("recordTo a path on a closed engine refuses, and leaves the file as it was", () => {
        const base = process.env.DS_MERCURY_SCRATCH || tmpdir();
        mkdirSync(base, { recursive: true });
        const dir = mkdtempSync(join(base, "ds-js-rec-"));
        try {
            const path = join(dir, "kept.rfcs");
            writeFileSync(path, "kept");
            const e = engine();
            e.close();
            dsError(() => e.recordTo(path), S.DS_ERR_STATE);
            assert.equal(readFileSync(path, "utf8"), "kept");
        } finally {
            rmSync(dir, { recursive: true, force: true });
        }
    });

    test("a sink that throws fails the recording, not the engine", () => {
        const e = engine();
        const boom = new Error("disk full");
        // On this fresh engine recordTo writes nothing: the header and the
        // schema announcements go out at the first stream event, the assert
        // below ([RFCS.5.1]), where this sink, armed by then, fails.
        let armed = false;
        e.recordTo(() => { if (armed) throw boom; });
        armed = true;
        e.assert("Reading", { id: "a", n: 1n, x: 0, ok: false });
        e.pump();
        assert.equal(e.factCount, 1, "the engine carried on");
        let err;
        try { e.stopRecording(); } catch (x) { err = x; }
        assert.ok(err instanceof DsError, `${err}`);
        assert.equal(err.status, S.DS_ERR_IO);
        assert.equal(err.cause, boom);
        e.stopRecording();                       // already stopped
        // `e` has had stream events by now, so this recordTo writes the header
        // itself, and a sink that fails there fails recordTo, with the same
        // cause, and leaves nothing armed. On a fresh engine it could not.
        let err2;
        try { e.recordTo(() => { throw boom; }); } catch (x) { err2 = x; }
        assert.ok(err2 instanceof DsError && err2.status === S.DS_ERR_IO, `${err2}`);
        assert.equal(err2.cause, boom);
        e.recordTo(() => {});                    // not "already recording"
        e.stopRecording();
        e.close();
    });

    test("one recording at a time; a replay of another program is refused", () => {
        const e = engine();
        e.recordTo(() => {});
        dsError(() => e.recordTo(() => {}), S.DS_ERR_STATE);
        e.stopRecording();
        const s = recordSession();
        const other = engine(R3);
        dsError(() => other.replayStream(s.bytes), S.DS_ERR_BND_DSC_MISMATCH);
        other.close();
        e.close();
    });

    // The replay's compare recorder has the stream slot while it runs,
    // and libds leaves the slot empty when it ends. Each case runs after a
    // replay that returned and after each way of one throwing: a stream cut
    // short, a chunk source that throws, and a stream libds refuses as it is
    // fed.
    const replays = {
        "that returned": (e, bytes) => { e.replayStream(bytes); },
        "of a truncated stream": (e, bytes) => {
            dsError(() => e.replayStream(bytes.subarray(0, bytes.length - 3)), S.DS_ERR_PARSE);
        },
        "whose chunk source threw": (e, bytes) => {
            const boom = new Error("the source failed");
            assert.throws(() => e.replayStream((function* () { yield bytes.subarray(0, 8); throw boom; })()),
                          (err) => err === boom);
        },
        "of a recording that began late": (e) => {
            const late = engine();
            late.assert("Reading", { id: "a", n: 1n, x: 0, ok: false });
            late.pump();
            const chunks = [];
            late.recordTo((b) => chunks.push(b));
            late.assert("Reading", { id: "b", n: 1n, x: 0, ok: false });
            late.pump();
            late.stopRecording();
            late.close();
            dsError(() => e.replayStream(concat(chunks)), S.DS_ERR_FS_RECORDING_INCOMPLETE);
        },
    };
    /** A recording with no rule firing, so nothing in it is compared on replay:
        Reading "b" is asserted and retracted. */
    function retractingSession() {
        const e = engine();
        const chunks = [];
        e.recordTo((b) => chunks.push(b));
        const f = e.assert("Reading", { id: "b", n: 1n, x: 0.5, ok: false });
        e.pump();
        e.retract(f);
        e.pump();
        e.stopRecording();
        e.close();
        return concat(chunks);
    }
    for (const [how, replay] of Object.entries(replays)) {
        test(`after a replay ${how}, a listener added before it hears events`, () => {
            const s = recordSession();
            const e = engine();
            const kinds = [];
            onStream(e, (ev) => kinds.push(ev.type));
            replay(e, s.bytes);
            assert.deepEqual(kinds, [], "no event of the replay reached the listener");
            e.assert("Reading", { id: "after", n: 1n, x: 0, ok: false });
            e.pump();
            assert.ok(kinds.includes("fact_assert"), kinds.join());
            e.close();
        });

        test(`after a replay ${how}, a recordTo records`, () => {
            const s = recordSession();
            const e = engine();
            replay(e, s.bytes);
            const chunks = [];
            e.recordTo((b) => chunks.push(b));
            e.assert("Reading", { id: "after", n: 1n, x: 0, ok: false });
            e.pump();
            e.stopRecording();
            const atoms = ds.readAtoms(concat(chunks)).atoms.map((a) => a.message);
            assert.ok(atoms.includes("FactAssert"), atoms.join());
            e.close();
        });

        test(`after a replay ${how}, a retracted Fact is dead`, () => {
            const s = recordSession();
            const e = engine();
            replay(e, s.bytes);
            const f = e.assert("Reading", { id: "after", n: 1n, x: 0, ok: false });
            e.pump();
            assert.equal(f.alive, true);
            e.retract(f);
            e.pump();
            assert.equal(f.alive, false);
            dsError(() => f.read(), S.DS_ERR_FACT_INVALID);
            e.close();
        });
    }

    test("a recording running when a replay starts hears none of it, then resumes", () => {
        const s = recordSession();
        const e = engine();
        const chunks = [];
        e.recordTo((b) => chunks.push(b));
        e.replayStream(s.bytes);
        assert.equal(chunks.length, 0, "the replay reached the recording");
        e.assert("Reading", { id: "after", n: 1n, x: 0, ok: false });
        e.pump();
        e.stopRecording();
        const facts = ds.readAtoms(concat(chunks)).atoms.filter((a) => a.message === "FactAssert");
        assert.equal(facts.length, 1, "the one assert after the replay");
        e.close();
    });

    test("a Fact whose fact left working memory during a replay is dead after it", () => {
        const bytes = retractingSession();
        const e = engine();
        // The recording's assert of "b" is a no-op reassert of this fact, and
        // its retract takes it, with the fence off.
        const held = e.assert("Reading", { id: "b", n: 1n, x: 0.5, ok: false });
        e.pump();
        e.replayStream(bytes);
        assert.equal(e.factCount, 0);
        assert.equal(held.alive, false);
        dsError(() => held.read(), S.DS_ERR_FACT_INVALID);
        e.close();
    });

    test("a Fact whose fact stayed in working memory through a replay stays alive", () => {
        const bytes = retractingSession();
        const e = engine();
        const held = e.assert("Reading", { id: "kept", n: 1n, x: 0, ok: false });
        e.pump();
        e.replayStream(bytes);
        assert.equal(held.alive, true);
        assert.equal(held.read().slots.id, "kept");
        e.close();
    });

    test("a Fact is refused while a replay's source is being iterated, and readable after", () => {
        const bytes = retractingSession();
        const e = engine();
        const held = e.assert("Reading", { id: "kept", n: 1n, x: 0, ok: false });
        e.pump();
        const source = function* () {
            dsError(() => held.read(), S.DS_ERR_STATE);
            dsError(() => e.retract(held), S.DS_ERR_STATE);
            yield bytes;
        };
        e.replayStream(source());
        assert.equal(held.read().slots.id, "kept");
        e.close();
    });

    test("a replay started inside a listener is refused, and the engine's stream goes on", () => {
        const s = recordSession();
        const e = engine();
        const refused = [], kinds = [];
        e.addEventListener("fact_assert", () => {
            let err;
            try { e.replayStream(s.bytes); } catch (x) { err = x; }
            refused.push(err?.status);
        });
        onStream(e, (ev) => kinds.push(ev.type));
        const f = e.assert("Reading", { id: "a", n: 1n, x: 0, ok: false });
        e.pump();
        assert.deepEqual(refused, [S.DS_ERR_STATE]);
        assert.ok(kinds.includes("fact_assert"));
        e.retract(f);
        e.pump();
        assert.ok(kinds.includes("fact_retract"), "the slot is still the glue's");
        assert.equal(f.alive, false);
        e.close();
    });
});

// Reading atoms: libds's reader, field by field, and typed fact bodies.
describe(`@ds-lang/ds reading atoms on the ${TARGET} target`, () => {
    /** A short recording: two asserts, a pump that fires past_2_53, a retract. */
    function recording() {
        const e = engine();
        const chunks = [];
        e.recordTo((b) => chunks.push(b));
        e.assert("Reading", { id: "a", n: TWO_53 + 1n, x: 1.5, ok: true });
        e.pump();
        const f = e.assert("Reading", { id: "b", n: -7n, x: 0.25, ok: false });
        e.pump();
        e.retract(f);
        e.pump();
        e.stopRecording();
        return { e, bytes: Uint8Array.from(chunks.flatMap((c) => [...c])) };
    }

    test("every atom, named, with its fields; 64-bit values exact", () => {
        const { e, bytes } = recording();
        const r = ds.readAtoms(bytes);
        assert.equal(r.error, null);
        assert.equal(r.incomplete, false);
        assert.equal(r.end, bytes.length);
        const by = (m) => r.atoms.filter((a) => a.message === m);
        assert.equal(r.atoms[0].message, "StreamHeader");
        for (const a of r.atoms) {
            assert.equal(typeof a.offset, "number");
            assert.equal(typeof a.field, "number");
            assert.equal(a.message, ds.messageName(a.field), "an atom's message is its field number's");
            assert.ok(a.body === null || typeof a.body === "object");
        }
        const asserts = by("FactAssert");
        assert.equal(asserts.length, 2);
        assert.equal(asserts[0].body.schema_name, "Reading");
        assert.equal(typeof asserts[0].body.fact_id, "bigint");
        assert.ok(asserts[0].body.fact instanceof Uint8Array);
        assert.equal(asserts[0].body.fact.constructor, Uint8Array);
        assert.equal(by("FactRetract").length, 1);
        assert.equal(by("FactRetract")[0].body.fact_id, asserts[1].body.fact_id);
        assert.ok(by("RuleFireAnnotation").some((a) => a.body.rule_name === "past_2_53"));
        // The derived fact is a FactEmit, not a FactAssert.
        assert.ok(by("FactEmit").some((a) => a.body.schema_name === "Big"));
        e.close();
    });

    test("messageName takes a field number: null for one with no entry, refused if not one", () => {
        const { e, bytes } = recording();
        const factAssert = ds.readAtoms(bytes).atoms.find((a) => a.message === "FactAssert");
        assert.equal(ds.messageName(factAssert.field), "FactAssert");
        assert.equal(ds.messageName(2047), null, "2047 has no entry");
        assert.throws(() => ds.messageName("FactAssert"), TypeError, "a name is not looked up");
        assert.throws(() => ds.messageName(1.5), TypeError);
        assert.throws(() => ds.messageName(-1), RangeError);
        assert.throws(() => ds.messageName(2 ** 32), RangeError);
        e.close();
    });

    test("a fact body typed by the engine's schema", () => {
        const { e, bytes } = recording();
        const [first, second] = ds.readAtoms(bytes).atoms.filter((a) => a.message === "FactAssert");
        assert.deepEqual(e.decodeFactBody("Reading", first.body.fact), { id: "a", n: TWO_53 + 1n, x: 1.5, ok: true });
        assert.deepEqual(e.decodeFactBody("Reading", second.body.fact), { id: "b", n: -7n, x: 0.25, ok: false });
        dsError(() => e.decodeFactBody("NoSuch", first.body.fact), S.DS_ERR_SCHEMA_UNKNOWN);
        e.close();
    });

    // A reader with no program types a body by the stream's own
    // Slot atoms ([RFCS.5.1]), and gets what the program's schema gives.
    describe("a fact body typed by the stream's own announcement", () => {
        /** Each schema's announced slots, from the stream's Slot atoms, in order. */
        function announced(atoms) {
            const by = new Map();
            for (const a of atoms) {
                if (a.message !== "Slot") continue;
                const v = a.body;
                if (!by.has(v.schema_name)) by.set(v.schema_name, []);
                by.get(v.schema_name).push({ name: v.slot_name, kind: v.kind.number, nullable: v.nullable,
                                             schemaRef: v.schema_ref });
            }
            return by;
        }

        test("every body equals what the engine's schema gives: a null beside an empty string, Json, Bytes", () => {
            const e = engine();
            const chunks = [];
            e.recordTo((b) => chunks.push(b));
            e.assert("Reading", { id: "a", n: TWO_53 + 1n, x: 1.5, ok: true });
            e.assert("Blob", { id: "p", doc: '{"k": [1, 2.5]}', raw: new Uint8Array([0, 255]) });
            e.assert("Blob", { id: "q", doc: "[]", raw: new Uint8Array(), note: "" });
            e.pump();
            e.stopRecording();
            const atoms = ds.readAtoms(Uint8Array.from(chunks.flatMap((c) => [...c]))).atoms;
            const slots = announced(atoms);
            const bodies = atoms.filter((a) => a.message === "FactAssert" || a.message === "FactEmit");
            assert.ok(bodies.some((a) => a.message === "FactEmit"), "the rule's emit is decoded too");
            for (const a of bodies) {
                const { schema_name: schema, fact } = a.body;
                assert.ok(slots.has(schema), `${schema} is announced`);
                assert.deepEqual(ds.decodeAnnouncedFactBody(slots.get(schema), fact), e.decodeFactBody(schema, fact),
                                 `${a.message} ${schema}`);
            }
            // Not only equal to each other: right, a null and an empty string apart.
            const [p, q] = bodies.filter((a) => a.body.schema_name === "Blob");
            assert.equal(ds.decodeAnnouncedFactBody(slots.get("Blob"), p.body.fact).note, null, "omitted: null");
            assert.equal(ds.decodeAnnouncedFactBody(slots.get("Blob"), q.body.fact).note, "", "empty: itself");
            e.close();
        });

        test("a fact-ref slot, an unspecified kind and a kind no slot has are refused", () => {
            const body = new Uint8Array();
            const slot = (kind) => [{ name: "s", kind, nullable: true, schemaRef: kind === 6 ? "Other" : null }];
            dsError(() => ds.decodeAnnouncedFactBody(slot(6), body), S.DS_ERR_INVAL);
            dsError(() => ds.decodeAnnouncedFactBody(slot(0), body), S.DS_ERR_INVAL);
            dsError(() => ds.decodeAnnouncedFactBody(slot(99), body), S.DS_ERR_INVAL);
            assert.deepEqual(ds.decodeAnnouncedFactBody(slot(1), body), { s: null }, "an absent nullable Int is null");
            assert.deepEqual(ds.decodeAnnouncedFactBody([], body), {});
        });

        // No U+FFFD comes back in place of these bytes. PATH PINNED: libds's
        // decode_body, the String and Json arms, through each announced decode.
        test("a String or Json field that is not well-formed UTF-8 is a malformed body", () => {
            const slot = (kind) => [{ name: "s", kind, nullable: false, schemaRef: null }];
            const string = Uint8Array.of(0x0a, 0x02, 0x61, 0xff);
            const json = Uint8Array.of(0x0a, 0x04, 0x22, 0x61, 0xff, 0x22);
            dsError(() => ds.decodeAnnouncedFactBody(slot(3), string), S.DS_ERR_PARSE);
            dsError(() => ds.decodeAnnouncedFactBody(slot(5), json), S.DS_ERR_PARSE);
            dsError(() => ds.decodeAnnouncedFactBodyHandles(slot(3), string), S.DS_ERR_PARSE);
            assert.deepEqual(ds.decodeAnnouncedFactBody(slot(3), Uint8Array.of(0x0a, 0x02, 0xc3, 0xa9)), { s: "é" },
                             "the control: well-formed text decodes");
        });

        // [RFCS.6.3]. PATH PINNED: libds's decode_body, its last loop, through
        // the engine's decode and each announced one.
        test("an absent non-nullable Json field is a malformed body, and a nullable one is null", () => {
            const slot = (nullable) => [{ name: "j", kind: 5, nullable, schemaRef: null }];
            const absent = new Uint8Array();
            dsError(() => ds.decodeAnnouncedFactBody(slot(false), absent), S.DS_ERR_PARSE);
            dsError(() => ds.decodeAnnouncedFactBodyHandles(slot(false), absent), S.DS_ERR_PARSE);
            assert.deepEqual(ds.decodeAnnouncedFactBody(slot(true), absent), { j: null }, "the control");
        });

        test("decodeFactBody refuses an absent non-nullable Json field", {
            skip: NO_DSC || (TARGET === "wasm" && "on the wasm target, fromSource is the wasm runner's"),
        }, () => {
            const e = ds.fromSource("use default\n\nschema Doc scope logical:\n    k: Int key\n    j: Json mutable\n",
                                    { file: "doc.ds" });
            dsError(() => e.decodeFactBody("Doc", Uint8Array.of(0x08, 0x01)), S.DS_ERR_PARSE);
            e.close();
        });

        // [RFCS.6.3]. PATH PINNED: libds's decode_body, its last loop, through
        // the engine's decode and each announced one.
        const ROOT_NULL = Uint8Array.of(0x0a, 0x04, 0x6e, 0x75, 0x6c, 0x6c);
        test("a root-null Json field is null in a nullable slot and a malformed body in a non-nullable one", () => {
            const slot = (nullable) => [{ name: "j", kind: 5, nullable, schemaRef: null }];
            dsError(() => ds.decodeAnnouncedFactBody(slot(false), ROOT_NULL), S.DS_ERR_PARSE);
            dsError(() => ds.decodeAnnouncedFactBodyHandles(slot(false), ROOT_NULL), S.DS_ERR_PARSE);
            assert.deepEqual(ds.decodeAnnouncedFactBody(slot(true), ROOT_NULL), { j: null });
            assert.deepEqual(ds.decodeAnnouncedFactBodyHandles(slot(true), ROOT_NULL), { slots: { j: null }, refs: {} });
        });

        test("decodeFactBody reads a root-null Json field by its slot", {
            skip: NO_DSC || (TARGET === "wasm" && "on the wasm target, fromSource is the wasm runner's"),
        }, () => {
            const e = ds.fromSource("use default\n\nschema Doc scope logical:\n    k: Int key\n    j: Json mutable\n\n"
                                    + "schema DocN scope logical:\n    k: Int key\n    j: Json? mutable\n",
                                    { file: "doc.ds" });
            const body = Uint8Array.of(0x08, 0x01, 0x12, 0x04, 0x6e, 0x75, 0x6c, 0x6c);
            dsError(() => e.decodeFactBody("Doc", body), S.DS_ERR_PARSE);
            assert.equal(e.decodeFactBody("DocN", body).j, null);
            e.close();
        });

        test("what is not a list of announced slots, or not a body, is refused before libds", () => {
            assert.throws(() => ds.decodeAnnouncedFactBody("Reading", new Uint8Array()), TypeError);
            assert.throws(() => ds.decodeAnnouncedFactBody([{ name: "s", nullable: false }], new Uint8Array()),
                          TypeError, "a slot with no kind");
            assert.throws(() => ds.decodeAnnouncedFactBody([{ kind: 1, nullable: false }], new Uint8Array()),
                          TypeError, "a slot with no name");
            assert.throws(() => ds.decodeAnnouncedFactBody([{ name: "s", kind: 1.5, nullable: false }],
                                                           new Uint8Array()), TypeError, "a kind that is no integer");
            assert.throws(() => ds.decodeAnnouncedFactBody([], [1, 2]), TypeError, "a body that is no Uint8Array");
        });

        // A body holding fact references, decoded with each one's
        // recorded handle, which is the fact_id of the record that carried
        // the referenced fact ([RFCS.6.3]).
        test("a fact-ref slot gives its recorded handle, the referenced fact's fact_id; an empty nullable one, null", () => {
            const e = engine(R7_REFS);
            const chunks = [];
            e.recordTo((b) => chunks.push(b));
            e.assert("Motion", { entity_id: "m1", level: 0.75 });
            e.pump();
            e.stopRecording();
            const atoms = ds.readAtoms(Uint8Array.from(chunks.flatMap((c) => [...c]))).atoms;
            const slots = announced(atoms);
            const motion = atoms.find((a) => a.message === "FactAssert" && a.body.schema_name === "Motion")
                ?? assert.fail("no Motion asserted");
            const trace = atoms.find((a) => a.message === "FactEmit" && a.body.schema_name === "Trace")
                ?? assert.fail("make_trace emitted no Trace");
            assert.deepEqual(ds.decodeAnnouncedFactBodyHandles(slots.get("Trace"), trace.body.fact),
                             { slots: { n: 1n }, refs: { target: motion.body.fact_id, seen: null } });
            // A body with no fact-ref slot: every slot, as the plain decode gives it, and no refs.
            assert.deepEqual(ds.decodeAnnouncedFactBodyHandles(slots.get("Motion"), motion.body.fact),
                             { slots: ds.decodeAnnouncedFactBody(slots.get("Motion"), motion.body.fact), refs: {} });
            assert.throws(() => ds.decodeAnnouncedFactBodyHandles([{ name: "s", nullable: false }], new Uint8Array()),
                          TypeError, "a slot with no kind");
            e.close();
        });
    });

    test("incremental: a partial tail is where to resume, not an error", () => {
        const { e, bytes } = recording();
        const whole = ds.readAtoms(bytes).atoms;
        const cutAt = whole[whole.length - 1].offset + 3;          // inside the last atom
        const part = ds.readAtoms(bytes.subarray(0, cutAt), { incremental: true });
        assert.equal(part.error, null);
        assert.equal(part.incomplete, true);
        assert.equal(part.end, whole[whole.length - 1].offset);
        assert.equal(part.atoms.length, whole.length - 1);
        const strict = ds.readAtoms(bytes.subarray(0, cutAt));
        assert.notEqual(strict.error, null);
        assert.equal(strict.atoms.length, whole.length - 1, "the atoms before it are still read");
        e.close();
    });

    test("bytes no append repairs are an error at their offset; a valid prefix is not", () => {
        const { e, bytes } = recording();
        const head = [...bytes.subarray(0, ds.readAtoms(bytes).atoms[2].offset)];
        // The outer tag 0x0a, then a length still arriving: incomplete, not wrong.
        const prefix = ds.readAtoms(Uint8Array.from([...head, 0x0a, 0xff]), { incremental: true });
        assert.equal(prefix.error, null);
        assert.equal(prefix.incomplete, true);
        // A frame begins with the byte 0x0a ([RFCS.19.1]), so 0xff begins none,
        // however many bytes follow it ([RFCS.19.2]: a wrong byte is not a short tail).
        const erased = ds.readAtoms(Uint8Array.from([...head, 0xff, 0xff, 0xff, 0xff, 0xff]), { incremental: true });
        assert.notEqual(erased.error, null);
        assert.equal(erased.atoms.length, 2);
        assert.equal(erased.error.offset, head.length);
        // A frame for field 1999, which no atom is allocated: no append helps.
        const bad = Uint8Array.from([...head, 0xfa, 0x7c, 0x00]);
        const r = ds.readAtoms(bad, { incremental: true });
        assert.notEqual(r.error, null);
        assert.equal(r.atoms.length, 2);
        assert.equal(typeof r.error.offset, "number");
        assert.ok(r.error.offset >= r.atoms[1].offset, "the error is at or after the last good atom");
        assert.equal(typeof r.error.detail, "string");
        e.close();
    });

    test("a .dsc reads through the same reader", () => {
        const r = ds.readAtoms(R1);
        assert.equal(r.error, null);
        assert.ok(r.atoms.some((a) => a.message === "SchemaDef" && a.body.schema_name === "Reading"));
        assert.ok(r.atoms.every((a) => Number.isInteger(a.field) && typeof a.message === "string"));
        assert.ok(r.atoms.every((a) => Array.isArray(a.unknownFields) && a.unknownFields.length === 0),
                  "a .dsc the compiler wrote carries no field its reader does not know");
    });

    // @spec [RTIM.14.9]: "the interpreter must read each test
    // atom in a way that lets a field it does not know reach it". The bytes
    // are test_rfcs_reader.c's: an OracleEmit (field 288) with test_id 1,
    // polarity POS, schema_name "R" and one slot_match { slot_name "a" }.
    describe("unknownFields: what the descriptor does not name reaches the reader", () => {
        const head = [0x08, 0x01, 0x10, 0x01, 0x1a, 0x01, 0x52];
        const slot = [0x22, 0x03, 0x0a, 0x01, 0x61];
        const slot8 = [0x22, 0x05, 0x0a, 0x01, 0x61, 0x40, 0x01];  // + field 8 = 1
        const f99 = [0x98, 0x06, 0x07];                            // field 99 = 7
        /** One framed atom ([RFCS.19.1]): 0x0a, its length, then field 288's tag and body. */
        function oracleEmit(body) {
            const atom = [0x82, 0x12, body.length, ...body];
            return Uint8Array.from([0x0a, atom.length, ...atom]);
        }

        test("an OracleEmit with an extra field 99 is read with unknownFields [99]", () => {
            const r = ds.readAtoms(oracleEmit([...head, ...slot, ...f99]));
            assert.equal(r.error, null);
            assert.equal(r.atoms.length, 1);
            const [a] = r.atoms;
            assert.equal(a.message, "OracleEmit");
            assert.deepEqual(a.unknownFields, [99]);
            assert.equal(a.body.schema_name, "R", "its known fields still read");
            assert.equal("99" in a.body, false, "field 99 is not in the body: no name says what it is");
        });

        test("the same bytes without the field report none", () => {
            const [a] = ds.readAtoms(oracleEmit([...head, ...slot])).atoms;
            assert.equal(a.message, "OracleEmit");
            assert.deepEqual(a.unknownFields, []);
        });

        test("one in a nested message is reported too, in the order read", () => {
            const [a] = ds.readAtoms(oracleEmit([...head, ...slot8, ...f99])).atoms;
            assert.deepEqual(a.unknownFields, [8, 99], "TestSlotLiteral's field 8, then OracleEmit's 99");
            assert.equal(a.body.slot_match[0].slot_name, "a");
        });

        // @spec [RTIM.14.15]: a reader names the atom it refuses from
        // the error, with no frame of its own to parse.
        test("a body that does not unpack names its atom in the error", () => {
            // slot_match declares 5 bytes and holds 1, inside a whole frame.
            const r = ds.readAtoms(oracleEmit([...head, 0x22, 0x05, 0x0a]));
            assert.deepEqual(r.atoms, []);
            assert.notEqual(r.error, null);
            assert.equal(r.error.offset, 0);
            assert.equal(r.error.field, 288);
            assert.equal(r.error.message, "OracleEmit");
        });

        test("framing that does not read names none", () => {
            const whole = oracleEmit([...head, ...slot]);
            const r = ds.readAtoms(whole.subarray(0, whole.length - 1));
            assert.notEqual(r.error, null);
            assert.equal(r.error.field, null);
            assert.equal(r.error.message, null);
        });
    });
});

// What dsdb's hypotheses need: a fact by id in a clone, and the engine's bytes.
describe(`@ds-lang/ds factById and mem on the ${TARGET} target`, () => {
    test("factById finds, in a clone, a fact asserted before it; null for none", () => {
        const e = engine();
        const f = e.assert("Reading", { id: "a", n: 1n, x: 1.5, ok: true });
        const id = f.id;
        const c = e.clone();
        try {
            const g = c.factById(id);
            assert.ok(g instanceof ds.Fact);
            assert.equal(g.id, id);
            assert.equal(g.read().slots.id, "a");
            // The clone's handle retracts the clone's fact, and only it.
            c.retract(g);
            assert.equal(c.factById(id), null);
            assert.equal(e.factById(Number(id)).id, id, "a safe Number is an id too");
            assert.equal(c.factById(id + 1000n), null);
            assert.throws(() => c.factById(-1), TypeError);
        } finally {
            c.close();
            e.close();
        }
    });

    test("mem: ds_engine_mem, every field a Number, total the sum", () => {
        const e = engine();
        try {
            e.assert("Reading", { id: "a", n: 1n, x: 1.5, ok: true });
            const m = e.memory();
            const fields = ["wmFactCount", "wmFactBytes", "wmIndexBytes", "alphaNodeCount", "alphaMatchCount",
                            "alphaIndexBytes", "betaNodeCount", "betaTokenCount", "betaTokenBytes", "betaIndexBytes",
                            "internCount", "internStringBytes", "internIndexBytes", "poolReservedBytes", "totalBytes"];
            assert.deepEqual(Object.keys(m).sort(), [...fields].sort());
            for (const k of fields) assert.equal(typeof m[k], "number", k);
            assert.equal(m.wmFactCount, 1);
            assert.ok(m.totalBytes > 0);
        } finally {
            e.close();
        }
        // No program yet: nothing refused, just what an empty engine holds.
        const empty = new ds.Engine();
        try {
            assert.equal(empty.memory().wmFactCount, 0);
        } finally {
            empty.close();
        }
    });

    test("no encodeText: TextNote is post-v1", () => {
        assert.equal("encodeText" in ds, false);
    });
});

// Series, whose backends libds registers itself.
describe(`@ds-lang/ds series on the ${TARGET} target`, () => {
    /** R2_SERIES on the mock clock at 0: Sensor.state, not persisted, count over 10 s. */
    function sensor() {
        const e = new ds.Engine();
        e.clock.mode = "mock";
        e.clock.set(0n);
        e.loadDsc(R2_SERIES);
        return e;
    }

    // A SERIES IS READ THROUGH A RULE: no public function reads one
    // ([NSBK.6.3]), so `trig`'s log is what shows the backing absorbed. Its
    // `where` reads the count before the pump's own sample ([LSER.8.6]): the
    // first assert's pump reads 0 and does not fire, and the second, a
    // supersede, reads the first sample and fires.
    test("a rule reads the series: fire-then-sample, so the second pump fires", () => {
        const e = sensor();
        const logs = [];
        e.addEventListener("log", (l) => logs.push(l.message));
        e.assert("Sensor", { entity_id: "kitchen", state: 20.0 });
        e.pump();
        assert.deepEqual(logs, [], "the first pump reads a cold count");
        e.assert("Sensor", { entity_id: "kitchen", state: 21.0 });
        e.pump();
        assert.ok(logs.length >= 1 && logs.every((m) => m === "x"), JSON.stringify(logs));
        e.close();
    });

    test("no seriesValue: no public function reads a series", () => {
        const e = sensor();
        assert.equal("seriesValue" in e, false);
        e.close();
    });
});
