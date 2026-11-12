#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
# @spec [LSER.15.1]
# @spec [LSER.16.2]
# @spec [LSER.16.3.3]
# @spec [LSER.17.2]
# @spec [LSER.10.9]
# @spec [LSER.16.9]
# @spec [LSER.19.8]
# @spec [LSER.14.1]
# @spec [LSMP.2.1]
"""Every series backing's read held to the clause-literal reference, bit for bit.

[LSER.15.1]: every v1 aggregation is exact and bit-identical across platforms.
`series_reference.py` writes each aggregation and window admission from its
clause's words; this file is the glue that drives libds through pyds over
generated sample streams and holds what each backing answers to that reading.
It runs on libds alone, so it ratifies no clause ([STYL.5.3.11]): it is a
bug-finder, and a disagreement the clause decides in the reference's favour is
pinned as a conformance vector, which runs on both runtimes.

How one example runs. A program is compiled per (slot type, time model, window
parameter): schema `S` keyed on `k`, its tracked slot `v`, a sequence number
`n` and a trigger flag `q`; one `series S.v (by: k)` line holding every
aggregation [LSER.18.1] marks exact for that model and [LSER.17.2] admits for
that type; and one rule per aggregation, gated `where x.q`, emitting the read
into `OutF`, `OutI`, `OutB` or `OutS` by its result type, each slot `T?` so a
`null` read stays visible ([LSER.19.8]). One rule per read keeps a fault in
one from hiding the others. On a mock clock each sample is one assert of a new
fact on `k` (its `n` changes, so it is no no-op reassertion, [LSER.8.5.1]) and
one pump, which absorbs it after the agenda drains, stamped with the clock
([LSER.8.6]). The read is one more assert with `q: true`, at a read instant at
or after the last sample, and one pump: its rules read the snapshot that held
when that pump began, so the trigger's own sample is not among them
([LSER.8.6.1]).

What is compared. A `Float` by its eight bytes (`struct.pack`, never `==` with a
tolerance), so `-0.0` and `+0.0` are told apart; an `Int`, a `Bool` and a
`String` by type and value; `null` as `None`. A read whose reference value is
NaN is dropped, and only that read: a NaN never reaches a slot ([LEXP.4.2]), so
that read has nothing to compare, and every other read of the example is
compared as usual. The census counts the dropped reads beside the compared
ones.

How much is compared. Each program must compare at least `FLOOR` examples,
an example counting when it compared at least one read, or that program's test
fails. A run that compared little is red, not merely small in the census.

The negative fixtures, run every time: `test_an_answer_one_ulp_off_is_reported`
(a reference answer one ULP off, or `null` against a value, must be reported
by the comparison the property uses), `test_a_nan_read_is_dropped_alone` (a
NaN read is dropped and counted, and a wrong read beside it is still reported)
and `test_a_thin_program_is_refused` (a count under the floor fails the floor
check the property uses).
"""
from __future__ import annotations

import math
import struct
from typing import Callable, NamedTuple

import pytest
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

import series_reference as ref

INT64_MIN = -(1 << 63)
INT64_MAX = (1 << 63) - 1
SECOND = 1_000_000_000

# The quantiles each windowed program reads: the two ends, the quartiles, and
# `median` (`p50`) beside them.
PERCENTILES = (1, 25, 75, 99)

# The literal `count_of` and `contains` look up, per slot type. Each strategy
# below draws it often, and `Float`'s draws `-0.0` too, which the equality
# takes as the same value ([LSER.16.5.1]).
PROBE = {"Float": "0.0", "Int": "0", "Bool": "true", "String": '"a"'}
PROBE_VALUE = {"Float": 0.0, "Int": 0, "Bool": True, "String": "a"}

# Where each aggregation's read lands, by slot type.
_OUT_OF_SLOT = {"Float": "OutF", "Int": "OutI", "Bool": "OutB", "String": "OutS"}


class Read(NamedTuple):
    """One aggregation a program reads: its name in the census, the DS
    expression that reads it on binding `x`, the `Out*` schema it lands in,
    and the reference that answers it from the admitted samples."""
    agg: str
    expr: str
    out: str
    answer: Callable[[list, str], object]


