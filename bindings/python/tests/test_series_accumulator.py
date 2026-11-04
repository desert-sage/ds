# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""End-to-end series test: an accumulator's `count(...)` fires a rule fire-then-sample.

The ordering is LSER.8.6's.

Exercises the full pivot path:
- the DEFAULT dialect compiles a series aggregation. pyds used to register
  its own bundling four SeriesBackendDescriptors, because `default` bundled
  none; the dialect gate is retired ([LSER.13.13], [NDLC.2.3]), and the
  workaround with it
- all seven built-in backends registered at engine init ([NSBK.2.3])
- compiler lowers `count(t.price)` to (ds-series-count ...) builtin (8.7c)
- runtime builtin dispatch -> SeriesBackendWelfordEwma backend -> count query
(8.7c)
- compiler-emitted hidden absorber defrule at salience -10000 calls
  (ds-series-absorb ...) which dispatches to vtable->update; this is
  the RLOW.8.1.3 mechanism that gives LSER.8.6 fire-then-sample for
  free (author rule's where-clause sees PRE-sample state, then the
  absorber fires after every author rule activated by this fact)

Under fire-then-sample, the rule's where-clause for the Nth assert
sees count == N - 1 (samples 1..N-1 absorbed prior; sample N still
pending the absorber rule). So `count(...) >= 3` first becomes true
on the FOURTH assert.
"""

from log_sink import capture_critical

import pyds

_DS_SOURCE = """
schema Trade scope logical:
    symbol: String key
    price: Float mutable

series Trade.price (by: symbol):
    count all_time

rule alert_three_samples:
    Trade t where count(t.price) >= 3
->
    log critical "three"
"""


def test_accumulator_count_fires_on_fourth_assert():
    """Under fire-then-sample (LSER.8.6), `count(...) >= 3` first holds on the 4th assert.

    The Nth assert's where-clause sees count from samples 1..N-1; sample N
    hasn't been absorbed yet because the absorber defrule fires AFTER author
    rules at salience -10000. So on the 4th assert count == 3, from samples
    1, 2, 3.
    """
    eng = pyds.from_source(_DS_SOURCE)

    alerts: list[str] = []
    capture_critical(eng, alerts)

    # Pump once before any assert to drain TTL sweep / setup.
    eng.pump()
    assert alerts == []

    # Assert #1: where sees count=0; rule false; absorber takes count to 1.
    eng.assert_("Trade", symbol="AAPL", price=100.0)
    eng.pump()
    assert alerts == [], f"after #1: {alerts!r}"

    # Assert #2: where sees count=1; rule false; absorber takes count to 2.
    eng.assert_("Trade", symbol="AAPL", price=101.0)
    eng.pump()
    assert alerts == [], f"after #2: {alerts!r}"

    # Assert #3: where sees count=2; rule false; absorber takes count to 3.
    eng.assert_("Trade", symbol="AAPL", price=102.0)
    eng.pump()
    assert alerts == [], f"after #3: {alerts!r}"

    # Assert #4: where sees count=3; rule fires.
    eng.assert_("Trade", symbol="AAPL", price=103.0)
    eng.pump()
    assert alerts == ["three"], f"after the fourth: {alerts!r}"


def test_accumulator_absorbs_every_update_within_one_pump():
    """Samples are absorbed on every meaningful fact update, not once per pump (LSER.8.5.1).

    Trade is keyed on symbol, so three asserts before a single pump
    leave ONE fact in working memory. An absorber that walked WM at the
    end of the pump would lose the two superseded samples silently, and
    count(...) would reach 1 instead of 3.

    Kept separate from the partitions test below, whose subject is
    partitioning.
    """
    eng = pyds.from_source(_DS_SOURCE)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Trade", symbol="AAPL", price=100.0)
    eng.assert_("Trade", symbol="AAPL", price=101.0)
    eng.assert_("Trade", symbol="AAPL", price=102.0)
    eng.pump()
    # Fire-then-sample (LSER.8.6.1): the where-clause read happens
    # before absorption, so this pump still sees count == 0.
    assert alerts == [], f"premature alert: {alerts!r}"

    # The fourth assert re-activates the rule, and its where-clause now
    # sees all three earlier samples, not 1.
    eng.assert_("Trade", symbol="AAPL", price=103.0)
    eng.pump()
    assert alerts == ["three"], f"expected one 'three'; got {alerts!r}"


_PARTITION_SOURCE = _DS_SOURCE.replace('"three"', '"three {t.symbol}"')


def test_accumulator_count_partitions_by_identity():
    """Per-symbol counts don't bleed: GOOG's three samples are GOOG's.

    AAPL's first fact reads its own row, which is empty.

    The `where` reads a series, so it is re-read every pump ([LTIM.2.4.1]),
    and a live fact fires on the pump its
    condition first holds ([LTIM.2.5.1]). So GOOG's third fact, whose own
    pump read count 2, fires at the next pump with no new GOOG fact. The
    symbol is in the message, so that firing and a bleed into AAPL's row
    (which would read 3) are told apart.
    """
    eng = pyds.from_source(_PARTITION_SOURCE)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    # Three GOOG facts, one per pump, each reading GOOG's row before its own
    # sample: 0, 1, 2.
    for price in (200.0, 201.0, 202.0):
        eng.assert_("Trade", symbol="GOOG", price=price)
        eng.pump()
    assert alerts == [], f"premature alert: {alerts!r}"

    # AAPL's first fact reads AAPL's row, 0. GOOG's live fact reads 3 now.
    eng.assert_("Trade", symbol="AAPL", price=100.0)
    eng.pump()
    assert alerts == ["three GOOG"], f"AAPL/GOOG bleed: {alerts!r}"

    # A fourth GOOG is a new fact, which reads 3 and fires.
    eng.assert_("Trade", symbol="GOOG", price=203.0)
    eng.pump()
    assert alerts == ["three GOOG", "three GOOG"], f"after 4th GOOG: {alerts!r}"


_DIRECTION_DS = """
schema Trade scope logical:
    symbol: String key
    price: Float mutable

