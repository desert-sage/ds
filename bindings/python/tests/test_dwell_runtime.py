# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for the LSER.10.4 dwell companion-slot.

`t.dwell` is how long the fact has been live: its entry stamp's age, a
`Duration`, reading no slot (LEXP.9.5.1). A Duration compares with a
Duration and nothing else (LTIM.5.5), so the window is written `10_s`.
"""

from log_sink import capture_critical

import pyds

_DWELL = """
schema Sensor scope logical:
    entity_id: String key
    ts: Time
    state: Float mutable

rule alert_stale:
    Sensor s where s.dwell > 10_s
->
    log critical "{s.entity_id}"
"""


def test_dwell_predicate_fires_when_now_exceeds_ts_plus_window():
    """With the mock clock past the fact's entry + 10s, the dwell predicate fires."""
    eng = pyds.from_source(_DWELL)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Sensor", entity_id="dev1", ts=0, state=42.0)
    eng.pump()
    # Advance clock past the dwell window.
    eng.clock.set(15_000_000_000)  # 15s in ns
    eng.pump()
    assert alerts == ["dev1"], f"dwell predicate didn't fire: {alerts!r}"


def test_dwell_predicate_silent_within_window():
    """Within the dwell window the predicate must not fire."""
    eng = pyds.from_source(_DWELL)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Sensor", entity_id="dev1", ts=0, state=42.0)
    eng.pump()
    eng.clock.set(5_000_000_000)
    eng.pump()
    assert alerts == [], f"dwell predicate fired prematurely: {alerts!r}"
