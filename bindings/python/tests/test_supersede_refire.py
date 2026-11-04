# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""[LFAC.2.5.3] — a meaningful change replaces the fact, so a rule re-fires.

Found by the `mercury-lockstep` gate: in `06_supersede` Mercury fires
`kitchen_high` on the replacement and libds built from the same commit does
not. The parametrisation separates the two readings — a supersede defect (only
the `prior` cases fail) from an evaluation defect (the `fresh` cases fail too) —
and the where-clause halves separate the conjuncts.
"""

import pytest

import pyds

_WHERES = {
    "both": 's.state > 75 and s.entity_id == "kitchen"',
    "state": "s.state > 75",
    "entity": 's.entity_id == "kitchen"',
}


def _src(where: str) -> str:
    return (
        "schema Sensor scope logical:\n"
        "    entity_id: String key\n"
        "    state: Float mutable\n"
        "\n"
        "rule kitchen_high:\n"
        f"    Sensor s where {where}\n"
        "->\n"
        '    log warning "high"\n'
    )


def _fires(where: str, prior: bool) -> list[str]:
    dsc = pyds.compile(_src(where), file="supersede.ds")
    eng = pyds.Engine()
    eng.clock.mode = "mock"
    fired: list[str] = []
    eng.on_event = lambda ev: (
        fired.append(ev.rule_name) if isinstance(ev, pyds.events.RuleFireBegin) else None
    )
    eng.on_log = lambda record: None
    eng.load_dsc(dsc)
    if prior:
        eng.assert_("Sensor", entity_id="kitchen", state=10.0)
        eng.pump()
        fired.clear()
    eng.assert_("Sensor", entity_id="kitchen", state=99.0)
    eng.pump()
    return fired


@pytest.mark.parametrize("prior", [False, True], ids=["fresh", "prior"])
@pytest.mark.parametrize("which", sorted(_WHERES))
def test_supersede_refire(which, prior):
    assert _fires(_WHERES[which], prior) == ["kitchen_high"]
