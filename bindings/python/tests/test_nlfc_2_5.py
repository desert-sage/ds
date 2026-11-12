# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""NLFC.2.5 through pyds: the engine reports its next deadline.

The clause binds the binding class. `@ds-lang/ds` (engine.test.mjs) and
`mercury_ds` (test_mercury_ds.m) hold the same assertions, which puts libds and
the Mercury runtime behind them.

Every instant below is the mock clock's, in seconds: the cache entry's TTL is
10 s, the `Lease` fact's 20 s and the `after` timer's 30 s, so the three kinds
fall due in that order.
"""

from __future__ import annotations

import pyds

_SEC = 1_000_000_000

_PROGRAM = """
use default

schema Arm scope logical:
    id: Int key

schema Lease scope ttl 20_s:
    id: Int

schema Write scope logical:
    id: Int key

schema Drop scope logical:
    id: Int key

rule arm_timer:
    Arm
->
    after 30_s:
        log critical "fired"

rule write_cache:
    Write
->
    cache key: "k" value: 1 ttl: 10_s

rule drop_cache:
    Drop
->
    cache_delete key: "k"
"""

_DWELL = """
use default

schema Ping scope logical:
    k: String key

rule held:
    Ping p where p.dwell >= 3_s
->
    log critical "fired"
"""


def _engine(source: str = _PROGRAM) -> pyds.Engine:
    """Return a fresh engine on the mock clock at 0, with `source` loaded."""
    eng = pyds.Engine()
    eng.clock.mode = "mock"
    eng.clock.set(0)
    eng.load_dsc(pyds.compile(source, file="test.ds"))
    return eng


def _all_three(eng: pyds.Engine) -> pyds.FactId:
    """Arm all three kinds at the current clock; the `Lease` fact's id."""
    eng.assert_("Write", id=1)
    eng.assert_("Arm", id=1)
    lease = eng.assert_("Lease", id=1)
    eng.pump()
    return lease


def test_nlfc_2_5__none_when_nothing_is_due():
    """A loaded program with no timer, TTL fact or cache entry reports none."""
    assert _engine().clock.next_deadline_ns is None


def test_nlfc_2_5__reports_a_timer_fire_at():
    """A rule's `after` clause arms a timer whose `fire_at` is reported."""
    eng = _engine()
    eng.clock.set(100 * _SEC)
    eng.assert_("Arm", id=1)
    eng.pump()
    assert eng.clock.next_deadline_ns == 130 * _SEC


def test_nlfc_2_5__reports_a_fact_ttl():
    """A `ttl` fact is reported at its entry stamp plus its TTL."""
    eng = _engine()
    eng.clock.set(5 * _SEC)
    eng.assert_("Lease", id=1)
    assert eng.clock.next_deadline_ns == 25 * _SEC


def test_nlfc_2_5__reports_a_cache_entry_expiry():
    """A `cache` write with a TTL is reported at its expiry."""
    eng = _engine()
    eng.clock.set(7 * _SEC)
    eng.assert_("Write", id=1)
    eng.pump()
    assert eng.clock.next_deadline_ns == 17 * _SEC


def test_nlfc_2_5__earliest_of_the_three_kinds():
    """The earliest live kind is reported, and the next once it is gone."""
    eng = _engine()
    lease = _all_three(eng)
    assert eng.clock.next_deadline_ns == 10 * _SEC
    eng.assert_("Drop", id=1)
    eng.pump()
    assert eng.clock.next_deadline_ns == 20 * _SEC
    eng.retract(lease)
    eng.pump()
    assert eng.clock.next_deadline_ns == 30 * _SEC


def test_nlfc_2_5__later_than_the_clock():
    """A deadline at or before the clock is not reported, with no pump."""
    eng = _engine()
    _all_three(eng)
    eng.clock.set(10 * _SEC)
    assert eng.clock.next_deadline_ns == 20 * _SEC
    eng.clock.set(25 * _SEC)
    assert eng.clock.next_deadline_ns == 30 * _SEC


def test_nlfc_2_5__a_time_dependent_condition_is_not_a_deadline():
    """A `where dwell >= T` rule alone reports none."""
    eng = _engine(_DWELL)
    eng.assert_("Ping", k="a")
    eng.pump()
    assert eng.clock.next_deadline_ns is None


def _stream(queried: bool) -> list[tuple[str, object, object]]:
    """Return what a run streams, with the query between its two clock moves or not."""
    eng = _engine()
    events: list[object] = []
    eng.on_event = events.append
    eng.clock.set(5 * _SEC)
    if queried:
        _ = eng.clock.next_deadline_ns
    eng.clock.set(7 * _SEC)
    if queried:
        _ = eng.clock.next_deadline_ns
    eng.assert_("Write", id=1)
    eng.pump()
    return [
        (type(e).__name__, getattr(e, "seq", None), getattr(e, "clock_ns", None)) for e in events
    ]


def test_nlfc_2_5__takes_no_sample():
    """The stream holds what it holds without the query."""
    assert _stream(queried=True) == _stream(queried=False)


def test_nlfc_2_5__refused_from_a_callback():
    """Called from the stream callback, the query is DS_ERR_STATE."""
    eng = _engine()
    refused: list[pyds.Status] = []

    def probe(_event: object) -> None:
        try:
            _ = eng.clock.next_deadline_ns
        except pyds.Error as err:
            refused.append(err.status)

    eng.on_event = probe
    eng.assert_("Write", id=1)
    assert refused, "the stream callback ran"
    assert all(status is pyds.Status.STATE for status in refused)