def _vals(samples: list) -> list:
    return ref.values(samples)


def _reads(slot: str, model: str) -> list[Read]:
    """Every read [LSER.18.1] marks exact under `model` and [LSER.17.2] admits
    for `slot`, with the reference that answers it."""
    same = _OUT_OF_SLOT[slot]
    table: list[Read] = []

    def add(agg: str, expr: str, out: str, answer) -> None:
        cell = "pXX" if agg.startswith("p") and agg[1:].isdigit() else agg
        if (model in ref.EXACT_CELLS[cell]
                and slot in ref.ADMITTED_TYPES[cell]):
            table.append(Read(agg, expr, out, answer))

    float_sum = ref.sum_float if slot == "Float" else None
    add("count", "x.count", "OutI", lambda s, m: ref.count(_vals(s)))
    add("sum", "x.sum", same,
        lambda s, m: (float_sum or ref.sum_int)(_vals(s)))
    add("mean", "x.mean", "OutF", lambda s, m: ref.mean(_vals(s), m))
    add("variance", "x.variance", "OutF",
        lambda s, m: ref.variance(_vals(s), m))
    add("pvariance", "x.pvariance", "OutF",
        lambda s, m: ref.pvariance(_vals(s), m))
    add("stdev", "x.stdev", "OutF", lambda s, m: ref.stdev(_vals(s), m))
    add("pstdev", "x.pstdev", "OutF", lambda s, m: ref.pstdev(_vals(s), m))
    add("min", "x.min", same, lambda s, m: ref.min_(_vals(s)))
    add("max", "x.max", same, lambda s, m: ref.max_(_vals(s)))
    add("first", "x.first", same, lambda s, m: ref.first(_vals(s)))
    add("last", "x.last", same, lambda s, m: ref.last(_vals(s)))
    add("bool_and", "x.bool_and", "OutB", lambda s, m: ref.bool_and(_vals(s)))
    add("bool_or", "x.bool_or", "OutB", lambda s, m: ref.bool_or(_vals(s)))
    add("direction", "x.direction", "OutI",
        lambda s, m: ref.direction(_vals(s)))
    add("rate", "x.rate", "OutF", lambda s, m: ref.rate(s))
    add("median", "x.median", "OutF", lambda s, m: ref.median(_vals(s)))
    for p in PERCENTILES:
        add(f"p{p}", f"x.p{p}", "OutF",
            lambda s, m, p=p: ref.percentile(_vals(s), p))
    add("count_distinct", "x.count_distinct", "OutI",
        lambda s, m: ref.count_distinct(_vals(s)))
    add("count_of", f"count_of(x.v, {PROBE[slot]})", "OutI",
        lambda s, m: ref.count_of(_vals(s), PROBE_VALUE[slot]))
    add("contains", f"contains(x.v, {PROBE[slot]})", "OutB",
        lambda s, m: ref.contains(_vals(s), PROBE_VALUE[slot]))
    return table


def _series_names(reads: list[Read]) -> str:
    names = []
    for r in reads:
        if r.agg in ("count_of", "contains", "count_distinct"):
            names.append(r.agg)
        else:
            names.append(r.expr[len("x."):])
    return ", ".join(dict.fromkeys(names))


def _model_clause(model: str, param: int) -> str:
    if model == "all_time":
        return "all_time"
    if model == "sliding":
        return f"sliding {param}_s"
    return f"sample {param}"


def program(slot: str, model: str, param: int) -> str:
    """The DS program one (slot type, time model, parameter) runs."""
    reads = _reads(slot, model)
    lines = [
        "use default",
        "",
        "schema S scope logical:",
        "    k: String key",
        "    n: Int mutable",
        "    q: Bool mutable",
        f"    v: {slot} mutable",
        "",
    ]
    for out, ty in (("OutF", "Float"), ("OutI", "Int"), ("OutB", "Bool"),
                    ("OutS", "String")):
        lines += [f"schema {out} scope ttl 1_h:", "    agg: String",
                  f"    r: {ty}?", ""]
    lines += ["series S.v (by: k):",
              f"    {_series_names(reads)} {_model_clause(model, param)}", ""]
    for r in reads:
        lines += [f"rule read_{r.agg}:", "    S x where x.q", "->",
                  f"    emit {r.out} agg: \"{r.agg}\" r: {r.expr}", ""]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# What one read is compared as.

