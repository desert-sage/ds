# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for `publish <Schema> ...` action.

`publish` sends a fact to another tier and asserts nothing in its own
([LTIE.4.3]): the integrator's stream gets an `action_publish` event carrying
the fact's schema, its slot values and its FactExternal, and no `fact_assert`.
"""

import pyds

_PUBLISH = """
schema Trig scope logical:
    v: Int key

schema Bell scope ttl 1_min:
    msg: String

rule trig:
    Trig
->
    publish Bell msg: "ding"
"""


def test_publish_emits_action_publish_stream_event():
    """A rule firing `publish` produces one action_publish stream event.

    It carries the published schema and slot values, copied while the
    callback ran, and the FactExternal another tier asserts; and it is the
    only trace of the Bell: no fact_assert, no action_emit, no Bell in working
    memory.
    """
    eng = pyds.from_source(_PUBLISH)
    events = []
    eng.on_event = events.append

    eng.assert_("Trig", v=1)
    eng.pump()

    pubs = [e for e in events if isinstance(e, pyds.events.ActionPublish)]
    assert len(pubs) == 1, f"want one action_publish: {[e.kind for e in events]!r}"
    assert pubs[0].schema == "Bell"
    assert pubs[0].slots == {"msg": "ding"}
    assert pubs[0].external, "the event carries no FactExternal"

    asserted = [e for e in events if isinstance(e, pyds.events.FactAssert)]
    assert len(asserted) == 1, "only the Trig is asserted ([LTIE.4.3])"
    assert not any(isinstance(e, pyds.events.ActionEmit) for e in events)
    assert len(eng.facts) == 1
    assert eng.facts.of("Bell") == []
