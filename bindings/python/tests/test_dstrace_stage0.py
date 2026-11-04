# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""`dstrace -i` stage 0 — the five runtime checks its specification rests on.

tools/dsdb/DSTRACE_INTERACTIVE.md §10.10 lists five claims read from the code
and not yet run. Each test below is one of them. A failure message says what
was seen, because a failing check is a design input, not only a regression.

1. An `emit` may set a fact-reference slot from a pattern binding.
2. Distinct referenced facts give distinct hit facts, each withdrawn when its
   own match ends, even when the referenced facts' values are identical.
3. The integrator may assert into an `ambient` schema, and into a `logical`
   schema the program's rules also derive.
4. A query engine driven record by record (spec §7.3) expires TTL facts inside
   the same cascade as the recording's TTL_EXPIRED withdrawals, and ends with
   the recording's working memory.
5. A program engine fed only the recording's inputs (spec §8.2) reproduces its
   fact ids, rule firings and withdrawals.
"""

from __future__ import annotations

import dataclasses

import pyds
from pyds import AtomKind, atoms
from pyds.proto import fact_withdraw_pb2

_TTL_EXPIRED = fact_withdraw_pb2.FactWithdraw.TTL_EXPIRED
_SEC = 1_000_000_000


# ── helpers ────────────────────────────────────────────────────────────


def _load(source: str) -> pyds.Engine:
    """pyds.from_source, with every compile error spelled out.

    The Python compiler's MultiError says only how many errors there were,
    and a refused test program must say why.
    """
    try:
        return pyds.from_source(source)
    except Exception as exc:
        errs = getattr(exc, "errors", None)
        if not errs:
            raise
        raise AssertionError(
            "compile refused:\n"
            + "\n".join(
                f"  {getattr(e, 'code', '?')} line {getattr(e, 'line', '?')}: "
                f"{getattr(e, 'message', e)}"
                for e in errs
            )
        ) from exc


def _watch(eng: pyds.Engine) -> list[dict]:
    """Install a stream callback that records events AS THEY ARRIVE.

    Each event becomes this test's own record: a dict of its fields and its
    kind, with what the checks below join on added. An emitted fact's slot
    values are read inside the callback, while it is certainly live.
    """
    events: list[dict] = []

    def cb(ev: pyds.events.Event) -> None:
        e = {f.name: getattr(ev, f.name) for f in dataclasses.fields(ev)}
        e["kind"] = ev.kind
        kind = ev.kind
        # A publish names no fact: it puts none in working memory ([LTIE.4.3]).
        if kind in ("fact_assert", "fact_retract", "action_emit"):
            e["id"] = e["fact_id"]
        if kind == "action_emit":
            e["fact"] = eng.facts[e["fact_id"]]
        if kind == "rule_lhs_facts":
            e["ids"] = list(e["lhs_facts"])
        events.append(e)

    eng.on_event = cb
    return events


def _hits(events: list[dict], rule: str) -> dict[int, list[int]]:
    """Hit fact id -> the matched fact ids of the firing that emitted it."""
    out: dict[int, list[int]] = {}
    lhs: list[int] = []
    current = None
    for e in events:
        if e["kind"] == "rule_lhs_facts":
            lhs = e["ids"]
        elif e["kind"] == "rule_fire_begin":
            current = e["rule_name"]
        elif e["kind"] == "rule_fire_end":
            current = None
        elif e["kind"] == "action_emit" and current == rule:
            out[e["id"]] = list(lhs)
    return out


def _records(data: bytes, eng: pyds.Engine) -> list[dict]:
    """Read a C-recorded trace into records through libds's reader (`pyds.atoms`).

    Each fact body is typed by libds against ``eng``'s artefact
    (`Engine.decode_fact_body`).
    """
    out: list[dict] = []
    for i, atom in enumerate(atoms.iter_atoms(data)):
        kind = atom.kind
        rec: dict = {"i": i, "kind": kind}
        if kind in (AtomKind.FACT_ASSERT, AtomKind.FACT_EMIT):
            m = atom.message()
            rec.update(
                fact_id=m.fact_id,
                schema_name=m.schema_name,
                seq=m.seq,
                clock_ns=m.clock_ns,
                slots=eng.decode_fact_body(m.schema_name, m.fact),
            )
            if kind is AtomKind.FACT_EMIT:
                rec.update(rule_name=m.rule_name, ttl_ns=m.ttl_ns)
        elif kind in (AtomKind.FACT_RETRACT, AtomKind.CLOCK_ADVANCE):
            m = atom.message()
            rec.update(seq=m.seq, clock_ns=m.clock_ns)
            if kind is AtomKind.FACT_RETRACT:
                rec.update(fact_id=m.fact_id)
        elif kind is AtomKind.RULE_FIRE_ANNOTATION:
            m = atom.message()
            rec.update(
                seq=m.seq, clock_ns=m.clock_ns, rule_name=m.rule_name, timetag=m.timetag, end=m.end
            )
        elif kind is AtomKind.FACT_WITHDRAW:
            m = atom.message()
            rec.update(fact_id=m.fact_id, cause=m.cause, seq=m.seq, clock_ns=m.clock_ns)
        out.append(rec)
    return out


def _summary(recs: list[dict]) -> str:
    return "\n".join(
        f"  {r['i']:3d} {r['kind']!r} "
        + " ".join(
            f"{k}={r[k]!r}"
            for k in ("fact_id", "schema_name", "rule_name", "cause", "clock_ns", "end")
            if k in r
        )
        for r in recs
    )


# ── checks 1 and 2: the query hit fact ─────────────────────────────────

_QUERY = """
schema Thermometer scope logical:
    entity_id: String key
    temperature: Float mutable