def same_value(got: object, want: object) -> bool:
    """Bit-equality for a `Float`, type and value for the rest, `None` for a
    `null` read."""
    if want is None:
        return got is None
    if isinstance(want, bool):
        return isinstance(got, bool) and got is want
    if isinstance(want, float):
        return (isinstance(got, float)
                and struct.pack("<d", got) == struct.pack("<d", want))
    if isinstance(want, int):
        return type(got) is int and got == want
    return type(got) is type(want) and got == want


def check_reads(got: dict[str, object], want: dict[str, object],
                where: str) -> None:
    """Every aggregation's read equals its reference; one that does not is
    reported by name, both values and their bits."""
    bad = []
    for agg, w in want.items():
        g = got.get(agg, "<no read>")
        if not same_value(g, w):
            bits = ""
            if isinstance(g, float) and isinstance(w, float):
                bits = (f" (libds {struct.pack('<d', g).hex()}, "
                        f"reference {struct.pack('<d', w).hex()})")
            bad.append(f"{agg}: libds {g!r}, reference {w!r}{bits}")
    assert not bad, f"{where}: " + "; ".join(bad)


def split_nan(want: dict[str, object]) -> tuple[dict[str, object], list[str]]:
    """The reads to compare, and the names of those dropped because their
    reference value is NaN, which no slot can hold ([LEXP.4.2])."""
    compared: dict[str, object] = {}
    dropped: list[str] = []
    for agg, w in want.items():
        if isinstance(w, float) and math.isnan(w):
            dropped.append(agg)
        else:
            compared[agg] = w
    return compared, dropped


# Examples Hypothesis draws per program, and the fewest a program must compare.
MAX_EXAMPLES = 40
FLOOR = MAX_EXAMPLES // 2


def check_floor(compared: int, where: str) -> None:
    """A program that compared fewer than `FLOOR` examples fails."""
    assert compared >= FLOOR, (
        f"{where}: compared {compared} examples, under the floor of {FLOOR}")


# ---------------------------------------------------------------------------
# Driving libds.

_COMPILED: dict[str, bytes] = {}


def _engine(src: str):
    import pyds
    if src not in _COMPILED:
        _COMPILED[src] = pyds.compile(src, file="series_backend.ds")
    eng = pyds.Engine()
    eng.load_dsc(_COMPILED[src])
    eng.clock.mode = "mock"
    eng.clock.set(0)
    return eng


def libds_reads(src: str, samples: list[ref.Sample], read_at: int,
                trigger_v: object) -> dict[str, object]:
    """Absorb `samples`, one per pump, each at its own clock; then pump once at
    `read_at` with the trigger asserted, and return what each read emitted."""
    eng = _engine(src)
    try:
        for i, smp in enumerate(samples):
            eng.clock.set(smp.t)
            eng.assert_("S", k="a", n=i, q=False, v=smp.v)
            eng.pump()
        eng.clock.set(read_at)
        eng.assert_("S", k="a", n=len(samples), q=True, v=trigger_v)
        eng.pump()
        got: dict[str, object] = {}
        for out in ("OutF", "OutI", "OutB", "OutS"):
            for fact in eng.facts.of(out):
                agg = fact.slots["agg"]
                assert agg not in got, f"{agg} read twice"
                got[agg] = fact.slots["r"]
        return got
    finally:
        eng.close()


def reference_reads(reads: list[Read], model: str, param: int,
                    samples: list[ref.Sample], read_at: int) -> dict:
    """The reference's answer to each read over the samples the model admits
    at `read_at`."""
    if model == "all_time":
        admitted = ref.all_time(samples)
    elif model == "sliding":
        admitted = ref.sliding(samples, param * SECOND, read_at)
    else:
        admitted = ref.reservoir(samples, param)
    return {r.agg: r.answer(admitted, model) for r in reads}


