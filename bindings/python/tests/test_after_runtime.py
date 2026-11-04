# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for LTAC `after <dur>:` clauses.

`after <dur>:` synthesises a `$Timer_<rule>_<N>` deftemplate
holding a `fire_at` timestamp + a follow-up rule that matches
when `(ds-now-ns) >= fire_at`. The follow-up rule's RHS contains
the body actions and retracts the timer fact. Together this gives
"fire body actions <dur> after the parent rule activated".
"""

from log_sink import capture_critical

import pyds

_AFTER_SIMPLE = """
schema Trig scope logical:
    v: Int key

rule outer:
    Trig
->
    log critical "now"
    after 5s:
        log critical "later"
"""


def test_after_clause_fires_after_window_elapses():
    """The follow-up rule fires once the mock clock passes the timer's fire_at.

    The outer rule fires immediately and asserts the timer fact.
    """
    eng = pyds.from_source(_AFTER_SIMPLE)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Trig", v=1)
    eng.pump()
    # Outer rule already fired the immediate alert.
    assert alerts == ["now"], f"outer rule didn't fire immediate alert: {alerts!r}"

    # Advance clock just under the after-duration; follow-up
    # shouldn't fire yet.
    eng.clock.set(4_000_000_000)
    eng.pump()
    assert alerts == ["now"], f"after-clause fired before window elapsed: {alerts!r}"

    # Past the window — follow-up fires.
    eng.clock.set(6_000_000_000)
    eng.pump()
    assert alerts == ["now", "later"], f"after-clause didn't fire after window: {alerts!r}"


_AFTER_TWO = """
schema Trig scope logical:
    v: Int key

rule outer:
    Trig
->
    log critical "now"
    after 5s:
        log critical "five"
    after 10s:
        log critical "ten"
"""


def test_two_after_clauses_fire_in_order():
    """Two `after` clauses fire in timer-elapsed order, whatever their source order."""
    eng = pyds.from_source(_AFTER_TWO)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Trig", v=1)
    eng.pump()
    eng.clock.set(7_000_000_000)
    eng.pump()
    eng.clock.set(15_000_000_000)
    eng.pump()
    assert alerts == ["now", "five", "ten"], f"after-clauses fired out of order: {alerts!r}"