schema Door scope logical:
    entity_id: String key
    open: Bool mutable

schema Ping scope ttl 1_h:
    entity_id: String

schema QHit scope logical:
    t: Thermometer key
    d: Door key

schema QPing scope logical:
    t: Thermometer key
    p: Ping key

rule q:
    Thermometer t where t.temperature > 85.0
    Door d where d.entity_id == t.entity_id
->
    emit QHit logical t: t d: d

rule qp:
    Thermometer t where t.temperature > 85.0
    Ping p where p.entity_id == t.entity_id
->
    emit QPing logical t: t p: p
"""


def test_check1_emit_sets_a_fact_reference_slot_from_a_binding():
    eng = _load(_QUERY)  # raises if the compiler refuses it
    events = _watch(eng)
    eng.assert_("Thermometer", entity_id="k", temperature=90.0)
    eng.assert_("Door", entity_id="k", open=True)
    eng.pump()
    hits = [e for e in events if e["kind"] == "action_emit" and e["fact"].schema == "QHit"]
    assert len(hits) == 1, f"expected one QHit, saw {events!r}"
    slots = hits[0]["fact"].slots
    assert set(slots) == {"t", "d"}, f"QHit slots: {slots!r}"


def test_check2_distinct_references_give_distinct_hits_that_end_separately():
    eng = _load(_QUERY)
    events = _watch(eng)
    t1 = eng.assert_("Thermometer", entity_id="k1", temperature=90.0)
    eng.assert_("Thermometer", entity_id="k2", temperature=90.0)
    eng.assert_("Door", entity_id="k1", open=True)
    eng.assert_("Door", entity_id="k2", open=True)
    eng.pump()
    hits = _hits(events, "q")
    assert len(hits) == 2, f"expected two hits, saw {hits!r}"

    t1_id = t1
    before = len(events)
    eng.retract(t1)
    eng.pump()
    ended = {e["id"] for e in events[before:] if e["kind"] == "fact_retract"}
    expected = {h for h, lhs in hits.items() if t1_id in lhs}
    assert len(expected) == 1, f"hits referencing t1: {hits!r}, t1={t1_id}"
    assert expected <= ended, f"t1's hit {expected} did not end; ended={ended}"
    assert not ((set(hits) - expected) & ended), (
        f"the other hit ended too: ended={ended}, hits={hits!r}"
    )


def test_check2_identical_events_still_give_distinct_hits():
    """Two ttl facts with IDENTICAL values are two facts.

    Their hits must not coalesce — the case the fallback in spec §10.8 would
    get wrong.
    """
    eng = _load(_QUERY)
    events = _watch(eng)
    eng.assert_("Thermometer", entity_id="k", temperature=90.0)
    eng.assert_("Ping", entity_id="k")
    eng.assert_("Ping", entity_id="k")
    eng.pump()
    hits = _hits(events, "qp")
    assert len(hits) == 2, f"expected two QPing hits, saw {hits!r}"
    assert len({tuple(v) for v in hits.values()}) == 2, hits


# ── check 3: what the integrator may assert ────────────────────────────

_SCOPES = """
schema Amb scope logical ambient:
    entity_id: String key
    v: Int mutable

