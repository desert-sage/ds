#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The pyds harness: one program that drives every feature of pyds.

It is an example of what an integration does, and nothing more: no
application logic, and a program, ``harness.ds`` beside this file, whose rules
each reach one feature an integrator handles. ``main`` runs the stages in the
order the features depend on one another, and each stage logs what it calls
and what came back, as every callback logs when it runs. Read the log top to
bottom.

It ends with ``harness: OK`` and exits 0, or raises at the first thing that
does not do what the log says it does. The pyds test suite runs it.

Run it with an installed pyds and a ``dsc`` it can find::

    python harness.py
"""

import os
import tempfile
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pyds
import pyds.atoms
from pyds import (
    Admission,
    Capability,
    ClockMode,
    FactId,
    events,
)

HERE = Path(__file__).resolve().parent
SEC = 1_000_000_000

# A Time 23:30 UTC on day 19000, and the date it falls on in a zone one hour
# ahead of UTC: the zone's `TimeZoneOffset` row (assert_facts) states that
# offset.
SEEN_NS = (19_000 * 86_400 + 84_600) * SEC
DAY_AHEAD = 19_001
ZONE = "Harness/Zone"
ZONE_OFFSET_S = 3_600


def stage(name: str) -> None:
    """Head one stage of the log."""
    print(f"\n== {name} ==")


def log(text: str) -> None:
    """Log one line of a stage."""
    print(f"  {text}")


def expect(condition: bool, what: str) -> None:
    """Stop the harness if ``condition`` is false; ``what`` says what held."""
    if not condition:
        raise RuntimeError(f"harness: expected {what}")
    log(f"ok   {what}")


# --- Callbacks: one handler for each, logging whatever reaches it ---------


def on_event(ev: events.Event) -> None:
    """Every stream event, as a ``pyds.events`` value."""
    match ev:
        case events.FactAssert(fact_id=fid) | events.FactRetract(fact_id=fid):
            log(f"[on_event] {ev.kind} {fid!r}")
        case events.RuleFireBegin(rule_name=rule):
            log(f"[on_event] {ev.kind} {rule}")
        case events.ComputationError(trap_kind=trap, rule_name=rule):
            log(f"[on_event] {ev.kind} {trap.name} in {rule}")
        case _:
            log(f"[on_event] {ev.kind}")


def on_log(ev: events.LogEvent) -> None:
    """Log a rule's ``log``."""
    log(f"[on_log] {ev.level} {ev.category}: {ev.message}")


def on_metric(ev: events.Metric) -> None:
    """Log a metric the engine reports."""
    log(f"[on_metric] {ev.name} = {ev.value}")


def on_cache_set(key: str, value_json: str, ttl_ns: int) -> None:
    """Log a write to the engine's cache, which a host would mirror in its own store."""
    log(f"[on_cache_set] {key} = {value_json} ttl_ns={ttl_ns}")


def on_cache_delete(key: str, reason: pyds.CacheRemovalReason) -> None:
    """Log a key leaving the engine's cache."""
    log(f"[on_cache_delete] {key} ({reason})")


def call_recorder(calls: list[dict[str, Any]]) -> Callable[[dict[str, Any]], None]:
    """Return a call callback that queues each call, for the host to answer later."""

    def on_call(request: dict[str, Any]) -> None:
        log(
            f"[call] {request['service']} as {request['correlation']!r} "
            f"from {request['rule_name']}, args {sorted(request['args'])}"
        )
        calls.append(request)

    return on_call


# --- Stages, in the order the features depend on one another --------------


def build() -> None:
    """Log the pyds version and the capabilities this build of libds has."""
    stage("build")
    log(f"pyds {pyds.__version__}")
    names = sorted(c.name for c in pyds.BUILD_CAPABILITIES)
    log(f"BUILD_CAPABILITIES = {names}")


def compile_program() -> bytes:
    """Compile ``harness.ds`` and return the artefact."""
    stage("compile")
    dsc = pyds.compile_file(HERE / "harness.ds")
    log(f"compile_file(harness.ds) -> {len(dsc)} bytes")
    return dsc


def make_engine() -> pyds.Engine:
    """Make an engine with a run id and a tier id, admitting either setting of ``call``."""
    stage("make_engine")
    engine = pyds.Engine(run_id="harness-run", tier_id="harness-tier")
    log(f"Engine(run_id=..., tier_id=...) -> {engine!r}")
    expect(engine.run_id == "harness-run", "run_id is the one given")
    expect(engine.tier_id == "harness-tier", "tier_id is the one given")
    # Admit both settings of `call`, the default. An integration with nothing
    # behind `call` would admit FALSE_ONLY, and refuse a program that calls.
    engine.set_admission(Capability.CALL, Admission.EITHER)
    log("set_admission(Capability.CALL, Admission.EITHER)")
    return engine


