# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""End-to-end series test: ring_buffer `count(...)` and `avg(...)`, and silence eviction.

The eviction is the silence-window sweep (8.7d).

Exercises the same pivot 8.7 path as the accumulator test, but
through the SeriesBackendRingBuffer backend:
- ring_buffer Float storage with explicit `window:` (LGRA.13.5)
- the aggregations SeriesBackendRingBuffer claims: count, avg, series_min,
  series_max
- Eviction sweep frees per-row instances after window-of-silence
  per LSER.9.3.1 — verifiable by advancing the mock clock past
  the window without further asserts and observing that count
  resets to 0 on the next sample.

⚠ **The read is `count(t.price)`, with no explicit window, and that is
load-bearing.** [RDSC.5a.8.1] keys a backend atom on
`(schema, slot, identity, magic, window_ns)` and says "each read resolves to
its own line's window". These tests declare `sliding 10_s`, so a read naming
window `0` — which is `all_time`, not "whatever was declared" — asks for a
series that does not exist. It does not fail loudly: [LSER.19.8] gives a cold
`count` a concrete zero, so the where-clause quietly compares `0 >= 3` and the
rule simply never fires. The one-argument form desugars to the declared window
per [LSER.13.5], which is what these tests mean.

The accumulator test beside this one reads `count(t.price)` too; before
[LSER.6.11.3] it wrote `count(t.price, 0)`, because it declares
`count all_time` — there, window `0` is the declared window and the read is
correct.
"""

from log_sink import capture_critical

import pyds

_DS_SOURCE = """
schema Trade scope logical:
    symbol: String key
    price: Float mutable

series Trade.price (by: symbol):
    count sliding 10_s

rule alert_three:
    Trade t where count(t.price) >= 3
->
    log critical "three"
"""


def test_ring_buffer_count_fires_on_fourth():
    """Under fire-then-sample (LSER.8.6) the rule fires on the 4th assert.

    That is the assert whose where-clause sees count == 3.
    """
    eng = pyds.from_source(_DS_SOURCE)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.pump()
    assert alerts == []

    eng.assert_("Trade", symbol="AAPL", price=100.0)
    eng.pump()
    assert alerts == []

    eng.assert_("Trade", symbol="AAPL", price=101.0)
    eng.pump()
    assert alerts == []

    eng.assert_("Trade", symbol="AAPL", price=102.0)
    eng.pump()
    assert alerts == [], f"after #3 (sample-then-fire would already alert): {alerts!r}"

    eng.assert_("Trade", symbol="AAPL", price=103.0)
    eng.pump()
    assert alerts == ["three"], f"got {alerts!r}"


def test_ring_buffer_eviction_after_silence():
    """A ring-buffer row whose silence-window has elapsed is freed (LSER.9.3.1).

    The row's backend instance is freed; the next sample
    cold-starts a fresh allocation. Observable: assert 4 facts so
    the count crosses the threshold and the rule fires once;
    advance the mock clock past the window with no further
    asserts; assert one more fact for the same identity. The new
    sample sees a cold-started buffer (count=0 at where-time, 1
    after absorber), so the rule does NOT fire again on this
    pump.
    """
    eng = pyds.from_source(_DS_SOURCE)
    eng.clock.mode = "mock"
    eng.clock.set(0)

    alerts: list[str] = []
    capture_critical(eng, alerts)

    # CLIPS evaluates the where-clause `(test ...)` at activation
    # time (when the fact asserts), not at agenda-fire time. Under
    # fire-then-sample, an absorber for a fact only runs in the
    # NEXT pump after the absorber is activated. So we pump
    # between asserts to let absorbers run; the 4th assert's
    # activation then sees count=3 and fires.
    eng.assert_("Trade", symbol="AAPL", price=100.0)
    eng.pump()
    eng.assert_("Trade", symbol="AAPL", price=101.0)
    eng.pump()
    eng.assert_("Trade", symbol="AAPL", price=102.0)
    eng.pump()
    eng.assert_("Trade", symbol="AAPL", price=103.0)
    eng.pump()
    assert alerts == ["three"], f"setup phase: got {alerts!r}"

    # Advance well past the 10s silence window. The next pump's
    # eviction sweep frees the AAPL row's backend instance.
    eng.clock.advance(60_000_000_000)  # +60s

    # A pump now triggers the eviction sweep but no new asserts:
    # nothing for the rule to do.
    eng.pump()
    # Asserting again cold-starts the row's SeriesBackendRingBuffer instance.
    # where sees count=0 (eviction freed the instance); rule false.
    alerts.clear()
    eng.assert_("Trade", symbol="AAPL", price=200.0)
    eng.pump()
    assert alerts == [], f"expected no alert after cold-start; got {alerts!r}"
