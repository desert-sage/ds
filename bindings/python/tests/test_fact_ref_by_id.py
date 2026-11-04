# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""A fact-ref slot holds its target's fact id, and a read gives it.

libds keeps the referenced fact's id, never a pointer to it. pyds reads the
slot as that FactId whether or not the target is still in working memory;
whether it is is `fid in engine.facts`, and reading it is a KeyError once the
target has gone.

The referrer here is a `ttl` fact so that it outlives its target: a `logical`
emit would be withdrawn by truth maintenance along with the match, leaving
nothing to read.
"""

import pytest

import pyds

_SRC = """
schema Motion scope logical:
    entity_id: String key
    state: Int mutable

schema Trace scope ttl 1_h:
    target: Motion

rule make_trace:
    Motion m where m.state > 0
->
    emit Trace target: m
"""


def _engine_with_trace_sink():
    eng = pyds.from_source(_SRC)
    traces: list[pyds.FactId] = []

    def sink(ev):
        match ev:
            case pyds.events.FactAssert(fact_id=fid) if eng.facts[fid].schema == "Trace":
                traces.append(fid)

    eng.on_event = sink
    return eng, traces


def test_a_retracted_target_keeps_its_id():
    eng, traces = _engine_with_trace_sink()
    motion = eng.assert_("Motion", entity_id="kitchen", state=1)
    eng.pump()
    assert len(traces) == 1, traces
    trace = traces[0]

    # Live: the slot is the Motion's id, and the Motion is there.
    assert eng.facts[trace].slots["target"] == motion
    assert eng.facts[motion].schema == "Motion"

    eng.retract(motion)

    # The Trace stays; its reference still names the fact it referred to,
    # which is no longer in working memory.
    assert [f.schema for f in eng.facts.of("Trace")] == ["Trace"]
    assert eng.facts[trace].slots["target"] == motion
    assert motion not in eng.facts
    with pytest.raises(KeyError):
        eng.facts[motion]


def test_a_superseded_target_does_not_name_its_successor():
    """A Trace that referred to a superseded Motion does not name its successor.

    An upsert replaces the Motion with a new fact under a new id. The first
    Trace referred to the old one, so it must not name the new one -- the case
    a pointer got wrong whenever the new fact reused the old slot.
    """
    eng, traces = _engine_with_trace_sink()
    eng.assert_("Motion", entity_id="kitchen", state=1)
    eng.pump()
    first = traces[0]
    old_id = eng.facts[first].slots["target"]

    eng.assert_("Motion", entity_id="kitchen", state=2)
    eng.pump()
    motions = eng.facts.of("Motion")
    assert len(motions) == 1, motions
    new_id = motions[0].id
    assert new_id != old_id

    assert eng.facts[first].slots["target"] == old_id
    with pytest.raises(KeyError):
        eng.facts[old_id]

    # The Trace the second firing emitted refers to the new Motion.
    second = traces[-1]
    assert second != first
    assert eng.facts[second].slots["target"] == new_id
