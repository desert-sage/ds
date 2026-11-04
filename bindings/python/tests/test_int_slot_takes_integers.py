# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""An Int slot takes an integer and nothing else.

`int`, or any object with `__index__` -- the conversion `range()` and slicing
use. A `float` is refused rather than converted: a C cast from a double is
undefined for NaN, the infinities and anything outside int64, and silently
truncates everything else.
"""

from __future__ import annotations

import pytest

import pyds


class _Index:
    def __init__(self, n: int) -> None:
        self.n = n

    def __index__(self) -> int:
        return self.n


_PROGRAM = """use default

schema S scope logical:
    k: Int key
"""


def _engine() -> pyds.Engine:
    return pyds.from_source(_PROGRAM)


@pytest.mark.parametrize(
    "value", [2.9, -0.5, float("nan"), float("inf"), float("-inf"), 1e30, True, "3"]
)
def test_a_non_integer_is_refused(value):
    eng = _engine()
    with pytest.raises(TypeError, match="slot `k`"):
        eng.assert_("S", k=value)
    assert len(eng.facts) == 0


@pytest.mark.parametrize("value", [2**63, -(2**63) - 1])
def test_an_integer_outside_int64_is_refused(value):
    eng = _engine()
    with pytest.raises(OverflowError):
        eng.assert_("S", k=value)
    assert len(eng.facts) == 0


@pytest.mark.parametrize(
    "value, stored", [(7, 7), (_Index(7), 7), (2**63 - 1, 2**63 - 1), (-(2**63), -(2**63))]
)
def test_an_integer_is_stored_exactly(value, stored):
    eng = _engine()
    h = eng.assert_("S", k=value)
    assert eng.facts[h].slots["k"] == stored
