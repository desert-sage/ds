# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for `emit X logical` and CLIPS truth maintenance.

When a rule's RHS contains `emit X logical` (or `publish X
logical`), the lowering wraps the entire LHS pattern set in a
`(logical ...)` CE. CLIPS's truth-maintenance system then
auto-retracts the emitted X when the supporting LHS facts
disappear.
"""

import pyds

_LOGICAL_EMIT = """
schema Trig scope logical:
    v: Int key

schema Derived scope logical:
    src_v: Int key

rule derive:
    Trig t
->
    emit Derived logical src_v: t.v
"""


def test_logical_emit_creates_truth_maintained_derived_fact():
    """A logical emit's Derived fact is retracted with the Trig that justified it.

    Asserting Trig fires derive, which emits a logical Derived. Retracting the
    Trig (via integrator-driven retract) triggers truth maintenance to retract
    the Derived too.
    """
    eng = pyds.from_source(_LOGICAL_EMIT)
    events = []
    eng.on_event = events.append

    h = eng.assert_("Trig", v=42)
    eng.pump()
    asserts = [e for e in events if isinstance(e, pyds.events.FactAssert)]
    # Two asserts: Trig + Derived.
    assert len(asserts) == 2, f"expected 2 asserts, got {asserts!r}"
    assert len(eng.facts) == 2, len(eng.facts)

    # Retract the Trig — truth maintenance should drop Derived too.
    eng.retract(h)
    eng.pump()
    assert len(eng.facts) == 0, f"truth maintenance didn't retract Derived: count={len(eng.facts)}"
    retracts = [e for e in events if isinstance(e, pyds.events.FactRetract)]
    assert len(retracts) >= 2, f"expected >=2 retracts, got {retracts!r}"