# ---------------------------------------------------------------------------
# The streams.

_FLOATS = st.one_of(
    st.floats(allow_nan=False, allow_infinity=True, width=64),
    st.sampled_from([0.0, -0.0, 1.0, -1.0, 0.1, 2.5]),
)
_INTS = st.one_of(
    st.integers(-5, 5),
    st.sampled_from([INT64_MIN, INT64_MAX, INT64_MIN + 1, INT64_MAX - 1]),
    st.integers(INT64_MIN, INT64_MAX),
)
VALUES = {
    "Float": _FLOATS,
    "Int": _INTS,
    "Bool": st.booleans(),
    "String": st.sampled_from(["a", "b", "", "ab", "é"]),
}

# Gaps between absorptions, in quarter seconds, so a sample lands exactly a
# window's width before a read often enough ([LSIG.2.2.4]'s open bound).
_GAPS = st.integers(0, 8).map(lambda q: q * (SECOND // 4))

PARAMS = {"all_time": (0,), "sliding": (1, 3), "sample": (1, 3, 8)}

CASES = [
    (slot, model, param)
    for slot in VALUES
    for model in ref.TIME_MODELS
    for param in PARAMS[model]
    if _reads(slot, model)
]


@st.composite
def streams(draw, slot: str):
    """Samples on a non-decreasing clock, and a read instant at or after the
    last. The clock is the engine's, so a later absorption never carries an
    earlier stamp: out-of-order stamps are not a case a series sees."""
    vs = draw(st.lists(VALUES[slot], max_size=12))
    t = draw(_GAPS)
    samples = []
    for v in vs:
        samples.append(ref.Sample(t, v))
        t += draw(_GAPS)
    return samples, t


# What the property compared in this run, which the census prints: a property
# that ran over nothing reads as zero here, not as a pass.
_COMPARED = {"examples": 0, "reads": 0, "cold": 0, "nan_dropped": 0}
# Examples compared, per program that ran.
_PER_PROGRAM: dict[str, int] = {}


@pytest.mark.parametrize(("slot", "model", "param"), CASES,
                         ids=[f"{s}-{m}-{p}" for s, m, p in CASES])
def test_every_read_equals_the_reference(slot, model, param):
    reads = _reads(slot, model)
    src = program(slot, model, param)
    label = f"{slot} {_model_clause(model, param)}"
    compared = 0

    # `database=None`: the property is defined inside this test, so every
    # program would share one database key, and one program's saved example
    # would be replayed against another's.
    @settings(max_examples=MAX_EXAMPLES, deadline=None, database=None,
              suppress_health_check=[HealthCheck.too_slow,
                                     HealthCheck.filter_too_much])
    @given(data=st.data())
    def every_read(data):
        nonlocal compared
        samples, read_at = data.draw(streams(slot))
        want, dropped = split_nan(
            reference_reads(reads, model, param, samples, read_at))
        got = libds_reads(src, samples, read_at, PROBE_VALUE[slot])
        _COMPARED["nan_dropped"] += len(dropped)
        if want:
            compared += 1
            _COMPARED["examples"] += 1
            _COMPARED["reads"] += len(want)
            _COMPARED["cold"] += not samples
        check_reads(got, want,
                    f"{label} over {[(s.t, s.v) for s in samples]} "
                    f"read at {read_at}")

    every_read()
    _PER_PROGRAM[label] = compared
    check_floor(compared, label)


def test_an_answer_one_ulp_off_is_reported():
    """The negative fixture: a reference `mean` one ULP away from libds's must
    fail the comparison the property uses, and so must a `null` read against
    a value."""
    samples = [ref.Sample(0, 0.1), ref.Sample(SECOND, 0.2),
               ref.Sample(2 * SECOND, 0.7)]
    reads = _reads("Float", "sliding")
    want = reference_reads(reads, "sliding", 3, samples, 2 * SECOND)
    got = libds_reads(program("Float", "sliding", 3), samples, 2 * SECOND,
                      0.0)
    check_reads(got, want, "the fixture's stream")
    off = dict(want)
    off["mean"] = math.nextafter(want["mean"], math.inf)
    with pytest.raises(AssertionError, match="mean: libds"):
        check_reads(got, off, "one ULP off")
    off = dict(want)
    off["min"] = None
    with pytest.raises(AssertionError, match="min: libds"):
        check_reads(got, off, "null against a value")


def test_a_nan_read_is_dropped_alone():
    """The negative fixture for the per-read drop: over a stream holding both
    infinities the reference's `mean` is NaN and is dropped, alone; `min`
    beside it is still compared, and a wrong `min` is still reported."""
    samples = [ref.Sample(0, math.inf), ref.Sample(SECOND, -math.inf)]
    reads = _reads("Float", "all_time")
    want, dropped = split_nan(
        reference_reads(reads, "all_time", 0, samples, SECOND))
    assert "mean" in dropped
    assert want["min"] == -math.inf
    assert not any(isinstance(w, float) and math.isnan(w)
                   for w in want.values())
    got = libds_reads(program("Float", "all_time", 0), samples, SECOND, 0.0)
    check_reads(got, want, "the fixture's infinities")
    off = dict(want)
    off["min"] = math.inf
    with pytest.raises(AssertionError, match="min: libds"):
        check_reads(got, off, "min beside a dropped NaN")


def test_a_thin_program_is_refused():
    """The negative fixture for the floor: one example under it fails the
    check the property uses, and the floor itself passes."""
    check_floor(FLOOR, "at the floor")
    with pytest.raises(AssertionError, match="under the floor"):
        check_floor(FLOOR - 1, "one under the floor")


# ---------------------------------------------------------------------------
# The census ([LSER.18.1]): which cells the property covers, printed every run.

NOT_COVERED_TYPES = {
    "Duration": "the `time` dimension's reads return `Duration?` through "
                "`duration_of` and its sum raises past the range; not driven "
                "here",
    "Time": "no aggregation over a `Time` slot is generated",
    "Date": "no aggregation over a `Date` slot is generated",
}


def census() -> tuple[list[str], list[str]]:
    covered, not_covered = [], []
    for cell, models in ref.EXACT_CELLS.items():
        for model in models:
            for slot in ref.ADMITTED_TYPES[cell]:
                name = f"{cell:<15} {model:<9} {slot}"
                if slot in VALUES:
                    covered.append(name)
                else:
                    not_covered.append(f"{name}: {NOT_COVERED_TYPES[slot]}")
    return covered, not_covered


def test_census(capsys):
    covered, not_covered = census()
    lines = [f"series backend census ([LSER.18.1]): {len(covered)} cells "
             f"covered, {len(not_covered)} not; this run compared "
             f"{_COMPARED['reads']} reads over {_COMPARED['examples']} "
             f"examples, {_COMPARED['cold']} of them cold, in "
             f"{len(_PER_PROGRAM)} of {len(CASES)} programs, and dropped "
             f"{_COMPARED['nan_dropped']} NaN reads"]
    if _PER_PROGRAM:
        fewest = min(_PER_PROGRAM, key=lambda p: _PER_PROGRAM[p])
        lines.append(f"  fewest examples compared: {_PER_PROGRAM[fewest]} "
                     f"({fewest}), floor {FLOOR} per program")
    lines += [f"  covered      {c}" for c in covered]
    lines += [f"  not covered  {c}" for c in not_covered]
    lines += [
        "  across every cell: a read whose reference is NaN is dropped and "
        "counted, the example's other reads compared (no slot holds a NaN, "
        "[LEXP.4.2]); `capacity:` is not declared; out-of-order stamps do "
        "not occur on the engine's clock; `pXX` is read at p1, p25, p75 and "
        "p99 beside `median`",
    ]
    # Past pytest's capture, so the census reaches the run's log whether the
    # test passes or not.
    with capsys.disabled():
        print("\n" + "\n".join(lines), flush=True)
    # Every cell the matrix marks exact is either covered or named.
    total = sum(len(ref.ADMITTED_TYPES[c]) * len(ms)
                for c, ms in ref.EXACT_CELLS.items())
    assert len(covered) + len(not_covered) == total
    assert covered


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
