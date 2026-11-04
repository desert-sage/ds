# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""One firing has one timetag, on every event it produces ([NCBK.2.12]).

`rule_lhs_facts` and `timer_armed` carry the firing's `timetag`, the value its
`rule_fire_begin` carries, so a consumer joins them by key rather than by
position in the stream.
"""

import pyds

_PROGRAM = """\
schema Ping scope logical:
    id: Int key

schema Pong scope ttl 60s:
    id: Int

rule echo cooldown 10min:
    Ping p
->
    emit Pong id: p.id
"""


def _events_of_two_firings():
    eng = pyds.from_source(_PROGRAM)
    events = []
    eng.on_event = events.append
    eng.clock.mode = "mock"
    # A non-zero base: the cooldown table reads a last firing at 0 as "never
    # fired", so a firing at t=0 would arm nothing to observe.
    eng.clock.set(1_000_000_000)
    eng.assert_("Ping", id=1)
    eng.assert_("Ping", id=2)
    eng.pump()
    eng.close()
    return events


def _by_kind(events, cls):
    return [e for e in events if isinstance(e, cls) and e.rule_name == "echo"]


def test_each_firing_s_lhs_facts_and_timer_armed_carry_its_timetag():
    events = _events_of_two_firings()
    begins = _by_kind(events, pyds.events.RuleFireBegin)
    lhs = _by_kind(events, pyds.events.RuleLhsFacts)
    armed = _by_kind(events, pyds.events.TimerArmed)
    assert len(begins) == len(lhs) == len(armed) == 2, [e.kind for e in events]

    firings = [b.timetag for b in begins]
    assert all(t > 0 for t in firings), firings
    assert len(set(firings)) == 2, "two firings, two timetags"
    # Joined by key, so the assertion holds whatever order the events came in.
    assert sorted(e.timetag for e in lhs) == sorted(firings)
    assert sorted(e.timetag for e in armed) == sorted(firings)
