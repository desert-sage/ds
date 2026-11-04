# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for negated LHS patterns (`not <Schema>`)."""

from log_sink import capture_critical

import pyds

_NEG = """
schema Sensor scope logical:
    entity_id: String key
    state: Int mutable

schema Override scope logical:
    entity_id: String key

rule alert_no_override:
    Sensor s where s.state > 50
    no Override o where o.entity_id == s.entity_id
->
    log critical "{s.entity_id}"
"""


def test_negated_pattern_blocks_when_match_present():
    """When a matching Override fact is present, the negated CE blocks the rule."""
    eng = pyds.from_source(_NEG)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Override", entity_id="dev1")
    eng.assert_("Sensor", entity_id="dev1", state=99)
    eng.pump()
    assert alerts == [], f"negated CE didn't block: {alerts!r}"


def test_negated_pattern_fires_when_no_match():
    """No matching Override → rule fires."""
    eng = pyds.from_source(_NEG)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Sensor", entity_id="dev1", state=99)
    eng.pump()
    assert alerts == ["dev1"], f"rule didn't fire without override: {alerts!r}"


def test_negated_pattern_per_entity_separation():
    """An Override on one entity_id doesn't suppress firing for another."""
    eng = pyds.from_source(_NEG)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Override", entity_id="dev1")
    eng.assert_("Sensor", entity_id="dev2", state=99)
    eng.pump()
    assert alerts == ["dev2"], f"per-key negation leaked: {alerts!r}"
