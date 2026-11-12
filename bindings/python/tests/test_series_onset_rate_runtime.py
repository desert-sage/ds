# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""End-to-end runtime test for the signal aggregation `onset_rate` (LSIG.1.4).

`onset_rate` is a v1 signal aggregation on a Bool slot: rising edges
(false→true) per second over the sliding window. It rides the
SeriesBackendRingBuffer ring (LSIG.2.4.1) — no new backend atom — with a
per-instance `t_first` supplying the `min(W, elapsed)` denominator. This drives
it through the full stack: compiler backing-selection + emit
(SeriesBackendRingBuffer, element_type BOOL) → DSC load → the
`ds_series_onset_rate` adapter → the ring-buffer edge ring.
"""

from log_sink import capture_critical

import pyds

_ONSET = """
use default

schema Sensor scope logical:
    entity_id: String key
    active: Bool mutable

series Sensor.active:
    onset_rate sliding 10s

rule alert_onset:
    Sensor s where s.onset_rate > 0.1
->
    log critical "{s.entity_id}"
"""


def _assert_at(eng, t_ns, value):
    eng.clock.set(t_ns)
    eng.assert_("Sensor", entity_id="dev1", active=value)
    eng.pump()


def test_onset_rate_fires_after_rising_edges():
    """A toggling Bool signal's companion-slot read fires once its onset rate crosses 0.1/s.

    The toggling produces rising edges, and the threshold is on their
    in-window rate.
    """
    eng = pyds.from_source(_ONSET)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    # Rising edges at t=2s and 4s, each a `true` after a `false`; the first
    # `true`, at 0s, follows nothing and is no edge (LSIG.1.4.1). Well inside
    # the 10s window, elapsed grows to seconds → rate is O(1)/s ≫ 0.1.
    for t, v in [(0, True), (1, False), (2, True), (3, False), (4, True)]:
        _assert_at(eng, t * 1_000_000_000, v)

    assert "dev1" in alerts, f"expected onset_rate fire: {alerts!r}"


def test_onset_rate_flat_signal_does_not_fire():
    """A signal that never rises (stays false) has zero rising edges.

    So onset_rate stays 0.0 and the 0.1/s threshold never trips.
    """
    eng = pyds.from_source(_ONSET)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    for t in range(5):
        _assert_at(eng, t * 1_000_000_000, False)

    assert alerts == [], f"flat signal must not fire: {alerts!r}"
