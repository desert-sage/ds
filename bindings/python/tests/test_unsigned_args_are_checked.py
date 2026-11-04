# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""An unsigned argument out of its libds range raises OverflowError.

A parse with `K`, `k` or `I` masks to the C width: -1 becomes 2**64 - 1 and
2**32 + 5 becomes 5, and the call goes ahead with the wrong value. Each case
here is one call site, at the width libds declares for it.

A fact is named by its FactId and looked up, never converted to a pointer,
so the calls that take one raise KeyError for any id with no live
fact, out of range or not: test_fact_ids.py.
"""

from __future__ import annotations

import pytest

import pyds

_PROGRAM = """use default

schema S scope logical:
    k: Int key

schema T scope ttl 1_s:
    v: Int
"""


def _engine() -> pyds.Engine:
    return pyds.from_source(_PROGRAM)


U64_OUT = [-1, 2**64]
U32_OUT = [-1, 2**32, 2**32 + 5]

CASES = [
    *[(f"clock.set({v})", lambda e, v=v: e.clock.set(v)) for v in U64_OUT],
    *[(f"clock.advance({v})", lambda e, v=v: e.clock.advance(v)) for v in U64_OUT],
    *[
        (f"cache.seed(ttl_ns={v})", lambda e, v=v: e.cache.seed("k", "1", ttl_ns=v))
        for v in U64_OUT
    ],
    *[(f"cache.set_cap(keys={v})", lambda e, v=v: e.cache.set_cap(keys=v)) for v in U32_OUT],
    *[(f"cache.set_cap(bytes={v})", lambda e, v=v: e.cache.set_cap(bytes=v)) for v in U64_OUT],
]


@pytest.mark.parametrize("call", [c for _, c in CASES], ids=[i for i, _ in CASES])
def test_out_of_range_raises_overflow_error(call):
    eng = _engine()
    eng.clock.mode = "mock"
    with pytest.raises(OverflowError):
        call(eng)


def test_a_value_past_32_bits_reaches_a_64_bit_parameter_whole():
    eng = _engine()
    eng.clock.mode = "mock"
    eng.clock.set(2**40 + 3)
    assert eng.clock.now_ns == 2**40 + 3


def test_the_largest_32_bit_value_is_accepted():
    eng = _engine()
    eng.cache.set_cap(keys=2**32 - 1)
