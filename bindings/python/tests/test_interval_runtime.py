# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for LINT interval relation operators.

`<point> in <interval>` lowers to `(and (<= start point) (<
point end))`. The interval is constructed from `..` operator on
two integer/numeric expressions. End-to-end through the engine
verifies the half-open lowering produces the right truth value.
"""

from log_sink import capture_critical

import pyds

_POINT_IN_INTERVAL = """
schema Reading scope logical:
    entity_id: String key
    val: Int mutable

rule alert_in_range:
    Reading r where r.val in (10 .. 20)
->
    log critical "{r.entity_id}"
"""


def test_point_in_interval_fires_on_value_inside():
    """val=15 is in [10, 20) → fires."""
    eng = pyds.from_source(_POINT_IN_INTERVAL)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Reading", entity_id="r1", val=15)
    eng.pump()
    assert alerts == ["r1"], f"`in` predicate didn't fire on inside value: {alerts!r}"


def test_point_in_interval_silent_on_below_start():
    """val=5 is below 10 → silent."""
    eng = pyds.from_source(_POINT_IN_INTERVAL)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Reading", entity_id="r1", val=5)
    eng.pump()
    assert alerts == [], f"unexpected fire: {alerts!r}"


def test_point_in_interval_silent_on_at_end_boundary():
    """val=20 equals end, so the half-open interval excludes it (LINT.3.1).

    The rule is silent: `i.start <= t < i.end`.
    """
    eng = pyds.from_source(_POINT_IN_INTERVAL)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Reading", entity_id="r1", val=20)
    eng.pump()
    assert alerts == [], f"`in` matched closed-end boundary: {alerts!r}"


def test_point_in_interval_fires_on_at_start_boundary():
    """val=10 equals start, so the half-open interval includes it (LINT.3.1).

    The rule fires: `i.start <= t < i.end`.
    """
    eng = pyds.from_source(_POINT_IN_INTERVAL)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Reading", entity_id="r1", val=10)
    eng.pump()
    assert alerts == ["r1"], f"`in` didn't match closed-start boundary: {alerts!r}"
