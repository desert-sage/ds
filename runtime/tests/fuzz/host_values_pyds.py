# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""fuzz_host_values's op scripts through pyds.

    host_values_pyds.py PROGRAM.dsc DIR [DIR ...]
    host_values_pyds.py --self-test

fuzz_host_values.c hands libds.h the values a host asserts. This hands the
same scripts to pyds, so the C glue that turns Python values into libds's
(`_pyds/engine.c`) meets them too, and holds the run to the C target's
checks, in Python's terms. Every regular file in each DIR is one input, in
name order, one engine each, on the mock clock with the wall clock set.

THE SCRIPT is fuzz_host_values.c's, read the same way: an op byte taken
modulo eight (ASSERT, PUMP, ADVANCE, WALL, SEED, WHEN, ZONE, IDS) and its
operands, and a script that runs out of bytes mid-op stops there. Its values
become Python's:

    id   the byte modulo 8, an int
    s    the octets decoded as UTF-8 with `surrogateescape`, a str: octets
         that are not well-formed UTF-8 become lone surrogates
    u    the octets themselves, bytes, which pyds hands libds unchanged
    i    an int; f a float, NaN included; ok a bool
    b    bytes
    j    the octets as JSON text through `json.loads` (no NaN or Infinity
         constants), None where it refuses them; a lone surrogate the text
         escapes stays one
    SEED the key as `s` is decoded, the value as JSON text, bytes
    WHEN a When: id as above, t and d ints, z decoded as `s` is
    ZONE a TimeZoneOffset: zone decoded as `s` is, the three others ints
    IDS  `pyds.Engine(run_id=..., tier_id=...)`, each decoded as `s` is,
         replaces the engine; refused, the engine stays

WHAT IT ASSERTS, each a finding that ends the run with exit 1:

  1. EVERY REFUSAL IS ONE PYDS DOCUMENTS. An assert raises `pyds.Error` with
     a status libds.h names for ds_engine_assert (and the Json builders'
     JSON_NONFINITE and JSON_LIMIT), or the builtin pyds names for a value
     Python holds and DS does not: ValueError for a U+0000 or a lone
     surrogate (UnicodeEncodeError is one), OverflowError for a Json int
     outside int64. A seed, the same for ds_engine_cache_seed. Anything
     else, a TypeError included, is a finding: every value has its slot's
     type.
  2. A LONE SURROGATE IS NEVER TAKEN ([LSTR.8.5], [LSTR.1.1]). An assert
     whose `s`, or any str in its `j`, or a When's `z`, or a row's `zone`,
     holds one must be refused, and so must an engine whose run or tier id
     does ([NLFC.1.2]).
  3. NO HOST VALUE HALTS THE ENGINE. A pump that raises with ENGINE_HALTED
     is a finding, named with the EngineError the stream carried.
  4. WHAT LEAVES THE ENGINE IS WELL-FORMED. Every log message, String call
     argument, cache key and cache value is a str with no lone surrogate and
     no U+0000, and every Json value is JSON text Python reads.
  5. A CALL IS THE ONE DECLARED: `sink.take`, its arguments sorted by name,
     each of the type its kwarg declares, and no NaN.
  6. NOTHING IS REPORTED UNRAISABLE. pyds sends an exception it cannot
     raise to `sys.unraisablehook`, a failed conversion of an event or a
     callback's own error among them; this driver counts each as a finding.

