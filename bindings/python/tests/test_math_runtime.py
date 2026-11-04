# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for LEXP math constants + LEXP.5 distance builtins.

`math` and `distance` are standard-library modules (LIMP.3.3.4): a program
reaches `math.pi` and `distance.euclidean` only through an import. The
compile names no search path: every `dsc` has the standard library beside
it (LIMP.3.3.1, RCLI.1.11), and naming the repository's `stdlib/` as well
would put each module on the path twice, which LIMP.3.1.3 refuses as
ambiguous.
"""

from log_sink import capture_critical

import pyds


def _engine(source: str) -> pyds.Engine:
    eng = pyds.Engine()
    eng.load_dsc(pyds.compile(source, file="t.ds"))
    return eng


_PI = """
import math

schema Reading scope logical:
    entity_id: String key
    rad: Float mutable

rule alert_pi_above:
    Reading r where r.rad > math.pi
->
    log critical "{r.entity_id}"
"""


def test_pi_constant_inlines_correctly():
    """`math.pi` is the math constant (LEXP.4): the predicate fires above it, not below."""
    eng = _engine(_PI)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Reading", entity_id="above", rad=3.5)
    eng.assert_("Reading", entity_id="below", rad=3.0)
    eng.pump()
    assert alerts == ["above"], f"pi predicate gating wrong: {alerts!r}"


_DIST = """
import distance

schema Point scope logical:
    label: String key
    x: Float mutable
    y: Float mutable

rule alert_far:
    Point p where distance.euclidean(p.x, p.y, 0.0, 0.0) > 5.0
->
    log critical "{p.label}"
"""


def test_euclidean_2d_distance_predicate():
    """`distance.euclidean(x, y, 0, 0) > 5` fires for points farther than 5.0 from the origin."""
    eng = _engine(_DIST)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Point", label="near", x=1.0, y=1.0)  # ~1.41
    eng.assert_("Point", label="far", x=4.0, y=4.0)  # ~5.66
    eng.pump()
    assert alerts == ["far"], f"distance.euclidean gating wrong: {alerts!r}"
