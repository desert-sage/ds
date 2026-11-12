# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The series references held to the clauses' own words.

Unit tests of `series_reference.py`: the worked examples the clauses state,
the corner cases their words decide, and the two matrices ([LSER.18.1],
[LSER.17.2]) read back from the clause text, so that a clause that moves fails
here before the references are used against a runtime. Nothing here drives a
runtime and nothing here links a clause: these ratify nothing.
"""
from __future__ import annotations

import json
import math
import re
from pathlib import Path

import pytest

import series_reference as sr

_SPECS = Path(__file__).resolve().parents[2]       # specs/conformance/harness -> specs
_MODELS = ("all_time", "sliding", "tumbling", "sample")
INF = math.inf


def _clause_text(doc: str, clause: str) -> str:
    path = _SPECS / "language" / doc / f"{clause}.json"
    return json.loads(path.read_text(encoding="utf-8"))["text"]


def _rows(text: str) -> list[list[str]]:
    """The body rows of a clause's Markdown table: the lines that open with a
    backticked name, split on the pipes."""
    return [[c.strip() for c in line.strip().strip("|").split("|")]
            for line in text.splitlines() if line.startswith("| `")]


def _names(cell: str) -> list[str]:
    return re.findall(r"`([^`]+)`", cell)


def _neg_zero(x) -> bool:
    return isinstance(x, float) and x == 0.0 and math.copysign(1.0, x) < 0


# --- the two matrices are the clauses' -------------------------------------

def test_exact_cells_are_the_matrix_of_the_support_clause():
    text = _clause_text("SERIES", "LSER.18.1")
    parsed: dict[str, tuple[str, ...]] = {}
    for cells in _rows(text):
        exact = tuple(m for m, c in zip(_MODELS, cells[1:5]) if c.startswith("✓"))
        for name in _names(cells[0]):
            parsed[name] = exact
    assert parsed, "no table rows read from the clause"
    assert parsed == sr.EXACT_CELLS
    assert "tumbling" not in {m for ms in parsed.values() for m in ms}
    assert set(sr.TIME_MODELS) == {m for ms in parsed.values() for m in ms}


def test_admitted_types_are_the_matrix_of_the_applicability_clause():
    text = _clause_text("SERIES", "LSER.17.2")
    parsed: dict[str, tuple[str, ...]] = {}
    for cells in _rows(text):
        types = (sr.SAMPLED_TYPES if "any sampled type" in cells[1]
                 else tuple(_names(cells[1])))
        for name in _names(cells[0]):
            parsed[name] = types
    assert parsed, "no table rows read from the clause"
    assert parsed == sr.ADMITTED_TYPES
    sampled = re.search(r"The sampled types are(.*?)an opaque type", text, re.S)
    assert sampled is not None
    assert tuple(_names(sampled.group(1))) == sr.SAMPLED_TYPES
    assert set(sr.ADMITTED_TYPES) == set(sr.EXACT_CELLS)


# --- window admission ------------------------------------------------------

def test_sliding_window_is_half_open():
    s = [sr.Sample(0, 1), sr.Sample(5, 2), sr.Sample(10, 3)]
    assert sr.values(sr.sliding(s, 5, 10)) == [3]        # exactly 5 old: outside
    assert sr.values(sr.sliding(s, 6, 10)) == [2, 3]
    assert sr.values(sr.sliding(s, 5, 12)) == [3]
    assert sr.sliding(s, 5, 20) == []
    assert sr.all_time(s) == s


def test_capacity_drop_keeps_the_newest():
    s = [sr.Sample(t, t) for t in range(5)]
    assert sr.values(sr.at_capacity(s, 2)) == [3, 4]
    assert sr.at_capacity(s, None) == s
    assert sr.at_capacity(s, 9) == s


def test_reservoir_fills_in_order_then_replaces_one_slot_or_discards():
    s = [sr.Sample(i, i) for i in range(1, 51)]
    n = 7
    assert sr.reservoir(s[:3], n) == s[:3]               # not yet full: everything
    assert sr.reservoir(s[:n], n) == s[:n]
    held = s[:n]
    for i in range(n + 1, len(s) + 1):
        nxt = sr.reservoir(s[:i], n)
        assert len(nxt) == n
        moved = [k for k in range(n) if nxt[k] != held[k]]
        assert moved == [] or (len(moved) == 1 and nxt[moved[0]] == s[i - 1])
        held = nxt
    assert sr.reservoir(s, n) == held                     # the same trace, the same bag


def test_xorshift64_stays_in_sixty_four_bits_and_does_not_cycle_early():
    x = sr.RESERVOIR_SEED
    seen: set[int] = set()
    for _ in range(1000):
        x = sr.xorshift64(x)
        assert 0 < x < 1 << 64
        assert x not in seen
        seen.add(x)


# --- sums ------------------------------------------------------------------

def test_int_sum_wraps_and_float_sum_starts_at_plus_zero():
    assert sr.sum_int([]) == 0
    assert sr.sum_int([2**63 - 1, 1]) == -2**63
    assert sr.sum_int([-2**63, -1]) == 2**63 - 1
    assert sr.sum_float([]) == 0.0 and not _neg_zero(sr.sum_float([]))
    assert sr.sum_float([-0.0]) == 0.0 and not _neg_zero(sr.sum_float([-0.0]))
    assert sr.sum_float([1e308, 1e308]) == INF
    # Left to right, one rounding per step: the order is observable.
    assert sr.sum_float([0.1, 0.2, 0.3]) == (0.1 + 0.2) + 0.3
    assert sr.sum_float([0.1, 0.2, 0.3]) != 0.1 + (0.2 + 0.3)
    assert sr.sum_duration([5, 7]) == 12
    with pytest.raises(sr.NotRepresentable):
        sr.sum_duration([2**63 - 1, 1])


# --- mean and dispersion ---------------------------------------------------

@pytest.mark.parametrize("model", sr.TIME_MODELS)
def test_mean_and_dispersion_of_one_two_three(model):
    xs = [1.0, 2.0, 3.0]
    assert sr.mean(xs, model) == 2.0
    assert sr.variance(xs, model) == 1.0
    assert sr.pvariance(xs, model) == 2.0 / 3.0
    assert sr.stdev(xs, model) == 1.0
    assert sr.pstdev(xs, model) == math.sqrt(2.0 / 3.0)
    assert sr.mean([1, 2], model) == 1.5                  # Int samples convert


def test_one_sample_measures_no_dispersion():
    for model in sr.TIME_MODELS:
        assert sr.mean([-3.0], model) == -3.0
        assert sr.variance([-3.0], model) is None
        assert sr.stdev([-3.0], model) is None
        assert sr.pvariance([-3.0], model) == 0.0
        assert sr.pstdev([-3.0], model) == 0.0
    # The clause's own consequence: mu_1 = x_1 keeps a lone -0.0, and the
    # backings that start from +0 lose it.
    assert _neg_zero(sr.mean([-0.0], "all_time"))
    assert not _neg_zero(sr.mean([-0.0], "sliding"))
    assert not _neg_zero(sr.mean([-0.0], "sample"))


def test_a_variance_not_above_zero_is_a_zero_deviation_on_two_backings_only():
    assert math.isnan(sr.variance([INF, INF], "all_time"))
    assert sr.stdev([INF, INF], "all_time") == 0.0
    assert sr.pstdev([INF, INF], "sliding") == 0.0
    assert math.isnan(sr.stdev([INF, INF], "sample"))


def test_no_backing_for_tumbling():
    with pytest.raises(ValueError):
        sr.mean([1.0], "tumbling")


# --- quantiles -------------------------------------------------------------

def test_quantiles_interpolate_between_the_bracketing_order_statistics():
    assert sr.median([1, 2]) == 1.5                       # the clause's example
    assert sr.percentile([1.0, 2.0, 3.0, 4.0], 25) == 1.75  # num 75, lo 0, frac 75
    assert sr.percentile([4.0, 3.0, 2.0, 1.0], 25) == 1.75  # sorted first
    assert sr.percentile([1.0, 2.0, 3.0], 50) == 2.0      # frac 0
    assert sr.percentile([5.0], 37) == 5.0
    assert _neg_zero(sr.median([0.0, -0.0]))              # -0 sorts first; equal pair reads x_lo
    assert sr.median([-INF, 1.0]) == -INF
    assert sr.median([1.0, INF]) == INF
    assert math.isnan(sr.median([-INF, INF]))
    for p in (0, 100, 101):
        with pytest.raises(ValueError):
            sr.percentile([1.0], p)


# --- extremes --------------------------------------------------------------

def test_extremes_select_an_observed_value():
    assert sr.min_([3, 1, 2]) == 1 and sr.max_([3, 1, 2]) == 3
    assert sr.min_([2.5, -INF]) == -INF and sr.max_([2.5, -INF]) == 2.5
    assert _neg_zero(sr.min_([0.0, -0.0])) and _neg_zero(sr.min_([-0.0, 0.0]))
    assert not _neg_zero(sr.max_([0.0, -0.0])) and not _neg_zero(sr.max_([-0.0, 0.0]))
    assert sr.min_([7]) == 7 and sr.max_([7]) == 7


# --- counting, booleans, first and last ------------------------------------

def test_counting_uses_the_languages_equality():
    assert sr.count([1, 1, 2]) == 3
    assert sr.count_distinct([0.0, -0.0, 1.0]) == 2
    assert sr.count_distinct(["a", "b", "a"]) == 2
    assert sr.count_of(["a", "b", "a"], "a") == 2
    assert sr.count_of([0.0], -0.0) == 1
    assert sr.contains([1, 2], 2) is True
    assert sr.contains([1, 2], 3) is False
    assert sr.contains([INF], INF) is True


def test_boolean_aggregations_are_never_vacuous():
    assert sr.bool_and([True, False]) is False and sr.bool_and([True]) is True
    assert sr.bool_or([False]) is False and sr.bool_or([False, True]) is True


def test_first_and_last_are_the_oldest_and_newest():
    assert sr.first(["x", "y"]) == "x" and sr.last(["x", "y"]) == "y"


# --- direction and rate ----------------------------------------------------

def test_direction_is_the_sign_of_an_exact_comparison():
    assert sr.direction([1.0, 2.0]) == 1
    assert sr.direction([2.0, 1.0]) == -1
    assert sr.direction([2, 2]) == 0
    assert sr.direction([1.0, -0.0, 0.0]) == 0            # the two newest; -0 == +0
    assert sr.direction([INF, INF]) == 0
    assert sr.direction([-2**63, 2**63 - 1]) == 1         # never from a wrapped Int
    assert sr.direction([2**63 - 1, -2**63]) == -1
    assert sr.direction([5]) is None


def test_rate_is_the_change_over_the_elapsed_seconds():
    assert sr.rate([sr.Sample(0, 0.0), sr.Sample(2_000_000_000, 10.0)]) == 5.0
    assert sr.rate([sr.Sample(0, 0), sr.Sample(1_000_000_000, 3)]) == 3.0
    assert sr.rate([sr.Sample(0, 1.0), sr.Sample(5, 1.0), sr.Sample(10, 4.0)]) == 3e8
    assert sr.rate([sr.Sample(7, 1.0), sr.Sample(7, 9.0)]) is None   # no time elapses
    assert sr.rate([sr.Sample(0, 1.0)]) is None


# --- cold reads and the time dimension -------------------------------------

def test_cold_reads():
    for model in sr.TIME_MODELS:
        for f in (sr.mean, sr.variance, sr.pvariance, sr.stdev, sr.pstdev):
            assert f([], model) is None
    assert sr.count([]) == 0 and sr.count_distinct([]) == 0 and sr.count_of([], 1) == 0
    assert sr.contains([], 1) is False
    assert sr.median([]) is None and sr.percentile([], 99) is None
    assert sr.min_([]) is None and sr.max_([]) is None
    assert sr.first([]) is None and sr.last([]) is None
    assert sr.direction([]) is None and sr.rate([]) is None
    assert sr.bool_and([]) is None and sr.bool_or([]) is None


def test_a_time_dimension_result_rounds_ties_to_even_to_nanoseconds():
    assert sr.duration_of(None) is None
    assert sr.duration_of(2.5) == 2 and sr.duration_of(3.5) == 4
    assert sr.duration_of(1.0e18) == 10**18
    with pytest.raises(sr.NotRepresentable):
        sr.duration_of(INF)
    with pytest.raises(sr.NotRepresentable):
        sr.duration_of(1.0e19)
