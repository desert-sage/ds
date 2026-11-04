# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for the LSER.13.5 observation-triple `series` declaration surface.

The new triple form (`series <Schema>.<slot>: <agg> <time-model> <accuracy>?`)
lowers through the same SeriesBackendWelfordEwma/SeriesBackendRingBuffer
backends as the legacy `accumulator` / `ring_buffer` forms; this test verifies
an end-to-end aggregation through a triple-form decl.
"""

from log_sink import capture_critical

import pyds

_TRIPLE = """
use default

schema Sensor scope logical:
    entity_id: String key
    state: Float mutable

series Sensor.state:
    mean sliding 10s

rule alert_high_mean:
    Sensor s where t.mean > 50.0 and false
->
    log info "high"
"""


def test_obs_triple_loads_and_pumps_cleanly():
    """A program with a triple-form series decl loads and pumps with no errors.

    It goes through the validator, lowering, DSC emit, and engine load.
    """
    # The rule uses companion-slot `t.mean` for documentation;
    # `false` short-circuits so the rule never fires (we're
    # smoke-testing the load path, not aggregation).
    src = _TRIPLE.replace("Sensor s where t.mean", "Sensor s where s.mean")
    eng = pyds.from_source(src)
    eng.assert_("Sensor", entity_id="dev1", state=42.0)
    eng.pump()
    # No assertion — we just want load + pump to succeed.


_TRIPLE_FIRE = """
use default

schema Sensor scope logical:
    entity_id: String key
    state: Float mutable

series Sensor.state:
    mean sliding 10s

rule alert_high_mean:
    Sensor s where s.mean > 50.0
->
    log critical "{s.entity_id}"
"""


def test_obs_triple_companion_slot_fires_on_high_mean():
    """The predicate on `s.mean` fires once the rolling mean crosses 50.

    The companion slot reads through the obs-triple `mean sliding 10s`
    declaration.
    """
    eng = pyds.from_source(_TRIPLE_FIRE)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    # Push values whose rolling EWMA mean climbs past 50.
    for v in [100.0, 110.0, 120.0]:
        eng.assert_("Sensor", entity_id="dev1", state=v)
        eng.pump()
    assert "dev1" in alerts, f"expected fire: {alerts!r}"
