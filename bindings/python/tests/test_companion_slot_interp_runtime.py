# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Companion-slot interpolation in log messages.

A log line like `log info "lux={s.median}"` resolves the companion slot
through the matching `series Schema.slot:` declaration, and is never
DS_VALIDATE_NO_SERIES_FOR_COMPANION_SLOT when one exists.

These tests cover the load + pump path.
"""

from log_sink import capture_critical

import pyds

_INTERP_COMPANION = """
use default

schema Sensor scope logical:
    entity_id: String key
    state: Float mutable

series Sensor.state:
    mean sliding 10s

rule report:
    Sensor s where s.mean > 50.0
->
    log critical "lux={s.mean}"
"""


def test_companion_slot_in_alert_interp_loads_and_fires():
    """`{s.mean}` inside an alert string renders the resolved aggregate value.

    It desugars into the series builtin call. The validator accepts the
    FunctionCall as a valid interp segment shape; CLIPS lowering renders it
    via _expr_to_clips inside the str-cat chain.
    """
    eng = pyds.from_source(_INTERP_COMPANION)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    for v in [100.0, 110.0, 120.0]:
        eng.assert_("Sensor", entity_id="dev1", state=v)
        eng.pump()

    # The rule fires after the rolling mean crosses 50; the alert text contains
    # "lux=" followed by the rendered mean. Compare loosely so floating-point
    # formatting differences don't spook the test.
    assert any(a.startswith("lux=") for a in alerts), (
        f"companion-slot interp didn't render: {alerts!r}"
    )
    # Rough sanity: the rendered mean should be in the same ballpark as the
    # inputs (>= 50.0 is the predicate threshold).
    rendered = next(a for a in alerts if a.startswith("lux="))
    val = float(rendered.removeprefix("lux="))
    assert val > 50.0, f"rendered mean below threshold: {rendered!r}"


_INTERP_COMPANION_LOG = """
use default

schema Sensor scope logical:
    entity_id: String key
    state: Float mutable

series Sensor.state:
    mean sliding 10s

rule report_log:
    Sensor s where s.mean > 50.0
->
    log info "ent={s.entity_id} mean={s.mean}"
"""


def test_companion_slot_log_interp_renders_alongside_real_slot():
    """A log line mixing a real-slot and a companion-slot interp renders both.

    The real slot is `{s.entity_id}` and the companion slot `{s.mean}`: the
    message's concatenation holds a String slot read and a formatted
    aggregation read side by side.
    """
    eng = pyds.from_source(_INTERP_COMPANION_LOG)
    logs: list[tuple[str, str, str]] = []
    eng.on_log = lambda ev: logs.append((ev.level, ev.category, ev.message))

    for v in [100.0, 110.0, 120.0]:
        eng.assert_("Sensor", entity_id="dev1", state=v)
        eng.pump()

    rule_logs = [m for lvl, _, m in logs if lvl == "INFO" and m.startswith("ent=")]
    assert rule_logs, f"rule never logged: {logs!r}"
    msg = rule_logs[-1]
    assert "ent=dev1" in msg, msg
    # mean=<float> should be present (substring check rather than exact
    # equality to avoid printf-formatting brittleness).
    assert "mean=" in msg, msg