At exit it prints its counts, which the gate reads: every input judged, and
an assert, a pump, a log, a call, a cache write, a When, a zone row, an
engine with ids and a refused surrogate each seen at least once over the
seeds.
"""
from __future__ import annotations

import json
import math
import pathlib
import struct
import sys

import pyds

OPS = 8
OP_ASSERT, OP_PUMP, OP_ADVANCE, OP_WALL, OP_SEED, OP_WHEN, OP_ZONE, OP_IDS = range(OPS)

# The statuses each call may answer with, as fuzz_host_values.c's
# `assert_documented` and `seed_documented` list them; the assert also takes
# what pyds's Json builders give a value (`pyds_py_to_json_tree`), and the
# seed what ds_json_parse gives the text pyds hands it.
ASSERT_STATUSES = {-1, -104, -222, -205, -216, -710, -217, -221}
SEED_STATUSES = {-4, -222, -710, -205, -217, -100, -221}
ADVANCE_STATUSES = {-205}
PUMP_STATUSES = {-710}
NEW_STATUSES = {-222}
ENGINE_HALTED = -10

WALL_NS = 1_700_000_000_000_000_000
KWARGS = ["b", "f", "i", "j", "s"]

findings: list[str] = []
counts = {"judged": 0, "asserted": 0, "pumped": 0, "logged": 0, "called": 0,
          "cached": 0, "timed": 0, "zoned": 0, "named": 0, "surrogates": 0}


def finding(why: str) -> None:
    findings.append(why)


def _unraisable(u: object) -> None:
    exc = getattr(u, "exc_value", None)
    finding(f"unraisable: {exc!r} in {getattr(u, 'object', None)!r}")


def has_surrogate(v: object) -> bool:
    if isinstance(v, str):
        return any(0xD800 <= ord(c) <= 0xDFFF for c in v)
    if isinstance(v, (list, tuple)):
        return any(has_surrogate(x) for x in v)
    if isinstance(v, dict):
        return any(has_surrogate(k) or has_surrogate(x) for k, x in v.items())
    return False


def well_formed(text: object, what: str) -> None:
    if not isinstance(text, str):
        finding(f"{what} is {type(text).__name__}, not str")
    elif "\0" in text or has_surrogate(text):
        finding(f"{what} is not well-formed: {text!r}")


class Reader:
    def __init__(self, data: bytes) -> None:
        self.data, self.at = data, 0

    def take(self, n: int) -> bytes | None:
        if len(self.data) - self.at < n:
            return None
        out = self.data[self.at:self.at + n]
        self.at += n
        return out

    def str_(self) -> bytes | None:
        n = self.take(2)
        return None if n is None else self.take(n[0] | n[1] << 8)


def _no_constant(name: str) -> object:
    raise ValueError(f"JSON constant {name}")


def json_value(octets: bytes) -> object:
    try:
        return json.loads(octets.decode("utf-8", "surrogateescape"),
                          parse_constant=_no_constant)
    except (ValueError, RecursionError):
        return None


def refused(exc: BaseException, statuses: set[int]) -> bool:
    """Whether `exc` is a refusal pyds documents for the call."""
    if isinstance(exc, pyds.Error):
        return exc.status is not None and int(exc.status) in statuses
    return isinstance(exc, (ValueError, OverflowError))


def on_log(ev: object) -> None:
    counts["logged"] += 1
    well_formed(getattr(ev, "message", None), "a log message")


def on_call(req: dict) -> None:
    counts["called"] += 1
    if req.get("service") != "sink.take":
        finding(f"a call names a service the program does not call: {req!r}")
    if not req.get("correlation"):
        finding("a call has no correlation")
    args = req.get("args", {})
    if list(args) != KWARGS:
        finding(f"a call's arguments are not its kwargs, sorted by name: {list(args)}")
        return
    if not isinstance(args["b"], bytes):
        finding(f"call argument b is {type(args['b']).__name__}, not bytes")
    f = args["f"]
    if not isinstance(f, float) or math.isnan(f):
        finding(f"call argument f is {f!r}")
    if not isinstance(args["i"], int) or isinstance(args["i"], bool):
        finding(f"call argument i is {args['i']!r}")
    if not isinstance(args["j"], pyds.JsonText):
        finding(f"call argument j is {type(args['j']).__name__}, not JsonText")
    else:
        well_formed(str(args["j"]), "call argument j")
        try:
            json.loads(str(args["j"]))
        except ValueError:
            finding(f"call argument j is not JSON text: {args['j']!r}")
    well_formed(args["s"], "call argument s")


def on_cache_set(key: object, value_json: object, ttl_ns: object) -> None:
    counts["cached"] += 1
    if key not in ("s", "j"):
        finding(f"a rule wrote a cache key the program does not write: {key!r}")
    well_formed(value_json, "a cache value")


def text(octets: bytes) -> str:
    return octets.decode("utf-8", "surrogateescape")


def asserted(engine: pyds.Engine, schema: str, slots: dict, lone: bool,
             count: str) -> None:
    """Assert one fact, judged as an ASSERT is: a documented refusal, and
    a lone surrogate never taken. `count` is the count an accepted one adds
    to."""
    try:
        engine.assert_(schema, **slots)
    except Exception as exc:  # noqa: BLE001 -- judged, not swallowed
        if not refused(exc, ASSERT_STATUSES):
            finding(f"assert_ {schema} raised what pyds does not document: {exc!r}")
        if lone:
            counts["surrogates"] += 1
        return
    if lone:
        finding(f"a lone surrogate was taken by {schema}: {slots!r}")
    counts[count] += 1


def engine_up(program: bytes, halts: list, **ids: str) -> pyds.Engine:
    """A new engine with these ids, the program loaded and set up as every
    input's is. pyds.Engine raises for ids it refuses, as ds_engine_new
    does."""
    engine = pyds.Engine(**ids)
    try:
        engine.load_dsc(program)
        engine.clock.mode = pyds.ClockMode.MOCK
        engine.clock.set_wall(WALL_NS)
        engine.on_log = on_log
        engine.set_call_callback(on_call)
        engine.on_cache_set = on_cache_set
        engine.on_event = (lambda ev: halts.append(ev)
                           if isinstance(ev, pyds.events.EngineError) else None)
    except BaseException:
        engine.close()
        raise
    return engine


def run(engine: pyds.Engine, program: bytes, data: bytes, halts: list) -> pyds.Engine:
    """The script's ops on `engine`, or on the engine an IDS put in its
    place, which is returned."""
    r = Reader(data)
    while (op := r.take(1)) is not None:
        op = op[0] % OPS
        if op == OP_WHEN:
            fields = [r.take(1), r.take(8), r.take(8), r.str_()]
            if any(x is None for x in fields):
                return engine
            fid, t, d, z = fields
            slots = dict(id=fid[0] % 8, t=struct.unpack("<q", t)[0],
                         d=struct.unpack("<q", d)[0], z=text(z))
            asserted(engine, "When", slots, has_surrogate(slots["z"]), "timed")
            continue
        if op == OP_ZONE:
            fields = [r.str_(), r.take(8), r.take(8), r.take(8)]
            if any(x is None for x in fields):
                return engine
            name, start, until, offset = fields
            slots = dict(zone=text(name), valid_from=struct.unpack("<q", start)[0],
                         valid_until=struct.unpack("<q", until)[0],
                         offset_s=struct.unpack("<q", offset)[0])
            asserted(engine, "TimeZoneOffset", slots, has_surrogate(slots["zone"]),
                     "zoned")
            continue
        if op == OP_IDS:
            run_id, tier_id = r.str_(), None
            if run_id is not None:
                tier_id = r.str_()
            if tier_id is None:
                return engine
            ids = dict(run_id=text(run_id), tier_id=text(tier_id))
            lone = has_surrogate(ids["run_id"]) or has_surrogate(ids["tier_id"])
            try:
                fresh = engine_up(program, halts, **ids)
            except Exception as exc:  # noqa: BLE001 -- judged, not swallowed
                if not refused(exc, NEW_STATUSES):
                    finding(f"pyds.Engine raised what pyds does not document: {exc!r}")
                if lone:
                    counts["surrogates"] += 1
                continue
            if lone:
                finding(f"a lone surrogate was taken as an engine id: {ids!r}")
            pump(engine, halts)
            engine.close()
            engine = fresh
            counts["named"] += 1
            continue
        if op == OP_ASSERT:
            fields = [r.take(1), r.str_(), r.str_(), r.take(8), r.take(8), r.take(1),
                      r.str_(), r.str_()]
            if any(x is None for x in fields):
                return engine
            fid, s, u, i, f, ok, b, j = fields
            slots = dict(id=fid[0] % 8, s=text(s), u=u,
                         i=struct.unpack("<q", i)[0], f=struct.unpack("<d", f)[0],
                         ok=bool(ok[0] & 1), b=b, j=json_value(j))
            asserted(engine, "Host", slots,
                     has_surrogate(slots["s"]) or has_surrogate(slots["j"]), "asserted")
        elif op == OP_PUMP:
            pump(engine, halts)
        elif op == OP_ADVANCE:
            us = r.take(4)
            if us is None:
                return engine
            try:
                engine.clock.advance(struct.unpack("<I", us)[0] * 1000)
            except Exception as exc:  # noqa: BLE001 -- judged, not swallowed
                if not refused(exc, ADVANCE_STATUSES):
                    finding(f"clock.advance raised what pyds does not document: {exc!r}")
        elif op == OP_WALL:
            utc = r.take(8)
            if utc is None:
                return engine
            engine.clock.set_wall(struct.unpack("<q", utc)[0])
        else:
            key, val = r.str_(), None
            if key is not None:
                val = r.str_()
            if val is None:
                return engine
            try:
                engine.cache.seed(text(key), val)
            except Exception as exc:  # noqa: BLE001 -- judged, not swallowed
                if not refused(exc, SEED_STATUSES):
                    finding(f"cache.seed raised what pyds does not document: {exc!r}")
    return engine


def pump(engine: pyds.Engine, halts: list) -> None:
    counts["pumped"] += 1
    try:
        engine.pump()
    except pyds.Error as exc:
        status = None if exc.status is None else int(exc.status)
        if status == ENGINE_HALTED:
            finding(f"a host value halted the engine: {halts!r} {exc}")
        elif status not in PUMP_STATUSES:
            finding(f"pump raised a status pyds does not document: {exc}")


def judge(program: bytes, data: bytes) -> None:
    halts: list = []
    engine = engine_up(program, halts)
    try:
        engine = run(engine, program, data, halts)
        pump(engine, halts)
    finally:
        engine.close()


def self_test() -> list[str]:
    """The checks above, each fed what it must refuse and what it must take:
    the gate runs this before the scripts, so a check that stopped refusing
    fails the run rather than passing it. Returns what did not hold."""
    bad: list[str] = []

    def expect(ok: bool, what: str) -> None:
        if not ok:
            bad.append(what)

    expect(has_surrogate("a\udcff"), "has_surrogate misses a lone low surrogate")
    expect(has_surrogate({"k": ["x", "\ud800"]}), "has_surrogate misses one in a list")
    expect(has_surrogate({"\udc80": 1}), "has_surrogate misses one in a key")
    expect(not has_surrogate({"k": ["é", "😀"]}), "has_surrogate flags a pair")
    expect(has_surrogate(json_value(b'{"a": "\\ud800"}')),
           "json_value repairs an escaped lone surrogate")
    expect(json_value(b"NaN") is None, "json_value takes a NaN constant")
    expect(json_value(b"{oops") is None, "json_value takes bad text")
    before = len(findings)
    well_formed("ok é", "self-test")
    expect(len(findings) == before, "well_formed refuses well-formed text")
    for text in ("a\0b", "a\udcff", b"bytes"):
        well_formed(text, "self-test")
    expect(len(findings) == before + 3, "well_formed takes a NUL, a surrogate or bytes")
    del findings[before:]
    expect(refused(pyds.Error(-222, "x"), ASSERT_STATUSES), "ENCODING not taken")
    expect(refused(ValueError("NUL"), ASSERT_STATUSES), "ValueError not taken")
    expect(refused(UnicodeEncodeError("utf-8", "\ud800", 0, 1, "x"), ASSERT_STATUSES),
           "UnicodeEncodeError not taken")
    expect(not refused(pyds.Error(-10, "halted"), ASSERT_STATUSES),
           "ENGINE_HALTED taken for an assert")
    expect(not refused(pyds.Error(None, "x"), ASSERT_STATUSES), "no status taken")
    expect(not refused(TypeError("slot"), ASSERT_STATUSES), "TypeError taken")
    expect(not refused(pyds.Error(-4, "state"), ASSERT_STATUSES), "STATE taken for an assert")
    expect(refused(pyds.Error(-4, "state"), SEED_STATUSES), "STATE not taken for a seed")
    expect(refused(pyds.Error(-205, "range"), ADVANCE_STATUSES),
           "TIME_RANGE not taken for an advance")
    expect(not refused(pyds.Error(-4, "state"), ADVANCE_STATUSES), "STATE taken for an advance")
    expect(refused(pyds.Error(-222, "x"), NEW_STATUSES), "ENCODING not taken for ids")
    expect(not refused(pyds.Error(-1, "x"), NEW_STATUSES), "INVAL taken for ids")
    r = Reader(b"\x03\x00abc\x05")
    expect(r.str_() == b"abc" and r.take(1) == b"\x05" and r.take(1) is None,
           "Reader reads a str operand wrong")
    return bad


def main(argv: list[str]) -> int:
    if argv[1:] == ["--self-test"]:
        bad = self_test()
        for b in bad:
            print(f"host_values_pyds: self-test: {b}", file=sys.stderr)
        print(f"host_values_pyds: self-test: {'FAILED' if bad else 'ok'}", flush=True)
        return 1 if bad else 0
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    sys.unraisablehook = _unraisable
    program = pathlib.Path(argv[1]).read_bytes()
    for d in argv[2:]:
        for path in sorted(p for p in pathlib.Path(d).iterdir() if p.is_file()):
            data = path.read_bytes()
            if not data:
                continue
            counts["judged"] += 1
            judge(program, data)
            if findings:
                print(f"host_values_pyds: {path}: {data.hex()}", file=sys.stderr)
                for f in findings:
                    print(f"host_values_pyds: {f}", file=sys.stderr)
                return 1
    print(summary(), flush=True)
    return 0


def summary() -> str:
    """The counts line the gate reads (scripts/private/gate/gate.py `_binding_judged_all`)."""
    return (f"host_values_pyds: judged {counts['judged']} input(s): "
            f"{counts['asserted']} asserted, {counts['pumped']} pumped, "
            f"{counts['logged']} logged, {counts['called']} called, "
            f"{counts['cached']} cached, {counts['timed']} timed, "
            f"{counts['zoned']} zoned, {counts['named']} named, "
            f"{counts['surrogates']} surrogates refused")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
