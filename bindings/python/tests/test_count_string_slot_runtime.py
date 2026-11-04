# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""`count` series on a String slot.

count() on a String slot is well-defined (count the asserts; ignore the
value), so the SeriesBackendWelfordEwma backend routes a non-numeric value
through a count-only update that bumps the EWMA weight without polluting
mean / min / max, rather than refusing it at update time.

The series is declared `all_time`, NOT `tumbling`: `count tumbling` is refused
by the validator with DS_VALIDATE_SERIES_NO_EXACT_BACKING (LSER.15.2), and
never reaches the runtime. The String-value handling this test pins is a
property of the BACKEND, and `all_time` is what routes count to
SeriesBackendWelfordEwma. `sliding` would route to SeriesBackendRingBuffer and
quietly test something else.
"""

from log_sink import capture_critical

import pyds

_COUNT_STRING = """
use default

schema Buzzer scope logical:
    booth_id: String key
    buzzer_id: String mutable

series Buzzer.buzzer_id (by: booth_id):
    count all_time

rule alarm_three_buzzes:
    Buzzer b where count(b.buzzer_id) >= 3
->
    log critical "{b.booth_id}"
"""


def test_count_on_string_slot_does_not_reject_at_runtime():
    """String-valued asserts under a String-slot count series fire the >=3 predicate.

    Every pump goes through cleanly on the count-only update. fire-then-sample
    puts the alert on the 4th
    assert (the predicate sees the pre-sample count, so it crosses 3 then).
    """
    eng = pyds.from_source(_COUNT_STRING)
    alerts: list[str] = []
    capture_critical(eng, alerts)
    for v in ["b1", "b2", "b3"]:
        eng.assert_("Buzzer", booth_id="north", buzzer_id=v)
        eng.pump()
    assert alerts == [], f"premature fire: {alerts!r}"
    eng.assert_("Buzzer", booth_id="north", buzzer_id="b4")
    eng.pump()
    assert alerts == ["north"], f"count-on-String didn't fire: {alerts!r}"
