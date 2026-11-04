# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for multi-rule cascades.

A rule's `emit` action asserts a fact that another rule
patterns on. Within a single pump, both rules fire — the
chain semantics let authors split work across rules without
external orchestration.
"""

import pyds

_CASCADE = """
schema A scope logical:
    v: Int key

schema B scope logical:
    derived: Int key

schema C scope logical:
    final: Int key

rule a_to_b:
    A a
->
    emit B logical derived: a.v

rule b_to_c:
    B b
->
    emit C logical final: b.derived
"""


def test_two_step_cascade_fires_through():
    """Asserting an A fact chains through to B and then C in a single pump."""
    eng = pyds.from_source(_CASCADE)
    events = []
    eng.on_event = events.append

    eng.assert_("A", v=42)
    eng.pump()

    schema_asserts = [e for e in events if isinstance(e, pyds.events.FactAssert)]
    # Three asserts: A (integrator-driven) + B + C.
    assert len(schema_asserts) == 3, f"expected 3 asserts, got {schema_asserts!r}"
    assert len(eng.facts) == 3, len(eng.facts)
