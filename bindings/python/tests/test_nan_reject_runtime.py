# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""NaN is rejected at the assert ingress.

A NaN Float must never enter working memory: `NaN != NaN`, so it never
self-matches and corrupts no-op-reassert identity, beta joins, and refraction.
`ds_engine_assert` rejects it (DS_ERR_NAN_REJECTED, surfaced as an exception) and
bumps `ds.facts.nan_rejected_total`. `Inf` is a *valid* value — only NaN is
rejected — so it asserts cleanly.
"""

import math

import pytest

import pyds

_SRC = """
schema Reading scope logical:
    id: String key
    x: Float mutable

rule touch:
    Reading
->
    log info "r"
"""


def test_nan_float_rejected_at_assert():
    """Asserting a NaN Float raises (DS_ERR_NAN_REJECTED) and nothing lands."""
    eng = pyds.from_source(_SRC)
    with pytest.raises(Exception, match="NaN"):
        eng.assert_("Reading", id="a", x=math.nan)
    assert len(eng.facts) == 0


def test_inf_float_allowed_at_assert():
    """Inf is a valid value: it asserts and lives in working memory."""
    eng = pyds.from_source(_SRC)
    eng.assert_("Reading", id="a", x=math.inf)
    eng.pump()
    assert len(eng.facts) == 1
