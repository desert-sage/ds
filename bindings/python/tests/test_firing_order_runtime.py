# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime test for the firing order — source order, end to end.

[LDET.5.1] gives two keys and the OUTER one is [LDET.5.4]'s terminal
ordinal, which is source order: the rule written first fires first.
[LDET.5.5]'s creation timetag is the inner key and only ever separates
activations of the SAME rule.

This file tested priority bands until W2 (R14c) removed them. The shape is
kept deliberately — one fact activating three rules in one pump — because it
is the shape that distinguishes the two models. The band-era expectation was
`top, mid, low`; the source-order expectation is the file order.
"""

from log_sink import capture_critical

import pyds

_THREE = """
schema Trig scope logical:
    v: Int key

rule low:
    Trig
->
    log critical "low"

rule mid:
    Trig
->
    log critical "mid"

rule top:
    Trig
->
    log critical "top"
"""


def test_rules_fire_in_source_order():
    """Three rules one Trig fact activates in one pump fire in the order of the file."""
    eng = pyds.from_source(_THREE)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Trig", v=1)
    eng.pump()
    assert alerts == ["low", "mid", "top"], f"rules fired out of source order: {alerts!r}"
