# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""End-to-end runtime test for the signal aggregation `integral` (LSIG.1.5 / 2.3).

`integral` is the time-weighted ∫x dt of a piecewise-constant numeric signal,
backed by the SeriesBackendNumericIntegral atom (LSIG.2.3). This drives the
full path: compiler backing-selection + SeriesBackendNumericIntegral emit (with
the load-bearing time_model + gap_policy) → DSC load (handle_sbni) → the
`ds_series_integral` adapter → the numeric-integral ring with its fixed-order
Float64 sum.

Signals change value on each assertion (DS meaningful-change discipline), so a
value held over [t_i, t_{i+1}) contributes value·(t_{i+1} - t_i) to the integral
once the next assertion closes the interval.
"""

from log_sink import capture_critical

import pyds

_INTEG_SLIDING = """
use default

schema Flow scope logical:
    entity_id: String key
    q: Float mutable

series Flow.q:
    integral sliding 10s

rule alert_vol:
    Flow f where f.integral > 40.0
->
    log critical "{f.entity_id}"
"""


def _assert_at(eng, t_ns, value):
    eng.clock.set(t_ns)
    eng.assert_("Flow", entity_id="d1", q=value)
    eng.pump()


def test_integral_sliding_accrues_and_fires():
    """Q held at 10 over [0,5s) closes to an integral of 50, over 40, at the 5s assertion.

    The companion-slot read then fires.
    """
    eng = pyds.from_source(_INTEG_SLIDING)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    # closed interval [0,5s) value 10 → 50; then a further change to observe it.
    for t, v in [(0, 10.0), (5, 20.0), (8, 30.0)]:
        _assert_at(eng, t * 1_000_000_000, v)

    assert "d1" in alerts, f"expected integral fire: {alerts!r}"


def test_integral_sliding_low_does_not_fire():
    """A small-magnitude signal never accrues past the 40 threshold."""
    eng = pyds.from_source(_INTEG_SLIDING)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    for t, v in [(0, 1.0), (5, 2.0), (8, 3.0)]:
        _assert_at(eng, t * 1_000_000_000, v)

    assert alerts == [], f"low signal must not fire: {alerts!r}"


_INTEG_ALL_TIME = _INTEG_SLIDING.replace("integral sliding 10s", "integral all_time")


def test_integral_all_time_accrues_unbounded():
    """all_time accumulates every closed interval with no eviction.

    The same [0,5s) x 10 = 50 crosses the threshold.
    """
    eng = pyds.from_source(_INTEG_ALL_TIME)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    for t, v in [(0, 10.0), (5, 20.0), (8, 30.0)]:
        _assert_at(eng, t * 1_000_000_000, v)

    assert "d1" in alerts, f"expected all_time integral fire: {alerts!r}"


# --- gap_policy is load-bearing on the RULE read path ----------------------
#
# `gap hold` (the LSIG.3.1 default) says the currently-held value keeps
# accruing between assertions; `gap zero` says the integral only advances when
# a sample lands. The two differ only when the read happens strictly LATER than
# the last absorption — so every test above, which reads at absorb time, cannot
# tell them apart, and neither can a read path that answers as-of the last
# sample.
#
# The Probe pattern is the whole trick: it re-activates the rule at a time when
# nothing has been absorbed into Flow.q, forcing the read to resolve as-of the
# clock rather than as-of the series.
#
# The read is on the RIGHT-HAND SIDE, not in the `where`. On a two-pattern rule
# a `where` reading the integral is refused ([LTIM.2.6.2],
# DS_VALIDATE_NOW_MULTIPATTERN_UNSUPPORTED): the join test would sit in a beta
# memory nothing invalidates. A `let` is evaluated at fire time, which is the
# read time this test is about, so the rule logs the value and the tests compare
# it against the threshold.

_INTEG_GAP = """
use default

schema Flow scope logical:
    entity_id: String key
    q: Float mutable

schema Probe scope logical:
    probe_id: String key
    n: Int mutable

series Flow.q:
    integral sliding 60s gap @GAP@

rule alert_vol:
    Flow f
    Probe p where p.n > 0
->
    let v = f.integral
    log critical "{f.entity_id}={v}"
"""


def _gap_engine(policy):
    eng = pyds.from_source(_INTEG_GAP.replace("@GAP@", policy))
    eng.clock.mode = "mock"
    eng.clock.set(0)
    alerts: list[str] = []
    capture_critical(eng, alerts)
    return eng, alerts


def _hold_10_then_probe_at(eng, probe_ns):
    """Hold q=10.0 from t=0, then re-activate the rule at `probe_ns`.

    Nothing further is absorbed into the series.
    """
    eng.clock.set(0)
    eng.assert_("Flow", entity_id="d1", q=10.0)
    eng.pump()
    eng.clock.set(probe_ns)
    eng.assert_("Probe", probe_id="p1", n=1)
    eng.pump()


_THRESHOLD = 40.0


def _integral_read(alerts: list[str]) -> float:
    """Return the integral the probe-time firing read, from its `d1=<v>` line.

    There is exactly one firing: the probe is the only re-activation, so a
    second value would mean the rule fired at absorb time too and the read
    time is ambiguous.
    """
    reads = [a for a in alerts if a.startswith("d1=")]
    assert len(reads) == 1, f"expected one probe-time firing: {alerts!r}"
    return float(reads[0].split("=", 1)[1])


def test_integral_gap_hold_accrues_between_assertions():
    """Under `gap hold` the held value integrates forward to the read time (LSIG.3.1).

    10.0 x 10s = 100.0 U·s, over the 40.0 threshold. A rule path that read as
    of the last absorb (t=0) would see 0.0.
    """
    eng, alerts = _gap_engine("hold")
    _hold_10_then_probe_at(eng, 10_000_000_000)
    v = _integral_read(alerts)
    assert v > _THRESHOLD, f"gap hold must accrue to the read time: read {v}"


def test_integral_gap_zero_does_not_accrue_between_assertions():
    """Under `gap zero` the integral advances only on assertion (LSIG.3.6, the control).

    The same stream stays at 0.0 and never crosses the threshold, which is
    what tells the two policies apart.
    """
    eng, alerts = _gap_engine("zero")
    _hold_10_then_probe_at(eng, 10_000_000_000)
    v = _integral_read(alerts)
    assert v <= _THRESHOLD, f"gap zero must not accrue between samples: read {v}"


def test_integral_gap_hold_below_threshold_still_does_not_fire():
    """A 1s gap under `gap hold` accrues only 10.0 U·s, under the threshold.

    Accruing is not the same as always crossing: this pins that the read uses
    a real elapsed time rather than saturating.
    """
    eng, alerts = _gap_engine("hold")
    _hold_10_then_probe_at(eng, 1_000_000_000)
    v = _integral_read(alerts)
    assert v <= _THRESHOLD, f"1s of hold is only 10.0 U*s: read {v}"
