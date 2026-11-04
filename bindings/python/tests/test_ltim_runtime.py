# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime smoke tests for the LTIM compile-side surface.

Compile-side tests pin parse + validate behaviour (LTIM.4.1,
LTIM.4.2.2, LTIM.3.3.2, LTIM.5.5, LTIM.6.2). These tests exercise
the corresponding lowered output through pyds — exposes any builtins
that the compiler emits but the runtime doesn't register.

Zones resolve through the built-in `TimeZoneOffset` facts the host asserts
([LTIM.10.6]-[LTIM.10.10]).
"""

import pytest
from log_sink import capture_critical

import pyds

_NOW_ARITH = """
schema Event scope logical:
    entity_id: String key
    fired_at: Time mutable

rule old_event:
    Event m where (now() - m.fired_at) > 1h
->
    log critical "old"
"""


def test_now_minus_time_compiles_and_loads():
    """`now() - m.fired_at > 1h` compiles, and the lowered rule loads cleanly (LTIM.4.1).

    The where-clause reads the clock minus the bound fired_at slot.
    """
    eng = pyds.from_source(_NOW_ARITH)
    # Asserting a Time-typed slot via Python: the slot was declared
    # `Time`, but pyds's Python surface routes Time slots through
    # the Float path (Time is stored as float seconds). An older
    # fired_at value satisfies the > 1h window.
    # Time slots serialise as Int (signed-ns) per LTIM.1.
    eng.assert_("Event", entity_id="e1", fired_at=0)
    alerts = []
    capture_critical(eng, alerts)
    eng.pump()
    # We don't pin whether the rule fires (the value path through
    # CLIPS depends on slot-type marshalling); we pin that the
    # engine accepts the program and pump completes without error.


# The longest period a row can state, [INT64_MIN, INT64_MAX): `valid_until` is
# exclusive ([LTIM.10.7]).
_EVER = (-(2**63), 2**63 - 1)


def _zone(eng, zone, offset_s, valid_from=_EVER[0], valid_until=_EVER[1]):
    """Assert one `TimeZoneOffset` row ([LTIM.10.6]); its fact."""
    return eng.assert_(
        "TimeZoneOffset",
        zone=zone,
        valid_from=valid_from,
        valid_until=valid_until,
        offset_s=offset_s,
    )


_TIME_DATE_METHOD = """
schema Event scope logical:
    entity_id: String key
    fired_at: Time mutable
    expected: Date mutable

rule check:
    Event e where e.fired_at.date("UTC") == e.expected
->
    log critical "match"
"""


def test_t_date_in_utc_needs_no_row():
    """`t.date("UTC")` needs no `TimeZoneOffset` row ([LTIM.3.3.1], [LTIM.10.8]).

    `t.date(tz)` compiles to FN_TIME_DATE and loads, and exactly "UTC" is
    offset 0 with no row consulted, so the date of instant 0 in UTC is day 0
    and the rule fires on an engine that holds no row.
    """
    eng = pyds.from_source(_TIME_DATE_METHOD)
    alerts = []
    capture_critical(eng, alerts)
    eng.assert_("Event", entity_id="e1", fired_at=0, expected=0)
    eng.pump()
    assert alerts == ["match"]


_LOCAL_UNBOUND_WHERE = """
schema P scope logical:
    id: Int key

rule zone:
    P where now().local("Asia/Tokyo") >= now()
->
    log critical "never"
"""


def test_local_in_a_where_naming_no_binding_faults_and_the_engine_continues():
    """A zone no row answers, seen in a fire guard.

    A `where` that names no binding is lowered to the terminal's fire guard,
    which reads `now()` and so is driven by the clock tick. libds evaluates it
    in the pump's fire loop, where `t.local(tz)` with no row for the zone is a
    DOMAIN ComputationError ([LTIM.10.5.3]): the rule does not fire and the
    engine continues, so the next mutating call succeeds. It is not an
    EngineError, which would set the [NCBK.2.9] latch and refuse that next call
    with ENGINE_HALTED.

    `84_guard_fault` holds the two runtimes to one stream for a fire-guard
    fault.
    """
    eng = pyds.from_source(_LOCAL_UNBOUND_WHERE)
    logs = []
    # EVERY log call, at every level, with its arguments: the rule must not
    # fire, and a level filter would let a firing at another level through.
    eng.on_log = logs.append
    eng.assert_("P", id=1)
    eng.pump()
    eng.assert_("P", id=2)
    eng.pump()
    assert logs == [], logs


# `seen` is 23:30 UTC on day 19000, so its date in a zone an hour ahead is day
# 19001: the rule fires only if `date()` used the row's offset. (A
# `t.local(tz)` comparison cannot show the offset: a Time compares by its instant.)
_DATE_AHEAD = """
schema P scope logical:
    id: Int key
    seen: Time mutable
    day: Date mutable

rule ahead:
    P p where p.seen.date("Test/Ahead") == p.day
->
    log critical "ahead"

schema Q scope logical:
    id: Int key

rule later:
    Q
->
    log critical "later"
