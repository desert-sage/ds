# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for the LGRA `<bind> within <dur>` clause.

`Sensor s within 5s` matches while the fact ENTERED working memory less than
5 seconds ago on the monotonic clock: its entry stamp ([LTIM.2.8.6]), not its
`ts`. Each test asserts at one sample and pumps at a later one, so the age is
the advance between them, and `ts` is set to something the window would
contradict if it were read.
"""

from log_sink import capture_critical

import pyds

_WITHIN = """
schema Sensor scope ttl 1h:
    entity_id: String
    ts: Time
    state: Int

rule recent_high:
    Sensor s within 5s where s.state > 0
->
    log critical "{s.entity_id}"
"""


def test_within_clause_silent_when_fact_age_exceeds_window():
    """Entered at 0, pumped at 10s: age 10s > 5s, so nothing fires.

    The pump's sample finds the condition false and the match has ended
    ([LTIM.2.5.3]). `ts` is "now", which would fire under a `ts` reading.
    """
    eng = pyds.from_source(_WITHIN)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Sensor", entity_id="dev1", ts=10_000_000_000, state=1)
    eng.clock.advance(10_000_000_000)
    eng.pump()
    assert alerts == [], f"within fired on a fact that entered 10s ago: {alerts!r}"


def test_within_clause_fires_when_fact_age_inside_window():
    """Entered at 0, pumped at 3s: age 3s < 5s, so it fires.

    `ts` is 0 against a monotonic clock at 3s, so this also holds under a `ts` reading; the
    silent case above is the one that tells the two apart.
    """
    eng = pyds.from_source(_WITHIN)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Sensor", entity_id="dev1", ts=0, state=1)
    eng.clock.advance(3_000_000_000)
    eng.pump()
    assert alerts == ["dev1"], f"within didn't fire on a fact that entered 3s ago: {alerts!r}"