def register_callbacks(engine: pyds.Engine, calls: list[dict[str, Any]]) -> None:
    """Register every callback; each call is queued in ``calls``."""
    stage("register_callbacks")
    engine.on_event = on_event
    engine.on_log = on_log
    engine.on_metric = on_metric
    engine.on_cache_set = on_cache_set
    engine.on_cache_delete = on_cache_delete
    engine.set_call_callback(call_recorder(calls))
    log("on_event, on_log, on_metric, on_cache_set, on_cache_delete, set_call_callback")


def setup_clock(engine: pyds.Engine) -> None:
    """Put the clocks in mock mode at 0, so the run is reproducible."""
    stage("setup_clock")
    engine.clock.mode = ClockMode.MOCK
    engine.clock.set(0)
    engine.clock.set_wall(0)
    log(f"clock.mode = {engine.clock.mode}, now_ns = {engine.clock.now_ns}")


def load(engine: pyds.Engine, dsc: bytes) -> None:
    """Load the artefact and log what the engine then knows of the program."""
    stage("load")
    engine.load_dsc(dsc)
    log("load_dsc(dsc)")
    expect(engine.halted is None, "the engine runs")
    log(f"schemas = {sorted(engine.schemas)}")
    log(f"rules = {list(engine.rules)}")
    reading = engine.schemas["Reading"]
    log(f"Reading: {[(s.name, s.type, s.identity) for s in reading.slots]}")
    log(f"Reading declared at {reading.source}")
    expect(reading.proto_source is not None, "Reading carries its .proto text")
    (source,) = engine.sources.values()
    log(f"sources: {source.file}, {len(source.text)} characters")
    log(f"line_spans: {len(engine.line_spans)} nodes placed in the source")


def size_engine(engine: pyds.Engine) -> None:
    """Bound the cache and seed one entry before the first pump."""
    stage("size_engine")
    engine.cache.set_cap(keys=64, bytes=65_536)
    log("cache.set_cap(keys=64, bytes=65536)")
    engine.cache.seed("greeting", '"hello"', ttl_ns=60 * SEC)
    log("cache.seed('greeting', '\"hello\"', ttl_ns=60 s)")


def assert_facts(engine: pyds.Engine) -> dict[str, FactId]:
    """Assert the program's input facts and return their ids by name."""
    stage("assert_facts")
    ids = {
        # libds carries no time-zone database: a zone's offsets are facts of
        # the built-in TimeZoneOffset, each one zone's offset over one period
        # [valid_from, valid_until), here the longest a row can state.
        "zone": engine.assert_(
            "TimeZoneOffset",
            zone=ZONE,
            valid_from=-(2**63),
            valid_until=2**63 - 1,
            offset_s=ZONE_OFFSET_S,
        ),
        "reading": engine.assert_(
            "Reading", sensor="hall", level=60, detail={"unit": "dB", "peak": 72}
        ),
        "ratio": engine.assert_("Ratio", id="r", n=7, d=0),
        "stamp": engine.assert_("Stamp", id="s", seen=SEEN_NS, day=DAY_AHEAD),
        "note": engine.assert_("Note", id="n", text="read by no rule"),
    }
    for name, fid in ids.items():
        log(f"assert {name} -> {fid!r}")
    try:
        engine.assert_("Reading", sensor="hall", level=1.5, detail=None)
    except TypeError as exc:
        log(f"a Float for an Int slot is refused: TypeError({exc})")
    return ids


def pump_and_answer(engine: pyds.Engine, calls: list[dict[str, Any]]) -> pyds.EncodedFact:
    """Pump, answer the one call, pump again; return the call's encoded argument."""
    stage("pump_and_answer")
    engine.pump()
    log("pump()")
    expect(len(calls) == 1, "rule high called probe.ask once")
    (request,) = calls
    encoded = request["args"]["reading"]
    log(f"its reading argument: {encoded.schema}, {len(encoded.data)} bytes")
    # The service's answer is a fact of its response schema, with the call's
    # correlation, asserted by the host once it has one.
    engine.assert_("Answer", corr=request["correlation"])
    engine.pump()
    log("assert_('Answer', corr=...); pump()")
    calls.clear()
    return encoded


def read_facts(engine: pyds.Engine, ids: dict[str, FactId]) -> None:
    """Read working memory back and check what the rules derived."""
    stage("read_facts")
    log(f"len(facts) = {len(engine.facts)}")
    reading = engine.facts[ids["reading"]]
    log(f"facts[reading] -> {reading.schema} {dict(reading.slots)}")
    expect(
        isinstance(reading.slots["detail"], pyds.JsonText),
        "a Json slot reads as its canonical text",
    )
    log(f"asserted_ns = {reading.asserted_ns}, ttl_deadline_ns = {reading.ttl_deadline_ns}")
    (trace,) = engine.facts.of("Trace")
    expect(trace.slots["target"] == ids["reading"], "Trace's fact-ref slot holds the Reading's id")
    expect(ids["reading"] in engine.facts, "the Reading is live")
    expect(
        [f.slots["sensor"] for f in engine.facts.of("High")] == ["hall"], "rule high emitted High"
    )
    expect(engine.facts.of("Quotient") == [], "the faulted division emitted nothing")
    faults = engine.facts.of("ComputationError")
    expect(len(faults) == 1, "the fault is a ComputationError fact")