schema Derived scope logical:
    src: Int key

rule derive:
    Amb a
->
    emit Derived logical src: a.v
"""


def test_check3_integrator_may_assert_an_ambient_schema():
    eng = _load(_SCOPES)
    events = _watch(eng)
    eng.assert_("Amb", entity_id="x", v=1)
    eng.pump()
    fired = [e for e in events if e["kind"] == "rule_fire_begin"]
    assert fired, f"asserting Amb fired nothing: {events!r}"


def test_check3_integrator_may_assert_a_rule_derived_logical_schema():
    eng = _load(_SCOPES)
    _watch(eng)
    eng.assert_("Derived", src=7)
    eng.pump()
    assert len(eng.facts) == 1, len(eng.facts)


# ── checks 4 and 5: a recorded run, re-driven ──────────────────────────

_PROGRAM = """
schema Reading scope logical:
    entity_id: String key
    level: Float mutable

schema Alarm scope ttl 5_s:
    entity_id: String
    level: Float

schema Hot scope logical:
    entity_id: String key

rule hot:
    Reading r where r.level > 80.0
->
    emit Hot logical entity_id: r.entity_id

rule alarm:
    Reading r where r.level > 90.0
->
    emit Alarm entity_id: r.entity_id level: r.level
"""

# The query engine's program: the schemas and one query, none of the rules.
_QUERY_ENGINE = """
schema Reading scope logical:
    entity_id: String key
    level: Float mutable

schema Alarm scope ttl 5_s:
    entity_id: String
    level: Float

schema Hot scope logical:
    entity_id: String key

schema QA scope logical:
    a: Alarm key

rule qa:
    Alarm a
->
    emit QA logical a: a
