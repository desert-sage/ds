# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for multi-pattern rules (LHS joins).

A rule with two positive patterns matches when both fact types
exist with constraints satisfied. Cross-pattern bindings
(referencing slot vars from earlier patterns in later patterns)
exercise the join.
"""

from log_sink import capture_critical

import pyds

_JOIN = """
schema Sensor scope logical:
    entity_id: String key
    state: Int mutable

schema Threshold scope logical:
    entity_id: String key
    max_state: Int mutable

rule alert_over_limit:
    Sensor s
    Threshold t where t.entity_id == s.entity_id and s.state > t.max_state
->
    log critical "{s.entity_id}"
"""


def test_two_pattern_join_fires_when_constraint_satisfied():
    """Sensor + Threshold with matching entity_id and state > limit fire."""
    eng = pyds.from_source(_JOIN)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Threshold", entity_id="dev1", max_state=50)
    eng.assert_("Sensor", entity_id="dev1", state=99)
    eng.pump()
    assert alerts == ["dev1"], f"join didn't fire: {alerts!r}"


def test_two_pattern_join_silent_on_entity_mismatch():
    """With different entity_ids the cross-pattern binding can't unify."""
    eng = pyds.from_source(_JOIN)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Threshold", entity_id="dev1", max_state=50)
    eng.assert_("Sensor", entity_id="dev2", state=99)
    eng.pump()
    assert alerts == [], f"join cross-fired: {alerts!r}"


def test_two_pattern_join_silent_when_under_limit():
    """Same entity_ids but state ≤ limit — predicate fails."""
    eng = pyds.from_source(_JOIN)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Threshold", entity_id="dev1", max_state=50)
    eng.assert_("Sensor", entity_id="dev1", state=20)
    eng.pump()
    assert alerts == [], f"join fired despite under-limit: {alerts!r}"