# NO `read_series` STAGE: no public function reads a series
# ([NSBK.6.3]). harness.ds's rules read the series, as any program does.


def introspect(engine: pyds.Engine, ids: dict[str, FactId]) -> None:
    """Log the engine's introspection reads, the debugger's included."""
    stage("introspect")
    log(f"memory_usage() -> {engine.memory_usage()}")
    log(f"platform_signature -> {engine.platform_signature}")
    log(f"session_header -> {engine.session_header}")
    (high,) = engine.facts.of("High")
    log(f"debug.justifiers(High) -> {engine.debug.justifiers(high.id)}")
    network = engine.debug.network(rule_filter="high")
    log(
        f"debug.network(rule_filter='high') -> {len(network.nodes)} nodes, "
        f"{len(network.edges)} edges"
    )
    trace = engine.debug.match_trace(ids["reading"])
    log(f"debug.match_trace(reading) -> {len(trace)} steps")
    log(f"debug.refracted() -> {len(engine.debug.refracted())} activations")


def errors(engine: pyds.Engine) -> None:
    """Show a refusal of pyds's own and one of libds's, and how each is raised."""
    stage("errors")
    try:
        engine.assert_("NoSuchSchema", id="x")
    except KeyError as exc:
        log(f"assert_ of an unknown schema: KeyError({exc})")
    try:
        engine.assert_external(b"\x00")
    except pyds.Error as exc:
        expect(exc.status is pyds.Status.PARSE, "libds's refusal is a pyds.Error with its status")
        log(f"{type(exc).__name__}: {exc}")


def exchange(dsc: bytes, encoded: pyds.EncodedFact) -> None:
    """Hand an encoded fact to a second engine with the same program."""
    stage("exchange")
    with pyds.Engine() as other:
        other.load_dsc(dsc)
        other.assert_external(encoded)
        log("another engine: load_dsc(dsc); assert_external(EncodedFact)")
        (reading,) = other.facts.of("Reading")
        expect(reading.slots["sensor"] == "hall", "the other engine holds the Reading")


def record_and_replay(dsc: bytes, workdir: Path) -> None:
    """Record a run into ``workdir``, read the stream's atoms, and replay it."""
    stage("record_and_replay")
    path = workdir / "harness.dstrace"
    with pyds.Engine() as writer:
        writer.load_dsc(dsc)
        with writer.record(path):
            writer.assert_("Reading", sensor="cellar", level=10, detail={})
            writer.pump()
    log(f"record({path.name}) -> {path.stat().st_size} bytes")
    stream = path.read_bytes()
    atoms = list(pyds.atoms.iter_atoms(stream))
    log(f"pyds.atoms.iter_atoms(stream) -> {len(atoms)} atoms")
    log(f"first atom: {pyds.atoms.message_name(int(atoms[0].kind))}")
    with pyds.Engine() as reader:
        reader.load_dsc(dsc)
        result = reader.replay(stream)
        log(f"replay(stream) -> {result}")
        expect(result.asserts == 1, "the replay asserted the recorded Reading")


def clone(engine: pyds.Engine) -> None:
    """Clone the engine and check the copy holds the same working memory."""
    stage("clone")
    with engine.clone() as copy:
        log(f"clone() -> {copy!r}, {len(copy.facts)} facts")
        expect(len(copy.facts) == len(engine.facts), "the clone holds the same working memory")


def time_passes(engine: pyds.Engine) -> None:
    """Advance the mock clock past a TTL and check the fact expired."""
    stage("time_passes")
    expect(len(list(engine.facts.of("Answer"))) == 1, "the Answer is live")
    engine.clock.advance(61 * SEC)
    engine.pump()
    log("clock.advance(61 s); pump()")
    expect(not list(engine.facts.of("Answer")), "the Answer expired: its schema's TTL is 1 min")


def teardown(engine: pyds.Engine, ids: dict[str, FactId]) -> None:
    """Retract the Reading, check truth maintenance withdrew what it supported, close."""
    stage("teardown")
    engine.retract(ids["reading"])
    engine.pump()
    log("retract(reading); pump()")
    expect(engine.facts.of("High") == [], "truth maintenance withdrew High with its Reading")
    engine.close()
    expect(engine.closed, "close() released the engine")


def main() -> int:
    """Run every stage in order; return the exit status."""
    build()
    dsc = compile_program()
    calls: list[dict[str, Any]] = []
    with tempfile.TemporaryDirectory(dir=os.getcwd()) as tmp:
        engine = make_engine()
        register_callbacks(engine, calls)
        setup_clock(engine)
        load(engine, dsc)
        size_engine(engine)
        ids = assert_facts(engine)
        encoded = pump_and_answer(engine, calls)
        read_facts(engine, ids)
        introspect(engine, ids)
        errors(engine)
        exchange(dsc, encoded)
        record_and_replay(dsc, Path(tmp))
        clone(engine)
        time_passes(engine)
        teardown(engine, ids)
    print("\nharness: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
