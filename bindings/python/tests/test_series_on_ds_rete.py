# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The series absorb path at runtime.

The read path is the ds_series_<agg> adapters in engine_rete_adapters.c.
This test exercises the absorb side: the end-of-pump WM walker
(engine_rete_adapters.c::ds_rete_engine_absorb_pending, hooked from
ds_engine_pump after ds_rete_run drains). Each fact contributes at most
one sample (per-fact `series_absorbed` flag, a refraction analogue), and
hydrated facts (hydrated_corr != "") are skipped.

Fire-then-sample order across pumps is preserved: the rule's
where-clause for the Nth assert sees count from samples 1..N-1; the
absorber processes sample N AFTER the agenda drains, so the next
pump's read sees N. So `count(...) >= 3` first becomes true on the
4th assert — same sequence as test_series_accumulator.py.
"""

from __future__ import annotations

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


def _compile_with_rete(source: str) -> bytes:
    """Compile a series program under the DEFAULT dialect.

    This used to bind a pyds-specific dialect, because validate() looked up
    backend availability per dialect ([NDLC.2.3]) and `default` bundled none.
    That gate is retired ([LSER.13.13]): [NSBK.2.3]
    fixes the seven magics, every conforming runtime carries all of them, and
    a dialect declaring which it bundles declared something that cannot vary.

    Passing no dialect is therefore the assertion, not a simplification — a
    bare program referencing an aggregation has to compile.
    """
    return pyds.compile(source, file="t.ds")


def test_accumulator_count_fires_on_fourth_assert_ds_rete():
    """Mirror of test_series_accumulator::test_accumulator_count_fires_on_fourth_assert.

    The end-of-pump absorb walker has to wire engine->series_state up
    correctly for the read adapters to return non-zero counts on the
    next pump.
    """
    dsc = _compile_with_rete(_DS_SOURCE)
    alerts: list[str] = []
    eng = pyds.Engine()
    capture_critical(eng, alerts)
    eng.load_dsc(dsc)

    eng.pump()
    assert alerts == []

    eng.assert_("Trade", symbol="AAPL", price=100.0)
    eng.pump()
    assert alerts == [], f"after #1: {alerts!r}"

    eng.assert_("Trade", symbol="AAPL", price=101.0)
    eng.pump()
    assert alerts == [], f"after #2: {alerts!r}"

    eng.assert_("Trade", symbol="AAPL", price=102.0)
    eng.pump()
    assert alerts == [], f"after #3: {alerts!r}"

    eng.assert_("Trade", symbol="AAPL", price=103.0)
    eng.pump()
    assert alerts == ["three"], f"after #4: {alerts!r}"


def test_accumulator_count_partitions_by_identity_ds_rete():
    """Per-symbol counts don't bleed across identity values.

    GOOG asserts shouldn't lift AAPL's count toward the 3-sample
    threshold. The absorb walker's ds_series_state_lookup_or_insert
    keys on (schema, slot, id_slot, id_value), so distinct symbols
    allocate distinct rows.
    """
    dsc = _compile_with_rete(_DS_SOURCE.replace('"three"', '"three {t.symbol}"'))
    alerts: list[str] = []
    eng = pyds.Engine()
    capture_critical(eng, alerts)
    eng.load_dsc(dsc)

    # Three GOOG asserts, each reading GOOG's row before its own sample.
    eng.assert_("Trade", symbol="GOOG", price=2800.0)
    eng.pump()
    eng.assert_("Trade", symbol="GOOG", price=2801.0)
    eng.pump()
    eng.assert_("Trade", symbol="GOOG", price=2802.0)
    eng.pump()
    # AAPL's first fact reads AAPL's own row, 0. GOOG's live fact reads 3 now
    # and fires: the `where` reads a series, so it is re-read every pump
    # ([LTIM.2.4.1]), and a fact fires on the pump
    # its condition first holds ([LTIM.2.5.1]). A bleed would add "three AAPL".
    eng.assert_("Trade", symbol="AAPL", price=100.0)
    eng.pump()
    assert alerts == ["three GOOG"], f"AAPL/GOOG bleed: {alerts!r} — count partitioning broken"

    # A 4th GOOG is a new fact, which reads 3 and fires.
    eng.assert_("Trade", symbol="GOOG", price=2803.0)
    eng.pump()
    assert alerts == ["three GOOG", "three GOOG"], f"after 4th GOOG: {alerts!r}"