"""

_SEEN_NS = (19_000 * 86_400 + 84_600) * 10**9
_NEXT_DAY = 19_001
_FAULTS = (pyds.events.ComputationError, pyds.events.TypeError, pyds.events.EngineError)
_DOMAIN = [(pyds.events.ComputationError, pyds.TrapKind.DOMAIN)]


def _date_ahead(rows):
    """Run _DATE_AHEAD's P after asserting `rows`; return the engine, logs and faults.

    Each row is (zone, offset_s, valid_from, valid_until); the logs are the
    critical ones, and each fault event is (class, trap_kind). A zone no row
    answers, whatever supplied it, is a DOMAIN ComputationError and the engine
    carries on ([LTIM.10.5.3]); so no fault here halts the engine, and none is
    tolerated.
    """
    eng = pyds.from_source(_DATE_AHEAD)
    alerts, faults = [], []
    capture_critical(eng, alerts)

    def on_event(ev):
        if isinstance(ev, _FAULTS):
            trap = ev.trap_kind if isinstance(ev, pyds.events.ComputationError) else None
            faults.append((type(ev), trap))

    eng.on_event = on_event
    for zone, offset_s, valid_from, valid_until in rows:
        _zone(eng, zone, offset_s, valid_from, valid_until)
    eng.assert_("P", id=1, seen=_SEEN_NS, day=_NEXT_DAY)
    eng.pump()
    return eng, alerts, faults


def test_the_rows_offset_is_the_one_date_uses():
    """The row whose period holds the instant answers, with its `offset_s` ([LTIM.10.7]).

    `offset_s`, seconds east of UTC, is the offset `date()` uses.
    """
    _, alerts, faults = _date_ahead([("Test/Ahead", 3600, *_EVER)])
    assert alerts == ["ahead"]
    assert faults == []


def test_an_offset_of_zero_is_used_too():
    """The control: at offset 0 the date is day 19000, and the rule does not fire."""
    _, alerts, faults = _date_ahead([("Test/Ahead", 0, *_EVER)])
    assert alerts == []
    assert faults == []


def test_the_row_is_chosen_at_the_instant():
    """The row with the greatest `valid_from` not after the instant answers ([LTIM.10.7]).

    That holds whatever order the zone's rows arrived in: here the later row,
    +1 h from one second before `seen`, over the earlier one at 0.
    """
    rows = [("Test/Ahead", 3600, _SEEN_NS - 10**9, _EVER[1]), ("Test/Ahead", 0, *_EVER)]
    _, alerts, faults = _date_ahead(rows)
    assert alerts == ["ahead"]
    assert faults == []


def test_a_period_that_has_ended_answers_nothing():
    """Once the floor row's period has ended the zone has no answer: DOMAIN ([LTIM.10.7]).

    The floor row's `valid_until` is exclusive, and an earlier row covering
    the instant does not answer in its place.
    """
    rows = [("Test/Ahead", 3600, *_EVER), ("Test/Ahead", 3600, _SEEN_NS - 10**9, _SEEN_NS)]
    _, alerts, faults = _date_ahead(rows)
    assert alerts == []
    assert faults and set(faults) == set(_DOMAIN), faults


def test_a_zone_no_row_answers_faults_its_rule_and_the_engine_carries_on():
    """A zone no row answers is a DOMAIN fault of its rule, and the engine carries on.

    The rows are for another zone only, so a zone written in the program has
    no answer ([LTIM.10.5.3]). The faulting rule takes no action, a later
    input fires another rule, and the engine is not halted. The zone compares
    byte for byte ([LTIM.10.6]): "test/ahead" is another zone.
    """
    eng, alerts, faults = _date_ahead([("test/ahead", 3600, *_EVER)])
    assert faults and set(faults) == set(_DOMAIN), faults
    assert alerts == []  # `ahead` took no action
    eng.assert_("Q", id=1)
    eng.pump()
    assert alerts == ["later"]
    assert eng.halted is None


def test_a_retracted_row_no_longer_answers_and_a_clone_keeps_its_own():
    """A row retracted on the source leaves a clone's answer alone.

    The rows are facts, and a clone holds them as the source did ([NLFC.8.1]).
    """
    eng = pyds.from_source(_DATE_AHEAD)
    row = _zone(eng, "Test/Ahead", 3600)
    shadow = eng.clone()
    eng.retract(row)
    for e, want in ((eng, []), (shadow, ["ahead"])):
        alerts = []
        capture_critical(e, alerts)
        e.assert_("P", id=1, seen=_SEEN_NS, day=_NEXT_DAY)
        e.pump()
        assert alerts == want


@pytest.mark.parametrize(
    ("zone", "offset_s", "valid_from", "valid_until", "words"),
    [
        ("Test/Ahead", 3600, 10, 10, "valid_from is not before valid_until"),
        ("Test/Ahead", 3600, 20, 10, "valid_from is not before valid_until"),
        ("Test/Ahead", 64801, *_EVER, "offset_s outside"),
        ("Test/Ahead", -64801, *_EVER, "offset_s outside"),
        ("UTC", 0, *_EVER, 'the zone "UTC" takes no row'),
    ],
    ids=["empty", "reversed", "east-of-18h", "west-of-18h", "utc"],
)
def test_a_malformed_row_is_refused_and_nothing_is_asserted(
    zone, offset_s, valid_from, valid_until, words
):
    """[LTIM.10.9]: DS_ERR_INVAL, libds's words, and no fact."""
    eng = pyds.from_source(_DATE_AHEAD)
    with pytest.raises(pyds.Error, match="TimeZoneOffset") as caught:
        _zone(eng, zone, offset_s, valid_from, valid_until)
    assert caught.value.status is pyds.Status.INVAL
    assert words in str(caught.value)
    assert len(eng.facts) == 0


def test_rows_at_the_bounds_and_overlapping_are_admitted():
    """Offsets of eighteen hours either way are admitted, and so are overlapping rows.

    That is [LTIM.10.9]; [LTIM.10.7] decides which of two overlapping rows
    answers.
    """
    eng = pyds.from_source(_DATE_AHEAD)
    _zone(eng, "Test/East", 64800)
    _zone(eng, "Test/West", -64800)
    _zone(eng, "Test/West", 0, 0, 10)
    assert len(eng.facts) == 3
