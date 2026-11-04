# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""End-to-end runtime test for the signal aggregation `active_fraction` (LSIG.1.3 / 2.2).

`active_fraction` is a v1 signal aggregation on a Bool slot: the time-weighted
fraction of a sliding window during which the slot held `true`. It is backed
by the SeriesBackendIntervalPulse interval-pulse atom (LSIG.2.2) — this
drives the whole new-atom path: compiler backing-selection +
SeriesBackendIntervalPulse emit → DSC load (handle_sbip) → the
`ds_series_active_fraction` adapter → the interval- pulse deque with its single
correctly-rounded divide.
"""

from log_sink import capture_critical

import pyds

_AF = """
use default

schema Sensor scope logical:
    entity_id: String key
    active: Bool mutable

series Sensor.active:
    active_fraction sliding 10s

rule alert_af:
    Sensor s where s.active_fraction > 0.3
->
    log critical "{s.entity_id}"
"""


def _assert_at(eng, t_ns, value):
    eng.clock.set(t_ns)
    eng.assert_("Sensor", entity_id="dev1", active=value)
    eng.pump()


def test_active_fraction_fires_when_mostly_on():
    """A Bool slot held true for 6s of a 10s window has active_fraction 0.6.

    The companion-slot read crosses the 0.3 threshold and fires.
    """
    eng = pyds.from_source(_AF)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    # true for [0s, 6s), then toggles — well over 30% of the 10s window.
    for t, v in [(0, True), (6, False), (7, True), (8, False)]:
        _assert_at(eng, t * 1_000_000_000, v)

    assert "dev1" in alerts, f"expected active_fraction fire: {alerts!r}"


def test_active_fraction_flat_off_does_not_fire():
    """A slot that never goes true has active_fraction 0.0.

    No interval is ever opened, so the threshold never trips.
    """
    eng = pyds.from_source(_AF)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    for t in range(5):
        _assert_at(eng, t * 1_000_000_000, False)

    assert alerts == [], f"flat-off signal must not fire: {alerts!r}"