"""


def _record(tmp_path) -> list[dict]:
    """Record a canonical-cadence run, one pump after every input."""
    eng = _load(_PROGRAM)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    path = tmp_path / "run.dstrace"
    with eng.record(path):
        eng.assert_("Reading", entity_id="a", level=85.0)
        eng.pump()
        b = eng.assert_("Reading", entity_id="b", level=95.0)
        eng.pump()
        for _ in range(7):  # Alarm b expires at 5 s
            eng.clock.advance(_SEC)
            eng.pump()
        eng.assert_("Reading", entity_id="a", level=70.0)  # supersedes; Hot a ends
        eng.pump()
        eng.retract(b)  # integrator retract; Hot b ends
        eng.pump()
    return _records(path.read_bytes(), eng)


def test_check5_program_engine_reproduces_the_recording(tmp_path):
    recs = _record(tmp_path)
    eng = _load(_PROGRAM)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    events = _watch(eng)
    gone: set[int] = set()
    handles: dict[int, int] = {}

    for r in recs:
        m = r["kind"]
        if m is AtomKind.FACT_ASSERT:
            # The recorded ttl_ns is the schema's own (no per-fact override is
            # public), and the clock is the recording's, so a
            # plain assert reproduces the deadline; the withdrawal comparison
            # below fails if it does not.
            h = eng.assert_(r["schema_name"], **r["slots"])
            handles[r["fact_id"]] = h
        elif m is AtomKind.FACT_RETRACT:
            h = handles.get(r["fact_id"])
            gone.update(e["id"] for e in events if e["kind"] == "fact_retract")
            if h is not None and r["fact_id"] not in gone:
                eng.retract(h)
        elif m is AtomKind.CLOCK_ADVANCE:
            eng.clock.set(r["clock_ns"])
        else:
            continue
        eng.pump()

    rec_emits = [(r["fact_id"], r["schema_name"]) for r in recs if r["kind"] is AtomKind.FACT_EMIT]
    # A FactEmit is an emit's alone: a publish records a FactPublish ([RFCS.27.1]).
    got_emits = [(e["id"], e["fact"].schema) for e in events if e["kind"] == "action_emit"]
    rec_fires = [
        (r["rule_name"], r["timetag"])
        for r in recs
        if r["kind"] is AtomKind.RULE_FIRE_ANNOTATION and not r["end"]
    ]
    got_fires = [(e["rule_name"], e["timetag"]) for e in events if e["kind"] == "rule_fire_begin"]
    rec_gone = [
        r["fact_id"] for r in recs if r["kind"] in (AtomKind.FACT_WITHDRAW, AtomKind.FACT_RETRACT)
    ]
    got_gone = [e["id"] for e in events if e["kind"] == "fact_retract"]

    trace = _summary(recs)
    assert rec_fires, f"the recording has no firings:\n{trace}"
    assert got_emits == rec_emits, (
        f"emits differ\n recorded {rec_emits}\n replayed {got_emits}\n{trace}"
    )
    assert got_fires == rec_fires, (
        f"firings differ\n recorded {rec_fires}\n replayed {got_fires}\n{trace}"
    )
    assert got_gone == rec_gone, (
        f"withdrawals differ\n recorded {rec_gone}\n replayed {got_gone}\n{trace}"
    )


def test_check4_query_engine_tracks_the_recording(tmp_path):
    recs = _record(tmp_path)
    eng = _load(_QUERY_ENGINE)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    events = _watch(eng)
    at: list[int] = []  # record index per event
    eng_id: dict[int, int] = {}  # recorded id -> engine FactId
    live: set[int] = set()  # recorded ids, live in the engine

    def gone_now() -> set[int]:
        ended = {e["id"] for e in events if e["kind"] == "fact_retract"}
        return {rid for rid, eid in eng_id.items() if eid in ended}

    added = (AtomKind.FACT_ASSERT, AtomKind.FACT_EMIT)
    removed = (AtomKind.FACT_RETRACT, AtomKind.FACT_WITHDRAW)
    for r in recs:
        m = r["kind"]
        if m not in (*added, *removed, AtomKind.CLOCK_ADVANCE):
            continue
        clock = r.get("clock_ns") or 0
        if clock > eng.clock.now_ns:
            eng.clock.set(clock)
        if m in added:
            # Both programs give each schema the same TTL, so the schema's
            # own deadline is the recorded one (see check 5 above).
            eng_id[r["fact_id"]] = eng.assert_(r["schema_name"], **r["slots"])
            live.add(r["fact_id"])
        elif m in removed:
            live -= gone_now()
            if r["fact_id"] in live:
                eng.retract(eng_id[r["fact_id"]])
        eng.pump()
        at.extend([r["i"]] * (len(events) - len(at)))
    live -= gone_now()

    # Every recorded TTL expiry: the engine removed the same fact within the
    # cascade the recording removed it in.
    expiries = [
        r for r in recs if r["kind"] is AtomKind.FACT_WITHDRAW and r["cause"] == _TTL_EXPIRED
    ]
    trace = _summary(recs)
    assert expiries, f"the recording has no TTL expiry to compare:\n{trace}"
    injects = [
        r["i"]
        for r in recs
        if r["kind"] in (AtomKind.FACT_ASSERT, AtomKind.FACT_RETRACT, AtomKind.CLOCK_ADVANCE)
    ]
    for x in expiries:
        start = max(i for i in injects if i < x["i"])
        eid = eng_id[x["fact_id"]]
        when = [
            at[k] for k, e in enumerate(events) if e["kind"] == "fact_retract" and e["id"] == eid
        ]
        assert when and start <= when[0] <= x["i"], (
            f"fact {x['fact_id']} expired at record {x['i']} (cascade from "
            f"{start}); the query engine removed it at {when}\n{trace}"
        )

    # End state: the recording's live facts, and nothing else.
    rec_live = {r["fact_id"] for r in recs if r["kind"] in added}
    rec_live -= {r["fact_id"] for r in recs if r["kind"] in removed}
    assert live == rec_live, (
        f"final working memory differs\n recording {sorted(rec_live)}\n"
        f" engine {sorted(live)}\n{trace}"
    )
