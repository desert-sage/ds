# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for the 1-arg series-aggregation form.

`count(t.state)` (without explicit window) inherits the window
from the declared series per LSER.13.5. The validator injects
the window IntLit at expression resolution time; this test
verifies the lowered call actually fires correctly through the
runtime SeriesBackendWelfordEwma backend.
"""

from log_sink import capture_critical

import pyds

_ONE_ARG = """
schema Trade scope logical:
    symbol: String key
    price: Float mutable

series Trade.price (by: symbol):
    count sliding 5_s

rule alert_three_samples:
    Trade t where count(t.price) >= 3
->
    log critical "three"
"""


def test_count_one_arg_inherits_declared_series_window():
    """`count(t.price)` with no window argument reads the declared window (LSER.13.5).

    It reads the declared 5_000_000_000 ns window ([LSER.6.11.3]) because the
    declared accumulator window is 5s. Fire-then-sample applies
    so the rule first becomes true on the 4th assert (count==3
    seen pre-sample).
    """
    eng = pyds.from_source(_ONE_ARG)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    for v in [10.0, 11.0, 12.0]:
        eng.assert_("Trade", symbol="AAPL", price=v)
        eng.pump()
    assert alerts == [], f"premature fire: {alerts!r}"

    eng.assert_("Trade", symbol="AAPL", price=13.0)
    eng.pump()
    assert alerts == ["three"], f"1-arg count form didn't fire: {alerts!r}"
