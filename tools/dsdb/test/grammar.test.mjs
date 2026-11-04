// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The shell's line grammar (DSTRACE_INTERACTIVE.md §4.2), ported from
// tools/dstrace_shell/tests/test_commands.py case for case.

import { test } from "node:test";
import assert from "node:assert/strict";

import { durationNs, parse, position } from "../lib/core/grammar.js";

const pos = (seq, minus = 0) => ({ seq: BigInt(seq), minus });

// `new Cmd` gives every field a default, so the Python's tuple comparisons
// read the same here; `pos` is a plain object, compared by value.

test("queries: sigil, scope, position, timelines and body", () => {
    const cases = [
        ["#.", "#", ".", null, [], ""],
        ["#:", "#", ":", null, [], ""],
        ["!@1aba", "!", "@", pos(0x1aba), [], ""],
        ["^@1aba- /^alert/", "^", "@", pos(0x1aba, 1), [], "/^alert/"],
        ["?.Thermometer t where t.x % 2 == 0", "?", ".", null, [], "Thermometer t where t.x % 2 == 0"],
        ["?.%0 %1 Occupied o", "?", ".", null, [0, 1], "Occupied o"],
        ["#: tumbling 1_s mean", "#", ":", null, [], "tumbling 1_s mean"],
    ];
    for (const [line, sigil, scope, p, timelines, body] of cases) {
        const c = parse(line);
        assert.deepEqual([c.kind, c.sigil, c.scope, c.pos, c.timelines, c.body],
                         ["query", sigil, scope, p, timelines, body], line);
    }
});

test("navigation: every form, with its amount's type", () => {
    const S = 1_000_000_000n;
    const cases = [
        ["@", "show", 0, null],
        ["@<", "start", 0, null],                   // the start of time
        ["@>", "end", 0, null],                     // the end of time
        ["@$", "end", 0, null],                     // alias
        ["@0", "abs_pos", 0, pos(0)],               // an ordinary position, seq 0
        ["@1aba", "abs_pos", 0, pos(0x1aba)],
        ["@1d", "abs_pos", 0, pos(0x1d)],           // hex, not a day (§4.2)
        ["@1_d", "abs_clock", 86_400n * S, null],
        ["@12_s", "abs_clock", 12n * S, null],
        ["@+10", "rel_pos", 10, null],              // a decimal count of records
        ["@-3", "rel_pos", -3, null],
        ["@+500_ms", "rel_clock", 500_000_000n, null],
        ["@-2_s", "rel_clock", -2n * S, null],
        ["@#12", "bucket", 12, null],
        ["@[", "fact_asserted", 0, null],
        ["@]", "fact_ended", 0, null],
    ];
    for (const [line, nav, amount, p] of cases) {
        const c = parse(line);
        assert.deepEqual([c.kind, c.nav, c.amount, c.pos], ["nav", nav, amount, p], line);
    }
});

test("words, rows, steps and errors", () => {
    assert.equal(parse("").kind, "empty");
    assert.deepEqual([parse("3").kind, parse("3").row], ["row", 3]);
    assert.deepEqual([parse("n").kind, parse("n").args], ["step", "pump"]);
    assert.equal(parse("p fire").args, "fire");
    assert.equal(parse("n sideways").kind, "error");
    assert.deepEqual([parse("calls all").word, parse("calls all").args], ["calls", "all"]);
    // §4.16: a change at point says so; the bare word is left to DS.
    assert.deepEqual([parse("from here emit Foo x: 1").word, parse("from here emit Foo x: 1").args,
                      parse("from here emit Foo x: 1").fromHere], ["emit", "Foo x: 1", true]);
    assert.equal(parse("emit Foo x: 1").kind, "error");
    assert.match(parse("emit Foo x: 1").error, /from here emit/);
    assert.equal(parse("from here rule x:").kind, "error");
    // Any point: start, a position, the end, a clock.
    assert.equal(parse("from start withdraw #3").at.nav, "start");
    assert.deepEqual(parse("from @1def- emit A x: 1").at.pos, { seq: 0x1defn, minus: 1 });
    assert.equal(parse("from @> answer 1 {}").at.nav, "end");
    assert.equal(parse("from @12_s emit A x: 1").at.nav, "abs_clock");
    assert.equal(parse("from here emit A x: 1").at, null);
    assert.equal(parse("from @+5 emit A x: 1").kind, "error", "a point, not a move");
    assert.equal(parse("from yonder emit A x: 1").kind, "error");
    assert.equal(parse("frobnicate").kind, "error");
    assert.equal(parse("@zz").kind, "error");
    assert.equal(parse("?.%x Foo f").kind, "error");
    // A later stage's word is a word, so it can say when it arrives.
    assert.deepEqual([parse("why #3").kind, parse("why #3").args], ["word", "#3"]);
});

test("the error messages are the Python's, word for word", () => {
    assert.equal(parse("n sideways").error, "`n` steps by atom, fire or tick, not `sideways`");
    assert.equal(parse("frobnicate").error, "no command `frobnicate`; `help` lists them");
    assert.equal(parse("@zz").error, "`@zz` is neither a hex position nor a duration with its `_`");
    assert.equal(parse("?.%x Foo f").error, "`%x` is not a timeline; timelines are %0, %1, ...");
    assert.equal(parse("!@zz").error, "`@zz` is not a position; positions are hex");
    assert.equal(parse("@#x").error, "`@#x` needs a bucket number, as `@#12`");
    assert.equal(parse("@+x").error, "`@+x` moves by a count of records or a duration such as `500_ms`");
});

test("durations and positions", () => {
    assert.equal(durationNs("1.5_s"), 1_500_000_000n);
    assert.equal(durationNs("15s"), null);           // the underscore is required
    assert.equal(durationNs("250_µs"), 250_000n);
    // Python's round(): a tie goes to the even integer.
    assert.equal(durationNs("0.5_ns"), 0n);
    assert.equal(durationNs("1.5_ns"), 2n);
    assert.equal(durationNs("2.5_ns"), 2n);
    assert.deepEqual(position("ff--"), pos(255, 2));
    assert.equal(position("12_s"), null);
    // Past 2^53: a seq stays exact.
    assert.deepEqual(position("20000000000001"), pos(0x20000000000001n));
});