series Trade.price (by: symbol):
    direction all_time

rule alert_rising:
    Trade t where direction(t.price) == 1
->
    log critical "rising"

rule alert_falling:
    Trade t where direction(t.price) == -1
->
    log critical "falling"
"""


def test_accumulator_direction_rising_then_falling():
    """The direction query reports +1 rising and -1 falling (LSER.10.9).

    SeriesBackendWelfordEwma's answer is an Int, based on the EWMA-mean
    delta between the most recent absorbed sample and the prior state. The
    first pump's read is cold, so `null`, and does not fire ([LSER.19.8]).

    Two samples bootstrap the comparison; the third sample's
    where-clause sees the direction across samples 1→2.
    """
    eng = pyds.from_source(_DIRECTION_DS)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    # Sample #1 — bootstrap; no prior, direction stays "steady".
    eng.assert_("Trade", symbol="AAPL", price=100.0)
    eng.pump()
    # Sample #2 — absorb makes prev=100, mean rises to ~100.5.
    # Where-clause of sample #2 still sees pre-sample state
    # (direction "steady" from #1 before its absorb runs).
    eng.assert_("Trade", symbol="AAPL", price=110.0)
    eng.pump()
    # Sample #3 — where-clause sees direction post-absorb of #2,
    # which moved mean upward → "rising".
    eng.assert_("Trade", symbol="AAPL", price=120.0)
    eng.pump()
    assert "rising" in alerts, f"expected rising; got {alerts!r}"

    # Now drop — where-clause on #4 sees mean direction AFTER
    # absorb of #3 (mean climbing) — still "rising". Drop again on
    # #5 so the where-clause sees absorbed state going down →
    # "falling".
    eng.assert_("Trade", symbol="AAPL", price=80.0)
    eng.pump()
    eng.assert_("Trade", symbol="AAPL", price=70.0)
    eng.pump()
    assert "falling" in alerts, f"expected falling; got {alerts!r}"


_RATE_DS = """
schema Trade scope logical:
    symbol: String key
    price: Float mutable

series Trade.price (by: symbol):
    rate all_time

rule alert_rate_positive:
    Trade t where rate(t.price) > 0.0
->
    log critical "rate-positive"
"""


def test_accumulator_rate_reports_positive_for_climb():
    """A monotone climb yields a positive rate once two samples are absorbed.

    SeriesBackendWelfordEwma's rate is the per-second slope from the first
    sample to the running EWMA mean.
    """
    eng = pyds.from_source(_RATE_DS)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Trade", symbol="AAPL", price=100.0)
    eng.pump()
    eng.assert_("Trade", symbol="AAPL", price=110.0)
    eng.pump()
    eng.assert_("Trade", symbol="AAPL", price=120.0)
    eng.pump()
    # By assert #3 the rate-query sees the absorbed state from
    # samples 1..2 — both at higher prices than the initial.
    assert "rate-positive" in alerts, f"expected rate-positive; got {alerts!r}"
