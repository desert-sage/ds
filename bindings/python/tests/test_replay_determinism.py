# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""In-process replay determinism.

Per LDET.10.5 / LDET.10.12 the engine's output stream must be
byte-for-byte identical across runs given fixed inputs. This
module's tests run a sequence of integrator-driven inputs (asserts,
retracts, clock advances, pumps) twice in fresh pyds engines and
assert the captured stream events are equal after normalization.

Normalization strips fields that legitimately differ across engine
instances even when the programs are deterministic:

- `fact_id`: each unique fact id is replaced with a stream-local serial
  (1, 2, ...) by first-appearance order. Fresh engines assign the same ids,
  so this is the identity on these runs; it is kept because what
  determinism constrains is the relationship between assert / retract /
  publish / emit naming the same fact, not the numbering.

This module deliberately doesn't exercise:
- adapter `call` actions (they need the harness to record and replay
  integrator-side responses)
- live-clock mode (mock clock is the deterministic playback path
  per LFST.6.1 / LDET.10.3)
- cross-process / cross-platform replay
"""

import dataclasses

import pyds

Event = pyds.events.Event


# ----------------------------------------------------------------------
# Stream capture + normalization helpers
# ----------------------------------------------------------------------


def _normalize_handle_field(events: list[Event]) -> list[Event]:
    """Replace each unique fact_id with a stream-local serial id, in first-appearance order.

    The serials are 1, 2, 3, ... Determinism requires that *equality* of fact
    references is preserved across two streams.

    A serial is scoped to the fact's LIFETIME: a retract retires it, so a
    later assert of the same raw value gets a NEW serial. A FactId is never
    reused, so that does not arise from the engine; retiring keeps the
    output a function of the assert/retract SEQUENCE alone either way.
    """
    remap: dict[int, int] = {}
    # A monotonic counter, NOT len(remap): retirement shrinks the dict, so
    # len() would hand the same serial to a later, unrelated fact and
    # conflate the two.
    assigned = 0

    def _serial(handle: int) -> int:
        nonlocal assigned
        if handle not in remap:
            assigned += 1
            remap[handle] = assigned
        return remap[handle]

    out: list[Event] = []
    for ev in events:
        # Events are frozen, so each normalised one is a copy.
        changes: dict[str, object] = {}
        # Not every kind names a fact; a computation_error may name none.
        raw_handle = getattr(ev, "fact_id", None)
        if isinstance(raw_handle, int):
            changes["fact_id"] = _serial(raw_handle)
        # `rule_lhs_facts` carries the matched LHS facts' ids, remapped
        # through the same table by first-appearance order.
        if isinstance(ev, pyds.events.RuleLhsFacts):
            changes["lhs_facts"] = tuple(
                _serial(h) if isinstance(h, int) else h for h in ev.lhs_facts
            )
        out.append(dataclasses.replace(ev, **changes))
        # Retire AFTER serialising, so the retract event still names the fact
        # it is retracting. A later reuse of the value reads as a different
        # fact.
        if isinstance(ev, pyds.events.FactRetract) and isinstance(raw_handle, int):
            remap.pop(raw_handle, None)
    return out


def _capture_stream(ds_source: str, run_inputs) -> list[Event]:
    """Load `ds_source`, drive it with `run_inputs(eng)`, and return the events it streamed.

    A stream callback appends each event to the list returned. The engine is
    in mock-clock mode at clock_ns=0 before run_inputs starts, so timestamps
    are reproducible.
    """
    eng = pyds.from_source(ds_source)
    eng.clock.mode = "mock"
    eng.clock.set(0)

    captured: list[Event] = []
    eng.on_event = captured.append

    run_inputs(eng)
    return captured


def _replay_assert_byte_identical(ds_source: str, run_inputs) -> None:
    """Assert two runs of `run_inputs` on fresh engines stream identical normalized events.

    Both engines are compiled from the same DS source. This is the in-process
    determinism check.
    """
    a = _normalize_handle_field(_capture_stream(ds_source, run_inputs))
    b = _normalize_handle_field(_capture_stream(ds_source, run_inputs))
    assert a == b, (
        f"determinism violation: stream events differ after "
        f"handle normalization.\nrun A: {a!r}\nrun B: {b!r}"
    )


# ----------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------


def test_replay_simple_assert_log():
    """Simplest possible determinism check: a rule that fires `log info` for every Trade.

    Two assertions + one pump.
    """
    src = (
        "schema Trade scope ttl 1h:\n"
        "    symbol: String\n"
        "    price: Float\n"
        "\n"
        "rule trig:\n"
        "    Trade\n"
        "->\n"
        '    log info "hit"\n'
    )

    def drive(eng):
        eng.assert_("Trade", symbol="AAPL", price=100.0)
        eng.clock.advance(1_000)
        eng.assert_("Trade", symbol="GOOG", price=200.0)
        eng.clock.advance(1_000)
        eng.pump()

    _replay_assert_byte_identical(src, drive)


def test_replay_logical_lifecycle():
    """A logical schema's lifecycle replays identically.

    It exercises both DS_EV_FACT_ASSERT and DS_EV_FACT_RETRACT plus rule-fire
    brackets.
    """
    src = (
        "schema Trade scope logical:\n"
        "    symbol: String key\n"
        "    price: Float mutable\n"
        "\n"
        "rule trig:\n"
        "    Trade\n"
        "->\n"
        '    log critical "trade-seen"\n'
    )

    def drive(eng):
        eng.assert_("Trade", symbol="AAPL", price=100.0)
        eng.pump()
        eng.assert_("Trade", symbol="GOOG", price=200.0)
        eng.pump()

    _replay_assert_byte_identical(src, drive)


def test_replay_series_accumulator():
    """The accumulator series program from test_series_accumulator.py replays identically.

    It exercises sample absorption via the hidden absorber defrule, the
    dialect-bundled SeriesBackendWelfordEwma backend, and fire-then-sample
    ordering. If anything in that path were nondeterministic, byte-equality
    would fail.
    """
    src = (
        "schema Trade scope logical:\n"
        "    symbol: String key\n"
        "    price: Float mutable\n"
        "\n"
        "series Trade.price (by: symbol):\n"
        "    count all_time\n"
        "\n"
        "rule alert_three_samples:\n"
        "    Trade t where count(t.price) >= 3\n"
        "->\n"
        '    log critical "three"\n'
    )

    def drive(eng):
        for price in [100.0, 101.0, 102.0, 103.0]:
            eng.assert_("Trade", symbol="AAPL", price=price)
            eng.clock.advance(1_000_000)  # +1ms
            eng.pump()

    _replay_assert_byte_identical(src, drive)


def test_replay_clock_advance_only():
    """Clock advances alone, no facts: the TICK event stream is deterministic by itself."""
    src = "schema Trade scope ttl 1h:\n    symbol: String\n    price: Float\n"

    def drive(eng):
        eng.clock.advance(1_000)
        eng.clock.advance(2_000)
        eng.clock.advance(3_000)
        eng.pump()

    _replay_assert_byte_identical(src, drive)


# ----------------------------------------------------------------------
# The normalizer's own tests
#
# These exist because the determinism tests above cannot catch a bug in the
# helper they all depend on: a broken normalizer reports an ALLOCATOR's
# choices as engine nondeterminism, intermittently, so "run it again" is no
# control — free-list state depends on everything else the process did.
#
# Simulating both allocator behaviours directly is a better control than
# repetition: it is deterministic, it exercises the reuse case on every run,
# and it fails on the defect rather than on the weather.
# ----------------------------------------------------------------------

_A, _B = 0x7F00_1000, 0x7F00_2000  # two stand-in ds_fact_t * values


def _asserted(seq, fid):
    return pyds.events.FactAssert(seq=seq, clock_ns=0, fact_id=fid)


def _retracted(seq, fid):
    return pyds.events.FactRetract(seq=seq, clock_ns=0, fact_id=fid)


def _matched(seq, *fids):
    return pyds.events.RuleLhsFacts(seq=seq, clock_ns=0, rule_name="r", timetag=seq, lhs_facts=fids)


def test_normalizer_is_blind_to_whether_the_pool_recycled_a_pointer():
    """A recycled fact reference, reproduced without an allocator.

    Same logical sequence — assert, retract, assert — recorded twice: once
    where the pool handed back the SAME address for the second fact and once
    where it handed back a different one. The engine did nothing different.
    Normalization must therefore produce the same stream; without the
    lifetime scoping run A reads 1, 1, 1 and run B 1, 1, 2.
    """
    reused = [_asserted(1, _A), _retracted(2, _A), _asserted(3, _A)]  # recycled slot
    fresh = [_asserted(1, _A), _retracted(2, _A), _asserted(3, _B)]  # new address

    assert _normalize_handle_field(reused) == _normalize_handle_field(fresh)
    # And the serials are the ones the sequence implies, not just equal to
    # each other: the second fact is a DIFFERENT fact, so it is not 1.
    assert [e.fact_id for e in _normalize_handle_field(reused)] == [1, 1, 2]


def test_normalizer_still_ties_events_about_one_live_fact_together():
    """The guard against fixing the above by renumbering everything.

    While a fact is live, every event naming it — including a rule fire that
    matched it on the LHS — must carry ONE serial. A normalizer that issued a
    fresh serial per event would make both streams trivially equal and prove
    nothing.
    """
    events = [_asserted(1, _A), _matched(2, _A), _asserted(3, _B), _matched(4, _A, _B)]
    out = _normalize_handle_field(events)
    assert out[0].fact_id == 1
    assert out[1].lhs_facts == (1,)
    assert out[2].fact_id == 2
    assert out[3].lhs_facts == (1, 2)  # both still live, both stable


def test_normalizer_still_separates_two_facts_that_are_live_at_once():
    """Retirement must key on the fact being retracted, not on any retract.

    Two live facts, the first retracted: the second keeps its own serial, and
    a third assert onto the first's recycled address is a new fact again.
    """
    events = [
        _asserted(1, _A),
        _asserted(2, _B),
        _retracted(3, _A),
        _asserted(4, _A),  # recycled
        _matched(5, _B),
    ]
    out = _normalize_handle_field(events)
    assert [e.fact_id for e in out[:4]] == [1, 2, 1, 3]
    assert out[4].lhs_facts == (2,), "B's serial changed while it was live"


def test_normalizer_does_not_flatten_a_genuine_difference():
    """The control on the whole file: normalization must still be able to FAIL.

    Two streams that differ in which fact an event refers to are not
    equal after normalization — otherwise every test above passes vacuously.
    """
    one = [_asserted(1, _A), _asserted(2, _B), _matched(3, _A)]
    other = [_asserted(1, _A), _asserted(2, _B), _matched(3, _B)]  # the OTHER fact
    assert _normalize_handle_field(one) != _normalize_handle_field(other)
