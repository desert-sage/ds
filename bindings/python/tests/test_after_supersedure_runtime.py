# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for `after <dur> as <expr>:` per-key timer supersedure (LRST.2.2).

`after 5_min as t.entity_id:` schedules a timer keyed on the
entity_id; a re-fire of the parent rule with the same
entity_id retracts the prior timer before asserting the new
one. Different keys schedule independent timers.
"""

from log_sink import capture_critical

import pyds

_TIMER_SUPERSEDE = """
schema Trig scope logical:
    entity_id: String key
    v: Int mutable

rule outer:
    Trig t
->
    log critical "now"
    after 5s as t.entity_id:
        log critical "later"
"""


def test_after_supersedure_replaces_prior_timer_for_same_key():
    """A second Trig with the same entity_id retracts the first's timer.

    Both schedule timers keyed on entity_id, and the second fact's `after`
    clause retracts the first timer. Only the second timer fires when the
    clock advances.
    """
    eng = pyds.from_source(_TIMER_SUPERSEDE)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Trig", entity_id="dev1", v=1)
    eng.pump()
    eng.clock.set(1_000_000_000)
    # Second fact for same entity_id — retracts the first timer.
    eng.assert_("Trig", entity_id="dev1", v=2)
    eng.pump()

    # Advance past the original timer's would-be fire_at (5s
    # from t=0) and past the new timer's fire_at (5s from t=1s
    # = 6s). Only ONE timer fires.
    eng.clock.set(7_000_000_000)
    eng.pump()
    later_count = sum(1 for a in alerts if a == "later")
    assert later_count == 1, f"expected exactly one supersedure-deduped fire: {alerts!r}"


def test_after_supersedure_independent_timers_per_key():
    """Different entity_ids schedule independent timers; both fire."""
    eng = pyds.from_source(_TIMER_SUPERSEDE)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Trig", entity_id="dev1", v=1)
    eng.assert_("Trig", entity_id="dev2", v=1)
    eng.pump()
    eng.clock.set(7_000_000_000)
    eng.pump()
    later_count = sum(1 for a in alerts if a == "later")
    assert later_count == 2, f"expected two independent timer fires: {alerts!r}"
