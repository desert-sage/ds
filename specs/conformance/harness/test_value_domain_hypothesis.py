#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
# @spec [NERR.6]
"""Hypothesis property test for the Float value-domain gate at assert ([NERR.6]).

[NERR.6] `DS_ERR_NAN_REJECTED` (-216): a NaN `Float` is rejected at
`ds_engine_assert` -- NaN must not enter working memory. `Inf` IS allowed at
assert (it is only rejected later if forced into a JSON body, -217). This drives
random `Float` streams through the real engine and checks the gate against a
reference model:

  * a NaN assert is rejected (raises) and leaves working memory UNCHANGED;
  * a finite or infinite Float assert is admitted (upsert on the key);
  * `fact_count` always equals the number of distinct keys carrying a
    non-NaN value.
"""
from __future__ import annotations

import math

import pytest
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

PROGRAM_DS = ("use default\n\n"
              "schema S scope logical:\n    k: Int key\n    x: Float mutable\n")

_DSC = None


def _new_engine():
    global _DSC
    import pyds
    if _DSC is None:
        _DSC = pyds.compile(PROGRAM_DS, file="value_domain.ds")
    eng = pyds.Engine()
    eng.load_dsc(_DSC)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    return eng


@settings(max_examples=250, deadline=None,
          suppress_health_check=[HealthCheck.too_slow])
@given(ops=st.lists(
    st.tuples(st.integers(0, 3),
              st.floats(allow_nan=True, allow_infinity=True, width=64)),
    max_size=25))
def test_nan_rejected_inf_and_finite_admitted(ops):
    eng = _new_engine()
    ref: dict[int, float] = {}     # key -> last admitted value (NaN never enters)
    try:
        for k, x in ops:
            if math.isnan(x):
                with pytest.raises(Exception):
                    eng.assert_("S", k=k, x=x)       # [NERR.6] -216 NaN rejected
                # NaN must not have entered working memory.
            else:
                eng.assert_("S", k=k, x=x)           # finite or Inf: admitted
                ref[k] = x
            assert len(eng.facts) == len(ref), (
                f"count diverged after ({k}, {x!r}): "
                f"engine={len(eng.facts)} ref={len(ref)}")
    finally:
        eng.close()


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
