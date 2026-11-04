# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for `log <level> <msg>` actions across the LGRA.10.1.1 level set.

The levels are debug / info / warning / error / critical.
"""

import pyds


def _engine_for_level(level: str):
    src = f"""
schema Trig scope logical:
    v: Int key

rule trig:
    Trig
->
    log {level} "hello"
"""
    return pyds.from_source(src)


def test_each_log_level_threads_correctly_to_callback():
    """All five LGRA.10.1.1 log levels reach the log callback with their level string."""
    for level in ("debug", "info", "warning", "error", "critical"):
        eng = _engine_for_level(level)
        logs: list[pyds.events.LogEvent] = []
        eng.on_log = logs.append

        eng.assert_("Trig", v=1)
        eng.pump()

        assert len(logs) == 1, f"level={level}: expected one log, got {logs!r}"
        # The level is a LogLevel, whose value is the uppercase name the
        # validator normalises to.
        assert logs[0].level is pyds.LogLevel(level.upper()), f"level={level}: payload {logs[0]!r}"
        assert logs[0].message == "hello", logs[0]
