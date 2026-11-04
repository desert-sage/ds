# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for LSER multi-line obs-triple series decls.

A series declaration with multiple obs lines (e.g. mean +
stdev + p95 on the same slot) lowers to a single
AccumulatorDecl whose backing_magic set covers all the
declared aggregations. Authors can reference any of them via
companion slots.
"""

from log_sink import capture_critical

import pyds

_MULTI = """
use default

schema Sensor scope logical:
    entity_id: String key
    state: Float mutable

series Sensor.state:
    mean, stdev sliding 10s
    p95 sliding 10s tolerance 0.01

rule alert_high_p95:
    Sensor s where s.p95 > 50.0
->
    log critical "{s.entity_id}"
"""


_MULTI_MEAN = """
use default

schema Sensor scope logical:
    entity_id: String key
    state: Float mutable

series Sensor.state:
    mean, stdev sliding 10s

rule alert_high_mean:
    Sensor s where s.mean > 50.0
->
    log critical "mean"
"""


def test_multi_obs_triple_mean_companion_fires():
    """With mean + stdev on one series, the mean companion slot resolves and fires.

    It resolves through the SeriesBackendWelfordEwma backend.
    """
    eng = pyds.from_source(_MULTI_MEAN)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    for v in [60.0, 70.0, 80.0]:
        eng.assert_("Sensor", entity_id="dev1", state=v)
        eng.pump()
    assert "mean" in alerts, f"mean companion didn't fire: {alerts!r}"
